+++
title = "Mnemosyne Rebirth: Cronaca di una Memoria Sovrana (e di come mi sono scontrato con il protocollo MCP)"
date = 2026-02-22T18:05:00+01:00
draft = false
description = "Cronaca tecnica del refactoring del server Mnemosyne MCP: dalla gestione custom all'SDK ufficiale, risolvendo deadlock GitOps e problemi di buffering di rete."
tags = ["mcp", "go", "kubernetes", "gitops", "flux", "ai"]
author = "Tazzo"
+++

## Introduzione: Il Paradosso dell'Effimero
In un ecosistema nomadico e "Zero Trust" come quello di **TazLab**, l'ambiente di sviluppo (**TazPod**) è per sua natura effimero. Alla chiusura del container, ogni traccia dell'attività svanisce, eccezion fatta per i dati salvati nel vault cifrato. Questa volatilità, sebbene eccellente per la sicurezza e la pulizia del sistema, introduce un problema fondamentale: l'amnesia dell'agente AI. Ogni nuova sessione è un foglio bianco, una tabula rasa in cui l'intelligenza artificiale non ha memoria delle decisioni architettoniche prese ieri, dei bug risolti con fatica o delle direzioni strategiche del progetto.

Ho deciso che TazLab doveva avere una memoria semantica a lungo termine, una "coscienza tecnica" residente nell'infrastruttura stessa. Questo progetto ha preso il nome di **Mnemosyne**. L'obiettivo della giornata era ambizioso: abbandonare i bridge Python instabili e implementare un server nativo basato sul **Model Context Protocol (MCP)**, integrato direttamente nel **Gemini CLI**, per permettere all'AI di consultare il proprio passato tecnico in modo fluido e sovrano.

---

## Fase 1: Il Miraggio del Cloud e il Ritorno alla Sovranità

Inizialmente, la mia strategia per Mnemosyne si basava su **Google Cloud AlloyDB**. L'idea di delegare la persistenza vettoriale a un servizio gestito "Enterprise" sembrava la mossa più sicura e performante. AlloyDB, con la sua estensione `pgvector`, offriva una potenza di calcolo enorme per le ricerche semantiche.

**Deep-Dive Concettuale: AlloyDB e pgvector**
*AlloyDB* è un database PostgreSQL-compatibile di Google Cloud, ottimizzato per carichi di lavoro intensivi. È un servizio VPC-native, il che significa che per ragioni di sicurezza non espone normalmente un IP pubblico, ma richiede una connessione privata all'interno del cloud di Google. *pgvector* è l'estensione che permette di memorizzare gli "embeddings" (vettori numerici che rappresentano il significato del testo) e di eseguire ricerche di similitudine tramite l'operatore di distanza del coseno (`<=>`).

Tuttavia, mi sono scontrato rapidamente con la realtà operativa. Per accedere ad AlloyDB dal TazPod in mobilità, ho dovuto configurare l'**AlloyDB Auth Proxy**, un binario che crea un tunnel sicuro verso GCP. All'interno di un container Docker, questo proxy creava processi zombie e soffriva di latenze imprevedibili. Inoltre, il firewall di GCP richiedeva lo sblocco dinamico degli IP tramite script (`memory-gate`), creando un attrito costante che tradiva la natura agile del laboratorio. Ogni volta che cambiavo connessione (passando dal Wi-Fi di casa alla rete mobile), la mia memoria semantica diventava irraggiungibile finché non aggiornavo manualmente le regole di rete.

Ho deciso quindi di cambiare rotta: la vera sovranità digitale richiede che i dati risiedano sul mio hardware. Ho migrato Mnemosyne su un'istanza **PostgreSQL locale** ospitata nel mio cluster Kubernetes (Proxmox/Talos), utilizzando il Postgres Operator per la gestione del ciclo di vita. Questa scelta non ha solo azzerato i costi cloud, ma ha reso la memoria parte integrante del "ferro" di TazLab, rendendola accessibile in modo trasparente tramite la VPN Wireguard integrata nel TazPod.

---

## Fase 2: Genesi di un Server Nativo in Go

Per collegare il Gemini CLI al database Postgres, avevo bisogno di un ponte che parlasse il linguaggio MCP. Inizialmente usavo uno script Python che fungeva da bridge, ma la latenza di avvio dell'interprete e la fragilità delle dipendenze mi hanno spinto verso una soluzione più professionale: un server scritto in **Go**.

Ho scelto Go per la sua capacità di generare binari statici minuscoli, perfetti per le immagini **Distroless** di Google. Una immagine Distroless non contiene una shell o un package manager, riducendo drasticamente la superficie di attacco del pod in Kubernetes. Il server doveva essere ibrido per supportare due scenari d'uso:
1.  **Stdio Transport**: Per lo sviluppo locale rapido, dove il CLI lancia il binario e comunica tramite standard input/output.
2.  **SSE Transport (Server-Sent Events)**: Per la produzione, dove il server espone un endpoint HTTP nel cluster e il CLI si connette come client remoto tramite un LoadBalancer MetalLB.

**Deep-Dive Concettuale: Stdio vs SSE**
Il trasporto *Stdio* è il modo più semplice di far comunicare due processi sullo stesso host: i messaggi JSON-RPC passano per i file descriptor di sistema. È estremamente veloce ma limitato alla macchina locale. Il trasporto *SSE*, invece, è un protocollo unidirezionale su HTTP che permette al server di inviare "eventi" al client. Nel protocollo MCP, SSE viene usato per mantenere aperto un canale di risposta asincrono dal server verso l'AI, permettendo integrazioni multi-utente e distribuite.

---

## Fase 3: The Trail of Failures (La sezione dei fallimenti)

Il passaggio a un server nativo non è stato privo di ostacoli. Anzi, mi sono scontrato con una serie di bug che hanno richiesto un'indagine quasi forense.

### Il Bug dell'Apice Mortale (Errore 400)
Dopo il primo deploy, ogni ricerca semantica restituiva un laconico `embedding API returned status 400`. Ho controllato i log del server, ma il corpo dell'errore di Google non veniva visualizzato. Ho sospettato di tutto: dal modello di embedding (`gemini-embedding-001`) al formato del JSON.

Dopo aver implementato un logging più aggressivo che catturava il corpo della risposta HTTP, ho scoperto l'assurda verità: il file dei segreti nel TazPod (`/home/tazpod/secrets/gemini-api-key`) conteneva la chiave racchiusa tra **apici singoli** (`'AIzaSy...'`). Questi apici erano stati inclusi per errore durante una operazione di copia-incolla. Le API di Google ricevevano l'apice come parte della chiave, invalidandola. Ho risolto pulendo fisicamente il file con `sed` e aggiungendo una funzione di sanificazione nel codice Go per rendere il server resiliente a errori umani simili:

```go
// Pulizia aggressiva della chiave (rimuove apici e spazi)
apiKey = strings.Trim(strings.TrimSpace(apiKey), ""'")
```

### Il Silenzio è d'Oro (Stdio Discovery Failure)
Un altro comportamento inaspettato si è verificato all'avvio del Gemini CLI. Nonostante il server fosse configurato correttamente nel file `settings.json`, il CLI riportava `No tools found on the server`.

Indagando sui log di debug, ho capito che il protocollo Stdio è estremamente fragile: qualsiasi carattere stampato su `stdout` che non faccia parte del JSON-RPC rompe la comunicazione. Il mio server stampava dei log di benvenuto tramite `fmt.Printf`. Questi log sporcavano lo stream, facendo fallire il parser JSON del client Gemini CLI. Ho dovuto rendere il server **totalmente silenzioso** in modalità Stdio, reindirizzando ogni log diagnostico su `stderr`.

```go
// Prima (SBAGLIATO):
fmt.Printf("🚀 Server starting...")

// Dopo (CORRETTO):
fmt.Fprintf(os.Stderr, "🚀 Server starting...")
```

---

## Fase 4: Arrendersi agli Standard (Refactoring SDK)

Dopo ore passate a scrivere a mano la gestione dei messaggi JSON-RPC e dei canali SSE, ho dovuto ammettere un errore di orgoglio: reinventare il protocollo MCP da zero era complesso e incline ai bug di concorrenza. Ad esempio, il mio server perdeva messaggi se il client apriva più sessioni simultanee con lo stesso ID.

Ho deciso di rifattorizzare tutto usando l'SDK ufficiale della community: **`github.com/mark3labs/mcp-go`**. Questo ha significato riscrivere l'intero gestore dei tool, ma ha portato benefici immediati in termini di stabilità. L'SDK gestisce nativamente il "flushing" dei dati SSE, garantendo che i messaggi non rimangano bloccati nei buffer del server.

Tuttavia, anche qui la sfida non è mancata. Durante la build automatica su **GitHub Actions**, l'immagine prodotta continuava a mostrare i log del vecchio codice. Dopo aver controllato ogni riga, ho individuato un problema di **Module Naming**. Il modulo Go era denominato `tazlab/mnemosyne-mcp-server`, ma il repository reale su GitHub era `github.com/tazzo/...`. Go, durante la build in cloud, non riuscendo a risolvere i pacchetti interni come file locali, scaricava versioni vecchie del codice dai branch remoti invece di usare quelli appena committati. Ho corretto la struttura del modulo per allinearla al percorso GitHub reale, forzando una build pulita.

---

## Fase 5: Il Deadlock GitOps (Quando Flux mente)

L'ultimo scoglio è stato il deploy nel cluster. Nonostante i commit fossero corretti e la build GHA fosse passata, il pod continuava a girare con la vecchia immagine v14. Flux CD riportava `Applied revision`, ma lo stato live del cluster era congelato.

**Deep-Dive Concettuale: GitOps e Flux CD**
La filosofia *GitOps* prevede che il repository Git sia l'unica "fonte di verità". *Flux CD* monitora Git e applica i cambiamenti al cluster. Se però una risorsa fallisce la validazione di Kustomize, Flux si blocca per evitare di corrompere lo stato del cluster.

Ho indagato con `flux get kustomizations` e ho scoperto un **Deadlock di Dipendenze**. La kustomization `apps` (che gestisce Mnemosyne) era bloccata perché dipendeva da `infrastructure-configs`, che a sua volta era in errore a causa di uno YAML malformato. Involontariamente, avevo introdotto un errore di indentazione nel blocco `env` del manifesto di Mnemosyne durante un `rebase` Git concitato. Questo errore impediva al controller di Flux di generare i nuovi manifesti, lasciando in esecuzione la vecchia versione v14.

Ho risolto il deadlock riscrivendo il manifesto in modo pulito e forzando una riconciliazione a cascata di tutta la catena:

```bash
export KUBECONFIG="/path/to/kubeconfig"
# Sblocco della catena di dipendenze
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization apps --with-source
```

---

## Fase 6: Stato Finale: "1 MCP Caricato"

Dopo aver risolto l'errore di indentazione e aver forzato Kubernetes a scaricare l'immagine fresca con la policy `imagePullPolicy: Always`, il momento della verità è arrivato.

Lanciando il comando `gemini`, il CLI ha mostrato finalmente la scritta: **"1 MCP caricato"**.
Mnemosyne era vivo. Ho testato il tool `list_memories` e ho visto apparire i miei ricordi tecnici degli ultimi mesi, recuperati dal database Postgres locale tramite il protocollo SSE.

**Snippet finale del server MCP (Go SDK):**
```go
func (s *Server) registerTools() {
	// Tool per la ricerca semantica
	retrieve := mcp.NewTool("retrieve_memories", mcp.WithDescription("Search semantic memory"))
	retrieve.InputSchema = mcp.ToolInputSchema{
		Type: "object",
		Properties: map[string]any{"query": map[string]any{"type": "string"}},
		Required: []string{"query"},
	}
	s.mcp.AddTool(retrieve, s.handleRetrieve)
}
```

---

## Riflessioni post-lab: Verso una Conoscenza Resiliente

Questa sessione di lavoro è stata una vera e propria maratona tecnica di oltre 4 ore. Ho imparato che la semplicità dell'architettura (tornare a Postgres locale) vince quasi sempre sulla complessità dei servizi gestiti nel cloud, specialmente in un contesto di laboratorio. Il passaggio all'SDK standard ha trasformato Mnemosyne da un esperimento fragile a un componente infrastrutturale solido.

Cosa significa questo per TazLab? Ora il mio ambiente di sviluppo non è più amnesico. L'agente AI può finalmente dire: "Ricordo come abbiamo configurato Longhorn tre settimane fa" o "Ecco perché abbiamo scelto quella specifica policy di MetalLB". La memoria è sovrana, risiede sul mio hardware e parla un protocollo universale.

### Cosa ho imparato in questa tappa:
1.  **L'importanza degli standard**: Usare un SDK ufficiale (come quello di mark3labs) salva ore di debug sui dettagli dei protocolli come il flushing SSE e la gestione dei session ID.
2.  **GitOps Vigilance**: Non bisogna mai fidarsi di un "Reconciliation Succeeded" a livello globale se un componente a valle non risponde. Un errore di YAML silenzioso può congelare l'intero cluster.
3.  **Sanificazione dei Segreti**: Un singolo apice in un file di testo può essere più distruttivo di un bug logico complesso.

La missione Mnemosyne continua. Il prossimo obiettivo sarà l'automazione della distillazione della conoscenza, affinché ogni sessione venga archiviata senza intervento umano, trasformando ogni riga di log in un fatto atomico per il futuro.
