+++
title = "Strategies and architectures for storage management in Kubernetes: technical analysis of volumes, persistence, and cloud-native operations"
date = 2026-01-08
draft = false
description = "A technical analysis of Kubernetes volumes, persistence, and cloud-native operations."
tags = ["kubernetes", "storage", "volumes", "persistence", "csi", "statefulset"]
author = "Tazzo"
+++

The evolution of container orchestration has radically transformed the paradigm of state management in distributed applications. Within the Kubernetes ecosystem, storage management no longer represents a simple infrastructure accessory, but constitutes the critical foundation upon which the reliability of enterprise applications rests.1 Although containers were originally conceived as ephemeral and stateless entities, the operational reality of modern workloads requires that data survive not only the crashes of individual processes, but also the rescheduling of Pods across different nodes of the cluster.3 This technical analysis explores in depth the taxonomy of Kubernetes volumes, abstraction mechanisms, advanced YAML configurations, and optimization strategies for complex production scenarios.

## **Analysis of the YAML format and declarative orchestration**

Before delving into storage specifics, it is essential to understand the primary communication tool of Kubernetes: the YAML format (YAML Ain't Markup Language). The choice of this serialization format is not accidental; it responds to the need for a human-readable syntax that allows defining the desired state of the infrastructure in a declarative way.6 YAML excels in representing complex hierarchical data structures, fundamental for describing relationships between storage components and workloads.6

YAML syntax is based on key-value pairs and lists, where indentation (strictly performed with spaces and never with tabs) determines the hierarchy of elements.6 This structure is vital for defining volume specifications within Pod manifests. For example, the use of anchors (&) and aliases (*) in YAML allows reducing duplication in similar storage configurations, improving the maintainability of complex configuration files.6 Kubernetes leverages these features to validate files against its own API schemas, ensuring that storage definitions are syntactically correct before application to the cluster.6

## **Taxonomy and lifecycle of volumes**

A volume in Kubernetes is fundamentally a directory accessible to containers within a Pod, whose nature, content, and lifecycle are determined by the specific volume type used.5 Kubernetes solves two fundamental challenges: data persistence beyond a container crash (since upon restart the container starts from a clean state) and file sharing among multiple containers residing in the same Pod.5

### **Classification by persistence: ephemeral and persistent volumes**

The primary distinction in the Kubernetes storage system concerns the link between the life of the volume and that of the Pod.3

| Feature | Ephemeral Volumes | Persistent Volumes |
| :---- | :---- | :---- |
| **Lifespan** | Coincides with the life of the Pod.3 | Independent of the life of the Pod.3 |
| **Persistence post-container restart** | Data is maintained across restarts.5 | Data is maintained across restarts.8 |
| **Persistence post-Pod deletion** | Data is destroyed.3 | Data persists in external storage.3 |
| **Common examples** | emptyDir, ConfigMap, Secret, downwardAPI.3 | PersistentVolume, NFS, Azure Disk, AWS EBS.13 |

Ephemeral volumes are ideal for scenarios requiring scratch space, temporary caches, or configuration injection.5 Conversely, persistent volumes are essential for stateful applications like databases, where the loss of the Pod must not entail the loss of information.4

### **Deep dive on ephemeral volumes: emptyDir and hostPath**

The `emptyDir` volume type is created when a Pod is assigned to a node and remains existing as long as the Pod is running on that node.3 Initially empty, it allows all containers in the Pod to read and write in the same space.5 An advanced configuration involves using memory (RAM) as a backend for `emptyDir` by setting the `medium` field to `Memory`, which is useful for very high-performance caches but consumes the node's RAM quota.2

The `hostPath` volume, on the other hand, mounts a file or directory from the host's filesystem directly into the Pod.3 This type is particularly useful for system workloads that need to monitor the node, such as log agents reading `/var/log`.3 However, it presents significant security risks by exposing the host's filesystem and compromises portability, as the Pod becomes dependent on files present on a specific node.3

### **Projection mechanisms: ConfigMap and Secret**

Kubernetes uses special volumes to inject configuration data and secrets.15 Unlike using environment variables, mounting ConfigMap and Secret as volumes allows for dynamic updating of files within the container without having to restart the process, thanks to the atomic link update mechanism managed by the Kubelet.16 This approach is fundamental for modern microservices architectures that require hot reloads of configuration.16

An important technical detail concerns the use of `subPath`. While `subPath` allows mounting a single file from a volume into a specific folder of the container without overwriting the entire destination directory, files mounted via this technique do not benefit from automatic updates when the source resource changes in the cluster.5

## **The abstraction model: PersistentVolume and PersistentVolumeClaim**

To manage persistent storage in a scalable and infrastructure-agnostic way, Kubernetes introduces three key concepts: PersistentVolume (PV), PersistentVolumeClaim (PVC), and StorageClass (SC).13

### **Definition and responsibility**

A PersistentVolume is a physical storage resource within the cluster, comparable to a node in terms of computational resource.14 It captures the details of the storage implementation (whether NFS, iSCSI, or specific cloud provider storage).19 Conversely, a PersistentVolumeClaim represents the request for storage by the user, specifying size and access modes without needing to know the backend details.12

The lifecycle of these resources follows four distinct phases:

1. **Provisioning**: Storage can be created statically by an administrator or dynamically via a StorageClass.13  
2. **Binding**: Kubernetes monitors new PVCs and looks for a matching PV. Once found, the PV and PVC are bound in an exclusive 1-to-1 relationship.12  
3. **Using**: The Pod uses the PVC as if it were a local volume. The cluster inspects the claim to find the bound volume and mounts it into the container's filesystem.12  
4. **Reclaiming**: When the user has finished using the volume and deletes the PVC, the reclaim policy defines what happens to the PV.13

### **Analysis of Reclaim Policies**

Data management post-usage is critical for security and compliance. Three main policies exist 10:

* **Retain**: The PV remains intact after PVC deletion. The administrator must manually handle cleaning or reusing the volume.10  
* **Delete**: The physical volume and the associated PV are automatically deleted. This is the standard behavior for dynamic storage in cloud environments.13  
* **Recycle**: Performs a file deletion (cleans the filesystem) making the volume available for new claims. This policy is now considered deprecated in favor of dynamic provisioning.13

## **StorageClass and Dynamic Provisioning**

Dynamic provisioning represents a milestone in Kubernetes automation, eliminating the need for administrators to manually pre-create volumes.14 Through the StorageClass object, it is possible to define different storage tiers (e.g., "fast" for SSD, "slow" for HDD) and delegate to Kubernetes the on-demand creation of the physical volume via the relevant provisioner.25

| Cloud Provider | Provisioner (CSI) | Example Parameters | Operational Notes |
| :---- | :---- | :---- | :---- |
| **AWS** | ebs.csi.aws.com | type: gp3, iops: 3000 | Supports online expansion.27 |
| **Azure** | disk.csi.azure.com | storageaccounttype: Premium_LRS | Requires RWO type PVC.29 |
| **GCP** | pd.csi.storage.gke.io | type: pd-balanced | Supports snapshots via CSI.26 |

Using the parameter `volumeBindingMode: WaitForFirstConsumer` within a StorageClass is a fundamental best practice in multi-zone environments.24 This parameter instructs the cluster to wait for Pod scheduling before creating the volume, ensuring storage is allocated in the same availability zone where the Pod is actually running, avoiding cross-zone mount errors.2

## **Access Modes and Application Scenarios**

Correct selection of the access mode (AccessMode) is determinant for the stability of stateful applications.1

* **ReadWriteOnce (RWO)**: The volume can be mounted as read-write by a single node. It is the ideal mode for databases like MySQL or PostgreSQL that require exclusivity to guarantee data integrity.1  
* **ReadOnlyMany (ROX)**: Many nodes can mount the volume simultaneously but only in read-only mode. This scenario is typical for distributing static content (e.g., an `/html` folder for an Nginx cluster).1  
* **ReadWriteMany (RWX)**: Many nodes can read and write simultaneously. This mode is supported by systems like NFS or Azure Files and is useful for applications sharing a common state, although it requires attention to avoid corruption due to overlapping writes.1  
* **ReadWriteOncePod (RWOP)**: Introduced in recent versions, guarantees that only a single Pod in the entire cluster can access the volume, offering a higher security level than RWO (which limits access at the node level).1

## **Architecture of Stateful Workloads: StatefulSet**

Data management in Kubernetes culminates in the use of the StatefulSet, the API object designed to manage applications requiring persistent identities and stable storage.18 Unlike Deployments, where Pods are interchangeable, in a StatefulSet each Pod receives an ordinal index (0, 1, 2...) that it maintains throughout its existence.18

### **The role of volumeClaimTemplates**

The strength of the StatefulSet is the `volumeClaimTemplates`.18 Instead of sharing a single PVC among all Pods, the StatefulSet automatically generates a unique PVC for each instance.18 If Pod `db-1` is deleted and rescheduled, Kubernetes will reattach exactly the `data-db-1` PVC to that new instance, ensuring the database maintains its historical data continuity.18

### **Practical Example: Resilient PostgreSQL Architecture**

When implementing a PostgreSQL database, it is fundamental to use a Headless Service (with `clusterIP: None`) to provide stable DNS names (e.g., `postgres-0.postgres.namespace.svc.cluster.local`) allowing communication between primary and replicas.18

YAML

```yaml
apiVersion: apps/v1  
kind: StatefulSet  
metadata:  
  name: postgresql  
spec:  
  serviceName: "postgresql"  
  replicas: 3  
  template:  
    metadata:  
      labels:  
        app: postgres  
    spec:  
      containers:  
      - name: postgres  
        image: postgres:15  
        volumeMounts:  
        - name: pgdata  
          mountPath: /var/lib/postgresql/data  
  volumeClaimTemplates:  
  - metadata:  
      name: pgdata  
    spec:  
      accessModes:  
      storageClassName: "managed-csi"  
      resources:  
        requests:  
          storage: 100Gi
```

In this scenario, Kubernetes manages the order of creation and termination of Pods, ensuring that replicas are created only after the primary is ready, minimizing risks of inconsistencies during cluster bootstrap.33

## **Container Storage Interface (CSI) and Storage Evolution**

The Container Storage Interface (CSI) represents the modern standard for storage integration in Kubernetes, having replaced the old "in-tree" drivers (compiled directly into the Kubernetes code).37 CSI allows storage vendors to develop drivers independent of the Kubernetes release cycle, fostering innovation and core stability.37

### **CSI Driver Architecture**

A CSI driver operates through two main components 37:

1. **Controller Plugin**: Manages high-level operations such as creation, deletion, and attachment of volumes to physical nodes.37 It is typically supported by sidecar containers like `external-provisioner` and `external-attacher`.38  
2. **Node Plugin**: Running on every node (usually as a DaemonSet), it is responsible for the actual mounting and unmounting of the volume in the container's filesystem via gRPC calls provided by the Kubelet.37

This architecture allows advanced functionalities like volume resizing without interruptions and monitoring storage health directly via the Kubernetes API.5

## **Performance Tuning and Optimization**

Performance optimization requires a balance between IOPS, throughput, and latency.2

### **Storage Parameters and Tiers**

Organizations should define different storage classes based on workload requirements.1 For high-performance databases, using NVMe over TCP volumes or premium SSDs with configurable throughput is essential.1

To calculate necessary performance, one can refer to throughput density. For example, on Google Cloud Hyperdisk, balancing based on capacity is necessary:

$$\text{Minimum Throughput} \= 10 \text{ MiB/s per each TiB of capacity}$$

While the upper limit is set at 600 MiB/s per volume.30

### **VolumeAttributesClass (VAC)**

One of the most recent innovations (beta in v1.31) is the VolumeAttributesClass (VAC).22 It allows dynamically modifying volume performance parameters (such as IOPS or throughput) without having to recreate the PVC or PV, eliminating downtimes that were previously necessary to migrate between different storage classes.28 This is particularly useful for managing seasonal traffic peaks where temporarily increasing database speed is required.28

## **Security and Access Management**

Protection of data at rest and in transit is a non-negotiable requirement in enterprise environments.1

### **Encryption and RBAC**

It is fundamental to enable encryption at rest provided by the backend storage.1 Furthermore, access to PVCs must be regulated via Role-Based Access Control (RBAC), ensuring that only authorized users and ServiceAccounts can manipulate storage resources.15

### **Filesystem Permissions and fsGroup**

Many "Permission Denied" issues in Pods stem from misalignments between the user running the container and the mounted volume's permissions.39 Kubernetes resolves this problem through the `securityContext`. Using the `fsGroup` parameter, Kubernetes automatically applies ownership of the specified group to all files within the volume at mount time, ensuring that processes in the container can write data without manual `chmod` or `chown` interventions.5

YAML

```yaml
spec:  
  securityContext:  
    fsGroup: 2000  
    fsGroupChangePolicy: "OnRootMismatch"
```

The `OnRootMismatch` setting optimizes startup times for Pods mounting very large volumes, avoiding recursively scanning all files if the root directory already has correct permissions.5

## **Backup, Snapshot, and Disaster Recovery**

Persistence alone does not guarantee protection against accidental deletion or data corruption.40 It is essential to implement a solid backup strategy.40

### **CSI Snapshotting Mechanisms**

Kubernetes natively supports volume snapshots via the `VolumeSnapshot` object.22 This mechanism allows creating "point-in-time" copies of data that can be used to clone volumes or restore a previous state in case of application error.5

### **Velero: Enterprise Data Protection**

Velero is the open-source standard for Kubernetes backup and restore.40 It offers two main modes:

1. **CSI Snapshots**: Leverages backend storage native capabilities to create fast volume snapshots.41  
2. **File System Backup (FSB)**: Uses tools like Restic or Kopia to perform file-level backups, ideal when the CSI driver does not support snapshots or when moving data to a different object storage (off-site backup).41

An advanced best practice involves adopting the "CSI Snapshot Data Movement Mode", which combines the speed of hardware snapshots with the security of data transfer to an external repository, ensuring backup accessibility even in case of total primary cluster destruction.41

## **Conclusions: Towards a Flexible Data Infrastructure**

Storage management in Kubernetes has matured from an accessory necessity to a highly sophisticated abstraction ecosystem.1 Understanding the distinction between ephemeral and persistent volumes, coupled with mastery of the PV/PVC/StorageClass model, allows engineers to design systems that not only survive failures but can scale dynamically to respond to business needs.2

The future of cloud-native storage is oriented towards greater intelligence of CSI drivers, with auto-tuning performance capabilities and increasingly deep integration with security policies.28 For organizations operating critical workloads, the key to success lies in adopting open standards, automating provisioning via SC, and rigorously validating backup processes, transforming storage from a potential bottleneck to a catalyst for technological innovation.27

#### **Bibliography**

1. Kubernetes Persistent Volumes - Best Practices & Guide | simplyblock, accessed on January 8, 2026, [https://www.simplyblock.io/blog/kubernetes-persistent-volumes-how-to-best-practices/](https://www.simplyblock.io/blog/kubernetes-persistent-volumes-how-to-best-practices/)  
2. Kubernetes Performance Tuning Guide: Optimize Your K8s Cluster - Kubegrade, accessed on January 8, 2026, [https://kubegrade.com/kubernetes-performance-tuning-guide/](https://kubegrade.com/kubernetes-performance-tuning-guide/)  
3. Kubernetes Volumes Explained: Use Cases & Best Practices - Groundcover, accessed on January 8, 2026, [https://www.groundcover.com/learn/storage/kubernetes-volumes](https://www.groundcover.com/learn/storage/kubernetes-volumes)  
4. Kubernetes persistent vs ephemeral storage volumes and their uses - StarWind, accessed on January 8, 2026, [https://www.starwindsoftware.com/blog/kubernetes-persistent-vs-ephemeral-storage-volumes-and-their-uses/](https://www.starwindsoftware.com/blog/kubernetes-persistent-vs-ephemeral-storage-volumes-and-their-uses/ )
5. Volumes | Kubernetes, accessed on January 8, 2026, [https://kubernetes.io/docs/concepts/storage/volumes/](https://kubernetes.io/docs/concepts/storage/volumes/)  
6. YAML in detail: complete guide to the serialization format - Codegrind, accessed on January 8, 2026, [https://codegrind.it/blog/yaml-spiegato](https://codegrind.it/blog/yaml-spiegato)  
7. YAML: The Ultimate Guide with Examples and Best Practices | by Mahalingam SRE, accessed on January 8, 2026, [https://medium.com/@lingeshcbz/yaml-the-ultimate-guide-with-examples-and-best-practices-7040f9e389ed](https://medium.com/@lingeshcbz/yaml-the-ultimate-guide-with-examples-and-best-practices-7040f9e389ed)  
8. Kubernetes Volumes and How To Use Them – ReviewNPrep, accessed on January 8, 2026, [https://reviewnprep.com/blog/kubernetes-volumes-and-how-to-use-them/](https://reviewnprep.com/blog/kubernetes-volumes-and-how-to-use-them/)  
9. Ephemeral Volumes - Kubernetes, accessed on January 8, 2026, [https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/](https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/)  
10. What Is a Kubernetes Persistent Volume? - Pure Storage, accessed on January 8, 2026, [https://www.purestorage.com/knowledge/what-is-kubernetes-persistent-volume.html](https://www.purestorage.com/knowledge/what-is-kubernetes-persistent-volume.html)  
11. Ephemeral Storage in Kubernetes: Overview & Guide - Portworx, accessed on January 8, 2026, [https://portworx.com/knowledge-hub/ephemeral-storage-in-kubernetes-overview-guide/](https://portworx.com/knowledge-hub/ephemeral-storage-in-kubernetes-overview-guide/)  
12. Persistent Volume Claim (PVC) in Kubernetes: Guide - Portworx, accessed on January 8, 2026, [https://portworx.com/tutorial-kubernetes-persistent-volumes/](https://portworx.com/tutorial-kubernetes-persistent-volumes/)  
13. What is a Kubernetes persistent volume? - Pure Storage, accessed on January 8, 2026, [https://www.purestorage.com/it/knowledge/what-is-kubernetes-persistent-volume.html](https://www.purestorage.com/it/knowledge/what-is-kubernetes-persistent-volume.html)  
14. Kubernetes Persistent Volume: Examples & Best Practices - vCluster, accessed on January 8, 2026, [https://www.vcluster.com/blog/kubernetes-persistent-volume](https://www.vcluster.com/blog/kubernetes-persistent-volume)  
15. In-Depth Guide to Kubernetes ConfigMap & Secret Management Strategies - Gravitee, accessed on January 8, 2026, [https://www.gravitee.io/blog/kubernetes-configurations-secrets-configmaps](https://www.gravitee.io/blog/kubernetes-configurations-secrets-configmaps)  
16. Kubernetes ConfigMaps and Secrets Part 2 | by Sandeep Dinesh | Google Cloud - Medium, accessed on January 8, 2026, [https://medium.com/google-cloud/kubernetes-configmaps-and-secrets-part-2-3dc37111f0dc](https://medium.com/google-cloud/kubernetes-configmaps-and-secrets-part-2-3dc37111f0dc)  
17. Mounting ConfigMaps and Secrets as files - DuploCloud Documentation, accessed on January 8, 2026, [https://docs.duplocloud.com/docs/automation-platform/kubernetes-overview/configs-and-secrets/mounting-config-as-files](https://docs.duplocloud.com/docs/automation-platform/kubernetes-overview/configs-and-secrets/mounting-config-as-files)  
18. Run a Replicated Stateful Application | Kubernetes, accessed on January 8, 2026, [https://kubernetes.io/docs/tasks/run-application/run-replicated-stateful-application/](https://kubernetes.io/docs/tasks/run-application/run-replicated-stateful-application/)  
19. Kubernetes Persistent Volumes and the PV Lifecycle - NetApp, accessed on January 8, 2026, [https://www.netapp.com/learn/kubernetes-persistent-storage-why-where-and-how/](https://www.netapp.com/learn/kubernetes-persistent-storage-why-where-and-how/)  
20. How to manage Kubernetes storage access modes - LabEx, accessed on January 8, 2026, [https://labex.io/tutorials/kubernetes-how-to-manage-kubernetes-storage-access-modes-419137](https://labex.io/tutorials/kubernetes-how-to-manage-kubernetes-storage-access-modes-419137)  
21. Persistent Volumes - Kubernetes, accessed on January 8, 2026, [https://kubernetes.io/docs/concepts/storage/persistent-volumes/](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)  
22. Kubernetes PVC Guide: Best Practices & Troubleshooting - Plural, accessed on January 8, 2026, [https://www.plural.sh/blog/kubernetes-pvc-guide/](https://www.plural.sh/blog/kubernetes-pvc-guide/)  
23. Kubernetes Persistent Volumes - Tutorial and Examples - Spacelift, accessed on January 8, 2026, [https://spacelift.io/blog/kubernetes-persistent-volumes](https://spacelift.io/blog/kubernetes-persistent-volumes)  
24. Kubernetes Persistent Volume Claims: Tutorial & Top Tips - Groundcover, accessed on January 8, 2026, [https://www.groundcover.com/blog/kubernetes-pvc](https://www.groundcover.com/blog/kubernetes-pvc)  
25. Dynamic Provisioning and Storage Classes in Kubernetes, accessed on January 8, 2026, [https://kubernetes.io/blog/2017/03/dynamic-provisioning-and-storage-classes-kubernetes/](https://kubernetes.io/blog/2017/03/dynamic-provisioning-and-storage-classes-kubernetes/)  
26. Dynamic Volume Provisioning | Kubernetes, accessed on January 8, 2026, [https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/)  
27. Kubernetes StorageClass: A technical Guide | by Fortismanuel - Medium, accessed on January 8, 2026, [https://medium.com/@fortismanuel/kubernetes-storageclass-a-technical-guide-58cfb28619ee](https://medium.com/@fortismanuel/kubernetes-storageclass-a-technical-guide-58cfb28619ee)  
28. Modify Amazon EBS volumes on Kubernetes with Volume Attributes Classes | Containers, accessed on January 8, 2026, [https://aws.amazon.com/blogs/containers/modify-amazon-ebs-volumes-on-kubernetes-with-volume-attributes-classes/](https://aws.amazon.com/blogs/containers/modify-amazon-ebs-volumes-on-kubernetes-with-volume-attributes-classes/)  
29. Create a persistent volume with Azure Disks in the service ..., accessed on January 8, 2026, [https://learn.microsoft.com/it-it/azure/aks/azure-csi-disk-storage-provision](https://learn.microsoft.com/it-it/azure/aks/azure-csi-disk-storage-provision)  
30. Scale your storage performance with Hyperdisk | Google Kubernetes Engine (GKE), accessed on January 8, 2026, [https://docs.cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/hyperdisk](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/hyperdisk)  
31. Optimizing Persistent Storage in Kubernetes - Astuto AI, accessed on January 8, 2026, [https://www.astuto.ai/blogs/optimizing-persistent-storage-in-kubernetes](https://www.astuto.ai/blogs/optimizing-persistent-storage-in-kubernetes)  
32. Using NFS as External Storage in Kubernetes with PersistentVolume and PersistentVolumeClaim to Deploy Nginx | by Bshreyasharma | Medium, accessed on January 8, 2026, [https://medium.com/@bshreyasharma1/using-nfs-as-external-storage-in-kubernetes-with-persistentvolume-and-persistentvolumeclaim-to-112994f3ad59](https://medium.com/@bshreyasharma1/using-nfs-as-external-storage-in-kubernetes-with-persistentvolume-and-persistentvolumeclaim-to-112994f3ad59)  
33. StatefulSets - Kubernetes, accessed on January 8, 2026, [https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)  
34. Guide to Kubernetes StatefulSet – When to Use It and Examples - Spacelift, accessed on January 8, 2026, [https://spacelift.io/blog/kubernetes-statefulset](https://spacelift.io/blog/kubernetes-statefulset)  
35. Kubernetes StatefulSet - Examples & Best Practices - vCluster, accessed on January 8, 2026, [https://www.vcluster.com/blog/kubernetes-statefulset-examples-and-best-practices](https://www.vcluster.com/blog/kubernetes-statefulset-examples-and-best-practices)  
36. Deploying the PostgreSQL Pod on Kubernetes with StatefulSets - Nutanix Support Portal, accessed on January 8, 2026, [https://portal.nutanix.com/page/documents/solutions/details?targetId=TN-2192-Deploying-PostgreSQL-Nutanix-Data-Services-Kubernetes:deploying-the-postgresql-pod-on-kubernetes-with-statefulsets.html](https://portal.nutanix.com/page/documents/solutions/details?targetId=TN-2192-Deploying-PostgreSQL-Nutanix-Data-Services-Kubernetes:deploying-the-postgresql-pod-on-kubernetes-with-statefulsets.html)  
37. How the CSI (Container Storage Interface) Works - simplyblock, accessed on January 8, 2026, [https://www.simplyblock.io/blog/how-the-csi-container-storage-interface-works/](https://www.simplyblock.io/blog/how-the-csi-container-storage-interface-works/)  
38. Container Storage Interface (CSI) for Kubernetes GA | Kubernetes, accessed on January 8, 2026, [https://kubernetes.io/blog/2019/01/15/container-storage-interface-ga/](https://kubernetes.io/blog/2019/01/15/container-storage-interface-ga/)  
39. Configure a Pod to Use a PersistentVolume for Storage - Kubernetes, accessed on January 8, 2026, [https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/](https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/)  
40. Chapter 6: Backups - Kubernetes Guides - Apptio, accessed on January 8, 2026, [https://www.apptio.com/topics/kubernetes/best-practices/backups/](https://www.apptio.com/topics/kubernetes/best-practices/backups/)  
41. Kubernetes Backup using Velero - Afi.ai, accessed on January 8, 2026, [https://afi.ai/blog/kubernetes-velero-backup](https://afi.ai/blog/kubernetes-velero-backup)  
42. Snapshot Backups with Velero - MSR Documentation, accessed on January 8, 2026, [https://docs.mirantis.com/msr/4.13/backup/ha-backup/snapshot-backups-with-velero/](https://docs.mirantis.com/msr/4.13/backup/ha-backup/snapshot-backups-with-velero/)  
43. Velero Backup and Restore using Replicated PV Mayastor Snapshots - Raw Block Volumes, accessed on January 8, 2026, [https://openebs.io/docs/Solutioning/backup-and-restore/velerobrrbv](https://openebs.io/docs/Solutioning/backup-and-restore/velerobrrbv)  
44. File System Backup - Velero Docs, accessed on January 8, 2026, [https://velero.io/docs/v1.17/file-system-backup/](https://velero.io/docs/v1.17/file-system-backup/)