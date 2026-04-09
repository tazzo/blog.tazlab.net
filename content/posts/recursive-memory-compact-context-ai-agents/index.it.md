+++
title = "Memoria ricorsiva, contesto compatto: il tassello che mancava per lavorare bene con gli agenti AI"
date = 2026-04-10T08:00:00+00:00
draft = false
description = "Dopo il sistema dei contesti AGENTS.ctx, ho aggiunto un livello di memoria ricorsiva che mantiene gli agenti allineati sul presente senza far crescere il contesto all'infinito. Una cronaca tecnica su come funziona, perché serve e cosa cambia davvero nel lavoro quotidiano."
tags = ["AI", "Agents", "Memory", "Context Management", "Workflow", "DevOps", "Productivity", "Architecture"]
categories = ["AI", "Architecture", "Productivity"]
author = "Taz"
+++

# Memoria ricorsiva, contesto compatto: il tassello che mancava per lavorare bene con gli agenti AI

## Il problema dopo aver risolto il problema

Qualche settimana fa avevo scritto un articolo su **AGENTS.ctx**, il sistema di contesti che uso per lavorare con gli agenti AI senza dover rispiegare tutto da capo a ogni nuova sessione. L'idea di base era semplice: invece di aprire una chat vuota e reiniettare ogni volta regole, struttura del progetto, convenzioni operative e stato generale del lavoro, ho organizzato tutto in contesti caricabili on demand. L'agente non cambia: cambia il contesto che gli faccio leggere.

Quella soluzione ha funzionato davvero bene. Non in teoria, ma nel lavoro di tutti i giorni. Apro il contesto `tazpod`, e l'agente sa subito come è fatta la CLI, quali sono i path critici, come si spinge su GitHub, dove stanno i rischi operativi. Apro `blog-writer`, e l'agente sa già come pianificare un articolo, come passare alla scrittura e quando fermarsi per la review. Apro `crisp`, e il sistema cambia ritmo: non si implementa, si ricerca e si progetta.

Il punto però è che, una volta risolto il bootstrap operativo, è emerso un secondo problema. Più sottile del primo, ma altrettanto importante. I contesti spiegano **come** lavorare in un certo dominio. Non sempre spiegano **dove siamo arrivati oggi**, **cosa è successo nelle ultime sessioni**, **quali debiti sono ancora aperti**, **qual è la verità corrente del sistema**. Per un lavoro che dura settimane o mesi, questa distinzione conta moltissimo.

In altre parole: i contesti mi avevano dato il telaio. Mi mancava ancora una memoria attiva, continuamente aggiornata, che fosse abbastanza compatta da stare sempre a portata di mano ma abbastanza ricca da permettere a un agente di ripartire subito dal punto giusto.

## Perché non bastava “avere più memoria”

Quando si lavora con LLM e coding agent, la prima reazione davanti ai problemi di continuità è spesso istintiva: conservare più roba possibile. Tenere transcript più lunghi, più note, più file, più log, più riassunti. In apparenza sembra una buona idea. In pratica, quasi mai lo è.

Il problema non è solo quantitativo. È strutturale. Se la memoria attiva cresce senza controllo, prima o poi smette di essere uno strumento e diventa rumore. Un agente che deve leggere troppo materiale prima di diventare operativo non è davvero allineato: è semplicemente sommerso. Il costo di bootstrap torna a salire, solo in una forma diversa. Non sto più rispiegando le cose manualmente, ma sto obbligando il sistema a digerire un blocco sempre più grande di contesto eterogeneo.

Questo è lo stesso problema che avevo già cercato di evitare progettando AGENTS.ctx: **non caricare tutto, caricare solo quello che serve**. La stessa filosofia andava estesa anche alla memoria.

Quindi la domanda non era: come do più memoria all'agente? La domanda corretta era: come costruisco una memoria che resti **operativa**, **leggibile**, **densa**, e che non degradi man mano che il progetto va avanti?

## Il passo successivo: una memoria attiva, ricorsiva, ma sempre piccola

La soluzione che ho costruito si chiama semplicemente **`memory`**, ed è diventata il livello attivo della continuità operativa dentro `AGENTS.ctx`. Non è un database esterno. Non è un sistema opaco. Non è una funzione magica del modello. È ancora una volta una struttura di file semplice, versionata su Git, leggibile da qualsiasi agente che sappia leggere del Markdown.

Ma la differenza rispetto ai contesti statici è fondamentale: `memory` non è solo un insieme di regole. È una **memoria viva** che cambia nel tempo e che tiene traccia del presente in modo disciplinato.

Il modello attuale è organizzato così:

- `system-state.md`
- `debts.md`
- `past-summary.md`
- `chronicle.md`
- `past/`
- `scripts/archive-memory.sh`

A prima vista può sembrare solo un'ulteriore cartella di documentazione. In realtà è un sistema di ruoli molto preciso, e la precisione dei ruoli è esattamente ciò che lo rende utile.

## Il ruolo dei file: non un accumulo, ma una gerarchia

La prima decisione importante è stata evitare il file unico onnivoro. Se tutto finisce nello stesso documento, la distinzione tra stato corrente, cronologia, debiti tecnici e riassunto storico si rompe nel giro di poche sessioni. All'inizio può sembrare comodo. Dopo qualche giorno diventa ingestibile.

Per questo ogni file ha una responsabilità stretta.

### `system-state.md`: la verità di oggi

Questo file serve a rispondere a una sola domanda: **cosa è vero adesso?** Non cosa era vero tre giorni fa, non cosa si è deciso in una discussione di progetto, non il dettaglio completo del troubleshooting. Solo la dottrina operativa corrente.

Qui ci stanno le cose che, se apro un agente nuovo, voglio che sappia subito senza dover scavare:

- qual è il modello attuale di TazPod,
- quali sono i caveat importanti,
- come funziona in questo momento la pipeline CI,
- qual è il ruolo dei vari layer del sistema,
- quali componenti sono considerati fonte di verità.

Il punto di `system-state.md` non è raccontare il passato. È condensare il presente.

### `debts.md`: ciò che non è risolto

A un certo punto ho separato anche il debito tecnico in un file dedicato. Questa è stata una correzione importante, nata dall'uso reale. All'inizio è molto facile mescolare i problemi aperti dentro la cronologia o dentro lo stato. Ma sono due cose diverse.

Un debito tecnico non è solo un evento del passato. È una tensione ancora attiva nel sistema. Va tenuto visibile in forma strutturata. Per questo `debts.md` è diventato il registro canonico di tutto quello che è aperto, in corso, rinviato o da chiudere in futuro.

In pratica, quando riapro una sessione, non voglio solo sapere cosa è stato fatto. Voglio vedere subito **cosa ancora manca**, **dove sono i rischi**, **quali problemi non posso dimenticare**.

### `chronicle.md`: la continuità causale recente

Questo è il diario attivo del ciclo corrente. Non è un riassunto storico compresso, e non è la dottrina. È la parte narrativa che tiene insieme causa ed effetto delle ultime sessioni.

Qui vive la risposta alla domanda: **come siamo arrivati dove siamo?**

Questa distinzione è importante. Lo stato da solo non basta. Se apro un agente e gli dico che oggi il sistema funziona in un certo modo, spesso manca il perché. E senza il perché diventa molto più facile rompere qualcosa nella sessione successiva.

La cronologia serve esattamente a questo: preservare la catena recente di eventi, problemi, correzioni e conseguenze.

### `past-summary.md`: la compressione del passato utile

Questo è forse il pezzo più interessante dell'intero sistema. Perché il problema non è solo tenere una memoria recente. È farlo senza perdere il passato e senza caricarlo tutto ogni volta.

`past-summary.md` è il livello compresso della storia più vecchia. Non entra nei dettagli di tutto. Non deve farlo. Il suo compito è fornire orientamento storico ad alta densità: grandi decisioni, svolte architetturali, motivazioni che ancora contano oggi.

È la memoria lunga, ma ancora pronta all'uso.

### `past/`: l'archivio ricorsivo

Ed ecco il punto che per me rende il sistema davvero interessante. Il passato non viene cancellato. Viene **archiviato ricorsivamente**.

Quando il ciclo attivo supera una certa soglia, il sistema non si limita a “fare cleanup”. Sposta i file root dentro `past/`, conserva la struttura, e poi rigenera una nuova root attiva pulita. Se in futuro serve andare più indietro, si può scavare a strati.

Questa è una feature molto importante del modello. Quello che ho subito in mano è solo quello che mi serve ora. Ma se ho bisogno di ricostruire cosa è successo in modo più profondo, posso farlo andando a ritroso un livello alla volta, senza trasformare la root attiva in un archivio infinito.

## Perché la ricorsione qui non è un vezzo teorico

Dire “ricorsivo” può sembrare un tecnicismo elegante usato per darsi un tono. In realtà qui è una scelta molto concreta.

In una memoria lineare tradizionale ci sono due esiti comuni:

1. o il file cresce senza controllo,
2. oppure si taglia brutalmente il passato e si perde continuità.

Io volevo evitare entrambe le cose. La ricorsione mi permette di conservare tutto **senza dover tenere tutto caricato nello stesso piano operativo**. È una differenza sottile ma decisiva.

Il livello attivo resta compatto. Il passato non sparisce. Semplicemente viene spostato in un livello storico meno immediato. Se mi serve, lo riapro. Se non mi serve, non inquina la lettura corrente.

Questo approccio ha anche un effetto molto pratico sul modo di lavorare: quando riapro un agente, questo non deve attraversare settimane di storia per capire cosa fare. Legge la root attiva, e solo se il problema lo richiede va a cercare più indietro.

È memoria stratificata, non memoria gonfiata.

## L'archive model: tenere la memoria viva senza farla esplodere

Per rendere questo modello sostenibile non bastava dividere i file. Serviva anche un meccanismo disciplinato per evitare che la root attiva crescesse senza fine. Per questo ho introdotto un archive flow esplicito, gestito da `scripts/archive-memory.sh`.

La logica è questa:

- quando la cronologia attiva supera una soglia,
- oppure quando si chiude una tappa importante,
- oppure quando decido di forzare l'archivio,
- il ciclo corrente viene archiviato,
- la memoria root viene rigenerata,
- e il lavoro riparte da una base compatta.

Questa parte era importante non solo come idea, ma come implementazione reale. Non mi interessava avere un modello elegante su carta. Volevo verificare che, nel momento in cui la memoria andava davvero archiviata, il comportamento fosse pulito: file spostati correttamente, summary rigenerato, cronologia nuova minimale, nessun log inutile che sporca il workspace.

Per questo ho anche eseguito un **forced archive reale**, non una semplice review teorica. È stato un passaggio importante, perché ha trasformato il design in un comportamento verificato.

## Il sistema non è nato perfetto, ed è un bene

Una delle cose che considero più interessanti di questo lavoro è che il sistema non è emerso in una sola soluzione “geniale”. È stato corretto mano a mano che lo usavo.

La prima versione del modello era già utile, ma aveva ancora confini troppo morbidi. Alcune responsabilità erano mescolate. Alcune informazioni storiche finivano nel posto sbagliato. Il rischio era quello classico dei sistemi documentali: partire ordinati e tornare gradualmente al caos.

Le correzioni più importanti sono arrivate proprio da questo uso reale:

- il debito tecnico è stato separato in `debts.md`,
- la cronologia è stata ripulita fino a diventare davvero cronologia,
- lo stato è stato ristretto a “truth of today”,
- `past-summary.md` è diventato un artefatto di primo livello,
- il contract di archive è stato reso più preciso,
- la validazione è stata fatta con un ciclo completo, non solo con buon senso.

Questo per me è un segnale di salute del sistema. Un workflow utile non è quello che sembra perfetto al primo sketch. È quello che regge il contatto con l'uso reale e sopravvive alle revisioni senza perdere coerenza.

## Memory e Mnemosyne: due memorie, due usi diversi

Qui c'è una distinzione che per me vale la pena esplicitare molto bene, perché all'esterno può sembrare ridondanza.

Ho già **Mnemosyne**, che uso come memoria storica e retrieval semantico. Allora perché costruire anche `memory`?

Perché servono due cose diverse in due momenti diversi.

### Mnemosyne: cercare per significato

Mnemosyne è utile quando non ricordo esattamente **quando** è successa una cosa, ma ricordo **di cosa trattava**. Per esempio:

- “quando abbiamo già visto un problema simile con la CI?”
- “avevamo già discusso quella quota Gemini?”
- “in quale sessione era emerso quel trade-off su Hetzner?”

Questa è ricerca semantica. È potentissima, ma non sostituisce il contesto attivo.

### Memory: sapere dove siamo ora

`memory` serve invece quando apro il terminale e voglio ripartire subito. Non voglio cercare semanticamente nel passato. Voglio sapere:

- cosa è vero oggi,
- cosa è ancora aperto,
- cosa è successo di recente,
- qual è la base attiva da cui continuare.

È memoria cronologica e operativa. Non è retrieval. È continuità di lavoro.

Per questo considero `memory` e Mnemosyne complementari, non concorrenti. Una serve a **riprendere**. L'altra serve a **ritrovare**.

## Cosa cambia davvero nel lavoro quotidiano

La parte più interessante non è l'architettura in sé, ma il cambiamento di ritmo che produce.

Quando un workflow del genere funziona, succede una cosa molto semplice da descrivere e molto difficile da ottenere: riapro un agente, e questo sa già dove eravamo. Non in modo vago. Non nel senso “forse ricorda qualcosa”. Sa davvero qual è il punto del percorso.

Questo riduce enormemente il costo di riapertura delle sessioni. E riduce anche un'altra forma di attrito che all'inizio avevo sottovalutato: l'energia mentale spesa per ricostruire il contesto. Ogni volta che devo fermarmi a riassumere a mano lo stato di un progetto, sto sprecando una parte della mia attenzione su un compito amministrativo invece che sul problema tecnico reale.

Con `memory`, quella ricostruzione è già lì. E soprattutto è lì in una forma abbastanza piccola da restare utile.

## La direzione futura: semplificare ancora

C'è anche una conseguenza architetturale che sto vedendo più chiaramente proprio adesso che il sistema ha iniziato a funzionare bene: il modello finale dovrebbe probabilmente essere ancora più semplice.

Il mio obiettivo di lungo periodo è avere sostanzialmente **due soli layer**:

- **`memory`** come memoria cronologica, attuale, ricorsiva,
- **Mnemosyne** come memoria semantica e di ricerca.

Il resto, progressivamente, dovrebbe convergere lì dentro. Non perché la storia intermedia non sia stata utile, ma perché un modello che si lascia spiegare in due frasi è quasi sempre più robusto di uno che ha troppi strati transitori.

Questo non significa buttare via il passato. Significa assorbirlo in una struttura più chiara.

## Riflessioni post-lab

Se dovessi riassumere il senso di questo lavoro in una frase, direi così: dopo aver costruito i contesti, mi serviva un modo per non ripartire mai davvero da zero. La memoria ricorsiva è stata quel tassello.

Non volevo una memoria infinita. Volevo una memoria **sempre pronta**. Non volevo un accumulo di note. Volevo un sistema che separasse chiaramente stato, debiti, cronologia e passato compresso. Non volevo perdere la storia. Volevo poterla scavare solo quando serve.

Il risultato, almeno fin qui, è molto convincente. I contesti continuano a fare il loro lavoro: dare regole, struttura, indirizzamento e specializzazione operativa. La memoria aggiunge la continuità temporale che mancava. Mnemosyne resta il livello di retrieval semantico, utile quando serve cercare nel passato per significato.

Sono tre problemi diversi, ma due stanno ormai convergendo in una forma più pulita: una memoria attiva, ricorsiva, a grandezza controllata, e una memoria semantica per la ricerca storica.

Per il mio modo di lavorare, da solo, con agenti diversi e progetti lunghi, questo non è un dettaglio organizzativo. È un cambio di qualità del workflow. Apro il terminale, riapro l'agente, e il sistema sa già da dove ripartire. Non tutto. Solo quello che serve. Ed è esattamente questo il punto.