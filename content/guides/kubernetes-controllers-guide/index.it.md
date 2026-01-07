+++
title = "L'architettura dei controller in Kubernetes: guida onnicomprensiva al motore dell'automazione cloud-native"
date = 2026-01-07
draft = false
description = "Una guida completa ai controller di Kubernetes, alla loro architettura e a come guidano l'automazione cloud-native."
tags = ["kubernetes", "controllers", "cloud-native", "architecture", "automation"]
author = "Tazzo"
+++

Il successo di Kubernetes come standard de facto per l'orchestrazione dei container non risiede soltanto nella sua capacità di astrarre l'hardware o di gestire il networking, ma risiede in modo fondamentale nel suo modello operativo basato sui controller. In un sistema distribuito di scala massiva, la gestione manuale dei carichi di lavoro sarebbe impossibile; la stabilità è garantita invece da una miriade di cicli di controllo intelligenti che lavorano incessantemente per mantenere l'armonia tra ciò che l'utente ha dichiarato e ciò che effettivamente accade nei server fisici o virtuali.1 Un controller in Kubernetes è, nella sua essenza più pura, un ciclo infinito, un daemon che osserva lo stato condiviso del cluster attraverso l'API server e apporta le modifiche necessarie per far sì che lo stato attuale converga verso lo stato desiderato.1 Questo paradigma, mutuato dalla teoria dei sistemi e dalla robotica, trasforma la gestione delle infrastrutture da un approccio imperativo (fai questo) a uno dichiarativo (voglio che questo sia così).2

## **Fondamenti e meccanismi del loop di controllo**

Per comprendere i controller partendo "da zero", è necessario visualizzare il cluster non come un insieme statico di container, ma come un organismo dinamico regolato da un termostato intelligente. In una stanza, il termostato rappresenta il controller: l'utente imposta una temperatura desiderata (lo stato desiderato), il termostato rileva la temperatura attuale (lo stato attuale) e agisce accendendo o spegnendo il riscaldamento per eliminare la differenza.2 In Kubernetes, questo processo segue un pattern rigido denominato "Watch-Analyze-Act".4

Il primo pilastro, la fase di "Watch", si affida all'API server come unica fonte di verità. I controller monitorano costantemente le risorse di loro competenza, sfruttando i meccanismi di notifica di etcd per reagire in tempo reale a ogni cambiamento.3 Quando un utente applica un manifesto YAML, l'API server memorizza la specifica (spec) in etcd, e il controller corrispondente riceve immediatamente un segnale.2

Nella fase di "Analyze", il controller confronta la specifica con lo stato riportato nel campo status della risorsa. Se la specifica richiede tre repliche di un'applicazione ma lo stato ne riporta solo due, l'analisi identifica una discrepanza.2 Infine, nella fase "Act", il controller non agisce direttamente sul container, ma invia istruzioni all'API server per creare nuovi oggetti (come un Pod) o rimuovere quelli esistenti.2 Altri componenti, come il kube-scheduler e il kubelet, eseguiranno poi le azioni fisiche necessarie.2 Questo disaccoppiamento garantisce che ogni componente sia specializzato e che il sistema possa tollerare guasti parziali senza perdere la coerenza globale.3

### **Il Kube-Controller-Manager: il centro nevralgico**

Logicamente, ogni controller è un processo separato, ma per ridurre la complessità operativa, Kubernetes raggruppa tutti i controller core in un unico binario chiamato kube-controller-manager.1 Questo demone viene eseguito sul piano di controllo (control plane) e gestisce la maggior parte dei cicli di controllo integrati.1 Per ottimizzare le prestazioni, il kube-controller-manager permette di configurare la concorrenza, ovvero il numero di oggetti che possono essere sincronizzati simultaneamente per ogni tipologia di controller.1

| Controller | Parametro di Concorrenza | Valore Predefinito | Impatto sulle Prestazioni |
| :---- | :---- | :---- | :---- |
| **Deployment** | \--concurrent-deployment-syncs | 5 | Velocità di aggiornamento delle applicazioni stateless |
| **StatefulSet** | \--concurrent-statefulset-syncs | Non specificato (globale) | Gestione ordinata delle applicazioni con stato |
| **DaemonSet** | \--concurrent-daemonset-syncs | 2 | Prontezza dei servizi infrastrutturali su nuovi nodi |
| **Job** | \--concurrent-job-syncs | 5 | Capacità di elaborazione batch simultanea |
| **Namespace** | \--concurrent-namespace-syncs | 10 | Velocità di pulizia e terminazione delle risorse |
| **ReplicaSet** | \--concurrent-replicaset-syncs | 5 | Gestione del numero di repliche desiderato |

Questi parametri sono cruciali per gli amministratori di cluster di grandi dimensioni; aumentare questi valori può rendere il cluster più reattivo ma aumenta drasticamente il carico sulla CPU del piano di controllo e sul traffico di rete verso l'API server.1

## **Analisi dettagliata dei controller di carico di lavoro (Workload)**

La gestione delle applicazioni in Kubernetes avviene attraverso astrazioni chiamate risorse di carico di lavoro, ognuna delle quali è governata da un controller specifico progettato per risolvere problemi di orchestrazione unici.9

### **Deployment e ReplicaSet: lo standard stateless**

Il controller Deployment è probabilmente il più utilizzato nell'ecosistema Kubernetes. Esso fornisce aggiornamenti dichiarativi per Pod e ReplicaSet.5 Quando si definisce un Deployment, il controller non crea direttamente i Pod, ma crea un ReplicaSet, il quale a sua volta garantisce che il numero esatto di Pod sia sempre in esecuzione.5

La vera potenza del Deployment risiede nella gestione delle strategie di aggiornamento, principalmente la "RollingUpdate".11 Durante un rollout, il Deployment controller crea un nuovo ReplicaSet con la nuova versione dell'immagine e inizia a scalarlo verso l'alto, mentre contemporaneamente scala verso il basso il vecchio ReplicaSet.15 Questo meccanismo permette aggiornamenti senza downtime e facilita il rollback immediato tramite il comando kubectl rollout undo.18 I Deployment sono ideali per applicazioni web, API e microservizi dove i singoli Pod sono considerati effimeri e intercambiabili.9

### **StatefulSet: l'identità nel caos distribuito**

A differenza delle applicazioni stateless, molti sistemi (come database o code di messaggi) richiedono che ogni istanza abbia un'identità persistente e un ordine di avvio specifico.9 Il controller StatefulSet gestisce il deployment e lo scaling di un set di Pod fornendo garanzie di unicità.21

Ogni Pod riceve un nome derivato da un indice ordinale (es. $pod-0, pod-1, \\dots, pod-N-1$) che rimane costante anche se il Pod viene rischedulato su un altro nodo.17 Inoltre, lo StatefulSet garantisce la persistenza dello storage: ogni Pod viene associato a un PersistentVolume specifico tramite un volumeClaimTemplate.17 Se il Pod db-0 fallisce, il controller ne creerà uno nuovo chiamato db-0 e lo collegherà allo stesso volume di dati precedente, preservando lo stato applicativo.17

### **DaemonSet: infrastruttura onnipresente**

Il controller DaemonSet assicura che una copia di un Pod sia in esecuzione su tutti (o alcuni) nodi del cluster.5 Quando un nuovo nodo viene aggiunto al cluster, il DaemonSet controller vi aggiunge automaticamente il Pod specificato.9 Questo è fondamentale per servizi che devono risiedere su ogni macchina fisica, come raccoglitori di log (Fluentd, Logstash), agenti di monitoraggio (Prometheus Node Exporter) o componenti di rete (Calico, Cilium).9 È possibile limitare l'esecuzione a un sottoinsieme di nodi utilizzando selettori di etichette (label selectors) o affinità di nodo.22

### **Job e CronJob: l'esecuzione a termine**

Mentre i controller precedenti gestiscono servizi che dovrebbero essere eseguiti all'infinito, Job e CronJob gestiscono task che devono terminare con successo.9 Il Job controller crea uno o più Pod e garantisce che un numero specifico di essi termini correttamente.24 Se un Pod fallisce a causa di un errore del container o del nodo, il Job controller ne avvia uno nuovo fino al raggiungimento della quota di successi o del limite di tentativi (backoffLimit).24

Il CronJob estende questa logica permettendo l'esecuzione di Job su base programmata, utilizzando il formato crontab standard di Unix.27 Questo è ideale per backup notturni, generazione di report periodici o attività di manutenzione del database.28

| Caratteristica | Deployment | StatefulSet | DaemonSet | Job |
| :---- | :---- | :---- | :---- | :---- |
| **Natura Workload** | Stateless | Stateful | Infrastrutturale | Batch / Task unico |
| **Identità Pod** | Casuale (hash) | Ordinale stabile | Legata al nodo | Temporanea |
| **Storage** | Condiviso o effimero | Dedicato per replica | Locale o specifico | Effimero |
| **Ordine di avvio** | Casuale / Parallelo | Sequenziale ordinato | Parallelo su nodi | Parallelo / Sequenziale |
| **Esempio Uso** | Nginx, Spring Boot | MySQL, Kafka, Redis | Fluentd, New Relic | Migrazione DB |

## **I controller interni e l'integrità del sistema**

Oltre ai controller visibili all'utente che gestiscono i Pod, il piano di controllo di Kubernetes esegue numerosi controller "di sistema" che garantiscono il funzionamento dell'infrastruttura stessa.5

### **Node Controller**

Il Node Controller è responsabile della gestione del ciclo di vita dei nodi all'interno del cluster.5 Le sue funzioni principali includono:

1. **Registrazione e Monitoraggio:** Tiene traccia dell'inventario dei nodi e del loro stato di salute.6  
2. **Rilevamento Guasti:** Se un nodo smette di inviare segnali di heartbeat (segno di un guasto di rete o hardware), il Node Controller lo contrassegna come NotReady o Unknown.3  
3. **Evacuazione dei Pod:** Se un nodo rimane non raggiungibile per un periodo prolungato, il controller avvia l'espulsione dei Pod gestiti da Deployment o StatefulSet affinché possano essere rischedulati su nodi sani.5

### **Namespace Controller**

I namespace forniscono un meccanismo di isolamento logico all'interno di un cluster.12 Il Namespace Controller interviene quando un utente richiede la cancellazione di un namespace.5 Invece di una cancellazione istantanea, il controller avvia un processo di pulizia iterativo: si assicura che tutte le risorse associate (Pod, Service, Secret, ConfigMap) vengano rimosse correttamente prima di eliminare definitivamente l'oggetto Namespace dal database etcd.5

### **Endpoints ed EndpointSlice Controller**

Questi controller costituiscono il tessuto connettivo tra il networking e i carichi di lavoro. L'Endpoints Controller monitora costantemente i Service e i Pod; quando un Pod diventa "Ready" (secondo la sua readiness probe), il controller aggiunge l'indirizzo IP del Pod all'oggetto Endpoints corrispondente al Service.5 Questo permette a kube-proxy di instradare correttamente il traffico.3 L'EndpointSlice Controller è un'evoluzione più moderna e scalabile che gestisce raggruppamenti di endpoint più grandi in cluster con migliaia di nodi.5

### **Service Account e Token Controller**

La sicurezza all'interno del cluster è mediata dai Service Account, che forniscono un'identità ai processi che girano nei Pod.12 I Service Account Controller creano automaticamente un account "default" per ogni nuovo namespace e generano i token segreti necessari affinché i container possano autenticarsi presso l'API server per operazioni di monitoraggio o automazione.8

## **Cloud Controller Manager (CCM): L'interfaccia con i provider**

Nelle installazioni cloud (AWS, Azure, Google Cloud), Kubernetes deve interagire con risorse esterne come bilanciatori di carico o dischi gestiti.3 Il Cloud Controller Manager (CCM) separa la logica specifica del cloud dalla logica core di Kubernetes.6

Il CCM esegue tre cicli di controllo principali:

* **Service Controller:** Quando viene creato un Service di tipo LoadBalancer, questo controller interagisce con le API del cloud provider (es. AWS NLB/ALB) per istanziare un bilanciatore di carico esterno e configurarne i target verso i nodi del cluster.5  
* **Route Controller:** Configura le tabelle di routing dell'infrastruttura di rete del cloud per garantire che i pacchetti destinati ai Pod possano viaggiare tra i diversi nodi fisici.5  
* **Node Controller (Cloud):** Interroga il cloud provider per determinare se un nodo che ha smesso di rispondere sia stato effettivamente rimosso o terminato dalla console cloud, permettendo una pulizia più rapida delle risorse del cluster.5

## **Estendibilità estrema: Il pattern Operator e i Custom Controller**

Uno dei punti di forza di Kubernetes è la sua capacità di essere esteso oltre le capacità native.7 Se i controller integrati gestiscono astrazioni generali (Pod, Service), il pattern Operator permette di gestire applicazioni complesse introducendo "conoscenza di dominio" direttamente nel piano di controllo.16

### **Anatomia di un Operator**

Un Operator è l'unione di due componenti:

1. **Custom Resource Definition (CRD):** Estende l'API server permettendo la creazione di nuovi tipi di oggetti (es. un oggetto di tipo ElasticsearchCluster o PostgresBackup).7  
2. **Custom Controller:** Un loop di controllo personalizzato che osserva queste nuove risorse e implementa la logica operativa specifica, come eseguire un backup prima di un aggiornamento del database o gestire il re-sharding dei dati.7

Gli Operator automatizzano compiti che normalmente richiederebbero un intervento umano esperto (un Site Reliability Engineer), come la gestione del quorum in un cluster distribuito o la migrazione di schemi database durante un upgrade applicativo.16

### **Strumenti per lo sviluppo: Operator SDK e Kubebuilder**

Lo sviluppo di un controller personalizzato da zero è complesso, poiché richiede la gestione di cache, code di lavoro (workqueues) e interazioni di rete a bassa latenza.34 Strumenti come **Operator SDK** (supportato da Red Hat) e **Kubebuilder** (progetto ufficiale Kubernetes SIGs) forniscono framework in linguaggio Go per generare boilerplate, gestire la serializzazione degli oggetti e implementare il ciclo di riconciliazione in modo efficiente.33

| Strumento | Linguaggi Supportati | Caratteristiche Principali |
| :---- | :---- | :---- |
| **Operator SDK** | Go, Ansible, Helm | Integrazione con Operator Lifecycle Manager (OLM), ideale per integrazioni aziendali.33 |
| **Kubebuilder** | Go | Basato su controller-runtime, fornisce astrazioni pulite per la generazione di CRD e Webhook.33 |
| **Client-Go** | Go | Libreria di basso livello per il controllo totale, ma con curva di apprendimento molto ripida.33 |

## **Automazione Elastica: Horizontal Pod Autoscaler (HPA)**

Il controller Horizontal Pod Autoscaler (HPA) automatizza lo scaling orizzontale, ovvero l'aggiunta o la rimozione di repliche dei Pod in risposta al carico.38

Il funzionamento segue una formula matematica precisa per calcolare il numero di repliche desiderate:  
$R\_{desiderate} \= \\lceil R\_{attuali} \\times \\frac{Valore\_{attuale}}{Valore\_{target}} \\rceil$  
L'HPA interroga il Metrics Server (o un adattatore per metriche personalizzate come Prometheus) per ottenere l'utilizzo medio delle risorse.38 Se l'utilizzo supera la soglia impostata (es. 70% di CPU), l'HPA aggiorna il campo replicas del Deployment o dello StatefulSet target.38 Questo permette al cluster di adattarsi a picchi di traffico imprevisti senza intervento manuale, ottimizzando al contempo i costi durante i periodi di bassa attività.38

## **Guida Pratica: Installazione e Configurazione dei Controller**

La maggior parte degli utenti interagisce con i controller attraverso file manifest YAML. Ecco come configurare e gestire i principali controller con esempi reali.

### **Configurazione di un Deployment con strategie di Rollout**

Un Deployment ben configurato deve definire chiaramente come gestire gli aggiornamenti.

YAML

apiVersion: apps/v1  
kind: Deployment  
metadata:  
  name: api-service  
  labels:  
    app: api  
spec:  
  replicas: 4  
  strategy:  
    type: RollingUpdate  
    rollingUpdate:  
      maxSurge: 25%       \# Numero di pod extra creati durante il rollout  
      maxUnavailable: 25% \# Massimo numero di pod che possono essere offline  
  selector:  
    matchLabels:  
      app: api  
  template:  
    metadata:  
      labels:  
        app: api  
    spec:  
      containers:  
      \- name: api-container  
        image: myrepo/api:v1.0.2  
        ports:  
        \- containerPort: 8080  
        readinessProbe:    \# Fondamentale per il controller Deployment  
          httpGet:  
            path: /healthz  
            port: 8080

13

Per gestire questo controller da CLI:

* Visualizzare lo stato: kubectl rollout status deployment/api-service.19  
* Vedere la cronologia: kubectl rollout history deployment/api-service.15  
* Eseguire il rollback: kubectl rollout undo deployment/api-service \--to-revision=2.15

### **Installazione di un Operator tramite Operator SDK**

Il processo di installazione di un Operator è più articolato rispetto a una risorsa nativa, poiché richiede la registrazione di nuovi tipi di API.36

1. **Installazione delle CRD:** kubectl apply \-f deploy/crds/db\_v1alpha1\_mysql\_crd.yaml. Questo insegna all'API server cosa sia un "MySQLDatabase".34  
2. **Configurazione RBAC:** kubectl apply \-f deploy/role.yaml e kubectl apply \-f deploy/role\_binding.yaml. Questo dà al controller i permessi per creare Pod e Service.36  
3. **Deployment del Controller:** kubectl apply \-f deploy/operator.yaml. Questo avvia il Pod che contiene il codice sorgente dell'Operator.36  
4. **Creazione dell'istanza:** Una volta che l'Operator è in esecuzione, l'utente crea una risorsa personalizzata per istanziare l'applicazione:  
   YAML  
   apiVersion: db.example.com/v1alpha1  
   kind: MySQLDatabase  
   metadata:  
     name: production-db  
   spec:  
     size: 3  
     storage: 100Gi

   7

A questo punto, l'Operator prenderà in carico la richiesta e orchestrerà la creazione di StatefulSet, Service e backup necessari.7

## **Scelta del Controller: Decision Matrix per Architetti Cloud**

Identificare il controller corretto è una decisione architettonica critica che influenza la resilienza e la manutenibilità dell'intero sistema.20

| Scenari d'uso | Controller da utilizzare | Perché? |
| :---- | :---- | :---- |
| **API Gateway, Front-end Web, Microservizi stateless** | **Deployment** | Massima velocità di scaling e facilità di aggiornamenti "rolling".9 |
| **Database (PostgreSQL, MongoDB), Code (RabbitMQ), AI/ML con stato** | **StatefulSet** | Garantisce che i dati rimangano accoppiati alle istanze corrette e gestisce il quorum.9 |
| **Monitoraggio, Log Forwarding, Proxy di Rete (Kube-proxy)** | **DaemonSet** | Assicura che ogni nodo contribuisca all'osservabilità e alla connettività del cluster.20 |
| **Processamento dati massivo, Training di modelli ML, Migrazioni DB** | **Job** | Gestisce task che devono girare fino al successo, con logica di retry integrata.23 |
| **Backup periodici, Pulizia cache, Rotazione log programmata** | **CronJob** | Automazione basata su tempo, sostituisce il cron di sistema per un ambiente containerizzato.27 |
| **Software-as-a-Service (SaaS) complesso, Database managed-like** | **Operator** | Quando la logica operativa richiede passi specifici (es. promozione leader) non coperti da StatefulSet.7 |

## **Best Practices Operative e Troubleshooting**

Gestire correttamente i controller richiede la consapevolezza di alcune insidie comuni che possono destabilizzare l'ambiente di produzione.41

### **L'importanza delle Probes: Liveness e Readiness**

Il controller Deployment si fida delle informazioni fornite dai container. Se un container è "Running" ma l'applicazione all'interno è in stallo, il controller non interverrà a meno che non sia configurata una **Liveness Probe**.9 Allo stesso modo, una **Readiness Probe** è essenziale durante i rollout: essa informa il controller quando il nuovo Pod è effettivamente pronto a ricevere traffico, evitando che il rollout proceda se la nuova versione sta fallendo silenziosamente.9

### **Resource Requests e Limits: Il carburante dei Controller**

Lo scheduler e i controller di autoscaling (HPA) dipendono interamente dalle dichiarazioni di risorse.41 Senza requests, lo scheduler potrebbe sovraffollare un nodo, portando a prestazioni degradate.9 Senza limits, un singolo Pod con un memory leak potrebbe consumare tutta la memoria del nodo, causando il riavvio forzato di Pod critici di sistema (OOM Killing).41

### **Labels e Selectors: Il rischio del "Collisione"**

I controller identificano le risorse di loro competenza tramite selettori di etichette.5 Un errore comune è l'utilizzo di etichette troppo generiche (es. app: web) in namespace condivisi. Se due Deployment diversi usano lo stesso selettore, i loro controller entreranno in conflitto, tentando ognuno di gestire i Pod dell'altro, portando a una continua creazione e cancellazione di container.47 È buona norma utilizzare etichette univoche e strutturate.

### **Gestione della cronologia e Rollback**

Kubernetes mantiene una cronologia limitata dei rollout dei Deployment (per impostazione predefinita, 10 revisioni).21 È importante monitorare questi limiti per assicurarsi di poter tornare indietro a versioni stabili in caso di incidenti gravi.15 L'uso di strumenti di GitOps (come ArgoCD o Flux) che tracciano lo stato desiderato in un repository Git è la raccomandazione d'elezione per gestire configurazioni complesse senza errori manuali.14

## **Conclusioni: Verso l'autonomia del Cluster**

Il modello dei controller in Kubernetes rappresenta il culmine dell'ingegneria dei sistemi distribuiti moderni. Comprendere come i diversi controller interagiscono tra loro — dal Node Controller che rileva un guasto, al Deployment che risponde rischedulando i Pod, fino all'HPA che scala le repliche — è ciò che differenzia un utilizzatore passivo di Kubernetes da un esperto di orchestrazione.2

Il futuro di questa tecnologia si sta spostando verso una specializzazione sempre maggiore attraverso gli Operator, che permettono di gestire non solo i container, ma l'intero ciclo di vita del business logic, dai database AI-driven alle reti definite dal software. In questo ecosistema, il manifesto YAML non è più solo un file di configurazione, ma un contratto vivente che una schiera di controller intelligenti si impegna a onorare ogni secondo, garantendo che l'applicazione rimanga sempre disponibile, sicura e pronta a scalare.1

#### **Bibliografia**

1. kube-controller-manager \- Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/)  
2. Controllers \- Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/docs/concepts/architecture/controller/](https://kubernetes.io/docs/concepts/architecture/controller/)  
3. Kubernetes Control Plane: Ultimate Guide (2024) \- Plural, accesso eseguito il giorno dicembre 31, 2025, [https://www.plural.sh/blog/kubernetes-control-plane-architecture/](https://www.plural.sh/blog/kubernetes-control-plane-architecture/)  
4. Kube Controller Manager: A Quick Guide \- Techiescamp, accesso eseguito il giorno dicembre 31, 2025, [https://blog.techiescamp.com/docs/kube-controller-manager-a-quick-guide/](https://blog.techiescamp.com/docs/kube-controller-manager-a-quick-guide/)  
5. A controller in Kubernetes is a control loop that: \- DEV Community, accesso eseguito il giorno dicembre 31, 2025, [https://dev.to/jumptotech/a-controller-in-kubernetes-is-a-control-loop-that-23d3](https://dev.to/jumptotech/a-controller-in-kubernetes-is-a-control-loop-that-23d3)  
6. Basic Components of Kubernetes Architecture \- Appvia, accesso eseguito il giorno dicembre 31, 2025, [https://www.appvia.io/blog/components-of-kubernetes-architecture](https://www.appvia.io/blog/components-of-kubernetes-architecture)  
7. Understanding Custom Resource Definitions, Custom Controllers, and the Operator Framework in Kubernetes | by Damini Bansal, accesso eseguito il giorno dicembre 31, 2025, [https://daminibansal.medium.com/understanding-custom-resource-definitions-custom-controllers-and-the-operator-framework-in-5734739e012d](https://daminibansal.medium.com/understanding-custom-resource-definitions-custom-controllers-and-the-operator-framework-in-5734739e012d)  
8. Kubernetes Components, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes-docsy-staging.netlify.app/docs/concepts/overview/components/](https://kubernetes-docsy-staging.netlify.app/docs/concepts/overview/components/)  
9. The Guide to Kubernetes Workload With Examples \- Densify, accesso eseguito il giorno dicembre 31, 2025, [https://www.densify.com/kubernetes-autoscaling/kubernetes-workload/](https://www.densify.com/kubernetes-autoscaling/kubernetes-workload/)  
10. Workload Management \- Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/docs/concepts/workloads/controllers/](https://kubernetes.io/docs/concepts/workloads/controllers/)  
11. Deployment vs StatefulSet vs DaemonSet: Navigating Kubernetes Workloads, accesso eseguito il giorno dicembre 31, 2025, [https://dev.to/sre\_panchanan/deployment-vs-statefulset-vs-daemonset-navigating-kubernetes-workloads-190j](https://dev.to/sre_panchanan/deployment-vs-statefulset-vs-daemonset-navigating-kubernetes-workloads-190j)  
12. Controllers :: Introduction to Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://shahadarsh.github.io/docker-k8s-presentation/kubernetes/objects/controllers/](https://shahadarsh.github.io/docker-k8s-presentation/kubernetes/objects/controllers/)  
13. Kubernetes Workload \- Resource Types & Examples \- Spacelift, accesso eseguito il giorno dicembre 31, 2025, [https://spacelift.io/blog/kubernetes-workload](https://spacelift.io/blog/kubernetes-workload)  
14. Kubernetes Configuration Good Practices, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/blog/2025/11/25/configuration-good-practices/](https://kubernetes.io/blog/2025/11/25/configuration-good-practices/)  
15. How do you rollback deployments in Kubernetes? \- LearnKube, accesso eseguito il giorno dicembre 31, 2025, [https://learnkube.com/kubernetes-rollbacks](https://learnkube.com/kubernetes-rollbacks)  
16. Kubernetes Controllers vs Operators: Concepts and Use Cases ..., accesso eseguito il giorno dicembre 31, 2025, [https://konghq.com/blog/learning-center/kubernetes-controllers-vs-operators](https://konghq.com/blog/learning-center/kubernetes-controllers-vs-operators)  
17. Kubernetes StatefulSet vs. Deployment with Use Cases \- Spacelift, accesso eseguito il giorno dicembre 31, 2025, [https://spacelift.io/blog/statefulset-vs-deployment](https://spacelift.io/blog/statefulset-vs-deployment)  
18. kubectl rollout undo \- Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/docs/reference/kubectl/generated/kubectl\_rollout/kubectl\_rollout\_undo/](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_undo/)  
19. kubectl rollout \- Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/docs/reference/kubectl/generated/kubectl\_rollout/](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/)  
20. Kubernetes Deployments, DaemonSets, and StatefulSets: a Deep ..., accesso eseguito il giorno dicembre 31, 2025, [https://www.professional-it-services.com/kubernetes-deployments-daemonsets-and-statefulsets-a-deep-dive/](https://www.professional-it-services.com/kubernetes-deployments-daemonsets-and-statefulsets-a-deep-dive/)  
21. StatefulSets \- Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)  
22. Kubernetes DaemonSet: Examples, Use Cases & Best Practices \- Groundcover, accesso eseguito il giorno dicembre 31, 2025, [https://www.groundcover.com/blog/kubernetes-daemonset](https://www.groundcover.com/blog/kubernetes-daemonset)  
23. Mastering K8s Job Timeouts: A Complete Guide \- Plural, accesso eseguito il giorno dicembre 31, 2025, [https://www.plural.sh/blog/kubernetes-jobs/](https://www.plural.sh/blog/kubernetes-jobs/)  
24. What Are Kubernetes Jobs? Use Cases, Types & How to Run \- Spacelift, accesso eseguito il giorno dicembre 31, 2025, [https://spacelift.io/blog/kubernetes-jobs](https://spacelift.io/blog/kubernetes-jobs)  
25. How to Configure Kubernetes Jobs for Parallel Processing \- LabEx, accesso eseguito il giorno dicembre 31, 2025, [https://labex.io/tutorials/kubernetes-how-to-configure-kubernetes-jobs-for-parallel-processing-414879](https://labex.io/tutorials/kubernetes-how-to-configure-kubernetes-jobs-for-parallel-processing-414879)  
26. Understanding backoffLimit in Kubernetes Jobs | Baeldung on Ops, accesso eseguito il giorno dicembre 31, 2025, [https://www.baeldung.com/ops/kubernetes-backofflimit](https://www.baeldung.com/ops/kubernetes-backofflimit)  
27. CronJobs | Google Kubernetes Engine (GKE), accesso eseguito il giorno dicembre 31, 2025, [https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cronjobs](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cronjobs)  
28. CronJob in Kubernetes \- Automating Tasks on a Schedule \- Spacelift, accesso eseguito il giorno dicembre 31, 2025, [https://spacelift.io/blog/kubernetes-cronjob](https://spacelift.io/blog/kubernetes-cronjob)  
29. CronJob \- Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)  
30. How to automate your tasks with Kubernetes CronJob \- IONOS UK, accesso eseguito il giorno dicembre 31, 2025, [https://www.ionos.co.uk/digitalguide/server/configuration/kubernetes-cronjob/](https://www.ionos.co.uk/digitalguide/server/configuration/kubernetes-cronjob/)  
31. Service Accounts | Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/docs/concepts/security/service-accounts/](https://kubernetes.io/docs/concepts/security/service-accounts/)  
32. Operator pattern \- Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/docs/concepts/extend-kubernetes/operator/](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)  
33. What Is The Kubernetes Operator Pattern? – BMC Software | Blogs, accesso eseguito il giorno dicembre 31, 2025, [https://www.bmc.com/blogs/kubernetes-operator/](https://www.bmc.com/blogs/kubernetes-operator/)  
34. Ultimate Guide to Kubernetes Operators and How to Create New Operators \- Komodor, accesso eseguito il giorno dicembre 31, 2025, [https://komodor.com/learn/kubernetes-operator/](https://komodor.com/learn/kubernetes-operator/)  
35. The developer's guide to Kubernetes Operators | Red Hat Developer, accesso eseguito il giorno dicembre 31, 2025, [https://developers.redhat.com/articles/2024/01/29/developers-guide-kubernetes-operators](https://developers.redhat.com/articles/2024/01/29/developers-guide-kubernetes-operators)  
36. A complete guide to Kubernetes Operator SDK \- Outshift | Cisco, accesso eseguito il giorno dicembre 31, 2025, [https://outshift.cisco.com/blog/operator-sdk](https://outshift.cisco.com/blog/operator-sdk)  
37. Build a Kubernetes Operator in six steps \- Red Hat Developer, accesso eseguito il giorno dicembre 31, 2025, [https://developers.redhat.com/articles/2021/09/07/build-kubernetes-operator-six-steps](https://developers.redhat.com/articles/2021/09/07/build-kubernetes-operator-six-steps)  
38. Kubernetes HPA \[Horizontal Pod Autoscaler\] Guide \- Spacelift, accesso eseguito il giorno dicembre 31, 2025, [https://spacelift.io/blog/kubernetes-hpa-horizontal-pod-autoscaler](https://spacelift.io/blog/kubernetes-hpa-horizontal-pod-autoscaler)  
39. HPA with Custom GPU Metrics \- Docs \- Kubermatic Documentation, accesso eseguito il giorno dicembre 31, 2025, [https://docs.kubermatic.com/kubermatic/v2.29/tutorials-howtos/hpa-with-custom-gpu-metrics/](https://docs.kubermatic.com/kubermatic/v2.29/tutorials-howtos/hpa-with-custom-gpu-metrics/)  
40. Horizontal Pod Autoscaler (HPA) with Custom Metrics: A Guide \- overcast blog, accesso eseguito il giorno dicembre 31, 2025, [https://overcast.blog/horizontal-pod-autoscaler-hpa-with-custom-metrics-a-guide-0fd5cf0f80b8](https://overcast.blog/horizontal-pod-autoscaler-hpa-with-custom-metrics-a-guide-0fd5cf0f80b8)  
41. 7 Common Kubernetes Pitfalls (and How I Learned to Avoid Them), accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/blog/2025/10/20/seven-kubernetes-pitfalls-and-how-to-avoid/](https://kubernetes.io/blog/2025/10/20/seven-kubernetes-pitfalls-and-how-to-avoid/)  
42. kubectl rollout history \- Kubernetes, accesso eseguito il giorno dicembre 31, 2025, [https://kubernetes.io/docs/reference/kubectl/generated/kubectl\_rollout/kubectl\_rollout\_history/](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_history/)  
43. Install the Operator on Kubernetes | Couchbase Docs, accesso eseguito il giorno dicembre 31, 2025, [https://docs.couchbase.com/operator/current/install-kubernetes.html](https://docs.couchbase.com/operator/current/install-kubernetes.html)  
44. The Kubernetes Compatibility Matrix Explained \- Plural.sh, accesso eseguito il giorno dicembre 31, 2025, [https://www.plural.sh/blog/kubernetes-compatibility-matrix/](https://www.plural.sh/blog/kubernetes-compatibility-matrix/)  
45. A pragmatic look at the Kubernetes Threat Matrix | by Simon Elsmie | Beyond DevSecOps, accesso eseguito il giorno dicembre 31, 2025, [https://medium.com/beyond-devsecops/a-pragmatic-look-at-the-kubernetes-threat-matrix-d58504e926b5](https://medium.com/beyond-devsecops/a-pragmatic-look-at-the-kubernetes-threat-matrix-d58504e926b5)  
46. Tackle Common Kubernetes Security Pitfalls with AccuKnox CNAPP, accesso eseguito il giorno dicembre 31, 2025, [https://accuknox.com/blog/avoid-common-kubernetes-mistakes](https://accuknox.com/blog/avoid-common-kubernetes-mistakes)  
47. 7 Common Kubernetes Pitfalls in 2023 \- Qovery, accesso eseguito il giorno dicembre 31, 2025, [https://www.qovery.com/blog/7-common-kubernetes-pitfalls](https://www.qovery.com/blog/7-common-kubernetes-pitfalls)