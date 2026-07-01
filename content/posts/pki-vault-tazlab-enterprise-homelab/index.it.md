+++
title = "PKI Vault su TazLab: come ho costruito una PKI enterprise in un homelab"
date = 2026-07-01T15:00:00+02:00
draft = false
description = "Sedici ricerche, quindici review, un giorno di implementazione: il percorso per portare una PKI a tre livelli con Vault, Let's Encrypt e mTLS su PostgreSQL in un cluster Kubernetes Talos. Un progetto nato come prerequisite per il database multi-cluster, cresciuto fino a diventare il tassello più complesso dell'infrastruttura."
tags = ["Vault", "PKI", "Kubernetes", "Talos", "PostgreSQL", "mTLS", "Grafana", "Let's Encrypt", "CRISP", "TazLab"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

## Il Percorso, Non L'Urgenza

Se seguite la storia di TazLab da qualche mese, avrete notato un filo conduttore: la migrazione verso **segreti dinamici**. Non sostituire un fornitore di secret con un altro, ma cambiare paradigma — da credenziali statiche, scritte nei manifest YAML e ruotate manualmente, a credenziali generate al volo, con lease, rotazione automatica e zero contatto umano.

Nel [post precedente]({{< ref "first-steps-toward-dynamic-secrets" >}}) raccontavo i primi passi: JWT auth, Vault Agent Injector, il disastro del PKI di Talos. Poi [la scoperta di VSO]({{< ref "man-in-the-loop-vso-deep-research" >}}) e la decisione di abbandonare l'injector. Poi [la formalizzazione del metodo CRISP]({{< ref "crisp-2-verified-research-methodology" >}}): ricerca prima di scrivere codice, marker di verifica nei piani, review obbligatorie.

Ogni passo ha preparato il terreno per questo progetto: **la PKI**.

L'obiettivo finale? Poter replicare il database PostgreSQL su due cluster (Proxmox + Hetzner) con failover automatico. Per farlo, serve mTLS — certificati client, non password — perché le password statiche non sopravvivono a un failover, e quelle dinamiche generano lease che scadono al riavvio sbagliato. La PKI era già nel piano di lungo termine per alzare il livello di sicurezza del laboratorio. È diventata un prerequisito operativo per il passo successivo.

Questo articolo racconta quel progetto: un mese di progettazione, sedici ricerche, quindici review, e un giorno di implementazione.

## L'Architettura: Una PKI a Tre Livelli per un Cluster da Due Nodi

Prima di scrivere una riga di codice, ho passato settimane nella fase di design. Il metodo **CRISP** che ho implementato richiedeva di rispondere a una domanda fondamentale: qual è l'architettura giusta per una PKI che deve essere sicura, ma gestibile su un cluster Talos con un control plane e un worker?

La risposta è stata una **PKI a tre livelli** — overkill per un homelab, ma è esattamente ciò che volevo imparare:

- **Tier 0**: Offline Root CA (ECDSA P-384, 20 anni di validità) — generata su una macchina air-gapped, chiave cifrata con GPG AES-256, mai esposta online. È l'ancora di fiducia. Se Vault viene compromesso, la Root CA resta al sicuro.
- **Tier 1**: First Intermediate CA (10 anni) — importata in Vault come `pki_root`.
- **Tier 2**: Second Intermediate CA (5 anni) — generata e gestita interamente da Vault come `pki_int`, con ruoli specifici per ogni tipo di certificato.

La divisione dei domini:

- **Pubblico** (browser trust): blog.tazlab.net, wiki.tazlab.net, tazlab.net → Let's Encrypt via cert-manager
- **Interno** (tailnet): auth.tazlab.net, dex.tazlab.net, `*.tazlab.net` → Vault PKI
- **Database**: TLS server PostgreSQL + certificati client per ogni utente → Vault PKI

## Le Ricerche: Il Vero Lavoro è Stato Capire

Il metodo CRISP che ho implementato richiede che ogni decisione di design sia confermata da fonti esterne — non ci si affida alla memoria del modello linguistico. Questo ha portato a un processo di ricerca strutturato che ha prodotto sedici documenti di approfondimento, dieci nella fase di progettazione e sei durante l'implementazione.

### La Fase di Progettazione: R26—R35

1. **VaultPKISecret con JWT+JWKS**: come VSO si integra con l'engine PKI
2. **Configurazione PKI Role per Kubernetes**: parametri critici come `no_store`, `allowed_domains`, `allow_wildcard_certificates`
3. **Talos PKI Trust Bundle**: TrustedRootsConfig e le differenze tra `machine.certSANs` e `cluster.apiServer.certSANs`
4. **Migrazione Certificati TLS: Statico a VaultPKI**: perché il cutover graduale è meglio del big-bang
5. **Distribuzione Multi-Namespace di Segreti TLS**: reflector vs copia manuale
6. **Sicurezza Vault PKI PostgreSQL**: come impostare mTLS per il database
7. **Crunchy PGO v5 mTLS Vault**: come PGO gestisce i certificati
8. **Vault PKI Chain Resolution**: perché la catena dei certificati era incompleta
9. **VSO Secret Transformation Configuration**: come generare dinamicamente il file `ca.crt`
10. **Architectural Verification**: validazione dell'approccio complessivo

Ogni ricerca ha prodotto un documento Markdown archiviato nel progetto CRISP. Molte hanno rivelato complessità che un'analisi superficiale non avrebbe colto.

### La Fase di Implementazione: Sei Ricerche sul Campo

1. **Abilitazione TrustedRootsConfig su Talos**: perché `kubectl apply` falliva e serviva `talosctl patch mc`
2. **Configurazione mTLS PostgreSQL per applicazioni**: ogni client (psql, Grafana, pgAdmin, Go) ha requisiti diversi
3. **Risoluzione Errore TLS Vault PostgreSQL**: perché la `ca_chain` era vuota nonostante il `set-signed`
4. **Crunchy PGO Custom CA Configuration**: come PGO rende immutabile `ssl_ca_file`
5. **Configurazione Grafana Kube-Prometheus-Stack**: perché `grafana.command` viene ignorato
6. **Grafana PostgreSQL mTLS Helm Setup**: la configurazione finale che ha funzionato

Senza queste ricerche, sarei ancora a tentativi su problemi che — una volta capiti — si sono risolti in pochi minuti.

## Le Review: Quindici Cicli per Affinare il Design

Il metodo CRISP prevede cicli di review strutturati. Per questo progetto ne ho fatti tre maggiori, ciascuno dei quali ha identificato tra i 25 e i 35 gap nel design. Ogni gap è stato risolto con una modifica al design e, dove necessario, una ricerca di conferma.

Alcuni esempi:

- **`no_store` per `internal-ingress`**: inizialmente `true`. La review ha evidenziato che il wildcard `*.tazlab.net` copre auth e dex — servizi di identità. Se il certificato viene compromesso, senza `no_store=false` non è possibile revocarlo. Cambiato a `false`.
- **`allow_wildcard_certificates` mancante**: parametro obbligatorio per emettere wildcard. Senza, Vault rifiuta la richiesta con errore 400. Non era nel design iniziale.
- **Separazione ruoli `db-client-*`**: da un singolo ruolo `database-client` a quattro ruoli separati per evitare escalation: ogni utente PostgreSQL ha il suo ruolo Vault, con `allowed_domains` limitato al suo username.

## L'Implementazione: Un Giorno, Cinque Fasi

Con il design approvato e le ricerche completate, l'implementazione è stata sorprendentemente rapida: circa 12 ore di lavoro. Ma ogni fase ha portato le sue sfide — e alcune sono state risolte solo grazie alle ricerche fatte nei giorni precedenti.

### Fase 0: Backup e Preparazione

Prima di toccare qualsiasi configurazione, ho preparato il punto di rollback:

- Snapshot delle VM Talos (CP e Worker) su Proxmox, via API token (permesso VM.Snapshot aggiunto al ruolo TerraformAdmin dopo un piccolo giro di `pveum`)
- Raft snapshot di Vault su S3 con il root token estratto da `init.json` (quello in `root-token.txt` era scaduto — scoperta fatta sul momento)
- Tag git `pre-pki-build` su tutti e tre i repository coinvolti

### Fase 1: Terraform — JWT Roles, PKI Policies, Namespace vso-system

Il codice Terraform per i ruoli JWT e le policy PKI era già stato scritto durante la progettazione. Ho esteso il modulo `vault-jwt-config` con otto policy PKI e otto ruoli JWT con `bound_claims` glob sulla claim `sub`. Parallelamente, ho aggiunto il namespace `vso-system` e il secret `vault-ca-cert` al modulo `k8s-engine`, e creato otto risorse VaultAuth in `tazlab-k8s` per la segregazione per-namespace.

Qui ho incontrato il primo intoppo: i ruoli JWT non possono usare `bound_claims` sulla claim `kubernetes.io/serviceaccount/namespace` perché il JWT emesso da Talos non include questa claim. Il ruolo esistente `vso-role-jwt` usava già il pattern corretto con `bound_service_account_names`, ma non me n'ero accorto fino alla review del log VSO.

### Fase 2: Il Motore PKI in Vault

L'abilitazione del PKI engine è stata rapida: mount `pki_root` con import della First Intermediate CA, mount `pki_int` con generazione del CSR, firma tramite `pki_root/root/sign-intermediate`, e `set-signed` con la catena completa (Tier 2 + Tier 1 + Tier 0). Ma due problemi hanno richiesto attenzione.

**Issue #17359 — Il Default Issuer Fantasma.** Dopo `set-signed`, l'endpoint `pki_int/issue/*` restituiva `ca_chain` vuoto. I certificati venivano emessi, ma senza catena intermedia — e senza catena, i client Go rifiutano il certificato con `tls: unknown certificate authority`. La causa è il multi-issuer engine introdotto in Vault 1.11. Ho dovuto creare un nuovo issuer con la catena completa e impostarlo come default:

```bash
vault write pki_int/root/replace default=<nuovo-issuer-id>
```

**Issue #16667 — I Parametri EC Fantasma.** Il bundle PEM della CA offline conteneva blocchi `-----BEGIN EC PARAMETERS-----` che il parser ASN.1 di Go non tollera. Rimossi manualmente con una regex.

Poi ho creato gli otto ruoli su `pki_int`: `internal-ingress` (no_store=false, allow_wildcard_certificates=true, TTL 168h), `cluster-local-mtls`, `database-server`, quattro ruoli `db-client-*` per ogni utente PostgreSQL, e `cluster-replication` per la replica intra-cluster. Ogni ruolo è stato configurato con i parametri emersi dalle ricerche: `signature_bits=256` per i client, `exclude_cn_from_sans` non supportato (parametro ignorato da Vault), `allow_bare_domains=true` per i CN username.

### Fase 3: Let's Encrypt per Blog e Wiki

Blog e wiki usavano il wildcard TLS statico, ottenuto manualmente mesi fa con `lego` e Cloudflare DNS-01 — nessun rinnovo automatico. Ho creato due Certificate resources in cert-manager: `blog-tazlab.net-tls` per quattro domini (blog.tazlab.net, tazlab.net, www, lab) e `wiki-tazlab.net-tls` per wiki.tazlab.net. Entrambi con ClusterIssuer `letsencrypt-issuer` e HTTP01 solver. Attivati in pochi secondi.

Poi ho aggiornato gli Ingress. La modifica è stata semplice, ma il primo push ha rotto la sintassi YAML di un Ingress (sezione `rules` mancante sotto `spec`). La lezione: controllare sempre il diff prima di pushare.

### Fase 4: Il Cutover del Wildcard

Il momento critico: sostituire il wildcard statico con il VaultPKISecret. Ho creato `vault-pki-tls` in `vso-system` con commonName `*.tazlab.net`, TTL 168h, e annotation per reflector verso auth e dex.

Poi migrato gli Ingress uno per uno: prima auth, verificato, poi dex. L'oauth2-proxy ha richiesto attenzione: doveva fidarsi del certificato Vault PKI per parlare con Dex via HTTPS. Ho aggiunto `--provider-ca-file=/etc/oauth2-proxy/pki/ca.crt` con mount del secret tramite `items:` (la proiezione subPath è rotta su Talos a causa dei symlink di Kubernetes — errore "not a directory").

L'ultimo passo: eliminare l'ExternalSecret `wildcard-tls` da `infrastructure/tls/`. Una riga cancellata, mesi di debito tecnico chiusi.

### Fase 5: mTLS su PostgreSQL — Dove Tutto si è Complesso

Il server-side TLS era semplice: `customTLSSecret` su PGO con il VaultPKISecret `tazlab-db-server-tls`. Ma PGO ignora il `ca.crt` dal Secret a meno che non sia dichiarato con `items:` esplicito. E `ssl_ca_file` di PostgreSQL — il file che PostgreSQL usa per verificare i certificati client — è **immutabile** in PGO: non può essere sovrascritto via `patroni.dynamicConfiguration`. L'unico canale è il bundle `ca.crt` nel Secret.

La CA da mettere in quel bundle non poteva essere solo la Root CA offline. Serviva la catena completa degli intermedi, perché PGO genera il server cert dalla customTLSSecret ma usa la propria CA interna per la replica. Ho costruito un bundle CA combinato: CA interna PGO + Tier 2 + Tier 1 + Tier 0 = 4 certificati in un unico file `ca.crt` nel Secret.

Poi ho aggiunto la regola pg_hba: `hostssl grafana grafana 0.0.0.0/0 cert`. E qui ho scoperto che il database deve essere esatto: se la regola dice `database=grafana` e il client si connette a `database=postgres`, la regola non matcha e PostgreSQL cade su `md5` chiedendo password. Una sottigliezza che mi ha fatto perdere 20 minuti.

**Grafana è stata la sfida più lunga del progetto.** Il chart `kube-prometheus-stack` non propaga le configurazioni come ci si aspetterebbe:

1. **`grafana.command` non è supportato** — il sotto-chart Grafana ignora completamente il campo `command`. L'ho scoperto dopo aver tentato di usarlo per copiare i certificati. Soluzione: `extraInitContainers`.
2. **`grafana.env` viene filtrato da `assertNoLeakedSecrets`** — il meccanismo di sicurezza del chart blocca le variabili che contengono stringhe sensibili. Disabilitato con `assertNoLeakedSecrets: false`.
3. **`extraSecretMounts` funziona** — ma richiede `defaultMode: 384` (0600 in ottale). La libreria libpq di Grafana rifiuta la chiave privata se ha permessi troppo permissivi.
4. **`extraVolumes` ha un bug noto** — a volte monta emptyDir invece della risorsa attesa. Workaround: init container che copia da Secret mount a emptyDir, usando `cp -HL` per i symlink.
5. **Il `containerSecurityContext.runAsUser`** deve essere 472 (l'UID di Grafana), non 1000 come avevo inizialmente — altrimenti Grafana non può leggere i file dei certificati.

La configurazione finale che ha funzionato dopo 5 tentativi e una ricerca specifica:

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
  containerSecurityContext:
    runAsUser: 472
    runAsGroup: 472
```

Il risultato: Grafana 3/3, `"database":"ok"`, e `pg_stat_ssl` mostra `usename=grafana, ssl=t`. Autenticazione via certificato client funzionante.

**pgAdmin e mnemosyne: rimandati.** pgAdmin 4 non supporta certificati client via variabili d'ambiente — richiede un file `servers.json`. L'app Go mnemosyne necessita di modifiche al codice per supportare la catena completa del certificato client (Go richiede leaf + intermedi nel file `sslcert`, a differenza di `psql` che accetta solo il foglio). Per ora continuano con password.

## I Debiti Tecnici

- **DNS Tailscale post-reboot**: dopo reboot dei nodi, il MagicDNS di Vault impiega 1-5 minuti a risolvere correttamente. Il ClusterSecretStore di ESO lo segnala come errore, bloccando Flux. Risolto con l'aumento del timeout Flux da 5 a 10 minuti. Su destroy+create non succede.
- **mTLS per pgAdmin e mnemosyne**: documentato, pianificato, non ancora implementato. Richiede `servers.json` per pgAdmin, modifica codice Go per mnemosyne.
- **TrustedRootsConfig non attivo**: il patch è persistito nella configurazione Talos, ma non ha effetto fino al prossimo reboot. Al destroy+create verrà integrato in Terraform `config_patches`.

## Le Lezioni

### La Progettazione CRISP Ha Pagato

Ogni problema incontrato in fase di implementazione era risolvibile rapidamente perché l'architettura di fondo era solida. Se avessi iniziato a scrivere codice senza la fase di ricerca e review, avrei dovuto rivedere l'architettura più volte — invece ho potuto concentrarmi sui dettagli operativi.

### Le Ricerche Sono un Investimento, Non un Costo

Ogni ricerca mi ha fatto risparmiare ore di tentativi. Senza la ricerca su PGO `ssl_ca_file`, avrei passato ore a cercare di sovrascrivere un parametro che PGO rende volutamente immutabile. Senza quella su Grafana, sarei ancora lì a chiedermi perché `grafana.command` viene ignorato.

### mTLS Non È Standardizzato tra le App

Un certificato client è un file. Il modo in cui ogni applicazione lo carica no. `psql` lo prende da variabili d'ambiente. Grafana da env vars specifiche (con nomi che cambiano a seconda della documentazione che leggi). pgAdmin da un file JSON. Go da una connection string. Ognuna di queste ha requisiti diversi sul formato (certificato foglia vs bundle), sui permessi (0600 necessario per libpq), e sul percorso.

### Overkill? Sì, Volutamente

Una PKI a tre livelli per un cluster da due nodi è oggettivamente eccessiva. Ma non è mai stato il punto. Il punto era dimostrare che un homelab può ospitare le stesse architetture che girano nei datacenter enterprise. Con gli strumenti giusti, la metodologia giusta, e la pazienza di fare le cose per bene.

## Cosa Succede Dopo

Il prossimo passo è un ciclo `destroy+create` — far nascere il cluster da zero e verificare che l'intero PKI si ricrei senza interventi manuali. Un vero test one-shot. Poi pgAdmin e mnemosyne a mTLS. Poi, finalmente, il progetto che ha reso tutto questo necessario: il **database PostgreSQL cross-site con failover automatico**, che ho sbloccato con questa PKI e che mi aspetta.

Ma questa è un'altra storia.

---

*Questo articolo fa parte di una serie sulla gestione dell'infrastruttura TazLab. I precedenti: [CRISP 2.0: Ricerca Obbligatoria, Piano Verificato, Zero Assunzioni]({{< ref "crisp-2-verified-research-methodology" >}}), [Primi Passi Verso i Segreti Dinamici]({{< ref "first-steps-toward-dynamic-secrets" >}}), [La Ricerca che ha Ucciso l'Injector]({{< ref "man-in-the-loop-vso-deep-research" >}}). Codice su [github.com/tazzo](https://github.com/tazzo).*
