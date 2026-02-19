---
title: "Mnemosyne: Il Ritorno al Castello e la Battaglia contro il Rumore Ricorsivo"
date: 2026-02-18T23:00:00+01:00
draft: false
tags: ["postgresql", "pgvector", "data-engineering", "gemini-ai", "snr", "markdown", "recursive-loops"]
categories: ["Cloud Engineering", "Intelligence"]
author: "Taz"
description: "Dalla migrazione su PostgreSQL locale alla creazione di un pipeline di purificazione: come abbiamo risolto la trappola dei meta-ricordi e ottimizzato i log trasformando i JSON in Markdown."
---

# Mnemosyne: Il Ritorno al Castello e la Battaglia contro il Rumore Ricorsivo

Nel precedente capitolo, descrivevo **Mnemosyne** come un motore di memoria semantica ospitato su Google AlloyDB. Oggi quel ponte è stato abbattuto: Mnemosyne è tornata a casa, nel cluster locale di TazLab. Ma il trasloco ha rivelato una sfida di data engineering inaspettata: **la memoria stava iniziando a ricordare se stessa in un loop infinito.**

In questo post documento come abbiamo trasformato 176 sessioni di log in una base di conoscenza pulita, sconfiggendo la trappola della ricorsione e ottimizzando i dati per l'era dell'intelligenza artificiale.

## 1. Il Trasloco: PostgreSQL e pgvector nel Castello

L'autonomia di TazLab passa per il \"ferro\" locale. Abbiamo configurato un'istanza PostgreSQL gestita dal **Crunchy Postgres Operator (PGO)**, con l'estensione `pgvector` attiva per gestire embedding a 3072 dimensioni. 

La sfida non è stata solo far parlare il TazPod con il DB locale (`192.168.1.241`), ma farlo in modo sicuro e resiliente, estraendo le credenziali dinamicamente dai Secret di Kubernetes ed evitando di sporcare il codice con password statiche.

## 2. Dall'Esplosione JSON alla Compattezza Markdown

Il primo grande ostacolo è stato il formato dei dati. La Gemini CLI salva ogni sessione in file JSON densi di metadati tecnici: timestamp di ogni chiamata, strutture di tool-call e output grezzi. Ingerire questi JSON direttamente era inefficiente:
*   **Rumore**: Il 70% del file era struttura, non contenuto.
*   **Quota**: I file JSON superavano spesso i limiti di token dei modelli, portando a costi elevati e analisi frammentate.

Abbiamo quindi implementato il **Chronicler**, un pre-processore che trasforma i JSON in **Markdown ad Alta Risoluzione**. 
Questa trasformazione ha permesso di:
1.  **Sintetizzare i log**: Abbiamo rimosso i metadati inutili e troncato chirurgicamente i dump di sistema (Terraform, K8s logs) superiori a 5000 caratteri.
2.  **Aumentare l'SNR**: Il rapporto segnale-rumore è aumentato drasticamente, permettendo a Gemini di concentrarsi solo sulle decisioni architettoniche.
3.  **Gestire la Quota**: File più piccoli significano più \"ricordi\" estratti con una singola chiamata API.

## 3. La Trappola della Ricorsione (Meta-Memoria)

Il problema più insidioso è emerso durante il bulk update. Usando la Gemini CLI per gestire Mnemosyne, l'IA crea nuove sessioni in cui si discute di... come caricare i ricordi precedenti. 

### L'Inception dei Log
Se ingerissimo questi log senza filtrarli, creeremmo un loop catastrofico:
1.  L'IA estrae ricordi da una sessione tecnica.
2.  Viene creato un log della sessione di estrazione (che contiene i ricordi appena estratti).
3.  Lo script carica quel log, ri-estraendo gli stessi ricordi come se fossero fatti nuovi.
4.  La memoria si riempie di \"ricordi di ricordi\", duplicando i dati ed esponenzialmente il rumore.

### La Soluzione: \"Deep Sniffing\" a 5 Messaggi
Per rompere questo specchio riflesso, abbiamo evoluto il Chronicler con un filtro semantico di profondità. Lo script ora \"annusa\" i primi 5 messaggi di ogni sessione. Se rileva il **\"KNOWLEDGE EXTRACTION PROTOCOL\"**, identifica la sessione come *meta-lavoro* (lavoro sull'archiviazione stessa) e la scarta prima che possa contaminare il database.

## 4. La Maratona via CLI: Bypassare i Limiti API

L'ingestione di 176 file ha subito mostrato i limiti delle API \"sviluppatore\": 20 richieste al giorno per il Free Tier. Mnemosyne si fermava ogni dieci minuti.

Abbiamo risolto forzando lo script a usare la **Gemini CLI** (`--use-cli`) per l'estrazione dei fatti. Sfruttando la quota dell'account utente (molto più generosa) e implementando una **Retry Logic (60s)** per gestire gli errori `503 UNAVAILABLE` (sovraccarico dei server), abbiamo trasformato un processo fragile in una maratona inarrestabile.

## 5. La Regola d'Oro del Minimalismo

Infine, abbiamo codificato una regola di governance fondamentale: **La Regola del Minimo Cambiamento Necessario.**
Durante lo sviluppo, l'IA tendeva a \"migliorare\" o semplificare i log e il codice a ogni passaggio, rischiando di romperlo. Abbiamo stabilito che l'agente deve agire chirurgicamente: cambiare solo lo stretto indispensabile per mantenere la stabilità del Castello.

### Prossimi Passi: La Memoria Attiva
Mnemosyne è ora un archivio pulito e autoconsistente. Il prossimo obiettivo è la **Phase 6**: trasformare l'archiviazione in un processo incrementale che avviene *durante* la sessione, permettendo all'IA di imparare in tempo reale senza mai più dover rileggere vecchi log.

---
*Cronaca Tecnica a cura di Taz - Senior Archivist di TazLab.*
