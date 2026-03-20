+++
title = "Bootstrap from Zero: Ricostruire Tutto da un Singolo Bucket S3"
date = 2026-03-20T11:00:00+00:00
draft = false
tags = ["Kubernetes", "HashiCorp Vault", "Oracle Cloud", "Tailscale", "Security", "Secrets Management", "Talos OS", "S3", "Bootstrap", "Infisical", "Terragrunt"]
description = "Come ho progettato un ciclo di rinascita completo per il TazLab: da una macchina vuota a un cluster Kubernetes operativo usando solo un bucket S3, una passphrase e un dispositivo MFA."
+++

## The Current State: Il Piano Aveva un Buco

Nel [precedente articolo su questa roadmap](/posts/tazlab-roadmap-hashicorp-vault-oracle-cloud/) ho descritto il motivo per cui il TazLab sta migrando da Infisical a HashiCorp Vault CE, e la direzione verso cui si sta muovendo: segreti dinamici, rotazione automatica, un secondo cluster su Oracle Cloud. Il "cosa" e il "perché" erano chiari.

Quello che mancava era il "come sopravvive il sistema quando tutto sparisce".

La domanda che non riuscivo a togliermi dalla testa era questa: se domani mattina Proxmox, Oracle Cloud e il mio computer bruciassero contemporaneamente, cosa mi resterebbe? Un bucket S3, una passphrase in testa, e un dispositivo MFA fisico. Basta. Da questi tre elementi deve ripartire tutto — e non in maniera eroica e manuale, ma in modo sistematico, il più automatico possibile.

Questa è la sessione di progettazione in cui abbiamo risolto esattamente quel problema.

---

## The "Why": Non Basta Migrare, Bisogna Rinascere

La migrazione da Infisical a Vault non è solo una questione di vendor. È l'occasione per riprogettare il bootstrap da zero — il momento in cui l'intera filosofia del castello effimero viene messa alla prova.

Un'infrastruttura è davvero effimera solo se puoi distruggerla e ricostruirla senza paura. E puoi farlo senza paura solo se hai risposto onestamente a questa domanda: **cosa deve esistere fuori dai cluster per renderli ricostruibili?**

La risposta ha una forma precisa. Non una serie infinita di segreti sparsi, non una dipendenza da un servizio esterno sempre attivo. Tre anchor, tutti sullo stesso bucket S3:

```
S3: tazlab-storage/
├── tazpod/vault.tar.aes       ← segreti di bootstrap (AES-256-GCM, passphrase)
├── vault/vault-latest.snap    ← snapshot Raft di Vault (tutti i segreti app)
└── pgbackrest/                ← backup PostgreSQL (Mnemosyne, dati tazlab-k8s)
```

Il primo contiene il minimo indispensabile per far partire tutto prima che esistano cluster. Il secondo è la memoria di Vault — tutti i segreti delle applicazioni, aggiornata automaticamente ogni giorno. Il terzo è il database: i dati di Mnemosyne, le configurazioni, lo storico. Nessuno dei tre ha senso senza gli altri due. Insieme, sono tutto ciò che serve per ricominciare.

---

## The Target Architecture: Quattro Decisioni Difficili

La progettazione di questo ciclo ha richiesto di sciogliere quattro nodi che, in superficie, sembravano semplici.

### Il Problema del Bootstrap: Chi Viene Prima dell'Uovo?

L'immagine Docker di tazpod è **pubblica**. Non può contenere credenziali. Ma per scaricare `vault.tar.aes` da S3 ho bisogno di credenziali AWS. E le credenziali AWS le ho nel vault. E il vault è su S3.

La soluzione non è tecnica — è architetturale. Ho usato **AWS IAM Identity Center** (il servizio SSO di AWS): un flusso di autenticazione interattivo dove inserisci email, password e codice MFA, e ricevi credenziali temporanee valide 8 ore. Il file di configurazione AWS che va nell'immagine contiene solo l'URL del portale SSO e il nome del ruolo — nessun segreto, pubblicabile senza problemi.

```
docker run tazzo/tazpod-ai
    │
    ▼
aws sso login --profile tazlab-bootstrap
    │  → email + password + MFA fisico
    ▼
aws s3 cp s3://tazlab-storage/tazpod/vault.tar.aes ...
    │
    ▼
tazpod unlock  ←  passphrase (solo in testa)
    │
    ▼
secrets/ aperta — da qui parte tutto il resto
```

La passphrase vive solo nella mia testa. Il dispositivo MFA è fisico. Senza entrambi, il bucket S3 è un archivio cifrato inutile.

### L'Unseal di Vault: Professionale Non Significa Costoso

Vault parte sempre in stato "sealed" — non risponde finché non gli viene fornita la chiave per decifrare la sua master key. Nella mia testa il problema sembrava richiedere un KMS esterno: AWS KMS (1$/mese), OCI KMS (gratuito per chiavi software), qualcosa di sempre disponibile.

Ma c'era una soluzione più pulita che non richiedeva nessuna dipendenza esterna. Le chiavi di unseal di Vault (algoritmo di Shamir: 3 chiavi, servono 3 su 5 per aprire) vengono generate una volta sola all'inizializzazione. Le salvo in `secrets/`. Al bootstrap, `create.sh` le usa direttamente:

```bash
vault operator unseal $(cat /home/tazpod/secrets/vault-unseal-key-1)
vault operator unseal $(cat /home/tazpod/secrets/vault-unseal-key-2)
vault operator unseal $(cat /home/tazpod/secrets/vault-unseal-key-3)
```

È completamente automatico dal punto di vista dello script, perché l'interazione umana era già avvenuta: passphrase + MFA all'inizio del bootstrap hanno già aperto `secrets/`. Da lì in poi, nessun intervento richiesto.

OCI KMS rimane come opzione per ambienti di simulazione dove il ciclo manuale è scomodo.

### La Rete: Tailscale Come Estensione del Sistema Operativo

ESO su tazlab-k8s deve poter raggiungere Vault su tazlab-vault (OCI) dal primo momento in cui viene deployato. Vault non può stare su un endpoint pubblico senza motivo.

La soluzione è Tailscale — ma non come pod Kubernetes. Come **estensione del sistema operativo Talos**. Esiste `siderolabs/tailscale` come extension ufficiale: viene baked nell'immagine alla Talos Image Factory e si avvia come servizio di sistema, prima che Kubernetes esista.

```
Nodo OCI si avvia
    │
    ▼
Talos OS → Tailscale extension → nodo nella tailnet   ← prima di K8s
    │
    ▼
Kubernetes bootstrap → cluster healthy
    │
    ▼
Terragrunt deploya Vault → ESO connette Vault via tailnet ✓
```

La auth key di Tailscale (reusable, con tag `tag:tazlab-node`) vive in `secrets/` e viene iniettata nella machine config durante il provisioning. Il nodo rientra automaticamente nella stessa rete ad ogni rebuild, con lo stesso nome DNS.

La stessa estensione va su tazlab-k8s. I due cluster comunicano privatamente, senza esporre nulla su internet.

### tazlab-vault: Minimal by Design

L'ultima decisione è stata forse la più semplice una volta formulata correttamente: tazlab-vault non ha bisogno di Flux.

Flux ha senso quando gestisci molte applicazioni che cambiano continuamente e vuoi che il cluster si auto-riconcili. tazlab-vault ha **una sola responsabilità**: far girare Vault. Per deployare una sola applicazione, Flux è un livello di complessità che non guadagna nulla. Gli upgrade di Vault devono essere deliberati, testati, e mai automatici.

La scelta è Terragrunt con il Helm provider — esattamente il pattern già usato in ephemeral-castle per ESO, MetalLB e Longhorn. La struttura dei layer:

```
secrets → platform → vault
```

Niente `engine` (ESO), niente `gitops` (Flux). Vault usa Raft integrated storage su `hostPath` — non ha bisogno di Longhorn perché i dati persistenti vengono comunque ripristinati dallo snapshot S3 ad ogni rebuild.

---

## Phased Approach: Sette Fasi Verso la Rinascita Completa

Il lavoro è organizzato in fasi sequenziali, ognuna stabile prima di passare alla successiva.

**Fase A — Prerequisiti**: configurare AWS IAM Identity Center, creare l'utente SSO con MFA, generare la Tailscale reusable auth key. Zero impatto sui cluster esistenti.

**Fase B — tazlab-vault minimal**: nuovo schematic Talos con l'estensione Tailscale, risolvere il blocker degli IP riservati OCI (da tazlab-vault-init), completare il bootstrap Talos, deployare Vault CE via Terragrunt, prima inizializzazione e salvataggio delle unseal keys in `vault.tar.aes`.

**Fase C — Vault configuration**: abilitare KV v2, configurare il Kubernetes auth method per ESO, migrare tutti i segreti da Infisical a Vault KV.

**Fase D — Migrazione tazlab-k8s**: aggiornare la Talos image con l'estensione Tailscale (upgrade rolling, non rebuild), sostituire il `ClusterSecretStore` da Infisical a Vault, aggiornare tutti gli `ExternalSecret` con i nuovi path KV.

**Fase E — tazpod Vault integration**: rimuovere la logica Infisical da `main.go`, implementare `tazpod pull` via Vault CLI, aggiornare `tazpod vpn` per usare Tailscale al posto del WireGuard custom mai testato.

**Fase F — Decommission Infisical**: verificare che zero componenti usino ancora Infisical, rimuovere provider e riferimenti da tutti i repo, cancellare i segreti dall'account Infisical.

**Fase G — Make repos public**: audit del git history con `trufflehog`, verifica dei `.gitignore`, rendere pubblici `tazpod`, `tazlab-k8s` e `ephemeral-castle`.

---

## Future Outlook: La Prova Finale

C'è un test che non mente: riesci a rendere pubblici i tuoi repo senza paura?

Se la risposta è sì, hai davvero raggiunto zero-secrets-in-git. Non come principio dichiarato, ma come realtà verificabile. Chiunque può aprire il codice, vedere come funziona tutto, e non trovare nessuna credenziale, nessun token, nessun segreto. La sicurezza non dipende dall'oscurità.

Il ciclo di rinascita completo diventa quindi questa sequenza, eseguibile da chiunque che abbia accesso ai tre elementi giusti:

```
Macchina vuota
    + bucket S3 (sempre disponibile)
    + passphrase (in testa)
    + dispositivo MFA (in tasca)
    ──────────────────────────────
    = infrastruttura completa, operativa, < 30 minuti
```

Il TazLab non ha un indirizzo fisso. Ha solo un Bucket S3 da cui rinasce.
+++
