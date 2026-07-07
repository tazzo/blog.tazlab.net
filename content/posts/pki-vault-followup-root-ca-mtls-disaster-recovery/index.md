+++
title = "Vault PKI Follow-Up: Root CA, mTLS, and Disaster Recovery Certification"
date = 2026-07-07T21:00:00+02:00
draft = false
description = "The final chapter of the PKI project: adding the Root CA to the trust chain, completing Grafana mTLS, and certifying everything with five destroy+create cycles to a one-shot perfect run in 12 minutes."
tags = ["PKI", "Vault", "Kubernetes", "Flux", "GitOps", "Disaster Recovery", "Grafana", "mTLS"]
categories = ["Infrastructure", "DevOps"]
author = "Taz"
+++

## The Debt of the Final Phases

In the [previous post]({{< ref "pki-vault-tazlab-enterprise-homelab" >}}) I described building a three-tier enterprise PKI for TazLab: offline Root CA, Intermediate CA in Vault, certificates for ingress, database, and clients. The implementation completed phases zero through five: offline CA, Terraform, PKI engine, Let's Encrypt, wildcard TLS, and PostgreSQL mTLS.

But some things remained unfinished — items I could not test without rebooting the Talos nodes, or better yet, without a full cluster destroy+create cycle. In the CRISP project I had grouped them under "Phase 4bis and 4ter": adding the Root CA to the VSO templates, fixing the Grafana HelmRelease, configuring Reflector for certificate propagation, and a collection of technical debt accumulated in previous iterations.

It was time to close the loop.

## The Destroy+Create Ritual

After every significant architectural change to the cluster, I always follow the same procedure: destroy everything and rebuild from scratch. This is not an optional test — it is certification that the cluster is ready for a real disaster recovery. I have done this dozens of times, starting from the earliest consolidation projects. Lately, as the infrastructure has grown more complex, the recreation cycle has started hiding more pitfalls — and I have begun writing articles about this phase as well.

I had already covered this after [consolidating bootstrap secrets onto Vault]({{< ref "bootstrap-secret-infrastructure-consolidation" >}}) and after [eliminating Ansible from the rebirth cycle]({{< ref "eliminating-ansible-from-cluster-rebirth" >}}). The goal was always the same: **a single command, zero manual intervention, a fully operational cluster**.

The point is not testing a feature — it is verifying that the entire stack, from Terraform to Flux, from TLS certificates to Vault secrets, operates deterministically. If something breaks during bootstrap, it would also break during an actual disaster. And I want to know that beforehand.

The `destroy.sh` does not perform a polite `terraform destroy` — it carries out a **nuclear disintegration**: it deletes the Talos VMs via the Proxmox API, cleans up Tailscale DNS records, removes ghost devices, and wipes every trace of state. Then `create.sh` rebuilds everything: VMs, Talos, networking, storage, Flux, operators, applications. In about twelve minutes.

For the PKI project, the destroy+create cycle was also the only way to verify the remaining items. Let us look at what they were.

## What Was Missing

After the initial PKI implementation, the cluster was working. Grafana connected to the database, certificates were issued, Vault managed the entire lifecycle. But there were cracks.

### The Missing Root CA

The first problem was subtle but fundamental. The VSO (Vault Secrets Operator) templates for `VaultPKISecret` were generating the `ca.crt` using only Vault's `ca_chain` — which contains Tier 2 and Tier 1, but **not the offline Root CA** (Tier 0). Vault does not include the root in the chain because technically it should not be needed: the client is expected to trust the root as a pre-distributed trust anchor.

But Go, the language Grafana is written in, is stricter. Its TLS stack requires the trust anchor to be a self-signed certificate, not an intermediate. The offline Root CA is self-signed; Tier 1 is not. Without the Root in `ca.crt`, Go refuses the connection with `tls: unknown certificate authority`.

The fix was to append the Root CA certificate in plaintext (from the secrets vault) to the VSO template of all six `VaultPKISecret` resources. Now every `ca.crt` contains the full chain: Tier 2, Tier 1, Root. Three certificates, not two.

### The Broken Grafana HelmRelease

At the end of the PKI project, Grafana was running with `ssl_mode=disable` and a hardcoded password in `grafana.ini`. We had left it that way because mTLS (`ssl_mode=require`) seemed to require a node reboot: attempts to enable it caused "connection reset by peer".

When I started the test cycle, I discovered the implementation was more fragile than expected. The Grafana HelmRelease, part of the `kube-prometheus-stack`, had a serious problem: the `chartRef` pointed to a HelmChart named `prometheus-community`, but the actual chart was called `monitoring-kube-prometheus-stack`. Flux could not reconcile the release — the only reason Grafana was running was that the deployment had been created in a previous install and had never been updated.

Once I fixed the reference (from `chartRef` to `chart.spec` with the exact name and version), a second problem emerged: the init container that copies TLS certificates had its command written on a single line without separators between `cp`, `chmod`, and `ls`. `cp` interpreted everything as source files — and the init crashed with "Cross-device link".

I fixed both, set `ssl_mode=require`, and removed the password. The result: Grafana connects to the database with pure mTLS, no Kyber fragmentation or anything else. The original "connection reset" was not caused by the Proxmox checksum bug — it was the broken HelmRelease preventing a clean reconciliation.

A note on GODEBUG: I added `GODEBUG=tlskyber=0` as an environment variable to disable the Kyber post-quantum algorithm in Go 1.23+, keeping the TLS ClientHello below the VXLAN fragmentation threshold (MTU 1450). The correct format in the Grafana sub-chart of `kube-prometheus-stack` is a YAML dictionary under `grafana.env`, not a list.

### Reflector and Certificate Propagation

The wildcard certificate `*.tazlab.net` is generated by VSO in the `vso-system` namespace. But `oauth2-proxy` (in `auth`) and `dex` (in `dex`) need it for their TLS ingresses. In the previous cluster I used Reflector to copy the secret between namespaces.

The issue: Reflector v10.x **does not use CRDs**. It operates through annotations on the Secrets themselves. To enable automatic propagation, you simply add these annotations to the `VaultPKISecret`:

```yaml
  destination:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "auth,dex"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "auth,dex"
```

VSO generates the secret with these annotations, Reflector detects it and automatically copies it to `auth` and `dex`. No scripts, no `kubectl`, no manual intervention.

## The Five Cycles

With all fixes ready in the Git manifests, I launched the first destroy+create cycle. And that is where the real hunt began.

### Cycle 1 — The Rude Awakening

The first attempt was an instructive disaster. Six bugs at once:

1. `set -u` in bash: the `resolve()` function used `${!var_name}` without protection for undefined variables
2. The Vault JWT auto-import used the wrong path (`auth/jwt` instead of `jwt`)
3. The `config_patches` for the Talos EthernetConfig had the wrong format for provider v0.10.1
4. VaultAuth and VaultPKISecret CRs were in the same kustomization as the VSO HelmRelease — Flux ran dry-run before the CRDs existed
5. The YAML indentation of the Root CA certificate was wrong (the base64 lines and `END CERTIFICATE` lacked indentation)
6. The `vault-pki-tls` secret was not propagated to the `auth` and `dex` namespaces

The most interesting was number 4. Flux performs a **Server-Side Apply dry-run** on every resource in a Kustomization before applying any of them. If the VaultAuth CRD does not yet exist (because the VSO operator has not started), validation fails. The solution was to move the CRs into a separate Kustomization (`vso-secrets`) with `dependsOn` on the operator.

### Cycle 2 — One Bug

After fixing all six, the second cycle found just one issue: Reflector. I had created a `Reflector` CR thinking the operator supported it, but v10.x only works through annotations. Removed the CR, added the annotations to the VaultPKISecret. Done.

### Cycle 3 — Circular Dependency

This revealed an interesting architectural bug. The VSO operator creates ServiceAccounts in the `monitoring` namespace. But the `monitoring` namespace was being created by the `infrastructure-monitoring` Kustomization, which I had made depend on VSO (because of the dry-run issue). Result: VSO could not create the SA because the namespace did not exist, and the namespace was not being created because the Kustomization was waiting for VSO.

The solution: move the `monitoring` namespace creation into the `namespaces` Kustomization, which runs before both.

### Cycle 4 — Stale DNS

The fourth cycle uncovered a problem that had been lurking for a while. Tailscale DNS, after a destroy, left stale records behind. The `tazlab-db` service received a `-1` suffix (becoming `tazlab-db-1.magellanic-gondola.ts.net`) because the original record was not cleaned up. Vault, configured to connect to `tazlab-db`, could no longer resolve the hostname.

I added a DNS verification phase to `destroy.sh` — **Phase 0c** — that explicitly checks whether the records have been cleaned and warns if anything remains. If the records are dirty, it is better to know before launching the create.

### Cycle 5 — One-Shot

The fifth attempt started with clean DNS records and all previous fixes already in the manifests. The approximate timeline:

```
Layer Terraform...............~3 min
Flux convergence.............~5 min
DB restore + pod startup....~4 min
────────────────────────────
TOTAL operational cluster...~12 min
```

The Terraform layer timings are precise (secrets 4s, vault_jwt 3s, platform 85s, etc.), but after create.sh exits the database still has to restore from S3, and the last pods (Grafana, Prometheus, alertmanager) only start afterward. The cluster is fully operational in about 12-13 minutes from the create launch.

Twenty-one Flux Kustomizations out of twenty-one True. Seventy-five pods, zero errors, zero CrashLoopBackOff. Auth working via Reflector. Grafana connected to the database via mTLS. Wildcard certificates propagated. VaultPKISecrets in automatic rotation. **No manual intervention.**

## What I Learned

### Flux Dry-Run Does Not Forgive

Flux validates **every** resource in a Kustomization before applying **any** of them. This means you cannot place a CR and its operator in the same Kustomization. Separating into layers with `dependsOn` (CRD → Operators → Configurations) is not optional — it is the only way to achieve deterministic bootstrapping.

### DNS Is the Achilles Heel

In an architecture that depends on Tailscale for connectivity between Vault (Hetzner) and the cluster (Proxmox), stale DNS records after a destroy become a serious problem. The fix is not complicated — just verify and clean — but if you do not do it, the following create starts with wrong names and nothing works. Phase 0c in `destroy.sh` now guarantees this will not happen again.

### Annotations, Not CRDs

Reflector v10 dropped CRDs in favor of annotations. I discovered this after spending hours trying to make a CR work that would never be recognized. Real research (on GitHub and forums) remains irreplaceable.

### mTLS Works, No Shortcuts

At the end of the fifth cycle, Grafana was talking to PostgreSQL in pure mTLS. `ssl_mode=require`, client certificate, authentication via `pg_hba cert`. No password. No workaround. The client certificate rotates every 24 hours via VSO, the server certificate every 30 days. The Root CA in the chain ensures Go can verify the entire trust chain.

## Next Stop

The PKI project is officially closed. The next step is what all this infrastructure was built for: the **cross-site PostgreSQL failover** between Proxmox and Hetzner, using PGO standby clusters and S3 backup via pgBackRest.

But that is a story for another time.

---
*This article is part of a series on TazLab infrastructure management. Previous installments: [PKI Vault on TazLab]({{< ref "pki-vault-tazlab-enterprise-homelab" >}}), [Cluster Consolidation and Reducing Bootstrap Tokens]({{< ref "bootstrap-secret-infrastructure-consolidation" >}}), [Eliminating Ansible from the Cluster Rebirth Cycle]({{< ref "eliminating-ansible-from-cluster-rebirth" >}}). Code at [github.com/tazzo](https://github.com/tazzo).*
