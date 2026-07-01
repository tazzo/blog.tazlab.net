+++
title = "PKI Vault su TazLab: come ho costruito una PKI enterprise in un homelab"
date = 2026-07-01T15:00:00+02:00
draft = false
description = "Dieci ricerche, quindici review, un giorno di implementazione: il percorso per portare una PKI a tre livelli con Vault, Let's Encrypt e mTLS su PostgreSQL in un cluster Kubernetes Talos. Un progetto nato come prerequisite per il database multi-cluster, cresciuto fino a diventare il tassello più complesso dell'infrastruttura."
tags = ["Vault", "PKI", "Kubernetes", "Talos", "PostgreSQL", "mTLS", "Grafana", "Let's Encrypt", "CRISP", "TazLab"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

## Il Percorso, Non L'Urgenza

Se seguite la storia di TazLab da qualche mese, avrete notato un filo conduttore: la migrazione verso **segreti dinamici**. Non sostituire un fornitore di secret con un altro, ma cambiare paradigma — da credentiali statiche, scritte nei manifest YAML e ruotate manualmente, a credenziali generate al volo, con lease, rotazione automatica e zero contatto umano.

[Nel post precedente]({{< ref "first-steps-toward-dynamic-secrets" >}}) raccontavo i primi passi: JWT auth, Vault Agent Injector, il disastro del PKI di Talos. Poi [la scoperta di VSO]({{< ref "man-in-the-loop-vso-deep-research" >}}) e la decisione di abbandonare l'injector. Poi [la formalizzazione del metodo CRISP]({{< ref "crisp-2-verified-research-methodology" >}}): ricerca prima di scrivere codice, marker di verifica nei piani, review obbligatorie.

Ogni passo ha preparato il terreno per questo progetto: **la PKI**.

L'obiettivo finale? Poter replicare il database PostgreSQL su due cluster (Proxmox + Hetzner) con failover automatico. Per farlo, serve mTLS — certificati client, non password — perché le password statiche non sopravvivono a un failover, e quelle dinamiche generano lease che scadono al riavvio sbagliato. La PKI era già nel piano di lungo termine per alzare il livello di sicurezza del laboratorio. È diventata un prerequisito operativo per il passo successivo.

Questo articolo racconta quel progetto: un mese di progettazione, dieci ricerche, quindici review, e un giorno di implementazione.

## L'Architettura: Una PKI a Tre Livelli per un Cluster da Due Nodi

Prima di scrivere una riga di codice, ho passato settimane nella fase di design. Il metodo **CRISP** (Context, Research, Intent, Structure, Plan) richiedeva di rispondere a una domanda fondamentale: qual è l'architettura giusta per una PKI che deve essere sicura, ma gestibile su un cluster Talos con un control plane e un worker?

La risposta è stata una **PKI a tre livelli** — overkill per un homelab, ma è esattamente ciò che volevo imparare:

- **Tier 0**: Offline Root CA (ECDSA P-384, 20 anni di validità) — generata su una macchina air-gapped, chiave cifrata con GPG AES-256, mai esposta online. È l'ancora di fiducia. Se Vault viene compromesso, la Root CA resta al sicuro.
- **Tier 1**: First Intermediate CA (10 anni) — importata in Vault come `pki_root`.
- **Tier 2**: Second Intermediate CA (5 anni) — generata e gestita interamente da Vault come `pki_int`, con ruoli specifici per ogni tipo di certificato.

La divisione dei domini è stata altrettanto chiara:

- **Pubblico** (browser trust): blog.tazlab.net, wiki.tazlab.net, tazlab.net → Let's Encrypt via cert-manager
- **Interno** (tailnet): auth.tazlab.net, dex.tazlab.net, `*.tazlab.net` → Vault PKI
- **Database**: TLS server PostgreSQL + certificati client per ogni utente → Vault PKI

## Le Ricerche: Il Vero Lavoro è Stato Capire

Uno degli aspetti che ha reso questo progetto particolarmente complesso è stato il numero di ricerche necessarie prima di poter iniziare l'implementazione. Il metodo CRISP richiede che ogni decisione di design sia confermata da fonti esterne — non ci si affida alla memoria del modello linguistico. Questo ha portato a un processo di ricerca strutturato che ha prodotto sedici documenti di approfondimento, dieci nella fase di progettazione e sei durante l'implementazione.

### La Fase di Progettazione: R26—R35

Durante la progettazione iniziale, ho commissionato dieci ricerche su temi specifici:

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

Ogni ricerca ha prodotto un documento Markdown archiviato nel progetto CRISP. Ogni ricerca ha contribuito a raffinare il design. Molte hanno rivelato complessità che un'analisi superficiale non avrebbe colto.

### La Fase di Implementazione: Sei Ricerche sul Campo

Quando ho iniziato l'implementazione, ho scoperto che la teoria e la pratica non sempre coincidono. Ho dovuto commissionare altre sei ricerche:

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

Con il design approvato e le ricerche completate, l'implementazione è stata sorprendentemente rapida: circa 12 ore di lavoro. Ma ogni fase ha portato le sue sfide.

### Fase 0: Backup e Preparazione

- Snapshot delle VM Talos (CP e Worker) su Proxmox
- Raft snapshot di Vault su S3
- Tag git `pre-pki-build` sui tre repository coinvolti

### Fase 1: Terraform

Ho esteso il modulo Terraform `vault-jwt-config` con otto policy PKI e otto ruoli JWT. Qui ho incontrato il primo intoppo: i ruoli JWT non possono usare `bound_claims` sulla claim `kubernetes.io/serviceaccount/namespace` perché il JWT emesso da Talos non include questa claim. La soluzione è usare glob sulla claim `sub`:

```hcl
bound_claims      = { sub = "system:serviceaccount:${namespace}:${serviceaccount}" }
bound_claims_type = "glob"
```

### Fase 2: Il Motore PKI

L'abilitazione del PKI engine è stata lineare. Ma due problemi hanno richiesto attenzione.

**Il Default Issuer Fantasma (Issue #17359)**

Dopo `set-signed`, l'endpoint `pki_int/issue/*` restituiva `ca_chain` vuoto. I certificati venivano emessi, ma senza catena intermedia. I client Go rifiutavano il certificato con `tls: unknown certificate authority`.

La causa: Vault 1.11+ ha introdotto il multi-issuer engine. Importare una CA non la imposta automaticamente come default. Ho dovuto creare un nuovo issuer, importare la catena completa, e impostarlo come default:

```bash
vault write pki_int/root/replace default=<nuovo-issuer-id>
```

**I Parametri EC Fantasma (Issue #16667)**

Il bundle PEM della CA offline conteneva blocchi `-----BEGIN EC PARAMETERS-----` che il parser ASN.1 di Go non tollera. Rimossi manualmente.

### Fase 3: Let's Encrypt per Blog e Wiki

Blog e wiki usavano il wildcard TLS statico, ottenuto manualmente con Cloudflare DNS-01. Ho creato due Certificate resources in cert-manager con ClusterIssuer HTTP01 — entrambi attivi in pochi secondi.

### Fase 4: Il Cutover del Wildcard

Il momento critico: migrare auth e dex dal wildcard statico al VaultPKISecret. Ho creato `vault-pki-tls` in `vso-system` con commonName `*.tazlab.net`, TTL 168h, e annotation per reflector.

Poi migrato gli Ingress uno per uno, verificando ogni passo. L'oauth2-proxy ha richiesto attenzione extra: doveva fidarsi del certificato Vault PKI per parlare con Dex. Aggiunto `--provider-ca-file` con mount esplicito.

### Fase 5: mTLS su PostgreSQL — Il Vero Ostacolo

L'autenticazione client-server per PostgreSQL doveva passare da password a certificato. Qui ho scoperto che il diavolo sta nei dettagli — e ogni dettaglio è diverso per ogni applicazione.

**Il Server TLS**

Il Crunchy PostgreSQL Operator (PGO) gestisce i certificati server tramite `customTLSSecret`. Ma ignora il `ca.crt` a meno che non sia dichiarato con `items:` esplicito:

```yaml
customTLSSecret:
  name: tazlab-db-server-tls
  items:
    - key: ca.crt; path: ca.crt
    - key: tls.crt; path: tls.crt
    - key: tls.key; path: tls.key
```

Inoltre, `ssl_ca_file` di PostgreSQL è **immutabile** in PGO — non può essere sovrascritto via `patroni.dynamicConfiguration`. L'unico modo per aggiungere una CA custom è nel bundle `ca.crt` del Secret. Con PGO, questo è l'unico canale.

**La Catena Incompleta**

I client Go rifiutavano il certificato con `tls: unknown certificate authority`, anche se `openssl s_client` dava `Verify return code: 0`. La differenza? Go richiede che il server INVII la catena intermedia durante l'handshake. `openssl` la scarica automaticamente — Go no.

**Grafana: La Sfida Più Lunga**

Configurare Grafana per il client certificate è stato il compito più lungo del progetto. Il chart `kube-prometheus-stack` non propaga le configurazioni come ci si aspetterebbe:

1. **`grafana.command` non è supportato** — ignorato dal chart. Sostituito con `extraInitContainers`.
2. **`grafana.env` filtrato da `assertNoLeakedSecrets`** — disabilitato con `assertNoLeakedSecrets: false`.
3. **`extraSecretMounts` funziona** — con `defaultMode: 384` (0600). La libreria libpq rifiuta la chiave se ha permessi troppo permissivi.
4. **`extraVolumes` bug** — a volte monta emptyDir invece della risorsa attesa. Workaround: init container che copia da Secret a emptyDir.

La configurazione finale:

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

pgAdmin 4 non supporta certificati client via variabili d'ambiente — richiede un file `servers.json`. L'app Go mnemosyne necessita di modifiche al codice per la catena completa. Per ora continuano con password.

## I Debiti Tecnici

- **Longhorn CSI**: 3 repliche per sidecar su 1 worker → crashano. Ridotto a 1.
- **DNS Tailscale post-reboot**: dopo reboot, il MagicDNS di Vault impiega minuti a risolvere. Aumentato timeout Flux a 10 minuti. Su destroy+create non succede.
- **mTLS per pgAdmin e mnemosyne**: documentato, pianificato, non implementato.

## Le Lezioni

### La Progettazione CRISP Ha Pagato

Ogni problema incontrato in fase di implementazione era risolvibile rapidamente perché l'architettura di fondo era solida. Se avessi iniziato a scrivere codice senza la fase di ricerca, avrei dovuto rivedere l'architettura più volte.

### Le Ricerche Sono un Investimento, Non un Costo

Ogni ricerca mi ha fatto risparmiare ore. Senza la ricerca su PGO, avrei passato ore a cercare di sovrascrivere un parametro che PGO rende volutamente immutabile. Senza quella su Grafana, sarei ancora a chiedermi perché il chart ignora `grafana.command`.

### mTLS Non È Standardizzato

Un certificato client è un file. Il modo in cui ogni applicazione lo carica no. `psql` usa variabili d'ambiente. Grafana env vars specifiche. pgAdmin un file JSON. Go una connection string. Ognuna ha requisiti diversi sul formato e sui permessi.

### Overkill? Sì, Volutamente

Una PKI a tre livelli per un cluster da due nodi è oggettivamente eccessiva. Ma non è mai stato il punto. Il punto era dimostrare che un homelab può ospitare le stesse architetture che girano nei datacenter enterprise. Con gli strumenti giusti, la metodologia giusta, e la pazienza di fare le cose per bene.

## Cosa Succede Dopo

Il prossimo passo è un ciclo `destroy+create` — far nascere il cluster da zero e verificare che l'intero PKI si ricrei senza interventi manuali. Poi pgAdmin e mnemosyne a mTLS. Poi, finalmente, il progetto che ha reso tutto questo necessario: il **database PostgreSQL cross-site con failover automatico**, che ho sbloccato con questa PKI e che mi aspetta.

Ma questa è un'altra storia.

---

*Questo articolo fa parte di una serie sulla gestione dell'infrastruttura TazLab. I precedenti: [CRISP 2.0: Ricerca Obbligatoria, Piano Verificato, Zero Assunzioni]({{< ref "crisp-2-verified-research-methodology" >}}), [Primi Passi Verso i Segreti Dinamici]({{< ref "first-steps-toward-dynamic-secrets" >}}), [La Ricerca che ha Ucciso l'Injector]({{< ref "man-in-the-loop-vso-deep-research" >}}). Codice su [github.com/tazzo](https://github.com/tazzo).*
