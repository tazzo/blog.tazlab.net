---
title: "A mature cluster: automated deploys, agent contexts, and the Mnemosyne MCP migration"
date: 2026-03-14T06:00:00+01:00
draft: false
tags: ["kubernetes", "gitops", "flux", "mcp", "mnemosyne", "agents", "context-management", "ci-cd"]
categories: ["Infrastructure", "DevOps"]
author: "Taz"
description: "When the cluster becomes stable, deploys become routine, and procedures automate themselves. A chronicle of an MCP migration and the maturity reached by the lab."
---

## The end state

Today I migrated Mnemosyne from the deprecated SSE protocol to Streamable HTTP. But this is not an article about a technical migration. It is an article about what it means when your Kubernetes cluster becomes *boring* — in the good sense of the word.

I made the commit, waited two minutes, and the new pod was running with the new configuration. No manual intervention, no `kubectl apply`, no panic. Flux detected the change in the Git repository, the ImagePolicy pointed to the new image built by the GitHub Action, and the Deployment was updated.

This is not a configuration I put together this morning. It is the result of months of iterations, full cluster rebuilds, CI/CD pipelines that failed and were repaired, ImagePolicies that did not recognize the correct tags. But today, finally, it works.

## The migration as a case study

Mnemosyne is the MCP server that manages my semantic memory. It exposes tools for ingestion, search, and management of technical memories, using PostgreSQL with pgvector for semantic similarity. Until yesterday it used the SSE (Server-Sent Events) protocol to communicate with MCP clients.

The problem: the oh-my-pi client did not handle the SSE protocol correctly. It required the client to maintain a persistent GET connection on `/sse` while sending POST requests on `/message`. But oh-my-pi treated SSE as a simple HTTP POST, without a background listener.

The solution was not to fix the client, but to migrate to the new standard: **Streamable HTTP**. This protocol uses a single POST endpoint (`/mcp`) that returns an SSE response when necessary. No complex session management, no separate listeners.

The migration was straightforward:

1. Updated `mcp-go` from v0.44.0 to v0.45.0
2. Replaced `NewSSEServer()` with `NewStreamableHTTPServer()`
3. Changed the endpoint from `/sse` + `/message` to `/mcp`
4. Updated `MCP_TRANSPORT` from `"sse"` to `"http"` in the Deployment

Four minimal changes. The code compiled on the first attempt. I committed, pushed, and the cluster did the rest.

## The GitOps pipeline that works

The CI/CD pipeline is deliberately simple:

```
Commit → GitHub Action → Build image → Push to registry → Flux reconciles → Deploy
```

There are no multiple stages, no approval gates, no deployments to separate environments. It is a home lab, not an enterprise. But this simplicity is a feature, not a limitation.

When I commit to `mnemosyne-mcp-server`, the GitHub Action:
1. Checks out the code
2. Builds the Docker image with a tag based on the run number and full commit SHA
3. Pushes to Docker Hub as `tazzo/mnemosyne-mcp:mcp-<run_number>-<full_sha>`

Meanwhile, in the cluster:
1. Flux has an ImageRepository that monitors Docker Hub
2. An ImagePolicy selects the most recent image
3. The Deployment has a `{"$imagepolicy": "flux-system:mnemosyne-mcp"}` annotation that Flux uses for auto-update
4. When it detects a new image, it updates the Deployment
5. Kubernetes rolls out the new pod

Total time: 2-3 minutes from push to running pod.

## The AGENTS.ctx context system

But the most interesting part is not the pipeline. It is how I structured the operational procedures.

I created a context system in `AGENTS.ctx/` that defines rules, workflows, and memory for each type of activity. Each context has:

- A `CONTEXT.md` file describing the project and its rules
- Asset files with specific prompts, templates, or resources
- An inventory of projects, statuses, and technical debt

When I open a context, the agent I am using immediately becomes specialized. For example:

- **blog-writer**: Defines a 5-phase workflow (Planning → Writing → Review → Translation → Publish) with rules for style, formatting, and GitOps publication
- **mnemosyne-mcp-server**: Documents the MCP server, code structure, environment variables, and build/deploy procedures
- **tazlab-k8s**: Describes the Kubernetes cluster, Flux resources, and how to interact with it

This article is the second I have written using the `blog-writer` context. The process has become almost automatic: I open the context, decide the key points, the agent writes, I review. No more endless iterations with generic prompts. The rules are already there, ready.

## The vision: automatic procedures for Mnemosyne

The next step is to create a context for memory ingestion in Mnemosyne.

Currently, when I want to save a technical memory, I have to:
1. Format the content
2. Manually call the `ingest_memory` tool
3. Verify it was saved correctly

With a dedicated context, this will become automatic. The agent will know:
- Which format to use for memories
- How to structure content for semantic search
- When to save (e.g., at the end of a work session)
- How to verify the save was successful

Just open the context and say "save what we did today." Everything else is handled by the rules.

## The multi-agent paradigm redesigned

For a long time, the prevailing paradigm for LLM automation has been "use different specialized agents for different tasks." One agent for code, one for writing, one for data.

With the context system, this reasoning is overturned — but in a more subtle way than it might seem.

For how I work today, alone, the optimal configuration is a generic agent + N contexts loaded on-demand. When I open the `blog-writer` context, the agent already knows how to structure an article, which rules to follow, how to publish it. When I open `mnemosyne-mcp-server`, it knows the code structure, environment variables, the CI/CD pipeline. The agent does not change — the context does.

But the same system scales horizontally. In the future, I could deploy multiple separate agents directly on the Kubernetes cluster — each with its own context already loaded as a ConfigMap or mounted as a volume. One agent responsible for cluster maintenance, one dedicated to ingesting memories into Mnemosyne, one that monitors Flux deploys. Each autonomous, each specialized, each with a folder of contexts covering the operational situations it might encounter.

The point is that contexts are **portable and composable**. They are not tied to a single agent. They are units of operational knowledge that can be distributed, mounted, combined. Today I use them interactively. Tomorrow they could be the foundation of an autonomous automation system.

This reduces management complexity:
- A single format for operational knowledge (structured Markdown)
- Contexts versionable on Git, centrally updatable
- Same structure for interactive use and autonomous deployment

It is like having a library of operational procedures that works both when I browse them myself and when an agent running on a pod reads them.

## The cluster in good health

Back to the beginning: the cluster is stable. This does not mean there are no problems — there always are. But it means the problems are manageable, and the procedures are repeatable.

When I had to migrate Mnemosyne to Streamable HTTP, I did not have to:
- Rebuild the development environment
- Manually configure environment variables
- Debug the CI/CD pipeline
- Relearn how Flux works

I simply:
1. Opened the `mnemosyne-mcp-server` context
2. Made the code changes
3. Committed and pushed

The rest happened by itself. This is the result of having documented, iterated, and built solid procedures over time.

## The future pipeline

The pipeline today is simple. In the future it will become richer:

- **Automated tests**: Every PR triggers tests before merge
- **Staging environments**: Deploy to a separate environment before production
- **Automatic rollbacks**: If health checks fail, roll back to the previous version
- **Notifications**: Slack or email when a deploy completes or fails

But the foundation is there, and it is solid. Every new feature will be an extension, not a refoundation. This is the advantage of having built the foundations correctly.

## What we learned

This "leg" of the journey confirmed to me that:

1. **GitOps is not just theory**: When it works, you forget it exists. You commit, and the code reaches production.
2. **Contexts change the way you work**: In my case, working alone, a generic agent + well-defined contexts has turned out to be more convenient and manageable than many separate agents. It is not a universal law, but for this workflow it works well.
3. **Documentation is code**: The CONTEXT.md files are alive. They are updated, versioned, and used every day.
4. **Simplicity wins**: A pipeline with 3 steps that works is better than one with 10 that you do not know how to configure.

The cluster is mature. Not "complete" — it never will be. But mature enough to let me work on interesting things instead of putting out fires.
