+++
title = "The Order of Commits: Migrating PostgreSQL from 16 to 17 on Kubernetes"
date = 2026-09-27T08:20:00+02:00
draft = false
description = "The lab's shared PostgreSQL cluster moved from 16 to 17 with PGO's declarative procedure: ninety seconds of work on the data, six minutes of downtime, eighty healthy pods. And two errors the research had carried with it, visible only by executing."
tags = ["postgresql", "pgo", "kubernetes", "gitops", "database"]
author = "Tazzo"
+++

## Why Migrate a Database That Works

The lab's shared PostgreSQL cluster serves four databases and seven consumers: hindsight, mnemosyne, pgadmin, Grafana and the Paperclip agent company, in two containers. It worked well on PostgreSQL 16, and there was no technical urgency.

The push came from outside: a tool I want to adopt requires **PostgreSQL 17**, declared as an explicit requirement in its documentation. The choice was between building a second database just for it, or migrating the one I already have. The second path is the one that keeps the lab simple, but it entails an operation that is **not reversible**: a PostgreSQL major version advance rewrites the system catalog on the volume, and there is no declarative way back.

## Preparation Is Everything

Before touching anything, three jobs that look like bureaucracy and are the substance.

The first: **understanding what the documentation and the cluster actually say**. I verified the [official procedure](https://access.crunchydata.com/documentation/postgres-operator/5.7/guides/major-postgres-version-upgrade/) of the line I have installed (Crunchy Postgres for Kubernetes 5.7.2), not the most recent one, and I inspected the live state: operator version, image tags in its variables, extensions installed in **every** database, free capacity on the node hosting the volume. Some of these checks contradicted the plan I had written, and that is the reason I ran them.

The second: **removing `spec.dataSource` from the manifest**. That field is for bootstrap and disaster recovery; left there during a major upgrade, the controller tries to reconcile a restore while it creates the new instance set, and the `--delta` option can realign the blocks just converted back to the previous version. I removed it with a dedicated commit and verified that the database **did not restart**: zero restarts, unchanged version.

The third: **a complete and verified backup**, plus awareness of the way back in. The lab already has its mechanism: full backup plus WAL on S3, and recreation of the cluster from the `dataSource`. That is what I use in destructive cycles, and for a 306 MB database it means a few minutes. Curiously, the hard part was understanding what does **not** work: the "revert in place" of a volume snapshot onto an already attached PVC does not exist, neither in the CSI standard nor in the storage engine. The in-place rollback I had planned was an illusion, and it was worth discovering it beforehand.

## The Window

The order of the commits is not a preference, it is a technical requirement. In a single commit: the `PGUpgrade` object declaring the pair of versions, `spec.shutdown: true`, the annotation authorizing the upgrade on that cluster (a two-key mechanism: the object must want the cluster, and the cluster must allow the object), and the suspension of the backup schedules — because with the instance off a scheduled backup fails immediately instead of queueing, and it would fill the system with warnings.

Then the wait, and finally the two commits that close it: the **removal of the object** and, only after, `postgresVersion: 17` with `shutdown: false`. Reversing this order makes the upgrade fail, because the controller refuses the reconciliation when a cluster already on the new version still has in front of it the object that brought it there.

The final numbers: **ninety seconds** for the data phase, **six minutes** of total downtime, from the moment the cluster shut down to the restart with 17. The rest of the time was not the database: it was the Kubernetes transitions, the detach and reattach of the volume, and the GitOps reconciliation.

## The Extensions, Which Is the Part That Touches the Data

A major upgrade does not update the extensions by itself. Two of them deserve opposite attention.

**`pgaudit`** is compiled against the engine ABI: there are no migration scripts between majors, so `ALTER EXTENSION ... UPDATE` fails. It must be dropped and recreated — it is stateless, it records no data of its own. In the lab it was installed in **all seven** databases, not only where I thought: had I followed the original plan I would have left six at the previous version, and the automatic update would have failed.

**`vector`** (pgvector) must instead be updated **only** with `ALTER`. Dropping it would destroy the vector columns and their indexes in cascade: an operation that looks like maintenance and deletes data.

## The Two Things the Research Got Wrong

I had two in-depth researches prepared before executing. They were solid and saved me real mistakes — the order of the commits, the pooler's behaviour, the handling of the extensions. But they carried with them **two defects of the same nature**: material from a newer version applied to ours.

The first: a field of the upgrade object, `spec.transferMethod`, that exists in the documentation of version **6.0** of the CRD but **not** in the installed one. The API server rejected it with an unambiguous message — *field not declared in schema* — and the reconciliation stopped until I removed it.

The second: the image tags to pre-pull, indicated as `17.2-0` and `1.23-0` when the installed operator uses `17.2-1` and `1.23-2`. The pre-pull would have downloaded unused images and the real download would have taken place inside the window, which is the opposite of the purpose.

The lesson is not "the researches are useless": it is that **the most recent documentation is not the documentation of your version**. The operator's variables and the schema of the installed CRD are the truth, and they must be queried directly.

## What Remains

The cluster now serves PostgreSQL 17.2, the extensions are aligned, eighty pods are healthy and every consumer was queried with a real query, not just looked at from the "pod ready". The safety net was not needed, and the full pre-upgrade backup remains on S3.

Two things remained open and it is worth saying them. The GitOps reconciliation chain, in this lab, jams: after every commit some resources stay waiting for a dependency that is already ready, and I had to force the reconciliations in order three times. It lengthens the windows and it is not a PostgreSQL problem. And the durable documentation is now behind reality, as always after a successful change: it is the first job of the next round.

If there is one thing I take away from this migration, it is that the value of the plan was not in the list of commands. It was in the **order** — which commit before which, and why — and in the **verification**: everything I took for granted was contradicted by the facts, and everything I verified held.
