+++
title = "One Vault In, One Vault Out: Migrating Secrets Without Breaking the Cluster"
date = 2026-05-22T22:45:00+00:00
draft = false
description = "After months of preparation — Vault runtime on Hetzner, Tailscale bridge, stable transport, enterprise DNS — the secret migration from Infisical to Vault, completed and validated with a zero-touch destroy/create cycle."
tags = ["vault", "infisical", "eso", "external-secrets", "migration", "kubernetes", "tailscale", "crisp", "architecture"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# One Vault In, One Vault Out: Migrating Secrets Without Breaking the Cluster

If you have been following the TazLab cluster story so far, you know it has been a long approach march. The Vault on Hetzner has been operational since April (C1 + C2). The Tailscale bridge connecting the Proxmox/Talos cluster to Vault had been built. The transport had been stabilized after discovering that Docker bridge MTU was collapsing SSH connections. The MagicDNS name resolution had been solved with the Tailscale Operator and an enterprise "Disable & Replace" CoreDNS. Even the TazPod encrypted archive — the key wallet keeping the entire ecosystem alive — had been secured with S3 retention history.

One piece was missing. The last one.

Replacing Infisical. The external free-tier service that still managed all cluster secrets — API tokens, TLS certificates, OAuth credentials, S3 keys — had to be replaced by Vault. Not because it was broken: it worked. But it had three limitations the architecture could no longer ignore: vendor lock (no Infisical = dead cluster), free-tier scaling limits, and the inability to generate dynamic secrets — a problem we had already touched with the `sync_runtime_secrets` workaround for the Grafana password, a patch that proved exactly why Vault was needed.

This article covers the last mile: how we migrated all 20 secrets from Infisical to Vault in one session, and then certified the whole thing with a full destroy/create cycle — without a single manual intervention after the cycle started.

## Architecture: two-store and slice-based design

The key decision was the **two-store** model: not replacing everything at once, but adding a second ClusterSecretStore (`tazlab-secrets-vault`) alongside the existing one (`tazlab-secrets` on Infisical), migrating consumers one at a time. Per-consumer rollback, no big-bang, incremental verification.

The entire journey was managed with the CRISP methodology, decomposing into atomic projects with verifiable exit gates:

```
09-vault-k8s-integration-prep    ← ClusterSecretStore, ESO policy, smoke test
10-tazlab-k8s-vault-migration    ← 20 secrets migration in 7 waves
12-tazlab-k8s-vault-migration-followup ← Bootstrap hardening + destroy/create validation
```

Each gate was a verifiable condition already validated in previous projects: cluster-to-Vault connectivity via MagicDNS, ClusterSecretStore Valid, smoke test passed. By the time we started the migration, the only variable was the migration itself.

## The migration: 20 secrets in 7 waves

With prerequisites ready, the migration was a sequence of waves: one YAML change, git commit, Flux reconcile, `SecretSynced True` verification. Pilot (`GEMINI_API_KEY` for mnemosyne-mcp), GitHub token, auth (dex + oauth2), S3 storage, wildcard TLS + 9 replicas, AI (OpenClaw), and the Tailscale Operator bonus.

Two fundamental differences between Infisical and Vault in the ExternalSecret:

- **`remoteRef.key`**: no longer the flat secret name, but the path relative to the KV mount (`tazlab-k8s/static/apps/mnemosyne-mcp/GEMINI_API_KEY`)
- **`remoteRef.property: value`**: required because Vault KV v2 returns nested JSON, and `property: value` extracts the value

The only surprises: the `caSecret` field does not exist in the ESO CRD (use `caProvider` instead), and ESO requires `auth/token/lookup-self` in the policy to validate the store. Nothing blocking.

## Phase 2: bootstrap hardening

With all secrets on Vault, a subtler problem emerged: the cluster bootstrap still depended on Infisical for initial credentials (Proxmox tokens, Talos secretbox, GitHub token). The `secrets-fetcher` layer was an Infisical data source. The `create.sh` exported `INFISICAL_CLIENT_ID`. If Infisical were ever decommissioned, the cluster would not be reborn.

The solution was removing Infisical from the bootstrap chain:
- `secrets-fetcher` converted from data source to local file variables
- `proxmox-talos` reads `GITHUB_TOKEN` from a variable, not Infisical
- `create.sh` no longer exports Infisical credentials
- `setup.sh` pushes Operator credentials to Vault
- Infisical provider removed from all Terraform layers
- Architectural rule documented: Terraform = provider-specific, Flux = provider-agnostic

### The DNS deadlock

The most interesting challenge was a circular dependency: the Tailscale Operator needs an OAuth secret from Vault to start, but Vault is reachable only through the Tailscale Operator's DNS. Broken by pre-seeding the OAuth secret via Terraform in the engine layer, alongside `vault-ca-cert` and `vault-eso-token`.

## The final test: destroy/create from scratch

With all dependencies resolved, we ran a `destroy.sh` + `create.sh` cycle. The cluster was reborn in about 6 minutes:

| Phase | Time |
|-------|------|
| Platform (VM + Talos) | ~90s |
| Engine (ESO + bootstrap) | 75s |
| Gitops (Flux) | 190s |
| Storage (Longhorn) | 118s |

All services came back: blog and wiki reachable via HTTPS, all 22 ExternalSecrets `SecretSynced True`, dex and oauth2-proxy healthy. Zero manual interventions during the cycle. The only hiccup: the kube-controller-manager lost leader election for a few seconds during bootstrap (API server timeout on a single control-plane node), causing 3-4 restarts before stabilizing — a known behavior on Talos that self-resolves.

## Lessons learned

**Slice-based design works.** It is the red thread running through all articles in this series. Every CRISP project had a verifiable exit gate. By the time we reached the migration, every dependency had already been validated in a previous project. The result: zero rollbacks, zero incidents.

**The two-store model removes pressure.** Knowing Infisical was still there allowed us to proceed without rushing. Every wave could be tested and rolled back independently.

**Incremental testing pays off.** Pre-migration YAML backup, ESO force-sync, `SecretSynced` state verification, rollout restart — this sequence, repeated 7 times, made each wave low-risk.

## Final state

- **22/22 ExternalSecrets** on Vault, all `SecretSynced True`
- **Infisical-free bootstrap**: the cluster is born without calling Infisical
- **Infisical still alive** for external consumers (TazPod), decommission planned
- **Destroy/create validated**: cluster recreated from scratch without manual intervention

The migration is complete. PostgreSQL dynamic secrets and Infisical decommission are deferred to follow-up projects. But that is another story.
