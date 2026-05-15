+++
title = "Pet vs Cattle su Proxmox LXC: Come Ottenere Persistenza PVC-like con Solo API Token"
date = 2026-05-15T14:00:00+02:00
draft = false
tags = ["Proxmox", "LXC", "Terraform", "Ansible", "Hermes", "LVM-thin", "Storage", "Persistenza"]
description = "Deploy di Hermes Agent su Proxmox LXC. Dalla scelta bare-metal contro Docker, al 403 dei bind-mount, fino alla soluzione Pet vs Cattle per la persistenza dei dati su LVM-thin."
author = "Tazzo"
+++

## Il Problema: Dati Persistenti su Container Effimeri

Deployare un AI Agent (Hermes Agent) su un container LXC Proxmox sembrava un'attività lineare: installa il software, configura i servizi, funziona. Il problema è emerso dopo, quando ho dovuto affrontare la domanda: cosa succede ai dati quando il container viene distrutto e ricreato?

In Kubernetes, questa domanda ha una risposta standard: i PersistentVolumeClaim (PVC) separano il ciclo di vita del dato dal ciclo di vita del pod. Su Proxmox LXC, non esiste un equivalente diretto. O meglio, esistono diverse strade, ma ognuna ha limiti precisi che ho scoperto sperimentando.

Questo articolo racconta il percorso che mi ha portato dalla scelta architetturale iniziale fino a una soluzione di persistenza funzionante, passando per tre ricerche approfondite e altrettanti tentativi scartati.

## Il Container: Bare-metal, non Docker

La prima decisione è stata come installare Hermes all'interno del LXC. Le alternative erano tre.

**Docker-in-LXC** era la strada più ovvia, ma nascondeva un problema: nei container LXC unprivilegiati con storage ZFS, il driver overlay2 di Docker degrada a vfs, un driver senza supporto copy-on-write con IOPS drasticamente inferiori. La soluzione (un volume Ext4 su zvol) aggiungeva complessità senza un reale beneficio in questo contesto.

**Rootless Docker** aveva un limite strutturale più serio: `network_mode: host` in rootless Docker non espone la rete reale del container, ma una rete isolata da RootlessKit. Gateway e dashboard di Hermes, che comunicano su localhost, si sarebbero trovati in namespace di rete distinti — una configurazione instabile.

La scelta finale è stata il **bare-metal diretto**: eseguire `install.sh` di Hermes direttamente nel LXC. La sandbox dei terminali è gestita dall'hardening del container stesso: cap drop, AppArmor attivo, mount read-only di `/proc` e `/sys`, utente non-root `hermes` (UID 10000, nessun sudo).

```
features {
    nesting = true
}
```

L'unica feature extra è `nesting`, necessaria per i subprocessi interni di Hermes.

## Il Primo Ostacolo: install.sh e SSH Keepalive

Il playbook Ansible che installa Hermes esegue `install.sh` con `--skip-setup`. Il problema è che `install.sh` non è veloce: installa Python 3.11 via uv (~80MB), Node.js 22 (~30MB), centinaia di dipendenze Python con `uv sync --extra all`, e le dipendenze npm per la Web UI. Il tempo totale è di **5-10 minuti**.

Ansible esegue i comandi via SSH, e SSH di default non ha keepalive. Dopo 2-3 minuti senza output, la connessione cade. Ansible rimane in attesa indefinitamente senza segnalare l'errore — mostra solo "TASK [agent : Execute Hermes install.sh]" senza mai completare.

Ho diagnosticato il problema guardando i log del demone SSH sul container: la connessione veniva chiusa per inactivity timeout. La soluzione è stata aggiungere keepalive alla configurazione Ansible:

```ini
[ssh_connection]
ssh_args = -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ConnectTimeout=10
```

Con questo fix, la connessione SSH resta attiva e `install.sh` completa in circa 159 secondi. Ho anche pre-installato le dipendenze Playwright (25+ pacchetti) nel playbook baseline di Ansible, per evitare che i subprocessi di `apt-get` rimanessero sospesi in contesto non interattivo.

## Il Secondo Ostacolo: Bind-mount e il Muro 403

Una volta che Hermes era installato e funzionante (gateway e dashboard su `192.168.1.205:9119`), ho affrontato la persistenza dei dati. Il pattern standard nel resto dell'ecosistema TazLab è il bind-mount: una directory host montata nel container. La configurazione Terraform era:

```hcl
mount_point {
  volume = "/mnt/hermes_data"
  path   = "/home/hermes"
  backup = true
}
```

Proxmox restituiva **HTTP 403 Forbidden**. L'ispezione ha rivelato che i bind-mount via API sono consentiti solo per utenti autenticati via password (`root@pam`), non tramite token API. È un limite di sicurezza voluto, che però blocca l'automazione IaC.

Ho quindi adottato un **volume gestito** su `local-lvm` tramite il provider Terraform `bpg/proxmox`:

```hcl
mount_point {
  volume = "local-lvm"
  size   = "10G"
  path   = "/home/hermes"
  backup = true
}
```

Questo funziona — il volume viene creato e montato correttamente. Ma c'è un problema: i thin volume LVM sono legati al ciclo di vita del container. Quando il container viene distrutto da `terraform destroy`, il volume viene distrutto con esso.

## Tre Ricerche per un Problema che Sembrava Semplice

Ho condotto tre sessioni di ricerca per trovare un modo di preservare il volume oltre il ciclo di vita del container. Ecco cosa ho scoperto.

### Prima Ricerca: La Sintassi dell'API

La chiamata API per staccare un volume funziona: `PUT /config -d "delete=mp0"`. Ma riattaccarlo su un container esistente è più complesso. L'errore "duplicate key in comma-separated list property: volume" che ottenevo era dovuto a un problema di formato: usavo `size=10G` insieme al riferimento a un volume esistente, creando un conflitto interno nel parser di Proxmox.

La sintassi corretta per montare un volume esistente è:

```bash
curl -sk -X PUT "https://proxmox:8006/api2/json/nodes/tazlab/lxc/105/config" \
  --data-urlencode "mp0=local-lvm:vm-105-disk-1,mp=/home/hermes"
```

Niente `size`, niente `backup`. Quando si referenzia un volume esistente, questi parametri sono opzionali e, se presenti, causano conflitti.

### Seconda Ricerca: L'Ownership LVM-thin

Il problema fondamentale è che Proxmox 9.1, durante la distruzione di un container, **scansiona sempre lo storage** alla ricerca di volumi con nome `vm-<vmid>-disk-*`, indipendentemente dal fatto che siano ancora montati o meno. Anche dopo aver staccato il volume con `delete=mp0`, la chiamata `DELETE /nodes/{node}/lxc/{vmid}` lo elimina comunque.

Il parametro `destroy-unreferenced-disks=0` non è onorato per i container LXC in Proxmox 9.1 (funziona solo per le VM QEMU). Il provider Terraform `bpg/proxmox` v0.106 non espone questo flag per la risorsa LXC.

### Terza Ricerca: Perché Tutte le Strade Portano a un Vicolo Cieco

- **Bind-mount via API**: bloccato (403 per token, solo root@pam)
- **`protection=1`**: blocca il delete del container, ma anche la rimozione selettiva del compute
- **Rinomina volume via API**: non esiste un endpoint `lvrename` esposto via REST
- **ZFS**: non disponibile su questo host (singolo disco 476G, tutto allocato a LVM)
- **Riassegnazione volume (`move_volume`)**: endpoint instabile per rename in-place su stesso storage

La conclusione delle tre ricerche è stata: **con solo token API, un volume LVM-thin non può sopravvivere alla distruzione del suo container**. La proprietà nominale (il nome `vm-105-disk-1`) lo lega indissolubilmente al container 105.

## La Soluzione: Pet vs Cattle

L'unica via percorribile è stata cambiare la proprietà del volume. Se il volume si chiama `vm-105-disk-1`, Proxmox lo distrugge con CT 105. Se si chiama `vm-999-disk-1`, sopravvive perché appartiene a un altro container.

Ho creato un **container segnaposto** (CT 999, chiamato "pet-storage") con `protection=1`, che non verrà mai distrutto. Questo container possiede un volume di 10GB (`local-lvm:vm-999-disk-1`). Il container Hermes (CT 105, il "cattle") monta questo volume come se fosse un filesystem esterno.

La configurazione Terraform del pet è minima:

```hcl
resource "proxmox_virtual_environment_container" "pet_storage" {
  vm_id      = 999
  protection = true
  # 1 core, 256MB RAM, 2G rootfs — sufficiente per esistere
  ...
  mount_point {
    volume = "local-lvm"
    size   = "10G"
    path   = "/mnt/hermes-volume"
    backup = true
  }
}
```

Il container Hermes (CT 105) viene creato da Terraform **senza** mount_point. Il volume viene attaccato via API in una fase separata, dopo la creazione:

```bash
# Ferma il container
curl -X POST "https://proxmox:8006/api2/json/nodes/tazlab/lxc/105/status/stop"

# Attacca il volume del pet
curl -X PUT "https://proxmox:8006/api2/json/nodes/tazlab/lxc/105/config" \
  --data-urlencode "mp0=local-lvm:vm-999-disk-1,mp=/home/hermes"

# Riavvia il container
curl -X POST "https://proxmox:8006/api2/json/nodes/tazlab/lxc/105/status/start"
```

Sulla distruzione, il volume viene prima staccato, poi il container distrutto:

```bash
curl -X PUT "https://proxmox:8006/api2/json/nodes/tazlab/lxc/105/config" -d "delete=mp0"
terraform destroy
```

Il volume `vm-999-disk-1` sopravvive a ogni ciclo, perché Proxmox cerca volumi `vm-105-disk-*` durante la distruzione — e non trova nulla.

## Il Ciclo Completo in 137 Secondi

Con il pattern Pet vs Cattle, il ciclo destroy/create è più veloce del backup/restore perché Hermes è già installato sul volume persistente (niente reinstall da zero). Le tempistiche:

```
FASE                              DURATA
─────────────────────────────────────────
0. Pet Volume Ensure                  2s
1. Terraform Create                  11s
2. Wait SSH                          15s
3. Attach Volume                      8s
4. Ansible Baseline                  56s
5. Ansible Agent (idempotente)       30s
6. Ansible Configure                  6s
7. Ansible Verify                     9s
─────────────────────────────────────────
TOTALE                              137s  (2 min 17s)
```

## Lezioni Imparate

1. **L'API Proxmox ha limiti precisi sui mount point**. Bind-mount richiede root@pam, i volumi LVM-thin sono legati al VMID, e non esiste un modo per preservarli con una semplice flag. Ho perso tempo a cercare un parametro inesistente, quando la soluzione era cambiare architettura.

2. **Il naming LVM è la chiave della persistenza**. Su LVM-thin, la proprietà del volume è determinata dal nome (`vm-<vmid>-disk-*`). Capire questo meccanismo mi ha permesso di progettare la soluzione Pet vs Cattle, che non è altro che una riassegnazione nominale della proprietà.

3. **Tre ricerche sono state necessarie per escludere tutte le alternative**. Bind-mount, `destroy-unreferenced-disks`, `protection`, ZFS, rename API: ognuna aveva un motivo per non funzionare nel mio setup (token API, LVM-thin, singolo disco). Sapere cosa NON funziona è stato importante quanto trovare la soluzione.

4. **Il pattern Pet vs Cattle è riutilizzabile**. Un singolo pet (CT 999) può possedere N volumi, ognuno montabile su cattle diversi. Per estendere la persistenza ad altri servizi, basta aggiungere un mount_point al pet e montarlo via API sul cattle corrispondente.

Il codice sorgente e la documentazione completa sono disponibili su `github.com/tazzo/ephemeral-castle`, nella directory `hermes/`. Le tre ricerche sono documentate in `AGENTS.ctx/crisp-build/assets/`.
