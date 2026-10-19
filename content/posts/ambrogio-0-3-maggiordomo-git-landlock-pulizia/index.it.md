+++
title = "Ambrogio 0.3: Come Funziona Oggi tra Conversazioni, Tre Tipi di Agenti, Progetti e Gabbia Landlock"
date = 2026-10-16T06:00:00+02:00
draft = false
description = "L'architettura di Ambrogio 0.3 che usiamo oggi in laboratorio: le code che mantengono la sessione su disco, i tre tipi di agenti (interni, esterni pilotati ed esterni liberi istruiti tramite skill), i progetti con i documenti, i cron job, l'interfaccia web nativa e il motore che gestisce Git e Landlock."
tags = ["ambrogio", "agenti", "orchestrazione", "golang", "landlock", "sqlite", "git", "devops"]
author = "Tazzo"
+++

## Dagli esperimenti alla versione che usiamo tutti i giorni

Nei due articoli precedenti ho raccontato come è nato **Ambrogio 0.1** (un singolo binario in Go con SQLite per tenere vivi gli agenti) e come nella **0.2** abbiamo provato gli alberi di task su worktree Git con la review nella stessa sessione.

La 0.2 aveva mostrato due limiti chiari: gli alberi di task generati dagli agenti si moltiplicavano fuori controllo e dentro lo stesso binario si erano accumulati due motori diversi (il vecchio codice della 0.1/0.2 e quello nuovo), al punto che la pagina web leggeva contatori in memoria non più aggiornati e mostrava zero worker attivi anche mentre gli agenti stavano lavorando.

Con **Ambrogio 0.3** — dopo aver eliminato in due code di pulizia 377 file e oltre 67.700 righe di codice vecchio — siamo arrivati alla versione pulita e stabile che usiamo oggi nel laboratorio per tenere traccia di tutti i lavori, presentata anche sul sito dedicato del progetto: [ambrogio.tazlab.net](https://ambrogio.tazlab.net).

## 1. Dagli alberi alle code: una sola sessione che attraversa tutti i passi

Il cambiamento principale della 0.3 è il passaggio **dagli alberi di task alle code lineari**.

Oggi l'unità di lavoro è una **coda**: una sequenza ordinata di passi (*step*) con un tetto massimo di passi dichiarato nel momento in cui la accetto (`steps_cap`). Nessun lavoro parte più da solo: una richiesta può essere aperta in qualsiasi momento, ma resta ferma finché non la approvo io decidendo quanti passi può compiere. Se la coda raggiunge il limite di passi senza aver finito, si ferma e torna da me spiegando cosa ha completato e cosa manca, senza andare persa.

La caratteristica fondamentale è che **l'intera coda condivide un'unica sessione dell'agente salvata su disco (`session_id`)**:

- il terzo passo della coda conosce già tutto quello che è stato letto e deciso nel primo passo, senza dover rileggere il repository da capo e senza sprecare token;
- poiché la sessione vive su disco, sopravvive anche a una pausa o a un riavvio del binario di Ambrogio.

Anche **parlare con Ambrogio** usa esattamente lo stesso meccanismo: una conversazione non è una tabella separata, ma una coda di tipo `conversation`. Ogni mio messaggio aggiunge un passo alla coda e la risposta dell'agente ne diventa il riassunto (*brief*). Le conversazioni hanno slot dedicati (`conversation_slots`) così non aspettano mai dietro ai lavori pesanti in background; dopo un periodo di inattività vanno in pausa da sole e, appena scrivo un nuovo messaggio, riprendono la stessa sessione dal disco.

## 2. I tre tipi di agenti e la skill che apre la porta a qualsiasi strumento esterno

Per non dare a tutti gli agenti gli stessi permessi e lo stesso costo, Ambrogio 0.3 distingue **tre tipi di agenti**, ognuno con un ruolo preciso:

| Tipo di agente | Chi lo avvia | Cosa può fare | A cosa serve |
|---|---|---|---|
| **1. Agente interno (`worker-internal`)** | Avviato da Ambrogio | Legge il codice (`read`, `glob`, `grep`), apre e organizza i task, legge e scrive i documenti di progetto nel database. **Non ha `bash` e non può modificare file su disco.** | Gestire la struttura interna, pianificare i lavori, tenere aggiornati i documenti e i progetti a costo minimo. |
| **2. Agente esterno pilotato (`worker-external`)** | Avviato da Ambrogio via ACP dentro una gabbia Landlock | Ha tutti gli strumenti operativi (`read`, `write`, `edit`, `bash`, `browser`) ma limitati al solo worktree della coda, senza credenziali Git o accesso a `gopass`. | Eseguire i lavori sul codice in totale isolamento, lasciando poi al motore in Go il compito di fare push, Pull Request e merge. |
| **3. Agente esterno libero (*free external agent*)** | Qualsiasi agente o harness avviato fuori da Ambrogio | Prenota i task liberi via API (`GET /api/v1/free`, `POST /api/v1/book`) e consegna il risultato (`POST /api/v1/deliver`). | Permettere a qualunque agente o ambiente esterno di lavorare insieme ad Ambrogio tenendo tutta la tracciabilità nello stesso posto. |

Il terzo tipo — **l'agente esterno libero** — è quello che ha reso il sistema davvero aperto.

Invece di costringermi a usare solo i worker interni avviati dal binario, Ambrogio espone sulla sua API tre comandi pensati per chi lavora da fuori:

1. `GET /api/v1/free` per vedere i lavori aperti che nessuno ha ancora preso in carico;
2. `POST /api/v1/book` per prenotare un task con una scadenza automatica (se l'agente esterno si blocca o sparisce, la prenotazione scade da sola senza bisogno di watchdog);
3. `POST /api/v1/deliver` per consegnare il lavoro svolto e proporre eventuali passi successivi.

La cosa più comoda è come un agente esterno impara a usare tutto questo: **Ambrogio fornisce direttamente una propria skill** (`SKILL.md`) che spiega la struttura del motore, le porte HTTP, il ciclo di prenotazione e il formato di consegna. Qualsiasi agente o harness esterno — anche uno che non ha mai visto Ambrogio prima — può caricare quella skill all'inizio della sessione e cominciare immediatamente a prendere in carico task, aggiornarli e consegnare il lavoro dentro Ambrogio.

## 3. Progetti, documenti, cron job e interfaccia web nativa (`/ui`)

Tutto quello che succede nel motore viene registrato nel file SQLite locale ed è consultabile in tempo reale dall'**interfaccia web nativa (`/ui`)**, incorporata direttamente nel binario Go e sistemata anche per essere usata comodamente dallo schermo del telefono (`320×568`).

Dalla pagina web gestisco quattro elementi che tengono in ordine il laboratorio:

- **I progetti e i documenti:** ogni lavoro appartiene a un progetto, e ogni progetto conserva nel database i propri **documenti** (il piano, la roadmap, lo stato di avanzamento). I documenti non sono facoltativi: la catena dei task dice *cosa* è stato fatto, ma i documenti spiegano *perché*. Per questo la review deterministica del motore controlla che i documenti minimi del progetto (`MinDocs`) siano stati scritti e rifiuta di chiudere la coda se mancano.
- **I cron job:** posso dichiarare controlli periodici automatici (ad esempio un job che verifica periodicamente se il repository compila e aggiorna il documento `BUILD.md`). Se il controllo trova un errore, non si mette a toccare il codice da solo di nascosto: registra l'errore vero e apre una proposta di task che resta in attesa della mia conferma.
- **La tracciabilità completa e la contestazione:** ogni evento (`task_event`), ogni singola esecuzione con durata ed esito (`run`), ogni consegna (`report`) e ogni verifica (`review`) resta salvato nel database. E se mi accorgo più tardi che un task chiuso come completato in realtà non funziona, c'è un comando esplicito (`POST /api/v1/contest`) che apre un task figlio collegato alla chiusura precedente per correggere il difetto senza cancellare la storia.

## 4. Il motore come "Maggiordomo" Git, le due porte e la gabbia Landlock

Per i worker pilotati da Ambrogio (`worker-external`), la sicurezza e la gestione di Git non sono affidate alla buona volontà del modello AI, ma sono imposte dal codice Go e dal kernel Linux:

1. **È il motore che possiede Git, non l'agente:** ogni coda lavora in un proprio worktree e su un proprio branch locale. Il worker scrive il codice, fa girare i test e fa `git commit` in locale, ma non ha nessun token GitHub e non può fare `git push`. Quando la coda è pronta, è il treno di atterraggio (*train*) del motore in Go che valida il branch, fa il push, apre la Pull Request su GitHub, attende i check e fa il merge in sequenza (provando prima un rebase meccanico se serve). E la prima prova reale di questo meccanismo è stata proprio l'aggiornamento automatico del sito [ambrogio.tazlab.net](https://ambrogio.tazlab.net), portato in merge dalla coda `#67` del motore.
2. **La gabbia Landlock per ogni worker:** prima di eseguire un worker, il launcher `ambrogio-sandbox` applica al processo una policy **Landlock** del kernel Linux (`NoNewPrivs=1`). Il worker può scrivere esclusivamente nel worktree di quel giro; non può scrivere nel resto del filesystem e non può leggere `~/.gnupg` né invocare `gopass` (`Permission denied`).
3. **Due porte HTTP separate (`7806` e `7807`):** la porta `7806` è riservata a me e contiene tutti i comandi di amministrazione (accettare le code, cambiare le impostazioni, aprire le conversazioni); la porta `7807` (`AMBROGIO_DOOR`) è quella che vedono gli agenti e contiene solo i pochi comandi per leggere il proprio incarico e consegnare il risultato. Qualsiasi tentativo di un agente di chiamare un comando da operatore riceve `403 Forbidden`.
4. **Il Vault interno e la passphrase:** i segreti del motore vivono cifrati dentro SQLite (`AES-256-GCM` con chiave derivata tramite `Argon2id` dalla passphrase che inserisco all'avvio nella barra della pagina web). Anche il cambio della passphrase richiede obbligatoriamente di inserire sia la vecchia sia la nuova passphrase (`{old, new}`), ricifrando il vault in una sola transazione e revocando subito tutte le sessioni aperte, così nessuno può cambiare la chiave trovando un dispositivo con la sessione sbloccata.

## Conclusioni

Il percorso dalla 0.1 alla 0.3 mi ha portato esattamente al punto che cercavo quando ho spento gli orchestratori esterni:

- un **singolo binario in Go** che possiede una sola cartella (`/opt/ambrogio/data`) e tiene tutta la storia in un file SQLite;
- **code lineari che mantengono la sessione su disco**, così chi inizia il lavoro lo continua senza bruciare token a rileggere il contesto a ogni passo;
- **progetti, documenti, cron job e conversazioni** gestibili da un'unica pagina web anche da telefono;
- e **tre livelli di agenti** — interni per l'organizzazione, esterni pilotati in gabbia Landlock per i worktree automatici, ed esterni liberi istruiti tramite la skill di Ambrogio — che permettono di collegare al motore qualsiasi nuovo strumento o agente esterno senza perdere il controllo né la tracciabilità dei task.

Tutti i dettagli sull'architettura e sul funzionamento del progetto sono raccolti anche su [ambrogio.tazlab.net](https://ambrogio.tazlab.net).
