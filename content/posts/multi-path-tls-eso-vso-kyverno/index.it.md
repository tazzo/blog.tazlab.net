+++
title = "Dall'Idea al Fallimento al Compromesso: la Migrazione di un Certificato TLS attraverso Tre Operatori"
date = 2026-06-01T17:30:00+02:00
draft = false
description = "Dopo aver migrato tutto a VSO, restavano alcuni segreti su ESO. Sembrava un'attività semplice. Invece è stata un'odissea attraverso un deadlock del controller, un merge engine che non mergeva, e tre operatori diversi. Alla fine la soluzione era quella da cui eravamo partiti."
tags = ["vso", "vault", "eso", "kyverno", "reflector", "kubernetes", "tls", "secret-management", "crisp", "enterprise"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# Dall'Idea al Fallimento al Compromesso: la Migrazione di un Certificato TLS attraverso Tre Operatori

## Introduzione

Nel post precedente ho descritto come CRISP 2.0 ci ha permesso di migrare tre progetti Vault in un pomeriggio con zero bug. La narrazione si concludeva con tutte le VaultStaticSecret migrate da External Secrets Operator (ESO) a Vault Secrets Operator (VSO), e tutti i segreti dinamici riconfigurati.

Non era del tutto vero. Alcuni segreti erano rimasti su ESO.

Cinque erano copie dello stesso certificato wildcard TLS, distribuite in namespace diversi. L'ultimo era un segreto OAuth per Tailscale. Tutti condividevano la stessa caratteristica: i dati non erano memorizzati in Vault come un unico segreto con più chiavi, ma come path separati — il certificato da una parte, la chiave privata dall'altra.

Sembrava un'attività semplice. Creare una VaultStaticSecret per ogni segreto, come avevamo fatto per gli altri venti. Invece è stato un viaggio attraverso limitazioni architetturali di VSO, un deadlock nel controller, un merge engine che non mergeva, e una ricerca che ci ha portati a riscoprire l'ovvio: la soluzione migliore era quella da cui eravamo partiti.

## Il Problema: Due Path Vault per un Solo Segreto TLS

Il certificato wildcard di TazLab è memorizzato in HashiCorp Vault su due path separati:

```
secret/data/tazlab-k8s/static/tls/wildcard/WILDCARD_CRT   → {value: "<certificato PEM>"}
secret/data/tazlab-k8s/static/tls/wildcard/WILDCARD_KEY   → {value: "<chiave privata>"}
```

Questa separazione è voluta: in molti ambienti enterprise, certificati e chiavi private sono gestiti da pipeline diverse e talvolta da team diversi. Non è una scelta progettuale discutibile — è una pratica di sicurezza che ha senso. Ma crea un problema tecnico quando un orchestrator Kubernetes deve produrre un unico segreto `kubernetes.io/tls` che contiene entrambi.

Con ESO, questo non era mai stato un problema. Una singola `ExternalSecret` legge da due path Vault diversi e li fonde in un unico segreto Kubernetes usando il template engine:

```yaml
# ExternalSecret — funzionante da mesi
data:
  - secretKey: crt
    remoteRef:
      key: tazlab-k8s/static/tls/wildcard/WILDCARD_CRT
      property: value
  - secretKey: key
    remoteRef:
      key: tazlab-k8s/static/tls/wildcard/WILDCARD_KEY
      property: value
target:
  template:
    data:
      tls.crt: "{{ .crt }}"
      tls.key: "{{ .key }}"
```

La migrazione a VSO sembrava lineare. Una `VaultStaticSecret`, un path, una trasformazione. Peccato che VSO imponga un rapporto 1:1: una VaultStaticSecret legge un solo path Vault e produce un solo segreto Kubernetes. È una limitazione architetturale documentata, non un bug. Per unire due path servono due VaultStaticSecret.

E qui cominciano i problemi.

## Primo Tentativo: Due VSS con VaultAuth Condiviso

La soluzione più ovvia: due VaultStaticSecret nella stessa namespace, entrambe con `vaultAuthRef: vso-system/vso-jwt-auth`, ognuna che legge un path diverso e scrive sullo stesso segreto di destinazione.

```yaml
# VSS 1: legge WILDCARD_CRT, scrive tls.crt
# VSS 2: legge WILDCARD_KEY, scrive tls.key
# Entrambe → destination: wildcard-tls (stesso nome)
```

Sembrava funzionare. Le VaultStaticSecret venivano create, i VaultAuth erano Healthy. Ma dopo qualche secondo le VSS in più namespace mostravano stato vuoto — nessun errore, nessuna colonna, solo righe bianche nella `kubectl get`.

Analizzando i log del controller VSO, è emerso un pattern preciso: solo 3 VSS su 10 venivano processate, e le loro `lifetimeWatcher` restavano in stato "Starting" senza mai completarsi. Le altre 7 non venivano processate affatto.

La causa era una race condition nel controller VSO, riconducibile a meccanismi di lock interno della `cachingClientFactory`. Quando più VSS nella stessa namespace condividono lo stesso VaultAuth, condividono la stessa chiave di cache per l'autenticazione Vault. La prima VSS acquisisce il lock e crea il client. La seconda tenta di registrare una callback sullo stesso client già in esecuzione — ma il canale di callback è unbuffered, e poiché il ricevitore non ha ancora avviato il loop di ascolto, la scrittura si blocca indefinitamente. Il lock non viene mai rilasciato, e tutte le VSS successive non possono più procedere.

Il controller VSO ha 100 worker thread, ma se tutti e 100 condividono lo stesso lock — perché tutte le VSS puntano allo stesso VaultAuth — sono tutti bloccati.

## Secondo Tentativo: VaultAuth per Namespace

La prima idea: creare un VaultAuth dedicato per ogni namespace target. Questo avrebbe forzato chiavi di cache diverse e isolato il deadlock a un namespace per volta.

Ho creato 5 VaultAuth locali, uno per namespace. Funzionava: le VSS in namespace diversi non si bloccavano più a vicenda. Ma all'interno dello stesso namespace, la seconda VSS provocava ancora il deadlock. Con due VSS per namespace (una per CRT, una per KEY), la prima VSS acqusiva il lock, la seconda si bloccava.

Il problema era strutturale: con due VSS per namespace, la seconda si deadlockava sempre.

## Terzo Tentativo: Kyverno per il Merge

A questo punto la strada sembrava chiara: serviva un terzo componente che si occupasse del merge. Kyverno sembrava la scelta naturale — un policy engine Kubernetes che può generare risorse in risposta a eventi.

Il piano era:
1. Due VaultStaticSecret in `vso-system` con due VaultAuth diversi (nomi diversi → chiavi di cache diverse → niente deadlock)
2. Ognuna produce un segreto intermedio (`wildcard-crt`, `wildcard-key`)
3. Kyverno osserva i due intermedi, li fonde in un unico segreto `kubernetes.io/tls`
4. Reflector (EmberStack) distribuisce il segreto nei namespace target

Il setup funzionava. Le VSS erano Synced/Healthy/Ready. Il ClusterPolicy Kyverno era stato creato. Poi ho scoperto il problema.

**Il generate di Kyverno con data source non reagisce agli update del trigger.**

Dalla documentazione di Kyverno: `Modify Trigger → Downstream deleted`. Quando il trigger (il segreto intermedio) cambia, il downstream (il segreto consolidato) viene cancellato, non aggiornato. E poiché il generate rule si attiva solo su CREATE, non su UPDATE, dopo la cancellazione il downstream non viene ricreato.

Il pattern `clone` avrebbe funzionato (`Modify Source → Downstream synced`), ma richiede un'unica sorgente pre-consolidata — esattamente il problema originale.

La ricerca enterprise ha evidenziato l'esistenza di `mutateExisting` (che non cancella il downstream su fallimento) ma la complessità della soluzione a tre risorse (VSS → mutateExisting → clone con Reflector) cominciava a sembrare sproporzionata per un singolo certificato TLS.

## La Soluzione: ESO Multi-Path + Reflector

A questo punto la domanda era: perché non usare semplicemente ESO?

ESO è ancora installato nel cluster. Il suo `ClusterSecretStore` è funzionante. Supporta nativamente il multi-path merge con template engine. L'unico motivo per cui volevamo migrare era l'uniformità — avere tutto su VSO.

Ho creato una singola `ExternalSecret` in `vso-system` che legge entrambi i path Vault e produce il segreto `kubernetes.io/tls`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: wildcard-tls
  namespace: vso-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: tazlab-secrets-vault
  target:
    name: wildcard-tls
    template:
      type: kubernetes.io/tls
      metadata:
        annotations:
          reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
          reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
          reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "auth,dex,hugo-blog,hugo-wiki,ai-agents"
      data:
        tls.crt: "{{ .crt }}"
        tls.key: "{{ .key }}"
  data:
    - secretKey: crt
      remoteRef:
        key: tazlab-k8s/static/tls/wildcard/WILDCARD_CRT
        property: value
    - secretKey: key
      remoteRef:
        key: tazlab-k8s/static/tls/wildcard/WILDCARD_KEY
        property: value
```

Con Reflector a distribuire il segreto nei 5 namespace target. Il tutto ha funzionato al primo applicazione: `SecretSynced` in 5 secondi, tutti i namespace popolati in 10 secondi.

Ho rimosso Kyverno, le VSS in eccesso, e i VaultAuth doppi. Il cluster è tornato più pulito di prima.

## La Scoperta: il Bug che Non Era un Bug

Durante le ricerche, ho trovato riferimenti a PR #867 di VSO — "Vault client callback handler" — descritto in alcune discussioni come la causa del deadlock. Ho speso ore a progettare workaround per un bug che in realtà era già stato risolto.

PR #867 non è il bug, è la fix. Introdotto in VSO v1.4.0, ristruttura completamente il meccanismo di registrazione delle callback per evitare il deadlock che affliggeva le versioni precedenti. Il deadlock che abbiamo visto noi non era quello di PR #867 — era un problema diverso, probabilmente legato all'uso cross-namespace del VaultAuth e alla contesa su lock interni.

La lezione è chiara: quando si ricerca un problema, bisogna verificare non solo la presenza di issue simili, ma anche la versione esatta in cui sono state risolte. Un bug fixato nella versione che stai usando non è il tuo problema — il tuo problema è qualcos'altro.

## Lezioni Apprese

**La ricerca preventiva non può prevedere tutto.** CRISP 2.0 impone ricerche strutturate prima di ogni implementazione. E abbiamo fatto ricerche. Molte. Ma alcune scoperte — come il comportamento di Kyverno con generate+data, o il fatto che il deadlock non fosse PR #867 — sono emerse solo durante l'implementazione. La ricerca riduce l'incertezza ma non la elimina.

**La soluzione più semplice è spesso quella giusta.** Abbiamo speso ore per migrare da ESO a VSO per uniformità. Poi abbiamo speso ore per risolvere i problemi creati dalla migrazione. Alla fine siamo tornati a ESO per i due segreti che richiedevano multi-path. Se fossimo partiti dall'analisi obiettiva — "cosa gestisce bene ogni strumento?" — avremmo risparmiato tempo.

**Non tutti i segreti devono stare sullo stesso operatore.** Avere ESO per certi casi e VSO per altri non è un fallimento architetturale. È una scelta pragmatica. La purezza architetturale è meno importante della stabilità operativa.

**Il compromesso è una strategia valida.** La migrazione perfetta (tutto su VSO, tutto in un pomeriggio) non era possibile. La migrazione pragmatica (VSO per la maggior parte, ESO per i casi complessi) ha funzionato. Abbiamo abbandonato tre operatori (Vault Agent Injector, Reloader, Kyverno) e ne abbiamo tenuti due (VSO + ESO). Il cluster è più semplice oggi di quanto non fosse all'inizio della sessione.

## Conclusioni

Alla fine, la configurazione attuale è:

- **VSO** gestisce 11 VaultStaticSecret, 1 VaultDynamicSecret
- **ESO** gestisce 2 ExternalSecret (wildcard TLS, tailscale-operator-oauth)
- **Reflector** distribuisce il certificato TLS in 5 namespace
- **Zero** Vault Agent Injector, Reloader, Kyverno

La prossima volta che qualcuno dice "migriamo tutto da ESO a VSO per uniformità", risponderò: "Prima controlla se hai segreti multi-path. Poi ne parliamo."
