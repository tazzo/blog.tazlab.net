+++
title = "Architettura Tecnica e Implementazione di Longhorn su Kubernetes con Talos OS in Ambienti Virtualizzati Proxmox"
date = 2026-01-07
draft = false
description = "Una guida completa all'implementazione dello storage a blocchi Longhorn su un cluster Kubernetes Talos in esecuzione su Proxmox VE."
tags = ["talos", "longhorn", "proxmox", "storage", "kubernetes", "distributed-storage"]
author = "Tazzo"
+++

L'evoluzione delle infrastrutture IT verso paradigmi completamente dichiarativi e immutabili ha trovato nel binomio composto da Talos OS e Kubernetes una delle espressioni più avanzate. Tuttavia, l'adozione di un sistema operativo immutabile e privo di shell introduce sfide significative quando si rende necessaria l'integrazione di soluzioni di archiviazione a blocchi distribuita come Longhorn. Questa relazione tecnica analizza in modo esaustivo l'intero ciclo di vita dell'installazione, partendo dalla configurazione dell'hypervisor Proxmox VE, passando per la personalizzazione di Talos OS tramite estensioni di sistema, fino alla messa in produzione di Longhorn, con un focus particolare sulle ottimizzazioni delle prestazioni e sulla risoluzione delle problematiche di rete e di montaggio.

## **Configurazione dell'Hypervisor: Proxmox VE come Fondazione del Cluster**

La stabilità di un cluster Kubernetes distribuito dipende in larga misura dalla corretta configurazione delle macchine virtuali sottostanti. Proxmox VE offre una flessibilità notevole, ma richiede impostazioni specifiche per soddisfare i requisiti rigorosi di Talos OS e le esigenze di input/output (I/O) di Longhorn.

### **Requisiti della Microarchitettura CPU e Istruzioni Necessarie**

A partire dalla versione 1.0, Talos OS richiede esplicitamente la microarchitettura x86-64-v2. Questo requisito è fondamentale poiché molte installazioni predefinite di Proxmox utilizzano il tipo di CPU kvm64 per massimizzare la compatibilità durante la migrazione live, ma questo modello manca di istruzioni critiche come cx16, popcnt e sse4.2, necessarie per il corretto funzionamento del kernel e dei binari di Talos.1

La scelta del tipo di processore all'interno di Proxmox influenza direttamente la capacità di Longhorn di eseguire operazioni di crittografia e di gestione dei volumi. L'impostazione consigliata è host, che espone tutte le capacità della CPU fisica alla macchina virtuale, garantendo le massime prestazioni per il motore di archiviazione.1 Se la migrazione live tra nodi con CPU diverse è un requisito, l'amministratore deve configurare manualmente i flag CPU nel file di configurazione della VM /etc/pve/qemu-server/\<vmid\>.conf aggiungendo la stringa args: \-cpu kvm64,+cx16,+lahf\_lm,+popcnt,+sse3,+ssse3,+sse4.1,+sse4.2.1

| Parametro CPU | Valore Consigliato | Impatto Tecnico |
| :---- | :---- | :---- |
| Tipo Processore | host | Supporto nativo x86-64-v2 e prestazioni crittografiche superiori.1 |
| Core (Control Plane) | Minimo 2 | Necessari per la gestione dei processi di sistema e etcd.1 |
| Core (Worker Node) | 4 o più | Supporto per il polling del motore Longhorn V2 e carichi di lavoro.4 |
| NUMA | Abilitato | Ottimizzazione dell'accesso alla memoria su server multi-socket.6 |

### **Gestione della Memoria e del Controller SCSI**

Talos OS è progettato per operare interamente in RAM durante le fasi critiche, il che rende la gestione della memoria un punto di potenziale fallimento. Una limitazione nota di Talos riguarda il mancato supporto per l'hot-plug della memoria. Se questa funzione è abilitata in Proxmox, Talos non sarà in grado di rilevare correttamente la memoria totale allocata, portando a errori di installazione per memoria insufficiente.1 La dotazione minima di RAM deve essere di 2 GB per i nodi del piano di controllo e preferibilmente 8 GB per i nodi worker che ospitano Longhorn, dato che quest'ultimo richiede risorse per la replica dei dati e la gestione dei pod di gestione delle istanze.4

Per quanto riguarda l'archiviazione, il controller VirtIO SCSI single rappresenta la scelta d'elezione. Questa configurazione permette l'utilizzo di thread I/O dedicati per ogni disco virtuale, riducendo la contesa tra i processi e migliorando la latenza, un fattore critico quando Longhorn deve replicare blocchi di dati su più nodi attraverso la rete.6 L'abilitazione dell'opzione Discard sul disco virtuale è altrettanto essenziale per permettere al sistema operativo guest di inviare comandi TRIM, assicurando che lo storage sottostante (specialmente se basato su ZFS o LVM-thin in Proxmox) possa recuperare lo spazio non più utilizzato.7

## **Provisioning di Talos OS: Immutabilità e Personalizzazione**

La natura immutabile di Talos OS implica che non sia possibile installare software o driver dopo il boot tramite i canali tradizionali come apt o yum. Pertanto, la preparazione dell'immagine di installazione deve includere preventivamente tutti gli strumenti necessari per Longhorn.

### **Utilizzo dell'Image Factory e Estensioni di Sistema**

Longhorn dipende da binari e demoni che risiedono solitamente a livello di host, come iscsid per la connessione ai volumi e vari strumenti di gestione del filesystem. In Talos, queste dipendenze vengono soddisfatte attraverso le "System Extensions". L'Image Factory di Sidero Labs permette di generare ISO e installer personalizzati che integrano queste estensioni direttamente nell'immagine di sistema.1

Le estensioni indispensabili per un'installazione funzionante di Longhorn includono:

* siderolabs/iscsi-tools: fornisce il demone iscsid e l'utilità iscsiadm, necessari per mappare i volumi Longhorn come dispositivi a blocchi locali.4  
* siderolabs/util-linux-tools: include strumenti come fstrim, utilizzati per la manutenzione del filesystem e la riduzione dell'occupazione di spazio dei volumi.4  
* siderolabs/qemu-guest-agent: fondamentale in ambiente Proxmox per permettere all'hypervisor di comunicare con il guest, facilitando arresti puliti e la corretta visualizzazione degli indirizzi IP nella console di gestione.1

Il processo di generazione dell'immagine produce un ID schematico unico, che garantisce che ogni nodo nel cluster sia configurato in modo identico, eliminando alla radice il problema della deriva della configurazione (configuration drift).9

### **Bootstrapping del Cluster e Configurazione Dichiarativa**

Una volta avviate le VM Proxmox con la ISO personalizzata, il cluster entra in una modalità di manutenzione in attesa della configurazione. L'interazione avviene esclusivamente tramite l'utility talosctl dal terminale dell'amministratore. La generazione dei file di configurazione avviene tramite il comando talosctl gen config, specificando l'endpoint del piano di controllo.1

Durante la fase di modifica dei file controlplane.yaml e worker.yaml, è fondamentale verificare l'identificativo del disco di installazione. In Proxmox, a seconda del controller utilizzato, il disco potrebbe apparire come /dev/sda o /dev/vda. L'utilizzo del comando talosctl get disks \--insecure \--nodes \<IP\> permette di identificare con certezza il dispositivo corretto prima di applicare la configurazione.1

Il bootstrap del cluster segue una sequenza rigorosa:

1. Applicazione della configurazione al nodo del piano di controllo: talosctl apply-config \--insecure \--nodes $CP\_IP \--file controlplane.yaml.1  
2. Inizializzazione del cluster (Bootstrap ETCD): talosctl bootstrap \--nodes $CP\_IP.1  
3. Recupero del file kubeconfig per l'accesso amministrativo a Kubernetes tramite kubectl.1

## **Integrazione di Longhorn: Requisiti e Architettura dei Volumi**

L'installazione di Longhorn su Talos richiede un'attenzione meticolosa alla gestione dei privilegi e alla visibilità dei percorsi del filesystem, poiché Talos isola i processi del piano di controllo e i servizi di sistema in namespace di montaggio separati.

### **Moduli del Kernel e Parametri di Macchina**

Longhorn necessita che determinati moduli del kernel siano caricati per gestire i dispositivi a blocchi virtuali e la comunicazione iSCSI. Poiché Talos non carica tutti i moduli per impostazione predefinita, è necessario dichiararli esplicitamente nella sezione kernel della configurazione di macchina dei nodi worker.11

I moduli richiesti includono nbd (Network Block Device), iscsi\_tcp, iscsi\_generic e configfs.11 La loro inclusione assicura che il manager di Longhorn possa creare correttamente i dispositivi sotto /dev, che verranno poi montati dai pod delle applicazioni.

YAML

machine:  
  kernel:  
    modules:  
      \- name: nbd  
      \- name: iscsi\_tcp  
      \- name: iscsi\_generic  
      \- name: configfs

Questo frammento di configurazione, una volta applicato, forza il nodo al riavvio per caricare i moduli necessari, rendendo il sistema pronto per l'archiviazione distribuita.11

### **Propagazione dei Montaggi e Kubelet Extra Mounts**

Uno degli ostacoli tecnici più comuni nell'installazione di Longhorn su Talos è l'isolamento del processo kubelet. In Talos, kubelet gira all'interno di un contenitore e, per impostazione predefinita, non ha visibilità sui dischi montati dall'utente o sulle directory specifiche dell'host necessarie per le operazioni CSI (Container Storage Interface).10

Per risolvere questo problema, è necessario configurare gli extraMounts per il kubelet. Questa impostazione assicura che il percorso dove Longhorn memorizza i dati sia mappato all'interno del namespace del kubelet con la propagazione dei montaggi impostata su rshared.4 Senza questa configurazione, Kubernetes non sarebbe in grado di collegare i volumi Longhorn ai pod delle applicazioni, risultando in errori di tipo "MountVolume.SetUp failed".14

| Percorso Host | Percorso Kubelet | Opzioni di Montaggio | Funzione |
| :---- | :---- | :---- | :---- |
| /var/lib/longhorn | /var/lib/longhorn | bind, rshared, rw | Percorso predefinito per i dati dei volumi.15 |
| /var/mnt/sdb | /var/mnt/sdb | bind, rshared, rw | Utilizzato se si impiega un secondo disco dedicato.4 |

La propagazione rshared è fondamentale: essa permette a un montaggio effettuato all'interno di un contenitore (come il plugin CSI di Longhorn) di essere visibile all'host e, di conseguenza, ad altri contenitori gestiti dal kubelet.15

## **Strategia di Archiviazione: Dischi Secondari e Persistenza**

Sebbene Longhorn possa tecnicamente archiviare i dati sulla partizione EPHEMERAL di Talos, questa pratica è sconsigliata per ambienti di produzione. La partizione di sistema di Talos è soggetta a modifiche durante gli aggiornamenti del sistema operativo, e l'utilizzo di un disco secondario offre una netta separazione tra i dati applicativi e il sistema operativo immutabile.4

### **Vantaggi dell'Utilizzo di Dischi Dedicati in Proxmox**

L'aggiunta di un secondo disco virtuale (ad esempio /dev/sdb) in Proxmox per ogni nodo worker offre diversi vantaggi architetturali. In primo luogo, isola il traffico di I/O dello storage dal traffico di sistema, riducendo la latenza per le applicazioni sensibili. In secondo luogo, permette una gestione semplificata dello spazio: se un nodo esaurisce lo spazio per i volumi Longhorn, è possibile espandere il disco virtuale in Proxmox senza interferire con le partizioni critiche di Talos.4

Per implementare questa strategia, la configurazione di Talos deve includere istruzioni per formattare e montare il disco aggiuntivo all'avvio:

YAML

machine:  
  disks:  
    \- device: /dev/sdb  
      partitions:  
        \- mountpoint: /var/mnt/sdb

Una volta che il disco è montato su /var/mnt/sdb, questo percorso deve essere comunicato a Longhorn durante l'installazione tramite il file di valori di Helm, impostando defaultDataPath su tale directory.4

### **Analisi dei Formati Disco: RAW vs QCOW2**

La scelta del formato del file immagine in Proxmox ha un impatto diretto sulle prestazioni di Longhorn, che implementa già internamente meccanismi di replica e snapshotting.

| Caratteristica | RAW | QCOW2 |
| :---- | :---- | :---- |
| Prestazioni | Massime (nessun overhead di metadati).18 | Inferiori (overhead dovuto al Copy-on-Write).8 |
| Gestione Spazio | Occupa l'intero spazio allocato (se non supportato dai buchi nel FS).19 | Supporta il thin provisioning nativo.8 |
| Snapshot Hypervisor | Non supportati nativamente su storage a file.19 | Supportati nativamente.8 |

In un'architettura dove Longhorn gestisce la ridondanza a livello di cluster, l'utilizzo del formato RAW è spesso preferito per evitare il fenomeno del "doppio snapshotting" e ridurre la latenza di scrittura.18 Tuttavia, se l'infrastruttura Proxmox sottostante è basata su ZFS, è cruciale evitare l'uso di QCOW2 sopra ZFS per prevenire un'amplificazione massiccia delle scritture, che degraderebbe rapidamente le prestazioni degli SSD.20

## **Implementazione e Configurazione Software di Longhorn**

Dopo aver preparato l'infrastruttura Talos, l'installazione di Longhorn avviene tipicamente tramite Helm o operatori GitOps come Flux o ArgoCD.

### **Sicurezza e Namespace Privilegiato**

A causa delle operazioni a basso livello che deve compiere, Longhorn richiede privilegi elevati. Con l'introduzione dei Pod Security Standards in Kubernetes, è imperativo etichettare correttamente il namespace longhorn-system per permettere l'esecuzione di pod in modalità privilegiata.11

L'applicazione del seguente manifesto garantisce che i componenti di Longhorn non vengano bloccati dal controller di ammissione:

YAML

apiVersion: v1  
kind: Namespace  
metadata:  
  name: longhorn-system  
  labels:  
    pod-security.kubernetes.io/enforce: privileged  
    pod-security.kubernetes.io/audit: privileged  
    pod-security.kubernetes.io/warn: privileged

Questo passaggio è critico: senza di esso, i pod del manager di Longhorn o i plugin CSI non riuscirebbero ad avviarsi, lasciando il sistema in uno stato di attesa perpetua.11

### **Parametri di Installazione Helm Consigliati**

Durante l'installazione tramite Helm, alcuni parametri devono essere adattati per l'ambiente Talos-Proxmox. L'uso di un file values.yaml personalizzato permette di automatizzare queste impostazioni:

* defaultSettings.defaultDataPath: impostato sul percorso del disco secondario (es. /var/mnt/sdb).4  
* defaultSettings.numberOfReplicas: solitamente impostato a 3 per garantire l'alta affidabilità.4  
* defaultSettings.createDefaultDiskLabeledNodes: se impostato su true, permette di selezionare solo nodi specifici come nodi di archiviazione tramite etichette Kubernetes.4

Inoltre, per evitare problemi durante gli aggiornamenti in ambienti Talos, si raccomanda spesso di disabilitare il preUpgradeChecker se questo causa blocchi inspiegabili dovuti alla natura immutabile del filesystem host.11

## **Ottimizzazione delle Prestazioni e Networking**

L'archiviazione distribuita è intrinsecamente dipendente dalle prestazioni della rete. In un ambiente virtualizzato Proxmox, la configurazione dei bridge e delle interfacce VirtIO può fare la differenza tra un sistema reattivo e uno afflitto da timeout.

### **Problematiche di MTU e Frammentazione dei Pacchetti**

Un errore comune nelle configurazioni Proxmox riguarda il mismatch dell'MTU (Maximum Transmission Unit). Se il bridge fisico di Proxmox è configurato per i Jumbo Frames (MTU 9000\) per ottimizzare il traffico storage, ma le interfacce delle VM Talos sono lasciate al valore predefinito di 1500, si verificherà una frammentazione dei pacchetti che aumenterà drasticamente l'uso della CPU e ridurrà il throughput dei volumi Longhorn.23

La coerenza dell'MTU deve essere garantita lungo l'intero percorso:

1. Switch fisico e NIC del server Proxmox.  
2. Linux Bridge (vmbr0) o OVS Bridge in Proxmox.  
3. Configurazione di rete nel file YAML di Talos OS.  
4. Configurazione del CNI (es. Cilium o Flannel) all'interno di Kubernetes.23

In alcune versioni recenti di Proxmox (8.2+), sono stati segnalati bug relativi alla gestione dell'MTU con i driver VirtIO, che possono causare il blocco delle connessioni TCP durante trasferimenti intensivi. In questi casi, forzare l'MTU a 1500 su tutti i livelli può risolvere instabilità inspiegabili, a scapito di una leggera riduzione dell'efficienza.24

### **Motore V2 e SPDK: Requisiti di Risorse Elevati**

Longhorn ha introdotto un nuovo motore di archiviazione (V2) basato su SPDK (Storage Performance Development Kit). Sebbene offra prestazioni superiori, i requisiti per i nodi Talos aumentano notevolmente. Il motore V2 utilizza driver in modalità polling invece che basati su interrupt, il che significa che i processi di gestione delle istanze consumeranno il 100% di un core CPU dedicato per minimizzare la latenza.5

Requisiti per il motore V2 su Talos:

* **Huge Pages**: è necessario configurare l'allocazione di pagine di memoria grandi (2 MiB) tramite sysctl nella configurazione di Talos (es. 1024 pagine per un totale di 2 GiB).5  
* **Istruzioni CPU**: il supporto per SSE4.2 è obbligatorio, rinforzando la necessità del tipo CPU host in Proxmox.5

L'attivazione del motore V2 deve essere una scelta ponderata in base al carico di lavoro: per database ad alte prestazioni è consigliata, mentre per carichi di lavoro generici il motore V1 rimane più efficiente in termini di consumo di risorse.5

## **Gestione Operativa: Aggiornamenti, Backup e Troubleshooting**

Il mantenimento di un cluster Longhorn su Talos richiede una comprensione dei flussi di lavoro specifici per sistemi immutabili.

### **Gestione degli Aggiornamenti di Talos OS**

L'aggiornamento di un nodo Talos comporta il riavvio della macchina virtuale con una nuova immagine. Durante questo processo, Longhorn deve gestire la temporanea indisponibilità di una replica.

Procedura di aggiornamento sicuro:

1. Verificare che tutti i volumi Longhorn siano in stato "Healthy" e abbiano il numero completo di repliche.  
2. Eseguire l'aggiornamento di un nodo alla volta utilizzando talosctl upgrade.  
3. Attendere che il nodo rientri nel cluster Kubernetes e che Longhorn completi la ricostruzione (rebuilding) delle repliche prima di procedere al nodo successivo.9

È fondamentale che l'immagine utilizzata per l'aggiornamento contenga le stesse estensioni di sistema (iscsi-tools) dell'immagine originale, altrimenti Longhorn perderà la capacità di comunicare con i dischi al primo riavvio.9

### **Backup dei Dati e Disaster Recovery**

Sebbene Proxmox permetta di eseguire backup dell'intera VM, per i dati contenuti nei volumi Longhorn è preferibile utilizzare la funzione di backup nativa della soluzione. Longhorn può esportare snapshot verso un archivio esterno (S3 o NFS).11

In ambiente Talos, se si sceglie NFS come target di backup, è necessario assicurarsi che l'estensione per il client NFSv4 sia presente nell'immagine di sistema o che il supporto kernel sia abilitato.15 La configurazione di un BackupTarget predefinito è una best practice che evita errori di inizializzazione dei volumi in alcune versioni di Longhorn.11

### **Risoluzione dei Problemi Comuni**

Un problema frequente riguarda l'impossibilità per i nodi di unirsi al cluster dopo l'applicazione della configurazione, spesso manifestandosi con uno stato di "Installing" infinito nella console Proxmox. Questo è solitamente dovuto a problemi di rete (gateway errato, mancanza di DHCP o DNS non funzionante) che impediscono a Talos di scaricare l'immagine di installazione finale.28 L'uso di indirizzi IP statici prenotati tramite MAC address nel server DHCP è la soluzione raccomandata per garantire coerenza durante i molteplici riavvii del processo di installazione.3

Un altro errore critico è il "Missing Kind" durante l'uso di talosctl patch. Questo accade se il file di patch YAML non include le intestazioni apiVersion e kind. Talos richiede che ogni patch sia un oggetto Kubernetes valido o che la struttura rispetti esattamente lo schema previsto per la risorsa specifica.9

## **Modellazione delle Prestazioni I/O in Ambiente Virtualizzato**

Il rendimento di Longhorn può essere analizzato matematicamente considerando le latenze introdotte dai vari strati di astrazione. La latenza totale di scrittura ($L\_{total}$) in una configurazione con replicazione sincrona può essere espressa come:

$$L\_{total} \\approx L\_{virt} \+ L\_{fs\\\_guest} \+ \\max(L\_{net\\\_RTT} \+ L\_{io\\\_remote})$$  
Dove:

* $L\_{virt}$: latenza introdotta dall'hypervisor Proxmox e dal driver VirtIO.  
* $L\_{fs\\\_guest}$: overhead del filesystem all'interno della VM (es. XFS o Ext4).  
* $L\_{net\\\_RTT}$: tempo di andata e ritorno della rete tra i nodi worker per la replica del blocco.  
* $L\_{io\\\_remote}$: latenza di scrittura sul disco fisico del nodo remoto.

In una rete a 1 Gbps, $L\_{net\\\_RTT}$ può diventare il collo di bottiglia principale, specialmente sotto carico pesante. L'adozione di una rete a 10 Gbps riduce drasticamente questo valore, permettendo a Longhorn di avvicinarsi alle prestazioni di un'archiviazione locale.23

## **Sintesi e Raccomandazioni Finali**

L'implementazione di Longhorn su un cluster Kubernetes basato su Talos OS e Proxmox rappresenta una soluzione di eccellenza per la gestione di carichi di lavoro stateful in ambienti moderni. La chiave del successo risiede nella preparazione meticolosa dello strato infrastrutturale e nella comprensione della natura dichiarativa di Talos.

Si raccomandano le seguenti azioni per una messa in produzione ottimale:

1. **Personalizzazione Preventiva**: Integrare sempre iscsi-tools e util-linux-tools nelle immagini Talos tramite l'Image Factory per evitare problemi di runtime.4  
2. **Configurazione Hardware**: Utilizzare il tipo CPU host e controller SCSI dedicati con thread I/O abilitati in Proxmox.1  
3. **Separazione dei Dati**: Implementare sempre dischi secondari per l'archiviazione dei dati Longhorn, evitando l'uso della partizione di sistema.4  
4. **Monitoraggio della Rete**: Garantire la coerenza dell'MTU su tutti i livelli della rete virtuale e fisica per prevenire degradazioni delle prestazioni.23  
5. **Sicurezza Dichiarativa**: Gestire tutte le configurazioni, inclusi i montaggi extra e i moduli del kernel, tramite file YAML versionati, sfruttando appieno la filosofia GitOps supportata da Talos.29

Questa architettura, sebbene richieda una curva di apprendimento iniziale superiore rispetto alle distribuzioni Linux tradizionali, offre garanzie di sicurezza e riproducibilità che la rendono ideale per le sfide della moderna ingegneria del software.

#### **Bibliografia**

1. Proxmox \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno dicembre 30, 2025, [https://docs.siderolabs.com/talos/v1.9/platform-specific-installations/virtualized-platforms/proxmox](https://docs.siderolabs.com/talos/v1.9/platform-specific-installations/virtualized-platforms/proxmox)  
2. Talos on Proxmox, accesso eseguito il giorno dicembre 30, 2025, [https://homelab.casaursus.net/talos-on-proxmox-3/](https://homelab.casaursus.net/talos-on-proxmox-3/)  
3. Talos with Kubernetes on Proxmox \- Secsys, accesso eseguito il giorno dicembre 30, 2025, [https://secsys.pages.dev/posts/talos/](https://secsys.pages.dev/posts/talos/)  
4. Storage Solution: Longhorn, accesso eseguito il giorno dicembre 30, 2025, [https://www.xelon.ch/en/docs/storage-solution-longhorn](https://www.xelon.ch/en/docs/storage-solution-longhorn)  
5. Longhorn | Prerequisites, accesso eseguito il giorno dicembre 30, 2025, [https://longhorn.io/docs/1.10.1/v2-data-engine/prerequisites/](https://longhorn.io/docs/1.10.1/v2-data-engine/prerequisites/)  
6. Best CPU Settings for a VM? I want best Per Thread Performance from 13,900k : r/Proxmox, accesso eseguito il giorno dicembre 30, 2025, [https://www.reddit.com/r/Proxmox/comments/16i7i2w/best\_cpu\_settings\_for\_a\_vm\_i\_want\_best\_per\_thread/](https://www.reddit.com/r/Proxmox/comments/16i7i2w/best_cpu_settings_for_a_vm_i_want_best_per_thread/)  
7. Windows 2022 guest best practices \- Proxmox VE, accesso eseguito il giorno dicembre 30, 2025, [https://pve.proxmox.com/wiki/Windows\_2022\_guest\_best\_practices](https://pve.proxmox.com/wiki/Windows_2022_guest_best_practices)  
8. Using the QCOW2 disk format in Proxmox \- 4sysops, accesso eseguito il giorno dicembre 30, 2025, [https://4sysops.com/archives/using-the-qcow2-disk-format-in-proxmox/](https://4sysops.com/archives/using-the-qcow2-disk-format-in-proxmox/)  
9. Improve Documentation for Longhorn and System Extensions ..., accesso eseguito il giorno dicembre 30, 2025, [https://github.com/siderolabs/talos/issues/12064](https://github.com/siderolabs/talos/issues/12064)  
10. Install Longhorn on Talos Kubernetes \- HackMD, accesso eseguito il giorno dicembre 30, 2025, [https://hackmd.io/@QI-AN/Install-Longhorn-on-Talos-Kubernetes](https://hackmd.io/@QI-AN/Install-Longhorn-on-Talos-Kubernetes)  
11. Installing Longhorn on Talos Linux: A Step-by-Step Guide \- Phin3has Tech Blog, accesso eseguito il giorno dicembre 30, 2025, [https://phin3has.blog/posts/talos-longhorn/](https://phin3has.blog/posts/talos-longhorn/)  
12. A collection of scripts for creating and managing kubernetes clusters on talos linux \- GitHub, accesso eseguito il giorno dicembre 30, 2025, [https://github.com/joshrnoll/talos-scripts](https://github.com/joshrnoll/talos-scripts)  
13. Automating Talos Installation on Proxmox with Packer and Terraform, Integrating Cilium and Longhorn | Suraj Remanan, accesso eseguito il giorno dicembre 30, 2025, [https://surajremanan.com/posts/automating-talos-installation-on-proxmox-with-packer-and-terraform/](https://surajremanan.com/posts/automating-talos-installation-on-proxmox-with-packer-and-terraform/)  
14. Why are Kubelet extra mounts for Longhorn needed? · siderolabs talos · Discussion \#9674, accesso eseguito il giorno dicembre 30, 2025, [https://github.com/siderolabs/talos/discussions/9674](https://github.com/siderolabs/talos/discussions/9674)  
15. Longhorn | Quick Installation, accesso eseguito il giorno dicembre 30, 2025, [https://longhorn.io/docs/1.10.1/deploy/install/](https://longhorn.io/docs/1.10.1/deploy/install/)  
16. Kubernetes \- Reddit, accesso eseguito il giorno dicembre 30, 2025, [https://www.reddit.com/r/kubernetes/hot/](https://www.reddit.com/r/kubernetes/hot/)  
17. Longhorn | Multiple Disk Support, accesso eseguito il giorno dicembre 30, 2025, [https://longhorn.io/docs/1.10.1/nodes-and-volumes/nodes/multidisk/](https://longhorn.io/docs/1.10.1/nodes-and-volumes/nodes/multidisk/)  
18. Which is better image format, raw or qcow2, to use as a baseimage for other VMs?, accesso eseguito il giorno dicembre 30, 2025, [https://serverfault.com/questions/677639/which-is-better-image-format-raw-or-qcow2-to-use-as-a-baseimage-for-other-vms](https://serverfault.com/questions/677639/which-is-better-image-format-raw-or-qcow2-to-use-as-a-baseimage-for-other-vms)  
19. Raw vs Qcow2 Image | Storware BLOG, accesso eseguito il giorno dicembre 30, 2025, [https://storware.eu/blog/raw-vs-qcow2-image/](https://storware.eu/blog/raw-vs-qcow2-image/)  
20. RAW or QCOW2 ? : r/Proxmox \- Reddit, accesso eseguito il giorno dicembre 30, 2025, [https://www.reddit.com/r/Proxmox/comments/1jh4rlp/raw\_or\_qcow2/](https://www.reddit.com/r/Proxmox/comments/1jh4rlp/raw_or_qcow2/)  
21. Performance Tweaks \- Proxmox VE, accesso eseguito il giorno dicembre 30, 2025, [https://pve.proxmox.com/wiki/Performance\_Tweaks](https://pve.proxmox.com/wiki/Performance_Tweaks)  
22. Longhorn \- Rackspace OpenStack Documentation, accesso eseguito il giorno dicembre 30, 2025, [https://docs.rackspacecloud.com/storage-longhorn/](https://docs.rackspacecloud.com/storage-longhorn/)  
23. Strange Issue Using Virtio on 10Gb Network Adapters | Page 2 | Proxmox Support Forum, accesso eseguito il giorno dicembre 30, 2025, [https://forum.proxmox.com/threads/strange-issue-using-virtio-on-10gb-network-adapters.167666/page-2](https://forum.proxmox.com/threads/strange-issue-using-virtio-on-10gb-network-adapters.167666/page-2)  
24. qemu virtio issues after upgrade to 9 \- Proxmox Support Forum, accesso eseguito il giorno dicembre 30, 2025, [https://forum.proxmox.com/threads/qemu-virtio-issues-after-upgrade-to-9.169625/](https://forum.proxmox.com/threads/qemu-virtio-issues-after-upgrade-to-9.169625/)  
25. working interface fails when added to bridge \- Proxmox Support Forum, accesso eseguito il giorno dicembre 30, 2025, [https://forum.proxmox.com/threads/working-interface-fails-when-added-to-bridge.106271/](https://forum.proxmox.com/threads/working-interface-fails-when-added-to-bridge.106271/)  
26. qemu virtio issues after upgrade to 9 | Page 2 \- Proxmox Support Forum, accesso eseguito il giorno dicembre 30, 2025, [https://forum.proxmox.com/threads/qemu-virtio-issues-after-upgrade-to-9.169625/page-2](https://forum.proxmox.com/threads/qemu-virtio-issues-after-upgrade-to-9.169625/page-2)  
27. Installing Longhorn on Talos With Helm \- Josh Noll, accesso eseguito il giorno dicembre 30, 2025, [https://joshrnoll.com/installing-longhorn-on-talos-with-helm/](https://joshrnoll.com/installing-longhorn-on-talos-with-helm/)  
28. Completely unable to configure Talos in a Proxmox VM · siderolabs ..., accesso eseguito il giorno dicembre 30, 2025, [https://github.com/siderolabs/talos/discussions/9291](https://github.com/siderolabs/talos/discussions/9291)  
29. What Longhorn Talos Actually Does and When to Use It \- hoop.dev, accesso eseguito il giorno dicembre 30, 2025, [https://hoop.dev/blog/what-longhorn-talos-actually-does-and-when-to-use-it/](https://hoop.dev/blog/what-longhorn-talos-actually-does-and-when-to-use-it/)