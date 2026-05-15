+++
title = "Pet vs Cattle on Proxmox LXC: How to Get PVC-like Persistence with Only an API Token"
date = 2026-05-15T14:00:00+02:00
draft = false
tags = ["Proxmox", "LXC", "Terraform", "Ansible", "Hermes", "LVM-thin", "Storage", "Persistence"]
description = "Deploying Hermes Agent on Proxmox LXC. From the bare-metal vs Docker decision, to the 403 bind-mount error, to the Pet vs Cattle solution for LVM-thin data persistence."
author = "Tazzo"
+++

## The Problem: Persistent Data on Ephemeral Containers

Deploying an AI Agent (Hermes Agent) on a Proxmox LXC container seemed straightforward: install the software, configure the services, make it work. The real problem emerged later, when I had to face the question: what happens to the data when the container is destroyed and recreated?

In Kubernetes, this question has a standard answer: PersistentVolumeClaims (PVC) separate the data lifecycle from the pod lifecycle. Proxmox LXC has no direct equivalent. Or rather, it has several approaches, each with specific limitations I discovered through trial and error.

This article covers the journey from the initial architectural choices to a working persistence solution, passing through three dedicated research sessions and just as many discarded attempts.

## The Container: Bare-metal, Not Docker

The first architectural decision was how to install Hermes inside the LXC. There were three alternatives.

**Docker-in-LXC** was the most obvious path, but it had a hidden problem: in unprivileged LXC containers with ZFS storage, Docker's overlay2 driver degrades to vfs, a driver without copy-on-write support and drastically lower IOPS. The workaround (an Ext4 volume on a zvol) added complexity without real benefit in this context.

**Rootless Docker** had a more structural limitation: `network_mode: host` in rootless Docker does not expose the container's real network — it exposes a network isolated by RootlessKit. Hermes' gateway and dashboard, which communicate over localhost, would end up in separate network namespaces — an inherently unstable configuration.

The final choice was **direct bare-metal installation**: running Hermes' `install.sh` directly inside the LXC, without Docker. Terminal sandboxing is handled by the container's own hardening: cap drop, active AppArmor, read-only mounts for `/proc` and `/sys`, and a non-root `hermes` user (UID 10000, no sudo).

```
features {
    nesting = true
}
```

The only extra feature is `nesting`, required by Hermes' internal subprocess management.

## The First Roadblock: install.sh and SSH Keepalive

The Ansible playbook that installs Hermes runs `install.sh` with `--skip-setup`. The problem is that `install.sh` is slow: it installs Python 3.11 via uv (~80MB), Node.js 22 (~30MB), hundreds of Python dependencies with `uv sync --extra all`, and the npm dependencies for the Web UI. The total time is **5-10 minutes**.

Ansible executes commands over SSH, and SSH does not have keepalive enabled by default. After 2-3 minutes of silent output during `uv sync`, the connection drops. Ansible waits indefinitely without reporting the error — it just shows "TASK [agent : Execute Hermes install.sh]" without ever completing.

I diagnosed the problem by checking the SSH daemon logs on the container: the connection was being closed due to inactivity timeout. The fix was adding keepalive to the Ansible configuration:

```ini
[ssh_connection]
ssh_args = -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ConnectTimeout=10
```

With this fix, the SSH connection stays alive and `install.sh` completes in roughly 159 seconds. I also pre-installed the Playwright dependencies (25+ packages) in Ansible's baseline playbook, to prevent `apt-get` subprocesses from hanging in non-interactive mode.

## The Second Roadblock: Bind-mount and the 403 Wall

Once Hermes was installed and running (gateway and dashboard on `192.168.1.205:9119`), I tackled data persistence. The standard pattern in the rest of the TazLab ecosystem is a bind-mount: a host directory mounted into the container. The Terraform configuration was:

```hcl
mount_point {
  volume = "/mnt/hermes_data"
  path   = "/home/hermes"
  backup = true
}
```

Proxmox returned **HTTP 403 Forbidden**. Investigation revealed that bind-mounts via the API are only allowed for users authenticated with a password (`root@pam`), not for API tokens. This is a deliberate security restriction, but it blocks IaC automation.

I then adopted a **managed volume** on `local-lvm` through the `bpg/proxmox` Terraform provider:

```hcl
mount_point {
  volume = "local-lvm"
  size   = "10G"
  path   = "/home/hermes"
  backup = true
}
```

This works — the volume is created and mounted correctly. But there is a catch: LVM-thin volumes are tied to the container lifecycle. When the container is destroyed by `terraform destroy`, the volume is destroyed with it.

## Three Research Sessions for a Seemingly Simple Problem

I conducted three research sessions to find a way to preserve the volume beyond the container lifecycle. Here is what I found.

### First Research: The API Syntax

The API call to detach a volume works: `PUT /config -d "delete=mp0"`. But reattaching it to an existing container is trickier. The "duplicate key in comma-separated list property: volume" error I was getting was due to a formatting issue: I was including `size=10G` together with a reference to an existing volume, creating an internal conflict in the Proxmox parser.

The correct syntax to mount an existing volume is:

```bash
curl -sk -X PUT "https://proxmox:8006/api2/json/nodes/tazlab/lxc/105/config" \
  --data-urlencode "mp0=local-lvm:vm-105-disk-1,mp=/home/hermes"
```

No `size`, no `backup`. When referencing an existing volume, these parameters are optional and, if present, cause conflicts.

### Second Research: LVM-thin Ownership

The fundamental problem is that Proxmox 9.1, during container destruction, **always scans the storage** for volumes named `vm-<vmid>-disk-*`, regardless of whether they are still mounted or not. Even after detaching the volume with `delete=mp0`, the `DELETE /nodes/{node}/lxc/{vmid}` call still removes it.

The `destroy-unreferenced-disks=0` parameter is not honored for LXC containers in Proxmox 9.1 (it only works for QEMU VMs). The `bpg/proxmox` Terraform provider v0.106 does not expose this flag for the LXC resource.

### Third Research: Why Every Path Led to a Dead End

- **Bind-mount via API**: blocked (403 for tokens, only root@pam)
- **`protection=1`**: blocks the container delete, but also prevents selective compute removal
- **Volume rename via API**: there is no `lvrename` endpoint exposed through REST
- **ZFS**: not available on this host (single 476G SSD, fully allocated to LVM)
- **Volume reassignment (`move_volume`)**: endpoint unstable for in-place rename on the same storage

The conclusion from all three research sessions was: **with only an API token, an LVM-thin volume cannot survive its container's destruction**. The nominal ownership (the name `vm-105-disk-1`) ties it inextricably to container 105.

## The Solution: Pet vs Cattle

The only viable path was to change the volume's ownership. If the volume is named `vm-105-disk-1`, Proxmox destroys it with CT 105. If it is named `vm-999-disk-1`, it survives because it belongs to a different container.

I created a **placeholder container** (CT 999, named "pet-storage") with `protection=1`, which will never be destroyed. This container owns a 10GB volume (`local-lvm:vm-999-disk-1`). The Hermes container (CT 105, the "cattle") mounts this volume as if it were an external filesystem.

The pet's Terraform configuration is minimal:

```hcl
resource "proxmox_virtual_environment_container" "pet_storage" {
  vm_id      = 999
  protection = true
  # 1 core, 256MB RAM, 2G rootfs — enough to exist
  ...
  mount_point {
    volume = "local-lvm"
    size   = "10G"
    path   = "/mnt/hermes-volume"
    backup = true
  }
}
```

The Hermes container (CT 105) is created by Terraform **without** a mount_point. The volume is attached via API in a separate phase, after creation:

```bash
# Stop the container
curl -X POST "https://proxmox:8006/api2/json/nodes/tazlab/lxc/105/status/stop"

# Attach the pet's volume
curl -X PUT "https://proxmox:8006/api2/json/nodes/tazlab/lxc/105/config" \
  --data-urlencode "mp0=local-lvm:vm-999-disk-1,mp=/home/hermes"

# Restart the container
curl -X POST "https://proxmox:8006/api2/json/nodes/tazlab/lxc/105/status/start"
```

On destruction, the volume is detached first, then the container is destroyed:

```bash
curl -X PUT "https://proxmox:8006/api2/json/nodes/tazlab/lxc/105/config" -d "delete=mp0"
terraform destroy
```

The `vm-999-disk-1` volume survives every cycle because Proxmox scans for `vm-105-disk-*` volumes during destruction — and finds nothing.

## The Full Cycle in 137 Seconds

With the Pet vs Cattle pattern, the destroy/create cycle is faster than backup/restore because Hermes is already installed on the persistent volume (no full reinstall). The timings:

```
PHASE                             DURATION
──────────────────────────────────────────
0. Pet Volume Ensure                   2s
1. Terraform Create                   11s
2. Wait SSH                           15s
3. Attach Volume                       8s
4. Ansible Baseline                   56s
5. Ansible Agent (idempotent)         30s
6. Ansible Configure                   6s
7. Ansible Verify                      9s
──────────────────────────────────────────
TOTAL                                137s  (2 min 17s)
```

## Lessons Learned

1. **The Proxmox API has strict limits on mount points.** Bind-mounts require root@pam, LVM-thin volumes are tied to the VMID, and there is no way to preserve them with a simple flag. I wasted time looking for a non-existent parameter, when the real solution was an architectural change.

2. **LVM naming is the key to persistence.** On LVM-thin, volume ownership is determined by the name (`vm-<vmid>-disk-*`). Understanding this mechanism led me to the Pet vs Cattle solution, which is essentially a nominal ownership reassignment.

3. **Three research sessions were needed to rule out every alternative.** Bind-mounts, `destroy-unreferenced-disks`, `protection`, ZFS, rename API: each had a reason not to work in my setup (API token only, LVM-thin, single disk). Knowing what does NOT work was as important as finding the solution.

4. **The Pet vs Cattle pattern is reusable.** A single pet (CT 999) can own N volumes, each mountable on different cattle containers. To extend persistence to other services, simply add a mount_point to the pet and attach it via API to the corresponding cattle container.

The source code and full documentation are available at `github.com/tazzo/ephemeral-castle`, in the `hermes/` directory. The three research sessions are documented in `AGENTS.ctx/crisp-build/assets/`.
