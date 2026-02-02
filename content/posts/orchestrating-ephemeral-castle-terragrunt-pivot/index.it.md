---
title: "L'Orchestra del Castello: Il Pivot verso Terragrunt e la Guerra alle Race Condition"
date: 2026-02-01T06:00:00+01:00
draft: false
tags: ["kubernetes", "terragrunt", "terraform", "fluxcd", "devops", "proxmox", "automation", "gitops"]
categories: ["Infrastructure", "Design Patterns"]
author: "Taz"
description: "Cronaca tecnica di una trasformazione radicale: dal monolite Terraform all'orchestrazione a layer con Terragrunt per eliminare le race condition e garantire un bootstrap deterministico in 8 minuti."
---

# L'Orchestra del Castello: Il Pivot verso Terragrunt e la Guerra alle Race Condition

Il sogno di ogni ingegnere DevOps che lavora con infrastrutture ephemere è il **Determinismo Totale**. L'idea che, premendo un singolo tasto, un'intera cattedrale digitale possa sorgere dal nulla, configurarsi e servire traffico in pochi minuti, per poi svanire senza lasciare traccia, è ciò che spinge il progetto del **Castello Effimero**. Tuttavia, come spesso accade nel passaggio dal laboratorio alla produzione, la realtà ha presentato un conto salato sotto forma di instabilità, conflitti temporali e stalli infiniti.

In questa nuova tappa del mio diario tecnico, documento il pivot architetturale più significativo dall'inizio del progetto: l'abbandono del monolite Terraform in favore di un'orchestrazione a layer gestita da **Terragrunt**. Non si è trattato di un semplice cambio di tool, ma di un cambiamento filosofico necessario per sconfiggere le **Race Condition** che stavano rendendo il bootstrap del cluster una scommessa invece che una certezza.

---

## Il Punto di Rottura: La Tirannia dei Webhook

Fino a pochi giorni fa, il Castello nasceva da un unico, gigantesco `main.tf`. Terraform si occupava di tutto: creava le VM su Proxmox, configurava Talos OS, installava MetalLB, Longhorn, Cert-Manager e infine Flux. Sulla carta, il grafo delle dipendenze di Terraform avrebbe dovuto gestire l'ordine di esecuzione. Nella pratica, mi sono scontrato con la natura asincrona di Kubernetes.

### L'Analisi dello Struggle: Webhook in Timeout
Il problema si manifestava sistematicamente durante l'installazione di **MetalLB** o **Cert-Manager**. Kubernetes utilizza gli **Admission Webhooks** per convalidare le risorse. Quando Terraform inviava il manifesto di un `IPAddressPool` (per MetalLB) o di un `ClusterIssuer` (per Cert-Manager), il controller relativo era ancora in fase di inizializzazione.

Il risultato era un errore frustrante:
`failed calling webhook "l2advertisementvalidationwebhook.metallb.io": connect: connection refused`

Nonostante il Pod del controller risultasse `Running`, il servizio del webhook non era ancora pronto a rispondere. Terraform, vedendo il fallimento, andava in errore e interrompeva l'intera catena di provisioning. Ho provato a inserire dei "wait" artificiali, ma erano fragili: troppo brevi e il sistema falliva, troppo lunghi e perdevo il vantaggio della velocità. Il monolite stava diventando ingestibile perché cercava di gestire troppi stati diversi (infrastruttura, rete, storage, logica applicativa) in un unico ciclo di vita.

---

## Il Pivot Filosofico: Infrastruttura di Base vs GitOps

Un altro errore tattico che ho dovuto riconoscere è stata la delega eccessiva a **Flux**. Nel post precedente, avevo celebrato l'idea di spostare Longhorn e MetalLB sotto la gestione di Flux per rendere Terraform "più leggero". 

### Il Ragionamento: Perché sono tornato indietro
Ho capito che MetalLB e Longhorn non sono "applicazioni", ma **estensioni del Kernel del cluster**. Senza MetalLB, l'Ingress non riceve un IP. Senza Longhorn, le app che richiedono persistenza (come il blog o database) non possono partire. 

Se delego questi componenti a Flux, creo un loop di dipendenze pericoloso: Flux ha bisogno di segreti per autenticarsi, ma ESO (External Secrets Operator) ha bisogno di un cluster sano per girare. Se Flux fallisce per un motivo qualsiasi, perdo la visibilità sui componenti vitali del cluster. Ho deciso quindi che tutto ciò che è necessario affinché il cluster sia considerato "funzionante e capace" deve nascere tramite **IaC (Infrastructure as Code)**, mentre Flux deve occuparsi solo di ciò che il cluster "ospita".

---

## L'Arrivo di Terragrunt: Il Direttore d'Orchestra

Per risolvere questi problemi, ho introdotto **Terragrunt**. Terragrunt agisce come un wrapper per Terraform, permettendo di dividere l'infrastruttura in moduli indipendenti ma collegati da un grafo di dipendenze esplicito.

### Deep-Dive: State Isolation e Dependency Graph
L'uso di Terragrunt ha introdotto due concetti chiave che hanno cambiato tutto:
1.  **Isolamento dello Stato**: Ogni layer (rete, storage, engine) ha il suo file `.tfstate`. Se rompo la configurazione di Flux, lo stato delle mie VM su Proxmox rimane intatto. Non rischio più di distruggere l'intero cluster per un errore di sintassi in un manifesto Kubernetes.
2.  **Grafo delle Dipendenze**: Posso dire a Terragrunt: "Non provare nemmeno a installare MetalLB finché il layer Platform (le VM) non è completamente online e l'API di Kubernetes non risponde".

---

## L'Anatomia del Castello a 6 Layer

Ho riorganizzato l'intero repository `ephemeral-castle` in una struttura a strati, dove ogni strato costruisce sulle fondamenta del precedente.

### Layer 1: Secrets (G1)
Questo strato interagisce solo con **Infisical EU**. Recupera i token necessari per Proxmox, le chiavi SSH e le credenziali S3. È il "punto zero" della fiducia.

### Layer 2: Platform (G2)
Qui avviene il provisioning pesante. Vengono create le macchine virtuali su Proxmox e viene iniettata la configurazione di **Talos OS**.
*   **Deep-Dive: Quorum e VIP**: In questa fase, Terraform attende che i 3 nodi di Control Plane abbiano formato il quorum di etcd. Il **Virtual IP (VIP)** deve essere stabile prima di passare al layer successivo. Se il VIP non risponde, il bootstrap si ferma qui.

### Layer 3: Engine (G3)
Una volta che il "ferro" è pronto, installiamo il motore di identità: **External Secrets Operator (ESO)**. Senza ESO, il cluster non può parlare con Infisical per recuperare i segreti applicativi. È il ponte tra il mondo esterno e il mondo Kubernetes.

### Layer 4: Networking (G4)
Installazione di **MetalLB**. Qui abbiamo implementato la soluzione definitiva alla race condition del webhook. Lo script di orchestrazione interroga Kubernetes finché l'**EndpointSlice** del webhook non è `Ready`. Solo allora la configurazione del pool di IP viene iniettata.

### Layer 5 & 6: Storage e GitOps (G5 - In Parallelo)
Qui è avvenuta l'ottimizzazione che ho chiamato **"Parallel Blitz"**. Mi sono reso conto che **Longhorn** (Storage) e **Flux** (GitOps) possono nascere contemporaneamente. Flux può iniziare a scaricare le immagini e preparare i deployment mentre Longhorn sta ancora inizializzando i dischi sui nodi.

---

## La Guerra allo Stato: "VM Already Exists" e il Backend Persistente

Un problema ricorrente durante i test era la corruzione dello stato locale. Se cancellavo accidentalmente la cartella `.terraform` o se lo stato non veniva salvato dopo un crash, al tentativo successivo ricevevo l'errore:
`400 Parameter verification failed: vmid: VM 421 already exists on node proxmox`

### L'Investigazione: Il fantasma nel sistema
Terraform è un sistema "state-aware". Se perde il file di stato, pensa che il mondo sia vuoto. Ma Proxmox ha una memoria fisica. Per risolvere questo stallo, ho implementato due strategie:
1.  **Backend Persistente Fuori-Albero**: Ho spostato tutti i file di stato in una directory dedicata `/home/taz/kubernetes/ephemeral-castle/states/`, esterna al repository Git. Questo garantisce che lo stato sopravviva anche a un `git clean` aggressivo o a un cambio di branch.
2.  **Nuclear Wipe**: Ho creato uno script `nuclear-wipe.sh` che, in caso di emergenza, usa l'API di Proxmox per cancellare forzatamente le VM tra gli ID 421 e 432, permettendo a Terraform di ripartire da una tabula rasa reale.

---

## Implementazione Tecnica: Il Cuore di Terragrunt

Ecco come appare il file di configurazione radice che orchestra l'intera danza. Notate come vengono generati i provider per tutti i layer sottostanti, garantendo la coerenza totale.

```hcl
# live/terragrunt.hcl
remote_state {
  backend = "local"
  config = {
    path = "${get_parent_terragrunt_dir()}/../../states/${path_relative_to_include()}/terraform.tfstate"
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "proxmox" {
  endpoint = var.pm_api_url
  api_token = var.pm_api_token
  insecure = true
}

provider "kubernetes" {
  config_path = "${get_parent_terragrunt_dir()}/../../clusters/tazlab-k8s-proxmox/proxmox/configs/kubeconfig"
}

provider "helm" {
  kubernetes {
    config_path = "${get_parent_terragrunt_dir()}/../../clusters/tazlab-k8s-proxmox/proxmox/configs/kubeconfig"
  }
}
EOF
}
```

E un esempio di come un layer (es. `networking`) dichiara la sua dipendenza dal layer precedente:

```hcl
# live/tazlab-k8s-proxmox/stage4-networking/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "engine" {
  config_path = "../stage3-engine"
}

inputs = {
  # Input passati dal layer precedente se necessario
}
```

---

## Ottimizzazione: Il "Parallel Blitz" e il Record degli 8 Minuti

Dopo aver stabilizzato l'ordine, la sfida è diventata la velocità. Inizialmente, il bootstrap impiegava circa 14 minuti. Analizzando i log, ho visto che Flux restava in attesa di Longhorn anche se non era strettamente necessario per la sua installazione di base.

### La Soluzione: Orchestrazione Intelligente
Nello script `create.sh`, ho separato l'applicazione dei layer. Mentre i layer 1, 2, 3 e 4 devono essere sequenziali (Segreti -> VM -> Engine -> Rete), il layer 5 e 6 vengono lanciati quasi simultaneamente.

```bash
# create.sh snippet - Enterprise V4
echo "🚀 STAGE 5 & 6: Launching Storage and GitOps in Parallel..."
terragrunt run-all apply --terragrunt-non-interactive --terragrunt-parallelism 2
```

Questo cambiamento ha ridotto il tempo totale di bootstrap a **8 minuti e 20 secondi**. In questo arco di tempo, il sistema passa dal nulla cosmico a un cluster HA con 5 nodi, storage distribuito, networking Layer 2 e Flux che ha già riconciliato l'ultima versione di questo blog.

---

## Riflessioni post-lab: Verso l'Agnosticismo Cloud

Il passaggio a Terragrunt ha trasformato il Castello Effimero in una vera **Fabbrica di Infrastruttura**. 

### Cosa significa questo setup per il futuro?
1.  **Agnosticismo della Piattaforma**: Ora posso creare una cartella `live/tazlab-k8s-aws/`, cambiare solo il layer `stage2-platform` (usando moduli AWS invece di Proxmox) e mantenere identici tutti gli altri layer. Il networking darà un LoadBalancer AWS invece di MetalLB, ma Flux e le app non se ne accorgeranno nemmeno.
2.  **Affidabilità Industriale**: Abbiamo eliminato il "forse funziona". Se un layer fallisce, Terragrunt si ferma esattamente lì, permettendoci di ispezionare lo stato specifico senza dover rincorrere fantasmi in un file di stato da 5000 righe.
3.  **Velocità come Sicurezza**: Un'infrastruttura che nasce in 8 minuti permette di non aver paura di distruggere tutto. Se sospettiamo una compromissione o un errore di configurazione, la risposta è sempre: `destroy && create`. 

Il Castello è ora solido, modulare e pronto a scalare oltre i confini del mio laboratorio domestico. L'orchestra è pronta, e la musica del codice non è mai stata così armoniosa.

---
*Fine della Cronaca Tecnica - La Rivoluzione Terragrunt*
