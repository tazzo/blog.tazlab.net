+++
title = "Cloud Free e la Cruda Realtà: Il Pivot di Lushy Corp verso Hetzner"
date = "2026-03-30T18:00:00+01:00"
draft = false
description = "Cronaca di un fallimento necessario: come i limiti di OCI Always Free hanno portato a scegliere un VPS Hetzner stabile, versatile e conveniente per ospitare il nostro Vault."
tags = ["Hetzner", "VPS", "OCI", "Vault", "Tailscale", "DevOps", "HomeLab"]
categories = ["Infrastructure", "Security"]
author = "Tazzo"
+++

## L'illusione del "Gratis" e la Ricerca della Stabilità

L'obiettivo iniziale era semplice e ambizioso: un cluster privato di HashiCorp Vault sulle risorse "Always Free" di Oracle Cloud a Torino. **4 vCPU ARM, 24 GB di RAM e 200 GB di storage**, tutto gratis. Un paradiso per un home lab professionale.

Dopo 24 ore di battaglia, ho dovuto fare i conti con la cruda realtà: quando si tratta di servizi critici, il "gratis" può costare molto caro in termini di tempo e affidabilità.

Il nome **Lushy Corp** è nato da un typo — stavo scrivendo "HashiCorp Vault Container" e l'agente AI ha letto "LushyCorp". Da quel momento, è diventato il nome in codice del nostro vault.

## La Saga OCI: Una Battaglia contro i Mulini a Vento

### Il Muro della Capacità

Il primo ostacolo è arrivato prima ancora di poter fare qualsiasi cosa. Le istanze **Ampere** (ARM64) nel datacenter `eu-turin-1` di OCI sono estremamente popolari: offrono prestazioni eccellenti in un tier gratuito. Il problema è che la domanda supera di gran lunga l'offerta.

Ho dovuto implementare un loop aggressivo nel mio script di provisioning, un `create.sh` che tentava continuamente di creare istanze, spesso per ore. Il messaggio `Out of host capacity` è diventato il mio compagno costante. Oracle semplicemente non aveva risorse disponibili nel momento in cui le richiedevo.

Questo ha evidenziato un problema concettuale: se devo "lottare" per ottenere una risorsa gratuita, quel tempo ha un costo. E se quel tempo viene speso su un servizio critico 24/7, il rischio operativo diventa inaccettabile.

### Il Bug dell'Architettura: Istanze che Girano ma non Partono

Dopo aver finalmente "accaparrato" un'istanza Ampere, ho incontrato un problema più subdolo. L'istanza raggiungeva lo stato `RUNNING` senza errori, ma Talos Linux non si avviava. Nessun output sulla console, solo un'istanza che girava nel vuoto.

L'investigazione ha richiesto ore. Alla fine, la causa è emersa: l'immagine ARM64 importata era stata registrata con i metadati di architettura su `None` invece di `ARM64`. OCI accettava l'istanza, ma al boot il firmware UEFI non riconosceva l'architettura e si bloccava silenziosamente.

La soluzione è stata rimportare l'immagine tramite OCI CLI, specificando esplicitamente `ARM64`:

```bash
oci compute image import \
  --compartment-id $COMPARTMENT_ID \
  --image-id $IMAGE_ID \
  --source-image-type QCOW2 \
  --launch-mode PARAVIRTUALIZED \
  --architecture ARM64
```

Una lezione importante: su OCI, i **metadati dell'immagine** devono essere corretti *al momento dell'importazione*. Non possono essere modificati dopo.

### Terragrunt e Problemi di Orchestrazione

Quando Terragrunt ha iniziato a bloccarsi su problemi di caching e credenziali, ho dovuto bypassarlo completamente, passando a comandi OCI CLI diretti. Inoltre, OCI impiegava un tempo anomalo ad assegnare gli IP privati alle VNIC, richiedendo multipli reset hardware per forzare la sincronizzazione.

Il sentimento prevalente non era soddisfazione: era la consapevolezza che stavo costruendo su fondamenta instabili.

## Il Colpo Fatale: La Politica di Spegnimento

Il momento decisivo è arrivato quando ho realizzato che le politiche di OCI "Always Free" consentono lo spegnimento delle istanze ritenute "inattive". Per un servizio come Vault, che deve essere **sempre disponibile**, questo è un rischio inaccettabile.

Immaginate la scena: è notte, un'applicazione Kubernetes ha bisogno di accedere a un segreto per ruotare un certificato, ma il Vault è stato spento da Oracle perché "inattivo". Il certificato scade, l'app va in errore, e voi state dormendo. È esattamente il tipo di fallimento silenzioso che un sistema di gestione dei segreti deve prevenire a tutti i costi.

Ho deciso che la stabilità operativa di Lushy Corp valeva più di qualche euro risparmiato.

## Il Pivot AWS: Il Problema delle Istanze Spot

Prima di arrivare a Hetzner, ho fatto un'escursione nell'ecosistema AWS. Ho progettato un'architettura basata su **Fargate + EFS + Tailscale + KMS Auto-Unseal**, con l'intento di mantenere un costo stimato di circa 4€/mese.

Non è stata la complessità dell'infrastruttura a fermarmi. Al contrario, configurare quell'ambiente è stato uno stimolo tecnico interessante, un'ottima occasione per imparare e approfondire componenti avanzati di AWS. Il problema reale, emersi fatti i conti, era il compromesso tra costi e affidabilità. 

Per rientrare in quel budget così basso, avrei dovuto usare istanze **Fargate Spot**. Tuttavia, le istanze Spot introducono lo stesso identico problema da cui stavo scappando su OCI: se AWS necessita di potenza computazionale, ti spegne la macchina. Tornavamo al punto di partenza, un rischio inaccettabile per un Vault. 

Per avere un'architettura realmente solida e funzionante per bene (usando istanze On-Demand classiche), la spesa sarebbe salita a più del doppio di quanto preventivato all'inizio. Per un progetto nato per imparare, mettermi alla prova e testare tecnologie nel mio home lab (dove un cluster Vault è di per sé già una sovrastruttura "esagerata" per i dati che contiene), mi sembrava semplicemente una spesa ingiustificata.

## La Scelta Finale: Hetzner e la Bellezza della Semplicità

La scelta è caduta su un **VPS dedicato su Hetzner**. Questa decisione offre il bilanciamento perfetto per un home lab professionale.

**1. Versatilità**: Una VM Linux non è solo per Vault. Può ospitare altri microservizi, un reverse proxy, strumenti di monitoring. Il costo fisso di 4-5€/mese si distribuisce su più servizi nel tempo.

**2. Semplicità Operativa**: Con una VM pura, ho il controllo completo e diretto su ogni componente. Niente servizi gestiti opachi, solo pura amministrazione di sistema Linux.

**3. Costo Prevedibile**: 4-5€/mese garantiti 24/7. È il prezzo della pace mentale, senza i rischi delle istanze Spot e senza sorprese in bolletta.

### Il Setup: Podman e Tailscale Nativo

Invece di soluzioni iper-impacchettate, sto pensando a un approccio più "grezzo" e formativo. Installerò **Tailscale direttamente nel sistema operativo** della macchina, garantendo la connettività sicura a livello di host in modo pulito.

Per quanto riguarda i container, ho deciso di approfittarne per usare **Podman** al posto del classico Docker. Non perché Docker non vada bene (anzi, Podman non mi darà necessariamente feature in più per questo use case base), ma puramente per il gusto di provarlo e imparare a usarlo in un contesto reale. Su questo strato Podman farò girare il container di Vault. Essendo un VPS pubblico, in futuro, mi farà comodo avere questa infrastruttura già pronta per tirar su facilmente altri servizi.

## Conclusione: Fallire per Costruire Meglio

Ho "nuclearizzato" il compartment OCI, cancellato il progetto AWS Fargate, ma non sono stati fallimenti. Sono state **tappe necessarie** di un percorso che ha portato a un'architettura più solida, pragmatica e consapevole.

Ogni pivot ha insegnato qualcosa:

- **OCI**: Il "gratis" ha costi nascosti enormi in termini di affidabilità e tempo perso.
- **AWS Fargate**: Le architetture serverless "economiche" via Spot non sono adatte a servizi always-on critici per infrastrutture lab.
- **Hetzner**: La semplicità di una VM classica è una virtù.

L'era di **Lushy Corp** inizia ora, su una solida fondazione Linux, pronta a gestire i segreti.

Prossima tappa: Provisioning.