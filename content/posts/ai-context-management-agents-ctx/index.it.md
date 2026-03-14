+++
title = "AGENTS.ctx: Gestione Contesti per Agenti AI Senza Rispiegare Tutto da Capo"
date = 2026-03-14T11:00:00+01:00
draft = false
description = "Come ho risolto il problema dell'amnesia delle sessioni AI con un sistema di contesti organizzati: caricamento selettivo, agent-agnostic, e zero ripetizioni."
tags = ["AI", "DevOps", "Context Management", "Agents", "Workflow", "Productivity"]
author = "Tazzo"
+++

## Il Problema: Amnesia di Sessione

Ogni volta che riavvio un terminale e apro una nuova sessione con un agente AI, mi trovo di fronte allo stesso problema: devo rispiegare tutto da capo. Dove siamo, cosa stiamo facendo, quali sono le regole del progetto, quali problemi abbiamo già risolto.

È un ciclo frustrante. L'agente non ricorda nulla della sessione precedente. Devo reiniettare il contesto manualmente, oppure sperare che il sistema abbia qualche meccanismo di persistenza — ma spesso questi meccanismi sono opachi, inefficienti, o semplicemente non esistono.

Il problema diventa ancora più evidente quando si lavora su più progetti paralleli. Ogni progetto ha le sue convenzioni, la sua struttura, le sue regole non scritte. Caricare tutto nella stessa sessione non è solo inefficiente: è controproducente.

### Il Limite del Context Window

I modelli linguistici hanno un limite fisico: il **context window**. Quando la sessione inizia a riempirsi, le performance degradano. Intorno al 50% della capacità, la qualità delle risposte peggiora visibilmente. Il modello "dimentica" le istruzioni iniziali, perde coerenza, ripete informazioni.

Questo è il **context bloat**: troppe informazioni non pertinenti caricate nella stessa sessione. La soluzione non è avere più memoria, ma avere memoria *selettiva*.

## Due Tool, Due Scopi

Prima di arrivare alla soluzione, è importante distinguere due problemi diversi:

**Mnemosyne** è un MCP server che ho costruito per la **memoria a lungo termine**. Registra cosa ho fatto, quali problemi ho incontrato, come li ho risolti. È un archivio consultabile: quando un problema si ripresenta, cerco nei ricordi e trovo la soluzione applicata in passato. È utile per il troubleshooting, per la documentazione automatica, per costruire una knowledge base personale.

**AGENTS.ctx** risponde a un problema diverso: il **contesto attivo**. Non voglio ricordare cosa ho fatto tre mesi fa — voglio che l'agente sappia *ora* dove siamo, cosa stiamo facendo, quali regole seguire. E voglio che lo sappia senza che io debba ripetere tutto ogni volta.

Mnemosyne è il diario storico. AGENTS.ctx è il brief operativo.

## L'Architettura: Indirezione e Caricamento Selettivo

L'idea centrale di AGENTS.ctx è semplice: **non caricare tutto, caricare solo il necessario**.

La struttura si basa su tre livelli:

### Livello 0: AGENTS.md (Entry Point)

Nella directory di lavoro (`/workspace`), un file `AGENTS.md` contiene le istruzioni base per l'agente. Dice cosa fare all'avvio, dove trovare i contesti, come gestirli.

Questo file è leggero, pochi paragrafi. Il suo compito è indicare la strada, non trasportare il carico.

### Livello 1: AGENTS.ctx/CONTEXT.md (Base Context)

Nella cartella `AGENTS.ctx/`, un file `CONTEXT.md` contiene il contesto base: la lista dei contesti disponibili, le regole generali che si applicano a tutti i progetti, la struttura delle cartelle.

Questo file viene caricato automaticamente all'avvio. È il "sistema operativo" dei contesti: fornisce l'indirizzario e le regole fondamentali.

### Livello 2: Contesti Specifici

Ogni contesto ha la sua sottocartella. Possono essere:

- **Progetti**: `tazpod/`, `ephemeral-castle/`, `tazlab-k8s/`
- **Workflow generici**: `blog-writer/`, `plans/` — per attività ripetibili
- **Utilità**: contesti che caricano solo regole, si usano e si chiudono

Quando dico "lavora nel contesto X", l'agente carica solo quel file. Niente di più, niente di meno. Finito il lavoro, chiudo la sessione e riparto pulito, pronto per un altro contesto.

### Contesti Composti

Alcuni lavori richiedono più contesti contemporaneamente. Ad esempio, "cluster" è un contesto composto che carica sia `ephemeral-castle` (l'infrastruttura Proxmox/Talos) sia `tazlab-k8s` (le configurazioni Kubernetes). L'agente legge entrambi i file e unisce le regole.

Questo permette di lavorare su sistemi complessi senza dover duplicare informazioni.

## Agent-Agnostic by Design

Una scelta deliberata: tutto è basato su file di testo in cartelle semplici. Niente database, niente formati proprietari, niente lock-in.

Questo significa che posso usare **qualsiasi agente**: Gemini CLI, Claude Code, pi.dev. Basta che l'agente sappia leggere un file di testo e seguire istruzioni.

La portabilità è fondamentale. Non voglio che il mio workflow dipenda da uno strumento specifico. Se domani scopro un agente migliore, voglio poterlo adottare senza ricostruire tutto il sistema.

### Ispirazione e Attribuzione

L'idea non è mia. L'ho vista in [questo video](https://youtu.be/MkN-ss2Nl10), che mostra un approccio simile per gestire contesti con gli agenti AI. Ho adattato il concetto al mio workflow, aggiungendo la struttura a livelli, i contesti composti, e l'integrazione con il mio sistema esistente.

## Come Funziona in Pratica

La sequenza di avvio è:

1. L'agente legge `/workspace/AGENTS.md`
2. Segue l'istruzione: "leggi `AGENTS.ctx/CONTEXT.md`"
3. Il base context lista i contesti disponibili
4. Quando dico "contesto X", l'agente legge `AGENTS.ctx/X/CONTEXT.md`

### Struttura di un Contesto

Ogni contesto può contenere:

- `CONTEXT.md`: le istruzioni principali
- `scripts/`: script di interazione (deploy, test, utility)
- `docs/`: documentazione aggiuntiva
- `assets/`: file di configurazione, template, risorse

La struttura è flessibile. L'importante è che `CONTEXT.md` spieghi cosa c'è e come usarlo.

### Esempio: Contesto tazpod

**TazPod** è una CLI Go per gestire un ambiente di sviluppo nomade e secrets-aware. Fornisce:

- Un vault AES-256-GCM in RAM per i secrets (si monta con `tazpod unlock`, si azera con `lock`)
- Container Docker con tutto il toolchain (kubectl, terraform, helm, neovim, ecc.)
- Sync automatico dell'identità su S3 per portabilità
- Integrazione con Infisical per secrets management

Il contesto `tazpod/CONTEXT.md` spiega all'agente l'architettura a tre livelli (host CLI, tmpfs enclave, container), i comandi principali, i path hardcoded, e le procedure custom (come il push GitHub con token).

Quando lavoro su tazpod, l'agente ha subito il quadro completo: non devo spiegare cos'è il vault, come funziona l'enclave, o dove stanno i file. Il contesto è compatto e focalizzato.
## Trade-offs e Lezioni Imparate

### Cosa Funziona Bene

- **Caricamento esplicito**: so esattamente cosa viene caricato
- **Separazione netta**: ogni progetto ha il suo spazio
- **Zero magia**: niente auto-discovery che carica cose inaspettate
- **Portabilità**: funziona con qualsiasi agente

### Cosa Potrebbe Migliorare

- **Gestione manuale**: devo aggiornare le tabelle quando aggiungo contesti
- **Niente inferenza**: l'agente non indovina il contesto, deve essere esplicito
- **Overhead iniziale**: richiede un po' di setup

Il trade-off principale è tra comodità e controllo. Ho scelto il controllo.

## Conclusione: Contesto Compatto, Performance Migliori

AGENTS.ctx risolve un problema pratico: evitare di ripetere le stesse cose ogni volta che apro una sessione. La soluzione non è più memoria, ma memoria organizzata.

Indirezione, caricamento selettivo, contesti separati. L'agente ha solo il necessario per il lavoro corrente. Niente bloat, niente degradazione.

E quando cambio agente, il sistema viene con me.
