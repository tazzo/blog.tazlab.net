+++
title = "LushyCorp Vault on Hetzner: security-driven architectural choices"
date = 2026-04-04T14:00:00+00:00
draft = false
description = "The design of the LushyCorp Vault project on Hetzner: security model, complete end-to-end flow, and architectural rationale before the implementation phase."
tags = ["hetzner", "vault", "ansible", "tailscale", "security", "architecture", "devops", "s3"]
categories = ["Infrastructure", "Security", "DevOps"]
author = "Taz"
+++

# LushyCorp Vault on Hetzner: security-driven architectural choices

This article is not about implementation. It is about **design**: how I defined the core of the LushyCorp Vault project on Hetzner before splitting it into execution subprojects.

The goal was only one: build a Vault runtime that could be born, die, and be reborn without losing security, without depending on fragile manual steps, and without introducing “convenience” secrets in the wrong places.

---

## 1) The Current State: the real problem to solve

The starting point was not “I need a VM with Vault.” That is simple. The real problem was this:

- how to boot a new machine in the cloud,
- how to configure it without passwords,
- how to inject private-network prerequisites,
- how to initialize Vault the first time,
- how to reopen it deterministically on subsequent runs,
- and how to do all of this without leaving secrets in image, user-data, or repositories.

In other words: I was not designing a server, I was designing a **secure lifecycle**.

If this part is designed poorly, everything else (rotation, governance, private connectivity with the cluster, etc.) is built on weak foundations from day one.

---

## 2) The “Why”: why these choices (and not others)

### No secrets in the image

The base image had to contain only software and neutral configuration. No token, no bootstrap key, no cloud credential.

Reason: an image is meant to be cloned. If you place a secret in it, that secret automatically becomes replicable and hard to revoke in an orderly way.

### No `cloud-init`/`user-data` to pass keys

I rejected the “pass everything through user-data” pattern because it is not consistent with the security model I wanted. Cloud metadata is not where I want sensitive credentials to transit.

If tomorrow I need to run an audit or incident response, I must be able to state with certainty: **secrets never passed through provider metadata**.

### Initial access only via key-based SSH, never password

The VM is born with one open port only, SSH, and only with key-based authentication already registered on Hetzner. No password access, no fragile interactive bootstrap.

This reduces two surfaces at the same time:

1. opportunistic password attacks,
2. dependence on non-repeatable manual steps.

### The turning point: from a massive SH script to Ansible (the real clarity moment)

A fundamental part of the design was exactly this: at first I was designing everything with a single, very complex SH script. The idea was to make the script do every step: SSH in, check states, apply configuration, inject keys, manage first-run/re-run branches, validate outputs, and perform cleanup.

On paper it looked feasible. In practice I was hand-building an idempotent orchestrator with conditional logic, retries, error handling, dependency ordering, and action traceability. At some point the question became inevitable: **"isn’t this exactly the ideal case for Ansible?"**

The answer was yes, with no ambiguity: we were effectively writing a **mini-Ansible in Bash**. That was the moment I truly understood what Ansible is for in the real world: not to "run remote commands," but to provide a declarative, repeatable, and verifiable shape to machine convergence.

For me this was also an important professional step: I had known Ansible in theory for a long time, but I had never had a case where it was this clearly the right tool. In this project its value was obvious because:

- the flow requires **idempotency** (first-run and re-run must converge, not diverge),
- security requires a **deterministic** configuration (no opaque manual steps),
- I needed to track "what is applied, when, and in which order."

In addition, Ansible’s declarative model is consistent with the rest of my stack: same Kubernetes mindset and same traceability discipline typical of GitOps flows. It is not Kubernetes, but it speaks the same operational language: desired state, convergence, verifiability.

Ansible’s role in the project is therefore precise:

- configure the host environment consistently,
- inject required materials (e.g., Tailscale keys/config) at the correct point in the cycle,
- keep initial bootstrap separate from subsequent convergence,
- drastically reduce drift risk caused by SH scripts that grew beyond threshold.

Without this declarative convergence, security would remain tied to memory from the previous session. With Ansible, instead, it becomes part of the system.

### Why not rely on an external Key Manager (e.g., AWS KMS) at this stage

The most important discussion was this: “let’s use an external key manager and solve it.”

On paper it is elegant. In practice, in my scenario, to authenticate a machine outside their perimeter I would still need local authentication material (secrets/credentials) stored on the machine itself.

So the risk point does not disappear: it moves.

- Storing local credentials to authenticate to KMS,
- or storing local material needed for bootstrap in an encrypted container,

in this context, they have a very similar risk profile, unless you run the first option with a full enterprise ecosystem that is not available here.

Hence the pragmatic and controllable choice: no forced dependency on an external key manager at this stage, but a deterministic cycle with encrypted artifacts and an explicit recovery path.

---

## 3) The Target Architecture: the complete project, before the execution split

Before splitting it into multiple subprojects, the project was conceived as one end-to-end logical pipeline.

### Step A — Golden image runtime (technical base only)

1. I create a base image with required software preinstalled.
2. The image is tested.
3. No secrets inside the image.

This is the trust base: a machine born ready to converge, but still “neutral” from a secrets perspective.

### Step B — Instance with only SSH port open

1. I instantiate the VM from the golden image.
2. Open port: only 22.
3. Access: only SSH key registered on Hetzner.

No password, no shell bootstrap via cloud metadata.

### Step C — Convergence via Ansible, controlled injection

Once inside via SSH, Ansible prepares the runtime:

- configures system and environment,
- injects required materials for Tailscale,
- prepares the transition to the private channel.

### Step D — Switch management plane to Tailscale

After initial convergence:

1. the VM joins the Tailscale network,
2. management moves to the private channel,
3. in perspective, public SSH is closed (both internet-side and cloud firewall),
4. from that point, operations are private.

This is the key transition: public SSH is only an initial bridge, not a permanent channel.

### Step E — Vault phase: first boot vs reboot

Here the design is explicitly split.

#### First boot (bootstrap)

- Vault is initialized,
- required keys are generated (unseal/root metadata),
- artifacts are saved in the encrypted secrets path on S3.

#### Subsequent boots (re-instantiation)

- artifacts already exist,
- Vault is not re-initialized,
- state is recovered and runtime is reopened deterministically.

This prevents the most dangerous risk: accidental “re-init” with loss of operational continuity.

### Step F — Private integration with the cluster

Once the runtime is stabilized on a private network, the cluster also joins the same private communication domain.

This is where the project delivers its final value:

- secrets management,
- synchronization,
- rotation,

happen on a private network, not over public exposure.

---

## 4) Operational blueprint (scripts defined by the design)

This is the final blueprint. The first idea was a monolithic SH script; after the Ansible turning point, the project was redesigned into a pipeline where scripts orchestrate phases and Ansible handles configuration convergence.

```bash
# 1) build secure base image (no secrets)
create-runtime-golden-image.sh

# 2) instantiate from golden image with initial SSH
create-runtime-instance.sh

# 3) host convergence + private-network material injection
converge-runtime-with-ansible.sh

# 4) switch management to Tailscale and progressively close public SSH
switch-to-tailscale-management.sh

# 5) Vault first-run bootstrap (init + encrypted artifact save)
vault-first-init.sh

# 6) re-instantiation reopen path (no re-init)
vault-recover-from-secrets.sh

# 7) controlled runtime resource cleanup
destroy-runtime.sh
```

The critical distinction is not script names, but responsibility boundaries. Each script must do one critical thing, with clear logs and verifiable outputs.

---

## 5) Why this comes before implementation into subprojects

Only after defining this complete flow did I choose to split implementation into separate phases. The split was not created to “complicate governance”; it was created to keep the security design intact during execution.

So the point is not the number of subprojects. The point is that, at its core, the project remains this:

- clean image base,
- controlled bootstrap,
- declarative convergence via Ansible,
- transition to private management via Tailscale,
- deterministic Vault first-run/re-run lifecycle,
- no secrets in the wrong places.

---

## Future Outlook: what this architecture actually unlocks

When this design is respected, I gain three strategic properties:

1. **Operational repeatability**
   - I can recreate runtime without reinventing the procedure.

2. **Structural risk reduction**
   - secrets do not transit through improper channels,
   - public exposure is not the permanent operating mode.

3. **Vault lifecycle continuity**
   - first boot and subsequent reopens are distinct and controlled paths.

This is the truly important part of the project: not “standing up Vault,” but building a system that remains secure even when rebuilt from zero.
