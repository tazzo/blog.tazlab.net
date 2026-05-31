+++
title = "La Ricerca che ha Ucciso l'Injector: Perché Uso le Deep Research per Guidare gli LLM"
date = 2026-05-30T10:00:00+02:00
draft = false
description = "Dopo aver speso settimane a costruire un setup con Vault Agent Injector, una ricerca sul web mi ha mostrato che Vault Secrets Operator era la scelta migliore. Non ho perso tempo: ho imparato. Ed è esattamente così che vanno usati gli LLM — non per scrivere codice, ma per esplorare, progettare, verificare."
tags = ["ai", "llm", "vso", "vault", "kubernetes", "deep-research", "crisp", "workflow", "methodology"]
categories = ["Perspective", "DevOps", "AI"]
author = "Taz"
+++

# La Ricerca che ha Ucciso l'Injector: Perché Uso le Deep Research per Guidare gli LLM

## The Thesis

L'intelligenza artificiale non sta sostituendo gli ingegneri. Sta cambiando radicalmente il rapporto tra il tempo speso a progettare e il tempo speso a eseguire. Ma per ottenere risultati professionali — quelli che funzionano, che si mantengono, che non crollano al primo edge case — serve un processo. Serve qualcuno che decida, che verifichi, che dica "no, questa strada non va bene, ne abbiamo un'altra".

Questo articolo non è una difesa dell'AI. È una spiegazione di come la uso, perché funziona, e perché il "vibe coding" — lasciare che l'agente faccia tutto da solo — non è il modo giusto per costruire infrastruttura enterprise.

## La Scintilla: Una Decisione Che Pensavo Giusta

Per settimane ho lavorato a un progetto: Vault Agent Injector sul cluster Talos. L'ho progettato, implementato, testato. Ho scritto articoli, documentato pattern, risolto bug del sidecar che crashava su Talos, fixato il DNS di Podman, workaroundato un bug di vault-k8s. Il tutto funzionava.

Poi, durante una ricerca di approfondimento su un dettaglio tecnico, mi sono imbattuto in Vault Secrets Operator (VSO). Più lo studiavo, più capivo che era esattamente quello che avrei dovuto usare al posto dell'injector. Centralizzato, senza sidecar, senza overhead sul worker singolo, con rollout restart nativo.

Non ho sbagliato. Ho seguito un processo che mi ha portato a scoprire una soluzione migliore. E questa è la differenza tra un prodotto professionale e uno costruito a caso.

## Il Processo: Non È Magia, È Metodologia

Il modo in cui lavoro oggi segue un ciclo preciso che ho affinato progetto dopo progetto. Lo chiamo il ciclo CRISP, anche se il nome è quello che conta meno:

1. **Butto giù le idee** — senza ordine, senza struttura. Una mappa mentale grezza.
2. **Deep research** — su ogni punto che non conosco a fondo, faccio una ricerca mirata. Google, Perplexity, Context7, documentazione ufficiale. Ogni ricerca è un prompt studiato, non "cerca questo".
3. **Progetto** — struttura le idee in un DESIGN.md e un PLAN.md. Ogni fase ha un test di uscita.
4. **Split** — se il progetto cresce troppo, lo divido in figli o fratelli. L'albero progettuale cresce con la comprensione.
5. **Build** — implementazione con l'LLM.
6. **Review** — alla fine, analizzo le deviazioni dal piano. Ogni volta scopro qualcosa. Ogni volta affino il processo.

Questo ciclo non è diverso da quello che facevo prima. La differenza è che la **deep research** — la parte che prima richiedeva giorni di lettura, forum, blog, trial and error — oggi richiede minuti. Ma la qualità della ricerca dipende dalla qualità della domanda. Se non sai inquadrare il problema, l'AI non lo farà per te.

## L'Albero Che Cresce: La Vera Mappa del Progetto

Uno dei risultati più visibili di questo processo è la struttura ad albero dei progetti. Aprire la directory dei progetti CRISP del vault è istruttivo. Quello che era iniziato come "metti Vault su una VM Hetzner" oggi assomiglia a questo:

```
hetzner-vault-platform/
│
├── 10-hetzner-vault-foundation/                       ✅ Foundation
│   ├── 10-hetzner-runtime-golden-image/               ✅ Golden Image
│   └── 20-hetzner-tailscale-foundation/               ✅ Tailscale
│
├── 20-hetzner-vault-runtime/                          ✅ Runtime
│   ├── 10-hetzner-vault-local-lifecycle/              ✅ Vault server
│   ├── 20-hetzner-vault-s3-backup-recovery/           ✅ S3 backup
│   └── 30-hetzner-vault-runtime-orchestration/        📝 Orchestration
│
├── 30-hetzner-vault-consumers/
│   │
│   ├── 04-hetzner-tailscale-talos-bridge/             ✅ Talos bridge
│   ├── 07-tailscale-operator-deployment/              ✅ Tailscale K8s
│   │   ├── 10-operator-dns-resolution/                ✅ DNS resolution
│   │   ├── 15-tailscale-operator-hardening/           ✅ Hardening
│   │   └── 20-tailscale-service-exposure/             ✅ Service exposure
│   │
│   ├── 09-vault-k8s-integration-prep/                 ✅ Integration prep
│   ├── 10-tazlab-k8s-vault-migration/                 ✅ Secret migration
│   ├── 12-tazlab-k8s-vault-migration-followup/        ✅ Followup
│   │
│   ├── 15-tazlab-k8s-vault-dynamic-secrets-operator/  🟢 Active
│   │   ├── 10-vault-agent-injector-phase1/            ✅ Completed
│   │   ├── 11-vault-agent-injector-phase1-followup/   ✅ Completed
│   │   ├── 12-vso-foundation/                         📝 VSO foundation
│   │   ├── 13-vso-static-migration/                   📝 Static migration
│   │   ├── 14-vso-dynamic-migration/                  📝 Dynamic migration
│   │   ├── 20-vault-secrets-universal-adoption/       📜 Historical
│   │   ├── 30-vault-pki-certificate-authority/        📜 Historical
│   │   └── 40-vault-transit-engine/                   📜 Historical
│   │
│   └── 20-infisical-decommission/                     📝 Infisical cleanup
│
├── 40-system-rebirth-orchestration/                   📝 Rebirth
│
└── 90-historical/
    └── 10-hetzner-vault-convergence/                  📜 Historical
```

Solo la parte dei consumer del vault — quella che gestisce l'integrazione tra cluster e Vault — oggi conta 8 progetti, di cui 3 attivi e 3 storici. E non è finita: sospetto che crescerà ancora quando esploreremo PKI e Transit.

Ogni ramo dell'albero rappresenta un momento in cui ho capito che la soluzione era più complessa del previsto. Invece di forzare tutto in un progetto unico — ottenendo un piano confuso e difficile da validare — ho diviso. Ogni progetto ha un suo DESIGN.md, un suo PLAN.md, un suo RESEARCH.md, e quando arriva alla build, una sua tasks.md.

I tre progetti marcati "Historical" non sono fallimenti. Sono direzioni che ho esplorato, documentato, e poi superato con una scelta migliore — come VSO che ha reso obsoleto l'approccio con l'injector. Se non li avessi esplorati, non avrei mai capito perché VSO è migliore. L'albero è la mappa della mia comprensione: ogni biforcazione è un apprendimento.

## Il Vibe Coding e Perché Non Funziona per l'Infrastruttura

Vedo sempre più persone che descrivono il loro workflow come: "ho chiesto all'AI di costruirmi questo, ha funzionato, ho fatto deploy". E funziona, per un certo valore di "funziona". La domanda è: cosa c'è dietro le quinte? Quante decisioni sono state prese senza che tu lo sapessi? Quante sono giuste? Quante sono ottimali?

Prendiamo il mio progetto Vault. Se avessi detto a un LLM "migra tutti i segreti a Vault, implementa dynamic secrets per Grafana", in qualche modo ci sarebbe arrivato. Avrebbe scelto ESO, injector, o forse un approccio completamente diverso. Ma ogni scelta porta con sé un albero di decisioni — compatibilità, overhead, manutenibilità, sicurezza — che un LLM non può valutare perché non conosce il contesto: il cluster a un nodo worker, la VM Hetzner con Podman, le limitazioni di Talos, il budget.

Questo non vuol dire che gli LLM non servano. Vuol dire che vanno **guidati**. La metafora giusta non è l'autista che si addormenta, ma il pilota che programma il volo e poi monitora ogni parametro. Se il pilota si addormenta — se accetta la prima soluzione che funziona — il volo arriva a destinazione, ma chissà quanto carburante ha bruciato in più, quante deviazioni ha preso, quanto stress ha messo sulla macchina.

## L'Esempio di Salvatore Sanfilippo

Salvatore Sanfilippo, l'autore di Redis, uno dei software più diffusi al mondo, usa gli LLM in modo simile. Nei suoi video racconta che passa mesi a scrivere specifiche dettagliatissime prima di far generare codice a un LLM. Il suo progetto Dwarf Star 4 — un'implementazione quantizzata di DeepSeek che gira su un MacBook — è stato scritto quasi interamente da agenti AI. Ma ogni singola riga di specifica è stata pensata da lui. Ogni decisione architetturale è sua. L'AI ha scritto il codice, ma l'architettura, il design, i tradeoff — quelli sono umani.

Questo è il pattern che vedo funzionare: l'ingegnere progetta, l'AI esegue. L'ingegnere verifica, l'AI corregge. L'ingegnere impara, l'AI documenta.

## Deep Research Come Moltiplicatore

La vera svolta per me è stata la deep research. Prima, per affrontare un argomento nuovo — diciamo, i dynamic secrets di Vault o il PKI engine — dovevo:
1. Leggere la documentazione ufficiale (ore)
2. Cercare blog post, tutorial, esempi (ore)
3. Fare tentativi, sbagliare, ripetere (ore o giorni)

Oggi faccio così:
1. Studio abbastanza da inquadrare il problema (minuti)
2. Preparo un prompt di ricerca preciso — contesto, domande, scenario (minuti)
3. Lancio la ricerca su Google Deep Research o Context7 (minuti)
4. Leggo i risultati, decido, progetto (ore)

Il risultato è lo stesso livello di comprensione, ma in una frazione del tempo. E la qualità è migliore, perché la ricerca è mirata, non esplorativa. Non trovo informazioni casuali — trovo risposte a domande precise.

Questo mi ha permesso di fare cose che prima erano impossibili per mancanza di tempo. Un cluster Kubernetes enterprise con 80 pod, Vault, Tailscale, Monitoring, GitOps — in cinque mesi, la sera dopo lavoro. Non è una questione di velocità: è una questione di processo. La parte che richiede tempo — progettare, decidere — la faccio io. La parte che richiede esecuzione — scrivere codice, testare, configurare — la fa l'AI.

Ma la deep research non la uso solo in fase di progettazione. Ormai ho impostato il processo in modo che l'LLM si fermi da solo quando i tentativi di risolvere un problema si moltiplicano senza progresso. Lui si ferma, mi spiega qual è il punto di attrito, e io vado a fare una ricerca su quello specifico problema. A volte scopro che semplicemente non avevamo fatto ricerche abbastanza approfondite prima di iniziare. Altre volte — un paio di volte in questo progetto — ci siamo imbattuti in un bug documentato. Un esempio concreto: durante l'implementazione dell'injector, l'agente vault-agent crashava in loop. L'LLM ha provato alcune varianti, poi si è fermato da solo e mi ha spiegato l'errore. Ho fatto una ricerca, ho scoperto che era il bug #660 di vault-k8s: l'injector genera il parametro sbagliato per il metodo JWT. Bug documentato, con workaround noto. Risolto in pochi minuti. Senza quel meccanismo — fermati se non progredisci — l'LLM avrebbe continuato a girare in tondo per ore.

## I Test Come Recinto di Contenimento

Una delle cose più importanti che ho imparato è usare i test come guardrail per l'AI. Quando progetto una fase, cerco sempre di definire un test funzionale che deve passare per considerare la fase completata. Se il test è ben progettato, l'AI non può barare: deve implementare esattamente quello che voglio io, perché altrimenti il test fallisce.

Per esempio, nel progetto Vault, uno dei test era: "il container Vault deve poter risolvere MagicDNS names". Se l'AI avesse preso una scorciatoia (usare IP statici, configurare DNS diversamente), il test sarebbe fallito. Il test ha costretto l'LLM a implementare la soluzione giusta, non quella veloce.

I test sono il mio strumento per mantenere il controllo su un processo che altrimenti tenderebbe a scegliere la strada più breve.

## Il Lato Economico: Usare il Modello Giusto

In un periodo in cui i prezzi degli LLM stanno esplodendo, la maggior parte del mio lavoro — implementazione e buona parte della ricerca — è fatta con DeepSeek V4 Flash. Un modello che costa pochissimo, ma che funziona sorprendentemente bene quando il progetto è solido. Ne ho provati molti, e questo è quello che in questo periodo mi sta dando più soddisfazioni con un costo veramente contenuto.

In fase di progettazione, invece, quando i problemi si fanno più complessi o serve uscire da un vicolo cieco, passo a DeepSeek Pro o Gemini. Modelli più costosi, ma con la capacità di affrontare ragionamenti articolati che Flash non sempre gestisce bene.

La lezione è: usare il modello giusto per il compito giusto. Un buon progetto rende i modelli più accessibili efficaci quanto quelli costosi — ma per progettare bene, a volte serve un'intelligenza superiore.

## Cosa Ho Imparato

1. **La ricerca non è opzionale** — ogni progetto dovrebbe iniziare con una deep research sulle parti che non conosci. Non è perdita di tempo, è investimento.

2. **L'albero è la mappa** — se il progetto cresce, dividilo. La struttura ad albero riflette la tua comprensione. Se è piatta, probabilmente stai forzando.

3. **I test sono verità** — un test funzionale ben scritto vale più di mille righe di specifica. Costringe l'AI a implementare ciò che vuoi, non ciò che è più facile.

4. **La review è sacra** — dopo ogni build, analizza le deviazioni. Sempre. Ogni volta scoprirai qualcosa che non sapevi.

5. **Il modello giusto al prezzo giusto** — non serve il modello più costoso per tutto. DeepSeek V4 Flash con specifiche chiare fa il 90% del lavoro. Per il 10% difficile — progettazione complessa, vicoli ciechi — passo a DeepSeek Pro o Gemini.

6. **L'ingegnere resta** — l'AI non sostituisce il giudizio. Sostituisce l'esecuzione. E questo è un patto che funziona, se lo rispetti.

## Una Nota Finale

Tutto quello che ho costruito in questi mesi — il cluster, Vault, i dynamic secrets, la migrazione — non mi serviva veramente. Il mio blog e il mio wiki avrebbero funzionato benissimo su due container Docker. Ma l'ho fatto perché ora è possibile imparare facendo, a un livello che prima richiedeva anni di esperienza in azienda.

Uno dei miei progetti più recenti si chiama Vault Secrets Operator. Ha reso obsoleto un mese di lavoro sull'injector. E va bene così. Perché quel mese non è stato sprecato: molte cose le sapevo già — Vault, KV, autenticazione — ma alcuni aspetti li ho scoperti lungo il percorso. PKI per esempio: so cos'è, come si usa, ho un'idea chiara del meccanismo. Ma so già che quando arriveremo all'implementazione — scambio di chiavi, certificati, handshake — emergeranno dettagli che oggi non vedo. È successo con JWT, succederà con PKI. Questo modo di lavorare mi permette di studiare e imparare in modo molto più mirato. Prima dovevo leggere libri interi o documentazione enorme, gran parte della quale non era focalizzata sul problema che avevo di fronte. Leggevo cose che non mi servivano, sperando di trovare quelle poche che mi servivano. Adesso invece vado dritto al punto: approfondisco solo gli aspetti che mi servono per l'obiettivo che ho in quel momento, un pezzo alla volta. Non devo sapere tutto di tutto. E quando arriverà il momento di implementare PKI più a fondo, lo farò con lo stesso approccio — mirato, concreto, senza dispersione.

Questo, per me, è il vero valore dell'AI: non la risposta veloce, ma la possibilità di esplorare, sbagliare, correggere e imparare — a una velocità che prima era semplicemente impossibile.
