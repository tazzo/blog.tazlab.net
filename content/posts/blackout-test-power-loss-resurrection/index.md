+++
title = "Blackout Test: Power Loss and Resurrection of TazLab"
date = 2026-04-29T00:00:00+00:00
draft = false
tags = ["Kubernetes", "Talos OS", "Flux", "Longhorn", "Proxmox", "Disaster Recovery", "High Availability", "Home Lab", "Power Loss"]
description = "A sudden power outage shut down the TazLab cluster. Manual PC restart, and in 10 minutes everything was back online — almost everything. Here's what worked, what didn't, and why."
+++

## The Moment of Panic

I open the terminal, run `kubectl get nodes`, and nothing. Timeout. I try again. Still nothing.

The first thought is always the same: "what did I break this time?". It's a conditioned reflex of anyone running a home lab cluster — every time something doesn't respond, it's almost always my own failed experiment. I check the node IP, I check Proxmox, I check the firewall. Nothing.

Then I remember: last night the power went out.

And that's when I realize: I didn't break anything. It was the blackout. But there's a second problem I hadn't considered: the mini PC hosting Proxmox doesn't have auto-power-on configured. The BIOS is set to "power off" after a power interruption, not "power on". So the machine was simply off, waiting for someone to press the button.

It wasn't a failure. It was the absence of infrastructure that could turn itself back on.

## Ten Minutes of Waiting

I physically go to the PC, press the button, and wait. Proxmox starts, the Talos VMs boot up, and I sit staring at the terminal like watching toast that won't pop.

Ten minutes later, everything was up.

I'm not exaggerating. The Talos nodes were `Ready`, etcd had re-elected its leader, the Flux controllers — kustomize-controller, helm-controller, source-controller — were reconciling. Pods were visibly coming back: first cert-manager and Traefik, then External Secrets, then the applications. The blog, the wiki, the PostgreSQL database, Mnemosyne — all working. I didn't type a single `kubectl` to fix things. The cluster recovered by itself, exactly as it was designed to.

Flux has a behavior I've grown to appreciate in this moment: it looks at the Git repository, reads all the Kustomizations, and applies them in dependency order. First namespaces, then operators, then configs, then applications. It's a declarative DAG (Directed Acyclic Graph). When it started after the reboot, it simply repeated the same process as the initial bootstrap — only this time the nodes were already there, the database had already recovered, and the images were already cached. It was fast.

## Almost Everything: The Volumes That Didn't Make It

When I say "almost everything," I'm talking about Longhorn.

Of the five volumes managed by Longhorn, one was healthy — the PostgreSQL database — and the other four were in `faulted` state. The database survived because PostgreSQL uses the Write-Ahead Log (WAL): when it restarts after an unclean shutdown, it replays the transaction log and recovers everything that was committed before the crash. It's a decades-old protection mechanism, and it works.

The other volumes — Prometheus, pgAdmin, OpenClaw's configuration — don't have this protection. With Longhorn configured at a single replica, there was no second healthy copy to promote in place of the one corrupted by the sudden shutdown.

This isn't a Longhorn bug. It's a direct consequence of the architecture: I have a single physical host simulating a cluster. Longhorn manages volume lifecycles through two components: the **engine**, which exposes the volume as a block device, and the **replicas**, which store data on disk. After a power loss, the engine tries to restart, but if the only available replica has a failure timestamp, it stops. With multiple replicas, Longhorn selects the most recent healthy one and rebuilds the others.

On a real cluster with three nodes and two replicas per volume, a node going down doesn't cause data loss — the other replicas keep working, the engine moves to a healthy node, and the volume remains accessible. Here, with a single physical machine, there's no room for this redundancy.

The right question isn't "why did Longhorn fail?", but "why did PostgreSQL work?". The answer is the Write-Ahead Log: every transaction is first written to a sequential log and only then applied to the data. An unexpected crash means that on startup, PostgreSQL replays the log, finds the last valid checkpoint, and recovers — or discards — any uncommitted transactions. Longhorn doesn't have this level of protection at the volume level: if the engine stops while writing, the replica can remain in an inconsistent state.

## Why (Almost) Everything Worked

The most important result of this event is not what broke, but what held up.

Talos Linux, the immutable operating system of the nodes, restarted without intervention. etcd rebuilt quorum. Flux read the desired state from the Git repository and reconciled it without me having to do anything. The stateless applications (blog, wiki) were up and running in minutes. The PostgreSQL database resumed serving queries after recovering its WAL.

This is the practical proof that the three-layer architecture I built works:

- **Talos** manages the operating system — immutable and self-healing
- **Flux** manages the desired state — always aligned with the Git repository
- **Longhorn** manages storage — but pays the price of the minimal configuration

The cluster didn't need me to recover. It only needed the PC to be turned back on.

## Salvaging Prometheus

I scaled the Prometheus StatefulSet to zero, removed the `failedAt` and `lastFailedAt` fields from the Longhorn replica, and set the volume's `nodeID`. The engine restarted, the volume reattached, and I scaled the pod back up. All the metrics — ten gigabytes of history — were intact.

For the pgAdmin and OpenClaw volumes, I didn't even attempt a salvage. They were disposable data — local configuration and workspace — and the correct procedure for non-critical data after a fault is: throw it away, recreate it, move on. Flux took care of creating the new clean PVCs.

## The Lesson

This event taught me three things.

First, the architecture I designed for TazLab — Talos + Flux + Longhorn — handles an unscheduled shutdown better than I expected. It's not an enterprise cluster, but it behaves like one for most workloads.

Second, the single-replica Longhorn configuration is the weak point. It works perfectly for a lab where data can be discarded, but it's exactly where the problem shows up when a node shuts down uncleanly. It's a conscious choice: I have a single physical host, and two replicas on the same disk don't provide real resilience.

Third, BIOS auto-power-on is not a detail to overlook. The cluster handled everything perfectly, but it couldn't restart on its own because the PC was physically off. Such a trivial detail required manual intervention, while everything else — Talos, etcd, Flux, the pods — would have recovered autonomously.

If TazLab were an enterprise cluster with five or more nodes, this blackout would have been a non-event. Talos nodes would be redundant, etcd would have three or five members, Longhorn volumes would have replicas on different nodes, and workloads would have shifted automatically. I wouldn't even have noticed the problem — I would have seen a few rescheduled pods and moved on.

But TazLab isn't an enterprise cluster. It's a lab on a single mini PC simulating a cluster. And in this context, the test was passed. The cluster did everything it could, and it did it well. The limitation isn't in the architecture — it's in the hardware, and it's a conscious choice.

## Conclusion

A blackout is the ultimate test for an infrastructure. You can't cheat: either the cluster recovers on its own, or it doesn't. TazLab recovered. Not perfectly — the faulted volumes prove it — but well enough to convince me that the design direction is the right one.

Next time the power goes out, though, the PC will turn itself back on. I've already added the technical debt (TD-023) to remind myself to configure that damn BIOS setting.
