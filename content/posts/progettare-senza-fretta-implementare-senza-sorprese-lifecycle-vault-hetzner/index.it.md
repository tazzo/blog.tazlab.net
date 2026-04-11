+++
title = "Progettare senza fretta, implementare senza sorprese: il lifecycle di Vault su Hetzner"
date = 2026-04-11T14:00:00+00:00
draft = true
description = "L'evoluzione del metodo CRISP e la dimostrazione pratica del suo valore. Come tre giorni di design intensivo si sono tradotti in meno di due ore di implementazione perfetta del lifecycle di Vault su Hetzner."
tags = ["hetzner", "vault", "podman", "tailscale", "ansible", "devops", "infrastructure", "crisp", "architecture"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# Progettare senza fretta, implementare senza sorprese: il lifecycle di Vault su Hetzner

Il completamento del passo *foundation* ci aveva lasciato con una certezza: separare le fasi di provisioning puro da quelle di configurazione applicativa semplifica enormemente la diagnosi dei problemi. Ma la vera prova del fuoco per la nuova metodologia operativa, battezzata internamente **CRISP** (Context, Research, Intent, Structure, Plan), doveva ancora arrivare.

Il target di questa sessione era uno dei componenti più critici dell'intera infrastruttura: l'implementazione del lifecycle locale di **HashiCorp Vault** sul nodo Hetzner, denominata `hetzner-vault-local-lifecycle` (fase C1). Parliamo di un nodo Vault che gira come container Podman, con storage Raft locale, crittografia TLS nativa, unseal automatizzato e un processo di bootstrap rigoroso.

Il contrasto tra il tempo speso a pensare e quello speso a eseguire è stato drastico: tre giorni interi dedicati esclusivamente alla progettazione, senza scrivere una singola riga di codice infrastrutturale. Una serie continua di review per limare e perfezionare ogni singolo dettaglio del piano. Il risultato? Un'implementazione completata a regola d'arte in meno di due ore. Una "passeggiata" tecnica, ma solo perché il percorso era stato tracciato con ossessiva precisione.

## L'evoluzione del metodo CRISP: smussare i problemi prima del codice

Il vero valore di un'architettura non si misura da quanto è complessa, ma da quanto è gestibile quando le cose vanno storte. Durante i tre giorni di design, ogni scelta è stata messa in discussione. Ho affrontato decisioni architetturali complesse che, se affrontate durante l'implementazione, avrebbero inevitabilmente generato caos.

### La gestione dello State e del Lineage

Una delle decisioni più complesse è stata la classificazione dello stato. Invece di affidarci a un semplice "se il file esiste, allora Vault è configurato", ho progettato un sistema di classificazione deterministico su tre domini indipendenti: lo stato di bootstrap sul controller (TazPod), lo stato di runtime locale su Vault e, in futuro, lo stato di recovery remoto su S3.

Questo ha portato all'introduzione del concetto di **Vault Lineage ID**, un identificatore univoco generato durante il primo `vault operator init` e salvato in un file non segreto (`lifecycle-receipt.json`). Perché? Perché un riavvio di un container è radicalmente diverso dalla ricreazione di un'identità Vault. Senza un lineage chiaro, uno script di automazione rischia di sovrascrivere chiavi di unseal valide con una nuova inizializzazione accidentale, o di tentare un restore da un backup incompatibile.

### Il dilemma dell'Automated Unseal

Un'altra scelta cruciale è stata l'approccio all'unseal. In un ambiente Enterprise cloud-native (come AWS), si userebbe un KMS (Key Management Service) per l'auto-unseal. In quello scenario, la macchina fa parte del perimetro di sicurezza del provider e gode di un'autenticazione forte implicita (es. IAM roles). Su un server Hetzner isolato, il discorso cambia: per usare un KMS esterno dovrei depositare sulla Virtual Machine un token o un certificato di autenticazione. Questo non aggiungerebbe un reale strato di sicurezza. Un eventuale attaccante che compromettesse la macchina, invece di trovarvi le chiavi di unseal, troverebbe semplicemente il certificato per andarsele a prendere dal KMS. Si sposterebbe solo il problema un passettino più in là. Poiché il confine di sicurezza in questo scenario è la Virtual Machine stessa (se un attaccante entra, ha già sfondato il muro), ho deciso di non introdurre questa complessità e di gestire l'unseal localmente.

La soluzione adottata sfrutta lo standard Shamir Secret Sharing di Vault (impostato a 3 share totali con soglia a 2), conservando l'intero set di chiavi in modo sicuro nel vault crittografato del controller (TazPod). Sul nodo Hetzner, vengono depositate *esattamente* due chiavi (il minimo necessario per superare la soglia), lette da uno script locale (`vault-local-unseal.sh`) gestito da un'unità systemd (`vault-local-unseal.service`). In questo modo, se il nodo si riavvia, l'unità systemd esegue l'unseal in modo idempotente. Se il nodo viene compromesso o distrutto, l'operatore possiede ancora l'autorità crittografica per ricreare o revocare il cluster, poiché la terza chiave e il root token non risiedono mai sulla macchina esposta.

## L'implementazione: i problemi "buoni" di un sistema deterministico

Arrivato il momento dell'esecuzione, il piano Ansible è stato tradotto in codice. Come previsto in ogni lavoro infrastrutturale a basso livello, ci sono stati degli ostacoli. Tuttavia, l'aspetto gratificante è che questi problemi sono emersi come *dettagli di integrazione*, non come difetti architetturali.

### Il nodo operatore Tailscale offline

Il primo ostacolo è stato una failed connection dell'operatore Ansible. L'inventory dinamico di Tailscale si aspettava che il demone `tailscaled` locale sull'operatore (TazPod) fosse in esecuzione e mappasse il tailnet. In questo ambiente isolato, il demone non era attivo.

L'errore ha evidenziato un problema di identità: il nodo operatore locale era entrato nella rete come utente generico, ma le ACL (Access Control List) di Tailscale prevedevano che solo i nodi con il tag `tag:tazpod` potessero raggiungere la porta 22 del nodo `tag:tazlab-vault`. La soluzione è stata chirurgica e non ha richiesto alterazioni all'architettura: tramite le credenziali OAuth, ho chiamato le API di Tailscale (`POST /api/v2/tailnet/{tailnet}/keys`) per generare una nuova auth-key effimera con le capabilities esatte per applicare il `tag:tazpod`, avviando poi `tailscaled` in modalità userspace con un socket dedicato (`/tmp/tailscaled-operator.sock`). Questo ha ristabilito immediatamente il path `tailscale nc`, permettendo ad Ansible di fluire in sicurezza.

### Podman 4.3.1 e l'inaffidabilità di Quadlet

Il design prevedeva l'uso di **Quadlet**, un generatore systemd nativo per Podman che trasforma file dichiarativi `.container` in unità systemd. È uno standard eccellente per gestire i container come servizi nativi.

Durante l'applicazione, però, l'unità `lushycorp-vault.service` generata da Quadlet semplicemente non veniva rilevata da systemd. La versione di Podman installata sulla Golden Image Debian (4.3.1) mostrava comportamenti imprevedibili con il generatore. In un contesto senza design, questo avrebbe scatenato il panico: "Cambiamo OS? Aggiorniamo Podman da repository non stabili?". 

Avendo i contratti ben definiti, la deviazione è stata pragmatica: ho sostituito il file `.container` con un'unità systemd esplicita di tipo `Type=simple` che esegue `podman run` in modo deterministico. Il contratto di servizio, i mount dei volumi e le variabili d'ambiente sono rimasti identici. L'interfaccia verso l'esterno non è cambiata, salvando l'implementazione senza corrompere l'intento architetturale.

### Capability e privilegi: il caso CAP_SETFCAP

L'immagine ufficiale di HashiCorp Vault è progettata per gestire internamente il drop dei privilegi usando `libcap`. Quando ho provato a forzare l'esecuzione del container strettamente con `--user vault` (uid 100), il container andava in crash immediato con l'errore:

`unable to set CAP_SETFCAP effective capability: Operation not permitted`

L'analisi dei log ha rivelato che il wrapper di avvio dell'immagine tentava di impostare le file capabilities per permettere al binario `vault` di usare `mlock` (memory lock) pur non essendo root. Poiché il container era già avviato come utente non privilegiato, l'operazione falliva.

La soluzione ha richiesto un aggiustamento di precisione: ho rimosso il flag `--user vault` dal comando `podman run`, avviando il container come root, ma impostando esplicitamente `--entrypoint vault` per bypassare il wrapper problematico. Internamente, i processi sono comunque isolati, e a livello di host filesystem l'ownership rigorosa (`root:vault` per TLS, `vault:vault` per i dati Raft) ha garantito la sicurezza senza bloccare l'esecuzione.

## Il "Fail-Fast" che ti salva la vita

Il momento di massima soddisfazione tecnica è arrivato verso la fine dell'esecuzione. Avevo strutturato l'inizializzazione del nodo come un'operazione atomica in 3 fasi:
1. **Phase A (Nodo Remoto):** Avvio Vault, init, unseal, mount del secret engine e generazione di token/policy in una directory di staging temporanea.
2. **Phase B (Controller locale):** Download di questi artifact via Ansible e persistenza sicura all'interno del vault crittografato di TazPod.
3. **Phase C (Nodo Remoto):** Se e solo se la Phase B ha successo, spostamento delle chiavi di unseal nella directory finale di bootstrap e scrittura del `lifecycle-receipt.json`.

Al primo tentativo, un errore di sintassi nello script Ansible della Phase B ha impedito il salvataggio dei file sul controller. Il playbook è fallito.

Cosa è successo al successivo avvio? Il sistema ha ispezionato il nodo remoto. Ha visto che la directory dei dati Raft conteneva dei dati (Vault era stato inizializzato), ma mancava il `lifecycle-receipt.json` (la Phase C non era mai avvenuta). Il sistema ha classificato il nodo come **inconsistent** e si è fermato con un Hard Fail, rifiutandosi di proseguire.

Questo è il trionfo del design preventivo. In uno script di provisioning ingenuo, Ansible avrebbe tentato di reinizializzare Vault, distruggendo irreparabilmente il cluster, o peggio, avrebbe finto che tutto andasse bene lasciando l'operatore senza una copia sicura delle chiavi di unseal (memorizzate solo nella directory di staging effimera). Il guardrail ha funzionato esattamente come progettato: ha bloccato il disastro e mi ha obbligato a distruggere la VM per ricominciare l'intero processo da uno stato pulito.

## Riflessioni post-lab

Dopo aver risolto l'intoppo della Phase B, la successiva esecuzione ha completato tutte e tre le fasi senza sbavature. La VM era attiva, Vault era unsealed, le chiavi erano al sicuro nel controller, le chiamate TLS rispondevano correttamente e il cluster era pronto per il successivo step (l'integrazione del backup remoto S3, fase C2).

Cosa mi porto via da questa sessione? La conferma definitiva che l'approccio "Architettura prima del codice" riduce l'entropia ingegneristica. Quando i contratti sono definiti a priori — come i nomi esatti degli host (`lushycorp-vm.ts.tazlab.net`), i path dei volumi, i formati dei metadata — l'implementazione diventa una semplice operazione di traduzione.

Il tempo "perso" in progettazione (quei 3 giorni di review asincrone e meticolose) non è stato perso affatto: è stato un investimento ad altissimo rendimento. Ci ha evitato giornate intere di frustrazione nel cercare di sbrogliare una matassa in cui permessi Podman, reti Tailscale e crittografia Vault si intrecciavano in modo incomprensibile. 

Progettare senza fretta ha permesso, ancora una volta, di implementare senza sorprese. E nel mondo dell'infrastruttura enterprise, "nessuna sorpresa" è il complimento migliore che un sistema possa ricevere.
