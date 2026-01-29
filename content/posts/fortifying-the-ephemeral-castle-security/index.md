---
title: "The Fortress Walls: Implementing Zero-Trust Security and Secret Management"
date: 2026-01-29T10:00:00+01:00
draft: false
tags: ["kubernetes", "security", "infisical", "terraform", "talos", "gitops", "devops", "external-secrets"]
categories: ["Infrastructure", "Security"]
author: "Taz"
description: "Technical chronicle of the Ephemeral Castle consolidation: from Infisical integration via TazPod to native etcd encryption and the adoption of External Secrets Operator."
---

# The Fortress Walls: Engineering Zero-Trust Security into the Ephemeral Infrastructure

Building an immutable infrastructure is an exercise in discipline, but making it secure without sacrificing portability is an architectural challenge. After laying the foundations of the **Ephemeral Castle** on Proxmox and establishing the reconciliation loop with Flux, I realized that the foundations were solid but the walls were still vulnerable. Secrets resided in SOPS-encrypted YAML files within the Git repository: a functional solution, but one that introduced significant operational friction and too tight a coupling with local encryption keys.

In this technical chronicle, I document the transition to a production-grade security model, where trust is never presumed (Zero-Trust) and secrets flow as dynamic entities, never persisted on disk in cleartext.

---

## The Spark: The Zero Point of Trust with TazPod

Every fortress needs a key, but where does this key reside when the knight is nomadic? My answer is **TazPod**. Before I can launch a single Terraform command, I must establish a secure channel to my source of truth: **Infisical**.

I decided to use TazPod not just as a development environment, but as a true "identity anchor." Through the `tazpod pull` command, I activate the "Ghost Mount." In this state, TazPod creates an isolated Linux namespace and mounts an encrypted memory area where it downloads Infisical session tokens. This step is crucial: the tokens that allow Terraform to read the cluster keys never touch the guest computer's disk in cleartext.

Why Infisical? The choice fell on Infisical (EU instance for compliance and latency) to overcome the limits of SOPS. SOPS requires every collaborator (or every CI/CD instance) to possess the Age private key or access to a KMS. With Infisical, I centralized secret management into a platform that offers audit logs, rotation, and, most importantly, native integration with Kubernetes via Machine Identities.

Once TazPod was unlocked, I populated the `secrets.tfvars` file with the Machine Identity's `client_id` and `client_secret`. This file is the "beachhead": it is the only sensitive information needed to start the automation dance, and it is strictly excluded from version control via `.gitignore`.

---

## Phase 1: Hardening the Heart - Talos Secretbox and etcd Encryption

Kubernetes, by its nature, stores all resources, including `Secret`, within **etcd**. If an attacker were to gain access to etcd data files on the Control Plane disk, they could extract every key, certificate, or password in the cluster. In a standard configuration, this data is stored in cleartext.

### The Technical Reasoning
I decided to implement Talos **Secretbox Encryption**. Talos allows patching the node configuration to include a 32-byte encryption key (AES-GCM) that is used to encrypt data before it is written to etcd.

Why not use native Kubernetes encryption (EncryptionConfiguration)? The answer lies in the operational simplicity of Talos. Managing EncryptionConfiguration manually requires creating files on the node and managing rotation via the API server. Talos abstracts this process into its declarative configuration, allowing me to manage the key like any other IaC parameter.

### The Investigation: The disaster of hot migration
The initial plan involved applying the patch to an already existing cluster. I generated a secure key with:
```bash
openssl rand -base64 32
```
I uploaded it to Infisical and updated the Terraform manifest to inject it into the Control Plane. However, at the moment of `terraform apply`, disaster struck: core cluster Pods began to fail. Flux went into `CrashLoopBackOff`, the `helm-controller` could no longer read its tokens.

Checking `kube-apiserver` logs with `talosctl logs`, I found the fatal error:
`"failed to decrypt data" err="output array was not large enough for encryption"`

The API server had entered a state of confusion: it was trying to decrypt existing secrets (written in cleartext) using the new Secretbox key, or worse, it had partially encrypted some data, rendering it unreadable. The cluster was corrupted.

### The Ephemeral Way: Destruction and Rebirth
Faced with a compromised Kubernetes cluster, a traditional administrator would spend hours attempting to repair etcd. But this is the **Ephemeral Castle**. I decided to honor the project's philosophy: **do not repair, recreate**.

I performed an aggressive reset:
1. I manually removed "ghost" resources from the Terraform state (`terraform state rm`).
2. I destroyed the VMs on Proxmox.
3. I relaunched the entire provisioning.

The cluster was reborn in 5 minutes, but this time with the Secretbox active from the very first second of life. Every piece of data written to etcd during the bootstrap process was born already encrypted. This is the true power of immutability: the ability to solve complex problems by returning to a known, clean state.

```hcl
# Patch snippet applied in main.tf
resource "talos_machine_configuration_apply" "cp_config" {
  client_configuration = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node = var.control_plane_ip
  config_patches = [
    yamlencode({
      machine = {
        # ... networking and installation ...
      }
      cluster = {
        secretboxEncryptionSecret = data.infisical_secrets.talos_secrets.secrets["TALOS_SECRETBOX_KEY"].value
      }
    })
  ]
}
```

---

## Phase 2: The Dynamic Ambassador - External Secrets Operator (ESO)

With the cluster database secured, the next step was to eliminate the need to store application secrets in the Git repository. SOPS is a great tool, but it introduces a problem: secret rotation requires a new commit and a new push.

### Why External Secrets Operator?
I chose to install **External Secrets Operator (ESO)** as a fundamental pillar of the Castle. ESO does not store secrets; it acts as a bridge between Kubernetes and an external provider (Infisical).

The advantage is radical: in Git, I write an `ExternalSecret` object that describes *which* secret I want and *where* it should end up in Kubernetes. ESO takes care of contacting Infisical via API, retrieving the value, and creating a native Kubernetes `Secret` only in the cluster's RAM. If I change a value on Infisical, ESO updates it in the cluster in real-time, without any Git intervention.

### The Authentication Challenge: Universal Auth
To have ESO talk to Infisical securely, I avoided using simple static tokens. I implemented the **Universal Auth** method (Machine Identity).

The thought process was this: Terraform creates an initial Kubernetes secret containing the Machine Identity's `clientId` and `clientSecret`. Then, it configures a `ClusterSecretStore`, a resource that instructs ESO on how to authenticate cluster-wide.

During installation, I ran into the rigid schema of ESO version `0.10.3`. A configuration error in the `ClusterSecretStore` blocked synchronization with a laconic `InvalidProviderConfig`. Analyzing the CRD with:
```bash
kubectl get crd clustersecretstores.external-secrets.io -o yaml
```
I discovered that the fields had changed compared to previous versions. The `universalAuth` section had become `universalAuthCredentials` and required explicit references to Kubernetes secret keys.

Here is the final and correct configuration that I integrated directly into the Terraform provisioning:

```hcl
resource "kubectl_manifest" "infisical_store" {
  yaml_body = <<-EOT
    apiVersion: external-secrets.io/v1beta1
    kind: ClusterSecretStore
    metadata:
      name: infisical-tazlab
    spec:
      provider:
        infisical:
          hostAPI: https://eu.infisical.com
          secretsScope:
            environmentSlug: ${var.infisical_env_slug}
            projectSlug: ${var.infisical_project_slug}
          auth:
            universalAuthCredentials:
              clientId:
                name: ${kubernetes_secret.infisical_machine_identity.metadata[0].name}
                namespace: ${kubernetes_secret.infisical_machine_identity.metadata[0].namespace}
                key: clientId
              clientSecret:
                name: ${kubernetes_secret.infisical_machine_identity.metadata[0].name}
                namespace: ${kubernetes_secret.infisical_machine_identity.metadata[0].namespace}
                key: clientSecret
  EOT
  depends_on = [helm_release.external_secrets, kubernetes_secret.infisical_machine_identity]
}
```

---

## Phase 3: Modularization and Cleanup - The Castle Factory

The final act of this consolidation day was code refactoring. An ephemeral infrastructure must be replicable. If tomorrow I wanted to create a "Green" cluster identical to the "Blue" one but isolated, I shouldn't have to rewrite the code, just change the parameters.

### The Concept of Zero-Hardcoding
I decided to rigorously apply the principle of **Zero-Hardcoding**. I removed every static IP, every Infisical folder name, and every repository URL from the `main.tf` and `providers.tf` files. Everything was moved to a three-level system:

1.  **`variables.tf`**: Defines the schema. What data is needed? What type is it? What are the secure defaults?
2.  **`terraform.tfvars`**: Defines the topology. This is where node IPs, the GitOps repo URL, and Infisical project slugs reside. This file is committed: it describes *what* the castle is, not how to open it.
3.  **`secrets.tfvars`**: The only forbidden file. It contains the Machine Identity credentials. Thanks to the `.gitignore` modification, this file stays only on my protected workstation (or in the TazPod vault).

```hcl
# Modularization example in providers.tf
provider "infisical" {
  host          = "https://eu.infisical.com"
  client_id     = var.infisical_client_id
  client_secret = var.infisical_client_secret
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  # Proxmox secrets are now dynamically retrieved from Infisical via data source
  api_token = "${data.infisical_secrets.talos_secrets.secrets["PROXMOX_TOKEN_ID"].value}=${data.infisical_secrets.talos_secrets.secrets["PROXMOX_TOKEN_SECRET"].value}"
}
```

### The Final Farewell to SOPS
With this move, I was finally able to delete `proxmox-secrets.enc.yaml`. There are no more encrypted files weighing down the repository. The dependency on the SOPS provider in Terraform has been removed. The "Castle" is now lighter, faster to initialize, and infinitely more secure.

---

## Post-Lab Reflections: What have we learned?

This implementation phase taught me that security in a modern environment is not a perimeter, but a **flow**.

We have traced a path that starts from the developer's mind (the TazPod passphrase), crosses an encrypted channel in RAM, temporarily materializes in Terraform variables to build the infrastructure, and finally stabilizes in a Kubernetes operator (ESO) that keeps the secret fluid and updatable.

### Results Achieved:
*   **Armored etcd**: Even with physical access to Proxmox disks, cluster data is unreadable without the Secretbox key.
*   **Clean Git**: The repository contains only logic, no keys, not even encrypted ones.
*   **Total Replicability**: I can duplicate the provider folder, change three lines in `.tfvars`, and have a production-ready new cluster in less than 10 minutes.

The Castle now has its walls. It is ready to host the services that will make it alive, knowing that every "treasure" deposited within it will be protected by modern encryption and an architecture that never forgets its ephemeral nature.

---
*End of Technical Chronicle - Phase 2: Security and Secrets*
