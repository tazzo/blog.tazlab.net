+++
title = "After the PKI: Migrating mnemosyne to mTLS"
date = 2026-07-08T21:00:00+02:00
draft = false
description = "After the enterprise PKI project with Vault and Grafana's mTLS migration, it was time to close the loop with the remaining password-authenticated applications. Mnemosyne, the cluster's only custom Go app, was the first — and the simplest."
tags = ["PKI", "Vault", "Kubernetes", "mTLS", "PostgreSQL", "Go", "CRISP", "TazLab"]
categories = ["Infrastructure", "DevOps"]
author = "Taz"
+++

## The Loop to Close

In the [previous post]({{< ref "pki-vault-followup-root-ca-mtls-disaster-recovery" >}}) I covered the PKI project certification: five destroy+create cycles, the Root CA in VSO templates, the fixed Grafana HelmRelease, and the first working mTLS case with Grafana connecting to PostgreSQL via client certificate.

But Grafana was a special case. It uses a web framework (Go), sure, but the configuration is all Helm YAML — no code to write. The real challenge was the cluster's only custom Go application: **mnemosyne-mcp-server**, an MCP server for semantic memory (vector embeddings with pgvector and Gemini).

Its `db.go` hardcoded `sslmode=disable` and required `DB_PASS` as mandatory. Until yesterday, it was the last client on password auth.

## The PKI Project Had Already Done Everything

One of the advantages of building the PKI project with the CRISP methodology — mandatory research, verified design, structured reviews — is that by the time you reach the client application implementation, the road is already paved.

The `VaultPKISecret` for mnemosyne (`db-client-mnemosyne-tls`) already existed, with a 24h TTL and VSO templates generating `tls.crt`, `tls.key`, and `ca.crt` (with the full three-tier chain: Tier 2 + Tier 1 + Root CA). The Vault role `db-client-mnemosyne` was already configured on `pki_int`. PostgreSQL (PGO v5.7.2) already had `pg_hba` rules to accept client certificate connections.

Only the app was missing: it needed to learn how to use those certificates.

## The Go Refactor: Simple, with One Subtle Point

The code change was straightforward. I added an `SSLConfig` to `db.go`:

```go
type SSLConfig struct {
    SSLMode     string
    SSLCert     string
    SSLKey      string
    SSLRootCert string
}

func New(host, port, user, password, dbname string, ssl *SSLConfig) (*DB, error) {
```

The `nil` pointer maintains backward compatibility: when `ssl` is `nil`, the connection uses `sslmode=disable` as before. When an `SSLConfig` with `SSLMode != ""` is provided, it builds the connection string with the TLS parameters.

The env side (`main.go`) was equally simple: read `DB_SSLMODE`, `DB_SSLCERT`, `DB_SSLKEY`, `DB_SSLROOTCERT` from environment variables and make them optional. The real novelty was making `DB_PASS` **non-mandatory** when using an SSL mode that requires certificate authentication:

```go
if dbPass == "" && dbSslMode != "require" && dbSslMode != "verify-ca" && dbSslMode != "verify-full" {
    missing = append(missing, "DB_PASS")
}
```

This small change was a sensitive point during the reviews: it's easy to fall into the trap of only handling `verify-full` (the most secure mode) and forgetting that `require` and `verify-ca` exist — less secure but useful in specific contexts, such as debugging or integrating with services that don't support hostname verification. Three reviews on this project circled around this subtlety, and each time the condition was widened until it covered all modes.

### defaultMode: 384

The Kubernetes deployment mounts the `db-client-mnemosyne-tls` secret into `/etc/secrets/tls` with `defaultMode: 384` — which corresponds to `0600` in octal. The `lib/pq` library (like all PostgreSQL libraries) rejects the private key if it's readable by others. It's a detail I already encountered with Grafana, and it's worth keeping in mind: **overly permissive permissions on `tls.key` are the most common mistake in mTLS configurations**.

## Automatic Rotation: A Test Worth Doing

The mnemosyne client certificate has a 24h TTL. VSO (Vault Secrets Operator) renews it approximately every 20 hours (TTL - 4h `expiryOffset`). The `VaultPKISecret` has `rolloutRestartTargets` pointing to the mnemosyne deployment: when the secret changes, the deployment is reconciled and the pod restarts with the new certificate.

To verify the mechanism worked, I forced a rotation by deleting the Kubernetes secret. VSO regenerated it in about 5 seconds, and the pod was replaced automatically (new ReplicaSet, not a simple restart). The certificate serial changed — and the PostgreSQL connection remained active. `pg_stat_ssl` showed `ssl=t, client_dn=/CN=mnemosyne` both before and after.

I also tested backward compatibility: I temporarily removed the SSL variables from the deployment, leaving only `DB_PASS`. The pod reconnected via password. `pg_stat_ssl` showed `ssl=f, client_dn=null`. It worked. Then I restored the SSL variables and permanently removed `DB_PASS` and the `md5` rules from `pg_hba`.

## Problems Encountered

The project was surprisingly clean — especially compared to the five PKI cycles. There were only two real issues:

### YAML Indent

The dumbest one. I had added `rolloutRestartTargets` to the `VaultPKISecret` before the `transformation` block. YAML has precise indentation rules: after a mapping key that contains a sequence (the restart targets), you can't go back to the same indentation with a new key. Flux's parser reported it with a cryptic `did not find expected '-' indicator`. I moved it after the `transformation` block — at the same indentation as `destination` — and it worked.

### Slow Flux Reconciliation

The kustomization containing mnemosyne's resources (`infrastructure-instances`) is at the bottom of a four-level dependency chain: from `infrastructure-operators-vso` up to `infrastructure-configs` and down to `infrastructure-instances`. Each level must be `Ready=True` before the next one can execute. After the Git push, I had to manually trigger reconciliations to speed up the process — otherwise it would take several minutes for the full propagation. Not a bug, but a standard Flux behavior worth knowing when working with deep dependency chains.

## pg_stat_ssl: The Proof

The final verification was the most satisfying:

```
 usename  | ssl |   client_dn
----------+-----+---------------
 mnemosyne | t   | /CN=mnemosyne
```

`ssl=t` means the connection is encrypted with TLS. `client_dn=/CN=mnemosyne` means PostgreSQL verified the client certificate, extracted the Common Name, and accepted it. No password. No `DB_PASS` in the configuration. Just the certificate signed by Vault PKI.

## What's Left

With mnemosyne migrated, the PostgreSQL app landscape looks like this:

| App | Authentication | Status |
|---|---|---|
| Grafana | Client certificate (mTLS) | ✅ From PKI project |
| **mnemosyne** | **Client certificate (mTLS)** | **✅ Done now** |
| pgAdmin | Password | ⏳ Requires servers.json |
| Vault DB engine | Password (scram-sha-256) | ⏳ Requires Vault Agent |
| TazLab CLI (tazpod) | Local password | 🔒 Not in cluster |

The next two migrations (pgAdmin and Vault DB engine) are already planned as separate CRISP projects. But they have a different complexity level: pgAdmin requires managing a preconfigured `servers.json` file with certificate paths; the Vault DB engine requires a Vault Agent sidecar on the Hetzner VM, an enterprise HashiCorp pattern I've never implemented before.

For now, though, the PKI project loop — started with the goal of eliminating static passwords from all database connections — has gained another notch. Two apps out of five. Three still to go. But the pattern is now well-established.

---

*This article is part of a series on TazLab infrastructure management. Previous posts: [Vault PKI Follow-Up]({{< ref "pki-vault-followup-root-ca-mtls-disaster-recovery" >}}), [PKI Vault on TazLab]({{< ref "pki-vault-tazlab-enterprise-homelab" >}}). Code on [github.com/tazzo](https://github.com/tazzo).*
