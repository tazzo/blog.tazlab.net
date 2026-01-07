+++
title = "Proxmox Virtual Environment: Architettura, Implementazione e Analisi Comparativa verso il Cloud Pubblico"
date = 2026-01-07
draft = false
description = "Un'analisi approfondita di Proxmox VE, dall'architettura alla configurazione avanzata, confrontata con le soluzioni cloud pubbliche."
tags = ["proxmox", "virtualization", "hypervisor", "kvm", "lxc", "cloud"]
author = "Tazzo"
+++

L’evoluzione delle infrastrutture digitali ha reso la virtualizzazione un elemento cardine non solo per i grandi data center aziendali, ma anche per i contesti di ricerca e i laboratori domestici (home lab). Proxmox Virtual Environment (VE) si distingue in questo panorama come una piattaforma di gestione della virtualizzazione di classe enterprise, completamente open-source, che integra in un’unica soluzione l'hypervisor KVM (Kernel-based Virtual Machine) e i container basati su LXC (Linux Containers).1 Questa trattazione esplora in profondità ogni aspetto della piattaforma, partendo dai concetti fondamentali fino alle configurazioni avanzate per la messa in produzione, fornendo al contempo un’analisi critica rispetto ai giganti del cloud pubblico come Amazon Web Services (AWS) e Google Cloud Platform (GCP).

## **Capitolo 1: Fondamenti e Architettura di Sistema**

Proxmox VE è un hypervisor di tipo 1, definito "bare metal", poiché viene installato direttamente sull'hardware fisico senza la necessità di un sistema operativo sottostante preesistente.1 Questa architettura garantisce che le risorse della macchina — CPU, RAM, storage e connettività di rete — siano gestite direttamente dal software di virtualizzazione, riducendo drasticamente l'overhead e migliorando le prestazioni complessive.1

### **Il Kernel e la Base Debian**

La stabilità di Proxmox deriva dalla sua base Debian GNU/Linux, su cui viene applicato un kernel modificato per supportare le funzioni critiche di virtualizzazione e clustering.3 L'integrazione con Debian permette a Proxmox di beneficiare di un vasto ecosistema di pacchetti e di una gestione degli aggiornamenti tramite lo strumento APT (Advanced Package Tool), rendendo la manutenzione del sistema familiare per gli amministratori Linux.4

### **I Pilastri della Gestione: pveproxy e pvedaemon**

Il funzionamento di Proxmox è orchestrato da una serie di servizi specializzati che lavorano in concerto per offrire un'interfaccia di gestione fluida. Il servizio pveproxy funge da interfaccia web, operando sulla porta 8006 tramite protocollo HTTPS.1 Questo componente agisce come il punto di ingresso principale per l'utente, permettendo il controllo totale del datacenter tramite browser.1

Il pvedaemon, invece, rappresenta il motore operativo che esegue i comandi impartiti dall'utente, come la creazione di macchine virtuali o la modifica delle impostazioni di rete.1 In un ambiente cluster, entra in gioco pve-cluster, un servizio che mantiene sincronizzate le configurazioni tra i nodi utilizzando un file system a cluster (pmxcfs).1 Questa architettura assicura che, qualora un amministratore apporti una modifica su un nodo, tale informazione sia istantaneamente disponibile in tutto il cluster, garantendo l'integrità operativa.1

| Componente | Funzione Principale | Dipendenze |
| :---- | :---- | :---- |
| **KVM** | Hypervisor per virtualizzazione completa | Estensioni CPU (Intel VT-x / AMD-V) |
| **LXC** | Virtualizzazione leggera tramite container | Condivisione kernel host |
| **QEMU** | Emulazione hardware per VM | KVM per accelerazione |
| **pveproxy** | Server interfaccia Web (Porta 8006\) | Certificati SSL |
| **pvedaemon** | Esecuzione task amministrativi | API di sistema |
| **pve-cluster** | Sincronizzazione multi-nodo | Corosync (Porte 5404/5405) |

1

## **Capitolo 2: Tecnologie di Virtualizzazione: KVM vs LXC**

La forza distintiva di Proxmox risiede nella sua capacità di offrire due tecnologie di virtualizzazione complementari sotto lo stesso tetto, permettendo agli amministratori di scegliere lo strumento più adatto in base al carico di lavoro specifico.1

### **KVM e QEMU: Virtualizzazione Completa**

Il binomio KVM/QEMU rappresenta la soluzione per la virtualizzazione completa. In questo scenario, ogni macchina virtuale si comporta come un computer fisico indipendente, dotato di un proprio BIOS/UEFI e di un kernel del sistema operativo autonomo.1 QEMU si occupa dell'emulazione dei componenti hardware — come controller disco, schede di rete e schede video — mentre KVM sfrutta le capacità hardware della CPU per eseguire il codice ospite a velocità quasi nativa.1

Questa tecnologia è indispensabile per eseguire sistemi operativi non Linux, come Microsoft Windows, o istanze Linux che richiedono kernel personalizzati o un isolamento totale per ragioni di sicurezza.1 Tuttavia, la virtualizzazione completa comporta un costo in termini di risorse: ogni VM richiede una porzione dedicata di RAM e CPU che non può essere facilmente condivisa con altre istanze, rendendola meno efficiente per servizi leggeri.1

### **LXC: Efficienza e Velocità dei Container**

I Linux Containers (LXC) offrono un approccio radicalmente diverso. Invece di emulare l'hardware, LXC isola i processi all'interno dell'ambiente host, condividendo il kernel del sistema operativo Proxmox.1 Questo elimina la necessità di avviare un intero kernel per ogni applicazione, riducendo i tempi di boot a pochi secondi e abbattendo drasticamente l'uso di memoria e CPU.1

I container sono ideali per eseguire servizi Linux standard, come server web Nginx, database o istanze Docker annidate. La limitazione principale risiede nella compatibilità: un container può eseguire solo distribuzioni Linux e non può avere un kernel differente da quello dell'host.1 Nonostante ciò, per carichi di lavoro scalabili, LXC rappresenta la scelta d'elezione per ottimizzare la densità di servizi su un singolo mini PC.1

### **Analisi delle Performance: Casi di Studio**

Studi comparativi indicano che LXC tende a superare KVM in compiti ad alta intensità di CPU e memoria, grazie al minor overhead.8 Tuttavia, sono stati rilevati casi anomali: in alcuni test relativi a carichi di lavoro Java o Elasticsearch, le VM KVM hanno mostrato prestazioni superiori rispetto agli LXC o addirittura all'hardware bare metal.9 Questo fenomeno è spesso attribuito a come il kernel ospite della VM gestisce la pianificazione dei processi e la cache della memoria in modo più aggressivo rispetto a quanto farebbe un processo isolato in un container, suggerendo che per applicazioni specifiche sia necessaria una validazione empirica prima della scelta definitiva.9

| Caratteristica | KVM (Virtual Machine) | LXC (Container) |
| :---- | :---- | :---- |
| **Isolamento** | Hardware (Massimo) | Processo (Elevato) |
| **Kernel** | Indipendente | Condiviso con l'host |
| **Sistemi Operativi** | Windows, Linux, BSD, ecc. | Solo Linux |
| **Tempo di Avvio** | 30-60 secondi | 1-5 secondi |
| **Uso RAM** | Riservata e fissa | Dinamica e condivisa |
| **Overhead** | Moderato | Minimo |

1

## **Capitolo 3: Lo Stack di Storage: Prestazioni e Integrità**

La gestione dei dati in Proxmox è estremamente flessibile, supportando sia storage locale che distribuito. Per un utente homelab su un mini PC, la scelta tra ZFS e LVM è determinante per le prestazioni e la longevità dell'hardware.10

### **ZFS: Il Gold Standard per l'Integrità**

ZFS è molto più di un semplice file system; è un gestore di volumi logici con funzionalità avanzate di protezione dei dati.10 La caratteristica più rilevante è il checksumming end-to-end, che permette di rilevare e correggere automaticamente la corruzione dei dati silente (bit rot).10 ZFS eccelle nella gestione degli snapshot e nella replicazione nativa, permettendo di sincronizzare i dischi delle VM tra diversi nodi Proxmox in pochi minuti.10

Tuttavia, ZFS è esigente in termini di risorse. Richiede l'accesso diretto ai dischi (HBA mode), rendendolo incompatibile con i controller RAID hardware tradizionali che dovrebbero essere evitati.10 Inoltre, ZFS utilizza la RAM come cache di lettura (ARC), raccomandando almeno 8-16 GB di memoria di sistema per operare in modo ottimale.10

### **LVM e LVM-Thin: Velocità e Semplicità**

LVM (Logical Volume Manager) è l'opzione tradizionale per la gestione dei dischi in Linux. Proxmox implementa LVM-Thin per permettere il "thin provisioning", ovvero la possibilità di allocare virtualmente più spazio di quello fisicamente disponibile.10 LVM è estremamente veloce e ha un overhead di CPU e RAM quasi nullo, rendendolo ideale per mini PC con processori economici o poca memoria.10 Il rovescio della medaglia è la mancanza di protezione contro il bit rot e l'assenza di replicazione nativa tra i nodi del cluster.10

### **Storage Distribuito: Ceph e Shared Storage**

Per le configurazioni multi-nodo più ambiziose, Proxmox integra Ceph, un sistema di storage distribuito che trasforma i dischi locali di più server in un unico pool di archiviazione ridondante e altamente disponibile.11 Sebbene Ceph sia considerato lo standard per la produzione enterprise, la sua implementazione su mini PC richiede cautela: sono necessari almeno tre nodi (meglio cinque) e reti veloci (almeno 10GbE) per evitare colli di bottiglia e latenze inaccettabili.11

| Tipo Storage | Tipo | Snapshot | Replicazione | Ridondanza |
| :---- | :---- | :---- | :---- | :---- |
| **ZFS** | Locale/Soft RAID | Sì | Sì | Software RAID |
| **LVM-Thin** | Locale | Sì | No | No (Richiede Hardware RAID) |
| **Ceph** | Distribuito | Sì | Sì | Replica tra nodi |
| **NFS / iSCSI** | Condiviso (NAS) | Dipende dal backend | No | Gestita dal NAS |

10

## **Capitolo 4: Networking e Segmentazione della Rete**

La configurazione della rete in Proxmox si basa sull'astrazione dei componenti fisici in bridge virtuali, permettendo una gestione granulare del traffico tra le VM e il mondo esterno.16

### **Linux Bridge e Naming Convention**

Al momento dell'installazione, Proxmox crea un bridge predefinito chiamato vmbr0, che viene collegato alla scheda di rete fisica principale.1 Le moderne installazioni utilizzano nomi di interfaccia predittivi (come eno1 o enp0s3), che evitano cambiamenti di nome dovuti ad aggiornamenti del kernel o modifiche hardware.16 È possibile personalizzare questi nomi creando file .link in /etc/systemd/network/ per garantire una coerenza totale nelle configurazioni multi-nodo.16

### **VLAN-Aware Bridge: La Guida alla Segmentazione**

Per isolare il traffico in un home lab (ad esempio, separando le telecamere IP dai server di produzione), la tecnica consigliata è l'uso di bridge "VLAN-aware".17 Invece di creare un bridge separato per ogni VLAN, un singolo bridge può gestire tag 802.1Q multipli. Una volta abilitata l'opzione nelle impostazioni del bridge, è sufficiente specificare il "VLAN Tag" nell'hardware di rete della VM.17

Questo approccio offre diversi vantaggi:

* **Semplicità:** Riduce la complessità dei file di configurazione /etc/network/interfaces.17  
* **Flessibilità:** Permette di cambiare la rete di una VM senza dover modificare l'infrastruttura di rete dell'host.17  
* **Sicurezza:** Abbinato a un firewall, impedisce il movimento laterale tra zone di sicurezza diverse.17

### **Il Ruolo di OpenVSwitch (OVS)**

Per scenari di networking ancora più complessi, Proxmox supporta OpenVSwitch, uno switch virtuale multistrato progettato per operare in ambienti cluster su larga scala.19 OVS offre funzionalità avanzate di monitoraggio e gestione, ma richiede un'installazione separata (apt install openvswitch-switch) e una configurazione manuale che può risultare superflua per la maggior parte dei piccoli laboratori.19

## **Capitolo 5: Dal Laboratorio alla Produzione: Manutenzione e Aggiornamenti**

Trasformare un'installazione sperimentale in un sistema pronto per la produzione richiede il passaggio a pratiche di gestione più rigorose, specialmente per quanto riguarda la sicurezza e l'integrità del software.21

### **Gestione dei Repository: Enterprise vs No-Subscription**

Proxmox offre diversi canali per gli aggiornamenti. Di default, il sistema è configurato con il repository "Enterprise", che garantisce pacchetti estremamente stabili e testati, ma richiede una sottoscrizione a pagamento.3 Per gli utenti che non necessitano del supporto ufficiale, il repository "No-Subscription" è la scelta corretta.4

Per passare al repository gratuito su Proxmox 8, è necessario modificare i file in /etc/apt/sources.list.d/. La procedura corretta prevede di commentare il repository enterprise e aggiungere la riga per il no-subscription, assicurandosi di includere anche il repository corretto per Ceph (anche se non utilizzato direttamente, alcuni pacchetti sono necessari) per evitare errori durante l'aggiornamento.5

**Esempio di configurazione per Proxmox 8 (Bookworm):**

Bash

\# Disabilitare Enterprise  
sed \-i 's/^deb/\#deb/' /etc/apt/sources.list.d/pve-enterprise.list

\# Aggiungere No-Subscription  
cat \> /etc/apt/sources.list.d/pve-no-subscription.list \<\< EOF  
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription  
EOF

È fondamentale utilizzare sempre il comando apt dist-upgrade invece di apt upgrade per assicurarsi che i nuovi pacchetti del kernel e le dipendenze strutturali di Proxmox siano installati correttamente.21

### **Hardening e Sicurezza dell'Accesso**

La sicurezza di un sistema in produzione inizia dall'accesso amministrativo. Si raccomanda di:

* **Disabilitare il login root via SSH:** Utilizzare utenti non privilegiati dotati di sudo.22  
* **Implementare il 2FA:** Proxmox supporta nativamente TOTP e WebAuthn per l'accesso alla GUI.6  
* **Certificati SSL:** Sostituire il certificato auto-firmato con uno emesso da Let's Encrypt tramite il protocollo ACME integrato.24

La configurazione ACME può essere effettuata direttamente dalla GUI sotto Datacenter \> ACME. Se il Proxmox non è esposto pubblicamente, è possibile utilizzare le sfide DNS tramite plugin per fornitori come Cloudflare o DuckDNS, permettendo l'ottenimento di certificati validi anche in reti locali isolate.25

## **Capitolo 6: Strategie di Backup con Proxmox Backup Server (PBS)**

Un sistema senza un piano di backup non può essere considerato "in produzione". Proxmox ha rivoluzionato questo aspetto con il lancio di Proxmox Backup Server (PBS), una soluzione dedicata che si integra perfettamente con Proxmox VE.28

### **Deduplicazione e Integrità dei Dati**

A differenza dei backup tradizionali (basati su file .vzdump), PBS opera a livello di blocchi. Questo significa che se dieci macchine virtuali eseguono lo stesso sistema operativo Linux, i blocchi di dati identici vengono salvati una sola volta sul server di backup.28 I vantaggi sono molteplici:

* **Risparmio di spazio:** Riduzione dello storage necessario anche del 90% in ambienti omogenei.29  
* **Velocità:** I backup incrementali trasferiscono solo i blocchi modificati, riducendo i tempi di esecuzione da ore a minuti.28  
* **Verifica:** PBS permette di programmare controlli periodici dell'integrità (Garbage Collection e Verification) per assicurarsi che i dati non siano corrotti.28

### **Implementazione di PBS**

PBS può essere installato su hardware bare metal dedicato o, per test, come VM (anche se non raccomandato per la produzione reale dei backup critici dell'host che lo ospita).28 Una configurazione tipica prevede un programma di manutenzione rigoroso:

* **Pruning:** Rimozione automatica dei vecchi backup in base a regole di conservazione (es. mantenere 7 giornalieri, 4 settimanali).28  
* **Garbage Collection:** Liberazione dello spazio fisico sul disco dopo che i blocchi sono stati marcati per la cancellazione dal pruning.28

| Operazione | Orario Consigliato | Scopo |
| :---- | :---- | :---- |
| **Backup VM** | 02:00 | Copia dati degli ospiti |
| **Pruning** | 03:00 | Applicazione policy conservazione |
| **Garbage Collection** | 03:30 | Recupero spazio fisico |
| **Verification** | 05:00 | Controllo integrità blocchi |

31

## **Capitolo 7: Ottimizzazione per Mini PC e Risparmio Energetico**

I mini PC sono popolari per gli home lab grazie al loro basso consumo, ma Proxmox è configurato di default per massimizzare le prestazioni, il che può portare a temperature elevate e sprechi energetici.32

### **CPU Governor: Powersave vs Performance**

Di default, Proxmox imposta il governor della CPU su performance, forzando i core alla massima frequenza.33 Per i mini PC, è consigliabile cambiare questa impostazione in powersave. Contrariamente al nome, nei processori moderni (specialmente Intel Core i5/i7 recenti), il governor powersave permette comunque alla CPU di accelerare istantaneamente sotto carico, ma la fa scendere a frequenze minime in idle, risparmiando anche 40-50W per nodo.33

È possibile automatizzare questo cambiamento aggiungendo un comando al crontab dell'host:

Bash

@reboot echo "powersave" | tee /sys/devices/system/cpu/cpu\*/cpufreq/scaling\_governor \>/dev/null 2\>&1

Questo garantisce che l'impostazione persista dopo ogni riavvio.33

### **Gestione Energetica Avanzata: Powertop e ASPM**

Per ottimizzare ulteriormente il consumo, è possibile utilizzare strumenti come powertop per identificare i componenti che impediscono alla CPU di entrare negli stati di risparmio energetico profondi (C-states).32 Spesso, l'abilitazione dell'ASPM (Active State Power Management) nel BIOS o tramite parametri del kernel può dimezzare il consumo in idle dei mini PC dotati di NIC Intel o Realtek.33

### **Criticità del Passthrough Hardware**

Una sfida comune nei mini PC è il passthrough hardware, ad esempio passare un controller SATA o una iGPU a una VM specifica. È stato documentato che su alcuni modelli (come gli Aoostar), il passaggio del controller SATA può disabilitare le funzioni di gestione termica e di boosting della CPU dell'host, poiché il controller è integrato direttamente nel SoC.37 In questi casi, l'host perde la capacità di leggere i sensori di temperatura e, per protezione, blocca la CPU alla frequenza base, degradando le prestazioni generali.37

## **Capitolo 8: Clustering e Alta Affidabilità (HA)**

Sebbene Proxmox possa operare come nodo singolo, la sua vera potenza emerge in una configurazione cluster.

### **La Scienza del Quorum**

In un cluster Proxmox, la stabilità è garantita dal concetto di "quorum". Ogni nodo ha un voto e, affinché il cluster sia operativo, deve essere presente la maggioranza dei voti (50% \+ 1).38 Con due soli nodi, se uno fallisce, il cluster perde il quorum e i servizi si bloccano per evitare il fenomeno del "split-brain".15

La soluzione ottimale è un cluster a tre nodi.38 Se non si dispone di tre mini PC identici, è possibile utilizzare un "Quorum Device" (QDevice). Un QDevice può essere un'istanza minima di Linux eseguita su un Raspberry Pi o persino in una piccola VM su un altro hardware, che fornisce il terzo voto necessario per mantenere il quorum in un setup a due nodi principali.15

### **Live Migration e HA**

Con uno storage condiviso (come un NAS via NFS) o tramite la replicazione ZFS, è possibile eseguire la "Live Migration" delle macchine virtuali da un host all'altro senza interruzioni di servizio.13 In caso di guasto hardware di un nodo, il gestore di alta affidabilità (HA Manager) di Proxmox rileverà l'assenza del nodo e riavvierà automaticamente le VM sugli host superstiti, minimizzando i tempi di fermo.15

## **Capitolo 9: Proxmox vs. Cloud Pubblico (AWS e GCP)**

Molti utenti si chiedono perché gestire un proprio server Proxmox invece di utilizzare servizi pronti all'uso come AWS o GCP. La risposta risiede in un equilibrio tra costi, controllo e apprendimento.

### **Analisi dei Costi (TCO)**

AWS e GCP utilizzano un modello "pay-as-you-go" che può apparire economico inizialmente, ma i costi scalano rapidamente.40 Per un'istanza con 8 GB di RAM e 2 vCPU, il costo nel cloud può aggirarsi intorno ai 50-70 euro al mese.42 Un mini PC di fascia media per un home lab costa circa 300-500 euro; l'investimento iniziale si ripaga quindi in meno di un anno di utilizzo continuo.42 Inoltre, il cloud addebita costi per il traffico dati in uscita (egress), mentre nel proprio laboratorio l'unico limite è la larghezza di banda della propria connessione internet.45

### **Privacy e Sovranità dei Dati**

Proxmox offre una privacy totale. I dati risiedono fisicamente nel mini PC dell'utente, non su server di terze parti soggetti a normative straniere o cambiamenti delle policy aziendali.44 Questo è fondamentale per la gestione di dati sensibili, backup personali o per chi desidera evitare il "vendor lock-in".2

### **Complessità Operativa e Learning Curve**

AWS e GCP offrono migliaia di servizi gestiti (database, IA, networking globale) che Proxmox non può replicare facilmente.40 Tuttavia, imparare Proxmox significa comprendere i fondamenti dell'IT: hypervisor, file system, networking Linux e sicurezza di rete.1 Queste sono competenze universali che rimangono valide indipendentemente dal cloud provider utilizzato in futuro.38

| Dimensione | Proxmox VE | AWS / GCP |
| :---- | :---- | :---- |
| **Controllo Hardware** | Totale | Nessuno |
| **Costi Egress** | Zero | Elevati |
| **Manutenzione** | Utente (Self-managed) | Provider (Managed) |
| **Integrazione IA/ML** | Manuale | Servizi nativi (Vertex AI, SageMaker) |
| **Scalabilità** | Hardware limitato | Virtualmente infinita |
| **Proprietà dei Dati** | Utente | Fornitore del servizio |

40

## **Capitolo 10: Conclusioni e Roadmap per l'Utente**

Proxmox VE rappresenta il perfetto ponte tra la sperimentazione domestica e l'affidabilità professionale. Per un utente che parte da zero con un mini PC, il percorso verso la produzione segue tappe precise che trasformano un semplice hobby in un'infrastruttura resiliente.

La forza di questa piattaforma non risiede solo nelle sue capacità tecniche — come la velocità dei container LXC o l'integrità di ZFS — ma nella sua comunità e nella sua natura aperta. Mentre il cloud pubblico continuerà a dominare gli scenari di scala globale e le applicazioni "cloud-native", Proxmox rimane la scelta d'elezione per chiunque cerchi indipendenza tecnologica, efficienza economica e un controllo granulare sul proprio ambiente digitale.

Implementare Proxmox oggi significa investire in un sistema che cresce con le proprie esigenze, passando da una singola macchina a un cluster ridondante, protetto da un backup allo stato dell'arte e ottimizzato per consumare solo lo stretto necessario. Che si tratti di ospitare un server Home Assistant, un database per lo sviluppo o un'intera infrastruttura aziendale, Proxmox VE si conferma una delle soluzioni di virtualizzazione più complete e potenti disponibili sul mercato.

#### **Bibliografia**

1. Understanding the Proxmox Architecture: From ESXi to Proxmox VE 8.4 \- Dev Genius, accesso eseguito il giorno dicembre 29, 2025, [https://blog.devgenius.io/understanding-the-proxmox-architecture-from-esxi-to-proxmox-ve-8-4-0d41d300365a](https://blog.devgenius.io/understanding-the-proxmox-architecture-from-esxi-to-proxmox-ve-8-4-0d41d300365a)  
2. What Is Proxmox? Guide to Open Source Virtualization \- CloudFire Srl, accesso eseguito il giorno dicembre 29, 2025, [https://www.cloudfire.it/en/blog/proxmox-guida-virtualizzazione-open-source](https://www.cloudfire.it/en/blog/proxmox-guida-virtualizzazione-open-source)  
3. \[SOLVED\] \- Explain please pve-no-subscription | Proxmox Support Forum, accesso eseguito il giorno dicembre 29, 2025, [https://forum.proxmox.com/threads/explain-please-pve-no-subscription.102743/](https://forum.proxmox.com/threads/explain-please-pve-no-subscription.102743/)  
4. Package Repositories \- Proxmox VE, accesso eseguito il giorno dicembre 29, 2025, [https://pve.proxmox.com/wiki/Package\_Repositories](https://pve.proxmox.com/wiki/Package_Repositories)  
5. How to Setup Proxmox VE 8.4 Non-Subscription Repositories \+ ..., accesso eseguito il giorno dicembre 29, 2025, [https://ecintelligence.ma/en/blog/how-to-setup-proxmox-ve-84-non-subscription-reposi/](https://ecintelligence.ma/en/blog/how-to-setup-proxmox-ve-84-non-subscription-reposi/)  
6. Proxmox VE Port Requirements: The Complete Guide | Saturn ME, accesso eseguito il giorno dicembre 29, 2025, [https://www.saturnme.com/proxmox-ve-port-requirements-the-complete-guide/](https://www.saturnme.com/proxmox-ve-port-requirements-the-complete-guide/)  
7. Firewall Ports Cluster Configuration \- Proxmox Support Forum, accesso eseguito il giorno dicembre 29, 2025, [https://forum.proxmox.com/threads/firewall-ports-cluster-configuration.16210/](https://forum.proxmox.com/threads/firewall-ports-cluster-configuration.16210/)  
8. Proxmox VE: Performance of KVM vs. LXC \- IKUS, accesso eseguito il giorno dicembre 29, 2025, [https://ikus-soft.com/en\_CA/blog/techies-10/proxmox-ve-performance-of-kvm-vs-lxc-75](https://ikus-soft.com/en_CA/blog/techies-10/proxmox-ve-performance-of-kvm-vs-lxc-75)  
9. Performance of LXC vs KVM \- Proxmox Support Forum, accesso eseguito il giorno dicembre 29, 2025, [https://forum.proxmox.com/threads/performance-of-lxc-vs-kvm.43170/](https://forum.proxmox.com/threads/performance-of-lxc-vs-kvm.43170/)  
10. Choosing the Right Proxmox Local Storage Format: ZFS vs LVM \- Instelligence, accesso eseguito il giorno dicembre 29, 2025, [https://www.instelligence.io/blog/2025/08/choosing-the-right-proxmox-local-storage-format-zfs-vs-lvm/](https://www.instelligence.io/blog/2025/08/choosing-the-right-proxmox-local-storage-format-zfs-vs-lvm/)  
11. Proxmox VE Storage Options: Comprehensive Comparison Guide \- Saturn ME, accesso eseguito il giorno dicembre 29, 2025, [https://www.saturnme.com/proxmox-ve-storage-options-comprehensive-comparison-guide/](https://www.saturnme.com/proxmox-ve-storage-options-comprehensive-comparison-guide/)  
12. \[SOLVED\] \- Performance comparison between ZFS and LVM \- Proxmox Support Forum, accesso eseguito il giorno dicembre 29, 2025, [https://forum.proxmox.com/threads/performance-comparison-between-zfs-and-lvm.124295/](https://forum.proxmox.com/threads/performance-comparison-between-zfs-and-lvm.124295/)  
13. Proxmox with Local M.2 Storage: The Best Storage & Backup Strategy (No Ceph Needed), accesso eseguito il giorno dicembre 29, 2025, [https://www.detectx.com.au/proxmox-with-local-m-2-storage-the-best-storage-backup-strategy-no-ceph-needed/](https://www.detectx.com.au/proxmox-with-local-m-2-storage-the-best-storage-backup-strategy-no-ceph-needed/)  
14. Mini PC Proxmox cluster with ceph, accesso eseguito il giorno dicembre 29, 2025, [https://forum.proxmox.com/threads/mini-pc-proxmox-cluster-with-ceph.156601/](https://forum.proxmox.com/threads/mini-pc-proxmox-cluster-with-ceph.156601/)  
15. HA Best Practice | Proxmox Support Forum, accesso eseguito il giorno dicembre 29, 2025, [https://forum.proxmox.com/threads/ha-best-practice.157253/](https://forum.proxmox.com/threads/ha-best-practice.157253/)  
16. Network Configuration \- Proxmox VE, accesso eseguito il giorno dicembre 29, 2025, [https://pve.proxmox.com/wiki/Network\_Configuration](https://pve.proxmox.com/wiki/Network_Configuration)  
17. Proxmox VLAN Configuration | Bankai-Tech Docs, accesso eseguito il giorno dicembre 29, 2025, [https://docs.bankai-tech.com/Proxmox/Docs/Networking/VLAN%20Configuration](https://docs.bankai-tech.com/Proxmox/Docs/Networking/VLAN%20Configuration)  
18. Proxmox VLAN Configuration: Linux Bridge Tagging, Management IP, and Virtual Machines, accesso eseguito il giorno dicembre 29, 2025, [https://www.youtube.com/watch?v=stQzK0p59Fc](https://www.youtube.com/watch?v=stQzK0p59Fc)  
19. Proxmox VLANs Demystified: Step-by-Step Network Isolation for Your Homelab \- Medium, accesso eseguito il giorno dicembre 29, 2025, [https://medium.com/@P0w3rChi3f/proxmox-vlan-configuration-a-step-by-step-guide-edc838cc62d8](https://medium.com/@P0w3rChi3f/proxmox-vlan-configuration-a-step-by-step-guide-edc838cc62d8)  
20. Proxmox vlan handling \- Homelab \- LearnLinuxTV Community, accesso eseguito il giorno dicembre 29, 2025, [https://community.learnlinux.tv/t/proxmox-vlan-handling/3232](https://community.learnlinux.tv/t/proxmox-vlan-handling/3232)  
21. How to Safely Update Proxmox VE: A Complete Guide \- Saturn ME, accesso eseguito il giorno dicembre 29, 2025, [https://www.saturnme.com/how-to-safely-update-proxmox-ve-a-complete-guide/](https://www.saturnme.com/how-to-safely-update-proxmox-ve-a-complete-guide/)  
22. Proxmox server hardening document for compliance, accesso eseguito il giorno dicembre 29, 2025, [https://forum.proxmox.com/threads/proxmox-server-hardening-document-for-compliance.146961/](https://forum.proxmox.com/threads/proxmox-server-hardening-document-for-compliance.146961/)  
23. \[SOLVED\] \- converting from no subscription repo to subscription \- Proxmox Support Forum, accesso eseguito il giorno dicembre 29, 2025, [https://forum.proxmox.com/threads/converting-from-no-subscription-repo-to-subscription.164060/](https://forum.proxmox.com/threads/converting-from-no-subscription-repo-to-subscription.164060/)  
24. How to Secure Your Proxmox VE Web Interface with Let's Encrypt SSL \- Skynats, accesso eseguito il giorno dicembre 29, 2025, [https://www.skynats.com/blog/how-to-secure-your-proxmox-ve-web-interface-with-lets-encrypt-ssl/](https://www.skynats.com/blog/how-to-secure-your-proxmox-ve-web-interface-with-lets-encrypt-ssl/)  
25. Automate Proxmox SSL Certificates with ACME and Dynv6, accesso eseguito il giorno dicembre 29, 2025, [https://bitingbytes.de/posts/2025/proxmox-ssl-certificate-with-dynv6/](https://bitingbytes.de/posts/2025/proxmox-ssl-certificate-with-dynv6/)  
26. Managing Certificates in Proxmox VE 8.1: A Step-by-Step Guide \- BDRShield, accesso eseguito il giorno dicembre 29, 2025, [https://www.bdrshield.com/blog/managing-certificates-in-proxmox-ve-8-1/](https://www.bdrshield.com/blog/managing-certificates-in-proxmox-ve-8-1/)  
27. Step-by-step guide to configure Proxmox Web GUI/API with Let's Encrypt certificate and automatic validation using the ACME protocol in DNS alias mode with DNS TXT validation redirection to Duck DNS. \- GitHub Gist, accesso eseguito il giorno dicembre 29, 2025, [https://gist.github.com/zidenis/e93532c0e6f91cb75d429f7ac7f66ba5](https://gist.github.com/zidenis/e93532c0e6f91cb75d429f7ac7f66ba5)  
28. Proxmox Backup Server, accesso eseguito il giorno dicembre 29, 2025, [https://homelab.casaursus.net/proxmox-backup-server/](https://homelab.casaursus.net/proxmox-backup-server/)  
29. Features \- Proxmox Backup Server, accesso eseguito il giorno dicembre 29, 2025, [https://www.proxmox.com/en/products/proxmox-backup-server/features](https://www.proxmox.com/en/products/proxmox-backup-server/features)  
30. How To: Proxmox Backup Server 4 (VM) Installation, accesso eseguito il giorno dicembre 29, 2025, [https://www.derekseaman.com/2025/08/how-to-proxmox-backup-server-4-vm-installation.html](https://www.derekseaman.com/2025/08/how-to-proxmox-backup-server-4-vm-installation.html)  
31. Proxmox Backup Server \- Our Home Lab, accesso eseguito il giorno dicembre 29, 2025, [https://homelab.anita-fred.net/pbs/](https://homelab.anita-fred.net/pbs/)  
32. Guide for Proxmox powersaving \- Technologie Hub Wien, accesso eseguito il giorno dicembre 29, 2025, [https://technologiehub.at/project-posts/tutorial/guide-for-proxmox-powersaving/](https://technologiehub.at/project-posts/tutorial/guide-for-proxmox-powersaving/)  
33. PSA How to configure Proxmox for lower power usage \- Home Assistant Community, accesso eseguito il giorno dicembre 29, 2025, [https://community.home-assistant.io/t/psa-how-to-configure-proxmox-for-lower-power-usage/323731](https://community.home-assistant.io/t/psa-how-to-configure-proxmox-for-lower-power-usage/323731)  
34. CPU power throttle back to save energy \- Proxmox Support Forum, accesso eseguito il giorno dicembre 29, 2025, [https://forum.proxmox.com/threads/cpu-power-throttle-back-to-save-energy.27510/](https://forum.proxmox.com/threads/cpu-power-throttle-back-to-save-energy.27510/)  
35. gaming rig to run proxmox server \- how do i lower my idle power? \- Reddit, accesso eseguito il giorno dicembre 29, 2025, [https://www.reddit.com/r/Proxmox/comments/1fwphxw/gaming\_rig\_to\_run\_proxmox\_server\_how\_do\_i\_lower/](https://www.reddit.com/r/Proxmox/comments/1fwphxw/gaming_rig_to_run_proxmox_server_how_do_i_lower/)  
36. Powersaving tutorial : r/Proxmox \- Reddit, accesso eseguito il giorno dicembre 29, 2025, [https://www.reddit.com/r/Proxmox/comments/1nultme/powersaving\_tutorial/](https://www.reddit.com/r/Proxmox/comments/1nultme/powersaving_tutorial/)  
37. WTR Pro CPU throttling \- Proxmox Support Forum, accesso eseguito il giorno dicembre 29, 2025, [https://forum.proxmox.com/threads/wtr-pro-cpu-throttling.160039/](https://forum.proxmox.com/threads/wtr-pro-cpu-throttling.160039/)  
38. How to Set Up a Proxmox Cluster for Free – Virtualization Basics \- freeCodeCamp, accesso eseguito il giorno dicembre 29, 2025, [https://www.freecodecamp.org/news/set-up-a-proxmox-cluster-virtualization-basics/](https://www.freecodecamp.org/news/set-up-a-proxmox-cluster-virtualization-basics/)  
39. Building a Highly Available (HA) two-node Home Lab on Proxmox \- Jon, accesso eseguito il giorno dicembre 29, 2025, [https://jon.sprig.gs/blog/post/2885](https://jon.sprig.gs/blog/post/2885)  
40. AWS Vs. GCP: Which Platform Offers Better Pricing? \- CloudZero, accesso eseguito il giorno dicembre 29, 2025, [https://www.cloudzero.com/blog/aws-vs-gcp/](https://www.cloudzero.com/blog/aws-vs-gcp/)  
41. AWS vs GCP vs Azure: Which Cloud Platform is Best for Mid-Size Businesses? \- Qovery, accesso eseguito il giorno dicembre 29, 2025, [https://www.qovery.com/blog/aws-vs-gcp-vs-azure](https://www.qovery.com/blog/aws-vs-gcp-vs-azure)  
42. What's the Difference Between AWS vs. Azure vs. Google Cloud? \- Coursera, accesso eseguito il giorno dicembre 29, 2025, [https://www.coursera.org/articles/aws-vs-azure-vs-google-cloud](https://www.coursera.org/articles/aws-vs-azure-vs-google-cloud)  
43. I set up a tiny PC Proxmox cluster\! : r/homelab \- Reddit, accesso eseguito il giorno dicembre 29, 2025, [https://www.reddit.com/r/homelab/comments/15gkr1r/i\_set\_up\_a\_tiny\_pc\_proxmox\_cluster/](https://www.reddit.com/r/homelab/comments/15gkr1r/i_set_up_a_tiny_pc_proxmox_cluster/)  
44. Compare Google Compute Engine vs Proxmox VE 2025 | TrustRadius, accesso eseguito il giorno dicembre 29, 2025, [https://www.trustradius.com/compare-products/google-compute-engine-vs-proxmox-ve](https://www.trustradius.com/compare-products/google-compute-engine-vs-proxmox-ve)  
45. Cloud Comparison AWS vs Azure vs GCP – Networking & Security \- Exeo, accesso eseguito il giorno dicembre 29, 2025, [https://exeo.net/en/networking-security-cloud-comparison-aws-vs-azure-vs-gcp/](https://exeo.net/en/networking-security-cloud-comparison-aws-vs-azure-vs-gcp/)  
46. AWS vs GCP: Unraveling the cloud conundrum \- Proxify, accesso eseguito il giorno dicembre 29, 2025, [https://proxify.io/articles/aws-vs-gcp](https://proxify.io/articles/aws-vs-gcp)  
47. AWS vs GCP \- Which One to Choose in 2025? \- ProjectPro, accesso eseguito il giorno dicembre 29, 2025, [https://www.projectpro.io/article/aws-vs-gcp-which-one-to-choose/477](https://www.projectpro.io/article/aws-vs-gcp-which-one-to-choose/477)  
48. AWS vs. GCP: A Developer's Guide to Picking the Right Cloud \- DEV Community, accesso eseguito il giorno dicembre 29, 2025, [https://dev.to/shrsv/aws-vs-gcp-a-developers-guide-to-picking-the-right-cloud-59a1](https://dev.to/shrsv/aws-vs-gcp-a-developers-guide-to-picking-the-right-cloud-59a1)