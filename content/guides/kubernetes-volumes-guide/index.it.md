+++
title = "Strategie e architetture per la gestione dello storage in Kubernetes: analisi tecnica dei volumi, della persistenza e delle operazioni cloud-native"
date = 2026-01-08
draft = false
description = "Un'analisi tecnica dei volumi Kubernetes, della persistenza e delle operazioni cloud-native."
tags = ["kubernetes", "storage", "volumi", "persistenza", "csi", "statefulset"]
author = "Tazzo"
+++

L'evoluzione dell'orchestrazione dei container ha trasformato radicalmente il paradigma della gestione dello stato nelle applicazioni distribuite. All'interno dell'ecosistema Kubernetes, la gestione dello storage non rappresenta più un semplice accessorio infrastrutturale, ma costituisce il fondamento critico su cui poggia l'affidabilità delle applicazioni enterprise.1 Sebbene i container siano stati originariamente concepiti come entità effimere e stateless, la realtà operativa dei carichi di lavoro moderni richiede che i dati sopravvivano non solo ai crash dei singoli processi, ma anche alla rischedulazione dei Pod tra i diversi nodi del cluster.3 Questa analisi tecnica esplora in profondità la tassonomia dei volumi di Kubernetes, i meccanismi di astrazione, le configurazioni YAML avanzate e le strategie di ottimizzazione per scenari di produzione complessi.

## **Analisi del formato YAML e l'orchestrazione dichiarativa**

Prima di approfondire le specifiche dello storage, è essenziale comprendere lo strumento di comunicazione primario di Kubernetes: il formato YAML (YAML Ain't Markup Language). La scelta di questo formato di serializzazione non è casuale; essa risponde all'esigenza di una sintassi leggibile dall'uomo che permetta di definire lo stato desiderato dell'infrastruttura in modo dichiarativo.6 YAML eccelle nella rappresentazione di strutture dati gerarchiche complesse, fondamentali per descrivere le relazioni tra i componenti di storage e i carichi di lavoro.6

La sintassi YAML si basa su coppie chiave-valore e liste, dove l'indentazione (rigorosamente eseguita con spazi e mai con tabulazioni) determina la gerarchia degli elementi.6 Questa struttura è vitale per definire le specifiche dei volumi all'interno dei manifesti dei Pod. Per esempio, l'uso di ancore (&) e alias (\*) in YAML permette di ridurre la duplicazione nelle configurazioni di storage simili, migliorando la manutenibilità dei file di configurazione complessi.6 Kubernetes sfrutta queste caratteristiche per validare i file rispetto ai propri schemi API, garantendo che le definizioni di storage siano sintatticamente corrette prima dell'applicazione al cluster.6

## **Tassonomia e ciclo di vita dei volumi**

Un volume in Kubernetes è fondamentalmente una directory accessibile ai container all'interno di un Pod, la cui natura, contenuto e ciclo di vita sono determinati dal tipo di volume specifico utilizzato.5 Kubernetes risolve due sfide fondamentali: la persistenza dei dati oltre il crash di un container (poiché al riavvio il container parte da uno stato pulito) e la condivisione di file tra più container che risiedono nello stesso Pod.5

### **Classificazione per persistenza: volumi effimeri e persistenti**

La distinzione primaria nel sistema di storage di Kubernetes riguarda il legame tra la vita del volume e quella del Pod.3

| Caratteristica | Volumi Effimeri | Volumi Persistenti |
| :---- | :---- | :---- |
| **Durata della vita** | Coincide con la vita del Pod.3 | Indipendente dalla vita del Pod.3 |
| **Persistenza post-riavvio container** | I dati vengono mantenuti tra i riavvii.5 | I dati vengono mantenuti tra i riavvii.8 |
| **Persistenza post-eliminazione Pod** | I dati vengono distrutti.3 | I dati persistono nello storage esterno.3 |
| **Esempi comuni** | emptyDir, ConfigMap, Secret, downwardAPI.3 | PersistentVolume, NFS, Azure Disk, AWS EBS.13 |

I volumi effimeri sono ideali per scenari che richiedono spazio di scratch, cache temporanee o l'iniezione di configurazioni.5 Al contrario, i volumi persistenti sono essenziali per applicazioni stateful come i database, dove la perdita del Pod non deve comportare la perdita dell'informazione.4

### **Deep dive sui volumi effimeri: emptyDir e hostPath**

Il tipo di volume emptyDir viene creato nel momento in cui un Pod viene assegnato a un nodo e rimane esistente finché il Pod è in esecuzione su quel nodo.3 Inizialmente vuoto, permette a tutti i container nel Pod di leggere e scrivere nello stesso spazio.5 Una configurazione avanzata prevede l'uso della memoria (RAM) come backend per emptyDir impostando il campo medium a Memory, il che è utile per cache ad altissime prestazioni ma consuma la quota di RAM del nodo.2

Il volume hostPath, invece, monta un file o una directory dal filesystem dell'host direttamente nel Pod.3 Questo tipo è particolarmente utile per carichi di lavoro di sistema che devono monitorare il nodo, come agenti di log che leggono /var/log.3 Tuttavia, presenta rischi di sicurezza significativi esponendo il filesystem dell'host e compromette la portabilità, poiché il Pod diviene dipendente dai file presenti su uno specifico nodo.3

### **Meccanismi di proiezione: ConfigMap e Secret**

Kubernetes utilizza volumi speciali per iniettare dati di configurazione e segreti.15 A differenza dell'uso di variabili d'ambiente, il montaggio di ConfigMap e Secret come volumi permette l'aggiornamento dinamico dei file all'interno del container senza dover riavviare il processo, grazie al meccanismo di aggiornamento atomico dei link simbolici gestito dal Kubelet.16 Questo approccio è fondamentale per le moderne architetture microservizi che richiedono ricaricamenti di configurazione a caldo ("hot reload").16

Un dettaglio tecnico importante riguarda l'uso di subPath. Mentre subPath permette di montare un singolo file da un volume in una specifica cartella del container senza sovrascrivere l'intera directory di destinazione, i file montati tramite questa tecnica non beneficiano dell'aggiornamento automatico quando la risorsa sorgente cambia nel cluster.5

## **Il modello di astrazione: PersistentVolume e PersistentVolumeClaim**

Per gestire lo storage persistente in modo scalabile e agnostico rispetto all'infrastruttura, Kubernetes introduce tre concetti chiave: PersistentVolume (PV), PersistentVolumeClaim (PVC) e StorageClass (SC).13

### **Definizione e responsabilità**

Un PersistentVolume è una risorsa fisica di storage all'interno del cluster, paragonabile a un nodo in termini di risorsa computazionale.14 Esso cattura i dettagli dell'implementazione dello storage (che sia NFS, iSCSI o uno storage specifico di un cloud provider).19 Al contrario, una PersistentVolumeClaim rappresenta la richiesta di storage da parte dell'utente, specificando dimensioni e modalità di accesso senza dover conoscere i dettagli del backend.12

Il ciclo di vita di queste risorse segue quattro fasi distinte:

1. **Provisioning**: Lo storage può essere creato staticamente da un amministratore o dinamicamente tramite una StorageClass.13  
2. **Binding**: Kubernetes monitora le nuove PVC e cerca un PV corrispondente. Una volta trovato, il PV e la PVC vengono legati in una relazione esclusiva 1 a 1\.12  
3. **Using**: Il Pod utilizza la PVC come se fosse un volume locale. Il cluster ispeziona la claim per trovare il volume legato e lo monta nel filesystem del container.12  
4. **Reclaiming**: Quando l'utente ha terminato l'uso del volume e cancella la PVC, la politica di recupero (Reclaim Policy) definisce cosa accade al PV.13

### **Analisi delle Reclaim Policy**

La gestione del dato post-utilizzo è critica per la sicurezza e la conformità. Esistono tre politiche principali 10:

* **Retain**: Il PV rimane intatto dopo la cancellazione della PVC. L'amministratore deve gestire manualmente la pulizia o il riutilizzo del volume.10  
* **Delete**: Il volume fisico e il PV associato vengono eliminati automaticamente. È il comportamento standard per lo storage dinamico in ambiente cloud.13  
* **Recycle**: Esegue una cancellazione dei file (pulisce il filesystem) rendendo il volume disponibile per nuove claim. Questa politica è ora considerata obsoleta a favore del provisioning dinamico.13

## **StorageClass e Provisioning Dinamico**

Il provisioning dinamico rappresenta una pietra miliare dell'automazione in Kubernetes, eliminando la necessità per gli amministratori di pre-creare manualmente i volumi.14 Attraverso l'oggetto StorageClass, è possibile definire diversi tier di storage (es. "fast" per SSD, "slow" per HDD) e delegare a Kubernetes la creazione on-demand del volume fisico tramite il relativo provisioner.25

| Cloud Provider | Provisioner (CSI) | Esempio Parametri | Note Operative |
| :---- | :---- | :---- | :---- |
| **AWS** | ebs.csi.aws.com | type: gp3, iops: 3000 | Supporta espansione online.27 |
| **Azure** | disk.csi.azure.com | storageaccounttype: Premium\_LRS | Richiede PVC di tipo RWO.29 |
| **GCP** | pd.csi.storage.gke.io | type: pd-balanced | Supporta snapshot tramite CSI.26 |

L'uso del parametro volumeBindingMode: WaitForFirstConsumer all'interno di una StorageClass è una best practice fondamentale in ambienti multi-zona.24 Questo parametro istruisce il cluster ad attendere la schedulazione del Pod prima di creare il volume, assicurando che lo storage venga allocato nella stessa zona di disponibilità dove il Pod è effettivamente in esecuzione, evitando errori di montaggio cross-zone.2

## **Modalità di Accesso e Scenari Applicativi**

La corretta selezione della modalità di accesso (AccessMode) è determinante per la stabilità delle applicazioni stateful.1

* **ReadWriteOnce (RWO)**: Il volume può essere montato in lettura/scrittura da un singolo nodo. È la modalità ideale per database come MySQL o PostgreSQL che richiedono l'esclusività per garantire l'integrità del dato.1  
* **ReadOnlyMany (ROX)**: Molti nodi possono montare il volume simultaneamente ma solo in modalità sola lettura. Questo scenario è tipico per la distribuzione di contenuti statici (es. una cartella /html per un cluster Nginx).1  
* **ReadWriteMany (RWX)**: Molti nodi possono leggere e scrivere simultaneamente. Questa modalità è supportata da sistemi come NFS o Azure Files ed è utile per applicazioni che condividono uno stato comune, sebbene richieda attenzione per evitare corruzioni dovute a scritture sovrapposte.1  
* **ReadWriteOncePod (RWOP)**: Introdotta in versioni recenti, garantisce che un solo Pod in tutto il cluster possa accedere al volume, offrendo un livello di sicurezza superiore rispetto a RWO (che limita l'accesso a livello di nodo).1

## **Architettura dei Carichi di Lavoro Stateful: StatefulSet**

La gestione dei dati in Kubernetes culmina nell'uso dello StatefulSet, l'API object progettata per gestire applicazioni che necessitano di identità persistenti e storage stabile.18 A differenza dei Deployment, dove i Pod sono intercambiabili, in uno StatefulSet ogni Pod riceve un indice ordinale (0, 1, 2...) che mantiene per tutta la sua esistenza.18

### **Il ruolo di volumeClaimTemplates**

L'elemento di forza dello StatefulSet è il volumeClaimTemplates.18 Invece di condividere una singola PVC tra tutti i Pod, lo StatefulSet genera automaticamente una PVC unica per ogni istanza.18 Se il Pod db-1 viene eliminato e rischedulato, Kubernetes ricollegherà esattamente la PVC data-db-1 a quella nuova istanza, garantendo che il database mantenga la sua continuità storica dei dati.18

### **Esempio Pratico: Architettura PostgreSQL Resiliente**

Nell'implementare un database PostgreSQL, è fondamentale utilizzare un Headless Service (con clusterIP: None) per fornire nomi DNS stabili (es. postgres-0.postgres.namespace.svc.cluster.local) che permettano la comunicazione tra primario e repliche.18

YAML

apiVersion: apps/v1  
kind: StatefulSet  
metadata:  
  name: postgresql  
spec:  
  serviceName: "postgresql"  
  replicas: 3  
  template:  
    metadata:  
      labels:  
        app: postgres  
    spec:  
      containers:  
      \- name: postgres  
        image: postgres:15  
        volumeMounts:  
        \- name: pgdata  
          mountPath: /var/lib/postgresql/data  
  volumeClaimTemplates:  
  \- metadata:  
      name: pgdata  
    spec:  
      accessModes:  
      storageClassName: "managed-csi"  
      resources:  
        requests:  
          storage: 100Gi

In questo scenario, Kubernetes gestisce l'ordine di creazione e terminazione dei Pod, assicurando che le repliche vengano create solo dopo che il primario è pronto, minimizzando i rischi di inconsistenze durante il bootstrap del cluster.33

## **Container Storage Interface (CSI) e Evoluzione dello Storage**

Il Container Storage Interface (CSI) rappresenta lo standard moderno per l'integrazione dello storage in Kubernetes, avendo sostituito i vecchi driver "in-tree" (compilati direttamente nel codice di Kubernetes).37 CSI permette ai produttori di storage di sviluppare driver indipendenti dal ciclo di rilascio di Kubernetes, favorendo l'innovazione e la stabilità del core.37

### **Architettura del Driver CSI**

Un driver CSI opera attraverso due componenti principali 37:

1. **Controller Plugin**: Gestisce le operazioni ad alto livello come la creazione, cancellazione e il collegamento (attachment) dei volumi ai nodi fisici.37 È tipicamente supportato da sidecar container come external-provisioner e external-attacher.38  
2. **Node Plugin**: In esecuzione su ogni nodo (solitamente come DaemonSet), è responsabile del montaggio e smontaggio effettivo del volume nel filesystem del container tramite chiamate gRPC fornite dal Kubelet.37

Questa architettura permette funzionalità avanzate come il ridimensionamento dei volumi senza interruzioni e il monitoraggio dello stato di salute dello storage direttamente tramite l'API di Kubernetes.5

## **Performance Tuning e Ottimizzazione**

L'ottimizzazione delle performance richiede un bilanciamento tra IOPS, throughput e latenza.2

### **Parametri di Storage e Tiers**

Le organizzazioni dovrebbero definire classi di storage diverse in base ai requisiti del carico di lavoro.1 Per database ad alte prestazioni, l'uso di volumi NVMe over TCP o SSD premium con throughput configurabile è essenziale.1

Per calcolare le performance necessarie, si può fare riferimento alla densità di throughput. Ad esempio, su Google Cloud Hyperdisk, è necessario prevedere un bilanciamento basato sulla capacità:

$$\\text{Throughput Minimo} \= 10 \\text{ MiB/s per ogni TiB di capacità}$$

Mentre il limite superiore è fissato a 600 MiB/s per volume.30

### **VolumeAttributesClass (VAC)**

Una delle innovazioni più recenti (beta in v1.31) è la VolumeAttributesClass (VAC).22 Essa permette di modificare dinamicamente i parametri di performance di un volume (come IOPS o throughput) senza dover ricreare la PVC o il PV, eliminando i tempi di inattività che precedentemente erano necessari per migrare tra diverse classi di storage.28 Questo è particolarmente utile per gestire picchi di traffico stagionali dove è necessario aumentare temporaneamente la velocità del database.28

## **Sicurezza e Gestione degli Accessi**

La protezione del dato a riposo e in transito è un requisito non negoziabile in ambienti enterprise.1

### **Crittografia e RBAC**

È fondamentale abilitare la crittografia a riposo fornita dallo storage backend.1 Inoltre, l'accesso alle PVC deve essere regolato tramite Role-Based Access Control (RBAC), assicurando che solo gli utenti e i ServiceAccount autorizzati possano manipolare le risorse di storage.15

### **Permessi del Filesystem e fsGroup**

Molti problemi di "Permission Denied" nei Pod derivano da disallineamenti tra l'utente che esegue il container e i permessi del volume montato.39 Kubernetes risolve questo problema attraverso il securityContext. Utilizzando il parametro fsGroup, Kubernetes applica automaticamente l'ownership del gruppo specificato a tutti i file all'interno del volume nel momento del montaggio, garantendo che i processi nel container possano scrivere dati senza interventi manuali di chmod o chown.5

YAML

spec:  
  securityContext:  
    fsGroup: 2000  
    fsGroupChangePolicy: "OnRootMismatch"

L'impostazione OnRootMismatch ottimizza i tempi di avvio dei Pod che montano volumi molto grandi, evitando di scansionare ricorsivamente tutti i file se la directory root ha già i permessi corretti.5

## **Backup, Snapshot e Disaster Recovery**

La persistenza non garantisce da sola la protezione contro la cancellazione accidentale o la corruzione dei dati.40 È essenziale implementare una strategia di backup solida.40

### **Meccanismi di Snapshotting CSI**

Kubernetes supporta nativamente gli snapshot dei volumi tramite l'oggetto VolumeSnapshot.22 Questo meccanismo permette di creare copie "point-in-time" dei dati che possono essere utilizzate per clonare volumi o per ripristinare uno stato precedente in caso di errore applicativo.5

### **Velero: Protezione Dati Enterprise**

Velero è lo standard open-source per il backup e il ripristino di Kubernetes.40 Esso offre due modalità principali:

1. **CSI Snapshots**: Sfrutta le capacità native dello storage backend per creare istantanee veloci dei volumi.41  
2. **File System Backup (FSB)**: Utilizza strumenti come Restic o Kopia per eseguire backup a livello di file, ideale quando il driver CSI non supporta gli snapshot o quando si desidera spostare i dati su un object storage differente (off-site backup).41

Una best practice avanzata prevede l'adozione del "CSI Snapshot Data Movement Mode", che combina la velocità dello snapshot hardware con la sicurezza del trasferimento dei dati verso un repository esterno, garantendo che il backup sia accessibile anche in caso di distruzione totale del cluster primario.41

## **Conclusioni: Verso un'Infrastruttura Dati Flessibile**

La gestione dello storage in Kubernetes è maturata da una necessità accessoria a un ecosistema di astrazione altamente sofisticato.1 La comprensione della distinzione tra volumi effimeri e persistenti, unitamente alla padronanza del modello PV/PVC/StorageClass, permette agli ingegneri di progettare sistemi che non solo sopravvivono ai guasti, ma che possono scalare dinamicamente per rispondere alle esigenze di business.2

Il futuro dello storage cloud-native è orientato verso una maggiore intelligenza dei driver CSI, con funzionalità di auto-tuning delle performance e una sempre più profonda integrazione con le policy di sicurezza.28 Per le organizzazioni che operano carichi di lavoro critici, la chiave del successo risiede nell'adozione di standard aperti, nell'automazione del provisioning tramite SC e nella validazione rigorosa dei processi di backup, trasformando lo storage da potenziale collo di bottiglia a catalizzatore di innovazione tecnologica.27

#### **Bibliografia**

1. Kubernetes Persistent Volumes \- Best Practices & Guide | simplyblock, accesso eseguito il giorno gennaio 8, 2026, [https://www.simplyblock.io/blog/kubernetes-persistent-volumes-how-to-best-practices/](https://www.simplyblock.io/blog/kubernetes-persistent-volumes-how-to-best-practices/)  
2. Kubernetes Performance Tuning Guide: Optimize Your K8s Cluster \- Kubegrade, accesso eseguito il giorno gennaio 8, 2026, [https://kubegrade.com/kubernetes-performance-tuning-guide/](https://kubegrade.com/kubernetes-performance-tuning-guide/)  
3. Kubernetes Volumes Explained: Use Cases & Best Practices \- Groundcover, accesso eseguito il giorno gennaio 8, 2026, [https://www.groundcover.com/learn/storage/kubernetes-volumes](https://www.groundcover.com/learn/storage/kubernetes-volumes)  
4. Kubernetes persistent vs ephemeral storage volumes and their uses \- StarWind, accesso eseguito il giorno gennaio 8, 2026, [https://www.starwindsoftware.com/blog/kubernetes-persistent-vs-ephemeral-storage-volumes-and-their-uses/](https://www.starwindsoftware.com/blog/kubernetes-persistent-vs-ephemeral-storage-volumes-and-their-uses/)  
5. Volumes | Kubernetes, accesso eseguito il giorno gennaio 8, 2026, [https://kubernetes.io/docs/concepts/storage/volumes/](https://kubernetes.io/docs/concepts/storage/volumes/)  
6. YAML nel dettaglio: guida completa al formato di serializzazione \- Codegrind, accesso eseguito il giorno gennaio 8, 2026, [https://codegrind.it/blog/yaml-spiegato](https://codegrind.it/blog/yaml-spiegato)  
7. YAML: The Ultimate Guide with Examples and Best Practices | by Mahalingam SRE, accesso eseguito il giorno gennaio 8, 2026, [https://medium.com/@lingeshcbz/yaml-the-ultimate-guide-with-examples-and-best-practices-7040f9e389ed](https://medium.com/@lingeshcbz/yaml-the-ultimate-guide-with-examples-and-best-practices-7040f9e389ed)  
8. Kubernetes Volumes and How To Use Them – ReviewNPrep, accesso eseguito il giorno gennaio 8, 2026, [https://reviewnprep.com/blog/kubernetes-volumes-and-how-to-use-them/](https://reviewnprep.com/blog/kubernetes-volumes-and-how-to-use-them/)  
9. Ephemeral Volumes \- Kubernetes, accesso eseguito il giorno gennaio 8, 2026, [https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/](https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/)  
10. What Is a Kubernetes Persistent Volume? \- Pure Storage, accesso eseguito il giorno gennaio 8, 2026, [https://www.purestorage.com/knowledge/what-is-kubernetes-persistent-volume.html](https://www.purestorage.com/knowledge/what-is-kubernetes-persistent-volume.html)  
11. Ephemeral Storage in Kubernetes: Overview & Guide \- Portworx, accesso eseguito il giorno gennaio 8, 2026, [https://portworx.com/knowledge-hub/ephemeral-storage-in-kubernetes-overview-guide/](https://portworx.com/knowledge-hub/ephemeral-storage-in-kubernetes-overview-guide/)  
12. Persistent Volume Claim (PVC) in Kubernetes: Guide \- Portworx, accesso eseguito il giorno gennaio 8, 2026, [https://portworx.com/tutorial-kubernetes-persistent-volumes/](https://portworx.com/tutorial-kubernetes-persistent-volumes/)  
13. Che cos'è un volume persistente Kubernetes? \- Pure Storage, accesso eseguito il giorno gennaio 8, 2026, [https://www.purestorage.com/it/knowledge/what-is-kubernetes-persistent-volume.html](https://www.purestorage.com/it/knowledge/what-is-kubernetes-persistent-volume.html)  
14. Kubernetes Persistent Volume: Examples & Best Practices \- vCluster, accesso eseguito il giorno gennaio 8, 2026, [https://www.vcluster.com/blog/kubernetes-persistent-volume](https://www.vcluster.com/blog/kubernetes-persistent-volume)  
15. In-Depth Guide to Kubernetes ConfigMap & Secret Management Strategies \- Gravitee, accesso eseguito il giorno gennaio 8, 2026, [https://www.gravitee.io/blog/kubernetes-configurations-secrets-configmaps](https://www.gravitee.io/blog/kubernetes-configurations-secrets-configmaps)  
16. Kubernetes ConfigMaps and Secrets Part 2 | by Sandeep Dinesh | Google Cloud \- Medium, accesso eseguito il giorno gennaio 8, 2026, [https://medium.com/google-cloud/kubernetes-configmaps-and-secrets-part-2-3dc37111f0dc](https://medium.com/google-cloud/kubernetes-configmaps-and-secrets-part-2-3dc37111f0dc)  
17. Mounting ConfigMaps and Secrets as files \- DuploCloud Documentation, accesso eseguito il giorno gennaio 8, 2026, [https://docs.duplocloud.com/docs/automation-platform/kubernetes-overview/configs-and-secrets/mounting-config-as-files](https://docs.duplocloud.com/docs/automation-platform/kubernetes-overview/configs-and-secrets/mounting-config-as-files)  
18. Run a Replicated Stateful Application | Kubernetes, accesso eseguito il giorno gennaio 8, 2026, [https://kubernetes.io/docs/tasks/run-application/run-replicated-stateful-application/](https://kubernetes.io/docs/tasks/run-application/run-replicated-stateful-application/)  
19. Kubernetes Persistent Volumes and the PV Lifecycle \- NetApp, accesso eseguito il giorno gennaio 8, 2026, [https://www.netapp.com/learn/kubernetes-persistent-storage-why-where-and-how/](https://www.netapp.com/learn/kubernetes-persistent-storage-why-where-and-how/)  
20. How to manage Kubernetes storage access modes \- LabEx, accesso eseguito il giorno gennaio 8, 2026, [https://labex.io/tutorials/kubernetes-how-to-manage-kubernetes-storage-access-modes-419137](https://labex.io/tutorials/kubernetes-how-to-manage-kubernetes-storage-access-modes-419137)  
21. Persistent Volumes \- Kubernetes, accesso eseguito il giorno gennaio 8, 2026, [https://kubernetes.io/docs/concepts/storage/persistent-volumes/](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)  
22. Kubernetes PVC Guide: Best Practices & Troubleshooting \- Plural, accesso eseguito il giorno gennaio 8, 2026, [https://www.plural.sh/blog/kubernetes-pvc-guide/](https://www.plural.sh/blog/kubernetes-pvc-guide/)  
23. Kubernetes Persistent Volumes \- Tutorial and Examples \- Spacelift, accesso eseguito il giorno gennaio 8, 2026, [https://spacelift.io/blog/kubernetes-persistent-volumes](https://spacelift.io/blog/kubernetes-persistent-volumes)  
24. Kubernetes Persistent Volume Claims: Tutorial & Top Tips \- Groundcover, accesso eseguito il giorno gennaio 8, 2026, [https://www.groundcover.com/blog/kubernetes-pvc](https://www.groundcover.com/blog/kubernetes-pvc)  
25. Dynamic Provisioning and Storage Classes in Kubernetes, accesso eseguito il giorno gennaio 8, 2026, [https://kubernetes.io/blog/2017/03/dynamic-provisioning-and-storage-classes-kubernetes/](https://kubernetes.io/blog/2017/03/dynamic-provisioning-and-storage-classes-kubernetes/)  
26. Dynamic Volume Provisioning | Kubernetes, accesso eseguito il giorno gennaio 8, 2026, [https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/)  
27. Kubernetes StorageClass: A technical Guide | by Fortismanuel \- Medium, accesso eseguito il giorno gennaio 8, 2026, [https://medium.com/@fortismanuel/kubernetes-storageclass-a-technical-guide-58cfb28619ee](https://medium.com/@fortismanuel/kubernetes-storageclass-a-technical-guide-58cfb28619ee)  
28. Modify Amazon EBS volumes on Kubernetes with Volume Attributes Classes | Containers, accesso eseguito il giorno gennaio 8, 2026, [https://aws.amazon.com/blogs/containers/modify-amazon-ebs-volumes-on-kubernetes-with-volume-attributes-classes/](https://aws.amazon.com/blogs/containers/modify-amazon-ebs-volumes-on-kubernetes-with-volume-attributes-classes/)  
29. Creare un volume permanente con Dischi di Azure nel servizio ..., accesso eseguito il giorno gennaio 8, 2026, [https://learn.microsoft.com/it-it/azure/aks/azure-csi-disk-storage-provision](https://learn.microsoft.com/it-it/azure/aks/azure-csi-disk-storage-provision)  
30. Scale your storage performance with Hyperdisk | Google Kubernetes Engine (GKE), accesso eseguito il giorno gennaio 8, 2026, [https://docs.cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/hyperdisk](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/hyperdisk)  
31. Optimizing Persistent Storage in Kubernetes \- Astuto AI, accesso eseguito il giorno gennaio 8, 2026, [https://www.astuto.ai/blogs/optimizing-persistent-storage-in-kubernetes](https://www.astuto.ai/blogs/optimizing-persistent-storage-in-kubernetes)  
32. Using NFS as External Storage in Kubernetes with PersistentVolume and PersistentVolumeClaim to Deploy Nginx | by Bshreyasharma | Medium, accesso eseguito il giorno gennaio 8, 2026, [https://medium.com/@bshreyasharma1/using-nfs-as-external-storage-in-kubernetes-with-persistentvolume-and-persistentvolumeclaim-to-112994f3ad59](https://medium.com/@bshreyasharma1/using-nfs-as-external-storage-in-kubernetes-with-persistentvolume-and-persistentvolumeclaim-to-112994f3ad59)  
33. StatefulSets \- Kubernetes, accesso eseguito il giorno gennaio 8, 2026, [https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)  
34. Guide to Kubernetes StatefulSet – When to Use It and Examples \- Spacelift, accesso eseguito il giorno gennaio 8, 2026, [https://spacelift.io/blog/kubernetes-statefulset](https://spacelift.io/blog/kubernetes-statefulset)  
35. Kubernetes StatefulSet \- Examples & Best Practices \- vCluster, accesso eseguito il giorno gennaio 8, 2026, [https://www.vcluster.com/blog/kubernetes-statefulset-examples-and-best-practices](https://www.vcluster.com/blog/kubernetes-statefulset-examples-and-best-practices)  
36. Deploying the PostgreSQL Pod on Kubernetes with StatefulSets \- Nutanix Support Portal, accesso eseguito il giorno gennaio 8, 2026, [https://portal.nutanix.com/page/documents/solutions/details?targetId=TN-2192-Deploying-PostgreSQL-Nutanix-Data-Services-Kubernetes:deploying-the-postgresql-pod-on-kubernetes-with-statefulsets.html](https://portal.nutanix.com/page/documents/solutions/details?targetId=TN-2192-Deploying-PostgreSQL-Nutanix-Data-Services-Kubernetes:deploying-the-postgresql-pod-on-kubernetes-with-statefulsets.html)  
37. How the CSI (Container Storage Interface) Works \- simplyblock, accesso eseguito il giorno gennaio 8, 2026, [https://www.simplyblock.io/blog/how-the-csi-container-storage-interface-works/](https://www.simplyblock.io/blog/how-the-csi-container-storage-interface-works/)  
38. Container Storage Interface (CSI) for Kubernetes GA | Kubernetes, accesso eseguito il giorno gennaio 8, 2026, [https://kubernetes.io/blog/2019/01/15/container-storage-interface-ga/](https://kubernetes.io/blog/2019/01/15/container-storage-interface-ga/)  
39. Configure a Pod to Use a PersistentVolume for Storage \- Kubernetes, accesso eseguito il giorno gennaio 8, 2026, [https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/](https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/)  
40. Chapter 6: Backups \- Kubernetes Guides \- Apptio, accesso eseguito il giorno gennaio 8, 2026, [https://www.apptio.com/topics/kubernetes/best-practices/backups/](https://www.apptio.com/topics/kubernetes/best-practices/backups/)  
41. Kubernetes Backup using Velero \- Afi.ai, accesso eseguito il giorno gennaio 8, 2026, [https://afi.ai/blog/kubernetes-velero-backup](https://afi.ai/blog/kubernetes-velero-backup)  
42. Snapshot Backups with Velero \- MSR Documentation, accesso eseguito il giorno gennaio 8, 2026, [https://docs.mirantis.com/msr/4.13/backup/ha-backup/snapshot-backups-with-velero/](https://docs.mirantis.com/msr/4.13/backup/ha-backup/snapshot-backups-with-velero/)  
43. Velero Backup and Restore using Replicated PV Mayastor Snapshots \- Raw Block Volumes, accesso eseguito il giorno gennaio 8, 2026, [https://openebs.io/docs/Solutioning/backup-and-restore/velerobrrbv](https://openebs.io/docs/Solutioning/backup-and-restore/velerobrrbv)  
44. File System Backup \- Velero Docs, accesso eseguito il giorno gennaio 8, 2026, [https://velero.io/docs/v1.17/file-system-backup/](https://velero.io/docs/v1.17/file-system-backup/)