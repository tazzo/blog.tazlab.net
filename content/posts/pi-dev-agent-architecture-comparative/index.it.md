+++
title = "Pi.Dev: Architettura di Agenti Minimali per l'Ecosistema Cloud-Native"
date = 2026-03-09T13:16:51+01:00
draft = false
description = "Analisi comparativa delle architetture di coding agent: dal fallimento dei tool 'convenience-first' (Gemini CLI, Cloud Code) alla scoperta di Pi.Dev come fondamento per sistemi agentici configurabili e specializzati."
tags = ["AI", "DevOps", "Kubernetes", "Cloud Native", "Agents", "Architecture", "Developer Tools"]
author = "Tazzo"
+++

## Introduzione: La Frustrazione dei Walled Garden

Quando si lavora su un'infrastruttura complessa come **TazLab** — un ecosistema nomadico basato su Talos Kubernetes, GitOps con Flux CD, e una superficie di attacco ridotta tramite Zero Trust — la necessità di automazione intelligente diventa rapidamente critica. Non parlo di automazione procedurale (quella è risolta con Terragrunt e Ansible), ma di **assistenza cognitiva**: un agente AI capace di leggere il contesto del progetto, ragionare sulle dipendenze, suggerire refactoring e debuggare problemi complessi di orchestrazione.

Inizialmente, ho cercato di risolvere questo problema affidandomi agli strumenti mainstream: **Gemini CLI** di Google e **Cloud Code**. Entrambi promettevano integrazione nativa con le API di Gemini e un workflow fluido. Tuttavia, dopo settimane di utilizzo intensivo, mi sono scontrato con limiti strutturali che rendevano impossibile adattarli ai requisiti di TazLab.

Questa analisi documenta il mio percorso verso **Pi.Dev** (pi-coding-agent), uno strumento minimale ma radicalmente configurabile che ho adottato come base per costruire agenti specializzati. Il confronto non è accademico: riflette esigenze concrete emerse dalla gestione di un laboratorio home lab in produzione.

---

## Fase 1: I Limiti delle Soluzioni "Convenience-First"

### Gemini CLI: Potenza Limitata da Scelte Architetturali

**Gemini CLI** è lo strumento ufficiale di Google per interagire con i modelli Gemini via linea di comando. La mia prima impressione era positiva: supporta multi-modalità (testo, immagini, video), gestisce sessioni persistenti e integra il protocollo **Model Context Protocol (MCP)** per estendere le capacità tramite server esterni.

**Deep-Dive Concettuale: Model Context Protocol (MCP)**
Il *Model Context Protocol* è un protocollo JSON-RPC che permette agli agenti AI di invocare "tool" esterni (funzioni esposte da server remoti o locali). Ad esempio, un server MCP può fornire strumenti per interrogare un database Postgres, cercare in una knowledge base vettoriale o leggere metriche da Prometheus. Il protocollo supporta due modalità di trasporto: *Stdio* (comunicazione tra processi sulla stessa macchina tramite stdin/stdout) e *SSE* (Server-Sent Events su HTTP, per integrazioni distribuite).

Il problema con Gemini CLI emerge quando si vuole fare più di quanto Google abbia previsto. Ecco i limiti che ho incontrato:

1. **Lentezza cronica**: Anche con il piano Pro, Gemini CLI è notevolmente lento. Le risposte arrivano con latenze significative — a volte decine di secondi per query che richiedono context reading del cluster. In un workflow di debugging iterativo, dove interroghi l'agente più volte per affinare la diagnosi, questa lentezza diventa un freno tangibile alla produttività.

2. **Estensibilità rigida via MCP**: Sebbene Gemini CLI supporti MCP, la configurazione è limitata a un file JSON (`settings.json`) che specifica quali server esterni invocare. Non è possibile iniettare logica custom direttamente nel loop dell'agente senza passare per un server MCP separato. Questo significa che se volevo un agente che, ad esempio, leggesse automaticamente i log di Flux CD dal cluster Kubernetes prima di rispondere a una domanda, dovevo costruire un server MCP dedicato per esporre quel tool — per ogni singola funzionalità.

3. **Nessun controllo sul prompt di sistema**: Gemini CLI usa un prompt di sistema hard-coded. Non è possibile modificarlo per istruire l'agente su convenzioni specifiche del progetto (ad esempio, "Quando scrivi manifesti Kubernetes, usa sempre Kustomize invece di Helm" o "Per ogni commit, aggiungi una git note con il timestamp"). Questo limita drasticamente la specializzazione.

### Cloud Code: Velocità al Costo del Quota

**Cloud Code** è lo strumento successivo che ho provato — da terminale, non come estensione VS Code che non rientra nel mio workflow. La differenza rispetto a Gemini CLI è immediata: le risposte sono notevolmente più veloci. Per chi lavora su infrastrutture come TazLab, dove ogni query implica leggere log di controller, stato di Flux e output di `kubectl`, la velocità di risposta non è un dettaglio cosmetic.

Il problema è la sostenibilità del piano. Con il piano Pro, una sessione di debugging Kubernetes — leggere log di `kustomize-controller`, validare manifest, iterare su un problema di Flux — è sufficiente per esaurire il quota. Fatico a superare le due ore di lavoro intensivo prima di ritrovarmi bloccato.

**Perché Cloud Code non era sostenibile per TazLab:**

1. **Quota insostenibile per workload Kubernetes**: Il piano Pro si esaurisce rapidamente su task che richiedono context intensivo. Una singola sessione di Flux debugging consuma abbastanza da bloccarti il resto della giornata. Non è un caso limite: è la norma per chi lavora su infrastrutture complesse.

2. **Nessuna possibilità di scripting**: Non posso invocare Cloud Code da uno script Bash per automatizzare task ripetitivi. È un'interfaccia conversazionale chiusa, non componibile in pipeline.

3. **Vendor Lock-In**: L'intero ecosistema spinge verso i servizi Google Cloud. Questa filosofia è opposta a quella di TazLab, dove la **sovranità digitale** è un principio fondamentale. Non voglio che la mia capacità di lavorare dipenda dalla disponibilità — o dalla generosità del piano — di un servizio cloud esterno.

---

## Fase 2: La Scoperta di Pi.Dev — Filosofia Unix per gli Agenti AI

Dopo settimane di frustrazione, ho iniziato a cercare alternative che soddisfacessero questi requisiti:

- **Estensibilità radicale**: Capacità di modificare ogni aspetto del comportamento dell'agente.
- **Modularità**: Supporto per più agenti specializzati, ciascuno con il proprio prompt di sistema e set di tool.
- **Multi-modello**: Possibilità di usare modelli diversi (Anthropic Claude, Google Gemini, OpenAI, Ollama) a seconda del task. Determinante è il supporto nativo a **OpenRouter**, che permette di accedere a praticamente qualsiasi modello disponibile sul mercato con un'unica API key. Uno degli esperimenti in programma è un benchmark sistematico dei modelli di punta su contesti Kubernetes — per capire quali offrono il miglior rapporto qualità/costo per task come debugging di Flux, analisi di manifest e generazione di configurazioni.
- **Scripting-friendly**: Utilizzabile sia interattivamente che in pipeline automatiche.
- **Minimale**: Nessuna dipendenza da IDE o framework pesanti.

Scavando tra progetti open source e sperimentazioni della community, sono arrivato a **Pi.Dev** (pi-coding-agent). Il confronto che faccio spesso per descriverlo è: **Pi.Dev sta a Gemini CLI/Cloud Code come Neovim sta a Visual Studio Code**. È minimale, configurabile fino ai minimi dettagli, e richiede investimento iniziale per padroneggiarlo, ma ripaga con flessibilità totale.

Vale la pena aggiungere un dato di contesto: **OpenClaw**, il coding agent che negli ultimi mesi ha raccolto notevole attenzione nella comunità degli sviluppatori, è costruito proprio su Pi.Dev. Non è un dettaglio marginale — significa che il framework che uso come base ha già dimostrato di reggere sotto carichi e ambizioni di produzione reali.

### Anatomia di Pi.Dev: Architettura Component-Based

Pi.Dev è scritto in TypeScript e distribuito come pacchetto npm. L'architettura è basata su tre concetti fondamentali:

1. **Agent**: Un'istanza AI con un prompt di sistema specifico, un modello associato, e un set di tool disponibili.
2. **Skill**: Moduli riutilizzabili che aggiungono capacità contestuali (es. "quando l'utente chiede di lavorare su Kubernetes, carica le istruzioni dal file `KUBERNETES.md`").
3. **Extension**: Funzioni custom (tool) che l'agente può invocare, scritte in TypeScript e integrate tramite un'interfaccia semplice.

**Deep-Dive Concettuale: Agent vs Assistant vs Tool**
È importante distinguere i livelli di astrazione. Un *Assistant* (come Gemini o Claude) è il modello sottostante, fornito da un provider (Google, Anthropic). Un *Agent* è una configurazione specifica di quell'assistant, con un prompt di sistema e un set di tool. Ad esempio, posso avere un agent chiamato "k8s-debugger" che usa il modello `claude-sonnet-4`, con prompt di sistema che lo istruisce a leggere sempre i log di Flux prima di rispondere, e con accesso a tool custom per interrogare Prometheus. Un *Tool* è una funzione che l'agent può invocare. Pi.Dev permette di definire tool sia come estensioni (codice locale) che come skill (bundle predefiniti di prompt + tool).

La differenza chiave è **l'approccio filosofico**. Gemini CLI e Cloud Code sono *prodotti finiti* — strumenti progettati per un caso d'uso mainstream e poi sigillati. Pi.Dev è un *toolkit* — fornisce i mattoni (gestione conversazioni, invocazione modelli, protocollo MCP) e lascia che l'utente costruisca la propria architettura di agenti.

---

## Fase 3: Casi d'Uso — Agenti Specializzati per l'Ecosistema Kubernetes

Una volta compreso il potenziale di Pi.Dev, ho iniziato a mappare i casi d'uso concreti per TazLab. Eccone due che sto esplorando:

### Caso 1: L'Agente "Blog Writer" (Questo Articolo)

Il primo agente che ho configurato è quello che sta scrivendo questo articolo. Il suo prompt di sistema (`CLAUDE.md` nel repository) gli istruisce a:
- Leggere la documentazione esistente nel blog (`~/kubernetes/blog-src/content/posts/`) per capire lo stile.
- Seguire un template strutturato (Introduzione → Fasi → Riflessioni).
- Espandere ogni concetto tecnico con paragrafi "Deep-Dive".
- Usare un tono professionale in prima persona singolare.

Questo agente usa il modello `claude-sonnet-4` di Anthropic perché eccelle nella scrittura tecnica lunga e strutturata. Quando gli chiedo di scrivere un articolo, legge autonomamente esempi esistenti, identifica i tag appropriati, e genera un file Markdown completo con frontmatter TOML.

**Perché questo non sarebbe possibile con Gemini CLI:**
Con Gemini CLI, avrei dovuto:
1. Creare un server MCP che espone un tool "read_blog_posts".
2. Lanciare il server in background.
3. Configurare Gemini CLI per connettersi al server.
4. Scrivere manualmente il prompt di sistema ogni volta, perché non posso salvarlo nella configurazione.
5. Parsare l'output testuale e salvarlo manualmente.

Con Pi.Dev, tutto questo è configurato una volta nel file dell'agente, e ogni invocazione è automatica.

### Caso 2: L'Agente "K8s Watchdog" — Sorveglianza Proattiva del Cluster

Il secondo caso d'uso è il più ambizioso: un pod con una versione minimale di Pi.Dev deployato **dentro il cluster Kubernetes**, che agisce da watchdog generale su tutti i componenti critici dell'infrastruttura.

L'architettura è un CronJob Kubernetes con intervallo configurabile — probabilmente tra i dieci e i trenta minuti. Ad ogni esecuzione, l'agente interroga il cluster su più fronti usando il client in-cluster con un ServiceAccount dal RBAC stretto: sola lettura su risorse, log ed eventi.

**Perimetro di monitoraggio:**
- **GitOps (Flux)**: stato di HelmRelease, Kustomization, GitRepository. Rileva riconciliazioni fallite, stalled o in ritardo rispetto alla revisione più recente.
- **Storage (Longhorn)**: salute dei volumi, stato delle repliche, backup recenti. Identifica volumi in stato degraded o senza snapshot nell'intervallo atteso.
- **Database**: pod dei database critici (Postgres/CrunchyPostgres e altri stateful set). Verifica che siano Running, senza restart anomali, con liveness probe che risponde.
- **Pod generale**: qualsiasi pod in CrashLoopBackOff, OOMKilled, ImagePullBackOff, o con restart count sopra una soglia configurabile.

**Flusso operativo:**
- **Nominal**: Se tutto è sano, produce un report sintetico e termina.
- **Anomalia rilevata**: Passa in modalità investigativa — legge gli eventi Kubernetes correlati, i log del componente in errore, lo stato delle risorse dipendenti.
- **Causa elevata**: Se un pod si riavvia troppo spesso, correla con OOMKilled events, memory limit, log dell'applicazione. Se un volume Longhorn è degraded, verifica lo stato dei nodi e delle repliche.
- **Report strutturato**: Diagnosi probabile, lista ordinata di opzioni da verificare manualmente, soluzioni concrete da valutare — **senza applicare nulla autonomamente**.

La distinzione è deliberata: l'agente ha visibilità completa ma **zero potere esecutivo**. L'obiettivo non è creare un sistema autonomo che possa peggiorare una situazione già critica, ma ridurre il triaging da "leggo tutto io" a "leggo il report e decido".

**Modello previsto:** un modello economico via OpenRouter — il perimetro di analisi è ampio ma strutturato, e la frequenza di esecuzione rende il costo per token un vincolo non negoziabile.

---

## Riflessioni Architetturali: Verso un'Infrastruttura "Agent-Aware"

L'adozione di Pi.Dev sta cambiando il modo in cui penso all'architettura di TazLab. Tradizionalmente, l'automazione era separata in due categorie:
1. **Automazione procedurale** (script Bash, Terragrunt, Ansible) — task ripetibili, deterministici.
2. **Intervento umano** (debugging, decisioni architetturali, refactoring) — task che richiedono ragionamento.

Con agenti AI configurabili, emerge una terza categoria: **automazione cognitiva**. Task che richiedono ragionamento ma che possono essere delegati a un agente con il giusto contesto.

### Il Problema della Trust Boundary

Tuttavia, questo introduce una sfida di sicurezza critica. Un agente AI in-cluster con accesso a `kubectl` e alle API del cluster ha potenzialmente il potere di distruggere l'intera infrastruttura. Come gestisco questa trust boundary?

**Approcci che sto esplorando:**

1. **RBAC Stretto**: L'agente in-cluster gira con un ServiceAccount Kubernetes con permessi limitati. Ad esempio, può leggere metriche e log, ma non può cancellare risorse o modificare ConfigMap critiche.

2. **Audit Trail Completo**: Ogni azione dell'agente viene loggata in modo immutabile (Loki + S3 backup). Se l'agente compie un'azione distruttiva, posso ricostruire la catena di eventi.

3. **Human-in-the-Loop per Azioni Critiche**: L'agente può proporre modifiche (es. "Ecco una PR per scalare lo storage Longhorn"), ma l'applicazione richiede approvazione umana via GitOps.

4. **Sandbox Environments**: Prima di deployare un agente in produzione, lo testo in un cluster di staging (cluster "Green" di TazLab, non ancora documentato).

### Il Pattern "Agent-as-Operator"

Un Operator Kubernetes tradizionale (scritto in Go con controller-runtime) riconcilia uno stato desiderato dichiarato in CRD. L'idea di un "Agent-as-Operator" è diversa: l'agente non riconcilia uno stato dichiarato, ma **risponde a eventi e prende decisioni contestuali**.

**Esempio concreto:**
- **Operator tradizionale**: "Se il PVC supera l'80% di utilizzo, aumenta la dimensione a X GB (valore hard-coded)."
- **Agent-as-Operator**: "Se il PVC supera l'80%, analizza i pattern di crescita degli ultimi 7 giorni, verifica il budget di storage disponibile, consulta i log di backup per garantire recovery, e proponi un piano di scaling ottimale."

Questo pattern non sostituisce gli Operator tradizionali (che sono più efficienti per task deterministici), ma li complementa per scenari che richiedono flessibilità.

---

## Fase 4: Cosa Manca — Gap e Direzioni Future

Nonostante l'entusiasmo (controllato) per Pi.Dev, ci sono gap evidenti che sto affrontando:

### Gap 1: Costo per Token e Multi-Model Orchestration

Usare modelli diversi per task diversi è potente, ma introduce complessità di budgeting. Claude Sonnet è costoso (circa $3 per milione di token di input), mentre Gemini Flash è quasi gratuito. Devo costruire logica per:
- Routing intelligente: task semplici → modello economico, task complessi → modello capace.
- Monitoring dei costi: dashboard che traccia quanti token consumo per agente/task.

Pi.Dev non fornisce questo out-of-the-box. Sto esplorando l'integrazione con tool come LangSmith o costruzione di una dashboard custom con Prometheus + Grafana.

### Gap 2: Testing e Validazione degli Agenti

Come testo che un agente funzioni correttamente? Con codice tradizionale, scrivo unit test. Con un agente AI, il comportamento è probabilistico. Sto sperimentando con:
- **Golden Test**: Eseguo l'agente su problemi noti (es. "Debugga questo errore di Flux che so essere causato da un YAML malformato") e verifico che l'output contenga le keyword giuste.
- **Regression Test**: Ogni volta che l'agente risolve un problema, salvo input/output come test case. Se cambio il prompt di sistema, ri-eseguo i test per verificare che i comportamenti desiderati non siano regressi.

### Gap 3: Persistent State per Agenti In-Cluster

Un agente in un pod Kubernetes è per definizione effimero. Se il pod crasha, perde la memoria della conversazione. Per agenti long-running, devo implementare persistent state. Opzioni:
- **Database esterno** (Postgres): Salvo la cronologia delle conversazioni e il contesto.
- **Kubernetes ConfigMap**: Per stato leggero (configurazioni, task queue).

---

## Conclusione: Una Scelta di Sovranità Tecnica

L'adozione di Pi.Dev rispetto a Gemini CLI o Cloud Code non è stata guidata da fanatismo per l'open source o da avversione a Google. È stata una scelta pragmatica basata sui requisiti architetturali di TazLab:

1. **Estensibilità**: Ho bisogno di agenti che si comportino esattamente come voglio, non come un product manager di BigTech ha deciso.
2. **Multi-Modello**: Voglio scegliere il modello ottimale per ogni task, non essere vincolato a un ecosistema.
3. **Integrazione Deep**: Gli agenti devono vivere dentro il mio ecosistema (TazPod, Kubernetes, Mnemosyne), non in un walled garden cloud.
4. **Sovranità**: Voglio capire e controllare ogni aspetto del sistema, dal prompt di sistema al protocollo di comunicazione.

Pi.Dev, con la sua filosofia minimale e configurabile, soddisfa questi requisiti. È il Neovim degli AI coding agent: ha una curva di apprendimento ripida, richiede investimento iniziale, ma ripaga con controllo totale.

Mentre scrivo questo articolo (tramite l'agente "blog-writer" basato su Pi.Dev), sto ancora imparando. La documentazione è frammentata, alcune feature sono sperimentali, e ci sono edge case da risolvere. Ma è proprio questo il punto: **ho la possibilità di risolverli**. Con Gemini CLI, se una feature non esiste, posso solo aprire una issue su GitHub e sperare. Con Pi.Dev, posso aprire il codice, capire come funziona, e contribuire la patch.

Questo è il tipo di empowerment tecnico che cercavo quando ho iniziato il progetto TazLab. L'aggiunta di Pi.Dev all'arsenale rappresenta un ulteriore passo verso un ecosistema veramente sovrano, dove ogni componente — dall'OS (Talos) al vault (TazPod) alla memoria (Mnemosyne) agli agenti (Pi.Dev) — è controllabile, ispezionabile e modificabile.

Nei prossimi articoli, documenterò l'implementazione concreta del "K8s Watchdog" e i primi risultati del benchmark comparativo tra modelli su task Kubernetes. Se questa analisi comparativa ti ha incuriosito, ti invito a esplorare Pi.Dev e a considerare se la filosofia "tool minimale ma radicalmente configurabile" si adatta al tuo workflow.

---

**Nota per i lettori:** Questo articolo è stato scritto da un agente Pi.Dev configurato come "Home Lab Blogger". L'ironia non è casuale — è una dimostrazione pratica della tesi dell'articolo. L'agente ha letto autonomamente articoli precedenti del blog, identificato il formato corretto, generato il frontmatter TOML, e prodotto questo testo seguendo le regole di stile definite nel suo prompt di sistema. Il processo è stato: `pi --agent blog-writer --task "Scrivi analisi comparativa su Pi.Dev vs Gemini CLI/Cloud Code"`. Tempo di generazione: ~3 minuti. Costo: ~$0.15 (Claude Sonnet 4, ~50k token output).
+++