+++
title = "GitOps for Knowledge: trasformare un wiki di progetto in una superficie operativa"
date = 2026-04-25T05:10:51+00:00
draft = false
description = "Cronaca tecnica di come ho trasformato `wiki.tazlab.net` da semplice repository markdown in una knowledge base operativa per agenti e umani, pubblicata via Hugo, Docker, Flux e Kubernetes."
tags = ["wiki", "gitops", "hugo", "flux", "kubernetes", "agents", "documentation", "llm", "knowledge-base", "devops", "context-management"]
categories = ["DevOps", "Architecture", "AI"]
author = "Taz"
+++

# GitOps for Knowledge: trasformare un wiki di progetto in una superficie operativa

## L'obiettivo della giornata

Negli ultimi mesi ho costruito molte parti del TazLab in modo abbastanza disciplinato: l'ambiente operativo con TazPod, la base infrastrutturale con `ephemeral-castle`, il layer GitOps del cluster con `tazlab-k8s`, i contesti `AGENTS.ctx`, la memoria attiva e la memoria semantica. Tutti pezzi utili. Tutti pezzi che, presi singolarmente, avevano già iniziato a ridurre parecchio il caos operativo.

Ma mancava ancora una cosa importante: una superficie di documentazione navigabile, duratura e leggibile sia da me sia dagli agenti. Non una raccolta di note buttate in una cartella. Non un dump di file markdown. E nemmeno una documentazione tradizionale pensata solo per un lettore umano che apre una pagina alla volta e la consuma in ordine lineare.

Il problema concreto era questo: ogni volta che volevo far lavorare un agente su una parte specifica del progetto, dovevo ancora ricostruire a mano un pezzo di contesto. Certo, avevo già `AGENTS.ctx`, e quello aveva cambiato molto il workflow. Ma il contesto operativo non basta da solo se la conoscenza di dettaglio resta intrappolata nel codice, nei manifest, negli script, nei README storici, nei file `docs/` dimenticati in repository diversi, o peggio ancora nella mia memoria a breve termine.

Per questo ho deciso di fare un passo ulteriore: costruire un vero wiki di progetto, pubblicato come servizio del cluster, organizzato in pagine atomiche, linkate tra loro, e pensato esplicitamente per essere sezionato in micro-contesti utili a futuri agenti. Il risultato è ora visibile qui:

**[wiki.tazlab.net](https://wiki.tazlab.net)**

Questa non è solo la cronaca di un nuovo servizio statico deployato sul cluster. È la cronaca di un cambio di livello: trattare la documentazione non come una conseguenza del progetto, ma come una sua parte operativa. E, nel mio caso, trattarla con la stessa serietà con cui tratto il GitOps, l'infrastruttura o la gestione dei segreti.

## Il contesto teorico: da Karpathy al laboratorio reale

L'ispirazione di fondo viene da un'idea che negli ultimi mesi ha iniziato a circolare molto tra chi lavora con agenti e sistemi LLM-oriented: l'idea di un **LLM Wiki**, cioè una base di conoscenza strutturata, mantenuta e resa navigabile anche dagli agenti, non solo dagli umani.

Il riferimento esplicito è il lavoro di Andrej Karpathy, in particolare:

- il gist: [https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)
- il tweet: [https://x.com/karpathy/status/2039805659525644595](https://x.com/karpathy/status/2039805659525644595)

L'idea è semplice solo in apparenza. Se un progetto cresce, il codice da solo non è più un'interfaccia sufficiente per ricostruire il contesto. Il codice è la verità dell'implementazione. Ma non è sempre la verità della navigazione mentale. Non ti dice facilmente perché una cosa è stata fatta in un certo modo, in quale cartella cercare una certa responsabilità, quali concetti appartengono a un certo sottosistema, quali pagine leggere prima di mettere mano a una pipeline o a un runtime.

In altre parole: il codice è il punto di arrivo dell'esecuzione, ma non sempre è il miglior punto di partenza per la comprensione.

Questo è ancora più vero quando entrano in gioco gli agenti. Un agente può certamente cercare nel codice, fare grep, leggere manifest, aprire dieci file e provare a costruire un modello mentale locale del sistema. Ma se ogni volta deve ripercorrere da zero questo tragitto, il costo di bootstrap resta alto. E soprattutto la qualità del contesto dipende troppo dalla fortuna: quali file ha aperto, in che ordine, quanto era accurata la documentazione legacy, quanto era coerente la nomenclatura delle directory, quanto rumore c'era intorno all'informazione utile.

Io volevo evitare esattamente questo. Non volevo una base di conoscenza "bella". Volevo una base di conoscenza **operativa**.

## Il problema reale: avere troppa conoscenza e non poterla caricare bene

Paradossalmente, il problema non era la mancanza di informazione. Il problema era la frammentazione dell'informazione.

Nel mio caso, TazLab aveva già parecchi strati documentali:

- i repository stessi (`tazpod`, `ephemeral-castle`, `tazlab-k8s`, `blog-src`, `mnemosyne-mcp-server`)
- i file di contesto sotto `AGENTS.ctx`
- la documentazione interna dei singoli repository
- gli articoli del blog
- i dettagli correnti preservati nella memoria attiva
- gli artefatti storici e la memoria semantica

Messa così, sembrerebbe quasi un lusso. In realtà è un rischio. Perché quando l'informazione è distribuita tra troppi livelli, serve ancora una superficie che dica: *se devi lavorare su questa cosa, parti da qui; se devi capire questa parte, leggi prima quest'altra; se devi toccare quel layer, guarda questa mappa e poi questi file*.

È esattamente il tipo di bisogno che un wiki ben fatto riesce a risolvere. Ma solo a due condizioni:

1. non sia un accumulo generico di pagine scollegate;
2. venga mantenuto allineato al codice, e non trattato come materiale di contorno.

Questa seconda condizione è quella più difficile. Perché significa accettare che la documentazione va progettata come un sistema. E appena accetti questa idea, cambia tutto: non stai più "scrivendo note", stai costruendo un layer del progetto.

## La reinterpretazione TazLab: non solo knowledge base, ma documentazione di progetto e layer di contesto

Nel mio caso, il wiki non doveva servire solo agli agenti. Doveva servire anche a me.

Io volevo un posto in cui poter ritrovare rapidamente:

- come è fatto il DAG di Flux,
- dove stanno i layer Terragrunt,
- come funziona il restore di Vault da S3,
- quali namespace usa il cluster e perché,
- come è organizzata la delivery chain di un servizio statico,
- dove si trovano davvero i manifest applicativi,
- quali sono i percorsi corretti per toccare `tazpod`, `ephemeral-castle` o `tazlab-k8s` senza riaprire ogni volta quindici file di codice.

Il wiki quindi è diventato contemporaneamente tre cose:

1. **documentazione operativa per me**,
2. **superficie di navigazione per nuovi agenti**,
3. **strato di sintesi tra codice, memoria e repository**.

Questo è il punto in cui la nozione di *LLM Wiki* è diventata davvero utile nel laboratorio. Non come slogan, ma come infrastruttura cognitiva.

## La regola progettuale più importante: pagine atomiche, non monoliti

Se avessi messo tutto in poche pagine gigantesche, il wiki sarebbe diventato subito un altro blob ingestibile. Quindi la regola fondamentale è stata la stessa che già mi aveva aiutato con CRISP e con la memoria: **scomporre**.

Ho organizzato il wiki in sezioni abbastanza piccole e abbastanza specifiche da essere utili come mattoni di contesto:

- `entities/` per i repository e i sistemi principali,
- `topics/` per le sintesi trasversali,
- `operations/` per i runbook,
- `sources/` per i riassunti delle fonti,
- `analyses/` per i nodi di chiarimento e drift,
- `concepts/` per i modelli mentali più generali.

La differenza non è cosmetica. È il fatto che un agente che deve lavorare, per esempio, sulla parte GitOps del cluster, non è costretto a leggere l'intero universo TazLab. Può partire da `tazlab-k8s`, aprire il DAG di Flux, poi i layer, poi le pagine sui secrets, poi le pagine sulle ingress class e sull'image automation. Il contesto viene composto per navigazione mirata, non per ingestione indiscriminata.

Questo per me è uno dei veri vantaggi del pattern: il wiki diventa *ritagliabile*. Non è solo navigabile; è **sezionabile**.

## Il lato interessante: il cluster era ormai abbastanza maturo da far sembrare tutto banale

Una delle cose più istruttive di questa implementazione è stata proprio la distribuzione dei problemi.

Se avessi provato a mettere in piedi `wiki.tazlab.net` mesi fa, probabilmente sarebbe stata una maratona di attrito: namespace da chiarire, pipeline da correggere, automazione immagini incompleta, ingress ambigui, secret delivery non ancora pulita, operatori in uno stato troppo fragile per trattare un nuovo servizio come una semplice aggiunta.

Invece stavolta il cluster si è comportato da cluster maturo.

E questa, per me, è la vera notizia di sfondo dell'articolo.

Il lavoro di progettazione precedente — soprattutto quello fatto bene in CRISP, con decomposizione e passaggi stretti — ha prodotto un effetto molto concreto: quando è arrivato il momento di aggiungere un nuovo servizio statico, la parte infrastrutturale non ha opposto resistenza. Non perché fosse banale in assoluto, ma perché le fondamenta erano già al posto giusto.

È una differenza importante. In un sistema immaturo, ogni nuova funzione è un test di sopravvivenza dell'architettura. In un sistema maturo, una nuova funzione diventa soprattutto un problema di modellazione dell'applicazione e del contenuto. La piattaforma smette di essere il collo di bottiglia.

Ed è esattamente quello che è successo qui.

## Il publication layer Hugo: la parte che ha fatto attrito sul serio

Il punto in cui ho speso davvero energia non è stato Kubernetes. Non è stato Flux. Non è stato l'ImagePolicy. Non è stata la namespace isolation. Non è stata la wildcard TLS delivery.

La parte che ha fatto attrito è stata **Hugo**.

Ho scelto deliberatamente di non deformare il repository del wiki per far felice il generatore statico. Il contenuto canonico doveva restare sotto `wiki/`, con la sua organizzazione pensata per agenti e umani, non essere ristrutturato per diventare una finta cartella `content/` di Hugo.

Quindi ho costruito un adapter sotto `publish/`, con mount espliciti, una homepage separata (`homepage.md`), una distinzione netta tra porta pubblica e indice interno, e un layer di presentazione abbastanza minimo da non tradire la natura del repository sorgente.

Questa scelta, che architetturalmente considero corretta, ha spostato l'attrito sul publication layer:

- mount da allineare,
- link markdown da rendere compatibili,
- homepage da distinguere dall'indice interno,
- `baseURL` da fissare correttamente,
- `enableGitInfo` da disattivare nel build Docker per non pretendere `.git` dentro l'immagine,
- prove sui temi Hugo che si sono rivelate molto meno intercambiabili di quanto sembri a prima vista.

Questo è un esempio utile di come lavorano davvero questi sistemi. L'infrastruttura matura non elimina i problemi. Li **sposta** nei punti dove il design sta ancora evolvendo.

## La parte GitOps, invece, è andata esattamente come dovrebbe andare

Sul lato cluster, il comportamento è stato quasi didattico.

Ho costruito la lane del wiki in `tazlab-k8s` seguendo il pattern già esistente del blog:

- namespace dedicato,
- wildcard TLS delivery nel namespace corretto,
- `Deployment`, `Service`, `Ingress`,
- `ImageRepository`, `ImagePolicy`, `ImageUpdateAutomation`,
- `Kustomization` separata (`apps-static-wiki`) invece di infilare tutto nel lane del blog.

Il risultato è stato esattamente quello che speravo da un cluster maturo:

1. GitHub Actions builda l'immagine del wiki.
2. Docker Hub riceve il nuovo tag `wiki-<run>-<sha>`.
3. Flux lo vede tramite `ImageRepository`.
4. `ImagePolicy` seleziona il tag più recente.
5. `ImageUpdateAutomation` aggiorna il manifest.
6. Il cluster riconcilia.
7. Il pod parte.
8. L'Ingress diventa disponibile su `wiki.tazlab.net`.

La cosa più interessante è che questo flusso, una volta corretti due difetti reali di build, ha funzionato senza richiedere interventi strutturali sul cluster. Il modello GitOps ha fatto esattamente il suo mestiere. Io ho dovuto solo descrivere il nuovo servizio usando il linguaggio che la piattaforma già capisce.

Per chi progetta cluster, questo è un punto molto importante: la maturità non si misura quando fai il primo deploy. Si misura quando aggiungi il ventunesimo servizio e non devi reinventare niente.

## I due errori veri che hanno bloccato la publication pipeline

Ci sono stati due errori reali nel publication path del wiki, ed entrambi sono istruttivi.

### 1. L'autenticazione Docker Hub

Il primo fallimento è stato il più banale e anche il più tipico: la GitHub Action del wiki non aveva ancora il secret corretto per Docker Hub.

Qui la differenza tra sistema fragile e sistema robusto si vede bene. In un sistema fragile, un errore del genere ti porta a dubitare di tutto il resto. In un sistema robusto, il fallimento è leggibile, localizzato, e si corregge senza intaccare il modello generale.

Una volta allineato il contract del secret `DOCKER_PASSWORD`, il publication flow ha superato l'autenticazione e si è spostato sul problema successivo.

### 2. Hugo dentro Docker e `enableGitInfo`

Il secondo errore era più interessante: Hugo cercava metadata Git durante il build dell'immagine, ma il Docker build context non includeva `.git`.

Questa è una di quelle situazioni che rivelano subito se stai costruendo una pipeline reale o solo simulando un deploy locale. In locale tutto andava, perché il repository Git era lì. Dentro il builder container no.

La soluzione corretta non era infilare `.git` nell'immagine, che sarebbe stata una forzatura architetturale e un inutile rumore nel container finale. La soluzione corretta era riconoscere che il wiki non aveva bisogno di Git metadata in quella fase e fissare la configurazione con `enableGitInfo = false`.

È una piccola correzione, ma dice molto su come considero questi sistemi: non cerco workaround spettacolari quando basta rimuovere una dipendenza non necessaria.

## Il problema più fastidioso: `baseURL`, link e temi Hugo

Se c'è una parte che ha ricordato quanto i temi Hugo siano meno intercambiabili di quanto si racconti, è stata questa.

Ho voluto provare un allineamento estetico con Blowfish, il tema del blog, e mi sono scontrato subito con il lato meno elegante di questi ecosistemi: i temi non sono solo skin. Sono framework impliciti. Si portano dietro aspettative su front matter, struttura del contenuto, layout, tassonomie, rendering dei link, pagina home e lista delle sezioni.

In un certo senso era inevitabile. Il wiki nasce come knowledge surface agent-oriented, non come blog Hugo-native. Quindi ogni tentativo di trattarlo come se fosse già contenuto modellato per un tema esterno produce attrito.

Alla fine, la lezione è stata molto semplice: quando una cosa funziona, è spesso meglio tenerla sobria e pulita piuttosto che forzarla dentro un'estetica che nasce per un altro scopo. La versione finale che ho mantenuto non è quella più ambiziosa in termini di tematizzazione. È quella più stabile, leggibile e coerente con il contenuto.

Questa per me è una lezione generale, non solo su Hugo: **il publication layer non deve imporre una struttura mentale sbagliata al contenuto**.

## Il cuore del progetto: il wiki come strumento per creare contesti più piccoli e più utili

Il valore vero di `wiki.tazlab.net` non è che adesso esiste una nuova sottodirectory in più o un nuovo hostname nel cluster. Il valore è che adesso esiste una superficie dove la conoscenza è organizzata con una granularità che posso riusare.

Questo significa che posso costruire contesti per gli agenti in modo molto più preciso.

Per esempio:

- un agente che deve lavorare su `ephemeral-castle` può leggere solo la mappa architetturale, il rebirth protocol, i layer Terragrunt, Vault runtime e Tailscale;
- un agente che deve lavorare su `tazlab-k8s` può leggere DAG Flux, repository mapping, image automation, ingress/auth e monitoring;
- un agente che deve lavorare su `tazpod` può leggere image hierarchy, RAM vault security, dotfiles/provisioning e sync daemon.

Questa possibilità di ritagliare il contesto è, secondo me, molto più importante di quanto sembri. Perché il vero nemico degli agenti non è solo la mancanza di informazione. È l'eccesso di informazione non organizzata.

Un wiki fatto bene non è quindi solo un posto dove conservi cose. È un posto dove **decidi in che forma renderle caricabili**.

## Il cluster maturo come premessa di semplicità

Se devo tirare fuori una morale tecnica da questa implementazione, è questa: la semplicità che percepisci nel passo finale non nasce dal passo finale. Nasce da tutto il lavoro di progettazione che lo rende possibile.

Mettere online il wiki è stato semplice non perché Hugo sia sempre semplice, o perché Kubernetes sia sempre semplice, o perché Flux sia magia. È stato semplice perché il cluster era già sufficientemente maturo da assorbire un nuovo servizio senza costringermi a ripensare tutto.

Questo per me è uno dei segnali migliori che un'infrastruttura sta iniziando a diventare davvero utile. Non quando supporta il primo demo. Ma quando supporta con naturalezza una nuova funzione trasversale come questa: documentazione, knowledge layer, onboarding per agenti, publication pipeline, nuova lane Flux, nuovo hostname, nuovo deployment lifecycle.

Se tutto questo entra senza tensione eccessiva, vuol dire che la piattaforma sta iniziando a fare il proprio mestiere.

## Cosa abbiamo imparato in questa tappa

Questa tappa mi ha lasciato alcune convinzioni abbastanza nette.

La prima è che il pattern dell'**LLM Wiki** è reale e utile. Non è una moda passeggera legata al nome di chi l'ha resa popolare. Funziona davvero quando hai un progetto che supera una certa soglia di complessità e quando vuoi far lavorare agenti su pezzi diversi senza costringerli a ricostruire il mondo ogni volta.

La seconda è che il valore di questo approccio cresce tantissimo quando il wiki non è solo una knowledge base "per gli agenti", ma anche un manuale operativo per l'umano che mantiene il sistema. Questo crea un allineamento forte: se la documentazione serve davvero anche a me, allora ho un incentivo reale a mantenerla viva e a farla corrispondere al codice.

La terza è che la maturità di una piattaforma si misura bene quando aggiungi un nuovo layer e la parte più difficile non è più l'infrastruttura. In questo caso il cluster, Flux e la delivery chain hanno fatto il loro lavoro. L'attrito si è spostato sul publication layer del wiki, che era il pezzo meno consolidato. È un ottimo segnale.

La quarta è che il wiki, così costruito, diventa una sorgente di verità intermedia molto potente: non sostituisce il codice, non sostituisce la memoria, non sostituisce i contesti. Li collega. E rende navigabile la loro relazione.

## Riflessioni finali

Se dovessi descrivere in una frase cosa ho costruito oggi, direi questo: **ho smesso di trattare la documentazione come un output e ho iniziato a trattarla come una superficie operativa del progetto**.

Nel mio caso, questa superficie ora vive su `wiki.tazlab.net`, ma il punto non è il dominio. Il punto è il modello.

Prendere il codice, la memoria, la documentazione sparsa, le decisioni, i runbook, i drift reali e trasformarli in un wiki navigabile e ritagliabile cambia il modo in cui si lavora con un sistema complesso. Cambia il mio modo di ricordare dov'è una cosa. Cambia il modo in cui un agente può essere allineato. Cambia il costo di riapertura di un problema dopo giorni o settimane.

E soprattutto cambia il tipo di domanda che puoi fare a un agente. Non più solo: *trova nel codice dove succede questa cosa*. Ma anche: *caricati il contesto giusto, capisci come è fatto quel sottosistema, poi lavora lì dentro con precisione*.

Per me, questo è il vero senso di `GitOps for Knowledge`. Non applicare GitOps a un sito statico. Ma trattare la conoscenza di progetto con la stessa disciplina con cui tratto l'infrastruttura: struttura esplicita, pipeline chiara, aggiornamento continuo, deploy ripetibile, e una superficie finale che non sia solo pubblicata, ma anche utilizzabile.
