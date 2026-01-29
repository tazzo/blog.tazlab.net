---
title: "Le Mura del Castello: Implementazione di Sicurezza Zero-Trust e Gestione dei Segreti"
date: 2026-01-29T10:00:00+01:00
draft: false
tags: ["kubernetes", "security", "infisical", "terraform", "talos", "gitops", "devops", "external-secrets"]
categories: ["Infrastructure", "Security"]
author: "Taz"
description: "Cronaca tecnica del consolidamento del Castello Effimero: dall'integrazione di Infisical tramite TazPod alla cifratura nativa di etcd e l'adozione di External Secrets Operator."
---

# Le Mura del Castello: Ingegnerizzare la Sicurezza Zero-Trust nell'Infrastruttura Ephemerale

Costruire un'infrastruttura immutabile è un esercizio di disciplina, ma renderla sicura senza sacrificare la portabilità è una sfida di architettura. Dopo aver gettato le basi del **Castello Effimero** su Proxmox e aver stabilito il ciclo di riconciliazione con Flux, mi sono reso conto che le fondamenta erano solide ma le mura erano ancora vulnerabili. I segreti risiedevano in file YAML cifrati con SOPS all'interno del repository Git: una soluzione funzionale, ma che introduceva un attrito operativo non trascurabile e un accoppiamento troppo stretto con le chiavi di cifratura locali.

In questa cronaca tecnica, documento il passaggio a un modello di sicurezza di livello produttivo, dove la fiducia non è mai presunta (Zero-Trust) e i segreti fluiscono come entità dinamiche, mai persistite su disco in chiaro.

---

## La Scintilla: Il Punto Zero della Fiducia con TazPod

Ogni fortezza ha bisogno di una chiave, ma dove risiede questa chiave quando il cavaliere è nomade? La mia risposta è **TazPod**. Prima di poter lanciare un solo comando Terraform, devo stabilire un canale sicuro verso la mia fonte di verità: **Infisical**.

Ho deciso di utilizzare il TazPod non solo come ambiente di sviluppo, ma come vero e proprio "ancoraggio di identità". Attraverso il comando `tazpod pull`, attivo il "Ghost Mount". In questo stato, il TazPod crea un namespace Linux isolato e monta un'area di memoria criptata dove scarica i token di sessione di Infisical. Questo passaggio è cruciale: i token che permettono a Terraform di leggere le chiavi del cluster non toccano mai il disco del computer ospite in chiaro.

Perché Infisical? La scelta è ricaduta su Infisical (istanza EU per conformità e latenza) per superare i limiti di SOPS. SOPS richiede che ogni collaboratore (o ogni istanza CI/CD) possieda la chiave privata Age o l'accesso a un KMS. Con Infisical, ho centralizzato la gestione dei segreti in una piattaforma che offre audit log, rotazione e, soprattutto, un'integrazione nativa con Kubernetes tramite Machine Identities.

Una volta sbloccato il TazPod, ho popolato il file `secrets.tfvars` con il `client_id` e il `client_secret` della Machine Identity. Questo file è la "testa di ponte": è l'unica informazione sensibile necessaria per avviare la danza dell'automazione, ed è rigorosamente escluso dal controllo di versione tramite `.gitignore`.

---

## Fase 1: Hardening del Cuore - Talos Secretbox ed etcd Encryption

Kubernetes, per sua natura, memorizza tutte le risorse, inclusi i `Secret`, all'interno di **etcd**. Se un attaccante dovesse ottenere l'accesso ai file di dati di etcd sul disco del Control Plane, potrebbe estrarre ogni chiave, certificato o password del cluster. In una configurazione standard, questi dati sono memorizzati in chiaro.

### Il Ragionamento tecnico
Ho deciso di implementare la **Secretbox Encryption** di Talos. Talos permette di patchare la configurazione del nodo per includere una chiave di cifratura a 32 byte (AES-GCM) che viene utilizzata per criptare i dati prima che vengano scritti in etcd.

Perché non usare la cifratura nativa di Kubernetes (EncryptionConfiguration)? La risposta risiede nella semplicità operativa di Talos. Gestire l'EncryptionConfiguration manualmente richiede la creazione di file sul nodo e la gestione della rotazione tramite API server. Talos astrae questo processo nella sua configurazione dichiarativa, permettendomi di gestire la chiave come un qualsiasi altro parametro IaC.

### L'Investigazione: Il disastro della migrazione a caldo
Il piano iniziale prevedeva l'applicazione della patch su un cluster già esistente. Ho generato una chiave sicura con:
```bash
openssl rand -base64 32
```
L'ho caricata su Infisical e ho aggiornato il manifesto Terraform per iniettarla nel Control Plane. Tuttavia, al momento del `terraform apply`, il disastro: i Pod core del cluster hanno iniziato a fallire. Flux è andato in `CrashLoopBackOff`, il `helm-controller` non riusciva più a leggere i suoi token.

Controllando i log del `kube-apiserver` con `talosctl logs`, ho trovato l'errore fatale:
`"failed to decrypt data" err="output array was not large enough for encryption"`

L'API server era entrato in uno stato di confusione: cercava di decifrare segreti esistenti (scritti in chiaro) usando la nuova chiave della Secretbox, o peggio, aveva parzialmente cifrato alcuni dati rendendoli illeggibili. Il cluster era corrotto.

### La Via Ephemerale: Distruzione e Rinascita
Di fronte a un cluster Kubernetes compromesso, un amministratore tradizionale passerebbe ore a tentare di riparare etcd. Ma questo è il **Castello Effimero**. Ho deciso di onorare la filosofia del progetto: **non riparare, ricreare**.

Ho eseguito un reset aggressivo:
1. Ho rimosso manualmente le risorse "fantasma" dallo stato di Terraform (`terraform state rm`).
2. Ho distrutto le VM su Proxmox.
3. Ho rilanciato l'intero provisioning.

Il cluster è rinato in 5 minuti, ma questa volta con la Secretbox attiva fin dal primo secondo di vita. Ogni dato scritto in etcd dal processo di bootstrap è nato già cifrato. Questa è la vera potenza dell'immutabilità: la capacità di risolvere problemi complessi tornando a uno stato noto e pulito.

```hcl
# Patch snippet applied in main.tf
resource "talos_machine_configuration_apply" "cp_config" {
  client_configuration = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node = var.control_plane_ip
  config_patches = [
    yamlencode({
      machine = {
        # ... networking and installation ...
      }
      cluster = {
        secretboxEncryptionSecret = data.infisical_secrets.talos_secrets.secrets["TALOS_SECRETBOX_KEY"].value
      }
    })
  ]
}
```

---

## Fase 2: L'Ambasciatore Dinamico - External Secrets Operator (ESO)

Con il database del cluster al sicuro, il passo successivo è stato eliminare la necessità di memorizzare segreti applicativi nel repository Git. SOPS è un ottimo strumento, ma introduce un problema: la rotazione dei segreti richiede un nuovo commit e un nuovo push.

### Perché External Secrets Operator?
Ho scelto di installare **External Secrets Operator (ESO)** come pilastro fondamentale del Castello. ESO non memorizza i segreti; agisce come un ponte tra Kubernetes e un fornitore esterno (Infisical). 

Il vantaggio è radicale: in Git scrivo un oggetto `ExternalSecret` che descrive *quale* segreto voglio e *dove* deve finire in Kubernetes. ESO si occupa di contattare Infisical via API, recuperare il valore e creare un `Secret` nativo di Kubernetes solo nella memoria RAM del cluster. Se cambio un valore su Infisical, ESO lo aggiorna nel cluster in tempo reale, senza alcun intervento su Git.

### La Sfida dell'Autenticazione: Universal Auth
Per far parlare ESO con Infisical in modo sicuro, ho evitato l'uso di semplici token statici. Ho implementato il metodo **Universal Auth** (Machine Identity).

Il processo mentale è stato questo: Terraform crea un segreto Kubernetes iniziale contenente il `clientId` e il `clientSecret` della Machine Identity. Poi, configura un `ClusterSecretStore`, una risorsa che istruisce ESO su come autenticarsi a livello di intero cluster.

Durante l'installazione, mi sono scontrato con lo schema rigido della versione `0.10.3` di ESO. Un errore di configurazione nel `ClusterSecretStore` ha bloccato la sincronizzazione con un laconico `InvalidProviderConfig`. Analizzando il CRD con:
```bash
kubectl get crd clustersecretstores.external-secrets.io -o yaml
```
Ho scoperto che i campi erano cambiati rispetto alle versioni precedenti. La sezione `universalAuth` era diventata `universalAuthCredentials` e richiedeva riferimenti espliciti a chiavi di segreti Kubernetes.

Ecco la configurazione finale e corretta che ho integrato direttamente nel provisioning Terraform:

```hcl
resource "kubectl_manifest" "infisical_store" {
  yaml_body = <<-EOT
    apiVersion: external-secrets.io/v1beta1
    kind: ClusterSecretStore
    metadata:
      name: infisical-tazlab
    spec:
      provider:
        infisical:
          hostAPI: https://eu.infisical.com
          secretsScope:
            environmentSlug: ${var.infisical_env_slug}
            projectSlug: ${var.infisical_project_slug}
          auth:
            universalAuthCredentials:
              clientId:
                name: ${kubernetes_secret.infisical_machine_identity.metadata[0].name}
                namespace: ${kubernetes_secret.infisical_machine_identity.metadata[0].namespace}
                key: clientId
              clientSecret:
                name: ${kubernetes_secret.infisical_machine_identity.metadata[0].name}
                namespace: ${kubernetes_secret.infisical_machine_identity.metadata[0].namespace}
                key: clientSecret
  EOT
  depends_on = [helm_release.external_secrets, kubernetes_secret.infisical_machine_identity]
}
```

---

## Fase 3: Modularizzazione e Pulizia - La Fabbrica di Castelli

L'ultimo atto di questa giornata di consolidamento è stato il refactoring del codice. Un'infrastruttura ephemerale deve essere replicabile. Se domani volessi creare un cluster "Green" identico al "Blue" ma isolato, non dovrei riscrivere il codice, ma solo cambiare i parametri.

### Il concetto di Zero-Hardcoding
Ho deciso di applicare rigorosamente il principio del **Zero-Hardcoding**. Ho rimosso ogni IP statico, ogni nome di cartella Infisical e ogni URL di repository dai file `main.tf` e `providers.tf`. Tutto è stato spostato in un sistema a tre livelli:

1.  **`variables.tf`**: Definisce lo schema. Quali dati servono? Di che tipo sono? Quali sono i default sicuri?
2.  **`terraform.tfvars`**: Definisce la topologia. Qui risiedono gli IP dei nodi, l'URL del repo GitOps e gli slug dei progetti Infisical. Questo file viene committato: descrive *cosa* è il castello, non come aprirlo.
3.  **`secrets.tfvars`**: L'unico file proibito. Contiene le credenziali della Machine Identity. Grazie alla modifica del `.gitignore`, questo file rimane solo sulla mia workstation protetta (o nel vault del TazPod).

```hcl
# Modularization example in providers.tf
provider "infisical" {
  host          = "https://eu.infisical.com"
  client_id     = var.infisical_client_id
  client_secret = var.infisical_client_secret
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  # Proxmox secrets are now dynamically retrieved from Infisical via data source
  api_token = "${data.infisical_secrets.talos_secrets.secrets["PROXMOX_TOKEN_ID"].value}=${data.infisical_secrets.talos_secrets.secrets["PROXMOX_TOKEN_SECRET"].value}"
}
```

### L'Addio definitivo a SOPS
Con questa mossa, ho potuto finalmente eliminare `proxmox-secrets.enc.yaml`. Non ci sono più file cifrati che appesantiscono il repository. La dipendenza dal provider SOPS in Terraform è stata rimossa. Il "Castello" è ora più leggero, più veloce da inizializzare e infinitamente più sicuro.

---

## Riflessioni post-lab: Cosa abbiamo imparato?

Questa fase di implementazione mi ha insegnato che la sicurezza in un ambiente moderno non è un perimetro, ma un **flusso**. 

Abbiamo tracciato un percorso che parte dalla mente dello sviluppatore (la passphrase del TazPod), attraversa un canale cifrato in RAM, si materializza temporaneamente in variabili Terraform per costruire l'infrastruttura, e infine si stabilizza in un operatore Kubernetes (ESO) che mantiene il segreto fluido e aggiornabile.

### Risultati ottenuti:
*   **etcd blindato**: Anche con un accesso fisico ai dischi di Proxmox, i dati del cluster sono illeggibili senza la chiave Secretbox.
*   **Git pulito**: Il repository contiene solo logica, nessuna chiave, nemmeno cifrata.
*   **Replicabilità totale**: Posso duplicare la cartella del provider, cambiare tre righe nel `.tfvars` e avere un nuovo cluster pronto alla produzione in meno di 10 minuti.

Il Castello ora ha le sue mura. È pronto ad accogliere i servizi che lo renderanno vivo, sapendo che ogni "tesoro" depositato al suo interno sarà protetto da una crittografia moderna e da un'architettura che non dimentica mai la sua natura ephemerale.

---
*Fine della Cronaca Tecnica - Fase 2: Sicurezza e Segreti*
