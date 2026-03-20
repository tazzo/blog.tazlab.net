+++
title = "Terraforming the Cloud: My First IaC on OCI"
date = 2026-03-19T05:00:00Z
draft = false
description = "A detailed technical chronicle of provisioning a Kubernetes cluster on Oracle Cloud Infrastructure for the first time using Terraform, Terragrunt, and Talos Linux. From untested scaffolding challenges to managing custom ARM64 images."
tags = ["terraform", "terragrunt", "oracle-cloud", "talos-linux", "kubernetes", "iac", "devops", "arm64", "infrastructure-as-code"]
author = "Tazzo"
+++

# Terraforming the Cloud: My First IaC on OCI

## Introduction: When Infrastructure Becomes Real

For years I have read about "Infrastructure as Code" (IaC). I studied the principles, watched tutorials, and even implemented local solutions that approached the concept. But there is a fundamental difference between defining a virtual machine on your own Proxmox server in the basement and defining a complete infrastructure on a public cloud provider like Oracle Cloud Infrastructure (OCI). The former is a controlled exercise; the latter is reality.

Today I bridged that gap. The goal was not trivial: I didn't want a "Hello World" with a single Linux instance. I wanted to replicate the robust and ephemeral architecture of my local cluster (`tazlab-k8s`) on OCI, leveraging the **Always Free** tier and the **ARM64 (Ampere A1)** architecture to build the foundation of the new `tazlab-vault` cluster. This cluster will eventually host an enterprise installation of HashiCorp Vault, so the "seriousness" of the project demanded absolute technical rigor from day one.

This is not a story of immediate success. It is the chronicle of an afternoon spent battling untested scaffolding, peculiarities of cloud images, and the paradox of TLS certificates in NAT environments. It is the story of how two virtual machines powering on can represent a significant technical victory.

## 1. Context and Technology Choice

Why OCI? And why Terraform?

The choice of Oracle Cloud is purely pragmatic: their **Always Free** plan offers incredibly generous ARM64 resources (4 OCPUs and 24 GB of RAM), perfect for a two-node Kubernetes cluster (Control Plane + Worker) with no recurring costs.

The technology stack choice follows the philosophy of **Ephemeral Castle**, the framework I developed internally:
*   **Terraform**: For provisioning base resources (VCN, Subnet, Instances).
*   **Terragrunt**: To keep code DRY and manage dependencies between layers (network vs compute).
*   **Talos Linux**: An immutable, minimal, and secure operating system for Kubernetes. Talos has no SSH, no shell, and is managed entirely via API. This forces a pure IaC approach: you cannot "ssh in and fix" a misconfiguration; you must destroy and recreate.

I had prepared an initial scaffolding of Terraform files a week ago, but it had never been executed ("roughed out" but untested). Today was the day of reckoning.

## 2. Phase 1: SDD and Account Preparation

Before writing a single line of code or running a command, I activated my **Spec-Driven Development (SDD)** process. Instead of diving headfirst into execution, I defined four artifacts:
1.  **Constitution**: Immutable rules (no secrets in code, mandatory logging, defined stack).
2.  **Spec**: What do we need to build today? (OCI Account, CLI, VMs, Lifecycle scripts).
3.  **Plan**: How do we do it? (Custom image import, module fixes, end-to-end tests).
4.  **Tasks**: 28 micro-tasks to track progress.

This approach, which might seem bureaucratic for a personal project, proved to be a lifesaver when technical complexity exploded in later phases.

### First Contact with OCI
The OCI account was empty. Zero. I had to navigate the console to create the first **Compartment** (`tazlab-vault`), generate API Keys for programmatic access, and configure the OCI CLI on my workstation.

A critical detail was determining the correct Availability Domain (AD). Unlike AWS or GCP which use zones like `eu-central-1a`, OCI uses tenancy-specific identifiers, such as `GRGU:EU-TURIN-1-AD-1`. Hardcoding these values is a mistake; I had to extract them dynamically or save them as secrets in my local vault (managed by Infisical).

## 3. The Talos Image Dilemma

Here I encountered the first real architectural obstacle. My original scaffolding planned to use a standard **Oracle Linux 8** image and then install Talos on top of it using a `cloud-init` script.

On paper, it works. In practice, it is fragile. It turns an atomic operation (OS boot) into a two-stage process prone to network and dependency errors. Furthermore, the `cloud-init` template I had written was just a non-functional placeholder.

**The Decision**: I decided to abandon the hybrid approach and use a **native Talos** image.
Talos provides an "Image Factory" that allows generating custom disk images. I used the same schematic ID as my local cluster (`e187c9b9...`), which includes specific kernel modules (`iscsi_tcp`, `nbd`) for Longhorn distributed storage support.

### The Import Odyssey
Importing a custom image into OCI is not as trivial as pasting a URL.
1.  **Attempt 1**: Pasting the Factory URL into the OCI console.
    *   *Result*: Error. OCI only accepts URLs from its own Object Storage.
2.  **Attempt 2**: Downloading the image, uploading it to an OCI Bucket, importing.
    *   *Result*: Error `Shape VM.Standard.A1.Flex is not valid for image`. OCI detected the image as x86 because I hadn't specified the architecture. The web console did not allow selecting "ARM64" for custom images imported this way.

**The Solution (The Hard Way)**:
I had to follow the official Talos "Bring Your Own Image" procedure for Oracle Cloud, which is surprisingly manual:
1.  Download the raw compressed image (`.raw.xz`).
2.  Decompress it and convert it to QCOW2 format (`qemu-img convert`).
3.  Create a specific `image_metadata.json` file to tell OCI "Hey, this is a UEFI ARM64 image compatible with VM.Standard.A1.Flex".
4.  Package everything into an `.oci` archive (tarball of qcow2 + json).
5.  Upload this 90MB package to the Bucket and import from there.

Only then did OCI recognize the image as valid for Ampere A1 instances. It was a brutal reminder that the cloud is not magic; it's just someone else's computer with very strict rules.

## 4. Terraforming: Debugging the Scaffolding

With the image ready, I ran `terragrunt plan`. The result was a wall of red errors. The code written a week ago and never tested was showing all its limitations.

### 1. Non-Existent Functions
I had used `get_terragrunt_config()` in child files, a function that does not exist. Terragrunt requires including the root configuration and then reading values via `read_terragrunt_config()`. I had to rewrite the variable passing logic between the `engine` (network) and `platform` (compute) layers.

### 2. Provider Conflicts
Each module declared its own `required_providers`, but the root file also generated a `versions.tf`. Result: Terraform panicked due to duplicate definitions. I had to clean up the modules, letting Terragrunt inject the correct dependencies.

### 3. The "Tag Tax"
OCI is picky about tags. My code used `tags = { ... }`, but the OCI provider distinguishes between `freeform_tags` (free key-value) and `defined_tags` (enterprise taxonomies). I had to refactor every single resource to use `freeform_tags`. Additionally, I discovered that tags are case-insensitive in keys, causing merge conflicts when I tried to overwrite `Layer` with `layer`.

### 4. DNS Label Limits
A trivial but annoying error: `dns_label` for subnets has a 15-character limit. My string `tazlab-vault-public-subnet` generated `tazlabvaultpublicsubnet` (23 characters), blocking VCN provisioning. A simple `substr()` solved it, but it reminded me to always check provider limits.

After two hours of *fix-plan-repeat* cycles, I finally saw the most beautiful message in the world:
`Plan: 12 to add, 0 to change, 0 to destroy.`

## 5. "They're Alive!" (and the hidden network problem)

I launched the `create.sh` script. Terraform created the VCN, subnets, Security Lists, and finally the two Compute instances.
In less than 3 minutes, I had two public IPs.

But the cluster was not responding. The `talosctl version` command timed out.

**The Investigation**:
I used `nc` (netcat) to test port 50000 (Talos API). `Connection refused`.
It was strange. My Network Security Groups (NSG) explicitly allowed traffic on port 50000.
I dug into the VCN configuration and found the culprit: the **Default Security List**.
In OCI, every subnet has a default Security List that is applied *in addition* to NSGs. This list only allowed SSH (port 22). Even though my NSG said "allow everything", the Security List said "block everything except SSH". It's a "defense in depth" security model that caught me by surprise.

I opened the Security List and the situation changed instantly: `Connection refused` became `tls: certificate required`. The server was responding!

## 6. The TLS Paradox and Machine Configuration

At this point, the machines were on, Talos was started, but I couldn't bootstrap the cluster. Why?

Because Talos, being secure by-default, uses mTLS (Mutual TLS) for every communication.
The server certificate is generated at first boot based on the machine configuration. The configuration, generated by Terraform, set the `cluster_endpoint` to the VM's private IP address (`10.0.1.100`), the only one known at `plan` time.

I, however, was trying to connect from the outside via the public IP (`92.x.x.x`).
Result: The `talosctl` client connected to the public IP, the server presented a certificate valid only for `10.0.1.100`, and the client rejected the connection due to a name mismatch.

**The Dead End**:
*   I couldn't regenerate the certificate without accessing the machine.
*   I couldn't access the machine without a valid certificate.
*   I couldn't use the private IP because I don't have a site-to-site VPN with OCI (yet).

I attempted to use Reserved Public IPs, injecting them into the configuration before instance creation. I modified Terraform to add these IPs to the certificate's `certSANs` (Subject Alternative Names).
Unfortunately, Terraform on OCI does not easily allow assigning a reserved public IP *during* instance creation in a single atomic step; it requires a separate resource. The instances were born with ephemeral IPs different from the ones I had put in the certificate anyway.

## Conclusions: A Partial Success is Still a Success

At the end of the session, I had to accept a partial victory.
The machines are up. Talos is installed and configured. The infrastructure is defined as code. The `destroy.sh` script, which I had to rewrite to correctly handle the cleanup of orphaned resources (terminated instances keeping boot disks occupied), works perfectly, allowing me to zero out costs with one command.

I achieved the goal of "Terraforming": I transformed an intention (a cluster) into reality (cloud resources) using only code.
The TLS bootstrap problem is a classic "Day 2" problem anticipated to "Day 0". The solution for Phase 2 is clear: correctly associate Reserved IPs to network interfaces (VNIC) or establish a secure tunnel to operate on the private IP.

But for today, seeing those two `RUNNING` lines in the Oracle console, knowing I didn't click any button to create them, is an immense satisfaction. It is the confirmation that theoretical study has transformed into practical competence. The infrastructure, finally, has become real.
