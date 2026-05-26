+++
title = "Tailscale Ingress in Production: A Practical Migration Story from TazLab"
date = 2026-05-24T15:00:00+02:00
draft = false
description = "After solving DNS with the Tailscale Operator and migrating secrets from Infisical to Vault, the next step was coherent: moving internal service access onto the tailnet. Here is how I replaced MetalLB and public Traefik with Tailscale Ingress and LoadBalancer."
tags = ["tailscale", "kubernetes", "networking", "migration", "ingress", "metalLB", "talos", "flux", "crisp"]
categories = ["Infrastructure", "DevOps", "Networking"]
author = "Taz"
+++

# Tailscale Ingress in Production: A Practical Migration Story from TazLab

If you have been following the TazLab cluster saga so far, you know the rhythm: each article describes one step forward in the architecture. First **DNS** — solving Tailscale MagicDNS resolution for cluster pods with the Tailscale Operator, after eight destroy-create cycles and a complete Flux DAG redesign. Then **secrets** — migrating all 20 secrets from Infisical to Vault in a single session, certifying the bootstrap with a destroy/create cycle from scratch (and publishing a blog post titled One Vault In, One Vault Out).

Now it is **networking**'s turn. After Vault became the single secret backend, and after the Tailscale Operator became the DNS gateway between cluster and tailnet, the next step was natural: moving internal service access — homepage, database, dashboards — onto the same tailnet, eliminating the dependency on public IP addresses and MetalLB LoadBalancers.

This article describes how I migrated six services from public Traefik + MetalLB to native Tailscale Ingress and LoadBalancer, the surprises along the way, and what it means to expose services in a tailnet-native architecture.

## The starting point: protected services, but publicly exposed

Before this migration, the service exposure architecture looked like this:

```
         Internet
            │
      ┌─────▼──────┐
      │  Traefik   │ ← public ingress with wildcard TLS
      │ + oauth2   │ ← protected by Dex + oauth2-proxy
      └─────┬──────┘
            │
      ┌─────▼──────┐
      │  Services  │ ← homepage, pgAdmin, Grafana, Longhorn...
      └────────────┘

      TazPod (container)
            │
      ┌─────▼──────┐
      │  MetalLB   │ ← LoadBalancer IP 192.168.1.241
      │  Postgres  │
      └────────────┘
```

The administrative services were protected by **oauth2-proxy + Dex**: no unauthenticated user could access them. The database was exposed on a MetalLB IP reachable only from the local network. The architecture was not insecure — it was inconsistent.

The problem was not security, but paradigm. I had infrastructure connected to the tailnet (Vault on Hetzner, Proxmox/Talos cluster, TazPod), but the internal services still spoke the language of the "public cloud": ingress on public FQDNs, LoadBalancer on local network IPs, manually managed wildcard TLS certificates. Each service had a different way of being reached: some via Traefik, some via MetalLB, some via direct IP. The new paradigm, after Vault and after the Tailscale Operator, was a single one: **everything goes through the tailnet**.

## The design: CRISP and design review

As with previous projects, the entire effort was managed with the **CRISP** methodology, starting with a Research and Design phase before touching a single YAML file.

### The external research: what the official documentation says

Before writing any configuration, I did two parallel research passes: one with Context7 on the official Tailscale Operator docs (validated January 2026) and one manual deep research. The goal was to clarify exactly how the Tailscale Operator handles service exposure.

The key discovery: the Tailscale Operator supports **three** exposure mechanisms, not just one:

1. **LoadBalancer Service** with `loadBalancerClass: tailscale` — for any TCP/UDP protocol (Postgres, SSH, etc.)
2. **Annotation** `tailscale.com/expose: "true"` on an existing Service — for quick exposure without creating new resources
3. **Ingress** with `ingressClassName: tailscale` — HTTP/HTTPS only, with automatic Let's Encrypt TLS

The database (Postgres) would be exposed with method 1. The administrative dashboards (homepage, pgAdmin, Longhorn, Traefik, Grafana) with method 3.

One crucial difference that emerged from the research: Tailscale Ingress supports **TLS only on port 443**. There is no cleartext exposure on port 80. This was not a problem — my backends already speak HTTP internally — but it is an architectural constraint to know.

### The agent design review

Before moving to implementation, I launched a **design review** agent to analyze the project. The review identified nine critical points, one of which required a major architectural decision: the authentication model.

The original plan was to keep **oauth2-proxy** behind the Tailscale Ingress, preserving the two-layer security: Tailscale ACL for the network, oauth2-proxy for user authentication. But verifying the actual oauth2-proxy deployment revealed a fundamental incompatibility:

```bash
kubectl get deployment -n auth oauth2-proxy -o json | jq '.spec.template.spec.containers[0].args'
["--provider=oidc",
 "--upstream=static://200",     # ← does not forward to any app
 "--set-xauthrequest=true",     # ← middleware for Traefik only
 ...
]
```

oauth2-proxy in my cluster is not a reverse proxy: it is configured as a **forward-auth middleware** for Traefik. With `--upstream=static://200`, it does not serve any application — it returns 200 OK if authentication is valid, and Traefik handles forwarding the request to the actual app. It cannot be used as a backend for a Tailscale Ingress.

The decision: **Tailscale ACL + identity headers**. The Tailscale Ingress injects HTTP headers like `Tailscale-User` and `Tailscale-User-Login` that identify the caller in the tailnet. Tailscale ACL blocks at the network level (only authorized devices), the headers provide identity for auditing, and each application maintains its own internal login. Three layers, no oauth2-proxy in the middle.

Other decisions from the review:

- **Intentional pgBouncer bypass**: TazPod is the sole tailnet consumer of the database with 1-2 persistent connections. Connection pooling would serve no purpose. If future consumers are added, a second tailnet Service pointing to pgBouncer will be created.
- **Comment-out for rollback**: the old MetalLB Service is not deleted but commented out in git. If the migration has issues, a `git revert` restores the original path in seconds.
- **Wildcard certificate cleanup**: after each migration, the ExternalSecret block for the wildcard TLS and the associated Traefik Ingress are removed.

## Bug #19471: the services scope

Before I could create any exposure resources, I had to resolve a known bug in the Tailscale Operator v1.96.x. The `k8s_operator` OAuth client was configured with only the `devices` scope — sufficient for DNSConfig, but not for creating Ingress or LoadBalancer proxies.

The bug is documented in issue #19471 of the Tailscale repository: during startup, the operator performs a self-verification call to the endpoint `/api/v2/tailnet/-/vip-services`. If the OAuth client does not have the `services` scope, the endpoint returns 404, and the operator misinterprets the error as `InvalidOAuth`, blocking the creation of any proxy.

The fix: updating the OAuth client via Terraform:

```hcl
resource "tailscale_oauth_client" "k8s_operator" {
  description = "tazlab-k8s-operator"
  scopes      = ["devices", "auth_keys", "services"]
  tags        = ["tag:k8s-operator"]
}
```

```bash
terraform apply -auto-approve -var="tailscale_api_key=${TS_API_KEY}" \
  -var="tailnet=magellanic-gondola.ts.net"
kubectl delete pod -n tailscale operator-...  # recycle for new credentials
```

### Tailnet HTTPS: a forgotten API call

Another discovery: the Tailscale Ingress requires the **HTTPS** (Let's Encrypt) option to be enabled at the tailnet level. It was not. From the Terraform state: `"httpsEnabled": false`. A simple API call fixed it:

```bash
curl -X PATCH -H "Authorization: Bearer ${TS_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"httpsEnabled": true}' \
  "https://api.tailscale.com/api/v2/tailnet/magellanic-gondola.ts.net/settings"
```

The problem was resolved in seconds.

## The ACLs: new tags for new services

The migration also required updating the tailnet access policies. I added two new tags:

- **`tag:k8s`**: default tag for operator-managed proxies (LoadBalancer and Ingress)
- **`tag:internal-apps`**: tag for administrative dashboard Ingress resources

```json
"tagOwners": {
  "tag:k8s":           ["tag:k8s-operator"],
  "tag:internal-apps": ["tag:k8s-operator"]
}
```

And two new ACL rules to allow TazPod to reach the exposed services:

```json
{"action": "accept", "src": ["tag:tazpod"], "dst": ["tag:k8s:5432"]},
{"action": "accept", "src": ["tag:tazpod"], "dst": ["tag:internal-apps:443"]}
```

## The implementation: six services, three slices

The migration was split into three vertical slices, each implemented and validated independently.

### Slice 1: Database

The first migrated service was PostgreSQL. The old MetalLB Service (`tazlab-db-external` on `192.168.1.241:5432`) was replaced with a Tailscale LoadBalancer:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: tazlab-db-tailnet
  annotations:
    tailscale.com/hostname: "tazlab-db"
    tailscale.com/tags: "tag:k8s"
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  ports:
    - port: 5432
  selector:
    postgres-operator.crunchydata.com/cluster: tazlab-db
    postgres-operator.crunchydata.com/role: master
```

The database is now reachable from any authorized device in the tailnet at `tazlab-db.magellanic-gondola.ts.net:5432`.

**One important detail**: the Service selector must match the original MetalLB Service exactly — both `cluster: tazlab-db` **and** `role: master` labels. During the design review, the agent noted that my first draft used only `role: master`, which could match replicas in the future.

### Slice 2: Administrative dashboards

The five dashboards (Homepage, pgAdmin, Longhorn, Traefik, Grafana) were migrated one at a time, in order of complexity. The mechanism is the same for all: an Ingress with `ingressClassName: tailscale` pointing directly to the application's Service.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pgadmin-tailnet
  annotations:
    tailscale.com/experimental-forward-cluster-traffic-via-ingress: "true"
    tailscale.com/tags: "tag:internal-apps"
spec:
  ingressClassName: tailscale
  tls:
    - hosts:
        - pgadmin
  defaultBackend:
    service:
      name: pgadmin
      port:
        number: 8001
```

Two annotations are mandatory for every Ingress:

- **`tailscale.com/experimental-forward-cluster-traffic-via-ingress: "true"`**: allows pods inside the cluster to reach the Ingress via its MagicDNS name. Without this annotation, hairpin traffic (pod → same cluster via tailnet) does not work.
- **`tailscale.com/tags: "tag:internal-apps"`**: assigns the tag to the proxy device created by the operator, controlled by tailnet ACLs.

Each migration was a two-phase GitOps operation:

1. **Phase 1**: create the new Tailscale Ingress (coexists with the old Traefik Ingress) → validate → commit
2. **Phase 2**: remove the Traefik Ingress and the wildcard TLS ExternalSecret → remove MetalLB annotations from the Service → change the Service from LoadBalancer to ClusterIP → commit

### The YAML mistake that blocked Flux

During Phase 2, I removed MetalLB annotations from some Service YAML files, but the indentation was incorrect: `spec:` ended up as a child of `metadata:` instead of at the same level.

```yaml
# WRONG
kind: Service
metadata:
  name: longhorn
  namespace: longhorn-system
  spec:                # ← indented under metadata!
  type: ClusterIP
  ports: ...
```

Flux's dry-run failed with: `Service "longhorn" is invalid: spec.ports: Required value`. The error message did not say "wrong indentation" — it said "ports required", leading me to look for the problem in the wrong place.

I fixed it by correcting the indentation in three files (longhorn, traefik, pgadmin) and re-pushing. The lesson: when Flux says a field is "required" and you know you wrote it, check the YAML structure — the Kubernetes validator parses the tree literally.

### Slice 3: Homepage links

The last slice was the simplest: updating the links in the homepage `services.yaml` to point to the new tailnet hostnames, and adding `home.magellanic-gondola.ts.net` to the `HOMEPAGE_ALLOWED_HOSTS` whitelist.

## The result

| Service | Before | After |
|---|---|---|
| Database | MetalLB `192.168.1.241:5432` | `tazlab-db.magellanic-gondola.ts.net:5432` |
| Homepage | Traefik `home.tazlab.net` | `home.magellanic-gondola.ts.net` |
| pgAdmin | Traefik `pgadmin.tazlab.net` | `pgadmin.magellanic-gondola.ts.net` |
| Longhorn | Traefik `longhorn.tazlab.net` | `longhorn.magellanic-gondola.ts.net` |
| Traefik | Traefik `traefik.tazlab.net` | `traefik.magellanic-gondola.ts.net` |
| Grafana | Traefik `grafana.tazlab.net` | `grafana.magellanic-gondola.ts.net` |

All services are now accessible exclusively via the tailnet. No public IP addresses, no MetalLB LoadBalancers, no Traefik Ingress for internal services. The only way to reach them is to be an authorized device in the tailnet.

## Lessons learned

**The design review finds problems the plan cannot see.** The review identified the oauth2-proxy incompatibility that, if discovered during implementation, would have halted everything and required a redesign. It costs 30 minutes of review and saves hours of debugging.

**External research is an investment, not a cost.** Without verifying the official documentation, I would not have known that Tailscale Ingress is TLS-only, that the `services` scope is mandatory, or that the clusterIP can be defined in the DNSConfig CR. Every unverified assumption is a potential blocker during build.

**YAML is unforgiving.** The indentation error that blocked Flux was trivial but hard to diagnose because the error message pointed in the wrong direction. Next time, after a structural change to a YAML file, I will validate syntax with `kubectl --dry-run` before pushing.

**The tailnet paradigm is consistent.** The common thread of this article series is the gradual migration toward a tailnet-native architecture: first DNS, then secrets, now networking. Each step is enabled by the previous one, and each step simplifies the next. It is a self-reinforcing pattern.
