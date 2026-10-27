---
title: "Ada: a house of agents that does not fall asleep"
date: 2026-10-28
draft: true
tags: ["agents", "ada", "podman", "systemd", "debugging", "observability"]
---

> Working material for the Ada article (nothing written about it so far). Facts measured on the
> night of 27–28 October 2026, with the numbers that actually mattered.

## What it is

Ada is a **house**: a durable engine (Node 24 + TypeScript, SQLite) and a team of agents sharing one
database and one machine. Not "a chatbot": an administrator (Ada), an engineer (Enrico), a researcher
(Renato), an organizer (Orfeo), a designer (Debora), plus engineers created at runtime (Teo, Alice).
Each has a role, a tool set and a written mandate.

The night's move: from **LXC on Proxmox** to a **Podman container on a Hetzner VM**, losing neither
the database nor the way to govern it.

## The installation mistake (the root of everything)

The code had been copied **into the image** (`COPY app/ /app/`). It sounds right in an immutable
world, but for an agent that **edits its own code** it is wrong: a restart reloads the same image,
therefore the same commit. Nine restarts changed nothing, and it looked like "the container does not
restart". In the LXC the code lived on the **volume**: `git checkout` + restart = new code.

Hence the correct design, which Ada herself had already written in a commit:

> **code in a volume, image only for the environment.**

## The night's seven failures (with numbers)

1. **Code in the image** → no deploy possible (nine restarts, zero effect).
2. **`gopass show -o` truncates multi-line secrets** → Vault's CA arrived as a 27-byte header; VSO:
   *no valid certificates found*. The CA was there; the flag was wrong.
3. **The engine runs the working tree, not the commit** → a half-written `src/restart.ts` (an import of
   `liveRestartUnits` that did not exist) killed it on import. From outside: "the container does not
   restart".
4. **One roster row without a conversation id killed `/agents`**:
   *Document pi.live requires a conversation ID* → the panel lost every channel, and Teo's page
   answered 500 (which is why he "said nothing").
5. **`request_restart` lied**: *"interrupted and may have partially run"*, zero boot lines.
6. **Queue pump with no ceiling**: **4560** lines of `told an idle orchestrator it has work ready`; and
   the deploy lock armed for **90 minutes** with its 30-minute valve never firing.
7. **`.backup` livelock**: on a database being written the copy restarts at every commit and never
   finishes; the deploy hung in the snapshot (same root as the flood).

Around them: **363 `tool failed`**, **41 `stop=error` turns** without the cause in the log, **72**
recorded health failures and **28** automatic recoveries.

## What exists now

- **Home on a volume** (`/srv/ada/prod/home` → `/home/ada`); image `ada-env` with node, git, sqlite3,
  curl, poppler, **systemd**.
- **systemd inside the container**: `ada.service` (engine) + `ada-hubd` (supervisor). Restarting your
  own process is a command, not an external intervention: pid 198 → 266 → 851, container untouched.
- **A restart channel that cannot lie**: `touch /home/ada/data/.restart` → path unit → restart.
- **Deploy with an external verdict** (host side): health names the commit, ≥5 agents, `quick_check`,
  and **a real turn with a marker**; if one is red, roll back to the commit that was running, and the
  candidate stays on `wip/<sha>`. It refuses a dirty tree: `refused: dirty tree`.
- **An independent guard**: `ada-guard.timer` every 2 minutes.
- **Ada can delegate**: `subagent` (cap 1+4) and her children are **read-only** — verified:
  `read, recall, list_agents, agent_status, journal, skill_list, skill_read, catalog_document,
  find_document, documents_list, search_history`; **no bash, no write, no edit**.
- **`inspect`: the readers' raw eyes** — git, journalctl, a forced read-only SELECT, local HTTP. A
  closed command list, **no shell**: looking cannot become touching.
- **Settings API**: `GET/POST /agents/:name/settings` → role mandate, live/pending caps, limits.

## The "no-silence" contract (the article's core)

Five invariants born from the failures:

1. **No wait without an owner and a deadline.** An agent idle with open work is a fault.
2. **No tool may lie.** The verdict comes from the world: a boot line, a result file.
3. **Every loop has a ceiling and a backoff.** 4560 notifications are not a system talking: it is noise.
4. **A failing gate names the blocker** (`tests/deploy.ts: 13 vs 0`), not "48 errors".
5. **Whoever gives up says so, with a receipt.** Inert `escalated` is not a decision.

And the architectural consequence: **one actor does the switch** (the host); the agents write the code.
Two supervisors with two ideas of "what is running" are the bug, not the cure.

## Still open (the next episode)

- The **settings menu** in the panel (API ready): mandate visible and editable, caps by hand.
- **Log discipline**: `stop=error` with a cause, `tool failed` with the error, `turn done` in one line,
  `restart-announced` once per commit instead of every boot.
- The engineers to be **unfrozen** for the operator's work (teaching, halloween).

## The sentence to keep

> It was not the model. It was the context: what an agent sees, what it may touch, and how wide its
> blast radius is. A good agent in a room with three actors and one shared tree looks stupid; the same
> agent, isolated, with an external verdict and a deadline, looks like a colleague.
