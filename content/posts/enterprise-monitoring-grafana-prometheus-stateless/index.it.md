+++
title = "Enterprise Monitoring in a Home Lab: La strada (in salita) verso Grafana e Prometheus Stateless"
date = 2026-03-04T12:40:00Z
draft = false
description = "Una cronaca tecnica dettagliata sull'implementazione di uno stack di monitoraggio di classe enterprise nel TazLab: dalle sfide di persistenza su PostgreSQL ai conflitti di rete con MetalLB."
tags = ["kubernetes", "prometheus", "grafana", "postgresql", "monitoring", "gitops", "fluxcd", "homelab", "devops"]
author = "Tazzo"
+++

# Enterprise Monitoring in a Home Lab: La strada (in salita) verso Grafana e Prometheus Stateless

## Introduzione: Oltre il Monitoring "Out of the Box"

In un Homelab che ambisce a essere qualcosa di più di un semplice insieme di container, il monitoraggio non può essere un elemento accessorio. Dopo aver stabilizzato il mio cluster **Talos Linux** su Proxmox e aver consolidato lo storage distribuito con **Longhorn**, ho sentito la necessità di una visibilità granulare. Non mi servivano solo grafici; mi serviva un'infrastruttura di osservabilità che seguisse gli stessi principi di resilienza e immutabilità del resto del cluster.

Molti tutorial suggeriscono di installare `kube-prometheus-stack` con i valori di default: Grafana che salva i dati su un database SQLite locale e Prometheus che scrive su un volume temporaneo. Questa soluzione, per quanto rapida, è antitetica alla mia visione di "Enterprise Homelab". Se un nodo fallisce e il Pod di Grafana viene rischedulato altrove senza un volume persistente, perderei ogni dashboard creata manualmente, ogni utente e ogni configurazione. Ho deciso quindi di intraprendere la strada più complessa: un'architettura **Stateless per Grafana** e una **Persistenza Duratura per Prometheus**, orchestrata interamente via GitOps con FluxCD.

## La Strategia Architetturale: Perché lo "Stateless"?

Il concetto di "applicazione stateless" è fondamentale nelle architetture cloud-native moderne. Per Grafana, questo significa che il binario dell'applicazione non deve contenere alcuno stato vitale. Ho deciso di utilizzare il cluster PostgreSQL esistente (`tazlab-db`), gestito dal **CrunchyData Postgres Operator**, come backend per i metadati di Grafana.

### Il Ragionamento: SQLite vs PostgreSQL
Perché prendersi il disturbo di configurare un database esterno? In un'installazione standard, Grafana utilizza **SQLite**, un database a file singolo. Sebbene eccellente per semplicità, SQLite in Kubernetes richiede un `PersistentVolumeClaim` (PVC) dedicato. Se il PVC si corrompe o se ci sono problemi di lock del file durante una migrazione di nodo (comune con i volumi RWO), Grafana non parte. Utilizzando PostgreSQL, sposto la responsabilità della persistenza su un sistema che ho già reso resiliente (con backup S3 via pgBackRest e alta affidabilità). Questo mi permette di trattare i Pod di Grafana come sacrificabili: posso distruggerli e ricrearli in qualsiasi momento, sapendo che i dati sono al sicuro nel database centrale.

### La scelta di Prometheus su Longhorn
Per Prometheus, la situazione è diversa. Prometheus è intrinsecamente "stateful" a causa del suo database a serie temporali (TSDB). Sebbene esistano soluzioni come Thanos o Cortex per renderlo stateless, per il mio attuale volume di dati sarebbe stato un overkill inutile. Ho optato per un approccio pragmatico: un volume da 10GB su **Longhorn** con una policy di retention di 15 giorni. Questo garantisce che i dati storici sopravvivano ai riavvii dei Pod, mentre la replica distribuita di Longhorn mi protegge dai guasti hardware dei nodi fisici Proxmox.

---

## L'Implementazione: Configurazione e GitOps

L'intero stack è definito tramite un `HelmRelease` di FluxCD. Questo mi permette di gestire la configurazione in modo dichiarativo nel repository `tazlab-k8s`.

### Il cuore della configurazione (Snippet Tecnico)
Ecco come ho dichiarato l'integrazione con PostgreSQL e la gestione del networking:

```yaml
spec:
  values:
    grafana:
      enabled: true
      grafana.ini:
        database:
          type: postgres
          host: tazlab-db-primary.tazlab-db.svc.cluster.local:5432
          name: grafana
          user: grafana
      env:
        GF_DATABASE_TYPE: postgres
        GF_DATABASE_HOST: tazlab-db-primary.tazlab-db.svc.cluster.local:5432
        GF_DATABASE_NAME: grafana
        GF_DATABASE_USER: grafana
      envValueFrom:
        GF_DATABASE_PASSWORD:
          secretKeyRef:
            name: tazlab-db-pguser-grafana
            key: password
      service:
        type: LoadBalancer
        annotations:
          metallb.universe.tf/loadBalancerIPs: "192.168.1.240"
          metallb.universe.tf/allow-shared-ip: "tazlab-internal-dashboard"
        port: 8005
```

Questa configurazione utilizza le **External Secrets (ESO)** per iniettare la password del database, sincronizzandola direttamente da **Infisical**. È un passaggio critico per la sicurezza: nessuna password è scritta in chiaro nel codice Git.

---

## La Cronaca dei Fallimenti: Un Percorso a Ostacoli

Nonostante la pianificazione, l'installazione è stata un "Trail of Failures" che ha richiesto ore di debugging profondo. Documentare questi errori è fondamentale, perché rappresentano la realtà del lavoro di un ingegnere DevOps.

### 1. Il Fantasma di SQLite (The Silent Failure)
Dopo il primo deploy, ho notato dai log che Grafana tentava ancora di inizializzare un database SQLite in `/var/lib/grafana/grafana.db`. Nonostante avessi configurato la sezione `database` in `grafana.ini`, le impostazioni venivano ignorate.

**L'Investigazione:** Ho eseguito un `kubectl exec` nel Pod per ispezionare il file di configurazione generato. Ho scoperto che, a causa del modo in cui la Helm Chart di Grafana processa i valori, alcune variabili inserite in `grafana.ini` non venivano propagate correttamente se non erano presenti anche come variabili d'ambiente.
**La Soluzione:** Ho dovuto duplicare la configurazione sia nella sezione `grafana.ini` che nella sezione `env`. Solo allora Grafana ha "capito" di dover puntare a PostgreSQL. È un comportamento fastidioso delle chart complesse: la ridondanza a volte è l'unica via.

### 2. Il Muro dei Permessi di Postgres 16
Una volta risolto il problema della configurazione, il Pod di Grafana ha iniziato a crashare con un errore criptico: `pq: permission denied for schema public`.

**L'Investigazione:** Sapevo che il database era attivo e che l'utente `grafana` esisteva. Tuttavia, PostgreSQL 16 ha introdotto cambiamenti restrittivi sui permessi dello schema `public`. Per impostazione predefinita, i nuovi utenti non hanno più il diritto di creare oggetti in quello schema.
**La Soluzione:** Ho dovuto intervenire manualmente sul database con una sessione SQL:
```sql
GRANT ALL ON SCHEMA public TO grafana;
ALTER SCHEMA public OWNER TO grafana;
```
Questo passaggio mi ha ricordato che, anche in un mondo automatizzato, la conoscenza profonda dei sistemi sottostanti (come il RBAC di un database) è insostituibile.

### 3. Il Conflitto di Rete: La Porta 8004
Il cluster utilizza **MetalLB** per esporre i servizi su un IP dedicato (`192.168.1.240`). Durante il deploy, il servizio di Grafana rimaneva in stato `<pending>`.

**L'Investigazione:** Ho controllato gli eventi del servizio con `kubectl describe svc`. MetalLB segnalava un conflitto: "port 8004 is already occupied". Un'analisi rapida della mia documentazione ha rivelato che `mnemosyne-mcp` stava già usando quella porta sullo stesso IP condiviso.
**La Soluzione:** Ho spostato Grafana sulla porta `8005`. Questo evidenzia l'importanza di un **IP Address Management (IPAM)** rigoroso anche in un ambiente di laboratorio, specialmente quando si usano annotazioni come `allow-shared-ip`.

### 4. Il Silenzio del Node Exporter (Pod Security Standards)
Dopo l'installazione, le dashboard erano visibili ma... vuote. Nessun dato dai nodi.

**L'Investigazione:** Ho controllato il DaemonSet del `node-exporter`. Nessun Pod era stato creato. Il controller restituiva un errore di violazione delle **Pod Security Policies**: `violates PodSecurity baseline:latest`. Il `node-exporter` richiede accesso ai namespace dell'host (`hostNetwork`, `hostPID`) e ai `hostPath` per leggere le metriche hardware, comportamenti che Kubernetes ora blocca di default per sicurezza.
**La Soluzione:** Ho dovuto "ammorbidire" il namespace `monitoring` etichettandolo come `privileged`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    pod-security.kubernetes.io/enforce: privileged
```
È un compromesso necessario: per monitorare l'hardware, il software deve poterlo "vedere".

---

## GitOps per le Dashboard: Il Sidecar Magico

Un altro pilastro di questa installazione è l'automazione delle dashboard. Non voglio creare grafici a mano cliccando nell'interfaccia; voglio che le dashboard siano parte del codice.

Ho configurato il **Grafana Sidecar**, un processo leggero che gira accanto a Grafana e scansiona il cluster alla ricerca di `ConfigMap` con l'etichetta `grafana_dashboard: "1"`. Quando ne trova una, scarica il JSON della dashboard e lo inietta in Grafana. Questo trasforma il monitoraggio in un sistema puramente dichiarativo. Se domani dovessi reinstallare tutto da zero, le mie dashboard professionali ("Nodes Pro", "Cluster Health") apparirebbero automaticamente al primo avvio.

---

## Riflessioni Post-Lab: Cosa abbiamo imparato?

Questa "tappa" del viaggio nel TazLab è stata una delle più impegnative dal punto di vista del troubleshooting. Cosa significa questo setup per la stabilità a lungo termine?

1. **Resilienza ai Guasti:** Ora posso perdere un intero nodo o corrompere il namespace del monitoraggio senza perdere la storia del mio lavoro. Il database PostgreSQL è il mio "ancoraggio".
2. **Standardizzazione:** L'uso di `privileged` namespaces e porte specifiche su MetalLB è ora documentato e codificato, riducendo l'entropia del cluster.
3. **Scalabilità Mentale:** Affrontare questi problemi mi ha costretto a scavare nelle specifiche di Postgres 16 e nei meccanismi interni di Kubernetes (PSA, MetalLB). È questa la vera crescita professionale.

In conclusione, l'osservabilità non è solo "vedere dei grafici". È costruire un sistema che sia affidabile quanto il sistema che deve monitorare.
