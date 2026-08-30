+++
title = "Ritorno di Memoria: Da un Meccanismo Artigianale a Hindsight, la nuova Memoria Multi-Agente per il TazLab"
date = 2026-08-29T20:15:00+01:00
draft = false
description = "Otto mesi dopo Mnemosyne, la migrazione della memoria tecnica del TazLab verso Hindsight: perché il fai-da-te non serviva più, le date fabbricate dai modelli, e un nuovo modo di lavorare con gli agenti."
tags = ["hindsight", "mcp", "kubernetes", "ai", "memoria"]
author = "Tazzo"
+++

## Il Paradosso dell'Effimero, otto mesi dopo

A febbraio, in [*Mnemosyne Rebirth*](/posts/mnemosyne-mcp-integration/), descrivevo il problema di fondo di questo laboratorio: l'ambiente di lavoro è effimero, e ogni nuova sessione di un agente AI è una tabula rasa. Nessuna memoria delle decisioni prese, dei bug risolti, di dove eravamo rimasti.

Ma la storia del TazLab spiega meglio di tutto perché la memoria sia diventata un problema. Il lab è nato con container Docker su un host, niente cluster, niente orchestrazione: era più rozzo, e andava bene così. Il punto di svolta è arrivato tra ottobre e novembre 2025, quando gli LLM sono diventati veramente agentici — modelli come Opus 4.x capaci di fare lavoro autonomo su più passi, scrivere file di configurazione, gestire operazioni complete. A quel punto ho smesso di accontentarmi dei container e ho costruito il cluster Kubernetes: con gli agenti di quel livello, scrivere manifest, configurazioni e automazioni era diventato fattibile — e il cluster diventava utile.

È esattamente lì che la memoria è diventata un bisogno pesante. Ogni sessione che aprivi o chiudevi richiedeva di rileggersi tutto: il codice, le cose fatte, com'era il sistema, dove eravamo arrivati. Con più agenti che lavoravano sugli stessi progetti il problema si moltiplicava: dovevano condividere la stessa memoria, sapere la situazione senza rileggere tutto ogni volta, senza rompere cose già fatte. Da quel bisogno è nato il meccanismo artigianale: un server MCP scritto in Go (**Mnemosyne**) che parlava con PostgreSQL, affiancato da un workspace di cronache, report e registri che gli agenti caricavano a inizio sessione.

Otto mesi dopo — un'eternità, nell'AI di oggi — l'ecosistema ha cambiato faccia: i framework si sono standardizzati attorno al Model Context Protocol e sono nati servizi di memoria multi-agente maturi. Quando diversi progetti del TazLab hanno raggiunto una maturità sufficiente da rendere la migrazione sensata, ho deciso di mettere alla prova uno di questi servizi, sostituendo il meccanismo artigianale invece di affiancarlo. Questo articolo racconta la prima tappa: l'installazione di **Hindsight** sul cluster, le scelte, i problemi — e la scoperta sgradevole che ha trasformato un import meccanico in un audit forense.

---

## La scelta: Hindsight contro le alternative

La valutazione è stata breve e pragmatica. I candidati erano due: **Hindsight** di Vectorize.io e **TencentDB Agent Memory** ([github.com/TencentCloud/TencentDB-Agent-Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory)), che mi aveva incuriosito per l'approccio integrato. Ho scelto Hindsight per tre ragioni concrete:

1. **Maturità e prontezza d'uso**: architettura a tre componenti pensata per Kubernetes, Helm chart ufficiale, documentazione seria, e un modello a *memory bank* che combacia con il requisito primario — agenti diversi che condividono la stessa memoria.
2. **Compatibilità con il ferro esistente**: vuole PostgreSQL con `pgvector`, e il TazLab ha già un cluster PostgreSQL gestito da Crunchy PGO con disaster recovery su S3. Zero componenti nuove.
3. **Estrazione semantica, non solo embedding**: qui c'è la differenza di fondo con il mio artigianale. Mnemosyne salvava il testo dei ricordi e lo convertiva in vettori numerici per cercare le memorie **simili** — una ricerca di somiglianza, per quanto buona. Hindsight fa un passo in più: un LLM legge il contenuto ed estrae **fatti atomici con date, entità e relazioni**, li consolida in sintesi, e li ricerca combinando quattro strategie (semantica, testo esatto, grafo, tempo). Non risponde a "cosa somiglia a questa domanda?" ma a "cosa sappiamo su questo argomento, quando è successo, e chi c'entra".

Il costo di questa architettura è un LLM in pipeline: ogni `retain` genera chiamate di estrazione. Ho collegato l'estrazione al gateway **opencode-go** con il modello `mimo-v2.5` — lo stesso gateway che usa Hermes sul lab — e gli embedding restano su `gemini-embedding-001`. La separazione diventerà importante a metà migrazione.

---

## Fase 1: Stateless su un cluster che esiste già

Il principio del deployment è lo stesso di tutto il TazLab: GitOps puro, nessun dato nello stato dei pod. Tre deployment in un namespace dedicato — l'API (immagine slim, ~300 MB di RAM contro i 4-8 GB della versione con modelli locali), un worker asincrono con identità statica, la dashboard di controllo — e **zero volumi**: tutto lo stato vive in PostgreSQL.

**Perché "stateless" qui non è un dettaglio.** Il cluster TazLab nasce e muore per design: `create.sh` e `destroy.sh` lo ricostruiscono da Terraform in un ciclo one-shot. Un deployment con volumi è un'eccezione che rompe la riproducibilità. Hindsight non li richiede: fatti, entità, grafo e coda dei task stanno in PostgreSQL, e il database esistente eredita il disaster recovery già configurato (backup pgBackrest su S3 con restore incrementale). Tradotto: distruggere e ricreare il cluster **non perde un ricordo**. Il paradosso dell'effimero, alla fine, si risolve da solo.

L'integrazione col PostgreSQL esistente avviene via certificati: utente dedicato con autenticazione `cert`-only, client certificate da Vault PKI, schema dedicato. Le API key arrivano da Vault, l'esposizione segue il pattern degli altri servizi (LoadBalancer sulla LAN con NetworkPolicy), e le quattro composizioni di manifest sono passate da Flux come tutto il resto.

Gli intoppi sono stati i classici di un'app non nata per Kubernetes, e ne cito due su tutti:

- **Collisione di variabili d'ambiente**: un Service chiamato `hindsight-api` fa sì che il kubelet inietti `HINDSIGHT_API_PORT=tcp://10.96.x.x:8888` in tutti i pod del namespace. Il codice fa `int(os.getenv("HINDSIGHT_API_PORT"))` → crash garantito. L'immagine upstream lo conosce e overridea la variabile; chi fa manifest raw deve saperlo.
- **pgvector non "trusted"**: da PostgreSQL 13 un'estensione marcata `trusted` può essere creata da un utente con privilegi adeguati. Il packaging di Crunchy **non ha quel flag**, quindi `CREATE EXTENSION vector` richiede superuser. La soluzione GitOps: dichiarare l'utente `postgres` nel cluster spec e un Job idempotente gestito da Flux che esegue l'estensione, con un loop di attesa per il bootstrap one-shot.

---

## Fase 2: 745 ricordi e le date che non tornavano

Con la piattaforma in piedi, la migrazione: 745 ricordi di Mnemosyne più il workspace di memoria strutturata (19 cronache archiviate, 57 report, lo stato del sistema). Ho scritto un importer dedicato con un protocollo preciso: un item alla volta, un file di stato aggiornato dopo ogni atterraggio — se il processo si ferma, si sa esattamente dove.

Il primo lotto è andato liscio. Poi il test a campione ha smesso di tornare: **36 ricordi datati 2024, e nessuno può esserlo**. Il contenuto era reale — parlava di DevPod, di TazPod, del setup del notebook — ma le date no. La memoria che descriveva la transizione a TazPod v0.1.7 era datata 22 maggio 2024: il tag `v0.1.0` esiste solo dal 21 gennaio 2026, e la v0.1.7 è mai stata taggata — è esistita un giorno solo, il 3 febbraio 2026, come documenta un commit.

**La diagnosi**: il writer LLM che all'epoca aveva generato quelle memorie aveva **allucinato gli anni** — spostati indietro di uno o due. Il contenuto era reale, le date no.

**La correzione**: riscrivere 38 date a mano era troppo rischioso. Ho lanciato quattro agenti indipendenti, ognuno con un pacco di memorie e un brief con le ancore verificabili (date dei primi commit, dei tag, dei file di chat reali nel vault). Gli agenti hanno incrociato le cronache del workspace, i report datati e la storia git, e hanno restituito 38 date corrette con evidenza e confidence — trovando anche una regola utile: in alcuni cluster il writer aveva spostato solo l'anno, in altri aveva inventato anche mese e giorno, quindi ogni item richiedeva il proprio riscontro.

**Purga e re-import**: eliminate dal bank le versioni con date fabbricate (cancellazione a cascata delle unit derivate), re-importate quelle con le date corrette. La scansione completa del bank ha confermato zero unit residuali nel 2024 — e ora il recall temporale funziona: chiedere "cosa è successo a gennaio 2026?" restituisce i fatti con la data giusta.

Il merito di averlo beccato va al **test a campione su contenuti reali**: l'import era terminato senza errori, i dati formalmente validi — e storicamente falsi. Solo cercando le cose per tema e controllando le date si vede che una memoria "riuscita" non trova quello che deve trovare.

---

## Fase 3: Il muro di quota e gli item invisibili

Durante la migrazione, la quota embedding del free tier Gemini — su una chiave condivisa con altri consumatori del lab — ha prodotto muri di `429` a orari non prevedibili. Il comportamento di Hindsight in queste condizioni è stata la scoperta tecnica più utile:

- Un retain accettato durante il muro **non fallisce del tutto**: l'op muore sull'embedding, ma **il contenuto estratto resta salvato** nel database — senza vettori.
- Un'unità senza vettore è **invisibile al recall**: esiste nell'inventario, non esiste per la ricerca.
- Le op fallite sono **terminali**: nessun auto-ripristino, e non esiste (ancora) un comando di re-embedding nativo.

La conseguenza operativa: **"done" significa op completata e ricercabile**, verificata via recall — non sufficiente che l'operazione sia stata accettata o che il documento esista. Gli item importati durante un muro vengono marcati in uno stato dedicato e ri-embeddati con una pass dedicata quando il budget giornaliero lo consente. Il pacing adattivo — che attende il `retryDelay` indicato da Google più un margine, e sospende l'import quando il muro persiste — evita di accumulare backlog invisibile.

---

## Il nuovo modo di lavorare (in costruzione)

La parte che mi entusiasma di più è ancora la più immatura. Hindsight offre meccanismi che il mio artigianale non aveva, e la migrazione è anche l'occasione per ripensare come gli agenti accedono alla conoscenza:

- **Direttive sempre-attive**: regole persistenti del bank iniettate in ogni estrazione e sintesi — le convenzioni del TazLab (niente segreti in chiaro, tutto via Git, tutto con log, revisione con agenti indipendenti prima dei build importanti) non sono più un file che gli agenti devono ricordarsi di leggere: stanno nel canale di ogni chiamata.
- **Mental models**: sintesi vive di un tema, ancorate a una query, che si auto-aggiornano a ogni consolidamento. Il primo è `tazlab-operating-doctrine`: le regole operative sempre attuali, consultabili con una chiamata.
- **Bank per agente**: ogni agente ha il suo bank (Hermes, TazPod, OpenClaw) con contesto e direttive propri, e condivide `tazlab-common` per la conoscenza infrastrutturale. Il disagio storico — contesti mantenuti a mano, agenti che non sapevano la situazione — ha una risposta strutturale: contesti preparati che gli agenti caricano da soli via MCP.

Questa parte è dichiaratamente **in costruzione**: quali contesti preparare, come strutturarli, cosa rendere sempre-attivo e cosa lasciare alla rilevanza semantica sono decisioni aperte che l'uso reale ci aiuterà a prendere. E anche la migrazione è a metà: i ricordi fino a febbraio 2026 sono dentro con date verificate, il grosso (marzo→agosto) entra a ritmo di quota nei prossimi giorni, un blocco alla volta, con test approfonditi a ogni blocco.

---

## Conclusioni

La migrazione è a metà e il bilancio è parziale. L'infrastruttura ha retto bene: il deployment si è integrato con PostgreSQL, Vault PKI e Flux senza componenti nuovi fuori dal ciclo destroy/create, e gli errori incontrati sono stati tutti corretti in Git. L'audit delle date ha invece mostrato un problema che l'import da solo non poteva vedere: dati formalmente validi e storicamente falsi. Il test a campione con controlli esterni — git, documenti reali — è stato l'unico modo di beccarlo, e da oggi fa parte del protocollo per ogni blocco.

Restano aperte le parti che contano di più: i ricordi ancora da importare, gli item salvati durante i muri di quota da ri-vettorizzare, e soprattutto la definizione di come gli agenti useranno il sistema — quali contesti preparare, quali regole rendere permanenti, dove confinare la conoscenza comune. Su questo l'uso reale insegnerà più di quanto riesco a progettare ora. Il meccanismo artigianale resta attivo in lettura finché la migrazione non è verificata per intero: se Hindsight si comporterà come sembra, sarà il momento di dismetterlo; se non lo farà, avrò imparato dove intervenire.
