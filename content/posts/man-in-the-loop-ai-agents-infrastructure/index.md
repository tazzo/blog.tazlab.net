---
title: "Man in the Loop: Reflections on Using AI Agents to Build Infrastructure"
date: 2026-03-18T08:00:00+00:00
draft: false
tags: ["AI", "Kubernetes", "DevOps", "Cloud", "AI Agents", "pi.dev", "OpenRouter", "Workflow"]
description: "Not hype, not science fiction: an honest account from someone who uses AI agents every day to build serious Kubernetes clusters, with all the limitations that entails."
---

## The Thesis: Powerful, But Only If You Know Where to Point Them

AI agents are the most transformative tool I have added to my workflow in recent years. In two months of evening work I produced what would have taken me two years to build alone. Yet every time I see someone on YouTube saying "look, I asked it to build me an app and it did", I get a wry smile.

Because there is an enormous difference between doing something and doing it well. And that difference, for now, still runs entirely through the engineer.

This is not an enthusiastic chronicle about AI changing the world. It is the account of someone who works every day with these tools on Kubernetes, cloud clusters, GitOps pipelines, and secret management — and has learned the hard way where you can trust these agents and where, instead, you need to keep them on a leash.

---

## Contextual Analysis: A Rapidly Moving Landscape

When I started experimenting with AI agents on infrastructure, my starting point was simple: I wanted to understand if they could help me do things I already knew how to do, but faster. I was not looking for magic. I was looking for efficiency.

The first problem I ran into was platform lock-in. Gemini CLI, Cloud Code, the native tools of the major providers: each has its own world, its own rules, its own updates that change interfaces without warning. One day you work a certain way, the next day someone has decided it works differently. And you have to follow along.

The turning point was discovering **pi.dev**, the platform on which this very working environment is built. It is a minimal agent, comparable to VI among editors: there is little by default, but it is configurable to an extreme degree and with disarming simplicity. You can tell it directly "create this extension, add this behavior" and build your own custom tool. Above all, it does not tie you to any specific provider.

This opened the door to **OpenRouter**, which is essentially a one-stop shop for every language model in existence. From there I started seriously exploring what the various providers offer, with a constant eye on costs — because I am a private individual, and a €200/month subscription is not a sustainable budget line.

### The Field Comparison

I tested many models in the specific context of working on clusters, containers, and cloud. The verdict was not what I expected.

**Claude (Cloud Code)** is excellent for complex design work. It reasons well, makes the right choices, understands architectures. The problem is cost: with Opus I exhaust my quota in an hour. With Sonnet you get a bit further, but not much. Excellent for surgical and critical work, unsustainable as a daily driver.

**Gemini Flash 3.0** surprised me more than once. On at least two occasions, on real Kubernetes configuration problems that Sonnet could not unblock, Flash solved them on the first attempt. It is not a rule, but it is frequent enough to be significant. It has reasonable pricing and performs well in my domain. There is one important asterisk, however: Gemini CLI used via pi.dev becomes nearly unusable due to rate limiting issues — 50-second waits between calls, then it errors out. The solution is to use it through its native terminal, where it works correctly.

**Minimax M2.5** was a disappointment. It gets good press, but in my specific domain — cluster configuration, Kubernetes, cloud infrastructure — it made too many mistakes and forgot too many things.

**Grok 4.1 fast** is not bad for the price. It loses track on long jobs, but on bounded tasks it is usable.

**Stepfun** (free model): very fast, but produces streams of intermediate logs because it is an extended reasoning model. In practice, it is nearly unusable on configuration work.

**GLM-5** (Zhipu AI) is the positive surprise of the bunch. Pricing comparable to Gemini Flash, it performs well on Kubernetes and cloud configurations, advances work with discipline, and self-corrects when it makes mistakes. It is one of those models I always keep as a backup when I run out of quota.

**Hunter Alpha** (openrouter/hunter-alpha) deserves its own mention. It is a free model of unknown authorship — probably a new version of DeepSeek or something similar, but it is not clear. I am using it with growing satisfaction: it is good at self-correcting, handles complex work well, and for now it is free. A bit slow — probably the consequence of the free tier — but the results are excellent.

The pattern that emerges is clear: **the best model depends on the task, not the brand**. And having a provider-agnostic platform like pi.dev, which lets me switch from one to another in seconds without changing my workflow, is worth more than any single model.

---

## Deep Dive: Where Agents Excel and Where They Break Down

### 1. The Context and Memory Problem

The real value of an AI agent in infrastructure does not lie in the ability to write YAML. It lies in the ability to hold a complex context in mind and apply it consistently. Kubernetes is a universe: there is Linux at the base, then Docker, then Kubernetes itself, then networking, then security, then the specifics of each cloud provider. Each layer has its own syntax, its own tools, its own flags.

For years my problem was not not knowing what I wanted. I always knew what I wanted to achieve. The problem was having to re-read documentation every time I switched library or provider, because every ecosystem has its own idiosyncrasies. Terraform on Oracle is not Terraform on AWS — same logic, different commands and configurations.

With agents, this problem nearly disappears. I describe the result, they write the code. My time shifts from the rote memorization of commands to the precise definition of what I want to achieve.

For this I built a custom context management solution — which I have written about elsewhere — that lets me open a terminal and find myself in 20 seconds with the project context already loaded: what has been done, where we are, what problems we have encountered. I can switch agent, switch project, and the new agent knows exactly where to pick up. Contexts are kept small and dense — only the information relevant to the moment — which reduces the risk of coherence loss.

### 2. The Risk of Autonomy: What Happens When You Let Them Run

This is the point I want to be most direct about, because it is where the most confusion exists.

I have tried multiple times to let agents work autonomously on complex tasks. The result is almost invariably the same: they complete the task, but the choices they make along the way are often wrong. Not wrong in the sense that they do not work — sometimes they work perfectly well. Wrong in the sense that they do not respect the architectural constraints I had in mind, they take shortcuts that create technical debt, they build fragile solutions that cannot be extended.

The most emblematic case I have experienced: I work on a cluster managed with a GitOps philosophy, so everything ends up on Git. On more than one occasion, an agent left to run autonomously committed credentials inside a ConfigMap or directly in a YAML file. It saw a problem, it looked for the fastest solution, and that solution was wrong from a security standpoint. Not because it did not know that secrets should not be committed — if you ask it, it can explain this perfectly. But in the flow of autonomous work, the pressure to "close the task" overrode compliance with the rules.

This taught me one thing: **AI agents know the best practices, but they do not feel them as an inviolable constraint when operating autonomously**. They apply them when explicitly instructed to do so, or when someone is watching.

### 3. Spec-Driven Development: The Structural Response

I am not the only one to have noticed this problem. An entire movement has emerged around what is called Spec-Driven Development: you design the system in detail first, document the architectural choices and constraints, and only then let the agent execute against that specification.

I use it, and it works. But there is a necessary condition that is often omitted from the enthusiastic presentations: **to write a good specification, you need to know what you are specifying**. You cannot precisely describe a security architecture for Kubernetes if you do not have a solid understanding of RBAC, secrets engines, and network policies. The agent will follow your specifications to the letter — but if the specifications are vague or wrong, the result will be vague or wrong.

The method works because it moves the intellectual work to where it belongs: inside the engineer's head, during the design phase. And the agent becomes the executor of a precise plan, not the designer.

### 4. Debugging and Cognitive Load

One of the most concrete transformations I have experienced concerns debugging. I used to spend hours — sometimes nights — changing flags, recompiling, testing, reading stack traces, searching forums. It was the most frustrating part of the work. And it was also, it must be said, the most formative part.

Agents do it in parallel and never tire. When there is a problem they cannot solve, they continue to iterate until they find the solution. And then they explain it to me — not just what they did, but why they chose that approach. This is the formative value I did not expect: not only do I stop doing manual debugging, but I learn from the reasoning the agent makes explicit.

I have developed the habit of not using them as silent oracles. I always ask for explanations, discuss choices, sometimes challenge them. At the end of every significant session I ask for a report: what was done, what problems arose, how they were resolved, what architectural choices were made. At that point, reading it back, I notice things I had not caught while we were working — choices I would not have made, constraints that were worked around instead of respected.

---

## The Human Element: The Engineer's New Role

There is a metaphor I often use to myself: the AI agent is like someone who knows how to write code but needs to be **herded in the right direction**. It knows what to do, it has the technical skills, but if you leave it the steering wheel it goes where it finds the nearest grass, not where it needs to go. Your job is to indicate the direction, verify the path, and correct when it strays.

This profoundly changes what it means to be an engineer. I write less code. I think at a much higher level. I focus on architecture, constraints, trade-offs. I have become better at describing systems precisely — because if the description is imprecise, the agent produces something imprecise.

And I am learning more, not less. Because discussing with an informed agent on a topic you do not know well is one of the most effective ways to deepen your understanding I have ever found. It is not a search engine, it is not documentation: it is an interlocutor that can answer the specific questions of your specific context. I went from a superficial knowledge of Kubernetes to a deep understanding of how secret management works, RBAC, credential rotation — not because I read a book, but because I spent hours discussing it in the context of my cluster, my use case, my mistakes.

---

## Final Synthesis: Recommendations for Those Working Seriously

The dominant narrative about AI has one flaw: it tends to present these tools as equalizers. As if anyone, with the right prompt, could build the same things. That is not the case — at least not in serious work on complex infrastructure.

My observation, after months of daily use, is that **AI is a multiplier, not a replacement**. And the size of the multiplier depends on the baseline competence. For those with a solid foundation, these tools are transformative — 100x, perhaps 1000x on certain types of work. For those without one, the benefit is real but far more limited.

This does not mean they are useless for those who are learning. It means that to truly learn, you need to use them actively: discuss, ask for explanations, challenge the choices, build understanding instead of accepting the result. The mountain of expertise is still high. These tools make it more climbable, not shorter.

For those who want to use them seriously on infrastructure, some lessons I have learned the hard way:

**Never give up the steering wheel.** Especially on a cluster hosting real services. Monitoring, analysis, proposed solutions — all fine. But the approval of every change must pass through a person who understands the consequences.

**Design first, execute later.** Robust Spec-Driven Development is the difference between an agent that advances your project and one that builds something you will have to throw away. But this requires that you already know how to do the thing, at least in its fundamental aspects.

**Always verify critical output.** Especially in a GitOps context: every commit you did not write yourself must be read. Agents do not have the risk perception of someone who has spent nights restoring a broken cluster.

**Use the right platform, not the right model.** A provider-agnostic environment that lets you switch models without switching workflow is worth more than any single model. Models change constantly — last week the best one was one thing, now it is another. The workflow must remain stable.

The programmer is not dead. They have evolved into something closer to a systems designer who has at their disposal a team of tireless, fast, well-informed developers — but who need to know exactly where they are going.
