+++
title = "The PC Shuts Down, the Castle Rises: Migrating the Kubernetes Cluster to Hetzner in Two Hours"
date = 2026-10-28T12:00:00+02:00
draft = true
description = "Technical chronicle of an expected hardware failure: when the local lab machine gave way to overheating, the promise of the Ephemeral Castle moved from theory to practice. How the clean separation between Terraform and Flux enabled the rebirth of the cluster on Hetzner in just two hours."
tags = ["kubernetes", "gitops", "fluxcd", "terraform", "hetzner", "disaster-recovery", "vault", "talos"]
author = "Tazzo"
+++

> **Working Note:** This draft documents the chronicle of the hardware failure, the emergency migration to Hetzner Cloud, and the architectural audit that confirmed the validity of decoupling Terraform and Flux.

## Introduction: The Foreseen Crash and the Proving Ground

In previous articles dedicated to the vision of the **Ephemeral Castle**, I described at length the founding objective of my homelab: building a nomadic, reproducible, and stateless infrastructure capable of rising from scratch wherever a network connection exists, in minimal time. The theoretical premise was straightforward: drastically separate the physical provisioning layer from the application layer. Terraform prepares the ground; Flux CD populates and governs the castle.

On October 27, 2026, theory was abruptly called to face reality.

The desktop computer hosting the home cluster (a Proxmox VE node running Talos Linux virtual machines and service containers) shut down unexpectedly due to overheating. No disk failure, no software error, no failed upgrade: the physical hardware simply could no longer handle the thermal strain, tripping into intermittent protective power-offs.

Faced with a PC collapsing within minutes of powering on, two paths lay open: attempt therapeutic obstinacy with disassembly, emergency fans, and local repairs, or pull the trigger on the nomadic plan and **migrate the entire cluster to Hetzner Cloud**.

We did not spend days completing the transition: **it took roughly two hours of active work**.

This was neither arrogance nor a stroke of luck: the outcome was the direct consequence of deliberate architectural choices planned months in advance. The incident forced us into practice with what we had planned to tackle from the very beginning. The sole reason it took two hours rather than a few minutes was that the Terraform layer for Hetzner had not yet been fully polished and tested. Once that ground was laid with Terraform, Flux restored the entire application fleet almost instantly and virtually painlessly.

---

## Phase 0: Triage of Real State and Hot Rescue

Before initiating any reconstruction in the cloud, the absolute priority of disaster recovery is distinguishing what is purely ephemeral from what constitutes real persistent state. If an element can be rebuilt through code or synchronized from Git, it is not saved; only and exclusively what cannot be regenerated from scratch is preserved.

The resource mapping confirmed the robustness of the architecture:

| Component | State Type | Recovery Strategy |
|---|---|---|
| **Kubernetes Cluster (Talos)** | **Stateless** | Entirely defined in Git repositories (`tazlab-k8s` and `ephemeral-castle`). Zero unique data on local disks. |
| **Vault (Secret Store)** | **Independent** | Already placed beforehand on an external Hetzner VPS; did not reside on the failing machine. |
| **PostgreSQL Application Database** | **Recoverable** | Continuous backups managed by pgBackRest to an S3-compatible bucket. |
| **Ambrogio + Ambrogio Memory** | **Real State** | Two local SQLite databases (`ambrogio.db` and `memory.db`, ~135 MB) hosted in LXC containers. |
| **ADA (Agent House)** | **Real State** | Database `agent.sqlite` (450 MB) and operational configurations. |
| **21 Local Git Repositories** | **Consistency Audit** | Immediate verification of local commits not yet pushed to GitHub remotes. |

Taking advantage of the brief windows during which the PC remained powered on before hitting critical temperatures, we executed the rescue sequence in strict order of priority:

1. **User Archive Extraction:** Rapid tarball generation for the LXC container home directories containing binaries and data for Ambrogio, Memory, and ADA.
2. **Git Audit and Bundles:** Auditing 21 repositories revealed an insidious surprise. While most projects matched GitHub, three repositories were ahead: `tazpod` (+1 commit), `tazlab-secrets` (+16 commits), and above all **`ada` with 125 unpushed commits**. Ada's container had been configured internally with a local bare repository and had never synchronized its changes to the GitHub remote. We immediately saved complete bundles to prevent catastrophic code loss.
3. **Transactional Backup of SQLite Databases:** A frequent mistake during emergencies is copying database files while engines are running (`cp db.sqlite`). With SQLite running in WAL (Write-Ahead Logging) mode, a hot copy yields corrupt or inconsistent files. Our first attempt with the engine running showed a discrepancy between read records (`entries 22016` versus `22020`). We cleanly stopped the services and ran atomic backups:
   ```bash
   sqlite3 memory.db ".backup memory-2026-10-27-final.sqlite"
   sqlite3 ambrogio.db ".backup ambrogio-final.sqlite"
   ```
   Integrity was verified immediately (`PRAGMA integrity_check;`) with verified sha256 checksums.
4. **Forced Power-off:** Once containers were halted, the machine was powered off permanently with `systemctl --force poweroff`. From that moment onward, the home hardware was never touched again.

---

## Phase 1: The Terraform Bottleneck and Laying the New Ground

The philosophy of the Ephemeral Castle enforces a strict **Division of Labour**:
- **Terraform** owns infrastructure and provider-specific resources (node provisioning, Talos Linux configuration, cloud firewalls, Hetzner CCM network controller, Longhorn storage, and essential secret bootstrapping).
- **Flux CD** owns all platform-agnostic resources (internal operators, certificates, ingresses, databases, workloads, and monitoring).

Why did the migration take two hours instead of a few minutes?

The entire reason lay within Terraform. While the Proxmox module was mature, tested, and battle-hardened over months of operational use, the module for Hetzner Cloud (`hcloud-talos`) had been outlined and planned architecturally, but had never been validated end-to-end with all supporting units. Refinements were missing for private network integration (flannel over interface `eth1`), binding the Hetzner Cloud Controller Manager, and automating the `create.sh` workflow.

In approximately an hour and a half of focused engineering work on the `ephemeral-castle` repository (on branch `feat/hetzner-rebirth`), we closed the technical debt:
1. Porting and completing the 4 missing units: cloud networking, bootstrap engine, Longhorn storage, and GitOps triggers.
2. Generating Talos Cloud nodes (`k8s-cp-01` and `k8s-wk-01`) on Hetzner instances with immutable configurations.
3. Allocating the public cloud Load Balancer (`188.245.75.246`) routing traffic toward private node endpoints.

The moment Terraform completed foundational infrastructure provisioning, it installed a single essential component inside the cluster: **Flux CD**, handing it credentials to connect to the `tazlab-k8s` GitOps repository.

---

## Phase 2: The GitOps Triumph: Flux Raises the Castle with Virtually Zero Changes

Here the extraordinary power of the GitOps paradigm shone through: the exact instant Flux initiated reconciliation of the `tazlab-k8s` repository, the entire application ecosystem reconstructed itself in a cascading sequence.

We did not rewrite manifests for websites, nor manually reconfigure Nginx, Dex, Grafana, OAuth2-Proxy, MinIO, or database controllers. The tree of 26 Kustomizations declared in Git was processed and applied automatically:

```
Flux Kustomizations: 26/26 Ready
├── infrastructure-traefik          [Ready]
├── infrastructure-cert-manager     [Ready]
├── infrastructure-longhorn         [Ready]
├── infrastructure-operators-vso    [Ready]
├── infrastructure-vso-secrets      [Ready]
├── apps-database-pgo               [Ready]
├── apps-monitoring-grafana         [Ready]
├── apps-auth-dex                   [Ready]
└── apps-workload (blog, wiki, ...) [Ready]
```

The architectural invariant was fully preserved: **the `tazlab-k8s` repository remained strictly singular and identical for both local and cloud environments**. No separate branch existed for Hetzner, nor duplicated directories.

The only divergences required by the cloud platform were handled through data abstraction in `cluster-vars`, injected by Terraform via `postBuild.substituteFrom`:
- **`ddns_replicas`**: set to `0` on Hetzner because the cloud server possesses static public IP addresses, whereas on Proxmox it is set to `1` to continuously update the dynamic record of the home connection.
- **`vault_jwt_mount`**: configured as `${vault_jwt_mount:=jwt}` (defaulting to `jwt` for Proxmox, while Hetzner selects `jwt-hcloud`).
- **Load Balancer Targeting**: annotation for the Hetzner Cloud Controller Manager directing the balancer to private node IPs, inertly ignored by MetalLB in the local environment.

---

## Phase 3: Technical Bottlenecks Analysis and Methodical Resolution

Because this marked the first time the cluster was brought up on Hetzner, several operational hiccups surfaced during the boot sequence. Below is a methodical cause-effect-resolution analysis of each issue, as precise diagnosis carries the didactic value.

### 1. Vault CA Truncation (`gopass show -o`)
- **Symptom:** Vault Secrets Operator (VSO) pods failed to start, logging: `invalid CA cert in secret "vso-system/vault-ca-cert": no valid certificates found`.
- **Diagnosis:** In the `create.sh` bootstrap script, the Vault Certificate Authority certificate was retrieved using `gopass show -o vpn/vault/ca`. The `-o` flag (historically introduced to print passwords only) prints strictly the first line of output. The first line of a PEM certificate is `-----BEGIN CERTIFICATE-----` (exactly 27 bytes). The secret injected into Kubernetes contained only the header line stripped of cryptographic payload.
- **Resolution:** Corrected the command in `create.sh` by removing the `-o` flag to extract the complete PEM certificate (1,854 bytes).

### 2. Tailnet Name Resolution (MagicDNS)
- **Symptom:** VSO could not reach Vault at `lushycorp-vault.magellanic-gondola.ts.net:8200`, returning an `NXDOMAIN` error.
- **Diagnosis:** Unlike the Proxmox installation where CoreDNS was replaced by a custom deployment forwarding the `.ts.net` zone, standard Talos CoreDNS on Hetzner lacked visibility into the Tailscale network.
- **Resolution:** We converged the `VaultConnection` resource toward the internal cluster egress proxy (`lushycorp-vault.tailscale.svc.cluster.local:8200`), setting `tlsServerName` to the original MagicDNS name to validate TLS certificate matching. An elegant, clean solution completely agnostic to the underlying platform.

### 3. Vault JWT Backend and Roles for Hetzner (`jwt-hcloud`)
- **Symptom:** Authentication requests from cluster ServiceAccounts to Vault were rejected with `no known key successfully validated the token signature`.
- **Diagnosis:** The external Vault instance only had the `auth/jwt` authentication mount tied to the old local cluster's public key. The cloud-dedicated backend (`jwt-hcloud`) had not yet been instantiated in Terraform, leaving ten component-specific roles (database, monitoring, application secrets) absent.
- **Resolution:** Configured the `jwt-hcloud` mount on Vault registering the public key of the new Talos cluster ServiceAccounts, established rate-limiting quotas, and replicated component roles with required policy mappings.

### 4. Validation of the `bound_issuer` Claim
- **Symptom:** JWT token validation failure: `invalid issuer (iss) claim`.
- **Diagnosis:** Talos injects an issuer into the service token matching the actual API server endpoint (`https://kube.tazlab.net:6443`). The Vault backend validated the claim against the Kubernetes default; Vault performs a verbatim string comparison and does not tolerate format mismatches or comma-separated lists.
- **Resolution:** Aligned the `bound_issuer` parameter inside the Terraform configuration with the exact API endpoint value of the new cluster.

### 5. PostgreSQL Database Restore from S3
- **Symptom:** When deploying PGO (CrunchyData Postgres Operator), the cluster initialized an empty database rather than restoring historical data.
- **Diagnosis:** PGO restores data via the `dataSource` block only during the initial creation of an `instance set`. On Proxmox, data resided on the local persistent volume and that block had been removed following the PostgreSQL 17 upgrade. On Hetzner's fresh Longhorn storage, the volume was virgin.
- **Resolution:** Performed a manual restore via pgBackRest pointing to differential backups on S3, and made the procedure **declarative** in the shared manifest:
  ```yaml
  dataSource:
    pgbackrest:
      stanza: db
      configuration:
        - secret:
            name: pgo-s3-creds
  ```
  Consequently, any future rebirth operates with identical idempotence.

---

## Verified Final State and Metrics

At the conclusion of the two-hour intervention, the validation chain returned full positive confirmation:

```text
Cluster:     Hetzner Cloud (2 Talos Linux nodes Ready)
Flux:        26/26 Kustomizations synchronized (master@a8accb0)
VSO:         14/14 VaultStaticSecrets synchronized · 7/7 VaultPKISecrets issued
Database:    PGO Postgres 17.2 active (4/4 pods, pgBouncer 2/2, repo-host 2/2)
Workloads:   Hindsight, Mnemosyne, Dex, OAuth2-Proxy, Grafana, pgAdmin all Running
Web Sites:   blog=200, wiki=200, teaching=200, halloween=200 (Let's Encrypt TLS)
Apex Domain: tazlab.net -> 301 Permanent Redirect to https://blog.tazlab.net
```

All laboratory services returned to full operational readiness in the cloud, featuring end-to-end TLS encryption and identities managed centrally through Vault.

---

## Conclusions: Lessons That Justify an Architecture

A sudden hardware failure is the most unforgiving test an infrastructure can endure. When the local machine collapsed, there was no room for improvisation or frantic manual patching: the system responded precisely as it had been engineered to respond.

Four fundamental lessons emerge from this experience:

1. **IaC/GitOps Decoupling is an Insurance Policy:** Separating Terraform (the ground) from Flux (the castle walls) averted disaster. Maintaining an application repository (`tazlab-k8s`) completely agnostic to underlying hardware allowed twenty-six complex services to remount in mere minutes from the instant cloud nodes became available.
2. **Technical Debt Comes Due at the Worst Time:** The sole reason the operation took two hours instead of fifteen minutes was that the Terraform layer for Hetzner had not been polished during peacetime. Keeping provisioning modules aligned across all planned targets is indispensable for transparent failover.
3. **SQLite Files Demand Atomic Discipline:** Copying active database files during a failure exposes systems to severe data corruption. Methodical use of `sqlite3 .backup` and immediate integrity checks preserved months of historical memory and agent conversations.
4. **Git is the True Record of State:** Pre-shutdown audits prevented the loss of 125 code commits confined to a local bare repository. In a distributed architecture, an unpushed commit to a trusted remote is a commit that does not exist.

The Ephemeral Castle proved the validity of its guiding principle in the field: physical machines perish, but infrastructure governed by code always rises again.
