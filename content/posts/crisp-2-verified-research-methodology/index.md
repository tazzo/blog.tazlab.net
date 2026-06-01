+++
title = "CRISP 2.0: Mandatory Research, Verified Plans, Zero Assumptions"
date = 2026-06-01T00:30:00+02:00
draft = false
description = "After theorizing the CRISP cycle in the previous post, I formalized it into a concrete workflow and tested it on three Vault migration projects in one afternoon. The result: zero bugs, zero redesign, three projects completed. Here is how it went."
tags = ["crisp", "methodology", "vso", "vault", "kubernetes", "deep-research", "workflow", "infrastructure", "enterprise"]
categories = ["Perspective", "DevOps", "Methodology"]
author = "Taz"
+++

# CRISP 2.0: Mandatory Research, Verified Plans, Zero Assumptions

## The Backstory

Two days ago I made a radical decision: abandon the Vault Agent Injector I had just finished implementing and migrate everything to Vault Secrets Operator (VSO).

It looks like a step backward. In reality, it was the demonstration that the method works. Two days of design with targeted research, one afternoon of implementation, and three migration projects completed — from Vault Agent Injector to VSO, through migrating all static secrets from External Secrets Operator, to reconfiguring Grafana to use dynamic credentials. Zero bugs in production, zero redesign during the build.

This article is not a tutorial. It is the chronicle of how a working method, applied with discipline, can transform a complex operation into a predictable process.

## From Cycle to Method

In the previous post I described a workflow cycle I called CRISP: Context, Research, Intent, Structure, Plan. It was a description of how I worked, not a formal method. Deep research was recommended, not mandatory. The plan was a sketch, not a verified contract.

The experience of the previous months — and in particular the discovery that VSO was better than the Injector, which emerged during a deep research session — led me to ask: if a research conducted midway through the project changed architectural choices, what would happen if research were the mandatory first step, not an afterthought?

This question gave birth to CRISP 2.0, a formal evolution of the previous cycle. The differences are substantial:

1. **Deep Research First is not optional.** Every project starts with specific research on every aspect not fully understood. The research is not exploratory — it is guided by structured prompts that include architectural context, exact component versions, specific questions, and evaluation criteria.

2. **Research has a home.** Every research finding is saved as a Markdown file in the project's `web-research/` folder, with a central index that catalogs them by topic and related project. Information is no longer lost.

3. **The plan has verification markers.** Every task in PLAN.md must be marked as `[🔍 confirmed by: web-research/filename.md]` or `[🔍 to verify]`. No task can be implemented without research confirming its prerequisites.

4. **Reality wins over documentation.** Research Grounding Rule: before implementing any migration, verify the real state with CLI tools. Manifest YAML files and research describe how things *should* work. Reality may differ.

5. **The verification cycle is mandatory.** Review → fix → research → repeat, until every single marker is confirmed. Only then proceed to the build.

6. **Mandatory retrospective.** Every completed project produces a report analyzing plan deviations, decisions made during the build, problems encountered, and gaps that emerged during the design phase.

It looks like bureaucracy. It is not. It is an investment — and like all investments, it must be measured.

## The Test: Three Projects in One Afternoon

To test the method, I chose the most complex node of the Vault project: migrating secrets from ESO and Vault Agent Injector to Vault Secrets Operator. I divided it into three independent projects:

- **12-vso-foundation**: install VSO, configure JWT authentication to the external Vault via Tailscale, verify with a pilot secret.
- **13-vso-static-migration**: migrate all static secrets from External Secrets Operator to VaultStaticSecret, remove Stakater Reloader.
- **14-vso-dynamic-migration**: migrate Grafana from Vault Agent Injector to VaultDynamicSecret, remove the injector from the cluster.

Three projects, three distinct scopes, three separate plans. Each with its own research, its own DESIGN.md, its own PLAN.md.

Here is what happened.

### Three Reviews per Project

Each project went through three review cycles before the build. The first review agent identified architectural problems. After each fix, a second agent verified the corrections. A third cycle confirmed everything was in order.

In project 12, the first review found a design error: the proposed authentication method (`method: kubernetes`, based on TokenReview) was incompatible with an external Vault on Tailscale. Research R14 confirmed that `method: jwt` was the correct enterprise choice, reusing the already configured `auth/jwt` backend — exactly the kind of discovery the method is designed to foster.

The second review found a more subtle bug: the Vault role was configured with `bound_subject` matching the VSO controller's ServiceAccount identity. But research R15 revealed that VSO resolves the ServiceAccount in the *consumer's* namespace, not in the VaultAuth's. The fix (`bound_claims_type=glob` with pattern `system:serviceaccount:*:vso-auth-sa`) resolved a problem that would have only emerged in production, likely as silent secret synchronization failures.

Without the review cycle, both bugs would have reached production.

### The Complex Problem: Grafana and Env Vars

The last project, the Grafana migration, presented the most insidious challenge. kube-prometheus-stack v61.3.1, the Helm chart managing Grafana in the cluster, automatically generates the `GF_DATABASE_USER` and `GF_DATABASE_PASSWORD` environment variables whenever the database is not SQLite. These variables are created with empty string values — but they still exist, and Grafana interprets them as a conflict with their `__FILE` equivalents we wanted to use to point to the files mounted from VaultDynamicSecret.

The result was an immediate container crash:

```
ERROR: Both GF_DATABASE_PASSWORD and GF_DATABASE_PASSWORD__FILE are set (but are exclusive)
```

The problem was not in the configuration, but in the Helm chart's template engine. The first research suggested using `envValueFrom`. It did not work — the chart was not passing values to the Grafana sub-chart. The second research identified the correct pattern, called *SQLite Template Bypass*: set the database type to `sqlite3` to prevent the chart from generating the conflicting variables, then override everything at runtime via standard environment variables.

The solution was:

```yaml
grafana:
  database:
    type: sqlite3
  grafana.ini:
    database: null
  env:
    GF_DATABASE_TYPE: "postgres"
    GF_DATABASE_USER__FILE: "/etc/secrets/grafana-dynamic-creds/username"
    GF_DATABASE_PASSWORD__FILE: "/etc/secrets/grafana-dynamic-creds/password"
```

Two research sessions, perhaps thirty minutes total. In a traditional approach, it would have been hours of debugging, trial and error, log reading, Helm template analysis. Here we identified the problem, searched for the solution, applied it. Done.

It is not that the problem did not exist — it is that the time to solve it was reduced from hours to minutes.

## The Economic Lesson: DeepSeek V4 Flash

All the work described in this article — design, review, implementation — was executed with DeepSeek V4 Flash. Not the most expensive model, not the highest ranked in benchmarks. A model that costs very little.

And it worked.

The reason is that CRISP 2.0 shifts the workload from execution (where a powerful model matters) to design (where a human being making decisions is needed). When the project is solid, when plans are verified, when every choice is supported by research, the most economical model is sufficient. The difficult phase is the decision-making one — and that remains human.

For complex problems — the Grafana env var conflict is the example — two targeted researches solved in minutes what would have been an afternoon of debugging. In a traditional workflow, the model would try variants, fail, retry, until running out of context. With CRISP 2.0, the model stops, says "this does not work, I need research on this specific point", and with that research returns the solution.

This is the difference between using an LLM as an executor and using it as a collaborator.

## Vibe Coding vs Infrastructure: Two Different Worlds

There is a growing debate about how to use LLMs for writing code. "Vibe coding" — describing an application in natural language and letting the LLM generate it entirely — works for certain kinds of software development. For enterprise infrastructure, it does not.

Infrastructure is not linear code. It is a system of constraints: the cluster has only one worker node, Vault is on a Hetzner VM reachable only via Tailscale, Talos filesystem is read-only, the budget does not allow expensive models. An LLM cannot evaluate these constraints because it does not know them. Or worse, it evaluates them based on its training data, which may be months old.

CRISP 2.0 does not eliminate the LLM. It channels it. The LLM does research, writes plans, implements solutions, verifies results. But the decisions — which authentication method to use, how to structure the project, when to stop and do research — remain human.

It is a pact: the human decides what to do and why, the LLM does and verifies. It only works if both parties respect their role.

## The Numbers of the Afternoon

At the end of the afternoon, the tally was:

- **3 CRISP projects** completed: foundation, static migration, dynamic migration
- **8 VaultStaticSecret** created, all Healthy
- **1 VaultDynamicSecret** for Grafana, working
- **1 Vault Agent Injector** removed
- **1 Reloader** removed
- **0 bugs in production**
- **0 redesign during the build**
- **2 research sessions for the complex problem** (Grafana env var)
- **1 economical model** (DeepSeek V4 Flash) for all the work

Three problems that could have derailed the project — wrong auth method, incompatible bound_subject, env var conflict — were identified and resolved during design, before they became bugs.

## Conclusions

CRISP 2.0 passed its first real test. Three migration projects completed in one afternoon, with a level of quality I consider high: no bugs in production, no regressions, no discoveries during the build that required returning to the design phase.

It is not perfect. During the build, details emerged that the design had not anticipated: the exact structure of Vault paths (which were not leaf keys but directories), the key names in secrets (which VSO handles differently from ESO), the Grafana environment variable conflict. But none of these required a redesign — they were resolved with targeted research or local corrections.

What makes this method effective? Three ingredients:

1. **Research is specific and contextualized.** A CRISP research prompt is not "search how to do X". It is a document that includes architecture, versions, precise questions, and evaluation criteria. The quality of the answer depends on the quality of the question.

2. **The verification cycle is mandatory, not optional.** Three reviews per project are not excessive — they are the mechanism that prevented the most critical bugs.

3. **The method cleanly separates design from execution.** Design until every choice is verified. Then execute. Do not mix the two phases.

This working model is specific to enterprise infrastructure. For software development — writing an application, an API server, a frontend — the relationship is different. There, code is the product, and rapid iteration makes sense. Here, code is system configuration, and an error does not produce a bug to fix: it produces a non-functional cluster.

The difference is that infrastructure does not forgive haste.
