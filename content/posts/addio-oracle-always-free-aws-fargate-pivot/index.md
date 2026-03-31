+++
title = "Goodbye Oracle Always Free: Why Lushy Corp Chooses the Simplicity of a VPS"
date = 2026-03-31T10:18:20+01:00
draft = false
description = "Technical chronicle of a necessary failure: how OCI Always Free limitations pushed us toward the versatility and stability of a dedicated VPS on Hetzner."
tags = ["Hetzner", "VPS", "OCI", "Vault", "Tailscale", "DevOps", "Docker"]
author = "Tazzo"
+++

## The Illusion of \"Free\" and the Search for Resilience

The initial goal was noble, almost romantic: build an enterprise-grade, totally private **HashiCorp Vault** cluster, leveraging the generous \"Always Free\" resources of **Oracle Cloud Infrastructure (OCI)** in Turin. I had planned everything: Ampere ARM64 instances with 4 cores and 24GB of RAM, **Talos Linux** as the immutable operating system, and **Tailscale** for zero-trust connectivity without public ingress.

On paper, it was the perfect plan to host what, in this work session, was accidentally named **Lushy Corp**.

Before diving into the technical details, let me explain this name. **Lushy Corp** is not a new tech giant, but the nickname born from a typo while interacting with the AI agent. I was trying to write \"HashiCorp Vault Container\", and \"LushyCorp\" came out. From that moment on, TazLab's secret vault, the one that will manage key rotation and cluster security, officially became the **Lushy Corp** project.

## The Turin Trenches: Loops and Ghost Metadata

The war for Ampere capacity in `eu-turin-1` and the discovery of images imported with `Architecture: None` were the final nails in the coffin of the OCI dream. After 24 hours of troubleshooting, I had to admit that production secrets cannot stand on foundations of sand.

Oracle's policy for Always Free instances includes shutting down resources in case of low utilization. For Vault, this is a catastrophic risk.

## The New Course: The Versatile Simplicity of a Dedicated VPS

I decided to pivot toward a more classical, pragmatic, and versatile solution: a **dedicated VPS on Hetzner**. While we initially considered AWS Fargate, the flexibility of a real Linux virtual machine won for several reasons:

1.  **Lab Versatility**: A VPS with Debian or Ubuntu isn't just for Vault. We can use it to host other small services or TazLab utilities, maximizing the monthly cost.
2.  **Native Tailscale**: Instead of fighting with sidecars and userspace proxies, we install Tailscale as a system service. This gives us a real `tun` interface and standard networking, which is much more robust and easier to debug.
3.  **Standard Runtime (Docker/Podman)**: We run Vault as a container managed by Docker or Podman. It is a battle-tested setup, easy to update and migrate.
4.  **Low and Predictable Cost**: For about €4-5/month, Hetzner guarantees resources that will never be arbitrarily shut down. It's the price of peace of mind for Lushy Corp's security.

## Conclusion: Failing Fast to Build Better

The OCI cluster has been \"nuclearized\". The era of **Lushy Corp** begins now, on a solid Linux foundation, ready to serve secrets 24/7.

Next stop: Provisioning on Hetzner.
