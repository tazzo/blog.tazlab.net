+++
title = "TazPod Gopass Migration: Decommissioning the RAM Vault for Zero-Privilege Security"
date = 2026-07-16T18:00:00+02:00
draft = false
description = "A deep architectural evolution in TazPod: how decommissioning the encrypted RAM vault and AWS SSO/S3 dependencies in favor of gopass and GPG simplified code, reduced Docker container privileges to zero, and introduced a partitioned security model tailored for AI agents."
tags = ["TazPod", "Gopass", "GPG", "Security", "Docker", "DevOps", "TazLab"]
categories = ["Software-IT", "Infrastructure"]
author = "Taz"
+++

## The Secret Challenge in the Nomadic Workspace

Managing secrets in a nomadic, ephemeral, and reproducible development environment like **TazPod** has always been an exercise in balancing usability and security. TazPod was born to provide a preconfigured Docker container with all the necessary tools (CLIs, SDKs, AI extensions, customized shell) that can be launched instantly on any Linux host or Proxmox LXC container, ensuring the exact same experience everywhere.

However, a complete toolchain needs access to API keys, cloud tokens, database credentials, and cryptographic keys. In early versions of TazPod, we solved this with an ad hoc engineering solution called **RAM Vault**: an AES-encrypted archive stored in an S3 bucket, decrypted at startup into a host-side RAM-backed filesystem and mounted inside the container.

While this architecture worked for months, it presented two major limitations: massive operational complexity (laden with fragile hacks and exit traps) and a blast radius that was too wide in an era where AI agents operate directly within our workspaces.

This post explains why and how we decommissioned the RAM Vault, migrating the entire TazLab toward a partitioned and standardized secrets management system based on **gopass** and **GPG**, reducing container privileges to zero and radically limiting the blast radius in case of compromise.

---

## The Previous Architecture and Its Complicating Factors (TazPod v2)

To understand the value of the change, it is helpful to analyze how secrets management worked until yesterday. The old RAM Vault architecture relied on a three-stage workflow:

1. **Authentication via AWS SSO & S3**: The operator initiated login to obtain temporary credentials and download the encrypted `vault.tar.aes` archive.
2. **Decryption on tmpfs**: The Go CLI invoked `sudo` commands on the host to create a **tmpfs** filesystem mounted at `/home/tazpod/secrets` and decrypted the archive there, which was then bind-mounted into the container.
3. **Sync Daemon**: A background service synchronized local changes of the archive by encrypting and uploading them back to S3.

> [!NOTE]
> **Tmpfs** is a Linux filesystem that stores files directly in the volatile memory (RAM) of the system. Since it does not write to the hard drive or solid-state drive (SSD), data vanishes completely as soon as the filesystem is unmounted or the server is powered down, preventing accidental persistence of secrets at rest.
>
> **Bind-mount** is a mechanism that maps an existing directory in the host's file tree inside the namespace of a container, allowing host and container to share files in real time with native performance.

This approach introduced severe complications in managing the Docker environment:
* **Elevated Host Privileges**: Because mounting tmpfs required `mount` and `umount` privileges, the TazPod CLI had to be executed with `sudo` on the host. Furthermore, the Docker container had to be started with the `--cap-add SYS_ADMIN` capability to properly handle mount propagation, weakening container isolation from the host.
* **Exit-Trap Hacks**: To prevent secrets from remaining mounted in plain text in RAM on the host after the user exited, we had to implement a complex trap system in `.bashrc` inside the container. This script kept track of the active shell count and, when the last shell instance closed, sent a signal to the host to unmount the tmpfs. If the container was terminated abruptly, secrets could remain exposed in plain text on the host's filesystem.
* **Concurrent Synchronization**: The S3 sync daemon introduced race conditions when multiple shells modified secrets at the same time, risking the overwrite of important credentials.

---

## The Security Concern: AI Agents and Blast Radius

The most critical limit, however, was not operational, but related to **security**.

In the RAM Vault model, unlocking was an \"all-or-nothing\" operation. Once the archive was decrypted under `/home/tazpod/secrets`, all TazLab secrets were exposed in plain text: development API keys, production database passwords, cloud credentials, and even the offline private key of the Root CA for our PKI infrastructure.

With the integration of autonomous AI agents operating within our development environment to write and execute code, this model became untenable. If an AI agent, performing research or testing activities, were compromised or fell victim to a prompt injection attack from an untrusted external source, it would gain immediate and indiscriminate access to the entire secret vault of the TazLab.

It was essential to find a way to **partition secrets** based on their criticality level, reducing the blast radius to a limited subset and requiring explicit, controlled unlocks.

---

## The Choice of Linux Standards: GPG and Gopass

In searching for an alternative, the goal was to abandon custom code and align with standard Linux tools: **GPG (GNU Privacy Guard)** encryption and the standard Git-backed secrets management model of **pass** (the standard Linux password manager).

During the research phase, we evaluated using standard `pass`, but found significant risks regarding potential file corruption in automated and concurrent write scenarios. `pass` manages each secret as a single encrypted file inside a Git-tracked folder structure; in case of rapid parallel operations or script-automated commands, the repository synchronization could corrupt or generate conflicts that are difficult to resolve programmatically.

We therefore selected **gopass**, a modern rewrite of `pass` in Go. Gopass offers several key benefits:
1. **Robust Git transaction handling**: It handles commit and push automation natively and securely.
2. **Multiple stores (Mounts)**: It allows dividing secrets into independent sub-stores (e.g., a store for development, one for production, one for infrastructure keys).
3. **Standard GPG-based encryption**: Each secret is encrypted individually for one or more recipients identified by their public GPG keys.

Thanks to this flexibility, we implemented a partitioned security model:
* **Standard Secrets**: Encrypted with GPG keys whose agents keep the passphrase in cache for short durations.
* **Highly Critical Secrets (such as the Root CA)**: Encrypted with offline GPG keys or protected by dedicated passphrases, excluded from the daily mounted standard stores.

---

## The New Zero-Privilege Design

With the migration to gopass, the TazPod CLI has been completely rewritten in Go, eliminating all legacy code related to S3, AWS SSO, AES encryption, and host-side mount logic.

### 1. Eliminating Elevated Capabilities
Since it no longer mounts tmpfs filesystems on the host, TazPod no longer requires execution with `sudo`. Furthermore, when creating the Docker container, we removed the `--cap-add SYS_ADMIN` capability. The container now runs exclusively with `--cap-add NET_ADMIN` (needed only for the Tailscale virtual network interface), dramatically reducing container privileges on the host system.

### 2. The `tazpod gopass` Command
The store setup now happens entirely inside the container via the `tazpod gopass` command. This command:
1. Scans `.asc` files in the `/workspace/tazlab-secrets/gpg-keys/` directory and imports public and private GPG keys into the container's local keyring.
2. Configures gopass by setting the local store path.
3. Creates a symbolic link (*symlink*) at `~/.local/share/gopass/stores/root` pointing directly to the versioned `/workspace/tazlab-secrets` folder.

### 3. Secure Caching in RAM and TTY Alignment
Secrets are no longer decrypted into a fully exposed filesystem; instead, decryption is delegated to the `gpg-agent` on demand.
In the `.tazpod/Dockerfile.base` configuration, we set the agent caching parameters:

```dockerfile
RUN mkdir -p /home/tazpod/.gnupg && \
    echo "default-cache-ttl 3600" > /home/tazpod/.gnupg/gpg-agent.conf && \
    echo "max-cache-ttl 604800" >> /home/tazpod/.gnupg/gpg-agent.conf && \
    echo "trust-model always" > /home/tazpod/.gnupg/gpg.conf
```

> [!TIP]
> `default-cache-ttl 3600` keeps the GPG passphrase cached in the agent's RAM for 1 hour, resetting the timer on every secret read operation. `max-cache-ttl 604800` (7 days) enforces an absolute expiration limit, after which re-entering the passphrase is required.

To prevent the password entry interface (*pinentry*) from hanging when running parallel shells or multiple TMUX panes inside the container, we added the TTY alignment sequence to `.bashrc` at startup:

```bash
if [ -t 0 ]; then export GPG_TTY=$(tty); fi
gpgconf --launch gpg-agent >/dev/null 2>&1
gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1
```

The `updatestartuptty` command dynamically notifies the background `gpg-agent` daemon of the currently active shell TTY, ensuring that the interactive pinentry screen for the passphrase appears on the terminal where the user is actually typing.

To lock the store instantly and wipe decrypted keys from RAM, the operator can run `tazpod lock`, which executes:

```go
gpgconf --kill gpg-agent
```

---

## LXC and Hetzner Vault: Provisioning Simplification

The benefits of the migration propagated immediately to the Ansible-managed provisioning infrastructure.

Previously, Proxmox LXC storage node creation and Hetzner Vault runtime convergence depended on decrypted credential files residing locally on the operator's filesystem (under `~/secrets/`). This created drift if the operator forgot to unlock the vault or if files were deleted.

We refactored the Ansible playbooks and orchestration scripts (`create.sh` and `stage-prelude.yml`) to interact directly with gopass:
* **Zero Files on Disk**: SSH keys, API tokens, and initialization credentials are read from gopass in memory and passed directly via SSH streams or environment variables.
* **Clean Bootstrapping**: In `stage-converge.yml` for Hetzner Vault, Vault initialization (unseal keys and root token) is generated in memory on the server and inserted directly into gopass via `gopass insert -f`, ensuring that no plaintext credentials ever touch the operator's local disk.

---

## Conclusions: Lessons in Architectural Simplicity

The migration from a custom RAM Vault architecture to a gopass and GPG-based system demonstrated three core principles:

1. **Don't reinvent the wheel**: Standard Linux cryptographic systems (`gpg`, `gpg-agent`, `pass`) solved caching and TTY management issues decades ago. Utilizing these tools drastically reduces the lines of custom code to maintain in the CLI.
2. **Zero-Privilege Security**: Removing `SYS_ADMIN` and `sudo` requirements within our workspaces isolates the development container further from the host, reducing the impact of potential container vulnerabilities.
3. **Prepare for AI Agents**: Configuring systems under the assumption that the terminal user might be an AI agent (and thus limiting the blast radius through partitioned secrets and targeted unlocks) not only protects against future attacks but also enforces a clean, elegant design that benefits human operators as well.
