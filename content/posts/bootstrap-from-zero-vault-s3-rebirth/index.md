+++
title = "Bootstrap from Zero: Rebuilding Everything from a Single S3 Bucket"
date = 2026-03-21T13:00:00+00:00
draft = true
tags = ["Kubernetes", "HashiCorp Vault", "Oracle Cloud", "Tailscale", "Security", "Secrets Management", "Talos OS", "S3", "Bootstrap", "Infisical", "Terragrunt"]
description = "How I designed a complete rebirth cycle for TazLab: from a blank machine to a fully operational Kubernetes cluster using only an S3 bucket, a passphrase, and an MFA device."
+++

## The Current State: The Plan Had a Gap

In the [previous article on this roadmap](/posts/tazlab-roadmap-hashicorp-vault-oracle-cloud/) I described why TazLab is migrating from Infisical to HashiCorp Vault CE, and the direction it's heading: dynamic secrets, automatic rotation, a second cluster on Oracle Cloud. The "what" and the "why" were clear.

What was missing was the "how does the system survive when everything disappears".

The question I couldn't get out of my head was this: if tomorrow morning Proxmox, Oracle Cloud, and my computer all burned down at the same time, what would I have left? An S3 bucket, a passphrase in my head, and a physical MFA device. That's it. From these three elements, everything must restart — not heroically and manually, but systematically, as automatically as possible.

This is the design session where we solved exactly that problem.

---

## The "Why": Migrating Is Not Enough, You Have to Reborn

The migration from Infisical to Vault is not just a vendor question. It's an opportunity to redesign the bootstrap from scratch — the moment when the entire ephemeral castle philosophy is put to the test.

An infrastructure is truly ephemeral only if you can destroy and rebuild it without fear. And you can do that without fear only if you've answered this question honestly: **what must exist outside the clusters to make them rebuildable?**

The answer has a precise shape. Not an endless series of scattered secrets, not a dependency on an always-on external service. Three anchors, all on the same S3 bucket:

```
S3: tazlab-storage/
├── tazpod/vault.tar.aes       ← bootstrap secrets (AES-256-GCM, passphrase)
├── vault/vault-latest.snap    ← Vault Raft snapshot (all app secrets)
└── pgbackrest/                ← PostgreSQL backup (Mnemosyne, tazlab-k8s data)
```

The first contains the bare minimum to start everything before any cluster exists. The second is Vault's memory — all application secrets, automatically updated every day. The third is the database: Mnemosyne data, configurations, history. None of the three makes sense without the other two. Together, they are everything needed to start over.

---

## The Target Architecture: Four Hard Decisions

Designing this cycle required untying four knots that, on the surface, seemed simple.

### The Bootstrap Problem: Which Comes First, the Chicken or the Egg?

The tazpod Docker image is **public**. It cannot contain credentials. But to download `vault.tar.aes` from S3 I need AWS credentials. And the AWS credentials are in the vault. And the vault is on S3.

The solution is not technical — it's architectural. I used **AWS IAM Identity Center** (AWS's SSO service): an interactive authentication flow where you enter your email, password, and MFA code, and receive temporary credentials valid for 8 hours. The AWS configuration file that goes into the image contains only the SSO portal URL and the role name — no secrets, safely publishable.

```
docker run tazzo/tazpod-ai
    │
    ▼
aws sso login --profile tazlab-bootstrap
    │  → email + password + physical MFA
    ▼
aws s3 cp s3://tazlab-storage/tazpod/vault.tar.aes ...
    │
    ▼
tazpod unlock  ←  passphrase (in my head only)
    │
    ▼
secrets/ open — everything else starts from here
```

The passphrase lives only in my head. The MFA device is physical. Without both, the S3 bucket is a useless encrypted archive.

### Vault Unseal: Professional Doesn't Mean Expensive

Vault always starts in a "sealed" state — it doesn't respond until it's given the key to decrypt its master key. In my head the problem seemed to require an external KMS: AWS KMS ($1/month), OCI KMS (free for software keys), something always available.

But there was a cleaner solution that required no external dependency. Vault's unseal keys (Shamir algorithm: 3 keys, 3 of 5 required to open) are generated once at initialization. I save them in `secrets/`. At bootstrap, `create.sh` uses them directly:

```bash
vault operator unseal $(cat /home/tazpod/secrets/vault-unseal-key-1)
vault operator unseal $(cat /home/tazpod/secrets/vault-unseal-key-2)
vault operator unseal $(cat /home/tazpod/secrets/vault-unseal-key-3)
```

It's completely automatic from the script's perspective, because the human interaction had already happened: passphrase + MFA at the start of the bootstrap had already opened `secrets/`. From that point on, no intervention required.

OCI KMS remains as an option for simulation environments where the manual cycle is inconvenient.

### The Network: Tailscale as an Operating System Extension

ESO on tazlab-k8s must be able to reach Vault on tazlab-vault (OCI) from the very first moment it's deployed. Vault cannot sit on a public endpoint without reason.

The solution is Tailscale — but not as a Kubernetes pod. As a **Talos operating system extension**. `siderolabs/tailscale` exists as an official extension: it gets baked into the image at the Talos Image Factory and starts as a system service, before Kubernetes even exists.

```
OCI node boots
    │
    ▼
Talos OS → Tailscale extension → node in tailnet   ← before K8s
    │
    ▼
Kubernetes bootstrap → cluster healthy
    │
    ▼
Terragrunt deploys Vault → ESO connects to Vault via tailnet ✓
```

The Tailscale auth key (reusable, tagged `tag:tazlab-node`) lives in `secrets/` and is injected into the machine config during provisioning. The node automatically rejoins the same network on every rebuild, with the same DNS name.

The same extension goes on tazlab-k8s. The two clusters communicate privately, exposing nothing to the internet.

### tazlab-vault: Minimal by Design

The last decision was perhaps the simplest once framed correctly: tazlab-vault doesn't need Flux.

Flux makes sense when you manage many applications that change continuously and want the cluster to self-reconcile. tazlab-vault has **one single responsibility**: running Vault. To deploy a single application, Flux is a layer of complexity that gains nothing. Vault upgrades must be deliberate, tested, and never automatic.

The choice is Terragrunt with the Helm provider — exactly the pattern already used in ephemeral-castle for ESO, MetalLB, and Longhorn. The layer structure:

```
secrets → platform → vault
```

No `engine` (ESO), no `gitops` (Flux). Vault uses Raft integrated storage on `hostPath` — it doesn't need Longhorn because persistent data is restored from the S3 snapshot on every rebuild anyway.

---

## Phased Approach: Seven Phases Toward Complete Rebirth

The work is organized in sequential phases, each stable before moving to the next.

**Phase A — Prerequisites**: configure AWS IAM Identity Center, create the SSO user with MFA, generate the Tailscale reusable auth key. Zero impact on existing clusters.

**Phase B — tazlab-vault minimal**: new Talos schematic with the Tailscale extension, resolve the OCI reserved IP blocker (from tazlab-vault-init), complete the Talos bootstrap, deploy Vault CE via Terragrunt, first initialization and save of unseal keys in `vault.tar.aes`.

**Phase C — Vault configuration**: enable KV v2, configure the Kubernetes auth method for ESO, migrate all secrets from Infisical to Vault KV.

**Phase D — tazlab-k8s migration**: update the Talos image with the Tailscale extension (rolling upgrade, not rebuild), replace the `ClusterSecretStore` from Infisical to Vault, update all `ExternalSecret` resources with the new KV paths.

**Phase E — tazpod Vault integration**: remove the Infisical logic from `main.go`, implement `tazpod pull` via Vault CLI, update `tazpod vpn` to use Tailscale instead of the never-tested custom WireGuard.

**Phase F — Decommission Infisical**: verify that zero components still use Infisical, remove provider and references from all repos, delete secrets from the Infisical account.

**Phase G — Make repos public**: audit git history with `trufflehog`, verify `.gitignore` coverage, make `tazpod`, `tazlab-k8s`, and `ephemeral-castle` public.

---

## Future Outlook: The Final Proof

There's a test that doesn't lie: can you make your repos public without fear?

If the answer is yes, you've truly achieved zero-secrets-in-git. Not as a declared principle, but as a verifiable reality. Anyone can open the code, see how everything works, and find no credentials, no tokens, no secrets. Security does not depend on obscurity.

The complete rebirth cycle then becomes this sequence, executable by anyone who has access to the three right elements:

```
Blank machine
    + S3 bucket (always available)
    + passphrase (in your head)
    + MFA device (in your pocket)
    ──────────────────────────────
    = complete, operational infrastructure, < 30 minutes
```

TazLab doesn't have a fixed address. It only has an S3 Bucket from which it is reborn.
+++
