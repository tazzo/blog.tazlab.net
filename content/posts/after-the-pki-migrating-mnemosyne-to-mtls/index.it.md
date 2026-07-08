+++
title = "Dopo la PKI: Migrare mnemosyne a mTLS"
date = 2026-07-08T21:00:00+02:00
draft = false
description = "Dopo il progetto PKI enterprise con Vault e la migrazione di Grafana al mTLS, è arrivato il momento di chiudere il cerchio con le applicazioni rimaste su password. Mnemosyne, l'unica app Go custom del cluster, è stata la prima — e la più semplice."
tags = ["PKI", "Vault", "Kubernetes", "mTLS", "PostgreSQL", "Go", "CRISP", "TazLab"]
categories = ["Infrastructure", "DevOps"]
author = "Taz"
+++

## Il Cerchio da Chiudere

Nel [post precedente]({{< ref "pki-vault-followup-root-ca-mtls-disaster-recovery" >}}) ho raccontato la certificazione del progetto PKI: cinque cicli destroy+create, la Root CA nei template VSO, il Grafana HelmRelease riparato, e il primo caso mTLS funzionante con Grafana connesso a PostgreSQL via certificato client.

Ma Grafana era un caso speciale. Usa un framework web (Go), sì, ma la configurazione è tutta in YAML Helm — niente codice da scrivere. La vera sfida era l'unica applicazione Go custom del cluster: **mnemosyne-mcp-server**, un MCP server per memoria semantica (embedding vettoriali con pgvector e Gemini).

Il suo codice `db.go` hardcodava `sslmode=disable` e richiedeva `DB_PASS` come obbligatorio. Fino a ieri, era l'ultimo cliente su password.

## Il Progetto PKI Aveva Già Fatto Tutto

Uno dei vantaggi di aver costruito il progetto PKI con metodo CRISP — ricerca obbligatoria, design verificato, review strutturate — è che quando arrivi alla fase di implementazione delle applicazioni client, la strada è già tracciata.

Il `VaultPKISecret` per mnemosyne (`db-client-mnemosyne-tls`) esisteva già, con TTL 24h e template VSO che generano `tls.crt`, `tls.key` e `ca.crt` (con la catena completa a tre livelli: Tier 2 + Tier 1 + Root CA). Il ruolo Vault `db-client-mnemosyne` era già configurato su `pki_int`. PostgreSQL (PGO v5.7.2) aveva già le regole `pg_hba` per accettare connessioni con certificato client.

Mancava solo l'app: doveva imparare a usare quei certificati.

## Il Refactor Go: Semplice, ma con un Punto di Attenzione

La modifica al codice è stata lineare. Ho aggiunto un `SSLConfig` a `db.go`:

```go
type SSLConfig struct {
    SSLMode     string
    SSLCert     string
    SSLKey      string
    SSLRootCert string
}

func New(host, port, user, password, dbname string, ssl *SSLConfig) (*DB, error) {
```

Il puntatore `nil` mantiene la compatibilità all'indietro: quando `ssl` è `nil`, la connessione usa `sslmode=disable` come prima. Quando viene fornito un `SSLConfig` con `SSLMode != ""`, costruisce la connection string con i parametri TLS.

Questa piccola modifica è stata un punto delicato delle review: è facile cadere nella tentazione di gestire solo `verify-full` (la modalità più sicura) e dimenticare che esistono `require` e `verify-ca` — meno sicuri ma utili in contesti specifici, come il debug o l'integrazione con servizi che non supportano la verifica del nome host. Tre review su questo progetto hanno girato intorno a questa sottigliezza, e ogni volta la condizione è stata allargata fino a coprire tutte le modalità.

```go
if dbPass == "" && dbSslMode != "require" && dbSslMode != "verify-ca" && dbSslMode != "verify-full" {
    missing = append(missing, "DB_PASS")
}
```

Questa piccola modifica è stata il punto più discusso del progetto: è facile cadere nella tentazione di gestire solo `verify-full` (la modalità più sicura) e dimenticare che esistono `require` e `verify-ca` — meno sicuri ma utili in contesti specifici, come il debug o l'integrazione con servizi che non supportano la verifica del nome host. Tre review su questo progetto hanno girato intorno a questa sottigliezza, e ogni volta la condizione è stata allargata fino a coprire tutte le modalità.

### defaultMode: 384

Il deployment Kubernetes monta il secret `db-client-mnemosyne-tls` nella directory `/etc/secrets/tls` con `defaultMode: 384` — che corrisponde a `0600` in ottale. La libreria `lib/pq` di Go (come tutte le librerie PostgreSQL) rifiuta la chiave privata se è leggibile da altri. È un dettaglio che ho già incontrato con Grafana e che vale la pena tenere a mente: **permessi troppo permissivi su `tls.key` sono l'errore più comune nelle configurazioni mTLS**.

## Rotazione Automatica: Un Test che Valeva la Pena

Il certificato client di mnemosyne ha TTL 24h. VSO (Vault Secrets Operator) lo rinnova circa ogni 20 ore (TTL - 4h di `expiryOffset`). Il `VaultPKISecret` ha `rolloutRestartTargets` che punta al deployment di mnemosyne: quando il secret cambia, il deployment viene riconciliato e il pod riparte con il nuovo certificato.

Per verificare che il meccanismo funzionasse, ho forzato una rotazione cancellando il secret Kubernetes. VSO lo ha rigenerato in circa 5 secondi, e il pod è stato rimpiazzato automaticamente (nuovo ReplicaSet, non un semplice restart). Il seriale del certificato è cambiato — e la connessione PostgreSQL è rimasta attiva. `pg_stat_ssl` mostrava `ssl=t, client_dn=/CN=mnemosyne` sia prima che dopo.

A questo proposito, ho anche testato la compatibilità all'indietro: ho rimosso temporaneamente le variabili SSL dal deployment, lasciando solo `DB_PASS`. Il pod si è riconnesso via password. `pg_stat_ssl` mostrava `ssl=f, client_dn=null`. Funzionante. Poi ho ripristinato le variabili SSL e rimosso definitivamente `DB_PASS` e le regole `md5` da `pg_hba`.

## I Problemi Incontrati

Il progetto è stato sorprendentemente pulito — soprattutto in confronto ai cinque cicli del PKI. I problemi reali sono stati solo due:

### YAML Indent

Il più stupido. Avevo aggiunto `rolloutRestartTargets` al `VaultPKISecret` mettendolo prima del blocco `transformation`. YAML ha regole di indentazione precise: dopo un mapping key che contiene una sequenza (i target della restart), non puoi tornare alla stessa indentazione con una nuova chiave. Il parser di Flux lo segnalava con un criptico `did not find expected '-' indicator`. L'ho spostato dopo il blocco `transformation` — alla stessa indentazione di `destination` — e ha funzionato.

### Riconciliazione Flux Lenta

La Kustomization che contiene le risorse di mnemosyne (`infrastructure-instances`) è in fondo a una catena di dipendenze di quattro livelli: da `infrastructure-operators-vso` fino a `infrastructure-configs` e giù a `infrastructure-instances`. Ogni livello deve essere `Ready=True` prima che il successivo possa eseguire. Dopo il push Git, ho dovuto triggerare manualmente le riconciliazioni per accelerare il processo — altrimenti ci sarebbero voluti diversi minuti per la propagazione completa. Non un bug, ma un comportamento fisiologico di Flux che è bene conoscere quando si lavora con catene di dipendenze profonde.

## pg_stat_ssl: La Prova

L'ultima verifica è stata la più soddisfacente:

```
 usename  | ssl |   client_dn
----------+-----+---------------
 mnemosyne | t   | /CN=mnemosyne
```

`ssl=t` significa che la connessione è crittografata con TLS. `client_dn=/CN=mnemosyne` significa che PostgreSQL ha verificato il certificato client, ha estratto il Common Name, e l'ha accettato. Niente password. Niente `DB_PASS` nella configurazione. Solo il certificato firmato da Vault PKI.

## Cosa Resta

Con mnemosyne migrato, la situazione delle app PostgreSQL è:

| App | Autenticazione | Stato |
|---|---|---|
| Grafana | Certificato client (mTLS) | ✅ Dal progetto PKI |
| **mnemosyne** | **Certificato client (mTLS)** | **✅ Fatto ora** |
| pgAdmin | Password | ⏳ Richiede servers.json |
| Vault DB engine | Password (scram-sha-256) | ⏳ Richiede Vault Agent |
| TazLab CLI (tazpod) | Password locale | 🔒 Non in cluster |

Le prossime due migrazioni (pgAdmin e Vault DB engine) sono già pianificate come progetti CRISP separati. Ma hanno un livello di complessità diverso: pgAdmin richiede la gestione di un file `servers.json` preconfigurato con percorsi dei certificati; il Vault DB engine richiede un Vault Agent sidecar sulla VM Hetzner, un pattern HashiCorp enterprise che non ho mai implementato prima.

Per ora, però, il cerchio del progetto PKI — iniziato con l'obiettivo di eliminare password statiche da tutte le connessioni al database — si è chiuso con un'altra tacca. Due app su cinque. Tre ancora da fare. Ma il pattern è ormai consolidato.

---

*Questo articolo fa parte di una serie sulla gestione dell'infrastruttura TazLab. I precedenti: [Vault PKI Follow-Up]({{< ref "pki-vault-followup-root-ca-mtls-disaster-recovery" >}}), [PKI Vault su TazLab]({{< ref "pki-vault-tazlab-enterprise-homelab" >}}). Codice su [github.com/tazzo](https://github.com/tazzo).*
