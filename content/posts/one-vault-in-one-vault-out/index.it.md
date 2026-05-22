+++
title = "One Vault In, One Vault Out: Migrare Segreti Senza Fermare il Cluster"
date = 2026-05-22T22:45:00+00:00
draft = false
description = "Dopo mesi di preparazione — runtime Vault su Hetzner, bridge Tailscale, trasporto stabile, DNS enterprise — la migrazione dei segreti da Infisical a Vault, completata e validata con un destroy/create da zero."
tags = ["vault", "infisical", "eso", "external-secrets", "migration", "kubernetes", "tailscale", "crisp", "architecture"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# One Vault In, One Vault Out: Migrare Segreti Senza Fermare il Cluster

Se avete seguito la storia del cluster TazLab fin qui, sapete che è una lunga marcia di avvicinamento. Il Vault su Hetzner era operativo da aprile (C1 + C2). Il ponte Tailscale che connette il cluster Proxmox/Talos al Vault era stato costruito. Il trasporto era stato stabilizzato dopo aver scoperto che l'MTU di Docker bridge faceva collassare le connessioni SSH. La risoluzione DNS dei nomi MagicDNS era stata risolta con il Tailscale Operator e un CoreDNS enterprise "Disable & Replace". Persino l'archivio crittografico di TazPod — il portafoglio di chiavi che tiene in vita l'intero ecosistema — era stato messo in sicurezza con retention history su S3.

Mancava un pezzo. L'ultimo.

Sostituire Infisical. Il servizio esterno free tier che ancora gestiva tutti i segreti del cluster — token API, certificati TLS, credenziali OAuth, chiavi S3 — doveva essere rimpiazzato da Vault. Non perché non funzionasse: funzionava. Ma aveva tre limiti che l'architettura non poteva più ignorare: dipendenza da un vendor esterno (nessun Infisical = cluster morto), limiti di scala del free tier, e l'impossibilità di generare segreti dinamici — un problema che avevamo già toccato con il workaround `sync_runtime_secrets` per la password di Grafana, una toppa che dimostrava esattamente perché serviva Vault.

Questo articolo racconta l'ultimo miglio: come abbiamo migrato tutti i 20 segreti da Infisical a Vault in una sessione, e poi certificato il tutto con un ciclo destroy/create da zero — senza un singolo intervento manuale a ciclo avviato.

## L'architettura: two-store e progettazione a slice

La scelta chiave è stata il modello **two-store**: non sostituire tutto in un colpo solo, ma affiancare un nuovo ClusterSecretStore (`tazlab-secrets-vault`) a quello esistente (`tazlab-secrets` su Infisical), migrando i consumer uno per volta. Rollback per-consumer, niente big-bang, verifica incrementale.

L'intero percorso è stato gestito con la metodologia CRISP, decomponendo in progetti atomici con gate di uscita verificabili:

```
09-vault-k8s-integration-prep    ← ClusterSecretStore, policy ESO, smoke test
10-tazlab-k8s-vault-migration    ← Migrazione 20 segreti in 7 wave
12-tazlab-k8s-vault-migration-followup ← Hardening bootstrap + destroy/create validation
```

Ogni gate era una condizione verificabile già validata nei progetti precedenti: connettività cluster→Vault via MagicDNS, ClusterSecretStore Valid, smoke test passato. Quando siamo arrivati alla migrazione, l'unica variabile era la migrazione stessa.

## La migrazione: 20 segreti in 7 wave

Con i prerequisiti pronti, la migrazione è stata una sequenza di wave: una modifica YAML, commit Git, Flux reconcile, verifica `SecretSynced True`. Pilot (`GEMINI_API_KEY` per mnemosyne-mcp), GitHub token, auth (dex + oauth2), storage S3, wildcard TLS + 9 repliche, AI (OpenClaw), e il bonus Tailscale Operator.

Due differenze fondamentali tra Infisical e Vault nell'ExternalSecret:

- **`remoteRef.key`**: non più il nome piatto del segreto, ma il percorso relativo al mount KV (`tazlab-k8s/static/apps/mnemosyne-mcp/GEMINI_API_KEY`)
- **`remoteRef.property: value`**: necessario perché Vault KV v2 restituisce JSON annidato, e `property: value` estrae il valore

Le uniche sorprese: il campo `caSecret` non esiste nel CRD di ESO (va usato `caProvider`), e ESO richiede `auth/token/lookup-self` nella policy per validare lo store. Niente di bloccante.

## La fase 2: hardening bootstrap

Con tutti i segreti su Vault, è emerso un problema più subdolo: il bootstrap del cluster dipendeva ancora da Infisical per le credenziali iniziali (token Proxmox, Talos secretbox, GitHub token). Il layer `secrets-fetcher` era un data source Infisical. Il `create.sh` esportava `INFISICAL_CLIENT_ID`. Se Infisical fosse stato dismesso, il cluster non sarebbe più nato.

La soluzione è stata eliminare Infisical dalla catena di bootstrap:
- `secrets-fetcher` convertito da data source a variabili da file locali
- `proxmox-talos` legge `GITHUB_TOKEN` da variabile, non da Infisical
- `create.sh` non esporta più credenziali Infisical
- `setup.sh` pusha le credenziali Operator su Vault
- Provider Infisical rimosso da tutti i layer Terraform
- Regola architetturale documentata: Terraform = provider-specific, Flux = provider-agnostic

### Il deadlock DNS

La sfida più interessante è stata una dipendenza circolare: il Tailscale Operator richiede un secret OAuth da Vault per partire, ma Vault è raggiungibile solo via DNS del Tailscale Operator. Rotto pre-seedando il secret OAuth via Terraform nell'engine layer, insieme a `vault-ca-cert` e `vault-eso-token`.

## Il test finale: destroy/create da zero

Con tutte le dipendenze risolte, abbiamo eseguito un ciclo `destroy.sh` + `create.sh`. Il cluster è rinato in circa 6 minuti:

| Fase | Tempo |
|------|-------|
| Platform (VM + Talos) | ~90s |
| Engine (ESO + bootstrap) | 75s |
| Gitops (Flux) | 190s |
| Storage (Longhorn) | 118s |

Tutti i servizi sono tornati su: blog e wiki raggiungibili via HTTPS, tutte le 22 ExternalSecret `SecretSynced True`, dex e oauth2-proxy healthy. Zero interventi manuali durante il ciclo. L'unico intoppo: il kube-controller-manager ha perso il leader election per qualche secondo durante il bootstrap (timeout sulla API server locale su control-plane singolo), causando 3-4 riavvii prima di stabilizzarsi — comportamento noto su Talos, che si risolve da solo.

## Lezioni apprese

**La progettazione in slice funziona.** È il filo rosso che attraversa tutti gli articoli di questa serie. Ogni progetto CRISP aveva un gate di uscita verificabile. Quando siamo arrivati alla migrazione, ogni dipendenza era già stata validata in un progetto precedente. Il risultato: zero rollback, zero incidenti.

**Il two-store model rimuove la pressione.** Sapere che Infisical era ancora lì ha permesso di procedere senza fretta. Ogni wave poteva essere testata e rollbackata individualmente.

**I test puntuali pagano.** Backup YAML pre-migrazione, force-sync ESO, verifica stato `SecretSynced`, rollout restart — questa sequenza, ripetuta 7 volte, ha reso ogni wave a basso rischio.

## Stato finale

- **22/22 ExternalSecrets** su Vault, tutti `SecretSynced True`
- **Bootstrap Infisical-free**: il cluster nasce senza chiamare Infisical
- **Infisical ancora vivo** per consumer esterni (TazPod), dismissione pianificata
- **Destroy/create validato**: cluster ricreato da zero senza interventi manuali

La migrazione è completa. I segreti dinamici PostgreSQL e la dismissione di Infisical sono rinviati a progetti successivi. Ma questa è un'altra storia.
