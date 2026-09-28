+++
title = "Troppi Agenti per tmux: Paperclip e il Container Dedicato"
date = 2026-09-24T21:35:00+02:00
draft = false
description = "Cronaca tecnica di un esperimento con un orchestratore di agenti: perché tmux non basta più, come ho costruito un container dedicato con un confine di sicurezza verificabile, gli errori diagnosticati lungo il percorso — e il verdetto: interessante, ma troppo astratto per come voglio gestire l'ambiente."
tags = ["paperclip", "agenti", "orchestrazione", "lxc", "proxmox", "sicurezza"]
author = "Tazzo"
+++

## Il problema non è il numero di agenti

Il problema non è mai stato la quantità di agenti: è la mappa. Lavoro con cinque o sei sessioni aperte su aspetti diversi dello stesso problema — una scrive un manifest, una indaga un errore, una aggiorna la documentazione. Il lavoro procede, ma a un certo punto ci si accorge di dover cercare *in quale finestra* si stava facendo quella determinata cosa. Ogni cambio di sessione costa la ricostruzione del contesto da capo.

Da qui nasce l'interesse per gli **orchestratori di agenti**: strumenti che non si limitano a lanciare processi, ma mantengono un modello esplicito di chi lavora a cosa, con quale ruolo e quale risultato atteso. Paperclip è il primo che ho provato: questo articolo documenta cosa ho costruito, quali problemi ho incontrato e perché non sono convinto che sia il modo in cui voglio gestire l'ambiente.

## Paperclip: cosa promette, e in quale infrastruttura entra

Paperclip è una piattaforma web per gestire una "compagnia" di agenti: una board con issue, agenti con ruoli, progetti, budget e heartbeat periodici. L'infrastruttura in cui l'ho inserita non è banale: host Proxmox, cluster Talos con GitOps su Flux, database PostgreSQL gestito fuori dal container. La prima scelta è stata quindi di non usare il database embedded (SQLite) che la piattaforma porta con sé, e di collegarla al PostgreSQL del cluster: lo stato della compagnia non doveva vivere in un file dentro un container ricostruibile.

Le alternative sono state valutate esplicitamente. Continuare con **tmux** non costava nulla e non risolveva il problema della mappa. Scrivere un wrapper artigianale significava costruire da zero anche il modello di chi lavora a cosa. Un orchestratore esistente ne porta con sé uno già pensato: molte parti sono pronte, ma si accettano scelte che non sono le mie — il vantaggio e il rischio insieme, perché si adotta un modo di lavorare, non soltanto uno strumento.

## Il modo convenzionale era sbagliato per lo scopo

La prima installazione ha seguito la forma che avrei dato a qualunque servizio: account di servizio dedicato, repository in sola lettura, nessuna credenziale nelle mani del processo. È la forma corretta in azienda; qui era sbagliata, e l'ho riconosciuto osservandone le conseguenze.

Paperclip esiste in questo laboratorio per sostituire gli agenti che oggi girano in tmux. Quelli non sono spettatori: scrivono nei repository, eseguono push con le credenziali fornite dal gestore dei segreti, usano le chiavi SSH dell'operatore. Ho quindi spostato il servizio a girare **come l'operatore**, guadagnando funzionalità e perdendo una separazione che avrei voluto mantenere: è la tensione che attraversa tutto il percorso.

## Le trappole della piattaforma

L'installazione si è fermata tre volte, sempre nello stesso modo: io facevo quello che avevo in mente e il sistema rispondeva qualcosa che non c'entrava con quello che avevo chiesto.

**Il primo agente non si poteva creare dall'interfaccia.** Volevo un agente che usasse il modello che uso già, quello servito da OpenCode: è la CLI che conosco e che su questa macchina è già configurata. Il wizard di onboarding però offriva solo due famiglie di modelli, Claude e Codex, e il suo test di connessione non poteva passare, perché quelle due CLI qui non sono installate: nessuna delle scelte proposte era utilizzabile. Ho verificato allora cosa contiene davvero il pacchetto installato — conosce più di tredici tipi di adattatore, incluso quello che mi serviva. Il wizard è più stretto del prodotto che installa, e la conseguenza pratica è che gli agenti li ho creati da riga di comando, non dalla board.

**L'identificatore del modello deve essere qualificato dal provider**, nella forma `provider/modello`. Scritto nudo, il salvataggio riesce senza un avviso e il fallimento arriva alla prima esecuzione, quando l'agente prova a partire. Il costo è tutto in diagnosi: la configurazione risultava salvata e il modello esisteva, quindi non c'era modo di accorgersene prima di provare.

**I token della CLI sono memorizzati per endpoint.** Il login era riuscito; il comando successivo rispondeva `401`. Non erano le credenziali: il token era stato salvato per una specifica API base, e quel comando ne interrogava un'altra, quindi per il server non ero autenticato. L'opzione va ripetuta a ogni invocazione, e senza di essa l'errore arriva come un permesso negato.

Nessuno dei tre era grave, e in tutti e tre i casi l'operazione è stata accettata senza errori: il problema è comparso dopo, alla prima esecuzione dell'agente o al comando successivo.

## La compagnia costruita dalla ricerca

Prima di creare un solo agente ho svolto due ricerche: una sul payload installato, per stabilire cosa la piattaforma supporta davvero, e una su quindici fonti primarie di design multi-agente, fra cui il saggio dissenziente di Cognition, *Don't Build Multi-Agents*. Il consenso è convergente: due livelli al massimo, da tre a cinque riporti diretti, un solo scrittore per artefatto, un revisore in sola lettura che non è mai l'autore, cancelli umani sulle azioni irreversibili, budget per agente.

Due dettagli contano più di quanto sembri: solo il ruolo `ceo` riceve un pacchetto di istruzioni dedicato, mentre ogni altro ruolo eredita un `AGENTS.md` generico; e gli agenti non hanno appartenenza ai progetti, perché `reportsTo` e il lead sono gli unici legami strutturali.

## Il pivot: un container dedicato

Fino a quel momento Paperclip e i suoi agenti giravano nello stesso container in cui lavoro io, sugli stessi checkout, con le mie chiavi e le mie credenziali. È la condizione in cui girano anche gli agenti che lancio a mano in tmux, e finché li lancio io non è un problema: so cosa ho chiesto e guardo cosa succede.

Con un orchestratore la situazione cambia. Gli agenti partono da soli, più di uno alla volta, su heartbeat o su assegnazione, e lavorano su un albero di lavoro che la run successiva si aspetterà di trovare com'era. Il caso che mi ha fatto decidere non è l'agente che sbaglia: è l'agente che lascia qualcosa dietro di sé — un hook, una configurazione, un commit — in un repository che poi tratto come mio. In quella configurazione nulla separava ciò che una run scrive da ciò che la run successiva legge.

Volevo quindi tre cose, e le ho scritte come requisiti prima di decidere come ottenerle: gli agenti **fuori** dal container in cui lavoro, in un ospite separato e sacrificabile; lo stato della compagnia su qualcosa che sopravvive a un container ricreato; e un confine **verificabile**, non una convenzione. Da qui il container dedicato, separato da quello operatore.

Ho valutato anche di sostituire i container con una macchina virtuale, e i numeri hanno prodotto un risultato controintuitivo: una VM impegna la memoria, mentre un container la condivide, e in questo host la memoria è la risorsa scarsa. Una VM offre comodità — dispositivo di rete, credenziali di sistema, Docker interno — non sicurezza aggiuntiva: il kernel è condiviso in entrambi i casi, e ciò che cambia è il raggio di un'eventuale evasione. La separazione che conta è un ospite per dominio di fiducia, ed è quella che ho mantenuto.

**Un volume dati persistente.** Il container è sacrificabile, il volume no: il disco che contiene lo stato dell'istanza — la chiave che cifra i segreti nel database, la configurazione, i log delle run — è un volume separato, e la procedura di distruzione lo stacca prima di eliminare il container, così che Proxmox non lo cancelli insieme al resto; chi ricrea il container lo riattacca per nome: ricreare il container non significa perdere lo stato dell'istanza.

**Un archivio di segreti con ambito ristretto.** L'agente dispone del proprio archivio, cifrato con la propria chiave, in sola lettura, contenente soltanto i segreti che gli servono. La chiave non ha passphrase, perché un servizio che parte da solo non può digitarla: ciò che protegge l'archivio non è la chiave ma l'ambito. Un test automatico all'avvio verifica che le voci dell'operatore non siano leggibili da lì, e se fallisce il servizio non parte.

**Il chokepoint.** È il componente centrale del progetto, e non è una funzione di Paperclip: risponde al problema di concedere a un agente l'accesso a servizi esterni senza consegnargli le credenziali.

## Come funziona il chokepoint

Un proxy locale ([mitmproxy](https://mitmproxy.org/)) ascolta su `127.0.0.1:3128` all'interno del container, e l'ambiente dell'agente è configurato perché tutto il traffico HTTP e HTTPS passi da lì. Il proxy non è un passaggio trasparente: consulta una lista di destinazioni ammesse e, per alcune, inietta la credenziale al posto dell'agente. Il token di push verso GitHub e quello dell'API di virtualizzazione non esistono nell'ambiente dell'agente: esistono soltanto nella memoria del proxy, che li aggiunge alla richiesta uscente e rimuove l'header di autorizzazione inviato dal client.

Il secondo elemento è il filtro di pacchetto, ed è ciò che trasforma il proxy da convenzione a confine:

```bash
# Solo l'uid del proxy esce. L'uid dell'agente no.
meta skuid 0 accept                 # root: identità dell'operatore, non dell'agente
meta skuid <uid-del-proxy> accept
ct state established,related accept
counter drop                        # tutto il resto
```

L'agente non dispone di root né di sudo, quindi non può assumere l'identità autorizzata a uscire; il test di accettazione è di tipo negativo e verifica proprio questo. Il terzo elemento è la conseguenza del secondo: se il proxy è spento, l'agente non ha vie d'uscita. Non degrada in "agente che raggiunge internet direttamente", ma in "le chiamate dell'agente falliscono": è il significato di *fail-closed*, e richiede che il confine risieda nel kernel.

## Gli errori che hanno insegnato qualcosa

**Il sigillo che blocca la propria riparazione.** L'archivio dell'agente è in sola lettura per scelta: l'agente deve poter leggere le proprie credenziali, non scriverle, e il flag che sigilla l'archivio viene applicato alla fine del provisioning. Il passo che copia i segreti considera da riparare una voce mancante **o vuota**, così che un secondo giro corregga un valore rimasto vuoto invece di ereditarlo; ma al secondo giro l'archivio è già sigillato, e l'inserimento muore sul sigillo stesso: `writing to agent is disabled by core.readonly`. La correzione è dissigillare per la durata della scrittura e risigillare subito dopo. Il passo resta idempotente perché agisce solo quando c'è davvero una voce da scrivere, e riscrive il flag solo se il valore corrente è diverso da quello atteso.

**Le credenziali di systemd non sono disponibili in un container non privilegiato.** La scelta iniziale era di passare la chiave al servizio come credenziale di [systemd](https://systemd.io/CREDENTIALS/): un file di sola lettura, verificato a ogni lettura, non ereditato dai processi figli. In questo container il servizio non partiva. La diagnosi è stata costruita con una unit temporanea, con una sola direttiva e un consumatore banale:

```bash
LoadCredential=probe:/etc/hostname
ExecStart=/bin/sh -c 'wc -c < $CREDENTIALS_DIRECTORY/probe'
# → Failed to set up credentials: Protocol error
#   Main process exited, status=243/CREDENTIALS
```

Il file esisteva e il consumatore era elementare: la causa era l'ambiente, non la configurazione. Da lì la scelta di consegnare la chiave come percorso, con il vincolo di fail-closed mantenuto.

**apt non scarica come root.** Il filtro che avevo scritto lasciava uscire root e dichiarava in un commento che questo fosse sufficiente al funzionamento di apt. È falso: apt delega i download all'utente sandbox `_apt`, quindi il socket che esce dal container appartiene a quell'utente, e la regola per root non lo copriva. Il sintomo era un provisioning fermo da venti minuti, senza una riga di errore. La causa è emersa leggendo il contatore dei pacchetti scartati nel regolamento del filtro, che aveva superato le mille unità: quel contatore è il primo elemento da esaminare quando la rete "non funziona".

**Il valore del token conteneva il token.** Il token dell'agente verso l'API di virtualizzazione rispondeva `401` su ogni chiamata. Ho isolato il problema creando un token di prova sullo stesso utente tramite API: rispondeva `200`. Utente, header e separazione dei privilegi erano corretti; restava il valore, ed era errato perché il provider restituisce la coppia `<identificativo>=<segreto>`: consegnavo al proxy una stringa con l'identificativo due volte. Un `401` che sembrava un problema di permessi era un problema di formato, e l'isolamento per differenza è ciò che l'ha reso visibile.

**L'archivio svuotato due volte, e recuperato dalla storia.** A un certo punto tutte le credenziali della compagnia nell'archivio dell'operatore sono risultate vuote, con una firma inconfondibile: un valore vuoto viene memorizzato come allegato senza corpo, quindi la lettura risponde "nessuna password" invece di fallire. Le ho recuperate dalla storia git dell'archivio, e le lunghezze coincidevano con quelle originali: il repository versionato è anche l'unica copia di sicurezza dell'archivio.

## Il verdetto: troppo astratto

Paperclip è interessante e in certe situazioni è utile: una board reale, ruoli reali, budget, heartbeat. Non sono però convinto che sia il modo in cui voglio gestire l'ambiente, e la ragione è precisa: è troppo astratto, troppo lontano dal comprendere cosa stia accadendo e quali decisioni vengano prese. All'accensione aveva già svolto attività: alcune corrette, altre delle quali non sono convinto. Il problema non è che sbagli, ma che il suo ragionamento non è visibile, e quindi non è correggibile prima che produca effetti.

Continuerò a provarlo, e proverò anche altri strumenti dello stesso tipo: il prossimo sarà Multica. La domanda che sto cercando di risolvere non riguarda un prodotto specifico, ma quale strumento permetta di mantenere molti agenti su aspetti diversi dello stesso problema senza perdere la mappa e senza perdere la visibilità sulle decisioni.

## Conclusioni: cosa resta anche se lo strumento non basta

Due considerazioni restano valide indipendentemente da quale orchestratore verrà adottato.

Il confine di sicurezza è trasferibile. Mantenere le credenziali fuori dal confine, iniettarle al margine, limitare l'uscita per identità e fallire in modo chiuso non dipende dallo strumento: è un pattern costruito attorno a Paperclip e riutilizzabile con il prossimo.

Quasi tutti i difetti descritti sono emersi alla prima esecuzione reale: la revisione del codice li aveva lasciati passare.

Se si sta valutando un orchestratore di agenti, la domanda che suggerisco non è quanti agenti sia in grado di gestire, ma cosa faccia vedere e chi decida. Nel mio caso l'astrazione ha tolto quello che mi serviva davvero: capire cosa stava facendo e perché.
