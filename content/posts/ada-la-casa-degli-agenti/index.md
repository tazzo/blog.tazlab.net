---
title: "Ada: una casa di agenti che non si addormenta"
date: 2026-10-28
draft: true
tags: ["agents", "ada", "podman", "systemd", "debugging", "observability"]
---

> Materiale di lavoro per l'articolo su Ada (finora non scritto). Fatti misurati la notte del 27–28
> ottobre 2026, con i numeri che sono serviti davvero.

## Cos'è

Ada è una **casa**: un motore durevole (Node 24 + TypeScript, SQLite) e una squadra di agenti che
condividono un database e una macchina. Non "un chatbot": un'amministratrice (Ada), un ingegnere
(Enrico), una ricercatrice (Renato), un organizzatore (Orfeo), una designer (Debora), più gli
ingegneri creati a runtime (Teo, Alice). Ognuno ha un ruolo, dei tool e un mandato scritto.

Il passaggio della notte: da **LXC su Proxmox** a **container Podman su una VM Hetzner**, senza
perdere né il database né il modo di governarlo.

## L'errore di impianto (la radice di tutto)

Il codice era stato copiato **dentro l'immagine** (`COPY app/ /app/`). Sembra la cosa giusta in un
mondo immutabile, ma per un agente che **modifica il proprio codice** è sbagliata: un riavvio ricarica
la stessa immagine, quindi lo stesso commit. Nove riavvii non hanno cambiato niente, e sembrava "il
container non riparte". Nel LXC il codice stava sul **volume**: `git checkout` + restart = codice nuovo.

Da qui il disegno corretto, che Ada stessa aveva già scritto in un commit:

> **codice su volume, immagine solo per l'ambiente.**

## I sette guasti della notte (con i numeri)

1. **Codice nell'immagine** → nessun deploy possibile (nove riavvii, zero effetti).
2. **`gopass show -o` tronca i segreti multilinea** → la CA di Vault arrivava come header di 27 byte;
   VSO: *no valid certificates found*. La CA c'era: sbagliava il flag.
3. **Il motore esegue l'albero di lavoro, non il commit** → un `src/restart.ts` a metà (import di
   `liveRestartUnits` che non esisteva) lo uccideva all'import. Da fuori: "il container non riparte".
4. **Una riga di roster senza conversation id uccideva `/agents`**:
   *Document pi.live requires a conversation ID* → il pannello perdeva tutti i canali, e la pagina di
   Teo rispondeva 500 (per questo "non diceva niente").
5. **`request_restart` mentiva**: *"interrupted and may have partially run"*, zero righe di boot.
6. **Pump della coda senza tetto**: **4560** righe `told an idle orchestrator it has work ready`; e il
   lock dei deploy armato **90 minuti** con la valvola dei 30 che non scattava mai.
7. **`.backup` in livelock**: su un DB scritto di continuo la copia riparte a ogni commit e non
   finisce; il deploy restava appeso nello snapshot (stessa radice del flood).

Contorno: **363 `tool failed`**, **41 turni `stop=error`** senza la causa nel log, **72** health
falliti registrati e **28** recuperi automatici.

## Cosa c'è adesso

- **Home su volume** (`/srv/ada/prod/home` → `/home/ada`), immagine `ada-env` con node, git, sqlite3,
  curl, poppler, **systemd**.
- **systemd dentro il container**: `ada.service` (motore) + `ada-hubd` (supervisore). Riavviare il
  proprio processo è un comando, non un intervento esterno: pid 198 → 266 → 851, container intatto.
- **Canale di riavvio che non mente**: `touch /home/ada/data/.restart` → path unit → restart.
- **Deploy con verdetto esterno** (lato host): health col commit giusto, ≥5 agenti, `quick_check`, e
  **un turno vero con un marker**; se uno è rosso, rollback al commit che stava girando, e il
  candidato resta su `wip/<sha>`. Rifiuta un albero sporco: `refused: dirty tree`.
- **Guardia** indipendente: `ada-guard.timer` ogni 2 minuti.
- **Ada può delegare**: `subagent` (cap 1+4) e i suoi figli sono **di sola lettura** — verificato:
  `read, recall, list_agents, agent_status, journal, skill_list, skill_read, catalog_document,
  find_document, documents_list, search_history`; **no bash, no write, no edit**.
- **`inspect`: gli occhi grezzi dei lettori** — git, journalctl, una SELECT forzata in sola lettura,
  HTTP locale. Lista chiusa, **senza shell**: guardare non può diventare toccare.
- **Settings API**: `GET/POST /agents/:name/settings` → mandato del ruolo, cap live/pending, limiti.

## Il contratto "no-silence" (la parte da articolo)

Cinque invarianti nate dai guasti:

1. **Nessuna attesa senza padrone e scadenza.** Un agente `idle` con lavoro aperto è un guasto.
2. **Nessuno strumento può mentire.** Il verdetto viene dal mondo: una riga di boot, un file di esito.
3. **Ogni ciclo ha un tetto e un backoff.** 4560 notifiche non sono un sistema che parla: è rumore.
4. **Un cancello che fallisce nomina il blocco** (`tests/deploy.ts: 13 vs 0`), non "48 errori".
5. **Chi si arrende lo dice, con una ricevuta.** `escalated` inerte non è una scelta.

E la conseguenza architetturale: **un solo attore fa lo switch** (il host), gli agenti fanno il
codice. Due supervisori con due idee di "cosa sta girando" sono il bug, non la cura.

## Cosa resta aperto (e sarà il prossimo episodio)

- Il **menù settings** nel pannello (API pronta): mandato visibile e modificabile, cap a mano.
- **Disciplina dei log**: `stop=error` con causa, `tool failed` con l'errore, `turn done` in una riga,
  `restart-announced` una volta per commit e non a ogni boot.
- Gli ingegneri da **scongelare** per il lavoro dell'operatore (teaching, halloween).

## La frase da tenere

> Non era il modello. Era il contesto: cosa vede un agente, cosa può toccare, e quanto è grande il
> suo raggio d'azione. Un agente bravo in una stanza con tre attori e un albero condiviso sembra
> stupido; lo stesso agente, isolato, con un verdetto esterno e una scadenza, sembra un collega.
