+++
title = "Cloud Free and the Harsh Reality: Lushy Corp's Pivot to Hetzner"
date = "2026-03-30T18:00:00+01:00"
draft = false
description = "Chronicle of a necessary failure: how OCI Always Free's limits led to choosing a stable, versatile, and affordable VPS on Hetzner to host our Vault."
tags = ["Hetzner", "VPS", "OCI", "Vault", "Tailscale", "DevOps", "HomeLab"]
categories = ["Infrastructure", "Security"]
author = "Tazzo"
+++

## The Illusion of "Free" and the Search for Stability

The initial goal was simple and ambitious: a private HashiCorp Vault cluster on Oracle Cloud's "Always Free" resources in Turin. **4 ARM vCPUs, 24 GB of RAM, and 200 GB of storage**, all for free. A paradise for a professional home lab.

After a 24-hour battle, I had to face the harsh reality: when it comes to critical services, "free" can be very expensive in terms of time and reliability.

The name **Lushy Corp** was born from a typo — I was typing "HashiCorp Vault Container" and the AI agent read it as "LushyCorp". Since that moment, it became the codename for our vault.

## The OCI Saga: Tilting at Windmills

### The Capacity Wall

The first hurdle arrived before I could even do anything. The **Ampere** (ARM64) instances in OCI's `eu-turin-1` datacenter are extremely popular: they offer excellent performance in a free tier. The problem is that demand far exceeds supply.

I had to implement an aggressive loop in my provisioning script, a `create.sh` that continuously tried to create instances, often for hours. The `Out of host capacity` message became my constant companion. Oracle simply didn't have resources available exactly when I requested them.

This highlighted a conceptual problem: if I have to "fight" to get a free resource, that time has a cost. And if that time is spent on a 24/7 critical service, the operational risk becomes unacceptable.

### The Architecture Bug: Instances Spinning but Not Booting

After finally "snatching" an Ampere instance, I encountered a more subtle issue. The instance reached the `RUNNING` state without errors, but Talos Linux wouldn't boot. No output on the console, just an instance spinning in a void.

The investigation took hours. Eventually, the root cause emerged: the imported ARM64 image was registered with architecture metadata set to `None` instead of `ARM64`. OCI accepted the instance, but at boot time the UEFI firmware didn't recognize the architecture and silently froze.

The solution was to re-import the image via OCI CLI, explicitly specifying `ARM64`:

```bash
oci compute image import \
  --compartment-id $COMPARTMENT_ID \
  --image-id $IMAGE_ID \
  --source-image-type QCOW2 \
  --launch-mode PARAVIRTUALIZED \
  --architecture ARM64
```

An important lesson: on OCI, the **image metadata** must be correct *at import time*. They cannot be modified later.

### Terragrunt and Orchestration Issues

When Terragrunt started hanging on caching and credential issues, I had to bypass it completely, moving to direct OCI CLI commands. Furthermore, OCI took an anomalous amount of time to assign private IPs to the VNICs, requiring multiple hardware resets to force synchronization.

The prevailing feeling was not satisfaction: it was the realization that I was building on unstable foundations.

## The Fatal Blow: The Shutdown Policy

The decisive moment came when I realized that OCI's "Always Free" policies allow for the shutdown of instances deemed "idle". For a service like Vault, which must be **always available**, this is an unacceptable risk.

Picture the scene: it's night, a Kubernetes application needs to access a secret to rotate a certificate, but the Vault has been shut down by Oracle because it's "idle". The certificate expires, the app errors out, and you are sleeping. It is exactly the kind of silent failure that a secrets management system must prevent at all costs.

I decided that Lushy Corp's operational stability was worth more than a few euros saved.

## The AWS Pivot: The Problem with Spot Instances

Before arriving at Hetzner, I took a detour into the AWS ecosystem. I designed an architecture based on **Fargate + EFS + Tailscale + KMS Auto-Unseal**, intending to keep an estimated cost of around 4€/month.

It wasn't the complexity of the infrastructure that stopped me. On the contrary, configuring that environment was an interesting technical stimulus, a great opportunity to learn and dive deep into advanced AWS components. The real issue, once the math was done, was the trade-off between costs and reliability.

To stay within that low budget, I would have had to use **Fargate Spot** instances. However, Spot instances introduce the exact same problem I was running away from on OCI: if AWS needs computational power, it shuts down your machine. We were back to square one, an unacceptable risk for a Vault.

To have a truly solid architecture working properly (using classic On-Demand instances), the expense would have risen to more than double what was initially budgeted. For a project born to learn, test myself, and test technologies in my home lab (where a Vault cluster is already an "exaggerated" superstructure for the data it holds in itself), it simply felt like an unjustified expense.

## The Final Choice: Hetzner and the Beauty of Simplicity

The choice fell on a **dedicated VPS on Hetzner**. This decision offers the perfect balance for a professional home lab.

**1. Versatility**: A Linux VM is not just for Vault. It can host other microservices, a reverse proxy, monitoring tools. The fixed cost of 4-5€/month gets distributed across multiple services over time.

**2. Operational Simplicity**: With a pure VM, I have complete and direct control over every component. No opaque managed services, just pure Linux system administration.

**3. Predictable Cost**: 4-5€/month guaranteed 24/7. It's the price of peace of mind, without the risks of Spot instances and without billing surprises.

### The Setup: Podman and Native Tailscale

Instead of hyper-packaged solutions, I'm thinking of a more "raw" and educational approach. I will install **Tailscale directly on the operating system** of the machine, ensuring secure connectivity at the host level in a clean way.

As for the containers, I decided to take the opportunity to use **Podman** instead of the classic Docker. Not because Docker isn't good (in fact, Podman won't necessarily give me extra features for this basic use case), but purely for the sake of trying it out and learning to use it in a real context. I will run the Vault container on this Podman layer. Since it's a public VPS, having this infrastructure ready will be handy in the future to easily spin up other services.

## Conclusion: Failing to Build Better

I "nuked" the OCI compartment, deleted the AWS Fargate project, but these were not failures. They were **necessary steps** in a journey that led to a more solid, pragmatic, and mindful architecture.

Every pivot taught me something:

- **OCI**: "Free" has huge hidden costs in terms of reliability and wasted time.
- **AWS Fargate**: "Cheap" serverless architectures via Spot are not suited for critical always-on services for lab infrastructures.
- **Hetzner**: The simplicity of a classic VM is a virtue.

The era of **Lushy Corp** begins now, on a solid Linux foundation, ready to manage secrets.

Next stop: Provisioning.