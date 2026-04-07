+++
title = "Golden image runtime on Hetzner: the path to the final version"
date = 2026-04-07T12:38:03+00:00
draft = false
description = "How I completed my first full runtime golden image pipeline on Hetzner, using Ansible for the first time, with multiple validation cycles and a clean operational closure."
tags = ["hetzner", "golden-image", "ansible", "devops", "automation", "infrastructure", "linux", "testing"]
categories = ["Infrastructure", "DevOps"]
author = "Taz"
+++

## Objective of the session

The goal was simple to describe but not trivial to close properly: to arrive at a **stable, reusable runtime golden image** on Hetzner, ready to be consumed in the next foundation phase.

In practical terms, I wanted to eliminate heavy runtime bootstrap and move the work into build-time: prepare a builder VM, configure it, validate it, freeze it into a snapshot, then verify that machines born from that snapshot are coherent and predictable.

At the method level, I imposed a clear operational rule: not to stop at the “first time it seems to work,” but to close the full cycle all the way to a final version verified on fresh instances. This led to multiple iterations (`v1` → `v4`), but that was the necessary step to turn a local result into a reliable artifact.

## Why a golden image before the foundation

When building an infrastructure foundation, mixing provisioning, package installation, hardening, and application bootstrap at the same time creates a domino effect that is difficult to diagnose. If something fails, it is never immediately clear whether the problem is:

- in the network layer,
- in the access layer,
- in the runtime layer,
- or in a race condition during bootstrap.

The golden image separates responsibilities:

1. **Build-time**: I prepare the base runtime once, in a repeatable way.
2. **Deploy-time**: I instantiate and converge the network/foundation with fewer variables in play.

This approach reduces the error surface and makes troubleshooting more readable. It is not just an “elegant” choice: it is a practical choice when I want to deliver a pipeline that holds up in future sessions, not just in the current demo.

## The builder profile: economical but sufficient

An explicit constraint of the session was to use the cheapest profile possible, as long as it was adequate:

- **`cx23`**
- **4 GB RAM**
- **40 GB SSD**
- shared CPU

This choice was kept across all final iterations. This is important because it avoids building a pipeline that works only on more expensive sizes and then degrades when brought back to realistic profiles.

In other words, I wanted to verify behavior within the real economic perimeter of the project, not in a “comfortable” environment.

## First real use of Ansible in my flow

This was the first time I used **Ansible** in a central way in my process, not as a secondary tool. The operational difference was clear: moving from manual actions to repeatable declarative configuration.

The playbook covered the runtime baseline with:

- packages required by the runtime,
- a coherent user model (`admin` for operations, `vault` non-interactive),
- SSH hardening (password authentication disabled),
- minimal but deterministic system configuration.

An example of the core of the playbook used during build:

```yaml
- name: Configure Hetzner runtime golden image baseline
  hosts: builder
  become: true
  vars:
    runtime_packages:
      - podman
      - python3
      - curl
      - jq
      - ca-certificates
      - gnupg
      - apt-transport-https

  tasks:
    - name: Update apt cache
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600

    - name: Install runtime baseline packages
      ansible.builtin.apt:
        name: "{{ runtime_packages }}"
        state: present

    - name: Ensure admin user exists
      ansible.builtin.user:
        name: admin
        shell: /bin/bash
        groups: sudo
        append: true
        create_home: true
        state: present

    - name: Ensure vault service user exists (no login)
      ansible.builtin.user:
        name: vault
        shell: /usr/sbin/nologin
        create_home: false
        system: true
        state: present
```

The practical value was not “Ansible itself,” but the fact that every correction entered the playbook instead of remaining a manual workaround forgotten in the next session.

## The build and validation cycle

The full operational flow was:

1. create builder VM,
2. apply baseline with Ansible,
3. technical validations,
4. power off builder,
5. snapshot,
6. test on a new VM from the snapshot,
7. cleanup of temporary resources.

This cycle was repeated multiple times until all inconsistencies between “the builder works” and “a fresh instance really works” were removed.

### Why multiple snapshots (v1, v2, v3, v4)

This was the most important point of the session: true stability is not measured on the node I have just configured, but on a new machine born from the artifact.

Each iteration removed a practical defect that surfaced only when retesting on a fresh instance. In the end, instead of keeping a chain of “almost good” snapshots, I chose a cleaner policy:

- promote only the final valid version,
- delete intermediate versions,
- lock a single handoff ID.

## The most concrete defect: different behavior across users

Part of the stabilization was making sure commands were available not only to root but also to the operational user.

This kind of problem is typical in image pipelines: installations that look correct but are tied to user-specific paths or shell contexts. The final solution was to make publishing the binary explicit in a system path (`/usr/local/bin`), so visibility would be uniform for root/admin on snapshot-born instances.

The lesson here is straightforward: when validating a golden image, it is not enough to verify “command present.” I also need to verify **presence + execution + target user**.

## The part that looked like an image bug but was not

At an advanced stage I saw tests fail with VMs reported as `running`. The initial suspicion can easily drift toward a corrupted snapshot or incomplete bootstrap. In reality, the problem was different: unstable local connectivity in the working network (mobile hotspot), especially on the IPv6 path during certain time windows.

This has a huge practical impact on debugging: I can lose hours changing the image when the actual problem is in the client→server path.

To avoid false positives, I separated the two planes:

- image artifact quality,
- test channel reliability.

From there came the final operational decision for the test pipeline: robust IPv4 by default in mobile contexts, IPv6-only as an explicit mode when the local network is confirmed.

## Hardening the test harness

To close the session properly, I did not stop at “the test passed once.” I also consolidated the operational tools.

I structured three main scripts:

- dynamic inventory generation,
- end-to-end golden image build,
- image test with validations and cleanup.

A simplified example of the test script intent:

```bash
./scripts/test-image.sh \
  --image-id 373384231 \
  --server-name lv-img-script-test-ipv4-final
```

The key point is that the test does not stop at SSH ping. It explicitly verifies the expected binaries for both operational users, and closes the cycle by deleting the test VM at the end.

## Final result

Final promoted artifact:

- **Snapshot name**: `lushycorp-vault-base-20260404-v4`
- **Image ID**: `373384231`

Satisfied criteria:

- runtime baseline applied repeatably,
- validation on a fresh instance,
- coherent behavior for root/admin,
- stable test harness with explicit cleanup,
- no VM left active at the end of the run.

## What I take away from this stage

This session was not just about “building an image.” It was a stage in the maturation of the process.

The things that made the real difference were:

1. **Separating build-time and deploy-time** to reduce diagnostic noise.
2. **Using Ansible as the source of truth** for configuration, not as occasional support.
3. **Always validating on new instances**, not stopping at the builder machine.
4. **Distinguishing infrastructure bugs from local network bugs** before changing the artifact.
5. **Closing with rigorous cleanup** to avoid polluting the next cycle.

From an operational perspective, the golden image pipeline is now in a usable state: not perfect in the abstract, but sufficiently deterministic to become a reliable input for the foundation phase.

And that is exactly the kind of result I was looking for: less “a script that works today,” more “a process I can reopen tomorrow without starting from zero.”
