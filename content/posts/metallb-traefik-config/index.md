+++
title = "From HostNetwork Chaos to MetalLB Elegance"
date = 2026-01-04T10:00:00Z
draft = false
description = "Transitioning from hostNetwork to a proper LoadBalancer with MetalLB in a bare-metal Kubernetes cluster."
tags = ["kubernetes", "metallb", "traefik", "networking", "homelab"]
author = "Tazzo"
+++

## Introduction: The Limit of "It Just Works"

Until yesterday, our Kubernetes cluster lived in a sort of architectural limbo. The Ingress Controller (Traefik) was configured in `hostNetwork: true` mode. Simply put, the Traefik Pod hijacked the entire network interface of the node it was running on, listening directly on ports 80 and 443 of the Control Plane's physical IP.

Does it work? Yes. Is it a best practice? Absolutely not.
This configuration creates a strong coupling between the logical service and the physical infrastructure. If the node dies, the service dies. Furthermore, it blocks those ports for anything else. In cloud providers (AWS, GCP), this problem is solved with a click: "Create Load Balancer". But we are "on-premise" (or rather, "on-homelab"), where the luxury of ELBs (Elastic Load Balancers) does not exist.

The solution is **MetalLB**: a component that simulates a hardware Load Balancer inside the cluster, assigning "virtual" IPs to services. Today's mission was simple on paper but complex in execution: install MetalLB, configure a dedicated IP zone, and migrate Traefik to make it a first-class citizen of the cluster.

---

## Phase 1: MetalLB and the Dance of Protocols (Layer 2)

For a home cluster where we don't have expensive BGP routers (like Juniper or Cisco in datacenters), MetalLB offers **Layer 2** mode.

**Key Concept: Layer 2 & ARP**
In this mode, one of the cluster nodes "raises its hand" and tells the local network: "Hey, IP 192.168.1.240 is me!". It does this by sending ARP (Address Resolution Protocol) packets. If that node dies, MetalLB instantly elects another node that starts shouting "No, it's me now!". It's a simple yet effective failover mechanism.

### The Challenge of Tolerations
The first obstacle was architectural. By default, MetalLB installs pods called "speakers" (those that "shout" ARP) only on Worker nodes. But in our cluster, traffic was still predominantly entering from the Control Plane. If we hadn't had a speaker on the Control Plane, we would have risked having a mute Load Balancer on half the infrastructure.

We had to force Helm's hand with a specific `tolerations` configuration, allowing speakers to "get their hands dirty" on the Master node as well:

```yaml
# metallb-values.yaml
speaker:
  tolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
    - key: "node-role.kubernetes.io/master"
      operator: "Exists"
      effect: "NoSchedule"
controller:
  tolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
```

Without this, the speakers would have remained in `Pending` on the control plane, making failover lame.

---

## Phase 2: The DHCP Trap (Networking Surgery)

Configuring MetalLB requires an IP address pool to assign. And here we risked disaster.

The home router (a Sky Hub) was configured, like many consumer routers, to cover the entire `192.168.1.x` subnet with its DHCP server (range `.2` - `.253`).

**The Danger of IP Conflict**
If we had told MetalLB "Use the range `.50-.60`" without touching the router, we would have created a ticking time bomb.
Scenario:
1. MetalLB assigns `.50` to Traefik. Everything works.
2. I come home, my phone connects to Wi-Fi.
3. The router, unaware of MetalLB, assigns `.50` to my phone.
4. **Result:** IP Conflict. The Kubernetes cluster and my phone start fighting over who owns the address. Packets get lost, connections drop. Chaos.

**The Solution: "DHCP Shrinking"**
Before applying any YAML, we intervened on the router. We drastically reduced the DHCP range: **from `.2-.120`**.
This created a "No Man's Land" (from `.121` to `.254`) where the router dares not venture. It is in this safe space that we carved out the pool for MetalLB.

```yaml
# metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: main-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.240-192.168.1.245 # Safe Zone
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - main-pool
```

---

## Phase 3: Refactoring Traefik (The Big Leap)

With MetalLB ready to serve IPs, the time came to detach Traefik from the hardware.

The changes to Traefik's `values.yaml` were radical:
1.  **Gone `hostNetwork: true`:** The pod now lives in the cluster's virtual network, isolated and secure.
2.  **Gone `nodeSelector`:** We no longer force Traefik to run on the Control Plane. It can (and must) go to Workers.
3.  **Service Type `LoadBalancer`:** The keystone. We ask the cluster for an external IP.

But migrations are never painless.

---

## Phase 4: Chronicle of a Debugging (The Struggle)

Just as we launched the Helm upgrade, we ran into two classic but educational problems.

### 1. The Volume Deadlock (RWO)
Traefik uses a persistent volume (Longhorn) to save SSL certificates (`acme.json`). This volume is of type **ReadWriteOnce (RWO)**, which means it can be mounted by **only one node at a time**.

When Kubernetes tried to move Traefik from the Control Plane to the Worker:
1. It created the new pod on the Worker.
2. The old pod on the Control Plane was still shutting down (`Terminating`).
3. The volume still appeared "attached" to the old node.
4. The new pod remained stuck in `ContainerCreating` with the error `Multi-Attach error`.

**Solution:** Sometimes Kubernetes is too polite. We had to force delete the old pod and scale the deployment to 0 replicas to "unlock" the volume from Longhorn, then allowing the new pod to mount it cleanly.

### 2. The Permission War (Root vs Non-Root)
In the hardening process, we decided to run Traefik as a non-privileged user (UID `65532`), abandoning `root`.
However, the existing `acme.json` file in the volume had been created by the old Traefik (which ran as `root`).

Result?
`open /data/acme.json: permission denied`

User `65532` looked at the file owned by `root` and couldn't touch it. The `fsGroup` parameter in the SecurityContext often isn't enough for existing files on certain storage drivers.

**Solution: The "Init Container" Pattern**
Instead of going back and using root (which would be a defeat for security), we implemented an **Init Container**. It's a small ephemeral container that starts *before* the main one, executes a command, and dies.

We configured it to run as `root` (only him!), fix permissions, and leave the field clear for Traefik:

```yaml
# traefik-values.yaml snippet
initContainers:
  - name: volume-permissions
    image: busybox:latest
    # Brutal but effective command: "This is all yours, user 65532"
    command: ["sh", "-c", "chown -R 65532:65532 /data && chmod 600 /data/acme.json || true"]
    securityContext:
      runAsUser: 0 # Root, necessary for chown
    volumeMounts:
      - name: data
        mountPath: /data
```

---

## Conclusions

Today the cluster took a leap in quality. It is no longer a collection of hacks to make things work at home, but an infrastructure that respects cloud-native patterns.

**What we achieved:**
1.  **Node Independence:** Traefik can die and be reborn on any node; the service IP (`192.168.1.240`) will follow it thanks to MetalLB.
2.  **Security:** Traefik no longer has access to the host's entire network and runs with a limited user.
3.  **Order:** We clearly separated the router's responsibility (home DHCP) from the cluster's (Static IP Pool).

The main lesson? Automation (Helm) is powerful, but when touching persistent storage (Stateful) and permissions, surgical human intervention and log understanding (`permission denied`, `multi-attach error`) remain irreplaceable.
