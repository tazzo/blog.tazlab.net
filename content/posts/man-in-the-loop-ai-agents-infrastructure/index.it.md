---
title: "Man in the Loop: Riflessioni sull'Uso degli Agenti AI per Costruire Infrastrutture"
date: 2026-03-18T08:00:00+00:00
draft: false
tags: ["AI", "Kubernetes", "DevOps", "Cloud", "Agenti AI", "pi.dev", "OpenRouter", "Workflow"]
description: "Non è hype, non è fantascienza: è il resoconto onesto di chi usa agenti AI ogni giorno per costruire cluster Kubernetes seri, con tutti i limiti del caso."
---

## La Tesi: Potenti, ma Solo se Sai Dove Mandarli

Gli agenti AI sono lo strumento più trasformativo che ho aggiunto al mio workflow negli ultimi anni. In due mesi di lavoro serale ho prodotto quello che avrei impiegato due anni a costruire da solo. Eppure, ogni volta che vedo qualcuno su YouTube che dice "guarda, gli ho chiesto di farmi un'app e l'ha fatta", mi viene un mezzo sorriso amaro.

Perché c'è una differenza abissale tra fare una cosa e farla bene. E quella differenza, al momento, passa ancora interamente dall'ingegnere.

Questa non è una cronaca entusiasta sull'AI che cambierà il mondo. È il resoconto di chi lavora ogni giorno con questi strumenti su Kubernetes, cluster cloud, pipeline GitOps e gestione dei segreti — e ha imparato a proprie spese dove si può dare fiducia a questi agenti e dove, invece, bisogna tenerli al guinzaglio.

---

## Contextual Analysis: Un Panorama in Movimento Rapido

Quando ho iniziato a sperimentare con gli agenti AI sull'infrastruttura, il mio punto di partenza era semplice: volevo capire se potevano aiutarmi a fare cose che già sapevo fare, ma più velocemente. Non cercavo magia. Cercavo efficienza.

Il primo problema che ho incontrato è stato il vincolo di piattaforma. Gemini CLI, Cloud Code, gli strumenti nativi dei grandi provider: ognuno ha il suo mondo, le sue regole, i suoi aggiornamenti che cambiano interfacce senza avvisare. Un giorno lavori in un certo modo, il giorno dopo qualcuno ha deciso che si fa diversamente. E tu devi seguire.

La svolta è stata scoprire **pi.dev**, la piattaforma su cui è costruito questo stesso ambiente di lavoro. È un agente minimale, paragonabile a VI tra gli editor: c'è poco di default, ma è configurabile in maniera estrema e con una semplicità disarmante. Puoi dirgli direttamente "creami questa estensione, aggiungi questo comportamento" e costruirti il tuo strumento su misura. Soprattutto, non ti lega a nessun provider specifico.

Questo mi ha aperto le porte a **OpenRouter**, che è essenzialmente uno sportello unico per tutti i modelli linguistici esistenti. Da lì ho cominciato a esplorare seriamente cosa offrono i vari provider, con un occhio costante ai costi — perché sono un privato, e un abbonamento da €200 al mese non è una voce di bilancio sostenibile.

### Il Confronto sul Campo

Ho testato molti modelli nel contesto specifico del lavoro su cluster, container e cloud. Il verdetto non è quello che mi aspettavo.

**Claude (Cloud Code)** è eccellente per i lavori di progettazione complessa. Ragiona bene, fa le scelte giuste, capisce le architetture. Il problema è il costo: con Opus esaurisco le quote in un'ora. Con Sonnet si va un po' più avanti, ma non molto. Ottimo per lavori chirurgici e critici, insostenibile come strumento quotidiano.

**Gemini Flash 3.0** mi ha sorpreso più di una volta. In almeno due occasioni, su problemi reali di configurazione Kubernetes che Sonnet non riusciva a sbloccare, il Flash li ha risolti al primo tentativo. Non è una regola, ma è abbastanza frequente da essere significativo. Ha prezzi ragionevoli e nel mio campo si comporta bene. C'è un asterisco importante, però: Gemini CLI usato tramite pi.dev diventa quasi inutilizzabile per problemi di rate limiting — 50 secondi di attesa tra una chiamata e l'altra, poi va in errore. La soluzione è usarlo attraverso il suo terminale nativo, dove funziona correttamente.

**Minimax M2.5** è stato una delusione. Ne parlano bene in giro, ma nel mio campo specifico — configurazione cluster, Kubernetes, infrastruttura cloud — sbagliava e dimenticava troppe cose.

**Grok 4.1 fast** non è male per il prezzo che ha. Si perde su lavori lunghi, ma su compiti circoscritti è utilizzabile.

**Stepfun** (modello gratuito): velocissimo, ma produce fiumi di log intermedi perché è un modello a ragionamento esteso. Nella pratica, è quasi inutilizzabile su lavori di configurazione.

**GLM-5** (Zhipu AI) è la sorpresa positiva del lotto. Prezzi comparabili a Gemini Flash, si comporta bene su Kubernetes e configurazioni cloud, porta avanti il lavoro con disciplina e si corregge quando sbaglia. È uno di quei modelli che tengo sempre come riserva quando finisco le quote.

**Hunter Alpha** (openrouter/hunter-alpha) merita un discorso a parte. È un modello gratuito di autore ignoto — probabilmente una nuova versione di DeepSeek o qualcosa di simile, ma non è chiaro. Lo sto usando con soddisfazione crescente: è bravo a correggersi, gestisce bene i lavori complessi, e per ora è gratuito. Un po' lento — probabilmente la conseguenza del free tier — ma i risultati sono ottimi.

Il pattern che emerge è chiaro: **il modello migliore dipende dal task, non dalla marca**. E avere una piattaforma agnostica come pi.dev, che mi permette di passare da uno all'altro in pochi secondi senza cambiare workflow, vale più di qualsiasi singolo modello.

---

## Deep Dive: Dove gli Agenti Eccellono e Dove Cedono

### 1. Il Problema del Contesto e della Memoria

Il valore reale di un agente AI nell'infrastruttura non sta nella capacità di scrivere YAML. Sta nella capacità di tenere in testa un contesto complesso e applicarlo in modo coerente. Kubernetes è un universo: c'è Linux alla base, poi Docker, poi Kubernetes stesso, poi networking, poi sicurezza, poi le specificità di ogni cloud provider. Ogni livello ha la sua sintassi, i suoi strumenti, i suoi flag.

Per anni il mio problema non è stato non sapere cosa volevo. Ho sempre saputo cosa volevo ottenere. Il problema era dovermi rileggere la documentazione ogni volta che cambiavo libreria o provider, perché ogni ecosistema ha le sue idiosincrasie. Terraform su Oracle non è Terraform su AWS — stessa logica, comandi e configurazioni diverse.

Con gli agenti, questo problema scompare quasi completamente. Io descrivo il risultato, loro scrivono il codice. Il mio tempo si sposta dalla memorizzazione mnemonica dei comandi alla definizione precisa di cosa voglio ottenere.

Ho costruito per questo una soluzione di gestione del contesto personalizzata — di cui ho scritto altrove — che mi permette di aprire un terminale e ritrovarmi in 20 secondi con il contesto del progetto già carico: cosa è stato fatto, dove siamo arrivati, quali problemi abbiamo incontrato. Posso cambiare agente, cambiare progetto, e il nuovo agente sa esattamente da dove riprendere. I contesti sono tenuti piccoli e densi — solo le informazioni pertinenti al momento — il che riduce il rischio di perdita di coerenza.

### 2. Il Rischio dell'Autonomia: Cosa Succede Quando li Lasci Andare

Questo è il punto su cui voglio essere più diretto, perché è quello su cui si fa più confusione.

Ho provato più volte a lasciare gli agenti lavorare in autonomia su compiti complessi. Il risultato è quasi invariabilmente lo stesso: portano il compito a termine, ma le scelte che fanno lungo il percorso sono spesso sbagliate. Non sbagliate nel senso che non funzionano — a volte funzionano benissimo. Sbagliate nel senso che non rispettano i vincoli architetturali che avevo in testa, prendono scorciatoie che creano debito tecnico, costruiscono soluzioni fragili che non si possono estendere.

Il caso più emblematico che ho vissuto: lavoro su un cluster gestito con filosofia GitOps, quindi tutto finisce su Git. In più di un'occasione, un agente lasciato andare ha committato credenziali all'interno di un ConfigMap o direttamente in un file YAML. Ha visto un problema, ha cercato la soluzione più rapida, e quella soluzione era sbagliata da un punto di vista di sicurezza. Non perché non sapesse che i segreti non si committano — se glielo chiedi, te lo sa spiegare perfettamente. Ma nel flusso del lavoro autonomo, la pressione di "chiudere il task" ha prevalso sul rispetto delle regole.

Questo mi ha insegnato una cosa: **gli agenti AI conoscono le best practice, ma non le sentono come un vincolo imprescindibile quando operano in autonomia**. Le applicano quando vengono esplicitamente istruiti a farlo, o quando c'è qualcuno che verifica.

### 3. Lo Spec-Driven Development: La Risposta Strutturale

Non sono l'unico ad aver notato questo problema. È nato un intero movimento attorno a quello che viene chiamato Spec-Driven Development: si progetta prima il sistema in dettaglio, si documentano le scelte architetturali e i vincoli, e solo dopo si lascia eseguire l'agente su quella specifica.

Lo uso, e funziona. Ma c'è una condizione necessaria che spesso viene omessa nelle presentazioni entusiaste: **per scrivere una specifica buona, devi sapere cosa stai specificando**. Non puoi descrivere con precisione un'architettura di sicurezza per Kubernetes se non hai una conoscenza solida di RBAC, dei secrets engine, delle network policy. L'agente seguirà le tue specifiche alla lettera — ma se le specifiche sono vaghe o sbagliate, il risultato sarà vago o sbagliato.

Il metodo funziona perché sposta il lavoro intellettuale dove deve stare: nella testa dell'ingegnere, nella fase di progettazione. E l'agente diventa l'esecutore di un piano preciso, non il progettista.

### 4. Il Debugging e il Carico Cognitivo

Una delle trasformazioni più concrete che ho vissuto riguarda il debugging. Passavo ore — a volte notti — a cambiare flag, ricompilare, testare, leggere stack trace, cercare su forum. Era la parte più frustrante del lavoro. Ed era anche, va detto, la parte più formativa.

Gli agenti lo fanno in parallelo e non si stancano. Quando c'è un problema che non riescono a risolvere, continuano a iterare fino a trovare la soluzione. E poi me la spiegano — non solo cosa hanno fatto, ma perché hanno scelto quell'approccio. Questo è il valore formativo che non mi aspettavo: non solo smetto di fare debugging manuale, ma imparo dai ragionamenti che l'agente esplicita.

Ho preso l'abitudine di non usarli come oracoli silenziosi. Chiedo sempre spiegazioni, discuto le scelte, a volte li metto in discussione. Alla fine di ogni sessione significativa mi faccio fare un resoconto: cosa è stato fatto, quali problemi si sono presentati, come sono stati risolti, quali scelte architetturali sono state prese. In quel momento, rileggendo, mi rendo conto di cose che non avevo notato mentre lavoravamo — scelte che non avrei fatto, vincoli che sono stati aggirati invece di rispettati.

---

## The Human Element: Il Nuovo Ruolo dell'Ingegnere

C'è una metafora che uso spesso tra me e me: l'agente AI è come qualcuno che sa scrivere codice ma ha bisogno di essere **portato al pascolo**. Sa cosa fare, ha le competenze tecniche, ma se gli lasci il volante va dove trova l'erba più vicina, non dove serve andare. Il tuo lavoro è indicare la direzione, verificare il percorso, e correggere quando devia.

Questo cambia profondamente cosa significa essere un ingegnere. Scrivo meno codice. Penso molto di più ad alto livello. Mi concentro su architettura, vincoli, trade-off. Sono diventato più bravo a descrivere sistemi in modo preciso — perché se la descrizione è imprecisa, l'agente produce qualcosa di impreciso.

E sto imparando di più, non di meno. Perché la discussione con un agente informato su un argomento che non conosci bene è uno dei modi più efficaci per approfondirlo che io abbia mai trovato. Non è un motore di ricerca, non è documentazione: è un interlocutore che può rispondere alle domande specifiche del tuo contesto specifico. Sono passato da una conoscenza superficiale di Kubernetes a una comprensione profonda di come funziona la gestione dei segreti, il RBAC, la rotazione delle credenziali — non perché abbia letto un libro, ma perché ho trascorso ore a discuterne nel contesto del mio cluster, del mio caso d'uso, dei miei errori.

---

## Final Synthesis: Raccomandazioni per Chi Lavora sul Serio

La narrativa dominante sull'AI ha un difetto: tende a presentare questi strumenti come livellatori. Come se chiunque, con il prompt giusto, potesse costruire le stesse cose. Non è così — almeno non nel lavoro serio su infrastruttura complessa.

Il mio osservazione, dopo mesi di utilizzo quotidiano, è che **l'AI è un moltiplicatore, non un sostituto**. E la grandezza del moltiplicatore dipende dalla competenza di partenza. Per chi ha una base solida, questi strumenti sono trasformativi — 100x, forse 1000x su certi tipi di lavoro. Per chi non ce l'ha, il beneficio è reale ma molto più limitato.

Questo non significa che siano inutili per chi sta imparando. Significa che per imparare davvero bisogna usarli in modo attivo: discutere, chiedere spiegazioni, mettere in discussione le scelte, costruire la comprensione invece di accettare il risultato. La montagna dell'expertise è ancora alta. Questi strumenti la rendono più scalabile, non più bassa.

Per chi vuole usarli seriamente sull'infrastruttura, alcune lezioni che ho imparato a caro prezzo:

**Non lasciare mai il volante.** Soprattutto su un cluster che ospita servizi reali. Monitoring, analisi, proposta di soluzioni — tutto benissimo. Ma l'approvazione di ogni modifica deve passare da una persona che capisce le conseguenze.

**Progettare prima, eseguire poi.** Uno Spec-Driven Development robusto è la differenza tra un agente che porta avanti il tuo progetto e uno che costruisce qualcosa che dovrai buttare via. Ma questo richiede che tu sappia già come si fa la cosa, almeno nei suoi aspetti fondamentali.

**Verificare sempre l'output critico.** Specialmente in un contesto GitOps: ogni commit che non hai scritto tu va letto. Gli agenti non hanno la percezione del rischio che ha chi ha passato notti a ripristinare un cluster rotto.

**Usare la piattaforma giusta, non il modello giusto.** Un ambiente agnostico che ti permette di cambiare modello senza cambiare workflow vale più di qualsiasi singolo modello. I modelli cambiano continuamente — la settimana scorsa il migliore era uno, adesso è un altro. Il workflow deve rimanere stabile.

Il programmatore non è morto. Si è evoluto in qualcosa di più vicino a un progettista di sistemi che ha a disposizione un team di sviluppatori instancabili, veloci, ben informati — ma che hanno bisogno di sapere esattamente dove devono andare.
