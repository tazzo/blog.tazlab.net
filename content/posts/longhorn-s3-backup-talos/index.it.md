+++
title = "Dalla Persistenza alla Resilienza: Orchestrazione di Backup Longhorn su AWS S3 in un Ambiente Talos Linux"
date = 2026-01-07T10:00:00Z
draft = false
description = "Un'analisi approfondita sull'implementazione di backup offsite per lo storage Longhorn utilizzando AWS S3 su un cluster Talos Linux immutabile."
tags = ["kubernetes", "longhorn", "aws-s3", "backup", "talos-linux", "disaster-recovery"]
author = "Tazzo"
+++

# Dalla Persistenza alla Resilienza: Orchestrazione di Backup Longhorn su AWS S3 in un Ambiente Talos Linux


## Introduzione: Il Paradosso della Disponibilità Locale

Nelle ultime settimane, il mio Homelab basato su **Talos Linux** e virtualizzato su Proxmox ha raggiunto un livello di stabilità operativa notevole. I servizi core come Traefik e il blog Hugo girano senza interruzioni, e il networking è stato blindato grazie all'assegnazione di IP statici ai nodi. Tuttavia, analizzando l'architettura con occhio critico, è emersa una vulnerabilità fondamentale: la confusione tra **High Availability (HA)** e **Disaster Recovery (DR)**.

Longhorn, il motore di storage distribuito che ho scelto per questo cluster, eccelle nella replica sincrona dei dati. Configurando una `replicaCount: 2`, ogni blocco scritto sul disco viene duplicato istantaneamente su un secondo nodo. Questo mi protegge se un singolo nodo fallisce o se un disco si corrompe. Ma cosa succederebbe se un errore di configurazione cancellasse il namespace `traefik`? O se un guasto catastrofico all'hardware fisico di Proxmox rendesse inaccessibili entrambi i nodi virtuali? La risposta è inaccettabile per un ambiente che ambisce a essere "Production Grade": perdita totale dei dati.

L'obiettivo della sessione odierna era colmare questo divario implementando una strategia di backup offsite automatizzata, utilizzando **AWS S3** come target remoto e gestendo l'intera configurazione secondo i principi dell'**Infrastructure as Code (IaC)**. Quella che doveva essere una semplice configurazione di parametri si è trasformata in una complessa operazione di upgrade del software e refactoring delle definizioni dichiarative.

---

## Fase 1: Fondamenta di Sicurezza e Gestione dei Segreti

Prima di toccare Kubernetes, ho dovuto preparare il terreno su AWS. Il principio guida in questo contesto è il **Principio del Minimo Privilegio (PoLP)**. Non è accettabile utilizzare le credenziali dell'account root o di un utente amministratore per un processo automatizzato di backup. Se quelle chiavi venissero compromesse, l'intero account AWS sarebbe a rischio.

### Creazione dell'Identità IAM e del Bucket
Ho creato un bucket S3 dedicato nella regione `eu-central-1` (Francoforte), scelta per minimizzare la latenza con il mio laboratorio in Europa. Successivamente, ho configurato un utente IAM tecnico, `longhorn-backup-user`, associandogli una policy JSON restrittiva. Questa policy concede esclusivamente i permessi necessari per leggere e scrivere oggetti in quel specifico bucket, negando l'accesso a qualsiasi altra risorsa cloud.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket",
                "s3:DeleteObject",
                "s3:GetBucketLocation"
            ],
            "Resource": [
                "arn:aws:s3:::tazlab-longhorn",
                "arn:aws:s3:::tazlab-longhorn/*"
            ]
        }
    ]
}
```

### Crittografia dei Segreti con SOPS
Il passo successivo riguardava come portare queste credenziali (Access Key e Secret Key) all'interno del cluster Kubernetes. L'approccio ingenuo sarebbe stato creare il Secret manualmente con `kubectl create secret` o, peggio, committare un file YAML con le chiavi in chiaro nel repository Git.

Ho optato per **SOPS (Secrets OPerationS)** combinato con **Age** per la crittografia asimmetrica. Questo workflow permette di versionare i file dei segreti nel repository Git in formato cifrato. Solo chi possiede la chiave privata Age (nel mio caso, presente sulla mia workstation di gestione) può decifrare il file al momento dell'applicazione.

Il file `aws-secrets.enc.yaml` generato contiene solo i metadati in chiaro, mentre il payload `stringData` è un blocco crittografato incomprensibile. L'applicazione al cluster è avvenuta tramite una pipeline di decifrazione al volo:

```bash
sops --decrypt aws-secrets.enc.yaml | kubectl apply -f -
```

Questo metodo garantisce che non esista mai un file in chiaro sul disco rigido che possa essere inavvertitamente committato o esposto.

---

## Fase 2: L'Odissea dell'Upgrade (Longhorn 1.8 -> 1.10)

Per sfruttare le ultime funzionalità di gestione dei backup e delle StorageClass, ho deciso di aggiornare Longhorn dalla versione 1.8.0 alla versione corrente 1.10.1. Qui mi sono scontrato con la rigidità (giustificata) dei sistemi stateful.

### Il Blocco del Pre-Upgrade Hook
Lanciando un `helm upgrade` diretto alla versione 1.10.1, il processo è fallito istantaneamente. I log del job di pre-upgrade riportavano un messaggio inequivocabile:

> `failed to upgrade since upgrading from v1.8.0 to v1.10.1 for minor version is not supported`

Questo errore evidenzia una differenza critica tra applicazioni *stateless* (come un web server Nginx) e applicazioni *stateful* (come uno storage engine). Un'applicazione stateless può saltare versioni a piacimento. Uno storage engine gestisce strutture dati su disco e formati di metadati che evolvono nel tempo. Longhorn richiede che ogni aggiornamento di versione "minor" (il secondo numero della versione semantica) venga eseguito sequenzialmente per permettere ai job di migrazione del database di convertire i dati in modo sicuro.

### La Strategia di Mitigazione Incrementale
Ho dovuto adottare un approccio a gradini, simulando manualmente il ciclo di vita del software che avrei dovuto seguire se avessi mantenuto il cluster aggiornato regolarmente.

1.  **Step 1: Upgrade alla v1.9.2.** Ho forzato Helm a installare l'ultima patch della serie 1.9. Questo ha permesso a Longhorn di migrare i suoi CRD (Custom Resource Definitions) e i formati interni. Ho atteso che tutti i pod `longhorn-manager` tornassero in stato `Running` e completi (`2/2`).
2.  **Step 2: Upgrade alla v1.10.1.** Solo dopo aver validato la salute del cluster sulla 1.9, ho lanciato l'aggiornamento finale.

Questa procedura ha richiesto tempo e pazienza, monitorando i log per assicurarsi che i volumi non venissero scollegati o corrotti durante il riavvio dei demoni. È un promemoria del fatto che la manutenzione in ambito Kubernetes non è mai un semplice "lancio e dimentico".

---

## Fase 3: La Battaglia per la Configurazione Dichiarativa (IaC)

Una volta aggiornato il software, il vero problema è emerso nel tentativo di configurare il `BackupTarget` (l'URL S3) in modo dichiarativo. La mia intenzione era definino tutto nel file `longhorn-values.yaml` passato a Helm, per evitare configurazioni manuali tramite la UI web.

### Il Limite di `defaultSettings`
Ho inserito le configurazioni nel blocco `defaultSettings` del chart Helm:

```yaml
defaultSettings:
  backupTarget: "s3://tazlab-longhorn@eu-central-1/"
  backupTargetCredentialSecret: "aws-backup-secret"
```

Tuttavia, dopo l'applicazione, la configurazione in Longhorn rimaneva vuota. Analizzando la documentazione e il comportamento del chart, ho riscoperto un dettaglio tecnico spesso trascurato: **Longhorn applica i `defaultSettings` solo durante la prima installazione**. Se il cluster Longhorn è già inizializzato, questi valori vengono ignorati per evitare di sovrascrivere configurazioni che l'amministratore potrebbe aver cambiato a runtime.

### Il Fallimento dell'Approccio Imperativo Dichiarato
Ho tentato di aggirare il problema creando manifesti YAML per oggetti di tipo `Setting` (es. `settings.longhorn.io`), sperando che Kubernetes forzasse la configurazione. Il risultato è stato un rifiuto da parte del Validating Webhook di Longhorn:

> `admission webhook "validator.longhorn.io" denied the request: setting backup-target is not supported`

Questo errore criptico nascondeva un cambiamento architetturale introdotto nelle versioni recenti. L'impostazione `backup-target` non è più una semplice chiave-valore globale gestita tramite l'oggetto `Setting`, ma è stata promossa a una **CRD dedicata** chiamata `BackupTarget`. Cercare di configurarla come un vecchio setting generava un errore di validazione perché la chiave non esisteva più nello schema delle impostazioni semplici.

### La Soluzione "Tabula Rasa"
Di fronte a uno stato del cluster disallineato rispetto al codice (Configuration Drift) e all'impossibilità di riconciliarlo pulitamente a causa dei residui delle versioni precedenti, ho preso una decisione drastica ma necessaria: **la disinstallazione completa del control plane di Longhorn**.

È fondamentale distinguere tra la cancellazione del software di controllo e la cancellazione dei dati. Disinstallando Longhorn (`helm uninstall`), ho rimosso i Pod, i Servizi e i DaemonSet. Tuttavia, i dati fisici sui dischi (`/var/lib/longhorn` sui nodi) e le definizioni dei Persistent Volume in Kubernetes sono rimasti intatti.

Reinstallando Longhorn v1.10.1 da zero con il file `values.yaml` corretto, il sistema ha letto i `defaultSettings` come se fosse una nuova installazione, applicando correttamente la configurazione S3 fin dal primo avvio. Al riavvio, i manager hanno scansionato i dischi, ritrovato i dati esistenti e ricollegato i volumi senza alcuna perdita di informazioni. Questa operazione ha validato non solo la configurazione, ma anche la resilienza intrinseca dell'architettura disaccoppiata di Kubernetes.

---

## Fase 4: Automazione e Strategie di Backup

Avere un target di backup configurato non significa avere dei backup. Senza automazione, il backup dipende dalla memoria umana, il che garantisce il fallimento.

### Implementazione di `RecurringJob`
Ho definito una risorsa `RecurringJob` per automatizzare il processo. A differenza dei cronjob di sistema, questi sono gestiti internamente da Longhorn e sono consapevoli dello stato dei volumi.

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: nightly-s3-backup
spec:
  cron: "0 3 * * *"
  task: backup
  retain: 7
  groups:
    - traefik-only
```

La scelta di mantenere solo 7 backup (`retain: 7`) è un compromesso tra sicurezza e costi di storage su S3.

### Granularità tramite Labels e Gruppi
Inizialmente, tutti i volumi erano nel gruppo `default`. Tuttavia, non tutti i dati hanno lo stesso valore. Il volume del blog Hugo contiene dati che sono già versionati su GitHub; il volume di Traefik contiene i certificati SSL privati, che sono insostituibili e critici.

Ho deciso di implementare una strategia di backup granulare:
1.  Ho creato un gruppo personalizzato `traefik-only` nel RecurringJob.
2.  Ho applicato una label specifica al volume di Traefik: `recurring-job-group.longhorn.io/traefik-only: enabled`.
3.  Ho rimosso le label generiche dagli altri volumi.

Questo approccio riduce il traffico di rete e i costi di storage, salvando solo ciò che è strettamente necessario.

### StorageClass Avanzata: Automazione alla Nascita
Per chiudere il cerchio dell'IaC, ho creato una nuova **StorageClass** dedicata: `longhorn-traefik-backup`.

```yaml
kind: StorageClass
metadata:
  name: longhorn-traefik-backup
parameters:
  recurringJobSelector: '[{"name":"nightly-s3-backup", "isGroup":true}]'
  reclaimPolicy: Retain
```

L'uso del parametro `recurringJobSelector` direttamente nella StorageClass è potente: qualsiasi volume futuro creato con questa classe erediterà automaticamente la politica di backup, senza bisogno di interventi manuali o patch successive. Inoltre, la policy `Retain` assicura che se anche cancellassi per errore il Deployment di Traefik, il volume rimarrebbe nel cluster in attesa di essere reclamato, prevenendo la cancellazione accidentale dei certificati.

---

## Conclusioni e Riflessioni

Questa sessione di lavoro ha trasformato il layer di storage del cluster da una semplice persistenza locale a una soluzione di livello enterprise resiliente ai disastri.

**Lezioni chiave apprese:**
1.  **Mai sottovalutare gli upgrade stateful:** I salti di versione nei database e negli storage engine richiedono pianificazione e passaggi incrementali.
2.  **L'IaC richiede disciplina:** È facile risolvere un problema con `kubectl patch`, ma ricostruire l'infrastruttura da zero (come abbiamo fatto disinstallando Longhorn) è l'unico modo per garantire che il codice descriva fedelmente la realtà.
3.  **Default vs Runtime:** Capire quando una configurazione viene applicata (init vs runtime) è cruciale per il debugging di Helm chart complessi.

L'infrastruttura è ora pronta per affrontare il peggio. Il prossimo passo logico sarà validare questo setup eseguendo un **Disaster Recovery Test** reale: distruggere intenzionalmente un volume e tentare il ripristino da S3, per trasformare la "speranza" del backup nella "certezza" del recupero.
