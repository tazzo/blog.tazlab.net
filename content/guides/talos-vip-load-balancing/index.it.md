+++
title = "Strategie Architetturali per il Bilanciamento del Carico e l'Alta Affidabilità del Control Plane in Cluster Kubernetes basati su Talos OS"
date = 2026-01-07
draft = false
description = "Un'analisi approfondita delle strategie VIP, kube-vip e MetalLB per Talos Linux."
tags = ["talos", "kubernetes", "networking", "load-balancing", "ha", "metallb", "kube-vip"]
author = "Tazzo"
+++

L'adozione di Talos OS come sistema operativo per i nodi Kubernetes rappresenta un cambio di paradigma verso l'immutabilità, la sicurezza e la gestione dichiarativa tramite API. Tuttavia, la natura minimalista e la mancanza di una shell tradizionale in Talos pongono sfide specifiche quando si tratta di configurare l'endpoint ad alta affidabilità (HA) per l'API server e l'esposizione dei servizi verso l'esterno. La scelta tra il Virtual IP (VIP) nativo di Talos, kube-vip e MetalLB non è puramente tecnica, ma dipende dalla scala del cluster, dai requisiti di latenza e dalla complessità dell'infrastruttura di rete sottostante.1 Una comprensione profonda di come questi componenti interagiscono con il kernel Linux e il piano di controllo di Kubernetes è essenziale per implementare una strategia di bilanciamento del carico che sia resiliente e scalabile.

## **Fondamenti dell'Alta Affidabilità del Control Plane in Talos OS**

Il cuore di un cluster Kubernetes è il suo piano di controllo, che include componenti critici come etcd, kube-apiserver, kube-scheduler e kube-controller-manager. In Talos OS, questi componenti vengono eseguiti come pod statici gestiti direttamente dal kubelet.5 La sfida principale nell'architettura di un cluster HA consiste nel fornire ai client, come kubectl o i nodi worker, un unico endpoint stabile (un indirizzo IP o un URL) che possa raggiungere qualsiasi nodo del piano di controllo disponibile, garantendo la continuità operativa anche in caso di guasto di uno o più nodi.1

Talos OS affronta questa sfida attraverso diverse metodologie, ognuna con implicazioni differenti in termini di velocità di failover e capacità di carico. L'approccio più immediato è l'utilizzo del VIP nativo integrato nel sistema operativo, ma man mano che il carico esterno sull'API server aumenta, emerge la necessità di soluzioni più sofisticate come bilanciatori di carico esterni o implementazioni basate su BGP.7

### **Il Meccanismo del Virtual IP Nativo di Talos**

Il VIP nativo di Talos è una funzionalità integrata progettata per semplificare la creazione di cluster HA senza richiedere risorse esterne come proxy inversi o bilanciatori di carico hardware.1 Questo meccanismo si basa sulla contesa dell'indirizzo IP condiviso tra i nodi del control plane attraverso un processo di elezione gestito da etcd.1

Dal punto di vista operativo, la configurazione richiede che tutti i nodi del control plane condividano una rete Layer 2\. L'indirizzo VIP deve essere un indirizzo riservato e non utilizzato all'interno della stessa sottorete dei nodi.1 Un aspetto cruciale di questa implementazione è che il VIP non diventa attivo finché il cluster Kubernetes non è stato bootstrappato, poiché la sua gestione dipende direttamente dallo stato di salute di etcd.1

| Caratteristica del VIP Nativo | Dettaglio Tecnico |
| :---- | :---- |
| **Requisito di Rete** | Connettività Layer 2 (stessa sottorete/switch) |
| **Meccanismo di Elezione** | Basato sul quorum di etcd |
| **Comportamento Failover** | Quasi istantaneo per shutdown graziosi; fino a 1 minuto per crash improvvisi |
| **Limitazione di Carico** | Solo un nodo riceve il traffico alla volta (Active-Passive) |
| **Dipendenza Bootstrap** | Attivo solo dopo la formazione del cluster etcd |

1

L'analisi dei tempi di failover rivela un'importante decisione progettuale dei creatori di Talos. Mentre una disconnessione ordinata permette un passaggio di consegne immediato, un guasto improvviso richiede che Talos attenda il timeout dell'elezione di etcd. Questo ritardo è intenzionale e serve a garantire che non si verifichino scenari di "split-brain", in cui più nodi annunciano lo stesso IP contemporaneamente, una situazione che potrebbe corrompere le sessioni di rete e destabilizzare l'accesso all'API.1

### **KubePrism: L'Eroe Silenzioso dell'Alta Affidabilità Interna**

Spesso confuso con le soluzioni di VIP esterno, KubePrism è in realtà una funzionalità complementare e distinta.8 Mentre il VIP nativo o kube-vip servono principalmente per l'accesso esterno (come i comandi kubectl), KubePrism è progettato esclusivamente per l'accesso interno al cluster.7 Esso crea un endpoint di bilanciamento del carico locale su ogni nodo del cluster (solitamente su localhost:7445), che i processi interni come il kubelet utilizzano per comunicare con l'API server.8

L'importanza di KubePrism risiede nella sua capacità di astrarre la complessità del piano di controllo dai nodi worker. Se il bilanciatore di carico esterno o il VIP dovessero fallire, KubePrism dispone di un meccanismo di fallback automatico che consente ai nodi di continuare a funzionare comunicando direttamente con i nodi del control plane.7 In architetture di produzione, è raccomandato mantenere KubePrism sempre abilitato per garantire che la salute interna del cluster non dipenda mai esclusivamente da un singolo endpoint di rete esterno.7

## **Analisi delle Strategie per il Bilanciamento del Carico dei Servizi**

Oltre all'accesso all'API server, la gestione del traffico verso i carichi di lavoro (workload) richiede l'implementazione di servizi di tipo LoadBalancer. In ambienti bare-metal o virtualizzati dove Talos viene comunemente distribuito, questa funzionalità non è fornita automaticamente dal fornitore di cloud, rendendo necessaria l'installazione di controller specifici come MetalLB o kube-vip.3

### **MetalLB: Lo Standard per i Servizi Bare-Metal**

MetalLB è probabilmente la soluzione più matura e diffusa per fornire bilanciamento del carico in ambienti on-premise.3 Esso opera monitorando le risorse di tipo Service con spec.type: LoadBalancer e assegnando loro un indirizzo IP da un pool preconfigurato.3

MetalLB supporta due modalità operative principali: Layer 2 e BGP. Nella modalità Layer 2, uno dei nodi del cluster viene eletto "leader" per un determinato indirizzo IP del servizio e risponde alle richieste ARP (per IPv4) o NDP (per IPv6).3 Sebbene sia estremamente semplice da configurare, questa modalità presenta il limite di convogliare tutto il traffico di un servizio attraverso un singolo nodo, creando un potenziale collo di bottiglia.4 Al contrario, la modalità BGP permette a ogni nodo di annunciare l'indirizzo IP del servizio ai router della rete, abilitando il bilanciamento del carico vero e proprio tramite ECMP (Equal-Cost Multi-Path).4

### **Kube-vip: Versatilità e Unificazione**

Kube-vip si distingue per la sua capacità di gestire sia l'HA del control plane che il bilanciamento del carico dei servizi in un unico componente.2 A differenza del VIP nativo di Talos, kube-vip può essere configurato per utilizzare IPVS (IP Virtual Server) per distribuire il traffico dell'API server su tutti i nodi del control plane in modalità active-active, migliorando notevolmente le prestazioni sotto carico elevato.14

Kube-vip può funzionare come pod statico, il che lo rende ideale per scenari in cui l'endpoint HA deve essere disponibile fin dai primissimi istanti del bootstrap del cluster, prima ancora che il database etcd sia completamente formato.14 Tuttavia, la sua configurazione come bilanciatore di servizi è spesso considerata meno ricca di funzionalità rispetto a MetalLB, che offre una gestione più granulare dei pool di indirizzi e delle policy di annuncio.16

## **Confronto tra le Strategie Richieste dall'Utente**

La scelta della combinazione corretta di strumenti dipende dalla necessità di bilanciare semplicità operativa e scalabilità. Di seguito viene analizzato il confronto tra le tre strategie principali sollevate nel quesito.

### **Strategia 1: VIP Nativo di Talos con MetalLB**

Questa è la configurazione più comune e consigliata per cluster di dimensioni piccole e medie (fino a 10-20 nodi) in ambienti Layer 2\.7

* **Vantaggi:** Sfrutta la stabilità del sistema operativo per l'accesso critico all'API e utilizza MetalLB, che è lo standard di settore, per la gestione dei servizi applicativi. La separazione dei compiti rende il sistema facile da diagnosticare: i problemi dell'API sono legati alla configurazione di Talos, mentre i problemi delle applicazioni sono legati a MetalLB.17  
* **Svantaggi:** L'accesso all'API server è limitato alla capacità di un singolo nodo (active-passive), il che potrebbe non essere sufficiente per cluster con un'altissima frequenza di operazioni API (ad esempio, ambienti CI/CD massivi).7

### **Strategia 2: Kube-vip senza MetalLB**

Questa strategia punta all'unificazione delle funzioni di rete sotto un unico controller.2

* **Vantaggi:** Riduce il numero di componenti da gestire nel cluster. Kube-vip può gestire sia l'IP dell'API server che gli IP dei servizi LoadBalancer. Supporta IPVS per il bilanciamento reale dell'API.14  
* **Svantaggi:** Sebbene sia versatile, kube-vip può risultare più complesso da configurare correttamente per coprire tutte le casistiche di MetalLB, specialmente in reti BGP complesse. La perdita del pod kube-vip potrebbe, in teoria, interrompere contemporaneamente sia l'accesso al piano di controllo che a tutti i servizi del cluster.16

### **Strategia 3: Kube-vip con MetalLB**

In questa configurazione, kube-vip viene utilizzato esclusivamente per l'alta affidabilità del control plane, mentre MetalLB gestisce i servizi applicativi.16

* **Vantaggi:** Offre le migliori prestazioni per l'API server (grazie a IPVS o BGP ECMP forniti da kube-vip) mantenendo la flessibilità di MetalLB per le applicazioni.17 È una scelta eccellente per ambienti enterprise dove il control plane è sottoposto a forte stress.  
* **Svantaggi:** È la configurazione più complessa da mantenere, richiedendo la gestione di due diversi controller di rete che potrebbero entrare in conflitto se non configurati con attenzione (ad esempio, entrambi che tentano di ascoltare sulla porta BGP 179).3

| Caratteristica | VIP Nativo \+ MetalLB | Kube-vip (Solo) | Kube-vip \+ MetalLB |
| :---- | :---- | :---- | :---- |
| **Complessità** | Bassa | Media | Alta |
| **Performance API** | Active-Passive | Active-Active (IPVS) | Active-Active (IPVS) |
| **Performance Servizi** | Elevata (L2/BGP) | Media | Elevata (L2/BGP) |
| **Standardizzazione** | Molto Comune | Comune | Professionale/Enterprise |
| **Uso Consigliato** | Homelab / PMI | Sistemi Minimalisti | Cluster ad alto carico |

3

## **Strategie Differenziate per Dimensione del Cluster**

Il dimensionamento del cluster è un fattore determinante per la scelta della strategia di bilanciamento. Ciò che funziona per un piccolo server domestico potrebbe non essere adeguato per un data center distribuito.

### **Cluster Piccoli e Ambienti "Minecraft"**

Per "configurazione Minecraft" si intende solitamente un cluster di dimensioni ridotte, spesso costituito da un solo nodo o da un piccolo set di nodi (3 o meno), tipico degli ambienti homelab o di test.21

In un cluster a singolo nodo, è fondamentale prestare attenzione a un dettaglio tecnico di Talos: per impostazione predefinita, i nodi del control plane sono etichettati per essere esclusi dai bilanciatori di carico esterni (node.kubernetes.io/exclude-from-external-load-balancers: "").24 In un cluster multi-nodo, questo protegge i nodi master dal traffico applicativo, ma in un cluster a singolo nodo, impedisce a MetalLB o kube-vip di esporre correttamente i servizi.24 La soluzione consiste nel rimuovere o commentare questa etichetta nella configurazione della macchina.24

Per questi piccoli cluster, la raccomandazione è la semplicità assoluta:

* **Control Plane:** Utilizzare il VIP nativo di Talos.7  
* **Servizi:** Utilizzare MetalLB in modalità Layer 2\.10  
* **Storage:** Spesso accoppiato con Longhorn per la semplicità di gestione su pochi nodi.7

### **Cluster di Grandi Dimensioni (\>100 Nodi)**

In cluster di scala enterprise, le limitazioni della rete Layer 2 diventano evidenti. Il traffico di broadcast ARP per la gestione dei VIP può degradare le prestazioni della rete e la velocità di failover basata sull'elezione di etcd potrebbe non soddisfare i requisiti di disponibilità.4

Le linee guida di Sidero Labs (gli sviluppatori di Talos) per i cluster ad alto carico suggeriscono di spostare la responsabilità del bilanciamento dell'API server all'esterno del cluster.6 L'uso di un bilanciatore di carico esterno (F5, Netscaler, o un'istanza HAProxy dedicata) che distribuisce le richieste a tutti i nodi del control plane sani è l'opzione più resiliente.6 Questo approccio scarica la CPU dei nodi master dalla gestione del traffico di rete e garantisce che l'accesso all'API sia indipendente dallo stato interno del piano di controllo Kubernetes.7

Per i servizi, a questa scala è imperativo l'uso della modalità BGP.4 MetalLB o Cilium (che offre un piano di controllo BGP nativo basato su eBPF) diventano gli strumenti d'elezione.18 L'integrazione con router TOR (Top of Rack) permette una distribuzione del traffico realmente orizzontale, sfruttando l'infrastruttura di rete fisica per garantire la scalabilità.27

## **Analisi Tecnica dei Protocolli: ARP vs BGP**

La decisione tra Layer 2 (ARP) e Layer 3 (BGP) è dettata dall'infrastruttura. È fondamentale comprendere il "costo" di ogni scelta.

### **Implicazioni del Layer 2 e ARP**

Il bilanciamento basato su ARP è fondamentalmente un meccanismo di failover, non di distribuzione del carico.12 Quando MetalLB o kube-vip operano in questa modalità, scelgono un nodo che risponde a tutte le richieste per un determinato IP.3 Il vantaggio è che funziona ovunque, anche su switch economici.29 Tuttavia, in caso di guasto del nodo leader, deve essere inviato un pacchetto ARP "gratuitous" per informare gli altri host che il MAC address associato a quell'IP è cambiato.12 Se i client o i router della rete hanno cache ARP persistenti e ignorano gli annunci gratuiti, si possono verificare interruzioni di connettività fino a 30-60 secondi.12

### **Implicazioni del Layer 3 e BGP**

BGP trasforma i nodi Kubernetes in veri e propri router.13 Ogni nodo annuncia i prefissi IP dei servizi a un peer BGP (solitamente il gateway predefinito). Questo permette il bilanciamento ECMP, dove il router distribuisce i pacchetti tra i nodi.4

Tuttavia, BGP su Kubernetes presenta una sfida nota come "churn" delle connessioni. Poiché i router tradizionali sono spesso "stateless" nel loro hashing ECMP, quando un nodo viene aggiunto o rimosso (ad esempio durante un aggiornamento di Talos), l'algoritmo di hashing del router potrebbe ricalcolare i percorsi, spostando sessioni TCP attive su nodi diversi.13 Se il nuovo nodo non conosce quella sessione (perché il traffico non è stato proxato correttamente), la connessione verrà interrotta con un errore "Connection Reset".13 Per ovviare a questo, è necessario utilizzare router che supportano il "Resilient ECMP" o posizionare i servizi dietro un controller di Ingress che possa gestire la persistenza delle sessioni a livello applicativo.13

## **Guida alla Configurazione: Dettagli e Avvertenze**

La configurazione di queste strategie in Talos OS richiede l'uso di patch YAML applicate ai file di configurazione della macchina (machineconfig).

### **Configurazione del VIP Nativo**

Un errore comune è utilizzare il VIP come endpoint nel file talosconfig.1 Poiché il VIP dipende dalla salute di etcd e del kube-apiserver, se questi componenti falliscono, non sarà possibile utilizzare talosctl tramite il VIP per riparare il nodo. La prassi corretta prevede l'inserimento dei singoli indirizzi IP fisici dei nodi master nella lista degli endpoint di talosconfig.6

### **Conflitti tra Kube-vip e MetalLB**

Se si sceglie di utilizzare kube-vip per il control plane e MetalLB per i servizi, è vitale utilizzare le classi di bilanciamento (loadBalancerClass) introdotte in Kubernetes 1.24.17 Senza questa distinzione, entrambi i controller potrebbero tentare di "prendere in carico" lo stesso servizio, portando a una situazione di instabilità in cui l'indirizzo IP viene assegnato e rimosso continuamente.17

Inoltre, se entrambi i componenti vengono configurati per utilizzare BGP, è probabile che entrino in conflitto per l'uso della porta TCP 179\.3 In Talos, una soluzione moderna consiste nell'utilizzare Cilium come CNI e affidare a lui l'intero piano di controllo BGP, eliminando la necessità di MetalLB e riducendo la complessità del sistema.18

## **Casi d'Uso Particolari e Troubleshooting**

Nelle installazioni reali, emergono spesso scenari non documentati che richiedono interventi specifici.

### **Problemi di Routing Asimmetrico**

Quando si utilizzano bilanciatori di carico software su Talos, può verificarsi il fenomeno del routing asimmetrico: il pacchetto entra nel cluster tramite il nodo A (che detiene il VIP) ma deve essere consegnato a un pod sul nodo B.32 Se il nodo B risponde direttamente al client tramite il proprio gateway predefinito, molti firewall bloccheranno il traffico considerandolo un attacco o un errore di protocollo.32

Per mitigare questo problema, Talos e MetalLB raccomandano di abilitare la modalità "strict ARP" nel kube-proxy.31 Questo assicura che il traffico segua percorsi prevedibili. Un'altra opzione è l'uso di externalTrafficPolicy: Local nel servizio Kubernetes, che istruisce il bilanciatore di carico a inviare traffico solo ai nodi che ospitano effettivamente il pod del servizio, eliminando il salto interno tra i nodi e preservando l'indirizzo IP sorgente del client.13

### **Failover e Impatto sui Workload**

È fondamentale capire che il failover del VIP (sia esso nativo o gestito da kube-vip) influisce solo sull'accesso esterno al cluster (ad esempio, l'esecuzione di kubectl o le chiamate API esterne).1 All'interno del cluster, grazie a KubePrism e alla scoperta dei servizi, i carichi di lavoro continuano a comunicare normalmente e non risentono dello stato del VIP esterno.1 Tuttavia, le connessioni a lunga durata che passano attraverso il VIP (come i tunnel gRPC o le sessioni HTTP/2) verranno interrotte e richiederanno una logica di riconnessione lato client.1

## **Conclusioni e Raccomandazioni Strategiche**

In base all'analisi dei dati raccolti e delle best practice di settore, la strategia corretta per un cluster Kubernetes su Talos OS può essere sintetizzata in tre percorsi principali, a seconda delle esigenze di scalabilità e della complessità della rete.

Per la maggior parte degli utenti, la **Strategia Consigliata** è l'accoppiamento del **VIP nativo di Talos con MetalLB in modalità Layer 2**. Questa configurazione bilancia perfettamente la semplicità di gestione tipica di Talos con la flessibilità di MetalLB. È la scelta ideale per cluster che operano in una singola sala server o in un ambiente virtualizzato standard, garantendo un'alta affidabilità dell'API server senza aggiungere componenti critici che devono essere gestiti manualmente durante il bootstrap.

Per le installazioni **Enterprise o ad Alto Carico**, la strategia ottimale vira verso il **bilanciamento del carico esterno per il control plane e MetalLB o Cilium in modalità BGP per i servizi**. Questa architettura elimina i colli di bottiglia tipici delle reti Layer 2 e sfrutta la potenza dei router fisici per distribuire il traffico, garantendo che il cluster possa scalare fino a centinaia di nodi senza degradi delle prestazioni di rete.

Infine, per i **Piccoli Cluster e Homelab (Minecraft Style)**, la parola d'ordine è minimalismo. L'uso del **VIP nativo e di MetalLB (L2)**, avendo cura di configurare correttamente le etichette dei nodi per permettere l'esposizione dei servizi, fornisce un ambiente robusto e facile da mantenere, riducendo al minimo il "consumo" di risorse preziose da parte dei componenti di infrastruttura.

In sintesi, l'architetto di sistemi che opera con Talos OS deve sempre privilegiare l'abilitazione di **KubePrism** come fondamento della resilienza interna e selezionare il metodo di annuncio degli indirizzi IP (ARP vs BGP) non in base alla preferenza del software, ma in base alle capacità effettive dell'hardware di rete che ospita il cluster.

#### **Bibliografia**

1. Virtual (shared) IP \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 1, 2026, [https://docs.siderolabs.com/talos/v1.8/networking/vip](https://docs.siderolabs.com/talos/v1.8/networking/vip)  
2. kube-vip: Documentation, accesso eseguito il giorno gennaio 1, 2026, [https://kube-vip.io/](https://kube-vip.io/)  
3. Setting Up MetalLB: Kubernetes LoadBalancer for Bare Metal Clusters | Talha Juikar, accesso eseguito il giorno gennaio 1, 2026, [https://talhajuikar.com/posts/metallb/](https://talhajuikar.com/posts/metallb/)  
4. MetalLB: A Load Balancer for Bare Metal Kubernetes Clusters | by 8grams \- Medium, accesso eseguito il giorno gennaio 1, 2026, [https://8grams.medium.com/metallb-a-load-balancer-for-bare-metal-kubernetes-clusters-ef8a9e00c2bd](https://8grams.medium.com/metallb-a-load-balancer-for-bare-metal-kubernetes-clusters-ef8a9e00c2bd)  
5. Control Plane \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 1, 2026, [https://docs.siderolabs.com/talos/v1.9/learn-more/control-plane](https://docs.siderolabs.com/talos/v1.9/learn-more/control-plane)  
6. Production Clusters \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 1, 2026, [https://docs.siderolabs.com/talos/v1.7/getting-started/prodnotes](https://docs.siderolabs.com/talos/v1.7/getting-started/prodnotes)  
7. Kubernetes Cluster Reference Architecture with Talos Linux for 2025-05 \- Sidero Labs, accesso eseguito il giorno gennaio 1, 2026, [https://www.siderolabs.com/wp-content/uploads/2025/08/Kubernetes-Cluster-Reference-Architecture-with-Talos-Linux-for-2025-05.pdf](https://www.siderolabs.com/wp-content/uploads/2025/08/Kubernetes-Cluster-Reference-Architecture-with-Talos-Linux-for-2025-05.pdf)  
8. difference VIP vs KubePrism (or other) · siderolabs talos · Discussion \#9906 \- GitHub, accesso eseguito il giorno gennaio 1, 2026, [https://github.com/siderolabs/talos/discussions/9906](https://github.com/siderolabs/talos/discussions/9906)  
9. Installation \- kube-vip, accesso eseguito il giorno gennaio 1, 2026, [https://kube-vip.io/docs/installation/](https://kube-vip.io/docs/installation/)  
10. Kubernetes Homelab Series Part 3 \- LoadBalancer With MetalLB | Eric Daly's Blog, accesso eseguito il giorno gennaio 1, 2026, [https://blog.dalydays.com/post/kubernetes-homelab-series-part-3-loadbalancer-with-metallb/](https://blog.dalydays.com/post/kubernetes-homelab-series-part-3-loadbalancer-with-metallb/)  
11. Configuration :: MetalLB, bare metal load-balancer for Kubernetes, accesso eseguito il giorno gennaio 1, 2026, [https://metallb.universe.tf/configuration/](https://metallb.universe.tf/configuration/)  
12. MetalLB in layer 2 mode :: MetalLB, bare metal load-balancer for Kubernetes, accesso eseguito il giorno gennaio 1, 2026, [https://metallb.universe.tf/concepts/layer2/](https://metallb.universe.tf/concepts/layer2/)  
13. MetalLB in BGP mode :: MetalLB, bare metal load-balancer for Kubernetes, accesso eseguito il giorno gennaio 1, 2026, [https://metallb.universe.tf/concepts/bgp/](https://metallb.universe.tf/concepts/bgp/)  
14. Architecture | kube-vip, accesso eseguito il giorno gennaio 1, 2026, [https://kube-vip.io/docs/about/architecture/](https://kube-vip.io/docs/about/architecture/)  
15. Static Pods | kube-vip, accesso eseguito il giorno gennaio 1, 2026, [https://kube-vip.io/docs/installation/static/](https://kube-vip.io/docs/installation/static/)  
16. What do you use for baremetal VIP ControlPane and Services : r/kubernetes \- Reddit, accesso eseguito il giorno gennaio 1, 2026, [https://www.reddit.com/r/kubernetes/comments/1nlnb1o/what\_do\_you\_use\_for\_baremetal\_vip\_controlpane\_and/](https://www.reddit.com/r/kubernetes/comments/1nlnb1o/what_do_you_use_for_baremetal_vip_controlpane_and/)  
17. HA Kubernetes API server with MetalLB...? \- Reddit, accesso eseguito il giorno gennaio 1, 2026, [https://www.reddit.com/r/kubernetes/comments/1o9t1j2/ha\_kubernetes\_api\_server\_with\_metallb/](https://www.reddit.com/r/kubernetes/comments/1o9t1j2/ha_kubernetes_api_server_with_metallb/)  
18. For those who work with HA onprem clusters : r/kubernetes \- Reddit, accesso eseguito il giorno gennaio 1, 2026, [https://www.reddit.com/r/kubernetes/comments/1j05ozt/for\_those\_who\_work\_with\_ha\_onprem\_clusters/](https://www.reddit.com/r/kubernetes/comments/1j05ozt/for_those_who_work_with_ha_onprem_clusters/)  
19. Kubernetes Load-Balancer service \- kube-vip, accesso eseguito il giorno gennaio 1, 2026, [https://kube-vip.io/docs/usage/kubernetes-services/](https://kube-vip.io/docs/usage/kubernetes-services/)  
20. metallb \+ BGP \= conflict with kube-router? | TrueNAS Community, accesso eseguito il giorno gennaio 1, 2026, [https://www.truenas.com/community/threads/metallb-bgp-conflict-with-kube-router.115690/](https://www.truenas.com/community/threads/metallb-bgp-conflict-with-kube-router.115690/)  
21. Talos Kubernetes in Five Minutes \- DEV Community, accesso eseguito il giorno gennaio 1, 2026, [https://dev.to/nabsul/talos-kubernetes-in-five-minutes-1p1h](https://dev.to/nabsul/talos-kubernetes-in-five-minutes-1p1h)  
22. \[Lab Setup\] 3-node Talos cluster (Mac minis) \+ MinIO backend — does this topology make sense? : r/kubernetes \- Reddit, accesso eseguito il giorno gennaio 1, 2026, [https://www.reddit.com/r/kubernetes/comments/1myb8xc/lab\_setup\_3node\_talos\_cluster\_mac\_minis\_minio/](https://www.reddit.com/r/kubernetes/comments/1myb8xc/lab_setup_3node_talos_cluster_mac_minis_minio/)  
23. Getting back into the HomeLab game for 2024 \- vZilla, accesso eseguito il giorno gennaio 1, 2026, [https://vzilla.co.uk/vzilla-blog/getting-back-into-the-homelab-game-for-2024](https://vzilla.co.uk/vzilla-blog/getting-back-into-the-homelab-game-for-2024)  
24. Fix LoadBalancer Services Not Working on Single Node Talos Kubernetes Cluster, accesso eseguito il giorno gennaio 1, 2026, [https://www.robert-jensen.dk/posts/2025/fix-loadbalancer-services-not-working-on-single-node-talos-kubernetes-cluster/](https://www.robert-jensen.dk/posts/2025/fix-loadbalancer-services-not-working-on-single-node-talos-kubernetes-cluster/)  
25. Deploy Talos Linux with Local VIP, Tailscale, Longhorn, MetalLB and Traefik \- Josh's Notes, accesso eseguito il giorno gennaio 1, 2026, [https://notes.joshrnoll.com/notes/deploy-talos-linux-with-local-vip-tailscale-longhorn-metallb-and-traefik/](https://notes.joshrnoll.com/notes/deploy-talos-linux-with-local-vip-tailscale-longhorn-metallb-and-traefik/)  
26. Kubernetes & Talos \- Reddit, accesso eseguito il giorno gennaio 1, 2026, [https://www.reddit.com/r/kubernetes/comments/1hs6bui/kubernetes\_talos/](https://www.reddit.com/r/kubernetes/comments/1hs6bui/kubernetes_talos/)  
27. Advanced BGP configuration :: MetalLB, bare metal load-balancer for Kubernetes, accesso eseguito il giorno gennaio 1, 2026, [https://metallb.universe.tf/configuration/\_advanced\_bgp\_configuration/](https://metallb.universe.tf/configuration/_advanced_bgp_configuration/)  
28. Talos with redundant routed networks via bgp : r/kubernetes \- Reddit, accesso eseguito il giorno gennaio 1, 2026, [https://www.reddit.com/r/kubernetes/comments/1iy411r/talos\_with\_redundant\_routed\_networks\_via\_bgp/](https://www.reddit.com/r/kubernetes/comments/1iy411r/talos_with_redundant_routed_networks_via_bgp/)  
29. MetalLB on K3s (using Layer 2 Mode) | SUSE Edge Documentation, accesso eseguito il giorno gennaio 1, 2026, [https://documentation.suse.com/suse-edge/3.3/html/edge/guides-metallb-k3s.html](https://documentation.suse.com/suse-edge/3.3/html/edge/guides-metallb-k3s.html)  
30. Troubleshooting \- Sidero Documentation \- What is Talos Linux?, accesso eseguito il giorno gennaio 1, 2026, [https://docs.siderolabs.com/talos/v1.9/troubleshooting/troubleshooting](https://docs.siderolabs.com/talos/v1.9/troubleshooting/troubleshooting)  
31. Installation :: MetalLB, bare metal load-balancer for Kubernetes, accesso eseguito il giorno gennaio 1, 2026, [https://metallb.universe.tf/installation/](https://metallb.universe.tf/installation/)  
32. Analyzing Load Balancer VIP Routing with Calico BGP and MetalLB \- AHdark Blog, accesso eseguito il giorno gennaio 1, 2026, [https://www.ahdark.blog/analyzing-load-balancer-vip-routing/](https://www.ahdark.blog/analyzing-load-balancer-vip-routing/)  
33. Kubernetes Services : Achieving optimal performance is elusive | by CloudyBytes | Medium, accesso eseguito il giorno gennaio 1, 2026, [https://cloudybytes.medium.com/kubernetes-services-achieving-optimal-performance-is-elusive-5def5183c281](https://cloudybytes.medium.com/kubernetes-services-achieving-optimal-performance-is-elusive-5def5183c281)  
34. Usage :: MetalLB, bare metal load-balancer for Kubernetes, accesso eseguito il giorno gennaio 1, 2026, [https://metallb.universe.tf/usage/](https://metallb.universe.tf/usage/)