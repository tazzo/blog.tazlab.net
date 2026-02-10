---
title: "Phoenix Protocol: Validating Zero-Touch Rebirth and the S3 PITR Hell"
date: 2026-02-10T18:30:00+01:00
draft: false
tags: ["kubernetes", "devops", "postgresql", "s3-backup", "pgbackrest", "longhorn", "disaster-recovery", "automation", "terragrunt"]
categories: ["Infrastructure", "Reliability Engineering"]
author: "Taz"
description: "Technical chronicle of extreme validation: testing data immortality through repeated cycles of total destruction (Nuclear Wipe) and automated rebirth, resolving S3 key injection conflicts and distributed storage latencies."
---

# Phoenix Protocol: Validating Zero-Touch Rebirth and the S3 PITR Hell

In the architecture of the **Ephemeral Castle**, resilience is not an option, but the very condition of existence. An infrastructure that can be destroyed and recreated in less than twelve minutes is useless if, at the end of the rebirth, its memory has vanished. Over the last 48 hours, I subjected the TazLab cluster to what I dubbed the **Phoenix Protocol**: an obsessive cycle of `nuclear-wipe` and `create`, aimed at validating data immortality through automated restoration (Point-In-Time Recovery) from AWS S3.

This is not a story of immediate success, but the honest chronicle of a war of attrition against the CrunchyData PGO v5 operator's automations, the idiosyncrasies of S3 object paths, and the physical latency of distributed storage on limited hardware.

---

## The Mindset: Infrastructure is Ash, Data is Diamond

I decided to adopt a radical philosophy: the entire state of the cluster (VMs, OS configurations, local volumes) must be considered sacrificial. The only element that must survive the "nuclear fire" is the encrypted backup on S3. To test this vision, I had to face three main technical hurdles:
1.  **Deterministic Orchestration**: Ensuring that the Terragrunt layers rise in the correct order, managing dependencies between network storage and database instances.
2.  **S3 Credential Injection**: Resolving the paradox of an operator that requires access keys to download the restoration manifest that contains instructions on how to use those very keys.
3.  **Longhorn Latency**: Managing volume re-attachment on nodes that, after a total wipe, present state residues that confuse the Kubernetes scheduler.

---

## Phase 1: The Storage Struggle and the Longhorn Paradox

The first rebirth attempt clashed with the physical reality of my HomeLab (3 Proxmox nodes with about 32GB of total RAM). Longhorn, the distributed storage engine I chose for its simplicity and native Kubernetes integration, proved to be an unexpected bottleneck during rapid destruction and creation cycles.

### The Investigation: "Volume not ready for workloads"
After launching the creation command, I observed the restore Pods remaining stuck in `Init:0/1`. Analyzing the events with `kubectl describe pod`, I encountered the error:
`AttachVolume.Attach failed for volume "pvc-xxx" : rpc error: code = Aborted desc = volume is not ready for workloads`

The mental process that led me to the solution was this: I initially suspected a Talos OS error in mounting iSCSI targets. However, the Longhorn Manager logs indicated that the volume was "stuck" in a detachment phase from the previous node, which physically no longer existed due to the wipe.

### The Reasoning: Why I reduced replicas and forced overprovisioning
To resolve this deadlock, I had to make two crucial decisions:
1.  **Replica Count to 1**: In a cluster with only two worker nodes, demanding three replicas for each database volume led to a scheduler deadlock. I decided that storage redundancy would be managed at the application level (via Postgres) and at the backup level (via S3), allowing local volumes to be lean and fast.
2.  **200% Overprovisioning**: I configured Longhorn to allow the virtual allocation of double the physical space. This is necessary because during bootstrap, the system attempts to create new volumes before the old ones have been completely removed from the nodes' state database.

---

## Phase 2: The S3 Path Hell and the War on Leading Slashes

Once storage was stabilized, I faced the heart of the problem: **pgBackRest**. The integration between CrunchyData PGO v5 and S3 is extremely powerful, but equally picky.

### Analysis of Failure: "No backup set found"
Despite the files being present in the S3 bucket, the restore Job failed systematically with a laconic `FileMissingError: unable to open missing file '/pgbackrest/repo1/backup/db/backup.info'`.

**Deep-Dive: Object Storage Pathing**
Unlike a POSIX filesystem, an S3 bucket does not have real folders, but only keys composed of strings (prefixes). When a tool like `pgbackrest` searches for a file, the presence or absence of a leading slash (`/`) in the configured prefix can radically change the API request.

After using a temporary Pod with AWS CLI to inspect the bucket, I discovered that the data resided in `pgbackrest/repo1/...` (without a leading slash). In my `cluster.yaml` manifest, I had configured `repo1-path: /pgbackrest/repo1`. The operator was thus looking for a ghost "subfolder" in the root. I removed the leading slash, aligning the configuration with the reality of S3 objects.

---

## Phase 3: The Authentication Paradox in Bootstrap

Once the path problem was solved, the most difficult error emerged: `ERROR: [037]: restore command requires option: repo1-s3-key`.

### The Reasoning: Why the operator does not "inherit" keys
I discovered that the CrunchyData v5 operator manages backups and restores asymmetrically. Although the S3 credentials were defined in the `backups` block, the bootstrap Job (the one that brings the cluster to life from nothing) did not automatically inherit them.

I had to implement a refactoring of the **ExternalSecret** and the cluster manifest to force the injection. The solution was to create an `s3.conf` file dynamically injected via a Secret, and explicitly reference it in the `dataSource` block.

### Technical Implementation: The "Sacred" Configuration

Here is the secret that unlocked the situation, mapping the Infisical keys into the format required by the pgBackRest configuration file:

```yaml
# infrastructure/configs/tazlab-db/s3-external-secret.yaml
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
    template:
      engineVersion: v2
      data:
        # Configuration file that CrunchyData mounts in the restore pod
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

And the cluster manifest that explicitly calls this configuration for the bootstrap:

```yaml
# infrastructure/instances/tazlab-db/cluster.yaml
spec:
  dataSource:
    pgbackrest:
      stanza: db
      configuration:
        - secret:
            name: s3-backrest-creds # Essential for authentication during restore
      repo:
        name: repo1
        s3:
          bucket: "tazlab-longhorn"
          endpoint: "s3.amazonaws.com"
          region: "eu-central-1"
      options:
        - --delta # Allows restoration onto existing volumes if necessary
```

---

## Phase 4: Validating the Phoenix Protocol (PITR)

For the final test, I wanted to raise the bar. It wasn't enough to recover an old backup; I wanted to recover data inserted **seconds before** the total destruction of the cluster.

### The Test Protocol:
1.  Insert **DATO_A**: Recorded in the S3 Full Backup.
2.  Manual backup trigger.
3.  Insert **DATO_B**: Recorded only in the transaction logs (**WAL**).
4.  Force `pg_switch_wal()` to ensure the last segment was pushed to S3.
5.  **Nuclear Wipe**: Physical destruction of all VMs on Proxmox.

**Deep-Dive: Point-In-Time Recovery (PITR)**
PITR is the ability of a database to return to any past instant in time by combining a full backup ("the base") with transaction logs (WAL - "the bricks"). If the system can replay the WALs on S3 after a wipe, it means we haven't lost even a single row of data, even if inserted just a moment before the disaster.

### The Final Obstacle: The --type=immediate flag
Initially, the restoration showed only DATO_A. Analyzing the logs, I realized that the operator used the `--type=immediate` option by default.
This option instructs Postgres to stop as soon as the database reaches a consistent state after the full backup, ignoring all subsequent transaction logs. I removed the flag from the manifest, allowing the process to "chew" through all available WALs until the last transaction received from S3.

---

## Final Result: 11 Minutes and 38 Seconds

Using the system clock to measure each phase of the rebirth, here is the final telemetry of the complete bootstrap:

- **Layer Secrets**: 33s
- **Layer Platform (Proxmox + Talos)**: 3m 48s
- **Layer Engine & Networking**: 2m 51s
- **Layer GitOps & Storage**: 2m 25s
- **Database Restore (S3 PITR)**: ~2m 00s

**Total: 11 minutes and 38 seconds.**

At the end of this interval, I queried the `memories` table:
```sql
 id |             content              |          created_at           
----+----------------------------------+-------------------------------
  2 | DATO_B_VOLATILE_MA_IMMORTALE_WAL | 2026-02-10 14:55:10
  1 | DATO_A_NEL_BACKUP_S3             | 2026-02-10 14:54:02
```

Both pieces of data were there. The Phoenix Protocol succeeded.

---

## Post-Lab Reflections: The Future is Nomadic

Achieving this milestone radically transforms my approach to the cluster. Knowing that I can destroy everything and have every single database transaction back in less than 12 minutes frees me from the "fear of the hardware."

### What we learned:
1.  **Automation is not magic**: It is a sequence of rigorous validations. Every slash, every username (which must respect the RFC 1123 standard, otherwise reconciliation fails), every restore flag counts.
2.  **Data is the only anchor**: Infrastructure must be considered ephemeral by definition. Investing time in making the data "immortal" via S3 is worth a thousand times the time spent trying to make a VM "stable."
3.  **The cloud is close**: This 3-node setup (1 CP + 2 Workers) with 24GB of total RAM is already ready to be moved to AWS EC2 or Google Cloud. The configuration is agnostic; only the VM provisioning layer will change, but the heart of the rebirth will remain the same.

The TazLab Castle is now officially indestructible. Its strength lies not in its walls, but in its ability to rise from its own ashes, exactly where and when I decide.

---
*Cronaca Tecnica a cura di Taz - HomeLab  DevOps Engineer.*
