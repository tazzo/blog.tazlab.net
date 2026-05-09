+++
title = "When the Plan Isn't Enough: Deploying the Tailscale Operator on Talos"
date = 2026-05-08T20:00:00+02:00
draft = false
tags = ["Kubernetes", "Talos OS", "Flux", "Tailscale", "GitOps", "DNS", "CRISP", "Design Review", "Home Lab"]
description = "Deploying the Tailscale Kubernetes Operator on a Talos cluster looked like a straightforward CRISP project. After eight destroy-create cycles, three DNS redesigns, and an Infisical API discovery, here's what I learned."
author = "Tazzo"
+++

## The Goal: DNS for Vault

The context is straightforward. The TazLab cluster runs a HashiCorp Vault instance on a Hetzner VM, connected to the tailnet via Tailscale. The next step is integrating Vault as a secret backend for the cluster — a ClusterSecretStore for External Secrets Operator pointing to `lushycorp-vault.magellanic-gondola.ts.net:8200`.

The problem: cluster pods can't resolve MagicDNS names. The Talos nodes are on the tailnet (thanks to the Tailscale System Extension), but pods only have access to CoreDNS, which is a Deployment without `hostNetwork`. Tailscale's local resolver (`100.100.100.100`) isn't reachable from pods.

The designed solution: deploy the **Tailscale Kubernetes Operator** and use its `DNSConfig` CRD to create a DNS nameserver with tailnet access, then configure CoreDNS to forward `magellanic-gondola.ts.net` to that nameserver. A linear plan, well encapsulated in the CRISP project `10-operator-dns-resolution`.

At least, that's how it seemed.

## The First Mistake: DNSConfig Doesn't Resolve Arbitrary Nodes

After hours spent designing the three-layer Flux DAG, writing tasks, and reviewing the design, deployment time arrives. The Operator starts without issues — namespace, ExternalSecret, HelmRelease, everything in order. The `DNSConfig` CRD is created, the nameserver pod starts.

But DNS tests fail. `kubectl exec` from any pod — **NXDOMAIN**. The nameserver doesn't resolve.

The problem? **The DNSConfig CRD only resolves hostnames of Operator-managed proxies.** Egress proxies, Ingress resources with `tailscale.com/experimental-forward-cluster-traffic-via-ingress` — these are automatically registered in the nameserver. A regular tailnet node like `lushycorp-vault` is not resolved.

The CRD documentation is clear, but deceptively so: it says "DNSConfig makes a subset of Tailscale MagicDNS names resolvable." That "subset" is proxies, not nodes. I hadn't noticed this limitation during the design phase because the project README vaguely mentioned "MagicDNS resolution" without specifying I meant arbitrary tailnet nodes. A classic abstraction mistake: I assumed the solution was more general than it actually is.

## The Tailscale ACL Trap

Another roadblock during implementation was Tailscale ACL management. The design specified creating a `tag:tazlab-k8s` group that included both the existing tag and the new `tag:k8s-operator`, so that the existing ACL rule `tag:tazlab-k8s → tag:vault-api:8200` would automatically cover the Operator.

The problem: **Tailscale doesn't allow tags inside groups.** Groups (`group:`) only accept user email addresses, not machine tags. It's a documented limitation of the ACL syntax. The rule I had designed — `"groups": { "group:tazlab-k8s": ["tag:tazlab-k8s", "tag:k8s-operator"] }` — was rejected by the Tailscale validator with a cryptic error.

The fix was much simpler: add a dedicated ACL rule for `tag:k8s-operator → tag:vault-api:8200`. Two rules instead of one. A few lines, zero magic.

## Two Paths, Two Results

At this point I had four options:

1. **Use the raw tailnet IP** — `100.82.13.87:8200` instead of the DNS name. Works for TCP, but Vault's TLS certificate is issued for the hostname, not the IP. I'd need to add the IP to the certificate's SAN or bypass TLS verification. Both are fragile solutions.
2. **Create a Connector CR** — The Connector creates a Tailscale device managed by the Operator, but it doesn't proxy an existing node's hostname. It's a new device, not a proxy for an existing one.
3. **hostNetwork DNS relay** — A DaemonSet running on the host network, where Tailscale should be accessible (or so I thought).
4. **Modify the CoreDNS deployment** to run on the host network. Invasive and touches Talos configuration.

I chose option three: a CoreDNS DaemonSet with `hostNetwork: true`, on an alternate port (5353 — port 53 is already in use by Talos's system CoreDNS). The relay was supposed to forward queries to `100.100.100.100`, Tailscale's MagicDNS resolver.

Except **even the hostNetwork relay can't reach `100.100.100.100`**. The Talos System Extension for Tailscale doesn't expose the virtual resolver to the host — `tailscaled` handles DNS queries internally. I had to fall back to a static mapping via CoreDNS's `hosts` plugin: `lushycorp-vault.magellanic-gondola.ts.net → 100.82.13.87`.

It's not elegant. It's a working workaround. And it leaves obvious technical debt: if Vault's tailnet IP changes, the mapping needs updating.

## The Second Mistake: The Ignored InlineManifest

Talos provides an `inlineManifest` mechanism to inject Kubernetes resources directly into the machine config. The project uses this to create the `coredns` ConfigMap in `kube-system` with a custom Corefile that blocks IPv6 queries and configures forwarding.

The MagicDNS modification: add a server block for `magellanic-gondola.ts.net` forwarding to the relay. I update the `proxmox-talos` Terraform module, run `terragrunt apply`, the config is applied. But the running Corefile remains the default.

**Why?** Talos has its own controller that manages the CoreDNS ConfigMap. The inlineManifest is applied — the `coredns` ConfigMap is created — but Talos's controller immediately overwrites it with its internal template. An ownership conflict I hadn't anticipated.

The practical fix: patch the `kube-system/coredns` ConfigMap after every cluster create, via the `create.sh` script. It's not the enterprise path — the ConfigMap should be declarative, not patched by a shell script — but it's the only thing that worked.

## The EU Infisical Endpoint Discovery

During the ExternalSecret deployment for the Operator's OAuth credentials, I found the Secret empty. The keys `TAILSCALE_OPERATOR_CLIENT_ID` and `TAILSCALE_OPERATOR_CLIENT_SECRET` weren't arriving from Infisical. The ExternalSecret was created (ESO reported `SecretSynced`), but the values were empty strings.

The problem was a **much** more subtle configuration error than a typo. Our `setup.sh` had always been configured to push secrets to the `app.infisical.com` endpoint. But the TazLab Infisical workspace is on the **EU region**, which uses a different domain: `eu.infisical.com`. For weeks, every attempt to push secrets had failed with a 401 that I interpreted as "expired credentials," when the real issue was "wrong endpoint."

Once I corrected the endpoint, authentication worked, the keys arrived, and the ExternalSecret started populating the correct values. The most interesting part: the **ClusterSecretStore** ESO configuration was already correct — `hostAPI: https://eu.infisical.com` — but the setup script wasn't. The mismatch had gone unnoticed because the credentials for existing secrets (GITHUB_TOKEN, GEMINI_API_KEY, etc.) had been created manually.

## The ghcr.io Anonymous Rate Limit

A problem completely unrelated to the design that blocked everything for hours: ghcr.io's anonymous rate limit.

After a destroy+create, Talos nodes are fresh with no cached images. When `flux_bootstrap_git` installs the Flux controllers, it pulls images from ghcr.io. These are subject to the anonymous rate limit of 100 pulls per 6 hours per IP.

The first controllers (source-controller, kustomize-controller) pull without issues. But the helm-controller is last. By the time it tries to pull, the anonymous quota is exhausted. The pod stays in `ContainerCreating` for minutes, then times out, the Flux DAG stalls, and the entire bootstrap halts.

The fix: create a Docker registry secret with the GitHub token (`x-access-token`) and patch it onto the relevant ServiceAccounts. Authenticated pulls have no rate limit. I had to extend `create.sh` to create this secret in 6 strategic namespaces as soon as the cluster became operational — before the controllers started pulling.

## The DAG We Discovered Was Too Long

The original CRISP project had a 2-layer DAG:
1. **Layer 1**: namespace, ExternalSecret, HelmRepository
2. **Layer 2**: HelmRelease, DNSConfig, Service, ConfigMap

The problem: the HelmRelease installs CRDs, but the DNSConfig is applied in the same Kustomization before the CRDs are ready. Flux retry resolves it (retries after a few seconds), but this violates the "zero transient errors" goal we had set for ourselves. The review highlighted that placing a Custom Resource in the same Kustomization as its operator is a classic design mistake — and we had done it anyway.

The fix was a 3-layer DAG, where each Kustomization has a single responsibility:
1. **Layer 1** (`infrastructure-tailscale`): namespace + ESO credentials + HelmRepository — DAG root, starts in parallel with other roots
2. **Layer 2** (`infrastructure-operators-tailscale`): pure HelmRelease — installs CRDs and starts the Operator, depends on Layer 1
3. **Layer 3** (`infrastructure-tailscale-dns`): DNSConfig + Service + ConfigMap — applied when Layer 2 completes

Each layer is guaranteed by the previous one via `dependsOn` + `wait: true`. Zero transients. But the DAG is longer to explain and maintain.

## An Entire Session for a Bootstrap Fix

Once the code was complete, I did what I always do: destroy and recreate the cluster to verify everything works one-shot.

The first attempt worked — after 22 minutes. Then I destroyed and recreated. 9 minutes. Then again. Each time I destroyed and recreated the cluster, something different happened: ghcr.io rate limits, Corefile not being applied, storage waiting for gitops unnecessarily.

After **8 destroy-create cycles**, I had fixed all the issues:

- **ghcr.io pull secret** created after the engine layer in 6 namespaces
- **Corefile patched** via `kubectl create configmap` in the create script
- **Storage parallelized** with networking+gitops instead of sequential
- **Infisical endpoint** corrected from `app.infisical.com` to `eu.infisical.com`
- **Kubernetes_manifest** removed from the Terraform module (conflict with Terragrunt)
- **Every change** committed to the project's feat branch

The last cycle went smoothly: 9 minutes, zero manual interventions. The cluster was born with the Operator deployed, DNS working, blog online. But it took 8 attempts to get there.

## The Leftover Debt

The cluster works. Vault is reachable via DNS. But I left technical debt that needs addressing soon:

1. **Static DNS relay mapping** — `lushycorp-vault → 100.82.13.87` is hardcoded. If Vault's tailnet IP changes, DNS breaks. The ideal solution would be dynamic forwarding to `100.100.100.100`, but it's not reachable from Talos nodes.

2. **CoreDNS patched in create.sh** — The real Corefile is managed neither by Terraform nor by GitOps. It's a shell script doing `kubectl apply`. A declarative way to configure CoreDNS on Talos without it being overwritten is needed.

3. **DNSConfig CR bloat** — The `dnsconfig.yaml` CRD is still deployed but does nothing useful. It doesn't resolve arbitrary nodes. Should be removed.

4. **ghcr.io pull secret** — Works but is a shell script. Should be a permanent mechanism, inline in the bootstrap or a mutating webhook.

5. **Auth race (TD-026)** — `oauth2-proxy` starts before Dex and crash-loops until Dex is ready. An init container polling the OIDC endpoint would fix this.

## Reflections

This project taught me that the gap between a CRISP plan and a running cluster is filled with small discoveries: a CRD that doesn't do what you think, an API endpoint that changes per region, a Talos controller that overwrites your manifests.

The design review was invaluable — it caught DAG and placement errors that would have caused much worse problems. But it didn't catch the DNSConfig CRD issue, because the documentation hadn't been read with sufficient depth. Next time, every CRD will be analyzed alongside the official documentation, not just the project README.
