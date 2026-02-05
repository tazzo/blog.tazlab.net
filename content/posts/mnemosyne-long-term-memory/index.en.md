---
title: "Mnemosyne: A Chronicle of Semantic Memory Between AlloyDB and Cluster Self-Sufficiency"
date: 2026-02-04T12:00:00+01:00
draft: false
tags: ["alloydb", "google-cloud", "gemini-ai", "postgresql", "vector-database", "devops", "troubleshooting", "kubernetes", "linux-namespaces"]
categories: ["Cloud Engineering", "Infrastructure"]
author: "Taz"
description: "From gathering months of Gemini CLI sessions scattered across multiple machines to creating a semantic memory engine on AlloyDB, awaiting final migration to in-cluster PostgreSQL."
---

# Mnemosyne: A Chronicle of Semantic Memory Between AlloyDB and Cluster Self-Sufficiency

In the process of building a complex infrastructure like **TazLab**, the most valuable asset is not the Terraform code or Kubernetes manifests, but the **accumulated knowledge** gained during hours of interaction with artificial intelligence. Every session with Gemini CLI — the tool I use daily as an architect and debugging companion — contains the "whys" behind every line of code, the solutions to sudden Proxmox crashes, and the network hardening strategies.

However, this information was dispersed across a multitude of session JSON files, scattered between my old development PC, the current workstation, and the containerized environment of the **TazPod**. Starting a new session too often meant having to re-explain who we were and where we left off to the AI.

In this technical chronicle, I document the birth of **Mnemosyne**, the long-term semantic memory system I designed to centralize this information chaos and make it searchable in real-time.

## 1. The Engine Strategy: Why AlloyDB (for now)?

The final vision for TazLab is total **self-sufficiency**. The project plans to host the entire memory within my Kubernetes cluster, using a PostgreSQL database with the `pgvector` extension, persistent volumes managed by Longhorn with encrypted backups on S3 buckets, and a dedicated Pod acting as an MCP (Model Context Protocol) server.

However, serious engineering teaches not to fight too many battles at once. Building the in-cluster storage infrastructure *while* trying to develop the memory engine logic would have created an infinite dependency loop.

### Managed as a Bridge to In-House
I decided to initially rely on **Google AlloyDB** in the Milan region (`europe-west8`). This choice allowed me to:
1. **Isolate the problem**: Develop and test archival and search scripts without worrying about Longhorn stability or PVC configuration.
2. **Development speed**: AlloyDB offers native integration with Google's embedding models, giving me a "turnkey" environment to perfect the data analysis algorithm.
3. **Decoupling**: By having the memory outside the cluster, I can destroy and rebuild the entire laboratory environment (*Wipe-First* philosophy) without ever risking the loss of session history.

Once the Mnemosyne "engine" is mature, bringing it into the TazPod on local Postgres will be a simple data migration, as AlloyDB maintains full compatibility with the PostgreSQL ecosystem.

## 2. The Gathering: Recovering Gold from Chaos

The first real "dirty" work was the **gathering**. I had accumulated months of interactions with the Gemini CLI. Some files remained on another laptop, others were buried in temporary folders of previous Docker containers, others still lived in auto-save checkpoints.

### The Log Mine
These files are not simple logs; they are the chronology of the Castle's construction. They contain:
- Specific **Talos Linux** configurations that resolved FRR crash loops.
- Steps of the Hugo blog migration from a dynamic to a stateless setup.
- Reflections on the security of the LUKS vault integrated into the TazPod.

I implemented a "recursive collection" script (`gather_sessions.py`) capable of scanning entire portions of the disk in search of `.gemini` folders. The script was designed to handle name collisions and unify everything into a single working repository in `/workspace/chats`. This "gathering" brought to light 127 session files for a total of approximately 89MB of pure strategic text.

```python
# Un pezzetto della logica di scansione ricorsiva
def gather_sessions(source_root, dest_dir):
    for root, dirs, files in os.walk(source_root):
        if ".gemini" in dirs:
            gemini_path = Path(root) / ".gemini"
            # Copia e rinomina per evitare sovrascritture
            # ... logica di salvataggio in /workspace/chats ...
```

## 3. The Networking Enigma and the `memory-gate`

One of the most frustrating moments was establishing a stable connection between the TazPod (my development container) and AlloyDB on GCP. Although I was convinced the dynamic public IP was the culprit, the math didn't add up: the IP changed rarely, yet connections systematically died with `Connection Timeout` errors.

### Investigation Beyond the Obvious
I tried using the AlloyDB Auth Proxy, but the container seemed to suffer from unexplained latencies or internal DNS resolution issues. Instead of wasting weeks chasing ghosts in Docker's networking layers, I chose a pragmatic and enterprise path: **security automation**.

I created **`memory-gate`**, a script that doesn't try to "cure" the network but programmatically "opens" it. The script:
1. Calls an external API to find the current IP I am exiting from (be it home, a VPN, or a mobile network).
2. Uses the `gcloud` CLI to authorize that specific IP in AlloyDB's "Authorized Networks."
3. Allows me to work on the go without ever manually opening the Google Cloud console.

This solution transformed a blocking problem into an invisible automation that guarantees access from anywhere in total security.

## 4. Data Quality: The "Senior Architect" Filter

The initial upload was a disaster from a quality perspective. The archival script saved every single line of the logs, including thousands of Terraform status messages or Pod waiting logs ("Still creating...", "Still waiting...").

### Noise Killing the Signal
When I queried the memory, Gemini would respond by citing banal VM parameters (vlan_id, cpu_count) instead of reminding me *why* we had configured that specific subnet. The memory was full of "technical garbage."

I had to evolve the `tazlab_archivist.py` script. I rewrote the analysis prompt asking Gemini to act as a **Senior Cloud Architect**. I gave it the mandate to discard everything that is routine and synthesize only atomic facts and strategic decisions into self-consistent paragraphs. This "refinement" process transformed the database into a true architectural knowledge base.

## 5. The Invisible Bug and the Castle's New Laws

The most important moment of growth came during the debugging of an apparently unrelated problem. I noticed that the **Vault** folder (where all the cluster secrets reside) was no longer correctly mounted in the container's namespace. It was an error invisible even to the root user unless the mount table was specifically checked.

### Discovering AI Over-Engineering
Analyzing the history, I understood what had happened: in one of the countless refactoring iterations of the TazPod CLI code, Gemini had decided — on its own initiative and without me asking — to "optimize" or remove that specific line of the `docker run` command. The AI, in its propensity to improve code, had broken a consolidated feature.

This silent regression made me realize two things:
1. Gemini is a very powerful tool but can be excessively prone to unsolicited changes.
2. I needed a way to "instruct" the AI permanently on my quality standards.

### TazLab's Golden Laws
I immediately archived a set of rules in Mnemosyne that now surface in every session as initial context:

- **Minimum Change Necessary Rule**: When modifying code, change only the bare minimum. Always ask for confirmation before altering consolidated structures such as mounts, vaults, or GitOps flows.
- **Read-Before-Write**: It is mandatory to read the file before attempting a modification. Never trust the current session's memory, as the real file system might be different from what the AI "thinks" it remembers.

## 6. The Awakening Protocol: Meta-RAG and Context Injection

To close the circle, I implemented **Semantic Awakening**. I didn't want to have to ask Gemini to refresh its memory; the AI had to "wake up" already conscious of its history.

### The Semantic Index (`INDEX.yaml`)
I designed a **Meta-RAG** architecture. Instead of injecting static data, I inject a set of "fundamental questions" that Gemini must ask itself at the beginning of each session. These queries are defined in a YAML file that acts as a map of the project's consciousness:

```yaml
# TAZLAB SEMANTIC INDEX PROTOCOL
boot_sequence:
  - category: "Access & Prerequisites"
    query: "Come si accede alla memoria Mnemosyne e quali chiavi servono?"
  - category: "Environment & Architecture"
    query: "Qual è la struttura attuale del cluster TazLab (Talos, Proxmox, Nodi)?"
  - category: "Operational Philosophy & Safety Rules"
    query: "Quali sono le regole di sicurezza (Read-Before-Write, Minimo Cambiamento)?"
  - category: "Technical Debt & Tasks"
    query: "Quali sono i debiti tecnici aperti e le cose rimaste da fare?"
```

### Authoritative Injection in `.bashrc`
Through a hook in my `.bashrc`, the awakening script queries AlloyDB using these queries, generates a `CURRENT_CONTEXT.md` file, and passes it to the Gemini CLI via the `-i` flag (initial interactive prompt).

To prevent the AI from ignoring this information in favor of useless filesystem searches, I had to write an "authoritative" injection prompt:

```bash
/usr/local/bin/gemini -i "--- TAZLAB STRATEGIC MEMORY AWAKENING ---
The user has recalled your long-term memory (Mnemosyne). 
The following context is the result of a semantic search on 127 historical sessions.

RULES FOR THIS SESSION:
1. Use this context as the PRIMARY SOURCE OF TRUTH.
2. DO NOT scan the file system with 'grep' or 'ls' for information that is already present here.
3. Trust the paths described in memory, even if different from current folder names.

--- RECOVERED CONTEXT ---
$(cat /workspace/tazlab-memory/CURRENT_CONTEXT.md)
--------------------------"
```

In this way, as soon as I enter the terminal, the AI greets me confirming it knows exactly which technical debts are open (like the migration of the TazPod into the cluster) and which security rules it must respect not to break vault mounts.

## Final Reflections

Mnemosyne is not just a log database; it is the operating system of my knowledge. It taught me that in the relationship between humans and artificial intelligence, trust must be mediated by control and rigorous documentation.

Today, Mnemosyne is the bridge that allows me to suspend work for days and pick it up exactly where I left off, with an assistant that not only remembers what we did but also knows "how" we want the work to be carried out in the Castle of TazLab.

The journey toward total self-sufficiency continues. The next goal is already written in memory: bringing Mnemosyne home, inside the cluster, transforming it into a native TazLab service.

---
*Technical Chronicle by Taz - Systems Engineering and Zero-Trust Infrastructures.*
