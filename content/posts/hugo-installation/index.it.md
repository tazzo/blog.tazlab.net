+++
date = '2025-12-21T23:07:21Z'
draft = false
title = "Dettagli sull'installazione di Hugo"
+++

Questo post descrive la configurazione dell'installazione di Hugo.

## Configurazione di Docker Compose

Il sito Hugo è configurato tramite Docker Compose. Il file `compose.yml` definisce un servizio chiamato `hugo` che utilizza l'immagine Docker `hugomods/hugo:exts-non-root`. Questa immagine include la versione estesa di Hugo e viene eseguita come utente non-root, migliorando la sicurezza e fornendo funzionalità essenziali per un sito Hugo moderno.

Il file `compose.yml` mappa anche la directory locale del progetto su `/src` all'interno del container, consentendo a Hugo di servire i contenuti dai file locali. La porta `1313` è esposta per accedere al server di sviluppo.

```yaml
services:
  hugo:
    image: hugomods/hugo:exts-non-root
    container_name: hugo
    command: server --bind=0.0.0.0 --buildDrafts --buildFuture --watch
    volumes:
      - ./:/src
    ports:
      - "1313:1313"
```

## Installazione del tema Blowfish

Il tema Blowfish è stato installato utilizzando i sottomoduli Git. Questo metodo garantisce che il tema possa essere facilmente aggiornato e mantenuto insieme al progetto Hugo principale.

1.  **Inizializza il repository Git**:
    \`\`\`bash
    git init
    \`\`\`

2.  **Aggiungi il tema Blowfish come sottomodulo**:
    \`\`\`bash
    git submodule add -b main https://github.com/nunocoracao/blowfish.git themes/blowfish
    \`\`\`

3.  **Configura il tema**:
    Il file `hugo.toml` predefinito è stato rimosso e i file di configurazione dalla directory `config/_default/` del tema Blowfish sono stati copiati nella directory `config/_default/` del sito. La riga `theme = "blowfish"` nel file `config/_default/hugo.toml` è stata decommentata per attivare il tema.

Questa configurazione fornisce un ambiente robusto e flessibile per lo sviluppo di un sito web Hugo con il tema Blowfish.

## Automatizzare i Deploy con un Webhook

Dopo aver configurato il blog, il passo logico successivo per noi era automatizzare gli aggiornamenti. Effettuare manualmente il pull delle modifiche sul server ogni volta che veniva scritto un nuovo post sembrava macchinoso. Volevamo un classico flusso di lavoro GitOps: un `git push` sul ramo principale doveva aggiornare automaticamente il blog live.

È qui che è iniziata la nostra avventura con i webhook, e si è trasformata in una vera e propria maratona di debugging!

### Lo Strumento: `webhook-receiver`

Abbiamo deciso di utilizzare la popolare immagine Docker `almir/webhook`, uno strumento leggero che ascolta le richieste HTTP ed esegue script predefiniti. Il piano era semplice:
1.  GitHub invia una richiesta POST al nostro URL del webhook quando effettuiamo un push di un commit.
2.  Il servizio `webhook` verifica la richiesta utilizzando un segreto condiviso.
3.  Esegue quindi uno script, `pull-blog.sh`, che lancia `git pull` all'interno della directory del nostro progetto Hugo.

Semplice, no? Be'...

### Il Viaggio nell'Inferno dei Permessi

Quello che è seguito è stato un classico caso di "sulla mia macchina funziona" contro la dura realtà della sicurezza dei container Docker.

**Problema 1: `git: not found`**
Il primo trigger del webhook è fallito immediatamente. Ci siamo subito resi conto che l'immagine minimale `almir/webhook` non includeva `git`. La prima correzione è stata creare il nostro `Dockerfile` personalizzato basato sull'immagine e aggiungere `git` utilizzando il gestore di pacchetti di Alpine:

```dockerfile
FROM almir/webhook:latest

USER root
RUN apk add --no-cache git
USER webhook
```

**Problema 2: Autenticazione GitHub**
Con `git` installato, l'errore successivo è stato `fatal: could not read Username for 'https://github.com'`. Il nostro `git pull` stava cercando di usare HTTPS e non aveva credenziali. Sebbene avremmo potuto usare un Personal Access Token (PAT), abbiamo optato per l'approccio più sicuro e standard per la comunicazione server-to-server: le **Deploy Key SSH**.

Questo ha comportato:
1.  Generare una nuova coppia di chiavi SSH sul server.
2.  Aggiungere la chiave pubblica alla sezione "Deploy keys" del nostro repository GitHub (con accesso di sola lettura).
3.  Montare la chiave privata nel container `webhook`.

**Problema 3: La Saga del `Permission denied`**
È qui che le cose si sono complicate. Per quella che è sembrata un'eternità, ogni tentativo è stato accolto da un errore `Permission denied (publickey)` da parte di `git`. L'utente `webhook` all'interno del container non poteva accedere alla chiave SSH.

Il nostro viaggio di debugging è andato più o meno così:
-   **Tentativo A:** Impostare i permessi del file della chiave dal `Dockerfile`. Fallito, perché non si può fare `chmod`/`chown` su un volume che viene montato a *runtime* during la fase di *build* dell'immagine.
-   **Tentativo B:** Introdurre uno script `entrypoint.sh` per impostare i permessi all'avvio del container. Questo ci ha portato in un labirinto di problemi di cambio utente all'interno del container. Strumenti come `su-exec`, `runuser` e `gosu` sono tutti falliti con errori di `Operation not permitted`, anche dopo aver concesso le capabilities `SETUID` e `SETGID` al container. È stata una classica battaglia contro le immagini minimali di Alpine e le feature di sicurezza di Docker.

**La Svolta**
Dopo aver provato ogni combinazione di direttive `user:` e logica di entrypoint, abbiamo trovato il vero colpevole: la chiave privata veniva montata come **sola lettura (read-only)**.

I permessi di un file in sola lettura *non possono essere cambiati*. Il nostro script `entrypoint.sh` stava fallendo nel tentativo di `chown` della chiave all'utente `webhook`, ma falliva silenziosamente.

**La Soluzione Finale e Funzionante**
La soluzione corretta, e molto più robusta, è stata:
1.  **Modificare `compose.yml`**: Montare la chiave privata in una posizione temporanea e *scrivibile* (`/tmp/id_rsa`).
2.  **Usare uno script `entrypoint.sh`**: Questo script, eseguito come `root` prima dell'avvio dell'applicazione principale, fa quanto segue:
    -   Crea la directory `.ssh` nella home reale dell'utente `webhook` (`/home/webhook/.ssh`).
    -   **Copia** la chiave da `/tmp/id_rsa` a `/home/webhook/.ssh/id_rsa`.
    -   Imposta la proprietà (`chown webhook:webhook`) e i permessi (`chmod 600`) corretti sulla chiave *copiata*.
    -   Rimuove la chiave temporanea da `/tmp`.
3.  **Aggiornare `GIT_SSH_COMMAND`**: Assicurarsi che la variabile d'ambiente punti alla destinazione finale della chiave: `/home/webhook/.ssh/id_rsa`.
4.  **Eseguire il container come utente `webhook`**: Abbiamo impostato `user: webhook` in `compose.yml` per garantire che il processo venga eseguito con privilegi minimi dopo che l'entrypoint ha svolto il suo lavoro come root.

**L'Ultimo Mistero: I Log Vuoti**
Anche con tutto funzionante, il comando `docker logs` rimaneva ostinatamente vuoto. Il servizio `webhook` funzionava, ma inghiottiva tutto l'output del nostro script. L'ultimo pezzo del puzzle è stato aggiungere questa riga all'inizio del nostro script `pull-blog.sh`, che forza tutto l'output verso gli stream standard del container:
```bash
exec >/proc/1/fd/1 2>/proc/1/fd/2
```
Con questo, abbiamo finalmente potuto vedere l'output di `git pull` nei log. Un lungo viaggio, ma una lezione preziosa sulle sfumature dei permessi Docker e della logica di runtime!
