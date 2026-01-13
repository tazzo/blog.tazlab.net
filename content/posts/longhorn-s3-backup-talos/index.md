+++
title = "From Persistence to Resilience: Orchestrating Longhorn Backups on AWS S3 in a Talos Linux Environment"
date = 2026-01-07T10:00:00Z
draft = false
description = "A deep dive into implementing offsite backups for Longhorn storage using AWS S3 on an immutable Talos Linux cluster."
tags = ["kubernetes", "longhorn", "aws-s3", "backup", "talos-linux", "disaster-recovery"]
author = "Tazzo"
+++

# From Persistence to Resilience: Orchestrating Longhorn Backups on AWS S3 in a Talos Linux Environment


## Introduction: The Local Availability Paradox

In recent weeks, my Homelab based on **Talos Linux** and virtualized on Proxmox has reached a remarkable level of operational stability. Core services like Traefik and the Hugo blog run without interruption, and networking has been hardened through static IP assignment to nodes. However, analyzing the architecture with a critical eye, a fundamental vulnerability emerged: the confusion between **High Availability (HA)** and **Disaster Recovery (DR)**.

Longhorn, the distributed storage engine I chose for this cluster, excels at synchronous data replication. By configuring a `replicaCount: 2`, every block written to disk is instantly duplicated on a second node. This protects me if a single node fails or a disk becomes corrupted. But what would happen if a configuration error deleted the `traefik` namespace? Or if a catastrophic failure of the physical Proxmox hardware rendered both virtual nodes inaccessible? The answer is unacceptable for an environment aiming to be "Production Grade": total data loss.

The goal of today's session was to bridge this gap by implementing an automated offsite backup strategy, using **AWS S3** as a remote target and managing the entire configuration according to **Infrastructure as Code (IaC)** principles. What was supposed to be a simple parameter configuration turned into a complex operation involving software upgrades and declarative definition refactoring.

---

## Phase 1: Security Foundations and Secrets Management

Before touching Kubernetes, I had to prepare the ground on AWS. The guiding principle in this context is the **Principle of Least Privilege (PoLP)**. It is not acceptable to use root account credentials or an administrator user for an automated backup process. If those keys were compromised, the entire AWS account would be at risk.

### IAM Identity and Bucket Creation
I created a dedicated S3 bucket in the `eu-central-1` (Frankfurt) region, chosen to minimize latency with my laboratory in Europe. Subsequently, I configured a technical IAM user, `longhorn-backup-user`, associating it with a restrictive JSON policy. This policy exclusively grants the permissions necessary to read and write objects in that specific bucket, denying access to any other cloud resource.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket",
                "s3:DeleteObject",
                "s3:GetBucketLocation"
            ],
            "Resource": [
                "arn:aws:s3:::tazlab-longhorn",
                "arn:aws:s3:::tazlab-longhorn/*"
            ]
        }
    ]
}
```

### Secrets Encryption with SOPS
The next step involved how to bring these credentials (Access Key and Secret Key) inside the Kubernetes cluster. The naive approach would have been to create the Secret manually with `kubectl create secret` or, worse, commit a YAML file with the keys in clear text to the Git repository.

I opted for **SOPS (Secrets OPerationS)** combined with **Age** for asymmetric encryption. This workflow allows for versioning secret files in the Git repository in encrypted format. Only those who possess the Age private key (in my case, present on my management workstation) can decrypt the file at the time of application.

The generated `aws-secrets.enc.yaml` file contains only the metadata in clear text, while the `stringData` payload is an incomprehensible encrypted block. The application to the cluster occurred through a just-in-time decryption pipeline:

```bash
sops --decrypt aws-secrets.enc.yaml | kubectl apply -f -
```

This method ensures that a clear text file never exists on the hard drive that could be inadvertently committed or exposed.

---

## Phase 2: The Upgrade Odyssey (Longhorn 1.8 -> 1.10)

To take advantage of the latest backup management and StorageClass features, I decided to upgrade Longhorn from version 1.8.0 to the current version 1.10.1. Here I encountered the (justified) rigidity of stateful systems.

### The Pre-Upgrade Hook Block
Launching a direct `helm upgrade` to version 1.10.1, the process failed instantly. The pre-upgrade job logs reported an unequivocal message:

> `failed to upgrade since upgrading from v1.8.0 to v1.10.1 for minor version is not supported`

This error highlights a critical difference between *stateless* applications (like an Nginx web server) and *stateful* applications (like a storage engine). A stateless application can skip versions at will. A storage engine manages data structures on disk and metadata formats that evolve over time. Longhorn requires that each "minor" version update (the second number in semantic versioning) be performed sequentially to allow database migration jobs to convert data safely.

### Incremental Mitigation Strategy
I had to adopt a stepped approach, manually simulating the software lifecycle I should have followed if I had maintained the cluster updated regularly.

1.  **Step 1: Upgrade to v1.9.2.** I forced Helm to install the latest patch of the 1.9 series. This allowed Longhorn to migrate its CRDs (Custom Resource Definitions) and internal formats. I waited for all `longhorn-manager` pods to return to `Running` and complete (`2/2`) status.
2.  **Step 2: Upgrade to v1.10.1.** Only after validating the cluster health on 1.9 did I launch the final update.

This procedure required time and patience, monitoring logs to ensure volumes were not disconnected or corrupted during daemon restarts. It is a reminder that maintenance in the Kubernetes sphere is never a simple "set and forget" operation.

---

## Phase 3: The Battle for Declarative Configuration (IaC)

Once the software was updated, the real problem emerged in the attempt to configure the `BackupTarget` (the S3 URL) declaratively. My intention was to define everything in the `longhorn-values.yaml` file passed to Helm, to avoid manual configurations via the web UI.

### The Limit of `defaultSettings`
I inserted the configurations into the `defaultSettings` block of the Helm chart:

```yaml
defaultSettings:
  backupTarget: "s3://tazlab-longhorn@eu-central-1/"
  backupTargetCredentialSecret: "aws-backup-secret"
```

However, after application, the configuration in Longhorn remained empty. Analyzing the documentation and chart behavior, I rediscovered a technical detail often overlooked: **Longhorn applies `defaultSettings` only during the first installation**. If the Longhorn cluster is already initialized, these values are ignored to prevent overwriting configurations that the administrator might have changed at runtime.

### The Failure of the Declared Imperative Approach
I attempted to bypass the problem by creating YAML manifests for `Setting` type objects (e.g., `settings.longhorn.io`), hoping Kubernetes would force the configuration. The result was a rejection by the Longhorn Validating Webhook:

> `admission webhook "validator.longhorn.io" denied the request: setting backup-target is not supported`

This cryptic error hid an architectural change introduced in recent versions. The `backup-target` setting is no longer a simple global key-value managed via the `Setting` object, but has been promoted to a **dedicated CRD** called `BackupTarget`. Attempting to configure it as an old setting generated a validation error because the key no longer existed in the simple settings schema.

### The "Tabula Rasa" Solution
Faced with a cluster state misaligned with the code (Configuration Drift) and the impossibility of reconciling it cleanly due to residues from previous versions, I made a drastic but necessary decision: **the complete uninstallation of the Longhorn control plane**.

It is essential to distinguish between deleting the control software and deleting the data. By uninstalling Longhorn (`helm uninstall`), I removed the Pods, Services, and DaemonSets. However, the physical data on the disks (`/var/lib/longhorn` on the nodes) and the Persistent Volume definitions in Kubernetes remained intact.

Reinstalling Longhorn v1.10.1 from scratch with the correct `values.yaml` file, the system read the `defaultSettings` as if it were a new installation, correctly applying the S3 configuration from the very first boot. Upon restart, the managers scanned the disks, found the existing data, and reconnected the volumes without any data loss. This operation validated not only the configuration but also the intrinsic resilience of Kubernetes' decoupled architecture.

---

## Phase 4: Automation and Backup Strategies

Having a configured backup target does not mean having backups. Without automation, backup depends on human memory, which guarantees failure.

### `RecurringJob` Implementation
I defined a `RecurringJob` resource to automate the process. Unlike system cronjobs, these are managed internally by Longhorn and are aware of the volume status.

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: nightly-s3-backup
spec:
  cron: "0 3 * * *"
  task: backup
  retain: 7
  groups:
    - traefik-only
```

The choice to keep only 7 backups (`retain: 7`) is a compromise between security and S3 storage costs.

### Granularity via Labels and Groups
Initially, all volumes were in the `default` group. However, not all data has the same value. The Hugo blog volume contains data that is already versioned on GitHub; the Traefik volume contains private SSL certificates, which are irreplaceable and critical.

I decided to implement a granular backup strategy:
1.  I created a custom group `traefik-only` in the RecurringJob.
2.  I applied a specific label to the Traefik volume: `recurring-job-group.longhorn.io/traefik-only: enabled`.
3.  I removed generic labels from other volumes.

This approach reduces network traffic and storage costs, saving only what is strictly necessary.

### Advanced StorageClass: Automation at Birth
To close the IaC circle, I created a new dedicated **StorageClass**: `longhorn-traefik-backup`.

```yaml
kind: StorageClass
metadata:
  name: longhorn-traefik-backup
parameters:
  recurringJobSelector: '[{"name":"nightly-s3-backup", "isGroup":true}]'
  reclaimPolicy: Retain
```

Using the `recurringJobSelector` parameter directly in the StorageClass is powerful: any future volume created with this class will automatically inherit the backup policy, without needing manual intervention or subsequent patches. Furthermore, the `Retain` policy ensures that even if the Traefik Deployment were accidentally deleted, the volume would remain in the cluster waiting to be reclaimed, preventing accidental deletion of certificates.

---

## Conclusions and Reflections

This work session transformed the cluster's storage layer from simple local persistence to a disaster-resilient enterprise-level solution.

**Key lessons learned:**
1.  **Never underestimate stateful upgrades:** Version jumps in databases and storage engines require planning and incremental steps.
2.  **IaC requires discipline:** It is easy to solve a problem with `kubectl patch`, but rebuilding the infrastructure from scratch (as we did by uninstalling Longhorn) is the only way to ensure the code faithfully describes reality.
3.  **Default vs. Runtime:** Understanding when a configuration is applied (init vs. runtime) is crucial for debugging complex Helm charts.

The infrastructure is now ready to face the worst. The next logical step will be to validate this setup by performing a real **Disaster Recovery Test**: intentionally destroying a volume and attempting restoration from S3, to transform the "hope" of backup into the "certainty" of recovery.
