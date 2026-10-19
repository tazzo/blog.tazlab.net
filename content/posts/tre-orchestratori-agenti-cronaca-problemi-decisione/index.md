+++
title = "Three Agent Orchestrators Compared: Paperclip, Multica, Buzz, and Why I Chose a Different Path"
date = 2026-10-05T05:00:00+02:00
draft = false
description = "A practical comparison after installing and using three systems to manage AI agents in the lab: the limits of task queues in Paperclip and Multica, the multiplication of contexts and tokens, testing Buzz over the Nostr protocol, and the reasons that led me to a different solution."
tags = ["agents", "orchestration", "paperclip", "multica", "buzz", "kubernetes", "nostr", "devops"]
author = "Tazzo"
+++
> **Update (2026-10-19):** Paperclip and Buzz have both been decommissioned and uninstalled; this article is kept as a record of the comparison.


## Why I Ended Up Trying Three of Them

In the last two articles I covered the installation and use of **Paperclip** and **Multica**. Right after that, I installed and tested a third system, **Buzz**. I had not planned from the start to try three of them: I got there because each of the first two, once put to work on real lab tasks, showed practical limits that are not visible as long as you only install it.

In my lab, agents do more than write summaries: they write Kubernetes manifests, prepare Ansible roles, update documentation, and open pull requests. To work this way, I need three concrete things:

1. to understand right away what an agent is doing at that exact moment and whether it is stuck;
2. to be able to talk to the agent or course-correct it on the fly without having to restart the job from scratch;
3. not to waste time and tokens making agents re-read and re-verify the same information from zero at every small step.

This article compares the three tools across these practical points, describes how the integration of Buzz on the Kubernetes cluster went, and explains the final decision I reached.

## The First Two Attempts: Paperclip and Multica

### Paperclip: A Board of Isolated Tasks

**Paperclip** was the first experiment. I installed it in a dedicated LXC container on Proxmox (`CT108`), isolated from the rest of the network with an egress proxy (`mitmproxy`), `nftables` rules, and dedicated credentials. From a technical standpoint, the system works well: it provides a task board, assigns a budget to agents, and runs them at regular intervals.

The limitation that led me to turn it off concerns how it manages work. In Paperclip, every job is an isolated ticket assigned to an agent: there is no channel where agents can talk to each other or coordinate, and there is no way to step into a conversation while the agent is working. For simple, independent tasks it can be enough, but when work touches multiple components of the same cluster, it becomes too rigid.

### Multica: Great Integration, but Queues Multiply Tasks and Tokens

**Multica** was the next step: a control plane on Kubernetes (managed via Flux, with a PostgreSQL 17 database authenticated via mTLS client certificates and secrets injected from Vault) paired with a daemon on the `CT106` work container that runs a team of twelve agents defined in Git.

I appreciated two aspects of Multica: its clean integration with the lab's GitOps infrastructure and the fact that it has **written working rules** (states, stages, and report formats shared across the entire team). Using it every day, however, brought out two major problems.

The first, which I covered in the dedicated article, is **excessive text on the board**: every step produces very long comments (often over 3,000 characters), so figuring out at a glance who is working and who is stopped waiting for my reply requires opening individual tasks and reading all the way to the bottom.

The second problem, even more expensive, is **the consumption of tasks and tokens caused by handoffs across queues**. In a queue-based system, work is split into steps: one agent sets up the activity, then creates or passes a task into a queue for another agent to execute, which in turn opens a task for verification or publication. The critical point is that **every new task starts a new agent instance from scratch**: the agent that starts the work is not the one that continues it.

Because the new agent starts with no memory of the previous session, at every handoff it has to:

- re-read all project files and the comment history from the beginning;
- re-confirm the state of the environment;
- repeat the exact same checks already performed by the previous agent before touching anything.

Even for simple operations — such as writing and publishing a regular blog post or making a small configuration change — this chain generated a disproportionate number of tasks. The contexts to load multiplied at every handoff, and with them the tokens consumed just to do and redo the same checks multiplied as well.

## The Third Attempt: What Changes with Buzz

To overcome the problem of agents being recreated from scratch for every task, I tried **Buzz**.

Buzz takes a completely different approach: it is not a ticket board with queues, but a self-hosted **Nostr relay** where human operators and agents are members of the same chat rooms (in my case, the `#lab` channel). Every participant, human or agent, holds a cryptographic key pair and signs every message they send.

From a practical standpoint, this changes how work happens:

- **The agent stays active and replies in the channel:** it is not born and killed for a single micro-task. When I write to `@buzz-agent-1` in the channel, the agent replies right there.
- **Messages arriving while it works are not lost:** I verified this behavior by sending a second request 24 seconds after the first, while the agent was still processing the first turn. The system queued the second message (`queue_depth=1`) and the agent answered both in sequence, signing each reply with its own key.
- **Unauthorized keys are rejected immediately:** every key must be explicitly admitted to the relay and the channel. When trying to connect with an unregistered key, the relay immediately responds with a clear error (`403 relay_membership_required`), preventing it from even reading the room.

## How I Integrated Buzz and What Problems I Found

I installed the Buzz relay on the Kubernetes cluster (namespace `buzz`, exposed only on the internal network and over VPN at `ws://192.168.1.240:3010`), connecting it to a Redis pod and the shared PostgreSQL 17 cluster using client-certificate authentication exclusively (`sslmode=verify-full`).

While the database and certificates worked on the first try thanks to the work already done for Multica, the rest of the installation took considerable time for five specific reasons.

### 1. The Agent Binaries Must Be Compiled from Source

The relay has an official Helm chart, but the programs that run the agent on the work machine (`buzz-acp`, `buzz`, and `buzz-admin`) are not distributed as ready-to-download executables. I had to compile them in Rust from tag `relay-v0.2.1`, publish them in a Docker image (`tazzo/buzz-tools`) pinned by digest, and have `CT106` extract them while verifying the checksum. It is a clean solution because it avoids installing the Rust compiler on the work container, but it means maintaining a build pipeline for every update.

### 2. Three Overlapping Problems Behind a Single Silence

Once the agent was started on `CT106`, mentioning it in the channel did nothing: no reply and no clear error in the standard logs. Instead of guessing configuration settings, I ran the `omp acp` command manually, sending it the same JSON-RPC messages that the Buzz harness uses. In under a minute, three distinct causes hidden one behind another came to light:

1. **The sender filter (`respond_to`):** the initial `owner-only` setting prevented turns from starting; I replaced it with an explicit list of authorized keys (`allowlist`), which is also required if two agents need to wake each other up in the channel.
2. **No model selected:** the child process responded with a JSON-RPC error `-32603 ("No model selected")`. The Buzz harness did not print the specific message; it simply requeued the job with ten backoff retries, making it look like a hung process.
3. **The provider API key was missing from the environment:** once the model was set, the process returned `-32603 ("No API key found")`. Because keys in the lab live in `gopass` rather than in global environment variables, I configured the startup script to read the key from `gopass` into memory at launch time and refuse to start if the key is missing.

### 3. The Desktop Application and Agent Registration

The Buzz relay does not provide a web interface for reading and writing in channels: using the system requires its desktop application (built on Tauri).

On first launch, choosing the path *"I already have a community → I own the community"* caused the application to attempt a login against an external cloud service and reject the private IP address of my relay. By inspecting the application code, I found that this path is only for the hosted offering: to connect to your own server, you must instead select **"Join a community"**, enter `ws://192.168.1.240:3010`, and click **"Set up later"** on the screen asking for AI model keys (which are only needed if you create agents inside the desktop app).

Furthermore, even after the agent is online in the channel, it does not appear in the interface's agent list until the relay owner sends an explicit **attestation** command certifying that the key belongs to an agent. Until you know that, the agent simply appears not to work.

### 4. Kubernetes Node Disk Space

The first deployment of Buzz pushed the Kubernetes worker node past the 85% disk usage threshold (almost entirely occupied by container images already present on the node). Kubernetes triggered `DiskPressure` and evicted 19 Buzz pods.

The incident exposed an oversight: in my plans I had budgeted RAM for every component, but no pod in the cluster declared a temporary disk request (`ephemeral-storage`). I immediately added disk requests to the Buzz pods (2 GiB for the relay and 256 MiB for Redis) and scheduled an expansion of the node's system partition.

### 5. Duplicate Replies

During testing, the harness replied twice to several messages. It does not block work, but it clutters the channel and remained an open defect to fix before any continuous use.

## Agents Recreated Per Task vs. Persistent Agents

Putting the tests on Multica and Buzz side by side, the most important difference is not in the graphical interface, but **in the agent's lifecycle**.

| Model | How It Works | Advantages | Practical Problem Encountered |
|---|---|---|---|
| **On-demand via task queue** (Paperclip, Multica) | Every queued task starts a brand-new agent from scratch; when the task ends, the agent exits. | No dirty memory across separate jobs; formal rules for every state. | When a job is handed off across multiple agents, every task spawns a new agent that must re-read the entire context and repeat the same checks, multiplying tasks and tokens even for simple work. |
| **Persistent / resident agents** (Buzz) | The agent stays active, keeps its session, and replies directly in the channel. | The agent that starts the work can continue it; you can talk to it mid-flight without reloading everything from scratch. | Session memory must be managed so noise does not accumulate over time. |

At first, I thought spawning a clean agent for every single task was the tidiest solution. Practice proved the opposite: if publishing an article or applying a change requires passing through three or four queued tasks, and every task starts a different agent that re-reads the entire repository and re-verifies everything from scratch, the cost in tokens and waiting time becomes unsustainable.

To work effectively, I need **the agent that starts a job to be the one that finishes it**, or at least to stay active in its session until the activity is truly complete, so I can converse with it without having to re-explain the context at every step.

## Three Technical Mistakes That Do Not Depend on the Tool

Beyond the differences between Paperclip, Multica, and Buzz, three problems repeated themselves during these installations that depend on how I write configurations, instructions, and checks.

### 1. Configurations Accepted by Kubernetes That Do Nothing

This is the most insidious mistake because all status indicators stay green:

- **Names generated by Flux (`HelmRelease`):** when `spec.targetNamespace` is set on a `HelmRelease`, Flux automatically prefixes the release name with the namespace name (for example `buzz-buzz` or `multica-multica-backend`), unless `spec.releaseName` is explicitly forced. If a restart check (`rolloutRestartTargets`) or a Prometheus `ServiceMonitor` uses the short name `multica` instead of `multica-multica`, Kubernetes accepts the resource without error, but pods are never restarted when certificates renew and Prometheus collects zero metrics.
- **`NetworkPolicy` objects without a CNI that enforces them:** to isolate Buzz's Redis, I wrote and verified a `NetworkPolicy`. Instead of stopping once the resource existed in the cluster, I launched a test pod to attempt the connection that should have been blocked: the connection succeeded. The reason is that the cluster uses `kube-flannel` without a network policy controller, so all `NetworkPolicy` resources are accepted by the Kubernetes API but ignored at the network layer.

The rule I set for myself is simple: checking that a resource is `Ready` is not enough; you need a **negative test** proving that the block or effect is actually working (for example, trying to connect to PostgreSQL with a password and verifying that the server responds with `FATAL: connection requires a valid client certificate`).

### 2. How Agent Instructions Are Written

On several occasions, an agent that had finished its part stopped and waited for me instead of handing the work over to the next step. Re-reading the prompt, the cause was an ambiguous phrasing: I had written *"the owner of the assignment is the operator"*. The agent read that as descriptive information and stopped. Replacing it with a direct command (*"open the task for the subagent and wait for the result"*) eliminated the problem. With agents, a descriptive sentence is treated as context, not as an instruction.

### 3. Trusting the Report Instead of Checking the Result

On the same day, three separate times an agent stated in its final message that it had completed an operation (a channel created, a build executed, an attestation sent) that had never actually happened. For a language model, producing a plausible report is much easier than completing a command that failed silently. Verification must never be done by reading the agent's comment, but by querying the system directly (the Git commit, the database, the API response).

## The Final Decision

After testing all three systems in the field, here is where things stand in the lab:

1. **Paperclip stays powered off on standby:** the configuration remains saved in the repository in case I ever need a simple isolated board in the future, but the service is disabled.
2. **Multica has been frozen:** on October 1st I closed all tasks and emptied the workspace. From this experience I am keeping the two things that worked best — client-certificate authentication on PostgreSQL and written rules for agent roles — but I am leaving behind the task-queue model, because recreating a new agent at every handoff needlessly multiplies the contexts to re-read, verification times, and token consumption, while also producing an amount of text I cannot follow in real time.
3. **Buzz remains as a testbed for the Nostr protocol, but does not become the main engine:** the idea of resident agents in a channel with signed messages solves the direct dialogue problem, but having to recompile the harness by hand, depend on the desktop app, and deal with early client bugs makes it too cumbersome for daily use.

## Conclusions

Testing three different orchestrators in a few weeks clarified what I actually need: not a massive platform full of queues and formal handoffs, but a lightweight system where **agents stay active while working**, keep their context without having to re-read everything from scratch at every step, spend tokens doing the work rather than re-verifying what someone else already did, and leave true traceability where it has always been safest: in Git commits.

Putting these conclusions together is what led me, once the experiments with Multica and Buzz were closed, to write from scratch the resident-agent supervisor I now use in the lab (**Ambrogio**): a single Go binary that keeps agents alive over ACP, lets me talk to them directly from a web page without multiplying contexts, and enforces mechanical checks on work in code rather than in prompts.
