+++
title = "Architettura e implementazione di Tailscale su Talos Linux: Analisi tecnica e risoluzione delle criticità operative"
date = 2026-01-07
draft = false
description = "Guida tecnica all'integrazione di Tailscale con Talos Linux, coprendo le estensioni di sistema e le sfide di rete."
tags = ["talos", "tailscale", "vpn", "networking", "security", "wireguard"]
author = "Tazzo"
+++

L'evoluzione dei sistemi operativi cloud-native ha portato alla nascita di soluzioni radicalmente diverse rispetto alle distribuzioni Linux tradizionali. Talos Linux si colloca all'avanguardia di questa trasformazione, proponendo un modello operativo basato sull'immutabilità, l'assenza di shell interattive e una gestione interamente mediata da API.1 In questo ecosistema, l'integrazione di Tailscale, una soluzione di rete mesh basata sul protocollo WireGuard, non rappresenta una semplice installazione di software, ma un'operazione di ingegneria dei sistemi che richiede la comprensione profonda dei meccanismi di estensione del kernel e del filesystem di Talos.3 Il presente rapporto analizza le metodologie di implementazione, le strategie di configurazione dichiarativa e la risoluzione delle problematiche di rete che emergono dalla convergenza di queste due tecnologie.

## **Paradigmi operativi e architettura di Talos Linux**

Per comprendere le sfide dell'installazione di Tailscale, è necessario analizzare la struttura fondamentale di Talos Linux. A differenza delle distribuzioni generaliste, Talos non utilizza gestori di pacchetti come apt o yum.1 Il filesystem di root è montato in sola lettura e il sistema è progettato per essere effimero, con l'eccezione della partizione dedicata ai dati persistenti.3 Questo approccio elimina il problema della deriva della configurazione (configuration drift) ma impedisce l'esecuzione dei comuni script di installazione di Tailscale.1

La gestione del sistema avviene esclusivamente tramite talosctl, un'utilità CLI che comunica con le API gRPC esposte dal demone machined.3 In questo contesto, ogni componente software aggiuntivo deve essere integrato come estensione di sistema o come carico di lavoro all'interno di Kubernetes.3

| Caratteristica | Talos Linux | Distribuzioni Tradizionali |
| :---- | :---- | :---- |
| Gestione Pacchetti | Assente (Estensioni OCI) | apt, yum, zypper, pacman |
| Accesso Remoto | API gRPC (Porta 50000\) | SSH (Porta 22\) |
| Filesystem Root | Immutabile (Read-only) | Mutabile (Read-write) |
| Configurazione | Dichiarativa (YAML) | Imperativa (Script/CLI) |
| Kernel | Hardened / Minimalista | Generalista / Modulare |

L'assenza di un terminale locale e di strumenti di diagnostica standard come iproute2 o iptables accessibili direttamente dall'utente rende indispensabile l'uso di Tailscale non solo per la sicurezza della rete, ma anche come potenziale ponte per la gestione fuori banda del cluster.3

## **Il meccanismo delle estensioni di sistema**

Il metodo primario per iniettare binari come tailscaled e tailscale in Talos Linux è il sistema delle estensioni (System Extensions).9 Un'estensione di sistema è un'immagine container conforme alle specifiche OCI che contiene una struttura di file predefinita, destinata a essere sovrapposta al filesystem di root durante la fase di boot.12

### **Anatomia di un'estensione OCI**

Un'estensione valida deve contenere un file manifest.yaml alla radice, il quale definisce il nome, la versione e i requisiti di compatibilità con la versione di Talos.3 Il contenuto effettivo dei binari deve essere collocato nella directory /rootfs/usr/local/lib/containers/\<nome-estensione\>.3 Talos scansiona la directory /usr/local/etc/containers alla ricerca di definizioni di servizio in formato YAML, che descrivono come il demone machined debba avviare il processo.9

Il servizio Tailscale, quando eseguito come estensione, opera come un container privilegiato con accesso al dispositivo /dev/net/tun dell'host, essenziale per la creazione dell'interfaccia di rete virtuale.4 Poiché l'interfaccia tailscale0 deve essere disponibile per il sistema operativo host e non solo all'interno di un namespace di rete isolato, l'estensione utilizza il networking dell'host.14

### **Ciclo di vita del servizio ext-tailscale**

Quando Talos rileva la configurazione di Tailscale, registra un servizio denominato ext-tailscale.9 Questo servizio entra in uno stato di attesa finché non vengono soddisfatte le dipendenze di rete, come l'assegnazione di indirizzi IP alle interfacce fisiche e la connettività verso i gateway predefiniti.9 La telemetria di questo servizio può essere monitorata tramite il comando talosctl service ext-tailscale, che fornisce dettagli sullo stato operativo, gli eventi di restart e la salute del processo.9

## **Metodologie di installazione e generazione delle immagini**

Esistono tre percorsi principali per implementare Tailscale su un nodo Talos, ognuno con implicazioni diverse sulla manutenibilità e sulla stabilità del sistema.3

### **Utilizzo della Talos Image Factory**

La Talos Image Factory rappresenta l'approccio più moderno e consigliato.5 Si tratta di un servizio API gestito da Sidero Labs che consente di assemblare dinamicamente immagini ISO, asset PXE o immagini disco (raw) includendo estensioni certificate.3 L'utente seleziona la versione di Talos, l'architettura (amd64 o arm64) e aggiunge l'estensione siderolabs/tailscale dalla lista delle estensioni ufficiali.5

Il risultato di questa operazione è un identificativo schematico (Schematic ID).10 Questo hash garantisce che l'immagine sia riproducibile e che tutti i nodi di un cluster utilizzino l'esatta combinazione di kernel e driver.

| Piattaforma | Formato Immagine | Metodo di Distribuzione |
| :---- | :---- | :---- |
| Bare Metal | ISO / RAW | USB Flash / iDRAC / IPMI |
| Virtualizzazione (Proxmox/ESXi) | ISO | Caricamento Datastore |
| Cloud (AWS/GCP/Azure) | AMI / Disk Image | Importazione Immagine |
| Network Boot | PXE / iPXE | Server TFTP/HTTP |

L'installazione avviene fornendo l'URL dell'installer basato sullo schema nel file di configurazione della macchina, sotto la chiave machine.install.image.3 Durante il processo di installazione o aggiornamento, Talos recupera l'immagine OCI, estrae i componenti necessari e li persiste nella partizione di sistema.3

### **Installazione tramite OCI Installer su nodi esistenti**

Per i nodi già operativi, è possibile iniettare Tailscale senza rigenerare l'intero supporto di avvio fisico.3 Questo avviene modificando dinamicamente l'immagine di installazione nel MachineConfig.3 Tuttavia, questo metodo presenta un rischio: se l'immagine specificata non contiene l'estensione durante un successivo aggiornamento del sistema operativo, Tailscale verrà rimosso al riavvio.3 È quindi imperativo che lo schematic ID rimanga coerente attraverso l'intero ciclo di vita del nodo.

### **Build personalizzate tramite Imager**

In ambienti air-gapped o dove è richiesta la massima personalizzazione, gli operatori possono utilizzare l'utility imager di Sidero Labs per creare immagini offline.12 Questo strumento permette di scaricare i pacchetti necessari, includere configurazioni di rete statiche e integrare Tailscale localmente prima di produrre l'asset di boot finale.12

## **Configurazione dichiarativa e gestione delle identità**

Una volta installati i binari, Tailscale deve essere configurato per unirsi al tailnet. In Talos, questo non avviene tramite l'invocazione manuale di tailscale up, ma attraverso la risorsa ExtensionServiceConfig.3

### **Autenticazione tramite Auth Keys**

Il metodo più semplice consiste nell'uso di una chiave di autenticazione pre-generata dal pannello di controllo di Tailscale.4 Esistono diverse tipologie di chiavi, ognuna adatta a uno scenario specifico:

* **Chiavi Riutilizzabili:** Ideali per l'espansione automatica dei worker node in un cluster Kubernetes. Una singola chiave può autenticare più macchine.10  
* **Chiavi Ephemeral:** Raccomandate per i nodi Talos, in quanto garantiscono che, se un nodo viene distrutto o resettato, la sua voce venga automaticamente rimossa dal tailnet, evitando la proliferazione di nodi orfani.10  
* **Chiavi Pre-approvate:** Consentono di bypassare l'approvazione manuale dei dispositivi se il tailnet ha tale funzione abilitata.22

### **Integrazione di OAuth2 per la sicurezza avanzata**

Per installazioni di livello enterprise, l'integrazione con OAuth2 è la soluzione preferita.16 Talos Linux supporta il flusso di autenticazione OAuth2 direttamente nei parametri del kernel o nella configurazione della macchina.24 Fornendo un clientId e un clientSecret, il sistema può negoziare le proprie credenziali di accesso, riducendo la necessità di gestire chiavi di lunga durata.16

Questa configurazione viene inserita nel file YAML di patch del nodo:

YAML

apiVersion: v1alpha1  
kind: ExtensionServiceConfig  
metadata:  
  name: tailscale  
spec:  
  environment:  
    \- TS\_AUTHKEY=tskey-auth-abcdef123456  
    \- TS\_EXTRA\_ARGS=--advertise-tags=tag:talos,tag:k8s \--accept-dns=false

L'applicazione della patch avviene tramite talosctl patch mc \-p @tailscale-patch.yaml \-n \<node-ip\>, che forza il caricamento dei parametri nel demone machined e il conseguente riavvio del servizio dell'estensione.3

## **Persistenza dello stato e stabilità dell'identità**

Uno dei problemi più comuni segnalati dagli utenti è la creazione di nodi duplicati nel pannello Tailscale dopo ogni riavvio.11 Questo accade perché lo stato di Tailscale (che include la chiave privata del nodo e il certificato della macchina) è solitamente memorizzato in /var/lib/tailscale, che nelle estensioni di sistema è effimero per impostazione predefinita.6

### **Strategie di persistenza su filesystem immutabili**

In Talos Linux, la directory /var è montata su una partizione persistente che sopravvive ai riavvii e agli aggiornamenti del sistema operativo.6 Per garantire la stabilità dell'identità del nodo, è necessario configurare l'estensione affinché monti una directory host persistente.3

| Parametro di Configurazione | Valore | Scopo |
| :---- | :---- | :---- |
| TS\_STATE\_DIR | /var/lib/tailscale | Percorso per la memorizzazione della chiave del nodo |
| Mount Source | /var/lib/tailscale | Directory persistente sull'host Talos |
| Mount Destination | /var/lib/tailscale | Destinazione all'interno del container dell'estensione |
| Mount Options | bind, rw | Permette l'accesso in lettura e scrittura |

Senza questo accorgimento, ogni aggiornamento di Talos (che comporta un riavvio e la cancellazione dello stato effimero) provocherebbe la generazione di una nuova identità crittografica, rompendo le rotte statiche e le policy ACL configurate nel tailnet.11

## **Analisi dei conflitti di networking e multihoming**

L'introduzione di un'interfaccia di rete virtuale come tailscale0 su un host che gestisce già interfacce fisiche e il networking di Kubernetes (tramite CNI) può portare a conflitti di routing complessi.27

### **Il problema del binding del Kubelet e dell'API Server**

Kubernetes, per impostazione predefinita, tenta di identificare l'indirizzo IP primario del nodo per le comunicazioni interne del cluster.27 Se Tailscale viene avviato prima che l'interfaccia fisica abbia stabilito una connessione stabile, o se il Kubelet rileva l'interfaccia tailscale0 come prioritaria, potrebbe tentare di registrare il nodo con l'IP del tailnet (nell'intervallo 100.64.0.0/10).27

Questo scenario impedisce al CNI (Cilium, Flannel, ecc.) di stabilire tunnel corretti tra i pod, poiché il traffico incapsulato potrebbe tentare di transitare attraverso il tunnel Tailscale invece che sulla rete locale, causando un degrado delle prestazioni o il fallimento completo della connettività.27

Soluzione Documentata:  
La configurazione di Talos deve istruire esplicitamente il Kubelet e l'Etcd a utilizzare solo le subnet della rete locale per il traffico del cluster.27

YAML

machine:  
  kubelet:  
    nodeIP:  
      validSubnets:  
        \- 192.168.1.0/24  \# Sostituire con la propria subnet locale  
cluster:  
  etcd:  
    advertisedSubnets:  
      \- 192.168.1.0/24

Questa configurazione garantisce che, nonostante la presenza di Tailscale, il piano di controllo di Kubernetes e il traffico tra i worker rimangano sulla rete fisica, mentre Tailscale viene utilizzato esclusivamente per l'accesso remoto e la gestione.27

### **Gestione del DNS e di resolv.conf**

Tailscale tenta spesso di assumere il controllo della risoluzione DNS per abilitare MagicDNS, un servizio che permette di contattare i nodi del tailnet tramite nomi host semplici.4 In Talos Linux, il file /etc/resolv.conf è gestito in modo deterministico e le modifiche esterne vengono spesso sovrascritte.4

Molti utenti segnalano che l'attivazione di MagicDNS rompe la risoluzione dei nomi interni di Kubernetes (come kubernetes.default.svc.cluster.local).27 La raccomandazione tecnica è di disabilitare la gestione del DNS da parte di Tailscale tramite il flag \--accept-dns=false e, se necessario, configurare CoreDNS nel cluster Kubernetes affinché inoltri le query per il dominio .ts.net all'IP del resolver di Tailscale (100.100.100.100).15

## **Prestazioni, MTU e ottimizzazione del traffico**

Tailscale utilizza un valore MTU (Maximum Transmission Unit) predefinito di $1280$ byte.35 Questo valore è scelto per garantire che i pacchetti WireGuard (che aggiungono un overhead di incapsulamento) non superino l'MTU standard di $1500$ byte tipico della maggior parte delle reti Ethernet.35

### **Criticità legate alla frammentazione dei pacchetti**

In alcuni ambienti, come le connessioni DSL con PPPoE o gli hotspot cellulari, l'MTU della rete sottostante potrebbe essere inferiore a $1500$. In questi casi, un MTU di $1280$ per Tailscale potrebbe essere troppo alto, portando alla frammentazione dei pacchetti.36 Poiché WireGuard droppa silenziosamente i pacchetti frammentati per motivi di sicurezza, le sessioni TCP (come SSH o i trasferimenti di file) potrebbero apparire "congelate" o estremamente lente.35

L'esperienza degli utenti suggerisce che l'impostazione manuale dell'MTU a $1200$ può risolvere drasticamente problemi di throughput in reti problematiche.36

| Scenario di Rete | MTU Consigliato | Tecnica di Ottimizzazione |
| :---- | :---- | :---- |
| Ethernet Standard (LAN) | 1280 | Default |
| DSL / PPPoE | 1240 \- 1260 | MSS Clamping |
| Reti Mobili (LTE/5G) | 1200 \- 1240 | TS\_DEBUG\_MTU |
| Overlay su Overlay (VPN in VPN) | 1100 \- 1200 | Riduzione manuale |

Per applicare queste ottimizzazioni su Talos, è necessario utilizzare la variabile d'ambiente TS\_DEBUG\_MTU all'interno dell' ExtensionServiceConfig.36 Inoltre, per il traffico che attraversa il cluster come Subnet Router, è fondamentale implementare l'MSS Clamping tramite regole di firewalling (sebbene questo sia complesso in Talos senza estensioni specifiche per iptables o nftables).35

## **Configurazione di Subnet Router ed Exit Node su Talos**

Un nodo Talos può fungere da gateway per l'intero cluster o per la rete locale, permettendo ad altri membri del tailnet di accedere a risorse che non possono eseguire direttamente il client Tailscale (come database legacy, stampanti o i singoli Pod Kubernetes).32

### **Abilitazione dell'IP Forwarding a livello Kernel**

Il prerequisito assoluto per il funzionamento di un Subnet Router è l'abilitazione dell'inoltro dei pacchetti IP a livello di kernel.32 Mentre nelle distribuzioni standard questo si fa modificando /etc/sysctl.conf, in Talos deve essere definito nel MachineConfig.8

YAML

machine:  
  sysctls:  
    net.ipv4.ip\_forward: "1"  
    net.ipv6.conf.all.forwarding: "1"

Questa modifica richiede un riavvio del nodo (o l'applicazione a caldo tramite talosctl apply-config) affinché il kernel inizi a instradare i pacchetti tra le interfacce fisiche e l'interfaccia tailscale0.42

### **Pubblicizzazione delle rotte Pod e Service**

Per esporre i servizi Kubernetes, il nodo deve pubblicizzare le rotte corrispondenti ai CIDR del cluster.32 Ad esempio, se il Pod CIDR è 10.244.0.0/16, il comando Tailscale deve includere \--advertise-routes=10.244.0.0/16.32

È importante ricordare che la pubblicizzazione delle rotte nel comando non è sufficiente; esse devono essere approvate manualmente nel pannello di controllo di Tailscale, a meno che non siano configurati degli "Auto Approvers".32 L'uso di \--snat-subnet-routes=false è consigliato per preservare l'indirizzo IP del client originale nelle comunicazioni interne al cluster, facilitando il logging e il monitoraggio della sicurezza.32

## **Analisi comparativa: Estensione di Sistema vs Operatore Kubernetes**

Esiste un dibattito tra gli utenti su quale sia il metodo migliore per integrare Tailscale in un cluster Talos.3

### **L'approccio basato su Estensioni di Sistema**

L'estensione opera a livello di sistema operativo host. È la soluzione preferita quando l'obiettivo principale è la gestione del nodo stesso.3

* **Vantaggi:** Permette di accedere alla Talos API (porta 50000\) anche se Kubernetes non è avviato o è in crash.3 È ideale per il bootstrap iniziale del cluster su reti remote.10  
* **Svantaggi:** Richiede la gestione di chiavi e stati a livello di singolo nodo, aumentando il sovraccarico amministrativo se il cluster ha molti nodi.3

### **L'approccio basato su Tailscale Operator**

L'operatore viene installato all'interno di Kubernetes tramite Helm e gestisce Proxy Pod dedicati per ogni servizio che deve essere esposto.16

* **Vantaggi:** Integrazione nativa con Kubernetes. La creazione di un Ingress di tipo Tailscale genera automaticamente una voce nel tailnet con il nome del servizio.16 Non richiede modifiche al MachineConfig di Talos.16  
* **Svantaggi:** Non fornisce accesso alla gestione del sistema operativo host.16 Se il piano di controllo di Kubernetes fallisce, l'accesso tramite Tailscale viene interrotto.16

### **Raccomandazione per l'architettura ibrida**

Per un'infrastruttura robusta, si raccomanda l'uso di entrambi i sistemi: l'estensione di sistema su almeno un nodo di controllo (control plane) per l'accesso di emergenza e l'amministrazione tramite talosctl, e l'operatore Kubernetes per esporre le applicazioni agli utenti finali in modo scalabile e granulare.20

## **Errori comuni segnalati dagli utenti e risoluzioni documentate**

L'analisi dei thread di supporto e delle issue su GitHub evidenzia una serie di "trappole" tipiche dell'integrazione Talos-Tailscale.

### **Errore 1: Conflitti tra KubeSpan e Tailscale**

KubeSpan è la soluzione nativa di Talos per il networking mesh tra i nodi, anch'essa basata su WireGuard.6 Sebbene teoricamente compatibili, l'attivazione simultanea di entrambi può causare problemi di performance e conflitti di porte (entrambi potrebbero tentare di utilizzare la porta UDP 51820).49

Soluzione:  
Se si utilizza Tailscale per la connettività tra i nodi, KubeSpan dovrebbe essere disabilitato.49 In alternativa, è necessario configurare Tailscale per utilizzare una porta UDP diversa tramite il flag \--port o lasciare che utilizzi la negoziazione NAT dinamica.36

### **Errore 2: Rottura del networking di Portainer e altri agenti privilegiati**

Un caso specifico segnalato riguarda l'installazione di Tailscale che interrompe il funzionamento di Portainer o degli agenti di monitoraggio che si basano sulla comunicazione inter-pod.27 Questo accade quando l'agente tenta di unirsi a un cluster utilizzando l'IP di Tailscale invece dell'IP del pod, riscontrando un errore "no route to host".27

Risoluzione:  
L'errore è una conseguenza diretta del problema del multihoming discusso in precedenza. La soluzione definitiva è l'impostazione di machine.kubelet.nodeIP.validSubnets per escludere l'intervallo IP di Tailscale dalle rotte interne di Kubernetes.27

### **Errore 3: Certificati API non validi a causa di IP dinamici**

Se un nodo Talos riceve un nuovo IP dal tailnet e l'utente tenta di connettersi tramite quell'IP, talosctl potrebbe restituire un errore di validazione del certificato mTLS.30 Talos genera i certificati API includendo solo gli indirizzi IP noti al momento del bootstrap.28

Soluzione:  
È necessario aggiungere gli intervalli IP di Tailscale (o i nomi MagicDNS) alla lista dei Subject Alternative Names (SAN) nel MachineConfig.30

YAML

machine:  
  certSANs:  
    \- 100.64.0.0/10  
    \- my-node.tailnet-id.ts.net

## **Prospettive future e considerazioni finali**

L'integrazione di Tailscale su Talos Linux rappresenta la sintesi tra la sicurezza di un sistema operativo immutabile e la flessibilità di una rete mesh moderna. Nonostante le sfide iniziali legate alla configurazione dichiarativa e alla gestione del multihoming, i benefici in termini di semplicità operativa e sicurezza sono innegabili.

Le discussioni all'interno della comunità suggeriscono un interesse crescente verso la creazione di immagini Talos ancora più specializzate, che potrebbero includere Tailscale direttamente nel kernel per ridurre ulteriormente l'impronta di memoria e migliorare le prestazioni crittografiche.11 Fino ad allora, il sistema delle estensioni OCI rimane il meccanismo più robusto e flessibile per estendere le capacità di rete di Talos.9

Gli operatori che adottano questo stack devono privilegiare l'uso dell'Image Factory per garantire la riproducibilità, implementare politiche di persistenza rigorose per mantenere l'identità dei nodi e prestare particolare attenzione alla configurazione delle subnet del Kubelet per evitare conflitti di routing che potrebbero compromettere la stabilità dell'intero cluster Kubernetes.3 Con queste precauzioni, Tailscale diventa un componente invisibile ma fondamentale per l'orchestrazione di infrastrutture cloud-native sicure e resilienti.

#### **Bibliografia**

1. Talos Linux \- The Kubernetes Operating System, accesso eseguito il giorno gennaio 6, 2026, [https://www.talos.dev/](https://www.talos.dev/)  
2. siderolabs/talos: Talos Linux is a modern Linux distribution built for Kubernetes. \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/siderolabs/talos](https://github.com/siderolabs/talos)  
3. Customizing Talos with Extensions \- A cup of coffee, accesso eseguito il giorno gennaio 6, 2026, [https://a-cup-of.coffee/blog/talos-ext/](https://a-cup-of.coffee/blog/talos-ext/)  
4. Install Tailscale on Linux, accesso eseguito il giorno gennaio 6, 2026, [https://tailscale.com/kb/1031/install-linux](https://tailscale.com/kb/1031/install-linux)  
5. System Extensions \- Image Factory \- Talos Linux, accesso eseguito il giorno gennaio 6, 2026, [https://factory.talos.dev/?arch=amd64\&platform=metal\&target=metal\&version=1.7.6](https://factory.talos.dev/?arch=amd64&platform=metal&target=metal&version=1.7.6)  
6. What's New in Talos 1.8.0 \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 6, 2026, [https://docs.siderolabs.com/talos/v1.8/getting-started/what's-new-in-talos](https://docs.siderolabs.com/talos/v1.8/getting-started/what's-new-in-talos)  
7. Install talosctl \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 6, 2026, [https://docs.siderolabs.com/omni/getting-started/how-to-install-talosctl](https://docs.siderolabs.com/omni/getting-started/how-to-install-talosctl)  
8. MachineConfig \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 6, 2026, [https://docs.siderolabs.com/talos/v1.8/reference/configuration/v1alpha1/config](https://docs.siderolabs.com/talos/v1.8/reference/configuration/v1alpha1/config)  
9. Extension Services \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 6, 2026, [https://docs.siderolabs.com/talos/v1.8/build-and-extend-talos/custom-images-and-development/extension-services](https://docs.siderolabs.com/talos/v1.8/build-and-extend-talos/custom-images-and-development/extension-services)  
10. Creating a Kubernetes Cluster With Talos Linux on Tailscale | Josh Noll, accesso eseguito il giorno gennaio 6, 2026, [https://joshrnoll.com/creating-a-kubernetes-cluster-with-talos-linux-on-tailscale/](https://joshrnoll.com/creating-a-kubernetes-cluster-with-talos-linux-on-tailscale/)  
11. FR: Minimal Purpose-Built OS for Tailscale · Issue \#17761 \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/tailscale/tailscale/issues/17761](https://github.com/tailscale/tailscale/issues/17761)  
12. How to build a Talos system extension \- Sidero Labs, accesso eseguito il giorno gennaio 6, 2026, [https://www.siderolabs.com/blog/how-to-build-a-talos-system-extension/](https://www.siderolabs.com/blog/how-to-build-a-talos-system-extension/)  
13. Package tailscale \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/orgs/siderolabs/packages/container/package/tailscale](https://github.com/orgs/siderolabs/packages/container/package/tailscale)  
14. How to make Tailscale container persistant? \- ZimaOS \- IceWhale Community Forum, accesso eseguito il giorno gennaio 6, 2026, [https://community.zimaspace.com/t/how-to-make-tailscale-container-persistant/5987](https://community.zimaspace.com/t/how-to-make-tailscale-container-persistant/5987)  
15. Using Tailscale with Docker, accesso eseguito il giorno gennaio 6, 2026, [https://tailscale.com/kb/1282/docker](https://tailscale.com/kb/1282/docker)  
16. Kubernetes operator · Tailscale Docs, accesso eseguito il giorno gennaio 6, 2026, [https://tailscale.com/kb/1236/kubernetes-operator](https://tailscale.com/kb/1236/kubernetes-operator)  
17. talosctl \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 6, 2026, [https://docs.siderolabs.com/talos/v1.6/reference/cli](https://docs.siderolabs.com/talos/v1.6/reference/cli)  
18. Talos Linux Image Factory, accesso eseguito il giorno gennaio 6, 2026, [https://factory.talos.dev/](https://factory.talos.dev/)  
19. siderolabs/extensions: Talos Linux System Extensions \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/siderolabs/extensions](https://github.com/siderolabs/extensions)  
20. Deploy Talos Linux with Local VIP, Tailscale, Longhorn, MetalLB and Traefik \- Josh's Notes, accesso eseguito il giorno gennaio 6, 2026, [https://notes.joshrnoll.com/notes/deploy-talos-linux-with-local-vip-tailscale-longhorn-metallb-and-traefik/](https://notes.joshrnoll.com/notes/deploy-talos-linux-with-local-vip-tailscale-longhorn-metallb-and-traefik/)  
21. Securely handle an auth key · Tailscale Docs, accesso eseguito il giorno gennaio 6, 2026, [https://tailscale.com/kb/1595/secure-auth-key-cli](https://tailscale.com/kb/1595/secure-auth-key-cli)  
22. Auth keys · Tailscale Docs, accesso eseguito il giorno gennaio 6, 2026, [https://tailscale.com/kb/1085/auth-keys](https://tailscale.com/kb/1085/auth-keys)  
23. OAuth clients · Tailscale Docs, accesso eseguito il giorno gennaio 6, 2026, [https://tailscale.com/kb/1215/oauth-clients](https://tailscale.com/kb/1215/oauth-clients)  
24. Machine Configuration OAuth2 Authentication \- What is Talos Linux?, accesso eseguito il giorno gennaio 6, 2026, [https://docs.siderolabs.com/talos/v1.8/security/machine-config-oauth](https://docs.siderolabs.com/talos/v1.8/security/machine-config-oauth)  
25. A collection of scripts for creating and managing kubernetes clusters on talos linux \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/joshrnoll/talos-scripts](https://github.com/joshrnoll/talos-scripts)  
26. Troubleshooting guide · Tailscale Docs, accesso eseguito il giorno gennaio 6, 2026, [https://tailscale.com/kb/1023/troubleshooting](https://tailscale.com/kb/1023/troubleshooting)  
27. Tailscale on Talos os breaks Portainer : r/kubernetes \- Reddit, accesso eseguito il giorno gennaio 6, 2026, [https://www.reddit.com/r/kubernetes/comments/1izy26m/tailscale\_on\_talos\_os\_breaks\_portainer/](https://www.reddit.com/r/kubernetes/comments/1izy26m/tailscale_on_talos_os_breaks_portainer/)  
28. Production Clusters \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 6, 2026, [https://docs.siderolabs.com/talos/v1.7/getting-started/prodnotes](https://docs.siderolabs.com/talos/v1.7/getting-started/prodnotes)  
29. Issues · siderolabs/talos \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/siderolabs/talos/issues](https://github.com/siderolabs/talos/issues)  
30. Troubleshooting \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 6, 2026, [https://docs.siderolabs.com/talos/v1.9/troubleshooting/troubleshooting](https://docs.siderolabs.com/talos/v1.9/troubleshooting/troubleshooting)  
31. Split dns on talos machine config · Issue \#7287 · siderolabs/talos \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/siderolabs/talos/issues/7287](https://github.com/siderolabs/talos/issues/7287)  
32. Subnet routers · Tailscale Docs, accesso eseguito il giorno gennaio 6, 2026, [https://tailscale.com/kb/1019/subnets](https://tailscale.com/kb/1019/subnets)  
33. Configure a subnet router · Tailscale Docs, accesso eseguito il giorno gennaio 6, 2026, [https://tailscale.com/kb/1406/quick-guide-subnets](https://tailscale.com/kb/1406/quick-guide-subnets)  
34. README.md \- michaelbeaumont/k8rn \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/michaelbeaumont/k8rn/blob/main/README.md](https://github.com/michaelbeaumont/k8rn/blob/main/README.md)  
35. Slow direct connection, get better result with UDP \+ MTU tweak : r/Tailscale \- Reddit, accesso eseguito il giorno gennaio 6, 2026, [https://www.reddit.com/r/Tailscale/comments/1p5dxtq/slow\_direct\_connection\_get\_better\_result\_with\_udp/](https://www.reddit.com/r/Tailscale/comments/1p5dxtq/slow_direct_connection_get_better_result_with_udp/)  
36. PSA: Tailscale yields higher throughput if you lower the MTU \- Reddit, accesso eseguito il giorno gennaio 6, 2026, [https://www.reddit.com/r/Tailscale/comments/1ismen1/psa\_tailscale\_yields\_higher\_throughput\_if\_you/](https://www.reddit.com/r/Tailscale/comments/1ismen1/psa_tailscale_yields_higher_throughput_if_you/)  
37. Unable to lower the MTU · Issue \#8219 · tailscale/tailscale \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/tailscale/tailscale/issues/8219](https://github.com/tailscale/tailscale/issues/8219)  
38. Site-to-site networking · Tailscale Docs, accesso eseguito il giorno gennaio 6, 2026, [https://tailscale.com/kb/1214/site-to-site](https://tailscale.com/kb/1214/site-to-site)  
39. Using Tailscale and subnet routers to access legacy devices \- Ryan Freeman, accesso eseguito il giorno gennaio 6, 2026, [https://ryanfreeman.dev/writing/using-tailscale-and-subnet-routers-to-access-legacy-devices](https://ryanfreeman.dev/writing/using-tailscale-and-subnet-routers-to-access-legacy-devices)  
40. Check Linux IP Forwarding for Access Server Routing \- OpenVPN, accesso eseguito il giorno gennaio 6, 2026, [https://openvpn.net/as-docs/faq-ip-forwarding-on-linux.html](https://openvpn.net/as-docs/faq-ip-forwarding-on-linux.html)  
41. Setting loadBalancer.acceleration=native causes Cilium Status to report unexpected end of JSON input \#35873 \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/cilium/cilium/issues/35873](https://github.com/cilium/cilium/issues/35873)  
42. 2.5. Turning on Packet Forwarding | Load Balancer Administration \- Red Hat Documentation, accesso eseguito il giorno gennaio 6, 2026, [https://docs.redhat.com/en/documentation/red\_hat\_enterprise\_linux/6/html/load\_balancer\_administration/s1-lvs-forwarding-vsa](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/6/html/load_balancer_administration/s1-lvs-forwarding-vsa)  
43. Sysctl: net.ipv4.ip\_forward \- Linux Audit, accesso eseguito il giorno gennaio 6, 2026, [https://linux-audit.com/kernel/sysctl/net/net.ipv4.ip\_forward/](https://linux-audit.com/kernel/sysctl/net/net.ipv4.ip_forward/)  
44. Rootless podman without privileged flag on talos/Setting max\_user\_namespaces · Issue \#4385 \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/talos-systems/talos/issues/4385](https://github.com/talos-systems/talos/issues/4385)  
45. Set Up a Tailscale Exit Node and Subnet Router on an Ubuntu 24.04 VPS \- Onidel, accesso eseguito il giorno gennaio 6, 2026, [https://onidel.com/blog/setup-tailscale-exit-node-ubuntu](https://onidel.com/blog/setup-tailscale-exit-node-ubuntu)  
46. Configuring tailscale subnet router using a Linux box and OpnSense : r/homelab \- Reddit, accesso eseguito il giorno gennaio 6, 2026, [https://www.reddit.com/r/homelab/comments/18zds4l/configuring\_tailscale\_subnet\_router\_using\_a\_linux/](https://www.reddit.com/r/homelab/comments/18zds4l/configuring_tailscale_subnet_router_using_a_linux/)  
47. OpenZiti meets Talos Linux\!, accesso eseguito il giorno gennaio 6, 2026, [https://openziti.discourse.group/t/openziti-meets-talos-linux/2988](https://openziti.discourse.group/t/openziti-meets-talos-linux/2988)  
48. Is there a better way than system extensions to run simple commands on boot as root? · siderolabs talos · Discussion \#9857 \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/siderolabs/talos/discussions/9857](https://github.com/siderolabs/talos/discussions/9857)  
49. hcloud-talos/terraform-hcloud-talos: This repository contains a Terraform module for creating a Kubernetes cluster with Talos in the Hetzner Cloud. \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/hcloud-talos/terraform-hcloud-talos](https://github.com/hcloud-talos/terraform-hcloud-talos)  
50. How I Setup Talos Linux. My journey to building a secure… | by Pedro Chang | Medium, accesso eseguito il giorno gennaio 6, 2026, [https://medium.com/@pedrotychang/how-i-setup-talos-linux-bc2832ec87cc](https://medium.com/@pedrotychang/how-i-setup-talos-linux-bc2832ec87cc)  
51. Talos VM Setup on macOS ARM64 with QEMU \#9799 \- GitHub, accesso eseguito il giorno gennaio 6, 2026, [https://github.com/siderolabs/talos/discussions/9799](https://github.com/siderolabs/talos/discussions/9799)