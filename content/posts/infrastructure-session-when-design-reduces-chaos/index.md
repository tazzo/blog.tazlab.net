+++
title = "A quieter infrastructure session than usual: when design reduces chaos"
date = 2026-04-08T06:00:00+00:00
draft = false
description = "The technical diary of the Hetzner foundation step with Tailscale: a build that went fairly smoothly not by chance, but thanks to hours of design work, problem decomposition, and guided use of LLMs."
tags = ["hetzner", "tailscale", "ansible", "terraform", "devops", "llm", "automation", "infrastructure", "architecture"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# A quieter infrastructure session than usual: when design reduces chaos

## Objective of the session

This stage of the project had a very precise goal: to close the **foundation** step of the Hetzner pipeline, meaning to arrive at a runtime machine capable of being born from a golden image, being bootstrapped over public SSH, joining Tailscale correctly, moving the operational plane onto the private channel, and proving that it can converge repeatably even on the second run.

Put more concretely, the target was the `hetzner-tailscale-foundation` project: not Vault yet, not the full lifecycle of the application service yet, but the first real operational layer on which everything else can rest. If this base is not clean, every subsequent phase becomes noisy: when something breaks, I can no longer tell whether the problem is in provisioning, networking, secrets, the runtime, or the final service. Closing the foundation properly means removing ambiguity from the rest of the journey.

What is interesting is that this session was relatively calm. Not perfect, but orderly. There were a couple of real issues, also instructive ones, but it was not a marathon of chaos. And this is exactly the point I want to fix in place: it did not go well because the problem was trivial. It went well because the hardest work had already been done before implementation.

## The invisible part that made the smoothness visible

If I looked only at the final execution, I could describe it like this: I launched the build, corrected a few real integration details, validated the transition onto Tailscale, verified idempotent rerun behavior, and closed with `destroy.sh`. That would be a correct account, but an incomplete one. The decisive point is that this build did not come from a “build me this infrastructure” prompt thrown at an LLM in the hope that everything would assemble itself elegantly.

Before getting here, there had already been hours of discussion, redefinition of the problem, clarification of constraints, review of TazPod’s real behavior, correction of wrong assumptions, and above all one fundamental choice: **splitting the project into smaller parts**. First the golden image, then the foundation, only after that the Vault convergence. This decomposition drastically reduced the number of active variables in each phase.

This is where the `CRISP` methodology and the following step into `crisp-build` had real value. Not so much as a methodological label, but as discipline. I used one context to design, discuss, correct the plan, and lock the contracts. Only after that did I open the implementation worksite. The practical benefit was enormous: when something did not match, the deviation was readable. I did not have to investigate one giant blob of provisioning+runtime+network+Vault all at once, but a single step of the system.

## Why splitting into subprojects really changes the outcome

This is probably the strongest lesson of the session. If I had tried to do golden image, foundation, Tailscale bootstrap, secrets, and the first Vault lifecycle all at the same time, I would have produced a classic domino effect. Every error would have dirtied all the higher layers, making troubleshooting ambiguous. A VM that did not respond could have meant a broken image, a wrong ACL, a non-idempotent playbook, a bad bootstrap token, an incoherent Tailscale policy, or simple local network instability.

By splitting the journey into multiple steps instead, I got the opposite effect. The golden image had already been closed and validated as an independent gate. That meant that during the foundation phase I could treat the base runtime as reliable, and focus only on provisioning, network bootstrap, and operational convergence. In engineering terms, this is a huge reduction in diagnostic surface. It is not just “project management”: it is a concrete reduction of technical entropy.

It is the difference between launching an operation with ten open hypotheses and launching one where seven hypotheses have already been closed beforehand. Then, when real problems appear, as they did here, their nature is much more readable. And that is exactly what happened.

## The actual implementation: building a clean and verifiable foundation

The implementation work was concentrated in the new workspace under `ephemeral-castle/runtimes/lushycorp-vault/hetzner/`. I built there all the pieces needed for the foundation:

- Terraform layer for the VM, bootstrap firewall, and local outputs,
- Ansible baseline for runtime verification,
- Ansible role for Tailscale bootstrap,
- `create.sh` and `destroy.sh` with separate logs per phase,
- helper scripts for inventory generation and tag validation,
- an explicit source of truth for the approved golden image.

This choice has a precise meaning: the project could not depend on implicit memory or on IDs remembered out loud. If the approved image is `lushycorp-vault-base-20260404-v4` with ID `373384231`, that information has to live in a file actually consumed by the scripts, not in a mental note or in a sentence lost inside a design document.

The core of the foundation provisioning was intentionally simple. Terraform creates a VM from the approved golden image, opens only the minimum required in the cloud firewall for phase A, and generates the public inventory used for the first bootstrap. Ansible enters over public SSH, verifies the user model, installs or checks the required components, and brings the node into Tailscale. At that point, the system must be able to move onto the private plane and continue operating there.

A very representative example of the Terraform layer is this one:

```hcl
resource "hcloud_server" "foundation" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.image_id
  location    = var.location
  ssh_keys    = [var.ssh_key_name]
  firewall_ids = [
    hcloud_firewall.foundation_bootstrap.id,
  ]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  labels = merge(local.foundation_labels, {
    image_name = var.image_name
    image_id   = var.image_id
  })
}
```

Here the meaning of the step is clear: no infrastructure fantasy, no opaque layers, just the minimum necessary to generate a machine that is coherent and traceable, with outputs useful to the following steps.

## The problems that emerged were “good” problems

The first interesting point is that the problems that emerged never put the overall architecture into question. That does not mean they were trivial. It means they were **real integration problems**, not signs of a wrong project.

The first serious error appeared at the moment of `tailscale up` on the runtime VM. The machine had been created correctly, initial access over SSH worked, the Tailscale daemon installed correctly, but the join failed with a very precise message: the requested tags were invalid or not permitted. This is exactly the kind of problem a live build is supposed to surface. The design correctly said that the node had to join with `tag:tazlab-vault` and `tag:vault-api`. The reality of the Tailscale control plane said instead that the bootstrap OAuth client still did not have the right ownership model to assign them.

This diagnosis was important because it showed the quality of the plan: I did not have to rethink the whole foundation, I had to correct a real contract between the bootstrap client and the tailnet policy. I updated the ACL source of truth and the OAuth client definition in `ephemeral-castle/tailscale/`, applying the fix directly to the real tailnet. It is an apparently small detail, but it says a lot: the project needed a control-plane alignment, not a pipeline rewrite.

## The second problem: the node was online, but SSH over Tailscale still failed

After correcting the tag problem, the runtime did in fact join Tailscale and showed the expected tags. It looked like everything was resolved. But the next step — Ansible over Tailscale — kept failing. This was the most instructive point of the entire session, because on paper the node was healthy:

- `tailscale ping` replied,
- the node appeared in the tailnet,
- the tags were correct,
- `sshd` was active,
- the `tailscale0` interface had its IP.

And yet SSH to the `100.x` address timed out.

Here the difference between chaos and readable investigation showed up again. The fact that the peer was alive while the application transport was not told me that I was not looking at a global Tailscale failure. There were two possibilities: an incomplete ACL on the control-plane side, or a peculiarity on the operator side. In reality, both were true.

On one side, port `22` was explicitly missing from the ACL path `tag:tazpod -> tag:tazlab-vault`. That was a real policy error and had to be fixed on the tailnet. On the other side, there was an even more interesting aspect: in my local operator environment Tailscale runs in **userspace-networking**, so `tailscale ping` can work perfectly even if the host system has no direct kernel routing toward `100.x` addresses.

This distinction is very important. A superficial use of the tools could easily have led to the wrong conclusion: “Tailscale is up, so SSH to the `100.x` address should work.” But no. In userspace mode the mesh is healthy, but the TCP path from the host system may still require an explicit bridge.

## The final correction was small, but highly instructive

The solution was not to force the local system to behave like a node with full kernel routing, but to adapt the transport switch to the real context. I therefore changed the Tailscale inventory generation so that it used `tailscale nc` as the SSH `ProxyCommand`. This way Ansible no longer depends on whether my local host can directly reach the `100.x` address at the traditional network stack level: it uses the userspace channel provided by the local Tailscale daemon.

It is a small fix, but from a design point of view it is excellent, because it makes the system more robust with respect to the real operator environment. I am not writing a foundation that works only in the ideal lab; I am closing a foundation that works in the concrete context in which I am using it today.

The key part of the generated inventory became this:

```ini
[foundation_tailscale]
foundation-node ansible_host=100.83.183.124 ansible_user=admin ansible_ssh_private_key_file=/home/tazpod/secrets/ssh/lushycorp-vault/id_ed25519 ansible_ssh_common_args='-o ProxyCommand="tailscale nc %h %p" -o StrictHostKeyChecking=accept-new'
```

This line tells a broader lesson: real systems do not always fail on the big concepts. They often fail at the contact points between a well-designed project and an operating environment with specific characteristics. The difference lies in the ability to read the problem without generalizing too quickly.

## The final result: create, rerun, destroy

Once those details were corrected, the project closed its objective exactly as expected. `create.sh` reached the end successfully. The VM was born from the golden image, passed the public bootstrap, joined the tailnet as `lushycorp-vault-foundation`, showed the correct tags, answered on the Tailscale path, and executed the baseline check via Ansible on the private channel. Even the `podman --version` verification passed without surprises.

Even more importantly, the **rerun** confirmed the sanity of the plan. Terraform went to no-op, Tailscale did not require unnecessary mutations, and the system showed the behavior I expected from a well-designed foundation: not only “it works once,” but it converges when I launch it again.

Finally, I also executed `destroy.sh` and verified local cleanup. This step is essential for me. An infrastructure-as-code project is not really closed when it creates a machine: it is closed when it also knows how to remove it cleanly, leaving the workspace readable and ready for the next cycle. That is where you see whether the pipeline is just a demo or a process you can reopen.

## The lesson about LLMs is the most important part of this post

All of this confirms in a very concrete way something I had already sensed and written before: LLMs are powerful, but the result does not depend only on their generative capacity. It depends enormously on **how they are guided**.

If the approach is “build me this infrastructure” and then I wait for a well-made system to emerge from a generic request, the risk is extremely high. I may get plausible output, but fragile, poorly aligned with the real context, or built on unchecked assumptions. A language model can produce an impressive amount of useful material, but it does not automatically replace the work of clarifying the problem.

What this session shows is almost the opposite: when the operator knows what is being built, knows how to split the problem, knows how to identify the real constraints, and uses the LLM inside a disciplined structure, the multiplier changes scale. It is no longer a text generator trying to improvise an infrastructure. It becomes an accelerator for the engineering capacity of whoever is guiding it.

The most honest formula I take away is this: **the more the person using the LLM understands the domain, the more the multiplier rises**. If understanding is weak, the model amplifies ambiguity. If understanding is strong, the model amplifies speed, breadth of exploration, and implementation quality.

## Post-lab reflections

This stage is not memorable because “there were no problems.” There were problems, and that is exactly how it should be. It is memorable because the problems were the right kind: small, real, readable, and correctable without demolishing the project. That is the best possible signal for a foundation.

The most satisfying thing, at this stage, is not that I brought up a VM on Hetzner with Tailscale. It is that I verified that the combination of upfront design, work decomposition, and guided use of an LLM produces a much smoother execution than the one I would have obtained with a more impulsive or monolithic approach.

In the end, that is exactly the point of this session: less improvisation during the build, more intelligence before the build. And when that happens, even a complex infrastructure step can finally become a quieter session than usual.
