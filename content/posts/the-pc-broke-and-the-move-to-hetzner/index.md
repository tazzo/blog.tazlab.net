---
title: "The PC broke: moving the house to Hetzner in two days"
date: 2026-10-28
draft: true
tags: ["homelab", "hetzner", "terraform", "vault", "gitops", "disaster-recovery"]
---

> Working material: measured facts, numbers, lessons. To be rewritten as prose.

## The failure

The PC that held the home cluster shuts itself down from overheating. Not a disk, not an update: the
machine cannot take it any more. The house (Proxmox, the containers, the cluster) lives there.

Decision: **move everything to Hetzner**, and do it while the PC is up in bursts. The rule that drove
everything: save what cannot be rebuilt first, fix the rest after.

## What lived there (and what was rebuildable)

| thing | state |
|---|---|
| the Kubernetes cluster (was on Proxmox) | **stateless**: all in git plus one database |
| Vault | on a Hetzner VM (already outside the house) |
| Ambrogio + Ambrogio Memory | **real state**: two SQLite files (`ambrogio.db`, `memory.db` 135 MB) |
| ADA (the agent house) | **real state**: `agent.sqlite` 450 MB, plus code with 125 unpushed commits |
| wg-easy (VPN) | config with the clients' keys |
| 21 repositories | three with unpushed commits |

## The rescue, in order

1. **Tarballs of the homes** from CT106 and CT110 (ambrogio, memory, ADA, `/etc/ada`), plus the binaries.
2. **Git**: 21 repos audited, three were ahead — `ada` **+125 commits** (its `origin` was a bare repo
   inside the container: it had *never* reached GitHub), `tazpod` +1, `tazlab-secrets` +16. Bundled
   first, then pushed from the laptop with the gopass token.
3. **Database**: `sqlite3 .backup`, **not `cp`**. The first attempt with the engine running gave
   `entries 22016 / max_id 46040` against `22020 / 46048`: four writes in between. Redone with the
   engine stopped: `22022 = 22022`, `max_id 46052 = 46052`, `integrity_check ok`, 518 MiB, sha256
   `db19d75f…`.
4. **Secrets**: never in the backup. Names only; values in gopass (`vpn/wg-easy/wg0.conf`, `wg0.json`).
5. **Shutdown**: containers stopped, then `systemctl --force poweroff` (the first shutdown hung on
   waiting units).

## Recovering the cluster (the part nobody writes about)

The secret chain would not start. Six failures, in the order they surfaced:

1. **`gopass show -o` truncates multi-line secrets**: Vault's CA reached Kubernetes as
   `-----BEGIN CERTIFICATE-----`, 27 bytes. VSO: *no valid certificates found*. gopass was innocent.
2. **Tailnet DNS**: pods do not resolve `*.ts.net`; fixed by pointing VaultConnection at the egress
   proxy (`…tailscale.svc.cluster.local`) with `tlsServerName` on the MagicDNS name.
3. **JWT mount never created** (`jwt-hcloud`): Vault only had the Proxmox backend.
4. **Per-component roles** missing on the new backend.
5. **`bound_issuer`**: a Talos token carries the cluster endpoint in `iss`, and Vault compares it
   verbatim — a comma-separated list does not match.
6. **DNS records** for `dex`, `auth`, `ambrogio` still on the home IP.

Plus the **database**: PGO restores `dataSource` only when an instance set is born. It is not an
automatic behaviour. On Proxmox the data was on the volume, and the block had been **removed** before
the PG16→17 upgrade. Here the volume was new: empty database. Restored by hand from S3 (full 25/10 +
diff 26/10), then made **declarative**: `dataSource` in the shared manifest, pinned to
`--set=${postgres_restore_set:=…}`, so a rebirth on either target behaves the same.

## Final numbers

```
Flux 26/26 · VaultStaticSecrets 14/14 · PKI 7/7
blog/wiki/teaching/halloween = 200 (Let's Encrypt TLS) · apex 301
DB: 245 conversations · 20 752 entries · 1 238 documents · 19 643 tasks
Vault VM: CX23 (2 vCPU, 4 GB, 40 GB) · Vault 50 MB, local auto-unseal
```

## Lessons (the ones worth an article)

- **A file that opens is not a backup**: verify with `integrity_check` *and* by comparing
  `count(*)`/`max_id` against the live database.
- **`.backup`, never `cp`**: with WAL active, copying the main file is inconsistent; and a `.backup`
  of a database being written restarts at every commit (livelock).
- **The CA was in gopass**: the bug was the flag that read it.
- **A restore is not automatic**: if you want it idempotent across two platforms, declare it.
- **Access is a secret like any other**: without the right key you go to rescue mode (and Vault's
  auto-unseal turns a reboot into an event, not a risk).
