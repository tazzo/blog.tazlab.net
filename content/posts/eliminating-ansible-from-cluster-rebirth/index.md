+++
title = "Consolidating Cluster Bootstrap and Eliminating Ansible from the Rebirth Cycle"
date = 2026-06-07T20:00:00+00:00
draft = false
tags = ["Kubernetes", "HashiCorp Vault", "Terraform", "Terragrunt", "Ansible", "Vault Secrets Operator", "Flux", "GitOps", "Talos", "Proxmox", "PostgreSQL", "PGO"]
description = "Three infrastructure consolidation projects: removing Ansible and vault-configurator, consolidating all Vault configuration into pure Terraform, and achieving a one-shot cluster rebirth with zero manual interventions in about 12 minutes."
+++

## The Architectural Problem

When I designed the TazLab cluster rebirth cycle, the sequence was: Terraform created the VMs and installed Talos, then Ansible took over to configure Vault. Ansible ran `kubectl exec` into a `vault-configurator` pod — a container with the Vault CLI inside — to execute commands like `vault auth enable jwt` and `vault policy write vso-policy`. Finally, Flux completed the application deployments.

This approach worked, but it had three structural problems.

The first was the **circular dependency between Vault and the cluster**. Vault is a persistent service on a Hetzner VM, but configuring it required the K8s cluster (where vault-configurator ran). And the K8s cluster, to function, needed Vault (for bootstrap secrets). Breaking this loop required complex orchestration: Ansible had to wait for the cluster to be up, execute the commands, and only then could Flux converge.

The second was the **absence of GitOps for Vault configuration**. Ansible is a procedural tool, not a declarative one. Vault's configuration state was not in Git, not in Terraform. If someone manually modified a policy on Vault, the next Ansible run would overwrite it anyway — but if Ansible failed, Vault would remain in an inconsistent state with no Git rollback capability.

The third was the **fragility of the vault-configurator pod**. It was a Kubernetes Deployment with `sleep 36000` that served only as a proxy for `kubectl exec`. If the pod crashed, Ansible failed. If the cluster was unstable, the command never reached Vault. It was an unnecessary point of failure.

This article recounts the journey to completely eliminate Ansible and vault-configurator, consolidate all Vault configuration into pure Terraform, and achieve a fully one-shot cluster rebirth cycle: about 12 minutes, zero manual interventions, from VM destruction to a complete 83-pod cluster.

> **Note**: This article is part of a series on TazLab infrastructure consolidation. The previous project covered migrating bootstrap secrets to Vault and moving External Secrets Operator (ESO) from Terraform to Flux. This project builds on that foundation and completes the transition by removing the last non-declarative component: Ansible.

## Reference Architecture

Before diving into the project details, it helps to understand the architecture I work with.

TazLab is a Kubernetes cluster on two Proxmox VMs (control-plane and worker), with Longhorn distributed storage, Tailscale as the private network, and Vault as the secret store on a separate Hetzner VM. The cluster is **ephemeral**: each test cycle starts from zero with `destroy.sh` deleting the VMs, and `create.sh` rebuilding them from Talos golden images. Vault is **persistent**: it survives cycles because it runs on Hetzner, with S3 snapshots for disaster recovery.

This separation — Platform Landing Zone (Vault on Hetzner) and Workload Landing Zone (K8s cluster on Proxmox) — is a well-known architectural pattern, but in our case it was poorly implemented: Vault was persistent, yet its configuration depended on the ephemeral cluster.

## The Three Projects

The migration was split into three projects, executed sequentially after an extensive review phase.

### Project 1: JWT Auth in Terraform

The first step was moving the Vault JWT auth backend configuration from Ansible to Terraform.

The JWT auth backend allows Vault to authenticate JWT tokens signed by the Kubernetes API Server. When a ServiceAccount (e.g., `vso-auth-sa`) presents its JWT token to Vault, Vault verifies the signature using the cluster's public key and grants access according to the associated policies.

Ansible configured this backend with:
```bash
kubectl exec -n vault-configurator vault-configurator -- vault auth enable jwt
kubectl exec -n vault-configurator vault-configurator -- vault write auth/jwt/config \
    jwt_validation_pubkeys=<public-key> \
    bound_issuer=<issuer>
```

The problem: vault-configurator had to already be running in the cluster to execute these commands. But the cluster couldn't start without Vault configured. It was a circular dependency.

The solution was to **generate the RSA keypair offline** in the `secrets` Terragrunt layer (the very first layer, always executed) and configure Vault JWT auth directly via the Terraform Vault provider, using Vault's root token. The Vault provider talks directly to Vault over Tailscale — no intermediate pod needed.

```hcl
# modules/secrets-fetcher/main.tf
resource "tls_private_key" "serviceaccount" {
  algorithm = "RSA"
  rsa_bits  = 2048
}
```

```hcl
# live/persistent/vault-jwt-config/main.tf (after refactoring)
provider "vault" {
  address = "https://lushycorp-vault.magellanic-gondola.ts.net:8200"
}

resource "vault_jwt_auth_backend" "k8s" {
  path         = "jwt"
  bound_issuer = "https://lushycorp-k8s.magellanic-gondola.ts.net:6443"
  jwt_validation_pubkeys = [var.serviceaccount_public_key_pem]
}
```

The private key is injected into Talos via `config_patches`, so the API Server signs ServiceAccount tokens with that key:

```hcl
# modules/proxmox-talos/main.tf
cluster = {
  serviceAccount = {
    key = base64encode(var.serviceaccount_private_key_pem)
  }
}
```

This project resolved the first dependency: Vault JWT auth no longer needs the cluster.

### Project 2: Database Engine in Terraform

The second project handled the Vault database engine configuration for PostgreSQL.

Vault's database engine generates dynamic credentials: when Grafana requests a PostgreSQL user, Vault creates a temporary user with a one-time password, grants it to Grafana for the required duration, and revokes it upon expiration.

Previously, Ansible configured this engine through vault-configurator. The new version is a Terraform module that:

1. Creates the PostgreSQL database connection (with `verify_connection = false` — a crucial detail)
2. Defines the `grafana` role with `creation_statements` for user generation
3. Saves the bootstrap passwords in a Vault KV secret

```hcl
# modules/vault-db-config/main.tf
resource "vault_database_secret_backend_connection" "tazlab_db" {
  backend           = "database"
  name              = "tazlab-db"
  verify_connection = false  # Vault does not need the DB at this point

  postgresql {
    connection_url = "host=tazlab-db.magellanic-gondola.ts.net port=5432 dbname=tazlab user={{username}} password={{password}} sslmode=disable"
    username       = "tazlab-admin"
    password       = var.tazlab_admin_password
  }
}
```

In parallel, **Secret Adoption** for PGO (Crunchy Data PostgreSQL Operator): the Kubernetes secrets containing passwords are created before PGO exists, and PGO adopts them by adding the SCRAM hashes required for PostgreSQL authentication. This pattern is essential because PGO cannot generate the passwords on its own — they must be predictable by Vault.

```hcl
# modules/k8s-engine/main.tf
resource "kubernetes_secret_v1" "pguser_tazlab_admin" {
  metadata {
    name      = "tazlab-db-pguser-tazlab-admin"
    namespace = "tazlab-db"
    labels = {
      "postgres-operator.crunchydata.com/cluster" = "tazlab-db"
      "postgres-operator.crunchydata.com/pguser"  = "tazlab-admin"
    }
  }
  data = {
    password = var.tazlab_admin_password
    verifier = ""  # PGO will populate this field
  }
  lifecycle { ignore_changes = [data, metadata] }
}
```

### Project 3: Cleanup — Removing Ansible and vault-configurator

The final project removed everything that was no longer needed:
- The Ansible playbook and role for Vault K8s configuration
- The vault-configurator deployment
- All references across Flux kustomizations
- The out-of-state bootstrap token generation

The result: No more Ansible in the cluster rebirth cycle.

## The Preventive Reviews

Before writing a single line of Terraform code, I conducted an extensive review phase that proved crucial to the project's quality.

**Multi-LLM Review**: I compared 5 different language models (DeepSeek, MiMo, GLM, Qwen, Kimi) on the same architectural patterns. Each model found different issues — a bug in bound_issuer, an error in PGO verifier handling, a missing rate limit. In the end, 40 findings were reduced to 20 real ones, all resolved before the first execution.

**Iterative Design Review**: Each project went through 3-4 design revision cycles before moving to code writing. The reviews caught problems such as:
- An error in calculating the Vault-to-cluster dependency (chicken-egg)
- The missing `external-secrets` namespace in the Flux kustomization (which would have caused ESO to fail)
- The absence of the `tls` provider in the root Terragrunt (which would have caused runtime errors)

**Chronicle Review**: I reviewed past decisions documented in the system chronicle to avoid repeating already-solved mistakes.

> **Lesson**: Multi-model reviews are not an academic exercise. In our case, they caught at least 3 bugs that would have crashed the first test cycle. The cost of review was amply repaid by the time saved in debugging.

## The Most Problematic Bugs

Despite the reviews, the implementation path encountered several bugs that required iterative test cycles. Here are the most significant ones.

### 1. Terragrunt Cache Dependency

The first wall was Terragrunt. When you clear the Terragrunt cache (`.terragrunt-cache/`) and run `apply` on a layer that depends on another, Terragrunt must perform `terraform init` out-of-band to read the dependency's state. Without Terraform's local ledger (`.terraform/`), Terraform detects a changed backend and requests `-reconfigure`. Terragrunt **does not pass** `-reconfigure` during out-of-band init operations, so it fails silently and propagates the error as "no variable named dependency" — a misleading message that hides the real cause.

```bash
# Cryptic error
Error: Unknown variable
  on terragrunt.hcl line 68:
  There is no variable named "dependency".
```

The solution was adding `extra_arguments "init_reconfigure"` and `disable_dependency_optimization = true` to the root `terragrunt.hcl`:

```hcl
terraform {
  extra_arguments "init_reconfigure" {
    commands = ["init"]
    arguments = ["-reconfigure"]
  }
}

remote_state {
  disable_dependency_optimization = true
}
```

### 2. Namespace Ordering

One of the most subtle problems was namespace creation ordering. The engine layer (Terraform) creates Kubernetes secrets (vault-ca-cert, vault-eso-token, tailscale-operator-oauth) in specific namespaces. But these namespaces are also created by Flux (kustomization `infrastructure-operators-namespaces`). Flux had not yet started when the engine layer was executing, because engine runs in Phase 1 (Terraform foundation) and Flux in Phase 2 (GitOps harmonization).

The fix was twofold: on one hand, the `k8s-engine` module creates the necessary namespaces (tailscale, external-secrets, tazlab-db) before creating secrets inside them. On the other, the definition of some critical namespaces (dex, external-secrets) was moved from the operator folder (which depends on Flux) to the centralized `infrastructure-operators-namespaces` kustomization, which executes first in the Flux chain.

This also solved another problem: VSO (Vault Secrets Operator) was trying to create a ServiceAccount in the `dex` namespace, but the namespace didn't exist yet because its definition was in the `operators/dex/` folder, which depends on `infrastructure-bridge` — too far down the chain.

### 3. random_password Lifecycle

Database passwords are generated with Terraform's `random_password`. The problem: without `lifecycle { ignore_changes = [result] }`, every `terragrunt apply` execution regenerates a different password. This means Vault ends up with one password, PGO with another, and the database connection fails.

```hcl
resource "random_password" "tazlab_admin" {
  length           = 32
  special          = true
  override_special = "_-._~"
  lifecycle {
    ignore_changes = [result]
  }
}
```

Furthermore, passwords must share the **same source of truth**. Initially, `random_password` was in the `engine` layer, but vault-db-config depended on engine to get them. This created an unnecessary dependency — vault-db-config had to wait for engine to be applied (after platform, after cluster health).

The solution was moving `random_password` to the `secrets` layer (the first Terragrunt layer), which executes before everything else. Now both engine and vault-db-config depend on secrets, and vault-db-config can run immediately after vault-jwt-config, before the VMs even exist.

### 4. Redundant Post-Flux Steps

This was the most time-consuming bug. For three test cycles, create.sh would reliably die after Flux convergence while waiting for the database. The flow was:

```
Flux convergence ✅
  → PGO wait (secret + master pod) → timeout 300s (or 600s)
    → ALTER ROLE (never executed)
      → VDS annotate (never executed)
        → vault read database/creds/grafana (never executed)
```

create.sh exited with an error, and I would manually execute the remaining steps. For three cycles I believed these steps were necessary: ALTER ROLE to synchronize the password between Vault and the database, annotating the VaultDynamicSecret to force VSO to recreate Grafana's credentials, the smoke test to verify.

Then, in a cycle where create.sh died before reaching these steps, I discovered that **the cluster was working perfectly anyway**. The password was already synchronized (same source: secrets-fetcher), VSO had automatically reconciled the VaultDynamicSecret, Grafana was up and running.

The entire post-Flux block was redundant because:
- vault-db-config had already been applied **before platform** (with the cycle 7 refactoring), so by the time VSO started after Flux, Vault's database configuration was already in place
- The passwords shared the same source (secrets-fetcher), so no ALTER ROLE was needed
- VSO reconciles the VaultDynamicSecret autonomously within 3 minutes, no manual annotation required

The entire post-Flux block (over 60 lines of code, 3 separate timeouts, 2 infinite loops) was removed from create.sh.

### 5. kubectl wait pod master

The last bug that took the longest to diagnose. `kubectl wait --for=condition=Ready pod -l postgres-operator.crunchydata.com/role=master --timeout=600s` **fails immediately** if no pod matches the selector at execution time. It does not wait 600 seconds — it exits right away with "no matching resources found". The `--timeout` only applies to pods that **already exist**.

The fix was splitting the wait into two phases:

```bash
# Phase 1: wait for the pod to exist
while [[ -z "$MASTER_POD" ]]; do
  MASTER_POD=$(kubectl get pod -n tazlab-db -l role=master -o name 2>/dev/null || echo "")
  if (( SECONDS > TIMEOUT_POD )); then exit 1; fi
  sleep 10
done

# Phase 2: wait for it to be Ready
kubectl wait "$MASTER_POD" -n tazlab-db --for=condition=Ready --timeout=300s
```

## The Result

After 9 test cycles, 8 destroy+create runs, and countless fixes, the cluster rebirth cycle is now **fully one-shot**.

```
secrets (16s) → vault-jwt-config (18s) → vault-db-config (18s) → platform (101s)
→ engine (21s) → networking+gitops+storage (parallel, 115s)
→ Flux convergence
```

Total time: **about 12 minutes**. With 8 for Terraform + Flux, and 4 for full database convergence (PGO restore job + master pod). create.sh exits after Flux convergence, but the cluster continues converging autonomously to all 83 pods Running. Zero manual interventions.

### What Changed

| Before (Ansible) | After (Terraform) |
|------------------|-------------------|
| 9 manual interventions per cycle | 0 manual interventions |
| vault-configurator pod (cluster dependency) | Direct Vault provider over Tailscale |
| Circular Vault ↔ Cluster dependency | Vault configured before cluster exists |
| State not in Git | Everything in Terraform + Flux |
| vault-db-config after Flux (would die) | vault-db-config before platform |
| Passwords in engine layer (dependency) | Passwords in secrets layer (single source) |
| Manual VDS annotation | VSO auto-reconciles |

### Lessons Learned

1. **Separate persistent configuration from cluster dependencies**. If Vault runs on an external VM, configure Vault before the cluster exists. Do not mix persistent configuration with workload deployment.

2. **Passwords must have a single source of truth**. If multiple components (engine, vault-db-config) use the same password, generate it in the earliest possible layer and pass it via dependency where needed.

3. **Do not trust `kubectl wait` timeouts**. `kubectl wait` with a label selector fails immediately if no pod exists. Use an explicit polling loop instead.

4. **Conduct preventive reviews with different models**. The multi-LLM review caught bugs that no human reviewer would have found. It costs less than a failed test cycle.

5. **If a post-bootstrap step always fails, maybe it is not needed**. If the cluster works without a step (ALTER ROLE, annotate, smoke test), that step is redundant. Do not force it — remove it.
