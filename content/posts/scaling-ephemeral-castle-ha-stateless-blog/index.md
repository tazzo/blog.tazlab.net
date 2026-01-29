---
title: "Rise of the Fortress: High Availability, Immutability, and the Birth of a Serious Cluster"
date: 2026-01-31T07:00:00+01:00
draft: false
tags: ["kubernetes", "ha", "gitops", "terraform", "traefik", "infisical", "nginx", "docker", "devops"]
categories: ["Infrastructure", "Architecture"]
author: "Taz"
description: "Technical chronicle of the Ephemeral Castle upgrade: evolution towards a High Availability cluster (3 CP, 2 Worker), migration of the blog to a stateless architecture, and implementation of an advanced GitOps workflow."
---

# Rise of the Fortress: High Availability, Immutability, and the Birth of a Serious Cluster

The journey of building the **Ephemeral Castle** has reached a critical threshold. Until now, the infrastructure had been an experimental laboratory: a single Control Plane, a single Worker, a functional but fragile shell. In systems engineering, a cluster with a single point of failure is not a cluster; it is just a scheduled delay towards disaster.

In this technical chronicle, I document the transformation of the Castle into a true **High Availability (HA)** fortress. I decided to scale the architecture to 3 Control Plane nodes and 2 Workers, establishing the minimum requirement to guarantee control plane resilience and workload continuity. Simultaneously, I faced the migration of the first \"real\" application: this blog, which moved from a dynamic and unstable setup to a **stateless and immutable** architecture, laying the foundations for a professional-grade CI/CD pipeline.

---

## Phase 1: Engineering High Availability (HA)

The first decision of the day was radical: wipe the existing setup to give birth to an infrastructure capable of withstanding the loss of an entire node without service interruption.

### The Reasoning: Why 3 Control Planes?
In a Kubernetes cluster, the brain is represented by **etcd**, the distributed database that stores the state of every resource. etcd uses the **Raft** consensus algorithm to ensure that all nodes agree on the data.

I chose the 3-node configuration for a purely mathematical reason related to the concept of **Quorum**. The quorum is the minimum number of nodes that must be online for the cluster to make decisions. The formula is `(n/2) + 1`.
*   With 1 node, the quorum is 1 (no fault tolerance).
*   With 2 nodes, the quorum is 2 (if one dies, the cluster freezes).
*   With 3 nodes, the quorum is 2. This means I can lose an entire node and the Castle will continue to function perfectly.

Moving to 3 nodes transforms the cluster from a toy into a production platform.

### Proxmox Infrastructure Details
I configured Terraform to manage 5 virtual machines on Proxmox:
*   **VIP (Virtual IP)**: `192.168.1.210` - The single entry point for the Kubernetes API.
*   **CP-01, 02, 03**: IP `.211, .212, .213` - The distributed brain.
*   **Worker-01, 02**: IP `.214, .215` - The operational arms where Pods run.

---

## Phase 2: The Quorum Struggle and the Fight Against Ghosts

The implementation of High Availability proved more complex than expected due to a phenomenon I dubbed \"ghost identity conflict.\"

### Error Analysis: etcd at a Standstill
After launching the provisioning, the nodes appeared on Proxmox, but the cluster failed to form. Monitoring the status with `talosctl service etcd`, I saw the services stuck in the `Preparing` state.

Investigation via `talosctl get members` revealed a chaotic situation: new nodes were trying to communicate but saw duplicate identities associated with the same IPs in the database. This happened because, during previous tests, I had reused the same IP addresses without performing a full wipe of the disks. etcd, finding residues of an old configuration, refused to form a new quorum to protect data integrity.

### The Solution: Clean Slate and Network Shift
I decided to apply the supreme philosophy of the Ephemeral Castle: **if it's not clean, it's not reliable**.
1.  I executed a `talosctl reset` on all nodes simultaneously to wipe every magnetic residue on the virtual disks.
2.  I moved the entire cluster IP range (from `.22x` to `.21x`) to force every network component, including the router's ARP cache, to forget the \"ghosts\" of the past.

After this total reset, provisioning went smoothly. The three brains recognized each other, elected a leader, and the VIP `.210` went online in less than 2 minutes. This result was particularly satisfying after hours of troubleshooting invisible certificate conflicts.

---

## Phase 3: The Stateless Revolution - Blog Migration

With a solid HA base, it was time to deploy the first non-infrastructure workload: the Hugo blog.

### The Reasoning: From State to Immutability
The previous blog setup was based on a `git-sync` container that downloaded source code from GitHub and a Hugo instance that compiled the site within the cluster.

I decided to abandon this approach for three fundamental reasons:
1.  **Security (Zero Trust)**: The old method required keeping a GitHub token or an SSH key inside the cluster. By removing git-sync, the cluster no longer needs to know that a source Git repository exists.
2.  **Reliability**: If GitHub had gone down, the blog would not have started. Now, the blog depends only on the Docker image saved on Docker Hub.
3.  **Speed**: An immutable image containing only pre-compiled files and a lightweight web server starts in milliseconds, whereas Hugo took precious seconds to generate the site at every startup.

### Deep-Dive: Docker Multi-Stage Build
To implement this vision, I wrote a multi-stage `Dockerfile`. This approach allows for the separation of the build environment from the runtime environment, ensuring tiny and secure images.

```dockerfile
# Stage 1: Builder
FROM hugomods/hugo:std AS builder
WORKDIR /src
COPY . .
# Generate static site with optimizations
RUN hugo --minify

# Stage 2: Runner
FROM nginx:stable-alpine
# Copy build artifacts, leaving behind compiler and source code
COPY --from=builder /src/public /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

---

## Phase 4: Level 2 GitOps - Total Traceability

A serious infrastructure requires a serious release workflow. I decided to implement an **Image Tagging system based on Git SHA**.

### The Problem with Static Tags
Using a tag like `:latest` or `:blog` is a cardinal sin in Kubernetes. It prevents deterministic rollbacks and misleads Kubernetes, which might not download the new version if the tag doesn't change.

### The Solution: The Smart Publish Script
I developed a `publish.sh` script that coordinates the release between two different repositories (`blog-src` and `tazlab-k8s`).

**The script's thought process:**
1.  Verify that there are no uncommitted changes (determinism).
2.  Extract the current commit SHA (e.g., `8c945ac`).
3.  Build and push the image `tazzo/tazlab.net:blog-8c945ac`.
4.  **GitOps Automation**: The script enters the local `tazlab-k8s` repository folder, searches for the blog manifest file, and replaces the old tag with the new one using `sed`.
5.  Executes an automatic commit and push to `tazlab-k8s`.

In this way, the blog update is not a manual operation on the cluster, but a declared state change on Git. **Flux CD** detects the new commit and aligns the cluster within 60 seconds. This is the true essence of GitOps: code is the only source of truth.

---

## Phase 5: The Port Mapping Bug Hunt

Despite the correct architecture, the blog initially responded with a frustrating `Connection Refused`.

### Investigation: Ingress vs Service
I began the investigation by checking the Pod status: they were `Running`. I checked the Traefik logs and noticed unexpected behavior: Traefik was receiving traffic on port 80 but failing to contact the backend.

Executing `kubectl describe svc hugo-blog`, I discovered the snag. Traefik, by default in its Helm chart, attempts to map traffic to ports `8000` (HTTP) and `8443` (HTTPS) of the containers. However, in my manifest, I had configured Nginx to listen on port `80`.

Furthermore, the official Traefik image runs as a non-root user and does not have permissions to listen on ports below 1024 inside the Pod.

### The Solution: Port Alignment
I modified the Traefik configuration in `main.tf` to explicitly handle the mapping:
*   **External**: Port 80 (exposed by the MetalLB LoadBalancer).
*   **Mapping**: Port 80 of the Service -> Port 8000 of the Traefik Pod.
*   **Ingress**: Traefik then routes to port 80 of the blog Pods (Nginx).

```hcl
# Traefik Port Configuration Fix
ports:
  web:
    exposedPort: 80
    port: 8000 # Internal port where Traefik is authorized to listen
  websecure:
    exposedPort: 443
    port: 8443
```

After applying this change, the Let's Encrypt SSL certificates (managed via HTTP-01 challenge) instantly moved from `pending` to `valid`. Seeing the green padlock appear on `https://blog.tazlab.net` was the culmination of a long debugging session.

---

## Post-lab Reflections: Towards the Complete Castle

With a 5-node cluster and a real application operational in HA, the Ephemeral Castle has emerged from its embryonic phase.

### What we achieved:
1.  **Resilience Born from Consensus**: Thanks to the 3 CPs, we can afford hardware failures without losing control of the platform.
2.  **Application Immutability**: The blog is no longer a mass of synchronized files, but an entity frozen in time, easy to scale and impossible to corrupt.
3.  **Backup Automation**: I no longer need to worry about `kubeconfig` files. Terraform uploads them to Infisical as soon as the cluster is born, allowing me to be operational on any machine in moments.

The Castle is now ready to welcome the next pillars: observability with **Prometheus** and **Grafana**, and filesystem hardening through **Disk Encryption** of the `/var` partition. Every step moves us further from the fragility of \"hardware\" and closer to the freedom of pure code.

---
*End of Technical Chronicle - Phase 4: HA and Immutability*
