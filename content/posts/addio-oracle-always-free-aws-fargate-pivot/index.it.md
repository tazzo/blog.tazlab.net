+++
title = "Addio Oracle Always Free: Perché Lushy Corp trasloca su AWS Fargate"
date = 2026-03-30T18:15:22+01:00
draft = false
description = "Cronaca tecnica di un fallimento necessario: come i limiti di OCI Always Free ci hanno spinto verso un'architettura Vault serverless e resiliente su AWS Fargate."
tags = ["AWS", "Fargate", "OCI", "Vault", "Tailscale", "DevOps", "Serverless"]
author = "Tazzo"
+++

## L'illusione del "Gratis" e la Ricerca della Resilienza

L'obiettivo iniziale era nobile, quasi romantico: costruire un cluster **HashiCorp Vault** enterprise-grade, totalmente privato, sfruttando le generose risorse "Always Free" di **Oracle Cloud Infrastructure (OCI)** a Torino. Avevo pianificato tutto: istanze Ampere ARM64 con 4 core e 24GB di RAM, **Talos Linux** come sistema operativo immutabile e **Tailscale** per una connettività zero-trust senza ingressi pubblici.

Sulla carta, era il piano perfetto per ospitare quello che, in questa sessione di lavoro, è stato battezzato per errore **Lushy Corp**.

Prima di entrare nei dettagli tecnici, lasciatemi spiegare questo nome. **Lushy Corp** non è un nuovo gigante del tech, ma il soprannome nato da un errore di battitura mentre interagivo con l'agente AI. Cercavo di scrivere "HashiCorp Vault Container", ed è uscito "LushyCorp". Da quel momento, lo scrigno dei segreti di TazLab, quello che dovrà gestire la rotazione delle chiavi e la sicurezza del cluster, è diventato ufficialmente il progetto **Lushy Corp**.

Ma un brand simpatico non basta a far girare un'infrastruttura. Dopo 24 ore di "trincea" tecnica su OCI, ho dovuto ammettere che l'illusione del costo zero si scontrava con una realtà troppo precaria per ospitare i segreti di produzione.

## La Trincea di Torino: Loop, Capacity e Metadati Fantasma

### La Guerra per la Capacità Ampere
Il primo muro di gomma è stato il famigerato `Out of host capacity` di OCI nella region `eu-turin-1`. Le risorse ARM64 di Oracle sono merce rara. Ho dovuto implementare un loop di provisioning aggressivo, capace di tentare la creazione delle istanze ogni 30 secondi, sperando di "catturare" un core nel momento esatto della sua liberazione.

```bash
# Lo script di "guerriglia" per catturare i core Ampere
until oci compute instance launch --compartment-id "$COMP_ID" \
    --availability-domain "$AD" --display-name "tazlab-vault-cp-01" \
    --image-id "$IMAGE_ID" --shape "VM.Standard.A1.Flex" \
    --shape-config '{"ocpus": 1, "memoryInGBs": 4}' \
    --subnet-id "$SUBNET_ID" --private-ip "10.0.1.100" \
    --metadata "{\"user_data\": \"$(base64 -w0 < cp-config.yaml)\"}" 2>/dev/null; do
    echo "⏳ OCI: Out of capacity. Retrying..."
    sleep 30
done
```

Dopo centinaia di tentativi, le istanze finalmente raggiungevano lo stato `RUNNING`. Ma qui è iniziata la vera discesa nell'abisso del troubleshooting.

### Il Bug dell'Architettura "None"
Le istanze erano accese, ma il sistema operativo Talos non dava segni di vita. Niente log sulla console seriale, niente registrazione sulla mesh Tailscale. Dopo un'analisi forense dei metadati dell'immagine tramite OCI CLI, ho scoperto un errore critico: l'immagine custom ARM64 era stata importata con il campo `Architecture` impostato a `None`.

OCI vedeva l'istanza come attiva, ma il bootloader UEFI falliva istantaneamente perché cercava di avviare codice ARM come se fosse x86. È stato necessario un **Nuclear Wipe** del compartimento e una re-importazione manuale dell'immagine forzando i metadati corretti.

### La "Bruciatura" delle chiavi Tailscale
Un altro problema insidioso è stato il consumo delle chiavi di autenticazione di Tailscale. Usando chiavi monouso (single-use), ogni reboot forzato per sbloccare la rete "consumava" la chiave. Al boot successivo, Talos provava a registrarsi ma veniva rifiutato. La soluzione è stata passare a chiavi **Reusable**, garantendo che i nodi potessero rientrare nella mesh anche dopo un reset hardware.

## Il Punto di Rottura: Perché Always Free non è per noi

Nonostante fossi riuscito a ottenere le VM e a correggere i bug di boot, è emersa una verità architetturale ineludibile: **i segreti di Lushy Corp non possono stare su fondamenta di sabbia.**

La policy di Oracle per le istanze Always Free prevede lo spegnimento (o la reclaim) delle risorse in caso di basso utilizzo della CPU o della memoria. Per un servizio come Vault, che per gran parte del tempo "aspetta" silente di servire una chiave, questo è un rischio catastrofico. Se il cluster Vault viene spento, i servizi dipendenti perdono l'accesso ai segreti, causando un downtime critico che richiederebbe un intervento manuale di unseal.

Ho deciso che la stabilità operativa di Lushy Corp vale più del risparmio di qualche euro al mese.

## La Nuova Rotta: AWS Fargate e la Fortezza Serverless

Ho deciso di virare verso un'architettura **Serverless su AWS**, utilizzando **ECS Fargate**. Questa scelta rappresenta un salto di qualità fondamentale per diverse ragioni:

1.  **Zero OS Management**: Non devo più preoccuparmi di aggiornare il kernel, gestire il firmware UEFI o lottare con bootloader corrotti. AWS gestisce l'infrastruttura sottostante; io gestisco solo il container Vault.
2.  **Affidabilità Garantita**: Fargate non spegne i container per inattività. Il servizio è sempre "caldo" e pronto a rispondere.
3.  **Persistence via EFS**: Utilizzeremo **Amazon EFS (Elastic File System)** come storage backend per Vault Raft. Questo garantisce che i dati siano replicati su più Availability Zone e sopravvivano anche se il Task Fargate viene ricreato.
4.  **Zero Ingress via Tailscale**: Il Task Fargate ospiterà due container nello stesso pod: Vault e Tailscale (sidecar pattern). Tailscale girerà in modalità `userspace-networking`, agendo come un proxy privato. Vault sarà esposto solo all'interno della Tailnet, rendendolo totalmente invisibile da internet nonostante non abbiamo un NAT Gateway dedicato.

### Ottimizzazione dei Costi
Abbiamo studiato un workaround per evitare la "tassa" di 32$/mese del NAT Gateway gestito di AWS. Posizionando il Task Fargate in una Subnet Pubblica con un Security Group blindato (Ingress: 0), otteniamo l'accesso a internet necessario per Tailscale e ECR a costo quasi zero, pagando solo la piccola quota per l'IP pubblico ephemeral.

## Conclusione: Fallire Velocemente per Costruire Meglio

Questa sessione di lavoro si conclude con un apparente fallimento: il cluster OCI è stato "nuclearizzato" e rimosso. In realtà, è stato un successo strategico. Abbiamo identificato i limiti di una piattaforma, imparato dai bug dei metadati e tracciato una rotta verso una soluzione che non è solo più stabile, ma anche più professionale.

L'era di **Lushy Corp** inizia ora, non come un esperimento a costo zero, ma come una infrastruttura seria, serverless e pronta a scalare.

Prossima fermata: Terraform su AWS.

