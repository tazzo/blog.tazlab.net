+++
title = "Memory Revisited: From a Handcrafted Mechanism to Hindsight, the New Multi-Agent Memory for TazLab"
date = 2026-08-29T20:15:00+01:00
draft = false
description = "Eight months after Mnemosyne, the TazLab technical memory migrates to Hindsight: why the DIY approach was no longer needed, model-fabricated dates, and a new way of working with agents."
tags = ["hindsight", "mcp", "kubernetes", "ai", "memory"]
author = "Tazzo"
+++

## The Ephemeral Paradox, Eight Months Later

Last February, in [*Mnemosyne Rebirth*](/posts/mnemosyne-mcp-integration/), I described the underlying problem of this lab: the working environment is ephemeral, and every new session of an AI agent is a blank slate. No memory of the decisions made, the bugs fixed, where we had left off.

But the history of TazLab explains better than anything why memory became a problem. The lab was born with Docker containers on a single host — no cluster, no orchestration: rougher, and that was fine. The turning point came in October–November 2025, when LLMs became genuinely agentic — models like Opus 4.x capable of autonomous multi-step work, writing configuration files, handling complete operations. At that point I stopped settling for containers and built the Kubernetes cluster: with agents at that level, writing manifests, configurations and automations had become feasible — and the cluster was worth it.

That is exactly where memory became a heavy need. Every session you opened or closed required re-reading everything: the code, the work done, how the system was built, where we had gotten to. With multiple agents working on the same projects the problem multiplied: they had to share the same memory, know the situation without re-reading everything each time, without breaking what was already done. From that need the handcrafted mechanism was born: an MCP server written in Go (**Mnemosyne**) talking to PostgreSQL, backed by a workspace of chronicles, reports and registers that the agents loaded at session start.

Eight months later — an eternity in today's AI — the ecosystem changed face: frameworks standardized around the Model Context Protocol and mature multi-agent memory services appeared. When several TazLab projects reached a maturity level that made the migration sensible, I decided to put one of these services to the test, replacing the handcrafted mechanism rather than running it side by side. This article covers the first stage: installing **Hindsight** on the cluster, the choices, the problems — and the unpleasant discovery that turned a mechanical import into a forensic audit.

---

## The Choice: Hindsight Against the Alternatives

The evaluation was short and pragmatic. There were two candidates: **Hindsight** by Vectorize.io and **TencentDB Agent Memory** ([github.com/TencentCloud/TencentDB-Agent-Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory)), which had intrigued me for its integrated approach. I chose Hindsight for three concrete reasons:

1. **Maturity and readiness**: a three-component architecture designed for Kubernetes, an official Helm chart, serious documentation, and a *memory bank* model that matches the primary requirement — different agents sharing the same memory.
2. **Compatibility with the existing hardware**: it wants PostgreSQL with `pgvector`, and TazLab already runs a PostgreSQL cluster managed by Crunchy PGO with S3 disaster recovery. Zero new components.
3. **Semantic extraction, not just embeddings**: this is the fundamental difference from my handcrafted setup. Mnemosyne stored the raw text of memories and converted it into numeric vectors to find **similar** memories — a similarity search, as good as it was. Hindsight goes one step further: an LLM reads the content and extracts **atomic facts with dates, entities and relations**, consolidates them into syntheses, and searches them by combining four strategies (semantic, exact text, graph, temporal). It doesn't answer "what resembles this query?" but "what do we know about this topic, when did it happen, and who is involved".

The cost of this architecture is an LLM in the pipeline: every `retain` triggers extraction calls. I connected extraction to the **opencode-go** gateway with the `mimo-v2.5` model — the same gateway Hermes uses in the lab — while embeddings stay on `gemini-embedding-001`. That separation would become important halfway through the migration.

---

## Phase 1: Stateless on a Cluster That Already Exists

The deployment principle is the same as everywhere in TazLab: pure GitOps, no data in pod state. Three deployments in a dedicated namespace — the API (slim image, ~300 MB of RAM versus the 4–8 GB of the version with local models), an async worker with a static identity, the control dashboard — and **zero volumes**: all state lives in PostgreSQL.

**Why "stateless" here is not a detail.** The TazLab cluster is born and dies by design: `create.sh` and `destroy.sh` rebuild it from Terraform in a one-shot cycle. A deployment with volumes is an exception that breaks reproducibility. Hindsight doesn't need them: facts, entities, graph and task queue live in PostgreSQL, and the existing database inherits the already-configured disaster recovery (pgBackrest backups to S3 with incremental restore). In plain terms: destroying and recreating the cluster **does not lose a single memory**. The ephemeral paradox, in the end, resolves itself.

The integration with the existing PostgreSQL happens via certificates: a dedicated user with `cert`-only authentication, a client certificate from Vault PKI, a dedicated schema. API keys come from Vault, exposure follows the pattern of the other services (LoadBalancer on the LAN with a NetworkPolicy), and the four manifest compositions flow through Flux like everything else.

The snags were the classic ones of an app not born for Kubernetes, and I'll quote two among them:

- **Environment variable collision**: a Service named `hindsight-api` makes the kubelet inject `HINDSIGHT_API_PORT=tcp://10.96.x.x:8888` into every pod in the namespace. The code does `int(os.getenv("HINDSIGHT_API_PORT"))` → guaranteed crash. The upstream image knows this and overrides the variable; anyone writing raw manifests needs to know it too.
- **pgvector not "trusted"**: since PostgreSQL 13 an extension marked `trusted` can be created by a user with adequate privileges. Crunchy's packaging **lacks that flag**, so `CREATE EXTENSION vector` requires superuser. The GitOps solution: declare the `postgres` user in the cluster spec and an idempotent Job managed by Flux that runs the extension, with a wait loop for the one-shot bootstrap.

---

## Phase 2: 745 Memories and the Dates That Didn't Add Up

With the platform up, the migration: 745 memories from Mnemosyne plus the structured memory workspace (19 archived chronicles, 57 reports, the system state). I wrote a dedicated importer with a precise protocol: one item at a time, a state file updated after every landing — if the process stops, you know exactly where.

The first batch went smoothly. Then the sample test stopped adding up: **36 memories dated 2024, and none of them can be**. The content was real — it talked about DevPod, TazPod, notebook setup — but the dates were not. The memory describing the transition to TazPod v0.1.7 was dated May 22, 2024: the `v0.1.0` tag only exists since January 21, 2026, and v0.1.7 was never tagged — it existed for a single day, February 3, 2026, as a commit documents.

**The diagnosis**: the LLM writer that had generated those memories back then had **hallucinated the years** — shifted back by one or two. The content was real; the dates were not.

**The correction**: rewriting 38 dates by hand was too risky. I launched four independent agents, each with a batch of memories and a brief containing the verifiable anchors (first-commit dates, tag dates, real chat files in the vault). The agents cross-referenced the workspace chronicles, the dated reports and the git history, and returned 38 corrected dates with evidence and confidence — also finding a useful rule: in some clusters the writer had shifted only the year, in others it had invented month and day too, so each item required its own verification.

**Purge and re-import**: the versions with fabricated dates were removed from the bank (cascading deletion of the derived units), and the corrected ones re-imported. A full scan of the bank confirmed zero residual units in 2024 — and temporal recall now works: asking "what happened in January 2026?" returns the facts with the right date.

The credit for catching it goes to the **sample test on real content**: the import had ended without errors, the data formally valid — and historically false. Only searching by topic and checking the dates reveals that a "successful" memory is not finding what it must find.

---

## Phase 3: The Quota Wall and the Invisible Items

During the migration, the Gemini free-tier embedding quota — on a key shared with other consumers of the lab — produced `429` walls at unpredictable times. Hindsight's behavior under these conditions was the most useful technical discovery of the session:

- A retain accepted during the wall **does not fail completely**: the op dies at the embedding step, but **the extracted content stays saved** in the database — without vectors.
- A unit without a vector is **invisible to recall**: it exists in the inventory, it does not exist for search.
- Failed ops are **terminal**: no self-recovery, and no (native, so far) re-embedding command exists.

The operational consequence: **"done" means op completed and searchable**, verified via recall — the operation being accepted, or the document existing, is not enough. Items imported during a wall are marked in a dedicated state and re-embedded in a dedicated pass when the daily budget allows. The adaptive pacing — waiting for the `retryDelay` reported by Google plus a margin, and suspending the import while the wall persists — avoids accumulating invisible backlog.

---

## The New Way of Working (Under Construction)

The part that excites me most is still the most immature. Hindsight offers mechanisms my handcrafted setup never had, and the migration is also the chance to rethink how agents access knowledge:

- **Always-on directives**: persistent bank rules injected into every extraction and synthesis — the TazLab conventions (no cleartext secrets, everything via Git, everything logged, independent-agent reviews before major builds) are no longer a file the agents must remember to read: they ride along in every call.
- **Mental models**: living syntheses of a topic, anchored to a query, that refresh themselves at every consolidation. The first one is `tazlab-operating-doctrine`: the operating rules, always current, readable with a single call.
- **Per-agent banks**: each agent has its own bank (Hermes, TazPod, OpenClaw) with its own context and directives, and shares `tazlab-common` for infrastructure knowledge. The historical friction — manually maintained contexts, agents that didn't know the situation — has a structural answer: prepared contexts the agents load themselves over MCP.

This part is deliberately **under construction**: which contexts to prepare, how to structure them, what to make always-on versus what to leave to semantic relevance are open decisions that real usage will help us make. The migration itself is also halfway: memories up to February 2026 are in with verified dates, the bulk (March→August) enters at quota pace over the next few days, one block at a time, with deep tests after every block.

---

## Conclusions

The migration is halfway through and the assessment is partial. The infrastructure held up well: the deployment integrated with PostgreSQL, Vault PKI and Flux without new components outside the destroy/create cycle, and every error encountered was fixed in Git. The date audit instead exposed a problem the import alone could not see: formally valid, historically false data. The sample test with external checks — git, real documents — was the only way to catch it, and it is now part of the protocol for every block.

The parts that matter most remain open: the memories still to import, the items saved during the quota walls that need re-vectorization, and above all defining how the agents will use the system — which contexts to prepare, which rules to make permanent, where to bound shared knowledge. On this, real usage will teach more than I can design right now. The handcrafted mechanism stays active in read mode until the migration is verified end to end: if Hindsight behaves as it seems, it will be time to retire it; if it doesn't, I will have learned where to intervene.