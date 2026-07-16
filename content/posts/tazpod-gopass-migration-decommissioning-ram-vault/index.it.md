+++
title = "TazPod Gopass Migration: Decommissioning the RAM Vault for Zero-Privilege Security"
date = 2026-07-16T18:00:00+02:00
draft = false
description = "Una profonda evoluzione architetturale in TazPod: come lo smantellamento del RAM vault cifrato e delle dipendenze AWS SSO/S3 in favore di gopass e GPG ha semplificato il codice, ridotto i privilegi del container Docker a zero e introdotto una sicurezza sezionata a prova di agenti IA."
tags = ["TazPod", "Gopass", "GPG", "Security", "Docker", "DevOps", "TazLab"]
categories = ["Software-IT", "Infrastructure"]
author = "Taz"
+++

## La Sfida dei Segreti nel Workspace Nomade

Gestire i segreti in un ambiente di sviluppo nomade, effimero e riproducibile come **TazPod** è sempre stato un esercizio di bilanciamento tra usabilità e sicurezza. TazPod nasce per fornire un container Docker preconfigurato con tutti i tool necessari (CLI, SDK, estensioni AI, shell personalizzata) che possa essere avviato istantaneamente su qualsiasi host Linux o container LXC su Proxmox, garantendo la stessa identica esperienza ovunque.

Tuttavia, un toolchain completo ha bisogno di accedere a chiavi API, token cloud, credenziali di database e chiavi crittografiche. Nelle prime versioni di TazPod, avevamo risolto questo problema con una soluzione ingegneristica ad hoc chiamata **RAM Vault**: un archivio cifrato con AES memorizzato su S3, decrittato all'avvio all'interno di un filesystem in RAM dell'host e montato nel container.

Sebbene questa architettura abbia funzionato per mesi, presentava due grossi limiti: un'enorme complessità operativa (condita da hack ed exit-trap fragili) e una superficie di attacco troppo ampia in un'epoca in cui gli agenti di intelligenza artificiale operano direttamente all'interno dei nostri workspace. 

Questo post racconta perché e come abbiamo smantellato il RAM Vault, migrando l'intero TazLab verso una gestione dei segreti sezionata e standardizzata basata su **gopass** e **GPG**, riducendo a zero i privilegi del container e limitando radicalmente il raggio di impatto (*blast radius*) in caso di compromissione.

---

## L'Architettura Precedente e le Sue Complicazioni (TazPod v2)

Per comprendere il valore del cambiamento, è utile analizzare come funzionava la gestione dei segreti fino a ieri. L'architettura del vecchio RAM Vault si basava su un flusso a tre stadi:

1. **Autenticazione via AWS SSO & S3**: L'operatore avviava il login per ottenere credenziali temporanee e scaricare l'archivio cifrato `vault.tar.aes`.
2. **Decrittazione su tmpfs**: La CLI Go invocava comandi `sudo` sull'host per creare un filesystem **tmpfs** montato su `/home/tazpod/secrets` e vi decrittava l'archivio, che poi veniva montato come *bind-mount* nel container.
3. **Sync Daemon**: Un servizio di background sincronizzava le modifiche locali dell'archivio crittografandolo e caricandolo nuovamente su S3.

> [!NOTE]
> **Tmpfs** è un filesystem Linux che memorizza i file direttamente nella memoria volatile (RAM) del sistema. Poiché non scrive sul disco rigido o sullo stato solido (SSD), i dati svaniscono completamente non appena il filesystem viene smontato o il server viene spento, prevenendo la persistenza accidentale di segreti a riposo.
>
> **Bind-mount** è un meccanismo che permette di mappare una directory esistente dell'albero dei file dell'host all'interno dello spazio dei nomi di un container, consentendo a host e container di condividere file in tempo reale con prestazioni native.

Questo approccio presentava gravi complicazioni di gestione dell'ambiente Docker:
* **Privilegi Elevati sull'Host**: Poiché il montaggio del tmpfs richiedeva `mount` e `umount`, la CLI TazPod doveva essere eseguita con permessi di `sudo` sull'host. Inoltre, il container Docker doveva essere avviato con la capability `--cap-add SYS_ADMIN` per gestire correttamente la propagazione dei mount, indebolendo l'isolamento del container dall'host.
* **Exit-Trap Hacks**: Per evitare che i segreti rimanessero montati in chiaro in RAM sull'host dopo l'uscita dell'utente, avevamo dovuto implementare un sistema complesso di trap in `.bashrc` all'interno del container. Questo script teneva traccia del conteggio delle shell attive e, alla chiusura dell'ultima istanza della shell, inviava un segnale all'host per smontare il tmpfs. Se il container veniva terminato in modo anomalo, i segreti potevano rimanere esposti in chiaro sul filesystem dell'host.
* **Sincronizzazione Concorrente**: Il demone di sincronizzazione S3 introduceva race condition quando più shell modificavano i segreti contemporaneamente, rischiando la sovrascrittura di credenziali importanti.

---

## La Preoccupazione di Sicurezza: Agenti IA e Blast Radius

Il limite più critico non era però di natura operativa, ma di **sicurezza**. 

Nel modello RAM Vault, lo sblocco era di tipo \"tutto o niente\". Una volta decrittato l'archivio in `/home/tazpod/secrets`, tutti i segreti del TazLab erano esposti in chiaro: API key di sviluppo, password dei database di produzione, credenziali cloud e persino la chiave privata offline della Root CA per la nostra infrastruttura PKI.

Con l'integrazione di agenti IA operanti in modo autonomo nel nostro ambiente di sviluppo per scrivere ed eseguire codice, questo modello è diventato insostenibile. Se un agente IA, eseguendo un'attività di ricerca o testing, fosse stato compromesso o avesse subito un attacco di *prompt injection* da una fonte esterna non fidata, avrebbe avuto accesso immediato e indiscriminato all'intero patrimonio di segreti del TazLab.

Era fondamentale trovare un modo per **sezionare i segreti** (partitioning) in base al loro livello di criticità, riducendo il raggio di impatto (*blast radius*) a un sottoinsieme limitato e richiedendo sblocchi espliciti e controllati.

---

## La Scelta degli Standard Linux: GPG e Gopass

Nel cercare un'alternativa, l'obiettivo è stato abbandonare codice custom e allinearsi agli standard del mondo Linux: la crittografia **GPG (GNU Privacy Guard)** e il modello di gestione basato su **pass** (il password manager standard di Linux basato su Git).

Durante la fase di ricerca, abbiamo valutato l'uso del classico `pass`, ma abbiamo riscontrato rischi significativi legati alla potenziale corruzione dei file in scenari di automazione e scrittura concorrente. `pass` gestisce ogni segreto come un singolo file cifrato all'interno di una struttura di cartelle tracciata con Git, e in caso di operazioni parallele veloci o comandi automatizzati da script, la sincronizzazione del repository può corrompersi o generare conflitti difficili da risolvere programmaticamente.

Abbiamo quindi scelto **gopass**, una riscrittura moderna di `pass` in Go. Gopass offre diversi vantaggi chiave:
1. **Robusta gestione delle transazioni Git**: Gestisce in modo nativo e sicuro l'automazione dei commit e dei push.
2. **Store multipli (Mounts)**: Consente di suddividere i segreti in sotto-store indipendenti (es. uno store per lo sviluppo, uno per la produzione, uno per le chiavi infrastrutturali).
3. **Crittografia basata su GPG standard**: Ogni segreto è cifrato singolarmente per uno o più destinatari identificati dalle loro chiavi GPG pubbliche.

Grazie a questa flessibilità, abbiamo potuto implementare una sicurezza sezionata:
* **Segreti Standard**: Cifrati con chiavi GPG i cui agenti di sblocco mantengono le passphrase in cache per brevi periodi.
* **Segreti Altamente Critici (come la Root CA)**: Cifrati con chiavi GPG offline o protette da passphrase dedicate, escluse dagli store standard montati quotidianamente.

---

## Il Nuovo Design a Privilegi Zero

Con la migrazione a gopass, la CLI TazPod è stata completamente riscritta in Go per eliminare tutto il codice legacy relativo a S3, AWS SSO, crittografia AES e logiche di mount del filesystem.

### 1. Eliminazione delle Capability Elevate
Non dovendo più montare filesystem tmpfs sull'host, TazPod non richiede più l'esecuzione di comandi con `sudo`. Inoltre, in fase di creazione del container Docker, abbiamo eliminato la capability `--cap-add SYS_ADMIN`. Il container ora gira esclusivamente con `--cap-add NET_ADMIN` (necessario unicamente per la scheda di rete virtuale di Tailscale), riducendo drasticamente i privilegi del container sul sistema host.

### 2. Comando `tazpod gopass`
Il setup dello store avviene ora interamente all'interno del container tramite il comando `tazpod gopass`. Questo comando:
1. Esegue la scansione dei file `.asc` nella cartella `/workspace/tazlab-secrets/gpg-keys/` e importa le chiavi GPG pubbliche e private nel portachiavi locale del container.
2. Configura gopass impostando il percorso locale dello store.
3. Crea un collegamento simbolico (*symlink*) in `~/.local/share/gopass/stores/root` puntando direttamente alla cartella versionata `/workspace/tazlab-secrets`.

### 3. Caching Sicuro in RAM e Allineamento TTY
La decrittazione dei segreti non avviene più su un intero filesystem esposto, ma viene delegata a `gpg-agent` in modo puntuale.
Nelle configurazioni di `.tazpod/Dockerfile.base` abbiamo impostato i parametri di caching dell'agente:

```dockerfile
RUN mkdir -p /home/tazpod/.gnupg && \
    echo "default-cache-ttl 3600" > /home/tazpod/.gnupg/gpg-agent.conf && \
    echo "max-cache-ttl 604800" >> /home/tazpod/.gnupg/gpg-agent.conf && \
    echo "trust-model always" > /home/tazpod/.gnupg/gpg.conf
```

> [!TIP]
> `default-cache-ttl 3600` indica che la passphrase di GPG rimane memorizzata in cache nella RAM del demone per 1 ora, e il timer si resetta ad ogni operazione di lettura del segreto. `max-cache-ttl 604800` (7 giorni) impone un limite assoluto di scadenza oltre il quale è obbligatorio reinserire la passphrase.

Per risolvere i problemi di blocco dell'interfaccia di inserimento password (*pinentry*) quando si utilizzano shell parallele o pannelli TMUX multipli all'interno del container, abbiamo aggiunto all'avvio della shell in `.bashrc` il comando di allineamento TTY:

```bash
if [ -t 0 ]; then export GPG_TTY=$(tty); fi
gpgconf --launch gpg-agent >/dev/null 2>&1
gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1
```

Il comando `updatestartuptty` comunica dinamicamente al demone `gpg-agent` in esecuzione in background quale sia la TTY della shell correntemente attiva, garantendo che la schermata interattiva di pinentry per la passphrase appaia sul terminale in cui l'utente sta effettivamente digitando.

Per chiudere istantaneamente lo store e rimuovere le chiavi decifrate dalla RAM, l'operatore può lanciare il comando `tazpod lock`, che esegue:

```go
gpgconf --kill gpg-agent
```

---

## LXC e Hetzner Vault: Semplificazione del Provisioning

I benefici della migrazione si sono propagati immediatamente all'infrastruttura di provisioning gestita con Ansible.

Precedentemente, la creazione di nodi storage LXC su Proxmox o la convergenza del runtime Vault su server Hetzner dipendevano dalla presenza di file di credenziali decrittati localmente sul filesystem dell'operatore (sotto `~/secrets/`). Questo creava disallineamenti se l'operatore dimenticava di sbloccare il vault o se i file venivano rimossi.

Abbiamo riscritto i playbook Ansible e gli script di orchestrazione (`create.sh` e `stage-prelude.yml`) per interagire direttamente con gopass:
* **Zero File su Disco**: Le chiavi SSH, i token API e le credenziali di inizializzazione vengono estratti da gopass in memoria e inviati direttamente tramite stream SSH o variabili d'ambiente.
* **Bootstrapping Pulito**: In `stage-converge.yml` per Hetzner Vault, l'inizializzazione del Vault (chiavi di unseal e root token) viene generata in memoria sul server e inserita direttamente in gopass tramite `gopass insert -f`, senza che alcuna credenziale in chiaro tocchi mai il disco locale dell'operatore.

---

## Conclusioni: Lezioni di Semplicità Architetturale

La migrazione da un'architettura custom basata su RAM Vault a un sistema basato su gopass e GPG ha dimostrato tre principi cardine:

1. **Non inventare la ruota**: I sistemi crittografici standard di Linux (`gpg`, `gpg-agent`, `pass`) hanno risolto i problemi di caching e gestione delle TTY da decenni. Utilizzare questi strumenti riduce drasticamente le righe di codice custom da manutenere nella CLI.
2. **Sicurezza a Privilegi Zero**: Rimuovere il requisito di `SYS_ADMIN` e `sudo` all'interno dei nostri ambienti di lavoro isola maggiormente l'host di sviluppo, riducendo l'impatto di un'eventuale vulnerabilità nel container.
3. **Prepararsi agli Agenti IA**: Configurare i sistemi assumendo che l'utente del terminale possa essere un agente IA (e quindi limitando il blast radius attraverso segreti sezionati e sblocchi mirati) non solo protegge da attacchi futuri, ma costringe a implementare un design pulito ed elegante che va a beneficio anche degli operatori umani.
