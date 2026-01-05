+++
title = "Lab Chronicles: Native VIP on Talos and Traefik Ingress"
date = 2025-12-30T10:00:00Z
draft = false
description = "A technical chronicle of configuring a native Virtual IP on Talos Linux and setting up Traefik Ingress."
tags = ["kubernetes", "talos-linux", "traefik", "homelab", "networking"]
categories = ["infrastructure", "devops"]
author = "Tazzo"
+++

## Introduction: The (Apparent) Charm of Simplicity

Today I tackled one of those lab sessions that start with an apparently simple goal and end up turning into a masterclass in Kubernetes architecture. The goal was clear: configure a solid entry point (Ingress) for my **Talos Linux** cluster on Proxmox, exposed via a native **VIP (Virtual IP)**, and install **Traefik** to manage HTTPS traffic with automatic Let's Encrypt certificates.

The mantra of the day was "Less is More". No MetalLB (for now). No complex external Load Balancers. I wanted to leverage Talos's native capabilities to manage network High Availability and run Traefik "on the metal" (HostNetwork).

What follows is not a sterile tutorial, but the faithful chronicle of the challenges, architectural errors, and solutions that led to success.

---

## Phase 1: The Talos Native VIP (Layer 2)

The first challenge was ensuring a stable IP address (`192.168.1.250`) that could "float" between nodes, regardless of which physical machine was powered on.

### The Reasoning (The Why)
Why a native VIP? In a Bare Metal environment (or VMs on Proxmox), we don't have the convenience of cloud Load Balancers (AWS ELB, Google LB) that provide us with a public IP with a click. The classic alternatives are **MetalLB** (which announces IPs via ARP/BGP) or **Kube-VIP**.
However, Talos Linux offers a built-in feature to manage shared VIPs directly in the machine configuration (`machine config`). I chose this path to reduce software dependencies: if the operating system can do it, why install another pod to manage it?

### The Analysis and the Error
I started by identifying the network interface on the nodes (`ens18`) and creating a patch to announce the IP `192.168.1.250`.

```yaml
# vip-patch.yaml
machine:
  network:
    interfaces:
      - interface: ens18
        dhcp: true
        vip:
          ip: 192.168.1.250
```

Applying the patch to the **Control Plane** node (`192.168.1.253`) was an immediate success. The node started answering ARP requests for the new IP.
The problem arose when I attempted to apply the same patch to the **Worker** node (`192.168.1.127`) to ensure redundancy.

> **Error:** `virtual (shared) IP is not allowed on non-controlplane nodes`

**Analysis:** Talos, by design, limits the use of shared VIPs to Control Plane nodes. This is because the primary use case is High Availability for the API Server (port 6443), not generic user traffic.
**Impact:** We had to accept that our VIP will reside, for now, only on the Control Plane. Is it a *Single Point of Failure*? Yes, if the CP node dies, we lose the IP. But for a home lab, it is an acceptable compromise that drastically simplifies the stack.

---

## Phase 2: Helm and Preparation of the Ground

With the VIP active, we needed the "engine" to install applications. **Helm** is the de facto standard. Installation was trivial via the official script, but essential. Helm allows us to define our infrastructure as code (Values files) instead of as imperative commands launched randomly.

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh && ./get_helm.sh
```

---

## Phase 3: Traefik and the Configuration Hell

Here the real battle began. We wanted Traefik configured in a very specific way:
1.  **HostNetwork:** Listen directly on ports 80/443 of the node (bypassing the K8s overlay network level) to intercept traffic directed to the VIP.
2.  **ACME (Let's Encrypt):** Generate valid SSL certificates.
3.  **Persistence:** Save certificates to disk to avoid regenerating them at every restart (and hitting rate-limits).

### The First Wall: The Helm Syntax
The Traefik chart evolves rapidly. My initial `values.yaml` configuration used deprecated syntax for redirects (`redirectTo`) and port exposure.
Helm responded with cryptic errors like `got boolean, want object`.

**Solution:** I had to consult the updated documentation (via Context7) and discover that global redirect management is now more robust if passed via `additionalArguments` rather than trying to fit it into the ports map.

### The Second Wall: RollingUpdate vs HostNetwork
Once the syntax was corrected, Helm refused installation with an interesting logical error:

> **Error:** `maxUnavailable should be greater than 0 when using hostNetwork`

**Deep-Dive:** When you use `hostNetwork: true`, a Pod physically occupies port 80 of the node. Kubernetes cannot start a *new* Pod (update) on the same node until the *old* one is dead, because the port is occupied. The default strategy `maxUnavailable: 0` (which tries to never have downtime) is mathematically incompatible with this constraint on a single node.
**Solution:** I had to modify the `updateStrategy` to allow `maxUnavailable: 1`.

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1
    maxSurge: 0
```

### The Third Wall: Pod Security Admission (PSA)
Overcoming the configuration obstacle, the Pods wouldn't start. They remained in `CreateContainerConfigError` state or weren't created by the DaemonSet.
Describing the DaemonSet (`kubectl describe ds`), the truth emerged:

> **Error:** `violates PodSecurity "baseline": host namespaces (hostNetwork=true)`

**Analysis:** Talos and recent Kubernetes versions apply strict security standards by default. A Pod requiring `hostNetwork` is considered "privileged" because it can see all node traffic. The namespace had to be explicitly authorized.

**Solution:**
```bash
kubectl label namespace traefik pod-security.kubernetes.io/enforce=privileged --overwrite
```

---

## Phase 4: The Connection Paradox

Everything looked green. Pod Running. VIP active. But trying to connect to `http://192.168.1.250` (or to the domain `tazlab.net`), I received a dry **Connection Refused**.

### The Investigation (Sherlock Mode)
1.  **VIP:** The VIP `192.168.1.250` is on the **Control Plane** node (`.253`).
2.  **Pod:** I checked where the Traefik Pod was running: `kubectl get pods -o wide`. It was running on the **Worker** node (`.127`).
3.  **The Black Hole:** Traffic arrived at node `.253` (VIP), but on that node, there was no Traefik listening on port 80! The router sent packets to the right place, but no one answered.

Why wasn't Traefik running on the Control Plane?
**Deep-Dive: Taints & Tolerations.** Control Plane nodes have a "Taint" (a stain) called `node-role.kubernetes.io/control-plane:NoSchedule`. This tells the scheduler: "Do not place any workload here, unless it is explicitly tolerated". Traefik, by default, does not tolerate it.

### The Definitive Architectural Solution
We had to take a drastic decision to make everything work in harmony:
1.  Abandon the `DaemonSet` (which tries to run everywhere).
2.  Switch to a `Deployment` with **1 single replica**.
3.  Force this replica to run **exclusively** on the Control Plane node (where the VIP resides).

Changes to `values.yaml`:

```yaml
# 1. Tolerate the Control Plane Taint
tolerations:
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"

# 2. Force execution on the Control Plane node
nodeSelector:
  kubernetes.io/hostname: "talos-unw-ifc" # Or use generic labels

# 3. Single replica Deployment (Crucial for ACME)
deployment:
  kind: Deployment
  replicas: 1
```

Why a single replica? Because the Community version of Traefik does not support sharing ACME certificates between multiple instances. If we had two replicas, both would try to renew certificates, conflicting or getting banned by Let's Encrypt.

---

## Conclusions and Final State

After applying this "surgical" configuration, the system came to life.

1.  The home router forwards ports 80/443 to the VIP `192.168.1.250`.
2.  The VIP carries traffic to the Control Plane node.
3.  Traefik (now residing on the Control Plane) intercepts the traffic.
4.  It recognizes the domain `tazlab.net`, requests the certificate from Let's Encrypt, saves it to `/data` (hostPath volume mounted), and serves the `whoami` application.

**What have we learned?**
That "simple" does not mean "easy". Removing abstraction layers (like external Load Balancers) forces us to deeply understand how Kubernetes interacts with the underlying physical network. We had to manually handle node affinity, namespace security, and update strategies.

The result is a lean cluster, without resource waste, perfect for a Homelab, but built with the awareness of every single gear.

**Next steps:** Configure certificate backups (because now they are on a single node!) and start deploying real services.

---
*Generated via Gemini CLI*