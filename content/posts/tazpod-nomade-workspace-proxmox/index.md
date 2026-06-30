+++
title = "TazPod Nomad: My Personal Workspace on Proxmox Accessible from Any Terminal"
date = 2026-06-30T06:00:00+02:00
draft = false
description = "How I turned an LXC container on Proxmox into a full development environment, accessible via SSH from laptop, tablet, and Termux, with tmux for persistent sessions."
tags = ["TazPod", "Proxmox", "LXC", "Tailscale", "Nomadic Computing", "DevOps", "Ansible"]
author = "Tazzo"
+++

## The Problem: A Work Environment Chained to a Single Device

For months I've been working with **TazPod** — a local Docker container on my laptop containing my entire development environment: encrypted vault, Go CLI for secrets management, complete toolchain (kubectl, helm, terraform, flux, talosctl), and AI tools (oh-my-pi, pi-coding-agent, gemini-cli, opencode). It works. But it has a structural limitation: it's tied to the laptop.

What if I want to work from my tablet? I'd need to set everything up from scratch. From my phone via Termux? Same story. Worse: if the laptop battery dies or the device breaks, I lose the session and the entire environment.

The solution I was looking for: a TazPod instance that's always on, reachable from any device, with the exact same toolchain, the same secrets, the same configuration. A nomadic workspace that outlives any single device.

## The Alternatives: Three Paths to a Container on Proxmox

I already have a **Proxmox VE 9** node on a mini PC (32 GB RAM, LVM-thin storage) hosting a Kubernetes cluster (Talos, two VMs) and an LXC with Hermes Agent. Adding an LXC for TazPod was the natural next step.

I evaluated three approaches:

### Option A: Docker-in-LXC

The most obvious: install Docker inside an unprivileged LXC and run `tazpod up` exactly like on the laptop.

**Pro**: Zero changes to TazPod. `tazpod up` creates the Docker container as always.

**Con**: Docker-in-LXC on unprivileged containers is fragile. The overlay2 driver on LVM-thin falls back to `vfs` with poor IOPS. The triple networking layer (LXC → Docker bridge → Tailscale) introduces MTU issues (already known as TD-018 on the laptop). Docker daemon RAM overhead (~300 MB) adds to the LXC's.

### Option C: Rootless Podman on the Hetzner VM

Co-locate TazPod on the Hetzner CX23 VM (4 GB RAM) where Vault already runs, using rootless Podman with a dedicated user.

**Pro**: No LXC complexity. The VM is already on the tailnet. Low-latency S3 access (same AWS region).

**Con**: The CX23 has only 4 GB total RAM — Vault (~400 MB) + OS + Tailscale + TazPod left little headroom for interactive tools. Rootless Podman doesn't support `--network host` and `CAP_SYS_ADMIN`, which are essential for the vault tmpfs and Tailscale TUN.

### Option B: Bare-Metal LXC (Final Choice)

Install TazPod directly in an LXC, without Docker. The LXC *is* the container — no Docker layer in between.

**Pro**: Zero Docker overhead. Clean networking (LXC → Tailscale direct). Pattern already validated by Hermes (Pet vs Cattle for persistence). The toolchain is installed via Ansible, identical to the Docker layers.

**Con**: TazPod was born as a Docker orchestrator. The lifecycle (`up/down/enter`) makes no sense in an LXC — you enter via SSH.

The choice fell on Option B not only for the technical advantages, but also because it let me redefine TazPod's role: no longer a Docker container manager, but a **CLI for vault management + sync daemon** that works identically in Docker and LXC, simply by reading `mode: lxc` in the config.

> **LXC (Linux Containers)**: An operating-system-level virtualization method that shares the host kernel but isolates processes in separate namespaces. Unlike Docker containers, an LXC doesn't require a central daemon and has native networking on the host bridge interface. It's Proxmox's standard choice for lightweight containers.

## Architecture: Pet vs Cattle for Persistence

The main challenge with LXC containers on Proxmox is data persistence. When you destroy a CT with `terraform destroy`, Proxmox deletes ALL volumes associated with that VMID — including those you might have thought were "external". The Proxmox API has no `destroy-unreferenced-disks=0` flag for LXCs (it only exists for QEMU VMs).

The solution is the **Pet vs Cattle** pattern, already validated for Hermes:

```
CT 999 — the "pet" (protection=1)
  └── Owns the persistent volumes: vm-999-disk-1, vm-999-disk-2
      Never destroyed by Terraform.

CT 106 — the "cattle" (protection=0)
  └── Mounts vm-999-disk-2 via mp0
      Normally destroyed and recreated.
      The volume SURVIVES because it's owned by CT 999.
```

> **LVM-thin ownership**: On Proxmox, each LVM-thin volume is tied to the VMID of the container that created it. If you destroy the CT, Proxmox looks for all volumes with the `vm-<VMID>-` prefix and deletes them. A volume created by CT 999 (`vm-999-disk-2`) survives even if CT 106, which mounts it, gets destroyed.

The pet volume is mounted on `/workspace` — which becomes the persistent working directory. Inside, a structure identical to the Docker TazPod:

```
/workspace/
├── .tazpod/           ← vault + tool configs (survives)
├── ephemeral-castle/  ← projects (survive)
├── tazpod/
├── AGENTS.ctx/
└── other repos…
```

## The Turning Point: Dual-Mode in Go Code

The most significant modification to TazPod was introducing **dual-mode**. A single binary, compiled once, that behaves differently based on the `mode` field in `.tazpod/config.yaml`:

```yaml
mode: lxc        # "docker" (default) or "lxc"
```

In `lxc` mode, six lifecycle functions become no-ops with a clear message:

```go
func up() {
    if cfg.Mode == "lxc" {
        fmt.Println("⚠️  'up' is not available in LXC mode — the container is always running.")
        fmt.Println("   SSH into it directly: ssh tazpod@<IP>")
        return
    }
    // ... existing Docker code, unchanged
}
```

The functions that matter — `unlock`, `lock`, `save`, `push`, `pull` — don't check `mode` at all. The vault (`vault.go`), cryptography (`crypto.go`), and S3 sync (`s3.go`) are pure Go processes, with no Docker dependencies. They work identically in both environments.

The local TazPod on the laptop continues to work exactly as before — `mode` is empty (defaulting to `"docker"`), no guards activate. The new LXC uses `mode: lxc`. Same binary, same CI, no build tags.

## Problems Encountered

### 1. Glibc: The tree-sitter Drama

The first CT 106 was born on **Debian 12** (glibc 2.36). Everything worked except tree-sitter parsing in Neovim/LazyVim: `tree-sitter-cli` requires glibc 2.39+.

The diagnosis was straightforward: `ldd --version | head -1` showed glibc 2.36, and `tree-sitter --version` failed with `GLIBC_2.39 not found`. The solution could have been installing an older tree-sitter version (which still required recent glibc), building from source (requires Rust, which wasn't available), or changing the container's base distribution.

I chose the cleanest solution: destroy CT 106 and recreate it with **Ubuntu 24.04** (glibc 2.39). The rootfs went from 10 GB to 20 GB (the Debian 12 disk was at 100%). The idempotent Ansible reinstalled everything in 7 minutes.

```
Before: Debian 12 — glibc 2.36 — 10 GB (100% full)
After:  Ubuntu 24.04 — glibc 2.39 — 20 GB (42% used)
```

### 2. TUN Device in Unprivileged LXC

Tailscale requires `/dev/net/tun`. In an unprivileged LXC, the TUN device isn't available by default. The configuration must be added manually in `/etc/pve/lxc/106.conf`:

```ini
features: nesting=1,keyctl=1

lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file

lxc.cap.drop: sys_rawio
lxc.cap.drop: sys_module
```

Without `nesting=1` and the TUN device, Tailscale can only run in `--tun=userspace-nic` mode (userspace mode), which has inferior performance. With the mount entry and cgroup, the TUN device is passed from the host kernel to the container transparently.

### 3. GRO/GSO Bug and DNS

A problem that only appears in LXC is the **GRO/GSO bug**: veth virtual drivers falsely advertise full GSO support. Tailscale sends 64 KB UDP packets that the real bridge can't fragment, causing a black hole. The solution is a systemd oneshot:

```bash
/sbin/ethtool -K eth0 rx-gro-list off rx-udp-gro-forwarding on
```

DNS is another tricky topic. Proxmox overwrites `/etc/resolv.conf` on every reboot, wiping Tailscale's MagicDNS nameserver (100.100.100.100). The solution: `touch /etc/.pve-ignore.resolv.conf` and fixed nameservers via `resolvectl dns eth0 1.1.1.1 8.8.8.8`.

## The Toolchain: 65 Ansible Tasks to Replicate Four Docker Layers

The most labor-intensive part was replicating the **four TazPod Docker layers** (base, aws, k8s, ai) as an idempotent Ansible playbook. Each task has a `creates:` check that prevents re-installation:

```yaml
- name: Helm
  shell: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  args: { creates: /usr/local/bin/helm }
```

The result: 65 tasks, 6 files organized by layer, **zero errors** on completion. Every tool — from Go 1.25 to Node 24/NVM, from kubectl to talosctl, from oh-my-pi to opencode — is aligned with the Docker TazPod version.

## The Nomadic Workflow

The final setup gives me a workflow I didn't have before:

1. **From the laptop**: SSH to `tazpod@192.168.1.206`, `tmux`, and the entire environment is there
2. **From the tablet (Termux)**: same command, same session (thanks to tmux)
3. **From Termux on the phone**: `ssh tazpod@tazpod-proxmox`, attach to the running tmux session
4. **If the mini PC is down**: `tazpod up` on the laptop, the local Docker instance starts as a fallback

The secrets vault is the same for both instances: encrypted with AES-256-GCM, synchronized to S3, mounted in tmpfs with `tazpod unlock` from any device.

> **tmux**: A terminal multiplexer that provides persistent sessions. You can detach from a session (Ctrl+B d), close the terminal, reconnect from another device, and reattach to the same session. It's the heart of the nomadic workflow.

## Conclusions

The most important lesson from this project is that **operational nomadism doesn't require new tools** — it requires rethinking the point of entry. I didn't create a new platform. I took an environment that was tied to a local Docker container and made it accessible from any network interface, using existing tools: SSH, tmux, Tailscale, an LXC on Proxmox.

The **Pet vs Cattle** pattern for Proxmox persistence has proven universal: after Hermes, TazPod now follows it. The next time I need a persistent LXC service, I already know how to structure it.

The dual-mode Go code (`mode: lxc`) made it possible to maintain a single binary for two very different environments. This pattern is extensible: in the future, a TazPod on a cloud VM could use `mode: cloud` or `mode: podman`.
