+++
title = "SDD in mezza giornata: un contesto con delle regole, e il DAG del cluster sistemato al primo colpo"
date = 2026-03-15T14:00:00+01:00
draft = false
description = "Come ho implementato un sistema di Spec-Driven Development come semplice contesto Markdown in mezza giornata, e come ha permesso di risolvere un problema persistente al cluster che resisteva da settimane."
tags = ["kubernetes", "flux", "gitops", "agents", "context-management", "sdd", "devops", "workflow"]
categories = ["Infrastructure", "DevOps"]
author = "Taz"
+++

## Gli ultimi sviluppi del TazLab

Questo è uno di quegli articoli che si scrivono quando le cose vanno bene. Nessun incidente da riportare, nessuna rebuild del cluster alle due di notte, nessun Deployment che rifiuta di partire per ragioni incomprensibili. Il lab gira. La pipeline funziona. Ho avuto il tempo di pensare ai processi invece di combattere i problemi.

Nelle ultime sessioni sono successe due cose concrete che vale la pena documentare: ho implementato un sistema di **Spec-Driven Development** come puro contesto Markdown, e ho usato quel sistema per sistemare un problema al DAG di Flux che resisteva da settimane. Il risultato è stato più pulito di quanto mi aspettassi.

## Spec-Driven Development come contesto: zero codice, solo regole

L'articolo precedente sull'[AGENTS.ctx](/posts/ai-context-management-agents-ctx/) descriveva l'idea di base del sistema di gestione dei contesti: ogni dominio operativo ha il suo `CONTEXT.md`, caricato su richiesta, con le regole già scritte. L'agente non cambia — il contesto sì.

La domanda naturale che mi sono posto subito dopo è stata: posso applicare lo stesso principio al processo di sviluppo stesso? Non come tool esterno, non come sistema a sé stante — come un altro contesto da aprire quando ne ho bisogno.

La risposta è sì, e ci ho messo circa mezza giornata.

**SDD** (Spec-Driven Development) è oggi un file `AGENTS.ctx/sdd/CONTEXT.md` con un workflow in quattro fasi e un insieme di regole che l'agente segue quando apre il contesto. Nessun codice. Nessuna dipendenza. Solo Markdown versionato su Git.

### Le quattro fasi

Il workflow che ho definito è deliberatamente lineare, con gate espliciti tra ogni fase. L'agente non può passare alla fase successiva senza approvazione.

**Phase 1 — Constitution.** Il documento fondazionale del progetto. Definisce le fondamenta immutabili: linguaggio, framework, convenzioni di naming, vincoli, librerie proibite. Una volta approvata, la constitution non cambia senza approvazione esplicita. È il documento a cui si torna quando durante l'implementazione emerge un dubbio su "ma avevamo detto di fare così?".

**Phase 2 — Specification.** Definisce *cosa* costruire in dettaglio logico completo. Non l'implementazione — la logica. Input attesi, output desiderati, comportamento per ogni caso. Edge case e gestione degli errori. I criteri di accettazione: quando il lavoro è considerato finito? Questo documento è la fonte di verità. Se durante l'implementazione qualcosa non quadra, si torna qui.

**Phase 3 — Plan.** Definisce *come* costruirlo tecnicamente. Quali file modificare, quali creare. Scelte architetturali e il loro razionale. Dipendenze e ordine di esecuzione. Il piano viene proposto dall'agente sulla base di constitution + spec, e richiede approvazione prima di procedere.

**Phase 4 — Tasks.** La spec viene decomposta in una checklist di micro-task atomici, ognuno segnato come `[ ]` o `[x]`. Ogni task è un'azione discreta e completabile. Durante l'implementazione, il file tasks è il GPS: si apre, si vede il prossimo step pendente, si esegue, si marca completato.

### Il project inventory

Ogni progetto SDD vive in `AGENTS.ctx/sdd/assets/<project-name>/` con i suoi quattro file. Il contesto mantiene una tabella di inventario in `CONTEXT.md` che si aggiorna quando un progetto viene creato o completato. Quando apro il contesto vedo subito lo stato di tutto: cosa è in progress, cosa è bloccato, cosa è completato con le note rilevanti.

Questo ha un effetto pratico importante: ogni sessione successiva non parte da zero. L'agente legge l'inventario, identifica il progetto in progress, carica il tasks.md, e continua dal prossimo step pendente. Il warm-up è quasi inesistente.

La struttura è la stessa che posso passare a Gemini o qualsiasi altro agente: basta far leggere il `AGENTS.ctx/CONTEXT.md` principale, che spiega dove trovare i contesti disponibili, e l'agente è immediatamente orientato senza ulteriori spiegazioni.

## Il primo test reale: flux-dag-fix-v2

La teoria costa poco. Il primo test reale dell'SDD è arrivato subito, con un problema che portavo dietro da settimane: il DAG delle kustomization Flux sul cluster TazLab non si comportava come previsto.

### Il contesto del problema

Il cluster TazLab è gestito interamente via **GitOps con Flux**. Ogni risorsa Kubernetes è definita in Git, Flux riconcilia continuamente lo stato del repository con lo stato del cluster. Le kustomization — i raggruppamenti logici di risorse — hanno dipendenze dichiarate esplicitamente tramite `dependsOn`, e possono avere `wait: true` che forza Flux ad aspettare che tutte le risorse della kustomization siano pronte prima di procedere con le dipendenti.

Il problema aveva già un'analisi precisa alle spalle: un documento strutturato con tabella dei problemi identificati nel DAG, diagramma del grafo obiettivo, sezioni dettagliate per ogni fix, matrice dei rischi e riepilogo delle 15 modifiche da applicare. Non era documentazione approssimativa — era un piano tecnico completo.

La difficoltà era diversa: il piano era pensato come un'unica soluzione da applicare tutta insieme. Tutte le modifiche, un commit, poi verifica finale. Senza una sequenza di passi isolati, senza un gate di verifica tra una modifica e la successiva, senza la possibilità di isolare esattamente quale cambiamento avesse introdotto un problema se qualcosa fosse andato storto.

### L'import nell'SDD

Ho usato il piano esistente come punto di partenza per creare il progetto SDD. L'analisi tecnica era già fatta — quello che mancava era la struttura di esecuzione. Le fasi hanno fatto il loro lavoro:

La **constitution** ha fissato un vincolo fondamentale che nelle sessioni precedenti non avevo mai esplicitato formalmente: *un cambiamento alla volta, ognuno verificato con un ciclo completo di destroy+create prima di procedere al successivo*. Sembra ovvio, ma senza che sia scritto da qualche parte è facile cedere alla tentazione di raggruppare più fix in un unico commit "per risparmiare tempo" — che è esattamente quello che aveva portato alla situazione confusa di partenza.

La **specification** mi ha costretto a enunciare le cause radice reali, non i sintomi. I sintomi erano kustomization bloccate in `NotReady`, dipendenze che non si sbloccavano, pod che non partivano nel giusto ordine. Le cause erano distinte e separate, e richiedevano correzioni separate.

Il **plan** ha decomposto il lavoro in 14 step isolati, ognuno con la sua verifica. Non 14 commit in sequenza cieca — 14 step ognuno con un ciclo destroy+create e un insieme preciso di condizioni da verificare prima di considerarlo completato.

Il file **tasks** è diventato la checklist operativa. Ogni sessione: apri tasks.md, vedi il prossimo step pendente, eseguilo, marcalo completato, chiudi. La sessione successiva: riapri, continua.

### La causa radice

Una volta strutturato il problema correttamente, la causa principale è emersa chiaramente.

La kustomization `infrastructure-operators-core` raggruppava due categorie di risorse fondamentalmente diverse:

1. **Controller leggeri**: cert-manager, traefik, Reloader, Dex, OAuth2-proxy, cloudflare-ddns. Chart Helm relativamente veloci, install in 1-2 minuti.
2. **Chart pesanti**: `kube-prometheus-stack` e `postgres-operator`. Il primo in particolare ha un'installazione che può richiedere 10-15 minuti su hardware lento.

Il problema con `wait: true` su questa kustomization era strutturale: Flux aspetta che *tutte* le risorse della kustomization siano in stato Ready prima di sbloccare le dipendenti. Con `kube-prometheus-stack` dentro `operators-core`, aggiungere `wait: true` significava bloccare l'intero grafo per 15 minuti ogni volta. Tutte le kustomization dipendenti — `infrastructure-bridge`, `infrastructure-instances`, `apps-static`, `apps-data` — restavano ferme ad aspettare che Prometheus finisse di installarsi.

Questo è un errore di progettazione del DAG, non un errore di configurazione. Avevo mescolato risorse con tempi di convergenza radicalmente diversi nello stesso nodo del grafo, e poi cercato di mettere un gate su quel nodo. Il gate era corretto in principio — `wait: true` su `operators-core` garantisce che cert-manager sia pronto prima che i certificati vengano richiesti — ma impossibile nella pratica finché il nodo conteneva chart pesanti.

### La correzione

La correzione era separare i concern. Ho rimosso `../monitoring` e `../postgres-operator` dalla kustomization `infrastructure/operators/core/kustomization.yaml`, lasciandoli nelle loro kustomization dedicate (`infrastructure-monitoring` e `infrastructure-operators-data`) che già esistevano e già gestivano il loro ciclo di vita in modo autonomo.

```yaml
# infrastructure/operators/core/kustomization.yaml — dopo la correzione
resources:
  - ../cert-manager
  - ../traefik
  - ../reloader
  - ../dex
  - ../auth
  - ../cloudflare-ddns
  # kube-prometheus-stack rimosso → gestito da infrastructure-monitoring
  # postgres-operator rimosso → gestito da infrastructure-operators-data
```

Con questa modifica, `operators-core` conteneva solo chart leggeri. L'installazione completa richiedeva 2-3 minuti. `wait: true` è diventato sicuro da abilitare: il gate garantisce che cert-manager, traefik e gli altri controller fondamentali siano operativi prima che le kustomization dipendenti inizino a creare risorse che li richiedono.

Il ciclo finale destroy+create ha dichiarato il blog online in **8 minuti e 20 secondi** — il critical path leggero funzionava esattamente come previsto. Il database PostgreSQL, con il restore da S3 in background, e i servizi dipendenti (Mnemosyne MCP, pgAdmin) hanno completato intorno ai **12-13 minuti**. Tempi nella norma: il restore non è sul critical path del blog, avviene in parallelo mentre i pod upstream già servono traffico.

### Cosa ha cambiato l'SDD in questa sessione

Sarei disonesto se dicessi che senza SDD il problema sarebbe stato irrisolvibile. Probabilmente lo avrei risolto comunque. Ma con più tentativi, più commit disordinati, e quasi certamente avrei introdotto regressioni lungo la strada.

Quello che SDD ha cambiato è la modalità di lavoro: invece di procedere per tentativi locali — "proviamo a togliere questa dipendenza e vediamo cosa succede" — ho dovuto prima enunciare formalmente cosa stava andando storto e perché, poi progettare una sequenza di correzioni verificabili, poi eseguirle una alla volta con conferma esplicita tra ognuna.

Questa disciplina ha un costo in termini di tempo iniziale. Ha un beneficio enorme in termini di chiarezza: quando sei al decimo step di quattordici e qualcosa non si comporta come previsto, sai esattamente cosa hai già verificato, cosa hai escluso, e dove cercare.

## Il ritmo del lavoro con i contesti

C'è un effetto collaterale del sistema dei contesti che non avevo previsto quando l'ho progettato, e che si è rivelato più prezioso di quanto pensassi: il ritmo di lavoro è cambiato.

Prima del sistema dei contesti, ogni sessione aveva un costo di bootstrap non trascurabile. Riaprire una sessione significava rispiegare dove eravamo, qual era lo stato del progetto, quali erano le regole da seguire. Con progetti complessi, questo poteva richiedere diversi scambi di messaggi prima di essere operativi.

Oggi il pattern è diventato: apro il terminale, carico il contesto, sono operativi in pochi secondi. Il contesto porta con sé le regole, lo stato del progetto, il prossimo step da eseguire. Chiudo il terminale, riapro, sono di nuovo esattamente dove ero.

Questo ha cambiato anche il modo in cui penso alle nuove funzionalità. Quando voglio aggiungere una nuova capacità al mio workflow, non penso più "ho bisogno di un nuovo agente specializzato". Penso "ho bisogno di un nuovo contesto con le regole giuste". Scrivo il `CONTEXT.md`, definisco il comportamento atteso, e ogni agente che lo legge si comporterà coerentemente.

Il vantaggio in termini di portabilità è reale. Passare a Gemini da Claude non richiede di reimpostare nulla: basta far leggere il `AGENTS.ctx/CONTEXT.md` principale, che spiega la struttura del sistema, dove trovare i contesti disponibili e le regole generali. L'agente è immediatamente orientato. Non c'è lock-in su nessun tool specifico.

## Riflessioni

Questa tappa del percorso ha confermato qualcosa che intuivo ma non avevo ancora sperimentato direttamente: la struttura del processo ha un impatto sulla qualità dell'output tanto quanto le capacità tecniche.

Il problema del DAG di Flux non era difficile una volta enunciato correttamente. La difficoltà era nell'enunciarlo correttamente dopo settimane di tentativi disorganizzati che avevano accumulato rumore. SDD non ha aggiunto capacità tecniche — ha aggiunto il framework per usare quelle capacità in modo ordinato.

C'è un'altra cosa che vale la pena notare: il sistema è volutamente semplice. Non c'è un tool da installare, non c'è un database da configurare, non c'è un server da mantenere. Sono file Markdown in una cartella Git. Questa semplicità non è una limitazione — è una scelta progettuale consapevole. Un sistema che dipende da pochi strumenti ubiqui è un sistema che sopravvive ai cambiamenti dell'ecosistema e funziona su qualsiasi macchina, con qualsiasi agente.

Il prossimo passo naturale è usare questo stesso sistema per i progetti futuri, raccogliendo nel tempo un inventario di spec, piani e task completati che documenta non solo cosa è stato costruito, ma perché è stato costruito così.
