+++
title = "Dall’Artigianato all’Infrastruttura: Cronaca dell’Introduzione di Terraform in Tazlab"
date = 2026-01-24T01:29:21+01:00
draft = false
description = "Cronaca dell'introduzione di Terraform in Tazlab per la gestione del cluster Talos su Proxmox."
tags = ["terraform", "proxmox", "iac", "kubernetes", "talos"]
author = "Tazzo"
+++


## Introduzione: Il Salto di Specie dell'Homelab
Gestire un cluster Kubernetes in un laboratorio domestico è spesso un atto d'amore, una miscela di YAML scritti a mano e piccoli aggiustamenti manuali via GUI. Tuttavia, arriva un momento in cui la complessità supera la capacità di memoria del suo amministratore. In **Tazlab**, quel momento è arrivato oggi. L'obiettivo era chiaro: cessare di trattare i nodi del cluster come "animali domestici" (pets) — ognuno con il suo nome e la sua storia — e iniziare a trattarli come "bestiame" (cattle) — risorse fungibili, identiche e riproducibili.

Ho deciso di introdurre **Terraform** per gestire il ciclo di vita del cluster **Talos Linux** ospitato su **Proxmox**. Questa non è stata una passeggiata trionfale, ma una cronaca onesta di errori di permessi, conflitti hardware virtuali e problemi di decodifica crittografica. Ecco come ho trasformato Tazlab in una vera infrastruttura definita dal codice.

---

## Fase 1: La Scelta degli Strumenti e l'Architettura Silenziosa

Prima di scrivere una singola riga di codice HCL (HashiCorp Configuration Language), ho dovuto affrontare la scelta dei **Provider**. Nel mondo Proxmox, esistono due correnti principali: il provider legacy di Telmate e il moderno provider di **bpg**. 

Ho deciso di optare per **bpg/proxmox**. La ragione risiede nella sua capacità di gestire gli oggetti Proxmox con una granularità superiore, specialmente per quanto riguarda gli snippet e la configurazione SDN. Telmate, pur essendo storico, soffre di instabilità croniche nel rilevamento del drift (configuration drift) sulle interfacce di rete nelle versioni di Proxmox 8.x. In un'architettura IaC (Infrastructure as Code) professionale, il rilevamento del drift deve essere preciso: Terraform non deve proporre modifiche se nulla è cambiato nella realtà.

### L'importanza del Quorum etcd
Un'altra decisione critica ha riguardato il **Control Plane**. Inizialmente ho ipotizzato la creazione di nodi control plane aggiuntivi, ma ho dovuto riflettere sul concetto di **Quorum**. In un sistema distribuito basato su etcd come Kubernetes, il quorum richiede una maggioranza assoluta ($n/2 + 1$). Passare da uno a due nodi control plane ridurrebbe paradossalmente l'affidabilità: se uno dei due cadesse, il cluster rimarrebbe bloccato. Ho quindi deciso di mantenere un singolo nodo control plane per ora, concentrando l'automazione sulla scalabilità orizzontale dei nodi worker.

---

## Fase 2: Il Setup dei Permessi - La Prima Barriera

L'automazione richiede un'identità. Non si può (e non si deve) usare l'utente `root@pam` per Terraform. Ho dovuto creare un utente dedicato e un ruolo con i privilegi minimi necessari. Questo passaggio ha rivelato una delle prime insidie: la documentazione ufficiale spesso omette permessi granulari che diventano critici durante l'esecuzione.

Ho dovuto modificare il ruolo `TerraformAdmin` su Proxmox più volte. L'errore più subdolo è stato legato al **QEMU Guest Agent**. Senza il permesso `VM.GuestAgent.Audit`, Terraform non riusciva a interrogare Proxmox per conoscere l'indirizzo IP assegnato dal DHCP, entrando in un loop di attesa infinito.

### Codice di Setup Proxmox (Shell):
```bash
# Creazione del ruolo professionale con permessi granulari
pveum role add TerraformAdmin -privs "Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Pool.Audit Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt SDN.Use VM.GuestAgent.Audit VM.GuestAgent.Unrestricted"

# Creazione utente e generazione token
pveum user add terraform-user@pve
pveum aclmod / -user terraform-user@pve -role TerraformAdmin
pveum user token add terraform-user@pve terraform-token --privsep=0
```

---

## Fase 3: Scaffolding e il "Debito" dei Segreti

Ho strutturato il progetto Terraform in modo modulare per separare le responsabilità: `versions.tf` per i plugin, `variables.tf` per lo schema dati, `data.tf` per la lettura dei segreti e `main.tf` per la logica di business.

### L'integrazione SOPS
Tazlab utilizza **SOPS** con crittografia **Age**. Questa è stata la sfida più interessante. Terraform deve decriptare i file YAML di Talos per estrarre la Certification Authority (CA) e i token di join. Ho incontrato un problema frustrante: i certificati salvati in SOPS erano codificati in **Base64** e contenevano spesso caratteri di newline (`\n`) invisibili che mandavano in crash la validazione di Talos.

Ho deciso di risolvere il problema "alla fonte" nel file `data.tf`, implementando una logica di pulizia aggressiva delle stringhe. Senza questa trasformazione, il nodo worker riceveva un certificato corrotto e rifiutava di unirsi al cluster, rimanendo in uno stato di "Maintenance Mode" perenne.

### `terraform/data.tf`:
```hcl
# Decriptazione dei segreti Proxmox e Talos tramite SOPS
data "sops_file" "proxmox_secrets" {
  source_file = "proxmox-secrets.enc.yaml"
}

data "sops_file" "controlplane_secrets" {
  source_file = "../talos/controlplane-reference.yaml"
}

data "sops_file" "worker_secrets" {
  source_file = "../talos/worker-reference.yaml"
}

locals {
  # Gestione multi-documento e pulizia Base64
  parts = split("---", data.sops_file.controlplane_secrets.raw)
  cp_raw = yamldecode(local.parts[0] == "" ? local.parts[1] : local.parts[0])

  cluster_secrets = {
    token  = trimspace(local.cp_raw.machine.token)
    # Rimoziome newline e decodifica PEM
    ca_crt_b64 = replace(replace(local.cp_raw.machine.ca.crt, "\n", ""), " ", "")
    ca_key_b64 = replace(replace(local.cp_raw.machine.ca.key, "\n", ""), " ", "")
    ca_crt     = base64decode(local.proxmox_token_id) # Logica di decode centralizzata
  }
}
```

---

## Fase 4: La Lotta contro l'Hardware Virtuale

Il provisioning di una VM Talos su Proxmox non segue le regole standard di Cloud-Init. Talos si aspetta che la configurazione venga "spinta" tramite le sue API sulla porta 50000. 

Ho riscontrato un conflitto hardware critico: Proxmox, di default, assegna il drive Cloud-Init all'interfaccia **`ide2`**. Tuttavia, io stavo usando l'interfaccia `ide2` anche per montare l'ISO di Talos. Questo conflitto silenzioso impediva a Talos di leggere la configurazione di rete statica, forzando la VM a richiedere un IP via DHCP (spesso fuori dal range desiderato) o, peggio, a non avere alcuna connettività.

Ho deciso di spostare l'ISO sull'interfaccia **`ide0`**, liberando la porta `ide2` per il bus di inizializzazione. Questa mossa, apparentemente banale, è stata la chiave per ottenere IP statici deterministici su un sistema immutabile.

### `terraform/main.tf` (Estratto):
```hcl
resource "proxmox_virtual_environment_vm" "worker_nodes" {
  for_each = var.worker_nodes
  name     = each.key
  node_name = var.proxmox_node

  # Allineamento hardware con i nodi fisici esistenti
  scsi_hardware = "virtio-scsi-single"
  
  agent {
    enabled = true # Cruciale per la visibilità dell'IP nella GUI
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk_size
    iothread     = true
  }

  # Disco dedicato a Longhorn: lo storage distribuito richiede dischi raw
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi1"
    size         = each.value.data_disk
    iothread     = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip_address}/24"
        gateway = var.gateway
      }
    }
  }

  cdrom {
    enabled   = true
    file_id   = "local:iso/nocloud-amd64.iso" # ISO Factory personalizzata
    interface = "ide0" # Risoluzione del conflitto IDE
  }
}
```

---

## Fase 5: Il "Debito Tecnico" e l'Image Factory

Durante la creazione del primo worker (`worker-new-01`), ho notato che i pod di **Longhorn** rimanevano in `CrashLoopBackOff`. L'analisi dei log con `kubectl logs` ha rivelato l'assenza del binario `iscsiadm` all'interno del sistema operativo.

Ho capito che Talos Linux, nella sua versione standard, è troppo minimale per Longhorn. I nodi esistenti del cluster stavano usando un'immagine generata tramite la **Talos Image Factory** che includeva l'estensione `iscsi-tools` e il `qemu-guest-agent`. 

Invece di distruggere il nodo, ho deciso di eseguire un **Upgrade In-Place** via API:
```bash
talosctl upgrade --image factory.talos.dev/installer/e187c9b90f773cd8c84e5a3265c5554ee787b2fe67b508d9f955e90e7ae8c96c:v1.12.0
```
Questo ha "saldato il debito" tecnico. Ho poi aggiornato immediatamente il codice Terraform per puntare a questa immagine factory per tutti i futuri nodi, garantendo l'omogeneità del cluster.

---

## Fase 6: Hugo e la Scalabilità Cloud-Native

Una volta stabilizzato il parco nodi, ho testato la scalabilità con l'applicazione del blog **Hugo**. Il blog usava un `PersistentVolumeClaim` (PVC) in modalità `ReadWriteOnce` (RWO). Scalando a 3 repliche, ho visto apparire il temuto **`Multi-Attach error`**. 

RWO permette il montaggio di un disco su un solo nodo alla volta. Kubernetes, cercando di distribuire i pod sui miei 3 nuovi worker per garantire l'alta affidabilità, si scontrava con il limite fisico del volume. 

Ho deciso di implementare un approccio **Shared-Nothing** usando una **`emptyDir`**. 
*   **Cos'è una `emptyDir`?** È un volume temporaneo che vive finché il pod è attivo, creato sul disco locale del nodo.
*   **Perché per Hugo?** Hugo è un generatore di siti statici. I suoi dati sorgente vengono scaricati da Git tramite un sidecar container (`git-sync`). Non serve un disco persistente centralizzato se ogni pod può scaricare la sua copia locale in pochi secondi.

Questa modifica ha permesso di scalare il blog a 3 repliche istantaneamente, ognuna residente su un worker diverso, senza alcun conflitto di storage.

---

## Fase 7: Messa in Sicurezza Finale con Terraform Cloud

L'ultimo atto è stato risolvere il problema del file `terraform.tfstate`. Come ho spiegato durante il processo, lo stato di Terraform contiene tutti i segreti decriptati in chiaro. Tenere questo file sul disco fisso è un rischio inaccettabile.

Ho deciso di migrare lo stato su **HCP Terraform (Terraform Cloud)**, ma con una configurazione specifica: **Local Execution Mode**.
In questa modalità, Terraform esegue i comandi sul mio PC (potendo così raggiungere l'IP locale di Proxmox e usare la mia chiave Age), ma invia lo stato cifrato nei server sicuri di HashiCorp. Ho rimosso ogni traccia locale di `.tfstate`, eliminando la possibilità di furto di credenziali dal file system.

### `terraform/versions.tf` (Configurazione Cloud):
```hcl
terraform {
  required_version = ">= 1.5.0"

  cloud {
    organization = "tazlab"
    workspaces {
      name = "tazlab-k8s"
    }
  }
  # ... provider ...
}
```

---

## Riflessioni Post-Lab: Cosa abbiamo imparato?

L'introduzione di Terraform in Tazlab non è stata solo l'aggiunta di uno strumento, ma un cambio di mentalità. Ho imparato che:
1.  **L'astrazione ha un costo**: Terraform semplifica la creazione, ma richiede una conoscenza profonda delle API sottostanti (Proxmox in questo caso).
2.  **I segreti sono vivi**: Gestire i segreti non significa solo nasconderli, ma saperli trasformare (Base64 vs PEM) per renderli digeribili dalle macchine.
3.  **L'architettura batte la persistenza**: Spesso cerchiamo di risolvere problemi di storage con volumi complessi, quando una semplice `emptyDir` e un buon processo di sincronizzazione sono più efficaci.

Oggi Tazlab ha 3 nuovi worker. Domani potrebbe averne 30. Mi basterà aggiungere una riga di testo. Questa è la vera libertà dell'Infrastructure as Code.

