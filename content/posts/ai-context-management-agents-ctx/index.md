+++
title = "AGENTS.ctx: Context Management for AI Agents Without Re-Explaining Everything"
date = 2026-03-13T21:00:00+01:00
draft = false
description = "How I solved the AI session amnesia problem with an organized context system: selective loading, agent-agnostic, and zero repetition."
tags = ["AI", "DevOps", "Context Management", "Agents", "Workflow", "Productivity"]
author = "Tazzo"
+++

## The Problem: Session Amnesia

Every time I restart a terminal and open a new session with an AI agent, I face the same problem: I have to re-explain everything from scratch. Where we are, what we're doing, what the project rules are, what problems we've already solved.

It's a frustrating cycle. The agent doesn't remember anything from the previous session. I have to manually re-inject the context, or hope the system has some persistence mechanism — but often these mechanisms are opaque, inefficient, or simply don't exist.

The problem becomes even more evident when working on multiple parallel projects. Each project has its own conventions, its structure, its unwritten rules. Loading everything into the same session is not just inefficient: it's counterproductive.

### The Context Window Limit

Language models have a physical limit: the **context window**. When the session starts filling up, performance degrades. Around 50% of capacity, the quality of responses visibly worsens. The model "forgets" initial instructions, loses coherence, repeats information.

This is **context bloat**: too much irrelevant information loaded into the same session. The solution isn't more memory, but *selective* memory.

## Two Tools, Two Purposes

Before arriving at the solution, it's important to distinguish two different problems:

**Mnemosyne** is an MCP server I built for **long-term memory**. It records what I did, what problems I encountered, how I solved them. It's a searchable archive: when a problem resurfaces, I search the memories and find the solution applied in the past. It's useful for troubleshooting, automatic documentation, building a personal knowledge base.

**AGENTS.ctx** answers a different problem: **active context**. I don't want to remember what I did three months ago — I want the agent to know *now* where we are, what we're doing, what rules to follow. And I want it to know without me having to repeat everything every time.

Mnemosyne is the historical diary. AGENTS.ctx is the operational brief.

## The Architecture: Indirection and Selective Loading

The central idea of AGENTS.ctx is simple: **don't load everything, load only what's necessary**.

The structure is based on three levels:

### Level 0: AGENTS.md (Entry Point)

In the working directory (`/workspace`), an `AGENTS.md` file contains basic instructions for the agent. It says what to do at startup, where to find contexts, how to manage them.

This file is lightweight, a few paragraphs. Its job is to point the way, not carry the load.

### Level 1: AGENTS.ctx/CONTEXT.md (Base Context)

In the `AGENTS.ctx/` folder, a `CONTEXT.md` file contains the base context: the list of available contexts, general rules that apply to all projects, folder structure.

This file is loaded automatically at startup. It's the "operating system" of contexts: it provides the directory and fundamental rules.

### Level 2: Specific Contexts

Each context has its own subfolder. They can be:

- **Projects**: `tazpod/`, `ephemeral-castle/`, `tazlab-k8s/`
- **Generic workflows**: `blog-writer/`, `plans/` — for repeatable activities
- **Utilities**: contexts that load only rules, are used and closed

When I say "work in context X", the agent loads only that file. Nothing more, nothing less. Finished the work, I close the session and start clean, ready for another context.

### Composite Contexts

Some work requires multiple contexts simultaneously. For example, "cluster" is a composite context that loads both `ephemeral-castle` (the Proxmox/Talos infrastructure) and `tazlab-k8s` (the Kubernetes configurations). The agent reads both files and merges the rules.

This allows working on complex systems without duplicating information.

## Agent-Agnostic by Design

A deliberate choice: everything is based on text files in simple folders. No databases, no proprietary formats, no lock-in.

This means I can use **any agent**: Gemini CLI, Claude Code, pi.dev. As long as the agent can read a text file and follow instructions.

Portability is fundamental. I don't want my workflow to depend on a specific tool. If tomorrow I discover a better agent, I want to be able to adopt it without rebuilding the whole system.

### Inspiration and Attribution

The idea isn't mine. I saw it in [this video](https://youtu.be/MkN-ss2Nl10), which shows a similar approach for managing contexts with AI agents. I adapted the concept to my workflow, adding the layered structure, composite contexts, and integration with my existing system.

## How It Works in Practice

The startup sequence is:

1. The agent reads `/workspace/AGENTS.md`
2. Follows the instruction: "read `AGENTS.ctx/CONTEXT.md`"
3. The base context lists available contexts
4. When I say "context X", the agent reads `AGENTS.ctx/X/CONTEXT.md`

### Structure of a Context

Each context can contain:

- `CONTEXT.md`: main instructions
- `scripts/`: interaction scripts (deploy, test, utility)
- `docs/`: additional documentation
- `assets/`: configuration files, templates, resources

The structure is flexible. The important thing is that `CONTEXT.md` explains what's there and how to use it.

### Example: tazpod Context

**TazPod** is a Go CLI for managing a nomadic, secrets-aware development environment. It provides:

- An AES-256-GCM vault in RAM for secrets (mounted with `tazpod unlock`, zeroed with `lock`)
- Docker container with full toolchain (kubectl, terraform, helm, neovim, etc.)
- Automatic identity sync to S3 for portability
- Integration with Infisical for secrets management

The `tazpod/CONTEXT.md` context explains to the agent the three-layer architecture (host CLI, tmpfs enclave, container), main commands, hardcoded paths, and custom procedures (like GitHub push with token).

When I work on tazpod, the agent immediately has the complete picture: I don't need to explain what the vault is, how the enclave works, or where the files are. The context is compact and focused.

## Trade-offs and Lessons Learned

### What Works Well

- **Explicit loading**: I know exactly what gets loaded
- **Clean separation**: each project has its own space
- **Zero magic**: no auto-discovery that loads unexpected things
- **Portability**: works with any agent

### What Could Improve

- **Manual management**: I have to update tables when adding contexts
- **No inference**: the agent doesn't guess the context, it must be explicit
- **Initial overhead**: requires some setup

The main trade-off is between convenience and control. I chose control.

## Conclusion: Compact Context, Better Performance

AGENTS.ctx solves a practical problem: avoiding repeating the same things every time I open a session. The solution isn't more memory, but organized memory.

Indirection, selective loading, separate contexts. The agent has only what's necessary for the current work. No bloat, no degradation.

And when I switch agents, the system comes with me.
