---
title: "Protecting TazLab's Keystone: Historical S3 Backups with TazPod"
date: 2026-05-21T11:00:00+02:00
draft: false
tags: ["Go", "Security", "S3", "Backup", "Cryptography", "DevOps"]
categories: ["Engineering", "Infrastructure"]
author: "Taz"
description: "How to manage retention and history of an AES-GCM encrypted archive on S3 without wasting API calls. The plaintext hash sidecar trick applied to TazLab's Vault."
---

# Protecting TazLab's Keystone: Historical S3 Backups with TazPod

In the design of a self-hosted infrastructure (be it a homelab or a private cloud), managing the initial encryption keys is a classic chicken-and-egg problem. If the entire ecosystem is encrypted, where do you store the keys needed to decrypt it at boot? 

In TazLab, the answer to this question is TazPod's **Vault**. Before moving forward, it is important to clarify a key terminological detail: in this context, "Vault" does not refer to an active, network-reachable HashiCorp Vault server (which we indeed run inside our Kubernetes cluster). Instead, we are talking about the **encrypted credentials package** (`vault.tar.aes`) managed by our TazPod CLI tool. 

This archive contains the root keys, encryption seeds, and bootstrap credentials needed to configure the Tailscale network, unlock Talos nodes, and restore databases from scratch. If the entire physical infrastructure were to be razed, the combination of this single encrypted file and the backups distributed across S3 would allow the entire system to be reborn from zero. It is, for all intents and purposes, the keystone of TazLab.

Today I am documenting how I evolved this backup mechanism by implementing a secure and S3 API cost-optimized retention policy in TazPod v0.3.31 and v0.3.32.

---

## 1. The Risk of Single-File Backups

Until the previous version of TazPod, the `tazpod push vault` command simply uploaded the encrypted archive to S3, overwriting the fixed key `tazpod/vault/vault.tar.aes`. 

This approach presented an unacceptable operational risk in a disaster recovery strategy: **lifeline corruption**. If an incorrect local modification or a partial dump corrupted the local key database and I executed a push (or if the background auto-sync daemon did so), I would overwrite the only valid backup on S3. At that point, the entire infrastructure would become unrecoverable.

The obvious solution was to implement a retention policy based on version history. The architectural choice fell on a model with **50 historical versions** ordered by timestamp:
*   The most recent version is copied to `tazpod/vault/vault.tar.aes` to act as a fast static pointer.
*   Every single push operation concurrently generates an archived copy at `tazpod/vault/history/vault-<TIMESTAMP>.tar.aes`.
*   An automatic, asynchronous pruning process keeps the total count of the `history/` folder limited to $N=50$ items.

---

## 2. The Cryptographic Challenge: Non-Deterministic Encryption and S3 APIs

Implementing history raised a performance issue with S3 API calls. The Vault is protected locally using **AES-256-GCM** encryption. 

For security reasons, Galois/Counter Mode (GCM) encryption requires a random and unique Initialization Vector (nonce) for every single encryption operation. This means that even if the plaintext files inside the Vault remain strictly identical, encrypting the same archive twice at different times produces two completely different binary files with different SHA256 hashes.

```
Plaintext (Identical Vault) 
   │
   ├──> Encryption T1 (Nonce A) ──> vault.tar.aes (Hash: 3a9f...)
   │
   └──> Encryption T2 (Nonce B) ──> vault.tar.aes (Hash: f82c...)
```

If the TazPod auto-sync daemon simply compared the hash of the local encrypted file with the one on S3, it would detect a difference during every single cycle (by default every 5 minutes). Consequently:
1.  It would perform an upload to S3 on every cycle, wasting bandwidth.
2.  It would quickly saturate the 50-copy retention limit with identical duplicate content, erasing the actual older historical versions.
3.  It would generate unnecessary S3 API write costs.

---

## 3. The Plaintext Hash Sidecar Trick

To solve this cryptographic constraint, I implemented the **Plaintext Hash sidecar** pattern. 

Before TazPod encrypts the archive, it calculates the plaintext SHA256 of the unencrypted tar archive. This hash, which is 100% deterministic since it depends solely on the content of the secrets, is saved locally in a sidecar file named `last-content.hash`.

During `pushVaultInternal()` execution, TazPod follows this logical flow:

1.  It reads the local plaintext hash from `last-content.hash`.
2.  It performs a quick `HeadObject` call on S3 to check the metadata of the `vault.tar.aes` file currently stored in the cloud.
3.  In the `HeadObject` response, it retrieves a custom metadata field named `content-sha256`, which contains the plaintext hash recorded at upload time.
4.  If the local hash matches the one returned by S3, TazPod aborts the operation, printing in the logs:
    `Vault unchanged, skipping push`

This way, if the Vault undergoes no actual changes by the operator, the sync daemon only performs highly inexpensive and fast `HEAD` read calls, avoiding `PUT` write calls and the creation of duplicate historical copies altogether.

Here is the Go snippet implementing this check:

```go
if contentHash != "" {
    lastMeta, headErr := s3.HeadObject("tazpod/vault/vault.tar.aes")
    if headErr == nil {
        if lastHash, ok := lastMeta["content-sha256"]; ok && lastHash == contentHash {
            slog.Info("Vault unchanged, skipping push")
            return nil
        }
    }
}
```

---

## 4. Technical Diagnosis and Lessons Learned

During the build and test cycle, two significant bugs required methodical troubleshooting.

### The Null Comparison Deception (The `"" == ""` Bug)
In the first version of the skip code, I hadn't used the `ok` idiom to verify whether the key existed in the metadata map returned by `HeadObject`. The original line was simply:
`if lastMeta["content-sha256"] == contentHash`

On the first run after the software update, the metadata on S3 did not exist yet (as the old archive was uploaded without metadata), returning an empty string `""`. Similarly, in the absence of the local sidecar file, `contentHash` was `""`. The comparison `"" == ""` evaluated to `true`, silently skipping the first configuration push. Introducing the check on metadata existence (`ok`) resolved the false skip.

### The Orphan Configuration Bug (v0.3.32)
After the initial deployment, the accidental deletion of the `config.yaml` file on a test container triggered anomalous behavior: the absence of the file configured the historical copies retention to `0` due to an unhandled early return in the `loadConfigs()` function. A retention of zero instructed the system to delete *all* archived copies on S3 on every push.

The fix involved applying default values at the initialization stage of the configuration struct, ensuring that even in the event of missing files or minor parsing errors, retention never drops below the safety threshold of 50 copies.

---

## Conclusions

The evolution of TazPod's backup system demonstrates how infrastructure optimization often requires looking beyond simple automation. The introduction of the plaintext hash sidecar allows us to sleep soundly thanks to historical S3 retention, without paying a financial and performance toll in redundant API calls due to the non-deterministic nature of AES-GCM encryption.
