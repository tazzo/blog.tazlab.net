+++
title = "Architecture and Implementation of Tailscale on Talos Linux: Technical Analysis and Resolution of Operational Criticalities"
date = 2026-01-07
draft = false
description = "Technical guide on integrating Tailscale with Talos Linux, covering system extensions and networking challenges."
tags = ["talos", "tailscale", "vpn", "networking", "security", "wireguard"]
author = "Tazzo"
+++

The evolution of cloud-native operating systems has led to the emergence of solutions radically different from traditional Linux distributions. Talos Linux stands at the forefront of this transformation, proposing an operational model based on immutability, the absence of interactive shells, and entirely API-mediated management.1 In this ecosystem, the integration of Tailscale, a mesh network solution based on the WireGuard protocol, is not a simple software installation, but a systems engineering operation that requires a deep understanding of Talos's kernel extension mechanisms and filesystem.3 This report analyzes the implementation methodologies, declarative configuration strategies, and the resolution of networking issues arising from the convergence of these two technologies.

## **Operational Paradigms and Architecture of Talos Linux**

To understand the challenges of installing Tailscale, it is necessary to analyze the fundamental structure of Talos Linux. Unlike general-purpose distributions, Talos does not use package managers such as apt or yum.1 The root filesystem is mounted as read-only, and the system is designed to be ephemeral, with the exception of the partition dedicated to persistent data.3 This approach eliminates the problem of configuration drift but prevents the execution of common Tailscale installation scripts.1

System management occurs exclusively via talosctl, a CLI utility that communicates with the gRPC APIs exposed by the machined daemon.3 In this context, any additional software component must be integrated as a system extension or as a workload within Kubernetes.3

| Feature | Talos Linux | Traditional Distributions |
| :---- | :---- | :---- |
| Package Management | Absent (OCI Extensions) | apt, yum, zypper, pacman |
| Remote Access | gRPC API (Port 50000) | SSH (Port 22) |
| Root Filesystem | Immutable (Read-only) | Mutable (Read-write) |
| Configuration | Declarative (YAML) | Imperative (Script/CLI) |
| Kernel | Hardened / Minimalist | General-purpose / Modular |

The absence of a local terminal and standard diagnostic tools like iproute2 or iptables accessible directly by the user makes the use of Tailscale indispensable not only for network security but also as a potential bridge for out-of-band cluster management.3

## **The System Extension Mechanism**

The primary method for injecting binaries like tailscaled and tailscale into Talos Linux is the System Extensions system.9 A system extension is an OCI-compliant container image containing a predefined file structure intended to be overlaid on the root filesystem during the boot phase.12

### **Anatomy of an OCI Extension**

A valid extension must contain a manifest.yaml file at the root, defining the name, version, and compatibility requirements with the Talos version.3 The actual content of the binaries must be placed in the /rootfs/usr/local/lib/containers/<extension-name> directory.3 Talos scans the /usr/local/etc/containers directory for service definitions in YAML format, which describe how the machined daemon should start the process.9

The Tailscale service, when run as an extension, operates as a privileged container with access to the host's /dev/net/tun device, essential for creating the virtual network interface.4 Since the tailscale0 interface must be available to the host operating system and not just within an isolated network namespace, the extension uses host networking.14

### **Lifecycle of the ext-tailscale Service**

When Talos detects the Tailscale configuration, it registers a service named ext-tailscale.9 This service enters a waiting state until network dependencies are met, such as the assignment of IP addresses to physical interfaces and connectivity to default gateways.9 The telemetry of this service can be monitored via the command talosctl service ext-tailscale, which provides details on operational status, restart events, and process health.9

## **Installation Methodologies and Image Generation**

There are three primary paths for implementing Tailscale on a Talos node, each with different implications for system maintainability and stability.3

### **Using the Talos Image Factory**

The Talos Image Factory represents the most modern and recommended approach.5 It is an API service managed by Sidero Labs that allows dynamically assembling ISO images, PXE assets, or disk images (raw) by including certified extensions.3 The user selects the Talos version, architecture (amd64 or arm64), and adds the siderolabs/tailscale extension from the official extensions list.5

The result of this operation is a Schematic ID.10 This hash ensures that the image is reproducible and that all nodes in a cluster use the exact combination of kernel and drivers.

| Platform | Image Format | Distribution Method |
| :---- | :---- | :---- |
| Bare Metal | ISO / RAW | USB Flash / iDRAC / IPMI |
| Virtualization (Proxmox/ESXi) | ISO | Datastore Upload |
| Cloud (AWS/GCP/Azure) | AMI / Disk Image | Image Import |
| Network Boot | PXE / iPXE | TFTP/HTTP Server |

Installation is performed by providing the schematic-based installer URL in the machine configuration file, under the machine.install.image key.3 During the installation or update process, Talos retrieves the OCI image, extracts the necessary components, and persists them in the system partition.3

### **Installation via OCI Installer on Existing Nodes**

For nodes already in operation, it is possible to inject Tailscale without regenerating the entire physical boot medium.3 This is done by dynamically modifying the installation image in the MachineConfig.3 However, this method carries a risk: if the specified image does not contain the extension during a subsequent operating system update, Tailscale will be removed upon reboot.3 It is therefore imperative that the schematic ID remains consistent throughout the node's entire lifecycle.

### **Custom Builds via Imager**

In air-gapped environments or where maximum customization is required, operators can use Sidero Labs' imager utility to create offline images.12 This tool allows downloading necessary packages, including static network configurations, and integrating Tailscale locally before producing the final boot asset.12

## **Declarative Configuration and Identity Management**

Once the binaries are installed, Tailscale must be configured to join the tailnet. In Talos, this does not happen through manual invocation of tailscale up, but through the ExtensionServiceConfig resource.3

### **Authentication via Auth Keys**

The simplest method is the use of an authentication key pre-generated from the Tailscale control panel.4 There are several types of keys, each suitable for a specific scenario:

* **Reusable Keys:** Ideal for the automatic expansion of worker nodes in a Kubernetes cluster. A single key can authenticate multiple machines.10  
* **Ephemeral Keys:** Recommended for Talos nodes, as they ensure that if a node is destroyed or reset, its entry is automatically removed from the tailnet, avoiding the proliferation of orphaned nodes.10  
* **Pre-approved Keys:** Allow bypassing manual device approval if the tailnet has this feature enabled.22

### **OAuth2 Integration for Advanced Security**

For enterprise-level installations, integration with OAuth2 is the preferred solution.16 Talos Linux supports the OAuth2 authentication flow directly in the kernel parameters or machine configuration.24 By providing a clientId and a clientSecret, the system can negotiate its own access credentials, reducing the need to manage long-lived keys.16

This configuration is inserted into the node's YAML patch file:

YAML

apiVersion: v1alpha1  
kind: ExtensionServiceConfig  
metadata:  
  name: tailscale  
spec:  
  environment:  
    \- TS\_AUTHKEY=tskey-auth-abcdef123456  
    \- TS\_EXTRA\_ARGS=--advertise-tags=tag:talos,tag:k8s \--accept-dns=false

The patch is applied via talosctl patch mc \-p @tailscale-patch.yaml \-n <node-ip>, which forces the parameters to load into the machined daemon and subsequently restarts the extension service.3

## **State Persistence and Identity Stability**

One of the most common issues reported by users is the creation of duplicate nodes in the Tailscale panel after each reboot.11 This happens because the Tailscale state (which includes the node's private key and machine certificate) is usually stored in /var/lib/tailscale, which in system extensions is ephemeral by default.6

### **Persistence Strategies on Immutable Filesystems**

In Talos Linux, the /var directory is mounted on a persistent partition that survives reboots and operating system updates.6 To ensure the stability of the node's identity, the extension must be configured to mount a persistent host directory.3

| Configuration Parameter | Value | Purpose |
| :---- | :---- | :---- |
| TS\_STATE\_DIR | /var/lib/tailscale | Path for storing the node key |
| Mount Source | /var/lib/tailscale | Persistent directory on the Talos host |
| Mount Destination | /var/lib/tailscale | Destination inside the extension container |
| Mount Options | bind, rw | Allows read and write access |

Without this precaution, every Talos update (which involves a reboot and erasure of ephemeral state) would trigger the generation of a new cryptographic identity, breaking static routes and ACL policies configured in the tailnet.11

## **Analysis of Networking Conflicts and Multihoming**

Introducing a virtual network interface like tailscale0 on a host already managing physical interfaces and Kubernetes networking (via CNI) can lead to complex routing conflicts.27

### **The Kubelet and API Server Binding Issue**

By default, Kubernetes attempts to identify the primary IP address of the node for internal cluster communications.27 If Tailscale is started before the physical interface has established a stable connection, or if the Kubelet detects the tailscale0 interface as priority, it might attempt to register the node with the tailnet IP (in the 100.64.0.0/10 range).27

This scenario prevents the CNI (Cilium, Flannel, etc.) from establishing correct tunnels between pods, as encapsulated traffic might attempt to transit through the Tailscale tunnel instead of the local network, causing performance degradation or complete connectivity failure.27

Documented Solution:  
The Talos configuration must explicitly instruct the Kubelet and Etcd to use only local network subnets for cluster traffic.27

YAML

machine:  
  kubelet:  
    nodeIP:  
      validSubnets:  
        \- 192.168.1.0/24  \# Replace with your local subnet  
cluster:  
  etcd:  
    advertisedSubnets:  
      \- 192.168.1.0/24

This configuration ensures that, despite the presence of Tailscale, the Kubernetes control plane and traffic between workers remain on the physical network, while Tailscale is used exclusively for remote access and management.27

### **DNS and resolv.conf Management**

Tailscale often attempts to take control of DNS resolution to enable MagicDNS, a service that allows contacting tailnet nodes via simple hostnames.4 In Talos Linux, the /etc/resolv.conf file is managed deterministically, and external changes are often overwritten.4

Many users report that enabling MagicDNS breaks the resolution of internal Kubernetes names (such as kubernetes.default.svc.cluster.local).27 The technical recommendation is to disable DNS management by Tailscale via the --accept-dns=false flag and, if necessary, configure CoreDNS in the Kubernetes cluster to forward queries for the .ts.net domain to the Tailscale resolver IP (100.100.100.100).15

## **Performance, MTU, and Traffic Optimization**

Tailscale uses a default MTU (Maximum Transmission Unit) value of 1280 bytes.35 This value is chosen to ensure that WireGuard packets (which add encapsulation overhead) do not exceed the standard 1500-byte MTU typical of most Ethernet networks.35

### **Criticalities Related to Packet Fragmentation**

In some environments, such as DSL connections with PPPoE or cellular hotspots, the underlying network MTU might be lower than 1500. In these cases, a 1280 MTU for Tailscale might be too high, leading to packet fragmentation.36 Since WireGuard silently drops fragmented packets for security reasons, TCP sessions (such as SSH or file transfers) might appear "frozen" or extremely slow.35

User experience suggests that manually setting the MTU to 1200 can drastically resolve throughput issues in problematic networks.36

| Network Scenario | Recommended MTU | Optimization Technique |
| :---- | :---- | :---- |
| Standard Ethernet (LAN) | 1280 | Default |
| DSL / PPPoE | 1240 - 1260 | MSS Clamping |
| Mobile Networks (LTE/5G) | 1200 - 1240 | TS\_DEBUG\_MTU |
| Overlay on Overlay (VPN in VPN) | 1100 - 1200 | Manual reduction |

To apply these optimizations on Talos, the TS_DEBUG_MTU environment variable must be used within the ExtensionServiceConfig.36 Furthermore, for traffic passing through the cluster as a Subnet Router, implementing MSS Clamping via firewalling rules is fundamental (although this is complex in Talos without specific extensions for iptables or nftables).35

## **Subnet Router and Exit Node Configuration on Talos**

A Talos node can act as a gateway for the entire cluster or local network, allowing other tailnet members to access resources that cannot run the Tailscale client directly (such as legacy databases, printers, or individual Kubernetes Pods).32

### **Enabling IP Forwarding at the Kernel Level**

The absolute prerequisite for a Subnet Router to function is enabling IP packet forwarding at the kernel level.32 While in standard distributions this is done by modifying /etc/sysctl.conf, in Talos it must be defined in the MachineConfig.8

YAML

machine:  
  sysctls:  
    net.ipv4.ip\_forward: "1"  
    net.ipv6.conf.all.forwarding: "1"

This modification requires a node reboot (or hot application via talosctl apply-config) for the kernel to start routing packets between physical interfaces and the tailscale0 interface.42

### **Advertising Pod and Service Routes**

To expose Kubernetes services, the node must advertise routes corresponding to the cluster CIDRs.32 For example, if the Pod CIDR is 10.244.0.0/16, the Tailscale command must include --advertise-routes=10.244.0.0/16.32

It is important to remember that advertising routes in the command is not enough; they must be manually approved in the Tailscale control panel, unless "Auto Approvers" are configured.32 Using --snat-subnet-routes=false is recommended to preserve the original client IP address in cluster-internal communications, facilitating logging and security monitoring.32

## **Comparative Analysis: System Extension vs. Kubernetes Operator**

There is an ongoing debate among users about the best method for integrating Tailscale into a Talos cluster.3

### **The System Extension Approach**

The extension operates at the host operating system level. It is the preferred solution when the main objective is managing the node itself.3

* **Pros:** Allows accessing the Talos API (port 50000) even if Kubernetes is not running or has crashed.3 It is ideal for the initial bootstrap of the cluster on remote networks.10  
* **Cons:** Requires managing keys and states at the individual node level, increasing administrative overhead if the cluster has many nodes.3

### **The Kubernetes Operator Approach**

The operator is installed within Kubernetes via Helm and manages dedicated Proxy Pods for each service to be exposed.16

* **Pros:** Native Kubernetes integration. Creating a Tailscale-type Ingress automatically generates an entry in the tailnet with the service name.16 Does not require modifications to the Talos MachineConfig.16  
* **Cons:** Does not provide access to the host operating system management.16 If the Kubernetes control plane fails, Tailscale access is cut off.16

### **Hybrid Architecture Recommendation**

For a robust infrastructure, the use of both systems is recommended: the system extension on at least one control plane node for emergency access and administration via talosctl, and the Kubernetes operator to expose applications to end-users in a scalable and granular manner.20

## **Common User-Reported Errors and Documented Resolutions**

Analysis of support threads and GitHub issues highlights a series of "traps" typical of Talos-Tailscale integration.

### **Error 1: Conflicts Between KubeSpan and Tailscale**

KubeSpan is Talos's native solution for mesh networking between nodes, also based on WireGuard.6 While theoretically compatible, simultaneous activation of both can cause performance issues and port conflicts (both might attempt to use UDP port 51820).49

Solution:  
If Tailscale is used for inter-node connectivity, KubeSpan should be disabled.49 Alternatively, Tailscale must be configured to use a different UDP port via the --port flag or allowed to use dynamic NAT negotiation.36

### **Error 2: Breaking Portainer and Other Privileged Agents Networking**

A specific reported case involves Tailscale installation breaking the functioning of Portainer or monitoring agents that rely on inter-pod communication.27 This happens when the agent attempts to join a cluster using the Tailscale IP instead of the pod IP, encountering a "no route to host" error.27

Resolution:  
The error is a direct consequence of the multihoming issue discussed earlier. The definitive solution is setting machine.kubelet.nodeIP.validSubnets to exclude the Tailscale IP range from internal Kubernetes routes.27

### **Error 3: Invalid API Certificates Due to Dynamic IPs**

If a Talos node receives a new IP from the tailnet and the user attempts to connect via that IP, talosctl might return an mTLS certificate validation error.30 Talos generates API certificates including only known IP addresses at the time of bootstrap.28

Solution:  
It is necessary to add Tailscale IP ranges (or MagicDNS names) to the Subject Alternative Names (SAN) list in the MachineConfig.30

YAML

machine:  
  certSANs:  
    \- 100.64.0.0/10  
    \- my-node.tailnet-id.ts.net

## **Future Perspectives and Final Considerations**

The integration of Tailscale on Talos Linux represents the synthesis between the security of an immutable operating system and the flexibility of a modern mesh network. Despite initial challenges related to declarative configuration and multihoming management, the benefits in terms of operational simplicity and security are undeniable.

Community discussions suggest a growing interest in creating even more specialized Talos images, which could include Tailscale directly in the kernel to further reduce the memory footprint and improve cryptographic performance.11 Until then, the OCI extension system remains the most robust and flexible mechanism for extending Talos's network capabilities.9

Operators adopting this stack must prioritize the use of the Image Factory to ensure reproducibility, implement rigorous persistence policies to maintain node identity, and pay close attention to the Kubelet subnet configuration to avoid routing conflicts that could compromise the stability of the entire Kubernetes cluster.3 With these precautions, Tailscale becomes an invisible but fundamental component for orchestrating secure and resilient cloud-native infrastructures.

#### **Bibliography**

1. Talos Linux - The Kubernetes Operating System, accessed on January 6, 2026, [https://www.talos.dev/](https://www.talos.dev/)  
2. siderolabs/talos: Talos Linux is a modern Linux distribution built for Kubernetes. - GitHub, accessed on January 6, 2026, [https://github.com/siderolabs/talos](https://github.com/siderolabs/talos)  
3. Customizing Talos with Extensions - A cup of coffee, accessed on January 6, 2026, [https://a-cup-of.coffee/blog/talos-ext/](https://a-cup-of.coffee/blog/talos-ext/)  
4. Install Tailscale on Linux, accessed on January 6, 2026, [https://tailscale.com/kb/1031/install-linux](https://tailscale.com/kb/1031/install-linux)  
5. System Extensions - Image Factory - Talos Linux, accessed on January 6, 2026, [https://factory.talos.dev/?arch=amd64&platform=metal&target=metal&version=1.7.6](https://factory.talos.dev/?arch=amd64&platform=metal&target=metal&version=1.7.6)  
6. What's New in Talos 1.8.0 - Sidero Documentation - What is Talos Linux?, accessed on January 6, 2026, [https://docs.siderolabs.com/talos/v1.8/getting-started/what's-new-in-talos](https://docs.siderolabs.com/talos/v1.8/getting-started/what's-new-in-talos)  
7. Install talosctl - Sidero Documentation - What is Talos Linux?, accessed on January 6, 2026, [https://docs.siderolabs.com/omni/getting-started/how-to-install-talosctl](https://docs.siderolabs.com/omni/getting-started/how-to-install-talosctl)  
8. MachineConfig - Sidero Documentation - What is Talos Linux?, accessed on January 6, 2026, [https://docs.siderolabs.com/talos/v1.8/reference/configuration/v1alpha1/config](https://docs.siderolabs.com/talos/v1.8/reference/configuration/v1alpha1/config)  
9. Extension Services - Sidero Documentation - What is Talos Linux?, accessed on January 6, 2026, [https://docs.siderolabs.com/talos/v1.8/build-and-extend-talos/custom-images-and-development/extension-services](https://docs.siderolabs.com/talos/v1.8/build-and-extend-talos/custom-images-and-development/extension-services)  
10. Creating a Kubernetes Cluster With Talos Linux on Tailscale | Josh Noll, accessed on January 6, 2026, [https://joshrnoll.com/creating-a-kubernetes-cluster-with-talos-linux-on-tailscale/](https://joshrnoll.com/creating-a-kubernetes-cluster-with-talos-linux-on-tailscale/)  
11. FR: Minimal Purpose-Built OS for Tailscale · Issue #17761 - GitHub, accessed on January 6, 2026, [https://github.com/tailscale/tailscale/issues/17761](https://github.com/tailscale/tailscale/issues/17761)  
12. How to build a Talos system extension - Sidero Labs, accessed on January 6, 2026, [https://www.siderolabs.com/blog/how-to-build-a-talos-system-extension/](https://www.siderolabs.com/blog/how-to-build-a-talos-system-extension/)  
13. Package tailscale - GitHub, accessed on January 6, 2026, [https://github.com/orgs/siderolabs/packages/container/package/tailscale](https://github.com/orgs/siderolabs/packages/container/package/tailscale)  
14. How to make Tailscale container persistant? - ZimaOS - IceWhale Community Forum, accessed on January 6, 2026, [https://community.zimaspace.com/t/how-to-make-tailscale-container-persistant/5987](https://community.zimaspace.com/t/how-to-make-tailscale-container-persistant/5987)  
15. Using Tailscale with Docker, accessed on January 6, 2026, [https://tailscale.com/kb/1282/docker](https://tailscale.com/kb/1282/docker)  
16. Kubernetes operator · Tailscale Docs, accessed on January 6, 2026, [https://tailscale.com/kb/1236/kubernetes-operator](https://tailscale.com/kb/1236/kubernetes-operator)  
17. talosctl - Sidero Documentation - What is Talos Linux?, accessed on January 6, 2026, [https://docs.siderolabs.com/talos/v1.6/reference/cli](https://docs.siderolabs.com/talos/v1.6/reference/cli)  
18. Talos Linux Image Factory, accessed on January 6, 2026, [https://factory.talos.dev/](https://factory.talos.dev/)  
19. siderolabs/extensions: Talos Linux System Extensions - GitHub, accessed on January 6, 2026, [https://github.com/siderolabs/extensions](https://github.com/siderolabs/extensions)  
20. Deploy Talos Linux with Local VIP, Tailscale, Longhorn, MetalLB and Traefik - Josh's Notes, accessed on January 6, 2026, [https://notes.joshrnoll.com/notes/deploy-talos-linux-with-local-vip-tailscale-longhorn-metallb-and-traefik/](https://notes.joshrnoll.com/notes/deploy-talos-linux-with-local-vip-tailscale-longhorn-metallb-and-traefik/)  
21. Securely handle an auth key · Tailscale Docs, accessed on January 6, 2026, [https://tailscale.com/kb/1595/secure-auth-key-cli](https://tailscale.com/kb/1595/secure-auth-key-cli)  
22. Auth keys · Tailscale Docs, accessed on January 6, 2026, [https://tailscale.com/kb/1085/auth-keys](https://tailscale.com/kb/1085/auth-keys)  
23. OAuth clients · Tailscale Docs, accessed on January 6, 2026, [https://tailscale.com/kb/1215/oauth-clients](https://tailscale.com/kb/1215/oauth-clients)  
24. Machine Configuration OAuth2 Authentication - What is Talos Linux?, accessed on January 6, 2026, [https://docs.siderolabs.com/talos/v1.8/security/machine-config-oauth](https://docs.siderolabs.com/talos/v1.8/security/machine-config-oauth)  
25. A collection of scripts for creating and managing kubernetes clusters on talos linux - GitHub, accessed on January 6, 2026, [https://github.com/joshrnoll/talos-scripts](https://github.com/joshrnoll/talos-scripts)  
26. Troubleshooting guide · Tailscale Docs, accessed on January 6, 2026, [https://tailscale.com/kb/1023/troubleshooting](https://tailscale.com/kb/1023/troubleshooting)  
27. Tailscale on Talos os breaks Portainer : r/kubernetes - Reddit, accessed on January 6, 2026, [https://www.reddit.com/r/kubernetes/comments/1izy26m/tailscale\_on\_talos\_os\_breaks\_portainer/](https://www.reddit.com/r/kubernetes/comments/1izy26m/tailscale_on_talos_os_breaks_portainer/)  
28. Production Clusters - Sidero Documentation - What is Talos Linux?, accessed on January 6, 2026, [https://docs.siderolabs.com/talos/v1.7/getting-started/prodnotes](https://docs.siderolabs.com/talos/v1.7/getting-started/prodnotes)  
29. Issues · siderolabs/talos - GitHub, accessed on January 6, 2026, [https://github.com/siderolabs/talos/issues](https://github.com/siderolabs/talos/issues)  
30. Troubleshooting - Sidero Documentation - What is Talos Linux?, accessed on January 6, 2026, [https://docs.siderolabs.com/talos/v1.9/troubleshooting/troubleshooting](https://docs.siderolabs.com/talos/v1.9/troubleshooting/troubleshooting)  
31. Split dns on talos machine config · Issue #7287 · siderolabs/talos - GitHub, accessed on January 6, 2026, [https://github.com/siderolabs/talos/issues/7287](https://github.com/siderolabs/talos/issues/7287)  
32. Subnet routers · Tailscale Docs, accessed on January 6, 2026, [https://tailscale.com/kb/1019/subnets](https://tailscale.com/kb/1019/subnets)  
33. Configure a subnet router · Tailscale Docs, accessed on January 6, 2026, [https://tailscale.com/kb/1406/quick-guide-subnets](https://tailscale.com/kb/1406/quick-guide-subnets)  
34. README.md - michaelbeaumont/k8rn - GitHub, accessed on January 6, 2026, [https://github.com/michaelbeaumont/k8rn/blob/main/README.md](https://github.com/michaelbeaumont/k8rn/blob/main/README.md)  
35. Slow direct connection, get better result with UDP + MTU tweak : r/Tailscale - Reddit, accessed on January 6, 2026, [https://www.reddit.com/r/Tailscale/comments/1p5dxtq/slow\_direct\_connection\_get\_better\_result\_with\_udp/](https://www.reddit.com/r/Tailscale/comments/1p5dxtq/slow_direct_connection_get_better_result_with_udp/)  
36. PSA: Tailscale yields higher throughput if you lower the MTU - Reddit, accessed on January 6, 2026, [https://www.reddit.com/r/Tailscale/comments/1ismen1/psa\_tailscale\_yields\_higher\_throughput\_if\_you/](https://www.reddit.com/r/Tailscale/comments/1ismen1/psa\_tailscale\_yields\_higher\_throughput\_if\_you/)  
37. Unable to lower the MTU · Issue #8219 · tailscale/tailscale - GitHub, accessed on January 6, 2026, [https://github.com/tailscale/tailscale/issues/8219](https://github.com/tailscale/tailscale/issues/8219)  
38. Site-to-site networking · Tailscale Docs, accessed on January 6, 2026, [https://tailscale.com/kb/1214/site-to-site](https://tailscale.com/kb/1214/site-to-site)  
39. Using Tailscale and subnet routers to access legacy devices - Ryan Freeman, accessed on January 6, 2026, [https://ryanfreeman.dev/writing/using-tailscale-and-subnet-routers-to-access-legacy-devices](https://ryanfreeman.dev/writing/using-tailscale-and-subnet-routers-to-access-legacy-devices)  
40. Check Linux IP Forwarding for Access Server Routing - OpenVPN, accessed on January 6, 2026, [https://openvpn.net/as-docs/faq-ip-forwarding-on-linux.html](https://openvpn.net/as-docs/faq-ip-forwarding-on-linux.html)  
41. Setting loadBalancer.acceleration=native causes Cilium Status to report unexpected end of JSON input #35873 - GitHub, accessed on January 6, 2026, [https://github.com/cilium/cilium/issues/35873](https://github.com/cilium/cilium/issues/35873)  
42. 2.5. Turning on Packet Forwarding | Load Balancer Administration - Red Hat Documentation, accessed on January 6, 2026, [https://docs.redhat.com/en/documentation/red\_hat\_enterprise\_linux/6/html/load\_balancer\_administration/s1-lvs-forwarding-vsa](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/6/html/load_balancer_administration/s1-lvs-forwarding-vsa)  
43. Sysctl: net.ipv4.ip\_forward - Linux Audit, accessed on January 6, 2026, [https://linux-audit.com/kernel/sysctl/net/net.ipv4.ip\_forward/](https://linux-audit.com/kernel/sysctl/net/net.ipv4.ip\_forward/)  
44. Rootless podman without privileged flag on talos/Setting max\_user\_namespaces · Issue #4385 - GitHub, accessed on January 6, 2026, [https://github.com/talos-systems/talos/issues/4385](https://github.com/talos-systems/talos/issues/4385)  
45. Set Up a Tailscale Exit Node and Subnet Router on an Ubuntu 24.04 VPS - Onidel, accessed on January 6, 2026, [https://onidel.com/blog/setup-tailscale-exit-node-ubuntu](https://onidel.com/blog/setup-tailscale-exit-node-ubuntu)  
46. Configuring tailscale subnet router using a Linux box and OpnSense : r/homelab - Reddit, accessed on January 6, 2026, [https://www.reddit.com/r/homelab/comments/18zds4l/configuring\_tailscale\_subnet\_router\_using\_a\_linux/](https://www.reddit.com/r/homelab/comments/18zds4l/configuring\_tailscale\_subnet\_router\_using\_a\_linux/)  
47. OpenZiti meets Talos Linux!, accessed on January 6, 2026, [https://openziti.discourse.group/t/openziti-meets-talos-linux/2988](https://openziti.discourse.group/t/openziti-meets-talos-linux/2988)  
48. Is there a better way than system extensions to run simple commands on boot as root? · siderolabs talos · Discussion #9857 - GitHub, accessed on January 6, 2026, [https://github.com/siderolabs/talos/discussions/9857](https://github.com/siderolabs/talos/discussions/9857)  
49. hcloud-talos/terraform-hcloud-talos: This repository contains a Terraform module for creating a Kubernetes cluster with Talos in the Hetzner Cloud. - GitHub, accessed on January 6, 2026, [https://github.com/hcloud-talos/terraform-hcloud-talos](https://github.com/hcloud-talos/terraform-hcloud-talos)  
50. How I Setup Talos Linux. My journey to building a secure… | by Pedro Chang | Medium, accessed on January 6, 2026, [https://medium.com/@pedrotychang/how-i-setup-talos-linux-bc2832ec87cc](https://medium.com/@pedrotychang/how-i-setup-talos-linux-bc2832ec87cc)  
51. Talos VM Setup on macOS ARM64 with QEMU #9799 - GitHub, accessed on January 6, 2026, [https://github.com/siderolabs/talos/discussions/9799](https://github.com/siderolabs/talos/discussions/9799)
