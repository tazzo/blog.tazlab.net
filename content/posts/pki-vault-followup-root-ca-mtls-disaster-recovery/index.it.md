+++
title = "Vault PKI Follow-Up: Root CA, mTLS, e la Certificazione del Disaster Recovery"
date = 2026-07-07T21:00:00+02:00
draft = false
description = "Il capitolo finale del progetto PKI: aggiungere la Root CA alla catena di fiducia, completare il mTLS per Grafana, e certificare il tutto con cinque cicli destroy+create fino al one-shot perfetto in 11 minuti e 19 secondi."
tags = ["PKI", "Vault", "Kubernetes", "Flux", "GitOps", "Disaster Recovery", "Grafana", "mTLS"]
categories = ["Infrastructure", "DevOps"]
author = "Taz"
+++

## Il Debito delle Fasi Finali

Nel [post precedente]({{< ref "pki-vault-tazlab-enterprise-homelab" >}}) ho raccontato la costruzione della PKI enterprise a tre livelli per TazLab: Root CA offline, Intermediate CA in Vault, certificati per ingress, database e client. L'implementazione aveva completato le fasi dalla zero alla cinque: CA offline, Terraform, engine PKI, Let's Encrypt, wildcard TLS e mTLS su PostgreSQL.

Ma restavano delle cose in sospeso. Cose che non potevo testare senza riavviare i nodi Talos o, meglio ancora, senza un ciclo completo di distruzione e ricreazione del cluster. Nel progetto CRISP le avevo raggruppate sotto "Fase 4bis e 4ter": la Root CA da aggiungere ai template VSO, il fix del Grafana HelmRelease, la configurazione di Reflector per la propagazione dei certificati, e una serie di debiti tecnici accumulati nelle iterazioni precedenti.

Era il momento di chiudere il cerchio.

## Il Rituale del Destroy+Create

Dopo ogni modifica architetturale significativa al cluster, eseguo sempre la stessa procedura: distruggo tutto e ricostruisco da zero. Non è un test opzionale — è la certificazione che il cluster è pronto per un disaster recovery reale. L'ho fatto decine di volte, a partire dai primi progetti di consolidamento. Ultimamente, con l'infrastruttura che è diventata più complessa, anche il ciclo di ricreazione da zero ha iniziato a riservare più insidie — e ho iniziato a scrivere articoli anche su questa fase.

Ne avevo già parlato [dopo aver consolidato i segreti di bootstrap su Vault]({{< ref "bootstrap-secret-infrastructure-consolidation" >}}) e [dopo aver eliminato Ansible dal ciclo di rinascita]({{< ref "eliminating-ansible-from-cluster-rebirth" >}}). Ogni volta, l'obiettivo era lo stesso: **un singolo comando, nessun intervento manuale, cluster completamente operativo**.

Non si tratta di testare una feature — si tratta di verificare che l'intero stack, da Terraform a Flux, dai certificati TLS ai segreti Vault, funzioni in modo deterministico. Se qualcosa si rompe durante il bootstrap, vuol dire che si romperebbe anche durante un vero disastro. E io voglio saperlo prima.

Il `destroy.sh` non fa un elegante `terraform destroy` — fa una **disintegrazione nucleare**: cancella le VM Talos via API Proxmox, pulisce i record DNS di Tailscale, rimuove i device fantasma, azzera ogni stato. Poi `create.sh` ricostruisce tutto: VM, Talos, networking, storage, Flux, operatori, applicazioni. In circa dodici minuti.

Per il progetto PKI, il ciclo destroy+create era anche l'unico modo per verificare le cose rimaste in sospeso. Vediamo cosa sono.

## Cosa Mancava

Dopo l'implementazione iniziale della PKI, il cluster funzionava. Grafana si connetteva al database, i certificati venivano emessi, Vault gestiva l'intero ciclo di vita. Ma c'erano delle crepe.

### La Root CA Mancante

Il primo problema era sottile ma fondamentale. I template VSO (Vault Secrets Operator) per i `VaultPKISecret` generavano il `ca.crt` usando solo la `ca_chain` di Vault — che contiene Tier 2 e Tier 1, ma **non la Root CA offline** (Tier 0). Vault non include la root nella catena perché tecnicamente non dovrebbe essere necessaria: il client dovrebbe fidarsi della root come trust anchor pre-distribuita.

Ma Go, il linguaggio in cui è scritto Grafana, è più severo. Il suo stack TLS richiede che il trust anchor sia un certificato auto-firmato, non un intermediate. La Root CA offline è auto-firmata; Tier 1 non lo è. Senza la Root nel `ca.crt`, Go rifiuta la connessione con `tls: unknown certificate authority`.

Il fix è stato aggiungere il certificato della Root CA in chiaro (dal vault dei segreti) al template VSO di tutti e sei i `VaultPKISecret`. Ora ogni `ca.crt` contiene la catena completa: Tier 2, Tier 1, Root. Tre certificati, non due.

### Il Grafana HelmRelease Rotto

Alla fine del progetto PKI, Grafana era in esecuzione con `ssl_mode=disable` e una password hardcoded in `grafana.ini`. Lo avevamo lasciato così perché il mTLS (`ssl_mode=require`) sembrava richiedere un riavvio dei nodi: i tentativi di attivarlo causavano "connection reset by peer".

Quando ho iniziato il ciclo di test, ho scoperto che l'implementazione era più fragile del previsto. Il HelmRelease di Grafana, parte del `kube-prometheus-stack`, aveva un problema serio: il `chartRef` puntava a un HelmChart chiamato `prometheus-community`, ma il chart effettivo si chiamava `monitoring-kube-prometheus-stack`. Flux non riusciva a riconciliare il rilascio, e l'unica ragione per cui Grafana funzionava era che il deployment era stato creato in un'installazione precedente e non era mai stato aggiornato.

Una volta corretto il riferimento (da `chartRef` a `chart.spec` con nome e versione esatti), è emerso il secondo problema: l'init container che copia i certificati TLS aveva il comando scritto su una riga senza separatori tra `cp`, `chmod` e `ls`. `cp` interpretava tutto come file sorgente — e l'init crashava con "Cross-device link".

Ho fixato entrambi, ho impostato `ssl_mode=require`, ho rimosso la password. Il risultato: Grafana si connette al database con mTLS puro, senza Kyber fragmentation o altro. Il "connection reset" originale non era causato dal bug checksum di Proxmox — era il HelmRelease rotto che impediva una riconciliazione pulita.

Una nota sul GODEBUG: ho comunque aggiunto `GODEBUG=tlskyber=0` come variabile d'ambiente per disabilitare l'algoritmo post-quantico Kyber in Go 1.23+, tenendo il ClientHello TLS sotto la soglia di frammentazione VXLAN (MTU 1450). Il formato corretto nel sub-chart Grafana di `kube-prometheus-stack` è un dizionario YAML sotto `grafana.env`, non una lista.

### Reflector e la Propagazione dei Certificati

Il certificato wildcard `*.tazlab.net` viene generato da VSO nel namespace `vso-system`. Ma `oauth2-proxy` (in `auth`) e `dex` (in `dex`) devono poterlo usare per i loro ingress TLS. Nel cluster precedente usavo Reflector per copiare il secret tra namespace.

Il problema: Reflector v10.x **non usa CRD**. Opera tramite annotazioni sui Secret stessi. Per attivare la propagazione automatica, basta aggiungere queste annotazioni al `VaultPKISecret`:

```yaml
  destination:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "auth,dex"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "auth,dex"
```

VSO genera il secret con queste annotazioni, Reflector lo vede e lo copia automaticamente in `auth` e `dex`. Niente script, niente `kubectl`, niente interventi manuali.

## I Cinque Cicli

Con tutti i fix pronti nei manifest Git, ho lanciato il primo ciclo destroy+create. E qui è iniziata la vera caccia.

### Ciclo 1 — Il Risveglio Brusco

Il primo tentativo è stato un disastro istruttivo. Sei bug in un colpo solo:

1. `set -u` in bash: la funzione `resolve()` usava `${!var_name}` senza protezione per variabili non definite
2. L'auto-import delle risorse Vault JWT usava il path sbagliato (`auth/jwt` invece di `jwt`)
3. Il `config_patches` per l'EthernetConfig Talos era nel formato sbagliato per il provider v0.10.1
4. I CR di VaultAuth e VaultPKISecret erano nello stesso kustomization dell'HelmRelease VSO — Flux faceva dry-run prima che i CRD esistessero
5. L'indentazione YAML del certificato Root CA era sbagliata (le linee base64 e `END CERTIFICATE` senza rientro)
6. Il secret `vault-pki-tls` non veniva propagato ai namespace `auth` e `dex`

Di questi, il più interessante è stato il numero 4. Flux esegue una **Server-Side Apply dry-run** su tutte le risorse di una Kustomization prima di applicarle. Se il CRD di VaultAuth non esiste ancora (perché il VSO operator non è partito), la validazione fallisce. La soluzione è stata spostare i CR in una Kustomization separata (`vso-secrets`) con `dependsOn` sull'operatore.

Dopo aver fixato tutti e sei, il secondo ciclo ha trovato un solo problema: Reflector. Avevo creato un CR `Reflector` pensando che l'operatore lo supportasse, ma v10.x funziona solo con annotazioni. Rimosso il CR, aggiunte le annotazioni al VaultPKISecret. Fine.


### Ciclo 3 — Dipendenza Circolare

Qui è emerso un bug architetturale interessante. Il VSO operator crea ServiceAccount nel namespace `monitoring`. Ma il namespace `monitoring` veniva creato dalla Kustomization `infrastructure-monitoring`, che avevo fatto dipendere da VSO (per il problema del dry-run). Risultato: VSO non poteva creare la SA perché il namespace non esisteva, e il namespace non veniva creato perché la Kustomization aspettava VSO.

La soluzione: spostare la creazione del namespace `monitoring` nella Kustomization `namespaces`, che viene eseguita prima di entrambe.

### Ciclo 4 — DNS Sporchi

Il quarto ciclo ha rivelato un problema che si annidava da tempo. Tailscale DNS, dopo un destroy, lasciava record sporchi. Il servizio `tazlab-db` riceveva un suffisso `-1` (diventando `tazlab-db-1.magellanic-gondola.ts.net`) perché il record originale non veniva ripulito. Vault, configurato per connettersi a `tazlab-db`, non risolveva più l'hostname.

Ho aggiunto una fase di verifica DNS al `destroy.sh` — **Phase 0c** — che controlla esplicitamente la pulizia dei record e avverte se qualcosa è rimasto. Se i record non sono puliti, meglio saperlo prima di lanciare il create.

### Ciclo 5 — One-Shot

Il quinto tentativo è partito con i record DNS puliti e tutti i fix precedenti già nei manifest. La sequenza temporale approssimativa:

```
Layer Terraform...............~3 min
Flux convergence.............~5 min
DB restore + pod startup....~4 min
────────────────────────────
TOTALE cluster operativo...~12 min
```

I tempi dei layer Terraform sono precisi (secrets 4s, vault_jwt 3s, platform 85s, ecc.), ma dopo l'exit di create.sh il database deve ancora fare il restore da S3 e gli ultimi pod (Grafana, Prometheus, alertmanager) partono solo dopo. Il cluster è completamente operativo in circa 12-13 minuti dal via del create.
Ventuno Kustomization Flux su ventuno True. Settantacinque pod, zero errori, zero CrashLoopBackOff. Auth funzionante via Reflector. Grafana connesso al database in mTLS. Certificati wildcard propagati. VaultPKISecret in rotazione automatica. **Nessun intervento manuale.**

## Cosa Ho Imparato

### Il Dry-Run di Flux Non Perdona

Flux valida **tutte** le risorse di una Kustomization prima di applicarne **nessuna**. Questo significa che non puoi mettere un CR e il suo operatore nella stessa Kustomization. La separazione in livelli con `dependsOn` (CRD → Operatori → Configurazioni) non è un optional — è l'unico modo per far funzionare il bootstrap in modo deterministico.

### I DNS Sono il Tallone d'Achille

In un'architettura che dipende da Tailscale per la connettività tra Vault (Hetzner) e il cluster (Proxmox), i record DNS sporchi dopo un destroy diventano un problema serio. Il fix non è complicato — basta verificare e pulire — ma se non lo fai, il create successivo parte con nomi sbagliati e nulla funziona. La Phase 0c nel `destroy.sh` ora garantisce che questo non succeda più.

### Le Annotazioni, Non i CRD

Reflector v10 ha abbandonato i CRD in favore delle annotazioni. L'ho scoperto dopo aver passato ore a cercare di far funzionare un CR che non sarebbe mai stato riconosciuto. La ricerca (quella vera, su GitHub e nei forum) rimane insostituibile.

### mTLS Funziona, Senza Scorciatoie

Alla fine del quinto ciclo, Grafana parlava con PostgreSQL in mTLS puro. `ssl_mode=require`, client certificate, autenticazione via `pg_hba cert`. Nessuna password. Nessun workaround. Il certificato client ruota ogni 24 ore tramite VSO, il server ogni 30 giorni. La Root CA nella catena garantisce che Go possa verificare l'intera catena di fiducia.

## La Prossima Fermata

Il progetto PKI è ufficialmente chiuso. Il prossimo passo è quello per cui tutta questa infrastruttura è stata costruita: il **database PostgreSQL cross-site con failover automatico** tra Proxmox e Hetzner, usando PGO standby cluster e backup S3 via pgBackRest.

Ma questa è un'altra storia.

---
*Questo articolo fa parte di una serie sulla gestione dell'infrastruttura TazLab. I precedenti: [PKI Vault su TazLab]({{< ref "pki-vault-tazlab-enterprise-homelab" >}}), [Consolidamento del Cluster e Riduzione dei Bootstrap Token]({{< ref "bootstrap-secret-infrastructure-consolidation" >}}), [Eliminazione di Ansible dal Ciclo di Rinascita]({{< ref "eliminating-ansible-from-cluster-rebirth" >}}). Codice su [github.com/tazzo](https://github.com/tazzo).*
