---
title: "The Foundations of Accessibility: Traefik, Cert-Manager, and the Castle's Philosophical Pivot"
date: 2026-01-30T10:42:00+01:00
draft: false
tags: ["kubernetes", "traefik", "cert-manager", "terraform", "devops", "security", "letsencrypt"]
categories: ["Infrastructure", "Security"]
author: "Taz"
description: "Technical chronicle of the implementation of Traefik and Cert-Manager in the Ephemeral Castle: the choice to switch to the HTTP-01 challenge to ensure technological agnosticism."
---

# The Foundations of Accessibility: Traefik, Cert-Manager, and the Castle's Philosophical Pivot

After securing the heart of the **Ephemeral Castle** with etcd encryption and establishing the secure bridge with Infisical, the infrastructure was in a state of "secure solitude." The cluster was protected, but isolated. In this new stage of my technical diary, I document the implementation process of the two pillars that allow the Castle to communicate with the outside world in a secure and automated way: **Traefik** and **Cert-Manager**.

The goal of the day was ambitious: to transform a "naked" cluster into a production-ready platform, capable of managing HTTPS traffic and the SSL certificate lifecycle without any manual intervention. Along the way, I collided with architectural choices that tested the very philosophy of the project, leading to a radical change of course.

---

## The Prelude of Trust: TazPod as Identity Anchor

No automation can begin without a verified identity. In the context of the Ephemeral Castle, where portability is the supreme dogma, I cannot afford to leave access keys scattered on my laptop's hard drive. This is where **TazPod** comes in.

The bootstrap process always begins in the terminal. Through the `tazpod pull` command, I activate the "Ghost Mount": an encrypted memory area, isolated via Linux Namespaces, where **Infisical** session tokens reside. It is this step that allows Terraform to authenticate towards the Infisical EU instance and retrieve cluster secrets (like the Proxmox token or S3 keys).

I populated the `secrets.tfvars` file by drawing from this secure enclave. This approach ensures that the "master" credentials are never written in cleartext on the persistent filesystem, keeping my work environment ready to disappear at any time without leaving a trace. Once Terraform has its tokens, the provisioning dance begins.

---

## Phase 1: Traefik - The Traffic Director

To manage incoming traffic, the choice fell on **Traefik**. In Kubernetes, an Ingress Controller is the component that listens for requests coming from the outside and routes them to the correct services within the cluster.

### The Reasoning: Why Traefik and not Nginx?
I decided to use Traefik primarily for its "Cloud Native" nature and its ability to self-configure by reading Kubernetes resource annotations. Compared to the Nginx Ingress, Traefik offers a smoother management of Custom Resource Definitions (CRDs), such as the **IngressRoute**, which allows for superior configuration granularity for traffic routing.

I could have chosen an approach based on a **DaemonSet**, running Traefik on every node, but for the "Blue" cluster (composed of only one operational worker) I opted for a classic **Deployment** with a single replica. This reduces resource consumption and simplifies persistence management, should it be necessary. In a larger architecture, scaling would be managed by a Horizontal Pod Autoscaler based on traffic metrics.

### IaC Integration
Traefik was not installed via Flux, but integrated directly into the `main.tf` of **ephemeral-castle**. This is a fundamental design choice: the Ingress is a component of the core infrastructure, not an application. It must be born along with the cluster.

```hcl
# Traefik Ingress Controller Configuration
resource "helm_release" "traefik" {
  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  namespace  = kubernetes_namespace.traefik.metadata[0].name
  version    = "34.0.0"

  values = [
    <<-EOT
      deployment:
        kind: Deployment
        replicas: 1
      podSecurityContext:
        fsGroup: 65532
      additionalArguments:
        - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
        - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      ports:
        web:
          exposedPort: 80
        websecure:
          exposedPort: 443
      service:
        enabled: true
        type: LoadBalancer
        annotations:
          # Static IP from MetalLB Pool
          metallb.universe.tf/loadBalancerIPs: 192.168.1.240
      persistence:
        enabled: false # Switched to stateless
    EOT
  ]
  depends_on = [helm_release.longhorn, kubectl_manifest.metallb_config]
}
```

---

## Phase 2: Cert-Manager and the Philosophical Pivot

An Ingress without HTTPS is a blunt weapon. To automate the issuance of TLS certificates via **Let's Encrypt**, I introduced **Cert-Manager**. This is where the real ideological clash of the day took place.

### The Initial Error: The temptation of DNS-01
Initially, I configured Cert-Manager to use the **DNS-01** challenge via Cloudflare. The technical advantage is undeniable: it allows for the generation of **Wildcard** certificates (`*.tazlab.net`), enormously simplifying subdomain management. I created the integration with Infisical to retrieve the Cloudflare API Token and watched with satisfaction as the first wildcard certificate appeared in the cluster.

### The Investigation: The betrayal of Agnosticism
As I observed the ready certificate, I realized I was violating the first commandment of the Ephemeral Castle: **provider independence**.
By tying the core infrastructure to Cloudflare, I was creating a "lock-in." If tomorrow I wanted to donate this project to the community or use it for a client using different DNS, I would have to rewrite the `ClusterIssuer` logic.

**I decided to take a step back.** I destroyed the Cloudflare configuration and switched to the **HTTP-01** challenge.

### Deep-Dive: DNS-01 vs HTTP-01
- **DNS-01**: Cert-manager writes a TXT record in your DNS to prove ownership. It allows wildcards but requires a specific integration for each provider (Cloudflare, Route53, etc.).
- **HTTP-01**: Cert-manager exposes a temporary file on port 80. Let's Encrypt reads it and validates the domain. It is universal and agnostic to the DNS, but it does not allow wildcards.

For the Castle, agnosticism is more important than the convenience of a single certificate. Every app (Blog, Grafana, etc.) will now request its own specific certificate. It is a cleaner choice and consistent with a modular architecture.

---

## Phase 3: Error Analysis and \"The Ephemeral Way\"

The transition from one configuration to another was not painless. During the Traefik update via Terraform, the command timed out.

### The Struggle: Helm in limbo
I saw the `helm_release.traefik` resource stuck in a `pending-install` state. When Terraform times out during a Helm installation, the cluster remains in an inconsistent state: the release exists in the Helm database but Terraform has lost the tracking (state).

On the next attempt, I received the error:
`Error: cannot re-use a name that is still in use`

**The mental resolution process:**
1. I checked the actual state with `helm list -n traefik`.
2. I tried to import the resource into the Terraform state (`terraform import`), but the release was marked as \"failed\" and not importable.
3. I adopted the \"Ephemeral\" solution: I manually uninstalled Traefik with `helm uninstall`, removed the resource from the Terraform state (`terraform state rm`), and deleted the namespace to clean up any remaining PVCs.
4. I relaunched `terraform apply`.

This \"clean slate\" approach is the heart of the project. Instead of debugging a corrupted Helm database for hours, I bring the system back to state zero and let the declarative code rebuild it correctly.

---

## Phase 4: The Final Agnostic Configuration

Here is how the universal `ClusterIssuer` now looks in the Castle. It does not need external API tokens; it only needs an email for Let's Encrypt.

```hcl
# letsencrypt-issuer.tf (integrated in main.tf)
resource "kubectl_manifest" "letsencrypt_issuer" {
  yaml_body = <<-EOT
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: letsencrypt-issuer
    spec:
      acme:
        email: ${var.acme_email}
        server: https://acme-v02.api.letsencrypt.org/directory
        privateKeySecretRef:
          name: letsencrypt-issuer-account-key
        solvers:
        - http01:
            ingress:
              class: traefik
  EOT
  depends_on = [helm_release.cert_manager, helm_release.traefik]
}
```

We have also implemented total **Zero-Hardcoding**. Every IP, every domain (`tazlab.net`), and every parameter is managed via `variables.tf` and `terraform.tfvars`. The code is now an \"empty box\" ready to be filled with any configuration.

---

## Post-lab Reflections: What does this setup mean?

With the implementation of Traefik and Cert-Manager (HTTP-01), the Castle has completed its \"Core Infrastructure\" phase.

### What we learned:
1.  **Stateless is better**: By removing ACME from Traefik and delegating it to Cert-Manager, we made the Ingress Controller totally stateless. We can destroy and recreate it without worrying about losing the certificate `.json` files.
2.  **Independence has a price**: Giving up wildcard certs is a small operational nuisance, but it ensures that the Castle can \"land\" on any DNS provider without changes to the core code.
3.  **The Castle is a Factory**: The current structure allows cloning the entire Proxmox provider folder, changing three lines in the `.tfvars` file, and having a new working cluster in less than 10 minutes.

Some elements are still missing to define this base as \"complete\" (Prometheus and Grafana are next on the list), but the path is set. The rest of the work is now in the hands of **Flux**, which will begin populating the Castle with real applications, starting with the Blog you are reading.

---
*End of Technical Chronicle - Phase 3: Ingress and Certificate Automation*
