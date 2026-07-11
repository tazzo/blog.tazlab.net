+++
title = "Completare la PKI: pgAdmin mTLS e la pulizia del Vault"
date = 2026-07-08T23:00:00+02:00
draft = false
description = "Dopo Grafana e mnemosyne, è il turno di pgAdmin: l'ultima app del cluster a passare al client certificate PostgreSQL. Un progetto semplice, senza codice da scrivere, con una sorpresa sulle regole pg_hba e una dimenticanza nel kustomization."
tags = ["PKI", "Vault", "Kubernetes", "mTLS", "PostgreSQL", "pgAdmin", "TazLab"]
categories = ["Infrastructure", "DevOps"]
author = "Taz"
+++

## Il Terzo: Sempre Più Facile

Nei [due]({{< ref "pki-vault-followup-root-ca-mtls-disaster-recovery" >}}) [post]({{< ref "after-the-pki-migrating-mnemosyne-to-mtls" >}}) precedenti ho raccontato la migrazione a mTLS di Grafana e mnemosyne. Il primo ha richiesto cinque cicli destroy+create e la riparazione di mezzo HelmRelease; il secondo ha richiesto un refactor Go, una review del codice, e un paio di test di rotazione.

pgAdmin doveva essere il più semplice. Ed è stato effettivamente il più semplice — ma non è stato senza sorprese.

## Cosa c'era già

A differenza di mnemosyne, dove dovevo modificare il codice Go e aggiungere env var e volume mount da zero, il deployment di pgAdmin **aveva già** tutto quello che serviva da commit del progetto PKI: il volume mount del secret `db-client-pgadmin-tls` in `/etc/pgadmin/certs` e le variabili d'ambiente `PGSSLMODE=verify-full`, `PGSSLCERT`, `PGSSLKEY`, `PGSSLROOTCERT`. Il `VaultPKISecret` era già deployato con TTL 24h.

Qualcuno (il me del passato, durante il progetto PKI) aveva già pensato a pgAdmin. Mancavano solo i dettagli finali.

## Cosa mancava

Quattro cose, tutte piccole:

**1. `rolloutRestartTargets`**. Il `VaultPKISecret` non aveva il riferimento al deployment di pgAdmin. Significa che quando VSO ruota il certificato (ogni 24h), il secret cambia ma il pod non si riavvia. Il nuovo certificato non viene caricato finché qualcuno non cancella il pod manualmente. Aggiunto — stesso pattern di mnemosyne.

**2. `defaultMode: 384`**. Il volume mount del secret non specificava i permessi. La libreria `libpq` (che pgAdmin usa sotto il cofano) richiede che la chiave privata `tls.key` abbia permessi `0600` — leggibile solo dal proprietario. Senza `defaultMode: 384` (che è `0600` in ottale), pgAdmin non può usare la chiave. Un dettaglio che ho già incontrato due volte e che vale la pena tenere a mente.

**3. `PGSSLROOTCERT` puntava a un file inesistente**. Il deployment diceva `/etc/pgadmin/certs/ca_chain`, ma il file generato da VSO si chiama `ca.crt`. Con `excludeRaw: true` nel template, VSO genera solo `tls.crt`, `tls.key` e `ca.crt` — non `ca_chain`. Un errore silenzioso: pgAdmin parte, ma le connessioni SSL con verifica della CA falliscono. Fixato a `/etc/pgadmin/certs/ca.crt`.

**4. Le regole `pg_hba`**. Le uniche regole per pgadmin in PostgreSQL erano di tipo `md5` (password). Ho aggiunto `hostssl postgres pgadmin ... cert` per abilitare l'autenticazione con certificato, e subito dopo `host postgres pgadmin ... reject` per impedire il fallback a password. Un pattern che ho imparato dalla review di mnemosyne: se non blocchi esplicitamente la password dopo il `cert`, la regola generica `host all all ... md5` continua a funzionare.

### servers.json

L'unica aggiunta nuova: una ConfigMap con un `servers.json` pre-configurato. pgAdmin è una GUI: l'utente deve connettersi manualmente al database ogni volta. Con questo file, il server "TazLab Database" compare già nella lista, con i path dei certificati già impostati. Niente ricerca dei percorsi. Niente configurazione manuale.

## La Sorpresa: il Kustomization

L'unico vero problema è stato banale: ho creato il file `servers-configmap.yaml` ma mi sono dimenticato di aggiungerlo al `kustomization.yaml`. Il pod nuovo partiva, l'init container restava in `PodInitializing` per minuti, e il log dell'evento diceva:

```
MountVolume.SetUp failed for volume "pgadmin-config" : configmap "pgadmin-servers" not found
```

La ConfigMap non esisteva perché Flux non la stava creando. Aggiungere una riga al `kustomization.yaml` ha risolto. Una dimenticanza stupida, ma che ha bloccato il rollout per dieci minuti buoni finché non ho capito cosa mancava.

## Cosa Cambia per l'Infrastruttura

Con pgAdmin migrato, la situazione delle applicazioni PostgreSQL è:

| App | Autenticazione | Stato |
|---|---|---|
| Grafana | Certificato client | ✅ |
| mnemosyne | Certificato client | ✅ |
| pgAdmin | Certificato client | ✅ |
| Vault DB engine | — | ⏳ In rimozione (non serve più) |

## E il Vault Database Engine? Rimosso.

L'ultimo punto della tabella — il Vault database engine — merita un approfondimento. Quando ho scritto la prima bozza di questo articolo, era ancora una domanda aperta: lo tengo per future automazioni, o lo rimuovo?

Ho fatto una ricerca enterprise approfondita, con fonti HashiCorp, best practice di sicurezza e analisi dei rischi. La risposta è stata chiara: **va rimosso**.

Il database engine (`database/`) era stato abilitato per generare utenti PostgreSQL dinamici — password temporanee con lease, create al volo e ruotate automaticamente. Era il meccanismo che usava Grafana prima di passare al certificato client. Ora che tutte le applicazioni usano mTLS, non c'è più nessun consumer.

Mantenerlo attivo significherebbe tenere una credenziale amministrativa PostgreSQL (`CREATEROLE`) dentro Vault per nessun motivo. Un potenziale vettore di privilege escalation senza alcun beneficio operativo. La ricerca ha anche evidenziato un problema di performance: il database engine esegue CREATE ROLE e DROP ROLE continuamente, frammentando i cataloghi di sistema di PostgreSQL.

Quindi sì: `vault secrets disable database`, revoca dei lease, rimozione dell'utente `vault-admin` da PostgreSQL. La configurazione Terraform resta nei repository — ricrearla in futuro, se dovesse servire, richiede secondi.

Tre app su tre al certificato client. Zero password. Zero engine inutilizzati.

---

*Questo articolo fa parte di una serie sulla gestione dell'infrastruttura TazLab. I precedenti: [Dopo la PKI: Migrare mnemosyne a mTLS]({{< ref "after-the-pki-migrating-mnemosyne-to-mtls" >}}), [Vault PKI Follow-Up]({{< ref "pki-vault-followup-root-ca-mtls-disaster-recovery" >}}). Codice su [github.com/tazzo](https://github.com/tazzo).*
