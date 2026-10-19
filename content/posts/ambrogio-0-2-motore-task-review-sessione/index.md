+++
title = "Ambrogio 0.2: From Agent Control to a Task Engine, Same-Session Review, and the Runaway Tree"
date = 2026-10-10T06:00:00+02:00
draft = false
description = "Moving from Ambrogio 0.1 to 0.2: why we put tasks on Git worktrees at the center, how the review sends errors back to the same agent without losing context, the engine bugs that rejected valid work, and what happened when agents started spawning tasks on their own."
tags = ["ambrogio", "agents", "orchestration", "golang", "git", "worktree", "devops"]
author = "Tazzo"
+++

## Why We Moved from 0.1 to 0.2

With version 0.1 of Ambrogio, I had solved the most annoying problem of the previous systems: agents stayed active in memory and I could talk to them through a single interface without recreating the context from scratch on every question.

However, a reliability problem remained around delivered work. In 0.1, the agent was at the center of everything: I gave it a job, it worked, and at the end it wrote a message saying it had finished. As I had already seen in the past, though, an agent stating "everything is done and tested" does not mean the code actually compiles or that the files were committed to the right branch.

With **Ambrogio 0.2**, we shifted the center of the system: the fundamental unit is no longer the agent, but **the task bound to a dedicated Git branch and worktree**, paired with an automated check (**gate**) and a **review** before closure.

## The Key Choice: Running the Review Before Closing the Worker's Session

When you introduce a review step (a second check that verifies the work done by the first agent), the risk is falling right back into the Multica trap:

1. agent A does the work and exits;
2. agent B runs the review, finds an error, and reopens the task;
3. a brand-new agent C starts up knowing nothing about what happened before, has to re-read all project files from the beginning, figure out what the review meant, and repeat the checks from scratch, multiplying the tokens consumed.

To avoid this waste, in 0.2 I enforced a strict rule on the session lifecycle: **the worker that delivers the work is not closed until the review has passed**.

The flow works like this:

- the worker executes the job in its worktree, prepares the delivery, and **waits while keeping its session open**;
- at that exact moment, the automated gate (which checks that the Git working tree is clean, commits are present, and required artifacts exist) and the review run;
- if the gate or the review finds an issue, the rejection is sent right back **to the very same worker session that just did the work**. The agent still holds everything it just read and wrote in memory, fixes the reported point right away, and delivers again;
- the agent's session is closed and discarded **only when the task has passed review and is permanently closed**.

This gives the safety of an independent verification without paying the cost of reloading context from zero on every fix.

## When the Engine Is Wrong: Four Bugs That Blamed the Agents

As soon as the gate and review mechanism went live (which puts a task into *escalation* asking for my intervention after a maximum number `K` of failed attempts), I saw dozens of tasks end up stuck in escalation.

My first instinct would have been to assume the agents were doing poor work. Looking closely at the stuck tasks, however, I realized that in most cases the agent's work was fine: **it was our engine botching the checks and counting its own errors as agent failures**. In a single day of inspecting the database, we found four bugs in this family.

### 1. The Check Executed the Description Instead of the Command

Every artifact required by a task has a file path (`path`) and a verification condition (`condition`). In the function that ran the automated check (`review.runOne`), the two fields had been swapped: the engine passed the descriptive English sentence to `/bin/sh -c` instead of the verification command.

The result in the logs was `/bin/sh: 1: the: not found`. Out of 72 total escalations, **27 had been caused by this single error** (93 `condition.broken` events), rejecting work that the agents had completed properly.

### 2. Engine Restarts Counted as Task Rejections

Whenever we recompiled and restarted Ambrogio while a worker was running, the process was interrupted and returned the Go error `context canceled`. The runner caught that error in the `default` branch of its switch statement and **incremented the task's failed-attempt counter**.

As a result, six out of nine tasks had ended up in escalation without ever receiving a single review verdict, and one had been escalated despite already having three `pass` verdicts on record, simply because the engine had been restarted during execution. From that point on, we wrote an ironclad rule into the code: **an outage or restart of our engine must never become a rejection of the agent's task**.

### 3. The SQLite Database Committed Inside the Git Repository

To make sure an agent does not leave forgotten files outside commits, the gate checks that `git status` in the worktree is completely clean upon delivery.

Unfortunately, in Ambrogio's own repository, the `data/ambrogio.db` file along with its temporary `-shm` and `-wal` files had been committed by mistake, and `__pycache__` was missing from `.gitignore`. Every time a worktree was created or a Python test ran, those files showed up as modified and the gate rejected the agent's delivery saying *"the tree has N uncommitted change(s)"*, even when the code written by the agent was spotless.

### 4. Detecting Exhausted AI Model Quota Without Burning Tasks

Another concrete issue is what happens when the AI provider account runs out of credit or hits its hourly quota. Initially, the engine's watchdog noticed the problem only after three real tasks had failed within five minutes — burning three attempts at the expense of queued tasks.

I had tried checking the status by querying the `GET /models` endpoint, but that endpoint always returns `200 OK` even when credit is at zero, because it only returns a static list. The solution that worked right away was a **single-token completion probe**, executed using the exact same API key used by the workers: when credit is exhausted, it consumes nothing and immediately returns `402 Insufficient account funds`, allowing a pure Go routine to pause the queues before any agent is started.

## The "Auto-Ambrogio" Experiment and the Problem with Task Trees

Once the checks were fixed, I wanted to run a stress test: driving Ambrogio exclusively through its HTTP API, placing an agent in the role of **guardian** to monitor the system and open fix tasks, and enabling the **proposals** mechanism (every worker, when closing its report, could propose up to 5 follow-up tasks to complete the work or fix issues found along the way).

On one hand, the test proved the engine really worked: starting from a single message where I asked to improve a settings panel, the system autonomously handled a tree of 37 tasks across eight levels, surviving three restarts and four merge conflicts, and the workers even found and fixed five bugs in code the guardian had written an hour earlier.

On the other hand, letting agents generate and queue tasks autonomously caused two obvious problems to blow up:

1. **Uncontrolled task multiplication:** starting from 15 initial findings, each child task generated up to 5 new proposals of its own. Within a few hours we were looking at **122 open tasks** in the queue (64 born in the first half hour, then 19, then 15). Even though the engine only ran a few at a time, the queue filled up with secondary jobs I had never asked for.
2. **Permanent queue inversion caused by inherited priority:** in the database, the `OpenChildren` function automatically assigned every child task the same urgency (`urgency`) as its parent task. Because a test task tree had been created with `urgency = 1`, all twenty-one of its descendants were born with `urgency = 1` and kept jumping ahead of real engine bugs that had been opened with `urgency = 0`, leaving them stuck waiting for hours.

## What Led Us to Version 0.3

The experience with 0.2 left me with two certainties:

- keeping the worker session open during the gate and review is the right call, because it avoids re-reading context from scratch whenever something needs fixing;
- letting agents open and launch task trees on their own (or touch main repository branches directly) takes control away from the person running the lab.

To have a truly reliable tool, one final step was needed: taking away from agents both the power to start unapproved work and direct access to Git and secrets, moving all branch management, pull requests, and security enforcement into the Go engine. That is what we did with **Ambrogio 0.3**.
