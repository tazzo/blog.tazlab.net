+++
title = "SDD in half a day: a context with rules, and the cluster DAG fixed on the first attempt"
date = 2026-03-15T14:00:00+01:00
draft = false
description = "How I implemented a Spec-Driven Development system as a simple Markdown context in half a day, and how it allowed me to fix a persistent cluster problem that had been resisting for weeks."
tags = ["kubernetes", "flux", "gitops", "agents", "context-management", "sdd", "devops", "workflow"]
categories = ["Infrastructure", "DevOps"]
author = "Taz"
+++

## The latest TazLab developments

This is one of those articles you write when things are going well. No incidents to report, no cluster rebuilds at two in the morning, no Deployment refusing to start for incomprehensible reasons. The lab is running. The pipeline works. I've had time to think about processes instead of fighting problems.

In the last few sessions, two concrete things happened that are worth documenting: I implemented a **Spec-Driven Development** system as a pure Markdown context, and I used that system to fix a Flux DAG problem that had been resisting for weeks. The result was cleaner than I expected.

## Spec-Driven Development as a context: zero code, just rules

The previous article on [AGENTS.ctx](/posts/ai-context-management-agents-ctx/) described the basic idea of the context management system: every operational domain has its own `CONTEXT.md`, loaded on demand, with the rules already written. The agent doesn't change — the context does.

The natural question I asked myself immediately after was: can I apply the same principle to the development process itself? Not as an external tool, not as a standalone system — as another context to open when needed.

The answer is yes, and it took me about half a day.

**SDD** (Spec-Driven Development) is today a file `AGENTS.ctx/sdd/CONTEXT.md` with a four-phase workflow and a set of rules the agent follows when it opens the context. No code. No dependencies. Just Markdown versioned on Git.

### The four phases

The workflow I defined is deliberately linear, with explicit gates between each phase. The agent cannot move to the next phase without approval.

**Phase 1 — Constitution.** The foundational document of the project. Defines the immutable foundations: language, framework, naming conventions, constraints, prohibited libraries. Once approved, the constitution doesn't change without explicit approval. It's the document you return to when, during implementation, a doubt arises about "but didn't we say to do it this way?".

**Phase 2 — Specification.** Defines *what* to build in full logical detail. Not the implementation — the logic. Expected inputs, desired outputs, behavior for each case. Edge cases and error handling. Acceptance criteria: when is the work considered done? This document is the source of truth. If during implementation something doesn't add up, you come back here.

**Phase 3 — Plan.** Defines *how* to build it technically. Which files to modify, which to create. Architectural choices and their rationale. Dependencies and execution order. The plan is proposed by the agent based on constitution + spec, and requires approval before proceeding.

**Phase 4 — Tasks.** The spec is decomposed into a checklist of atomic micro-tasks, each marked as `[ ]` or `[x]`. Each task is a discrete, completable action. During implementation, the tasks file is the GPS: open it, see the next pending step, execute it, mark it complete.

### The project inventory

Every SDD project lives in `AGENTS.ctx/sdd/assets/<project-name>/` with its four files. The context maintains an inventory table in `CONTEXT.md` that updates when a project is created or completed. When I open the context I immediately see the state of everything: what's in progress, what's blocked, what's completed with the relevant notes.

This has an important practical effect: every subsequent session doesn't start from zero. The agent reads the inventory, identifies the in-progress project, loads tasks.md, and continues from the next pending step. The warm-up is almost nonexistent.

The structure is the same one I can hand to Gemini or any other agent: just have it read the main `AGENTS.ctx/CONTEXT.md`, which explains where to find the available contexts, and the agent is immediately oriented without further explanation.

## The first real test: flux-dag-fix-v2

Theory is cheap. The first real test of SDD came immediately, with a problem I had been carrying for weeks: the Flux kustomization DAG on the TazLab cluster was not behaving as expected.

### The problem context

The TazLab cluster is managed entirely via **GitOps with Flux**. Every Kubernetes resource is defined in Git, Flux continuously reconciles the state of the repository with the state of the cluster. Kustomizations — the logical groupings of resources — have dependencies declared explicitly via `dependsOn`, and can have `wait: true` which forces Flux to wait until all resources in the kustomization are ready before proceeding with the dependents.

The problem already had a precise analysis behind it: a structured document with a table of problems identified in the DAG, a target graph diagram, detailed sections for each fix, a risk matrix, and a summary of the 15 changes to apply. It wasn't approximate documentation — it was a complete technical plan.

The difficulty was different: the plan was designed as a single solution to be applied all at once. All the changes, one commit, then final verification. Without a sequence of isolated steps, without a verification gate between one change and the next, without the ability to isolate exactly which change had introduced a problem if something went wrong.

### The SDD import

I used the existing plan as a starting point to create the SDD project. The technical analysis was already done — what was missing was the execution structure. The phases did their work:

The **constitution** fixed a fundamental constraint I had never formally stated in previous sessions: *one change at a time, each verified with a complete destroy+create cycle before proceeding to the next*. It seems obvious, but without it written down somewhere, it's easy to give in to the temptation to bundle multiple fixes into a single commit "to save time" — which is exactly what had led to the confused situation in the first place.

The **specification** forced me to state the actual root causes, not the symptoms. The symptoms were kustomizations stuck in `NotReady`, dependencies that wouldn't unblock, pods that weren't starting in the right order. The causes were distinct and separate, and required separate fixes.

The **plan** decomposed the work into 14 isolated steps, each with its own verification. Not 14 commits in blind sequence — 14 steps each with a destroy+create cycle and a precise set of conditions to verify before considering it complete.

The **tasks** file became the operational checklist. Each session: open tasks.md, see the next pending step, execute it, mark it complete, close. Next session: reopen, continue.

### The root cause

Once the problem was properly structured, the main cause emerged clearly.

The `infrastructure-operators-core` kustomization was grouping together two fundamentally different categories of resources:

1. **Lightweight controllers**: cert-manager, traefik, Reloader, Dex, OAuth2-proxy, cloudflare-ddns. Relatively fast Helm charts, install in 1-2 minutes.
2. **Heavy charts**: `kube-prometheus-stack` and `postgres-operator`. The former in particular has an installation that can take 10-15 minutes on slow hardware.

The problem with `wait: true` on this kustomization was structural: Flux waits for *all* resources in the kustomization to be in Ready state before unblocking the dependents. With `kube-prometheus-stack` inside `operators-core`, adding `wait: true` meant blocking the entire graph for 15 minutes every time. All dependent kustomizations — `infrastructure-bridge`, `infrastructure-instances`, `apps-static`, `apps-data` — remained stuck waiting for Prometheus to finish installing.

This is a DAG design error, not a configuration error. I had mixed resources with radically different convergence times in the same graph node, and then tried to put a gate on that node. The gate was correct in principle — `wait: true` on `operators-core` ensures cert-manager is ready before certificates are requested — but impossible in practice as long as the node contained heavy charts.

### The fix

The fix was to separate the concerns. I removed `../monitoring` and `../postgres-operator` from the `infrastructure/operators/core/kustomization.yaml` kustomization, leaving them in their dedicated kustomizations (`infrastructure-monitoring` and `infrastructure-operators-data`) which already existed and already managed their own lifecycle autonomously.

```yaml
# infrastructure/operators/core/kustomization.yaml — after the fix
resources:
  - ../cert-manager
  - ../traefik
  - ../reloader
  - ../dex
  - ../auth
  - ../cloudflare-ddns
  # kube-prometheus-stack removed → managed by infrastructure-monitoring
  # postgres-operator removed → managed by infrastructure-operators-data
```

With this change, `operators-core` contained only lightweight charts. The complete installation took 2-3 minutes. `wait: true` became safe to enable: the gate ensures that cert-manager, traefik, and the other fundamental controllers are operational before dependent kustomizations start creating resources that require them.

The final destroy+create cycle declared the blog online in **8 minutes and 20 seconds** — the lightweight critical path was working exactly as designed. The PostgreSQL database, with the S3 restore running in the background, and the dependent services (Mnemosyne MCP, pgAdmin) completed around **12-13 minutes**. Times within expectations: the restore is not on the blog's critical path, it runs in parallel while the upstream pods are already serving traffic.

### What SDD changed in this session

I would be dishonest if I said that without SDD the problem would have been unsolvable. I probably would have solved it anyway. But with more attempts, more disorganized commits, and almost certainly I would have introduced regressions along the way.

What SDD changed is the working mode: instead of proceeding by local attempts — "let's try removing this dependency and see what happens" — I had to first formally state what was going wrong and why, then design a sequence of verifiable fixes, then execute them one at a time with explicit confirmation between each.

This discipline has a cost in terms of initial time. It has an enormous benefit in terms of clarity: when you're on the tenth step out of fourteen and something isn't behaving as expected, you know exactly what you've already verified, what you've ruled out, and where to look.

## The working rhythm with contexts

There's a side effect of the context system that I hadn't anticipated when I designed it, and which has turned out to be more valuable than I expected: the working rhythm has changed.

Before the context system, every session had a non-negligible bootstrap cost. Reopening a session meant re-explaining where we were, what the state of the project was, what rules to follow. With complex projects, this could require several exchanges before being operational.

Today the pattern has become: open the terminal, load the context, operational in a few seconds. The context brings with it the rules, the project state, the next step to execute. Close the terminal, reopen, I'm back exactly where I was.

This has also changed how I think about new features. When I want to add a new capability to my workflow, I no longer think "I need a new specialized agent". I think "I need a new context with the right rules". Write the `CONTEXT.md`, define the expected behavior, and every agent that reads it will behave consistently.

The portability advantage is real. Switching to Gemini from Claude requires resetting nothing: just have it read the main `AGENTS.ctx/CONTEXT.md`, which explains the structure of the system, where to find the available contexts and the general rules. The agent is immediately oriented. There's no lock-in on any specific tool.

## Reflections

This leg of the journey confirmed something I had intuited but not yet experienced directly: the structure of the process has an impact on output quality just as much as technical capabilities.

The Flux DAG problem wasn't difficult once correctly stated. The difficulty was in stating it correctly after weeks of disorganized attempts that had accumulated noise. SDD didn't add technical capabilities — it added the framework for using those capabilities in an orderly way.

There's another thing worth noting: the system is deliberately simple. There's no tool to install, no database to configure, no server to maintain. They are Markdown files in a Git folder. This simplicity is not a limitation — it's a deliberate design choice. A system that depends on a few ubiquitous tools is a system that survives changes in the ecosystem and works on any machine, with any agent.

The natural next step is to use this same system for future projects, accumulating over time an inventory of completed specs, plans, and tasks that documents not only what was built, but why it was built that way.
