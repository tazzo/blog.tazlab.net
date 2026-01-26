---
title: "From Vision to Silicon: Implementing the Ephemeral Castle on Proxmox"
date: 2026-01-28T22:08:55+01:00
draft: false
tags: ["kubernetes", "terraform", "proxmox", "talos", "gitops", "devops", "longhorn", "flux"]
categories: ["Infrastructure", "Tutorials"]
author: "Taz"
description: "Technical chronicle of the first implementation phase of the Ephemeral Castle: provisioning with Terraform, managing Talos OS on Proxmox, and configuring distributed storage."
---

Architecture is not just a drawing on paper or a manifesto of intent. After outlining the vision of the **Ephemeral Castle**, it is time to get hands-on with silicon, hypervisors, and declarative code. This is the chronicle of the first implementation phase: the transition from an abstract concept to a functional Kubernetes cluster, born and managed entirely through Infrastructure as Code (IaC).

I decided to start the journey in my local lab based on **Proxmox VE**. The choice is not accidental: total control over the hardware allows me to iterate quickly, test the limits of distributed storage, and understand networking dynamics before facing the complexity (and costs) of the public cloud.

## The Foundation: Talos OS and the Death of SSH

The first critical decision concerned the operating system of the nodes. I chose **Talos OS**. In a world accustomed to Ubuntu Server or Debian, Talos represents a radical paradigm shift: it is a Linux operating system designed exclusively for Kubernetes. It is immutable, minimal, and, most importantly, it has no SSH shell.

Why this extreme choice? In an infrastructure that aims to be "ephemeral," the persistence of manual configurations within a node is the enemy. By eliminating SSH, I eliminated the temptation to apply "temporary fixes" that would become permanent. Every modification must pass through the Talos API via YAML configuration files. If a node behaves abnormally, I do not repair it: I destroy it and recreate it.

### Deep-Dive: Immutability and Security
Immutability means that the root filesystem is read-only. There are no package managers like `apt` or `yum`. This drastically reduces the attack surface: even if a malicious actor managed to gain access to a process in the node, they could not install rootkits or modify system binaries. The security quorum of the cluster benefits directly.

## The DHCP Nightmare and the Transition to Terraform

The initial implementation was far from fluid. During the first tests, I let the nodes acquire IP addresses via DHCP. This was a fundamental error that led to a significant technical incident. After a scheduled restart of the Proxmox server, the DHCP server assigned new addresses to the cluster nodes.

The result? The Control Plane became unreachable. `kubectl` could no longer authenticate because the certificates were tied to the old IPs, and the etcd quorum was destroyed. I spent hours attempting to manually patch the nodes with `talosctl patch`, trying to chase the new network topology.

It was here that I realized manual or semi-automated management was not enough. I decided to migrate the entire provisioning to **Terraform**.

### The Solution: Declarative Static Networking
I rewrote the Terraform manifests to statically define every network interface. This ensures that, regardless of restarts or network fluctuations, the "Castle" maintains its shape.

```hcl
# A glimpse of the providers.tf file with the node configuration
resource "proxmox_vm_qemu" "talos_worker" {
  count       = 3
  name        = "worker-${count.index + 1}"
  target_node = "pve"
  clone       = "talos-template"

  # Static network configuration to avoid IP drift
  ipconfig0 = "ip=192.168.1.15${5 + count.index}/24,gw=192.168.1.1"
  
  cores   = 4
  memory  = 8192
  
  # Integration with Talos happens via machine_config
  # generated through the dedicated Talos provider.
}
```

Using Terraform allowed me to map the desired state of the infrastructure. If I want to add a worker, I simply change the `count` from 3 to 4. Terraform will calculate the difference and interact with the Proxmox APIs to clone the VM, assign the correct IP, and inject the Talos configuration.

## Distributed Storage: The Longhorn Challenge

A cluster without persistent storage is just an academic exercise. For the Ephemeral Castle, I needed a storage system that was as resilient as the cluster itself. The choice fell on **Longhorn**.

Longhorn transforms the local disk space of the worker nodes into a distributed and replicated storage pool. However, running Longhorn on an immutable operating system like Talos requires specific precautions. Talos does not include the binaries for iSCSI (needed for mounting volumes) or NBD (Network Block Device) by default.

### Error Analysis: The Mount Problem
Initially, pods failed to transition from the `ContainerCreating` state to `Running`. Checking system logs with `kubectl describe pod`, I noticed a recurring error: `executable file not found in $PATH` referring to `iscsid`. 

On a traditional system, I would have installed `open-iscsi` with a command. On Talos, I had to instruct the system to load the necessary kernel modules via the Talos `machineConfig`, using system extensions.

```yaml
# Extract of the Talos configuration to enable iSCSI
machine:
  install:
    extensions:
      - image: ghcr.io/siderolabs/iscsi-tools:v0.1.4
      - image: ghcr.io/siderolabs/util-linux-tools:v2.39.3
```

This step is fundamental: it transforms the node from a generic entity into a specialized component of the storage cluster. Once configured, Longhorn began replicating data between nodes, ensuring that even in the event of a total loss of a worker, the blog or database volumes remain accessible.

## GitOps: The Beating Heart with Flux CD

The Ephemeral Castle is not configured manually. Once Terraform has created the VMs and Talos has initialized Kubernetes, **Flux CD** comes into play.

Flux is a GitOps operator that keeps the cluster synchronized with a GitHub repository. I created two distinct repositories:
1.  **ephemeral-castle**: Contains the Terraform code and "hardware" configurations (IPs, VM resources).
2.  **tazlab-k8s**: Contains the Kubernetes manifests (Deployment, Service, HelmRelease).

### Why not a single repository?
I decided to separate the infrastructure from the workload. Terraform manages the "iron" (even if virtual), while Flux manages the application ecosystem. This separation allows for the destruction of the entire cluster while keeping the application logic intact. When the new cluster emerges, Flux detects its presence and starts pulling the manifests, recreating the environment exactly as it was before.

### Deep-Dive: The Reconciliation Loop
The key concept of Flux is the *Reconciliation Loop*. Flux constantly monitors the Git repository. If I modify the number of replicas of a microservice in the YAML file on GitHub, Flux detects the "drift" between the current state of the cluster and the desired state in the repository and applies the change in seconds. This eliminates the need for manual commands like `kubectl apply -f`.

## Security and Secrets: SOPS and Git Integration

Versioning infrastructure on GitHub carries a risk: secret leakage. Proxmox passwords, SSH keys, API tokens... none of this should end up in plain text in the repository.

I adopted **SOPS (Secrets Operations)** by encrypting sensitive files with **Age** keys. The resulting files (e.g., `proxmox-secrets.enc.yaml`) are perfectly safe to push to a private repository. Terraform and Flux are configured to decrypt these files "on the fly" during execution, ensuring that credentials never touch the disk in unencrypted format.

```bash
# Example of encrypting a secrets file
sops --encrypt --age $(cat key.txt) secrets.yaml > secrets.enc.yaml
```

## Post-Lab Reflections: What have we learned?

This first stage of the journey has confirmed a fundamental truth of modern DevOps: **automation is painful at the beginning, but liberating later**. 

Configuring static IPs in Terraform was slower than assigning them manually on Proxmox. Configuring SOPS was more complex than using environment variables. However, I now have an infrastructure that I can replicate with the press of a button. The Castle is "Ephemeral" because its physical existence is irrelevant; what matters is the code that defines it.

### Next Steps
The Castle now breathes, but it is naked. In the next chronicles, we will address:
1.  **The Ingress Controller**: Configuring Traefik to manage external traffic and automatic SSL certificate generation with Let's Encrypt.
2.  **The Hugo Blog**: Deploying the site you are currently reading, fully automated via CI/CD.
3.  **To the Clouds**: Replicating this entire architecture on AWS, demonstrating the true portability of the Ephemeral Castle.

The road is still long, but the foundations have been laid in the concrete of code.

---
*End of Technical Chronicle - Stage 1*
