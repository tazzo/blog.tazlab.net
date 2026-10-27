---
title: "Il PC si è rotto: due giorni per portare la casa su Hetzner"
date: 2026-10-28
draft: true
tags: ["homelab", "hetzner", "terraform", "vault", "gitops", "disaster-recovery"]
---

> Materiale di lavoro: fatti misurati, numeri e lezioni. Da riscrivere in prosa.

## Il guasto

Il PC che teneva il cluster di casa si spegne per surriscaldamento. Non è un disco, non è un
aggiornamento: è la macchina che non regge più. La casa (Proxmox, i container, il cluster) sta lì.

Decisione: **spostare tutto su Hetzner**, e farlo mentre il PC è acceso a singhiozzo. La regola che
ha guidato tutto: si salva prima ciò che non è ricostruibile, poi si ripara il resto.

## Cosa viveva lì (e cosa era ricostruibile)

| cosa | stato |
|---|---|
| il cluster Kubernetes (era su Proxmox) | **stateless**: tutto in git + un DB |
| Vault | su una VM Hetzner (già fuori casa) |
| Ambrogio + Ambrogio Memory | **stato vero**: due SQLite (`ambrogio.db`, `memory.db` 135 MB) |
| ADA (la casa degli agenti) | **stato vero**: `agent.sqlite` 450 MB, + codice con 125 commit mai pushati |
| wg-easy (VPN) | config con le chiavi dei client |
| 21 repository | tre con commit non pushati |

## Il salvataggio, in ordine

1. **Tarball delle home** da CT106 e CT110 (ambrogio, memory, ADA, `/etc/ada`), più i binari.
2. **Git**: 21 repo controllati, tre erano avanti — `ada` **+125 commit** (con un bare locale dentro
   il container: non aveva *mai* visto GitHub), `tazpod` +1, `tazlab-secrets` +16. Presi come bundle,
   poi pushati dal laptop con il token di gopass.
3. **Database**: `sqlite3 .backup`, **non `cp`**. Il primo tentativo a motore acceso dava
   `entries 22016 / max_id 46040` contro `22020 / 46048`: quattro scritture in mezzo. Rifatto a motore
   fermo: `22022 = 22022`, `max_id 46052 = 46052`, `integrity_check ok`, 518 MiB, sha256 `db19d75f…`.
4. **Segreti**: mai nel backup. Solo i nomi; i valori in gopass (`vpn/wg-easy/wg0.conf`, `wg0.json`).
5. **Spegnimento**: container fermati, poi `systemctl --force poweroff` (il primo shutdown si era
   impuntato su unità in attesa).

## Il recupero del cluster (quello che nessuno racconta)

La catena di segreti non partiva. Sei guasti, in ordine di comparsa:

1. **`gopass show -o` tronca i segreti multilinea**: la CA di Vault arrivava a Kubernetes come
   `-----BEGIN CERTIFICATE-----`, 27 byte. VSO: *no valid certificates found*. gopass era innocente.
2. **DNS tailnet**: i pod non risolvono `*.ts.net`; risolto puntando VaultConnection al proxy egress
   (`…tailscale.svc.cluster.local`) con `tlsServerName` sul nome MagicDNS.
3. **Mount JWT mai creato** (`jwt-hcloud`): Vault aveva solo il backend del Proxmox.
4. **Ruoli per-componente** assenti sul backend nuovo.
5. **`bound_issuer`**: il token Talos porta l'endpoint del cluster in `iss`, e Vault confronta
   verbatim — una lista separata da virgole non matcha.
6. **Record DNS** di `dex`, `auth`, `ambrogio` ancora sull'IP di casa.

Più il **DB**: PGO ripristina `dataSource` solo alla nascita di un instance set. Non è un
comportamento automatico. Su Proxmox i dati stavano sul volume, e il blocco era stato **rimosso**
prima dell'upgrade PG16→17. Qui il volume era nuovo: DB vuoto. Restore fatto a mano da S3
(full 25/10 + diff 26/10), poi reso **dichiarativo**: `dataSource` nel manifest condiviso, pinnato a
`--set=${postgres_restore_set:=…}`, così una rinascita su entrambi i target si comporta uguale.

## I numeri finali

```
Flux 26/26 · VaultStaticSecrets 14/14 · PKI 7/7
blog/wiki/teaching/halloween = 200 (TLS Let's Encrypt) · apex 301
DB: 245 conversazioni · 20 752 entry · 1 238 documenti · 19 643 task
VM Vault: CX23 (2 vCPU, 4 GB, 40 GB) · Vault 50 MB, auto-unseal locale
```

## Le lezioni (quelle che valgono l'articolo)

- **Un file che si apre non è un backup**: si verifica con `integrity_check` *e* confrontando
  `count(*)`/`max_id` col vivo.
- **`.backup`, mai `cp`**: con il WAL attivo una copia del file principale è incoerente; e un
  `.backup` di un DB scritto di continuo riparte a ogni commit (livelock).
- **La CA in gopass c'era**: il bug era il flag che la leggeva.
- **Il restore non è automatico**: se lo vuoi idempotente su due piattaforme, lo dichiari nel manifest.
- **L'accesso è un segreto come gli altri**: senza la chiave giusta si entra in rescue mode (e
  l'auto-unseal di Vault rende il riavvio un evento, non un rischio).
