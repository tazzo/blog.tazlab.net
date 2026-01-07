+++
title = "Integrazione e Ottimizzazione di MetalLB su Cluster Kubernetes Talos OS in Ambienti Proxmox Virtual Environment"
date = 2026-01-07
draft = false
description = "Implementazione di MetalLB per il bilanciamento del carico bare-metal su cluster Talos ospitati su Proxmox."
tags = ["talos", "metallb", "proxmox", "load-balancing", "networking", "kubernetes"]
author = "Tazzo"
+++

L'adozione di Kubernetes in contesti on-premise ha introdotto la necessità di gestire il bilanciamento del carico in assenza dei servizi nativi offerti dai cloud provider pubblici. In questo scenario, la combinazione di Proxmox Virtual Environment (VE) come hypervisor, Talos OS come sistema operativo per i nodi del cluster e MetalLB come soluzione per il LoadBalancer di rete, rappresenta una delle architetture più robuste, sicure ed efficienti per la gestione di carichi di lavoro moderni.1 Proxmox fornisce la flessibilità della virtualizzazione enterprise combinando KVM e LXC, mentre Talos OS ridefinisce il concetto di sistema operativo per Kubernetes, eliminando la complessità delle distribuzioni Linux tradizionali a favore di un approccio immutabile e API-driven.1 MetalLB interviene per colmare il divario critico nel networking bare-metal, consentendo ai servizi Kubernetes di tipo LoadBalancer di ricevere indirizzi IP esterni raggiungibili dalla rete locale.3

## **Analisi Architetturale del Layer di Virtualizzazione Proxmox**

La progettazione di un'infrastruttura Kubernetes su Proxmox richiede una comprensione profonda di come l'hypervisor gestisce le risorse e il networking. Proxmox si basa su concetti di networking Linux standard, utilizzando principalmente bridge virtuali (vmbr) per collegare le macchine virtuali alla rete fisica.5 Quando si pianifica l'installazione di MetalLB, la configurazione di questi bridge diventa il fondamento su cui poggia l'intera raggiungibilità dei servizi.

### **Configurazione del Networking Host**

La best practice in Proxmox prevede l'utilizzo di bridge Linux (Linux Bridge) o, in scenari più complessi, di Open vSwitch. Per la maggior parte dei deployment Kubernetes, un bridge vmbr0 configurato correttamente è sufficiente, a patto che supporti il traffico Layer 2 necessario per le operazioni di ARP (Address Resolution Protocol) di MetalLB.4 Un aspetto spesso trascurato è la necessità di gestire VLAN diverse per isolare il traffico di gestione del cluster (Corosync), il traffico delle API di Kubernetes e il traffico dei dati applicativi.5 La latenza è un fattore critico per Corosync; pertanto, si raccomanda di non saturare il bridge principale con carichi di dati pesanti che potrebbero causare instabilità nel quorum del cluster Proxmox.5

| Componente di Rete | Configurazione Ottimale | Funzione Critica |
| :---- | :---- | :---- |
| **Bridge (vmbr0)** | VLAN Aware, No IP (opzionale) | Switch virtuale principale per il traffico delle VM.5 |
| **Bonding (LACP)** | 802.3ad (se supportato dallo switch) | Ridondanza e aumento della banda passante.5 |
| **MTU** | 1500 (standard) o 9000 (Jumbo Frames) | Ottimizzazione del throughput per storage e traffico pod-to-pod.5 |
| **VirtIO Model** | Paravirtualizzazione | Massime prestazioni di rete con il minimo overhead di CPU.7 |

L'integrazione di MetalLB richiede che il bridge di Proxmox non interferisca con i pacchetti ARP gratuiti inviati dagli speaker di MetalLB per annunciare i Virtual IP (VIP). In alcuni scenari di routing avanzato, potrebbe essere necessario abilitare il proxy\_arp sull'interfaccia del bridge host per facilitare la comunicazione tra subnet diverse, sebbene questa pratica debba essere valutata attentamente per le implicazioni di sicurezza.8

## **Talos OS: L'Evoluzione del Sistema Operativo Immutabile**

Talos OS si distingue radicalmente dalle distribuzioni Linux generaliste. È un sistema operativo minimale, privo di shell, SSH e gestori di pacchetti, progettato esclusivamente per far girare Kubernetes.1 Questa riduzione della superficie di attacco, che porta il sistema ad avere solo circa 12 binari contro i consueti 1500 delle distribuzioni standard, lo rende ideale per ambienti che richiedono elevata sicurezza e manutenibilità.2 La gestione di Talos avviene interamente tramite API gRPC utilizzando il tool talosctl.2

### **Specifiche delle Macchine Virtuali per Nodi Kubernetes**

La creazione delle VM su Proxmox per ospitare Talos deve seguire requisiti tecnici rigorosi per garantire la stabilità di etcd e delle API di sistema.

| Risorsa VM | Requisito Minimo | Configurazione Consigliata |
| :---- | :---- | :---- |
| **CPU Type** | host | Abilita tutte le estensioni hardware della CPU fisica.7 |
| **Core CPU** | 2 Core | 4 Core per i nodi Control Plane.7 |
| **Memoria RAM** | 2 GB | 4-8 GB per garantire fluidità operativa e caching.7 |
| **Disk Controller** | VirtIO SCSI | Supporto per il comando TRIM e latenze ridotte.7 |
| **Storage** | 20 GB | 32 GB o superiore per log e storage locale effimero.10 |

L'uso del tipo di CPU "host" è fondamentale poiché permette a Talos di accedere alle istruzioni di virtualizzazione e crittografia avanzate del processore fisico, migliorando le prestazioni di etcd e dei processi di cifratura del traffico.7 Inoltre, l'abilitazione dell'agente QEMU nelle impostazioni della VM Proxmox consente una gestione più granulare del sistema operativo, come l'arresto pulito e la sincronizzazione dell'orologio, sebbene Talos gestisca molte di queste funzioni nativamente tramite le sue API.7

## **Implementazione di MetalLB: Teoria e Meccanismi di Rete**

MetalLB risolve il problema della raggiungibilità esterna dei servizi Kubernetes agendo come un'implementazione software di un load balancer di rete. Funziona monitorando i servizi di tipo LoadBalancer e assegnando loro un indirizzo IP da un pool configurato dall'amministratore.11 Esistono due modalità operative principali: Layer 2 (ARP/NDP) e BGP.

### **Il Funzionamento della Modalità Layer 2**

In modalità Layer 2, MetalLB utilizza il protocollo ARP per IPv4 e NDP per IPv6. Quando un IP viene assegnato a un servizio, MetalLB elegge uno dei nodi del cluster come "proprietario" di quell'IP.4 Quel nodo inizierà a rispondere alle richieste ARP per l'External-IP del servizio con il proprio indirizzo MAC fisico. Dal punto di vista della rete esterna (ad esempio, il router del laboratorio o dell'ufficio), sembra che il nodo abbia più indirizzi IP associati alla sua scheda di rete.4

Questa modalità è estremamente popolare nei laboratori domestici (home-lab) e nelle piccole imprese perché non richiede alcuna configurazione sui router esistenti; funziona su qualsiasi switch Ethernet standard.4 Tuttavia, presenta un limite strutturale: tutto il traffico in ingresso per un determinato VIP viene convogliato verso un singolo nodo. Sebbene kube-proxy provveda poi a distribuire tale traffico ai pod effettivi su altri nodi, la larghezza di banda in ingresso è limitata dalla capacità di rete del singolo nodo leader.4

### **Border Gateway Protocol (BGP) e Scalabilità**

Per ambienti di produzione con traffico elevato, la modalità BGP è la scelta d'elezione. In questo caso, ogni nodo del cluster stabilisce una sessione di peering BGP con i router dell'infrastruttura.4 Quando un servizio riceve un External-IP, MetalLB annuncia tale rotta al router. Se il router supporta ECMP (Equal-Cost Multi-Pathing), il traffico può essere distribuito equamente tra tutti i nodi che annunciano la rotta, permettendo un vero bilanciamento del carico a livello di rete e superando i limiti della modalità Layer 2\.13

L'uso di BGP su Talos richiede una configurazione attenta, specialmente se si utilizzano CNI avanzati come Cilium, che possiedono a loro volta capacità BGP.14 È fondamentale evitare conflitti tra MetalLB e il CNI, decidendo quale componente debba gestire il peering con i router fisici.15

## **Guida Pratica all'Installazione: Dal Bootstrap alla Configurazione**

Il processo di installazione inizia dopo che il cluster Talos è stato bootstrappato con successo e kubectl è operativo.

### **Preparazione di Talos: Il Patching di Sistema**

Prima di installare MetalLB, è necessario applicare alcune modifiche alla configurazione dei nodi Talos. Uno dei requisiti fondamentali di MetalLB, quando opera con kube-proxy in modalità IPVS, è l'abilitazione del parametro strictARP.16 In Talos, questo non si fa modificando una ConfigMap, ma patchando il MachineConfig.

Il file di configurazione deve includere la sezione relativa a kube-proxy per forzare l'accettazione di ARP gratuiti e gestire correttamente il routing dei VIP.16 Inoltre, se si desidera che i nodi del Control Plane partecipino all'annuncio degli IP (molto comune in cluster piccoli), è necessario rimuovere le label restrittive che Kubernetes e Talos applicano per default.18

YAML

\# Esempio di patch per abilitare strictARP e rimuovere restrizioni sui nodi  
cluster:  
  proxy:  
    config:  
      ipvs:  
        strictARP: true  
  allowSchedulingOnControlPlanes: true \# Se si usano i master come worker  
machine:  
  nodeLabels:  
    node.kubernetes.io/exclude-from-external-load-balancers: ""  
    $patch: delete

Questa patch assicura che il piano di controllo non venga escluso dalle operazioni di bilanciamento del carico, permettendo a MetalLB di far girare i propri "speaker" su ogni nodo disponibile.18

### **Installazione di MetalLB tramite Helm**

L'utilizzo di Helm è il metodo raccomandato per installare MetalLB poiché facilita la gestione delle versioni e delle dipendenze RBAC.16

1. Creazione del Namespace e Label di Sicurezza:  
   Kubernetes applica Pod Security Admissions. MetalLB, dovendo manipolare lo stack di rete dell'host, richiede un profilo privileged. È essenziale etichettare il namespace prima dell'installazione.16  
   Bash  
   kubectl create namespace metallb-system  
   kubectl label namespace metallb-system pod-security.kubernetes.io/enforce=privileged  
   kubectl label namespace metallb-system pod-security.kubernetes.io/audit=privileged  
   kubectl label namespace metallb-system pod-security.kubernetes.io/warn=privileged

2. Esecuzione di Helm:  
   Si aggiunge il repository ufficiale e si procede all'installazione.10  
   Bash  
   helm repo add metallb https://metallb.github.io/metallb  
   helm repo update  
   helm install metallb metallb/metallb \-n metallb-system

### **Definizione delle Risorse Custom (CRD)**

Una volta installato, MetalLB rimane inattivo finché non vengono definite le pool di indirizzi IP e le modalità di annuncio.16 Queste configurazioni sono ora gestite tramite Custom Resource Definitions (CRD) e non più tramite ConfigMap come nelle versioni precedenti allo 0.13.

**IPAddressPool:** definisce l'intervallo di indirizzi IP che MetalLB può assegnare. È cruciale che questi IP non siano nel range DHCP del router per evitare conflitti.11

YAML

apiVersion: metallb.io/v1beta1  
kind: IPAddressPool  
metadata:  
  name: default-pool  
  namespace: metallb-system  
spec:  
  addresses:  
  \- 192.168.1.50-192.168.1.70

**L2Advertisement:** questa risorsa associa il pool di indirizzi alla modalità di annuncio Layer 2\. Senza di essa, MetalLB assegnerà gli IP ma non risponderà alle richieste ARP, rendendo gli IP irraggiungibili.20

YAML

apiVersion: metallb.io/v1beta1  
kind: L2Advertisement  
metadata:  
  name: default-advertisement  
  namespace: metallb-system  
spec:  
  ipAddressPools:  
  \- default-pool

## **Integrazione e Sicurezza con Proxmox: Gestione dello Spoofing**

Un ostacolo comune nell'installazione di MetalLB su Proxmox è il sistema di protezione di rete integrato nell'hypervisor. Il firewall di Proxmox include funzionalità di "IP Filter" e "MAC Filter" volte a prevenire che una VM utilizzi indirizzi IP o MAC diversi da quelli assegnati ufficialmente nel pannello di controllo.21

Poiché MetalLB in modalità Layer 2 "finge" che il nodo possieda gli indirizzi IP dei servizi (VIP), inviando risposte ARP per IP non configurati sull'interfaccia di rete primaria, il firewall di Proxmox potrebbe bloccare questo traffico identificandolo come ARP Spoofing.21

### **Risoluzione delle Restrizioni del Firewall Proxmox**

Per permettere a MetalLB di funzionare, esistono tre approcci principali:

1. **Disabilitazione del MAC Filter:** Nelle opzioni del firewall della VM (o del bridge), disabilitare la voce MAC filter. Questo permette alla VM di inviare traffico con sorgenti IP diverse da quella principale.22  
2. **Configurazione di IPSet:** Se si desidera mantenere un livello di sicurezza elevato, è possibile creare un IPSet chiamato ipfilter-net0 (dove net0 è l'interfaccia della VM) e includere in questo set tutti gli indirizzi IP presenti nel pool di MetalLB. In questo modo, il firewall di Proxmox saprà che quegli IP sono autorizzati per quella specifica VM.21  
3. **Regole ebtables manuali:** In scenari avanzati, l'amministratore può inserire regole ebtables sull'host Proxmox per consentire specificamente il traffico ARP per il range di MetalLB.23

Bash

\# Esempio di comando ebtables per consentire ARP su una specifica VM  
ebtables \-I FORWARD 1 \-i fwln\<VMID\>i0 \-p ARP \--arp-ip-dst 192.168.1.50/32 \-j ACCEPT

L'omissione di questi passaggi è la causa principale del fallimento delle installazioni di MetalLB su Proxmox, portando a situazioni in cui il servizio Kubernetes mostra un External-IP correttamente assegnato, ma tale IP risulta non raggiungibile (non pingabile) dall'esterno del cluster.19

## **Monitoraggio e Risoluzione dei Problemi (Troubleshooting)**

La natura immutabile di Talos OS rende il troubleshooting differente rispetto ai sistemi tradizionali. Non potendo accedere tramite SSH per eseguire tcpdump direttamente sul nodo, è necessario affidarsi ai log dei pod di MetalLB e agli strumenti di talosctl.

### **Analisi dei Log degli Speaker**

I pod "speaker" sono i responsabili dell'annuncio degli IP. Se un IP non è raggiungibile, il primo passo è controllare i log dello speaker sul nodo che dovrebbe essere il leader per quel servizio.4

Bash

kubectl logs \-n metallb-system \-l component=speaker

Nei log è possibile osservare se lo speaker ha rilevato il servizio, se ha eletto correttamente un leader e se sta incontrando errori nell'invio dei pacchetti gratuiti. Se i log mostrano che l'annuncio è avvenuto correttamente ma il router non vede l'indirizzo, il problema risiede quasi certamente nel layer di virtualizzazione di Proxmox o nello switch fisico.8

### **Verifica dello Stato L2 (ServiceL2Status)**

MetalLB fornisce una risorsa di stato che permette di vedere quale nodo sta attualmente servendo un determinato IP.19

Bash

kubectl get servicel2statuses.metallb.io \-n metallb-system

Questa informazione è vitale per capire se il traffico sta venendo indirizzato verso il nodo corretto e per verificare il comportamento del cluster durante un failover simulato (ad esempio, riavviando un nodo worker).6

### **Conflitti con il CNI e Routing Pod-to-Pod**

In alcuni casi, il traffico raggiunge il nodo ma non viene instradato correttamente verso i pod. Questo può accadere se il CNI (come Cilium o Calico) ha una configurazione che entra in conflitto con le regole di routing create da kube-proxy in modalità IPVS.12 Se si utilizza Cilium, è raccomandato verificare se la funzionalità "L2 Announcement" di Cilium sia attiva; se lo è, essa svolgerà la stessa funzione di MetalLB, rendendo quest'ultimo ridondante o addirittura dannoso per la stabilità della rete.14

## **Ottimizzazione delle Performance e Alta Affidabilità**

Un cluster Kubernetes professionale su Proxmox deve essere progettato per resistere ai guasti e scalare in modo efficiente.

### **Bilanciamento del Carico e Hardware Offloading**

L'uso di VirtIO in Proxmox permette l'offloading di alcune funzioni di rete (come il checksum offload) alla CPU dell'host, riducendo il carico sulla VM Talos.7 Inoltre, l'implementazione di MetalLB in modalità BGP, come discusso, permette di sfruttare l'hardware di rete fisico (router enterprise come MikroTik o Cisco) per gestire il bilanciamento a livello di pacchetto, garantendo che nessun singolo nodo diventi il collo di bottiglia per il traffico applicativo.13

### **Failover e Tempi di Convergenza**

In modalità Layer 2, il tempo di failover dipende dalla velocità con cui i nodi rilevano la caduta di un peer e dalla rapidità con cui il router aggiorna la propria tabella ARP.6 Talos ottimizza questo processo grazie a un kernel Linux estremamente snello e reattivo. Per accelerare ulteriormente il failover, è possibile configurare MetalLB con protocolli come BFD (Bidirectional Forwarding Detection) in modalità BGP, riducendo i tempi di rilevamento del guasto da secondi a millisecondi.13

## **Considerazioni Finali sulla Gestione Day-2**

L'integrazione di MetalLB su Talos e Proxmox non si esaurisce con l'installazione iniziale. La gestione "Day-2" riguarda gli aggiornamenti, il monitoraggio della sicurezza e l'espansione del cluster. Grazie alla natura dichiarativa di Talos e MetalLB, è possibile gestire l'intera infrastruttura come codice (Infrastructure as Code). L'uso di strumenti come Terraform per la creazione delle VM su Proxmox e Helm per la gestione dei componenti Kubernetes permette di ricreare l'intero ambiente in modo deterministico in caso di disaster recovery.8

In conclusione, la sinergia tra la stabilità di Proxmox, la sicurezza intrinseca di Talos OS e la versatilità di MetalLB crea un ecosistema ideale per ospitare applicazioni moderne. L'attenzione ai dettagli nella configurazione del networking Layer 2 e l'eliminazione dei filtri restrittivi di Proxmox sono i pilastri per una distribuzione di successo che garantisca che i servizi non solo siano operativi, ma anche costantemente accessibili e performanti per gli utenti finali. La continua evoluzione di questi strumenti suggerisce un futuro in cui la distinzione tra cloud pubblico e data center privato diventerà sempre più sottile, grazie a soluzioni software-defined che portano l'agilità del cloud direttamente sul metallo nudo della propria infrastruttura.1

#### **Bibliografia**

1. Proxmox vs Talos – Deciding on the Best Infrastructure Solution \- simplyblock, accesso eseguito il giorno gennaio 2, 2026, [https://www.simplyblock.io/blog/proxmox-vs-talos/](https://www.simplyblock.io/blog/proxmox-vs-talos/)  
2. Using Talos Linux and Kubernetes bootstrap on OpenStack \- Safespring, accesso eseguito il giorno gennaio 2, 2026, [https://www.safespring.com/blogg/2025/2025-03-talos-linux-on-openstack/](https://www.safespring.com/blogg/2025/2025-03-talos-linux-on-openstack/)  
3. How to setup the MetalLB | kubernetes-under-the-hood \- GitHub Pages, accesso eseguito il giorno gennaio 2, 2026, [https://mvallim.github.io/kubernetes-under-the-hood/documentation/kube-metallb.html](https://mvallim.github.io/kubernetes-under-the-hood/documentation/kube-metallb.html)  
4. MetalLB: A Load Balancer for Bare Metal Kubernetes Clusters | by 8grams \- Medium, accesso eseguito il giorno gennaio 2, 2026, [https://8grams.medium.com/metallb-a-load-balancer-for-bare-metal-kubernetes-clusters-ef8a9e00c2bd](https://8grams.medium.com/metallb-a-load-balancer-for-bare-metal-kubernetes-clusters-ef8a9e00c2bd)  
5. Networking best practice | Proxmox Support Forum, accesso eseguito il giorno gennaio 2, 2026, [https://forum.proxmox.com/threads/networking-best-practice.163550/](https://forum.proxmox.com/threads/networking-best-practice.163550/)  
6. MetalLB in layer 2 mode :: MetalLB, bare metal load-balancer for Kubernetes, accesso eseguito il giorno gennaio 2, 2026, [https://metallb.universe.tf/concepts/layer2/](https://metallb.universe.tf/concepts/layer2/)  
7. Talos with Kubernetes on Proxmox | Secsys, accesso eseguito il giorno gennaio 2, 2026, [https://secsys.pages.dev/posts/talos/](https://secsys.pages.dev/posts/talos/)  
8. epyc-kube/docs/proxmox-metallb-subnet-configuration.md at main ..., accesso eseguito il giorno gennaio 2, 2026, [https://github.com/xalgorithm/epyc-kube/blob/main/docs/proxmox-metallb-subnet-configuration.md](https://github.com/xalgorithm/epyc-kube/blob/main/docs/proxmox-metallb-subnet-configuration.md)  
9. How I Setup Talos Linux. My journey to building a secure… | by Pedro Chang | Medium, accesso eseguito il giorno gennaio 2, 2026, [https://medium.com/@pedrotychang/how-i-setup-talos-linux-bc2832ec87cc](https://medium.com/@pedrotychang/how-i-setup-talos-linux-bc2832ec87cc)  
10. Highly available kubernetes cluster with etcd, Longhorn and ..., accesso eseguito il giorno gennaio 2, 2026, [https://wiki.joeplaa.com/tutorials/highly-available-kubernetes-cluster-on-proxmox](https://wiki.joeplaa.com/tutorials/highly-available-kubernetes-cluster-on-proxmox)  
11. MetalLB Load Balancer \- Documentation \- K0s docs, accesso eseguito il giorno gennaio 2, 2026, [https://docs.k0sproject.io/v1.34.2+k0s.0/examples/metallb-loadbalancer/](https://docs.k0sproject.io/v1.34.2+k0s.0/examples/metallb-loadbalancer/)  
12. MetalLB \- Ubuntu, accesso eseguito il giorno gennaio 2, 2026, [https://ubuntu.com/kubernetes/charmed-k8s/docs/metallb](https://ubuntu.com/kubernetes/charmed-k8s/docs/metallb)  
13. MetalLB in BGP mode :: MetalLB, bare metal load-balancer for Kubernetes, accesso eseguito il giorno gennaio 2, 2026, [https://metallb.universe.tf/concepts/bgp/](https://metallb.universe.tf/concepts/bgp/)  
14. Kubernetes & Talos \- Reddit, accesso eseguito il giorno gennaio 2, 2026, [https://www.reddit.com/r/kubernetes/comments/1hs6bui/kubernetes\_talos/](https://www.reddit.com/r/kubernetes/comments/1hs6bui/kubernetes_talos/)  
15. Talos with redundant routed networks via bgp : r/kubernetes \- Reddit, accesso eseguito il giorno gennaio 2, 2026, [https://www.reddit.com/r/kubernetes/comments/1iy411r/talos\_with\_redundant\_routed\_networks\_via\_bgp/](https://www.reddit.com/r/kubernetes/comments/1iy411r/talos_with_redundant_routed_networks_via_bgp/)  
16. Installation :: MetalLB, bare metal load-balancer for Kubernetes, accesso eseguito il giorno gennaio 2, 2026, [https://metallb.universe.tf/installation/](https://metallb.universe.tf/installation/)  
17. Kubernetes Homelab Series Part 3 \- LoadBalancer With MetalLB ..., accesso eseguito il giorno gennaio 2, 2026, [https://blog.dalydays.com/post/kubernetes-homelab-series-part-3-loadbalancer-with-metallb/](https://blog.dalydays.com/post/kubernetes-homelab-series-part-3-loadbalancer-with-metallb/)  
18. Unable to use MetalLB on TalosOS linux v.1.9.3 on Proxmox · Issue \#2676 \- GitHub, accesso eseguito il giorno gennaio 2, 2026, [https://github.com/metallb/metallb/issues/2676](https://github.com/metallb/metallb/issues/2676)  
19. Unable to use MetalLB load balancer for TalosOS v1.9.3 · Issue \#10291 · siderolabs/talos, accesso eseguito il giorno gennaio 2, 2026, [https://github.com/siderolabs/talos/issues/10291](https://github.com/siderolabs/talos/issues/10291)  
20. Configuration :: MetalLB, bare metal load-balancer for Kubernetes, accesso eseguito il giorno gennaio 2, 2026, [https://metallb.universe.tf/configuration/](https://metallb.universe.tf/configuration/)  
21. Implementing MAC Filtering for IPv4 in Proxmox Using Built-In Firewall Features, accesso eseguito il giorno gennaio 2, 2026, [https://forum.proxmox.com/threads/implementing-mac-filtering-for-ipv4-in-proxmox-using-built-in-firewall-features.157726/](https://forum.proxmox.com/threads/implementing-mac-filtering-for-ipv4-in-proxmox-using-built-in-firewall-features.157726/)  
22. \[SOLVED\] \- Allow MAC spoofing? \- Proxmox Support Forum, accesso eseguito il giorno gennaio 2, 2026, [https://forum.proxmox.com/threads/allow-mac-spoofing.84424/](https://forum.proxmox.com/threads/allow-mac-spoofing.84424/)  
23. Block incoming ARP requests if destination ip is not part of ipfilter-net\[n\], accesso eseguito il giorno gennaio 2, 2026, [https://forum.proxmox.com/threads/block-incoming-arp-requests-if-destination-ip-is-not-part-of-ipfilter-net-n.144135/](https://forum.proxmox.com/threads/block-incoming-arp-requests-if-destination-ip-is-not-part-of-ipfilter-net-n.144135/)  
24. Filter ARP request \- Proxmox Support Forum, accesso eseguito il giorno gennaio 2, 2026, [https://forum.proxmox.com/threads/filter-arp-request.118505/](https://forum.proxmox.com/threads/filter-arp-request.118505/)  
25. Creating ExternalIPs in OpenShift with BGP and MetalLB | \- Random Tech Adventures, accesso eseguito il giorno gennaio 2, 2026, [https://xphyr.net/post/metallb\_and\_ocp\_using\_bgp/](https://xphyr.net/post/metallb_and_ocp_using_bgp/)  
26. Setting up a Talos kubernetes cluster with talhelper \- beyondwatts, accesso eseguito il giorno gennaio 2, 2026, [https://www.beyondwatts.com/posts/setting-up-a-talos-kubernetes-cluster-with-talhelper/](https://www.beyondwatts.com/posts/setting-up-a-talos-kubernetes-cluster-with-talhelper/)