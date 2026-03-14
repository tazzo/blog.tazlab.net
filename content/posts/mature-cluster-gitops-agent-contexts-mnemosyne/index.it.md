---
title: "Un cluster maturo: deploy automatici, contesti per agenti e la migrazione MCP di Mnemosyne"
date: 2026-03-14T06:00:00+01:00
draft: false
tags: ["kubernetes", "gitops", "flux", "mcp", "mnemosyne", "agents", "context-management", "ci-cd"]
categories: ["Infrastructure", "DevOps"]
author: "Taz"
description: "Quando il cluster diventa stabile, i deploy diventano routine e le procedure si automatizzano. Cronaca di una migrazione MCP e della maturità raggiunta dal laboratorio."
---

## Il punto di arrivo

Oggi ho migrato Mnemosyne dal protocollo SSE deprecato a Streamable HTTP. Ma questo non è un articolo su una migrazione tecnica. È un articolo su cosa significa quando il tuo cluster Kubernetes diventa *noioso* - nel senso buono del termine.

Ho fatto il commit, aspettato due minuti, e il nuovo pod era in esecuzione con la nuova configurazione. Nessun intervento manuale, nessun `kubectl apply`, nessun panico. Flux ha rilevato il cambiamento nel repository Git, l'ImagePolicy ha puntato alla nuova immagine buildata dalla GitHub Action, e il Deployment è stato aggiornato.

Questa non è una configurazione che ho fatto stamattina. È il risultato di mesi di iterazioni, di rebuild completi del cluster, di pipeline CI/CD che fallivano e venivano riparate, di ImagePolicy che non riconoscevano i tag corretti. Ma oggi, finalmente, funziona.

## La migrazione come caso di studio

Mnemosyne è il server MCP che gestisce la mia memoria semantica. Espone tool per l'ingestione, la ricerca e la gestione di ricordi tecnici, usando PostgreSQL con pgvector per la similarità semantica. Fino a ieri usava il protocollo SSE (Server-Sent Events) per comunicare con i client MCP.

Il problema: il client oh-my-pi non gestiva correttamente il protocollo SSE. Richiedeva che il client mantenesse una connessione GET persistente su `/sse` mentre inviava richieste POST su `/message`. Ma oh-my-pi trattava SSE come un semplice HTTP POST, senza il listener in background.

La soluzione non era fixare il client, ma migrare al nuovo standard: **Streamable HTTP**. Questo protocollo usa un singolo endpoint POST (`/mcp`) che restituisce una risposta SSE quando necessario. Niente session management complesso, niente listener separati.

La migrazione è stata semplice:

1. Aggiornato `mcp-go` dalla v0.44.0 alla v0.45.0
2. Sostituito `NewSSEServer()` con `NewStreamableHTTPServer()`
3. Cambiato l'endpoint da `/sse` + `/message` a `/mcp`
4. Aggiornato `MCP_TRANSPORT` da `"sse"` a `"http"` nel Deployment

Quattro modifiche minime. Il codice si è compilato al primo tentativo. Ho fatto commit, push, e il cluster ha fatto il resto.

## La pipeline GitOps che funziona

La nostra pipeline CI/CD è deliberatamente semplice:

```
Commit → GitHub Action → Build immagine → Push su registry → Flux riconcilia → Deploy
```

Non abbiamo stage multipli, non abbiamo approval gate, non abbiamo deployment su ambienti separati. È un laboratorio casalingo, non una enterprise. Ma questa semplicità è una feature, non un limite.

Quando faccio commit su `mnemosyne-mcp-server`, la GitHub Action:
1. Fa checkout del codice
2. Builda l'immagine Docker con un tag basato sul numero di run e sul commit SHA completo
3. Pusha su Docker Hub come `tazzo/mnemosyne-mcp:mcp-<run_number>-<full_sha>`

Nel frattempo, nel cluster:
1. Flux ha un ImageRepository che monitora Docker Hub
2. Un ImagePolicy seleziona l'immagine più recente
3. Il Deployment ha un commento `{"$imagepolicy": "flux-system:mnemosyne-mcp"}` che Flux usa per l'auto-update
4. Quando rileva una nuova immagine, aggiorna il Deployment
5. Kubernetes fa rollout del nuovo pod

Tempo totale: 2-3 minuti dalla push al pod in esecuzione.

## Il sistema dei contesti AGENTS.ctx

Ma la parte più interessante non è la pipeline. È come ho strutturato le procedure operative.

Ho creato un sistema di contesti in `AGENTS.ctx/` che definisce regole, workflow e memoria per ogni tipologia di attività. Ogni contesto ha:

- Un file `CONTEXT.md` che descrive il progetto e le sue regole
- File asset con prompt specifici, template, o risorse
- Un inventory di progetti, stati, e debito tecnico

Quando apro un contesto, l'agent che uso diventa immediatamente specializzato. Per esempio:

- **blog-writer**: Definisce un workflow a 5 fasi (Planning → Writing → Review → Translation → Publish) con regole per lo stile, la formattazione, e la pubblicazione GitOps
- **mnemosyne-mcp-server**: Documenta il server MCP, la struttura del codice, le variabili d'ambiente, e le procedure di build/deploy
- **tazlab-k8s**: Descrive il cluster Kubernetes, le risorse Flux, e come interagire con esso

Questo articolo è il secondo che scrivo usando il contesto `blog-writer`. Il processo è diventato quasi automatico: apro il contesto, decido i punti chiave, l'agent scrive, io revisiono. Niente più iterazioni infinite con prompt generici. Le regole sono già lì, pronte.

## La visione: procedure automatiche per Mnemosyne

Il prossimo passo è creare un contesto per l'ingestione dei ricordi in Mnemosyne.

Attualmente, quando voglio salvare un ricordo tecnico, devo:
1. Formattare il contenuto
2. Chiamare manualmente il tool `ingest_memory`
3. Verificare che sia stato salvato correttamente

Con un contesto dedicato, questo diventerà automatico. L'agent saprà:
- Quale formato usare per i ricordi
- Come strutturare il contenuto per la ricerca semantica
- Quando salvare (es. alla fine di una sessione di lavoro)
- Come verificare l'avvenuto salvataggio

Basta aprire il contesto e dire "salva quello che abbiamo fatto oggi". Tutto il resto è gestito dalle regole.

## Il paradigma multi-agent ridisegnato

Per molto tempo, il paradigma prevalente per l'automazione con LLM è stato "usa agenti specializzati diversi per compiti diversi". Un agent per il codice, uno per la scrittura, uno per i dati.

Con il sistema dei contesti, questo ragionamento si ribalta — ma in modo più sottile di quanto sembri.

Per come lavoro oggi, da solo, la configurazione ottimale è un agent generico + N contesti caricati on-demand. Quando apro il contesto `blog-writer`, l'agent sa già come strutturare un articolo, quali regole seguire, come pubblicarlo. Quando apro `mnemosyne-mcp-server`, conosce la struttura del codice, le variabili d'ambiente, la pipeline CI/CD. L'agent non cambia — cambia il contesto.

Ma lo stesso sistema scala in orizzontale. In futuro, potrei deployare più agenti separati direttamente sul cluster Kubernetes — ognuno con il proprio contesto già caricato come ConfigMap o montato come volume. Un agente responsabile della manutenzione del cluster, uno dedicato all'ingestione delle memorie in Mnemosyne, uno che monitora i deploy Flux. Ognuno autonomo, ognuno specializzato, ognuno con una cartella di contesti che copre le situazioni operative che potrebbe incontrare.

Il punto è che i contesti sono **portabili e componibili**. Non sono legati a un singolo agent. Sono unità di conoscenza operativa che possono essere distribuite, montate, combinate. Oggi le uso in modo interattivo. Domani potrebbero essere la base di un sistema di automazione autonoma.

Questo riduce la complessità di gestione:
- Un solo formato di conoscenza operativa (Markdown strutturato)
- Contesti versionabili su Git, aggiornabili centralmente
- Stessa struttura per uso interattivo e deployment autonomo

È come avere una libreria di procedure operative che funziona sia quando le sfoglio io, sia quando le legge un agente in esecuzione su un pod.

## Il cluster in salute

Tornando all'inizio: il cluster è stabile. Questo non significa che non ci siano problemi - ci sono sempre. Ma significa che i problemi sono gestibili, e le procedure sono ripetibili.

Quando ho dovuto migrare Mnemosyne a Streamable HTTP, non ho dovuto:
- Ricostruire l'ambiente di sviluppo
- Configurare manualmente le variabili d'ambiente
- Fare debugging della pipeline CI/CD
- Imparare da capo come funziona Flux

Ho semplicemente:
1. Aperto il contesto `mnemosyne-mcp-server`
2. Fatto le modifiche al codice
3. Commit e push

Il resto è successo da solo. Questo è il risultato di aver documentato, iterato, e costruito procedure solide nel tempo.

## La pipeline del futuro

La nostra pipeline oggi è semplice. In futuro diventerà più ricca:

- **Test automatizzati**: Ogni PR triggera test prima del merge
- **Ambienti di staging**: Deploy su un ambiente separato prima della produzione
- **Rollback automatici**: Se i health check falliscono, rollback alla versione precedente
- **Notifiche**: Slack o email quando un deploy completa o fallisce

Ma la base c'è, ed è robusta. Ogni nuova feature sarà un'estensione, non una rifondazione. È questo il vantaggio di aver costruito bene le fondamenta.

## Cosa abbiamo imparato

Questa "tappa" del viaggio mi ha confermato che:

1. **La GitOps non è solo teoria**: Quando funziona, ti dimentichi che esiste. Fai commit, e il codice arriva in produzione.
2. **I contesti cambiano il modo di lavorare**: Nel mio caso, lavorando da solo, un agent generico + contesti ben definiti è risultato più comodo e gestibile di tanti agenti separati. Non è una legge universale, ma per questo flusso di lavoro funziona bene.
3. **La documentazione è codice**: I file CONTEXT.md sono vivi. Vengono aggiornati, versionati, e usati ogni giorno.
4. **La semplicità vince**: Una pipeline con 3 passaggi che funziona è meglio di una con 10 che non sai come configurare.

Il cluster è maturo. Non "completo" - non lo sarà mai. Ma maturo abbastanza da permettermi di lavorare su cose interessanti invece di spegnere incendi.
