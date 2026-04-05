+++
title = "LushyCorp Vault su Hetzner: scelte architetturali guidate dalla sicurezza"
date = 2026-04-04T14:00:00+00:00
draft = false
description = "La progettazione del progetto LushyCorp Vault su Hetzner: modello di sicurezza, flusso completo end-to-end e ragioni architetturali prima della fase di implementazione."
tags = ["hetzner", "vault", "ansible", "tailscale", "security", "architecture", "devops", "s3"]
categories = ["Infrastructure", "Security", "DevOps"]
author = "Taz"
+++

# LushyCorp Vault su Hetzner: scelte architetturali guidate dalla sicurezza

Questo articolo non racconta l’implementazione. Racconta la **progettazione**: come ho definito il cuore del progetto LushyCorp Vault su Hetzner prima di spezzarlo in sottoprogetti esecutivi.

L’obiettivo era uno solo: costruire un runtime Vault che potesse nascere, morire e rinascere senza perdere sicurezza, senza dipendere da passaggi manuali fragili e senza introdurre segreti “di comodo” in posti sbagliati.

---

## 1) The Current State: il problema reale da risolvere

Il punto di partenza non era “mi serve una VM con Vault”. Quello è semplice. Il problema vero era questo:

- come avvio una macchina nuova in cloud,
- come la configuro senza password,
- come inietto i prerequisiti di rete privata,
- come inizializzo Vault la prima volta,
- come lo riapro in modo deterministico le volte successive,
- e come faccio tutto questo senza lasciare segreti in image, user-data o repository.

In altre parole: non stavo progettando un server, stavo progettando un **ciclo di vita sicuro**.

Se questa parte viene progettata male, tutto il resto (rotation, governance, private connectivity con il cluster, ecc.) nasce già su fondamenta deboli.

---

## 2) The “Why”: perché queste scelte (e non altre)

### Nessun segreto nell’immagine

L’immagine base doveva contenere solo software e configurazioni neutre. Nessun token, nessuna chiave di bootstrap, nessuna credenziale cloud.

Motivo: un’immagine è fatta per essere clonata. Se ci metti un segreto, quel segreto diventa automaticamente moltiplicabile e difficilmente revocabile in modo ordinato.

### Niente `cloud-init`/`user-data` per passare chiavi

Ho scartato il pattern “passo tutto in user-data” perché non è coerente con il modello di sicurezza cercato. I metadata cloud non sono il posto dove voglio far transitare credenziali sensibili.

Se un domani devo fare audit o incident response, devo poter dire con certezza: **i segreti non sono mai passati dai metadata del provider**.

### Accesso iniziale solo SSH a chiave, mai password

La VM nasce con una sola porta aperta, SSH, e solo con autenticazione a chiave già registrata su Hetzner. Nessun accesso password, nessun bootstrap interattivo fragile.

Questo riduce due superfici contemporaneamente:

1. attacchi opportunistici su password,
2. dipendenza da passaggi manuali non ripetibili.

### La svolta: da mega script SH a Ansible (il vero momento di chiarezza)

Una parte fondamentale della progettazione è stata proprio questa: all'inizio stavo disegnando tutto con un unico script SH molto complesso. L'idea era far fare allo script ogni passaggio: entrare in SSH, controllare stati, applicare configurazioni, iniettare chiavi, gestire branch first-run/re-run, validare output e fare cleanup.

Sulla carta sembrava fattibile. Nella pratica stavo costruendo a mano un orchestratore idempotente, con logica condizionale, retry, gestione errori, ordine delle dipendenze e tracciabilità delle azioni. A un certo punto la domanda è diventata inevitabile: **"ma non è esattamente il caso ideale per usare Ansible?"**

La risposta è stata sì, senza ambiguità: stavamo di fatto scrivendo un **mini-Ansible in Bash**. Ed è stato il momento in cui ho capito davvero a cosa serve Ansible nel mondo reale: non per "fare comandi remoti", ma per dare forma dichiarativa, ripetibile e verificabile alla convergenza di una macchina.

Per me è stato un passaggio importante anche sul piano professionale: conoscevo Ansible da tempo in teoria, ma non avevo mai avuto un caso in cui fosse così chiaramente il tool giusto. In questo progetto la sua utilità è stata evidente perché:

- il flusso richiede **idempotenza** (first-run e re-run devono convergere, non divergere),
- la sicurezza impone una configurazione **deterministica** (niente passaggi manuali opachi),
- serviva tracciare "cosa viene applicato, quando e in quale ordine".

In più, il modello dichiarativo di Ansible è coerente con il resto dello stack che uso: stessa mentalità di Kubernetes e stessa disciplina di tracciabilità tipica dei flussi GitOps. Non è Kubernetes, ma parla la stessa lingua operativa: stato desiderato, convergenza, verificabilità.

Il ruolo di Ansible nel progetto è quindi preciso:

- configurare l'ambiente host in modo coerente,
- iniettare i materiali necessari (es. chiavi/config Tailscale) nel punto corretto del ciclo,
- mantenere separato il bootstrap iniziale dalla convergenza successiva,
- ridurre drasticamente il rischio di drift dovuto a script SH cresciuti oltre soglia.

Senza questa convergenza dichiarativa, la sicurezza resterebbe legata alla memoria della sessione precedente. Con Ansible, invece, diventa parte del sistema.

### Perché non affidarsi a un Key Manager esterno (es. AWS KMS) in questa fase

La discussione più importante è stata questa: “usiamo un key manager esterno e risolviamo”.

Sulla carta è elegante. In pratica, nel mio scenario, per autenticare una macchina fuori dal loro perimetro avrei comunque bisogno di materiale di autenticazione locale (segreti/credenziali) da conservare sulla macchina stessa.

Quindi il punto di rischio non sparisce: si sposta.

- Conservare localmente credenziali per autenticarsi a KMS,
- oppure conservare localmente materiale necessario al bootstrap in un contenitore cifrato,

in questo contesto hanno un profilo di rischio molto vicino, se non gestisci il primo caso con un ecosistema completo enterprise che qui non è disponibile.

Da qui la scelta pragmatica e controllabile: niente dipendenza forzata da key manager esterno in questa fase, ma ciclo deterministico con artefatti cifrati e percorso di recupero esplicito.

---

## 3) The Target Architecture: il progetto completo, prima dello split esecutivo

Prima di dividerlo in più sottoprogetti, il progetto era pensato come un’unica pipeline logica end-to-end.

### Step A — Golden image runtime (solo base tecnica)

1. Creo un’immagine base con i software necessari preinstallati.
2. L’immagine viene testata.
3. Nessun segreto dentro l’immagine.

Questa è la base di fiducia: una macchina che nasce già pronta a convergere, ma ancora “neutra” dal punto di vista dei segreti.

### Step B — Istanza con sola porta SSH

1. Istanzio la VM da golden image.
2. Porta aperta: solo 22.
3. Accesso: solo chiave SSH registrata su Hetzner.

Niente password, niente shell bootstrap via cloud metadata.

### Step C — Convergenza via Ansible, iniezione controllata

Una volta dentro via SSH, Ansible prepara il runtime:

- configura sistema e ambiente,
- inietta i materiali necessari per Tailscale,
- prepara il terreno per il passaggio al canale privato.

### Step D — Switch del piano di gestione su Tailscale

Dopo la convergenza iniziale:

1. la VM entra nella rete Tailscale,
2. la gestione passa al canale privato,
3. in prospettiva si chiude SSH pubblico (sia lato internet sia cloud firewall),
4. da quel momento l’operatività è privata.

Questo è il passaggio chiave: SSH pubblico è solo ponte iniziale, non canale permanente.

### Step E — Fase Vault: primo avvio vs riavvio

Qui il design è esplicitamente biforcato.

#### Primo avvio (bootstrap)

- Vault viene inizializzato,
- vengono generate le chiavi necessarie (unseal/root metadata),
- gli artefatti vengono salvati nel percorso segreti cifrato su S3.

#### Avvii successivi (re-instanziazione)

- gli artefatti esistono già,
- non si re-inizializza Vault,
- si recupera lo stato e si riapre il runtime in modo deterministico.

Questo evita il rischio più pericoloso: “re-init accidentale” con perdita di continuità operativa.

### Step F — Integrazione privata con il cluster

Una volta stabilizzato il runtime su rete privata, anche il cluster entra nello stesso dominio di comunicazione privata.

È qui che il progetto esprime il suo valore finale:

- gestione segreti,
- sincronizzazione,
- rotazione,

avvengono su rete privata, non su esposizione pubblica.

---

## 4) Blueprint operativo (script previsti dal design)

Questo è il blueprint finale. La prima idea era un unico script SH monolitico; dopo la svolta su Ansible, il progetto è stato ripensato in una pipeline dove gli script orchestrano le fasi e Ansible gestisce la convergenza configurativa.

```bash
# 1) build immagine base sicura (no secrets)
create-runtime-golden-image.sh

# 2) istanzia da golden image con SSH iniziale
create-runtime-instance.sh

# 3) convergenza host + iniezione materiali rete privata
converge-runtime-with-ansible.sh

# 4) switch gestione su Tailscale e chiusura progressiva SSH pubblico
switch-to-tailscale-management.sh

# 5) bootstrap Vault first-run (init + salvataggio artefatti cifrati)
vault-first-init.sh

# 6) path di riapertura su re-instanziazione (no re-init)
vault-recover-from-secrets.sh

# 7) cleanup controllato risorse runtime
destroy-runtime.sh
```

La distinzione importante non è il nome degli script, ma la responsabilità di ciascun blocco. Ogni script deve fare una sola cosa critica, con log chiari e output verificabili.

---

## 5) Perché questa parte viene prima dell’implementazione a sottoprogetti

Solo dopo aver definito questo flusso completo ho scelto di dividere l’implementazione in fasi separate. Lo split non nasce per “complicare la governance”, nasce per mantenere intatto il disegno di sicurezza durante l’esecuzione.

Quindi il punto non è il numero di sottoprogetti. Il punto è che il progetto, nel suo cuore, resta questo:

- base immagine pulita,
- bootstrap controllato,
- convergenza dichiarativa via Ansible,
- passaggio a gestione privata via Tailscale,
- lifecycle Vault first-run/re-run deterministic,
- niente segreti in posti sbagliati.

---

## Future Outlook: cosa sblocca davvero questa architettura

Quando questo disegno è rispettato, ottengo tre proprietà strategiche:

1. **Ripetibilità operativa**
   - posso ricreare runtime senza reinventare la procedura.

2. **Riduzione del rischio strutturale**
   - i segreti non transitano su canali impropri,
   - l’esposizione pubblica non è la modalità operativa permanente.

3. **Continuità del lifecycle Vault**
   - il primo avvio e le riaperture successive sono percorsi distinti e controllati.

Questa è la parte davvero importante del progetto: non “mettere su Vault”, ma costruire un sistema che rimane sicuro anche quando lo rifai da zero.
