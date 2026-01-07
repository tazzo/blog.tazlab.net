+++
title = "Integration and Optimization of MetalLB on Talos OS Kubernetes Clusters in Proxmox Virtual Environments"
date = 2026-01-07
draft = false
description = "Implementing MetalLB for bare-metal load balancing on Talos clusters hosted on Proxmox."
tags = ["talos", "metallb", "proxmox", "load-balancing", "networking", "kubernetes"]
author = "Tazzo"
+++

The adoption of Kubernetes in on-premises contexts has introduced the need to manage load balancing in the absence of native services offered by public cloud providers. In this scenario, the combination of Proxmox Virtual Environment (VE) as the hypervisor, Talos OS as the operating system for cluster nodes, and MetalLB as the network LoadBalancer solution, represents one of the most robust, secure, and efficient architectures for managing modern workloads.1 Proxmox provides the flexibility of enterprise virtualization by combining KVM and LXC, while Talos OS redefines the concept of an operating system for Kubernetes, eliminating the complexity of traditional Linux distributions in favor of an immutable and API-driven approach.1 MetalLB steps in to fill the critical gap in bare-metal networking, allowing Kubernetes services of type LoadBalancer to receive external IP addresses reachable from the local network.3

## **Architectural Analysis of the Proxmox Virtualization Layer**

Designing a Kubernetes infrastructure on Proxmox requires a deep understanding of how the hypervisor manages resources and networking. Proxmox is based on standard Linux networking concepts, primarily using virtual bridges (vmbr) to connect virtual machines to the physical network.5 When planning a MetalLB installation, the configuration of these bridges becomes the foundation upon which the entire reachability of services rests.

### **Host Networking Configuration**

Best practice in Proxmox involves using Linux Bridges or, in more complex scenarios, Open vSwitch. For most Kubernetes deployments, a correctly configured `vmbr0` bridge is sufficient, provided it supports the Layer 2 traffic necessary for MetalLB's ARP (Address Resolution Protocol) operations.4 An often overlooked aspect is the need to manage different VLANs to isolate cluster management traffic (Corosync), Kubernetes API traffic, and application data traffic.5 Latency is a critical factor for Corosync; therefore, it is recommended not to saturate the main bridge with heavy data loads that could cause instability in the Proxmox cluster quorum.5

| Network Component | Optimal Configuration | Critical Function |
| :---- | :---- | :---- |
| **Bridge (vmbr0)** | VLAN Aware, No IP (optional) | Main virtual switch for VM traffic.5 |
| **Bonding (LACP)** | 802.3ad (if supported by the switch) | Redundancy and bandwidth increase.5 |
| **MTU** | 1500 (standard) or 9000 (Jumbo Frames) | Throughput optimization for storage and pod-to-pod traffic.5 |
| **VirtIO Model** | Paravirtualization | Maximum network performance with minimum CPU overhead.7 |

MetalLB integration requires that the Proxmox bridge does not interfere with the gratuitous ARP packets sent by MetalLB speakers to announce Virtual IPs (VIPs). In some advanced routing scenarios, it might be necessary to enable `proxy_arp` on the host bridge interface to facilitate communication between different subnets, although this practice must be carefully evaluated for security implications.8

## **Talos OS: The Evolution of the Immutable Operating System**

Talos OS stands radically apart from general-purpose Linux distributions. It is a minimal operating system, devoid of shell, SSH, and package managers, designed exclusively to run Kubernetes.1 This reduction in attack surface, which brings the system to have only about 12 binaries compared to the usual 1500 of standard distributions, makes it ideal for environments requiring high security and maintainability.2 Talos management occurs entirely via gRPC APIs using the `talosctl` tool.2

### **Virtual Machine Specifications for Kubernetes Nodes**

Creating VMs on Proxmox to host Talos must follow rigorous technical requirements to ensure the stability of etcd and system APIs.

| VM Resource | Minimum Requirement | Recommended Configuration |
| :---- | :---- | :---- |
| **CPU Type** | host | Enables all hardware extensions of the physical CPU.7 |
| **CPU Cores** | 2 Cores | 4 Cores for Control Plane nodes.7 |
| **RAM Memory** | 2 GB | 4-8 GB to ensure operational fluidity and caching.7 |
| **Disk Controller** | VirtIO SCSI | Support for TRIM command and reduced latencies.7 |
| **Storage** | 20 GB | 32 GB or higher for logs and ephemeral local storage.10 |

Using the "host" CPU type is fundamental as it allows Talos to access advanced virtualization and encryption instructions of the physical processor, improving the performance of etcd and traffic encryption processes.7 Furthermore, enabling the QEMU agent in the Proxmox VM settings allows for more granular management of the operating system, such as clean shutdowns and clock synchronization, although Talos handles many of these functions natively via its APIs.7

## **MetalLB Implementation: Theory and Network Mechanisms**

MetalLB solves the problem of external reachability for Kubernetes services by acting as a software implementation of a network load balancer. It works by monitoring services of type LoadBalancer and assigning them an IP address from a pool configured by the administrator.11 There are two main operational modes: Layer 2 (ARP/NDP) and BGP.

### **How Layer 2 Mode Works**

In Layer 2 mode, MetalLB uses the ARP protocol for IPv4 and NDP for IPv6. When an IP is assigned to a service, MetalLB elects one of the cluster nodes as the "owner" of that IP.4 That node will start responding to ARP requests for the service's External-IP with its own physical MAC address. From the perspective of the external network (e.g., the lab or office router), it looks like the node has multiple IP addresses associated with its network card.4

This mode is extremely popular in home labs and small businesses because it requires no configuration on existing routers; it works on any standard Ethernet switch.4 However, it has a structural limit: all inbound traffic for a given VIP is directed to a single node. Although `kube-proxy` then distributes this traffic to the actual pods on other nodes, inbound bandwidth is limited by the network capacity of the single leader node.4

### **Border Gateway Protocol (BGP) and Scalability**

For high-traffic production environments, BGP mode is the preferred choice. In this case, each cluster node establishes a BGP peering session with the infrastructure routers.4 When a service receives an External-IP, MetalLB announces that route to the router. If the router supports ECMP (Equal-Cost Multi-Pathing), traffic can be distributed equally among all nodes announcing the route, allowing true network-level load balancing and overcoming the limits of Layer 2 mode.13

Using BGP on Talos requires careful configuration, especially if advanced CNIs like Cilium are used, which have their own BGP capabilities.14 It is fundamental to avoid conflicts between MetalLB and the CNI, deciding which component should manage peering with physical routers.15

## **Practical Installation Guide: From Bootstrap to Configuration**

The installation process begins after the Talos cluster has been successfully bootstrapped and `kubectl` is operational.

### **Talos Preparation: System Patching**

Before installing MetalLB, it is necessary to apply some changes to the Talos node configuration. One of MetalLB's fundamental requirements, when operating with `kube-proxy` in IPVS mode, is enabling the `strictARP` parameter.16 In Talos, this is not done by modifying a ConfigMap, but by patching the `MachineConfig`.

The configuration file must include the `kube-proxy` section to force acceptance of gratuitous ARPs and correctly handle VIP routing.16 Furthermore, if it is desired that Control Plane nodes participate in IP announcements (very common in small clusters), it is necessary to remove the restrictive labels that Kubernetes and Talos apply by default.18

```yaml
# Example patch to enable strictARP and remove node restrictions
cluster:
  proxy:
    config:
      ipvs:
        strictARP: true
  allowSchedulingOnControlPlanes: true # If using masters as workers
machine:
  nodeLabels:
    node.kubernetes.io/exclude-from-external-load-balancers: ""
    $patch: delete
```

This patch ensures that the control plane is not excluded from load balancing operations, allowing MetalLB to run its "speakers" on every available node.18

### **Installing MetalLB via Helm**

Using Helm is the recommended method for installing MetalLB as it facilitates version management and RBAC dependencies.16

1. Namespace Creation and Security Labels:  
   Kubernetes applies Pod Security Admissions. MetalLB, needing to manipulate the host's network stack, requires a `privileged` profile. It is essential to label the namespace before installation.16  
   ```bash
   kubectl create namespace metallb-system
   kubectl label namespace metallb-system pod-security.kubernetes.io/enforce=privileged
   kubectl label namespace metallb-system pod-security.kubernetes.io/audit=privileged
   kubectl label namespace metallb-system pod-security.kubernetes.io/warn=privileged
   ```

2. Helm Execution:  
   The official repository is added and installation proceeds.10  
   ```bash
   helm repo add metallb https://metallb.github.io/metallb
   helm repo update
   helm install metallb metallb/metallb -n metallb-system
   ```

### **Defining Custom Resources (CRD)**

Once installed, MetalLB remains inactive until IP address pools and announcement modes are defined.16 These configurations are now managed via Custom Resource Definitions (CRD) and no longer via ConfigMap as in versions prior to 0.13.

**IPAddressPool:** defines the range of IP addresses that MetalLB can assign. It is crucial that these IPs are not in the router's DHCP range to avoid conflicts.11

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.50-192.168.1.70
```

**L2Advertisement:** this resource associates the address pool with the Layer 2 announcement mode. Without it, MetalLB will assign IPs but will not respond to ARP requests, rendering the IPs unreachable.20

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
```

## **Integration and Security with Proxmox: Spoofing Management**

A common hurdle in installing MetalLB on Proxmox is the network protection system integrated into the hypervisor. Proxmox's firewall includes "IP Filter" and "MAC Filter" features aimed at preventing a VM from using IP or MAC addresses other than those officially assigned in the management panel.21

Since MetalLB in Layer 2 mode "pretends" the node possesses the service IP addresses (VIPs), sending ARP responses for IPs not configured on the primary network interface, the Proxmox firewall might block this traffic, identifying it as ARP Spoofing.21

### **Resolving Proxmox Firewall Restrictions**

To allow MetalLB to function, there are three main approaches:

1. **Disabling MAC Filter:** In the VM's (or bridge's) firewall options, disable the `MAC filter` entry. This allows the VM to send traffic with IP sources other than the primary one.22  
2. **IPSet Configuration:** If maintaining a high security level is desired, an IPSet named `ipfilter-net0` (where `net0` is the VM interface) can be created, including all IP addresses in the MetalLB pool. In this way, the Proxmox firewall will know that those IPs are authorized for that specific VM.21  
3. **Manual ebtables Rules:** In advanced scenarios, the administrator can insert `ebtables` rules on the Proxmox host to specifically allow ARP traffic for the MetalLB range.23

```bash
# Example ebtables command to allow ARP on a specific VM
ebtables -I FORWARD 1 -i fwln<VMID>i0 -p ARP --arp-ip-dst 192.168.1.50/32 -j ACCEPT
```

Omission of these steps is the primary cause of MetalLB installation failures on Proxmox, leading to situations where the Kubernetes service shows a correctly assigned `External-IP`, but that IP is unreachable (not pingable) from outside the cluster.19

## **Monitoring and Troubleshooting**

The immutable nature of Talos OS makes troubleshooting different from traditional systems. Not being able to access via SSH to run `tcpdump` directly on the node, it is necessary to rely on MetalLB pod logs and `talosctl` tools.

### **Speaker Log Analysis**

The "speaker" pods are responsible for IP announcements. If an IP is unreachable, the first step is to check the speaker logs on the node that should be the leader for that service.4

```bash
kubectl logs -n metallb-system -l component=speaker
```

In the logs, it is possible to observe if the speaker has detected the service, if it has correctly elected a leader, and if it is encountering errors in sending gratuitous packets. If logs show the announcement occurred correctly but the router does not see the address, the problem almost certainly lies in the Proxmox virtualization layer or the physical switch.8

### **Verifying L2 Status (ServiceL2Status)**

MetalLB provides a status resource that allows seeing which node is currently serving a given IP.19

```bash
kubectl get servicel2statuses.metallb.io -n metallb-system
```

This information is vital for understanding if traffic is being directed to the correct node and for verifying cluster behavior during a simulated failover (e.g., rebooting a worker node).6

### **Conflicts with CNI and Pod-to-Pod Routing**

In some cases, traffic reaches the node but is not correctly routed to the pods. This can happen if the CNI (such as Cilium or Calico) has a configuration that conflicts with the routing rules created by `kube-proxy` in IPVS mode.12 If using Cilium, it is recommended to check if Cilium's "L2 Announcement" feature is active; if it is, it will perform the same function as MetalLB, rendering the latter redundant or even harmful to network stability.14

## **Performance Optimization and High Availability**

A professional Kubernetes cluster on Proxmox must be designed to withstand failures and scale efficiently.

### **Load Balancing and Hardware Offloading**

Using VirtIO in Proxmox allows offloading some network functions (such as checksum offload) to the host CPU, reducing the load on the Talos VM.7 Furthermore, the implementation of MetalLB in BGP mode, as discussed, allows leveraging physical network hardware (enterprise routers like MikroTik or Cisco) to manage packet-level balancing, ensuring no single node becomes the bottleneck for application traffic.13

### **Failover and Convergence Times**

In Layer 2 mode, failover time depends on the speed at which nodes detect a peer's failure and the rapidity with which the router updates its ARP table.6 Talos optimizes this process thanks to an extremely lean and responsive Linux kernel. To further accelerate failover, MetalLB can be configured with protocols like BFD (Bidirectional Forwarding Detection) in BGP mode, reducing failure detection times from seconds to milliseconds.13

## **Final Considerations on Day-2 Management**

MetalLB integration on Talos and Proxmox does not end with initial installation. "Day-2" management concerns updates, security monitoring, and cluster expansion. Thanks to the declarative nature of Talos and MetalLB, the entire infrastructure can be managed as code (Infrastructure as Code). Using tools like Terraform for VM creation on Proxmox and Helm for managing Kubernetes components allows recreating the entire environment deterministically in case of disaster recovery.8

In conclusion, the synergy between Proxmox stability, Talos OS's intrinsic security, and MetalLB's versatility creates an ideal ecosystem for hosting modern applications. Attention to detail in Layer 2 networking configuration and the elimination of Proxmox's restrictive filters are the pillars for a successful deployment that ensures services are not only operational but also constantly accessible and high-performing for end users. The continuous evolution of these tools suggests a future where the distinction between public cloud and private data center will become increasingly blurred, thanks to software-defined solutions that bring cloud agility directly to the bare metal of one's own infrastructure.1

#### **Bibliography**

1. Proxmox vs Talos – Deciding on the Best Infrastructure Solution - simplyblock, accessed on January 2, 2026, [https://www.simplyblock.io/blog/proxmox-vs-talos/](https://www.simplyblock.io/blog/proxmox-vs-talos/)  
2. Using Talos Linux and Kubernetes bootstrap on OpenStack - Safespring, accessed on January 2, 2026, [https://www.safespring.com/blogg/2025/2025-03-talos-linux-on-openstack/](https://www.safespring.com/blogg/2025/2025-03-talos-linux-on-openstack/)  
3. How to setup the MetalLB | kubernetes-under-the-hood - GitHub Pages, accessed on January 2, 2026, [https://mvallim.github.io/kubernetes-under-the-hood/documentation/kube-metallb.html](https://mvallim.github.io/kubernetes-under-the-hood/documentation/kube-metallb.html)  
4. MetalLB: A Load Balancer for Bare Metal Kubernetes Clusters | by 8grams - Medium, accessed on January 2, 2026, [https://8grams.medium.com/metallb-a-load-balancer-for-bare-metal-kubernetes-clusters-ef8a9e00c2bd](https://8grams.medium.com/metallb-a-load-balancer-for-bare-metal-kubernetes-clusters-ef8a9e00c2bd)  
5. Networking best practice | Proxmox Support Forum, accessed on January 2, 2026, [https://forum.proxmox.com/threads/networking-best-practice.163550/](https://forum.proxmox.com/threads/networking-best-practice.163550/)  
6. MetalLB in layer 2 mode :: MetalLB, bare metal load-balancer for Kubernetes, accessed on January 2, 2026, [https://metallb.universe.tf/concepts/layer2/](https://metallb.universe.tf/concepts/layer2/)  
7. Talos with Kubernetes on Proxmox | Secsys, accessed on January 2, 2026, [https://secsys.pages.dev/posts/talos/](https://secsys.pages.dev/posts/talos/)  
8. epyc-kube/docs/proxmox-metallb-subnet-configuration.md at main ..., accessed on January 2, 2026, [https://github.com/xalgorithm/epyc-kube/blob/main/docs/proxmox-metallb-subnet-configuration.md](https://github.com/xalgorithm/epyc-kube/blob/main/docs/proxmox-metallb-subnet-configuration.md)  
9. How I Setup Talos Linux. My journey to building a secure… | by Pedro Chang | Medium, accessed on January 2, 2026, [https://medium.com/@pedrotychang/how-i-setup-talos-linux-bc2832ec87cc](https://medium.com/@pedrotychang/how-i-setup-talos-linux-bc2832ec87cc)  
10. Highly available kubernetes cluster with etcd, Longhorn and ..., accessed on January 2, 2026, [https://wiki.joeplaa.com/tutorials/highly-available-kubernetes-cluster-on-proxmox](https://wiki.joeplaa.com/tutorials/highly-available-kubernetes-cluster-on-proxmox)  
11. MetalLB Load Balancer - Documentation - K0s docs, accessed on January 2, 2026, [https://docs.k0sproject.io/v1.34.2+k0s.0/examples/metallb-loadbalancer/](https://docs.k0sproject.io/v1.34.2+k0s.0/examples/metallb-loadbalancer/)  
12. MetalLB - Ubuntu, accessed on January 2, 2026, [https://ubuntu.com/kubernetes/charmed-k8s/docs/metallb](https://ubuntu.com/kubernetes/charmed-k8s/docs/metallb)  
13. MetalLB in BGP mode :: MetalLB, bare metal load-balancer for Kubernetes, accessed on January 2, 2026, [https://metallb.universe.tf/concepts/bgp/](https://metallb.universe.tf/concepts/bgp/)  
14. Kubernetes & Talos - Reddit, accessed on January 2, 2026, [https://www.reddit.com/r/kubernetes/comments/1hs6bui/kubernetes_talos/](https://www.reddit.com/r/kubernetes/comments/1hs6bui/kubernetes_talos/)  
15. Talos with redundant routed networks via bgp : r/kubernetes - Reddit, accessed on January 2, 2026, [https://www.reddit.com/r/kubernetes/comments/1iy411r/talos_with_redundant_routed_networks_via_bgp/](https://www.reddit.com/r/kubernetes/comments/1iy411r/talos_with_redundant_routed_networks_via_bgp/)  
16. Installation :: MetalLB, bare metal load-balancer for Kubernetes, accessed on January 2, 2026, [https://metallb.universe.tf/installation/](https://metallb.universe.tf/installation/)  
17. Kubernetes Homelab Series Part 3 - LoadBalancer With MetalLB ..., accessed on January 2, 2026, [https://blog.dalydays.com/post/kubernetes-homelab-series-part-3-loadbalancer-with-metallb/](https://blog.dalydays.com/post/kubernetes-homelab-series-part-3-loadbalancer-with-metallb/)  
18. Unable to use MetalLB on TalosOS linux v.1.9.3 on Proxmox · Issue #2676 - GitHub, accessed on January 2, 2026, [https://github.com/metallb/metallb/issues/2676](https://github.com/metallb/metallb/issues/2676)  
19. Unable to use MetalLB load balancer for TalosOS v1.9.3 · Issue #10291 · siderolabs/talos, accessed on January 2, 2026, [https://github.com/siderolabs/talos/issues/10291](https://github.com/siderolabs/talos/issues/10291)  
20. Configuration :: MetalLB, bare metal load-balancer for Kubernetes, accessed on January 2, 2026, [https://metallb.universe.tf/configuration/](https://metallb.universe.tf/configuration/)  
21. Implementing MAC Filtering for IPv4 in Proxmox Using Built-In Firewall Features, accessed on January 2, 2026, [https://forum.proxmox.com/threads/implementing-mac-filtering-for-ipv4-in-proxmox-using-built-in-firewall-features.157726/](https://forum.proxmox.com/threads/implementing-mac-filtering-for-ipv4-in-proxmox-using-built-in-firewall-features.157726/)  
22. [SOLVED] - Allow MAC spoofing? - Proxmox Support Forum, accessed on January 2, 2026, [https://forum.proxmox.com/threads/allow-mac-spoofing.84424/](https://forum.proxmox.com/threads/allow-mac-spoofing.84424/)  
23. Block incoming ARP requests if destination ip is not part of ipfilter-net[n], accessed on January 2, 2026, [https://forum.proxmox.com/threads/block-incoming-arp-requests-if-destination-ip-is-not-part-of-ipfilter-net-n.144135/](https://forum.proxmox.com/threads/block-incoming-arp-requests-if-destination-ip-is-not-part-of-ipfilter-net-n.144135/)  
24. Filter ARP request - Proxmox Support Forum, accessed on January 2, 2026, [https://forum.proxmox.com/threads/filter-arp-request.118505/](https://forum.proxmox.com/threads/filter-arp-request.118505/)  
25. Creating ExternalIPs in OpenShift with BGP and MetalLB | - Random Tech Adventures, accessed on January 2, 2026, [https://xphyr.net/post/metallb_and_ocp_using_bgp/](https://xphyr.net/post/metallb_and_ocp_using_bgp/)  
26. Setting up a Talos kubernetes cluster with talhelper - beyondwatts, accessed on January 2, 2026, [https://www.beyondwatts.com/posts/setting-up-a-talos-kubernetes-cluster-with-talhelper/](https://www.beyondwatts.com/posts/setting-up-a-talos-kubernetes-cluster-with-talhelper/)
