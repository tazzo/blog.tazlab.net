+++
title = "TazPod Nomade: Il mio workspace personale su Proxmox accessibile da qualsiasi terminale"
date = 2026-06-30T06:00:00+02:00
draft = false
description = "Come ho trasformato un LXC su Proxmox in un ambiente di sviluppo completo, accessibile via SSH da notebook, tablet e Termux, con Tmux per sessioni persistenti."
tags = ["TazPod", "Proxmox", "LXC", "Tailscale", "Nomadic Computing", "DevOps", "Ansible"]
author = "Tazzo"
+++

## Il Problema: L'Ambiente di Lavoro Incatenato al Dispositivo

Per mesi ho lavorato con **TazPod** — un container Docker locale sul notebook che contiene il mio intero ambiente di sviluppo: vault cifrato, CLI Go per la gestione dei secrets, toolchain completa (kubectl, helm, terraform, flux, talosctl), e i tool AI (oh-my-pi, pi-coding-agent, gemini-cli, opencode). Funziona. Ma ha un limite strutturale: è legato al notebook.

Se voglio lavorare dal tablet? Devo configurarlo da capo. Dal cellulare via Termux? Stessa storia. In più, se il notebook si scarica o si rompe, perdo la sessione in corso e tutto l'ambiente.

La soluzione che cercavo: un'istanza di TazPod sempre accesa, raggiungibile da qualsiasi dispositivo, con la stessa identica toolchain, gli stessi secrets, la stessa configurazione. Un workspace nomade, che sopravvive al singolo dispositivo.

## Le Alternative: Tre Strade per un Container su Proxmox

Avevo già un nodo **Proxmox VE 9** su un mini PC (32 GB RAM, storage LVM-thin) che ospita il cluster Kubernetes (Talos, due VM) e un LXC con Hermes Agent. Aggiungere un LXC per TazPod era il passo naturale.

Ho valutato tre approcci:

### Opzione A: Docker-in-LXC

La più ovvia: installare Docker in un LXC unprivilegiato e farci girare `tazpod up` esattamente come sul notebook.

**Pro**: Zero modifiche a TazPod. `tazpod up` crea il container Docker come sempre.

**Contro**: Docker-in-LXC unprivilegiato è fragile. Il driver overlay2 su LVM-thin fallisce a `vfs` con IOPS scarse. Il networking triplo (LXC → bridge Docker → Tailscale) introduce problemi di MTU (già noti come TD-018 sul notebook). La RAM overhead del Docker daemon (~300 MB) si somma a quella dell'LXC.

### Opzione C: Rootless Podman sulla VM Hetzner

Co-locare TazPod sulla VM Hetzner CX23 (4 GB RAM) dove già gira Vault, usando Podman rootless con un utente separato.

**Pro**: Nessuna LXC complexity. La VM è già sulla tailnet. S3 low-latency (stessa regione AWS).

**Contro**: La CX23 ha 4 GB RAM totali — Vault (~400 MB) + OS + Tailscale + TazPod lasciavano poco margine per tool interattivi. Rootless Podman non supporta `--network host` e `CAP_SYS_ADMIN`, fondamentali per il vault tmpfs e Tailscale TUN.

### Opzione B: Bare-metal LXC (Scelta Finale)

Installare TazPod direttamente in un LXC, senza Docker. Il LXC *è* il container — nessun layer Docker intermedio.

**Pro**: Zero overhead Docker. Networking pulito (LXC → Tailscale diretto). Pattern già validato da Hermes (Pet vs Cattle per la persistenza). La toolchain si installa via Ansible, identica ai layer Docker.

**Contro**: TazPod è nato come orchestratore Docker. Il lifecycle (`up/down/enter`) non ha senso in un LXC — si entra via SSH.

La scelta è caduta sull'Opzione B non solo per i vantaggi tecnici, ma anche perché mi ha permesso di ridefinire il ruolo di TazPod: non più un gestore di container Docker, ma un **CLI di vault management + sync daemon** che funziona identico in Docker e in LXC, semplicemente leggendo `mode: lxc` nel config.

> **LXC (Linux Containers)**: Un metodo di virtualizzazione a livello di sistema operativo che condivide il kernel dell'host ma isola i processi in namespace separati. A differenza dei container Docker, un LXC non richiede un daemon centralizzato e ha networking nativo sull'interfaccia di bridge dell'host. È la scelta standard di Proxmox per container leggeri.

## L'Architettura: Pet vs Cattle per la Persistenza

La sfida principale dei container LXC su Proxmox è la persistenza dei dati. Quando distruggi un CT con `terraform destroy`, Proxmox elimina TUTTI i volumi associati a quel VMID — anche quelli che pensavi fossero "esterni". L'API Proxmox non ha un flag `destroy-unreferenced-disks=0` per gli LXC (esiste solo per VM QEMU).

La soluzione è il pattern **Pet vs Cattle**, già validato per Hermes:

```
CT 999 — il "pet" (protection=1)
  └── Possiede i volumi persistenti: vm-999-disk-1, vm-999-disk-2
      Mai distrutto da Terraform.

CT 106 — il "cattle" (protection=0)
  └── Monta vm-999-disk-2 via mp0
      Distrutto e ricreato normalmente.
      Il volume SOPRAVVIVE perché è di proprietà del CT 999.
```

> **LVM-thin ownership**: Su Proxmox, ogni volume LVM-thin è legato al VMID del container che lo ha creato. Se distruggi il CT, Proxmox cerca tutti i volumi con prefisso `vm-<VMID>-` e li elimina. Un volume creato da CT 999 (`vm-999-disk-2`) sopravvive anche se il CT 106 che lo monta viene distrutto.

Il volume pet è montato su `/workspace` — che diventa la directory di lavoro persistente. Dentro, una struttura identica a quella del TazPod Docker:

```
/workspace/
├── .tazpod/           ← vault + tool configs (sopravvive)
├── ephemeral-castle/  ← progetti (sopravvivono)
├── tazpod/
├── AGENTS.ctx/
└── altri repo…
```

## La Svolta: Dual-Mode nel Codice Go

La modifica più significativa a TazPod è stata l'introduzione del **dual-mode**. Un singolo binary, compilato una volta, che si comporta diversamente in base al campo `mode` nel `.tazpod/config.yaml`:

```yaml
mode: lxc        # "docker" (default) o "lxc"
```

In modalità `lxc`, sei funzioni del lifecycle diventano no-op con un messaggio chiaro:

```go
func up() {
    if cfg.Mode == "lxc" {
        fmt.Println("⚠️  'up' is not available in LXC mode — the container is always running.")
        fmt.Println("   SSH into it directly: ssh tazpod@<IP>")
        return
    }
    // ... codice Docker esistente, invariato
}
```

Le funzioni che contano — `unlock`, `lock`, `save`, `push`, `pull` — non guardano `mode` per niente. Il vault (`vault.go`), la crittografia (`crypto.go`) e il sync S3 (`s3.go`) sono puri processi Go, senza dipendenze Docker. Funzionano identici in entrambi gli ambienti.

Il TazPod locale sul notebook continua a funzionare esattamente come prima — `mode` è vuoto (default: `"docker"`), nessuna guardia si attiva. Il nuovo LXC usa `mode: lxc`. Stesso binary, stesso CI, nessun build tag.

## I Problemi Incontrati

### 1. Glibc: Il Drama di tree-sitter

Il primo CT 106 è nato su **Debian 12** (glibc 2.36). Tutto funzionava tranne il parsing tree-sitter in Neovim/LazyVim: `tree-sitter-cli` richiede glibc 2.39+.

La diagnosi è stata semplice: `ldd --version | head -1` mostrava glibc 2.36, e `tree-sitter --version` falliva con `GLIBC_2.39 not found`. La soluzione poteva essere installare una versione vecchia di tree-sitter (che però richiedeva comunque glibc recente), compilare da sorgente (richiede Rust, che non avevamo), o cambiare base del container.

Ho scelto la soluzione più pulita: distruggere il CT 106 e ricrearlo con **Ubuntu 24.04** (glibc 2.39). Il rootfs è passato da 10 GB a 20 GB (il disco di Debian 12 era al 100%). L'Ansible idempotente ha reinstallato tutto in 7 minuti.

```
Prima: Debian 12 — glibc 2.36 — 10 GB (100% pieno)
Dopo:  Ubuntu 24.04 — glibc 2.39 — 20 GB (42% usato)
```

### 2. TUN Device in LXC Unprivilegiato

Tailscale richiede `/dev/net/tun`. In un LXC unprivilegiato, il TUN device non è disponibile per default. La configurazione va aggiunta manualmente in `/etc/pve/lxc/106.conf`:

```ini
features: nesting=1,keyctl=1

lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file

lxc.cap.drop: sys_rawio
lxc.cap.drop: sys_module
```

Senza `nesting=1` e il device TUN, Tailscale può solo funzionare in `--tun=userspace-nic` (modalità userspace), che ha performance inferiori. Con l'entry e il cgroup, il TUN device viene passato dal kernel host al container in modo trasparente.

### 3. GRO/GSO Bug e DNS

Un problema che si presenta solo in LXC è il **GRO/GSO bug**: i driver veth virtuali dichiarano falsamente supporto GSO completo. Tailscale invia pacchetti UDP di 64 KB che il bridge reale non sa frammentare, causando black hole. La soluzione è un systemd oneshot:

```bash
/sbin/ethtool -K eth0 rx-gro-list off rx-udp-gro-forwarding on
```

Il DNS è un altro tema spinoso. Proxmox sovrascrive `/etc/resolv.conf` a ogni riavvio, cancellando il nameserver MagicDNS di Tailscale (100.100.100.100). La soluzione: `touch /etc/.pve-ignore.resolv.conf` e nameserver fissi via `resolvectl dns eth0 1.1.1.1 8.8.8.8`.

## La Toolchain: 65 Task Ansible per Replicare Quattro Layer Docker

La parte più laboriosa è stata replicare i **quattro layer del Dockerfile TazPod** (base, aws, k8s, ai) come playbook Ansible idempotente. Ogni task ha un check `creates:` che evita re-installazioni:

Il risultato: 65 task, 6 file organizzati per layer, **zero errori** al completamento. Ogni tool — da Go 1.25 a Node 24/NVM, da kubectl a talosctl, da oh-my-pi a opencode — è allineato con la versione del Docker TazPod.
## Il Flusso di Lavoro Nomade

1. **Dal notebook**: SSH su `tazpod@192.168.1.206`, `tmux`, e ho tutto l'ambiente
2. **Dal tablet (Termux)**: stesso comando, stessa sessione (grazie a Tmux)
3. **Da Termux sul cellulare**: `ssh tazpod@tazpod-proxmox`, mi attacco alla sessione Tmux in corso
4. **Se il mini PC è giù**: `tazpod up` sul notebook, l'istanza Docker locale parte come fallback

Il vault dei secrets è lo stesso per entrambe le istanze: cifrato con AES-256-GCM, synchronized su S3, montato in tmpfs con `tazpod unlock` su qualsiasi dispositivo.

> **Tmux**: Un terminal multiplexer che permette di avere sessioni persistenti. Puoi staccarti da una sessione (Ctrl+B d), chiudere il terminale, riconnetterti da un altro dispositivo e riattaccarti alla stessa sessione. È il cuore del flusso nomade.

## Conclusioni

La lezione più importante di questo progetto è che **il nomadismo operativo non richiede strumenti nuovi** — richiede di riconsiderare il punto di attacco. Non ho creato una nuova piattaforma. Ho preso un ambiente che era legato a un container Docker locale e l'ho reso accessibile da qualsiasi interfaccia di rete, usando strumenti esistenti: SSH, Tmux, Tailscale, un LXC su Proxmox.

Il pattern **Pet vs Cattle** per la persistenza su Proxmox si è rivelato universale: dopo Hermes, ora TazPod lo segue. La prossima volta che avrò bisogno di un servizio persistente in LXC, so già come strutturarlo.

Il dual-mode nel codice Go (`mode: lxc`) ha permesso di mantenere un unico binary per due ambienti molto diversi. Questo pattern è estendibile: in futuro, un TazPod su una VM cloud potrebbe usare `mode: cloud` o `mode: podman`.
