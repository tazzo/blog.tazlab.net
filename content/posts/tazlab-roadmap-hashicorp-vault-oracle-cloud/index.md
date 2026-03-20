---
title: "TazLab Roadmap: HashiCorp Vault and Oracle Cloud"
date: 2026-03-19T09:00:00+00:00
draft: false
tags: ["Kubernetes", "HashiCorp Vault", "Oracle Cloud", "Tailscale", "Security", "Secrets Management", "Talos OS", "GitOps"]
description: "From Infisical to HashiCorp Vault, through a new cluster on Oracle Cloud and a Tailscale mesh VPN: the TazLab advanced security roadmap."
---

## The Current State: A Solid Cluster, But with an Achilles' Heel

TazLab today is an infrastructure that works. I have a Kubernetes cluster on Proxmox with Talos OS, a GitOps pipeline managed by Flux, metrics collected by Prometheus and visualized in Grafana, and `etcd` encrypted at rest. From the outside, it's a setup that inspires confidence.

But looking from the inside, there is a problem that keeps me up at night.

Secret management is handled by **Infisical** on its free plan. It works: it syncs secrets to Kubernetes via the External Secrets Operator, pods use them, life goes on. However, Infisical's free plan imposes a limit I can no longer accept: **it does not support automatic secret rotation**.

Secrets don't rotate. Database credentials are static. If a key is compromised, the response is manual.

---

## The "Why": When AI Exposes the Problem

The turning point didn't come from an incident, but from a reflection. I started using AI tools regularly in my workflow — Gemini CLI, Cloud Code, and other agents with access to the shell and filesystem. These tools are powerful, but they have an annoying habit: logging everything. Prompts, output, session context. Potentially, even fragments of secrets that appear in command responses.

At that point I realized that my secret security model was fragile by design. Not because Infisical does a bad job, but because **static and long-lived secrets** are inherently vulnerable. A secret that never rotates is a ticking time bomb.

The professional answer to this problem has a precise name: **dynamic secrets** and **automatic key rotation**.

---

## The Target Architecture: Vault as the Center of Gravity

The choice fell on **HashiCorp Vault Community Edition**, installed as a pod inside the cluster itself. It's a deliberately ambitious choice — probably overkill for a home lab — but it's exactly the kind of overkill I want. Vault is the de facto industry standard for secret management in enterprise environments. Learning it here, in my lab, means bringing real skills to the real world.

The model I want to implement works like this:

1. **Vault** generates secrets dynamically and manages their expiration and rotation.
2. **External Secrets Operator** intercepts changes and syncs the new secrets to Kubernetes as native `Secret` objects.
3. **Reloader** detects changes in Secrets and ConfigMaps and automatically triggers a reload of the affected pods.

The result: no static credentials, no manual intervention, no indefinite exposure window.

### The New Node: Oracle Cloud Always Free

To host Vault robustly and separately from the main infrastructure, I am adding a second cluster to TazLab. The chosen platform is **Oracle Cloud Infrastructure**, which offers a generous and stable Always Free tier:

- **Control Plane**: VM with 8 GB of RAM
- **Worker**: VM with 16 GB of RAM
- **OS**: Talos OS, same as the local cluster — operational consistency first

This Oracle cluster will become TazLab's security node: it will host Vault, be reachable via VPN, and will not depend on the physical hardware at home.

### Tailscale: The Glue That Holds Everything Together

The most critical piece of this architecture is not Vault — it's the **mesh VPN**.

To understand why, you need to understand how Vault's dynamic secrets for PostgreSQL work. When an application requests database credentials, Vault doesn't return a password stored somewhere: **it creates a PostgreSQL user on the spot**, with a defined expiration, and deletes it when the lease expires. To do this, Vault needs direct access to the database with administrator privileges.

If Vault is on Oracle Cloud and PostgreSQL is on the local Proxmox cluster, a secure and permanent channel between the two is required. This is where **Tailscale** comes in: a modern, zero-config mesh VPN solution built on WireGuard. Every node in the network — local cluster, Oracle cluster, workstation — becomes part of the same private network, regardless of its physical location.

The VPN is not an implementation detail. It is the precondition that makes the entire architecture possible.

---

## Phased Approach: The Steps Along the Way

The work is structured in sequential phases, each of which must be stable before proceeding to the next.

**Phase 1 — Mesh VPN**
Configure Tailscale between the local Proxmox cluster and the new Oracle Cloud cluster. Verify bidirectional connectivity. No Vault, no dynamic secrets until this foundation is solid.

**Phase 2 — New Oracle Cluster**
Provisioning the Talos cluster on Oracle Cloud via Terragrunt. Integration with the existing GitOps repo. The cluster must be managed by Flux exactly like the local cluster.

**Phase 3 — HashiCorp Vault**
Deploy Vault on the Oracle cluster. Configure the PKI engine, the PostgreSQL secrets engine, and access policies. Progressive migration of secrets from Infisical to Vault.

**Phase 4 — ESO + Reloader Integration**
Configure External Secrets Operator on both clusters to read from Vault. Integrate Reloader for automatic pod reloading. Test the full cycle: rotation → sync → reload.

---

## Future Outlook: The Ephemeral Cluster Becomes Reality

This roadmap is not just a list of tools to install. It is the step that transforms TazLab from a solid infrastructure to a **truly ephemeral** one.

The ultimate goal is a cluster you can destroy and recreate at will, on any cloud provider, at any time. The bootstrap process will be fully automated: the new cluster connects to the Tailscale mesh, obtains certificates automatically, reaches Vault and retrieves its secrets, restores data from the S3 bucket. No manual intervention.

AWS today, Google Cloud tomorrow, Oracle the day after. The platform becomes irrelevant.

This is "Terraforming the Cloud" in its most complete form: not terraforming a single cloud, but making your own ecosystem independent of all of them.

TazLab has no fixed address. It only has a starting point.
