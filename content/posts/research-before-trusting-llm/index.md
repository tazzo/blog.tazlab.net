+++
title = "Follow-Up: Don't Trust the LLM — From Research to Enterprise Hardening"
date = 2026-05-09T17:00:00+02:00
draft = false
tags = ["Kubernetes", "Talos OS", "Flux", "Tailscale", "DNS", "LLM", "Infisical", "Registry", "Enterprise", "Hardening"]
description = "Chronicle of the technical implementation post-research: transitioning to a native architecture for DNS resolution, Talos runtime hardening, and cluster bootstrap stabilization."
author = "Tazzo"
+++

## Last Time: Analysis of the Previous State

In the previous article, it emerged how an in-depth documentary research necessitated a complete revision of the `15-tailscale-operator-hardening` project. The analysis confirmed that the Tailscale Operator's `DNSConfig` CRD is functional only when coupled with `ExternalName` type Services with the `tailscale.com/tailnet-fqdn` annotation. Furthermore, the behavior of the Talos v1.12 CoreDNS controller imposed a shift towards a direct DNS stack management strategy ("Disable & Replace").

The objective of this phase was to transform the research results into a stable implementation, eliminating the temporary workarounds previously adopted (relay DaemonSet and static mappings).

## Phase 1: ExternalName Implementation and ACL Resolution

The first technical objective was the activation of native resolution for Vault through the Operator. I removed the relay DaemonSet and declared an `ExternalName` Service in the `tailscale` namespace:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: lushycorp-vault
  namespace: tailscale
  annotations:
    tailscale.com/tailnet-fqdn: lushycorp-vault.magellanic-gondola.ts.net
spec:
  type: ExternalName
  externalName: lushycorp-vault.magellanic-gondola.ts.net
```

**Analysis of the initial failure**: Upon deploying the manifest, the Operator reported a provisioning error (Status 400): `"requested tags [tag:k8s] are invalid or not permitted"`.
The investigation confirmed that the Operator was attempting to register the egress proxy using the default `tag:k8s`, which was not present in the Tailscale ACLs configured in `ephemeral-castle`.

**Resolution**: Instead of modifying the tailnet ACLs, I applied the principle of least privilege by configuring the Operator to use the already authorized `tag:k8s-operator` through the Helm values:

```yaml
  values:
    operator:
      proxy:
        tags: ["tag:k8s-operator"]
```

Applying the modification allowed for the correct instantiation of the egress proxy pod.

## Phase 2: Transition to Managed CoreDNS on Talos

DNS management on Talos v1.12 requires a declarative approach to prevent the `machined` controller from overwriting custom configurations. I proceeded with disabling the native controller and deploying a user-managed CoreDNS stack.

Configuration applied via Terraform:
1.  **Disabling**: `cluster.coreDNS.disabled: true`.
2.  **Kubelet Config**: `machine.kubelet.clusterDNS: ["10.96.0.10"]` to direct DNS traffic towards the service IP of the new stack.
3.  **Deploy**: Injection of the entire stack (SA, RBAC, Deployment, Service, ConfigMap) as an `inlineManifest` in the Control Plane configuration.

**Troubleshooting**: During the first startup, CoreDNS reported the error `plugin/forward: not an IP address or file: "nameserver.tailscale.svc.cluster.local"`. The `forward` plugin requires an explicit IP address as a target, not supporting recursive resolution for its own forwarding targets.

## Phase 3: IP Pinning and Design Invariants

To eliminate dependence on dynamic IP addresses and make the infrastructure resilient to `destroy/create` cycles, I implemented a static IP (Pinning) for the Operator's nameserver.

I declared an additional Service in the `tazlab-k8s` repository:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nameserver-static
  namespace: tailscale
spec:
  type: ClusterIP
  clusterIP: 10.96.0.101 # Design constant
  selector:
    app: nameserver
  ports:
    - name: udp
      port: 53
      targetPort: 1053
```

The Corefile now points stably to `10.96.0.101`, ensuring the persistence of the DNS resolution chain regardless of the cluster state.

## Phase 4: Registry Authentication via Container Runtime

The logic for creating pull secrets via bash scripts was removed, moving authentication to the `containerd` runtime level. Using the **Infisical** Terraform provider, credentials for `ghcr.io` are now injected directly into the Talos node configuration:

```hcl
# Dynamic retrieval from Infisical
data "infisical_secrets" "bootstrap" {
  env_slug     = "dev"
  workspace_id = var.infisical_workspace_id
  folder_path  = "/ephemeral-castle/tazlab-k8s/proxmox"
}

# Runtime configuration
registries = {
  config = {
    "ghcr.io" = {
      auth = {
        username = "x-access-token"
        password = data.infisical_secrets.bootstrap.secrets["GITHUB_TOKEN"].value
      }
    }
  }
}
```

This approach ensures node-wide authentication, eliminating the need to manage `ImagePullSecrets` in individual namespaces.

## Phase 5: Resolution of the Race Condition (TD-026)

The final step concerned the stability of the cluster bootstrap. `oauth2-proxy` had a critical dependency on the availability of Dex. To resolve the technical debt **TD-026**, I introduced an `initContainer` in the proxy deployment:

```yaml
initContainers:
  - name: wait-for-dex
    image: curlimages/curl:8.7.1
    args:
      - --retry
      - "30"
      - --retry-delay
      - "5"
      - https://dex.tazlab.net/.well-known/openid-configuration
```

The modification ensures that the main `oauth2-proxy` process is only started after confirming the reachability of the OIDC endpoint, ensuring a deterministic convergence of the cluster.

## Conclusions

The implementation of the `15-tailscale-operator-hardening` project allowed for the alignment of the TazLab cluster with enterprise standards, eliminating non-declarative workarounds.

The lessons learned confirm the effectiveness of a structured workflow:
1.  **Priority to Documentation**: External research prevented the implementation of fragile architectures.
2.  **IaC and Invariants**: The use of static IPs and runtime-level configurations increases system predictability.
3.  **CRISP Methodology**: The separation between design and implementation, supported by empirical verifications, ensured the success of the project.

With the ClusterSecretStore now able to resolve and contact Vault natively, the infrastructure is ready for the secret migration phase.
