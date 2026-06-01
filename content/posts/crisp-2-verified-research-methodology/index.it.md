+++
title = "CRISP 2.0: Ricerca Obbligatoria, Piano Verificato, Zero Assunzioni"
date = 2026-06-01T07:30:00+02:00
draft = false
description = "Dopo aver teorizzato il ciclo CRISP nel post precedente, l'ho formalizzato in un workflow concreto e l'ho testato su tre progetti di migrazione Vault in un pomeriggio. Il risultato: zero bug, zero redesign, tre progetti completati. Ecco com'è andata."
tags = ["crisp", "methodology", "vso", "vault", "kubernetes", "deep-research", "workflow", "infrastructure", "enterprise"]
categories = ["Perspective", "DevOps", "Methodology"]
author = "Taz"
+++

# CRISP 2.0: Ricerca Obbligatoria, Piano Verificato, Zero Assunzioni

## L'Antefatto

Due giorni fa ho preso una decisione radicale: abbandonare il Vault Agent Injector che avevo appena finito di implementare e migrare tutto a Vault Secrets Operator (VSO).

Sembra un passo indietro. In realtà è stata la dimostrazione che il metodo funziona. Due giorni di progettazione con ricerche mirate, un pomeriggio di implementazione, e tre progetti di migrazione completati — dal Vault Agent Injector a VSO, passando per la migrazione di tutti i segreti statici da External Secrets Operator, fino alla riconfigurazione di Grafana per usare credenziali dinamiche. Zero bug in produzione, zero redesign durante la build.

Questo articolo non è un tutorial. È la cronaca di come un metodo di lavoro, applicato con disciplina, può trasformare un'operazione complessa in un processo prevedibile.

## Dal Ciclo al Metodo

Nel post precedente descrivevo un ciclo di lavoro che chiamavo CRISP: Context, Research, Intent, Structure, Plan. Era una descrizione di come lavoravo, non un metodo formale. La deep research era consigliata, non obbligatoria. Il piano era una traccia, non un contratto verificato.

L'esperienza dei mesi precedenti — e in particolare la scoperta che VSO era migliore dell'Injector, emersa durante una ricerca di approfondimento — mi ha portato a chiedermi: se una ricerca fatta a metà del progetto ha cambiato le scelte architetturali, cosa succederebbe se la ricerca fosse il primo passo obbligatorio, non un ripensamento?

Da questa domanda è nato CRISP 2.0, un'evoluzione formale del ciclo precedente. Le differenze sono sostanziali:

1. **Deep Research First non è opzionale.** Ogni progetto inizia con ricerche specifiche su ogni aspetto non pienamente compreso. Le ricerche non sono esplorative — sono guidate da prompt strutturati che includono contesto architetturale, versione esatta dei componenti, domande specifiche e criteri di valutazione.

2. **Le ricerche hanno una casa.** Ogni ricerca viene salvata come file Markdown nella cartella `web-research/` del progetto, con un indice centrale che le cataloga per argomento e progetto correlato. Non si perdono più informazioni.

3. **Il piano ha marker di verifica.** Ogni task in PLAN.md deve essere marcato come `[🔍 confermato da: web-research/nome-file.md]` oppure `[🔍 da verificare]`. Nessun task può essere implementato senza una ricerca che ne confermi i presupposti.

4. **La realtà vince sulla documentazione.** Research Grounding Rule: prima di implementare qualsiasi migrazione, bisogna verificare lo stato reale con strumenti CLI. I file YAML dei manifest e le ricerche descrivono come le cose *dovrebbero* funzionare. La realtà può essere diversa.

5. **Il ciclo di verifica è obbligatorio.** Review → fix → ricerca → ripeti, fino a che ogni singolo marker non è confermato. Solo allora si passa alla build.

6. **Retrospettiva obbligatoria.** Ogni progetto completato produce un report che analizza deviazioni dal piano, decisioni prese durante la build, problemi incontrati e lacune emerse nella fase di progettazione.

Sembra burocrazia. Non lo è. È un investimento — e come tutti gli investimenti, va misurato.

## Il Test: Tre Progetti in un Pomeriggio

Per testare il metodo, ho scelto il nodo più complesso del progetto Vault: la migrazione dei segreti da ESO e Vault Agent Injector a Vault Secrets Operator. L'ho suddiviso in tre progetti indipendenti:

- **12-vso-foundation**: installare VSO, configurare l'autenticazione JWT verso il Vault esterno via Tailscale, verificare con un secret pilota.
- **13-vso-static-migration**: migrare tutti i segreti statici da External Secrets Operator a VaultStaticSecret, rimuovere Stakater Reloader.
- **14-vso-dynamic-migration**: migrare Grafana dal Vault Agent Injector a VaultDynamicSecret, rimuovere l'injector dal cluster.

Tre progetti, tre ambiti distinti, tre piani separati. Ognuno con le proprie ricerche, il proprio DESIGN.md, il proprio PLAN.md.

Ecco cosa è successo.

### Tre Review per Progetto

Ogni progetto è passato attraverso tre cicli di revisione prima della build. Il primo agente di review identificava i problemi architetturali. Dopo ogni fix, un secondo agente verificava le correzioni. Un terzo ciclo confermava che tutto fosse a posto.

Nel progetto 12, la prima review ha trovato un errore progettuale: il metodo di autenticazione proposto (`method: kubernetes`, basato su TokenReview) era incompatibile con un Vault esterno su Tailscale. La ricerca R14 ha confermato che `method: jwt` era la scelta enterprise corretta, riutilizzando l'backend `auth/jwt` già configurato — esattamente il tipo di scoperta che il metodo è progettato per favorire.

La seconda review ha trovato un bug più sottile: il Vault role era configurato con `bound_subject` che faceva match sull'identità del ServiceAccount del controller VSO. Ma la ricerca R15 ha rivelato che VSO risolve il ServiceAccount nel namespace *del consumer*, non in quello del VaultAuth. Il fix (`bound_claims_type=glob` con pattern `system:serviceaccount:*:vso-auth-sa`) ha risolto un problema che sarebbe emerso solo in produzione, probabilmente come fallimento silenzioso della sincronizzazione dei segreti.

Senza il ciclo di review, entrambi i bug sarebbero arrivati in produzione.

### Il Problema Complesso: Grafana e le Env Var

L'ultimo progetto, la migrazione di Grafana, ha presentato la sfida più insidiosa. kube-prometheus-stack v61.3.1, il chart Helm che gestisce Grafana nel cluster, genera automaticamente le variabili d'ambiente `GF_DATABASE_USER` e `GF_DATABASE_PASSWORD` ogni volta che il database non è SQLite. Queste variabili vengono create con valore stringa vuota — ma intanto esistono, e Grafana le interpreta come conflitto con le loro equivalenti `__FILE` che volevamo usare per puntare ai file montati dal VaultDynamicSecret.

Il risultato era un crash immediato del container:

```
ERROR: Both GF_DATABASE_PASSWORD and GF_DATABASE_PASSWORD__FILE are set (but are exclusive)
```

Il problema non era nella configurazione, ma nel template engine del chart Helm. La prima ricerca ha suggerito di usare `envValueFrom`. Non ha funzionato — il chart non passava i valori al sub-chart Grafana. La seconda ricerca ha identificato il pattern corretto, chiamato *SQLite Template Bypass*: impostare il tipo database a `sqlite3` per evitare che il chart generi le variabili conflittuali, e poi sovrascrivere tutto a runtime via variabili d'ambiente standard.

La soluzione è stata:

```yaml
grafana:
  database:
    type: sqlite3
  grafana.ini:
    database: null
  env:
    GF_DATABASE_TYPE: "postgres"
    GF_DATABASE_USER__FILE: "/etc/secrets/grafana-dynamic-creds/username"
    GF_DATABASE_PASSWORD__FILE: "/etc/secrets/grafana-dynamic-creds/password"
```

Due ricerche, forse trenta minuti totali. In un approccio tradizionale, sarebbero state ore di debugging, tentativi, lettura dei log, analisi del template Helm. Qui abbiamo identificato il problema, cercato la soluzione, applicato. Fine.

Non è che il problema non esistesse — è che il tempo per risolverlo è stato ridotto da ore a minuti.

## La Lezione Economica: DeepSeek V4 Flash

Tutto il lavoro descritto in questo articolo — progettazione, review, implementazione — è stato eseguito con DeepSeek V4 Flash. Non il modello più costoso, non il più capace in classifica. Un modello che costa pochissimo.

E ha funzionato.

La ragione è che il metodo CRISP 2.0 sposta il carico di lavoro dall'esecuzione (dove serve un modello potente) alla progettazione (dove serve un essere umano che decide). Quando il progetto è solido, quando i piani sono verificati, quando ogni scelta è supportata da una ricerca, il modello più economico è sufficiente. La fase difficile è quella decisionale — e quella resta umana.

Per i problemi complessi — il Grafana env var conflict è l'esempio — due ricerche mirate hanno risolto in minuti quello che sarebbe stato un pomeriggio di debugging. In un flusso di lavoro tradizionale, il modello avrebbe provato varianti, fallito, riprovato, fino a esaurire il contesto. Con CRISP 2.0, il modello si ferma, dice "non funziona, mi serve una ricerca su questo punto specifico", e con quella ricerca torna con la soluzione.

Questa è la differenza tra usare un LLM come un esecutore e usarlo come un collaboratore.

## Vibe Coding vs Infrastruttura: Due Mondi Diversi

C'è un dibattito crescente su come usare gli LLM per scrivere codice. Il "vibe coding" — descrivere un'applicazione in linguaggio naturale e lasciare che l'LLM la generi integralmente — funziona per certi tipi di sviluppo software. Per l'infrastruttura enterprise, no.

L'infrastruttura non è codice lineare. È un sistema di vincoli: il cluster ha un nodo worker solo, il Vault è su una VM Hetzner raggiungibile solo via Tailscale, il filesystem di Talos è read-only, il budget non permette modelli costosi. Un LLM non può valutare questi vincoli perché non li conosce. O peggio, li valuta sulla base della sua preparazione statistica, che potrebbe essere datata di mesi.

Il metodo CRISP 2.0 non elimina l'LLM. Lo incanala. L'LLM fa le ricerche, scrive i piani, implementa le soluzioni, verifica i risultati. Ma le decisioni — quale metodo di autenticazione usare, come strutturare il progetto, quando fermarsi e fare una ricerca — restano umane.

È un patto: l'umano decide cosa fare e perché, l'LLM fa e verifica. Funziona solo se entrambe le parti rispettano il proprio ruolo.

## I Numeri del Pomeriggio

Alla fine del pomeriggio, il bilancio è stato:

- **3 progetti CRISP** completati: foundation, static migration, dynamic migration
- **8 VaultStaticSecret** creati, tutti Healthy
- **1 VaultDynamicSecret** per Grafana, funzionante
- **1 Vault Agent Injector** rimosso
- **1 Reloader** rimosso
- **0 bug in produzione**
- **0 redesign durante la build**
- **2 ricerche per il problema complesso** (Grafana env var)
- **1 modello economico** (DeepSeek V4 Flash) per tutto il lavoro

Tre problemi che avrebbero potuto far deragliare il progetto — auth method sbagliato, bound_subject incompatibile, env var conflict — sono stati identificati e risolti durante la progettazione, prima che diventassero bug.

## Conclusioni

Il metodo CRISP 2.0 ha superato il suo primo test reale. Tre progetti di migrazione completati in un pomeriggio, con un livello di qualità che ritengo alto: nessun bug in produzione, nessuna regressione, nessuna scoperta durante la build che abbia richiesto di tornare alla fase di progettazione.

Non è perfetto. Durante la build sono emersi dettagli che la progettazione non aveva previsto: la struttura esatta dei path Vault (che non erano foglia ma directory), i nomi delle chiavi nelle secret (che VSO gestisce diversamente da ESO), il conflitto delle variabili d'ambiente di Grafana. Ma nessuno di questi ha richiesto un redesign — sono stati risolti con ricerche mirate o con correzioni locali.

Cosa rende questo metodo efficace? Tre ingredienti:

1. **Le ricerche sono specifiche e contestualizzate.** Un prompt di ricerca per CRISP non è "cerca come si fa X". È un documento che include architettura, versioni, domande precise e criteri di valutazione. La qualità della risposta dipende dalla qualità della domanda.

2. **Il ciclo di verifica è obbligatorio, non opzionale.** Tre review per progetto non sono eccessive — sono il meccanismo che ha prevenuto i bug più critici.

3. **Il metodo separa netamente progettazione ed esecuzione.** Si progetta finché ogni scelta non è verificata. Poi si esegue. Non si mescolano le due fasi.

Questo modello di lavoro è specifico per infrastruttura enterprise. Per lo sviluppo software — scrivere un'applicazione, un API server, un frontend — il rapporto è diverso. Lì il codice è il prodotto, e l'iterazione rapida ha senso. Qui il codice è la configurazione di un sistema, e un errore non produce un bug da fixare: produce un cluster non funzionante.

La differenza è che l'infrastruttura non perdona la fretta.
