+++
title = "PKI Vault su TazLab: come ho costruito una PKI enterprise in un homelab"
date = 2026-07-01T15:00:00+02:00
draft = false
description = "Dieci ricerche, quindici review, un giorno di implementazione: il percorso per portare una PKI a tre livelli con Vault, Let's Encrypt e mTLS su PostgreSQL in un cluster Kubernetes Talos."
tags = ["Vault", "PKI", "Kubernetes", "Talos", "PostgreSQL", "mTLS", "Grafana", "Let's Encrypt", "TazLab"]
author = "Tazzo"
+++

## Il Problema: Un Certificato Wildcard che Scadeva Tra un Mese

Il mio cluster TazLab aveva un problema che non potevo più ignorare: il certificato wildcard `*.tazlab.net`, usato da tutti i servizi interni — auth, dex, blog, wiki — era stato ottenuto manualmente con `lego` e Cloudflare DNS-01. Ed era in scadenza il 30 luglio 2026.

Non c'era alcun rinnovo automatico. Il ClusterIssuer di cert-manager era configurato solo con HTTP01, che non può emettere wildcard. E per la migrazione a Vault Secrets Operator (VSO), avevo già spostato tutti i segreti statici su Vault — ma il TLS era rimasto indietro.

E poi c'era un problema più profondo: le password degli utenti PostgreSQL (grafana, mnemosyne, pgadmin) erano statiche. VaultDynamicSecret le creava, ma dopo un restart di VSO il lease si perdeva e Grafana crashava. Il database aveva bisogno di autenticazione forte, non di password che scadono al riavvio sbagliato.

La soluzione? Una PKI completa su Vault: una CA offline, due intermediate, certificati dinamici per i servizi interni, Let's Encrypt per quelli pubblici, e mTLS per il database.

Sembrava semplice sulla carta. Non lo è stato.

## L'Architettura: Una PKI a Tre Livelli per un Cluster da Due Nodi

Prima di scrivere una riga di codice, ho passato settimane nella fase di progettazione. Il metodo **CRISP** (Context, Research, Intent, Structure, Plan) che uso per i progetti complessi richiedeva di rispondere a una domanda fondamentale: qual è l'architettura giusta per una PKI che deve essere sicura, ma gestibile su un cluster con un control plane e un worker?

La risposta è stata una **PKI a tre livelli**:

- **Tier 0**: Offline Root CA (ECDSA P-384, 20 anni di validità) — generata su una macchina air-gapped, chiave cifrata con GPG AES-256, mai esposta online.
- **Tier 1**: First Intermediate CA (10 anni) — importata in Vault come `pki_root`.
- **Tier 2**: Second Intermediate CA (5 anni) — generata e gestita interamente da Vault come `pki_int`, con ruoli specifici per ogni tipo di certificato.

Questa architettura garantisce che, anche se Vault viene compromesso, un attaccante può firmare solo fino al Tier 1, non alla Root. La Root CA resta offline, al sicuro.

La divisione dei domini è stata altrettanto chiara:

- **Pubblico** (browser trust): blog.tazlab.net, wiki.tazlab.net, tazlab.net, www, lab → Let's Encrypt via cert-manager
- **Interno** (tailnet): auth.tazlab.net, dex.tazlab.net `*.tazlab.net` → Vault PKI
- **Database**: TLS server PostgreSQL + certificati client per ogni utente → Vault PKI

## Le Ricerche: Dieci Approfondimenti Prima di Scrivere una Riga di Codice

Uno degli aspetti che ha reso questo progetto particolarmente complesso è stato il numero di ricerche necessarie prima di poter iniziare l'implementazione. Il metodo CRISP richiede che ogni decisione di design sia confermata da fonti esterne — non ci si affida alla memoria del modello linguistico. Questo ha portato a un processo di ricerca strutturato che ha prodotto dieci documenti di approfondimento.

### La Fase CRISP: R26—R35

Durante la progettazione iniziale, ho commissionato dieci ricerche su temi specifici:

1. **VaultPKISecret con JWT+JWKS**: come integrare VSO con Vault PKI
2. **Configurazione PKI Role per Kubernetes**: parametri di ogni ruolo (no_store, allowed_domains, TTL)
3. **Talos PKI Trust Bundle Gestione**: come TrustedRootsConfig funziona su Talos
4. **Migrazione Certificati TLS: Statico a VaultPKI**: strategia di cutover graduale vs big-bang
5. **Distribuzione Multi-Namespace di Segreti TLS**: reflector vs copia manuale
6. **Sicurezza Vault PKI PostgreSQL**: mTLS per il database
7. **Crunchy PGO v5 mTLS Vault**: come PGO gestisce i certificati client
8. **Vault PKI Chain Resolution**: il problema della catena incompleta
9. **VSO Secret Transformation Configuration**: template per generare ca.crt
10. **Architectural Verification**: validazione dell'approccio complessivo

Ogni ricerca ha prodotto un documento salvato nel progetto CRISP e ha contribuito a raffinare il design. Molte hanno rivelato complessità che non erano visibili a un'analisi superficiale.

### La Fase di Implementazione: Altre Sei Ricerche

Quando ho iniziato l'implementazione, ho scoperto che la teoria e la pratica non sempre coincidono. Ho dovuto commissionare altre sei ricerche mirate:

1. **Abilitazione TrustedRootsConfig su Talos**: il metodo corretto (`talosctl patch mc`, non `kubectl apply`)
2. **Configurazione mTLS PostgreSQL per applicazioni**: come ogni client (psql, Grafana, pgAdmin, Go) gestisce i certificati client in modo diverso
3. **Risoluzione Errore TLS Vault PostgreSQL**: perché la catena dei certificati era incompleta
4. **Crunchy PGO Custom CA Configuration**: come PGO gestisce (e blocca) il `ssl_ca_file`
5. **Configurazione Grafana Kube-Prometheus-Stack**: perché `grafana.command` non funziona
6. **Grafana PostgreSQL mTLS Helm Setup**: come configurare correttamente le env vars SSL

Senza queste ricerche, avrei probabilmente passato giorni a tentativi su aspetti che — una volta compresi — si sono risolti in pochi minuti.

## Le Review: Quindici Occhi sul Design

Il metodo CRISP prevede cicli di review strutturati. Per questo progetto, ho eseguito tre cicli di review maggiori, ciascuno dei quali ha identificato tra i 25 e i 35 gap nel design. Ogni gap è stato risolto con una modifica al design e, dove necessario, una ricerca di conferma.

Alcuni esempi di gap trovati in review:

- **no_store per internal-ingress**: inizialmente impostato a `true`, poi cambiato a `false` dopo che la review ha evidenziato che il wildcard `*.tazlab.net` copre auth e dex (servizi di identità) e che senza `no_store=false` non sarebbe stato possibile revocare un certificato compromesso
- **allow_wildcard_certificates mancante**: un parametro obbligatorio per emettere wildcard, senza il quale Vault rifiuta la richiesta con errore 400
- **Separazione dei ruoli database-client**: da un singolo ruolo `database-client` a quattro ruoli separati (`db-client-mnemosyne`, `db-client-grafana`, `db-client-pgadmin`, `db-client-tazlab-admin`) per prevenire privilege escalation via CN arbitrario

## L'Implementazione: Un Giorno, Cinque Fasi

Con il design approvato e le ricerche completate, l'implementazione è stata sorprendentemente rapida: circa 12 ore di lavoro continuativo. Ma ogni fase ha portato con sé le sue sfide.

### Fase 0: Backup e Preparazione

Prima di toccare qualsiasi configurazione, ho preparato il punto di rollback:

- Snapshot delle VM Talos (CP e Worker) su Proxmox
- Raft snapshot di Vault, salvato su TazPod S3
- Tag git `pre-pki-build` su tutti e tre i repository coinvolti

### Fase 1: Terraform e Risorse Kubernetes

Ho esteso il modulo Terraform `vault-jwt-config` con otto policy PKI e otto ruoli JWT. Qui ho incontrato il primo problema: i ruoli JWT non possono usare `bound_claims` sulla claim `kubernetes.io/serviceaccount/namespace` perché il JWT emesso da Talos non include questa claim. La soluzione è stata usare `bound_claims` glob sulla claim `sub`:

```hcl
bound_claims      = { sub = "system:serviceaccount:${namespace}:${serviceaccount}" }
bound_claims_type = "glob"
```

Il working role esistente usava già questo pattern, ma il mio design iniziale lo ignorava.

### Fase 2: Il Motore PKI in Vault

L'abilitazione del PKI engine è stata lineare: mount `pki_root` con import della First Intermediate CA, poi `pki_int` con generazione e firma del Second Intermediate. Ma due problemi hanno richiesto attenzione.

**Il Default Issuer Fantasma (Issue #17359)**

Dopo `set-signed`, l'endpoint `pki_int/issue/*` restituiva `ca_chain` vuoto. I certificati venivano emessi, ma non contenevano la catena intermedia. Senza catena, i client Go rifiutavano il certificato con `tls: unknown certificate authority`.

La causa era il multi-issuer engine introdotto in Vault 1.11: importare una CA con `set-signed` non la imposta automaticamente come default. Ho dovuto creare un nuovo issuer, importare la catena completa, e poi impostarlo come default:

```bash
vault write pki_int/root/replace default=<nuovo-issuer-id>
```

**I Parametri EC Fantasma (Issue #16667)**

Il bundle PEM della CA generata offline conteneva blocchi `-----BEGIN EC PARAMETERS-----` che il parser ASN.1 di Go non tollera. Ho dovuto rimuoverli prima dell'import — una pulizia manuale che ho poi integrato nello script di bootstrap.

### Fase 3: Let's Encrypt per Blog e Wiki

Blog e wiki usavano il wildcard TLS statico. Ho creato due Certificate resources in cert-manager:

- `blog-tazlab.net-tls` per blog.tazlab.net, tazlab.net, www, lab
- `wiki-tazlab.net-tls` per wiki.tazlab.net

Entrambi con ClusterIssuer `letsencrypt-issuer` e HTTP01 solver. L'attivazione è stata rapida — cert-manager ha risposto alle challenge HTTP01 in pochi secondi.

### Fase 4: Il Cutover del Wildcard

Il momento critico: sostituire il wildcard static con il VaultPKISecret. Ho creato `vault-pki-tls` in `vso-system` con commonName `*.tazlab.net`, TTL 168h, e annotation per reflector verso auth e dex.

Poi ho migrato gli Ingress uno per uno:
1. auth.tazlab.net → verifica
2. dex.tazlab.net → verifica
3. Eliminazione ExternalSecret `wildcard-tls`

L'oauth2-proxy ha richiesto un'attenzione particolare: doveva fidarsi del certificato Vault PKI per parlare con Dex. Ho aggiunto `--provider-ca-file=/etc/oauth2-proxy/pki/ca.crt` con mount esplicito del secret tramite `items:` (la proiezione subPath è rotta su Talos).

### Fase 5: mTLS — Il Vero Ostacolo

L'autenticazione client-server per PostgreSQL doveva passare da password a certificato. Qui ho scoperto che il diavolo sta nei dettagli — e ogni dettaglio è diverso per ogni applicazione.

**Server TLS PostgreSQL**

Il Crunchy PostgreSQL Operator (PGO) gestisce i certificati server tramite `customTLSSecret`. Ho configurato un VaultPKISecret per il server, e ho scoperto che PGO ignora il `ca.crt` dal Secret a meno che non sia dichiarato con `items:` esplicito:

```yaml
customTLSSecret:
  name: tazlab-db-server-tls
  items:
    - key: ca.crt
      path: ca.crt
    - key: tls.crt
      path: tls.crt
    - key: tls.key
      path: tls.key
```

Inoltre, il parametro `ssl_ca_file` di PostgreSQL è **immutabile** in PGO — non può essere sovrascritto via `patroni.dynamicConfiguration`. L'unico modo per aggiungere una CA custom (la mia CA Vault) è inserirla nel bundle del `ca.crt` del Secret. Con PGO, questo è l'unico canale per estendere la trust chain del server.

**La Catena Incompleta**

Quando ho verificato la connessione TLS, i client Go (Grafana) fallivano con `tls: unknown certificate authority` anche se `openssl s_client` dava `Verify return code: 0`. La differenza? Go richiede che il certificato server INVII la catena intermedia durante l'handshake. `openssl` la scarica automaticamente via AIA — i client Go e libpq no.

La soluzione è stata aggiornare il default issuer di `pki_int` e verificare che la `ca_chain` nella risposta di Vault contenesse effettivamente tutti e tre i certificati (Tier 2 + Tier 1 + Tier 0). Con il fix di Issue #17359, ora la catena è presente.

**Grafana: La Sfida Più Grande**

Configurare Grafana per usare il client certificate verso PostgreSQL è stato il compito più lungo e frustrante del progetto. Il problema era il chart Helm `kube-prometheus-stack`, che non propaga le configurazioni come ci si aspetterebbe.

Dopo cinque tentativi falliti, ho commissionato una ricerca specifica. I risultati:

1. **`grafana.command` non è supportato** — il sotto-chart Grafana ignora completamente questo campo. Ho dovuto usare `extraInitContainers` per copiare i certificati da un Secret a un emptyDir e applicare i permessi corretti.

2. **`grafana.env` usa sintassi mappa YAML** — non lista. Ma le variabili vengono filtrate dal meccanismo `assertNoLeakedSecrets` (default `true`). Per passare parametri SSL in chiaro, ho dovuto impostare `assertNoLeakedSecrets: false`.

3. **`grafana."grafana.ini"` è fully supported** — e non subisce filtraggio dal wrapper chart. È il modo corretto per configurare i parametri SSL del database. Ma ho scoperto che la sezione `database` in `grafana.ini` non veniva renderizzata, probabilmente perché il chart filtra le chiavi che confliggono con le proprie.

4. **`extraSecretMounts` funziona** — ma va usato con `defaultMode: 384` (0600 in ottale). La libreria libpq di Grafana rifiuta la chiave privata se ha permessi troppo permissivi o se è montata come symlink.

La configurazione finale che ha funzionato:

```yaml
grafana:
  database:
    type: sqlite3
  env:
    GF_DATABASE_TYPE: "postgres"
    GF_DATABASE_HOST: "tazlab-db-primary.tazlab-db.svc:5432"
    GF_DATABASE_NAME: "grafana"
    GF_DATABASE_USER: "grafana"
    GF_DATABASE_SSL_MODE: "require"
  extraSecretMounts:
    - name: grafana-db-certs
      secretName: db-client-grafana-tls
      mountPath: /tmp/db-certs-in
      defaultMode: 384
  extraInitContainers:
    - name: copy-db-certs
      image: alpine:3.21
      command:
        - sh -c "cp -rL /tmp/db-certs-in/* /etc/grafana/certs/ && chmod 600 /etc/grafana/certs/tls.key"
```

**pgAdmin e mnemosyne: Rimandati**

pgAdmin 4 non supporta i certificati client via variabili d'ambiente — richiede un file `servers.json` con i percorsi SSL. L'applicazione Go (mnemosyne) necessita di modifiche al codice per supportare la catena completa del certificato client (Go richiede che il file `sslcert` contenga la concatenazione di certificato foglia + intermedi, a differenza di `psql` che accetta solo il foglio).

Per ora, questi due servizi continuano ad autenticarsi con password. Il mTLS completo rimane come attività futura.

## I Debiti Tecnici

Ogni progetto lascia debiti. Questi sono i miei:

- **Longhorn CSI repliche**: il cluster ha un solo worker, ma Longhorn installa 3 repliche per ogni sidecar CSI — e 2 di queste crashano perché competono per lo stesso nodo. Risolto settando `replicaCount: 1` nei valori Helm.
- **DNS Tailscale post-reboot**: dopo il reboot dei nodi, il nome MagicDNS di Vault impiega 1-5 minuti a risolvere correttamente. Il ClusterSecretStore di ESO lo segnala come errore, bloccando Flux. La soluzione è pura tolleranza — basta aumentare il timeout Flux da 5 a 10 minuti. Su destroy+create non succede.
- **mTLS per pgAdmin e mnemosyne**: documentato, pianificato, non ancora implementato.

## Le Lezioni

### La Progettazione CRISP Ha Pagato

Ogni problema che ho incontrato in fase di implementazione era già stato identificato in fase di design? No. Ma quelli che ho incontrato erano risolvibili rapidamente proprio perché l'architettura di fondo era solida. Se avessi iniziato a scrivere codice senza la fase di ricerca e review, avrei dovuto rivedere l'architettura più volte — invece ho potuto concentrarmi sui dettagli operativi.

### Le Ricerche Sono un Investimento, Non un Costo

Ogni ricerca mi ha fatto risparmiare ore di tentativi. Senza la ricerca su PGO `ssl_ca_file`, avrei passato ore a cercare di sovrascrivere un parametro che PGO rende volutamente immutabile. Senza quella su Grafana, sarei ancora lì a chiedermi perché `grafana.command` viene ignorato.

### mTLS Non È Standardizzato tra le App

Un certificato client è un file. Il modo in cui ogni applicazione lo carica no. `psql` lo prende da variabili d'ambiente. Grafana da env vars specifiche (con nomi che cambiano a seconda della documentazione che leggi). pgAdmin da un file JSON. Go da una connection string. Ognuna di queste ha requisiti diversi sul formato (certificato foglia vs bundle), sui permessi (0600 necessario per libpq), e sul percorso.

### Il Cluster È Piccolo, Ma I Problemi Sono Quelli Enterprise

Avere un cluster con un control plane e un worker non semplifica i problemi di PKI. La complessità della gestione dei certificati, delle catene di trust, e dell'autenticazione mTLS è identica a quella di un cluster enterprise. Cambia solo il numero di nodi su cui applicare le patch.

## Cosa Succede Dopo

Il prossimo passo è un ciclo `destroy+create` per verificare che tutto l'implementato funzioni senza interventi manuali — un vero test one-shot. Poi migrerò pgAdmin a servers.json e l'app Go di mnemosyne a mTLS. Infine, installerò il reflector per la propagazione automatica dei secret tra namespace.

Ma questa è un'altra storia.

---

*Questo articolo fa parte di una serie sulla gestione dell'infrastruttura TazLab. Il codice sorgente è disponibile su [github.com/tazzo](https://github.com/tazzo). Commenti e suggerimenti sono benvenuti.*
