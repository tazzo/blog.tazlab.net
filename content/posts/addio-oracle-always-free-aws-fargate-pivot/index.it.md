+++
title = "Addio Oracle Always Free: Perché Lushy Corp sceglie la semplicità di una VPS"
date = 2026-03-31T10:18:20+01:00
draft = false
description = "Cronaca tecnica di un fallimento necessario: come i limiti di OCI Always Free ci hanno spinto verso la versatilità e la stabilità di una VPS dedicata su Hetzner."
tags = ["Hetzner", "VPS", "OCI", "Vault", "Tailscale", "DevOps", "Docker"]
author = "Tazzo"
+++

## L'illusione del \"Gratis\" e la Ricerca della Resilienza

L'obiettivo iniziale era nobile, quasi romantico: costruire un cluster **HashiCorp Vault** enterprise-grade, totalmente privato, sfruttando le generose risorse \"Always Free\" di **Oracle Cloud Infrastructure (OCI)** a Torino. Avevo pianificato tutto: istanze Ampere ARM64 con 4 core e 24GB di RAM, **Talos Linux** come sistema operativo immutabile e **Tailscale** per una connettività zero-trust senza ingressi pubblici.

Sulla carta, era il piano perfetto per ospitare quello che, in questa sessione di lavoro, è stato battezzato per errore **Lushy Corp**.

Prima di entrare nei dettagli tecnici, lasciatemi spiegare questo nome. **Lushy Corp** non è un nuovo gigante del tech, ma il soprannome nato da un errore di battitura mentre interagivo con l'agente AI. Cercavo di scrivere \"HashiCorp Vault Container\", ed è uscito \"LushyCorp\". Da quel momento, lo scrigno dei segreti di TazLab, quello che dovrà gestire la rotazione delle chiavi e la sicurezza del cluster, è diventato ufficialmente il progetto **Lushy Corp**.

Ma un brand simpatico non basta a far girare un'infrastruttura. Dopo 24 ore di \"trincea\" tecnica su OCI, ho dovuto ammettere che l'illusione del costo zero si scontrava con una realtà troppo precaria per ospitare i segreti di produzione.

## La Trincea di Torino: Loop, Capacity e Metadati Fantasma

### La Guerra per la Capacità Ampere
Il primo muro di gomma è stato il famigerato `Out of host capacity` di OCI nella region `eu-turin-1`. Le risorse ARM64 di Oracle sono merce rara. Ho dovuto implementare un loop di provisioning aggressivo, capace di tentare la creazione delle istanze ogni 30 secondi, sperando di \"catturare\" un core nel momento esatto della sua liberazione.

### Il Bug dell'Architettura \"None\"
Le istanze raggiungevano lo stato `RUNNING`, ma il sistema operativo Talos non dava segni di vita. Dopo un'analisi forense dei metadati tramite OCI CLI, ho scoperto un errore critico: l'immagine custom ARM64 era stata importata con il campo `Architecture` impostato a `None`. Il bootloader UEFI falliva istantaneamente cercando di avviare codice ARM come se fosse x86.

## Il Punto di Rottura: Perché Always Free non è per noi

Nonostante fossi riuscito a ottenere le VM e a correggere i bug di boot, è emersa una verità architetturale ineludibile: **i segreti di Lushy Corp non possono stare su fondamenta di sabbia.**

La policy di Oracle per le istanze Always Free prevede lo spegnimento (o la reclaim) delle risorse in caso di basso utilizzo. Per un servizio come Vault, che per gran parte del tempo \"aspetta\" silente di servire una chiave, questo è un rischio catastrofico. Ho deciso che la stabilità operativa di Lushy Corp vale più del risparmio di qualche euro al mese.

## La Nuova Rotta: La Semplicità Versatile di una VPS Dedicata

Ho deciso di virare verso una soluzione più classica, pragmatica e versatile: una **VPS dedicata su Hetzner**. Inizialmente avevamo valutato AWS Fargate, ma la flessibilità di una vera macchina virtuale Linux ha vinto per diverse ragioni:

1.  **Versatilità del Lab**: Una VPS con Debian o Ubuntu non serve solo a Vault. Possiamo utilizzarla per ospitare altri piccoli servizi o utility di TazLab, ottimizzando al massimo il costo mensile.
2.  **Tailscale Nativo**: Invece di lottare con sidecar e proxy userspace, installiamo Tailscale come servizio di sistema. Questo ci dà una vera interfaccia `tun` e una gestione della rete standard, molto più robusta e semplice da debuggare.
3.  **Runtime Standard (Docker/Podman)**: Facciamo girare Vault come container gestito da Docker o Podman. È un setup ultra-collaudato, facile da aggiornare e da migrare.
4.  **Costo Certo e Bassissimo**: Con circa 4-5€ al mese, Hetzner garantisce risorse che non verranno mai spente arbitrariamente. È il prezzo della pace mentale per la sicurezza di Lushy Corp.

## Conclusione: Fallire Velocemente per Costruire Meglio

Questa sessione di lavoro si conclude con un apparente fallimento: il cluster OCI è stato \"nuclearizzato\" e rimosso. In realtà, è stato un successo strategico. Abbiamo identificato i limiti di una piattaforma e tracciato una rotta verso una soluzione che è il perfetto compromesso tra professionalità, semplicità e controllo totale.

L'era di **Lushy Corp** inizia ora, su una solida base Linux, pronta a servire segreti 24/7.

Prossima fermata: Provisioning su Hetzner.
