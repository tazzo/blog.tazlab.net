+++
title = "The Research That Killed the Injector: Why I Use Deep Research to Guide LLMs"
date = 2026-05-30T10:00:00+02:00
draft = false
description = "After spending weeks building a Vault Agent Injector setup, a web search showed me that Vault Secrets Operator was the better choice. I didn't waste time: I learned. And that is exactly how LLMs should be used — not to write code, but to explore, design, and verify."
tags = ["ai", "llm", "vso", "vault", "kubernetes", "deep-research", "crisp", "workflow", "methodology"]
categories = ["Perspective", "DevOps", "AI"]
author = "Taz"
+++

# The Research That Killed the Injector: Why I Use Deep Research to Guide LLMs

## The Thesis

Artificial intelligence is not replacing engineers. It is radically changing the ratio between time spent designing and time spent executing. But to get professional results — ones that work, that last, that don't collapse at the first edge case — you need a process. You need someone to decide, to verify, to say "no, this path is wrong, we have another one."

This article is not a defense of AI. It is an explanation of how I use it, why it works, and why "vibe coding" — letting the agent do everything on its own — is not the right way to build enterprise infrastructure.

## The Spark: A Decision I Thought Was Right

For weeks I worked on a project: Vault Agent Injector on a Talos cluster. I designed it, implemented it, tested it. I wrote articles, documented patterns, fixed a sidecar crash on Talos, fixed Podman DNS, worked around a vault-k8s bug. Everything worked.

Then, during a deep-dive research on a technical detail, I stumbled upon Vault Secrets Operator (VSO). The more I studied it, the more I realized it was exactly what I should have used instead of the injector. Centralized, no sidecar, no overhead on a single worker, with native rollout restarts.

I didn't make a mistake. I followed a process that led me to discover a better solution. And that is the difference between a professional product and something cobbled together.

## The Process: It's Not Magic, It's Methodology

The way I work today follows a precise cycle that I have refined project after project. I call it the CRISP cycle, though the name is what matters least:

1. **Brain dump** — no order, no structure. A raw mind map.
2. **Deep research** — on every point I don't fully understand, I do a targeted search. Google, Perplexity, Context7, official documentation. Every search is a crafted prompt, not "search this."
3. **Design** — structure the ideas into a DESIGN.md and a PLAN.md. Each phase has an exit test.
4. **Split** — if the project grows too large, I split it into children or siblings. The project tree grows with understanding.
5. **Build** — implementation with the LLM.
6. **Review** — at the end, I analyze deviations from the plan. Every time I discover something. Every time I refine the process.

This cycle is no different from what I used to do. The difference is that **deep research** — the part that used to take days of reading forums, blogs, trial and error — now takes minutes. But the quality of the research depends on the quality of the question. If you cannot frame the problem, AI will not do it for you.

## The Growing Tree: The Real Project Map

One of the most visible results of this process is the project tree structure. Opening the CRISP projects directory for the vault is instructive. What started as "put Vault on a Hetzner VM" now looks like this:

```
hetzner-vault-platform/
│
├── 10-hetzner-vault-foundation/                       ✅ Foundation
│   ├── 10-hetzner-runtime-golden-image/               ✅ Golden Image
│   └── 20-hetzner-tailscale-foundation/               ✅ Tailscale
│
├── 20-hetzner-vault-runtime/                          ✅ Runtime
│   ├── 10-hetzner-vault-local-lifecycle/              ✅ Vault server
│   ├── 20-hetzner-vault-s3-backup-recovery/           ✅ S3 backup
│   └── 30-hetzner-vault-runtime-orchestration/        📝 Orchestration
│
├── 30-hetzner-vault-consumers/
│   │
│   ├── 04-hetzner-tailscale-talos-bridge/             ✅ Talos bridge
│   ├── 07-tailscale-operator-deployment/              ✅ Tailscale K8s
│   │   ├── 10-operator-dns-resolution/                ✅ DNS resolution
│   │   ├── 15-tailscale-operator-hardening/           ✅ Hardening
│   │   └── 20-tailscale-service-exposure/             ✅ Service exposure
│   │
│   ├── 09-vault-k8s-integration-prep/                 ✅ Integration prep
│   ├── 10-tazlab-k8s-vault-migration/                 ✅ Secret migration
│   ├── 12-tazlab-k8s-vault-migration-followup/        ✅ Followup
│   │
│   ├── 15-tazlab-k8s-vault-dynamic-secrets-operator/  🟢 Active
│   │   ├── 10-vault-agent-injector-phase1/            ✅ Completed
│   │   ├── 11-vault-agent-injector-phase1-followup/   ✅ Completed
│   │   ├── 12-vso-foundation/                         📝 VSO foundation
│   │   ├── 13-vso-static-migration/                   📝 Static migration
│   │   ├── 14-vso-dynamic-migration/                  📝 Dynamic migration
│   │   ├── 20-vault-secrets-universal-adoption/       📜 Historical
│   │   ├── 30-vault-pki-certificate-authority/        📜 Historical
│   │   └── 40-vault-transit-engine/                   📜 Historical
│   │
│   └── 20-infisical-decommission/                     📝 Infisical cleanup
│
├── 40-system-rebirth-orchestration/                   📝 Rebirth
│
└── 90-historical/
    └── 10-hetzner-vault-convergence/                  📜 Historical
```

Just the vault consumer section — the part that handles cluster-to-Vault integration — now has 8 projects, of which 3 are active and 3 historical. And it is not finished: I suspect it will grow further when we explore PKI and Transit.

Every branch of the tree represents a moment when I realized the solution was more complex than expected. Instead of forcing everything into a single project — producing a messy plan that is hard to validate — I split. Each project has its own DESIGN.md, PLAN.md, RESEARCH.md, and when it reaches the build phase, its own tasks.md.

The three projects marked "Historical" are not failures. They are directions I explored, documented, and then surpassed with a better choice — like VSO making the injector approach obsolete. If I had never explored them, I would never have understood why VSO is better. The tree is the map of my understanding: every fork is a lesson learned.

## Vibe Coding and Why It Doesn't Work for Infrastructure

I see more and more people describing their workflow as: "I asked the AI to build this, it worked, I deployed." And it works, for a certain definition of "works." The question is: what is happening behind the scenes? How many decisions were made without your knowledge? How many are correct? How many are optimal?

Take my Vault project. If I had told an LLM "migrate all secrets to Vault, implement dynamic secrets for Grafana," it would have gotten there somehow. It might have chosen ESO, the injector, or maybe a completely different approach. But every choice carries a tree of decisions — compatibility, overhead, maintainability, security — that an LLM cannot evaluate because it does not know the context: the single-worker cluster, the Hetzner VM with Podman, Talos limitations, the budget.

This does not mean LLMs are useless. It means they need to be **guided**. The right metaphor is not a sleeping driver, but a pilot who programs the flight plan and then monitors every parameter. If the pilot falls asleep — if they accept the first solution that works — the flight arrives at its destination, but who knows how much extra fuel was burned, how many detours were taken, how much stress was put on the machine.

## The Salvatore Sanfilippo Example

Salvatore Sanfilippo, the author of Redis — one of the most widely used software projects in the world — uses LLMs in a similar way. In his videos he describes spending months writing extremely detailed specifications before asking an LLM to generate code. His Dwarf Star 4 project — a quantized implementation of DeepSeek that runs on a MacBook — was written almost entirely by AI agents. But every line of the specification was his. Every architectural decision was his. The AI wrote the code, but the architecture, the design, the tradeoffs — those are human.

This is the pattern I see working: the engineer designs, the AI executes. The engineer verifies, the AI corrects. The engineer learns, the AI documents.

## Deep Research as a Multiplier

The real breakthrough for me was deep research. Before, to tackle a new topic — say, Vault dynamic secrets or the PKI engine — I had to:
1. Read the official documentation (hours)
2. Search for blog posts, tutorials, examples (hours)
3. Trial and error, repeat (hours or days)

Today I do this:
1. Study enough to frame the problem (minutes)
2. Prepare a precise research prompt — context, questions, scenario (minutes)
3. Run the search on Google Deep Research or Context7 (minutes)
4. Read the results, decide, design (hours)

The result is the same level of understanding, but in a fraction of the time. And the quality is better, because the research is targeted, not exploratory. I don't find random information — I find answers to precise questions.

This has allowed me to do things that were previously impossible due to time constraints. An enterprise Kubernetes cluster with 80 pods, Vault, Tailscale, monitoring, GitOps — in five months, in the evenings after work. It is not about speed: it is about process. The part that takes time — designing, deciding — I do. The part that requires execution — writing code, testing, configuring — the AI does.

But I do not only use deep research during the planning phase. I have now set up the process so that the LLM stops itself when attempts to solve a problem multiply without progress. It stops, explains the friction point to me, and I go do research on that specific problem. Sometimes I discover that we simply had not done enough research before starting. Other times — a couple of times during this project — we ran into a documented bug. A concrete example: during the injector implementation, the vault-agent sidecar crashed in a loop. The LLM tried a few variations, then stopped on its own and explained the error. I did a search and discovered it was vault-k8s bug #660: the injector generates the wrong parameter for the JWT method. Documented bug, with a known workaround. Resolved in minutes. Without that mechanism — stop if you are not making progress — the LLM would have kept spinning in circles for hours.

## Tests as a Containment Fence

One of the most important things I have learned is using tests as guardrails for the AI. When I design a phase, I always try to define a functional test that must pass for the phase to be considered complete. If the test is well-designed, the AI cannot cheat: it must implement exactly what I want, because otherwise the test fails.

For example, in the Vault project, one of the tests was: "the Vault container must be able to resolve MagicDNS names." If the AI had taken a shortcut (using static IPs, configuring DNS differently), the test would have failed. The test forced the LLM to implement the right solution, not the fast one.

Tests are my tool for maintaining control over a process that would otherwise tend to choose the shortest path.

## The Economics: Using the Right Model

In a period when LLM prices are skyrocketing, most of my work — implementation and most of the research — is done with DeepSeek V4 Flash. A model that costs very little, but works surprisingly well when the design is solid. I have tried many, and this is the one that is currently giving me the best results at a very reasonable cost.

For the design phase, however, when problems become more complex or we need to get out of a dead end, I switch to DeepSeek Pro or Gemini. More expensive models, but with the ability to handle complex reasoning that Flash does not always manage well.

The lesson is: use the right model for the right job. A good design makes cheaper models as effective as expensive ones — but to design well, sometimes you need higher intelligence.

## What I Learned

1. **Research is not optional** — every project should start with deep research on the parts you don't know. It is not a waste of time, it is an investment.

2. **The tree is the map** — if the project grows, split it. The tree structure reflects your understanding. If it is flat, you are probably forcing it.

3. **Tests are truth** — a well-written functional test is worth more than a thousand lines of specification. It forces the AI to implement what you want, not what is easiest.

4. **Review is sacred** — after every build, analyze the deviations. Always. Every time you will discover something you did not know.

5. **The right model at the right price** — you don't need the most expensive model for everything. DeepSeek V4 Flash with clear specifications handles 90% of the work. For the difficult 10% — complex design, dead ends — I switch to DeepSeek Pro or Gemini.

6. **The engineer remains** — AI does not replace judgment. It replaces execution. And that is a pact that works, if you respect it.

## A Final Note

Everything I have built in these months — the cluster, Vault, dynamic secrets, the migrations — I did not truly need. My blog and my wiki would have worked perfectly well on two Docker containers. But I did it because now it is possible to learn by doing, at a level that previously required years of experience in a company setting.

One of my most recent projects is called Vault Secrets Operator. It made a month of work on the injector obsolete. And that is fine. Because that month was not wasted: many things I already knew — Vault, KV, authentication — but some aspects I discovered along the way. PKI for example: I know what it is, how it works, I have a clear idea of the mechanism. But I already know that when we get to the implementation — key exchange, certificates, handshake — details will emerge that I cannot see today. It happened with JWT, it will happen with PKI. This way of working lets me study and learn in a much more targeted way. Before, I had to read entire books or massive documentation, most of which was not focused on the problem at hand. I read things I did not need, hoping to find the few that I did. Now I go straight to the point: I only explore the aspects I need for the goal I have at that moment, one piece at a time. I do not need to know everything about everything. And when the time comes to implement PKI more deeply, I will do it with the same approach — targeted, concrete, without dispersion.

This, for me, is the true value of AI: not the quick answer, but the ability to explore, make mistakes, correct, and learn — at a speed that was simply impossible before.
