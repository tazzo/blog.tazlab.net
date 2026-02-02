---
title: "The Castle's Orchestra: The Pivot to Terragrunt and the War on Race Conditions"
date: 2026-02-02T05:00:00+01:00
draft: false
tags: ["kubernetes", "terragrunt", "terraform", "fluxcd", "devops", "proxmox", "automation", "gitops"]
categories: ["Infrastructure", "Design Patterns"]
author: "Taz"
description: "Technical chronicle of a radical transformation: from monolithic Terraform to layered orchestration with Terragrunt to eliminate race conditions and ensure a deterministic bootstrap in 8 minutes."
---

# The Castle's Orchestra: The Pivot to Terragrunt and the War on Race Conditions

The dream of every DevOps engineer working with ephemeral infrastructure is **Total Determinism**. The idea that, by pressing a single key, an entire digital cathedral can rise from nothing, configure itself, and serve traffic in a few minutes, only to vanish without a trace, is what drives the **Ephemeral Castle** project. However, as often happens when transitioning from the lab to production, reality presented a steep bill in the form of instability, timing conflicts, and infinite stalls.

In this new stage of my technical diary, I am documenting the most significant architectural pivot since the project's inception: the abandonment of the Terraform monolith in favor of layered orchestration managed by **Terragrunt**. This was not merely a tool change, but a necessary philosophical shift to defeat the **Race Conditions** that were turning the cluster bootstrap into a gamble rather than a certainty.

---

## The Breaking Point: The Tyranny of Webhooks

Until a few days ago, the Castle was born from a single, giant `main.tf`. Terraform handled everything: it created the VMs on Proxmox, configured Talos OS, installed MetalLB, Longhorn, Cert-Manager, and finally Flux. On paper, Terraform's dependency graph should have managed the execution order. In practice, I collided with the asynchronous nature of Kubernetes.

### The Struggle Analysis: Webhooks in Timeout
The problem manifested systematically during the installation of **MetalLB** or **Cert-Manager**. Kubernetes uses **Admission Webhooks** to validate resources. When Terraform sent the manifest for an `IPAddressPool` (for MetalLB) or a `ClusterIssuer` (for Cert-Manager), the relative controller was still in the initialization phase.

The result was a frustrating error:
`failed calling webhook "l2advertisementvalidationwebhook.metallb.io": connect: connection refused`

Even though the controller Pod appeared `Running`, the webhook service was not yet ready to respond. Terraform, seeing the failure, errored out and interrupted the entire provisioning chain. I tried inserting artificial "waits," but they were fragile: too short and the system failed, too long and I lost the speed advantage. The monolith was becoming unmanageable because it tried to manage too many different states (infrastructure, network, storage, application logic) in a single lifecycle.

---

## The Philosophical Pivot: Base Infrastructure vs. GitOps

Another tactical error I had to acknowledge was over-delegation to **Flux**. In the previous post, I celebrated the idea of moving Longhorn and MetalLB under Flux management to make Terraform "lighter."

### The Reasoning: Why I moved back
I realized that MetalLB and Longhorn are not "applications," but **extensions of the cluster Kernel**. Without MetalLB, the Ingress doesn't receive an IP. Without Longhorn, apps requiring persistence (like the blog or databases) cannot start.

If I delegate these components to Flux, I create a dangerous dependency loop: Flux needs secrets to authenticate, but ESO (External Secrets Operator) needs a healthy cluster to run. If Flux fails for any reason, I lose visibility into the cluster's vital components. I decided, therefore, that everything necessary for the cluster to be considered "functional and capable" must be born via **IaC (Infrastructure as Code)**, while Flux must handle only what the cluster "hosts."

---

## The Arrival of Terragrunt: The Conductor

To solve these problems, I introduced **Terragrunt**. Terragrunt acts as a wrapper for Terraform, allowing the infrastructure to be divided into independent modules linked by an explicit dependency graph.

### Deep-Dive: State Isolation and Dependency Graph
Using Terragrunt introduced two key concepts that changed everything:
1.  **State Isolation**: Each layer (networking, storage, engine) has its own `.tfstate` file. If I break the Flux configuration, the state of my VMs on Proxmox remains intact. I no longer risk destroying the entire cluster due to a syntax error in a Kubernetes manifest.
2.  **Dependency Graph**: I can tell Terragrunt: "Don't even try to install MetalLB until the Platform layer (the VMs) is completely online and the Kubernetes API is responding."

---

## The Anatomy of the 6-Layer Castle

I reorganized the entire `ephemeral-castle` repository into a layered structure, where each layer builds upon the foundations of the previous one.

### Layer 1: Secrets (G1)
This layer interacts only with **Infisical EU**. It retrieves the necessary tokens for Proxmox, SSH keys, and S3 credentials. It is the "point zero" of trust.

### Layer 2: Platform (G2)
This is where the heavy provisioning happens. Virtual machines are created on Proxmox, and the **Talos OS** configuration is injected.
*   **Deep-Dive: Quorum and VIP**: In this phase, Terraform waits for the 3 Control Plane nodes to form the etcd quorum. The **Virtual IP (VIP)** must be stable before moving to the next layer. If the VIP does not respond, the bootstrap stops here.

### Layer 3: Engine (G3)
Once the "metal" is ready, we install the identity engine: **External Secrets Operator (ESO)**. Without ESO, the cluster cannot talk to Infisical to retrieve application secrets. It is the bridge between the external world and the Kubernetes world.

### Layer 4: Networking (G4)
Installation of **MetalLB**. Here we implemented the definitive solution to the webhook race condition. The orchestration script queries Kubernetes until the webhook's **EndpointSlice** is `Ready`. Only then is the IP pool configuration injected.

### Layer 5 & 6: Storage and GitOps (G5 - In Parallel)
This is where the optimization I called the **"Parallel Blitz"** took place. I realized that **Longhorn** (Storage) and **Flux** (GitOps) can be born simultaneously. Flux can start downloading images and preparing deployments while Longhorn is still initializing disks on the nodes.

---

## The War on State: "VM Already Exists" and the Persistent Backend

A recurring problem during testing was local state corruption. If I accidentally deleted the `.terraform` folder or if the state was not saved after a crash, the next attempt would yield the error:
`400 Parameter verification failed: vmid: VM 421 already exists on node proxmox`

### The Investigation: The ghost in the system
Terraform is a "state-aware" system. If it loses the state file, it thinks the world is empty. But Proxmox has a physical memory. To resolve this stall, I implemented two strategies:
1.  **Out-of-Tree Persistent Backend**: I moved all state files to a dedicated directory `/home/taz/kubernetes/ephemeral-castle/states/`, external to the Git repository. This ensures the state survives even an aggressive `git clean` or a branch change.
2.  **Nuclear Wipe**: I created a `nuclear-wipe.sh` script that, in case of emergency, uses the Proxmox API to forcibly delete VMs between IDs 421 and 432, allowing Terraform to restart from a real tabula rasa.

---

## Technical Implementation: The Heart of Terragrunt

Here is how the root configuration file that orchestrates the entire dance looks. Notice how providers are generated for all underlying layers, ensuring total consistency.

```hcl
# live/terragrunt.hcl
remote_state {
  backend = "local"
  config = {
    path = "${get_parent_terragrunt_dir()}/../../states/${path_relative_to_include()}/terraform.tfstate"
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "proxmox" {
  endpoint = var.pm_api_url
  api_token = var.pm_api_token
  insecure = true
}

provider "kubernetes" {
  config_path = "${get_parent_terragrunt_dir()}/../../clusters/tazlab-k8s-proxmox/proxmox/configs/kubeconfig"
}

provider "helm" {
  kubernetes {
    config_path = "${get_parent_terragrunt_dir()}/../../clusters/tazlab-k8s-proxmox/proxmox/configs/kubeconfig"
  }
}
EOF
}
```

And an example of how a layer (e.g., `networking`) declares its dependency on the previous layer:

```hcl
# live/tazlab-k8s-proxmox/stage4-networking/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "engine" {
  config_path = "../stage3-engine"
}

inputs = {
  # Inputs passed from the previous layer if necessary
}
```

---

## Optimization: The "Parallel Blitz" and the 8-Minute Record

After stabilizing the order, the challenge became speed. Initially, the bootstrap took about 14 minutes. Analyzing the logs, I saw that Flux remained waiting for Longhorn even though it wasn't strictly necessary for its basic installation.

### The Solution: Intelligent Orchestration
In the `create.sh` script, I separated the layer application. While layers 1, 2, 3, and 4 must be sequential (Secrets -> VMs -> Engine -> Network), layers 5 and 6 are launched almost simultaneously.

```bash
# create.sh snippet - Enterprise V4
echo "🚀 STAGE 5 & 6: Launching Storage and GitOps in Parallel..."
terragrunt run-all apply --terragrunt-non-interactive --terragrunt-parallelism 2
```

This change reduced the total bootstrap time to **8 minutes and 20 seconds**. In this timeframe, the system goes from cosmic nothingness to an HA cluster with 5 nodes, distributed storage, Layer 2 networking, and Flux having already reconciled the latest version of this blog.

---

## Post-Lab Reflections: Toward Cloud Agnosticism

The transition to Terragrunt has transformed the Ephemeral Castle into a real **Infrastructure Factory**.

### What does this setup mean for the future?
1.  **Platform Agnosticism**: I can now create a `live/tazlab-k8s-aws/` folder, change only the `stage2-platform` layer (using AWS modules instead of Proxmox), and keep all other layers identical. Networking will provide an AWS LoadBalancer instead of MetalLB, but Flux and the apps won't even notice.
2.  **Industrial Reliability**: We have eliminated the "maybe it works." If a layer fails, Terragrunt stops exactly there, allowing us to inspect the specific state without chasing ghosts in a 5000-line state file.
3.  **Speed as Security**: An infrastructure born in 8 minutes allows one to not fear destroying everything. If we suspect a compromise or a configuration error, the answer is always: `destroy && create`.

The Castle is now solid, modular, and ready to scale beyond the borders of my home lab. The orchestra is ready, and the music of code has never been so harmonious.

---
*End of Technical Chronicle - The Terragrunt Revolution*
