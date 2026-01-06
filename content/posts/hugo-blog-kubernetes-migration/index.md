+++
title = "Migrating a Hugo Blog to Kubernetes"
date = 2026-01-06T00:42:51Z
draft = false
description = "A technical chronicle of migrating a Hugo blog from Docker Compose to a Kubernetes cluster with Longhorn and Traefik."
tags = ["kubernetes", "hugo", "migration", "longhorn", "traefik", "homelab"]
author = "Tazzo"
+++

## Introduction: The Illusion of Simplicity

Today the goal seemed trivial: take a static blog generated with **Hugo**, which currently runs peacefully in a Docker container managed via Compose, and move it inside the Kubernetes cluster.

On paper, it's a five-minute operation. Take the `compose.yml`, translate it into a Deployment and a Service, apply, done. In reality, this migration turned into a masterclass on the difference between **local volume management** (Docker) and **distributed storage** (Kubernetes/Longhorn), and on how file permissions can become public enemy number one.

This is not a "copy-paste" guide. It is the chronicle of how we dissected the problem, analyzed the failures, and built a resilient solution.

**Yes, the blog you are reading right now runs on Kubernetes, self-hosted on Proxmox on my home mini PC!**

---

## Phase 1: The Storage Paradox

The starting point was a simple `docker-compose.yml` that I used for local development:

```yaml
services:
  hugo:
    image: hugomods/hugo:exts-non-root
    command: server --bind=0.0.0.0 --buildDrafts --watch
    volumes:
      - ./:/src  # <--- THE CULPRIT
```

Note that `volumes` line. In Docker, I was mapping the current folder of my host inside the container. It's immediate: I modify a file on my laptop, Hugo notices it and regenerates the site.

### The Conceptual Problem
When we move to Kubernetes, that "my laptop" no longer exists. The Pod can be scheduled on any node of the cluster. We cannot rely on files present on the host filesystem (unless using `hostPath`, which however is an anti-pattern because it binds the Pod to a specific node, breaking High Availability).

The architectural solution is to use a **PersistentVolumeClaim (PVC)** backed by **Longhorn**. Longhorn replicates data across multiple nodes, ensuring that if a node dies, the blog data survives and the Pod can restart elsewhere.

But here arises the paradox: **A new Longhorn volume is empty.** 
If I start the Hugo Pod attached to this empty volume, Hugo will crash instantly because it won't find the `config.toml` file.

### Ingestion Strategy
We had three paths:
1.  **Git-Sync Sidecar:** A side-by-side container that constantly clones the Git repo into the shared volume. Elegant, but complex for a personal blog.
2.  **InitContainer:** A container that starts before the app, clones the repo, and dies.
3.  **One-Off Copy:** Start the Pod, wait for it to fail (or hang), and manually copy the data once.

We opted for a hybrid variant. Since the goal was to keep the "watch" mode to edit live files (maybe via remote editor in the future), we decided to treat the volume as the "Single Source of Truth".

---

## Phase 2: The Manifesto Architecture

Why a **Deployment** and not a **StatefulSet**?

One often associates the StatefulSet with applications that need storage stability. However, Hugo (in server mode) does not need stable network identities (like `hugo-0`, `hugo-1`). It only needs its files. A Deployment with `Recreate` strategy (to avoid two pods writing to the same RWO volume simultaneously) is sufficient and simpler to manage.

Here is the final commented manifesto:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hugo-blog
  namespace: hugo-blog # Isolation first of all
spec:
  replicas: 1
  strategy:
    type: Recreate # Avoids Longhorn volume lock
  selector:
    matchLabels:
      app: hugo-blog
  template:
    metadata:
      labels:
        app: hugo-blog
    spec:
      # THE SECRET OF PERMISSIONS
      securityContext:
        fsGroup: 1000 
      containers:
        - name: hugo
          image: hugomods/hugo:exts-non-root
          args:
            - server
            - --bind=0.0.0.0
            - --baseURL=https://blog.tazlab.net/
            - --appendPort=false
          ports:
            - containerPort: 1313
          volumeMounts:
            - name: blog-src
              mountPath: /src
      volumes:
        - name: blog-src
          persistentVolumeClaim:
            claimName: hugo-blog-pvc
```

### Deep Dive: `fsGroup: 1000`
This was the critical moment of the investigation. The image `hugomods/hugo:exts-non-root` is built to run, as the name says, without root privileges (UID 1000). 
However, when Kubernetes mounts a volume (especially with certain CSI drivers like Longhorn), the mount directory can belong to `root` by default.

Result? The container starts, tries to write to the `/src` folder (for cache or lock files) and receives a `Permission Denied`.

The instruction `fsGroup: 1000` in the `securityContext` tells Kubernetes: "Hey, any volume mounted in this Pod must be readable and writable by group 1000". Kubernetes recursively applies a `chown` or manages ACL permissions at mount time, solving the problem at the root.

---

## Phase 3: The Network and Discovery

Once the Pod is running, it must be reachable. Here **Traefik**, our Ingress Controller, comes into play.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hugo-blog-ingress
  annotations:
    # The magic of Let's Encrypt
    traefik.ingress.kubernetes.io/router.tls.certresolver: myresolver
spec:
  ingressClassName: traefik
  rules:
    - host: blog.tazlab.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hugo-blog
                port:
                  number: 80
```

During setup, I had to verify what the exact name of the resolver configured in Traefik was. A quick check on `traefik-values.yaml` confirmed that the ID was `myresolver`. Without this exact match, SSL certificates would never be generated.

A detail often overlooked: **BaseURL**.
Hugo generates internal links based on its configuration. If it runs on internal port 1313, it will tend to create links like `http://localhost:1313/post`. But we are behind a Reverse Proxy (Traefik) serving on HTTPS port 443.
The argument `--baseURL=https://blog.tazlab.net/` and `--appendPort=false` forces Hugo to generate correct links for the outside world, regardless of the port the container listens on.

---

## Phase 4: Operation "Data Transplant"

With the manifesto applied, the Pod went into `Running` state, but served a blank page or an error, because `/src` was empty.

Here we used intelligent brute force: `kubectl cp`.

```bash
# Local copy -> Remote Pod
kubectl cp ./blog hugo-blog/hugo-blog-pod-xyz:/src
```

Thanks to the `fsGroup` configured earlier, the copied files kept the correct permissions to be read by the Hugo process. Immediately, the Hugo watcher detected the new files (`config.toml`, `content/`) and compiled the site in a few milliseconds.

---

## Post-Lab Reflections

This migration moved the blog from a "pet" entity (tied to my computer) to "cattle" (part of the cluster).

1.  **Resilience:** If the node where Hugo runs dies, Longhorn has replicated the data to another node. Kubernetes reschedules the Pod, which attaches to the data replica and restarts. Downtime time: seconds.
2.  **Scalability:** We don't need it now, but we could scale to more replicas (removing the `--watch` mode and using Nginx to serve pure statics).
3.  **Security:** Everything runs in HTTPS, with automatically renewed certificates, and the container has no root privileges.

Today's lesson is that in Kubernetes, **storage is a first-class citizen**. It is no longer just a folder on disk; it is a network resource with its own access rules, permissions, and lifecycle. Ignoring this aspect is the fastest way to a `CrashLoopBackOff`.

