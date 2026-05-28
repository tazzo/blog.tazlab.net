+++
title = "First Steps Toward Dynamic Secrets: From PKI Chaos to JWT Auth"
date = 2026-05-28T17:35:00+00:00
draft = false
description = "After migrating all static secrets from Infisical to Vault, it is time to begin the journey toward dynamic secrets. But preparing the ground proved far more complex than expected: a wrong Talos path collapsed the cluster, the Tailscale nameserver had a silent bug, and the bootstrap hid six circular dependencies."
tags = ["vault", "jwt", "kubernetes", "talos", "tailscale", "coredns", "crisp", "architecture", "secret-management"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# First Steps Toward Dynamic Secrets: From PKI Chaos to JWT Auth

If you have been following the TazLab cluster story so far, you know that the migration from Infisical to Vault was completed successfully in May 2026. Twenty-two ExternalSecrets migrated, zero Infisical references in production code, and a certified destroy/create cycle. Static secrets — API tokens, TLS certificates, OAuth credentials — all lived in Vault on Hetzner.

But the real goal was not replacing one external provider with another. The real goal was reaching **dynamic secrets**: credentials generated on the fly by Vault, with temporary leases, automatic rotation, and no hardcoded password in a Kubernetes Secret.

This article covers the first leg of that journey. What should have been a straightforward task — exposing the Kubernetes API server on the Tailnet and configuring JWT authentication — turned into a session that went through a PKI disaster, six bootstrap deadlocks, and a silent bug in the Tailscale nameserver. All before writing the first line of Vault Agent Injector configuration.

## The Architectural Problem

The Vault Agent Injector is a Kubernetes admission webhook that injects init containers and sidecars into Pods. These containers authenticate to Vault using the Pod's ServiceAccount JWT, obtain dynamic credentials, and mount them in a shared tmpfs. No Kubernetes Secret, no ExternalSecret, no ESO. Just the Pod and Vault communicating directly.

But for this to work, Vault must be able to validate the JWTs issued by the Kubernetes API server. To do that, Vault needs:

1. To reach the API server via HTTPS (from the Hetzner VM, through Tailscale)
2. To obtain the token signing public keys (the `/openid/v1/jwks` endpoint)
3. An issuer URL resolvable from the external VM (not `kubernetes.default.svc.cluster.local`)

The first step, then, was exposing the Kubernetes API server on the Tailnet via a Tailscale LoadBalancer, configuring the TLS certificate `certSANs` to include the MagicDNS name, and setting `service-account-issuer` to a URL reachable from Vault.

A seemingly linear task, which I approached with the CRISP methodology: project `10-vault-agent-injector-phase1`, Stage 1 (P0), tasks.md with 39 atomic tasks. The plan looked solid. Reality was different.

## Phase 1: The PKI Disaster — machine.certSANs ≠ cluster.apiServer.certSANs

The first mistake was also the most instructive. To add the API server's DNS name to its TLS certificate, I looked for how to configure `certSANs` in Talos. Using `talosctl patch mc`, I applied this patch:

```yaml
machine:
  certSANs:
    - lushycorp-k8s.magellanic-gondola.ts.net
```

Talos replied: "Applied configuration without a reboot". It seemed to work. I rebooted the control plane node to be safe, and the cluster died.

All Pods on the worker node lost connectivity to the API server. kube-proxy was throwing `Unauthorized` errors in rapid succession. kubelet could no longer communicate. The control plane rollout had regenerated the PKI through `trustd`, Talos's certificate manager, but the kubeconfigs on the worker nodes had not been updated. The result was an irreversible cluster deadlock.

### What I had done wrong

Talos has **two** distinct paths for `certSANs`, with completely different effects:

- **`machine.certSANs`**: Adds SANs to the **Talos node certificate** (port 50000, the Talos API daemon). Used to connect to the node via talosctl using a DNS name instead of an IP. Modifying this field triggers `trustd`, which regenerates the entire cluster PKI — node certificates, kubelet certificates, kube-proxy certificates — and distributes them to all nodes. If worker nodes are not rebooted together with the control plane, they receive stale certificates and are rejected by the API server.

- **`cluster.apiServer.certSANs`**: Adds SANs to the **Kubernetes API server TLS certificate** (port 6443). It does not trigger trustd, it does not regenerate the PKI. The API server reloads the certificate on the next restart.

The lesson is simple but costly: on Talos, the two paths are not interchangeable. Using `machine.certSANs` to modify the API server certificate is like changing your home address by editing a GPS URL — technically both are "addresses", but they have completely different effects.

The solution was equally clear: all Talos patches for the API server had to be **baked into the bootstrap**, not applied to a running cluster. I moved `certSANs`, `service-account-issuer`, `api-audiences`, and `service-account-jwks-uri` into the `config_patches` of the `proxmox-talos` Terraform module, so they would be applied during the initial cluster creation, completely avoiding the PKI regeneration problem.

## Phase 2: Six Bootstrap Deadlocks

After the PKI disaster, the strategy changed: destroy and recreate the cluster with the patches already included in the initial configuration. But with each create.sh attempt, a new block emerged. In the end I counted six.

### Deadlock 1: The Tailscale operator's OAuth

The Tailscale Operator needs an OAuth secret (clientId + clientSecret) to create proxy Pods on the tailnet. In the new Vault-native architecture, this secret is an ExternalSecret pulling from Vault. But Vault is only reachable via Tailscale DNS (`*.magellanic-gondola.ts.net`), which requires the Tailscale operator to function. The operator needs OAuth to start, OAuth is in Vault, Vault needs the operator for DNS. A perfect chicken-and-egg.

**Solution**: I removed the Vault dependency for bootstrap secrets. The Terraform engine layer now creates the OAuth secret directly from local operator files (`~/secrets/tailscale-operator-client-*`) using `kubernetes_secret_v1`, bypassing External Secrets Operator entirely.

### Deadlock 2: CoreDNS overwritten by Talos

Talos v1.12 uses Server-Side Apply to manage the CoreDNS ConfigMap. Any manual change or inlineManifest gets overwritten on the next reconcile. I had added a forward for the `ts.net` domain to the ConfigMap, but Talos would regularly erase it.

**Solution**: I set `cluster.coreDNS.disabled: true` in the Talos configuration and deployed a full user-managed CoreDNS (ServiceAccount, ClusterRole, ConfigMap, Deployment, Service with ClusterIP 10.96.0.10) directly from the Terraform engine layer.

### Deadlock 3: The ESO CRD was not ready

Terraform tried to create the `tazlab-secrets-vault` ClusterSecretStore before External Secrets Operator had finished installing and registering its CRDs. The error was "resource isn't valid for cluster, check the APIVersion and Kind fields".

**Solution**: `depends_on = [helm_release.external_secrets]`. A trivial fix, but one that took three attempts to identify.

### Deadlock 4: The GitHub token never arrived

Initially, the engine layer created an ExternalSecret for the GitHub token (needed by Flux to clone the repository), with a secretStoreRef pointing to Infisical. But Infisical was unreachable (DNS timeout). I tried switching to Vault, but Vault was unreachable (same problem as Deadlock 1).

**Solution**: same pattern as Deadlock 1 — create the GitHub token as a direct `kubernetes_secret_v1` from a local file, no ESO involved. Vault and Flux will take over later.

### Deadlock 5: CoreDNS would not start

To my great frustration, a syntax error in the Corefile prevented CoreDNS from starting. I had written:

```
health { lameduck 5s }
```

On a single line. This syntax is not supported by CoreDNS. The process crashed in a loop, the Deployment stayed in "Still creating..." for 5 minutes, and Terraform timed out.

**Solution**: the multiline version is the correct one:

```
health {
    lameduck 5s
}
```

### Deadlock 6: The file existed but was not deployed

The `secrets.yaml` file containing the ExternalSecret for Grafana's PostgreSQL credentials existed in the `infrastructure-monitoring` kustomization directory, but was not listed in the `resources:` section. So Flux never deployed it. Grafana remained in `CreateContainerConfigError` for no apparent reason.

**Solution**: added `secrets.yaml` to the kustomization's resources list.

## Phase 3: The Nameserver That Would Not Answer

With the bootstrap deadlocks behind me, the cluster was finally up and all 16 Flux Kustomizations were Ready. But the Vault ClusterSecretStore remained in `ValidationFailed`. The error message said "no such host" for `lushycorp-vault.magellanic-gondola.ts.net`.

CoreDNS was forwarding requests for the `ts.net` domain to the Tailscale nameserver (deployed by the DNSConfig CRD), but the nameserver was returning NXDOMAIN for every name, even those it was supposed to resolve.

### The Diagnosis

The nameserver logs were illuminating:

```
2026/05/28 20:21:39 ConfigMap update received
2026/05/28 20:21:39 configuration update detected, resetting records
2026/05/28 20:21:39 nameserver's configuration is empty, any in-memory records will be unset
2026/05/28 20:21:39 nameserver records were reset
```

The `dnsrecords` ConfigMap contained the correct records:

```json
{"version":"v1alpha1","ip4":{"lushycorp-vault.magellanic-gondola.ts.net":["10.244.1.31"]}}
```

But the nameserver kept saying "configuration is empty". Two distinct problems:

1. **File path**: The ConfigMap was mounted at `/config/records.json`, but the nameserver binary was looking for `/config/dnsrecords`. The directory watcher detected the change ("ConfigMap update received"), but when the binary tried to read its expected path, it found a nonexistent file and returned an empty configuration.

2. **JSON schema**: The Tailscale operator v1.96.5 writes the `v1alpha1` format with an `"ip4"` key. The `k8s-nameserver:unstable` image (bleeding-edge) had been refactored to support IPv6 and expects a different key (e.g., `"records"` or `"endpoints"`). Go's `json.Unmarshal` silently ignores unknown keys, so the parsing "succeeds" but produces an empty configuration.

### The Solution

Rather than chasing the bug in the nameserver, I changed strategy: instead of forwarding `ts.net` requests to the nameserver, I configured CoreDNS to rewrite MagicDNS names directly to the corresponding ClusterIPs of the Tailscale egress proxies.

The original CoreDNS block:
```
ts.net:53 {
    forward . 10.96.0.101
}
```

Became:
```
magellanic-gondola.ts.net:53 {
    rewrite name regex ([a-zA-Z0-9-]+)\.magellanic-gondola\.ts\.net {1}.tailscale.svc.cluster.local
    forward . 10.96.0.10
}
```

This rewrite rule transforms `lushycorp-vault.magellanic-gondola.ts.net` into `lushycorp-vault.tailscale.svc.cluster.local`, which CoreDNS resolves natively through the kubernetes plugin. No nameserver, no ConfigMap, no version-skew.

## Phase 4: JWT Auth on Vault

With DNS working and the ClusterSecretStore Valid, I could configure JWT authentication on Vault. But here another problem emerged: the JWKS endpoint URL.

```bash
vault write auth/jwt/config \
    jwks_url="https://lushycorp-k8s.magellanic-gondola.ts.net:6443/openid/v1/jwks" \
    bound_issuer="https://lushycorp-k8s.magellanic-gondola.ts.net:6443"
```

Vault tried to validate the URL by contacting the JWKS endpoint, but the connection failed. The reason? Every destroy+create cycle produces a new Tailscale device with a `-N` suffix (lushycorp-k8s-1, -2, -3...), but the canonical MagicDNS name (`lushycorp-k8s.magellanic-gondola.ts.net`) kept pointing to the oldest offline device.

### Workaround: Static Key

I extracted the RSA public key from the JWKS endpoint using `kubectl get --raw /openid/v1/jwks`, converted it to PEM format, and configured it directly on Vault. But why was the JWKS endpoint unreachable?

The root cause was **ghost devices on Tailscale**. Each destroy+create cycle produces a new proxy device on the tailnet with a `-N` suffix. The canonical MagicDNS name kept resolving to the oldest offline device.

This was a problem we had not anticipated. The Tailscale auth keys used for the local operator already had the `"ephemeral": true` flag, which automatically cleans up devices when they disconnect. But the proxy Pods created by the **Tailscale Operator** use a separate OAuth client (`k8s_operator`), and the devices created by the OAuth client **are not ephemeral**. When the cluster is destroyed, the proxy Pods disappear but the devices remain registered on the tailnet as "offline". On recreate, the operator creates new devices with `-N` suffixes because the canonical name is already taken.

```
100.79.55.31    lushycorp-k8s     tagged-devices   linux   offline  # cycle 1
100.108.49.94   lushycorp-k8s-2   tagged-devices   linux   offline  # cycle 2
100.113.43.5    lushycorp-k8s-5   tagged-devices   linux   active   # current cycle
```

The solution was to add a cleanup step in `destroy.sh` that calls the Tailscale API to remove devices with the `tag:k8s` tag before destroying the VMs. But in the meantime, I needed a workaround.

```bash
vault write auth/jwt/config \
    jwt_validation_pubkeys=@/tmp/jwks.pem \
    bound_issuer="https://lushycorp-k8s.magellanic-gondola.ts.net:6443"
```

I then created the role for Grafana's ServiceAccount:

```bash
vault write auth/jwt/role/grafana-consumer \
    role_type="jwt" \
    bound_audiences="https://lushycorp-vault.magellanic-gondola.ts.net:8200" \
    bound_subject="system:serviceaccount:monitoring:grafana-sa" \
    user_claim="sub" \
    token_ttl="24h"
```

The static key solution is not ideal — when the API server rotates its signing keys, this configuration will become obsolete. But it is sufficient to proceed with the next phases, while we resolve the ghost device problem on Tailscale.

## Conclusions and Lessons Learned

At the end of the day, the cluster was operational: 16/16 Flux Kustomizations Ready, 17/17 ExternalSecrets SecretSynced, Vault Store Valid, JWT auth configured. But the path to get there taught far more than I had anticipated.

### Generalizable Lessons

1. **On Talos, `machine.certSANs` and `cluster.apiServer.certSANs` are two different worlds**: modifying them on a running cluster can cause an irreversible deadlock. API server patches must be applied at bootstrap, not after.

2. **Bootstrap deadlocks hide in the details**: every component that depends on another that depends on the first creates a chicken-and-egg. The solution is to break the circle with bootstrap secrets created directly from local files, bypassing the ESO/Vault/DNS chain.

3. **`k8s-nameserver:unstable` is broken for the stable operator**: the version-skew between the bleeding-edge image and the operator v1.96.5 produces a silent failure. The CoreDNS rewrite solution is more elegant and removes a dependency.

4. **Version-skew is the most insidious problem**: unlike a syntax error or a misconfiguration, a version mismatch produces silent failures. The JSON parses without errors but the data is discarded. The ConfigMap is present but the content is ignored. The logs say everything is fine but the answer is NXDOMAIN.

### Next Steps

With JWT authentication working, the road toward dynamic secrets is clear. The next steps will be:

- Configuring the Vault database engine for PostgreSQL (dynamic credentials instead of PGO sync)
- Deploying the Vault Agent Injector as a mutating admission webhook
- Migrating Grafana to dynamic credentials injected via sidecar
- Removing `sync_runtime_secrets` and secrets.yaml from the monitoring kustomization

But that is a story for another day.
