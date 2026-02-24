+++
title = "Mnemosyne Rebirth: Chronicle of a Sovereign Memory (and how I collided with the MCP protocol)"
date = 2026-02-22T18:05:00+01:00
draft = false
description = "Technical chronicle of the Mnemosyne MCP server refactoring: from custom implementation to the official SDK, resolving GitOps deadlocks and network buffering issues."
tags = ["mcp", "go", "kubernetes", "gitops", "flux", "ai"]
author = "Tazzo"
+++

## Introduction: The Paradox of the Ephemeral
In a nomadic and "Zero Trust" ecosystem like **TazLab**, the development environment (**TazPod**) is ephemeral by nature. Upon closing the container, every trace of activity vanishes, except for data saved in the encrypted vault. This volatility, while excellent for security and system cleanliness, introduces a fundamental problem: AI agent amnesia. Every new session is a blank slate, a tabula rasa where the artificial intelligence has no memory of the architectural decisions made yesterday, the bugs resolved with effort, or the project's strategic directions.

I decided that TazLab needed a long-term semantic memory, a "technical conscience" residing within the infrastructure itself. This project was named **Mnemosyne**. The goal of the day was ambitious: abandon unstable Python bridges and implement a native server based on the **Model Context Protocol (MCP)**, integrated directly into the **Gemini CLI**, to allow the AI to consult its own technical past in a fluid and sovereign manner.

---

## Phase 1: The Cloud Mirage and the Return to Sovereignty

Initially, my strategy for Mnemosyne relied on **Google Cloud AlloyDB**. The idea of delegating vector persistence to an "Enterprise" managed service seemed like the safest and highest-performing move. AlloyDB, with its `pgvector` extension, offered enormous computing power for semantic searches.

**Conceptual Deep-Dive: AlloyDB and pgvector**
*AlloyDB* is a Google Cloud PostgreSQL-compatible database optimized for intensive workloads. It is a VPC-native service, meaning that for security reasons, it does not normally expose a public IP but requires a private connection within the Google cloud. *pgvector* is the extension that allows storing "embeddings" (numerical vectors representing text meaning) and performing similarity searches using the cosine distance operator (`<=>`).

However, I quickly collided with operational reality. To access AlloyDB from the TazPod on the move, I had to configure the **AlloyDB Auth Proxy**, a binary that creates a secure tunnel to GCP. Within a Docker container, this proxy created zombie processes and suffered from unpredictable latencies. Furthermore, the GCP firewall required dynamic IP unlocking via scripts (`memory-gate`), creating constant friction that betrayed the agile nature of the lab. Every time I changed connections (moving from home Wi-Fi to a mobile network), my semantic memory became unreachable until I manually updated the network rules.

I therefore decided to change course: true digital sovereignty requires that data resides on my own hardware. I migrated Mnemosyne to a **local PostgreSQL** instance hosted in my Kubernetes cluster (Proxmox/Talos), using the Postgres Operator for lifecycle management. This choice not only zeroed out cloud costs but made the memory an integral part of TazLab's "iron," making it transparently accessible via the Wireguard VPN integrated into the TazPod.

---

## Phase 2: Genesis of a Native Go Server

To connect the Gemini CLI to the Postgres database, I needed a bridge that spoke the MCP language. Initially, I used a Python script acting as a bridge, but the interpreter's startup latency and dependency fragility pushed me toward a more professional solution: a server written in **Go**.

I chose Go for its ability to generate tiny static binaries, perfect for Google's **Distroless** images. A Distroless image contains no shell or package manager, drastically reducing the pod's attack surface in Kubernetes. The server had to be hybrid to support two use cases:
1.  **Stdio Transport**: For rapid local development, where the CLI launches the binary and communicates via standard input/output.
2.  **SSE Transport (Server-Sent Events)**: For production, where the server exposes an HTTP endpoint in the cluster and the CLI connects as a remote client through a MetalLB LoadBalancer.

**Conceptual Deep-Dive: Stdio vs SSE**
*Stdio* transport is the simplest way to let two processes communicate on the same host: JSON-RPC messages pass through system file descriptors. It is extremely fast but limited to the local machine. *SSE* transport, on the other hand, is a unidirectional protocol over HTTP that allows the server to send "events" to the client. In the MCP protocol, SSE is used to keep an asynchronous response channel open from the server to the AI, allowing for multi-user and distributed integrations.

---

## Phase 3: The Trail of Failures

The transition to a native server was not without obstacles. In fact, I encountered a series of bugs that required almost forensic investigation.

### The Deadly Quote Bug (Error 400)
After the first deployment, every semantic search returned a laconic `embedding API returned status 400`. I checked the server logs, but the Google error body was not displayed. I suspected everything: from the embedding model (`gemini-embedding-001`) to the JSON format.

After implementing more aggressive logging that captured the HTTP response body, I discovered the absurd truth: the secrets file in the TazPod (`/home/tazpod/secrets/gemini-api-key`) contained the key enclosed in **single quotes** (`'AIzaSy...'`). These quotes had been included by mistake during a copy-paste operation. Google's APIs received the quote as part of the key, invalidating it. I resolved this by physically cleaning the file with `sed` and adding a sanitization function in the Go code to make the server resilient to similar human errors:

```go
// Aggressive key cleaning (removes quotes and spaces)
apiKey = strings.Trim(strings.TrimSpace(apiKey), ""'")
```

### Silence is Golden (Stdio Discovery Failure)
Another unexpected behavior occurred at Gemini CLI startup. Although the server was correctly configured in the `settings.json` file, the CLI reported `No tools found on the server`.

Investigating the debug logs, I realized that the Stdio protocol is extremely fragile: any character printed to `stdout` that is not part of the JSON-RPC breaks communication. My server was printing welcome logs via `fmt.Printf`. These logs polluted the stream, causing the Gemini CLI client's JSON parser to fail. I had to make the server **totally silent** in Stdio mode, redirecting every diagnostic log to `stderr`.

```go
// Before (WRONG):
fmt.Printf("🚀 Server starting...")

// After (CORRECT):
fmt.Fprintf(os.Stderr, "🚀 Server starting...")
```

---

## Phase 4: Surrendering to Standards (SDK Refactoring)

After hours spent manually writing JSON-RPC message handling and SSE channels, I had to admit an error of pride: reinventing the MCP protocol from scratch was complex and prone to concurrency bugs. For example, my server lost messages if the client opened multiple simultaneous sessions with the same ID.

I decided to refactor everything using the official community SDK: **`github.com/mark3labs/mcp-go`**. This meant rewriting the entire tool manager, but it brought immediate benefits in terms of stability. The SDK natively handles SSE data "flushing," ensuring that messages do not remain stuck in the server's buffers.

However, the challenge did not end there. During the automatic build on **GitHub Actions**, the produced image continued to show logs from the old code. After checking every line, I identified a **Module Naming** problem. The Go module was named `tazlab/mnemosyne-mcp-server`, but the real repository on GitHub was `github.com/tazzo/...`. Go, during the cloud build, failing to resolve internal packages as local files, downloaded old versions of the code from remote branches instead of using the ones just committed. I corrected the module structure to align with the real GitHub path, forcing a clean build.

---

## Phase 5: The GitOps Deadlock (When Flux lies)

The final hurdle was cluster deployment. Despite correct commits and the GHA build passing, the pod continued to run with the old v14 image. Flux CD reported `Applied revision`, but the cluster's live state was frozen.

**Conceptual Deep-Dive: GitOps and Flux CD**
The *GitOps* philosophy mandates that the Git repository is the sole "source of truth." *Flux CD* monitors Git and applies changes to the cluster. However, if a resource fails Kustomize validation, Flux stalls to avoid corrupting the cluster state.

I investigated with `flux get kustomizations` and discovered a **Dependency Deadlock**. The `apps` kustomization (which manages Mnemosyne) was blocked because it depended on `infrastructure-configs`, which in turn was in error due to a malformed YAML in the Mnemosyne manifest. Inadvertently, I had introduced an indentation error in the `env` block of the Mnemosyne manifest during a hectic Git `rebase`. This error prevented the Flux controller from generating the new manifests, leaving the old v14 version running.

I resolved the deadlock by cleanly rewriting the manifest and forcing a cascading reconciliation of the entire chain:

```bash
export KUBECONFIG="/path/to/kubeconfig"
# Unblocking the dependency chain
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization apps --with-source
```

---

## Phase 6: Final State: "1 MCP Loaded"

After resolving the indentation error and forcing Kubernetes to download the fresh image with the `imagePullPolicy: Always` policy, the moment of truth arrived.

Launching the `gemini` command, the CLI finally displayed the message: **"1 MCP loaded"**.
Mnemosyne was alive. I tested the `list_memories` tool and saw my technical memories from the last few months appear, retrieved from the local Postgres database via the SSE protocol.

**Final MCP server snippet (Go SDK):**
```go
func (s *Server) registerTools() {
	// Tool for semantic search
	retrieve := mcp.NewTool("retrieve_memories", mcp.WithDescription("Search semantic memory"))
	retrieve.InputSchema = mcp.ToolInputSchema{
		Type: "object",
		Properties: map[string]any{"query": map[string]any{"type": "string"}},
		Required: []string{"query"},
	}
	s.mcp.AddTool(retrieve, s.handleRetrieve)
}
```

---

## Post-Lab Reflections: Toward Resilient Knowledge

This work session was a true technical marathon of over 4 hours. I learned that architectural simplicity (returning to local Postgres) almost always wins over the complexity of managed cloud services, especially in a laboratory context. The transition to the standard SDK transformed Mnemosyne from a fragile experiment into a solid infrastructural component.

What does this mean for TazLab? Now my development environment is no longer amnesiac. The AI agent can finally say: "I remember how we configured Longhorn three weeks ago" or "This is why we chose that specific MetalLB policy." Memory is sovereign, resides on my hardware, and speaks a universal protocol.

### What I learned in this stage:
1.  **The importance of standards**: Using an official SDK (like mark3labs') saves hours of debugging on protocol details such as SSE flushing and session ID management.
2.  **GitOps Vigilance**: Never trust a global "Reconciliation Succeeded" if a downstream component does not respond. A silent YAML error can freeze the entire cluster.
3.  **Secret Sanitization**: A single quote in a text file can be more destructive than a complex logic bug.

The Mnemosyne mission continues. The next objective will be automated knowledge distillation, ensuring that every session is archived without human intervention, transforming every log line into an atomic fact for the future.
