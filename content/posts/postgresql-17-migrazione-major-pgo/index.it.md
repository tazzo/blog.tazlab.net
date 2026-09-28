+++
title = "L'Ordine dei Commit: Migrare PostgreSQL da 16 a 17 su Kubernetes"
date = 2026-09-27T08:20:00+02:00
draft = false
description = "Il cluster PostgreSQL condiviso del laboratorio è passato da 16 a 17 con la procedura dichiarativa di PGO: novanta secondi di lavoro sui dati, sei minuti di fermo, ottanta pod in salute. E due errori che la ricerca aveva portato con sé, visibili solo eseguendo."
tags = ["postgresql", "pgo", "kubernetes", "gitops", "database"]
author = "Tazzo"
+++

## Perché migrare un database che funziona

Il cluster PostgreSQL condiviso del laboratorio serve quattro database e sette consumatori: hindsight, mnemosyne, pgadmin, Grafana e la compagnia di agenti Paperclip, in due container. Funzionava bene a PostgreSQL 16, e non c'era alcuna urgenza tecnica.

La spinta è arrivata da fuori: uno strumento che voglio adottare richiede **PostgreSQL 17**, dichiarato come requisito esplicito nella sua documentazione. La scelta era tra costruire un secondo database solo per lui, oppure migrare quello che ho già. La seconda strada è quella che tiene il laboratorio semplice, ma comporta un'operazione che **non è reversibile**: l'avanzamento di major di PostgreSQL riscrive il catalogo di sistema sul volume, e non esiste un modo dichiarativo di tornare indietro.

## La preparazione è tutto

Prima di toccare qualsiasi cosa, tre lavori che sembrano burocrazia e sono la sostanza.

Il primo: **capire cosa dicono davvero la documentazione e il cluster**. Ho verificato la [procedura ufficiale](https://access.crunchydata.com/documentation/postgres-operator/5.7/guides/major-postgres-version-upgrade/) della linea che ho installata (Crunchy Postgres for Kubernetes 5.7.2), non quella più recente, e ho ispezionato lo stato vivo: versione dell'operatore, tag delle immagini nelle sue variabili, estensioni installate in **ogni** database, capacità libera sul nodo che ospita il volume. Alcune di queste verifiche hanno smentito il piano che avevo scritto, ed è il motivo per cui le ho fatte.

Il secondo: **togliere `spec.dataSource` dal manifest**. Quel campo serve al bootstrap e al disaster recovery; lasciato lì durante un major upgrade, il controller tenta di riconciliare un ripristino mentre crea il nuovo instance set, e l'opzione `--delta` può riallineare i blocchi appena convertiti alla versione precedente. L'ho rimosso con un commit dedicato e ho verificato che il database **non si riavviasse**: zero restart, versione invariata.

Il terzo: **un backup completo e verificato**, più la consapevolezza della via di rientro. Il laboratorio ha già il suo meccanismo: backup full più WAL su S3, e ricreazione del cluster dal `dataSource`. È quello che uso nei cicli distruttivi, e per un database di 306 MB significa pochi minuti. Curiosamente, la parte difficile è stato capire cosa **non** funziona: il "revert in place" di uno snapshot del volume su un PVC già collegato non esiste, né nello standard CSI né nel motore di storage. Il rollback in place che avevo pianificato era un'illusione, e valeva la pena scoprirlo prima.

## La finestra

L'ordine dei commit non è una preferenza, è un requisito tecnico. In un unico commit: l'oggetto `PGUpgrade` che dichiara la coppia di versioni, `spec.shutdown: true`, l'annotazione che autorizza l'upgrade su quel cluster (un meccanismo a due chiavi: l'oggetto deve volere il cluster, e il cluster deve permettere l'oggetto), e la sospensione delle schedulazioni di backup — perché con l'istanza spenta un backup schedulato fallisce immediatamente invece di mettersi in coda, e riempirebbe il sistema di avvisi.

Poi l'attesa, e infine i due commit che chiudono: la **rimozione dell'oggetto** e, solo dopo, `postgresVersion: 17` con `shutdown: false`. Invertire quest'ordine fa fallire l'upgrade, perché il controller rifiuta la riconciliazione quando un cluster già alla nuova versione ha ancora davanti l'oggetto che l'ha portato lì.

I numeri finali: **novanta secondi** per la fase sui dati, **sei minuti** di fermo totale, dal momento in cui il cluster si è spento al riavvio con la 17. Il resto del tempo non è stato il database: sono state le transizioni di Kubernetes, lo stacco e il riattacco del volume, e la riconciliazione di GitOps.

## Le estensioni, che è la parte che tocca i dati

Un major upgrade non aggiorna le estensioni da sé. Due meritano attenzione opposta.

**`pgaudit`** è compilata contro l'ABI del motore: non esistono script di migrazione fra major, quindi `ALTER EXTENSION ... UPDATE` fallisce. Va eliminata e ricreata — è senza stato, non registra dati propri. Nel laboratorio era installata in **tutti e sette** i database, non solo dove pensavo: se avessi seguito il piano originale ne avrei lasciate sei alla versione precedente, e l'aggiornamento automatico sarebbe fallito.

**`vector`** (pgvector) va invece aggiornata **solo** con `ALTER`. Eliminarla distruggerebbe a cascata le colonne vettoriali e i loro indici: un'operazione che sembra manutenzione e cancella dati.

## Le due cose che la ricerca aveva sbagliato

Avevo fatto preparare due ricerche approfondite prima di eseguire. Erano solide e mi hanno risparmiato errori veri — l'ordine dei commit, il comportamento del pooler, la gestione delle estensioni. Ma portavano con sé **due difetti della stessa natura**: materiale di una versione più nuova applicato alla nostra.

Il primo: un campo dell'oggetto di upgrade, `spec.transferMethod`, che esiste nella documentazione della versione **6.0** della CRD ma **non** in quella installata. L'API server l'ha rifiutato con un messaggio inequivocabile — *field not declared in schema* — e la riconciliazione si è fermata finché non l'ho tolto.

Il secondo: i tag delle immagini da pre-scaricare, indicati come `17.2-0` e `1.23-0` quando l'operatore installato usa `17.2-1` e `1.23-2`. Il pre-pull avrebbe scaricato immagini inutilizzate e il download vero sarebbe avvenuto dentro la finestra, cioè il contrario dello scopo.

La lezione non è "le ricerche non servono": è che **la documentazione più recente non è la documentazione della tua versione**. Le variabili dell'operatore e lo schema della CRD installata sono la verità, e vanno interrogati direttamente.

## Cosa resta

Il cluster serve ora PostgreSQL 17.2, le estensioni sono allineate, ottanta pod sono in salute e ogni consumatore è stato interrogato con una query reale, non solo guardato dal "pod pronto". La rete di sicurezza non è servita, e il backup full pre-upgrade resta su S3.

Due cose sono rimaste aperte e vale la pena dirle. La catena di riconciliazione di GitOps, in questo laboratorio, si incastra: dopo ogni commit alcune risorse restano in attesa di una dipendenza che è già pronta, e ho dovuto forzare le riconciliazioni in ordine tre volte. Allunga le finestre e non è un problema di PostgreSQL. E la documentazione durevole è ora indietro rispetto alla realtà, come sempre dopo un cambiamento riuscito: è il primo lavoro del prossimo giro.

Se c'è una cosa che porto via da questa migrazione, è che il valore del piano non stava nell'elenco dei comandi. Stava nell'**ordine** — quale commit prima di quale, e perché — e nella **verifica**: tutto ciò che ho dato per scontato è stato smentito dai fatti, e tutto ciò che ho verificato ha tenuto.
