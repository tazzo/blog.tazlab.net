+++
title = "Il PC si spegne, il Castello risorge: migrare il cluster Kubernetes su Hetzner in due ore"
date = 2026-10-28T12:00:00+02:00
draft = true
description = "Cronaca tecnica di un disastro hardware annunciato: quando la macchina fisica del laboratorio ha ceduto per surriscaldamento, la promessa del Castello Effimero è passata dalla teoria ai fatti. Come la separazione netta tra Terraform e Flux ha permesso la rinascita del cluster su Hetzner in sole due ore."
tags = ["kubernetes", "gitops", "fluxcd", "terraform", "hetzner", "disaster-recovery", "vault", "talos"]
author = "Tazzo"
+++

> **Nota di lavorazione:** Questa bozza documenta la cronaca dell'incidente hardware, la migrazione d'emergenza su Hetzner Cloud e l'audit architetturale che ha confermato la validità del disaccoppiamento tra Terraform e Flux.

## Introduzione: Il crash annunciato e il banco di prova

Negli articoli precedenti dedicati alla visione del **Castello Effimero**, ho descritto a lungo l'obiettivo fondante del mio homelab: costruire un'infrastruttura nomade, riproducibile e stateless, capace di rinascere da zero ovunque ci sia una connessione di rete e in tempi minimi. L'idea teorica era chiara: separare drasticamente il livello di provisioning fisico da quello applicativo. A Terraform il compito di preparare il terreno; a Flux CD il compito di popolare e governare il castello.

Il 27 ottobre 2026, la teoria è stata bruscamente chiamata a confrontarsi con la realtà. 

Il computer desktop che ospitava il cluster di casa (un nodo Proxmox VE su cui giravano le macchine virtuali Talos Linux e i container di servizio) si è spento improvvisamente per surriscaldamento. Nessun guasto al disco, nessun errore software o aggiornamento fallito: semplicemente, l'hardware fisico non ha più retto lo sforzo termico, entrando in spegnimento di protezione a singhiozzo. 

Di fronte a un PC che collassa dopo pochi minuti di accensione, le strade possibili erano due: tentare un accanimento terapeutico fatto di smontaggi, ventole di emergenza e manutenzioni locali, oppure premere il grilletto del piano nomade e **migrare l'intero cluster sul cloud Hetzner**.

Non abbiamo impiegato giorni per completare la transizione: **sono bastate circa due ore di lavoro effettivo**. 

Non si tratta di presunzione o di un colpo di fortuna: il risultato è la diretta conseguenza di scelte architetturali deliberate e pianificate con mesi di anticipo. L'incidente ci ha obbligato a mettere in pratica quello che avevamo preventivato di affrontare fin dall'inizio. L'unico motivo per cui sono servite due ore e non pochi minuti risiedeva nel fatto che lo strato Terraform per Hetzner non era ancora stato completamente rifinito e collaudato. Una volta steso quel terreno con Terraform, Flux ha ripristinato l'intera flotta applicativa in modo quasi istantaneo e praticamente indolore.

---

## Fase 0: Triage dello stato reale e salvataggio a caldo

Prima di avviare qualsiasi ricostruzione nel cloud, la priorità assoluta di un disaster recovery è distinguere ciò che è puramente effimero da ciò che è reale stato persistente. Se un elemento può essere ricostruito tramite codice o sincronizzato da Git, non va salvato; si salva solo ed esclusivamente ciò che non può essere generato nuovamente.

La mappatura delle risorse ha confermato la solidità dell'architettura:

| Componente | Tipologia di Stato | Strategia di Recupero |
|---|---|---|
| **Cluster Kubernetes (Talos)** | **Stateless** | Interamente definito nei repository Git (`tazlab-k8s` e `ephemeral-castle`). Zero dati unici sui dischi locali. |
| **Vault (Gestore Segreti)** | **Indipendente** | Già collocato preventivamente su una VPS Hetzner esterna; non risiedeva sulla macchina guasta. |
| **Database Applicativo PostgreSQL** | **Ripristinabile** | Backup continui gestiti da pgBackRest su bucket S3 compatibile. |
| **Ambrogio + Ambrogio Memory** | **Stato Reale** | Due database SQLite locali (`ambrogio.db` e `memory.db`, circa 135 MB) ospitati in container LXC. |
| **ADA (Casa degli Agenti)** | **Stato Reale** | Database `agent.sqlite` (450 MB) e configurazioni operative. |
| **21 Repository Git Locali** | **Audit di Coerenza** | Verifica immediata di commit locali non ancora inviati ai remote su GitHub. |

Sfruttando le brevi finestre in cui il PC riusciva a rimanere acceso prima di raggiungere le temperature critiche, abbiamo eseguito la sequenza di salvataggio in ordine rigoroso di priorità:

1. **Estrazione degli archivi utente:** Creazione rapida di tarball per le home dei container LXC contenenti i binari e i dati di Ambrogio, Memory e ADA.
2. **Audit e bundle Git:** Il controllo su 21 repository ha svelato una sorpresa insidiosa. Se la maggior parte dei progetti era allineata con GitHub, tre repository erano avanti: `tazpod` (+1 commit), `tazlab-secrets` (+16 commit) e soprattutto **`ada` con ben 125 commit non pushati**. Il container di Ada era stato configurato internamente con un repository bare locale e non aveva mai sincronizzato le modifiche sul remote GitHub. Abbiamo salvato immediatamente i bundle completi per evitare perdite catastrofiche di codice.
3. **Backup transazionale dei database SQLite:** Un errore frequente in situazioni di emergenza è copiare file di database mentre i motori sono ancora in esecuzione (`cp db.sqlite`). Con il motore SQLite in modalità WAL (Write-Ahead Logging), una copia a caldo genera file corrotti o inconsistenti. Il nostro primo tentativo a motore attivo ha mostrato una discrepanza tra record letti (`entries 22016` contro `22020`). Abbiamo quindi fermato ordinatamente i servizi ed eseguito il backup tramite comando atomico:
   ```bash
   sqlite3 memory.db ".backup memory-2026-10-27-final.sqlite"
   sqlite3 ambrogio.db ".backup ambrogio-final.sqlite"
   ```
   L'integrità è stata verificata immediatamente (`PRAGMA integrity_check;`) con sha256 verificato.
4. **Spegnimento forzato:** Fermati i container, la macchina è stata spenta definitivamente con `systemctl --force poweroff`. Da quel momento in poi, l'hardware di casa non è più stato toccato.

---

## Fase 1: Il collo di bottiglia di Terraform e la posa del nuovo terreno

La filosofia del Castello Effimero stabilisce una rigorosa **Division of Labour** (divisione dei compiti):
- **Terraform** possiede le risorse specifiche dell'infrastruttura e del provider (creazione nodi, configurazione Talos Linux, cloud firewall, controller di rete Hetzner CCM, storage Longhorn e bootstrap dei segreti essenziali).
- **Flux CD** possiede tutte le risorse agnostiche rispetto alla piattaforma (operatori interni, certificati, ingress, database, applicazioni e monitoraggio).

Perché la migrazione ha richiesto due ore invece di pochi minuti? 

La ragione risiede tutta in Terraform. Mentre il modulo per Proxmox era maturo, testato e consolidato da mesi di utilizzo, il modulo per Hetzner Cloud (`hcloud-talos`) era stato abbozzato e pianificato a livello architetturale, ma non era ancora stato collaudato end-to-end con tutte le unità di supporto. Mancavano le rifiniture dell'integrazione di rete privata (flannel su interfaccia `eth1`), il binding del Cloud Controller Manager di Hetzner e l'automazione dello script `create.sh`.

In circa un'ora e mezza di lavoro ingegneristico sul repository `ephemeral-castle` (sul branch `feat/hetzner-rebirth`), abbiamo colmato il debito tecnico:
1. Porting e completamento delle 4 unità mancanti: networking cloud, engine di bootstrap, storage Longhorn e gitops trigger.
2. Generazione dei nodi Talos Cloud (`k8s-cp-01` e `k8s-wk-01`) su macchine Hetzner con configurazione immutabile.
3. Allocazione del Load Balancer cloud pubblico (`188.245.75.246`) con instradamento del traffico verso gli endpoint privati dei nodi.

Non appena Terraform ha completato il provisioning dell'infrastruttura base, ha installato un unico componente fondamentale all'interno del cluster: **Flux CD**, consegnandogli le credenziali per connettersi al repository GitOps `tazlab-k8s`.

---

## Fase 2: Il trionfo di GitOps: Flux rialza il castello quasi senza modifiche

Qui si è rivelata la straordinaria potenza del paradigma GitOps: nel momento esatto in cui Flux ha avviato la riconciliazione del repository `tazlab-k8s`, l'intero ecosistema applicativo si è ricostruito da solo in cascata.

Non abbiamo dovuto riscrivere manifesti per i siti web, né riconfigurare a mano Nginx, Dex, Grafana, OAuth2-Proxy, MinIO o i controller di database. L'albero di 26 Kustomization dichiarate in Git è stato processato e applicato automaticamente:

```
Flux Kustomizations: 26/26 Ready
├── infrastructure-traefik          [Ready]
├── infrastructure-cert-manager     [Ready]
├── infrastructure-longhorn         [Ready]
├── infrastructure-operators-vso    [Ready]
├── infrastructure-vso-secrets      [Ready]
├── apps-database-pgo               [Ready]
├── apps-monitoring-grafana         [Ready]
├── apps-auth-dex                   [Ready]
└── apps-workload (blog, wiki, ...) [Ready]
```

L'invariante progettuale è stato rispettato in pieno: **il repository `tazlab-k8s` è rimasto rigorosamente unico e identico sia per l'ambiente locale sia per il cloud**. Non esiste un branch separato per Hetzner, né directory duplicate.

Le uniche differenze richieste dalla piattaforma cloud sono state gestite tramite l'astrazione dei dati in `cluster-vars`, iniettata da Terraform tramite `postBuild.substituteFrom`:
- **`ddns_replicas`**: impostato a `0` su Hetzner poiché il server cloud dispone di indirizzi IP pubblici statici, mentre su Proxmox è impostato a `1` per aggiornare costantemente il record dinamico della connessione domestica.
- **`vault_jwt_mount`**: configurato come `${vault_jwt_mount:=jwt}` (il default rimane `jwt` per Proxmox, mentre Hetzner seleziona `jwt-hcloud`).
- **Targeting del Load Balancer**: annotazione per il Cloud Controller Manager di Hetzner affinché il bilanciatore punti agli indirizzi IP privati dei nodi del cluster, ignorata in modo inerte da MetalLB nell'ambiente locale.

---

## Fase 3: Analisi degli intoppi tecnici e risoluzione metodica

Essendo la prima volta che il cluster veniva fatto nascere su Hetzner, sono emersi alcuni intoppi operativi durante la sequenza di avvio. Riportiamo l'analisi puntuale di ciascun problema secondo lo schema causa-effetto-risoluzione, perché è nella diagnosi precisa che risiede il valore didattico.

### 1. Il troncamento della CA di Vault (`gopass show -o`)
- **Sintomo:** I pod del Vault Secrets Operator (VSO) fallivano l'avvio segnalando: `invalid CA cert in secret "vso-system/vault-ca-cert": no valid certificates found`.
- **Diagnosi:** Nello script di bootstrap `create.sh`, il certificato della Certificate Authority di Vault veniva letto tramite `gopass show -o vpn/vault/ca`. Il flag `-o` (introdotto storicamente per copiare la sola password) stampa esclusivamente la prima riga dell'output. La prima riga di un certificato PEM è `-----BEGIN CERTIFICATE-----` (esattamente 27 byte). Il segreto iniettato in Kubernetes conteneva solo l'intestazione priva del payload crittografico.
- **Risoluzione:** Corretto il comando in `create.sh` rimuovendo il flag `-o` per estrarre il certificato PEM completo (1.854 byte).

### 2. Risoluzione dei nomi Tailnet (MagicDNS)
- **Sintomo:** VSO non riusciva a raggiungere Vault all'indirizzo `lushycorp-vault.magellanic-gondola.ts.net:8200`, restituendo errore `NXDOMAIN`.
- **Diagnosi:** A differenza dell'installazione su Proxmox in cui CoreDNS veniva sostituito da una configurazione personalizzata per inoltrare la zona `.ts.net`, il CoreDNS standard di Talos su Hetzner non aveva visibilità della rete Tailscale.
- **Risoluzione:** Abbiamo fatto convergere la risorsa `VaultConnection` verso il proxy di uscita egress interno al cluster (`lushycorp-vault.tailscale.svc.cluster.local:8200`), valorizzando `tlsServerName` sul nome MagicDNS originale per validare la corrispondenza del certificato TLS. Una soluzione elegante, pulita e completamente agnostica rispetto alla piattaforma.

### 3. Backend e ruoli JWT in Vault per Hetzner (`jwt-hcloud`)
- **Sintomo:** Le richieste di autenticazione dei ServiceAccount del cluster verso Vault venivano respinte con `no known key successfully validated the token signature`.
- **Diagnosi:** L'istanza esterna di Vault possedeva soltanto il mount di autenticazione `auth/jwt` collegato alla chiave pubblica del vecchio cluster locale. Il backend dedicato al cloud (`jwt-hcloud`) non era ancora stato instanziato in Terraform, e di conseguenza mancavano i dieci ruoli dedicati ai singoli componenti (database, monitoraggio, segreti applicativi).
- **Risoluzione:** Configurato su Vault il mount `jwt-hcloud` registrando la chiave pubblica dei ServiceAccount del nuovo cluster Talos, definite le quote di rate-limiting e replicati i ruoli dei componenti con mapping delle policy necessarie.

### 4. Validazione del claim `bound_issuer`
- **Sintomo:** Errore di validazione token JWT: `invalid issuer (iss) claim`.
- **Diagnosi:** Talos inietta all'interno del token di servizio un issuer coincidente con l'endpoint effettivo dell'API server (`https://kube.tazlab.net:6443`). Il backend Vault verificava il claim contro il valore di default di Kubernetes; Vault esegue un confronto letterale (*verbatim*) e non ammette formati disallineati o liste separate da virgole.
- **Risoluzione:** Allineato il parametro `bound_issuer` all'interno della configurazione Terraform al valore esatto dell'endpoint API del nuovo cluster.

### 5. Ripristino del database PostgreSQL da S3
- **Sintomo:** Al deploy di PGO (CrunchyData Postgres Operator), il cluster creava un database vuoto anziché ripristinare i dati storici.
- **Diagnosi:** PGO ripristina i dati tramite il blocco `dataSource` solo durante la prima inizializzazione di un `instance set`. Su Proxmox i dati risiedevano sul volume persistente locale e quel blocco era stato rimosso dopo il passaggio a PostgreSQL 17. Sul nuovo storage Longhorn di Hetzner, il volume era vergine.
- **Risoluzione:** Eseguito il restore manuale tramite pgBackRest puntando ai backup differenziali presenti su S3, e resa la procedura **dichiarativa** nel manifest condiviso:
  ```yaml
  dataSource:
    pgbackrest:
      stanza: db
      configuration:
        - secret:
            name: pgo-s3-creds
  ```
  In questo modo, qualsiasi futura rinascita opererà con la medesima idempotenza.

---

## Stato finale verificato e metriche

Al termine delle due ore di intervento, la catena di verifica ha restituito pieno esito positivo:

```text
Cluster:     Hetzner Cloud (2 nodi Talos Linux Ready)
Flux:        26/26 Kustomization sincronizzate (master@a8accb0)
VSO:         14/14 VaultStaticSecrets sincronizzati · 7/7 VaultPKISecrets emessi
Database:    PGO Postgres 17.2 attivo (4/4 pod, pgBouncer 2/2, repo-host 2/2)
Applicativi: Hindsight, Mnemosyne, Dex, OAuth2-Proxy, Grafana, pgAdmin tutti Running
Portali Web: blog=200, wiki=200, teaching=200, halloween=200 (TLS Let's Encrypt)
Apex Domain: tazlab.net -> 301 Redirect permanente su https://blog.tazlab.net
```

Tutti i servizi del laboratorio sono tornati pienamente operativi nel cloud, con crittografia TLS end-to-end e identità gestite centralmente da Vault.

---

## Conclusioni: Le lezioni che valgono un'architettura

Un incidente hardware improvviso è il test più spietato a cui possa essere sottoposta un'infrastruttura. Quando la macchina locale ha ceduto, non c'è stato spazio per improvvisazioni o correzioni manuali disperate: il sistema ha risposto esattamente come era stato progettato per rispondere.

Da questa esperienza emergono quattro lezioni fondamentali:

1. **Il disaccoppiamento IaC/GitOps è una polizza assicurativa:** Separare Terraform (il terreno) da Flux (le mura del castello) ha impedito il disastro. Avere un repository applicativo (`tazlab-k8s`) completamente agnostico rispetto all'hardware ha consentito di rimontare ventisei servizi complessi in pochi minuti netti dal momento in cui i nodi cloud sono diventati disponibili.
2. **Il debito tecnico si paga nel momento peggiore:** L'unica ragione per cui l'intervento ha richiesto due ore invece di quindici minuti è che lo strato Terraform per Hetzner non era stato rifinito in tempo di pace. Mantenere l'allineamento dei moduli di provisioning per tutti i target previsti è indispensabile per garantire un failover trasparente.
3. **I file SQLite richiedono disciplina atomica:** Copiare file di database attivi durante un guasto espone al rischio concreto di corruzione del dato. L'uso metodico di `sqlite3 .backup` e la verifica immediata di integrità hanno preservato mesi di memoria storica e conversazioni degli agenti.
4. **Git è il vero archivio dello stato:** L'audit preventivo prima del poweroff ha evitato la perdita di 125 commit di codice confinati in un repository bare locale. In un'architettura distribuita, un commit non spinto su un remote affidabile è un commit che non esiste.

Il Castello Effimero ha dimostrato sul campo la validità del suo principio ispiratore: le macchine fisiche muoiono, ma l'infrastruttura governata dal codice rinasce sempre.
