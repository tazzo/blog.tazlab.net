+++
title = "Terraforming the Cloud: My First IaC on OCI"
date = 2026-03-20T08:00:00+00:00
draft = false
description = "La cronaca tecnica del primo provisioning di un cluster Kubernetes su Oracle Cloud Infrastructure utilizzando Terraform, Terragrunt e Talos Linux. Dalle sfide di un scaffolding non testato alla gestione delle immagini custom ARM64."
tags = ["terraform", "terragrunt", "oracle-cloud", "talos-linux", "kubernetes", "iac", "devops", "arm64", "infrastructure-as-code"]
author = "Tazzo"
+++

# Terraforming the Cloud: My First IaC on OCI

## Introduzione: Quando l'Infrastruttura Diventa Reale

Per anni ho letto di "Infrastructure as Code" (IaC). Ho studiato i principi, ho visto i tutorial, e ho persino implementato soluzioni locali che si avvicinavano al concetto. Ma c'è una differenza fondamentale tra definire una macchina virtuale sul proprio server Proxmox in cantina e definire un'infrastruttura completa su un cloud provider pubblico come Oracle Cloud Infrastructure (OCI). La prima è un esercizio controllato; la seconda è la realtà.

Oggi ho colmato quel divario. L'obiettivo non era banale: non volevo un "Hello World" con una singola istanza Linux. Volevo replicare l'architettura robusta ed efimera del mio cluster locale (`tazlab-k8s`) su OCI, sfruttando il piano **Always Free** e l'architettura **ARM64 (Ampere A1)** per costruire la base del nuovo cluster `tazlab-vault`. Questo cluster ospiterà in futuro un'installazione enterprise di HashiCorp Vault, quindi la "serietà" del progetto imponeva un rigore tecnico assoluto fin dal primo giorno.

Questa non è la storia di un successo immediato. È la cronaca di un pomeriggio passato a combattere con scaffolding non testati, peculiarità delle immagini cloud, e il paradosso dei certificati TLS in ambienti NAT. È la storia di come due macchine virtuali che si accendono possano rappresentare una vittoria tecnica significativa.

## 1. Il Contesto e la Scelta Tecnologica

Perché OCI? E perché Terraform?

La scelta di Oracle Cloud è puramente pragmatica: il loro piano **Always Free** offre risorse ARM64 incredibilmente generose (4 OCPU e 24 GB di RAM), perfette per un cluster Kubernetes a due nodi (Control Plane + Worker) senza costi ricorrenti.

La scelta dello stack tecnologico segue la filosofia del **Ephemeral Castle**, il framework che ho sviluppato internamente:
*   **Terraform**: Per il provisioning delle risorse base (VCN, Subnet, Istanze).
*   **Terragrunt**: Per mantenere il codice DRY e gestire le dipendenze tra i layer (rete vs compute).
*   **Talos Linux**: Un sistema operativo immutabile, minimale e sicuro per Kubernetes. Talos non ha SSH, non ha shell, ed è gestito interamente via API. Questo forza un approccio IaC puro: non puoi "entrare e fixare" una configurazione sbagliata; devi distruggere e ricreare.

Avevo preparato uno scaffolding iniziale dei file Terraform una settimana fa, ma non era mai stato eseguito ("sgrossato" ma non testato). Oggi era il giorno della verità.

## 2. Phase 1: SDD e Preparazione dell'Account

Prima di scrivere una sola riga di codice o lanciare un comando, ho attivato il mio processo di **Spec-Driven Development (SDD)**. Invece di lanciarmi a capofitto nell'esecuzione, ho definito quattro artefatti:
1.  **Constitution**: Regole immutabili (niente segreti nel codice, logging obbligatorio, stack definito).
2.  **Spec**: Cosa dobbiamo costruire oggi? (Account OCI, CLI, VM, Script di lifecycle).
3.  **Plan**: Come lo facciamo? (Importazione immagine custom, fix dei moduli, test end-to-end).
4.  **Tasks**: 28 micro-task per tracciare il progresso.

Questo approccio, che potrebbe sembrare burocratico per un progetto personale, si è rivelato salvifico quando la complessità tecnica è esplosa nelle fasi successive.

### Il Primo Contatto con OCI
L'account OCI era vuoto. Zero. Ho dovuto navigare la console per creare il primo **Compartment** (`tazlab-vault`), generare le API Key per l'accesso programmatico e configurare la OCI CLI sulla mia workstation.

Un dettaglio critico è stato determinare l'Availability Domain (AD) corretto. A differenza di AWS o GCP che usano zone come `eu-central-1a`, OCI usa identificatori specifici per tenancy, come `GRGU:EU-TURIN-1-AD-1`. Hardcodare questi valori è un errore; ho dovuto estrarli dinamicamente o salvarli come segreti nel mio vault locale (gestito da Infisical).

## 3. Il Dilemma dell'Immagine Talos

Qui ho incontrato il primo vero ostacolo architetturale. Il mio scaffolding originale prevedeva di usare un'immagine standard **Oracle Linux 8** e poi installare Talos sopra di essa usando uno script `cloud-init`.

Sulla carta, funziona. Nella pratica, è fragile. Trasforma un'operazione atomica (boot dell'OS) in un processo a due stadi prono a errori di rete e dipendenze. Inoltre, il template `cloud-init` che avevo scritto era solo un placeholder non funzionale.

**La Decisione**: Ho deciso di abbandonare l'approccio ibrido e usare un'immagine **Talos nativa**.
Talos fornisce un "Image Factory" che permette di generare immagini disco personalizzate. Ho usato lo stesso schematic ID del mio cluster locale (`e187c9b9...`) che include moduli kernel specifici (`iscsi_tcp`, `nbd`) per il supporto allo storage distribuito Longhorn.

### L'Odissea dell'Importazione
Importare un'immagine custom su OCI non è banale come incollare un URL.
1.  **Tentativo 1**: Incollare l'URL della Factory nella console OCI.
    *   *Risultato*: Errore. OCI accetta URL solo dal proprio Object Storage.
2.  **Tentativo 2**: Scaricare l'immagine, caricarla su un Bucket OCI, importare.
    *   *Risultato*: Errore `Shape VM.Standard.A1.Flex is not valid for image`. OCI aveva rilevato l'immagine come x86 perché non avevo specificato l'architettura. La console web non permetteva di selezionare "ARM64" per immagini custom importate in quel modo.

**La Soluzione (The Hard Way)**:
Ho dovuto seguire la procedura ufficiale "Bring Your Own Image" di Talos per Oracle Cloud, che è sorprendentemente manuale:
1.  Scaricare l'immagine raw compressa (`.raw.xz`).
2.  Decomprimerla e convertirla in formato QCOW2 (`qemu-img convert`).
3.  Creare un file `image_metadata.json` specifico per dire a OCI "Ehi, questa è un'immagine ARM64 UEFI compatibile con VM.Standard.A1.Flex".
4.  Impacchettare tutto in un archivio `.oci` (tarball di qcow2 + json).
5.  Caricare questo pacchetto di 90MB sul Bucket e importare da lì.

Solo così OCI ha riconosciuto l'immagine come valida per le istanze Ampere A1. È stato un promemoria brutale che il cloud non è magico; è solo computer di qualcun altro con regole molto rigide.

## 4. Terraforming: Debugging dello Scaffolding

Con l'immagine pronta, ho lanciato `terragrunt plan`. Il risultato è stato un muro di errori rosso. Il codice scritto una settimana fa e mai testato mostrava tutti i suoi limiti.

### 1. Funzioni Inesistenti
Avevo usato `get_terragrunt_config()` nei file figlio, una funzione che non esiste. Terragrunt richiede di includere la configurazione radice e poi leggere i valori tramite `read_terragrunt_config()`. Ho dovuto riscrivere la logica di passaggio delle variabili tra i layer `engine` (rete) e `platform` (compute).

### 2. Conflitti di Provider
Ogni modulo dichiarava i suoi `required_providers`, ma anche il file radice generava un `versions.tf`. Risultato: Terraform andava in panico per definizioni duplicate. Ho dovuto ripulire i moduli, lasciando che fosse Terragrunt a iniettare le dipendenze corrette.

### 3. La "Tag Tax"
OCI è schizzinoso sui tag. Il mio codice usava `tags = { ... }`, ma il provider OCI distingue tra `freeform_tags` (chiave-valore liberi) e `defined_tags` (tassonomie enterprise). Ho dovuto refattorizzare ogni singola risorsa per usare `freeform_tags`. Inoltre, ho scoperto che i tag sono case-insensitive nelle chiavi, causando conflitti di merge quando cercavo di sovrascrivere `Layer` con `layer`.

### 4. DNS Label Limits
Un errore banale ma fastidioso: `dns_label` per le subnet ha un limite di 15 caratteri. La mia stringa `tazlab-vault-public-subnet` generava `tazlabvaultpublicsubnet` (23 caratteri), bloccando il provisioning della VCN. Una semplice `substr()` ha risolto, ma mi ha ricordato di controllare sempre i limiti dei provider.

Dopo due ore di ciclo *fix-plan-repeat*, ho finalmente visto il messaggio più bello del mondo:
`Plan: 12 to add, 0 to change, 0 to destroy.`

## 5. "They're Alive!" (e il problema di rete nascosto)

Ho lanciato lo script `create.sh`. Terraform ha creato la VCN, le subnet, le Security List e infine le due istanze Compute.
In meno di 3 minuti, avevo due IP pubblici.

Ma il cluster non rispondeva. Il comando `talosctl version` andava in timeout.

**L'Indagine**:
Ho usato `nc` (netcat) per testare la porta 50000 (API di Talos). `Connection refused`.
Era strano. Le mie Network Security Group (NSG) permettevano esplicitamente il traffico sulla porta 50000.
Ho scavato nella configurazione della VCN e ho trovato il colpevole: la **Default Security List**.
In OCI, ogni subnet ha una Security List di default che viene applicata *in aggiunta* alle NSG. Questa lista permetteva solo SSH (porta 22). Anche se la mia NSG diceva "lascia passare tutto", la Security List diceva "blocca tutto tranne SSH". È un modello di sicurezza "defense in depth" che mi ha colto di sorpresa.

Ho aperto la Security List e la situazione è cambiata istantaneamente: `Connection refused` è diventato `tls: certificate required`. Il server rispondeva!

## 6. Il Paradosso TLS e la Configurazione di Macchina

A questo punto, le macchine erano accese, Talos era avviato, ma non potevo fare il bootstrap del cluster. Perché?

Perché Talos, essendo sicuro by-default, usa mTLS (Mutual TLS) per ogni comunicazione.
Il certificato del server viene generato al primo avvio basandosi sulla configurazione della macchina. La configurazione, generata da Terraform, impostava come `cluster_endpoint` l'indirizzo IP privato della VM (`10.0.1.100`), l'unico noto al momento del `plan`.

Io, però, stavo cercando di connettermi dall'esterno tramite l'IP pubblico (`92.x.x.x`).
Risultato: Il client `talosctl` si connetteva all'IP pubblico, il server presentava un certificato valido solo per `10.0.1.100`, e il client rifiutava la connessione per mismatch del nome.

**Il vicolo cieco**:
*   Non potevo rigenerare il certificato senza accedere alla macchina.
*   Non potevo accedere alla macchina senza un certificato valido.
*   Non potevo usare l'IP privato perché non ho (ancora) una VPN site-to-site con OCI.

Ho tentato di usare degli IP Pubblici Riservati, iniettandoli nella configurazione prima della creazione delle istanze. Ho modificato Terraform per aggiungere questi IP ai `certSANs` (Subject Alternative Names) del certificato.
Sfortunatamente, Terraform su OCI non permette facilmente di assegnare un IP pubblico riservato *durante* la creazione dell'istanza in un solo passaggio atomico; richiede una risorsa separata. Le istanze nascevano comunque con IP effimeri diversi da quelli che avevo messo nel certificato.

## Conclusioni: Un Successo Parziale è Pur Sempre un Successo

Alla fine della sessione, ho dovuto accettare una vittoria parziale.
Le macchine sono su. Talos è installato e configurato. L'infrastruttura è definita come codice. Lo script `destroy.sh`, che ho dovuto riscrivere per gestire correttamente la pulizia delle risorse orfane (istanze terminate che mantenevano i dischi boot occupati), funziona perfettamente, permettendomi di azzerare i costi con un comando.

Ho raggiunto l'obiettivo della "Terraformazione": ho trasformato un'intenzione (un cluster) in realtà (risorse cloud) usando solo codice.
Il problema del bootstrap TLS è un classico problema di "Day 2" anticipato al "Day 0". La soluzione per la Fase 2 è chiara: associare correttamente gli IP Riservati alle interfacce di rete (VNIC) o stabilire un tunnel sicuro per operare sull'IP privato.

Ma per oggi, vedere quelle due righe `RUNNING` nella console di Oracle, sapendo che non ho cliccato nessun bottone per crearle, è una soddisfazione immensa. È la conferma che lo studio teorico si è trasformato in competenza pratica. L'infrastruttura, finalmente, è diventata reale.
