+++
title = "Debugging di un Timeout SSH su Tailscale Userspace: Anatomia di un Problema di Trasporto"
date = 2026-04-30T20:00:00+00:00
draft = false
description = "Un `apt-get install` remoto via SSH su Tailscale falliva sistematicamente dopo 76 secondi, qualsiasi altra operazione funzionasse. La soluzione ha richiesto di isolare il problema strato per strato, fino a scoprire un difetto nel trasporto del container operatore."
tags = ["Tailscale", "Docker", "SSH", "Networking", "Ansible", "Vault", "Debugging", "DevOps", "Home Lab"]
author = "Tazzo"
+++

## Il Contesto

Stavo lavorando al passaggio graduale della gestione dei segreti del cluster TazLab da Infisical a un'istanza Vault su una VM Hetzner. Il progetto — `09-vault-k8s-integration-prep` — era ben avanzato: la VM era operativa, Vault inizializzato e funzionante, il nome host su Tailscale convergeva sul MagicDNS `lushycorp-vault.magellanic-gondola.ts.net`, e il playbook Ansible aveva superato i primi cicli completi di destroy/create.

Ma la pipeline non era ancora abbastanza solida. Ogni tanto il `create.sh` si bloccava. Non in modo casuale, quasi sempre sugli stessi punti: un restart del servizio Vault, un task di fetch, un `apt install`. All'inizio sembravano problemi di playbook: handler `systemd_service` che non tornavano, "sessione SSH morta durante la riconnessione".

Dopo aver convertito in asincroni tutti i 7 task `systemd_service` sincroni e averlo spezzato in tre playbook separati — uno per l'installazione, uno per la convergenza vero e propria, uno per la finalizzazione post-convergenza — i miglioramenti c'erano, ma il problema non spariva del tutto.

Qualcosa non tornava.

## La Soglia dei 76 Secondi

Il passo successivo è stato rendere il problema misurabile. Ho costruito una **matrice di test** sistematica dall'interno del container TazPod verso la VM Hetzner, usando SSH puro:

| Operazione | Esito | Tempo |
|-----------|-------|-------|
| `echo ok` | ✅ | immediato |
| `sleep 120` | ✅ | 2 minuti |
| output continuo per 2 minuti | ✅ | 2 minuti |
| `curl` download di un file .deb da 8 MB | ✅ | ~1 minuto |
| `curl` limitato a 100k/s (80s) | ✅ | 80 secondi |
| `apt-get update` | ✅ | 4 secondi |
| `apt-get download awscli` | ✅ | 2 secondi |
| `sudo apt-get install --reinstall -y awscli` | ❌ | ~76 secondi |

Lo schema era chiarissimo: qualsiasi operazione superasse un certo **pattern di I/O** durante l'installazione dei pacchetti faceva collassare la connessione SSH.

Per escludere Ansible dalla diagnosi, ho ripetuto il test con SSH puro e verbose logging:

```bash
ssh -vvv -o ProxyCommand="tailscale --socket=... nc %h %p" \
  admin@<tailnet-ip> \
  "sudo apt-get install --reinstall -y awscli"
```

Risultato: stessa morte dopo ~76 secondi, identica sia via Ansible che via SSH diretto.

Il log `-vvv` mostrava uno schema preciso:

```
debug1: channel 0: new session
debug1: Entering interactive session.
debug2: exec request accepted on channel 0
debug2: channel 0: read failed ... Broken pipe
debug2: channel 0: send eof
debug3: send packet: type 80
debug3: send packet: type 80
...
Timeout, server <ip> not responding.
```

La connessione entrava in interactive session, il comando partiva, poi il canale SSH si rompeva con `Broken pipe`, seguito da ripetuti tentativi di keepalive e infine dal timeout.

## Cosa Funziona e Cosa Non Funziona

Il pattern escludeva molte ipotesi:

- **Non era la durata della sessione**: `sleep 120` passava senza problemi
- **Non era il volume di traffico**: `curl` di 8 MB per 80 secondi passava
- **Non era la larghezza di banda ridotta**: `curl` throttled a 100k/s passava
- **Non era Ansible**: SSH puro falliva allo stesso modo
- **Non era `apt` in sé**: `apt-get update` e `apt-get download` funzionavano
- **Non era l'ultimo task del playbook**: il problema si manifestava anche nei primi task dopo la connessione

Il salto logico più importante era questo: il fallimento avveniva specificamente durante `apt install`, non durante download, upload, o sleep lunga. C'era qualcosa nel pattern di I/O generato dall'installazione — scrittura su disco, scripts post-install, aggiornamento del database di dpkg — che faceva collassare il trasporto SSH via `tailscale nc`.

## Il Sospetto sul Trasporto

Il container TazPod esegue Tailscale in una configurazione particolare. Quando lo crei su Docker, non c'è `/dev/net/tun` — quindi Tailscale deve funzionare in **userspace networking mode**, un loop software che emula WireGuard senza un'interfaccia kernel. L'SSH verso la VM raggiunge il peer attraverso un ProxyCommand:

```bash
ssh -o ProxyCommand="tailscale nc %h %p" ...
```

Questo comando dice a SSH di non connettersi direttamente alla VM, ma di passare attraverso `tailscale nc`, che inoltra il traffico TCP sulla tailnet usando lo stack userspace.

La combinazione di tre livelli — **Docker bridge network** + **Tailscale userspace** + **ProxyCommand "nc"** — era un'architettura funzionale per comandi brevi, ma si rivelava fragile per operazioni che richiedevano una connessione stabile per minuti con burst di I/O.

La conferma più forte è arrivata quando ho confrontato lo stato del peer Tailscale tra sessioni "buone" e "cattive". Nei log storici di create precedenti di successo, il peer era spesso in stato `active; direct 178.104.84.205:41641` — cioè connessione diretta WireGuard. Nelle sessioni problematiche, il peer appariva in stato ambiguo, spesso via DERP relay, a volte con metadati inconsistenti tra ping e status.

Questo non provava che DERP fosse la causa, ma suggeriva che il path di trasporto non fosse pulito.

## Il Test Definitivo: Uscire dall'Userspace

A questo punto ho deciso di cambiare una variabile alla volta. La più grande era: "Cosa succede se eseguiamo Tailscale in modalità kernel, con un vero `/dev/net/tun`, invece che in userspace?"

Ho preparato un container di test con una configurazione diversa:

```bash
docker run -d --name tazpod-test \
  --network host \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  tazzo/tazpod-ai:latest \
  sleep infinity
```

Poi ho avviato Tailscale in modalità TUN normale, con un helper script che ora fa parte dell'immagine:

```bash
tazpod-tailscale-up
```

E ho ripetuto esattamente lo stesso test che prima falliva sempre:

```bash
ansible ... -m shell -a \
  'sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y awscli'
```

**Risultato: completato in 9 secondi.**

Stessa VM, stesso comando, stesso Ansible, stessi secret. L'unica differenza era il trasporto: non più `tailscaled --tun=userspace-networking` + `ProxyCommand tailscale nc`, ma una connessione diretta su tailnet attraverso il kernel WireGuard.

Il problema non era nel playbook, non era in Ansible, non era in `apt` o `dpkg`. Era nella combinazione di **userspace networking** e **ProxyCommand via nc** che, per ragioni ancora da investigare a fondo, non reggeva il workload di installazione dei pacchetti.

## La Pipeline Rinasce

Con la causa isolata, le modifiche sono state sorprendentemente contenute.

Il runtime del container TazPod ora usa di default:

- `--network host` — niente bridge Docker
- `--cap-add NET_ADMIN` — necessario per il TUN
- `--device /dev/net/tun` — l'interfaccia kernel

L'helper `tazpod-tailscale-up` avvia `tailscaled` in background, genera una chiave di autenticazione usando le stesse credenziali OAuth (con fallback su API key) già presenti nel vault, e connette il container alla tailnet.

L'inventory Ansible viene generato dinamicamente: se `/dev/net/tun` è presente, usa SSH diretto sul tailnet senza ProxyCommand; altrimenti torna alla vecchia via di `tailscale nc`. Questa logica di auto-rilevamento è nell'helper `render-tailscale-inventory.sh`.

Il playbook Vault, che prima era un monolite, è stato suddiviso in tre fasi con tempi separati:

| Fase | Durata |
|------|--------|
| Installazione runtime (pacchetti, config, servizio) | 175s |
| Convergenza (classificazione, restore, unseal, health) | 90s |
| Post-convergenza (token, backup, persistenza) | 38s |
| **Totale** | **~344s (5.7 min)** |

Il precedente tempo migliore era circa 1200 secondi (20 minuti) con frequenti blocchi. Il divario è sostanziale e, più importante, la pipeline è ora deterministica: zero timeout, zero UNREACHABLE, zero interventi manuali.

## Cosa Abbiamo Imparato

La prima lezione è stata metodologica. Il problema era nascosto sotto almeno tre strati di astrazione: creavo il container con TazPod, che avvia Docker, che non aveva `/dev/net/tun`, quindi Tailscale usava userspace, che obbligava a un ProxyCommand `nc`, e quello non reggeva certi pattern di traffico. Eravamo talmente abituati a questa configurazione da non considerarla più come possibile causa.

La seconda lezione è che i test di isolamento funzionano. Ridurre il problema fino a SSH puro, poi confrontare trasporti diversi (public SSH vs tailnet SSH, userspace vs TUN) ha dato una risposta chiara in poche ore. Se avessi continuato a "aggiustare" il playbook, sarei ancora al giro.

La terza lezione è che la modalità **userspace-networking** di Tailscale, pur straordinariamente utile per ambienti dove non hai privilegi di kernel (container su PaaS, Lambda, CI/CD), ha dei limiti operativi che ti si presentano solo dopo che il setup ha girato per ore. Non è un bug di Tailscale di per sé. È una combinazione di layer che insieme diventano fragili: Docker bridge nativo + userspace + ProxyCommand = una catena di dipendenze difficile da debuggare.

## Stato Attuale

La VM Hetzner Vault è operativa e la pipeline di creazione è stabile e misurabile. Il progetto `09-vault-k8s-integration-prep` ha chiuso la Phase 1 (convergenza runtime + validazione trasporto) con successo e tempo di esecuzione noto.

Il prossimo passo — Phase 2 — riguarda il lato cluster: configurare CoreDNS per risolvere correttamente il nome `lushycorp-vault.magellanic-gondola.ts.net` nella tailnet, creare il ClusterSecretStore in Kubernetes per leggere i segreti da Vault, e verificare il tutto con uno smoke test ESO.

Ma questa è un'altra giornata di lavoro.
