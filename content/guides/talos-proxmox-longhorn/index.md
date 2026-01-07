+++
title = "Technical Architecture and Implementation of Longhorn on Kubernetes with Talos OS in Proxmox Virtualized Environments"
date = 2026-01-07
draft = false
description = "A complete guide to deploying Longhorn block storage on a Talos Kubernetes cluster running on Proxmox VE."
tags = ["talos", "longhorn", "proxmox", "storage", "kubernetes", "distributed-storage"]
author = "Tazzo"
+++

The evolution of IT infrastructures towards fully declarative and immutable paradigms has found one of its most advanced expressions in the combination of Talos OS and Kubernetes. However, adopting an immutable and shell-less operating system introduces significant challenges when integrating distributed block storage solutions like Longhorn. This technical report comprehensively analyzes the entire installation lifecycle, starting from the configuration of the Proxmox VE hypervisor, moving through the customization of Talos OS via system extensions, up to the production deployment of Longhorn, with a particular focus on performance optimization and the resolution of networking and mounting issues.

## **Hypervisor Configuration: Proxmox VE as the Cluster Foundation**

The stability of a distributed Kubernetes cluster depends largely on the correct configuration of the underlying virtual machines. Proxmox VE offers remarkable flexibility but requires specific settings to meet the rigorous requirements of Talos OS and the input/output (I/O) needs of Longhorn.

### **CPU Microarchitecture Requirements and Necessary Instructions**

Starting from version 1.0, Talos OS explicitly requires the x86-64-v2 microarchitecture. This requirement is fundamental as many default Proxmox installations use the `kvm64` CPU type to maximize compatibility during live migration, but this model lacks critical instructions such as `cx16`, `popcnt`, and `sse4.2`, which are necessary for the correct functioning of the Talos kernel and binaries.1

The choice of processor type within Proxmox directly influences Longhorn's ability to perform encryption and volume management operations. The recommended setting is `host`, which exposes all physical CPU capabilities to the virtual machine, ensuring maximum performance for the storage engine.1 If live migration between nodes with different CPUs is a requirement, the administrator must manually configure CPU flags in the VM configuration file `/etc/pve/qemu-server/<vmid>.conf` by adding the string `args: -cpu kvm64,+cx16,+lahf_lm,+popcnt,+sse3,+ssse3,+sse4.1,+sse4.2`.1

| CPU Parameter | Recommended Value | Technical Impact |
| :---- | :---- | :---- |
| Processor Type | host | Native x86-64-v2 support and superior cryptographic performance.1 |
| Cores (Control Plane) | Minimum 2 | Necessary for managing system processes and etcd.1 |
| Cores (Worker Node) | 4 or more | Support for Longhorn V2 engine polling and workloads.4 |
| NUMA | Enabled | Optimization of memory access on multi-socket servers.6 |

### **Memory Management and SCSI Controller**

Talos OS is designed to operate entirely in RAM during critical phases, which makes memory management a potential point of failure. A known limitation of Talos concerns the lack of support for memory hot-plugging. If this feature is enabled in Proxmox, Talos will not be able to correctly detect the total allocated memory, leading to installation errors due to insufficient memory.1 The minimum RAM allocation must be 2 GB for control plane nodes and preferably 8 GB for worker nodes hosting Longhorn, as the latter requires resources for data replication and management of instance manager pods.4

Regarding storage, the `VirtIO SCSI single` controller is the preferred choice. This configuration allows for the use of dedicated I/O threads for each virtual disk, reducing contention between processes and improving latency, a critical factor when Longhorn must replicate data blocks across multiple nodes over the network.6 Enabling the `Discard` option on the virtual disk is equally essential to allow the guest operating system to send TRIM commands, ensuring that the underlying storage (especially if based on ZFS or LVM-thin in Proxmox) can reclaim unused space.7

## **Talos OS Provisioning: Immutability and Customization**

The immutable nature of Talos OS implies that it is not possible to install software or drivers after boot via traditional channels like `apt` or `yum`. Therefore, the preparation of the installation image must pre-emptively include all necessary tools for Longhorn.

### **Using the Image Factory and System Extensions**

Longhorn depends on binaries and daemons that usually reside at the host level, such as `iscsid` for volume connection and various filesystem management tools. In Talos, these dependencies are met through "System Extensions". Sidero Labs' Image Factory allows for generating custom ISOs and installers that integrate these extensions directly into the system image.1

Indispensable extensions for a working Longhorn installation include:

* `siderolabs/iscsi-tools`: provides the `iscsid` daemon and the `iscsiadm` utility, necessary for mapping Longhorn volumes as local block devices.4  
* `siderolabs/util-linux-tools`: includes tools like `fstrim`, used for filesystem maintenance and reducing the space occupation of volumes.4  
* `siderolabs/qemu-guest-agent`: fundamental in Proxmox environments to allow the hypervisor to communicate with the guest, facilitating clean shutdowns and correct display of IP addresses in the management console.1

The image generation process produces a unique schematic ID, which ensures that every node in the cluster is configured identically, fundamentally eliminating the problem of configuration drift.9

### **Cluster Bootstrapping and Declarative Configuration**

Once the Proxmox VMs are booted with the custom ISO, the cluster enters a maintenance mode awaiting configuration. Interaction occurs exclusively through the `talosctl` utility from the administrator's terminal. Configuration file generation is done via the `talosctl gen config` command, specifying the control plane endpoint.1

During the modification phase of the `controlplane.yaml` and `worker.yaml` files, it is crucial to verify the installation disk identifier. In Proxmox, depending on the controller used, the disk might appear as `/dev/sda` or `/dev/vda`. Using the command `talosctl get disks --insecure --nodes <IP>` allows for certain identification of the correct device before applying the configuration.1

Cluster bootstrapping follows a rigorous sequence:

1. Application of the configuration to the control plane node: `talosctl apply-config --insecure --nodes $CP_IP --file controlplane.yaml`.1  
2. Cluster initialization (ETCD Bootstrap): `talosctl bootstrap --nodes $CP_IP`.1  
3. Retrieval of the `kubeconfig` file for administrative access to Kubernetes via `kubectl`.1

## **Longhorn Integration: Requirements and Volume Architecture**

Installing Longhorn on Talos requires meticulous attention to privilege management and filesystem path visibility, as Talos isolates control plane processes and system services into separate mount namespaces.

### **Kernel Modules and Machine Parameters**

Longhorn requires certain kernel modules to be loaded to manage virtual block devices and iSCSI communication. Since Talos does not load all modules by default, they must be explicitly declared in the `kernel` section of the worker nodes' machine configuration.11

Required modules include `nbd` (Network Block Device), `iscsi_tcp`, `iscsi_generic`, and `configfs`.11 Their inclusion ensures that the Longhorn manager can correctly create devices under `/dev`, which will then be mounted by application pods.

```yaml
machine:
  kernel:
    modules:
      - name: nbd
      - name: iscsi_tcp
      - name: iscsi_generic
      - name: configfs
```

This configuration snippet, once applied, forces the node to reboot to load the necessary modules, making the system ready for distributed storage.11

### **Mount Propagation and Kubelet Extra Mounts**

One of the most common technical hurdles in installing Longhorn on Talos is the isolation of the `kubelet` process. In Talos, `kubelet` runs inside a container and, by default, has no visibility of user-mounted disks or specific host directories needed for CSI (Container Storage Interface) operations.10

To solve this problem, it is necessary to configure `extraMounts` for the `kubelet`. This setting ensures that the path where Longhorn stores data is mapped inside the `kubelet` namespace with mount propagation set to `rshared`.4 Without this configuration, Kubernetes would be unable to attach Longhorn volumes to application pods, resulting in "MountVolume.SetUp failed" errors.14

| Host Path | Kubelet Path | Mount Options | Function |
| :---- | :---- | :---- | :---- |
| /var/lib/longhorn | /var/lib/longhorn | bind, rshared, rw | Default path for volume data.15 |
| /var/mnt/sdb | /var/mnt/sdb | bind, rshared, rw | Used if a second dedicated disk is employed.4 |

`rshared` propagation is fundamental: it allows a mount performed inside a container (like the Longhorn CSI plugin) to be visible to the host and, consequently, to other containers managed by the `kubelet`.15

## **Storage Strategy: Secondary Disks and Persistence**

Although Longhorn can technically store data on Talos's `EPHEMERAL` partition, this practice is discouraged for production environments. Talos's system partition is subject to changes during operating system updates, and using a secondary disk offers a clear separation between application data and the immutable operating system.4

### **Advantages of Using Dedicated Disks in Proxmox**

Adding a second virtual disk (e.g., `/dev/sdb`) in Proxmox for each worker node offers several architectural advantages. First, it isolates storage I/O traffic from system traffic, reducing latency for sensitive applications. Second, it allows for simplified space management: if a node runs out of space for Longhorn volumes, the virtual disk in Proxmox can be expanded without interfering with Talos's critical partitions.4

To implement this strategy, the Talos configuration must include instructions to format and mount the additional disk at boot:

```yaml
machine:
  disks:
    - device: /dev/sdb
      partitions:
        - mountpoint: /var/mnt/sdb
```

Once the disk is mounted at `/var/mnt/sdb`, this path must be communicated to Longhorn during installation via the Helm values file, setting `defaultDataPath` to that directory.4

### **Disk Format Analysis: RAW vs QCOW2**

The choice of image file format in Proxmox directly impacts the performance of Longhorn, which already internally implements replication and snapshotting mechanisms.

| Feature | RAW | QCOW2 |
| :---- | :---- | :---- |
| Performance | Maximum (no metadata overhead).18 | Lower (overhead due to Copy-on-Write).8 |
| Space Management | Occupies the entire allocated space (if not supported by FS holes).19 | Supports native thin provisioning.8 |
| Hypervisor Snapshots | Not natively supported on file storage.19 | Natively supported.8 |

In an architecture where Longhorn manages redundancy at the cluster level, using the `RAW` format is often preferred to avoid the "double snapshotting" phenomenon and reduce write latency.18 However, if the underlying Proxmox infrastructure is based on ZFS, it is crucial to avoid using `QCOW2` on top of ZFS to prevent massive write amplification, which would rapidly degrade SSD performance.20

## **Software Implementation and Configuration of Longhorn**

After preparing the Talos infrastructure, Longhorn installation typically occurs via Helm or GitOps operators like Flux or ArgoCD.

### **Security and Privileged Namespace**

Due to the low-level operations it must perform, Longhorn requires elevated privileges. With the introduction of Pod Security Standards in Kubernetes, it is imperative to correctly label the `longhorn-system` namespace to allow pods to run in privileged mode.11

Applying the following manifest ensures that Longhorn components are not blocked by the admission controller:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: longhorn-system
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

This step is critical: without it, the Longhorn manager pods or CSI plugins would fail to start, leaving the system in a perpetual waiting state.11

### **Recommended Helm Installation Parameters**

During Helm installation, some parameters must be adapted for the Talos-Proxmox environment. Using a custom `values.yaml` file allows for automating these settings:

* `defaultSettings.defaultDataPath`: set to the secondary disk path (e.g., `/var/mnt/sdb`).4  
* `defaultSettings.numberOfReplicas`: usually set to 3 to ensure high availability.4  
* `defaultSettings.createDefaultDiskLabeledNodes`: if set to true, allows selecting only specific nodes as storage nodes via Kubernetes labels.4

Additionally, to avoid issues during updates in Talos environments, it is often recommended to disable the `preUpgradeChecker` if it causes inexplicable blocks due to the immutable nature of the host filesystem.11

## **Performance Optimization and Networking**

Distributed storage is inherently dependent on network performance. In a Proxmox virtualized environment, the configuration of bridges and VirtIO interfaces can make the difference between a responsive system and one plagued by timeouts.

### **MTU Issues and Packet Fragmentation**

A common error in Proxmox configurations concerns MTU (Maximum Transmission Unit) mismatch. If the physical Proxmox bridge is configured for Jumbo Frames (MTU 9000) to optimize storage traffic, but the Talos VM interfaces are left at the default value of 1500, packet fragmentation will occur, drastically increasing CPU usage and reducing throughput for Longhorn volumes.23

MTU consistency must be guaranteed along the entire path:

1. Physical switch and Proxmox server NIC.  
2. Linux Bridge (`vmbr0`) or OVS Bridge in Proxmox.  
3. Network configuration in the Talos OS YAML file.  
4. CNI configuration (e.g., Cilium or Flannel) inside Kubernetes.23

In some recent Proxmox versions (8.2+), bugs related to MTU management with VirtIO drivers have been reported, which can cause TCP connections to hang during intensive transfers. In these cases, forcing the MTU to 1500 at all levels can resolve inexplicable instabilities, at the cost of a slight reduction in efficiency.24

### **V2 Engine and SPDK: High Resource Requirements**

Longhorn has introduced a new storage engine (V2) based on SPDK (Storage Performance Development Kit). Although it offers superior performance, the requirements for Talos nodes increase significantly. The V2 engine uses polling-mode drivers instead of interrupt-based ones, meaning that instance management processes will consume 100% of a dedicated CPU core to minimize latency.5

V2 engine requirements on Talos:

* **Huge Pages**: it is necessary to configure the allocation of large memory pages (2 MiB) via `sysctl` in the Talos configuration (e.g., 1024 pages for a total of 2 GiB).5  
* **CPU Instructions**: SSE4.2 support is mandatory, reinforcing the need for the `host` CPU type in Proxmox.5

Activating the V2 engine must be a weighed choice based on the workload: for high-performance databases, it is recommended, while for general workloads, the V1 engine remains more resource-efficient.5

## **Operational Management: Updates, Backup, and Troubleshooting**

Maintaining a Longhorn cluster on Talos requires an understanding of specific workflows for immutable systems.

### **Managing Talos OS Updates**

Updating a Talos node involves rebooting the virtual machine with a new image. During this process, Longhorn must handle the temporary unavailability of a replica.

Safe update procedure:

1. Verify that all Longhorn volumes are in "Healthy" state and have the full number of replicas.  
2. Perform the update one node at a time using `talosctl upgrade`.  
3. Wait for the node to rejoin the Kubernetes cluster and for Longhorn to complete replica rebuilding before proceeding to the next node.9

It is fundamental that the image used for the update contains the same system extensions (`iscsi-tools`) as the original image; otherwise, Longhorn will lose the ability to communicate with the disks upon the first reboot.9

### **Data Backup and Disaster Recovery**

Although Proxmox allows for backing up the entire VM, for data contained in Longhorn volumes, it is preferable to use the solution's native backup function. Longhorn can export snapshots to an external archive (S3 or NFS).11

In a Talos environment, if NFS is chosen as the backup target, it is necessary to ensure that the NFSv4 client extension is present in the system image or that kernel support is enabled.15 Configuring a default `BackupTarget` is a best practice that avoids volume initialization errors in some Longhorn versions.11

### **Common Troubleshooting**

A frequent issue concerns nodes being unable to join the cluster after configuration application, often manifesting as an infinite "Installing" status in the Proxmox console. This is usually due to networking issues (wrong gateway, lack of DHCP, or non-functional DNS) that prevent Talos from downloading the final installation image.28 Using static IP addresses reserved via MAC address in the DHCP server is the recommended solution to ensure consistency during the multiple reboots of the installation process.3

Another critical error is "Missing Kind" when using `talosctl patch`. This happens if the YAML patch file does not include `apiVersion` and `kind` headers. Talos requires every patch to be a valid Kubernetes object or that the structure exactly matches the schema expected for the specific resource.9

## **I/O Performance Modeling in Virtualized Environments**

Longhorn's performance can be mathematically analyzed considering the latencies introduced by various layers of abstraction. Total write latency ($L_{total}$) in a configuration with synchronous replication can be expressed as:

$$L_{total} \approx L_{virt} + L_{fs\_guest} + \max(L_{net\_RTT} + L_{io\_remote})$$  
Where:

* $L_{virt}$: latency introduced by the Proxmox hypervisor and the VirtIO driver.  
* $L_{fs\_guest}$: filesystem overhead inside the VM (e.g., XFS or Ext4).  
* $L_{net\_RTT}$: network round-trip time between worker nodes for block replication.  
* $L_{io\_remote}$: write latency on the physical disk of the remote node.

In a 1 Gbps network, $L_{net\_RTT}$ can become the primary bottleneck, especially under heavy load. Adopting a 10 Gbps network drastically reduces this value, allowing Longhorn to approach the performance of local storage.23

## **Summary and Final Recommendations**

Implementing Longhorn on a Kubernetes cluster based on Talos OS and Proxmox represents an excellent solution for managing stateful workloads in modern environments. The key to success lies in the meticulous preparation of the infrastructure layer and understanding Talos's declarative nature.

The following actions are recommended for optimal production deployment:

1. **Pre-emptive Customization**: Always integrate `iscsi-tools` and `util-linux-tools` into Talos images via the Image Factory to avoid runtime issues.4  
2. **Hardware Configuration**: Use the `host` CPU type and dedicated SCSI controllers with I/O threads enabled in Proxmox.1  
3. **Data Separation**: Always implement secondary disks for Longhorn data storage, avoiding the use of the system partition.4  
4. **Network Monitoring**: Ensure MTU consistency across all virtual and physical network levels to prevent performance degradation.23  
5. **Declarative Security**: Manage all configurations, including extra mounts and kernel modules, via versioned YAML files, fully leveraging the GitOps philosophy supported by Talos.29

This architecture, although requiring a higher initial learning curve compared to traditional Linux distributions, offers security and reproducibility guarantees that make it ideal for the challenges of modern software engineering.

#### **Bibliography**

1. Proxmox - Sidero Documentation - What is Talos Linux?, accessed on December 30, 2025, [https://docs.siderolabs.com/talos/v1.9/platform-specific-installations/virtualized-platforms/proxmox](https://docs.siderolabs.com/talos/v1.9/platform-specific-installations/virtualized-platforms/proxmox)  
2. Talos on Proxmox, accessed on December 30, 2025, [https://homelab.casaursus.net/talos-on-proxmox-3/](https://homelab.casaursus.net/talos-on-proxmox-3/)  
3. Talos with Kubernetes on Proxmox - Secsys, accessed on December 30, 2025, [https://secsys.pages.dev/posts/talos/](https://secsys.pages.dev/posts/talos/)  
4. Storage Solution: Longhorn, accessed on December 30, 2025, [https://www.xelon.ch/en/docs/storage-solution-longhorn](https://www.xelon.ch/en/docs/storage-solution-longhorn)  
5. Longhorn | Prerequisites, accessed on December 30, 2025, [https://longhorn.io/docs/1.10.1/v2-data-engine/prerequisites/](https://longhorn.io/docs/1.10.1/v2-data-engine/prerequisites/)  
6. Best CPU Settings for a VM? I want best Per Thread Performance from 13,900k : r/Proxmox, accessed on December 30, 2025, [https://www.reddit.com/r/Proxmox/comments/16i7i2w/best_cpu_settings_for_a_vm_i_want_best_per_thread/](https://www.reddit.com/r/Proxmox/comments/16i7i2w/best_cpu_settings_for_a_vm_i_want_best_per_thread/)  
7. Windows 2022 guest best practices - Proxmox VE, accessed on December 30, 2025, [https://pve.proxmox.com/wiki/Windows_2022_guest_best_practices](https://pve.proxmox.com/wiki/Windows_2022_guest_best_practices)  
8. Using the QCOW2 disk format in Proxmox - 4sysops, accessed on December 30, 2025, [https://4sysops.com/archives/using-the-qcow2-disk-format-in-proxmox/](https://4sysops.com/archives/using-the-qcow2-disk-format-in-proxmox/)  
9. Improve Documentation for Longhorn and System Extensions ..., accessed on December 30, 2025, [https://github.com/siderolabs/talos/issues/12064](https://github.com/siderolabs/talos/issues/12064)  
10. Install Longhorn on Talos Kubernetes - HackMD, accessed on December 30, 2025, [https://hackmd.io/@QI-AN/Install-Longhorn-on-Talos-Kubernetes](https://hackmd.io/@QI-AN/Install-Longhorn-on-Talos-Kubernetes)  
11. Installing Longhorn on Talos Linux: A Step-by-Step Guide - Phin3has Tech Blog, accessed on December 30, 2025, [https://phin3has.blog/posts/talos-longhorn/](https://phin3has.blog/posts/talos-longhorn/)  
12. A collection of scripts for creating and managing kubernetes clusters on talos linux - GitHub, accessed on December 30, 2025, [https://github.com/joshrnoll/talos-scripts](https://github.com/joshrnoll/talos-scripts)  
13. Automating Talos Installation on Proxmox with Packer and Terraform, Integrating Cilium and Longhorn | Suraj Remanan, accessed on December 30, 2025, [https://surajremanan.com/posts/automating-talos-installation-on-proxmox-with-packer-and-terraform/](https://surajremanan.com/posts/automating-talos-installation-on-proxmox-with-packer-and-terraform/)  
14. Why are Kubelet extra mounts for Longhorn needed? · siderolabs talos · Discussion #9674, accessed on December 30, 2025, [https://github.com/siderolabs/talos/discussions/9674](https://github.com/siderolabs/talos/discussions/9674)  
15. Longhorn | Quick Installation, accessed on December 30, 2025, [https://longhorn.io/docs/1.10.1/deploy/install/](https://longhorn.io/docs/1.10.1/deploy/install/)  
16. Kubernetes - Reddit, accessed on December 30, 2025, [https://www.reddit.com/r/kubernetes/hot/](https://www.reddit.com/r/kubernetes/hot/)  
17. Longhorn | Multiple Disk Support, accessed on December 30, 2025, [https://longhorn.io/docs/1.10.1/nodes-and-volumes/nodes/multidisk/](https://longhorn.io/docs/1.10.1/nodes-and-volumes/nodes/multidisk/)  
18. Which is better image format, raw or qcow2, to use as a baseimage for other VMs?, accessed on December 30, 2025, [https://serverfault.com/questions/677639/which-is-better-image-format-raw-or-qcow2-to-use-as-a-baseimage-for-other-vms](https://serverfault.com/questions/677639/which-is-better-image-format-raw-or-qcow2-to-use-as-a-baseimage-for-other-vms)  
19. Raw vs Qcow2 Image | Storware BLOG, accessed on December 30, 2025, [https://storware.eu/blog/raw-vs-qcow2-image/](https://storware.eu/blog/raw-vs-qcow2-image/)  
20. RAW or QCOW2 ? : r/Proxmox - Reddit, accessed on December 30, 2025, [https://www.reddit.com/r/Proxmox/comments/1jh4rlp/raw_or_qcow2/](https://www.reddit.com/r/Proxmox/comments/1jh4rlp/raw_or_qcow2/)  
21. Performance Tweaks - Proxmox VE, accessed on December 30, 2025, [https://pve.proxmox.com/wiki/Performance_Tweaks](https://pve.proxmox.com/wiki/Performance_Tweaks)  
22. Longhorn - Rackspace OpenStack Documentation, accessed on December 30, 2025, [https://docs.rackspacecloud.com/storage-longhorn/](https://docs.rackspacecloud.com/storage-longhorn/)  
23. Strange Issue Using Virtio on 10Gb Network Adapters | Page 2 | Proxmox Support Forum, accessed on December 30, 2025, [https://forum.proxmox.com/threads/strange-issue-using-virtio-on-10gb-network-adapters.167666/page-2](https://forum.proxmox.com/threads/strange-issue-using-virtio-on-10gb-network-adapters.167666/page-2)  
24. qemu virtio issues after upgrade to 9 - Proxmox Support Forum, accessed on December 30, 2025, [https://forum.proxmox.com/threads/qemu-virtio-issues-after-upgrade-to-9.169625/](https://forum.proxmox.com/threads/qemu-virtio-issues-after-upgrade-to-9.169625/)  
25. working interface fails when added to bridge - Proxmox Support Forum, accessed on December 30, 2025, [https://forum.proxmox.com/threads/working-interface-fails-when-added-to-bridge.106271/](https://forum.proxmox.com/threads/working-interface-fails-when-added-to-bridge.106271/)  
26. qemu virtio issues after upgrade to 9 | Page 2 - Proxmox Support Forum, accessed on December 30, 2025, [https://forum.proxmox.com/threads/qemu-virtio-issues-after-upgrade-to-9.169625/page-2](https://forum.proxmox.com/threads/qemu-virtio-issues-after-upgrade-to-9.169625/page-2)  
27. Installing Longhorn on Talos With Helm - Josh Noll, accessed on December 30, 2025, [https://joshrnoll.com/installing-longhorn-on-talos-with-helm/](https://joshrnoll.com/installing-longhorn-on-talos-with-helm/)  
28. Completely unable to configure Talos in a Proxmox VM · siderolabs ..., accessed on December 30, 2025, [https://github.com/siderolabs/talos/discussions/9291](https://github.com/siderolabs/talos/discussions/9291)  
29. What Longhorn Talos Actually Does and When to Use It - hoop.dev, accessed on December 30, 2025, [https://hoop.dev/blog/what-longhorn-talos-actually-does-and-when-to-use-it/](https://hoop.dev/blog/what-longhorn-talos-actually-does-and-when-to-use-it/)
