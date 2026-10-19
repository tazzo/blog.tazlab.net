+++
title = "Ambrogio 0.1: Why I Wrote My Own Agent Supervisor from Scratch (and the Problems of Day One)"
date = 2026-10-06T06:00:00+02:00
draft = false
description = "How Ambrogio was born after testing Paperclip, Multica, and Buzz: a single Go binary with SQLite and resident agents over ACP, and the real problems faced in the first 24 hours between processes stopping mid-way and the Proxmox node saturated by headless browsers."
tags = ["ambrogio", "agents", "orchestration", "golang", "sqlite", "proxmox", "lxc", "devops"]
author = "Tazzo"
+++

## Where the Idea for Ambrogio Came From

After testing Paperclip, Multica, and Buzz in sequence, I finally had a clear picture of what did not work for the way I operate in the lab.

With ticket-queue systems like Multica, every handoff created a new task and started a brand-new agent from scratch: the agent that started the work was never the one that finished it, and at every step the newcomer had to re-read the entire repository and repeat the same checks, burning a huge amount of tokens even for trivial tasks. With Buzz I had seen the advantage of talking to agents already present in a channel, but carrying around a Nostr relay, a client that had to be recompiled in Rust, and a mandatory desktop application was too cumbersome.

So on October 1st I decided to close the external experiments and write a tool tailored to the lab from scratch: **Ambrogio**.

## Architectural Choices of Version 0.1

For the first version (`0.1`), I set a few very simple rules designed to eliminate the complexity of the previous tools at the root:

1. **A single Go binary on the work container (`CT106`):** no scattered microservices, no extra containers to orchestrate, and no external dependencies. A single process that starts in a fraction of a second and owns a single working directory.
2. **Resident agents managed over the ACP protocol (`omp acp`):** instead of spawning and killing an agent for every micro-task, the supervisor keeps agent processes active in the background. When I assign a task or ask a question, I talk to the same agent that already holds the session context in memory.
3. **A single conversation interface:** in the web page I talk in a single chat with **Ambrogio**, which acts as the entry point. The other agents work behind the scenes on assigned tasks and appear on the page as ongoing activity, without forcing me to chase ten different chat rooms.
4. **A single SQLite database opened exclusively by the hub:** the state of agents, issues, and permissions lives in a local SQLite file. No external script and no web page can read or write that file directly: **everything must go through the hub's HTTP API** (used in the exact same way by the terminal, the MCP bridge, and the web page).

This structure allowed me to have the system up and running in a single day. On the second day, however, we stopped "building" it and started using it for real, closing over a hundred issues in one session. That is where the first real problems came out.

## Four Problems That Surfaced on Day One

### 1. Two Places Answering the Same Question with Different Numbers

As soon as I opened the web interface under a real workload, I noticed the numbers did not add up: the counter in the sidebar showed one number of active agents while the main list showed another; an issue that was already closed kept re-sending a wait request every five minutes; and the program's version number changed on its own without recompiling the binary because it was read from Git at runtime.

The cause was always the same: instead of reading data directly from the SQLite database when needed, parts of the program kept in-memory copies or counters that ended up drifting out of sync. The rule I set from that moment on is that **truth lives only in the database row and is read on the spot**, without keeping duplicate state in RAM.

### 2. Interface Defects That Code Tests Cannot See

All automated API tests passed cleanly, but using the web page in the browser immediately exposed errors that were as trivial as they were blocking:

- the text box (`textarea`) for typing messages did not inherit the light text color from `body`, so it wrote in black on a dark background, making it invisible;
- clicking certain menu items changed the address in the browser bar (`location.hash`), but left the view stuck on the previous screen;
- clicking an agent's name in the list always opened the main Ambrogio chat instead of that agent's detail view.

No backend test can notice that text is black on a black background. Hence the practical rule: **a change is verified where it is read by the user**, by opening the real page, not by stopping once the API returns `200 OK`.

### 3. Agents Stopping Between Turns

With 14 configured agents and a maximum limit of 4 (later raised to 7) concurrently active agents, work moved in fits and starts: an agent would complete a single step, enter the `waiting_for_operator` state, and stop there, even when it still had an open issue to finish. In a single session I had to wake agents up by hand six times to keep the queue moving.

The problem was that I had left it up to the AI model to decide when to move on to the next task. I solved this by moving that logic directly into the supervisor's Go code:

- if a worker has an open issue, is not currently running a turn, and is not blocked waiting for a permission, an **internal timer (tick)** automatically sends it the command to continue;
- if there is an unowned open issue and a free agent, **assignment happens mechanically in code**, picking the oldest issue first.

Everything that is purely mechanical belongs in the supervisor's code, not in instructions given to the model.

### 4. The Memory Incident on CT106 That Nearly Froze the Proxmox Node

The most severe problem of the day did not come from Ambrogio's Go code (which used very little memory), but from child processes spawned by the agents.

During interface testing, the agent runtimes had left dozens of **headless Chromium** processes open, consuming **4.27 GB of RAM** on their own. Container `CT106` hit its 8 GiB RAM limit and filled its 1 GiB swap to 100%; the kernel page cache dropped to 10 MB, forcing every process to continuously re-read its own executable pages from the SSD (189 million *file refaults*, disk pinned at 100% utilization).

At that point, a trap we had built ourselves weeks earlier snapped shut:

1. The container's disk I/O limits (`io.max`), designed to protect the Proxmox host, queued `CT106`'s processes (`102` processes stuck in `rq_qos_wait`), freezing the container's userspace, including `cron` and `systemd-logind`.
2. The emergency timer we had created to kill orphaned Chromium processes ran **inside** `CT106`: because the container was frozen, the timer could not run to save it.

I solved this by acting at two levels on the Proxmox node and the container:

- I set `memory.high` to **6 GiB** in the container's LXC configuration (`/etc/pve/lxc/106.conf`), so the kernel starts reclaiming memory long before saturating swap (as soon as it was applied live, memory dropped from 8.1 GB to 2.6 GB without restarting anything);
- I replaced the cleanup script with an Ambrogio-aware version (`omp-cleanup.sh`) that terminates `chrome` and `omp` processes idle for more than 600 seconds but **never touches child processes of the active supervisor**;
- while installing the script, I also found and fixed a security bug: the file was executed as `root` by the systemd timer, but had been copied with `cp -a`, keeping user `tazpod` as its owner (it is now `root:root` with mode `0755`).

The lesson from this incident is clear-cut: **a protection mechanism cannot live inside the system it is meant to protect**, or it dies along with it.

## Why Version 0.1 Was Still Not Enough

By the end of the second day, Ambrogio 0.1 was stable, used very little memory, and had allowed us to close nearly two hundred old and new issues.

However, using it on real code made a structural limitation obvious: in 0.1, the unit of work was **the conversation with the agent**. When an agent said "I'm done", the issue was closed on trust, or it fell on me to manually check which branch it had written to, whether tests passed, and whether it had left untracked files lying around.

I needed the supervisor to stop trusting the agent's story and start checking the results on the Git repository by itself before declaring a job done. Out of that requirement, version **0.2** was born.
