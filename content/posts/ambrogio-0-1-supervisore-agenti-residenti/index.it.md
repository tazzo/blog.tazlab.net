+++
title = "Ambrogio 0.1: Perché Ho Scritto da Zero il Mio Supervisore di Agenti (e i Problemi del Primo Giorno)"
date = 2026-10-06T06:00:00+02:00
draft = false
description = "Come è nato Ambrogio dopo le prove con Paperclip, Multica e Buzz: un singolo binario in Go con SQLite e agenti residenti via ACP, e i problemi reali affrontati nelle prime 24 ore tra processi fermi a metà e il nodo Proxmox saturato dai browser headless."
tags = ["ambrogio", "agenti", "orchestrazione", "golang", "sqlite", "proxmox", "lxc", "devops"]
author = "Tazzo"
+++

## Da dove nasce l'idea di Ambrogio

Dopo aver provato in sequenza Paperclip, Multica e Buzz, avevo finalmente chiaro cosa non funzionava per il mio modo di lavorare nel laboratorio.

Con i sistemi basati su code di ticket come Multica, ogni passaggio di mano creava un nuovo task e avviava un agente nuovo da zero: l'agente che iniziava il lavoro non era mai quello che lo portava a termine, e a ogni passo il nuovo arrivato doveva rileggere tutto il repository e rifare le stesse verifiche, bruciando una quantità enorme di token anche per compiti banali. Con Buzz avevo visto il vantaggio di parlare con agenti già presenti in un canale, ma portarsi dietro un relay Nostr, un client da ricompilare in Rust e un'applicazione desktop obbligatoria era troppo macchinoso.

Così il 1° ottobre ho deciso di chiudere gli esperimenti esterni e scrivere da zero uno strumento su misura per il laboratorio: **Ambrogio**.

## Le scelte architetturali della versione 0.1

Per la prima versione (`0.1`) mi sono dato poche regole molto semplici, pensate per eliminare alla radice la complessità degli strumenti precedenti:

1. **Un singolo binario in Go sul container di lavoro (`CT106`):** niente microservizi sparsi, niente container aggiuntivi da orchestrare e nessuna dipendenza esterna. Un solo processo che si avvia in una frazione di secondo e possiede una sola cartella di lavoro.
2. **Agenti residenti gestiti tramite protocollo ACP (`omp acp`):** invece di far nascere e morire un agente per ogni micro-task, il supervisore tiene attivi i processi degli agenti in background. Quando assegno un compito o faccio una domanda, parlo con lo stesso agente che ha già in memoria il contesto della sessione.
3. **Un'unica interfaccia di conversazione:** nella pagina web io parlo in una sola chat con **Ambrogio**, che fa da punto di ingresso. Gli altri agenti lavorano dietro le quinte sui compiti assegnati e compaiono nella pagina come attività in corso, senza costringermi a rincorrere dieci stanze di chat diverse.
4. **Un solo database SQLite aperto esclusivamente dall'hub:** lo stato di agenti, issue e permessi vive in un file SQLite locale. Nessuno script esterno e nessuna pagina web può leggere o scrivere quel file direttamente: **tutto deve passare dall'API HTTP dell'hub** (usata allo stesso modo dal terminale, dal bridge MCP e dalla pagina web).

Questa struttura mi ha permesso di avere il sistema in piedi e funzionante in una sola giornata. Il secondo giorno, però, abbiamo smesso di «costruirlo» e abbiamo iniziato a usarlo per davvero, chiudendo oltre cento issue in una sessione. Ed è lì che sono usciti i primi problemi reali.

## I quattro problemi emersi nel primo giorno d'uso

### 1. Due posti che rispondono alla stessa domanda con numeri diversi

Appena aperta l'interfaccia web su un carico di lavoro vero, mi sono accorto che i numeri non tornavano: il contatore nella barra laterale indicava un numero di agenti attivi, mentre l'elenco principale ne mostrava un altro; una issue già chiusa continuava a riproporre una richiesta di attesa ogni cinque minuti; e il numero di versione del programma cambiava da solo senza aver ricompilato il binario perché veniva letto da Git a runtime.

La causa era sempre la stessa: invece di leggere il dato direttamente dal database SQLite nel momento in cui serviva, alcune parti del programma tenevano copie o contatori in memoria che finivano per disallinearsi. La regola che ho fissato da quel momento è che **la verità sta solo nella riga del database e si legge sul momento**, senza mantenere stati duplicati in RAM.

### 2. I difetti dell'interfaccia che i test sul codice non vedono

Tutti i test automatici sull'API passavano con successo, ma usando la pagina web dal browser sono saltati fuori subito errori banali quanto bloccanti:

- la casella di testo (`textarea`) in cui scrivere i messaggi non ereditava il colore chiaro del testo dal `body`, quindi scriveva in nero su sfondo scuro risultando invisibile;
- cliccando su alcune voci del menu l'indirizzo nella barra del browser (`location.hash`) cambiava, ma la vista rimaneva ferma sulla schermata precedente;
- cliccando sul nome di un agente nella lista si apriva sempre la chat principale di Ambrogio invece del dettaglio di quell'agente.

Nessun test sul backend può accorgersi che un testo è nero su sfondo nero. Da qui la regola pratica: **una modifica si verifica nel posto in cui viene letta dall'utente**, aprendo la pagina vera, non fermandosi al fatto che l'API restituisca `200 OK`.

### 3. Gli agenti che si fermavano tra un turno e l'altro

Con 14 agenti configurati e un limite massimo di 4 (poi portato a 7) agenti attivi in contemporanea, il lavoro procedeva a strappi: un agente completava un singolo passo, entrava nello stato `waiting_for_operator` e si fermava lì, anche se aveva ancora una issue aperta da finire. In una sola sessione ho dovuto risvegliare gli agenti a mano sei volte per far andare avanti la coda.

Il problema era che avevo lasciato al modello AI il compito di decidere quando passare al compito successivo. Ho risolto spostando questa logica direttamente nel codice Go del supervisore:

- se un worker ha una issue aperta, non sta eseguendo un turno e non è bloccato in attesa di un permesso, un **timer interno (tick)** gli invia automaticamente il comando di continuare;
- se c'è una issue aperta senza proprietario e c'è un agente libero, l'**assegnazione avviene in modo meccanico nel codice**, prendendo la issue più vecchia.

Tutto ciò che è puramente meccanico deve stare nel codice del supervisore, non nelle istruzioni date al modello.

### 4. L'incidente di memoria su CT106 che ha quasi bloccato il nodo Proxmox

Il problema più grave della giornata non è venuto dal codice Go di Ambrogio (che consumava pochissimo), ma dai processi figli avviati dagli agenti.

Durante i test dell'interfaccia, i runtime degli agenti avevano lasciato aperti decine di processi **Chromium headless**, arrivando a consumare da soli **4,27 GB di RAM**. Il container `CT106` ha toccato il suo limite di 8 GiB di RAM e ha riempito al 100% il gigabyte di swap; la page cache del kernel è scesa a 10 MB, costringendo ogni processo a rileggere continuamente le proprie pagine eseguibili dal disco SSD (189 milioni di *file refault*, disco fisso al 100% di utilizzo).

A quel punto è scattata una trappola che avevamo costruito noi stessi settimane prima:

1. I limiti di I/O sul disco del container (`io.max`), pensati per proteggere l'host Proxmox, hanno messo in coda i processi di `CT106` (`102` processi bloccati in `rq_qos_wait`), congelando lo spazio utente del container, compresi `cron` e `systemd-logind`.
2. Il timer di emergenza che avevamo creato per uccidere i processi Chromium orfani girava **dentro** `CT106`: essendo il container congelato, il timer non poteva partire per salvarlo.

L'ho risolto intervenendo su due livelli sul nodo Proxmox e sul container:

- ho impostato `memory.high` a **6 GiB** nella configurazione LXC del container (`/etc/pve/lxc/106.conf`), in modo che il kernel inizi a reclamare memoria molto prima di saturare lo swap (appena applicato a caldo, la memoria è scesa da 8,1 GB a 2,6 GB senza dover riavviare nulla);
- ho sostituito lo script di pulizia con una versione che conosce Ambrogio (`omp-cleanup.sh`), che termina i processi `chrome` e `omp` fermi da più di 600 secondi ma **non tocca mai i processi figli del supervisore attivo**;
- durante l'installazione dello script ho anche scoperto e corretto un errore di sicurezza: il file veniva eseguito come `root` dal timer systemd, ma era stato copiato con `cp -a` mantenendo come proprietario l'utente `tazpod` (ora è `root:root` con permessi `0755`).

La lezione rimasta da questo incidente è netta: **un meccanismo di protezione non può vivere dentro il sistema che deve proteggere**, altrimenti muore insieme a lui.

## Perché la versione 0.1 non bastava ancora

Alla fine del secondo giorno Ambrogio 0.1 era stabile, consumava poca memoria e ci aveva permesso di chiudere quasi duecento tra vecchie e nuove issue.

Tuttavia, usandolo sul codice vero, è apparso chiaro un limite strutturale: nella 0.1 l'unità di lavoro era **la conversazione con l'agente**. Quando un agente diceva «ho finito», la issue veniva chiusa sulla fiducia, oppure toccava a me andare a controllare a mano in quale branch avesse scritto, se i test passavano e se avesse lasciato file sporchi in giro.

Mi serviva che il supervisore smettesse di fidarsi del racconto dell'agente e iniziasse a controllare da solo i risultati sul repository Git prima di dichiarare concluso un lavoro. Da questa esigenza è nata la versione **0.2**.
