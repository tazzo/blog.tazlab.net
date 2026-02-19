---
title: "Mnemosyne: Returning to the Castle and the Battle Against Recursive Noise"
date: 2026-02-18T23:00:00+01:00
draft: false
tags: ["postgresql", "pgvector", "data-engineering", "gemini-ai", "snr", "markdown", "recursive-loops"]
categories: ["Cloud Engineering", "Intelligence"]
author: "Taz"
description: "From the migration to local PostgreSQL to the creation of a purification pipeline: how we solved the meta-memory trap and optimized logs by transforming JSON to Markdown."
---

# Mnemosyne: Returning to the Castle and the Battle Against Recursive Noise

In the previous chapter, I described **Mnemosyne** as a semantic memory engine temporarily hosted on Google AlloyDB. Today, that bridge has been dismantled: Mnemosyne has returned home, to the local TazLab cluster. But the relocation revealed an unexpected data engineering challenge: **the memory was beginning to remember itself in an infinite loop.**

In this post, I document how we transformed 176 session logs into a clean knowledge base, defeating the recursion trap and optimizing data for the AI era.

## 1. The Move: PostgreSQL and pgvector in the Castle

TazLab's autonomy requires local hardware. We configured a PostgreSQL instance managed by the **Crunchy Postgres Operator (PGO)**, with the `pgvector` extension active to handle 3072-dimensional embeddings.

The challenge wasn't just making TazPod talk to the local DB (`192.168.1.241`), but doing it securely and resiliently, extracting credentials dynamically from Kubernetes Secrets and avoiding static passwords in the code.

## 2. From JSON Explosion to Markdown Compactness

The first major obstacle was the data format. The Gemini CLI saves every session in JSON files dense with technical metadata: timestamps for each call, tool-call structures, and raw outputs. Ingesting these JSONs directly was inefficient:
*   **Noise**: 70% of the file was structure, not content.
*   **Quota**: JSON files often exceeded model token limits, leading to high costs and fragmented analysis.

We therefore implemented **Chronicler**, a pre-processor that transforms JSONs into **High-Resolution Markdown**. 
This transformation allowed us to:
1.  **Synthesize logs**: We removed useless metadata and surgically truncated system dumps (Terraform, K8s logs) exceeding 5000 characters.
2.  **Increase SNR**: The signal-to-noise ratio increased drastically, allowing Gemini to focus only on architectural decisions.
3.  **Manage Quota**: Smaller files mean more "memories" extracted with a single API call.

## 3. The Recursion Trap (Meta-Memory)

The most insidious problem emerged during the bulk update. Using Gemini CLI to manage Mnemosyne, the AI creates new sessions where it discusses... how to load the previous memories. 

### The Inception of Logs
If we ingested these logs without filtering them, we would create a catastrophic loop:
1.  The AI extracts memories from a technical session.
2.  A log of the extraction session is created (containing the just-extracted memories).
3.  The script loads that log, re-extracting the same memories as if they were new facts.
4.  The memory fills with "memories of memories", duplicating data and exponentially increasing noise.

### The Solution: 5-Message "Deep Sniffing"
To break this hall of mirrors, we evolved Chronicler with a depth semantic filter. The script now "sniffs" the first 5 messages of every session. If it detects the **"KNOWLEDGE EXTRACTION PROTOCOL"**, it identifies the session as *meta-work* (working on the archiving itself) and discards it before it can contaminate the database.

## 4. The CLI Marathon: Bypassing API Limits

Ingesting 176 files immediately showed the limits of "developer" APIs: 20 requests per day for the Free Tier. Mnemosyne would stop every ten minutes.

We solved this by forcing the script to use the **Gemini CLI** (`--use-cli`) for fact extraction. By leveraging the user account quota (which is much more generous) and implementing **Retry Logic (60s)** to handle `503 UNAVAILABLE` errors (server overload), we transformed a fragile process into an unstoppable marathon.

## 5. The Golden Rule of Minimalism

Finally, we codified a fundamental governance rule: **The Golden Rule of the Minimum Necessary Change.**
During development, the AI tended to "improve" or simplify logs and code at every step, risking breakage. We established that the agent must act surgically: change only what is strictly indispensable to maintain the Castle's stability.

### Next Steps: Active Memory
Mnemosyne is now a clean and self-consistent archive. The next goal is **Phase 6**: transforming archiving into an incremental process that occurs *during* the session, allowing the AI to learn in real-time without ever having to re-read old logs again.

---
*Technical Chronicle by Taz - Senior Archivist of TazLab.*
