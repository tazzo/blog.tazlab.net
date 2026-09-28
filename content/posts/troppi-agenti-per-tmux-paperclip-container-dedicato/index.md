+++
title = "Too Many Agents for tmux: Paperclip and the Dedicated Container"
date = 2026-09-24T21:35:00+02:00
draft = false
description = "A technical account of an experiment with an agent orchestrator: why tmux is no longer enough, how I built a dedicated container with a verifiable security boundary, the errors diagnosed along the way — and the verdict: interesting, but too abstract for the way I want to run this environment."
tags = ["paperclip", "agents", "orchestration", "lxc", "proxmox", "security"]
author = "Tazzo"
+++

## The Problem Is Not the Number of Agents

The problem has never been the number of agents: it is the map. I work with five or six sessions open on different aspects of the same problem — one writes a manifest, one investigates an error, one updates the documentation. Work moves forward, but at some point you realize you have to look for *in which window* you were doing that particular thing. Every session switch costs rebuilding the context from scratch.

That is where the interest in **agent orchestrators** comes from: tools that do not merely launch processes, but keep an explicit model of who is working on what, in which role and with which expected result. Paperclip is the first one I tried: this article documents what I built, which problems I ran into, and why I am not convinced it is the way I want to run this environment.

## Paperclip: What It Promises, and Which Infrastructure It Enters

Paperclip is a web platform for managing a "company" of agents: a board with issues, agents with roles, projects, budgets and periodic heartbeats. The infrastructure I placed it in is not trivial: a Proxmox host, a Talos cluster with GitOps on Flux, a PostgreSQL database managed outside the container. The first choice, then, was not to use the embedded database (SQLite) the platform ships with, and to connect it to the cluster's PostgreSQL instead: the state of the company was not to live in a file inside a rebuildable container.

The alternatives were evaluated explicitly. Staying with **tmux** cost nothing and did not solve the map problem. Writing an artisan wrapper meant building from scratch the model of who works on what as well. An existing orchestrator brings one with it, already thought through: many parts are ready, but you accept choices that are not yours — the advantage and the risk together, because you are adopting a way of working, not just a tool.

## The Conventional Way Was Wrong for the Purpose

The first installation followed the shape I would give any service: a dedicated service account, repositories in read-only mode, no credentials in the process's hands. It is the right shape in a company; here it was wrong, and I recognized it by observing the consequences.

Paperclip exists in this lab to replace the agents that today run in tmux. Those are not spectators: they write to repositories, they push with the credentials provided by the secret store, they use the operator's SSH keys. So I moved the service to run **as the operator**, gaining functionality and losing a separation I would have liked to keep: it is the tension that runs through the whole path.

## The Platform's Traps

The installation stopped three times, always in the same way: I did what I had in mind and the system answered with something that had nothing to do with what I had asked for.

**The first agent could not be created from the interface.** I wanted an agent that used the model I already use, the one served by OpenCode: it is the CLI I know and that is already configured on this machine. The onboarding wizard, however, offered only two families of models, Claude and Codex, and its connection test could not pass, because those two CLIs are not installed here: none of the proposed choices was usable. So I checked what the installed package actually contains — it knows more than thirteen adapter types, including the one I needed. The wizard is narrower than the product it installs, and the practical consequence is that I created the agents from the command line, not from the board.

**The model identifier must be qualified by the provider**, in the form `provider/model`. Written bare, saving succeeds without a warning, and the failure arrives at the first execution, when the agent tries to start. The cost is all in diagnosis: the configuration was saved and the model existed, so there was no way to notice before trying.

**The CLI's tokens are stored per endpoint.** The login had succeeded; the next command answered `401`. It was not the credentials: the token had been saved for a specific API base, and that command was querying another one, so from the server's point of view I was not authenticated. The option has to be repeated on every invocation, and without it the error arrives looking like a permission problem.

None of the three was serious, and in all three cases the operation was accepted without errors: the problem showed up later, at the agent's first execution or on the next command.

## The Company Built from Research

Before creating a single agent I ran two research passes: one on the installed payload, to establish what the platform actually supports, and one over fifteen primary sources on multi-agent design, among them Cognition's dissenting essay, *Don't Build Multi-Agents*. The consensus is convergent: two levels at most, three to five direct reports, one writer per artifact, a read-only reviewer that is never the author, human gates on irreversible actions, budgets per agent.

Two details matter more than they seem: only the `ceo` role receives a dedicated instruction bundle, while every other role inherits a generic `AGENTS.md`; and agents have no project membership, because `reportsTo` and the lead are the only structural links.

## The Pivot: a Dedicated Container

Until that point Paperclip and its agents ran in the same container I work in, on the same checkouts, with my keys and my credentials. It is the condition in which the agents I launch by hand in tmux also run, and as long as I launch them it is not a problem: I know what I asked for and I watch what happens.

With an orchestrator the situation changes. The agents start on their own, more than one at a time, on heartbeats or on assignment, and they work on a working tree the next run will expect to find as it was. The case that made me decide is not the agent getting it wrong: it is the agent leaving something behind — a hook, a configuration, a commit — in a repository I then treat as mine. In that setup nothing separated what one run writes from what the next run reads.

So I wanted three things, and I wrote them down as requirements before deciding how to obtain them: the agents **outside** the container I work in, in a separate and expendable guest; the company's state on something that survives a container being recreated; and a **verifiable** boundary, not a convention. Hence the dedicated container, separate from the operator one.

I also considered replacing containers with a virtual machine, and the numbers produced a counterintuitive result: a VM commits memory, while a container shares it, and on this host memory is the scarce resource. A VM offers conveniences — a network device, system credentials, Docker inside — not additional security: the kernel is shared in both cases, and what changes is the blast radius of a possible escape. The separation that matters is one guest per trust domain, and that is the one I kept.

**A persistent data volume.** The container is expendable, the volume is not: the disk holding the instance state — the key that encrypts the secrets in the database, the configuration, the run logs — is a separate volume, and the destroy procedure detaches it before deleting the container, so that Proxmox does not delete it along with the rest; whoever recreates the container reattaches it by name: recreating the container does not mean losing the instance state.

**A secret store with a narrow scope.** The agent has its own store, encrypted with its own key, read-only, holding only the secrets it needs. The key has no passphrase, because a service that starts on its own cannot type one: what protects the store is not the key but the scope. An automatic test at startup verifies that the operator's entries are not readable from there, and if it fails the service does not start.

**The chokepoint.** It is the central component of the project, and it is not a Paperclip feature: it answers the problem of giving an agent access to external services without handing it the credentials.

## How the Chokepoint Works

A local proxy ([mitmproxy](https://mitmproxy.org/)) listens on `127.0.0.1:3128` inside the container, and the agent's environment is configured so that all HTTP and HTTPS traffic goes through it. The proxy is not a transparent hop: it consults a list of allowed destinations and, for some of them, injects the credential in the agent's place. The push token toward GitHub and the one for the virtualization API do not exist in the agent's environment: they exist only in the proxy's memory, which adds them to the outgoing request and removes the authorization header sent by the client.

The second element is the packet filter, and it is what turns the proxy from a convention into a boundary:

```bash
# Only the proxy's uid gets out. The agent's uid does not.
meta skuid 0 accept                 # root: the operator's identity, not the agent's
meta skuid <proxy-uid> accept
ct state established,related accept
counter drop                        # everything else
```

The agent has neither root nor sudo, so it cannot take on the identity that is allowed out; the acceptance test is of the negative kind and checks exactly this. The third element is the consequence of the second: if the proxy is down, the agent has no way out. It does not degrade into "agent reaching the internet directly", but into "the agent's calls fail": that is the meaning of *fail-closed*, and it requires the boundary to live in the kernel.

## The Errors That Taught Something

**The seal that blocks its own repair.** The agent's store is read-only by choice: the agent must be able to read its own credentials, not write them, and the flag that seals the store is applied at the end of provisioning. The step that copies the secrets treats a missing **or empty** entry as one to repair, so that a second run fixes a value left empty instead of inheriting it; but on the second run the store is already sealed, and the insert dies on the seal itself: `writing to agent is disabled by core.readonly`. The fix is to unseal for the duration of the write and re-seal right after. The step stays idempotent because it acts only when there really is an entry to write, and it rewrites the flag only if the current value differs from the expected one.

**systemd credentials are not available in an unprivileged container.** The initial choice was to hand the key to the service as a [systemd](https://systemd.io/CREDENTIALS/) credential: a read-only file, verified on every read, not inherited by child processes. In this container the service would not start. The diagnosis was built with a temporary unit, a single directive and a trivial consumer:

```bash
LoadCredential=probe:/etc/hostname
ExecStart=/bin/sh -c 'wc -c < $CREDENTIALS_DIRECTORY/probe'
# → Failed to set up credentials: Protocol error
#   Main process exited, status=243/CREDENTIALS
```

The file existed and the consumer was elementary: the cause was the environment, not the configuration. From there came the choice to hand over the key as a path, with the fail-closed constraint preserved.

**apt does not download as root.** The filter I had written let root out and stated in a comment that this was sufficient for apt to work. It is false: apt delegates downloads to the sandbox user `_apt`, so the socket leaving the container belongs to that user, and the rule for root did not cover it. The symptom was provisioning stuck for twenty minutes, without a line of error. The cause emerged by reading the dropped-packet counter in the filter's ruleset, which had gone past a thousand: that counter is the first thing to examine when the network "does not work".

**The token's value contained the token.** The agent's token toward the virtualization API answered `401` on every call. I isolated the problem by creating a probe token on the same user through the API: it answered `200`. User, header and privilege separation were correct; what remained was the value, and it was wrong because the provider returns the pair `<id>=<secret>`: I was handing the proxy a string with the id twice. A `401` that looked like a permission problem was a format problem, and isolation by difference is what made it visible.

**The store emptied twice, and recovered from history.** At some point all the company's credentials in the operator's store turned up empty, with an unmistakable signature: an empty value is stored as an attachment with no body, so the read answers "no password" instead of failing. I recovered them from the store's git history, and the lengths matched the originals: the versioned repository is also the store's only safety copy.

## The Verdict: Too Abstract

Paperclip is interesting and in some situations useful: a real board, real roles, budgets, heartbeats. I am not convinced, though, that it is the way I want to run this environment, and the reason is precise: it is too abstract, too far from understanding what is happening and which decisions are being taken. On startup it had already done some work: some of it correct, some of it I am not convinced about. The problem is not that it gets things wrong, but that its reasoning is not visible, and therefore not correctable before it produces effects.

I will keep trying it, and I will try other tools of the same kind too: the next one will be Multica. The question I am trying to answer does not concern a specific product, but which tool allows me to keep many agents on different aspects of the same problem without losing the map and without losing visibility into the decisions.

## Conclusions: What Remains Even If the Tool Is Not Enough

Two considerations hold regardless of which orchestrator gets adopted.

The security boundary is transferable. Keeping the credentials outside the boundary, injecting them at the edge, restricting egress by identity and failing closed does not depend on the tool: it is a pattern built around Paperclip and reusable with the next one.

Almost all the defects described emerged at the first real execution: code review had let them through.

If you are evaluating an agent orchestrator, the question I suggest is not how many agents it can manage, but what it lets you see and who decides. In my case the abstraction removed what I really needed: understanding what it was doing and why.
