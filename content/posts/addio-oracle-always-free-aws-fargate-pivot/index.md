+++
title = "Goodbye Oracle Always Free: Why Lushy Corp is Moving to AWS Fargate"
date = 2026-03-30T18:15:22+01:00
draft = false
description = "Technical chronicle of a necessary failure: how OCI Always Free limitations pushed us toward a serverless and resilient Vault architecture on AWS Fargate."
tags = ["AWS", "Fargate", "OCI", "Vault", "Tailscale", "DevOps", "Serverless"]
author = "Tazzo"
+++

## The Illusion of \"Free\" and the Search for Resilience

The initial goal was noble, almost romantic: build an enterprise-grade, totally private **HashiCorp Vault** cluster, leveraging the generous \"Always Free\" resources of **Oracle Cloud Infrastructure (OCI)** in Turin. I had planned everything: Ampere ARM64 instances with 4 cores and 24GB of RAM, **Talos Linux** as the immutable operating system, and **Tailscale** for zero-trust connectivity without public ingress.

On paper, it was the perfect plan to host what, in this work session, was accidentally named **Lushy Corp**.

Before diving into the technical details, let me explain this name. **Lushy Corp** is not a new tech giant, but the nickname born from a typo while interacting with the AI agent. I was trying to write \"HashiCorp Vault Container\", and \"LushyCorp\" came out. From that moment on, TazLab's secret vault, the one that will manage key rotation and cluster security, officially became the **Lushy Corp** project.

But a cool brand isn't enough to run an infrastructure. After 24 hours in the technical \"trenches\" on OCI, I had to admit that the illusion of zero cost clashed with a reality too precarious to host production secrets.

## The Turin Trenches: Loops, Capacity, and Ghost Metadata

### The War for Ampere Capacity
The first wall of resistance was OCI's infamous `Out of host capacity` in the `eu-turin-1` region. Oracle's ARM64 resources are a rare commodity. I had to implement an aggressive provisioning loop, capable of attempting instance creation every 30 seconds, hoping to \"capture\" a core the exact moment it was freed.

```bash
# The \"guerrilla\" script to capture Ampere cores
until oci compute instance launch --compartment-id "$COMP_ID" \
    --availability-domain "$AD" --display-name "tazlab-vault-cp-01" \
    --image-id "$IMAGE_ID" --shape "VM.Standard.A1.Flex" \
    --shape-config '{"ocpus": 1, "memoryInGBs": 4}' \
    --subnet-id "$SUBNET_ID" --private-ip "10.0.1.100" \
    --metadata "{\"user_data\": \"$(base64 -w0 < cp-config.yaml)\"}" 2>/dev/null; do
    echo "⏳ OCI: Out of capacity. Retrying..."
    sleep 30
done
```

After hundreds of attempts, the instances finally reached the `RUNNING` state. But here began the real descent into the troubleshooting abyss.

### The \"None\" Architecture Bug
The instances were on, but the Talos operating system showed no signs of life. No logs on the serial console, no registration on the Tailscale mesh. After a forensic analysis of the image metadata via OCI CLI, I discovered a critical error: the custom ARM64 image had been imported with the `Architecture` field set to `None`.

OCI saw the instance as active, but the UEFI bootloader failed instantly because it was trying to boot ARM code as if it were x86. It required a **Nuclear Wipe** of the compartment and a manual re-import of the image forcing the correct metadata.

### Tailscale Key \"Burn\"
Another insidious problem was the consumption of Tailscale authentication keys. Using single-use keys, every forced reboot to unblock the network \"burned\" the key. At the next boot, Talos would try to register but was rejected. The solution was switching to **Reusable** keys, ensuring that nodes could rejoin the mesh even after a hardware reset.

## The Breaking Point: Why Always Free Isn't for Us

Despite managing to obtain the VMs and fixing the boot bugs, an inescapable architectural truth emerged: **Lushy Corp's secrets cannot stand on a foundation of sand.**

Oracle's policy for Always Free instances includes shutting down (or reclaiming) resources in case of low CPU or memory utilization. For a service like Vault, which for most of the time sits silent waiting to serve a key, this is a catastrophic risk. If the Vault cluster is shut down, dependent services lose access to secrets, causing critical downtime that would require manual unseal intervention.

I decided that Lushy Corp's operational stability is worth more than saving a few euros a month.

## The New Course: AWS Fargate and the Serverless Fortress

I decided to pivot toward a **Serverless architecture on AWS**, using **ECS Fargate**. This choice represents a fundamental jump in quality for several reasons:

1.  **Zero OS Management**: I no longer have to worry about updating the kernel, managing UEFI firmware, or fighting with corrupted bootloaders. AWS manages the underlying infrastructure; I only manage the Vault container.
2.  **Guaranteed Reliability**: Fargate does not shut down containers for inactivity. The service is always \"warm\" and ready to respond.
3.  **Persistence via EFS**: We will use **Amazon EFS (Elastic File System)** as the storage backend for Vault Raft. This ensures that data is replicated across multiple Availability Zones and survives even if the Fargate Task is recreated.
4.  **Zero Ingress via Tailscale**: The Fargate Task will host two containers in the same pod: Vault and Tailscale (sidecar pattern). Tailscale will run in `userspace-networking` mode, acting as a private proxy. Vault will be exposed only within the Tailnet, making it totally invisible from the internet despite not having a dedicated NAT Gateway.

### Cost Optimization
We studied a workaround to avoid the $32/month \"tax\" of AWS managed NAT Gateway. By placing the Fargate Task in a Public Subnet with a hardened Security Group (Ingress: 0), we get the internet access needed for Tailscale and ECR at almost zero cost, paying only the small fee for the ephemeral public IP.

## Conclusion: Failing Fast to Build Better

This work session ends with an apparent failure: the OCI cluster was \"nuclearized\" and removed. In reality, it was a strategic success. We identified the limits of a platform, learned from metadata bugs, and charted a course toward a solution that is not only more stable but also more professional.

The era of **Lushy Corp** begins now, not as a zero-cost experiment, but as a serious, serverless, and ready-to-scale infrastructure.

Next stop: Terraform on AWS.
