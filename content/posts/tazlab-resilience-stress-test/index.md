--- 
title: "Baptism by Fire: Resilience, Deadlock, and Disaster Recovery in the TazLab Cluster"
date: 2026-01-26T21:30:00+00:00
draft: false
tags: ["Kubernetes", "Talos", "Longhorn", "Traefik", "Terraform", "Disaster Recovery", "DevOps"]
description: "Technical chronicle of an extreme stress test session: from network collapse to storage deadlock, culminating in the IaC stabilization of the cluster."
---

## Introduction: The Weight of Theory against the Reality of the Metal

In recent weeks, I have dedicated a significant amount of time to building an immutable and secure workstation. However, a perfectly organized workshop is useless if the "construction site" — my Kubernetes cluster based on Talos Linux and Proxmox — is unable to withstand the impact of a real failure. My mindset today was not geared towards construction, but towards controlled destruction. I wanted to understand where the thread of resilience breaks.

The objective of the session was clear: now that the infrastructure is managed via **Terraform** and boasts 4 worker nodes, it is time to test the promises of High Availability (HA). But, as often happens in distributed systems, what looks like a painless transition on paper can turn into a catastrophic domino effect in reality. In this chronicle, I will document how a simple IP change and a forced shutdown brought the cluster to the brink of collapse, and how I decided to rebuild the foundations to prevent it from happening again.

---

## Phase 1: Expansion and IaC Consolidation

The first step was aligning the cluster with the new desired configuration. I decided to use **Terraform** to manage the entire lifecycle of the nodes on Proxmox. The use of an Infrastructure as Code (IaC) approach is not just a matter of convenience; it is a necessity to guarantee the replicability of the "Ephemeral Castle" I wrote about previously.

I configured 4 worker nodes, distributing workloads so that no single node was a Single Point of Failure (SPOF).

### Deep-Dive: Why 4 Workers and 3 Control Plane nodes?
In Kubernetes, the concept of **Quorum** is vital. The control plane uses `etcd`, a distributed database based on the Raft consensus algorithm. To survive the loss of a node, a minimum of odd members is required (3 is the bare minimum). For the workers, the number 4 allows for the implementation of robust **Antiaffinity** strategies: I can afford to lose a node for maintenance and still have 3 nodes on which to distribute replicas, maintaining high resource density without overloading the hardware.

---

## Phase 2: The Unexpected Disaster - The IP Change Domino Effect

The test began with an apparently trivial event: changing the IP of the Control Plane node. What was supposed to be a routine update turned into an operational nightmare.

### The Symptom
Suddenly, internal cluster services stopped communicating. The logs for **CoreDNS** and **Longhorn** began showing `No route to host` or `Connection refused` errors towards the `10.96.0.1:443` endpoint.

### The Investigation
I began the investigation by checking the status of the pods with `kubectl get pods -A`. Many were in `CrashLoopBackOff`. Analyzing the `longhorn-manager` logs:
```text
time="2026-01-25T20:45:28Z" level=error msg="Failed to list nodes" error="Get \"https://10.96.0.1:443/api/v1/nodes\": dial tcp 10.96.0.1:443: connect: no route to host"
```

The problem was deep: the internal Kubernetes service (`kubernetes.default`) was still pointing to the old physical IP of the Control Plane (`.71`) instead of the new one (`.253`). Although I had updated the external `kubeconfig`, the internal routing tables (managed by `kube-proxy` and `iptables`) remained stuck.

### The Solution: Manual Patching of Endpoints
I decided to intervene surgically on the `Endpoints` object in the `default` namespace. This is a risky operation because it is usually managed by the controller manager, but in a state of network partition, manual intervention was the only way.

```bash
# I extracted the configuration, corrected the IP and reapplied it
kubectl patch endpoints kubernetes -p '{"subsets":[{"addresses":[{"ip":"192.168.1.253"}],"ports":[{"name":"https","port":6443,"protocol":"TCP"}]}]}' --kubeconfig=kubeconfig
```

Immediately after, I forced a restart of `coredns` and `kube-proxy`. The network began to breathe again, but the wounds were still open at the storage level.

---

## Phase 3: The Longhorn Deadlock and RWO Storage

Once the network was resolved, I faced the harsh reality of distributed storage. I had forcibly shut down some nodes during the instability phase.

### The Problem: Ghost Volumes
Longhorn uses **RWO (ReadWriteOnce)** volumes. This means a volume can be mounted by only one node at a time. When the `worker-new-03` node was abruptly shut down, the Kubernetes cluster marked it as `NotReady`, but Longhorn maintained the "lock" on the Traefik volume, thinking the node might return at any moment.

I saw the new Traefik pod stuck in `ContainerCreating` for minutes, with this error in the events:
`Multi-Attach error for volume "pvc-..." Volume is already exclusively attached to one node and can't be attached to another.`

### Error Analysis: Why doesn't it unlock itself?
I analyzed the behavior: Kubernetes waits about 5 minutes before evicting pods from a dead node. However, even after eviction, the CSI (Container Storage Interface) does not detach the volume unless it receives confirmation that the original node is powered off. It is a protection measure against data corruption (**Split-Brain**).

### The Solution: Forcing the Cluster's Hand
I decided to proceed with an aggressive cleanup of **VolumeAttachments** and zombie pods.

```bash
# Forced deletion of the zombie pod
kubectl delete pod traefik-79fcb6d7fd-pwp9v -n traefik --force --grace-period=0

# Removal of the stale VolumeAttachment
kubectl delete volumeattachment csi-5f3b43f479e048a26187... --kubeconfig=kubeconfig
```

Only after these actions did Longhorn allow the new node to "take possession" of the disk. This taught me that a forced shutdown in an environment with RWO storage almost always requires human intervention to restore service availability.

---

## Phase 4: The Traefik Limit and the Necessity of Statelessness

During replica testing, I tried to increase the number of Traefik instances to 2. The result was an immediate failure.

### The Reasoning: Why did I want 2 replicas?
From a High Availability perspective, having only one Ingress Controller instance is an unacceptable risk. If the node hosting Traefik dies, the blog goes down (as we saw in the test). A normal `Deployment` should allow me to scale horizontally.

### The Clash with Reality
Traefik is configured to generate SSL certificates via Let's Encrypt and save them in an `acme.json` file. To persist these certificates across restarts, I used a Longhorn volume.
Here lies the architectural error: since the volume is RWO, the second Traefik replica could not start because the disk was already occupied by the first one.

**I decided**, therefore, to temporarily maintain a single replica, but I have mapped out a plan to migrate to **cert-manager**. By using Kubernetes Secrets for certificates, Traefik will become completely **stateless**, allowing us to scale to 3 or more replicas without disk conflicts.

---

## Phase 5: The 5-Minute Test - Automation vs. Prudence

I wanted to conduct one final scientific experiment: shut down a node and time how long it takes for the cluster to react on its own.

1.  **T+0:** Forcibly shut down `worker-new-01`.
2.  **T+1:** The node is `NotReady`. The pod is still considered `Running`.
3.  **T+5:** Kubernetes marks the pod as `Terminating` and creates a new one on another node.
4.  **T+8:** The new pod is still in `Init:0/1`, blocked by the Longhorn volume.

### Test Conclusion
Kubernetes automation works for compute, but fails for RWO persistent storage in the event of sudden hardware failures. Without a **Fencing** system (which physically shuts down the node via Proxmox API), automatic recovery is not guaranteed in a short timeframe.

---

## Post-Lab Reflections: The Roadmap towards Zero Trust

This session of "stress and suffering" was more instructive than a thousand clean installations. I learned that resilience is not a button you press, but a balance built piece by piece.

### What does this mean for long-term stability?
The cluster is now much more solid because:
1.  **Static IPs and VIP:** I moved all management to the `.250` VIP. If a control node dies, the `kubeconfig` does not need to change.
2.  **Network Configuration:** I corrected internal routes, ensuring that system components talk to the correct API.
3.  **Storage Management:** I now know Longhorn's limits and how to intervene in case of a deadlock.

### Next Steps
I have already budgeted for two major tasks:
*   **Traefik Restructuring:** Migration to `cert-manager` to eliminate RWO volumes and allow multi-replica.
*   **Etcd Security:** Implementation of `secretbox` and Disk Encryption on Talos to protect secrets at rest.

In conclusion, the TazLab cluster has passed its baptism by fire. It is not yet perfect, but it has become a system capable of failing with dignity and being repaired with surgical precision. The road to the "Ephemeral Castle" continues, one deadlock at a time.
