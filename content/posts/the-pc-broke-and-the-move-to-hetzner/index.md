+++
title = "The PC Shuts Down, the Castle Rises: Migrating the Kubernetes Cluster to Hetzner in Two Hours"
date = 2026-10-28T12:00:00+02:00
draft = false
description = "Technical chronicle of an expected hardware failure: when the local lab machine gave way to overheating, the promise of the Ephemeral Castle moved from theory to practice. How the clean separation between Terraform and Flux enabled the rebirth of the cluster on Hetzner in just two hours."
tags = ["kubernetes", "gitops", "fluxcd", "terraform", "hetzner", "disaster-recovery", "vault", "talos"]
author = "Tazzo"
+++

## The Foreseen Crash and the Proving Ground

The **Ephemeral Castle** was born on a verifiable promise: a nomadic, reproducible, and stateless infrastructure capable of rising from scratch wherever a network connection exists. The clean separation between the physical provisioning layer and the application layer — Terraform to prepare the ground, Flux CD to populate and govern the castle — was the part of that promise no test had yet put to the proof.

On October 27, 2026, the test arrived on its own. The desktop computer hosting the home cluster — a Proxmox VE node running Talos Linux virtual machines and service containers — shut down due to overheating: no disk failure, no software error, no failed upgrade. The physical hardware could no longer sustain the thermal strain and entered intermittent protective shutdowns within minutes of powering on. Faced with a PC collapsing like that, two paths lay open: therapeutic obstinacy with disassembly, emergency fans, and local repairs, or **migrating the entire cluster to Hetzner Cloud**.

I took the second. The transition did not take days: **roughly two hours of active work were enough**, and the reason for that duration is the most useful part of the story. The Terraform layer for Hetzner had not yet been fully polished and tested; once that ground was laid, Flux restored the entire application fleet almost instantly. This is neither arrogance nor a stroke of luck: it is the direct consequence of deliberate architectural choices, planned months in advance.

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

Two fundamental lessons emerge from this experience:

1. **IaC/GitOps Decoupling is an Insurance Policy:** Separating Terraform (the ground) from Flux (the castle walls) averted disaster. Maintaining an application repository (`tazlab-k8s`) completely agnostic to underlying hardware allowed twenty-six complex services to remount in mere minutes from the instant cloud nodes became available.
2. **Technical Debt Comes Due at the Worst Time:** The sole reason the operation took two hours instead of fifteen minutes was that the Terraform layer for Hetzner had not been polished during peacetime. Keeping provisioning modules aligned across all planned targets is indispensable for transparent failover.

The Ephemeral Castle proved the validity of its guiding principle in the field: physical machines perish, but infrastructure governed by code always rises again.
