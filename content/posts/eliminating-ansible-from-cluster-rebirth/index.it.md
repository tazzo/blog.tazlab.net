+++
title = "Consolidamento del Cluster e Eliminazione di Ansible dal Ciclo di Rinascita"
date = 2026-06-07T20:00:00+00:00
draft = false
tags = ["Kubernetes", "HashiCorp Vault", "Terraform", "Terragrunt", "Ansible", "Vault Secrets Operator", "Flux", "GitOps", "Talos", "Proxmox", "PostgreSQL", "PGO"]
description = "Tre progetti di consolidamento dell'infrastruttura cluster: eliminare Ansible e vault-configurator, consolidare tutta la configurazione Vault in Terraform puro, e ottenere un cluster one-shot senza interventi manuali in circa 12 minuti."
+++

## Il Problema Architetturale

Quando ho progettato il ciclo di rinascita del cluster TazLab, la sequenza era: Terraform creava le VM e installava Talos, poi subentrava Ansible per configurare Vault. Ansible faceva `kubectl exec` dentro un pod `vault-configurator` — un contenitore con la CLI di Vault dentro — per eseguire comandi come `vault auth enable jwt` e `vault policy write vso-policy`. Alla fine, Flux completava il deploy delle applicazioni.

Questo schema funzionava, ma aveva tre problemi strutturali.
Il primo era la **dipendenza circolare tra Vault e il cluster**. Vault è un servizio persistente su una VM Hetzner, ma per configurarlo serviva il cluster K8s (dove girava vault-configurator). E il cluster K8s, per funzionare, aveva bisogno di Vault (per i segreti di bootstrap). Spezzare questo anello richiedeva un orchestration complesso: Ansible doveva aspettare che il cluster fosse su, eseguire i comandi, e solo dopo Flux poteva convergere.


Il secondo era l'**assenza di GitOps per la configurazione di Vault**. Ansible è uno strumento procedurale, non dichiarativo. Lo stato della configurazione Vault non era in Git, non era in Terraform. Se qualcuno modificava manualmente una policy su Vault, al prossimo ciclo Ansible avrebbe comunque sovrascritto tutto — ma se Ansible falliva, Vault restava in uno stato inconsistente senza possibilità di rollback tramite Git.

Il terzo era la **fragilità del vault-configurator pod**. Era un Deployment Kubernetes con `sleep 36000` che serviva solo come proxy per `kubectl exec`. Se il pod crashava, Ansible falliva. Se il cluster era instabile, il comando non arrivava a Vault. Era un punto di rottura inutile.
Questo articolo racconta il percorso per eliminare completamente Ansible e vault-configurator, consolidare tutta la configurazione Vault in Terraform puro, e ottenere un ciclo di rinascita del cluster completamente one-shot: circa 12 minuti, zero interventi manuali, dalla distruzione delle VM al cluster completo con 83 pod.

> **Nota**: Questo articolo fa parte di una serie sul consolidamento dell'infrastruttura TazLab. Il progetto precedente ha riguardato la migrazione dei secret di bootstrap su Vault e di External Secrets Operator (ESO) da Terraform a Flux. Questo progetto parte da lì e completa la transizione eliminando l'ultimo componente non dichiarativo: Ansible.

## Architettura di Riferimento

Prima di entrare nel dettaglio dei progetti, è utile capire l'architettura in cui opero.

TazLab è un cluster Kubernetes su due VM Proxmox (control-plane e worker), con storage distribuito Longhorn, Tailscale come rete privata, e Vault come secret store su una VM separata su Hetzner. Il cluster è **ephemeral**: ogni ciclo di test parte da zero con `destroy.sh` che cancella le VM, e `create.sh` che le ricrea da immagini golden Talos. Vault è **persistente**: sopravvive ai cicli perché è su Hetzner, con snapshot S3 per il disaster recovery.

Questa separazione — Platform Landing Zone (Vault su Hetzner) e Workload Landing Zone (cluster K8s su Proxmox) — è un pattern architetturale noto, ma nel nostro caso era implementato male: Vault era persistente ma la sua configurazione dipendeva dal cluster effimero.

## I Tre Progetti

La migrazione è stata suddivisa in tre progetti, eseguiti in sequenza dopo un'estesa fase di review.

### Progetto 1: JWT Auth in Terraform

Il primo passo è stato portare la configurazione del JWT auth backend di Vault da Ansible a Terraform.

Il JWT auth backend permette a Vault di autenticare token JWT firmati dal Kubernetes API Server. Quando un ServiceAccount (ad esempio `vso-auth-sa`) presenta il suo token JWT a Vault, Vault verifica la firma usando la chiave pubblica del cluster e concede l'accesso secondo le policy associate.

Ansible configurava questo backend con:
```bash
kubectl exec -n vault-configurator vault-configurator -- vault auth enable jwt
kubectl exec -n vault-configurator vault-configurator -- vault write auth/jwt/config \
    jwt_validation_pubkeys=<public-key> \
    bound_issuer=<issuer>
```

Il problema: il vault-configurator doveva essere già in esecuzione nel cluster per eseguire questi comandi. Ma il cluster non poteva partire senza Vault configurato. Era una dipendenza circolare.

La soluzione è stata **generare la coppia di chiavi RSA offline** nel layer `secrets` di Terragrunt (il primo layer, che viene sempre eseguito) e configurare Vault JWT auth direttamente via Terraform Vault provider, usando il root token di Vault. Il provider Vault parla direttamente con Vault su Tailscale — non serve nessun pod intermediario.

```hcl
# modules/secrets-fetcher/main.tf
resource "tls_private_key" "serviceaccount" {
  algorithm = "RSA"
  rsa_bits  = 2048
}
```

```hcl
# live/persistent/vault-jwt-config/main.tf (dopo il refactoring)
provider "vault" {
  address = "https://lushycorp-vault.magellanic-gondola.ts.net:8200"
}

resource "vault_jwt_auth_backend" "k8s" {
  path         = "jwt"
  bound_issuer = "https://lushycorp-k8s.magellanic-gondola.ts.net:6443"
  jwt_validation_pubkeys = [var.serviceaccount_public_key_pem]
}
```

La chiave privata viene iniettata in Talos tramite `config_patches`, così l'API Server firma i ServiceAccount token con quella chiave:

```hcl
# modules/proxmox-talos/main.tf
cluster = {
  serviceAccount = {
    key = base64encode(var.serviceaccount_private_key_pem)
  }
}
```

Questo progetto ha già risolto la prima dipendenza: Vault JWT auth non ha più bisogno del cluster.

### Progetto 2: Database Engine in Terraform

Il secondo progetto ha gestito la configurazione del database engine di Vault per PostgreSQL.

Il database engine di Vault genera credenziali dinamiche: quando Grafana richiede un utente PostgreSQL, Vault crea un utente temporaneo con password monouso, lo concede a Grafana per il tempo necessario, e lo revoca alla scadenza.

Prima, Ansible configurava questo engine tramite vault-configurator. La nuova versione è un modulo Terraform che:

1. Crea la connessione al database PostgreSQL (con `verify_connection = false` — dettaglio cruciale)
2. Definisce il ruolo `grafana` con `creation_statements` per la generazione degli utenti
3. Salva le password di bootstrap in un segreto KV su Vault

```hcl
# modules/vault-db-config/main.tf
resource "vault_database_secret_backend_connection" "tazlab_db" {
  backend           = "database"
  name              = "tazlab-db"
  verify_connection = false  # Vault non ha bisogno del DB in questo momento

  postgresql {
    connection_url = "host=tazlab-db.magellanic-gondola.ts.net port=5432 dbname=tazlab user={{username}} password={{password}} sslmode=disable"
    username       = "tazlab-admin"
    password       = var.tazlab_admin_password
  }
}
```

In parallelo, **Secret Adoption** per PGO (PostgreSQL Operator di Crunchy Data): i secret Kubernetes con le password vengono creati prima che PGO esista, e PGO li adotta aggiungendo gli hash SCRAM necessari per l'autenticazione PostgreSQL. Questo pattern è essenziale perché PGO non può generare le password da solo — devono essere prevedibili da Vault.

```hcl
# modules/k8s-engine/main.tf
resource "kubernetes_secret_v1" "pguser_tazlab_admin" {
  metadata {
    name      = "tazlab-db-pguser-tazlab-admin"
    namespace = "tazlab-db"
    labels = {
      "postgres-operator.crunchydata.com/cluster" = "tazlab-db"
      "postgres-operator.crunchydata.com/pguser"  = "tazlab-admin"
    }
  }
  data = {
    password = var.tazlab_admin_password
    verifier = ""  # PGO compilerà questo campo
  }
  lifecycle { ignore_changes = [data, metadata] }
}
```

### Progetto 3: Cleanup — Rimozione di Ansible e vault-configurator

L'ultimo progetto ha rimosso tutto ciò che non serviva più:
- Il playbook Ansible e il ruolo per la configurazione K8s di Vault
- Il deployment di vault-configurator
- Le referenze in tutte le kustomization Flux
- La generazione del bootstrap token via out-of-state pattern

Il risultato: Niente più Ansible nel ciclo di rinascita del cluster.

## Le Review Preventive

Prima di scrivere una riga di codice Terraform, ho fatto una fase di review estesa che si è rivelata cruciale per la qualità del progetto.

**Multi-LLM Review**: Ho confrontato 5 modelli linguistici diversi (DeepSeek, MiMo, GLM, Qwen, Kimi) sugli stessi pattern architetturali. Ogni modello ha trovato criticità diverse — un bug nel bound_issuer, un errore nella gestione del verifier PGO, una dimenticanza nel rate limit. Alla fine, 40 findings sono stati ridotti a 20 reali, e tutti sono stati risolti prima della prima esecuzione.

**Design Review Iterativa**: Ogni progetto ha avuto 3-4 cicli di revisione del design prima di passare alla scrittura del codice. Le review hanno intercettato problemi come:
- Un errore nel calcolo della dipendenza tra Vault e cluster (chicken-egg)
- La mancanza del namespace `external-secrets` nella kustomization Flux (che avrebbe causato il fallimento di ESO)
- L'assenza del provider `tls` nel root Terragrunt (che avrebbe causato errori a runtime)

**Chronicle Review**: Ho rivisto le decisioni passate documentate nella cronaca del sistema per evitare di ripetere errori già affrontati.

> **Lezione**: Le review multi-modello non sono un esercizio accademico. Nel nostro caso hanno intercettato almeno 3 bug che avrebbero mandato in crash il primo ciclo di test. Il costo della review è stato ampiamente ripagato dal tempo risparmiato in debug.

## I Bug Più Problematici

Nonostante le review, il percorso di implementazione ha incontrato diversi bug che hanno richiesto cicli di test iterativi. Ecco i più significativi.

### 1. Terragrunt Cache Dependency

Il primo muro è stato Terragrunt. Quando si pulisce la cache di Terragrunt (`.terragrunt-cache/`) e si esegue `apply` su un layer che dipende da un altro, Terragrunt deve fare `terraform init` out-of-band per leggere lo stato della dipendenza. Senza il ledger locale di Terraform (`.terraform/`), Terraform rileva un backend cambiato e richiede `-reconfigure`. Terragrunt **non passa** `-reconfigure` durante gli init out-of-band, quindi fallisce silenziosamente e propaga l'errore come "no variable named dependency" — un messaggio fuorviante che non fa capire la causa reale.

```bash
# Errore criptico
Error: Unknown variable
  on terragrunt.hcl line 68:
  There is no variable named "dependency".
```

La soluzione è stata aggiungere `extra_arguments "init_reconfigure"` e `disable_dependency_optimization = true` al root `terragrunt.hcl`:

```hcl
terraform {
  extra_arguments "init_reconfigure" {
    commands = ["init"]
    arguments = ["-reconfigure"]
  }
}

remote_state {
  disable_dependency_optimization = true
}
```

### 2. Namespace Ordering

Uno dei problemi più subdoli è stato l'ordine di creazione delle namespace. Engine layer (Terraform) crea secret Kubernetes (vault-ca-cert, vault-eso-token, tailscale-operator-oauth) in namespace specifiche. Ma queste namespace sono create anche da Flux (kustomization `infrastructure-operators-namespaces`). Flux non era ancora partito quando il layer engine eseguiva, perché engine corre nella Phase 1 (Terraform foundation) e Flux nella Phase 2 (GitOps harmonization).

Il fix è stato duplice: da un lato, il modulo `k8s-engine` crea le namespace necessarie (tailscale, external-secrets, tazlab-db) prima di creare i secret al loro interno. Dall'altro, la definizione di alcune namespace critiche (dex, external-secrets) è stata spostata dalla cartella operator (che dipende da Flux) alla kustomization centralizzata `infrastructure-operators-namespaces`, che viene eseguita per prima nella catena Flux.

Questo ha risolto anche un altro problema: VSO (Vault Secrets Operator) cercava di creare un ServiceAccount nella namespace `dex`, ma la namespace non esisteva ancora perché la sua definizione era nella cartella `operators/dex/` che dipende da `infrastructure-bridge` — troppo in basso nella catena.

### 3. random_password Lifecycle

Le password dei database sono generate con `random_password` di Terraform. Il problema: senza `lifecycle { ignore_changes = [result] }`, ogni esecuzione di `terragrunt apply` rigenera una password diversa. Questo significa che Vault si ritrova con una password, PGO con un'altra, e la connessione database fallisce.

```hcl
resource "random_password" "tazlab_admin" {
  length           = 32
  special          = true
  override_special = "_-._~"
  lifecycle {
    ignore_changes = [result]
  }
}
```

Inoltre, le password devono avere lo **stesso source di truth**. Inizialmente, `random_password` era nel layer `engine`, ma vault-db-config dipendeva da engine per averle. Questo creava una dipendenza non necessaria — vault-db-config doveva aspettare che engine fosse stato applicato (dopo platform, dopo cluster health).

La soluzione è stata spostare `random_password` nel layer `secrets` (il primo layer Terragrunt), che viene eseguito prima di tutto. Ora sia engine che vault-db-config dipendono da secrets, e vault-db-config può essere eseguito subito dopo vault-jwt-config, prima ancora che le VM esistano.

### 4. Post-Flux Ridondante

Questo è stato il bug più dispendioso in termini di tempo. Per tre cicli di test, il create.sh moriva puntualmente dopo Flux convergence mentre aspettava il database. Il flusso era:

```
Flux convergence ✅
  → PGO wait (secret + master pod) → timeout 300s (o 600s)
    → ALTER ROLE (mai eseguito)
      → VDS annotate (mai eseguito)
        → vault read database/creds/grafana (mai eseguito)
```

Il create.sh usciva con errore, e io eseguivo manualmente i passi rimanenti. Per tre cicli ho creduto che questi passi fossero necessari: l'ALTER ROLE per sincronizzare la password tra Vault e il database, l'annotazione del VaultDynamicSecret per forzare VSO a ricreare le credenziali di Grafana, lo smoke test per verificare.

Poi, in un ciclo in cui il create.sh è morto prima di arrivare a questi passi, ho scoperto che **il cluster funzionava perfettamente lo stesso**. La password era già sincronizzata (stessa fonte: secrets-fetcher), VSO aveva riconciliato automaticamente il VaultDynamicSecret, Grafana era su e funzionante.

Tutto il blocco post-Flux era ridondante perché:
- vault-db-config era già stato applicato **prima di platform** (con il refactoring del ciclo 7), quindi quando VSO partiva dopo Flux, la configurazione database di Vault era già pronta
- Le password condividevano la stessa fonte (secrets-fetcher), quindi non c'era bisogno di ALTER ROLE
- VSO riconcilia autonomamente il VaultDynamicSecret entro 3 minuti, nessuna annotazione manuale necessaria

L'intero blocco post-Flux (oltre 60 righe di codice, 3 timeout separati, 2 loop infinito) è stato rimosso dal create.sh.

### 5. kubectl wait pod master

L'ultimo bug che ha richiesto più tempo per essere diagnosticato. `kubectl wait --for=condition=Ready pod -l postgres-operator.crunchydata.com/role=master --timeout=600s` **fallisce immediatamente** se nessun pod corrisponde al selettore al momento dell'esecuzione. Non aspetta 600 secondi — esce subito con "no matching resources found". Il `--timeout` si applica solo a pod che **già esistono**.

Il fix è stato separare l'attesa in due fasi:

```bash
# Fase 1: aspetta che il pod esista
while [[ -z "$MASTER_POD" ]]; do
  MASTER_POD=$(kubectl get pod -n tazlab-db -l role=master -o name 2>/dev/null || echo "")
  if (( SECONDS > TIMEOUT_POD )); then exit 1; fi
  sleep 10
done

# Fase 2: aspetta che sia Ready
kubectl wait "$MASTER_POD" -n tazlab-db --for=condition=Ready --timeout=300s
```

## Il Risultato

Dopo 9 cicli di test, 8 destroy+create, e innumerevoli fix, il ciclo di rinascita del cluster è ora **completamente one-shot**.

```
secrets (16s) → vault-jwt-config (18s) → vault-db-config (18s) → platform (101s)
→ engine (21s) → networking+gitops+storage (parallel, 115s)
→ Flux convergence
```

Tempo totale: **circa 12 minuti**. Risultato: 21/21 kustomization Flux, 83 pod, Blog, Wiki, Grafana, Prometheus, DB, Mnemosyne, pgAdmin — tutto operativo. Zero interventi manuali.

### Cosa è cambiato rispetto a prima

| Prima (Ansible) | Dopo (Terraform) |
|----------------|------------------|
| 9 interventi manuali per ciclo | 0 interventi manuali |
| vault-configurator pod (dipendenza dal cluster) | Provider Vault diretto su Tailscale |
| Dipendenza circolare Vault ↔ Cluster | Vault configurato prima che il cluster esista |
| Stato non in Git | Tutto in Terraform + Flux |
| vault-db-config dopo Flux (moriva) | vault-db-config prima di platform |
| Password in engine layer (dipendenza) | Password in secrets layer (source unico) |
| VDS annotate manuale | VSO auto-reconcilia |

### Lezioni Apprese

1. **Separa Persistent dalle dipendenze dal cluster**. Se Vault è su una VM esterna, configura Vault prima che il cluster esista. Non mescolare configurazione persistent con deploy del workload.

2. **Le password devono avere un unico source of truth**. Se più componenti (engine, vault-db-config) usano la stessa password, la password deve essere generata nel layer più a monte possibile e passata per dependency dove serve.

3. **Non fidarti dei timeout di `kubectl wait`**. `kubectl wait` con label selector fallisce immediatamente se nessun pod esiste. Usa un loop di polling esplicito.

4. **Fai review preventive con modelli diversi**. Il multi-LLM review ha intercettato bug che nessun revisore umano avrebbe trovato. Costa meno di un ciclo di test fallito.

5. **Se un passo post-bootstrap fallisce sempre, forse non serve**. Se il cluster funziona senza un passo (ALTER ROLE, annotate, smoke test), quel passo è ridondante. Non forzarlo — rimuovilo.
