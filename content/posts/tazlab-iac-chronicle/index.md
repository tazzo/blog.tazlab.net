+++
title = "From Craftsmanship to Infrastructure: Chronicle of the Introduction of Terraform in Tazlab"
date = 2026-01-25T01:29:21+01:00
draft = false
description = "Chronicle of the introduction of Terraform in Tazlab for managing the Talos cluster on Proxmox."
tags = ["terraform", "proxmox", "iac", "kubernetes", "talos"]
author = "Tazzo"
+++


## Introduction: The Species Jump of the Homelab
Managing a Kubernetes cluster in a home lab is often an act of love, a mixture of hand-written YAMLs and small manual adjustments via GUI. However, there comes a time when complexity exceeds the memory capacity of its administrator. In **Tazlab**, that moment arrived today. The goal was clear: to stop treating cluster nodes as "pets" — each with its own name and history — and start treating them as "cattle" — fungible, identical, and reproducible resources.

I decided to introduce **Terraform** to manage the lifecycle of the **Talos Linux** cluster hosted on **Proxmox**. This was not a triumphal march, but an honest chronicle of permission errors, virtual hardware conflicts, and cryptographic decoding issues. Here is how I transformed Tazlab into a true infrastructure defined by code.

---

## Phase 1: Tool Selection and the Silent Architecture

Before writing a single line of HCL (HashiCorp Configuration Language) code, I had to face the choice of **Providers**. In the Proxmox world, two main currents exist: the legacy provider by Telmate and the modern **bpg** provider.

I decided to opt for **bpg/proxmox**. The reason lies in its ability to manage Proxmox objects with superior granularity, especially regarding snippets and SDN configuration. Telmate, although historical, suffers from chronic instability in detecting drift (configuration drift) on network interfaces in Proxmox 8.x versions. In a professional IaC (Infrastructure as Code) architecture, drift detection must be precise: Terraform must not propose changes if nothing has changed in reality.

### The Importance of etcd Quorum
Another critical decision concerned the **Control Plane**. I initially hypothesized the creation of additional control plane nodes, but I had to reflect on the concept of **Quorum**. In a distributed system based on etcd like Kubernetes, quorum requires an absolute majority ($n/2 + 1$). Moving from one to two control plane nodes would paradoxically reduce reliability: if one of the two fell, the cluster would remain blocked. I therefore decided to maintain a single control plane node for now, concentrating automation on the horizontal scalability of worker nodes.

---

## Phase 2: Permissions Setup - The First Barrier

Automation requires an identity. One cannot (and must not) use the `root@pam` user for Terraform. I had to create a dedicated user and a role with the minimum necessary privileges. This step revealed one of the first pitfalls: official documentation often omits granular permissions that become critical during execution.

I had to modify the `TerraformAdmin` role on Proxmox several times. The most subtle error was related to the **QEMU Guest Agent**. Without the `VM.GuestAgent.Audit` permission, Terraform could not query Proxmox to know the IP address assigned by DHCP, entering an infinite waiting loop.

### Proxmox Setup Code (Shell):
```bash
# Creazione del ruolo professionale con permessi granulari
pveum role add TerraformAdmin -privs "Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Pool.Audit Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt SDN.Use VM.GuestAgent.Audit VM.GuestAgent.Unrestricted"

# Creazione utente e generazione token
pveum user add terraform-user@pve
pveum aclmod / -user terraform-user@pve -role TerraformAdmin
pveum user token add terraform-user@pve terraform-token --privsep=0
```

---

## Phase 3: Scaffolding and the "Secrets Debt"

I structured the Terraform project modularly to separate responsibilities: `versions.tf` for plugins, `variables.tf` for the data schema, `data.tf` for reading secrets, and `main.tf` for business logic.

### SOPS Integration
Tazlab uses **SOPS** with **Age** encryption. This was the most interesting challenge. Terraform must decrypt Talos YAML files to extract the Certification Authority (CA) and join tokens. I encountered a frustrating problem: certificates saved in SOPS were **Base64** encoded and often contained invisible newline characters (`\n`) that crashed Talos validation.

I decided to solve the problem "at the source" in the `data.tf` file, implementing an aggressive string cleaning logic. Without this transformation, the worker node received a corrupted certificate and refused to join the cluster, remaining in a perennial "Maintenance Mode" state.

### `terraform/data.tf`:
```hcl
# Decriptazione dei segreti Proxmox e Talos tramite SOPS
data "sops_file" "proxmox_secrets" {
  source_file = "proxmox-secrets.enc.yaml"
}

data "sops_file" "controlplane_secrets" {
  source_file = "../talos/controlplane-reference.yaml"
}

data "sops_file" "worker_secrets" {
  source_file = "../talos/worker-reference.yaml"
}

locals {
  # Gestione multi-documento e pulizia Base64
  parts = split("---", data.sops_file.controlplane_secrets.raw)
  cp_raw = yamldecode(local.parts[0] == "" ? local.parts[1] : local.parts[0])

  cluster_secrets = {
    token  = trimspace(local.cp_raw.machine.token)
    # Rimoziome newline e decodifica PEM
    ca_crt_b64 = replace(replace(local.cp_raw.machine.ca.crt, "\n", ""), " ", "")
    ca_key_b64 = replace(replace(local.cp_raw.machine.ca.key, "\n", ""), " ", "")
    ca_crt     = base64decode(local.proxmox_token_id) # Logica di decode centralizzata
  }
}
```

---

## Phase 4: The Fight against Virtual Hardware

Provisioning a Talos VM on Proxmox does not follow standard Cloud-Init rules. Talos expects the configuration to be "pushed" via its APIs on port 50000.

I encountered a critical hardware conflict: Proxmox, by default, assigns the Cloud-Init drive to the **`ide2`** interface. However, I was also using the `ide2` interface to mount the Talos ISO. This silent conflict prevented Talos from reading the static network configuration, forcing the VM to request an IP via DHCP (often outside the desired range) or, worse, to have no connectivity at all.

I decided to move the ISO to the **`ide0`** interface, freeing port `ide2` for the initialization bus. This move, apparently trivial, was the key to obtaining deterministic static IPs on an immutable system.

### `terraform/main.tf` (Excerpt):
```hcl
resource "proxmox_virtual_environment_vm" "worker_nodes" {
  for_each = var.worker_nodes
  name     = each.key
  node_name = var.proxmox_node

  # Allineamento hardware con i nodi fisici esistenti
  scsi_hardware = "virtio-scsi-single"
  
  agent {
    enabled = true # Cruciale per la visibilità dell'IP nella GUI
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk_size
    iothread     = true
  }

  # Disco dedicato a Longhorn: lo storage distribuito richiede dischi raw
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi1"
    size         = each.value.data_disk
    iothread     = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip_address}/24"
        gateway = var.gateway
      }
    }
  }

  cdrom {
    enabled   = true
    file_id   = "local:iso/nocloud-amd64.iso" # ISO Factory personalizzata
    interface = "ide0" # Risoluzione del conflitto IDE
  }
}
```

---

## Phase 5: The "Technical Debt" and the Image Factory

During the creation of the first worker (`worker-new-01`), I noticed that **Longhorn** pods remained in `CrashLoopBackOff`. Analysis of the logs with `kubectl logs` revealed the absence of the `iscsiadm` binary inside the operating system.

I realized that Talos Linux, in its standard version, is too minimal for Longhorn. The existing cluster nodes were using an image generated through the **Talos Image Factory** that included the `iscsi-tools` extension and the `qemu-guest-agent`.

Instead of destroying the node, I decided to perform an **In-Place Upgrade** via API:
```bash
talosctl upgrade --image factory.talos.dev/installer/e187c9b90f773cd8c84e5a3265c5554ee787b2fe67b508d9f955e90e7ae8c96c:v1.12.0
```
This "settled the technical debt". I then immediately updated the Terraform code to point to this factory image for all future nodes, ensuring cluster homogeneity.

---

## Phase 6: Hugo and Cloud-Native Scalability

Once the node fleet was stabilized, I tested scalability with the **Hugo** blog application. The blog used a `PersistentVolumeClaim` (PVC) in `ReadWriteOnce` (RWO) mode. Scaling to 3 replicas, I saw the dreaded **`Multi-Attach error`** appear.

RWO allows mounting a disk on only one node at a time. Kubernetes, trying to distribute pods across my 3 new workers to ensure high reliability, clashed with the physical limit of the volume.

I decided to implement a **Shared-Nothing** approach using an **`emptyDir`**.
*   **What is an `emptyDir`?** It is a temporary volume that lives as long as the pod is active, created on the node's local disk.
*   **Why for Hugo?** Hugo is a static site generator. Its source data is downloaded from Git via a sidecar container (`git-sync`). A centralized persistent disk is not needed if each pod can download its local copy in a few seconds.

This change allowed the blog to scale to 3 replicas instantly, each residing on a different worker, without any storage conflict.

---

## Phase 7: Final Security with Terraform Cloud

The last act was solving the problem of the `terraform.tfstate` file. As I explained during the process, the Terraform state contains all decrypted secrets in clear text. Keeping this file on the hard drive is an unacceptable risk.

I decided to migrate the state to **HCP Terraform (Terraform Cloud)**, but with a specific configuration: **Local Execution Mode**.
In this mode, Terraform executes commands on my PC (thus being able to reach the local Proxmox IP and use my Age key), but sends the encrypted state to HashiCorp's secure servers. I removed every local trace of `.tfstate`, eliminating the possibility of credential theft from the file system.

### `terraform/versions.tf` (Cloud Configuration):
```hcl
terraform {
  required_version = ">= 1.5.0"

  cloud {
    organization = "tazlab"
    workspaces {
      name = "tazlab-k8s"
    }
  }
  # ... provider ...
}
```

---

## Post-Lab Reflections: What have we learned?

The introduction of Terraform in Tazlab was not just the addition of a tool, but a change of mentality. I learned that:
1.  **Abstraction has a cost**: Terraform simplifies creation but requires deep knowledge of the underlying APIs (Proxmox in this case).
2.  **Secrets are alive**: Managing secrets does not just mean hiding them, but knowing how to transform them (Base64 vs PEM) to make them digestible for machines.
3.  **Architecture beats persistence**: We often try to solve storage problems with complex volumes when a simple `emptyDir` and a good synchronization process are more effective.

Today Tazlab has 3 new workers. Tomorrow it could have 30. I just need to add a line of text. This is the true freedom of Infrastructure as Code.

