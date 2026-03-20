---
title: "TazLab Roadmap: HashiCorp Vault e Oracle Cloud"
date: 2026-03-17T08:00:00+00:00
draft: false
tags: ["Kubernetes", "HashiCorp Vault", "Oracle Cloud", "Tailscale", "Security", "Secrets Management", "Talos OS", "GitOps"]
description: "Da Infisical a HashiCorp Vault, passando per un nuovo cluster su Oracle Cloud e una VPN mesh con Tailscale: la roadmap di sicurezza avanzata del TazLab."
---

## The Current State: Un Cluster Solido, Ma con un Tallone d'Achille

Il TazLab oggi è un'infrastruttura che funziona. Ho un cluster Kubernetes su Proxmox con Talos OS, una pipeline GitOps gestita da Flux, metriche raccolte da Prometheus e visualizzate su Grafana, e `etcd` cifrato a riposo. Da fuori, è un setup che ispira fiducia.

Ma guardando dall'interno, c'è un problema che mi tiene sveglio.

La gestione dei segreti è affidata a **Infisical** nel suo piano gratuito. Funziona: sincronizza i segreti su Kubernetes tramite l'External Secrets Operator, i pod li usano, la vita va avanti. Tuttavia, il piano gratuito di Infisical impone un limite che non riesco più ad accettare: **non supporta la rotazione automatica dei segreti**.

I segreti non ruotano. Le credenziali del database sono statiche. Se una chiave viene compromessa, l'intervento è manuale.

---

## The "Why": Quando l'AI Mette a Nudo il Problema

Il punto di svolta non è arrivato da un incidente, ma da una riflessione. Ho iniziato a usare con regolarità tool di intelligenza artificiale nel mio workflow — Gemini CLI, Cloud Code, e altri agenti con accesso alla shell e al filesystem. Questi strumenti sono potenti, ma hanno un'abitudine fastidiosa: loggare tutto. Prompt, output, contesto di sessione. Potenzialmente, anche frammenti di segreti che compaiono nelle risposte dei comandi.

In quel momento ho capito che il mio modello di sicurezza dei segreti era fragile per definizione. Non perché Infisical faccia un cattivo lavoro, ma perché segreti **statici e longevi** sono intrinsecamente vulnerabili. Un segreto che non ruota mai è una bomba a orologeria.

La risposta professionale a questo problema ha un nome preciso: **segreti dinamici** e **rotazione automatica delle chiavi**.

---

## The Target Architecture: Vault Come Centro di Gravità

La scelta è ricaduta su **HashiCorp Vault Community Edition**, installato come pod all'interno del cluster stesso. È una scelta deliberatamente ambiziosa — probabilmente overkill per un home lab — ma è esattamente il tipo di overkill che voglio. Vault è lo standard de facto del settore per la gestione dei segreti in ambienti enterprise. Impararlo qui, nel mio laboratorio, significa portare competenze reali nel mondo reale.

Il modello che voglio implementare funziona così:

1. **Vault** genera i segreti dinamicamente e gestisce la loro scadenza e rotazione.
2. **External Secrets Operator** intercetta i cambiamenti e sincronizza i nuovi segreti su Kubernetes come `Secret` nativi.
3. **Reloader** rileva le modifiche nei Secret e nei ConfigMap e attiva automaticamente il reload dei pod coinvolti.

Il risultato: nessuna credenziale statica, nessun intervento manuale, nessuna finestra di esposizione indefinita.

### Il Nuovo Nodo: Oracle Cloud Always Free

Per ospitare Vault in modo robusto e separato dall'infrastruttura principale, sto aggiungendo un secondo cluster al TazLab. La piattaforma scelta è **Oracle Cloud Infrastructure**, che offre un livello Always Free generoso e stabile:

- **Control Plane**: VM con 8 GB di RAM
- **Worker**: VM con 16 GB di RAM
- **OS**: Talos OS, come sul cluster locale — coerenza operativa al primo posto

Questo cluster Oracle diventerà il nodo di sicurezza del TazLab: ospiterà Vault, sarà raggiungibile dalla VPN, e non dipenderà dall'hardware fisico di casa.

### Tailscale: La Colla che Tiene Insieme Tutto

Il tassello più critico di questa architettura non è Vault — è la **VPN mesh**.

Per capire perché, bisogna capire come funzionano i segreti dinamici di Vault per PostgreSQL. Quando un'applicazione richiede credenziali al database, Vault non restituisce una password salvata da qualche parte: **crea un utente PostgreSQL al momento**, con una scadenza definita, e lo elimina quando il lease scade. Per farlo, Vault ha bisogno di accesso diretto al database con privilegi di amministratore.

Se Vault è su Oracle Cloud e PostgreSQL è sul cluster Proxmox di casa, serve un canale sicuro e permanente tra i due. È qui che entra **Tailscale**: una soluzione VPN mesh moderna, zero-config, basata su WireGuard. Ogni nodo della rete — cluster locale, cluster Oracle, workstation — diventa parte della stessa rete privata, indipendentemente da dove si trova fisicamente.

La VPN non è un dettaglio implementativo. È la precondizione che rende possibile l'intera architettura.

---

## Phased Approach: Le Tappe del Percorso

Il lavoro si articola in fasi sequenziali, ognuna delle quali deve essere stabile prima di procedere alla successiva.

**Fase 1 — VPN Mesh**
Configurare Tailscale tra il cluster Proxmox locale e il nuovo cluster Oracle Cloud. Verificare la connettività bidirezionale. Nessun Vault, nessun segreto dinamico finché questa base non è solida.

**Fase 2 — Nuovo Cluster Oracle**
Provisioning del cluster Talos su Oracle Cloud tramite Terragrunt. Integrazione con il repo GitOps esistente. Il cluster deve essere gestito da Flux esattamente come il cluster locale.

**Fase 3 — HashiCorp Vault**
Deploy di Vault sul cluster Oracle. Configurazione del PKI engine, del secrets engine per PostgreSQL, delle policy di accesso. Migrazione progressiva dei segreti da Infisical a Vault.

**Fase 4 — Integrazione ESO + Reloader**
Configurare External Secrets Operator su entrambi i cluster per leggere da Vault. Integrare Reloader per il reload automatico dei pod. Testare l'intero ciclo: rotazione → sync → reload.

---

## Future Outlook: Il Cluster Effimero Diventa Realtà

Questa roadmap non è solo una lista di strumenti da installare. È il passo che trasforma il TazLab da infrastruttura solida a infrastruttura **veramente effimera**.

L'obiettivo finale è un cluster che puoi distruggere e ricreare a piacimento, su qualsiasi cloud provider, in qualsiasi momento. Il processo di bootstrap sarà completamente automatizzato: il nuovo cluster si connette alla mesh Tailscale, ottiene i certificati automaticamente, raggiunge Vault e recupera i propri segreti, ripristina i dati dall'S3 bucket. Nessun intervento manuale.

AWS oggi, Google Cloud domani, Oracle dopodomani. La piattaforma diventa irrilevante.

Questo è il "Terraforming the Cloud" nella sua forma più compiuta: non terraformare un singolo cloud, ma rendere il proprio ecosistema indipendente da tutti.

Il TazLab non ha un indirizzo fisso. Ha solo un punto di ripartenza.
