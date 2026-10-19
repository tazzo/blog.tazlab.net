+++
title = "Multica: come ho integrato un piano di controllo per agenti nel laboratorio, e cosa ne penso dopo l'uso"
date = 2026-10-03T05:00:00+02:00
draft = false
description = "Le scelte con cui ho portato Multica dentro il laboratorio — il cluster condiviso, l'identità a certificato, i segreti da Vault, le patch al chart, il daemon su CT106 e la squadra di agenti dichiarata in Git — e la mia valutazione dopo averlo usato per davvero."
tags = ["multica", "agenti", "orchestrazione", "kubernetes", "gitops", "flux", "vault", "mtls", "postgresql", "devops"]
author = "Tazzo"
+++

## Da dove parte questo articolo

Nell'articolo precedente ho raccontato il tentativo con Paperclip. Il problema che avevo non era il numero di agenti: era non sapere **chi stava lavorando a cosa**, e non poter rileggere le decisioni prese mentre lavoravano. Paperclip rispondeva alla domanda con un modello che non mi serviva: un task era un processo da ricordare, non un oggetto che assegni, vedi in una tabella e che ti restituisce un commento con l'esito.

Con Multica ho provato la stessa cosa con uno strumento diverso. Questo articolo racconta quali scelte ho fatto per portarlo dentro il laboratorio e, alla fine, cosa ne penso dopo averlo usato per un periodo. Il progetto è su [github.com/multica-ai/multica](https://github.com/multica-ai/multica).

## Che cosa è Multica, in breve

Multica non fornisce modelli: usa gli **agenti già installati** sulla macchina. Tu assegni un task a un agente come assegneresti un lavoro a una persona, e l'agente lo esegue su una macchina che controlli, scrivendo commenti mentre lavora.

Si divide in due parti, e per il laboratorio è stato importante tenerle separate perché hanno due cicli di vita diversi:

| Parte | Dove | Chi la gestisce |
|---|---|---|
| Piano di controllo (backend in Go, interfaccia in Next.js, PostgreSQL) | cluster `tazlab-k8s`, namespace `multica` | Flux, Vault/VSO, Terraform |
| Daemon (il processo che esegue gli agenti) | CT106, unità systemd `multica-daemon.service` | layer Ansible basato su Git |

Il daemon cerca gli agenti installati nel `PATH`, registra **un runtime per ogni agente trovato** e prepara una cartella di lavoro separata per ogni esecuzione.

Un dettaglio che è bene sapere subito: **il daemon non isola gli agenti**. La documentazione dichiara che il confine di sicurezza è l'utente di sistema, quindi gli agenti girano con i permessi di `tazpod`, esattamente come quelli che avvio a mano. L'unico confine di sicurezza del laboratorio resta il container: è per questo che il daemon sta su CT106, dove gli agenti e le loro credenziali ci sono già.

## Le scelte di integrazione

Questa è la parte che conta, e la racconto una decisione per volta: quale alternativa avevo, cosa ho scelto e perché.

### 1. Dove far girare il piano di controllo: Kubernetes

Avevo tre strade: il cluster Kubernetes (dove girano già le altre applicazioni del laboratorio), Docker Compose su CT100 (è il percorso suggerito dal progetto), oppure una macchina virtuale dedicata.

Ho scelto Kubernetes perché il percorso di un'applicazione in questo cluster è già scritto: c'è una cartella per ogni applicazione, un overlay, una voce in Flux, e i segreti passano già da Vault. Le altre due strade sembrano più semplici, ma ognuna porta con sé una seconda catena da mantenere: con Docker Compose avrei dovuto costruire da zero l'esposizione privata e il secondo backup del database; con una macchina virtuale avrei dovuto riservare memoria che oggi condivido. Non è una scelta ideologica: è la strada con meno cose nuove da inventare.

### 2. Il database: il cluster condiviso, non uno dedicato

Multica vuole PostgreSQL 17, e il cluster condiviso `tazlab-db` era ancora alla 16. La raccomandazione iniziale era quindi un secondo cluster dedicato, e l'unico motivo era la versione.

Quella raccomandazione è durata un giorno: il cluster condiviso è passato a **PostgreSQL 17.2** con la procedura dichiarativa di PGO (l'ho raccontata nell'articolo precedente). Da lì la scelta più economica era usare il database che c'è già: un solo database da salvare, una sola catena di backup su S3, gli stessi certificati. Un secondo cluster avrebbe significato due backup e due cose da aggiornare, per un'applicazione che ha un frontend e un backend.

### 3. L'autenticazione: un certificato al posto della password

Questa è la scelta di cui sono più convinto.

In PostgreSQL le regole di accesso stanno nel file `pg_hba.conf` e vengono lette dall'alto verso il basso: vale la **prima riga che corrisponde**. Un dettaglio importante: usare l'autenticazione a certificato non chiude da solo la strada della password. Se il ruolo ha una password e più in basso restano le righe generiche che accettano `md5` per quell'indirizzo, il ruolo entra anche in chiaro. Il controllo sembra esserci e non c'è.

Per il ruolo `multica` ho quindi scritto quattro righe, **sopra** quelle generiche:

```
hostssl multica multica 0.0.0.0/0 cert
hostssl multica multica ::/0      cert
host    all     multica 0.0.0.0/0 reject
host    all     multica ::/0      reject
```

Le prime due accettano il certificato, le altre due impediscono che la stessa identità rientri dalla porta della password. L'identità la porta il certificato emesso dalla PKI di Vault, e il nome nel certificato (*Common Name*) deve corrispondere al nome del ruolo.

Perché rinuncio alla password: in questo laboratorio il momento critico è quando **distruggo e ricreo il cluster**. Con una password, dopo una ricostruzione il valore nel Secret non esiste più e devo ricomporlo e riallinearlo a mano; con il certificato non c'è nessun valore da conservare, perché Vault lo **riemette**. È lo stesso schema che usano già `hindsight` e `mnemosyne`; `paperclip` invece usa ancora la password, ed è la differenza nota nel laboratorio.

### 4. I segreti: Vault, con una voce fatta in un modo preciso

Il chart di Multica **cita** un Secret chiamato `multica-secrets` ma non lo crea: dice esplicitamente che i valori veri non devono finire in Git. È proprio quello che serve per usare Vault.

Qui ho trovato due condizioni da rispettare. La prima: un `VaultStaticSecret` legge **una sola voce** di Vault, e le chiavi del Secret diventano i **campi** di quella voce. La convenzione del laboratorio è un percorso per chiave con un solo campo `value`; se l'avessi usata, il Secret avrebbe avuto una sola chiave e il backend non sarebbe partito. Ho quindi scritto **una voce con sette campi** (`JWT_SECRET`, `DATABASE_URL`, `MULTICA_VCS_SECRET_KEY` e quattro opzionali). La seconda: il `VaultAuth` ha un **elenco di namespace autorizzati**, e un namespace nuovo va aggiunto, altrimenti il Secret non viene consegnato e l'applicazione parte senza le chiavi — un guasto che si scopre leggendo i log di un pod che non capisce perché non parte.

### 5. Il chart è rigido: quattro patch dichiarate in Git

Il chart non copre tutto quello che serviva: il tipo di Service è fisso, non c'è un punto per montare i certificati, manca la porta delle metriche e il frontend non ha sonde. Non ho fatto un fork: ho scritto **quattro patch sul manifest che Helm genera** (`postRenderers`), dichiarate in Git, che aggiungono il Service esterno, la porta delle metriche, il volume dei certificati e le sonde. Il prezzo è che quelle patch sono legate alla versione del chart: quando la versione cambia vanno ricontrollate.

### 6. Il daemon: un processo utente su CT106, con il binario fissato

Il daemon non è un container: è un eseguibile installato in `/usr/local/bin/multica`, fermo alla versione 0.5.3 e verificato con il checksum della release, più un'unità systemd gestita dal layer Ansible del laboratorio.

Sta su CT106 perché è lì che gli agenti e le loro credenziali vivono già. E il binario è fissato con il checksum perché l'aggiornamento automatico non mi serve: preferisco sostituirlo io, con il layer, così so sempre quale versione sta girando.

### 7. Gli agenti: la squadra dichiarata in Git

La squadra non si crea a mano nell'interfaccia: sta in un file nel repository (`configs/multica-team/roster.yml`) e viene applicata da uno script che non cancella niente e non contiene segreti. La conseguenza pratica è che la squadra **si ricostruisce dal repository**, senza dover ripristinare il database.

Sono dodici agenti, uno per ruolo: chi scrive gli articoli, chi tocca il cluster, chi firma il rilascio, chi si occupa della documentazione, e così via. Ognuno ha il suo runtime e il suo modello.

### 8. L'esposizione: una sola superficie

Il progetto prevedeva due superfici esposte (interfaccia e API), perché un client di casa o in VPN non è nella tailnet. Studiando il chart ho visto che l'interfaccia Next.js è un **proxy**: inoltra le chiamate al backend (`/v1`, `/api`, `/auth`, `/uploads`, `/ws`) restando sullo stesso indirizzo. Quindi il browser parla solo con l'interfaccia: una superficie sola e nessun problema di CORS.

Non ho messo un Ingress, per un fatto verificato: il DNS del dominio del laboratorio punta con un wildcard all'indirizzo pubblico e Traefik risponde dall'esterno, quindi un nome di dominio pubblicherebbe la dashboard su Internet. L'accesso è un Service `LoadBalancer` sull'indirizzo condiviso di MetalLB, `192.168.1.240:3000`, raggiungibile dalla rete di casa e in VPN.

## Gli errori: pochi, e di esecuzione

Il progetto è filato senza sorprese sulle decisioni. Gli errori che ci sono stati riguardano l'esecuzione, non le scelte, e alcuni li ha fatti l'agente che scriveva i manifest. Li elenco in breve perché non meritano spazio:

- i bersagli delle patch erano scritti con il nome sbagliato (`multica-backend` invece di `multica-multica-backend`, perché il nome generato porta davanti il nome della release), quindi il volume dei certificati non è mai stato montato e il backend è andato in ciclo di riavvio;
- il segnaposto per l'aggiornamento automatico delle immagini era stato messo sul campo sbagliato, e i pod rifiutavano il nome dell'immagine;
- l'installazione è rimasta bloccata due volte perché una release Helm non rilegge la sua configurazione finché l'operazione precedente non è finita: l'ho sbloccata a mano.

Di questi tre casi vale la pena tenere una cosa: **una patch che non trova il suo bersaglio non dà errore, semplicemente non fa niente.** La riconciliazione era verde, i pod erano vivi, e il difetto si è visto solo leggendo il log di un pod. Per questo adesso, quando cambio versione del chart, guardo il manifest generato prima di applicarlo.

## Due cose che il progetto non aveva previsto

Qui c'è la parte che mi ha insegnato di più, e riguarda ciò che serve perché il sistema funzioni, non ciò che il sistema fa.

**La chiave del modello per gli agenti.** Un'unità systemd non eredita l'ambiente della shell: senza la chiave del provider scritta nell'unità, il primo task assegnato sarebbe morto subito, con un errore che sembra un difetto dell'agente. L'ho visto prima di lanciare la prova, controllando l'ambiente degli agenti installati sulla macchina, e ho messo la chiave nell'unità: non nell'ambiente dell'agente configurato nel piano di controllo, perché l'avrebbe copiata nel database di Multica.

**La cartella di lavoro.** Il daemon registra un runtime per ogni cartella di lavoro che vede, e un account appena creato non ne ha nessuna: il risultato era zero runtime. Non è un errore di configurazione, è una cosa che non è scritta da nessuna parte: creata la cartella, i runtime sono comparsi.

Aggiungo una trappola che mi è costata tempo di lettura: `MULTICA_TOKEN` **non è la credenziale del daemon**, è il token che il daemon passa all'agente per il singolo task; la credenziale vera sta solo nel file `~/.multica/config.json`, quello scritto dal comando `multica login`. Non l'ho imparato dalla documentazione, ma leggendo il codice dell'applicazione da riga di comando.

La lezione, valida per ogni pezzo che si aggiunge (un daemon, un chart, un'unità systemd), è che nel piano va scritto anche **con quale credenziale, in quale file e con quale prerequisito** il pezzo funziona. Il progetto aveva verificato bene cosa il sistema fa, e non cosa gli serve per farlo.

## Cosa ho verificato

- Il piano di controllo risponde: `curl http://192.168.1.240:3000/` restituisce 200 dall'indirizzo condiviso.
- L'autenticazione a certificato funziona davvero, e la prova non è che il pod sia vivo: il backend esegue le migrazioni con `sslmode=verify-full`, quindi se il certificato non fosse valido non si connetterebbe affatto.
- Il daemon è attivo e registra gli agenti trovati sulla macchina.
- La prova che conta: un task assegnato all'agente del laboratorio è stato **completato in 29 secondi**, e il commento conteneva l'output reale dei comandi eseguiti.

## Cosa resta aperto

- **La prova di ricostruzione.** Non ho ancora distrutto e ricreato il cluster. Finché non lo faccio, "torna su senza interventi a mano" resta un'attesa, non un fatto verificato. È anche la prova che l'identità a certificato conviene.
- **La copia delle immagini su Docker Hub.** I repository `tazzo/tazlab-multica-*` rispondono 404, quindi i due `ImageRepository` puntano all'originale su GHCR.
- **Il disco degli allegati non ha un backup ricorrente.** L'ho accettato come debito: il laboratorio non ha ancora un backup Longhorn dichiarato in Git e non ho voluto introdurre il primo qui.
- **Gli elenchi degli indirizzi autorizzati sono vuoti.** Scriverli prima di sapere da quale indirizzo sarei entrato avrebbe potuto chiudermi fuori.

## Le mie considerazioni, dopo averlo usato

Multica non ha fallito: è il tentativo più riuscito dei tre che ho provato. Due cose le fa meglio degli altri due.

La prima sono le **regole di orchestrazione scritte**: un agente che riceve un task non improvvisa, perché lo stato, le fasi, il formato del commento e i confini sono definiti prima e valgono per tutti. Quando un agente sbaglia, posso rileggere la regola che avrebbe dovuto seguire, invece di discutere su cosa intendesse. La seconda è l'**identità a certificato**: se la chiave non c'è, la connessione non si apre, e non c'è nessuna password da far girare.

Il problema è un altro, e riguarda la lettura. Multica **scrive molto e scrive bene**: ogni esecuzione lascia task, commenti firmati e una cronologia completa. Ma la quantità è più di quella che riesco a leggere. Dopo una sessione di lavoro, per sapere **chi è fermo** devo aprire la tabella e ricostruire la situazione a mano. Non c'è un punto dove leggo cosa sta facendo ogni agente in questo momento: ho un resoconto completo di quello che è successo, ma non un colpo d'occhio su quello che sta succedendo.

Il problema si è visto nell'uso quotidiano, e l'ho misurato sui commenti veri: 3.057, 3.257 e 2.630 caratteri, contro un limite di circa 800 che avevamo scritto, con la decisione da prendere messa nell'ultima riga. Dopo la prima correzione il blocco delle richieste è finito a metà messaggio, con altro testo da leggere sotto. Nello stesso periodo un agente che aveva finito il suo lavoro **si è fermato invece di aprire il compito successivo**: ha scritto «dimmi la parola e lo apro», e la catena è ripartita solo perché l'ho detto io. Nessuno dei due è un difetto dello strumento: sono io che scrivo le istruzioni e che verifico. Ma è il costo che Multica mi fa pagare ogni giorno, e non è un costo di installazione.

Le condizioni con cui l'ho tenuto sono tre: il resoconto deve diventare più leggibile, cioè deve dire chi è fermo adesso e non solo cosa è successo; il volume deve scendere, perché un resoconto che non riesco a leggere non mi serve; le regole scritte restano il riferimento anche per gli altri tentativi, perché quella parte mi serve comunque.

Poi il tempo ha deciso: il 1° ottobre ho svuotato l'ambiente di lavoro (49 task chiusi, 6 annullati con il motivo, nessuno aperto) e ho congelato il progetto. La piattaforma è attiva, ma il lavoro è passato al motore che stavo scrivendo io. E restano due cose che Multica lascia dietro, e che riassumono il problema: un controllo sulle metriche che non seleziona niente — l'applicazione c'è, è in salute, e **nessuno la sta guardando** — e il disco degli allegati senza un backup ricorrente. Nessuna delle due dà un errore: si vedono solo se qualcuno guarda.

## Conclusioni

La lezione che porto via non riguarda Multica:

> Un progetto verifica bene **cosa** il sistema fa, e non **cosa gli serve** per farlo.

Database, autenticazione, esposizione e immagini: decisioni prese bene e realizzate senza sorprese. Le quattro cose che hanno fatto perdere tempo — i nomi degli oggetti generati dal chart, il segnaposto dell'automazione sul campo sbagliato, la chiave per gli agenti, la cartella di lavoro — erano tutte fuori dal progetto: erano domande che nessuno aveva fatto. Da qui tre abitudini.

**Controllare prima di salvare nel repository.** Il layer l'ho applicato due volte e la seconda non ha cambiato niente; la prova end-to-end l'ho eseguita dopo aver controllato l'ambiente, non prima.

**Guardare il risultato, non solo l'esito.** Una patch che non trova il suo bersaglio non fallisce: non fa niente. Per questo, quando cambio versione del chart, controllo il manifest generato.

**Dichiarare le eccezioni.** Le tre di questo progetto sono dichiarate, e l'unica accettata con una condizione (la voce in Vault, perché nessun oggetto in Git può scriverla) regge proprio grazie al resto. Un'eccezione dichiarata è una scelta; una scoperta sei mesi dopo è un incidente.
