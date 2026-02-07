---
title: "Il Castello Effimero: Nomadismo, Rinascita One-Shot e l'Orizzonte Cloud di TazLab"
date: 2026-02-07T19:00:00+01:00
draft: false
tags: ["kubernetes", "terragrunt", "postgresql", "s3-backup", "longhorn", "automation", "cloud-native", "devops", "proxmox", "infrastructure-as-code"]
categories: ["Infrastructure", "Cloud Engineering"]
author: "Taz"
description: "Dalla distruzione totale alla rinascita deterministica in meno di 12 minuti. Documento l'evoluzione del cluster verso l'indipendenza dall'hardware e la visione del nomadismo digitale tramite TazPod."
---

# Il Castello Effimero: Nomadismo, Rinascita One-Shot e l'Orizzonte Cloud di TazLab

Nell'ingegneria dei sistemi, la stabilità non è data dall'immobilità di un'infrastruttura, ma dalla sua capacità di essere ricostruita. Il concetto di **Castello Effimero**, che porto avanti nel progetto **TazLab**, si basa su un pilastro fondamentale: il provisioning deve essere deterministico, rapido e totalmente automatizzato. Se non puoi distruggere il tuo intero data center e vederlo risorgere in dieci minuti senza intervento umano, non possiedi l'infrastruttura; ne sei prigioniero.

Oggi documento il raggiungimento di un traguardo critico: la **Rinascita One-Shot Zero-Touch**. Attraverso un'orchestrazione raffinata di Terragrunt, l'integrazione di backup S3 per la "memoria semantica" e un drastico ripensamento della topologia hardware, ho trasformato il TazLab in una postazione di lavoro nomade, pronta a migrare dal ferro locale al Cloud pubblico con un singolo comando.

## 1. La Topologia del Compromesso: 1 CP + 2 Workers

Il mio laboratorio domestico poggia su un server Proxmox con **32GB di RAM**. Inizialmente, la mia architettura prevedeva un setup standard ad alta affidabilità (HA) con 3 nodi di Control Plane. Tuttavia, la realtà fisica ha presentato il conto: tra l'overhead di Talos OS, i servizi di sistema (Longhorn, MetalLB, ESO) e le applicazioni (Postgres, Blog, AI), il cluster soffriva di una saturazione cronica della memoria, portando a fenomeni di OOM (Out of Memory) e instabilità di `etcd`.

### Il Ragionamento: Ottimizzazione vs Ridondanza
Ho deciso di operare un pivot topologico verso un setup **1 Control Plane + 2 Workers**. 
Perché questa scelta? In un ambiente di produzione, 1 solo nodo CP è un single point of failure. Tuttavia, nella filosofia del Castello Effimero, la ridondanza del Control Plane è meno critica della **velocità di ricostruzione**. Se il CP cade, preferisco distruggere tutto e far rinascere il cluster in 10 minuti piuttosto che sprecare 16GB di RAM per mantenere un quorum che non posso permettermi.

Riducendo il CP a un singolo nodo, ho liberato risorse vitali per i nodi Worker, portando la memoria allocata a un totale di **24GB** (8GB per nodo). Questo garantisce un buffer di sicurezza per l'host Proxmox e permette al cluster di operare in uno stato di "equilibrio dinamico". Questa configurazione è, paradossalmente, la preparazione ideale per il Cloud: su AWS o GCP, le istanze con 8GB di RAM sono standard e prevedibili nei costi.

> **Deep-Dive: Quorum e etcd**
> In Kubernetes, `etcd` è il database distribuito che memorizza lo stato del cluster. Per garantire la coerenza, richiede un numero dispari di nodi (solitamente 3 o 5) per formare un *quorum*. Con un solo nodo, rinuncio alla tolleranza ai guasti del database di stato in favore di una maggiore densità applicativa.

---

## 2. L'Evoluzione di Mnemosyne in `tazlab-db`

Nel post precedente, documentavo l'uso di AlloyDB su Google Cloud come memoria semantica. Sebbene efficace, non rispondeva al mio obiettivo di **autoconsistenza**. La memoria deve risiedere dove risiede il lavoro. Ho quindi riportato Mnemosyne all'interno del cluster, rinominandola **`tazlab-db`**.

### La Strategia di "Data Immortality"
La sfida era garantire che il database sopravvivesse alla filosofia *Wipe-First*. Se distruggo le VM, come preservo la memoria? La risposta risiede nel **Backup S3-Native**.
Ho configurato il cluster Postgres (gestito dal Postgres Operator di CrunchyData) per utilizzare due repository di backup:
1.  **Repo1 (S3 - Immortality):** Un bucket AWS S3 criptato che contiene la storia del cluster.
2.  **Repo2 (Local - Speed):** Un volume Longhorn per ripristini rapidi in caso di errore logico.

Questo setup crea un'infrastruttura "stateless per definizione ma stateful per necessità". Il database può essere vaporizzato insieme alle VM; alla rinascita, il Postgres Operator riconcilierà lo stato scaricando i dati dal bucket S3.

---

## 3. La Cronaca Tecnica della Rinascita

Il test finale, che ho chiamato **Nuclear Rebirth**, è stato eseguito utilizzando lo script `precision-test.sh`. Questo script orchestra i layer di Terragrunt e valida la salute del cluster.

### Fase 1: Il Nuclear Wipe
Prima di creare, bisogna distruggere. Lo script `nuclear-wipe.sh` interagisce con le API di Proxmox per eliminare forzatamente ogni traccia delle VM (ID 421, 431, 432). È un protocollo aggressivo che garantisce una tabula rasa reale, eliminando lock di Terraform o stati fantasma.

### Fase 2: Il Bootstrap One-Shot
Per evitare che il processo venisse interrotto dalla chiusura della sessione shell, ho lanciato l'automazione con un protocollo di disaccoppiamento:
```bash
nohup setsid bash precision-test.sh > precision_test.log 2>&1 &
```
Questo comando garantisce che il "parto" del cluster avvenga in una sessione indipendente, immune ai segnali di `hangup` della CLI.

---

## 4. Analisi degli Errori: Lo "Struggle" della Configurazione

Nessuna rinascita è priva di dolore. Durante il bootstrap, mi sono scontrato con due problemi critici che hanno richiesto un'indagine approfondita.

### Errore #1: La Validazione DNS-1123
Il primo tentativo di creazione del database è fallito. Il Pod dell'operatore mostrava errori di riconciliazione. Analizzando i log con `kubectl logs`, ho scoperto un errore di validazione:
`spec.users[1].name: Invalid value: "tazlab_admin": should match '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'`

**L'Investigazione:** Avevo utilizzato l'underscore `_` nel nome utente. In Kubernetes, molti oggetti (come i Secret generati dall'operatore per le credenziali) devono seguire lo standard **RFC 1123**. L'uso di `_` è proibito. Ho dovuto rinominare l'utente in `tazlab-admin`. È un classico esempio di come una convenzione di naming possa bloccare un'intera pipeline di CD.

### Errore #2: Lo schema pgBackRest in PGO v5
Il secondo errore riguardava la configurazione dei backup S3. Avevo inserito il campo `s3Credentials` direttamente nel blocco del repository, seguendo un vecchio snippet trovato online.
`PostgresCluster dry-run failed: .spec.backups.pgbackrest.repos[name="repo1"].s3Credentials: field not declared in schema`

**La Soluzione:** Utilizzando `kubectl explain`, ho verificato che nella versione corrente di Crunchy PGO, le credenziali devono essere iniettate tramite un blocco `configuration` che referenzia un Secret.

Ecco la configurazione finale corretta del manifesto `cluster.yaml`:

```yaml
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: tazlab-db
  namespace: tazlab-db
spec:
  postgresVersion: 16
  databaseInitSQL:
    name: tazlab-db-init-sql
    key: init.sql
  instances:
    - name: instance1
      replicas: 1
      dataVolumeClaimSpec:
        storageClassName: longhorn-postgres
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 10Gi
  backups:
    pgbackrest:
      configuration:
      - secret:
          name: s3-backrest-creds
      repos:
      - name: repo1 # S3 Storage (Immortality)
        s3:
          bucket: "tazlab-longhorn"
          endpoint: "s3.amazonaws.com"
          region: "eu-central-1"
      - name: repo2 # Local Storage (Fast recovery)
        volume:
          volumeClaimSpec:
            storageClassName: longhorn-postgres
            accessModes:
            - ReadWriteOnce
            resources:
              requests:
                storage: 10Gi
  proxy:
    pgBouncer:
      replicas: 1
  users:
    - name: mnemosyne
      databases:
        - tazlab_memory
    - name: tazlab-admin
      databases:
        - tazlab_test
```

E l'**ExternalSecret** che genera il file di configurazione dinamico mappendo i segreti da Infisical:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: s3-backrest-creds
  namespace: tazlab-db
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: infisical-tazlab
  target:
    name: s3-backrest-creds
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        s3.conf: |
          [global]
          repo1-s3-key={{ .AWS_ACCESS_KEY_ID }}
          repo1-s3-key-secret={{ .AWS_SECRET_ACCESS_KEY }}
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: AWS_ACCESS_KEY_ID
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: AWS_SECRET_ACCESS_KEY
```

> **Deep-Dive: External Secrets Operator (ESO)**
> ESO è un sistema che sincronizza segreti da gestori esterni (come AWS Secrets Manager o Infisical) all'interno di Kubernetes. In questo caso, permette di non scrivere mai le chiavi AWS su disco nel repository Git, mantenendo il cluster conforme alla filosofia **Zero-Trust**.

---

## 5. Il Risultato: 11 Minuti e 40 Secondi

Dall'invio del comando di distruzione al momento in cui il blog è tornato online, servendo traffico e interrogando il database con successo, sono trascorsi esattamente **11 minuti e 40 secondi**.

Questo arco temporale rappresenta la mia libertà. Non ho più bisogno di un PC fisso o di un server casalingo affidabile al 100%. Se il mio hardware muore, ho un bucket S3 con i dati e un repository Git con le istruzioni per ricreare il mio intero mondo digitale.

---

## 6. Riflessioni Post-Lab: Nomadismo e l'Orizzonte Cloud

Il TazLab si è evoluto in un binomio simbiotico:
1.  **TazPod (Il Portale):** Il mio ambiente di lavoro sicuro, pronto in 5 minuti ovunque io sia.
2.  **TazLab (Il Castello):** L'infrastruttura pesante che comando a distanza tramite il TazPod.

Questa architettura mi rende un **Nomade Digitale dell'Infrastruttura**. Posso lavorare dal laptop in locale usando il TazPod, connettermi via VPN al cluster di casa, o — se necessario — ordinare al TazPod di far sorgere il Castello su AWS. 

La configurazione ottimizzata a 24GB totali rende la migrazione verso il Cloud pubblico non solo tecnicamente possibile, ma economicamente sostenibile. Il prossimo passo del viaggio è già tracciato: testare la stessa identica sequenza di rinascita su istanze EC2, portando il concetto di "Ephemeral Castle" alla sua massima espressione.

### Conclusioni
In questa tappa abbiamo imparato che:
- I limiti hardware sono acceleratori di design: ci costringono a essere snelli.
- Il dato è l'unica cosa che conta; l'infrastruttura deve essere considerata usa e getta.
- La validazione degli schemi (DNS-1123, CRD schemas) è l'ultimo miglio, spesso il più difficile, dell'automazione.

Il Castello è ora solido, portatile e, soprattutto, consapevole della propria mortalità. Ed è proprio questa consapevolezza che lo rende immortale.

---
*Cronaca Tecnica a cura di Taz - HomeLab DevOps Engineer *
