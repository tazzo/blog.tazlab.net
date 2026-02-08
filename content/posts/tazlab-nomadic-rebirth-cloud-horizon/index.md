---
title: "The Ephemeral Castle: Nomadism, One-Shot Rebirth, and the Cloud Horizon of TazLab"
date: 2026-02-07T19:00:00+01:00
draft: false
tags: ["kubernetes", "terragrunt", "postgresql", "s3-backup", "longhorn", "automation", "cloud-native", "devops", "proxmox", "infrastructure-as-code"]
categories: ["Infrastructure", "Cloud Engineering"]
author: "Taz"
description: "From total destruction to deterministic rebirth in less than 12 minutes. Documenting the cluster's evolution towards hardware independence and the vision of digital nomadism through TazPod."
---

# The Ephemeral Castle: Nomadism, One-Shot Rebirth, and the Cloud Horizon of TazLab

In systems engineering, stability is not granted by the immobility of an infrastructure, but by its ability to be rebuilt. The concept of the **Ephemeral Castle**, which I am pursuing in the **TazLab** project, is based on a fundamental pillar: provisioning must be deterministic, rapid, and fully automated. If you cannot destroy your entire data center and see it rise from nothing in ten minutes without human intervention, you do not own the infrastructure; you are its prisoner.

Today, I am documenting the achievement of a critical milestone: the **One-Shot Zero-Touch Rebirth**. Through a refined orchestration of Terragrunt, the integration of S3 backups for the "semantic memory," and a drastic rethinking of the hardware topology, I have transformed TazLab into a nomadic workstation, ready to migrate from local iron to the public Cloud with a single command.

## 1. The Topology of Compromise: 1 CP + 2 Workers

My home laboratory rests on a Proxmox server with **32GB of RAM**. Initially, my architecture included a standard high-availability (HA) setup with 3 Control Plane nodes. However, physical reality presented its bill: between the overhead of Talos OS, system services (Longhorn, MetalLB, ESO), and applications (Postgres, Blog, AI), the cluster suffered from chronic memory saturation, leading to OOM (Out of Memory) phenomena and `etcd` instability.

### The Reasoning: Optimization vs. Redundancy
I decided to operate a topological pivot towards a **1 Control Plane + 2 Workers** setup.
Why this choice? In a production environment, a single CP node is a single point of failure. However, in the philosophy of the Ephemeral Castle, Control Plane redundancy is less critical than **reconstruction speed**. If the CP falls, I prefer to destroy everything and have the cluster reborn in 10 minutes rather than wasting 16GB of RAM to maintain a quorum I cannot afford.

By reducing the CP to a single node, I freed up vital resources for the Worker nodes, bringing the total allocated memory to **24GB** (8GB per node). This guarantees a safety buffer for the Proxmox host and allows the cluster to operate in a state of "dynamic equilibrium." This configuration is, paradoxically, the ideal preparation for the Cloud: on AWS or GCP, instances with 8GB of RAM are standard and predictable in terms of cost.

> **Deep-Dive: Quorum and etcd**
> In Kubernetes, `etcd` is the distributed database that stores the cluster state. To ensure consistency, it requires an odd number of nodes (usually 3 or 5) to form a *quorum*. With only one node, I sacrifice the fault tolerance of the state database in favor of greater application density.

---

## 2. The Evolution of Mnemosyne into `tazlab-db`

In the previous post, I documented the use of AlloyDB on Google Cloud as semantic memory. While effective, it did not meet my goal of **self-consistency**. Memory must reside where the work resides. I have therefore brought Mnemosyne back inside the cluster, renaming it **`tazlab-db`**.

### The Strategy of "Data Immortality"
The challenge was ensuring the database survived the *Wipe-First* philosophy. If I destroy the VMs, how do I preserve the memory? The answer lies in **S3-Native Backup**.
I configured the Postgres cluster (managed by the CrunchyData Postgres Operator) to use two backup repositories:
1.  **Repo1 (S3 - Immortality):** An encrypted AWS S3 bucket containing the cluster's history.
2.  **Repo2 (Local - Speed):** A Longhorn volume for fast restores in case of logical errors.

This setup creates an infrastructure that is "stateless by definition but stateful by necessity." The database can be vaporized along with the VMs; upon rebirth, the Postgres Operator will reconcile the state by downloading data from the S3 bucket.

---

## 3. The Technical Chronicle of the Rebirth

The final test, which I called **Nuclear Rebirth**, was performed using the `precision-test.sh` script. This script orchestrates the Terragrunt layers and validates the cluster's health.

### Phase 1: The Nuclear Wipe
Before creating, one must destroy. The `nuclear-wipe.sh` script interacts with the Proxmox APIs to forcibly delete every trace of the VMs (IDs 421, 431, 432). It is an aggressive protocol that guarantees a real tabula rasa, eliminating Terraform locks or ghost states.

### Phase 2: The One-Shot Bootstrap
To prevent the process from being interrupted by the closure of the shell session, I launched the automation with a decoupling protocol:
```bash
nohup setsid bash precision-test.sh > precision_test.log 2>&1 &
```
This command ensures that the "birth" of the cluster occurs in an independent session, immune to the `hangup` signals of the CLI.

---

## 4. Error Analysis: The "Struggle" of Configuration

No rebirth is without pain. During the bootstrap, I encountered two critical issues that required deep investigation.

### Error #1: DNS-1123 Validation
The first database creation attempt failed. The operator Pod showed reconciliation errors. Analyzing the logs with `kubectl logs`, I discovered a validation error:
`spec.users[1].name: Invalid value: "tazlab_admin": should match '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'`

**The Investigation:** I had used an underscore `_` in the username. In Kubernetes, many objects (such as the Secrets generated by the operator for credentials) must follow the **RFC 1123** standard. The use of `_` is prohibited. I had to rename the user to `tazlab-admin`. It is a classic example of how a naming convention can block an entire CD pipeline.

### Error #2: pgBackRest Schema in PGO v5
The second error concerned the S3 backup configuration. I had inserted the `s3Credentials` field directly into the repository block, following an old snippet found online.
`PostgresCluster dry-run failed: .spec.backups.pgbackrest.repos[name="repo1"].s3Credentials: field not declared in schema`

**The Solution:** Using `kubectl explain`, I verified that in the current version of Crunchy PGO, credentials must be injected through a `configuration` block that references a Secret.

Here is the final corrected configuration of the `cluster.yaml` manifest:

```yaml
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: tazlab-db
  namespace: tazlab-db
spec:
  postgresVersion: 16
  databaseInitSQL:
    name: tazlab-db-init-sql
    key: init.sql
  instances:
    - name: instance1
      replicas: 1
      dataVolumeClaimSpec:
        storageClassName: longhorn-postgres
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 10Gi
  backups:
    pgbackrest:
      configuration:
      - secret:
          name: s3-backrest-creds
      repos:
      - name: repo1 # S3 Storage (Immortality)
        s3:
          bucket: "tazlab-longhorn"
          endpoint: "s3.amazonaws.com"
          region: "eu-central-1"
      - name: repo2 # Local Storage (Fast recovery)
        volume:
          volumeClaimSpec:
            storageClassName: longhorn-postgres
            accessModes:
            - ReadWriteOnce
            resources:
              requests:
                storage: 10Gi
  proxy:
    pgBouncer:
      replicas: 1
  users:
    - name: mnemosyne
      databases:
        - tazlab_memory
    - name: tazlab-admin
      databases:
        - tazlab_test
```

And the **ExternalSecret** that generates the dynamic configuration file by mapping secrets from Infisical:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: s3-backrest-creds
  namespace: tazlab-db
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: infisical-tazlab
  target:
    name: s3-backrest-creds
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        s3.conf: |
          [global]
          repo1-s3-key={{ .AWS_ACCESS_KEY_ID }}
          repo1-s3-key-secret={{ .AWS_SECRET_ACCESS_KEY }}
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: AWS_ACCESS_KEY_ID
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: AWS_SECRET_ACCESS_KEY
```

> **Deep-Dive: External Secrets Operator (ESO)**
> ESO is a system that synchronizes secrets from external managers (like AWS Secrets Manager or Infisical) inside Kubernetes. In this case, it allows AWS keys to never be written to disk in the Git repository, keeping the cluster compliant with the **Zero-Trust** philosophy.

---

## 5. The Result: 11 Minutes and 40 Seconds

From sending the destruction command to the moment the blog was back online, serving traffic and successfully querying the database, exactly **11 minutes and 40 seconds** elapsed.

This time span represents my freedom. I no longer need a fixed PC or a 100% reliable home server. If my hardware dies, I have an S3 bucket with the data and a Git repository with the instructions to recreate my entire digital world.

---

## 6. Post-Lab Reflections: Nomadism and the Cloud Horizon

TazLab has evolved into a symbiotic binomial:
1.  **TazPod (The Portal):** My secure work environment, ready in 5 minutes wherever I am.
2.  **TazLab (The Castle):** The heavy infrastructure that I command remotely through TazPod.

This architecture makes me an **Infrastructure Digital Nomad**. I can work from my laptop locally using TazPod, connect via VPN to the home cluster, or—if necessary—order TazPod to raise the Castle on AWS.

The optimized 24GB total configuration makes migration to the public Cloud not only technically possible but economically sustainable. The next step of the journey is already mapped out: testing the exact same rebirth sequence on EC2 instances, bringing the concept of the "Ephemeral Castle" to its ultimate expression.

### Conclusions
In this stage, we learned that:
- Hardware limits are design accelerators: they force us to be lean.
- Data is the only thing that matters; infrastructure must be considered disposable.
- Schema validation (DNS-1123, CRD schemas) is the last mile, often the most difficult, of automation.

The Castle is now solid, portable, and, above all, aware of its own mortality. And it is precisely this awareness that makes it immortal.

---
*Technical Chronicle by Taz - HomeLab DevOps Engineer.*
