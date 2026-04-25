+++
title = "GitOps for Knowledge: turning a project wiki into an operational surface"
date = 2026-04-25T05:10:51+00:00
draft = false
description = "A technical chronicle of how I turned `wiki.tazlab.net` from a simple markdown repository into an operational knowledge base for both agents and humans, published through Hugo, Docker, Flux, and Kubernetes."
tags = ["wiki", "gitops", "hugo", "flux", "kubernetes", "agents", "documentation", "llm", "knowledge-base", "devops", "context-management"]
categories = ["DevOps", "Architecture", "AI"]
author = "Taz"
+++

# GitOps for Knowledge: turning a project wiki into an operational surface

## The objective of the day

Over the last few months I have built many parts of TazLab with a fair amount of discipline: the operator environment with TazPod, the infrastructure foundation with `ephemeral-castle`, the GitOps cluster layer with `tazlab-k8s`, the `AGENTS.ctx` contexts, active memory, and semantic memory. Useful pieces, all of them. Pieces that, taken individually, had already started to reduce operational chaos quite a lot.

But one important thing was still missing: a documentation surface that was navigable, durable, and readable both by me and by agents. Not a collection of notes thrown into a folder. Not a dump of markdown files. And not even traditional documentation designed only for a human reader who opens one page at a time and consumes it in a linear order.

The concrete problem was this: every time I wanted to make an agent work on a specific part of the project, I still had to reconstruct part of the context by hand. Yes, I already had `AGENTS.ctx`, and that had changed the workflow a lot. But operational context alone is not enough if detailed knowledge remains trapped in code, manifests, scripts, historical READMEs, forgotten `docs/` files spread across different repositories, or worse, in my short-term memory.

Because of that, I decided to take one more step: build a real project wiki, publish it as a service inside the cluster, organize it into atomic pages, link those pages together, and explicitly design it so it could be sliced into micro-contexts useful for future agents. The result is now visible here:

**[wiki.tazlab.net](https://wiki.tazlab.net)**

This is not just the chronicle of a new static service deployed into the cluster. It is the chronicle of a change in level: treating documentation not as a consequence of the project, but as one of its operational parts. And, in my case, treating it with the same seriousness I apply to GitOps, infrastructure, and secrets management.

## The theoretical context: from Karpathy to a real lab

The underlying inspiration comes from an idea that has been circulating a lot recently among people working with agents and LLM-oriented systems: the idea of an **LLM Wiki**, that is, a structured knowledge base maintained and made navigable by agents as well as by humans.

The explicit reference is Andrej Karpathy's work, in particular:

- the gist: [https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)
- the tweet: [https://x.com/karpathy/status/2039805659525644595](https://x.com/karpathy/status/2039805659525644595)

The idea looks simple only at first glance. Once a project grows, code alone is no longer a sufficient interface to reconstruct context. Code is the truth of implementation. But it is not always the truth of mental navigation. It does not easily tell you why something was done a certain way, which directory holds a specific responsibility, which concepts belong to which subsystem, or which pages you should read before touching a pipeline or a runtime.

In other words: code is the endpoint of execution, but not always the best starting point for comprehension.

That becomes even more true when agents enter the picture. An agent can certainly search the code, grep through manifests, open ten files, and try to build a local mental model of the system. But if it has to retrace that path from scratch every time, the bootstrap cost remains high. And, more importantly, the quality of the context depends too much on luck: which files it opened, in what order, how accurate the legacy documentation was, how coherent the directory naming was, and how much noise surrounded the useful information.

That is exactly what I wanted to avoid. I did not want a knowledge base that was merely "nice". I wanted one that was **operational**.

## The real problem: having too much knowledge and still not being able to load it well

Paradoxically, the problem was not a lack of information. The problem was the fragmentation of information.

In my case, TazLab already had many documentation layers:

- the repositories themselves (`tazpod`, `ephemeral-castle`, `tazlab-k8s`, `blog-src`, `mnemosyne-mcp-server`)
- the context files under `AGENTS.ctx`
- the internal documentation of each repository
- the blog articles
- the current details preserved in active memory
- historical artifacts and semantic memory

Put that way, it almost sounds like a luxury. In reality it is a risk. Because once information is distributed across too many layers, you still need a surface that says: *if you need to work on this, start here; if you need to understand this part, read this other thing first; if you need to touch that layer, look at this map and then these files*.

That is exactly the kind of problem a well-built wiki can solve. But only under two conditions:

1. it must not become a generic accumulation of disconnected pages;
2. it must be kept aligned with the code rather than treated as side material.

That second condition is the hardest one. It means accepting that documentation itself has to be designed as a system. And the moment you accept that, everything changes: you are no longer "writing notes", you are building a project layer.

## The TazLab reinterpretation: not just a knowledge base, but project documentation and a context layer

In my case, the wiki was not supposed to serve agents alone. It also had to serve me.

I wanted a place where I could quickly find:

- what the Flux DAG actually looks like,
- where the Terragrunt layers live,
- how Vault restore from S3 works,
- which namespaces the cluster uses and why,
- how the delivery chain of a static service is organized,
- where the real application manifests actually live,
- which paths are the correct ones to touch `tazpod`, `ephemeral-castle`, or `tazlab-k8s` without reopening fifteen code files every single time.

So the wiki became three things at once:

1. **operational documentation for me**,
2. **a navigation surface for new agents**,
3. **a synthesis layer between code, memory, and repositories**.

That is the point where the notion of an *LLM Wiki* became genuinely useful in the lab. Not as a slogan, but as cognitive infrastructure.

## The most important design rule: atomic pages, not monoliths

If I had put everything into a few giant pages, the wiki would have immediately turned into yet another unmanageable blob. So the core rule was the same one that had already helped me with CRISP and with memory: **decompose**.

I organized the wiki into sections that are small enough and specific enough to be useful as context bricks:

- `entities/` for the main repositories and systems,
- `topics/` for cross-cutting syntheses,
- `operations/` for runbooks,
- `sources/` for source summaries,
- `analyses/` for clarification and drift notes,
- `concepts/` for the broader mental models.

The difference is not cosmetic. It is the fact that an agent that needs to work, for example, on the GitOps part of the cluster is not forced to read the entire TazLab universe. It can start from `tazlab-k8s`, open the Flux DAG, then the layer map, then the secrets pages, then the ingress and image automation pages. Context is composed through targeted navigation, not through indiscriminate ingestion.

For me, this is one of the real strengths of the pattern: the wiki becomes *sliceable*. It is not only navigable. It is **sectionable**.

## The interesting part: the cluster had become mature enough to make all of this feel almost trivial

One of the most instructive aspects of this implementation was exactly the distribution of friction.

If I had tried to stand up `wiki.tazlab.net` a few months ago, it probably would have turned into a marathon of resistance: namespaces still unclear, pipelines still shaky, image automation incomplete, ingresses ambiguous, secret delivery not yet clean, operators too fragile to treat a new service as a simple addition.

Instead, this time the cluster behaved like a mature cluster.

And, for me, that is the real background story of this article.

The previous design work — especially the work done carefully through CRISP, with decomposition and narrow steps — produced a very concrete effect: when the time came to add a new static service, the infrastructure layer did not resist. Not because it was absolutely trivial, but because the foundations were already in the right place.

This is an important difference. In an immature system, every new function is a survival test for the architecture. In a mature system, a new function becomes mostly an application and content modeling problem. The platform stops being the bottleneck.

And that is exactly what happened here.

## The Hugo publication layer: the part that generated real friction

The place where I actually spent energy was not Kubernetes. It was not Flux. It was not the ImagePolicy. It was not namespace isolation. It was not wildcard TLS delivery.

The part that created friction was **Hugo**.

I deliberately chose not to deform the wiki repository just to satisfy the static site generator. Canonical content had to remain under `wiki/`, with an organization designed for both agents and humans, not be reshaped into a fake Hugo-native `content/` tree.

So I built an adapter under `publish/`, with explicit mounts, a separate homepage (`homepage.md`), a strict distinction between the public front door and the internal index, and a presentation layer minimal enough not to betray the nature of the source repository.

That choice, which I still consider architecturally correct, moved the friction into the publication layer:

- mounts that needed alignment,
- markdown links that had to be made compatible,
- a homepage that had to remain separate from the internal index,
- a `baseURL` that had to be fixed correctly,
- `enableGitInfo` that had to be disabled in the Docker build so the image did not require `.git`,
- experiments with Hugo themes that turned out to be far less interchangeable than people like to believe.

This is a useful reminder of how these systems actually work. Mature infrastructure does not eliminate problems. It **moves** them into the places where design is still evolving.

## The GitOps side, instead, worked exactly as it should

On the cluster side, the behavior was almost textbook.

I built the wiki lane in `tazlab-k8s` by following the same pattern already used for the blog:

- dedicated namespace,
- wildcard TLS delivery in the correct namespace,
- `Deployment`, `Service`, `Ingress`,
- `ImageRepository`, `ImagePolicy`, `ImageUpdateAutomation`,
- a separate `Kustomization` (`apps-static-wiki`) instead of forcing it into the blog lane.

The result was exactly what I expect from a mature cluster:

1. GitHub Actions builds the wiki image.
2. Docker Hub receives the new `wiki-<run>-<sha>` tag.
3. Flux sees it through `ImageRepository`.
4. `ImagePolicy` selects the latest tag.
5. `ImageUpdateAutomation` updates the manifest.
6. The cluster reconciles.
7. The pod comes up.
8. The Ingress becomes reachable at `wiki.tazlab.net`.

The most interesting part is that, once two real build issues were fixed, this flow worked without requiring structural changes to the cluster. The GitOps model simply did its job. I only had to describe the new service in a language the platform already understood.

For anyone designing clusters, this matters a lot: maturity is not measured when you deploy the first thing. It is measured when you add the twenty-first service and do not have to reinvent anything.

## The two real errors that blocked the publication pipeline

There were two real failures in the wiki publication path, and both were instructive.

### 1. Docker Hub authentication

The first failure was the most banal and also the most typical one: the wiki GitHub Action did not yet have the correct Docker Hub secret wiring.

This is where the difference between a fragile system and a robust one becomes visible. In a fragile system, an error like this makes you doubt everything else. In a robust system, the failure is readable, local, and fixable without shaking the whole model.

Once the `DOCKER_PASSWORD` contract was aligned, the publication flow moved past authentication and landed on the next real problem.

### 2. Hugo inside Docker and `enableGitInfo`

The second error was more interesting: Hugo was trying to load Git metadata during the image build, but the Docker build context did not include `.git`.

This is the kind of issue that immediately reveals whether you are building a real delivery path or just simulating a local deployment. Locally everything worked, because the Git repository was there. Inside the builder container, it was not.

The correct fix was not to stuff `.git` into the image. That would have been an architectural distortion and pointless noise in the final container. The correct fix was to recognize that the wiki did not need Git metadata during that phase and lock the configuration to `enableGitInfo = false`.

It is a small correction, but it says a lot about how I approach these systems: I do not look for spectacular workarounds when removing an unnecessary dependency is enough.

## The most annoying part: `baseURL`, links, and Hugo themes

If there was one part of this work that reminded me how much less interchangeable Hugo themes are than people say, it was this one.

I wanted to try an aesthetic alignment with Blowfish, the blog theme, and I immediately ran into the less elegant side of these ecosystems: themes are not just skins. They are implicit frameworks. They carry strong expectations about front matter, content structure, layout behavior, taxonomies, link rendering, homepage logic, and section listings.

In a sense, this was inevitable. The wiki was born as an agent-oriented knowledge surface, not as a Hugo-native blog. So every attempt to treat it as if it were already content modeled for an external theme created friction.

In the end, the lesson was very simple: when something already works, it is often better to keep it sober and clean rather than force it into an aesthetic designed for another purpose. The final version I kept is not the most ambitious in terms of theming. It is the most stable, readable, and coherent with the content.

For me, this is a general lesson, not only about Hugo: **the publication layer must not impose the wrong mental structure on the content**.

## The heart of the project: the wiki as a tool for building smaller and more useful contexts

The real value of `wiki.tazlab.net` is not that there is now one more subdirectory or one more hostname in the cluster. The real value is that there is now a surface where knowledge is organized with a granularity that can be reused.

That means I can construct contexts for agents much more precisely.

For example:

- an agent that needs to work on `ephemeral-castle` can read only the architecture map, the rebirth protocol, the Terragrunt layers, the Vault runtime pages, and the Tailscale pages;
- an agent that needs to work on `tazlab-k8s` can read the Flux DAG, repository mapping, image automation, ingress/auth, and monitoring pages;
- an agent that needs to work on `tazpod` can read the image hierarchy, RAM vault security, dotfiles/provisioning, and sync daemon pages.

That ability to slice context is, in my view, much more important than it first appears. Because the real enemy of agents is not only missing information. It is excess information that is badly organized.

A well-built wiki is therefore not only a place where you store things. It is a place where you **decide the shape in which knowledge becomes loadable**.

## The mature cluster as a precondition for simplicity

If I had to extract one technical moral from this implementation, it would be this: the simplicity you perceive at the end does not come from the final step. It comes from all the design work that made the final step possible.

Bringing the wiki online was simple not because Hugo is always simple, or because Kubernetes is always simple, or because Flux is magic. It was simple because the cluster was already mature enough to absorb a new service without forcing me to rethink everything.

For me, this is one of the best signs that an infrastructure is starting to become truly useful. Not when it supports the first demo. But when it can absorb a new transversal function like this naturally: documentation, a knowledge layer, onboarding for agents, a publication pipeline, a new Flux lane, a new hostname, a new deployment lifecycle.

If all of that can enter without excessive friction, then the platform is starting to do its job.

## What we learned in this stage

This stage left me with a few fairly strong convictions.

The first is that the **LLM Wiki** pattern is real and useful. It is not a passing trend tied to the name of the person who popularized it. It genuinely works when a project crosses a certain threshold of complexity and when you want agents to work on different slices without forcing them to rebuild the world every time.

The second is that the value of this pattern increases dramatically when the wiki is not just a knowledge base *for agents*, but also an operational manual for the human maintaining the system. That creates a strong alignment: if the documentation is truly useful to me, then I have a real incentive to keep it alive and aligned with the code.

The third is that the maturity of a platform becomes clear when you add a new layer and infrastructure is no longer the hardest part. In this case the cluster, Flux, and the delivery chain all did their job. The friction moved into the publication layer of the wiki, which was the least consolidated part. That is a very good sign.

The fourth is that the wiki, once built this way, becomes a very powerful intermediate source of truth: it does not replace code, it does not replace memory, and it does not replace contexts. It connects them. And it makes their relationship navigable.

## Final reflections

If I had to describe what I built today in one sentence, I would say this: **I stopped treating documentation as an output and started treating it as an operational surface of the project**.

In my case, that surface now lives at `wiki.tazlab.net`, but the domain is not the important part. The important part is the model.

Taking code, memory, scattered documentation, decisions, runbooks, and real drift and turning them into a navigable, sliceable wiki changes the way you work with a complex system. It changes the way I remember where things are. It changes the way an agent can be aligned. It changes the cost of reopening a problem after days or weeks.

And above all, it changes the kind of question you can ask an agent. No longer only: *find in the code where this happens*. But also: *load the right context, understand how that subsystem is built, then work inside it with precision*.

For me, that is the real meaning of `GitOps for Knowledge`. Not applying GitOps to a static site. But treating project knowledge with the same discipline I apply to infrastructure: explicit structure, clear pipeline, continuous updates, repeatable delivery, and a final surface that is not only published, but truly usable.
