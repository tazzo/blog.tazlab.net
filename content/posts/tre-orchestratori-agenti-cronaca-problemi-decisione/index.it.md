+++
title = "Tre Orchestratori di Agenti a Confronto: Paperclip, Multica, Buzz e Perché Ho Scelto un'Altra Strada"
date = 2026-10-05T05:00:00+02:00
draft = false
description = "Il confronto pratico dopo aver installato e usato tre sistemi per gestire gli agenti AI nel laboratorio: i limiti delle code di task di Paperclip e Multica, la moltiplicazione dei contesti e dei token, la prova di Buzz su protocollo Nostr e le ragioni che mi hanno portato a una soluzione diversa."
tags = ["agenti", "orchestrazione", "paperclip", "multica", "buzz", "kubernetes", "nostr", "devops"]
author = "Tazzo"
+++
> **Aggiornamento (2026-10-19):** Paperclip e Buzz sono stati entrambi dismessi e disinstallati; questo articolo resta come testimonianza del confronto.


## Perché sono arrivato a provarne tre

Negli ultimi due articoli ho raccontato l'installazione e l'uso di **Paperclip** e di **Multica**. Subito dopo ho installato e messo alla prova anche un terzo sistema, **Buzz**. Non avevo pianificato fin dall'inizio di provarne tre: ci sono arrivato perché ognuno dei primi due, una volta messo al lavoro su compiti reali del laboratorio, ha mostrato dei limiti pratici che non si vedono finché ci si limita a installarlo.

Nel mio laboratorio gli agenti non fanno solo riassunti: scrivono manifest Kubernetes, preparano ruoli Ansible, aggiornano la documentazione e aprono pull request. Per lavorare così mi servono tre cose concrete:

1. capire subito cosa sta facendo un agente in quel preciso momento e se è bloccato;
2. poter parlare con l'agente o correggerlo in corsa senza dover ricominciare il lavoro da capo;
3. non sprecare tempo e token a far rileggere e riverificare da zero le stesse informazioni a ogni piccolo passaggio.

Questo articolo mette a confronto i tre strumenti su questi punti pratici, racconta come è andata l'integrazione di Buzz sul cluster Kubernetes e spiega la decisione finale a cui sono arrivato.

## I primi due tentativi: Paperclip e Multica

### Paperclip: una bacheca di task isolati

**Paperclip** è stato il primo esperimento. L'ho installato in un container LXC dedicato su Proxmox (`CT108`), isolato dal resto della rete con un proxy di uscita (`mitmproxy`), regole `nftables` e credenziali dedicate. Dal punto di vista tecnico il sistema funziona bene: offre una bacheca con i task, assegna un budget agli agenti e li avvia a intervalli regolari.

Il limite per cui ho deciso di spegnerlo riguarda il modo in cui gestisce il lavoro. In Paperclip ogni compito è un biglietto isolato assegnato a un agente: non c'è un canale in cui gli agenti possano parlarsi o coordinarsi, e non c'è modo di intervenire in una conversazione mentre l'agente lavora. Per attività semplici e indipendenti può bastare, ma quando il lavoro tocca più componenti dello stesso cluster diventa troppo rigido.

### Multica: ottima integrazione, ma le code moltiplicano i task e i token

**Multica** è stato il passo successivo: un piano di controllo su Kubernetes (gestito tramite Flux, con database su PostgreSQL 17 autenticato tramite certificato client mTLS e segreti iniettati da Vault) abbinato a un daemon sul container di lavoro `CT106` che avvia una squadra di dodici agenti definiti in Git.

Di Multica ho apprezzato molto due aspetti: l'integrazione pulita con l'infrastruttura GitOps del laboratorio e il fatto di avere **regole di lavoro scritte** (stati, fasi e formato dei resoconti uguali per tutta la squadra). Usandolo tutti i giorni, però, sono emersi due problemi pesanti.

Il primo, di cui ho parlato nell'articolo dedicato, è l'**eccesso di testo nella bacheca**: ogni passaggio produce commenti lunghissimi (spesso oltre i 3.000 caratteri), per cui capire a colpo d'occhio chi sta lavorando e chi è fermo in attesa di una mia risposta richiede di aprire i singoli task e leggere fino in fondo.

Il secondo problema, ancora più costoso, è **il consumo di task e di token causato dal passaggio di consegne nelle code**. In un sistema basato sulle code, il lavoro viene diviso in passaggi: un agente imposta l'attività, poi crea o passa un task in coda a un altro agente per l'esecuzione, che a sua volta apre un task per la verifica o per la pubblicazione. Il punto critico è che **ogni nuovo task avvia da zero una nuova istanza dell'agente**: l'agente che inizia il lavoro non è quello che lo continua.

Poiché il nuovo agente parte senza memoria della sessione precedente, a ogni passaggio deve:

- rileggere da capo tutti i file del progetto e la cronologia dei commenti;
- riconfermare lo stato dell'ambiente;
- rifare le stesse verifiche già eseguite dall'agente precedente prima di toccare qualsiasi cosa.

Anche per operazioni semplici — come scrivere e pubblicare un normale articolo del blog o fare una piccola modifica di configurazione — questa catena generava una quantità sproporzionata di task. I contesti da caricare si moltiplicavano a ogni passaggio di mano e, con essi, si moltiplicavano i token consumati solo per fare e rifare gli stessi controlli.

## Il terzo tentativo: cosa cambia con Buzz

Per superare il problema degli agenti ricreati da zero a ogni task, ho provato **Buzz**.

L'impostazione di Buzz è completamente diversa: non è una bacheca di ticket con delle code, ma un **relay Nostr** self-hosted in cui gli operatori umani e gli agenti sono membri delle stesse stanze di chat (nel mio caso il canale `#lab`). Ogni partecipante, umano o agente, possiede una coppia di chiavi crittografiche e firma ogni messaggio che invia.

Dal punto di vista pratico questo cambia il modo di lavorare:

- **L'agente resta attivo e risponde nel canale:** non nasce e muore per un singolo micro-task. Quando scrivo a `@buzz-agent-1` nel canale, l'agente mi risponde lì.
- **I messaggi in arrivo mentre lavora non vanno persi:** ho verificato questo comportamento mandando una seconda richiesta 24 secondi dopo la prima, mentre l'agente stava ancora elaborando il primo turno. Il sistema ha messo in coda il secondo messaggio (`queue_depth=1`) e l'agente ha risposto a entrambi in sequenza, firmando ogni risposta con la propria chiave.
- **Chi non è autorizzato viene respinto subito:** ogni chiave deve essere ammessa esplicitamente al relay e al canale. Provando a collegare una chiave non registrata, il relay risponde immediatamente con un errore chiaro (`403 relay_membership_required`) impedendo anche solo di leggere la stanza.

## Come ho integrato Buzz e quali problemi ho trovato

Ho installato il relay di Buzz sul cluster Kubernetes (namespace `buzz`, esposto solo sulla rete interna e in VPN su `ws://192.168.1.240:3010`), collegandolo a un pod Redis e al cluster condiviso PostgreSQL 17 con autenticazione esclusivamente a certificato client (`sslmode=verify-full`).

Mentre il database e i certificati sono andati a posto al primo colpo grazie al lavoro già fatto per Multica, il resto dell'installazione è costato parecchio tempo per cinque motivi precisi.

### 1. I binari dell'agente vanno compilati da sorgente

Il relay ha un chart Helm ufficiale, ma i programmi che fanno girare l'agente sulla macchina di lavoro (`buzz-acp`, `buzz` e `buzz-admin`) non vengono distribuiti come eseguibili pronti da scaricare. Ho dovuto compilarli in Rust a partire dal tag `relay-v0.2.1`, pubblicarli in un'immagine Docker (`tazzo/buzz-tools`) fissata tramite digest e farli estrarre da `CT106` verificando il checksum. È una soluzione pulita perché evita di installare il compilatore Rust sul container di lavoro, ma significa dover mantenere una pipeline di compilazione a ogni aggiornamento.

### 2. Tre problemi sovrapposti dietro un unico silenzio

Una volta avviato l'agente su `CT106`, menzionandolo nel canale non succedeva nulla: nessuna risposta e nessun errore chiaro nei log normali. Invece di andare a tentativi sulla configurazione, ho eseguito a mano il comando `omp acp` inviandogli direttamente i messaggi JSON-RPC che usa l'harness di Buzz. In meno di un minuto sono emerse tre cause diverse che si nascondevano una dietro l'altra:

1. **Il filtro sui mittenti (`respond_to`):** l'impostazione iniziale `owner-only` non faceva scattare il turno; l'ho sostituita con una lista esplicita delle chiavi autorizzate (`allowlist`), che è anche necessaria se due agenti devono potersi svegliare a vicenda nel canale.
2. **Nessun modello selezionato:** il processo figlio rispondeva con un errore JSON-RPC `-32603 ("No model selected")`. L'harness di Buzz non stampava il messaggio specifico, ma si limitava a rimettere in coda il lavoro con dieci tentativi di backoff, facendolo sembrare un processo bloccato.
3. **La chiave API del provider non era nell'ambiente:** risolto il modello, il processo rispondeva `-32603 ("No API key found")`. Poiché nel laboratorio le chiavi stanno in `gopass` e non nelle variabili d'ambiente globali, ho configurato lo script di avvio perché legga la chiave da `gopass` in memoria al momento della partenza e rifiuti di avviarsi se la chiave manca.

### 3. L'applicazione desktop e la registrazione dell'agente

Il relay di Buzz non offre un'interfaccia web per leggere e scrivere nei canali: per usare il sistema serve la sua applicazione desktop (basata su Tauri).

Al primo avvio, scegliendo il percorso *"I already have a community → I own the community"*, l'applicazione cercava di fare il login su un servizio cloud esterno e rifiutava l'indirizzo IP privato del mio relay. Analizzando il codice dell'applicazione ho capito che quel percorso serve solo per l'offerta ospitata: per collegarsi al proprio server bisogna invece scegliere **"Join a community"**, inserire `ws://192.168.1.240:3010` e cliccare su **"Set up later"** nella schermata che chiede le chiavi dei modelli AI (che servono solo se si creano agenti dentro l'app desktop).

Inoltre, anche dopo che l'agente è online nel canale, non compare nell'elenco degli agenti dell'interfaccia finché il proprietario del relay non invia un comando esplicito di **attestazione** per certificare che quella chiave appartiene a un agente. Finché non lo si sa, l'agente sembra semplicemente non funzionare.

### 4. Lo spazio su disco del nodo Kubernetes

Il primo deploy di Buzz ha fatto superare al nodo di lavoro di Kubernetes la soglia dell'85% di disco occupato (quasi tutto preso dalle immagini container già presenti sul nodo). Kubernetes ha attivato la condizione `DiskPressure` e ha espulso 19 pod di Buzz.

L'incidente ha messo in luce una svista: nei piani avevo calcolato la memoria RAM di ogni componente, ma nessun pod del cluster dichiarava una richiesta di spazio temporaneo (`ephemeral-storage`). Ho aggiunto subito le richieste di disco ai pod di Buzz (2 GiB per il relay e 256 MiB per Redis) e pianificato l'allargamento della partizione di sistema del nodo.

### 5. Le risposte duplicate

Durante le prove l'harness ha risposto due volte a diversi messaggi. Non blocca il lavoro, ma sporca il canale ed è rimasto come difetto aperto da correggere prima di un eventuale uso continuativo.

## Agenti ricreati a ogni task contro agenti persistenti

Mettendo insieme le prove fatte su Multica e su Buzz, la differenza più importante non sta nell'interfaccia grafica, ma **nel ciclo di vita dell'agente**.

| Modello | Come funziona | Vantaggi | Il problema riscontrato in pratica |
|---|---|---|---|
| **A richiesta su coda di task** (Paperclip, Multica) | Ogni task in coda avvia un agente nuovo da zero; finito il task, l'agente si chiude. | Nessuna memoria sporca tra lavori diversi; regole formali per ogni stato. | Quando un lavoro passa di mano tra più agenti, ogni task ricrea un agente nuovo che deve rileggere tutto il contesto e rifare le stesse verifiche, moltiplicando task e token anche per cose semplici. |
| **Agenti persistenti / residenti** (Buzz) | L'agente resta attivo, mantiene la propria sessione e risponde direttamente nel canale. | Chi inizia il lavoro può continuarlo; puoi parlargli in corsa senza ricaricare tutto da capo. | La memoria della sessione va gestita per evitare che si accumuli rumore nel tempo. |

All'inizio pensavo che far nascere un agente pulito per ogni singolo task fosse la soluzione più ordinata. La pratica mi ha dimostrato il contrario: se per pubblicare un articolo o applicare una modifica devo passare da tre o quattro task in coda, e ogni task avvia un agente diverso che rilegge l'intero repository e riverifica tutto da capo, il costo in token e in tempo di attesa diventa insostenibile.

Per lavorare bene mi serve che **l'agente che inizia un lavoro sia anche quello che lo porta a termine**, o almeno che resti attivo nella sua sessione finché l'attività non è davvero conclusa, così da poterci dialogare senza dovergli rispiegare il contesto a ogni passo.

## Tre errori tecnici che non dipendono dallo strumento

Al di là delle differenze tra Paperclip, Multica e Buzz, durante queste installazioni si sono ripetuti tre problemi che dipendono da come scrivo le configurazioni, le istruzioni e i controlli.

### 1. Le configurazioni accettate da Kubernetes che non fanno nulla

È l'errore più insidioso perché tutti gli indicatori restano verdi:

- **I nomi generati da Flux (`HelmRelease`):** quando si imposta `spec.targetNamespace` in una `HelmRelease`, Flux antepone automaticamente il nome del namespace al nome della release (ad esempio `buzz-buzz` o `multica-multica-backend`), a meno di non forzare `spec.releaseName`. Se in un controllo di riavvio (`rolloutRestartTargets`) o in un `ServiceMonitor` di Prometheus si scrive il nome semplice `multica` invece di `multica-multica`, Kubernetes accetta la risorsa senza errori, ma i pod non vengono riavviati al rinnovo dei certificati e Prometheus raccoglie zero metriche.
- **Le `NetworkPolicy` senza un CNI che le applichi:** per isolare il Redis di Buzz ho scritto una `NetworkPolicy` corretta e verificata. Invece di fermarmi al fatto che la risorsa fosse presente nel cluster, ho lanciato un pod di prova per tentare la connessione che doveva essere bloccata: la connessione è passata. Il motivo è che il cluster usa `kube-flannel` senza un controller di rete per le policy, quindi tutte le `NetworkPolicy` vengono accettate dall'API di Kubernetes ma ignorate a livello di rete.

La regola che mi sono dato è semplice: non basta verificare che una risorsa sia `Ready`, serve una **prova negativa** che dimostri che il blocco o l'effetto sta funzionando davvero (ad esempio provare a connettersi a PostgreSQL con una password e verificare che il server risponda `FATAL: connection requires a valid client certificate`).

### 2. Come sono scritte le istruzioni per gli agenti

In più occasioni un agente che aveva terminato la propria parte si è fermato ad aspettare me invece di passare il lavoro allo step successivo. Rileggendo il prompt, la causa era una frase ambigua: avevo scritto *"il proprietario dell'assegnazione è l'operatore"*. L'agente l'ha letta come una descrizione informativa e si è fermato. Sostituendola con un'istruzione diretta (*"apri il task per il subagente e attendi il risultato"*), il problema è sparito. Con gli agenti una frase descrittiva viene trattata come contesto, non come comando.

### 3. Fidarsi del resoconto invece di controllare il risultato

Nella stessa giornata mi è capitato tre volte che un agente dichiarasse nel suo messaggio finale di aver completato un'operazione (un canale creato, una compilazione eseguita, un'attestazione inviata) che in realtà non era mai avvenuta. Per un modello linguistico produrre un resoconto plausibile è molto più facile che portare a termine un comando che ha dato un errore silenzioso. La verifica non va mai fatta leggendo il commento dell'agente, ma interrogando direttamente il sistema (il commit in Git, il database, la risposta dell'API).

## La decisione finale

Dopo aver provato tutti e tre i sistemi sul campo, la situazione nel laboratorio è questa:

1. **Paperclip resta spento in standby:** la configurazione rimane salvata nel repository nel caso mi servisse in futuro una semplice bacheca isolata, ma il servizio è disattivato.
2. **Multica è stato congelato:** il 1° ottobre ho chiuso tutti i task e svuotato l'ambiente di lavoro. Di questa esperienza tengo strette le due cose che hanno funzionato meglio — l'autenticazione a certificato client su PostgreSQL e le regole scritte per i ruoli degli agenti — ma abbandono il modello a code di task, perché ricreare un agente nuovo a ogni passaggio moltiplica inutilmente i contesti da rileggere, i tempi di verifica e il consumo di token, oltre a produrre una quantità di testo che non riesco a seguire in tempo reale.
3. **Buzz resta come laboratorio di prova sul protocollo Nostr, ma non diventa il motore principale:** l'idea degli agenti residenti in un canale con messaggi firmati risolve il problema del dialogo diretto, ma dover ricompilare l'harness a mano, dipendere per forza dall'app desktop e gestire i difetti di gioventù del client lo rende troppo macchinoso per l'uso quotidiano.

## Conclusioni

Provare tre orchestratori diversi in poche settimane mi ha chiarito cosa mi serve davvero: non una piattaforma enorme piena di code e di passaggi formali, ma un sistema leggero in cui **gli agenti restano attivi durante il lavoro**, mantengono il contesto senza dover rileggere tutto da capo a ogni passo, consumano i token per fare il lavoro anziché per riverificare quello che ha già fatto qualcun altro, e lasciano la tracciabilità vera dove è sempre stata più sicura: nei commit di Git.

Ed è proprio mettendo insieme queste conclusioni che, chiuso l'esperimento con Multica e Buzz, ho deciso di scrivere da zero il supervisore di agenti residenti che uso oggi nel laboratorio (**Ambrogio**): un singolo binario in Go che mantiene vivi gli agenti via ACP, permette di parlargli direttamente da una pagina web senza moltiplicare i contesti e applica nel codice — non nei prompt — i controlli meccanici sul lavoro.
