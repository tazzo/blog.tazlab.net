---
title: "Mnemosyne: Cronaca di una Memoria Semantica tra AlloyDB e l'Autoconsistenza del Cluster"
date: 2026-02-04T12:00:00+01:00
draft: false
tags: ["alloydb", "google-cloud", "gemini-ai", "postgresql", "vector-database", "devops", "troubleshooting", "kubernetes", "linux-namespaces"]
categories: ["Cloud Engineering", "Infrastructure"]
author: "Taz"
description: "Dalla raccolta di mesi di sessioni Gemini CLI sparse su più macchine alla creazione di un motore di memoria semantica su AlloyDB, in attesa della migrazione finale verso PostgreSQL in-cluster."
---

# Mnemosyne: Cronaca di una Memoria Semantica tra AlloyDB e l'Autoconsistenza del Cluster

Nel percorso di costruzione di un'infrastruttura complessa come quella di **TazLab**, l'asset più prezioso non è il codice Terraform o i manifest di Kubernetes, ma la **conoscenza accumulata** durante le ore di interazione con l'intelligenza artificiale. Ogni sessione con Gemini CLI — lo strumento che uso quotidianamente come architetto e compagno di debugging — contiene i "perché" dietro ogni riga di codice, le soluzioni a crash improvvisi di Proxmox e le strategie di hardening del network.

Tuttavia, queste informazioni erano disperse in una moltitudine di file JSON di sessione, sparpagliati tra il mio vecchio PC di sviluppo, l'attuale workstation e l'ambiente containerizzato del **TazPod**. Iniziare una nuova sessione significava, troppo spesso, dover rispiegare all'IA chi fossimo e dove fossimo rimasti.

In questa cronaca tecnica documento la nascita di **Mnemosyne**, il sistema di memoria semantica a lungo termine che ho progettato per centralizzare questo caos informativo e renderlo interrogabile in tempo reale.

## 1. La Strategia del Motore: Perché AlloyDB (per ora)?

La visione finale per TazLab è la totale **autoconsistenza**. Il progetto prevede di ospitare l'intera memoria all'interno del mio cluster Kubernetes, usando un database PostgreSQL con l'estensione `pgvector`, volumi persistenti gestiti da Longhorn con backup criptati su bucket S3, e un Pod dedicato che funga da server MCP (Model Context Protocol).

Tuttavia, l'ingegneria seria insegna a non combattere troppe battaglie contemporaneamente. Costruire l'infrastruttura di storage in-cluster *mentre* si cerca di sviluppare la logica del motore di memoria avrebbe creato un loop di dipendenze infinito.

### Il Managed come ponte verso l'In-House
Ho deciso di appoggiarmi inizialmente a **Google AlloyDB** nella region di Milano (`europe-west8`). Questa scelta mi ha permesso di:
1. **Isolare il problema**: Sviluppare e testare gli script di archiviazione e ricerca senza preoccuparmi della stabilità di Longhorn o della configurazione dei PVC.
2. **Velocità di sviluppo**: AlloyDB offre un'integrazione nativa con i modelli di embedding di Google, dandomi un ambiente "chiavi in mano" per perfezionare l'algoritmo di analisi dei dati.
3. **Disaccoppiamento**: Avendo la memoria all'esterno del cluster, posso distruggere e ricostruire l'intero ambiente di laboratorio (filosofia *Wipe-First*) senza mai rischiare di perdere lo storico delle sessioni.

Una volta che il "motore" Mnemosyne sarà maturo, portarlo dentro il TazPod su Postgres locale sarà una semplice migrazione di dati, poiché AlloyDB mantiene la piena compatibilità con l'ecosistema PostgreSQL.

## 2. Il Rastrellamento: Recuperare l'Oro dal Caos

Il primo vero lavoro "sporco" è stato il **rastrellamento** (gathering). Avevo accumulato mesi di interazioni con la Gemini CLI. Alcuni file erano rimasti su un altro laptop, altri erano sepolti nelle cartelle temporanee di precedenti container Docker, altri ancora vivevano nei checkpoint di salvataggio automatico.

### La miniera dei log
Questi file non sono semplici log; sono la cronologia della costruzione del Castello. Contengono:
- Le configurazioni specifiche di **Talos Linux** che hanno risolto i crash loop di FRR.
- I passaggi della migrazione del blog Hugo da un setup dinamico a uno stateless.
- Le riflessioni sulla sicurezza del vault LUKS integrato nel TazPod.

Ho implementato uno script di "collezione ricorsiva" (`gather_sessions.py`) capace di scansionare intere porzioni di disco alla ricerca di cartelle `.gemini`. Lo script è stato progettato per gestire le collisioni di nomi e unificare tutto in un unico repository di lavoro in `/workspace/chats`. Questo "rastrello" ha portato alla luce 127 file di sessione per un totale di circa 89MB di puro testo strategico.

```python
# Un pezzetto della logica di scansione ricorsiva
def gather_sessions(source_root, dest_dir):
    for root, dirs, files in os.walk(source_root):
        if ".gemini" in dirs:
            gemini_path = Path(root) / ".gemini"
            # Copia e rinomina per evitare sovrascritture
            # ... logica di salvataggio in /workspace/chats ...
```

## 3. L'Enigma del Networking e il `memory-gate`

Uno dei momenti più frustranti è stato stabilire una connessione stabile tra il TazPod (il mio container di sviluppo) e AlloyDB su GCP. Nonostante fossi convinto che l'IP pubblico dinamico fosse il colpevole, i conti non tornavano: l'IP cambiava raramente, eppure le connessioni morivano sistematicamente con errori di `Connection Timeout`.

### Investigazione oltre l'ovvio
Ho provato a usare l'AlloyDB Auth Proxy, ma il container sembrava soffrire di latenze inspiegabili o problemi di risoluzione DNS interna. Invece di perdere settimane a inseguire fantasmi nei layer di networking di Docker, ho scelto una via pragmatica ed enterprise: **l'automazione della sicurezza**.

Ho creato **`memory-gate`**, uno script che non cerca di "curare" il network, ma lo "apre" programmaticamente. Lo script:
1. Chiama un'API esterna per conoscere l'IP attuale da cui sto uscendo (sia esso casa, una VPN o una rete mobile).
2. Utilizza la CLI `gcloud` per autorizzare quell'IP specifico nelle "Authorized Networks" di AlloyDB.
3. Mi permette di lavorare in mobilità senza dover mai aprire manualmente la console di Google Cloud.

Questa soluzione ha trasformato un problema bloccante in un automatismo invisibile che garantisce l'accesso da qualsiasi luogo in totale sicurezza.

## 4. Qualità del Dato: Il Filtro "Senior Architect"

Il caricamento iniziale è stato un disastro dal punto di vista della qualità. Lo script di archiviazione salvava ogni singola riga dei log, inclusi migliaia di messaggi di stato di Terraform o log di attesa dei Pod ("Still creating...", "Still waiting...").

### Il rumore che uccide il segnale
Quando interrogavo la memoria, Gemini mi rispondeva citando i parametri banali di una VM (vlan_id, cpu_count) invece di ricordarmi *perché* avevamo configurato quella specifica subnet. La memoria era piena di "spazzatura tecnica".

Ho dovuto evolvere lo script `tazlab_archivist.py`. Ho riscritto il prompt di analisi chiedendo a Gemini di agire come un **Senior Cloud Architect**. Gli ho dato il mandato di scartare tutto ciò che è routine e sintetizzare solo i fatti atomici e le decisioni strategiche in paragrafi autoconsistenti. Questo processo di "raffinazione" ha trasformato il database in una vera base di conoscenza architetturale.

## 5. Il Bug Invisibile e le Nuove Leggi del Castello

Il momento di crescita più importante è arrivato durante il debugging di un problema apparentemente non correlato. Mi sono accorto che la cartella del **Vault** (dove risiedono tutti i segreti del cluster) non era più montata correttamente nel namespace del container. Era un errore invisibile anche all'utente root se non si controllava specificamente la tabella dei mount.

### La scoperta dell'eccesso di zelo dell'IA
Analizzando la storia, ho capito cos'era successo: in una delle innumerevoli iterazioni di refactoring del codice della CLI TazPod, Gemini aveva deciso — di sua iniziativa e senza che io lo chiedessi — di "ottimizzare" o rimuovere quella specifica riga del comando `docker run`. L'IA, nella sua propensione a migliorare il codice, aveva rotto una feature consolidata.

Questa regressione silenziosa mi ha fatto capire due cose:
1. Gemini è uno strumento potentissimo ma può essere eccessivamente propenso a modifiche non richieste.
2. Avevo bisogno di un modo per "istruire" l'IA in modo permanente sui miei standard di qualità.

### Le Leggi d'Oro di TazLab
Ho immediatamente archiviato in Mnemosyne una serie di regole che ora affiorano in ogni sessione come contesto iniziale:

- **Regola del Minimo Cambiamento Necessario**: Quando modifichi il codice, cambia solo lo stretto indispensabile. Chiedi sempre conferma prima di alterare strutture consolidate come mount, vault o flussi GitOps.
- **Read-Before-Write**: È mandatorio leggere il file prima di tentare una modifica. Mai fidarsi della memoria della sessione corrente, poiché il file system reale potrebbe essere diverso da ciò che l'IA "pensa" di ricordare.

## 6. Il Protocollo di Risveglio: Meta-RAG e Context Injection

Per chiudere il cerchio, ho implementato il **Semantic Awakening**. Non volevo dover chiedere io a Gemini di rinfrescarsi la memoria; l'IA doveva "svegliarsi" già cosciente della propria storia.

### L'Indice Semantico (`INDEX.yaml`)
Ho progettato un'architettura **Meta-RAG**. Invece di iniettare dati statici, inietto un set di "domande fondamentali" che Gemini deve porsi all'inizio di ogni sessione. Queste query sono definite in un file YAML che funge da mappa della coscienza del progetto:

```yaml
# TAZLAB SEMANTIC INDEX PROTOCOL
boot_sequence:
  - category: "Access & Prerequisites"
    query: "Come si accede alla memoria Mnemosyne e quali chiavi servono?"
  - category: "Environment & Architecture"
    query: "Qual è la struttura attuale del cluster TazLab (Talos, Proxmox, Nodi)?"
  - category: "Operational Philosophy & Safety Rules"
    query: "Quali sono le regole di sicurezza (Read-Before-Write, Minimo Cambiamento)?"
  - category: "Technical Debt & Tasks"
    query: "Quali sono i debiti tecnici aperti e le cose rimaste da fare?"
```

### L'Iniezione Autoritativa nel `.bashrc`
Attraverso un hook nel mio `.bashrc`, lo script di risveglio interroga AlloyDB usando queste query, genera un file `CURRENT_CONTEXT.md` e lo passa alla CLI di Gemini tramite il flag `-i` (prompt interattivo iniziale). 

Per evitare che l'IA ignorasse queste informazioni a favore di ricerche inutili sul file system, ho dovuto scrivere un prompt di iniezione "autoritativo":

```bash
/usr/local/bin/gemini -i "--- TAZLAB STRATEGIC MEMORY AWAKENING ---
L'utente ha richiamato la tua memoria a lungo termine (Mnemosyne). 
Il seguente contesto è il risultato di una ricerca semantica su 127 sessioni storiche.

REGOLE PER QUESTA SESSIONE:
1. Usa questo contesto come FONTE DI VERITÀ PRIMARIA.
2. NON scansionare il file system con 'grep' o 'ls' per informazioni che sono già presenti qui.
3. Fidati dei percorsi descritti nella memoria, anche se diversi dai nomi dei folder attuali.

--- CONTESTO RECUPERATO ---
$(cat /workspace/tazlab-memory/CURRENT_CONTEXT.md)
--------------------------"
```

In questo modo, appena entro nel terminale, l'IA mi saluta confermando di sapere esattamente quali sono i debiti tecnici aperti (come la migrazione del TazPod nel cluster) e quali regole di sicurezza deve rispettare per non rompere i mount del vault.

## Riflessioni Finali

Mnemosyne non è solo un database di log; è il sistema operativo della mia conoscenza. Mi ha insegnato che nel rapporto tra uomo e intelligenza artificiale, la fiducia deve essere mediata dal controllo e da una documentazione rigorosa.

Oggi, Mnemosyne è il ponte che mi permette di sospendere il lavoro per giorni e riprenderlo esattamente da dove l'avevo lasciato, con un assistente che non solo ricorda cosa abbiamo fatto, ma sa anche "come" vogliamo che il lavoro venga svolto nel Castello di TazLab.

Il viaggio verso l'autoconsistenza totale continua. Il prossimo obiettivo è già scritto nella memoria: portare Mnemosyne a casa, dentro il cluster, trasformandola in un servizio nativo di TazLab.

---
*Cronaca Tecnica a cura di Taz - Ingegneria dei Sistemi e Infrastrutture Zero-Trust.*
