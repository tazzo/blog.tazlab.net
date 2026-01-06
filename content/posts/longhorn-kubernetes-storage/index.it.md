+++
title = "Cronache del Lab: Costruire la Persistenza con Longhorn e Talos"
date = 2026-01-02T10:00:00Z
draft = false
description = "Una cronaca tecnica dell'implementazione dello storage distribuito Longhorn su nodi immutabili Talos Linux."
tags = ["kubernetes", "longhorn", "storage", "talos-linux", "homelab"]
categories = ["infrastruttura", "storage"]
author = "Tazzo"
+++

## Introduzione: Il Paradosso della Persistenza

Nel paradigma Cloud Native, trattiamo i carichi di lavoro come bestiame, non come animali domestici. I Pod sono effimeri, sacrificabili e stateless. Tuttavia, la realtà operativa impone un vincolo ineludibile: lo stato deve risiedere da qualche parte. Che si tratti di un database, di log di sistema o, come nel nostro caso specifico, di certificati SSL generati dinamicamente da un Ingress Controller, la necessità di *Block Storage* persistente e distribuito è il primo vero ostacolo che trasforma un cluster "giocattolo" in un'infrastruttura di produzione.

L'obiettivo di questa sessione non era banale: implementare **Longhorn**, il motore di storage distribuito di SUSE/Rancher, su un sistema operativo immutabile come **Talos Linux**. La sfida è duplice: Talos, per design, impedisce la modifica del filesystem di root e l'installazione di pacchetti a runtime. Questo rende l'installazione di driver di storage (come iSCSI) un'operazione che va pianificata a livello di architettura dell'immagine OS, non tramite semplici comandi `apt` o `yum`.

Questa cronaca documenta il processo di hardening dell'infrastruttura, il provisioning dello storage fisico su Proxmox, e una complessa sessione di troubleshooting legata ai permessi dei volumi persistenti durante l'integrazione con Traefik.

---

## Fase 1: L'Ostacolo dell'Immutabilità e le System Extensions

La prima barriera tecnica incontrata riguarda la natura stessa di Longhorn. Per funzionare, Longhorn crea un device a blocchi virtuale su ogni nodo, che viene poi montato dal Pod. Questa operazione si basa pesantemente sul protocollo **iSCSI** (Internet Small Computer Systems Interface).

In una distribuzione Linux tradizionale (Ubuntu, CentOS), l'installazione di Longhorn verificherebbe la presenza di `open-iscsi` e, in caso negativo, l'amministratore lo installerebbe. Su Talos Linux, questo è impossibile. Il filesystem è in sola lettura; non esiste un package manager.

### Analisi e Soluzione: Sidero Image Factory

Un controllo preliminare sul cluster ha rivelato la mancanza delle estensioni necessarie:

```bash
talosctl get extensions
# Output: Nessuna estensione critica installata
```

Senza `iscsi-tools` e `util-linux-tools`, i pod di Longhorn sarebbero rimasti indefinitamente nello stato `ContainerCreating`, incapaci di montare i volumi.

La soluzione architetturale adottata è stata l'uso della **Sidero Image Factory**. Invece di modificare il nodo esistente, abbiamo generato una nuova definizione di immagine OS (uno "schematic") che includesse nativamente i driver richiesti.

Le estensioni selezionate sono state:
1.  `siderolabs/iscsi-tools`: Il demone e le utility user-space per iSCSI.
2.  `siderolabs/util-linux-tools`: Utility di gestione filesystem essenziali per la formattazione automatica dei volumi.
3.  `siderolabs/qemu-guest-agent`: Per migliorare l'integrazione con l'hypervisor Proxmox.

L'aggiornamento è stato eseguito in modalità "rolling", un nodo alla volta, garantendo che il cluster rimanesse operativo (o quasi) durante la transizione.

```bash
# Esempio del comando di aggiornamento chirurgico
talosctl upgrade --image factory.talos.dev/installer/[ID_SCHEMA]:v1.12.0 --preserve=true
```

Questo passaggio sottolinea una lezione fondamentale del moderno DevOps: **l'infrastruttura si gestisce dichiarativamente**. Non si "patchano" i server; si sostituiscono le immagini che li governano.

---

## Fase 2: Provisioning dello Storage Fisico (Proxmox & Talos)

Una volta abilitato il software a "parlare" con lo storage, dovevamo fornire lo storage fisico. Sebbene sia possibile utilizzare il disco principale del sistema operativo per i dati, questa è una pratica sconsigliata (anti-pattern) per diversi motivi:
*   **Contesa di I/O:** I log di sistema o le operazioni di etcd non devono competere con le scritture del database.
*   **Ciclo di vita:** La reinstallazione del sistema operativo (es. un reset di Talos) potrebbe comportare la formattazione della partizione `/var`, cancellando i dati persistenti.

### La Strategia del Disco Dedicato

Abbiamo optato per l'aggiunta di un secondo disco virtuale (`virtio-scsi` o `virtio-blk`) su ogni VM Proxmox. Qui è emerso un rischio operativo critico: **l'identificazione del device**.

Su Linux, i nomi dei device (`/dev/sda`, `/dev/sdb`, `/dev/vda`) non sono garantiti essere persistenti o deterministici, specialmente in ambienti virtualizzati dove l'ordine di boot può variare. Applicare una configurazione Talos che formatta `/dev/sdb` quando `/dev/sdb` è in realtà il disco di sistema porterebbe alla catastrofe (data loss totale).

### Tecnica di Mitigazione: Identificazione tramite Dimensione

Per mitigare questo rischio, abbiamo adottato una tecnica di "flagging" hardware. Invece di creare dischi identici a quelli di sistema (34GB), abbiamo ridimensionato i nuovi dischi dati a **43GB**.

```bash
# Verifica pre-formattazione
NODE            DISK   SIZE     TYPE
192.168.1.127   sda    34 GB    QEMU HARDDISK (OS)
192.168.1.127   vda    43 GB    (Target Dati)
```

Solo dopo aver confermato inequivocabilmente che `/dev/vda` era il disco da 43GB su tutti i nodi, abbiamo applicato la `MachineConfig` di Talos per partizionare, formattare in XFS e montare il disco su `/var/mnt/longhorn`.

### Il "Trick" del Kubelet Mount

Un dettaglio tecnico spesso trascurato è la visibilità dei mount. Il Kubelet gira all'interno di un container isolato. Montare un disco sull'host in `/var/mnt/longhorn` non lo rende automaticamente visibile al Kubelet.

Abbiamo dovuto configurare esplicitamente `extraMounts` con propagazione `rshared`:

```yaml
kubelet:
  extraMounts:
    - destination: /var/lib/longhorn
      type: bind
      source: /var/mnt/longhorn
      options:
        - bind
        - rshared
        - rw
```

Senza `rshared`, Longhorn avrebbe tentato di montare i volumi, ma il Kubelet non sarebbe stato in grado di passarli ai Pod, risultando in errori di "MountPropagation".

---

## Fase 3: Installazione e Configurazione di Longhorn

L'installazione tramite Helm è stata relativamente indolore, grazie alla preparazione meticolosa. Tuttavia, la configurazione di Longhorn in un ambiente a due nodi (un Control Plane e un Worker) richiede compromessi specifici.

### Configurazione della Replica

Di default, Longhorn cerca di mantenere 3 repliche dei dati su nodi diversi per garantire l'alta affidabilità (HA). In un cluster a 2 nodi, questo requisito è impossibile da soddisfare (Hard Anti-Affinity).

Abbiamo dovuto ridurre il `numberOfReplicas` a **2**. Questo configura una situazione di "tolleranza al guasto minima": se un nodo cade, i dati sono ancora accessibili sull'altro, ma la ridondanza è persa fino al ripristino. È un compromesso accettabile per un ambiente Homelab, ma critico da comprendere per la produzione.

Inoltre, abbiamo personalizzato il `defaultDataPath` per puntare a `/var/lib/longhorn` (il path interno al container del Kubelet che mappa il nostro disco dedicato), garantendo che i dati non toccassero mai il disco dell'OS.

---

## Fase 4: L'Integrazione con Traefik e l'Incubo dei Permessi

La vera battaglia tecnica è iniziata quando abbiamo tentato di utilizzare questo nuovo storage per persistere i certificati SSL di Traefik (file `acme.json`).

### Il Problema: Init:CrashLoopBackOff

Dopo aver configurato Traefik per usare un PVC Longhorn, il pod è entrato in un ciclo di crash continuo.
L'analisi dei log ha rivelato:
`chmod: /data/acme.json: Operation not permitted`

### Analisi della Root Cause

Il conflitto nasceva da tre vettori di sicurezza contrastanti:
1.  **Kubernetes `fsGroup`:** Abbiamo istruito Kubernetes a montare il volume rendendolo scrivibile per il gruppo `65532` (l'utente non-root di Traefik). Questo imposta i permessi a `660` (Lettura/Scrittura per Utente e Gruppo).
2.  **Let's Encrypt / Traefik:** Per sicurezza, Traefik esige che il file `acme.json` abbia permessi strettissimi: `600` (Solo l'utente proprietario può leggere/scrivere). Se i permessi sono più aperti (es. `660`), Traefik si rifiuta di partire.
3.  **HostNetwork & Porte Privilegiate:** Poiché stiamo usando `hostNetwork: true` per esporre Traefik direttamente sull'IP del nodo, Traefik deve poter fare il bind sulle porte 80 e 443. In Linux, le porte sotto la 1024 richiedono privilegi di **Root** (o la capability `NET_BIND_SERVICE`).

### Il Loop Infinito del Troubleshooting

Inizialmente, abbiamo tentato di forzare i permessi con un `initContainer`. Fallito: l'initContainer non aveva i privilegi di root sul filesystem montato.
Abbiamo poi provato a cambiare utente (`runAsUser: 65532`), ma questo impediva il binding sulla porta 80 (`bind: permission denied`).

La situazione era paradossale:
*   Se giravamo come **Root**, potevamo aprire la porta 80, mas Kubernetes (tramite `fsGroup`) alterava i permessi del file a `660`, facendo arrabbiare Traefik.
*   Se giravamo come **Non-Root**, non potevamo aprire la porta 80.

### La Soluzione Definitiva: "Clean Slate"

La risoluzione ha richiesto un approccio radicale:

1.  **Rimozione di `fsGroup`:** Abbiamo rimosso ogni direttiva `fsGroup` dal `values.yaml` di Helm. Questo dice a Kubernetes: "Monta il volume così com'è, non toccare i permessi dei file".
2.  **Esecuzione come Root (Temporanea):** Abbiamo configurato Traefik per girare come `runAsUser: 0` (Root). Questo risolve il problema del binding della porta 80.
3.  **Reset del Volume:** Poiché il file `acme.json` esistente era ormai "corrotto" dai tentativi precedenti (aveva permessi `660`), Traefik continuava a fallire anche con la nuova configurazione. Abbiamo dovuto cancellare manualmente il file (`rm /data/acme.json`) dall'interno del pod.

Al riavvio successivo, Traefik (girando come Root) ha creato un nuovo `acme.json`. Poiché non c'era `fsGroup` a interferire, il file è stato creato con i permessi di default corretti (`600`).
Il log finale è stato una liberazione:
`Testing certificate renew... Register... providerName=myresolver.acme`

---

## Riflessioni Post-Lab

L'implementazione di Longhorn su un cluster Kubernetes bare-metal (o virtualizzato low-level) è un'esercizio che espone la complessità nascosta dello storage distribuito. Non basta "installare il chart". Bisogna comprendere come il sistema operativo gestisce i device, come il Kubelet gestisce i mount point e come i container gestiscono i permessi utente.

**Lezioni Apprese:**
1.  **L'immutabilità richiede pianificazione:** Su sistemi come Talos, le dipendenze kernel e userspace devono essere "bakerizzate" nell'immagine, non installate a posteriori.
2.  **I permessi nello storage persistente sono insidiosi:** Il meccanismo `fsGroup` di Kubernetes è utile per database standard, ma può essere distruttivo per applicazioni che richiedono permessi file paranoici (come Traefik/ACME o le chiavi SSH).
3.  **Identificazione Hardware:** Mai fidarsi dei nomi dei device (`/dev/sda`). Usare UUID o, in fase di provisioning, dimensioni disco univoche per evitare errori umani catastrofici.

Il cluster ora possiede uno strato di persistenza resiliente. Il prossimo passo logico sarà rimuovere la dipendenza da `hostNetwork` e Root introducendo un Load Balancer BGP come **MetalLB**, permettendo a Traefik di girare come utente non privilegiato e completando l'architettura di sicurezza.

---
*Generato tramite Gemini CLI*