---
title: "Phoenix Protocol: Validazione del Rebirth Zero-Touch e l'Inferno del PITR su S3"
date: 2026-02-10T18:30:00+01:00
draft: false
tags: ["kubernetes", "devops", "postgresql", "s3-backup", "pgbackrest", "longhorn", "disaster-recovery", "automation", "terragrunt"]
categories: ["Infrastructure", "Reliability Engineering"]
author: "Taz"
description: "Cronaca tecnica di una validazione estrema: testare l'immortalità del dato attraverso cicli ripetuti di distruzione totale (Nuclear Wipe) e rinascita automatica, risolvendo i conflitti di iniezione delle chiavi S3 e le latenze dello storage distribuito."
---

# Phoenix Protocol: Validazione del Rebirth Zero-Touch e l'Inferno del PITR su S3

Nell'architettura del **Castello Effimero**, la resilienza non è un'opzione, ma la condizione stessa di esistenza. Un'infrastruttura che può essere distrutta e ricreata in meno di dodici minuti è inutile se, al termine della rinascita, la sua memoria è svanita. Nelle ultime 48 ore, ho sottoposto il cluster TazLab a quello che ho battezzato **Phoenix Protocol**: un ciclo ossessivo di `nuclear-wipe` e `create`, mirato a validare l'immortalità del dato attraverso il ripristino automatico (Point-In-Time Recovery) da AWS S3.

Questa non è la storia di un successo immediato, ma la cronaca onesta di una guerra di logoramento contro gli automatismi dell'operatore Postgres di CrunchyData, le idiosincrasie dei percorsi degli oggetti S3 e la latenza fisica dello storage distribuito su hardware limitato.

---
 
## Il Mindset: L'Infrastruttura è Cenere, il Dato è Diamante

Ho deciso di adottare una filosofia radicale: l'intero stato del cluster (VM, configurazioni OS, volumi locali) deve essere considerato sacrificabile. L'unico elemento che deve sopravvivere al "fuoco nucleare" è il backup criptato su S3. Per testare questa visione, ho dovuto affrontare tre scogli tecnici principali:
1.  **L'Orchestrazione Deterministica**: Garantire che i layer di Terragrunt nascano nell'ordine corretto, gestendo le dipendenze tra lo storage di rete e le istanze database.
2.  **L'Iniezione delle Credenziali S3**: Risolvere il paradosso di un operatore che richiede chiavi di accesso per poter scaricare il manifesto di ripristino che contiene le istruzioni su come usare quelle stesse chiavi.
3.  **La Latenza di Longhorn**: Gestire il riaggancio dei volumi su nodi che, dopo un wipe totale, presentano residui di stato che confondono lo scheduler di Kubernetes.

---

## Fase 1: Lo Struggle dello Storage e il Paradosso di Longhorn

Il primo tentativo di rinascita si è scontrato con la realtà fisica del mio HomeLab (3 nodi Proxmox con circa 32GB di RAM totali). Longhorn, il motore di storage distribuito che ho scelto per la sua semplicità e integrazione nativa con Kubernetes, si è rivelato un collo di bottiglia inaspettato durante i cicli rapidi di distruzione e creazione.

### L'Investigazione: "Volume not ready for workloads"
Dopo aver lanciato il comando di creazione, ho osservato i Pod di restore rimanere bloccati in `Init:0/1`. Analizzando gli eventi con `kubectl describe pod`, ho riscontrato l'errore:
`AttachVolume.Attach failed for volume "pvc-xxx" : rpc error: code = Aborted desc = volume is not ready for workloads`

Il processo mentale che mi ha portato alla soluzione è stato questo: inizialmente ho sospettato un errore di Talos OS nel montare i target iSCSI. Tuttavia, i log di Longhorn Manager indicavano che il volume era "incastrato" in una fase di distacco dal nodo precedente, che fisicamente non esisteva più a causa del wipe. 

### Il Ragionamento: Perché ho ridotto le repliche e forzato l'overprovisioning
Per risolvere questo stallo, ho dovuto prendere due decisioni cruciali:
1.  **Replica Count a 1**: In un cluster con soli due nodi worker, pretendere tre repliche per ogni volume database portava a uno stallo dello scheduler. Ho deciso che la ridondanza dello storage sarebbe stata gestita a livello applicativo (via Postgres) e a livello di backup (via S3), permettendo ai volumi locali di essere snelli e rapidi.
2.  **Overprovisioning al 200%**: Ho configurato Longhorn per permettere l'allocazione virtuale del doppio dello spazio fisico. Questo è necessario perché durante il bootstrap, il sistema tenta di creare nuovi volumi prima che quelli vecchi siano stati completamente rimossi dal database di stato dei nodi.

---

## Fase 2: L'Inferno dei Percorsi S3 e la Guerra ai Leading Slash

Una volta stabilizzato lo storage, mi sono scontrato con il cuore del problema: **pgBackRest**. L'integrazione tra CrunchyData PGO v5 e S3 è estremamente potente, ma altrettanto pignola. 

### L'Analisi del Fallimento: "No backup set found"
Nonostante i file fossero presenti nel bucket S3, il Job di restore falliva sistematicamente con un laconico `FileMissingError: unable to open missing file '/pgbackrest/repo1/backup/db/backup.info'`.

**Deep-Dive: Object Storage Pathing**
A differenza di un filesystem POSIX, un bucket S3 non ha cartelle reali, ma solo chiavi composte da stringhe (prefissi). Quando un tool come `pgbackrest` cerca un file, la presenza o l'assenza di uno slash (`/`) iniziale nel prefisso configurato può cambiare radicalmente la richiesta API.

Dopo aver utilizzato un Pod temporaneo con AWS CLI per ispezionare il bucket, ho scoperto che i dati risiedevano in `pgbackrest/repo1/...` (senza slash iniziale). Nel mio manifest `cluster.yaml`, avevo configurato `repo1-path: /pgbackrest/repo1`. L'operatore cercava quindi una "sottocartella" fantasma nella root. Ho rimosso il leading slash, allineando la configurazione alla realtà degli oggetti S3.

---

## Fase 3: Il Paradosso dell'Autenticazione nel Bootstrap

Risolto il problema del percorso, è emerso l'errore più ostico: `ERROR: [037]: restore command requires option: repo1-s3-key`.

### Il Ragionamento: Perché l'operatore non "eredita" le chiavi
Ho scoperto che l'operatore CrunchyData v5 gestisce i backup e i ripristini in modo asimmetrico. Sebbene le credenziali S3 fossero definite nel blocco `backups`, il Job di bootstrap (quello che fa nascere il cluster dal nulla) non le ereditava automaticamente. 

Ho dovuto implementare un refactoring dell' **ExternalSecret** e del manifesto del cluster per forzare l'iniezione. La soluzione è stata creare un file `s3.conf` iniettato dinamicamente tramite un Secret, e referenziarlo esplicitamente nel blocco `dataSource`.

### Implementazione Tecnica: La Configurazione "Sacra"

Ecco il segreto che ha sbloccato la situazione, mappando le chiavi di Infisical nel formato richiesto dal file di configurazione di pgBackRest:

```yaml
# infrastructure/configs/tazlab-db/s3-external-secret.yaml
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
    template:
      engineVersion: v2
      data:
        # File di config che CrunchyData monta nel pod di restore
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

E il manifesto del cluster che richiama esplicitamente questa configurazione per il bootstrap:

```yaml
# infrastructure/instances/tazlab-db/cluster.yaml
spec:
  dataSource:
    pgbackrest:
      stanza: db
      configuration:
        - secret:
            name: s3-backrest-creds # Fondamentale per l'autenticazione durante il restore
      repo:
        name: repo1
        s3:
          bucket: "tazlab-longhorn"
          endpoint: "s3.amazonaws.com"
          region: "eu-central-1"
      options:
        - --delta # Permette il ripristino su volumi esistenti se necessario
```

---

## Fase 4: La Validazione del Phoenix Protocol (PITR)

Per l'ultimo test, ho voluto alzare l'asticella. Non mi bastava recuperare un vecchio backup; volevo recuperare dati inseriti **secondi prima** della distruzione totale del cluster.

### Il Protocollo di Test:
1.  Inserimento **DATO_A**: Registrato nel Full Backup S3.
2.  Trigger manuale del backup.
3.  Inserimento **DATO_B**: Registrato solo nei log di transazione (**WAL**).
4.  Forzatura del `pg_switch_wal()` per assicurarmi che l'ultimo segmento venisse pushato su S3.
5.  **Nuclear Wipe**: Distruzione fisica di tutte le VM su Proxmox.

**Deep-Dive: Point-In-Time Recovery (PITR)**
Il PITR è la capacità di un database di tornare a un qualsiasi istante temporale passato combinando un backup completo ("la base") con i log delle transazioni (WAL - "i mattoni"). Se il sistema riesce a riprodurre i WAL su S3 dopo un wipe, significa che non abbiamo perso neanche una singola riga di dati, anche se inserita un istante prima del disastro.

### L'Ostacolo Finale: Il flag --type=immediate
Inizialmente, il ripristino mostrava solo DATO_A. Analizzando i log, ho capito che l'operatore utilizzava di default l'opzione `--type=immediate`. 
Questa opzione istruisce Postgres a fermarsi non appena il database raggiunge uno stato consistente dopo il backup full, ignorando tutti i log di transazione successivi. Ho rimosso il flag dal manifesto, permettendo al processo di "masticare" tutti i WAL disponibili fino all'ultima transazione ricevuta da S3.

---

## Risultato Finale: 11 Minuti e 38 Secondi

Utilizzando l'orologio di sistema per misurare ogni fase della rinascita, ecco la telemetria finale del bootstrap completo:

- **Layer Secrets**: 33s
- **Layer Platform (Proxmox + Talos)**: 3m 48s
- **Layer Engine & Networking**: 2m 51s
- **Layer GitOps & Storage**: 2m 25s
- **Database Restore (PITR da S3)**: ~2m 00s

**Totale: 11 minuti e 38 secondi.**

Al termine di questo intervallo, ho interrogato la tabella `memories`:
```sql
 id |             content              |          created_at           
----+----------------------------------+-------------------------------
  2 | DATO_B_VOLATILE_MA_IMMORTALE_WAL | 2026-02-10 14:55:10
  1 | DATO_A_NEL_BACKUP_S3             | 2026-02-10 14:54:02
```

Entrambi i dati erano lì. Il Phoenix Protocol ha avuto successo.

---

## Riflessioni Post-Lab: Il Futuro è Nomade

Il raggiungimento di questo traguardo trasforma radicalmente il mio approccio al cluster. Sapere che posso distruggere tutto e riavere ogni singola transazione database in meno di 12 minuti mi libera dalla "paura del ferro". 

### Cosa abbiamo imparato:
1.  **L'automazione non è magia**: È una sequenza di validazioni rigorose. Ogni slash, ogni nome utente (che deve rispettare lo standard RFC 1123, pena il fallimento della riconciliazione), ogni flag di restore conta.
2.  **Il dato è l'unica ancora**: L'infrastruttura deve essere considerata effimera per definizione. Investire tempo nel rendere il dato "immortale" via S3 vale mille volte il tempo speso a cercare di rendere "stabile" una VM.
3.  **Il cloud è vicino**: Questo setup a 3 nodi (1 CP + 2 Workers) con 24GB di RAM totali è già pronto per essere spostato su AWS EC2 o Google Cloud. La configurazione è agnostica; cambierà solo il layer di provisioning delle VM, ma il cuore della rinascita rimarrà lo stesso.

Il Castello di TazLab è ora ufficialmente indistruttibile. La sua forza non risiede nelle mura, ma nella sua capacità di risorgere dalle proprie ceneri, esattamente dove e quando decido io.

---
*Cronaca Tecnica a cura di Taz - HomeLab  DevOps Engineer.*
