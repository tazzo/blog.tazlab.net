+++
title = "From Idea to Failure to Compromise: Migrating a TLS Certificate Through Three Operators"
date = 2026-06-01T17:30:00+02:00
draft = false
description = "After migrating everything to VSO, a few secrets remained on ESO. It seemed like a simple task. Instead, it became an odyssey through a controller deadlock, a merge engine that would not merge, and three different operators. In the end, the solution was where we started."
tags = ["vso", "vault", "eso", "kyverno", "reflector", "kubernetes", "tls", "secret-management", "crisp", "enterprise"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# From Idea to Failure to Compromise: Migrating a TLS Certificate Through Three Operators

## Introduction

In the previous post I described how CRISP 2.0 allowed us to migrate three Vault projects in an afternoon with zero bugs. The narrative concluded with all VaultStaticSecrets migrated from External Secrets Operator (ESO) to Vault Secrets Operator (VSO), and all dynamic secrets reconfigured.

That was not entirely true. A few secrets had remained on ESO.

Five were copies of the same wildcard TLS certificate, distributed across different namespaces. The last one was an OAuth secret for Tailscale. All shared the same characteristic: the data was not stored in Vault as a single secret with multiple keys, but as separate paths — the certificate on one side, the private key on the other.

It seemed like a simple task. Create a VaultStaticSecret for each secret, as we had done for the other twenty. Instead, it became a journey through VSO's architectural limitations, a controller deadlock, a merge engine that would not merge, and research that led us to rediscover the obvious: the best solution was where we started.

## The Problem: Two Vault Paths for a Single TLS Secret

TazLab's wildcard certificate is stored in HashiCorp Vault on two separate paths:

```
secret/data/tazlab-k8s/static/tls/wildcard/WILDCARD_CRT   → {value: "<PEM certificate>"}
secret/data/tazlab-k8s/static/tls/wildcard/WILDCARD_KEY   → {value: "<private key>"}
```

This separation is intentional: in many enterprise environments, certificates and private keys are managed by different pipelines and sometimes by different teams. It is not a questionable design choice — it is a security practice that makes sense. But it creates a technical problem when a Kubernetes orchestrator must produce a single `kubernetes.io/tls` secret containing both.

With ESO, this had never been an issue. A single `ExternalSecret` reads from two different Vault paths and merges them into one Kubernetes secret using the template engine:

```yaml
# ExternalSecret — working for months
data:
  - secretKey: crt
    remoteRef:
      key: tazlab-k8s/static/tls/wildcard/WILDCARD_CRT
      property: value
  - secretKey: key
    remoteRef:
      key: tazlab-k8s/static/tls/wildcard/WILDCARD_KEY
      property: value
target:
  template:
    data:
      tls.crt: "{{ .crt }}"
      tls.key: "{{ .key }}"
```

The migration to VSO seemed straightforward. One `VaultStaticSecret`, one path, one transformation. Except VSO enforces a 1:1 mapping: a VaultStaticSecret reads a single Vault path and produces a single Kubernetes secret. This is a documented architectural limitation, not a bug. Merging two paths requires two VaultStaticSecrets.

And that is where the problems began.

## First Attempt: Two VSS with Shared VaultAuth

The most obvious solution: two VaultStaticSecrets in the same namespace, both with `vaultAuthRef: vso-system/vso-jwt-auth`, each reading a different path and writing to the same destination secret.

```yaml
# VSS 1: reads WILDCARD_CRT, writes tls.crt
# VSS 2: reads WILDCARD_KEY, writes tls.key
# Both → destination: wildcard-tls (same name)
```

It seemed to work. The VaultStaticSecrets were created, the VaultAuth was Healthy. But after a few seconds, the VSS in multiple namespaces showed empty status — no errors, no columns, just blank rows in `kubectl get`.

Analyzing the VSO controller logs revealed a precise pattern: only 3 VSS out of 10 were being processed, and their `lifetimeWatcher` remained in "Starting" state without ever completing. The other 7 were not processed at all.

The cause was a race condition in the VSO controller, related to internal locking mechanisms in the `cachingClientFactory`. When multiple VSS in the same namespace share the same VaultAuth, they share the same cache key for Vault authentication. The first VSS acquires the lock and creates the client. The second tries to register a callback on the same already-running client — but the callback channel is unbuffered, and since the receiver has not yet started its listener loop, the write blocks indefinitely. The lock is never released, and all subsequent VSS cannot proceed.

The VSO controller has 100 worker threads, but if all 100 share the same lock — because all VSS point to the same VaultAuth — they are all blocked.

## Second Attempt: VaultAuth per Namespace

The first idea: create a dedicated VaultAuth for each target namespace. This would force different cache keys and isolate the deadlock to one namespace at a time.

I created 5 local VaultAuth resources, one per namespace. It worked: VSS in different namespaces no longer blocked each other. But within the same namespace, the second VSS still caused the deadlock. With two VSS per namespace (one for CRT, one for KEY), the first VSS acquired the lock and the second blocked.

The problem was structural: with two VSS per namespace, the second one always deadlocked.

## Third Attempt: Kyverno for the Merge

At this point the path seemed clear: we needed a third component to handle the merge. Kyverno seemed the natural choice — a Kubernetes policy engine that can generate resources in response to events.

The plan was:
1. Two VaultStaticSecrets in `vso-system` with two different VaultAuth resources (different names → different cache keys → no deadlock)
2. Each produces an intermediate secret (`wildcard-crt`, `wildcard-key`)
3. Kyverno watches the two intermediates, merges them into a single `kubernetes.io/tls` secret
4. Reflector (EmberStack) distributes the secret to the target namespaces

The setup worked. The VSS were Synced/Healthy/Ready. The Kyverno ClusterPolicy had been created. Then I discovered the problem.

**Kyverno's generate with data source does not react to trigger updates.**

From the Kyverno documentation: `Modify Trigger → Downstream deleted`. When the trigger (the intermediate secret) changes, the downstream (the consolidated secret) is deleted, not updated. And since the generate rule only fires on CREATE, not on UPDATE, after the deletion the downstream is never recreated.

The `clone` pattern would have worked (`Modify Source → Downstream synced`), but it requires a single pre-consolidated source — exactly the original problem.

Enterprise research highlighted the existence of `mutateExisting` (which does not delete the downstream on failure), but the complexity of the three-resource solution (VSS → mutateExisting → clone with Reflector) started to feel disproportionate for a single TLS certificate.

## The Solution: ESO Multi-Path + Reflector

At this point the question was: why not simply use ESO?

ESO is still installed in the cluster. Its `ClusterSecretStore` is working. It natively supports multi-path merge with a template engine. The only reason we wanted to migrate was uniformity — having everything on VSO.

I created a single `ExternalSecret` in `vso-system` that reads both Vault paths and produces the `kubernetes.io/tls` secret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: wildcard-tls
  namespace: vso-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: tazlab-secrets-vault
  target:
    name: wildcard-tls
    template:
      type: kubernetes.io/tls
      metadata:
        annotations:
          reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
          reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
          reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "auth,dex,hugo-blog,hugo-wiki,ai-agents"
      data:
        tls.crt: "{{ .crt }}"
        tls.key: "{{ .key }}"
  data:
    - secretKey: crt
      remoteRef:
        key: tazlab-k8s/static/tls/wildcard/WILDCARD_CRT
        property: value
    - secretKey: key
      remoteRef:
        key: tazlab-k8s/static/tls/wildcard/WILDCARD_KEY
        property: value
```

With Reflector distributing the secret to the 5 target namespaces. Everything worked on the first apply: `SecretSynced` in 5 seconds, all namespaces populated in 10 seconds.

I removed Kyverno, the excess VSS, and the duplicate VaultAuths. The cluster ended up cleaner than before.

## The Discovery: The Bug That Was Not a Bug

During research, I found references to VSO PR #867 — "Vault client callback handler" — described in some discussions as the cause of the deadlock. I spent hours designing workarounds for a bug that had already been fixed.

PR #867 is not the bug, it is the fix. Introduced in VSO v1.4.0, it completely restructures the callback registration mechanism to avoid the deadlock that affected previous versions. The deadlock we saw was not PR #867 — it was a different problem, likely related to cross-namespace VaultAuth usage and internal lock contention.

The lesson is clear: when researching a problem, you must verify not only the presence of similar issues, but also the exact version in which they were resolved. A bug fixed in the version you are using is not your problem — your problem is something else.

## Lessons Learned

**Preventive research cannot predict everything.** CRISP 2.0 mandates structured research before every implementation. And we did research. Plenty of it. But some discoveries — like Kyverno's behavior with generate+data, or the fact that the deadlock was not PR #867 — only emerged during implementation. Research reduces uncertainty but does not eliminate it.

**The simplest solution is often the right one.** We spent hours migrating from ESO to VSO for uniformity. Then we spent hours solving the problems created by the migration. In the end, we went back to ESO for the two secrets that required multi-path merging. Had we started from an objective analysis — "what does each tool handle well?" — we would have saved time.

**Not all secrets must live on the same operator.** Having ESO for certain cases and VSO for others is not an architectural failure. It is a pragmatic choice. Architectural purity is less important than operational stability.

**Compromise is a valid strategy.** The perfect migration (everything on VSO, everything in one afternoon) was not possible. The pragmatic migration (VSO for most, ESO for complex cases) worked. We removed three operators (Vault Agent Injector, Reloader, Kyverno) and kept two (VSO + ESO). The cluster is simpler today than it was at the start of the session.

## Conclusion

In the end, the current configuration is:

- **VSO** manages 11 VaultStaticSecrets, 1 VaultDynamicSecret
- **ESO** manages 2 ExternalSecrets (wildcard TLS, tailscale-operator-oauth)
- **Reflector** distributes the TLS certificate to 5 namespaces
- **Zero** Vault Agent Injector, Reloader, Kyverno

Next time someone says "let us migrate everything from ESO to VSO for uniformity", I will answer: "First check if you have multi-path secrets. Then we will talk."
