+++
title = "Enterprise Monitoring in a Home Lab: The (Uphill) Road to Stateless Grafana and Prometheus"
date = 2026-03-04T12:40:00Z
draft = false
description = "A detailed technical chronicle of implementing an enterprise-grade monitoring stack in the TazLab: from PostgreSQL persistence challenges to MetalLB network conflicts."
tags = ["kubernetes", "prometheus", "grafana", "postgresql", "monitoring", "gitops", "fluxcd", "homelab", "devops"]
author = "Tazzo"
+++

# Enterprise Monitoring in a Home Lab: The (Uphill) Road to Stateless Grafana and Prometheus

## Introduction: Beyond "Out of the Box" Monitoring

In a Home Lab that aims to be more than just a collection of containers, monitoring cannot be an afterthought. After stabilizing my **Talos Linux** cluster on Proxmox and consolidating distributed storage with **Longhorn**, I felt the need for granular visibility. I didn't just need graphs; I needed an observability infrastructure that followed the same principles of resilience and immutability as the rest of the cluster.

Many tutorials suggest installing `kube-prometheus-stack` with default values: Grafana saving data to a local SQLite database and Prometheus writing to a temporary volume. This solution, while quick, is antithetical to my vision of an "Enterprise Home Lab." If a node fails and the Grafana Pod is rescheduled elsewhere without a persistent volume, I would lose every manually created dashboard, every user, and every configuration. I decided, therefore, to take the more complex path: a **Stateless architecture for Grafana** and **Long-term Persistence for Prometheus**, orchestrated entirely via GitOps with FluxCD.

## The Architectural Strategy: Why "Stateless"?

The concept of a "stateless application" is fundamental in modern cloud-native architectures. For Grafana, this means that the application binary must not contain any vital state. I decided to use the existing PostgreSQL cluster (`tazlab-db`), managed by the **CrunchyData Postgres Operator**, as the backend for Grafana's metadata.

### The Reasoning: SQLite vs PostgreSQL
Why bother configuring an external database? In a standard installation, Grafana uses **SQLite**, a single-file database. While excellent for simplicity, SQLite in Kubernetes requires a dedicated `PersistentVolumeClaim` (PVC). If the PVC becomes corrupted or if there are file lock issues during a node migration (common with RWO volumes), Grafana won't start. By using PostgreSQL, I shift the responsibility of persistence to a system I have already made resilient (with S3 backups via pgBackRest and high availability). This allows me to treat Grafana Pods as expendable: I can destroy and recreate them at any time, knowing the data is safe in the central database.

### The Choice of Prometheus on Longhorn
For Prometheus, the situation is different. Prometheus is inherently "stateful" due to its time-series database (TSDB). While solutions like Thanos or Cortex exist to make it stateless, for my current data volume, it would be unnecessary overkill. I opted for a pragmatic approach: a 10GB volume on **Longhorn** with a 15-day retention policy. This ensures that historical data survives Pod restarts, while Longhorn's distributed replication protects me from hardware failures of the physical Proxmox nodes.

---

## Implementation: Configuration and GitOps

The entire stack is defined via a FluxCD `HelmRelease`. This allows me to manage the configuration declaratively in the `tazlab-k8s` repository.

### The Heart of the Configuration (Technical Snippet)
Here is how I declared the PostgreSQL integration and networking management:

```yaml
spec:
  values:
    grafana:
      enabled: true
      grafana.ini:
        database:
          type: postgres
          host: tazlab-db-primary.tazlab-db.svc.cluster.local:5432
          name: grafana
          user: grafana
      env:
        GF_DATABASE_TYPE: postgres
        GF_DATABASE_HOST: tazlab-db-primary.tazlab-db.svc.cluster.local:5432
        GF_DATABASE_NAME: grafana
        GF_DATABASE_USER: grafana
      envValueFrom:
        GF_DATABASE_PASSWORD:
          secretKeyRef:
            name: tazlab-db-pguser-grafana
            key: password
      service:
        type: LoadBalancer
        annotations:
          metallb.universe.tf/loadBalancerIPs: "192.168.1.240"
          metallb.universe.tf/allow-shared-ip: "tazlab-internal-dashboard"
        port: 8005
```

This configuration uses **External Secrets (ESO)** to inject the database password, syncing it directly from **Infisical**. It is a critical security step: no password is written in plain text in the Git code.

---

## The Chronicle of Failures: An Obstacle Course

Despite the planning, the installation was a "Trail of Failures" that required hours of deep debugging. Documenting these errors is fundamental, as they represent the reality of a DevOps engineer's work.

### 1. The Ghost of SQLite (The Silent Failure)
After the first deploy, I noticed from the logs that Grafana was still trying to initialize an SQLite database in `/var/lib/grafana/grafana.db`. Despite having configured the `database` section in `grafana.ini`, the settings were being ignored.

**The Investigation:** I executed a `kubectl exec` into the Pod to inspect the generated configuration file. I discovered that, due to the way the Grafana Helm Chart processes values, some variables entered in `grafana.ini` were not being correctly propagated if they were not also present as environment variables.
**The Solution:** I had to duplicate the configuration in both the `grafana.ini` section and the `env` section. Only then did Grafana "understand" it needed to point to PostgreSQL. It's a frustrating behavior of complex charts: redundancy is sometimes the only way.

### 2. The Postgres 16 Permissions Wall
Once the configuration issue was resolved, the Grafana Pod started crashing with a cryptic error: `pq: permission denied for schema public`.

**The Investigation:** I knew the database was active and the `grafana` user existed. However, PostgreSQL 16 introduced restrictive changes to permissions on the `public` schema. By default, new users no longer have the right to create objects in that schema.
**The Solution:** I had to manually intervene on the database with an SQL session:
```sql
GRANT ALL ON SCHEMA public TO grafana;
ALTER SCHEMA public OWNER TO grafana;
```
This step reminded me that, even in an automated world, deep knowledge of underlying systems (like database RBAC) is irreplaceable.

### 3. Network Conflict: Port 8004
The cluster uses **MetalLB** to expose services on a dedicated IP (`192.168.1.240`). During deployment, the Grafana service remained in a `<pending>` state.

**The Investigation:** I checked the service events with `kubectl describe svc`. MetalLB reported a conflict: "port 8004 is already occupied". A quick analysis of my documentation revealed that `mnemosyne-mcp` was already using that port on the same shared IP.
**The Solution:** I moved Grafana to port `8005`. This highlights the importance of rigorous **IP Address Management (IPAM)** even in a lab environment, especially when using annotations like `allow-shared-ip`.

### 4. The Silence of Node Exporter (Pod Security Standards)
After installation, the dashboards were visible but... empty. No data from the nodes.

**The Investigation:** I checked the `node-exporter` DaemonSet. No Pods had been created. The controller returned a **Pod Security Policies** violation error: `violates PodSecurity baseline:latest`. `node-exporter` requires access to host namespaces (`hostNetwork`, `hostPID`) and `hostPath` to read hardware metrics—behaviors that Kubernetes now blocks by default for security.
**The Solution:** I had to "soften" the `monitoring` namespace by labeling it as `privileged`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    pod-security.kubernetes.io/enforce: privileged
```
It is a necessary compromise: to monitor hardware, the software must be able to "see" it.

---

## GitOps for Dashboards: The Magic Sidecar

Another pillar of this installation is dashboard automation. I don't want to create graphs by hand by clicking in the interface; I want dashboards to be part of the code.

I configured the **Grafana Sidecar**, a lightweight process that runs alongside Grafana and scans the cluster for `ConfigMap` objects with the label `grafana_dashboard: "1"`. When it finds one, it downloads the dashboard JSON and injects it into Grafana. This transforms monitoring into a purely declarative system. If I had to reinstall everything from scratch tomorrow, my professional dashboards ("Nodes Pro", "Cluster Health") would automatically appear at the first boot.

---

## Post-Lab Reflections: What have we learned?

This "stage" of the TazLab journey was one of the most challenging in terms of troubleshooting. What does this setup mean for long-term stability?

1. **Failure Resilience:** Now I can lose an entire node or corrupt the monitoring namespace without losing the history of my work. The PostgreSQL database is my "anchor."
2. **Standardization:** The use of `privileged` namespaces and specific ports on MetalLB is now documented and codified, reducing cluster entropy.
3. **Mental Scalability:** Facing these problems forced me to dig into the specifications of Postgres 16 and the internal mechanisms of Kubernetes (PSA, MetalLB). This is true professional growth.

In conclusion, observability is not just about "seeing graphs." It is about building a system that is as reliable as the system it is meant to monitor.
