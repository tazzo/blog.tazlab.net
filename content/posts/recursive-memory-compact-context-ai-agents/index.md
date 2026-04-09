+++
title = "Recursive memory, compact context: the missing piece for working well with AI agents"
date = 2026-04-10T08:00:00+00:00
draft = false
description = "After the AGENTS.ctx context system, I added a recursive memory layer that keeps agents aligned on the present without letting context grow forever. A technical chronicle about how it works, why it matters, and what it actually changes in day-to-day work."
tags = ["AI", "Agents", "Memory", "Context Management", "Workflow", "DevOps", "Productivity", "Architecture"]
categories = ["AI", "Architecture", "Productivity"]
author = "Taz"
+++

# Recursive memory, compact context: the missing piece for working well with AI agents

## The problem after solving the problem

A few weeks ago I had written an article about **AGENTS.ctx**, the context system I use to work with AI agents without having to explain everything again from scratch every time I open a new session. The basic idea was simple: instead of opening an empty chat and manually reinjecting rules, project structure, operating conventions, and the general state of the work, I organized everything into contexts that can be loaded on demand. The agent does not change: the context I make it read does.

That solution worked really well. Not in theory, but in day-to-day work. I open the `tazpod` context, and the agent immediately knows how the CLI is structured, which paths are critical, how to push to GitHub, and where the operational risks are. I open `blog-writer`, and the agent already knows how to plan an article, how to move to writing, and when to stop for review. I open `crisp`, and the whole rhythm changes: no implementation, only research and design.

The point, however, is that once the operational bootstrap was solved, a second problem emerged. More subtle than the first one, but just as important. Contexts explain **how** to work in a certain domain. They do not always explain **where we are today**, **what happened in the latest sessions**, **which debts are still open**, **what the current truth of the system is**. For work that lasts weeks or months, that distinction matters a lot.

In other words: contexts had given me the frame. I was still missing an active memory, continuously updated, compact enough to always stay within reach but rich enough to let an agent resume immediately from the right point.

## Why “having more memory” was not enough

When working with LLMs and coding agents, the first reaction to continuity problems is often instinctive: keep as much as possible. Longer transcripts, more notes, more files, more logs, more summaries. On paper it looks like a good idea. In practice, it almost never is.

The problem is not only quantitative. It is structural. If active memory grows without control, sooner or later it stops being a tool and becomes noise. An agent that has to read too much material before becoming operational is not really aligned: it is simply overloaded. The bootstrap cost starts rising again, only in a different form. I am no longer manually re-explaining things, but I am forcing the system to digest an increasingly large block of heterogeneous context.

This is the same problem I had already tried to avoid when designing AGENTS.ctx: **do not load everything, load only what is necessary**. That same philosophy had to be extended to memory as well.

So the question was not: how do I give the agent more memory? The correct question was: how do I build a memory that stays **operational**, **readable**, **dense**, and does not degrade as the project moves forward?

## The next step: an active, recursive memory that always stays small

The solution I built is simply called **`memory`**, and it has become the active continuity layer inside `AGENTS.ctx`. It is not an external database. It is not an opaque system. It is not some magic feature of the model. Once again it is a structure of simple files, versioned in Git, readable by any agent that can read Markdown.

But the difference from static contexts is fundamental: `memory` is not just a set of rules. It is a **living memory** that changes over time and keeps track of the present in a disciplined way.

The current model is organized like this:

- `system-state.md`
- `debts.md`
- `past-summary.md`
- `chronicle.md`
- `past/`
- `scripts/archive-memory.sh`

At first glance this may look like just another documentation folder. In reality it is a system of very precise roles, and the precision of those roles is exactly what makes it useful.

## The role of the files: not an accumulation, but a hierarchy

The first important decision was to avoid the single omnivorous file. If everything ends up in the same document, the distinction between current state, chronology, technical debt, and historical summary breaks within a few sessions. At the beginning it may seem convenient. After a few days it becomes unmanageable.

That is why each file has a strict responsibility.

### `system-state.md`: the truth of today

This file exists to answer one question only: **what is true now?** Not what was true three days ago, not what was decided in a design discussion, not the full detail of the troubleshooting. Only the current operating doctrine.

This is where I put the things that, if I open a new agent, I want it to know immediately without digging:

- what the current TazPod model is,
- which important caveats exist,
- how the CI pipeline works right now,
- what role the various system layers play,
- which components are considered sources of truth.

The purpose of `system-state.md` is not to narrate the past. It is to condense the present.

### `debts.md`: what is not solved

At a certain point I also split technical debt into its own file. This was an important correction that emerged from real use. At the beginning it is very easy to mix open problems into chronology or into state. But those are different things.

A technical debt is not just an event from the past. It is an active tension still present in the system. It needs to stay visible in structured form. That is why `debts.md` became the canonical register of everything that is open, in progress, deferred, or to be closed later.

In practice, when I reopen a session, I do not only want to know what has been done. I want to see immediately **what is still missing**, **where the risks are**, **which problems I cannot afford to forget**.

### `chronicle.md`: recent causal continuity

This is the diary of the current cycle. It is not a compressed historical summary, and it is not doctrine. It is the narrative layer that keeps together cause and effect from the latest sessions.

This is where the answer lives to the question: **how did we get to where we are?**

That distinction matters. State alone is not enough. If I open an agent and tell it that today the system works in a certain way, the “why” is often missing. And without the why, it becomes much easier to break something in the next session.

Chronology exists for exactly that reason: preserving the recent chain of events, problems, fixes, and consequences.

### `past-summary.md`: compression of the useful past

This is probably the most interesting piece in the entire system. Because the problem is not only keeping a recent memory. It is doing that without losing the past and without loading all of it every time.

`past-summary.md` is the compressed layer of older history. It does not go into every detail. It should not. Its job is to provide high-density historical orientation: major decisions, architectural pivots, motivations that still matter today.

It is long-term memory, but still immediately usable.

### `past/`: the recursive archive

And here is the part that, for me, makes the system genuinely interesting. The past is not deleted. It is **archived recursively**.

When the active cycle crosses a threshold, the system does not just “clean up.” It moves the root files into `past/`, preserves the structure, and then regenerates a clean active root. If in the future I need to reconstruct what happened more deeply, I can dig back one layer at a time.

This is a very important feature of the model. What I have immediately in hand is only what I need now. But if I need to understand what happened in more depth, I can do so by moving backward gradually, without turning the active root into an infinite archive.

## Why recursion here is not a theoretical flourish

Saying “recursive” can sound like the kind of technical word used to make something look elegant. In reality, here it is a very concrete choice.

In a traditional linear memory there are usually two common outcomes:

1. either the file grows without control,
2. or the past gets cut brutally and continuity is lost.

I wanted to avoid both. Recursion lets me preserve everything **without having to keep everything loaded on the same operational plane**. It is a subtle but decisive difference.

The active layer stays compact. The past does not disappear. It is simply moved into a less immediate historical layer. If I need it, I reopen it. If I do not, it does not pollute the current read.

This approach also has a very practical effect on the way I work: when I reopen an agent, it does not have to walk through weeks of history to understand what to do. It reads the active root, and only if the problem requires it does it go deeper.

It is stratified memory, not bloated memory.

## The archive model: keeping memory alive without letting it explode

To make this model sustainable it was not enough to split files. I also needed a disciplined mechanism to prevent the active root from growing forever. That is why I introduced an explicit archive flow managed by `scripts/archive-memory.sh`.

The logic is this:

- when active chronology crosses a threshold,
- or when an important milestone is completed,
- or when I decide to force an archive,
- the current cycle gets archived,
- the root memory gets regenerated,
- and work starts again from a compact base.

This part mattered not only as an idea, but as a real implementation. I was not interested in having an elegant model on paper. I wanted to verify that, when memory actually had to be archived, the behavior was clean: files moved correctly, summary regenerated, new chronology minimal, no useless logs polluting the workspace.

That is why I also executed a **real forced archive**, not just a theoretical review. It was an important step, because it turned the design into verified behavior.

## The system was not born perfect, and that is a good thing

One of the things I find most interesting about this work is that the system did not emerge as a single “brilliant” solution. It was corrected as I used it.

The first version of the model was already useful, but its boundaries were still too soft. Some responsibilities were mixed together. Some historical information ended up in the wrong place. The risk was the classic one of documentation systems: they start organized and gradually fall back into chaos.

The most important corrections came precisely from real use:

- technical debt was split into `debts.md`,
- chronology was cleaned up until it truly became chronology,
- state was narrowed down to “truth of today,”
- `past-summary.md` became a first-class artifact,
- the archive contract was made more precise,
- validation was done with a full cycle, not just with common sense.

For me, this is a sign of system health. A useful workflow is not the one that looks perfect in its first sketch. It is the one that survives contact with real use and survives revisions without losing coherence.

## Memory and Mnemosyne: two memories, two different uses

There is a distinction here that I think is worth making very explicit, because from the outside it could look redundant.

I already have **Mnemosyne**, which I use as historical memory and semantic retrieval. So why build `memory` as well?

Because they serve two different things at two different moments.

### Mnemosyne: search by meaning

Mnemosyne is useful when I do not remember exactly **when** something happened, but I remember **what it was about**. For example:

- “when did we already see a similar CI problem?”
- “had we already discussed that Gemini quota issue?”
- “in which session did that Hetzner trade-off emerge?”

That is semantic search. It is extremely powerful, but it does not replace active context.

### Memory: know where we are now

`memory` is useful instead when I open the terminal and want to resume immediately. I do not want to search semantically through the past. I want to know:

- what is true today,
- what is still open,
- what happened recently,
- what the active baseline is from which to continue.

It is chronological and operational memory. It is not retrieval. It is continuity of work.

That is why I consider `memory` and Mnemosyne complementary, not competing. One is for **resuming**. The other is for **finding again**.

## What this actually changes in day-to-day work

The most interesting part is not the architecture itself, but the change in rhythm it creates.

When a workflow like this works, something very simple and very hard to achieve happens: I reopen an agent, and it already knows where we were. Not in a vague sense. Not in the sense that “maybe it remembers something.” It really knows what stage of the journey we are in.

This drastically reduces the cost of reopening sessions. And it also reduces another form of friction that, at first, I had underestimated: the mental energy spent reconstructing context. Every time I have to stop and manually summarize the state of a project, I am wasting part of my attention on an administrative task instead of on the actual technical problem.

With `memory`, that reconstruction is already there. And above all, it is there in a form small enough to remain useful.

## The future direction: simplify even further

There is also an architectural consequence that I am seeing more clearly now that the system has started working well: the final model should probably become even simpler.

My long-term goal is to have essentially **two layers only**:

- **`memory`** as chronological, current, recursive memory,
- **Mnemosyne** as semantic memory and search.

Everything else should progressively converge there. Not because the intermediate history was not useful, but because a model that can be explained in two sentences is almost always more robust than one with too many transitional layers.

That does not mean throwing away the past. It means absorbing it into a clearer structure.

## Post-lab reflections

If I had to summarize the meaning of this work in one sentence, I would put it this way: after building contexts, I needed a way to never truly start from zero again. Recursive memory was that missing piece.

I did not want infinite memory. I wanted memory that is **always ready**. I did not want an accumulation of notes. I wanted a system that clearly separates state, debts, chronology, and compressed past. I did not want to lose history. I wanted to be able to dig into it only when necessary.

The result, at least so far, is very convincing. Contexts continue to do their job: they provide rules, structure, addressing, and operational specialization. Memory adds the temporal continuity that was missing. Mnemosyne remains the semantic retrieval layer, useful when I need to search the past by meaning.

They are different problems, but two of them are now converging toward a cleaner form: an active, recursive memory with controlled size, and a semantic memory for historical search.

For the way I work, alone, with different agents and long-running projects, this is not an organizational detail. It is a change in the quality of the workflow. I open the terminal, reopen the agent, and the system already knows where to resume from. Not everything. Only what is needed. And that is exactly the point.