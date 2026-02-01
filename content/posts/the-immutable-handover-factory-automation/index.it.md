---
title: "Il Passaggio di Consegne: Terraform, Flux e la Nascita della Fabbrica di Castelli"
date: 2026-02-01T07:00:00+01:00
draft: false
tags: ["kubernetes", "terraform", "fluxcd", "gitops", "automation", "devops", "security", "infisical"]
categories: ["Infrastructure", "Design Patterns"]
author: "Taz"
description: "Cronaca tecnica di una rivoluzione architettonica: come ho trasformato l'infrastruttura del Castello Effimero in una fabbrica modulare, delegando la gestione dei pilastri a Flux e automatizzando la rinascita totale con un solo comando."
---

# Il Passaggio di Consegne: Terraform, Flux e la Nascita della Fabbrica di Castelli

L'ingegneria dei sistemi non è un processo lineare, ma un'evoluzione fatta di continue semplificazioni. Dopo aver raggiunto l'Alta Affidabilità con un cluster a 5 nodi, mi sono reso conto che l'architettura soffriva ancora di un peccato originale: la sovrapposizione delle responsabilità. Terraform stava facendo troppo, e Flux stava facendo troppo poco. In questa cronaca tecnica, documento il salto evolutivo finale del **Castello Effimero**: la trasformazione in una vera "Fabbrica di Infrastruttura" dove il codice IaC agisce solo come innesco, delegando l'intera costruzione dei pilastri al motore GitOps.

L'obiettivo della sessione è stato radicale: ridurre Terraform al minimo indispensabile, riorganizzare il repository per garantire un isolamento totale tra i progetti e creare un sistema di rinascita capace di risorgere dalle ceneri con un singolo comando automatizzato.

---

## Il Ragionamento: L'Estetica del Minimalismo IaC

Inizialmente, avevo configurato Terraform per installare non solo il cluster Kubernetes, ma anche tutti i suoi componenti fondamentali: MetalLB per il networking, Longhorn per lo storage, Traefik per l'ingress e Cert-Manager per i certificati. Sulla carta, sembrava una scelta logica: un unico comando per avere tutto pronto. 

Tuttavia, questa scelta ha creato un conflitto di identità. Flux, il mio "butler" GitOps, cercava a sua volta di gestire quegli stessi componenti leggendo il repository dei manifesti. Il risultato era un duello costante tra Terraform e Flux per il controllo del cluster, con il rischio di drift (scostamento) e collisioni ad ogni aggiornamento.

### La scelta: Solo l'indispensabile
Ho deciso di attuare un refactoring drastico. Terraform ora gestisce solo il **"Kernel"** del Castello:
1.  **Provisioning Fisico**: Creazione delle VM su Proxmox e configurazione di Talos OS.
2.  **External Secrets Operator (ESO)**: Questo è l'unico componente Kubernetes che ho mantenuto in Terraform. Il motivo è puramente tecnico: per far sì che Flux possa scaricare le app, ha spesso bisogno di segreti (token Git, chiavi S3). ESO deve essere lì fin dal primo secondo per fare da ponte con Infisical EU.
3.  **Flux CD**: L'innesco finale. Terraform installa Flux e gli consegna le chiavi del repository `tazlab-k8s`.

Questa separazione trasforma Terraform in un'ostetrica: aiuta il cluster a nascere e poi si fa da parte. Flux diventa l'unico sovrano dei pilastri infrastrutturali. Il vantaggio? Gli aggiornamenti di Traefik o MetalLB ora avvengono con un semplice `git push`, senza dover mai più invocare Terraform per modifiche applicative.

---

## Fase 1: Ricostruzione Project-Centric ed Isolamento

Fino a ieri, la struttura delle cartelle era divisa per piattaforma (`providers/proxmox/...`). Era un approccio limitato che non scalava bene in uno scenario multi-progetto o multi-cloud. 

### Il Ragionamento: Isolamento Totale
Ho deciso di riorganizzare l'intero repository `ephemeral-castle` seguendo una gerarchia orientata al progetto. Un progetto (come "Blue") deve poter esistere sia su Proxmox che su AWS in modo totalmente isolato, con i suoi stati Terraform indipendenti e le sue chiavi protette.

Ho implementato la seguente struttura:
*   `clusters/blue/proxmox/`: La logica specifica per il cluster locale.
*   `clusters/blue/configs/`: Una cartella dedicata per ospitare i file sensibili generati (`kubeconfig`, `talosconfig`).

### Sicurezza e .gitignore
Un errore comune in IaC è lasciarsi scappare file di stato o config nel controllo di versione. Ho aggiornato il `.gitignore` con una regola ricorsiva e aggressiva:
```text
**/configs/
*.tfstate*
```
Questo garantisce che, indipendentemente da quanti nuovi cluster creerò, le loro chiavi rimarranno confinate sulla mia workstation o nel vault, mai su GitHub.

---

## Fase 2: Il Telecomando del Castello - `destroy.sh` e `create.sh`

La vera sfida dell'infrastruttura ephemerale è la velocità di rinascita. Se per ricostruire il cluster servono 10 comandi manuali, l'infrastruttura non è ephemerale, è solo faticosa. Ho deciso di condensare l'intera intelligenza operativa in due script di orchestrazione.

### L'Investigazione: Il blocco di Terraform
Il problema principale era che `terraform destroy` falliva sistematicamente. I provider di Kubernetes e Helm cercavano di connettersi al cluster per verificare lo stato delle risorse prima di eliminarle. Ma se le macchine erano già state resettate o spente, Terraform rimaneva appeso in attesa di una risposta che non sarebbe mai arrivata.

### La Soluzione: Il "Purge" dello Stato
Ho risolto questo stallo inserendo una fase di pulizia forzata nello script `destroy.sh`. Prima di lanciare il distruggitore, lo script rimuove manualmente le risorse problematiche dallo stato locale:

```bash
# destroy.sh snippet
echo "🔥 Phase 1: Cleaning Terraform State..."
terraform state list | grep -E "flux_|kubernetes_|kubectl_|helm_" | xargs -n 1 terraform state rm || true
```

Questo comando dice a Terraform: *"Dimentica di aver mai conosciuto Flux o Helm, pensa solo a cancellare le VM"*. È una manovra chirurgica che sblocca l'intero processo di distruzione.

---

## Fase 3: Lo Struggle delle Corse Critiche (Race Conditions)

Durante i primi test dello script `create.sh`, il cluster nasceva, ma i servizi (come il blog) rimanevano offline.

### L'Analisi dell'Errore: Il Webhook di MetalLB
Ho visto i Pod di MetalLB in stato `Running`, ma Flux segnalava un errore criptico sulle configurazioni del pool di IP:
`failed calling webhook "l2advertisementvalidationwebhook.metallb.io": connect: connection refused`

**Il processo mentale:**
Ho sospettato inizialmente di un problema di rete tra i nodi. Ho controllato i log del `metallb-controller` e ho scoperto la verità: il processo del webhook (che convalida i file YAML) impiega qualche secondo in più rispetto al controller principale per attivarsi. Flux provava a iniettare la configurazione nel millesimo di secondo sbagliato, riceveva un rifiuto e andava in stallo.

### La Soluzione: La pazienza degli EndpointSlice
Ho aggiornato lo script di creazione per non limitarsi ad aspettare i Pod, ma a interrogare Kubernetes finché l'endpoint del webhook non fosse stato realmente **pronto a servire**. Ho migrato la logica di controllo dal vecchio risorsa `Endpoints` (ormai deprecata) alla moderna `EndpointSlice`.

Tuttavia, anche questa logica ha richiesto un affinamento: inizialmente un errore di sintassi Bash nel ciclo di attesa ha bloccato la rinascita proprio sul traguardo. Correggere quel bug è stata l'ultima lezione della giornata: in uno script di orchestrazione, la robustezza dei controlli (usando `grep -q` invece di fragili comparazioni di stringhe) è ciò che separa un'automazione "giocattolo" da una di livello professionale.

```bash
# create.sh logic update
echo "⏳ Waiting for MetalLB Webhook to be serving..."
until kubectl get endpointslice -n metallb-system -l kubernetes.io/service-name=metallb-webhook-service -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[*]}{"\n"}{end}' 2>/dev/null | grep -q "\."; do
  printf "."
  sleep 5
done
echo " Webhook ready!"
```

Questo controllo granulare ha eliminato l'ultima "corsa critica" che impediva l'automazione totale.

---

## Fase 4: Idempotenza e il Conflitto con Infisical

Un altro ostacolo era rappresentato dal backup automatico dei config files su Infisical EU. Terraform cercava di creare il segreto `KUBECONFIG_CONTENT`, ma se questo esisteva già dal tentativo precedente, l'API restituiva un errore `400 Bad Request: Secret already exists`.

### Il Ragionamento: Importazione Preventiva
Invece di provare a cancellare il segreto (che richiede permessi elevati e tempo), ho deciso di implementare una logica di **importazione automatica**. Prima di eseguire l'apply finale, lo script prova a "importare" il segreto nello stato di Terraform. Se esiste, Terraform ne prende il controllo e lo aggiorna; se non esiste, l'errore viene ignorato e Terraform lo creerà normalmente.

```bash
# create.sh snippet
echo "🔗 Checking for existing configs on Infisical..."
terraform import -var-file=secrets.tfvars infisical_secret.kubeconfig_upload "$WORKSPACE_ID:$ENV_SLUG:$FOLDER_PATH:KUBECONFIG_CONTENT" || true
```

---

## Deep-Dive: Il concetto di Handover (Passaggio di Consegne)

In questa architettura, il concetto di **Handover** è fondamentale. Rappresenta il momento esatto in cui la responsabilità del cluster passa dal provisioning (IaC) alla consegna continua (GitOps).

Perché è un termine tecnico importante?
In un sistema tradizionale, Terraform è "lo stato". Se vuoi cambiare una porta di Traefik, cambi il codice Terraform. Nel Castello, Terraform non sa nemmeno cosa sia Traefik. Terraform sa solo che deve far nascere un cluster e installare Flux. 

Questo riduce drasticamente il **Blast Radius** (raggio d'impatto) di un errore in Terraform: se sbagli una riga nel codice IaC, rischi di rompere le VM, ma non romperai mai la logica applicativa del blog, perché quella risiede in un altro mondo (GitOps). È la separazione definitiva tra la "macchina" e lo "scopo".

---

## La Fabbrica in Azione: Come nasce un nuovo Progetto

Grazie a questa ristrutturazione, creare un nuovo cluster non è più un'opera di artigianato, ma un processo di catena di montaggio. Se oggi volessi far nascere il cluster "Green", la procedura sarebbe questa:

1. **Provisioning (IaC)**:
   - Copio la cartella `templates/proxmox-talos` in `clusters/green/proxmox`.
   - Modifico il file `terraform.tfvars` impostando i nuovi IP, il nome del cluster e il nuovo path di Infisical (es. `/ephemeral-castle/green/proxmox`).
   - Preparo i segreti su Infisical nella nuova cartella.

2. **Delivery (GitOps)**:
   - Creo un nuovo repository su GitHub partendo dal contenuto di `gitops-template`.
   - Inserisco l'URL di questo nuovo repository nel file `terraform.tfvars` della cartella del progetto.

3. **Innesco**:
   - Lancio `./create.sh` dalla cartella del progetto.

In meno di 10 minuti, Terraform creerebbe le macchine e Flux inizierebbe a popolare il nuovo repository con i componenti di base (MetalLB, Traefik, Cert-Manager) già pre-configurati. Questo è il vero potere del Castello: la capacità di scalare orizzontalmente non solo i nodi, ma interi ecosistemi digitali.

---

## Hardening Finale: Pulizia del Kernel e API v1

Per concludere la giornata, ho affrontato due bug di "pulizia" che sporcavano i log.

1.  **Moduli Kernel**: Talos segnalava errori nel caricamento di `iscsi_generic`. Investigando la documentazione, ho scoperto che nelle versioni recenti i moduli iSCSI sono stati accorpati. Ho rimosso il modulo inesistente da `talos.tf`, ottenendo finalmente un boot pulito ("Green Boot").
2.  **Deprecations**: Ho migrato ogni risorsa Kubernetes gestita da Terraform alle versioni `v1` (es. `kubernetes_secret_v1`). Questo non cambia la funzionalità, ma garantisce che l'infrastruttura sia pronta per le prossime major release di Kubernetes e silenzia i fastidiosi warning nel terminale.

---

## Riflessioni post-lab: Il Trionfo dell'Automazione

Vedere il Castello risorgere con un solo comando è stata una delle esperienze più soddisfacenti di questo viaggio. 

### Cosa abbiamo imparato:
1.  **IaC come Bootstrapper**: Terraform dà il meglio di sé quando si limita a creare le fondamenta. Più codice Kubernetes metti in Terraform, più problemi avrai in futuro.
2.  **L'importanza dei retry**: In un mondo distribuito, non puoi assumere che un comando funzioni al primo colpo. Gli script di orchestrazione devono avere la "pazienza" di attendere che i servizi di rete siano caldi.
3.  **Isolamento = Replicabilità**: Dividere per progetto e piattaforma rende il Castello una vera fabbrica. Oggi ho un cluster "Blue" su Proxmox, ma la struttura è pronta per far nascere un cluster "Green" su AWS in meno di 10 minuti.

Il Castello ora non è solo solido; è **autonomo**. Le mura sono alte, il maggiordomo (Flux) è al lavoro e il blog che state leggendo è la prova vivente che il codice, se ben orchestrato, può creare realtà immutabili e indistruttibili.

---
*Fine della Cronaca Tecnica - Fase 5: Automazione e Handover*
