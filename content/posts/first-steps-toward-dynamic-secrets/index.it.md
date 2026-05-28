+++
title = "Primi Passi Verso i Segreti Dinamici: Dal Caos del PKI al JWT Auth"
date = 2026-05-28T17:35:00+00:00
draft = false
description = "Dopo aver migrato tutti i segreti statici da Infisical a Vault, è il momento di iniziare il cammino verso i segreti dinamici. Ma preparare il terreno si è rivelato più complesso del previsto: un errore di path in Talos ha fatto crollare il cluster, il nameserver di Tailscale aveva un bug silenzioso, e il bootstrap nascondeva sei dipendenze circolari."
tags = ["vault", "jwt", "kubernetes", "talos", "tailscale", "coredns", "crisp", "architecture", "secret-management"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# Primi Passi Verso i Segreti Dinamici: Dal Caos del PKI al JWT Auth

Se avete seguito la storia del cluster TazLab finora, sapete che la migrazione da Infisical a Vault è stata completata con successo a maggio 2026. Ventidue ExternalSecrets migrati, zero riferimenti a Infisical nel codice di produzione, e un ciclo destroy/create certificato. I segreti statici — token API, certificati TLS, credenziali OAuth — vivevano finalmente tutti nel Vault su Hetzner.

Ma il vero obiettivo non era sostituire un fornitore esterno con un altro. Il vero obiettivo era arrivare ai **segreti dinamici**: credenziali generate al volo da Vault, con lease temporaneo, rotazione automatica, e nessuna password hardcodata in un Secret Kubernetes.

Questo articolo racconta la prima tappa di quel viaggio: quello che doveva essere un compito apparentemente semplice — esporre l'API server Kubernetes sulla Tailnet e configurare l'autenticazione JWT — si è trasformato in una sessione che ha attraversato un disastro PKI, sei deadlock di bootstrap, e un bug silenzioso nel nameserver di Tailscale. Tutto prima ancora di scrivere la prima riga di configurazione del Vault Agent Injector.

## Il Problema Architetturale

Il Vault Agent Injector è un admission webhook Kubernetes che inietta inizializzatori e sidecar nei Pod. Questi container si autenticano a Vault utilizzando il ServiceAccount JWT del Pod, ottengono credenziali dinamiche, e le montano in una memoria tmpfs condivisa. Nessun Secret Kubernetes, nessun ExternalSecret, nessun ESO. Solo il Pod e Vault che comunicano direttamente.

Ma perché questo funzioni, Vault deve poter validare i JWT emessi dal Kubernetes API server. E per farlo, Vault ha bisogno di:

1. Raggiungere l'API server via HTTPS (dalla Hetzner VM, attraverso Tailscale)
2. Ottenere le chiavi pubbliche di firma dei token (endpoint `/openid/v1/jwks`)
3. Un issuer URL che sia risolvibile dalla VM esterna (non `kubernetes.default.svc.cluster.local`)

Il primo passo, quindi, era esporre l'API server Kubernetes sulla Tailnet tramite un LoadBalancer di Tailscale, configurare i `certSANs` del certificato TLS dell'API server per includere il nome MagicDNS, e impostare `service-account-issuer` con un URL raggiungibile da Vault.

Un'attività apparentemente lineare, che ho affrontato con la metodologia CRISP: progetto `10-vault-agent-injector-phase1`, Stage 1 (P0), tasks.md con 39 task atomici. Il piano sembrava solido. La realtà è stata diversa.

## Fase 1: Il Disastro PKI — machine.certSANs ≠ cluster.apiServer.certSANs

Il primo errore è stato anche il più istruttivo. Per aggiungere il nome DNS dell'API server al suo certificato TLS, ho cercato il modo di configurare i `certSANs` in Talos. Con `talosctl patch mc` ho applicato questa patch:

```yaml
machine:
  certSANs:
    - lushycorp-k8s.magellanic-gondola.ts.net
```

Talos ha risposto: "Applied configuration without a reboot". Sembrava funzionare. Ho riavviato il nodo control plane per sicurezza, e il cluster è morto.

Tutti i Pod sul nodo worker hanno perso connettività con l'API server. kube-proxy mostrava errori `Unauthorized` a raffica. kubelet non riusciva più a comunicare. Il rollout del control plane aveva rigenerato il PKI tramite `trustd`, il gestore certificati di Talos, ma i kubeconfig sui nodi worker non erano stati aggiornati. Il risultato era un cluster in deadlock irreversibile.

### Cosa avevo sbagliato

Talos ha **due** path distinti per i `certSANs`, e hanno effetti completamente diversi:

- **`machine.certSANs`**: Aggiunge SAN al **certificato del nodo Talos** (porta 50000, API demone di Talos). Serve per connettersi al nodo via talosctl usando un nome DNS invece dell'IP. La modifica di questo campo attiva `trustd`, che rigenera l'intero PKI del cluster — certificati del nodo, certificati di kubelet, certificati di kube-proxy — e li distribuisce a tutti i nodi. Se i nodi worker non vengono riavviati insieme al control plane, ricevono certificati vecchi e vengono rifiutati dall'API server.

- **`cluster.apiServer.certSANs`**: Aggiunge SAN al **certificato TLS del Kubernetes API server** (porta 6443). Non attiva trustd, non rigenera il PKI. L'API server ricarica il certificato al prossimo restart.

La lezione è semplice ma costosa: su Talos, i due path non sono intercambiabili. Usare `machine.certSANs` per modificare il certificato dell'API server è come cambiare l'indirizzo di casa tua modificando l'URL del GPS — tecnicamente sono entrambi "indirizzi", ma hanno effetti completamente diversi.

La soluzione è stata altrettanto chiara: tutte le patch Talos per l'API server dovevano essere **baked nel bootstrap**, non applicate a cluster running. Ho spostato `certSANs`, `service-account-issuer`, `api-audiences` e `service-account-jwks-uri` nel `config_patches` del modulo Terraform `proxmox-talos`, in modo che venissero applicati durante la creazione iniziale del cluster, evitando completamente il problema della rigenerazione PKI.

## Fase 2: Sei Deadlock di Bootstrap

Dopo il disastro PKI, la strategia è cambiata: distruggere e ricreare il cluster con le patch già incluse nella configurazione iniziale. Ma a ogni tentativo di create.sh emergeva un nuovo blocco. Alla fine ne ho contati sei.

### Deadlock 1: L'OAuth dell'operatore Tailscale

Il Tailscale Operator ha bisogno di un segreto OAuth (clientId + clientSecret) per creare i proxy Pod sulla tailnet. Questo segreto, nella nuova architettura Vault-native, è un ExternalSecret che tira da Vault. Ma Vault è raggiungibile solo tramite DNS Tailscale (`*.magellanic-gondola.ts.net`), che richiede l'operatore Tailscale per funzionare. L'operatore ha bisogno di OAuth per partire, OAuth è in Vault, Vault ha bisogno dell'operatore per il DNS. Un uovo-gallina perfetto.

**Soluzione**: ho eliminato la dipendenza da Vault per i segreti di bootstrap. L'engine layer di Terraform ora crea il segreto OAuth direttamente dai file locali dell'operatore (`~/secrets/tailscale-operator-client-*`) usando `kubernetes_secret_v1`, bypassando completamente External Secrets Operator.

### Deadlock 2: CoreDNS sovrascritto da Talos

Talos v1.12 usa Server-Side Apply per gestire il ConfigMap di CoreDNS. Qualsiasi modifica manuale o inlineManifest viene sovrascritta al prossimo reconcile. Avevo aggiunto un forward per il dominio `ts.net` al ConfigMap, ma Talos lo cancellava regolarmente.

**Soluzione**: ho impostato `cluster.coreDNS.disabled: true` nella configurazione Talos e ho deployato un CoreDNS user-managed completo (ServiceAccount, ClusterRole, ConfigMap, Deployment, Service con ClusterIP 10.96.0.10) direttamente dall'engine layer Terraform.

### Deadlock 3: La CRD di ESO non era pronta

Terraform provava a creare il ClusterSecretStore `tazlab-secrets-vault` prima che External Secrets Operator avesse finito di installarsi e registrare le CRD. L'errore era "resource isn't valid for cluster, check the APIVersion and Kind fields".

**Soluzione**: `depends_on = [helm_release.external_secrets]`. Un fix banale, ma che ha richiesto tre tentativi per essere individuato.

### Deadlock 4: Il GitHub token non arrivava

Inizialmente l'engine layer creava un ExternalSecret per il GitHub token (necessario a Flux per clonare il repository), con secretStoreRef che puntava a Infisical. Ma Infisical era irraggiungibile (timeout DNS). Ho provato a puntare a Vault, ma Vault era irraggiungibile (stesso problema del Deadlock 1).

**Soluzione**: stesso pattern del Deadlock 1 — creare il GitHub token come `kubernetes_secret_v1` diretto da file locale, senza ESO. Vault e Flux se ne occuperanno in seguito.

### Deadlock 5: CoreDNS non partiva

Con mia grande frustrazione, un errore di sintassi nel Corefile impediva a CoreDNS di avviarsi. Avevo scritto:

```
health { lameduck 5s }
```

Su una riga sola. Questa sintassi non è supportata da CoreDNS. Il processo crashava in loop, il Deployment restava in "Still creating..." per 5 minuti, e Terraform faceva timeout.

**Soluzione**: la versione multiline è quella corretta:

```
health {
    lameduck 5s
}
```

### Deadlock 6: Il file esisteva ma non veniva deployato

Il file `secrets.yaml` che contiene l'ExternalSecret per le credenziali PostgreSQL di Grafana esisteva nella directory della kustomization `infrastructure-monitoring`, ma non era elencato nella sezione `resources:`. Quindi Flux non lo deployava. Grafana restava in `CreateContainerConfigError` senza motivo apparente.

**Soluzione**: un `secrets.yaml` nell'elenco dei resources della kustomization.

## Fase 3: Il Nameserver Che Non Rispondeva

Superati i deadlock di bootstrap, il cluster era finalmente su e tutti i 16 Kustomizations di Flux erano Ready. Ma il ClusterSecretStore di Vault restava in `ValidationFailed`. Il messaggio di errore diceva "no such host" per `lushycorp-vault.magellanic-gondola.ts.net`.

Il CoreDNS inoltrava le richieste per il dominio `ts.net` al nameserver di Tailscale (deployato dal DNSConfig CRD), ma il nameserver rispondeva NXDOMAIN per tutti i nomi, anche quelli che sapeva di dover risolvere.

### La Diagnosi

I log del nameserver erano illuminanti:

```
2026/05/28 20:21:39 ConfigMap update received
2026/05/28 20:21:39 configuration update detected, resetting records
2026/05/28 20:21:39 nameserver's configuration is empty, any in-memory records will be unset
2026/05/28 20:21:39 nameserver records were reset
```

Il ConfigMap `dnsrecords` conteneva i record corretti:

```json
{"version":"v1alpha1","ip4":{"lushycorp-vault.magellanic-gondola.ts.net":["10.244.1.31"]}}
```

Ma il nameserver diceva "configuration is empty". Due problemi distinti:

1. **Path del file**: Il ConfigMap veniva montato a `/config/records.json`, ma il binary del nameserver cercava `/config/dnsrecords`. Il watcher di directory vedeva il cambiamento ("ConfigMap update received"), ma quando il binary provava a leggere il suo path atteso, trovava un file inesistente e restituiva configurazione vuota.

2. **Schema JSON**: L'operatore Tailscale v1.96.5 scrive il formato `v1alpha1` con chiave `"ip4"`. L'immagine `k8s-nameserver:unstable` (bleeding-edge) è stata refattorizzata per supportare IPv6 e si aspetta una chiave diversa (es. `"records"` o `"endpoints"`). Go `json.Unmarshal` ignora silenziosamente le chiavi sconosciute, quindi il parsing "funziona" ma produce una configurazione vuota.

### La Soluzione

Piuttosto che inseguire il bug nel nameserver, ho cambiato strategia: invece di inoltrare le richieste `ts.net` al nameserver, ho configurato CoreDNS per riscrivere i nomi MagicDNS direttamente nei corrispondenti ClusterIP dei proxy egress di Tailscale.

Il blocco CoreDNS originale:
```
ts.net:53 {
    forward . 10.96.0.101
}
```

È diventato:
```
magellanic-gondola.ts.net:53 {
    rewrite name regex ([a-zA-Z0-9-]+)\.magellanic-gondola\.ts\.net {1}.tailscale.svc.cluster.local
    forward . 10.96.0.10
}
```

Questa regola di rewrite trasforma `lushycorp-vault.magellanic-gondola.ts.net` in `lushycorp-vault.tailscale.svc.cluster.local`, che CoreDNS risolve nativamente attraverso il plugin kubernetes. Niente nameserver, niente ConfigMap, niente version-skew.

## Fase 4: JWT Auth su Vault

Con il DNS funzionante e il ClusterSecretStore Valid, ho potuto configurare l'autenticazione JWT su Vault. Ma qui è emerso un altro problema: l'URL del JWKS endpoint.

```bash
vault write auth/jwt/config \
    jwks_url="https://lushycorp-k8s.magellanic-gondola.ts.net:6443/openid/v1/jwks" \
    bound_issuer="https://lushycorp-k8s.magellanic-gondola.ts.net:6443"
```

Vault cercava di validare l'URL contattando il JWKS endpoint, ma la connessione falliva. Il motivo? Ogni ciclo destroy+create del cluster produce un nuovo device su Tailscale con un suffisso `-N` (lushycorp-k8s-1, -2, -3...), ma il nome MagicDNS canonico (`lushycorp-k8s.magellanic-gondola.ts.net`) continuava a puntare al device più vecchio, ormai offline.

### Workaround: Chiave Statica

Ho estratto la chiave pubblica RSA dall'endpoint JWKS usando `kubectl get --raw /openid/v1/jwks`, convertita in formato PEM, e configurata direttamente su Vault. Ma perché il JWKS endpoint non era raggiungibile?

La causa erano i **device fantasma su Tailscale**. Ogni ciclo destroy+create del cluster produce un nuovo device Proxy sulla tailnet con un suffisso `-N` (lushycorp-k8s-1, -2, -3...). Il nome MagicDNS canonico (`lushycorp-k8s.magellanic-gondola.ts.net`) continuava a puntare al device più vecchio, ormai offline.

Questo è stato un problema che non avevamo preventivato. Le auth key di Tailscale usate per l'operatore locale avevano già il flag `"ephemeral": true`, che pulisce automaticamente i device quando si disconnettono. Ma i proxy Pod creati dal **Tailscale Operator** usano un OAuth client separato (`k8s_operator`), e i device generati dall'OAuth client **non sono ephemeral**. Quando il cluster viene distrutto, i proxy Pod scompaiono ma i device restano registrati sulla tailnet come "offline". Al ricreare, l'operatore crea nuovi device con suffisso `-N` perché il nome canonico è già occupato.

```bash
100.79.55.31    lushycorp-k8s     tagged-devices   linux   offline  # ciclo 1
100.108.49.94   lushycorp-k8s-2   tagged-devices   linux   offline  # ciclo 2
100.113.43.5    lushycorp-k8s-5   tagged-devices   linux   active   # ciclo attuale
```

La soluzione è stata aggiungere un passo di cleanup nel `destroy.sh` che chiama l'API Tailscale per rimuovere i device con tag `tag:k8s` prima di distruggere le VM. Ma nel frattempo ho dovuto usare un workaround.

```bash
vault write auth/jwt/config \
    jwt_validation_pubkeys=@/tmp/jwks.pem \
    bound_issuer="https://lushycorp-k8s.magellanic-gondola.ts.net:6443"
```

Ho poi creato il ruolo per il ServiceAccount di Grafana:

```bash
vault write auth/jwt/role/grafana-consumer \
    role_type="jwt" \
    bound_audiences="https://lushycorp-vault.magellanic-gondola.ts.net:8200" \
    bound_subject="system:serviceaccount:monitoring:grafana-sa" \
    user_claim="sub" \
    token_ttl="24h"
```

La soluzione con chiave statica non è ideale — quando l'API server ruoterà le sue chiavi di firma, questa configurazione diventerà obsoleta. Ma è sufficiente per procedere con le fasi successive, in attesa di risolvere il problema dei device fantasma su Tailscale.

## Conclusioni e Lezioni Apprese

Alla fine della giornata, il cluster era funzionante: 16/16 Kustomizations Flux Ready, 17/17 ExternalSecrets SecretSynced, Vault Store Valid, JWT auth configurato. Ma il percorso per arrivarci ha insegnato molto più di quanto avessi previsto.

### Lezioni generalizzabili

1. **Su Talos, `machine.certSANs` e `cluster.apiServer.certSANs` sono due mondi diversi**: modificarli su cluster running può causare un deadlock irreversibile. Le patch per l'API server vanno applicate al bootstrap, non dopo.

2. **I deadlock di bootstrap si nascondono nei dettagli**: ogni componente che dipende da un altro che dipende dal primo crea un uovo-gallina. La soluzione è rompere il cerchio con segreti bootstrap creati direttamente da file locali, bypassando la catena ESO/Vault/DNS.

3. **`k8s-nameserver:unstable` è rotto per la versione stabile dell'operatore**: il version-skew tra l'immagine bleeding-edge e l'operatore v1.96.5 produce un fallimento silenzioso. La soluzione CoreDNS rewrite è più elegante e rimuove una dipendenza.

4. **Il version-skew è il problema più insidioso**: a differenza di un errore di sintassi o di una configurazione sbagliata, un mismatch di versione produce fallimenti silenziosi. Il JSON si parsifica senza errori ma i dati vengono scartati. Il ConfigMap è presente ma il contenuto è ignorato. I log dicono che tutto è ok ma la risposta è NXDOMAIN.

### Prossimi passi

Con l'autenticazione JWT funzionante, la strada verso i segreti dinamici è spianata. I prossimi passi saranno:

- Configurare il database engine di Vault per PostgreSQL (credenziali dinamiche al posto del sync PGO)
- Deployare il Vault Agent Injector come mutating admission webhook
- Migrare Grafana a credenziali dinamiche iniettate via sidecar
- Eliminare il `sync_runtime_secrets` e il secrets.yaml dalla kustomization monitoring

Ma questa è un'altra storia.
