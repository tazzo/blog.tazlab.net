+++
title = "Cluster Consolidation and Reducing Bootstrap Tokens to One"
date = 2026-06-04T18:00:00+00:00
draft = false
tags = ["Kubernetes", "HashiCorp Vault", "Terraform", "Flux", "GitOps", "Secrets Management", "External Secrets Operator", "Vault Secrets Operator", "Reloader"]
description = "Two infrastructure secret consolidation projects: moving bootstrap secrets to Vault with a single scoped token, and migrating ESO from Terraform to Flux like VSO, with Reloader and ExternalSecrets for dex and oauth2-proxy."
+++

## The Architectural Problem

TazLab's secret infrastructure had evolved in a disorganized way. On one hand, the cluster bootstrap secrets were scattered across six files in `~/secrets/`, mixing Proxmox credentials, GitHub tokens, Talos keys, Vault tokens, Tailscale credentials, and TLS certificates. It was functional but fragile: the `~/secrets/` directory was the single source of truth, with no clear hierarchy between bootstrap secrets and workload secrets.

On the other hand, the External Secrets Operator (ESO) was still installed by Terraform, while the Vault Secrets Operator (VSO) was already managed by Flux. An asymmetry that made upgrading ESO difficult and violated the architectural division I had set: **Everything provider-agnostic must be in Flux. Everything provider-specific must be in Terraform**.

The project unfolded in two phases: first reducing the bootstrap secrets to Vault, then moving ESO to Flux. Eight reviews, a final destroy+create cycle, and a cleaner system.

In this article I describe the reasoning behind each choice, the mistakes I made, and how the iterative reviews caught them.

## Project 1: Moving Bootstrap Secrets to Vault

### The Context

When `create.sh` bootstraps a cluster, it needs access to several secrets before any operator (ESO, VSO) can run: the Proxmox credentials to create VMs, the GitHub token to bootstrap Flux, the Talos key for etcd encryption, the Tailscale OAuth credentials, the ESO token to authenticate against Vault, and the Vault CA certificate.

All these secrets were in `~/secrets/`, read directly from files. It worked, but the directory had grown unwieldy. The idea was: what if TazPod (where the scripts run) could talk directly to Vault over Tailscale, and the bootstrap fetched everything from there with a single scoped token?

TazPod is already on the tailnet. Vault is on Hetzner, reachable via Tailscale. No connectivity issues. All that was needed was a Vault token with a read-only policy on a specific path, and a modification to `create.sh` to fetch secrets at startup.

### The Solution

The core change was simple: a single `vault read -format=json secret/data/tazlab-k8s/bootstrap` call instead of 8 separate reads. The secret contains all 8 fields (PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET, GITHUB_TOKEN, TALOS_SECRETBOX_KEY, TAILSCALE_OPERATOR_CLIENT_ID/SECRET, VAULT_CA_CRT, ESO_READER_TOKEN) in a single KV v2 path.

```bash
# create.sh — Step 0
export VAULT_ADDR="https://lushycorp-vault.magellanic-gondola.ts.net:8200"
export VAULT_SKIP_VERIFY=true

if timeout 5 vault status >/dev/null 2>&1 && [[ -f ~/secrets/bootstrap-token.txt ]]; then
  export VAULT_TOKEN="$(cat ~/secrets/bootstrap-token.txt | tr -d "'\"\t\r\n ")"
  timeout 3 vault token renew >/dev/null 2>&1 || true

  SECRETS_JSON=$(vault read -format=json secret/data/tazlab-k8s/bootstrap 2>/dev/null)
  if [[ -n "$SECRETS_JSON" ]]; then
    parse_trim() { echo "$SECRETS_JSON" | jq -r ".data.data.$1 // \"\"" | tr -d "'\"\t\r\n "; }
    parse_raw()  { echo "$SECRETS_JSON" | jq -r ".data.data.$1 // \"\""; }

    export PROXMOX_TOKEN_ID=$(parse_trim PROXMOX_TOKEN_ID)
    export PROXMOX_TOKEN_SECRET=$(parse_trim PROXMOX_TOKEN_SECRET)
    # ... other fields
  fi
fi
```

If Vault is unreachable, the `resolve()` function falls back to local files. `~/secrets/` is never modified — it remains the immutable recovery anchor.

### What the Reviews Taught Me

I ran this project through **five reviews** with different agents. Each review found an edge case I hadn't considered:

1. **The `resolve()` guard clause overwrote Vault values** — the function ran after Step 0 and overwrote the variables just fetched from Vault. The fix: a check `if [[ -n "${!var_name}" && ! -f "${!var_name}" ]]` to skip resolution if already populated by Vault.

2. **`tr -d "'\" "` corrupted PEM certificates** — the same function used to strip spaces from tokens destroyed `-----BEGIN CERTIFICATE-----`. Conditional branch for CA_CRT/CERT variables.

3. **Missing `export` on VAULT_ADDR and VAULT_TOKEN** — without export, the vault CLI talked to localhost. Found by the third review.

4. **8 separate `vault kv get` calls vs 1 `vault read`** — the former suffered from a permission block (the scoped token couldn't query mount metadata). Grouping everything into a single secret and using `vault read + jq` solved it.

5. **The bootstrap token TTL was capped at 32 days** — Vault defaults to `max_lease_ttl = 768h`. Added `vault token renew` at the start of create.sh.

Each of these was technically small (a character, an export, a flag), but each would have broken the bootstrap in production.

## Project 2: ESO from Terraform to Flux

### A Shift in Perspective

When I originally designed the division between Terraform and Flux, I thought ESO would be useless on the cloud. The idea was: on AWS I'll use AWS Secrets Manager, on GCP I'll use Secret Manager, so ESO isn't needed. That's why I left it in Terraform — a "provider detail."

Over time I realized this isn't the case. I have a personal Vault (Hetzner) that works independently of the underlying provider. Whether the cluster runs on Proxmox, AWS EKS, or GCP GKE, Vault is always there, and ESO + VSO are the operators that talk to it. ESO is not provider-specific — it's a Kubernetes operator like any other.

Furthermore, my cloud plans have expanded: not just managed Kubernetes (EKS, GKE), but also raw VMs on Hetzner, Google Cloud, AWS. In all these scenarios, my Vault remains the source of truth for secrets, and ESO/VSO are the delivery channels into the cluster.

This is why ESO had to be in Flux, not in Terraform. Just like VSO.

### What Changed

The original project was simple: move the ESO HelmRelease from `k8s-engine/main.tf` to Flux, following the same pattern as VSO. Then two other things emerged:

1. **Reloader had been removed** during the VSO migration (because VSO has native `rolloutRestartTargets`). But ESO doesn't have this feature. If a secret is rotated, pods don't restart. The solution was to reinstall Reloader (Stakater, v1.2.1, `watchGlobally: true`) and add the `reloader.stakater.com/auto: "true"` annotation on the Deployment's `metadata.annotations` — not on `spec.template.metadata`, an error caught in review.

2. **Dex and oauth2-proxy were using `merged` paths** on Vault — and I hadn't noticed.

### The Merged Path Problem: Inherited Technical Debt

During the VSO migration (project 13-vso-static-migration, late May), someone — likely an agent trying to keep things clean — had consolidated dex and oauth2-proxy secrets into `merged` paths on Vault. Instead of keeping `DEX_GOOGLE_CLIENT_ID` and `DEX_GOOGLE_CLIENT_SECRET` on two separate paths (as they were originally), they had merged them into a single path `tazlab-k8s/static/auth/dex/merged`. Same for oauth2-proxy.

The problem is that VSO's `VaultStaticSecret` reads from a single Vault path. If two fields need to end up in the same Kubernetes Secret but come from different Vault paths, VSO can't do it. The `merged` path was the workaround: read everything from one path. The catch was that it was a one-shot snapshot, created manually and never updated. If the Google OAuth secret is rotated, the `merged` path stays at the old value, and the system keeps using stale credentials without anyone noticing.

I hadn't noticed. Tests passed, the system worked, and no one had rotated those secrets in the meantime. It only came to light during the reviews for this project, when we analyzed what was still on ESO and why. The wildcard TLS, for the exact same reason (CRT and KEY on two separate paths), had never been migrated to VSO — and that was a conscious decision. The dex and oauth2-proxy merged paths had slipped through unnoticed.

The solution was to move dex and oauth2-proxy back to ESO ExternalSecrets. ESO handles multi-path merging natively via multiple `remoteRef` entries with templates. Exactly as they worked before the VSO migration.

## The Iterative Review Process

In total, the two projects went through **eight reviews**. Each review still found something. Not because the project was poorly designed, but because each review looked from a different perspective: one agent looked at the code, another at the architecture, another at the Flux DAG, another at Ansible compatibility.

The pattern was always the same: the structure was right, the solution was correct, but there were small details — an unexported environment variable, an annotation in the wrong place, an incorrect YAML syntax in an Ansible task, a markdown table with missing pipes. Things that slip through during planning but that a targeted review catches.

The value of the reviews wasn't discovering architectural problems — those were already resolved during the design phase. It was catching the **distraction bugs** that in a real system would cause downtime.

## What Remains in Terraform

After these two projects, the Terraform engine layer handles only the bare bootstrap:

- The `external-secrets` and `tailscale` namespaces (needed for bootstrap secrets)
- The bootstrap secrets `vault-ca-cert`, `vault-eso-token`, `tailscale-operator-oauth`
- User-managed CoreDNS (provider-specific: Proxmox needs Tailscale DNS forwarding)
- Flux bootstrap (entry point)

Everything else — operators, secret delivery, apps — is in Flux. Provider-agnostic.

## Lessons Learned

1. **The Terraform/Flux division is clear only on paper** — in practice, each component must be evaluated individually. ESO seemed provider-specific (because I thought I'd use cloud-native secret managers), but with a personal Vault it's provider-agnostic.

2. **Iterative reviews work** — not for finding architectural holes, but for catching the detail bugs that in a complex system make the difference between a successful deployment and a night of debugging.

3. **Merged paths in Vault are insidious** — creating a path that combines multiple fields is a valid solution only if there's an automated process keeping it synchronized. Otherwise it's a bug waiting to happen.

4. **A single bootstrap token** with a scoped policy is more manageable than 6 separate files. The `~/secrets/` directory remains as an immutable fallback, but the primary source is Vault.

In the end, the system is cleaner, better documented (wiki + Mnemosyne), and every component is in its correct architectural place. The next step will be a full validation cycle on a different cloud platform.
