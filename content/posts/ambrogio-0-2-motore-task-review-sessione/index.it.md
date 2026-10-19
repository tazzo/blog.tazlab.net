+++
title = "Ambrogio 0.2: Dal Controllo degli Agenti al Motore di Task, la Review nella Stessa Sessione e l'Albero Fuori Controllo"
date = 2026-10-10T06:00:00+02:00
draft = false
description = "Il passaggio da Ambrogio 0.1 a 0.2: perché abbiamo messo al centro il task su worktree Git, come funziona la review che rimanda gli errori allo stesso agente senza perdere il contesto, i bug del motore che bocciavano lavori corretti e cosa è successo quando gli agenti hanno iniziato a generare task da soli."
tags = ["ambrogio", "agenti", "orchestrazione", "golang", "git", "worktree", "devops"]
author = "Tazzo"
+++

## Perché siamo passati dalla 0.1 alla 0.2

Con la versione 0.1 di Ambrogio avevo risolto il problema più fastidioso dei sistemi precedenti: gli agenti restavano attivi in memoria e potevo parlargli attraverso un'unica interfaccia senza ricreare il contesto da zero a ogni domanda.

Restava però un problema di affidabilità sul lavoro consegnato. Nella 0.1 al centro di tutto c'era l'agente: gli davo un compito, lui lavorava e alla fine scriveva un messaggio dicendo di aver finito. Come avevo già visto in passato, però, il fatto che un agente dichiari «tutto fatto e testato» non significa che il codice compili davvero o che i file siano stati committati sul branch giusto.

Con **Ambrogio 0.2** abbiamo cambiato il centro del sistema: l'unità fondamentale non è più l'agente, ma **il task associato a un branch e a un worktree Git dedicato**, accompagnato da un controllo automatico (**gate**) e da una **review** prima della chiusura.

## La scelta fondamentale: fare la review prima di chiudere la sessione del worker

Quando si introduce un passaggio di revisione (un secondo controllo che verifica il lavoro fatto dal primo agente), il rischio è di ricadere esattamente nella trappola di Multica:

1. l'agente A fa il lavoro e si spegne;
2. l'agente B fa la review, trova un errore e riapre il task;
3. parte un nuovo agente C che non sa nulla di quello che è successo prima, deve rileggere tutti i file del progetto da capo, capire cosa voleva dire la review e rifare i controlli da zero, moltiplicando i token consumati.

Per evitare questo spreco, nella 0.2 ho voluto una regola precisa sul ciclo di vita della sessione: **il worker che consegna il lavoro non viene chiuso finché la review non è passata**.

Il flusso funziona così:

- il worker esegue il compito nel suo worktree, prepara la consegna e **resta in attesa mantenendo aperta la propria sessione**;
- in quello stesso momento partono il gate automatico (che verifica che l'albero Git sia pulito, che i commit ci siano e che gli artefatti richiesti esistano) e la review;
- se il gate o la review trovano un problema, il rifiuto viene rimandato indietro **alla stessa sessione del worker che ha appena fatto il lavoro**. L'agente ha ancora in memoria tutto quello che ha appena scritto e letto, corregge subito il punto segnalato e riconsegna;
- la sessione dell'agente viene chiusa e scartata **solo quando il task ha superato la review ed è chiuso definitivamente**.

In questo modo si ottiene la sicurezza di una verifica indipendente senza pagare il costo di ricaricare da zero il contesto a ogni correzione.

## Quando è il motore a sbagliare: quattro bug che davano la colpa agli agenti

Appena messo in funzione il meccanismo di gate e review (che dopo un numero massimo `K` di tentativi falliti mette il task in *escalation* chiedendo il mio intervento), ho visto decine di task finire bloccati in escalation.

L'istinto iniziale sarebbe stato pensare che gli agenti lavorassero male. Guardando da vicino i task bloccati, invece, mi sono accorto che in moltissimi casi il lavoro dell'agente era corretto: **era il nostro motore a sbagliare i controlli e a contare i propri errori come fallimenti dell'agente**. In un solo giorno di verifica sul database abbiamo trovato quattro bug di questa famiglia.

### 1. Il controllo eseguiva la descrizione invece del comando

Ogni artefatto richiesto da un task ha un percorso (`path`) e una condizione di verifica (`condition`). Nella funzione che eseguiva il controllo automatico (`review.runOne`), i due campi erano stati invertiti: il motore passava a `/bin/sh -c` la frase descrittiva in inglese invece del comando di verifica.

Il risultato nei log era `/bin/sh: 1: the: not found`. Su 72 escalation totali, **27 erano state causate da questo singolo errore** (93 eventi `condition.broken`), bocciando lavori che gli agenti avevano completato regolarmente.

### 2. I riavvii del motore contati come bocciature del task

Ogni volta che ricompilavamo e riavviavamo Ambrogio mentre un worker stava lavorando, il processo veniva interrotto e restituiva l'errore Go `context canceled`. Il runner catturava quell'errore nel ramo `default` dello switch e **incrementava il contatore dei tentativi falliti del task**.

Così, sei task su nove erano finiti in escalation senza aver mai ricevuto nemmeno un verdetto di review, e uno ci era finito nonostante avesse già tre verdetti `pass` registrati, solo perché il motore era stato riavviato durante l'esecuzione. Da lì abbiamo scritto una regola ferrea nel codice: **un guasto o un riavvio del motore non deve mai diventare una bocciatura del task dell'agente**.

### 3. Il database SQLite committato dentro il repository Git

Per verificare che un agente non lasci file dimenticati fuori dai commit, il gate controlla che `git status` nel worktree sia completamente pulito alla consegna.

Peccato che nel repository stesso di Ambrogio fossero stati committati per sbaglio il file `data/ambrogio.db` e i suoi file temporanei `-shm` e `-wal`, e mancasse `__pycache__` nel `.gitignore`. Ogni volta che veniva creato un worktree o eseguito un test Python, quei file risultavano modificati e il gate rifiutava la consegna dell'agente dicendo *"the tree has N uncommitted change(s)"*, anche quando il codice scritto dall'agente era perfetto.

### 4. Accorgersi che la quota del modello AI è finita senza bruciare i task

Un altro caso concreto è cosa succede quando si esaurisce il credito o la quota oraria dell'account del provider AI. All'inizio il watchdog del motore si accorgeva del problema solo dopo che tre task reali erano falliti in cinque minuti — cioè bruciando tre tentativi sulla pelle dei task in coda.

Avevo provato a controllare lo stato interrogando l'endpoint `GET /models`, ma quell'endpoint risponde sempre `200 OK` anche quando il credito è a zero, perché restituisce solo un elenco statico. La soluzione che ha funzionato subito è stata una **sonda di completamento da un singolo token**, eseguita usando la stessa identica chiave API usata dai worker: quando il credito è finito non consuma nulla e restituisce immediatamente `402 Insufficient account funds`, permettendo a una routine in puro codice Go di mettere subito in pausa le code prima che parta qualsiasi agente.

## L'esperimento "auto-Ambrogio" e il problema degli alberi di task

Sistemati i controlli, ho voluto fare una prova spinta: usare Ambrogio esclusivamente tramite la sua API HTTP, mettendo un agente nel ruolo di **guardiano** incaricato di monitorare il sistema e aprire task di correzione, e attivando il meccanismo delle **proposte** (ogni worker, nel chiudere il proprio report, poteva proporre fino a 5 task successivi per completare il lavoro o risolvere problemi trovati lungo la strada).

Da un lato la prova ha dimostrato che il motore funzionava davvero: partendo da un singolo messaggio con cui chiedevo di migliorare un pannello delle impostazioni, il sistema ha gestito da solo un albero di 37 task su otto livelli, superando tre riavvii e quattro conflitti di merge, e i worker hanno persino trovato e corretto cinque bug nel codice che il guardiano aveva scritto un'ora prima.

Dall'altro lato, però, lasciare che gli agenti generassero e accodassero task in autonomia ha fatto esplodere due problemi evidenti:

1. **La moltiplicazione incontrollata dei task:** a partire da 15 segnalazioni iniziali, ogni task figlio ha generato a sua volta fino a 5 nuove proposte. In poche ore ci siamo trovati con **122 task aperti** in coda (64 nati nella prima mezz'ora, poi 19, poi 15). Anche se il motore ne eseguiva solo pochi alla volta, la coda si riempiva di lavori secondari che non avevo mai chiesto di fare.
2. **L'inversione permanente della coda per colpa delle priorità ereditate:** nel database, la funzione `OpenChildren` assegnava automaticamente a ogni task figlio la stessa urgenza (`urgency`) del task padre. Poiché un albero di task di test era stato creato con `urgency = 1`, tutti i suoi ventuno discendenti nascevano con `urgency = 1` e continuavano a scavalcare i bug veri del motore che erano stati aperti con `urgency = 0`, lasciandoli fermi in attesa per ore.

## Cosa ci ha portato alla versione 0.3

L'esperienza con la 0.2 mi ha lasciato due certezze:

- tenere aperta la sessione del worker durante il gate e la review è la scelta giusta, perché evita di rileggere il contesto da capo quando c'è qualcosa da correggere;
- lasciare che gli agenti aprano e facciano partire alberi di task da soli (o che tocchino direttamente i branch principali del repository) toglie controllo a chi guida il laboratorio.

Per avere uno strumento davvero affidabile serviva un ultimo passo: togliere agli agenti sia il potere di far partire lavori non approvati sia l'accesso diretto a Git e ai segreti, spostando tutta la gestione dei branch, delle pull request e della sicurezza dentro il motore in Go. È quello che abbiamo fatto con **Ambrogio 0.3**.
