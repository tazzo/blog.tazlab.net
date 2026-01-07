+++
title = "Proxmox Virtual Environment: Architecture, Implementation, and Comparative Analysis towards the Public Cloud"
date = 2026-01-07
draft = false
description = "A deep dive into Proxmox VE, from architecture to advanced configuration, compared with public cloud solutions."
tags = ["proxmox", "virtualization", "hypervisor", "kvm", "lxc", "cloud"]
author = "Tazzo"
+++

The evolution of digital infrastructures has made virtualization a cornerstone not only for large enterprise data centers but also for research contexts and home labs. Proxmox Virtual Environment (VE) stands out in this landscape as an enterprise-class virtualization management platform, completely open-source, which integrates the KVM (Kernel-based Virtual Machine) hypervisor and LXC-based containers (Linux Containers) into a single solution.1 This discussion explores every aspect of the platform in depth, starting from fundamental concepts to advanced configurations for production deployment, while providing a critical analysis compared to public cloud giants such as Amazon Web Services (AWS) and Google Cloud Platform (GCP).

## **Chapter 1: Fundamentals and System Architecture**

Proxmox VE is a type 1 hypervisor, defined as "bare metal," since it is installed directly on the physical hardware without the need for a pre-existing underlying operating system.1 This architecture ensures that machine resources — CPU, RAM, storage, and network connectivity — are managed directly by the virtualization software, drastically reducing overhead and improving overall performance.1

### **The Kernel and the Debian Base**

Proxmox's stability derives from its Debian GNU/Linux base, on which a modified kernel is applied to support critical virtualization and clustering functions.3 Integration with Debian allows Proxmox to benefit from a vast ecosystem of packages and update management via the APT (Advanced Package Tool) tool, making system maintenance familiar for Linux administrators.4

### **The Pillars of Management: pveproxy and pvedaemon**

Proxmox's operation is orchestrated by a series of specialized services working in concert to offer a smooth management interface. The pveproxy service acts as the web interface, operating on port 8006 via the HTTPS protocol.1 This component acts as the main entry point for the user, allowing total control of the datacenter via a browser.1

The pvedaemon, instead, represents the operational engine that executes commands given by the user, such as creating virtual machines or modifying network settings.1 In a cluster environment, pve-cluster comes into play, a service that keeps configurations synchronized between nodes using a cluster file system (pmxcfs).1 This architecture ensures that, should an administrator make a change on a node, that information is instantly available across the entire cluster, ensuring operational integrity.1

| Component | Main Function | Dependencies |
| :---- | :---- | :---- |
| **KVM** | Hypervisor for full virtualization | CPU Extensions (Intel VT-x / AMD-V) |
| **LXC** | Lightweight virtualization via containers | Host kernel sharing |
| **QEMU** | Hardware emulation for VMs | KVM for acceleration |
| **pveproxy** | Web interface server (Port 8006) | SSL certificates |
| **pvedaemon** | Execution of administrative tasks | System APIs |
| **pve-cluster** | Multi-node synchronization | Corosync (Ports 5404/5405) |

1

## **Chapter 2: Virtualization Technologies: KVM vs. LXC**

Proxmox's distinctive strength lies in its ability to offer two complementary virtualization technologies under the same roof, allowing administrators to choose the most suitable tool based on the specific workload.1

### **KVM and QEMU: Full Virtualization**

The KVM/QEMU pairing represents the solution for full virtualization. In this scenario, each virtual machine behaves like an independent physical computer, equipped with its own BIOS/UEFI and an autonomous operating system kernel.1 QEMU handles the emulation of hardware components — such as disk controllers, network cards, and video cards — while KVM leverages the CPU's hardware capabilities to execute guest code at near-native speeds.1

This technology is indispensable for running non-Linux operating systems, such as Microsoft Windows, or Linux instances that require custom kernels or total isolation for security reasons.1 However, full virtualization comes with a cost in terms of resources: each VM requires a dedicated portion of RAM and CPU that cannot be easily shared with other instances, making it less efficient for lightweight services.1

### **LXC: Efficiency and Speed of Containers**

Linux Containers (LXC) offer a radically different approach. Instead of emulating hardware, LXC isolates processes within the host environment, sharing the Proxmox operating system kernel.1 This eliminates the need to boot an entire kernel for each application, reducing boot times to a few seconds and drastically slashing memory and CPU usage.1

Containers are ideal for running standard Linux services, such as Nginx web servers, databases, or nested Docker instances. The main limitation lies in compatibility: a container can only run Linux distributions and cannot have a different kernel from the host's.1 Nevertheless, for scalable workloads, LXC represents the choice of choice for optimizing service density on a single mini PC.1

### **Performance Analysis: Case Studies**

Comparative studies indicate that LXC tends to outperform KVM in CPU and memory-intensive tasks, thanks to lower overhead.8 However, anomalous cases have been detected: in some tests related to Java or Elasticsearch workloads, KVM VMs showed superior performance compared to LXCs or even bare metal hardware.9 This phenomenon is often attributed to how the VM's guest kernel manages process scheduling and memory cache more aggressively than an isolated process in a container would, suggesting that for specific applications, empirical validation is necessary before the final choice.9

| Feature | KVM (Virtual Machine) | LXC (Container) |
| :---- | :---- | :---- |
| **Isolation** | Hardware (Maximum) | Process (High) |
| **Kernel** | Independent | Shared with host |
| **Operating Systems** | Windows, Linux, BSD, etc. | Linux only |
| **Boot Time** | 30-60 seconds | 1-5 seconds |
| **RAM Usage** | Reserved and fixed | Dynamic and shared |
| **Overhead** | Moderate | Minimum |

1

## **Chapter 3: The Storage Stack: Performance and Integrity**

Data management in Proxmox is extremely flexible, supporting both local and distributed storage. For a homelab user on a mini PC, the choice between ZFS and LVM is decisive for hardware performance and longevity.10

### **ZFS: The Gold Standard for Integrity**

ZFS is much more than just a file system; it is a logical volume manager with advanced data protection features.10 The most relevant feature is end-to-end checksumming, which allows for automatically detecting and correcting silent data corruption (bit rot).10 ZFS excels in snapshot management and native replication, allowing for synchronizing VM disks between different Proxmox nodes in minutes.10

However, ZFS is resource-demanding. It requires direct access to disks (HBA mode), making it incompatible with traditional hardware RAID controllers, which should be avoided.10 Furthermore, ZFS uses RAM as a read cache (ARC), recommending at least 8-16 GB of system memory to operate optimally.10

### **LVM and LVM-Thin: Speed and Simplicity**

LVM (Logical Volume Manager) is the traditional option for disk management in Linux. Proxmox implements LVM-Thin to allow for "thin provisioning," or the ability to virtually allocate more space than is physically available.10 LVM is extremely fast and has near-zero CPU and RAM overhead, making it ideal for mini PCs with budget processors or little memory.10 The downside is the lack of protection against bit rot and the absence of native replication between cluster nodes.10

### **Distributed Storage: Ceph and Shared Storage**

For more ambitious multi-node configurations, Proxmox integrates Ceph, a distributed storage system that transforms local disks of multiple servers into a single redundant and highly available storage pool.11 Although Ceph is considered the standard for enterprise production, its implementation on mini PCs requires caution: at least three nodes (preferably five) and fast networks (at least 10GbE) are necessary to avoid bottlenecks and unacceptable latencies.11

| Storage Type | Type | Snapshot | Replication | Redundancy |
| :---- | :---- | :---- | :---- | :---- |
| **ZFS** | Local/Soft RAID | Yes | Yes | Software RAID |
| **LVM-Thin** | Local | Yes | No | No (Requires Hardware RAID) |
| **Ceph** | Distributed | Yes | Yes | Replication between nodes |
| **NFS / iSCSI** | Shared (NAS) | Backend dependent | No | Managed by NAS |

10

## **Chapter 4: Networking and Network Segmentation**

Network configuration in Proxmox is based on the abstraction of physical components into virtual bridges, allowing for granular management of traffic between VMs and the outside world.16

### **Linux Bridge and Naming Convention**

At installation time, Proxmox creates a default bridge named vmbr0, which is linked to the primary physical network card.1 Modern installations use predictive interface names (such as eno1 or enp0s3), which avoid name changes due to kernel updates or hardware modifications.16 These names can be customized by creating .link files in /etc/systemd/network/ to ensure total consistency in multi-node configurations.16

### **VLAN-Aware Bridge: The Segmentation Guide**

To isolate traffic in a home lab (for example, separating IP cameras from production servers), the recommended technique is the use of "VLAN-aware" bridges.17 Instead of creating a separate bridge for each VLAN, a single bridge can handle multiple 802.1Q tags. Once the option is enabled in the bridge settings, simply specify the "VLAN Tag" in the VM's network hardware.17

This approach offers several advantages:

* **Simplicity:** Reduces the complexity of /etc/network/interfaces configuration files.17  
* **Flexibility:** Allows for changing a VM's network without having to modify the host's network infrastructure.17  
* **Security:** Combined with a firewall, it prevents lateral movement between different security zones.17

### **The Role of OpenVSwitch (OVS)**

For even more complex networking scenarios, Proxmox supports OpenVSwitch, a multilayer virtual switch designed to operate in large-scale cluster environments.19 OVS offers advanced monitoring and management features, but requires a separate installation (apt install openvswitch-switch) and manual configuration that may be superfluous for most small labs.19

## **Chapter 5: From Lab to Production: Maintenance and Updates**

Transforming an experimental installation into a production-ready system requires moving to more rigorous management practices, especially regarding security and software integrity.21

### **Repository Management: Enterprise vs. No-Subscription**

Proxmox offers different channels for updates. By default, the system is configured with the "Enterprise" repository, which guarantees extremely stable and tested packages, but requires a paid subscription.3 For users who do not need official support, the "No-Subscription" repository is the correct choice.4

To switch to the free repository on Proxmox 8, it is necessary to modify the files in /etc/apt/sources.list.d/. The correct procedure involves commenting out the enterprise repository and adding the line for no-subscription, ensuring to also include the correct repository for Ceph (even if not used directly, some packages are necessary) to avoid errors during the update.5

**Example configuration for Proxmox 8 (Bookworm):**

```bash
# Disabilitare Enterprise  
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list

# Aggiungere No-Subscription  
cat > /etc/apt/sources.list.d/pve-no-subscription.list << EOF  
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription  
EOF
```

It is fundamental to always use the apt dist-upgrade command instead of apt upgrade to ensure that new kernel packages and Proxmox's structural dependencies are correctly installed.21

### **Hardening and Access Security**

Production system security starts with administrative access. It is recommended to:

* **Disable root login via SSH:** Use non-privileged users with sudo.22  
* **Implement 2FA:** Proxmox natively supports TOTP and WebAuthn for GUI access.6  
* **SSL Certificates:** Replace the self-signed certificate with one issued by Let's Encrypt via the integrated ACME protocol.24

ACME configuration can be performed directly from the GUI under Datacenter > ACME. If Proxmox is not publicly exposed, DNS challenges can be used via plugins for providers such as Cloudflare or DuckDNS, allowing for obtaining valid certificates even in isolated local networks.25

## **Chapter 6: Backup Strategies with Proxmox Backup Server (PBS)**

A system without a backup plan cannot be considered "in production." Proxmox revolutionized this aspect with the launch of Proxmox Backup Server (PBS), a dedicated solution that integrates perfectly with Proxmox VE.28

### **Deduplication and Data Integrity**

Unlike traditional backups (based on .vzdump files), PBS operates at the block level. This means that if ten virtual machines run the same Linux operating system, identical data blocks are saved only once on the backup server.28 The advantages are manifold:

* **Space saving:** Reduction of necessary storage by up to 90% in homogeneous environments.29  
* **Speed:** Incremental backups transfer only modified blocks, reducing execution times from hours to minutes.28  
* **Verification:** PBS allows for scheduling periodic integrity checks (Garbage Collection and Verification) to ensure data is not corrupted.28

### **PBS Implementation**

PBS can be installed on dedicated bare metal hardware or, for testing, as a VM (although not recommended for real production of critical backups of the host hosting it).28 A typical configuration involves a rigorous maintenance schedule:

* **Pruning:** Automatic removal of old backups based on retention rules (e.g., keep 7 daily, 4 weekly).28  
* **Garbage Collection:** Freeing up physical space on the disk after blocks have been marked for deletion by pruning.28

| Operation | Recommended Time | Purpose |
| :---- | :---- | :---- |
| **VM Backup** | 02:00 | Copy guest data |
| **Pruning** | 03:00 | Retention policy application |
| **Garbage Collection** | 03:30 | Physical space recovery |
| **Verification** | 05:00 | Block integrity check |

31

## **Chapter 7: Optimization for Mini PCs and Energy Saving**

Mini PCs are popular for home labs thanks to their low power consumption, but Proxmox is configured by default to maximize performance, which can lead to high temperatures and energy waste.32

### **CPU Governor: Powersave vs. Performance**

By default, Proxmox sets the CPU governor to performance, forcing cores to maximum frequency.33 For mini PCs, it is advisable to change this setting to powersave. Contrary to the name, in modern processors (especially recent Intel Core i5/i7), the powersave governor still allows the CPU to instantly accelerate under load, but drops it to minimum frequencies at idle, saving even 40-50W per node.33

It is possible to automate this change by adding a command to the host's crontab:

```bash
@reboot echo "powersave" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1
```

This ensures that the setting persists after every reboot.33

### **Advanced Power Management: Powertop and ASPM**

To further optimize consumption, tools like powertop can be used to identify components that prevent the CPU from entering deep power-saving states (C-states).32 Often, enabling ASPM (Active State Power Management) in the BIOS or via kernel parameters can halve the idle consumption of mini PCs equipped with Intel or Realtek NICs.33

### **Hardware Passthrough Criticalities**

A common challenge in mini PCs is hardware passthrough, for example, passing a SATA controller or an iGPU to a specific VM. It has been documented that on some models (such as Aoostar), passing the SATA controller can disable the host CPU's thermal management and boosting functions, as the controller is integrated directly into the SoC.37 In these cases, the host loses the ability to read temperature sensors and, for protection, locks the CPU at the base frequency, degrading overall performance.37

## **Chapter 8: Clustering and High Availability (HA)**

Although Proxmox can operate as a single node, its true power emerges in a cluster configuration.

### **The Science of Quorum**

In a Proxmox cluster, stability is guaranteed by the concept of "quorum." Each node has one vote and, for the cluster to be operational, a majority of votes (50% + 1) must be present.38 With only two nodes, if one fails, the cluster loses quorum and services stall to avoid the "split-brain" phenomenon.15

The optimal solution is a three-node cluster.38 If you do not have three identical mini PCs, a "Quorum Device" (QDevice) can be used. A QDevice can be a minimal Linux instance running on a Raspberry Pi or even in a small VM on other hardware, providing the third vote necessary to maintain quorum in a two-primary node setup.15

### **Live Migration and HA**

With shared storage (such as a NAS via NFS) or via ZFS replication, it is possible to perform "Live Migration" of virtual machines from one host to another without service interruptions.13 In the event of a node hardware failure, Proxmox's high availability manager (HA Manager) will detect the node's absence and automatically restart VMs on the surviving hosts, minimizing downtime.15

## **Chapter 9: Proxmox vs. Public Cloud (AWS and GCP)**

Many users wonder why manage their own Proxmox server instead of using ready-to-use services like AWS or GCP. The answer lies in a balance between costs, control, and learning.

### **Cost Analysis (TCO)**

AWS and GCP use a "pay-as-you-go" model that may appear cheap initially, but costs scale quickly.40 For an instance with 8 GB of RAM and 2 vCPUs, the cost in the cloud can hover around 50-70 euros per month.42 A mid-range mini PC for a home lab costs about 300-500 euros; the initial investment thus pays for itself in less than a year of continuous use.42 Furthermore, the cloud charges for outbound data traffic (egress), while in your own lab the only limit is your internet connection's bandwidth.45

### **Privacy and Data Sovereignty**

Proxmox offers total privacy. Data physically resides in the user's mini PC, not on third-party servers subject to foreign regulations or corporate policy changes.44 This is fundamental for managing sensitive data, personal backups, or for those who wish to avoid "vendor lock-in."2

### **Operational Complexity and Learning Curve**

AWS and GCP offer thousands of managed services (databases, AI, global networking) that Proxmox cannot easily replicate.40 However, learning Proxmox means understanding the fundamentals of IT: hypervisors, file systems, Linux networking, and network security.1 These are universal skills that remain valid regardless of the cloud provider used in the future.38

| Dimension | Proxmox VE | AWS / GCP |
| :---- | :---- | :---- |
| **Hardware Control** | Total | None |
| **Egress Costs** | Zero | High |
| **Maintenance** | User (Self-managed) | Provider (Managed) |
| **AI/ML Integration** | Manual | Native services (Vertex AI, SageMaker) |
| **Scalability** | Limited hardware | Virtually infinite |
| **Data Ownership** | User | Service provider |

40

## **Chapter 10: Conclusions and Roadmap for the User**

Proxmox VE represents the perfect bridge between home experimentation and professional reliability. For a user starting from scratch with a mini PC, the path to production follows precise stages that transform a simple hobby into a resilient infrastructure.

The strength of this platform lies not only in its technical capabilities — such as the speed of LXC containers or the integrity of ZFS — but in its community and its open nature. While the public cloud will continue to dominate global-scale scenarios and "cloud-native" applications, Proxmox remains the choice of choice for anyone seeking technological independence, economic efficiency, and granular control over their digital environment.

Implementing Proxmox today means investing in a system that grows with your needs, moving from a single machine to a redundant cluster, protected by state-of-the-art backup and optimized to consume only what is strictly necessary. Whether it's hosting a Home Assistant server, a database for development, or an entire corporate infrastructure, Proxmox VE confirms itself as one of the most complete and powerful virtualization solutions available on the market.

#### **Bibliography**

1. Understanding the Proxmox Architecture: From ESXi to Proxmox VE 8.4 - Dev Genius, accessed on December 29, 2025, [https://blog.devgenius.io/understanding-the-proxmox-architecture-from-esxi-to-proxmox-ve-8-4-0d41d300365a](https://blog.devgenius.io/understanding-the-proxmox-architecture-from-esxi-to-proxmox-ve-8-4-0d41d300365a)  
2. What Is Proxmox? Guide to Open Source Virtualization - CloudFire Srl, accessed on December 29, 2025, [https://www.cloudfire.it/en/blog/proxmox-guida-virtualizzazione-open-source](https://www.cloudfire.it/en/blog/proxmox-guida-virtualizzazione-open-source)  
3. [SOLVED] - Explain please pve-no-subscription | Proxmox Support Forum, accessed on December 29, 2025, [https://forum.proxmox.com/threads/explain-please-pve-no-subscription.102743/](https://forum.proxmox.com/threads/explain-please-pve-no-subscription.102743/)  
4. Package Repositories - Proxmox VE, accessed on December 29, 2025, [https://pve.proxmox.com/wiki/Package_Repositories](https://pve.proxmox.com/wiki/Package_Repositories)  
5. How to Setup Proxmox VE 8.4 Non-Subscription Repositories + ..., accessed on December 29, 2025, [https://ecintelligence.ma/en/blog/how-to-setup-proxmox-ve-84-non-subscription-reposi/](https://ecintelligence.ma/en/blog/how-to-setup-proxmox-ve-84-non-subscription-reposi/)  
6. Proxmox VE Port Requirements: The Complete Guide | Saturn ME, accessed on December 29, 2025, [https://www.saturnme.com/proxmox-ve-port-requirements-the-complete-guide/](https://www.saturnme.com/proxmox-ve-port-requirements-the-complete-guide/)  
7. Firewall Ports Cluster Configuration - Proxmox Support Forum, accessed on December 29, 2025, [https://forum.proxmox.com/threads/firewall-ports-cluster-configuration.16210/](https://forum.proxmox.com/threads/firewall-ports-cluster-configuration.16210/)  
8. Proxmox VE: Performance of KVM vs. LXC - IKUS, accessed on December 29, 2025, [https://ikus-soft.com/en_CA/blog/techies-10/proxmox-ve-performance-of-kvm-vs-lxc-75](https://ikus-soft.com/en_CA/blog/techies-10/proxmox-ve-performance-of-kvm-vs-lxc-75)  
9. Performance of LXC vs KVM - Proxmox Support Forum, accessed on December 29, 2025, [https://forum.proxmox.com/threads/performance-of-lxc-vs-kvm.43170/](https://forum.proxmox.com/threads/performance-of-lxc-vs-kvm.43170/)  
10. Choosing the Right Proxmox Local Storage Format: ZFS vs LVM - Instelligence, accessed on December 29, 2025, [https://www.instelligence.io/blog/2025/08/choosing-the-right-proxmox-local-storage-format-zfs-vs-lvm/](https://www.instelligence.io/blog/2025/08/choosing-the-right-proxmox-local-storage-format-zfs-vs-lvm/)  
11. Proxmox VE Storage Options: Comprehensive Comparison Guide - Saturn ME, accessed on December 29, 2025, [https://www.saturnme.com/proxmox-ve-storage-options-comprehensive-comparison-guide/](https://www.saturnme.com/proxmox-ve-storage-options-comprehensive-comparison-guide/)  
12. [SOLVED] - Performance comparison between ZFS and LVM - Proxmox Support Forum, accessed on December 29, 2025, [https://forum.proxmox.com/threads/performance-comparison-between-zfs-and-lvm.124295/](https://forum.proxmox.com/threads/performance-comparison-between-zfs-and-lvm.124295/)  
13. Proxmox with Local M.2 Storage: The Best Storage & Backup Strategy (No Ceph Needed), accessed on December 29, 2025, [https://www.detectx.com.au/proxmox-with-local-m-2-storage-the-best-storage-backup-strategy-no-ceph-needed/](https://www.detectx.com.au/proxmox-with-local-m-2-storage-the-best-storage-backup-strategy-no-ceph-needed/)  
14. Mini PC Proxmox cluster with ceph, accessed on December 29, 2025, [https://forum.proxmox.com/threads/mini-pc-proxmox-cluster-with-ceph.156601/](https://forum.proxmox.com/threads/mini-pc-proxmox-cluster-with-ceph.156601/)  
15. HA Best Practice | Proxmox Support Forum, accessed on December 29, 2025, [https://forum.proxmox.com/threads/ha-best-practice.157253/](https://forum.proxmox.com/threads/ha-best-practice.157253/)  
16. Network Configuration - Proxmox VE, accessed on December 29, 2025, [https://pve.proxmox.com/wiki/Network_Configuration](https://pve.proxmox.com/wiki/Network_Configuration)  
17. Proxmox VLAN Configuration | Bankai-Tech Docs, accessed on December 29, 2025, [https://docs.bankai-tech.com/Proxmox/Docs/Networking/VLAN%20Configuration](https://docs.bankai-tech.com/Proxmox/Docs/Networking/VLAN%20Configuration)  
18. Proxmox VLAN Configuration: Linux Bridge Tagging, Management IP, and Virtual Machines, accessed on December 29, 2025, [https://www.youtube.com/watch?v=stQzK0p59Fc](https://www.youtube.com/watch?v=stQzK0p59Fc)  
19. Proxmox VLANs Demystified: Step-by-Step Network Isolation for Your Homelab - Medium, accessed on December 29, 2025, [https://medium.com/@P0w3rChi3f/proxmox-vlan-configuration-a-step-by-step-guide-edc838cc62d8](https://medium.com/@P0w3rChi3f/proxmox-vlan-configuration-a-step-by-step-guide-edc838cc62d8)  
20. Proxmox vlan handling - Homelab - LearnLinuxTV Community, accessed on December 29, 2025, [https://community.learnlinux.tv/t/proxmox-vlan-handling/3232](https://community.learnlinux.tv/t/proxmox-vlan-handling/3232)  
21. How to Safely Update Proxmox VE: A Complete Guide - Saturn ME, accessed on December 29, 2025, [https://www.saturnme.com/how-to-safely-update-proxmox-ve-a-complete-guide/](https://www.saturnme.com/how-to-safely-update-proxmox-ve-a-complete-guide/)  
22. Proxmox server hardening document for compliance, accessed on December 29, 2025, [https://forum.proxmox.com/threads/proxmox-server-hardening-document-for-compliance.146961/](https://forum.proxmox.com/threads/proxmox-server-hardening-document-for-compliance.146961/)  
23. [SOLVED] - converting from no subscription repo to subscription - Proxmox Support Forum, accessed on December 29, 2025, [https://forum.proxmox.com/threads/converting-from-no-subscription-repo-to-subscription.164060/](https://forum.proxmox.com/threads/converting-from-no-subscription-repo-to-subscription.164060/)  
24. How to Secure Your Proxmox VE Web Interface with Let's Encrypt SSL - Skynats, accessed on December 29, 2025, [https://www.skynats.com/blog/how-to-secure-your-proxmox-ve-web-interface-with-lets-encrypt-ssl/](https://www.skynats.com/blog/how-to-secure-your-proxmox-ve-web-interface-with-lets-encrypt-ssl/)  
25. Automate Proxmox SSL Certificates with ACME and Dynv6, accessed on December 29, 2025, [https://bitingbytes.de/posts/2025/proxmox-ssl-certificate-with-dynv6/](https://bitingbytes.de/posts/2025/proxmox-ssl-certificate-with-dynv6/)  
26. Managing Certificates in Proxmox VE 8.1: A Step-by-Step Guide - BDRShield, accessed on December 29, 2025, [https://www.bdrshield.com/blog/managing-certificates-in-proxmox-ve-8-1/](https://www.bdrshield.com/blog/managing-certificates-in-proxmox-ve-8-1/)  
27. Step-by-step guide to configure Proxmox Web GUI/API with Let's Encrypt certificate and automatic validation using the ACME protocol in DNS alias mode with DNS TXT validation redirection to Duck DNS. - GitHub Gist, accessed on December 29, 2025, [https://gist.github.com/zidenis/e93532c0e6f91cb75d429f7ac7f66ba5](https://gist.github.com/zidenis/e93532c0e6f91cb75d429f7ac7f66ba5)  
28. Proxmox Backup Server, accessed on December 29, 2025, [https://homelab.casaursus.net/proxmox-backup-server/](https://homelab.casaursus.net/proxmox-backup-server/)  
29. Features - Proxmox Backup Server, accessed on December 29, 2025, [https://www.proxmox.com/en/products/proxmox-backup-server/features](https://www.proxmox.com/en/products/proxmox-backup-server/features)  
30. How To: Proxmox Backup Server 4 (VM) Installation, accessed on December 29, 2025, [https://www.derekseaman.com/2025/08/how-to-proxmox-backup-server-4-vm-installation.html](https://www.derekseaman.com/2025/08/how-to-proxmox-backup-server-4-vm-installation.html)  
31. Proxmox Backup Server - Our Home Lab, accessed on December 29, 2025, [https://homelab.anita-fred.net/pbs/](https://homelab.anita-fred.net/pbs/)  
32. Guide for Proxmox powersaving - Technologie Hub Wien, accessed on December 29, 2025, [https://technologiehub.at/project-posts/tutorial/guide-for-proxmox-powersaving/](https://technologiehub.at/project-posts/tutorial/guide-for-proxmox-powersaving/)  
33. PSA How to configure Proxmox for lower power usage - Home Assistant Community, accessed on December 29, 2025, [https://community.home-assistant.io/t/psa-how-to-configure-proxmox-for-lower-power-usage/323731](https://community.home-assistant.io/t/psa-how-to-configure-proxmox-for-lower-power-usage/323731)  
34. CPU power throttle back to save energy - Proxmox Support Forum, accessed on December 29, 2025, [https://forum.proxmox.com/threads/cpu-power-throttle-back-to-save-energy.27510/](https://forum.proxmox.com/threads/cpu-power-throttle-back-to-save-energy.27510/)  
35. gaming rig to run proxmox server - how do i lower my idle power? - Reddit, accessed on December 29, 2025, [https://www.reddit.com/r/Proxmox/comments/1fwphxw/gaming\_rig\_to\_run\_proxmox\_server\_how\_do\_i\_lower/](https://www.reddit.com/r/Proxmox/comments/1fwphxw/gaming_rig_to_run_proxmox_server_how_do_i_lower/)  
36. Powersaving tutorial : r/Proxmox - Reddit, accessed on December 29, 2025, [https://www.reddit.com/r/Proxmox/comments/1nultme/powersaving\_tutorial/](https://www.reddit.com/r/Proxmox/comments/1nultme/powersaving_tutorial/)  
37. WTR Pro CPU throttling - Proxmox Support Forum, accessed on December 29, 2025, [https://forum.proxmox.com/threads/wtr-pro-cpu-throttling.160039/](https://forum.proxmox.com/threads/wtr-pro-cpu-throttling.160039/)  
38. How to Set Up a Proxmox Cluster for Free – Virtualization Basics - freeCodeCamp, accessed on December 29, 2025, [https://www.freecodecamp.org/news/set-up-a-proxmox-cluster-virtualization-basics/](https://www.freecodecamp.org/news/set-up-a-proxmox-cluster-virtualization-basics/)  
39. Building a Highly Available (HA) two-node Home Lab on Proxmox - Jon, accessed on December 29, 2025, [https://jon.sprig.gs/blog/post/2885](https://jon.sprig.gs/blog/post/2885)  
40. AWS Vs. GCP: Which Platform Offers Better Pricing? - CloudZero, accessed on December 29, 2025, [https://www.cloudzero.com/blog/aws-vs-gcp/](https://www.cloudzero.com/blog/aws-vs-gcp/)  
41. AWS vs GCP vs Azure: Which Cloud Platform is Best for Mid-Size Businesses? - Qovery, accessed on December 29, 2025, [https://www.qovery.com/blog/aws-vs-gcp-vs-azure](https://www.qovery.com/blog/aws-vs-gcp-vs-azure)  
42. What's the Difference Between AWS vs. Azure vs. Google Cloud? - Coursera, accessed on December 29, 2025, [https://www.coursera.org/articles/aws-vs-azure-vs-google-cloud](https://www.coursera.org/articles/aws-vs-azure-vs-google-cloud)  
43. I set up a tiny PC Proxmox cluster! : r/homelab - Reddit, accessed on December 29, 2025, [https://www.reddit.com/r/homelab/comments/15gkr1r/i\_set\_up\_a\_tiny\_pc\_proxmox\_cluster/](https://www.reddit.com/r/homelab/comments/15gkr1r/i\_set\_up\_a_tiny_pc_proxmox_cluster/)  
44. Compare Google Compute Engine vs Proxmox VE 2025 | TrustRadius, accessed on December 29, 2025, [https://www.trustradius.com/compare-products/google-compute-engine-vs-proxmox-ve](https://www.trustradius.com/compare-products/google-compute-engine-vs-proxmox-ve)  
45. Cloud Comparison AWS vs Azure vs GCP – Networking & Security - Exeo, accessed on December 29, 2025, [https://exeo.net/en/networking-security-cloud-comparison-aws-vs-azure-vs-gcp/](https://exeo.net/en/networking-security-cloud-comparison-aws-vs-azure-vs-gcp/)  
46. AWS vs GCP: Unraveling the cloud conundrum - Proxify, accessed on December 29, 2025, [https://proxify.io/articles/aws-vs-gcp](https://proxify.io/articles/aws-vs-gcp)  
47. AWS vs GCP - Which One to Choose in 2025? - ProjectPro, accessed on December 29, 2025, [https://www.projectpro.io/article/aws-vs-gcp-which-one-to-choose/477](https://www.projectpro.io/article/aws-vs-gcp-which-one-to-choose/477)  
48. AWS vs. GCP: A Developer's Guide to Picking the Right Cloud - DEV Community, accessed on December 29, 2025, [https://dev.to/shrsv/aws-vs-gcp-a-developers-guide-to-picking-the-right-cloud-59a1](https://dev.to/shrsv/aws-vs-gcp-a-developers-guide-to-picking-the-right-cloud-59a1)
