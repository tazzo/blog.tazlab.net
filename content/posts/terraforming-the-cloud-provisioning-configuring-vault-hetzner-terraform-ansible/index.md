+++
title = "Terraforming the Cloud: Provisioning and Configuring Vault on Hetzner via Terraform and Ansible"
date = 2026-04-11T20:38:00+00:00
draft = false
description = "How several days of focused design made it possible to implement the local lifecycle of Vault on Hetzner in a few hours, add remote durability on S3, close the entire C2 test matrix, and leave VM, TazPod, and S3 in a coherent final state."
tags = ["hetzner", "vault", "podman", "tailscale", "ansible", "s3", "backup", "disaster-recovery", "devops", "infrastructure", "crisp", "architecture"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# Terraforming the Cloud: Provisioning and Configuring Vault on Hetzner via Terraform and Ansible

There are infrastructure sessions where the primary value is not the number of modified files, but the confirmation that the working method is actually working. This is one of those.

In recent days, I had very cleanly separated two phases of the Vault runtime on Hetzner. The first, `hetzner-vault-local-lifecycle` (C1), aimed to prove that the node could exist as a coherent local entity: TLS, Raft storage, strict bootstrap, automatic unseal, and clear identity contracts. The second, `hetzner-vault-s3-backup-recovery` (C2), was to add remote durability and recovery: periodic snapshots, coherent pointers on S3, comparison logic, remote durability repair, and, above all, a restore path when the local node no longer exists but the cryptographic truth in the controller and the remote backups are still healthy.

Chronologically, they seem like two separate jobs. In reality, however, they were a single path. For about three days I worked almost exclusively on design: review, refinement, clarification of contracts, definition of nomenclature, decision matrix, responsibility between Ansible and shell helpers, behavior in case of ambiguous state, bootstrap flow, the role of TazPod, receipt structure, restore limits. Then, when the time came to implement, the hard work was already done. The execution part compressed into a few hours and, above all, took place with a fluidity very different from the typical work of this kind.

This does not mean there were no problems. There were, and some were even instructive. But the type of problem changed. I didn't find myself questioning the architecture in the middle of the session. Instead, I faced integration problems, operational details, and the actual behavior of tools like Podman, systemd, Tailscale, and Vault. It's a huge difference. When the design is solid, even the unexpected stops being chaos and simply becomes an anomaly to isolate and correct.

In this article, I recount the entire transition: from the local lifecycle to the remote backup on S3, with the live verification of snapshot rotation, the proof that the remote state can be initialized and repaired starting from the local truth, the real test of the "unchanged snapshot" case, the destructive restore cycles, and, above all, the complete closure of the C2 matrix. At the end of the work, no "almost ready" branch remained: the VM is coherent, Vault is active, TazPod is coherent, S3 is coherent, the backup timer is alive, and the entire set of scenarios designed for C2 was executed and brought to green.

## The starting point: an already credible C1, not a fragile prototype

The first important element to understand is that C2 was not built on an improvised foundation. The work on C1 had already eliminated much of the initial entropy.

The Vault node on Hetzner was no longer a simple container "that starts". It was already a runtime with its own well-defined identity. The host node was `lushycorp-vm.ts.tazlab.net`, the Vault TLS service was `lushycorp-api.ts.tazlab.net`, the persistent paths were stable, the TLS configuration was clear, the bootstrap produced a `vault_lineage_id`, the local receipt told the identity of the cluster, and the automatic unseal mechanism already had a precise shape.

This distinction is also fundamental from a methodological point of view. Many backup and restore problems arise because you attempt to design remote recovery when the local system is not yet rigorously defined. In that case, the remote layer inherits ambiguities already present in the local layer and amplifies them. Here the opposite happened: the work done on C1 reduced the degrees of freedom. When I started C2, I no longer had to decide "what" the Vault node was. I only had to decide how to rigorously extend an already defined identity.

Here it is worth clarifying immediately a term that I use often in the rest of the article: **lineage**. By `vault_lineage_id` I mean the stable identity of a specific life history of the Vault, that is, the "genealogical line" of that instance: it is born at the first bootstrap, it is kept in local receipts and canonical artifacts in TazPod, and it serves to distinguish a true restore of the same instance from a new initialization that instead produces a new identity. In practice, if I recreate the node but I am really bringing the same Vault back to life, the lineage remains the same. If instead I do a fresh init and a new Vault is born, a new lineage is also born.

This is why the division into phases proved so useful. `foundation`, `local lifecycle`, `remote durability` were not just names of convenience. They were true diagnostic boundaries. If something broke in the remote durability, I already knew I wasn't debating TLS, baseline Tailscale, elementary Podman runtime, or local bootstrap. This drastically reduces the noise when reading logs and having to make quick decisions.

## The real value of the three days of design

The most interesting part of this session, at least for me, was not so much writing the Ansible code or the helper scripts. It was seeing very concretely that the three days of design had really transformed the implementation session.

The point is not simply that "it went faster". Speed, in infrastructure, says little by itself. You can go fast in the wrong direction too. The point is that the session took place without the typical breaks in continuity that happen when you program the architecture while writing the code. I didn't have to stop halfway to ask myself if the bucket should contain the latest global snapshot or the latest snapshot per lineage. I didn't have to redefine what a "legitimate" restore was. I didn't have to decide on the fly whether the admin token should be recreated always or only in certain cases. All these choices had already been made explicit.

This had a very practical effect: when a problem emerged, the problem was confined. If the backup service unit was not passing the right variables, the correction was local. If the snapshot path was not mounted in the container, the correction was local. If two logically identical snapshots had different binary hashes, the problem didn't suddenly become a crisis of the backup strategy; it became a refinement of the comparison contract. This difference between "confined problem" and "systemic problem" is the reason why I consider this session a success.

In more didactic terms: preventive design does not eliminate bugs, but it transforms the type of bug you encounter. It reduces the risk of architectural bugs, that is, those that force you to change your mental model halfway through the work. What remains are integration bugs, real behavior bugs, interfaces between components. They are still annoying, but much more manageable.

## C2 in practice: what it really had to do

The second phase of the project shouldn't have been limited to "saving files to S3". Such a simple formulation would have been dangerously incomplete. The real goal was to introduce **coherent remote durability** without confusing the concept of backup with that of identity.

A coherent local Vault produces a certain cryptographic truth: unseal keys, administrative tokens, lineage, Raft state. A useful remote backup is not simply a blob of data; it is an artifact that must be able to be reconnected reliably to that same identity. This is where the contract of pointers and metadata comes from. It is not enough to upload a snapshot. You need to know which lineage it represents, which slot is active, which hash it corresponds to, and what the correct candidate is to use in the restore phase.

For this reason, I implemented three distinct levels in the bucket:

1. a **global pointer** (`vault/raft-snapshots/latest.json`) indicating the active lineage;
2. a **lineage-local pointer** (`vault/raft-snapshots/<vault_lineage_id>/latest.json`) indicating the current restore candidate for that lineage;
3. two remote slots (`slot-a` and `slot-b`) that allow a simple and readable rotation.

This structure was an important choice also for operational readability. In the incident response phase, an elegant but opaque system is often worse than a slightly more verbose but transparent system. Here I wanted an operator, reading objects in S3 or local logs, to be able to understand what the active state was without having to "guess" based on implicit conventions.

## The implementation of the C2 runtime

The physical implementation was distributed over a fairly wide area, but very tidy. I added a dedicated playbook (`vault-s3-backup-recovery.yml`), new task files in the shared Ansible role, two dedicated shell helpers for backup and restore, and new systemd units for the hourly timer and for the explicit restore.

An important aspect of the design was the division of responsibilities between **Ansible** and **shell helpers**. The helpers shouldn't "decide" the behavior of the system. They had to mechanically execute restricted operations: save a snapshot, calculate hashes, read or write S3 objects, execute the restore primitive when already authorized. The visibility of choices — restore yes/no, failure yes/no, selected lineage, need for recreation of the admin token — had to remain in the Ansible tasks. This is not just a stylistic quirk. It is a choice that improves auditability and debugging. A state machine that lives in separate tasks is much more readable than a shell script that engulfs everything and returns a generic exit code.

New operational fixed points also appeared on the host node:

- `/etc/lushycorp-vault/s3.env` for root-only S3 credentials;
- `/etc/lushycorp-vault/remote-restore.env` for the restore request contract;
- `/etc/lushycorp-vault/snapshot-backup-token.txt` for the token limited to backup;
- `/var/log/lushycorp-vault/vault-snapshot-backup.log`;
- `/var/log/lushycorp-vault/vault-remote-restore.log`.

This detail of the paths is less trivial than it seems. In long sessions or those distributed over several days, the difference between an "observable" system and one that forces you to guess the state from secondary symptoms is enormous. Here every important phase has its own log known before startup. When something went wrong, I didn't have to reconstruct ex post where it could have failed. I could read it directly.

## The first problems: good problems, not architectural problems

The first real stumble didn't concern Vault, but the operator node. The first C2 execution failed during the Tailscale validation phase because the system expected the standard `tailscaled` socket, while the local operator was using a userspace instance with a dedicated socket in `/tmp/tailscaled-operator.sock`.

The interesting point is not so much the fix — relaunching `create.sh` with `TAILSCALE_SOCKET=/tmp/tailscaled-operator.sock` — but the fact that the problem was immediately readable and confined. The phase log dedicated to Tailscale validation clearly showed the failure of the local path. There was no ambiguous domino effect on Terraform, Ansible, or Vault. This is exactly the kind of behavior you expect from orchestration well-separated into phases.

Immediately after, two other typical integration problems emerged:

- the backup service unit was not yet passing all the necessary operational variables (`S3_BUCKET`, `S3_PREFIX`, etc.);
- the snapshot path existed on the host but was not mounted in the Vault container.

Both were solved without having to change the model. I corrected the systemd templates to explicitly pass the required environment and I added the mount of the snapshot directory in the container service unit. This is the kind of work that in a poorly prepared session risks triggering broader doubts ("maybe the backup design is wrong"). Here instead it was clear from the start that it was a local wiring defect.

## The initial backup to S3: first real test of phase C2

Once the wiring part was corrected, the first real backup did what I expected from C2: it treated the remote layer as authoritatively reconstructible starting from a healthy local truth.

This point deserves an explanation. In the model I had defined, an "empty" or "incoherent" S3 must not block an already coherent local Vault. If the local node is healthy and TazPod is healthy, the remote layer is not the primary source of truth: it is the secondary durability. Consequently, the next backup must be able to initialize or repair the remote content without transforming a backup problem into a total blockage of the runtime.

And that is exactly what happened. The first successful backup:

- classified the remote state;
- wrote snapshot and metadata to S3;
- created the global pointer;
- created the lineage-local pointer;
- set the first active slot.

This is not a purely "mechanical" victory. It is the proof that the distinction between local truth and remote durability had been modeled correctly. If the design had been more confused, the system could have attempted absurd restores, blocked the node out of excessive prudence, or written remote objects lacking sufficient context for a future rebuild.

## Generating a distinguishable state: the `marker-A` marker

To avoid overly abstract tests, I wanted to introduce a clearly recognizable application state inside Vault. I therefore wrote a marker in the KV store, with the identifier `marker-A` and scenario `baseline-before-matrix`.

Why is it important? Because backup and restore tests must not stop at the infrastructure level. Knowing that Vault is "up" or "unsealed" is not enough. In a secrets system, the real question is: *what data exactly does this instance contain?* If after a rebuild the system comes back up but has lost or changed the data, the test has failed even if systemd is happy.

This marker had two very concrete uses:

1. it made visible the difference between snapshots of different states;
2. it provided a reference to reread after the destructive cycles.

It's a small detail, but it well represents the kind of approach I prefer in validations: avoid purely syntactic tests and introduce at least one readable functional signal that allows saying "this is really the same logical Vault that I expected to recover".

## The most interesting discovery: two logically identical snapshots, but different as files

The technically most instructive moment of the session came when I verified the behavior of the "unchanged snapshot" case. The initial contract provided for intuitive logic: if the hash of the current snapshot file is equal to that of the latest remote snapshot, the upload can be skipped.

On paper it is reasonable. In practice, it turned out to be false.

I ran a determinism check by saving two consecutive snapshots without modifying the logical state of Vault. I expected identical files. Instead I got:

- **same logical content** detected by `vault operator raft snapshot inspect`;
- **same Raft index**;
- **different file hashes**.

This is a very important difference. It means that the snapshot binary file incorporates enough variability that it cannot be used as a reliable criterion to say "the logical state has remained the same". If I had left the system like this, every run would have continued to upload new snapshots even in the absence of real modifications.

The correction I introduced was simple in concept but very important in result: I separated **file integrity** and **logical equivalence**.

- `snapshot_sha256` continues to describe the precise file uploaded to S3;
- `snapshot_compare_fingerprint` is calculated from the output of `vault operator raft snapshot inspect` and is used to figure out if the logical state has actually changed.

After this change, the test that would previously have produced a false positive of "changed snapshot" finally returned the correct behavior: `upload-skipped`. For me this is one of the most successful points of the entire session, because it is a perfect example of how a real test can improve the design without destroying it. The overall model was not wrong. It just needed a comparison more suited to the real semantics of Vault.

## The final turning point: really closing the `T1 + H0 + S1` restore

After validating the backup path, I moved to the most delicate part: the `T1 + H0 + S1` case, that is, TazPod coherent, local host empty, S3 coherent. In practical terms: the node is destroyed, but the controller still possesses the canonical bootstrap set and S3 possesses a coherent restore candidate. This is the heart of disaster recovery for phase C2.

When I wrote the first version of this article, that branch was not yet fully closed. The destructive tests had already shown that the restore was selected correctly, that the lineage was resolved the right way, and that the system got very far in the reconstruction. However, there remained two real defects that prevented declaring the matrix green.

The first was a problem of **remote state classification**. In some missing-object conditions on S3, the code did not correctly preserve the distinction between `empty` and `incoherent`. The result was subtle but important: a missing lineage-local pointer could be treated in the wrong branch. The fix was small as a shell modification, but large as an operational consequence: I corrected the capture of the exit code and made the reading of S3 `404`s reliable in both the restore path and the backup path.

The second was the truly decisive problem: **after the restore, the node still did not rebuild its host-side local-unseal path completely autonomously**. In practice, Vault could be brought back up to the correct state, but the two local unseal shares were not always rehydrated and the oneshot unseal service could conclude too early during the window in which the container was not yet at the right point of the post-restore bootstrap.

Here the useful work was not "adding random retries", but respecting the already defined C1/C2 contract:

- the C2 restore now explicitly rehydrates on the host node `unseal-share-1` and `unseal-share-2` starting from the canonical set kept in TazPod;
- the logic of `vault-local-unseal.sh` now better distinguishes the case in which Vault is not yet initialized but the unseal material already exists locally, avoiding declaring success too early;
- the convergence playbook no longer just relies on the systemd oneshot: it explicitly relaunches the local unseal helper after the restore, so the final state check actually happens after the reconstruction of the unseal path.

After these fixes, the `T1 + H0 + S1` branch passed all the way through. The node is destroyed, recreated, Vault is restored from the correct candidate on S3, the local receipt is updated, the host-side unseal shares return, the local-unseal resumes correctly, and the final Vault returns `initialized=true` and `sealed=false` without manual reconciliation.

The most important signal, however, remained the same: after the destructive part and the complete restore, the expected logical content was still there. I was not getting an "alive but new" Vault; I was really recovering the logical instance I wanted to bring back online.

## From half-victory to a complete green matrix

The difference between a promising session and a closed session lies entirely here: at a certain point you stop saying "the model looks right" and you start being able to say "the designed matrix actually passed". That is exactly what happened in the final transition of C2.

After the first implementation block and the first live tests, I already had strong evidence on backup, pointers, repair, and semantic comparison of snapshots. The final work transformed those partial proofs into a complete set of scenarios executed one by one.

In practice, all the cases designed for T7 were closed.

To read the matrix quickly: `T` indicates the state of the canonical set in TazPod, `H` the state of the local host/Vault node, `S` the state of the remote layer on S3. The suffix `0` means `empty`, `1` means `coherent`, `2` means `incoherent`. So `T0` = empty TazPod, `T1` = coherent TazPod, `T2` = incoherent TazPod; `H0` = empty local host/Vault, `H1` = coherent local host/Vault, `H2` = incoherent local host/Vault; `S0` = empty S3, `S1` = coherent S3, `S2` = incoherent S3.

- `T0 + H0 + S0` -> fresh init allowed;
- `T0 + H0 + S1` -> hard fail because the canonical anchor in TazPod is missing;
- `T1 + H0 + S1` -> restore succeeded during `create.sh`;
- `T1 + H0 + S0` -> hard fail, no fake restore;
- `T1 + H0 + S2` -> hard fail;
- `T1 + H1 + S0` -> backup correctly initializes the remote layer;
- `T1 + H1 + S2` -> backup correctly repairs the remote layer from coherent local truth;
- unchanged run -> real `upload-skipped`;
- first valid backup into remote-empty lineage -> write to `slot-a` + lineage-local pointer;
- changed run on coherent lineage -> switch to the inactive slot;
- missing pointer with slots still present -> restore hard-fail and subsequent repair via backup;
- metadata mismatch -> explicit hard fail;
- incoherent TazPod -> hard fail;
- incoherent local host -> hard fail.

This step is important also conceptually. As long as a matrix remains partially open, the system is still "promising". But when you have also covered the ugly cases — missing pointer, corrupted metadata, lineage mismatch, incoherent local state — the system stops being just convincing in a demo and begins to become credible in operation.

## The most beautiful result: the final unexpected events confirmed the design, they didn't demolish it

Paradoxically, the problems that emerged in the last part are the best proof that the days of design really served a purpose.

If the model had been fragile, these last tests would have forced a reworking of the general strategy: perhaps changing the structure of pointers, changing the relationship between TazPod and S3, or rewriting the semantics of `empty/incoherent` cases. Instead, it didn't happen. The problems turned out to be exactly the kind I hoped to encounter in a well-prepared session: local, readable, confined problems.

- a bug in the shell exit code capture;
- a precise problem in the reconstruction of the host-side material after restore;
- a too optimistic timing in the post-restore local-unseal.

These are real problems, but they are not architectural problems. And this, for me, is the difference between a chaotic session and an engineerable session.

## The final state left deliberately healthy and coherent

At the end of the work I did not leave behind a machine "good enough to stop testing". I explicitly reconciled the environment to a clean, coherent, and reusable final state.

The final state is this:

- Hetzner VM active and reachable;
- `lushycorp-vault.service` active;
- `vault-local-unseal.service` active;
- Vault initialized and unsealed;
- TazPod coherent with the canonical artifact set;
- S3 coherent with valid global pointer and lineage-local pointer;
- backup timer active;
- main logs present and available;
- final canonical lineage realigned to `d91c4d14-30a6-4518-b162-d1c1a1b9c069`.

There is a detail that I consider important to tell openly: during the fresh init tests, a new temporary lineage was also generated. It would have been easy to consider it "lab noise" and ignore it. Instead, the serious work is precisely not leaving noise around. At the end of the session that temporary lineage was not left as operational state: the final runtime was brought back in coherence with the original canonical lineage, on host as well as in TazPod and S3.

This choice is intentional. In a context that wants to behave in an increasingly enterprise manner, even the end of the session is part of the work. It is not enough to show that the test passes. The system must be left in a condition that is understandable and operable by the next session.

## Post-lab reflections, now that C2 is truly closed

If I had to summarize this stage in a single sentence, today I would formulate it like this: **design has shifted the difficulty from "understanding what to build" to "precisely closing the final real details until the whole matrix passes"**.

It is exactly the kind of result I wanted to obtain with CRISP. Not because coding must become trivial, but because coding should be the last phase of a chain of already mature decisions. In this session the result was seen very concretely: few truly unexpected problems, all readable from the logs, almost all confined, no collapse of the architectural system, and no really destructive surprise emerging from nowhere.

The difference compared to the first draft of this article is that now I no longer have to stop and say "the recovery is not yet fully closed". I can say something stronger and more useful: the remote backup is real, the comparison of snapshots was corrected based on the actual behavior of Vault, the destructive restore was closed, the hard-fail cases were verified, the runtime remains coherent across TazPod, host, and S3, and phase C2 can be considered concluded.

This, for a secrets platform on a single Hetzner node built with Podman, systemd, Tailscale, Ansible, and S3, is a very significant result. Not because it is "perfect" in an absolute sense, but because it has reached that rare point where design, implementation, destructive tests, and final operational state finally tell the same story.

Designing without rushing did not eliminate work. It made it proportionate. And, above all, it made the implementation linear enough to make something seem natural that, without those days of design, would probably have degenerated into many more hours of chaotic debugging.

For this phase, it is a great place to stop: with a live Vault, credible remote durability, a truly closed recovery, a complete matrix brought to green, and the confirmation that the time spent thinking before coding continues to be the most profitable investment of the entire laboratory.