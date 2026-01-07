+++
title = "Architettura, Implementazione e Ottimizzazione di Talos OS su Proxmox: La Guida Definitiva per Homelab e Ambienti di Produzione"
date = 2026-01-07
draft = false
description = "La guida definitiva per distribuire e ottimizzare Talos OS su Proxmox VE sia per homelab che per la produzione."
tags = ["talos", "proxmox", "kubernetes", "homelab", "production", "immutable-os"]
author = "Tazzo"
+++

L'evoluzione tecnologica dei data center domestici e delle infrastrutture aziendali ha portato alla nascita di soluzioni che sfidano i paradigmi tradizionali dell'amministrazione di sistema. In questo contesto, Talos OS si distingue non come una semplice distribuzione Linux, ma come una reinterpretazione radicale del sistema operativo progettato esclusivamente per Kubernetes. La sua natura immutabile, minimale e governata interamente tramite API rappresenta una soluzione ideale per chi desidera un ambiente Proxmox stabile, sicuro e privo del debito tecnico associato alla gestione manuale via SSH.1 Questa relazione esamina in profondità ogni aspetto necessario per portare un cluster Talos OS da zero a una configurazione di produzione su Proxmox VE, analizzando le complessità del networking, della persistenza dei dati e delle ottimizzazioni specifiche per l'hypervisor.

## **Fondamenti Architetturali di Talos OS e l'Approccio Immutabile**

La filosofia alla base di Talos OS è centrata sull'eliminazione di tutto ciò che non è strettamente necessario all'esecuzione di Kubernetes. A differenza di una distribuzione Linux tradizionale, Talos non include una shell, non ha un gestore di pacchetti e non permette l'accesso SSH.1 Tutta la gestione avviene attraverso un'interfaccia gRPC protetta da mTLS (Mutual TLS), garantendo che ogni interazione con il sistema sia autenticata e crittografata alla base.2

### **La Struttura del File System e la Gestione dei Layer**

L'architettura del file system di Talos è uno dei suoi tratti più distintivi e garantisce la resilienza del sistema contro la corruzione accidentale o gli attacchi malevoli. Il nucleo del sistema risiede in una partizione root di sola lettura, strutturata come un'immagine SquashFS.5 Durante il boot, questa immagine viene montata come un dispositivo di loop in memoria, creando una base immutabile. Sopra questa base, Talos sovrappone diversi livelli per gestire le necessità di runtime:

| Layer del File System | Tipologia               | Funzione Principale                                    | Persistenza                 |
| :-------------------- | :---------------------- | :----------------------------------------------------- | :-------------------------- |
| **Rootfs**            | SquashFS (Sola Lettura) | Nucleo del sistema operativo e binari essenziali.      | Immutabile                  |
| **System**            | tmpfs (In Memoria)      | File di configurazione temporanei come /etc/hosts.     | Ricreato al Boot            |
| **Ephemeral**         | XFS (Su Disco)          | Directory /var per container, immagini e dati di etcd. | Persistente (Wipe su Reset) |
| **State**             | Partizione dedicata     | Configurazione della macchina e identità del nodo.     | Persistente                 |

Questa separazione assicura che un errore di configurazione o un file temporaneo corrotto non compromettano mai l'integrità del sistema operativo sottostante. La partizione EPHEMERAL, montata in /var, ospita tutto ciò che Kubernetes richiede per funzionare: dal database di etcd nei nodi control plane alle immagini scaricate dal container runtime (containerd).5 Un aspetto critico del design di Talos è che i cambiamenti effettuati a file come /etc/resolv.conf o /etc/hosts sono gestiti tramite bind mount da una directory di sistema che viene completamente rigenerata a ogni riavvio, forzando l'amministratore a definire tali impostazioni esclusivamente nel file di configurazione dichiarativo.5

### **Il Modello Operativo basato su API**

Il passaggio da una gestione imperativa (comandi eseguiti via shell) a una dichiarativa (stato desiderato definito in YAML) è il cuore dell'esperienza Talos. Il tool talosctl agisce come il client primario che comunica con il demone apid in esecuzione su ogni nodo.5 Questa architettura permette di trattare i nodi del cluster come "bestiame" anziché "animali domestici" (cattle vs pets), dove la sostituzione di un nodo non funzionante è preferibile alla sua riparazione manuale. L'assenza di SSH riduce drasticamente la superficie di attacco, poiché elimina una delle porte d'ingresso più comuni per i malware e i movimenti laterali all'interno di una rete.2

## **Pianificazione dell'Infrastruttura su Proxmox VE**

L'implementazione di Talos su Proxmox richiede una configurazione attenta delle macchine virtuali per garantire che i driver paravirtualizzati e le funzionalità di sicurezza siano sfruttati correttamente. Proxmox, basandosi su KVM/QEMU, offre un supporto eccellente per Talos, ma alcune impostazioni di default possono causare instabilità o prestazioni subottimali.8

### **Allocazione delle Risorse e Requisiti Hardware**

Sebbene Talos sia estremamente efficiente, Kubernetes richiede risorse minime per gestire il piano di controllo e i carichi di lavoro. La distribuzione delle risorse deve tenere conto non solo delle necessità attuali, ma anche della crescita futura del cluster.

| Parametro Risorsa | Control Plane (Minimo) | Worker (Minimo) | Produzione Consigliata |
| :---- | :---- | :---- | :---- |
| **vCPU** | 2 Core | 1 Core | 4+ Core (Control Plane) |
| **RAM** | 2 GB | 2 GB | 4-8 GB+ |
| **Storage (OS)** | 10 GB | 10 GB | 40-100 GB (NVMe/SSD) |
| **Tipo CPU** | x86-64-v2 o Superiore | x86-64-v2 o Superiore | Host (Passthrough) |

Un dettaglio tecnico fondamentale riguarda la microarchitettura della CPU. A partire dalla versione 1.0, Talos richiede il supporto al set di istruzioni x86-64-v2.10 In Proxmox, il tipo di CPU predefinito "kvm64" potrebbe non esporre le flag necessarie (come cx16, popcnt, o sse4.2). È caldamente raccomandato impostare il tipo di CPU della VM su "host" o utilizzare una configurazione personalizzata che abiliti esplicitamente queste estensioni per evitare il fallimento del boot o crash improvvisi durante l'esecuzione di carichi di lavoro intensivi.10

### **Configurazione della VM per Prestazioni Ottimali**

Per un'integrazione fluida, la configurazione della macchina virtuale deve rispecchiare i moderni standard di virtualizzazione. L'uso di UEFI (OVMF) è preferibile rispetto al BIOS tradizionale, poiché permette una gestione più sicura del boot e supporta dischi di dimensioni maggiori con partizionamento GPT.10 Il chipset dovrebbe essere impostato su q35, che offre un supporto PCIe nativo superiore rispetto all'antiquato i440fx. Per quanto riguarda lo storage, l'uso del controller VirtIO SCSI Single con l'opzione "iothread" e l'abilitazione del supporto "discard" (se supportato dal backend fisico) assicura una gestione efficiente dello spazio disco e prestazioni di input/output elevate.6

## **Implementazione: Dal Boot al Cluster Ready**

Il processo di installazione di Talos non prevede un installer interattivo tradizionale. Il boot avviene tramite una ISO che carica il sistema operativo interamente in RAM, lasciando il nodo in attesa di una configurazione remota.6

### **Preparazione della Workstation e talosctl**

Prima di interagire con le VM su Proxmox, è necessario preparare l'ambiente di gestione locale. Il binario talosctl deve essere installato sulla workstation dell'amministratore. Questo strumento gestisce la generazione dei segreti, la configurazione dei nodi e il monitoraggio del cluster.6 È fondamentale che la versione di talosctl sia allineata con la versione di Talos OS che si intende distribuire per evitare incompatibilità nel protocollo gRPC.13

Bash

\# Esempio di installazione su macOS tramite Homebrew  
brew install siderolabs/tap/talosctl

Una volta scaricata l'immagine ISO di Talos (preferibilmente personalizzata tramite la Image Factory per includere i driver necessari), questa deve essere caricata nello storage ISO di Proxmox.6 Al primo avvio della VM, la console mostrerà un indirizzo IP temporaneo ottenuto tramite DHCP. Questo IP è il punto di ingresso per l'invio della configurazione iniziale.6

### **Generazione dei File di Configurazione e Gestione dei Segreti**

La sicurezza di Talos si basa su un set di segreti generati localmente. Questi segreti non vengono mai trasmessi in chiaro e costituiscono la base per la firma dei certificati mTLS.14 La generazione della configurazione richiede la definizione dell'endpoint dell'API di Kubernetes, che solitamente coincide con l'IP del primo nodo master o con un IP virtuale gestito.6

Bash

\# Generazione dei segreti del cluster  
talosctl gen secrets \-o secrets.yaml

\# Generazione dei file di configurazione per nodi master e worker  
talosctl gen config my-homelab-cluster https://192.168.1.50:6443 \\  
  \--with-secrets secrets.yaml \\  
  \--output-dir \_out

Questa operazione genera tre componenti principali:

* controlplane.yaml: Contiene le definizioni per i nodi che gestiranno etcd e l'API server.  
* worker.yaml: Contiene la configurazione per i nodi che eseguiranno i carichi di lavoro.  
* talosconfig: Il file client che permette all'amministratore di autenticarsi presso il cluster.6

### **Applicazione della Configurazione e Bootstrap di etcd**

L'applicazione della configurazione trasforma il nodo dalla modalità manutenzione a un sistema operativo installato e funzionale. È essenziale verificare il nome del disco target (es. /dev/sda o /dev/vda) prima dell'invio del file YAML.8 L'invio iniziale avviene in modalità "insicura" poiché i certificati mTLS non sono ancora stati distribuiti sul nodo.6

Bash

talosctl apply-config \--insecure \--nodes 192.168.1.10 \--file \_out/controlplane.yaml

Dopo il riavvio, il primo nodo control plane deve essere istruito per inizializzare il cluster Kubernetes tramite il comando di bootstrap. Questa operazione configura il database distribuito etcd e avvia i componenti principali del piano di controllo.6 Solo dopo questa fase, il cluster diventa consapevole di se stesso e l'endpoint dell'API Kubernetes diventa raggiungibile.

## **Networking: Ottimizzazione e Alta Affidabilità**

Il networking è il settore in cui Talos esprime la sua massima flessibilità, permettendo all'amministratore di scegliere tra configurazioni standard e soluzioni avanzate basate su eBPF.17

### **La Scelta tra Flannel e Cilium**

Di default, Talos utilizza Flannel come interfaccia di rete (CNI), una soluzione semplice che fornisce connettività pod-to-pod tramite un overlay VXLAN.17 Tuttavia, Flannel manca di supporto per le Network Policies e non offre funzionalità di osservabilità avanzate. Per un homelab orientato alla produzione, Cilium rappresenta il gold standard.17 Grazie all'uso intensivo di eBPF, Cilium può sostituire interamente il componente kube-proxy, migliorando drasticamente le prestazioni del routing e riducendo il carico sulla CPU eliminando le migliaia di regole iptables tipiche dei cluster Kubernetes tradizionali.19

L'implementazione di Cilium richiede la disabilitazione esplicita del CNI di default e di kube-proxy nella configurazione di Talos.16 Questo viene fatto tramite un patch YAML applicato durante la generazione o la modifica della configurazione:

YAML

cluster:  
  network:  
    cni:  
      name: none  
  proxy:  
    disabled: true

La rimozione di kube-proxy non è priva di sfide. Cilium deve essere configurato per gestire i servizi tramite l'eBPF host routing. Un dettaglio critico spesso trascurato è la necessità di impostare bpf.hostLegacyRouting=true se si riscontrano problemi di risoluzione DNS o connettività tra pod e host in particolari versioni del kernel.21

### **Alta Affidabilità con kube-vip**

In un cluster con più nodi control plane, è essenziale che l'API server sia raggiungibile attraverso un unico indirizzo IP stabile, anche se uno dei nodi master fallisce. Talos offre una funzionalità di IP virtuale (VIP) integrata che opera al livello 2 (ARP) o livello 3 (BGP).14 Questa funzione si basa sull'elezione del leader gestita direttamente da etcd.22

Un'alternativa molto diffusa è kube-vip, che può operare sia come VIP per il control plane sia come Load Balancer per i servizi Kubernetes di tipo LoadBalancer.23 Kube-vip in modalità ARP elegge un leader tra i nodi che ospita l'IP virtuale. Per evitare colli di bottiglia, è possibile abilitare la "leader election per service", permettendo a diversi nodi del cluster di ospitare diversi IP di servizio, distribuendo così il carico di rete.24

| Caratteristica | VIP Nativo di Talos | Kube-vip |
| :---- | :---- | :---- |
| **Control Plane HA** | Integrato, molto semplice da configurare. | Supportato via Static Pods o DaemonSet. |
| **Service LoadBalancer** | Non supportato nativamente. | Core feature, supporta diversi range di IP. |
| **Dipendenze** | Dipende direttamente da etcd. | Dipende da Kubernetes o etcd. |
| **Configurazione** | Dichiarativa nel file controlplane.yaml. | Richiede manifest Kubernetes o patches. |

L'uso del VIP nativo di Talos è consigliato per la sua semplicità nel garantire l'accesso all'API server, mentre kube-vip è la scelta ideale se si desidera esporre servizi interni (come un Ingress Controller) con IP statici della propria rete locale.23

## **Ottimizzazioni Proxmox e Personalizzazioni Avanzate**

Per far sì che Talos si comporti come un cittadino di prima classe all'interno di Proxmox, è necessario implementare alcune ottimizzazioni che colmano il divario tra l'hypervisor e il sistema operativo minimale.

### **QEMU Guest Agent e System Extensions**

Il QEMU Guest Agent è un helper fondamentale che permette a Proxmox di gestire gli shutdown puliti e di leggere informazioni sulla rete direttamente dalla VM.4 Poiché Talos non ha un gestore di pacchetti, non è possibile installarlo con un comando apt install. La soluzione risiede nelle "System Extensions" di Talos.4 Utilizzando la([https://factory.talos.dev](https://factory.talos.dev)), è possibile generare un'immagine ISO o un installer che includa l'estensione siderolabs/qemu-guest-agent.4

Una volta inclusa l'estensione, il servizio deve essere abilitato nel file di configurazione della macchina:

YAML

machine:  
  features:  
    qemuGuestAgent:  
      enabled: true

Questo approccio garantisce che l'agente sia parte integrante dell'immagine immutabile del sistema, mantenendo la coerenza tra i nodi e facilitando le operazioni di manutenzione dall'interfaccia web di Proxmox.4

### **Persistenza con iSCSI e Longhorn**

In molti homelab, lo storage non è locale ma risiede su un NAS o una SAN. Per utilizzare soluzioni di storage distribuito come Longhorn o per montare volumi via iSCSI, Talos necessita dei relativi binari di sistema. Anche in questo caso, le estensioni giocano un ruolo cruciale. L'aggiunta di siderolabs/iscsi-tools e siderolabs/util-linux-tools fornisce i driver necessari al kernel e le utilità allo spazio utente per gestire i target iSCSI.4

È inoltre necessario configurare il kubelet per permettere il montaggio di directory specifiche come /var/lib/longhorn con i permessi corretti (rshared, rw). Questo garantisce che i container che gestiscono lo storage abbiano accesso diretto all'hardware o ai volumi di rete senza interferenze da parte dei meccanismi di isolamento del sistema operativo.9

## **Ciclo di Vita: Aggiornamenti e Manutenzione Atomica**

La manutenzione di un cluster Talos differisce radicalmente dai sistemi tradizionali. Gli aggiornamenti sono atomici e basati su immagini, riducendo quasi a zero il rischio di lasciare il sistema in uno stato intermedio incoerente.2

### **Strategie di Update e Rollback**

Talos implementa un sistema di aggiornamento A-B. Quando viene inviato un comando di upgrade, il sistema scarica la nuova immagine in una partizione inattiva, aggiorna il bootloader e si riavvia.26 Se il boot della nuova versione fallisce (ad esempio per una configurazione incompatibile con il nuovo kernel), Talos esegue automaticamente il rollback alla versione precedente.26 Questo meccanismo, preso in prestito dai sistemi operativi per smartphone (come Android), garantisce una disponibilità elevatissima.

Le procedure consigliate prevedono l'aggiornamento un nodo alla volta, iniziando dai nodi worker e procedendo infine ai nodi control plane.13 Durante l'aggiornamento, Talos esegue automaticamente il "cordon" (impedisce nuovi pod) e il "drain" (sposta i pod esistenti) del nodo in Kubernetes, assicurando che i carichi di lavoro non subiscano interruzioni brusche.26

### **Monitoraggio con la Dashboard Integrata**

Per la diagnostica immediata, Talos mette a disposizione una dashboard integrata accessibile via talosctl. Questo strumento fornisce una panoramica dello stato di salute dei servizi core, dell'uso delle risorse e dei log di sistema, eliminando la necessità di installare agenti di monitoraggio esterni pesanti durante le fasi iniziali di troubleshooting.8

Bash

\# Avvio della dashboard per un nodo specifico  
talosctl dashboard \--nodes 192.168.1.10

Questa dashboard è particolarmente utile durante la fase di bootstrap per identificare perché un nodo non riesce a unirsi al cluster o perché etcd non raggiunge il quorum.8

## **Considerazioni Finali e Prospettive Future**

L'adozione di Talos OS su Proxmox VE rappresenta una scelta di eccellenza per chiunque voglia costruire un'infrastruttura Kubernetes robusta e moderna. La combinazione della gestione dichiarativa, dell'immutabilità e dell'assenza di componenti legacy come SSH eleva lo standard di sicurezza e stabilità ben oltre ciò che è possibile ottenere con distribuzioni Linux generaliste.1

Le sfide iniziali legate all'apprendimento di un nuovo paradigma sono ampiamente compensate dalla facilità con cui è possibile gestire gli aggiornamenti di sistema e dalla prevedibilità del comportamento del cluster. In un ecosistema dove la complessità di Kubernetes può spesso diventare travolgente, Talos offre un approccio "opinionated" che riduce le variabili in gioco, permettendo agli amministratori di concentrarsi sulle applicazioni piuttosto che sul sistema operativo. L'integrazione con Proxmox, supportata da VirtIO e dalle System Extensions, fornisce il perfetto equilibrio tra la potenza della virtualizzazione e l'agilità del Cloud Native, rendendo questa configurazione un punto di riferimento per il settore degli homelab professionali e delle infrastrutture edge.

#### **Bibliografia**

1. siderolabs/talos: Talos Linux is a modern Linux distribution built for Kubernetes. \- GitHub, accesso eseguito il giorno dicembre 29, 2025, [https://github.com/siderolabs/talos](https://github.com/siderolabs/talos)  
2. Introduction to Talos, the Kubernetes OS | Yet another enthusiast blog\!, accesso eseguito il giorno dicembre 29, 2025, [https://blog.yadutaf.fr/2024/03/14/introduction-to-talos-kubernetes-os/](https://blog.yadutaf.fr/2024/03/14/introduction-to-talos-kubernetes-os/)  
3. Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno dicembre 29, 2025, [https://docs.siderolabs.com/talos/v1.7/overview/what-is-talos](https://docs.siderolabs.com/talos/v1.7/overview/what-is-talos)  
4. Customizing Talos with Extensions \- A cup of coffee, accesso eseguito il giorno dicembre 29, 2025, [https://a-cup-of.coffee/blog/talos-ext/](https://a-cup-of.coffee/blog/talos-ext/)  
5. Architecture \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno dicembre 29, 2025, [https://docs.siderolabs.com/talos/v1.9/learn-more/architecture](https://docs.siderolabs.com/talos/v1.9/learn-more/architecture)  
6. Talos with Kubernetes on Proxmox | Secsys, accesso eseguito il giorno dicembre 29, 2025, [https://secsys.pages.dev/posts/talos/](https://secsys.pages.dev/posts/talos/)  
7. Using Talos Linux and Kubernetes bootstrap on OpenStack \- Safespring, accesso eseguito il giorno dicembre 29, 2025, [https://www.safespring.com/blogg/2025/2025-03-talos-linux-on-openstack/](https://www.safespring.com/blogg/2025/2025-03-talos-linux-on-openstack/)  
8. Proxmox \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno dicembre 29, 2025, [https://docs.siderolabs.com/talos/v1.9/platform-specific-installations/virtualized-platforms/proxmox](https://docs.siderolabs.com/talos/v1.9/platform-specific-installations/virtualized-platforms/proxmox)  
9. Creating a Kubernetes Cluster With Talos Linux on Tailscale | Josh ..., accesso eseguito il giorno dicembre 29, 2025, [https://joshrnoll.com/creating-a-kubernetes-cluster-with-talos-linux-on-tailscale/](https://joshrnoll.com/creating-a-kubernetes-cluster-with-talos-linux-on-tailscale/)  
10. Talos on Proxmox, accesso eseguito il giorno dicembre 29, 2025, [https://homelab.casaursus.net/talos-on-proxmox-3/](https://homelab.casaursus.net/talos-on-proxmox-3/)  
11. Talos ProxMox \- k8s development \- GitLab, accesso eseguito il giorno dicembre 29, 2025, [https://gitlab.com/k8s\_development/talos-proxmox](https://gitlab.com/k8s_development/talos-proxmox)  
12. Getting Started \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno dicembre 29, 2025, [https://docs.siderolabs.com/talos/v1.9/getting-started/getting-started](https://docs.siderolabs.com/talos/v1.9/getting-started/getting-started)  
13. Upgrade Talos Linux and Kubernetes | Eric Daly's Blog, accesso eseguito il giorno dicembre 29, 2025, [https://blog.dalydays.com/post/kubernetes-talos-upgrades/](https://blog.dalydays.com/post/kubernetes-talos-upgrades/)  
14. Production Clusters \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno dicembre 29, 2025, [https://docs.siderolabs.com/talos/v1.7/getting-started/prodnotes](https://docs.siderolabs.com/talos/v1.7/getting-started/prodnotes)  
15. How to Deploy a Kubernetes Cluster on Talos Linux \- HOSTKEY, accesso eseguito il giorno dicembre 29, 2025, [https://hostkey.com/blog/102-setting-up-a-k8s-cluster-on-talos-linux/](https://hostkey.com/blog/102-setting-up-a-k8s-cluster-on-talos-linux/)  
16. “ServiceLB” with cilium on Talos Linux | by Stefan Le Breton | Dev Genius, accesso eseguito il giorno dicembre 29, 2025, [https://blog.devgenius.io/servicelb-with-cilium-on-talos-linux-8a290d524cb7](https://blog.devgenius.io/servicelb-with-cilium-on-talos-linux-8a290d524cb7)  
17. Kubernetes & Talos \- Reddit, accesso eseguito il giorno dicembre 29, 2025, [https://www.reddit.com/r/kubernetes/comments/1hs6bui/kubernetes\_talos/](https://www.reddit.com/r/kubernetes/comments/1hs6bui/kubernetes_talos/)  
18. Installing Cilium and Multus on Talos OS for Advanced Kubernetes Networking, accesso eseguito il giorno dicembre 29, 2025, [https://www.itguyjournals.com/installing-cilium-and-multus-on-talos-os-for-advanced-kubernetes-networking/](https://www.itguyjournals.com/installing-cilium-and-multus-on-talos-os-for-advanced-kubernetes-networking/)  
19. Deploy Cilium CNI \- Sidero Documentation, accesso eseguito il giorno dicembre 29, 2025, [https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)  
20. Install in eBPF mode \- Calico Documentation \- Tigera.io, accesso eseguito il giorno dicembre 29, 2025, [https://docs.tigera.io/calico/latest/operations/ebpf/install](https://docs.tigera.io/calico/latest/operations/ebpf/install)  
21. Validating Talos Linux Install and Maintenance Operations \- Safespring, accesso eseguito il giorno dicembre 29, 2025, [https://www.safespring.com/blogg/2025/2025-04-validating-talos-linux-install/](https://www.safespring.com/blogg/2025/2025-04-validating-talos-linux-install/)  
22. Virtual (shared) IP \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno dicembre 29, 2025, [https://docs.siderolabs.com/talos/v1.8/networking/vip](https://docs.siderolabs.com/talos/v1.8/networking/vip)  
23. kube-vip: Documentation, accesso eseguito il giorno dicembre 29, 2025, [https://kube-vip.io/](https://kube-vip.io/)  
24. Kubernetes Load-Balancer service | kube-vip, accesso eseguito il giorno dicembre 29, 2025, [https://kube-vip.io/docs/usage/kubernetes-services/](https://kube-vip.io/docs/usage/kubernetes-services/)  
25. Qemu-guest-agent \- Proxmox VE, accesso eseguito il giorno dicembre 29, 2025, [https://pve.proxmox.com/wiki/Qemu-guest-agent](https://pve.proxmox.com/wiki/Qemu-guest-agent)  
26. Upgrading Talos Linux \- Sidero Documentation, accesso eseguito il giorno dicembre 29, 2025, [https://docs.siderolabs.com/talos/v1.8/configure-your-talos-cluster/lifecycle-management/upgrading-talos](https://docs.siderolabs.com/talos/v1.8/configure-your-talos-cluster/lifecycle-management/upgrading-talos)  
27. omni-docs/tutorials/upgrading-clusters.md at main \- GitHub, accesso eseguito il giorno dicembre 29, 2025, [https://github.com/siderolabs/omni-docs/blob/main/tutorials/upgrading-clusters.md](https://github.com/siderolabs/omni-docs/blob/main/tutorials/upgrading-clusters.md)  
28. Talos OS \- Documentation & FAQ \- HOSTKEY, accesso eseguito il giorno dicembre 29, 2025, [https://hostkey.com/documentation/marketplace/kubernetes/talos/](https://hostkey.com/documentation/marketplace/kubernetes/talos/)