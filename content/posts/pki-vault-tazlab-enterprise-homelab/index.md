+++
title = "Vault PKI on TazLab: Building an Enterprise PKI in a Homelab"
date = 2026-07-01T15:00:00+02:00
draft = false
description = "Sixteen researches, fifteen reviews, one day of implementation: the journey to build a three-tier PKI with Vault, Let's Encrypt, and mTLS on PostgreSQL in a Talos Kubernetes cluster. A project born as a prerequisite for multi-cluster database, growing into the most complex piece of the infrastructure."
tags = ["Vault", "PKI", "Kubernetes", "Talos", "PostgreSQL", "mTLS", "Grafana", "Let's Encrypt", "CRISP", "TazLab"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

## The Journey, Not the Urgency

If you've been following TazLab's story for a few months, you've noticed a common thread: the migration toward **dynamic secrets**. Not replacing one secret provider with another, but changing paradigms — from static credentials, written in YAML manifests and rotated manually, to credentials generated on the fly, with leases, automatic rotation, and zero human contact.

In the [previous post]({{< ref "first-steps-toward-dynamic-secrets" >}}) I described the first steps: JWT auth, Vault Agent Injector, the Talos PKI disaster. Then [the discovery of VSO]({{< ref "man-in-the-loop-vso-deep-research" >}}) and the decision to abandon the injector. Then [the formalization of the CRISP method]({{< ref "crisp-2-verified-research-methodology" >}}): research before writing code, verification markers in plans, mandatory reviews.

Every step paved the way for this project: **the PKI**.

The end goal? Being able to replicate the PostgreSQL database across two clusters (Proxmox + Hetzner) with automatic failover. For that, you need mTLS — client certificates, not passwords — because static passwords don't survive a failover, and dynamic ones generate leases that expire at the wrong restart. The PKI was already in the long-term plan to raise the lab's security level. It became an operational prerequisite for the next step.

This article tells that story: a month of planning, sixteen researches, fifteen reviews, and one day of implementation.

## The Architecture: A Three-Tier PKI for a Two-Node Cluster

Before writing a single line of code, I spent weeks in the design phase. The **CRISP** method I implemented required answering a fundamental question: what is the right architecture for a PKI that must be secure yet manageable on a Talos cluster with one control plane and one worker?

The answer was a **three-tier PKI** — overkill for a homelab, but that's exactly what I wanted to learn:

- **Tier 0**: Offline Root CA (ECDSA P-384, 20-year validity) — generated on an air-gapped machine, key encrypted with GPG AES-256, never exposed online. It's the anchor of trust. If Vault is compromised, the Root CA stays safe.
- **Tier 1**: First Intermediate CA (10 years) — imported into Vault as `pki_root`.
- **Tier 2**: Second Intermediate CA (5 years) — generated and managed entirely by Vault as `pki_int`, with specific roles for each certificate type.

The domain split:

- **Public** (browser trust): blog.tazlab.net, wiki.tazlab.net, tazlab.net → Let's Encrypt via cert-manager
- **Internal** (tailnet): auth.tazlab.net, dex.tazlab.net, `*.tazlab.net` → Vault PKI
- **Database**: PostgreSQL server TLS + client certificates for each user → Vault PKI

## The Research: The Real Work Was Understanding

The CRISP method I implemented requires every design decision to be confirmed by external sources — no reliance on language model memory. This led to a structured research process that produced sixteen research documents, ten in the design phase and six during implementation.

### The Design Phase: R26—R35

1. **VaultPKISecret with JWT+JWKS**: how VSO integrates with the PKI engine
2. **PKI Role Configuration for Kubernetes**: critical parameters like `no_store`, `allowed_domains`, `allow_wildcard_certificates`
3. **Talos PKI Trust Bundle**: TrustedRootsConfig and the differences between `machine.certSANs` and `cluster.apiServer.certSANs`
4. **TLS Certificate Migration: Static to VaultPKI**: why gradual cutover beats big-bang
5. **Multi-Namespace TLS Secret Distribution**: reflector vs manual copy
6. **Vault PKI PostgreSQL Security**: how to set up mTLS for the database
7. **Crunchy PGO v5 mTLS Vault**: how PGO handles certificates
8. **Vault PKI Chain Resolution**: why the certificate chain was incomplete
9. **VSO Secret Transformation Configuration**: how to dynamically generate the `ca.crt` file
10. **Architectural Verification**: validating the overall approach

Each research produced a Markdown document archived in the CRISP project. Many revealed complexities that a superficial analysis would have missed.

### The Implementation Phase: Six Field Researches

1. **Enabling TrustedRootsConfig on Talos**: why `kubectl apply` failed and `talosctl patch mc` was needed
2. **PostgreSQL mTLS Configuration for Applications**: each client (psql, Grafana, pgAdmin, Go) has different requirements
3. **Resolving Vault PostgreSQL TLS Error**: why `ca_chain` was empty despite `set-signed`
4. **Crunchy PGO Custom CA Configuration**: how PGO makes `ssl_ca_file` immutable
5. **Grafana Kube-Prometheus-Stack Configuration**: why `grafana.command` is ignored
6. **Grafana PostgreSQL mTLS Helm Setup**: the final configuration that worked

Without these researches, I'd still be trial-and-erroring on problems that — once understood — were solved in minutes.

## The Reviews: Fifteen Cycles to Refine the Design

The CRISP method involves structured review cycles. For this project I did three major ones, each identifying between 25 and 35 design gaps. Each gap was resolved with a design change and, where necessary, a confirming research.

Some examples:

- **`no_store` for `internal-ingress`**: initially `true`. The review highlighted that the wildcard `*.tazlab.net` covers auth and dex — identity services. If the certificate is compromised, without `no_store=false` it cannot be revoked. Changed to `false`.
- **Missing `allow_wildcard_certificates`**: mandatory parameter for issuing wildcards. Without it, Vault rejects the request with error 400. Not in the initial design.
- **Separation of `db-client-*` roles**: from a single `database-client` role to four separate roles to prevent escalation: each PostgreSQL user has its own Vault role, with `allowed_domains` scoped to its username.

## The Implementation: One Day, Five Phases

With the design approved and research completed, the implementation was surprisingly fast: about 12 hours of work. But each phase brought its challenges — and some were solved only thanks to the researches done in previous days.

### Phase 0: Backup and Preparation

Before touching any configuration, I prepared the rollback point:

- Snapshots of the Talos VMs (CP and Worker) on Proxmox, via API token (VM.Snapshot permission added to the TerraformAdmin role after a quick `pveum` session)
- Vault Raft snapshot to S3 with the root token extracted from `init.json` (the one in `root-token.txt` had expired — discovery made on the spot)
- Git tag `pre-pki-build` on all three repositories involved

### Phase 1: Terraform — JWT Roles, PKI Policies, vso-system Namespace

The Terraform code for JWT roles and PKI policies was already written during the design phase. I extended the `vault-jwt-config` module with eight PKI policies and eight JWT roles using `bound_claims` glob on the `sub` claim. In parallel, I added the `vso-system` namespace and the `vault-ca-cert` secret to the `k8s-engine` module, and created eight VaultAuth resources in `tazlab-k8s` for per-namespace segregation.

Here I hit the first snag: JWT roles cannot use `bound_claims` on the `kubernetes.io/serviceaccount/namespace` claim because the JWT issued by Talos does not include this claim. The existing `vso-role-jwt` role already used the correct pattern with `bound_service_account_names`, but I hadn't noticed until reviewing the VSO log.

### Phase 2: The PKI Engine in Vault

Enabling the PKI engine was quick: mount `pki_root` with import of the First Intermediate CA, mount `pki_int` with CSR generation, signing via `pki_root/root/sign-intermediate`, and `set-signed` with the full chain (Tier 2 + Tier 1 + Tier 0). But two problems needed attention.

**Issue #17359 — The Phantom Default Issuer.** After `set-signed`, the `pki_int/issue/*` endpoint returned an empty `ca_chain`. Certificates were issued, but without the intermediate chain — and without the chain, Go clients reject the certificate with `tls: unknown certificate authority`. The cause is the multi-issuer engine introduced in Vault 1.11. I had to create a new issuer with the full chain and set it as default:

```bash
vault write pki_int/root/replace default=<new-issuer-id>
```

**Issue #16667 — The Phantom EC Parameters.** The offline CA's PEM bundle contained `-----BEGIN EC PARAMETERS-----` blocks that Go's ASN.1 parser does not tolerate. Removed manually with a regex.

Then I created the eight roles on `pki_int`: `internal-ingress` (no_store=false, allow_wildcard_certificates=true, TTL 168h), `cluster-local-mtls`, `database-server`, four `db-client-*` roles for each PostgreSQL user, and `cluster-replication` for intra-cluster replication. Each role was configured with the parameters that emerged from the researches: `signature_bits=256` for clients, `exclude_cn_from_sans` not supported (parameter ignored by Vault), `allow_bare_domains=true` for CN usernames.

### Phase 3: Let's Encrypt for Blog and Wiki

Blog and wiki were using the static TLS wildcard, obtained manually months ago with `lego` and Cloudflare DNS-01 — no automatic renewal. I created two Certificate resources in cert-manager: `blog-tazlab.net-tls` for four domains (blog.tazlab.net, tazlab.net, www, lab) and `wiki-tazlab.net-tls` for wiki.tazlab.net. Both with ClusterIssuer `letsencrypt-issuer` and HTTP01 solver. Active in seconds.

Then I updated the Ingresses. The change was simple, but the first push broke an Ingress's YAML syntax (missing `rules` section under `spec`). Lesson learned: always check the diff before pushing.

### Phase 4: The Wildcard Cutover

The critical moment: replacing the static wildcard with the VaultPKISecret. I created `vault-pki-tls` in `vso-system` with commonName `*.tazlab.net`, TTL 168h, and reflector annotations for auth and dex.

Then I migrated Ingresses one by one: first auth, verified, then dex. oauth2-proxy needed attention: it had to trust the Vault PKI certificate to talk to Dex over HTTPS. I added `--provider-ca-file=/etc/oauth2-proxy/pki/ca.crt` with a secret mount via `items:` (subPath projection is broken on Talos due to Kubernetes symlinks — "not a directory" error).

The last step: deleting the `wildcard-tls` ExternalSecret from `infrastructure/tls/`. One line removed, months of technical debt closed.

### Phase 5: mTLS on PostgreSQL — Where Everything Got Complex

The server-side TLS was simple: `customTLSSecret` on PGO with the VaultPKISecret `tazlab-db-server-tls`. But PGO ignores `ca.crt` from the Secret unless declared with explicit `items:`. And PostgreSQL's `ssl_ca_file` — the file PostgreSQL uses to verify client certificates — is **immutable** in PGO: it cannot be overridden via `patroni.dynamicConfiguration`. The only channel is the `ca.crt` bundle in the Secret.

The CA to put in that bundle couldn't be just the offline Root CA. It needed the full intermediate chain, because PGO generates the server cert from customTLSSecret but uses its own internal CA for replication. I built a combined CA bundle: PGO internal CA + Tier 2 + Tier 1 + Tier 0 = 4 certificates in a single `ca.crt` file in the Secret.

Then I added the pg_hba rule: `hostssl grafana grafana 0.0.0.0/0 cert`. And here I discovered that the database name must be exact: if the rule says `database=grafana` and the client connects to `database=postgres`, the rule doesn't match and PostgreSQL falls back to `md5` asking for a password. A subtlety that cost me 20 minutes.

**Grafana was the longest challenge of the project.** The `kube-prometheus-stack` chart doesn't propagate configurations the way you'd expect:

1. **`grafana.command` is not supported** — the Grafana sub-chart completely ignores the `command` field. I discovered this after trying to use it to copy certificates. Solution: `extraInitContainers`.
2. **`grafana.env` is filtered by `assertNoLeakedSecrets`** — the chart's security mechanism blocks variables containing sensitive-looking strings. Disabled with `assertNoLeakedSecrets: false`.
3. **`extraSecretMounts` works** — but requires `defaultMode: 384` (0600 in octal). Grafana's libpq library rejects the private key if permissions are too permissive.
4. **`extraVolumes` has a known bug** — sometimes mounts emptyDir instead of the expected resource. Workaround: an init container that copies from the Secret mount to an emptyDir, using `cp -HL` for symlinks.
5. **`containerSecurityContext.runAsUser`** must be 472 (Grafana's UID), not 1000 as I initially had — otherwise Grafana can't read the certificate files.

The final configuration that worked after 5 attempts and a dedicated research:

```yaml
grafana:
  database:
    type: sqlite3
  env:
    GF_DATABASE_TYPE: "postgres"
    GF_DATABASE_HOST: "tazlab-db-primary.tazlab-db.svc:5432"
    GF_DATABASE_NAME: "grafana"
    GF_DATABASE_USER: "grafana"
    GF_DATABASE_SSL_MODE: "require"
  extraSecretMounts:
    - name: grafana-db-certs
      secretName: db-client-grafana-tls
      mountPath: /tmp/db-certs-in
      defaultMode: 384
  extraInitContainers:
    - name: copy-db-certs
      image: alpine:3.21
      command:
        - sh -c "cp -rL /tmp/db-certs-in/* /etc/grafana/certs/ && chmod 600 /etc/grafana/certs/tls.key"
  containerSecurityContext:
    runAsUser: 472
    runAsGroup: 472
```

The result: Grafana 3/3, `"database":"ok"`, and `pg_stat_ssl` shows `usename=grafana, ssl=t`. Client certificate authentication working.

**pgAdmin and mnemosyne: postponed.** pgAdmin 4 doesn't support client certificates via environment variables — it requires a `servers.json` file. The Go mnemosyne app needs code changes to handle the full client certificate chain (Go requires leaf + intermediates in the `sslcert` file, unlike `psql` which only accepts the leaf). For now they continue with passwords.

## Technical Debts

- **DNS Tailscale post-reboot**: after node reboots, Vault's MagicDNS takes 1-5 minutes to resolve correctly. ESO's ClusterSecretStore reports it as an error, blocking Flux. Fixed by increasing the Flux timeout from 5 to 10 minutes. Doesn't happen on destroy+create.
- **mTLS for pgAdmin and mnemosyne**: documented, planned, not yet implemented. Requires `servers.json` for pgAdmin, Go code changes for mnemosyne.
- **TrustedRootConfigs not active**: the patch is persisted in Talos configuration, but takes effect only after the next reboot. On destroy+create it will be integrated into Terraform `config_patches`.

## Lessons Learned

### CRISP Design Paid Off

Every problem encountered during implementation was quickly solvable because the underlying architecture was solid. If I had started writing code without the research and review phase, I would have had to revise the architecture multiple times — instead I could focus on operational details.

### Research Is an Investment, Not a Cost

Each research saved me hours of trial and error. Without the research on PGO `ssl_ca_file`, I would have spent hours trying to override a parameter that PGO deliberately makes immutable. Without the Grafana research, I'd still be wondering why `grafana.command` is ignored.

### mTLS Is Not Standardized Across Apps

A client certificate is a file. The way each application loads it is not. `psql` picks it up from environment variables. Grafana from specific env vars (with names that change depending on which docs you read). pgAdmin from a JSON file. Go from a connection string. Each has different requirements for format (leaf only vs bundle), permissions (0600 required for libpq), and path.

### Overkill? Yes, Deliberately

A three-tier PKI for a two-node cluster is objectively excessive. But that was never the point. The point was to prove that a homelab can host the same architectures that run in enterprise datacenters. With the right tools, the right methodology, and the patience to do things properly.

## What's Next

The next step is a `destroy+create` cycle — start the cluster from scratch and verify that the entire PKI rebuilds without manual interventions. A true one-shot test. Then pgAdmin and mnemosyne on mTLS. Then, finally, the project that made all of this necessary: the **cross-site PostgreSQL database with automatic failover**, which I've unblocked with this PKI and which awaits me.

But that's another story.

---

*This article is part of a series on TazLab infrastructure management. Previous articles: [CRISP 2.0: Research Required, Verified Plan, Zero Assumptions]({{< ref "crisp-2-verified-research-methodology" >}}), [First Steps Toward Dynamic Secrets]({{< ref "first-steps-toward-dynamic-secrets" >}}), [The Research That Killed the Injector]({{< ref "man-in-the-loop-vso-deep-research" >}}). Code on [github.com/tazzo](https://github.com/tazzo).*
