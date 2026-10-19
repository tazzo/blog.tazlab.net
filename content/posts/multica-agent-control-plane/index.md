+++
title = "Multica: How I Integrated an Agent Control Plane into the Lab, and What I Think of It After Using It"
date = 2026-10-03T05:00:00+02:00
draft = false
description = "The choices that brought Multica into the lab — the shared cluster, certificate identity, secrets from Vault, the patches to the chart, the daemon on CT106 and the agent team declared in Git — and my assessment after actually using it."
tags = ["multica", "agents", "orchestration", "kubernetes", "gitops", "flux", "vault", "mtls", "postgresql", "devops"]
author = "Tazzo"
+++

## Where This Article Starts

In the previous article I described the attempt with Paperclip. The problem I had was not the number of agents: it was not knowing **who was working on what**, and not being able to re-read the decisions taken while they worked. Paperclip answered the question with a model I did not need: a task was a process to remember, not an object you assign, see in a table, and that returns a comment with the outcome.

With Multica I tried the same thing with a different tool. This article describes which choices I made to bring it into the lab and, at the end, what I think of it after using it for a while. The project is at [github.com/multica-ai/multica](https://github.com/multica-ai/multica).

## What Multica Is, in Short

Multica does not provide models: it uses the **agents already installed** on the machine. You assign a task to an agent the way you would assign work to a person, and the agent runs it on a machine you control, writing comments while it works.

It is split into two parts, and for the lab it was important to keep them separate because they have two different lifecycles:

| Part | Where | Who manages it |
|---|---|---|
| Control plane (Go backend, Next.js frontend, PostgreSQL) | cluster `tazlab-k8s`, namespace `multica` | Flux, Vault/VSO, Terraform |
| Daemon (the process that runs the agents) | CT106, systemd unit `multica-daemon.service` | Git-based Ansible layer |

The daemon looks for the agents installed in the `PATH`, registers **one runtime per agent it finds**, and prepares a separate working directory for every execution.

One detail worth knowing straight away: **the daemon does not isolate the agents**. The documentation states that the security boundary is the system user, so the agents run with `tazpod`'s permissions, exactly like the ones I start by hand. The lab's only security boundary remains the container: that is why the daemon lives on CT106, where the agents and their credentials already are.

## The Integration Choices

This is the part that matters, and I will go through it one decision at a time: what alternative I had, what I chose, and why.

### 1. Where to Run the Control Plane: Kubernetes

I had three options: the Kubernetes cluster (where the lab's other applications already run), Docker Compose on CT100 (the path the project itself suggests), or a dedicated virtual machine.

I chose Kubernetes because the path of an application in this cluster is already written: there is a directory per application, an overlay, an entry in Flux, and secrets already come from Vault. The other two options look simpler, but each brings a second chain to maintain: with Docker Compose I would have had to build private exposure and a second database backup from scratch; with a virtual machine I would have had to reserve memory that today I share. It is not an ideological choice: it is the path with the fewest new things to invent.

### 2. The Database: the Shared Cluster, Not a Dedicated One

Multica wants PostgreSQL 17, and the shared cluster `tazlab-db` was still on 16. So the initial recommendation was a second, dedicated cluster, and the only reason was the version.

That recommendation lasted one day: the shared cluster moved to **PostgreSQL 17.2** with PGO's declarative procedure (I described it in the previous article). From there the cheapest choice was to use the database that already exists: one database to back up, one backup chain to S3, the same certificates. A second cluster would have meant two backups and two things to keep updated, for an application that has one frontend and one backend.

### 3. Authentication: a Certificate Instead of a Password

This is the choice I am most convinced of.

In PostgreSQL the access rules live in the `pg_hba.conf` file and are read from the top down: the **first line that matches** applies. One important detail: using certificate authentication does not by itself close the password route. If the role has a password and further down the generic lines that accept `md5` for that address are still there, the role also gets in in the clear. The check looks like it is there and it is not.

For the `multica` role I therefore wrote four lines, **above** the generic ones:

```
hostssl multica multica 0.0.0.0/0 cert
hostssl multica multica ::/0      cert
host    all     multica 0.0.0.0/0 reject
host    all     multica ::/0      reject
```

The first two accept the certificate, the other two stop the same identity from getting back in through the password door. The identity is carried by the certificate issued by Vault's PKI, and the name in the certificate (*Common Name*) must match the role name.

Why I give up the password: in this lab the critical moment is when I **destroy and recreate the cluster**. With a password, after a rebuild the value in the Secret no longer exists and I have to rebuild and realign it by hand; with the certificate there is no value to keep, because Vault **re-issues** it. It is the same scheme `hindsight` and `mnemosyne` already use; `paperclip` still uses a password, and that is the known difference in the lab.

### 4. Secrets: Vault, with an Entry Built in a Specific Way

Multica's chart **references** a Secret called `multica-secrets` but does not create it: it states explicitly that real values must not end up in Git. That is exactly what is needed to use Vault.

Here I found two conditions to respect. The first: a `VaultStaticSecret` reads **a single entry** in Vault, and the keys of the Secret become the **fields** of that entry. The lab's convention is one path per key with a single `value` field; had I used it, the Secret would have had one key and the backend would not have started. So I wrote **one entry with seven fields** (`JWT_SECRET`, `DATABASE_URL`, `MULTICA_VCS_SECRET_KEY` and four optional ones). The second: the `VaultAuth` has a **list of authorised namespaces**, and a new namespace has to be added, otherwise the Secret is not delivered and the application starts without its keys — a failure you discover by reading the logs of a pod that does not understand why it will not start.

### 5. The Chart Is Rigid: Four Patches Declared in Git

The chart does not cover everything that was needed: the Service type is fixed, there is no place to mount the certificates, the metrics port is missing, and the frontend has no probes. I did not fork it: I wrote **four patches on the manifest Helm generates** (`postRenderers`), declared in Git, which add the external Service, the metrics port, the certificate volume and the probes. The price is that those patches are tied to the chart version: when the version changes they have to be checked again.

### 6. The Daemon: a User Process on CT106, with the Binary Pinned

The daemon is not a container: it is an executable installed in `/usr/local/bin/multica`, held at version 0.5.3 and verified with the release checksum, plus a systemd unit managed by the lab's Ansible layer.

It lives on CT106 because that is where the agents and their credentials already are. And the binary is pinned with the checksum because I do not need automatic updates: I prefer to replace it myself, with the layer, so I always know which version is running.

### 7. The Agents: the Team Declared in Git

The team is not created by hand in the interface: it lives in a file in the repository (`configs/multica-team/roster.yml`) and is applied by a script that deletes nothing and contains no secrets. The practical consequence is that the team **rebuilds itself from the repository**, without having to restore the database.

There are twelve agents, one per role: the one that writes the articles, the one that touches the cluster, the one that signs the release, the one that looks after the documentation, and so on. Each has its own runtime and its own model.

### 8. Exposure: a Single Surface

The project called for two exposed surfaces (frontend and API), because a home client or a VPN client is not on the tailnet. Studying the chart I saw that the Next.js frontend is a **proxy**: it forwards calls to the backend (`/v1`, `/api`, `/auth`, `/uploads`, `/ws`) while staying on the same address. So the browser only talks to the frontend: a single surface and no CORS problem.

I did not add an Ingress, for a verified fact: the lab domain's DNS points with a wildcard at the public address and Traefik answers from outside, so a domain name would publish the dashboard on the Internet. Access is a `LoadBalancer` Service on MetalLB's shared address, `192.168.1.240:3000`, reachable from the home network and over VPN.

## The Errors: Few, and Matters of Execution

The project went through without surprises on the decisions. The errors there were concern execution, not the choices, and some of them were made by the agent writing the manifests. I list them briefly because they do not deserve space:

- the patch targets were written with the wrong name (`multica-backend` instead of `multica-multica-backend`, because the generated name carries the release name in front), so the certificate volume was never mounted and the backend went into a restart loop;
- the placeholder for automatic image updates had been put on the wrong field, and the pods rejected the image name;
- the install got stuck twice because a Helm release does not re-read its configuration until the previous operation has finished: I unblocked it by hand.

Of these three cases one thing is worth keeping: **a patch that does not find its target does not raise an error, it simply does nothing.** The reconcile was green, the pods were alive, and the defect was only visible by reading a pod's log. That is why now, when I change the chart version, I look at the generated manifest before applying it.

## Two Things the Project Had Not Foreseen

Here is the part that taught me the most, and it is about what the system needs in order to work, not about what the system does.

**The model key for the agents.** A systemd unit does not inherit the shell's environment: without the provider key written into the unit, the first assigned task would have died immediately, with an error that looks like an agent defect. I saw it before running the test, by checking the environment of the agents installed on the machine, and I put the key in the unit: not in the environment of the agent configured in the control plane, because that would have copied it into Multica's database.

**The working directory.** The daemon registers a runtime for every working directory it sees, and a freshly created account has none: the result was zero runtimes. It is not a configuration error, it is something written down nowhere: once the directory existed, the runtimes appeared.

Let me add a trap that cost me reading time: `MULTICA_TOKEN` **is not the daemon's credential**, it is the token the daemon passes to the agent for a single task; the real credential lives only in the `~/.multica/config.json` file, the one written by the `multica login` command. I did not learn it from the documentation, but by reading the command-line application's code.

The lesson, valid for every piece you add (a daemon, a chart, a systemd unit), is that the plan must also state **with which credential, in which file and with which precondition** the piece works. The project had verified well what the system does, and not what it needs in order to do it.

## What I Verified

- The control plane answers: `curl http://192.168.1.240:3000/` returns 200 from the shared address.
- Certificate authentication really works, and the proof is not that the pod is alive: the backend runs its migrations with `sslmode=verify-full`, so if the certificate were not valid it would not connect at all.
- The daemon is active and registers the agents found on the machine.
- The test that counts: a task assigned to the lab agent was **completed in 29 seconds**, and the comment contained the real output of the commands it ran.

## What Remains Open

- **The rebuild proof.** I have not yet destroyed and recreated the cluster. Until I do, "it comes back up with no manual work" remains an expectation, not a verified fact. It is also the proof that certificate identity pays off.
- **Mirroring the images to Docker Hub.** The `tazzo/tazlab-multica-*` repositories answer 404, so the two `ImageRepository` objects point at the original on GHCR.
- **The attachments disk has no recurring backup.** I accepted it as debt: the lab does not yet have a Longhorn backup declared in Git and I did not want to introduce the first one here.
- **The lists of authorised addresses are empty.** Writing them before knowing which address I would come in from could have locked me out.

## My Take, After Using It

Multica has not failed: it is the most successful of the three attempts I made. Two things it does better than the other two.

The first is the **written orchestration rules**: an agent receiving a task does not improvise, because the state, the stages, the format of the comment and the boundaries are defined beforehand and apply to everyone. When an agent gets it wrong, I can re-read the rule it should have followed, instead of arguing about what it meant. The second is **certificate identity**: if the key is not there, the connection does not open, and there is no password to pass around.

The problem is a different one, and it is about reading. Multica **writes a lot and writes well**: every execution leaves tasks, signed comments and a complete history. But the amount is more than I can read. After a work session, to know **who is stuck** I have to open the table and reconstruct the situation by hand. There is no single place where I read what each agent is doing right now: I have a complete account of what happened, but not a quick view of what is happening.

The problem showed up in daily use, and I measured it on real comments: 3,057, 3,257 and 2,630 characters, against a limit of about 800 that we had written, with the decision to take on the last line. After the first correction the request block ended up in the middle of the message, with more text to read below. In the same period an agent that had finished its work **stopped instead of opening the next task**: it wrote "say the word and I'll open it", and the chain only restarted because I said so. Neither is a defect of the tool: it is I who write the instructions and who verify. But it is the cost Multica makes me pay every day, and it is not an installation cost.

The conditions under which I kept it are three: the account has to become more readable, that is, it has to say who is stuck now and not only what happened; the volume has to come down, because an account I cannot read is of no use to me; the written rules remain the reference for the other attempts too, because I need that part anyway.

Then time decided: on 1 October I emptied the workspace (49 tasks closed, 6 cancelled with the reason, none open) and froze the project. The platform is alive, but the work moved to the engine I was writing myself. And two things Multica leaves behind remain, and they sum up the problem: a check on the metrics that selects nothing — the application is there, it is healthy, and **nobody is watching it** — and the attachments disk with no recurring backup. Neither of them raises an error: they are only visible if someone looks.

## Conclusions

The lesson I take away is not about Multica:

> A project verifies well **what** the system does, and not **what it needs** in order to do it.

Database, authentication, exposure and images: decisions taken well and built without surprises. The four things that cost time — the names of the objects generated by the chart, the automation placeholder on the wrong field, the key for the agents, the working directory — were all outside the project: they were questions nobody had asked. Three habits follow.

**Check before saving to the repository.** I applied the layer twice and the second time it changed nothing; I ran the end-to-end test after checking the environment, not before.

**Look at the result, not just the outcome.** A patch that does not find its target does not fail: it does nothing. That is why, when I change the chart version, I check the generated manifest.

**Declare the exceptions.** This project's three are declared, and the only one accepted with a condition (the entry in Vault, because no object in Git can write it) holds precisely because of the rest. A declared exception is a choice; one discovered six months later is an incident.
