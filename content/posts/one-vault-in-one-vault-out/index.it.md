+++
title = "One Vault In, One Vault Out: Migrare Segreti Senza Fermare il Cluster"
date = 2026-05-22T22:45:00+00:00
draft = false
description = "Come la progettazione a slice (CRISP) e un ciclo di hardening hanno permesso di migrare 20 segreti da Infisical a Vault e validare il tutto con un destroy/create da zero."
tags = ["vault", "infisical", "eso", "external-secrets", "migration", "kubernetes", "tailscale", "crisp", "architecture"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# One Vault In, One Vault Out: Migrare Segreti Senza Fermare il Cluster

C'è un test che ogni progetto infrastrutturale prima o poi affronta: quanto è doloroso sostituire il backend dei segreti in un cluster Kubernetes? La risposta dipende quasi interamente dalla qualità della progettazione che lo ha preceduto.

Questo articolo racconta come abbiamo sostituito Infisical con HashiCorp Vault come backend dei segreti per un cluster Kubernetes (Talos + Flux + ESO), migrando tutti i 20 segreti in una sessione, e poi certificato il tutto con un ciclo destroy/create da zero — senza un singolo intervento manuale sull'infrastruttura a ciclo avviato.

## Il problema

Il cluster `tazlab-k8s` gestiva tutti i segreti statici — token API, certificati TLS, credenziali OAuth, chiavi S3 — attraverso Infisical, un servizio esterno free tier. Funzionava, ma creava dipendenza da un vendor esterno, limiti di scala e impossibilità di gestire segreti dinamici.

La soluzione era già in casa: Vault su Hetzner via Tailscale, con storage Raft e snapshot S3. Il runtime era operativo. Mancava il pezzo finale: far comunicare il cluster con Vault.

## L'architettura: two-store e progettazione a slice

La scelta chiave è stata il modello **two-store**: non sostituire tutto in un colpo solo, ma affiancare un nuovo ClusterSecretStore (`tazlab-secrets-vault`) a quello esistente (`tazlab-secrets` su Infisical), migrando i consumer uno per volta. Rollback per-consumer, niente big-bang, verifica incrementale.

L'intero percorso è stato gestito con la metodologia CRISP, decomponendo in progetti atomici con gate di uscita verificabili:

```
09-vault-k8s-integration-prep    ← ClusterSecretStore, policy ESO, smoke test
10-tazlab-k8s-vault-migration    ← Migrazione 20 segreti in 7 wave
12-tazlab-k8s-vault-migration-followup ← Hardening bootstrap + destroy/create validation
```

Ogni gate era una condizione verificabile: connettività cluster→Vault, store Valid, smoke test passato. Quando siamo arrivati alla migrazione, ogni dipendenza era già stata validata.

## La migrazione: 20 segreti in 7 wave

Con i prerequisiti pronti, la migrazione è stata una sequenza di wave: una modifica YAML, commit Git, Flux reconcile, verifica `SecretSynced True`. Pilot (`GEMINI_API_KEY`), GitHub token, auth (dex + oauth2), storage AWS, wildcard TLS + 9 repliche, AI (OpenClaw), e il bonus Tailscale Operator.

Due differenze fondamentali tra Infisical e Vault:

- **`remoteRef.key`**: non più il nome piatto del segreto, ma il percorso relativo al mount KV (`tazlab-k8s/static/apps/mnemosyne-mcp/GEMINI_API_KEY`)
- **`remoteRef.property: value`**: necessario perché Vault KV v2 restituisce JSON annidato, e `property: value` estrae il valore

Le uniche sorprese: il campo `caSecret` non esiste nel CRD di ESO (va usato `caProvider`), e ESO richiede `auth/token/lookup-self` nella policy per validare lo store. Niente di bloccante.

## La fase 2: hardening bootstrap

Con tutti i segreti su Vault, è emerso un problema più subdolo: il bootstrap del cluster dipendeva ancora da Infisical per le credenziali iniziali (token Proxmox, Talos secretbox, GitHub token). Il layer `secrets-fetcher` era un data source Infisical. Il `create.sh` esportava `INFISICAL_CLIENT_ID`.

La soluzione è stata eliminare Infisical dalla catena di bootstrap:

- `secrets-fetcher` convertito da data source Infisical a variabili da file locali
- `proxmox-talos` legge `GITHUB_TOKEN` da variabile, non da Infisical
- `create.sh` non esporta più credenziali Infisical; esporta `TALOS_SECRETBOX_KEY`
- `setup.sh` pusha le credenziali Operator su Vault invece che su Infisical
- Provider Infisical rimosso da tutti i layer Terraform tranne engine (legacy store)
- `aws-backup-secret` migrato da Infisical a Vault nel modulo storage
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

Al termine: blog e wiki raggiungibili via HTTPS, tutte le 22 ExternalSecret `SecretSynced True`, dex e oauth2-proxy healthy, Flux DAG verde. Nessun intervento manuale durante il ciclo.

L'unico intoppo: il kube-controller-manager ha perso il leader election per qualche secondo durante il bootstrap iniziale (timeout sulla API server locale), causando 3-4 riavvii prima di stabilizzarsi. Un comportamento noto su Talos a control-plane singolo, che si risolve da solo.

## Lezioni apprese

**La progettazione in slice funziona.** Ogni progetto CRISP aveva un gate di uscita verificabile. Quando siamo arrivati alla migrazione, ogni dipendenza era già stata validata. Il risultato: zero rollback, zero incidenti, zero scoperte dell'ultimo minuto.

**Il two-store model rimuove la pressione.** Sapere che Infisical era ancora lì ha permesso di procedere senza fretta. Ogni wave poteva essere testata e rollbackata individualmente.

**I test puntuali pagano.** Backup YAML pre-migrazione, force-sync ESO, verifica stato `SecretSynced`, rollout restart — questa sequenza, ripetuta 7 volte, ha reso ogni wave a basso rischio.

## Stato finale

- **22/22 ExternalSecrets** su Vault, tutti `SecretSynced True`
- **Bootstrap Infisical-free**: il cluster nasce senza chiamare Infisical
- **Infisical ancora vivo** per consumer esterni (TazPod), decommission pianificata
- **Destroy/create validato**: cluster ricreato da zero senza interventi manuali

La migrazione è completa. I segreti dinamici PostgreSQL e la dismissione di Infisical sono rinviati a progetti successivi — ma questa è un'altra storia.
