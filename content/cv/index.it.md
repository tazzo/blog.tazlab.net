+++
title = "Curriculum"
date = 2026-09-29T09:00:00Z
description = "Il curriculum vitae di Roberto Tazzoli: platform engineering, infrastrutture AI e insegnamento."
author = "Tazzo"
showAuthor = false
showDate = false
showReadingTime = false
showPagination = false
+++

- Phone: +39 348 809 5252
- Email: [roberto.tazzoli@gmail.com](mailto:roberto.tazzoli@gmail.com)
- Location: Borgo Virgilio (MN), Italia
- Website: [www.tazlab.net](https://www.tazlab.net/)
- GitHub: [tazzo](https://github.com/tazzo)

## Progetti

### **Ambrogio — Personal Agent Orchestrator** -- **Progetto personale**

Orchestratore di agenti AI e registro di tracciabilità in un solo binario: avvia le mani, distribuisce il lavoro in code di passi e conserva ogni passaggio. Sito: [ambrogio.tazlab.net](https://ambrogio.tazlab.net).

- **Agenti interni ed esterni**: gli interni leggono e cercano nel motore; gli esterni sono *pilotati* — avviati dal motore, con posto in coda, ordine di lavoro e scadenza — o *liberi*, con un ordine preso da una mano esterna. Claude Code, Codex, OpenCode o altro restano usabili com'è.
- **Task e code**: una richiesta diventa una coda di passi con un tetto dichiarato; il motore tiene la catena e la traccia — chi, cosa, quando, e perché la coda si è chiusa.
- **GitHub**: il worker committa nel suo albero e consegna; il motore spinge il ramo, apre la pull request, la fonde dopo il controllo e riporta il tronco locale — una mano non ha la credenziale della forgia.
- **Sicurezza e segreti**: ogni mano gira in una sandbox *Landlock* (percorsi dichiarati, rete e IPC ristretti), pulita e con scadenza: riceve solo i segreti del suo progetto (`global` + `project`), mai quelli del motore.
- **Progetti, documenti e un solo binario**: un progetto è un posto con una radice, i documenti i testi che una mano scrive (piano, roadmap, stato, revisioni), le consegne rapporti con artefatti verificabili. Go statico con SQLite dentro, pagina, API ed eventi dal binario; porta dell'operatore dietro token, porta degli agenti.

### **TazLab — piattaforma Cloud-Native & AI Engineering** -- **Progetto personale**

Ago 2025 – oggi

Progetto personale evoluto da un server con container Docker a una piattaforma enterprise-grade (~80 pod): il salto è stato reso possibile dall'uso professionale degli agenti AI, impiegati per progettare, implementare e mantenere l'intera infrastruttura.

- **Kubernetes GitOps**: cluster multi-nodo Talos Linux (VM su Proxmox) con Flux CD e Terraform/Terragrunt; bootstrap one-shot in ~12 minuti, senza interventi manuali.
- **Infrastruttura interamente IaC**: Proxmox, Terraform/Terragrunt (cluster, VM, LXC), Ansible (playbook idempotenti); ogni componente è distruggibile e ricreabile in pochi minuti, con i dati persistenti su S3.
- **Segreti, PKI e zero-trust**: HashiCorp Vault come unico backend (dynamic secrets, Vault Secrets Operator), PKI a 3 livelli con Root CA offline, mTLS su PostgreSQL con rotazione automatica — zero password applicative; rete Tailscale as-code senza IP pubblici.
- **Disaster recovery**: backup offsite su S3, recupero autonomo dopo un blackout reale (~10 min), recovery completo da zero in <30 min.
- **AI Engineering**: *Mnemosyne* (server MCP in Go, memoria semantica pgvector), *Hindsight* (memoria multi-agente, 745+ ricordi), *Ambrogio* (orchestratore di agenti, Go); *TazPod* (CLI Go) come workspace con agenti AI su VM Proxmox — una dedicata all'agente *Hermes* — raggiungibili via SSH/Tailscale.
- **Agenti AI nei processi**: Claude Code, Codex, OpenCode, Pi, Gemini e OMP dentro GitOps, CI/CD e memoria multi-agente; *Multica* e *Buzz* su Kubernetes come piani di controllo self-hosted. Documentazione su [wiki.tazlab.net](https://wiki.tazlab.net) e [blog.tazlab.net](https://blog.tazlab.net).

## Esperienza Lavorativa

### **Insegnante di Matematica e Fisica**, Istituto di istruzione secondaria — Mantova -- Mantova, Italia

Set 2013 – oggi

- **Didattica e Formazione**: insegnamento di Matematica e Fisica nei licei.
- **Gestione Infrastruttura IT**: amministrazione e manutenzione dell'infrastruttura informatica dell'istituto: sito web scolastico, registro elettronico e piattaforma Google Workspace.
- **Innovazione e Didattica AI**: progettazione e conduzione di percorsi formativi sull'uso consapevole ed efficace dell'Intelligenza Artificiale Generativa per studenti e personale.

### **Programmatore**, Libero Professionista -- Bologna, Italia

Nov 2007 – Apr 2011

Progettazione e sviluppo di portali web completi.

- Progettati e sviluppati portali web completi con front-end dinamici e interfacce server-side per la gestione efficiente dei contenuti.
- Sviluppate interfacce amministrative ad alta usabilità per ottimizzare le operazioni di gestione dei portali.
- **Competenze Tecniche applicate**: JavaScript, HTML, XML, Python, JSP, Servlet; Database SQL.

### **Analista Sviluppatore Back-End**, Objectway -- Milano, Italia

Nov 2003 – Nov 2007

Sviluppo back-end in team (clienti ING Bank e H3G).

- **ING Bank — Conto Arancio**: partecipato allo sviluppo e all'integrazione dei moduli back-end per il lancio del primo servizio di home banking in Italia senza filiali fisiche, contribuendo a test e debugging per la stabilità della piattaforma.
- **H3G**: partecipato allo sviluppo di un'interfaccia di configurazione web per i telefoni cellulari dell'era pre-smartphone e dei primi sistemi di notifica push verso i clienti; contribuito alla realizzazione di componenti back-end in grado di gestire picchi di traffico di migliaia di richieste al secondo.
- **Tecnologie utilizzate**: Java, JavaBeans, Database SQL.

### **Assegnista di Ricerca**, Università degli Studi di Bologna -- Bologna, Italia

Set 2001 – Nov 2002

Progettazione e sviluppo di sistemi di Intelligenza Artificiale per la diagnostica medica.

- Progettato e implementato un sistema esperto basato su Reti Neurali e Algoritmi Genetici per l'identificazione automatica di anomalie in immagini mammografiche (diagnosi precoce del tumore al seno).
- Sviluppati modelli predittivi (SVM, Reti Neurali) per l'analisi di DNA Microarray, finalizzati all'identificazione di marcatori genetici e alla personalizzazione delle terapie.
- **Competenze Tecniche applicate**: C, C++, Java; Reti Neurali Artificiali, Algoritmi Genetici, Support Vector Machine (SVM).

## Istruzione e Formazione

### **SSIS Bologna**, Abilitazione all'insegnamento in Matematica e Fisica -- Bologna, Italia

2007 – 2009

### **CEFRIEL — Politecnico di Milano**, Master di II livello in Tecnologia dell'Informazione -- Milano, Italia

2003 – 2004

### **Università degli Studi di Bologna**, Laurea (110/110) in Fisica — Indirizzo Elettronico, Cibernetico, Intelligenza Artificiale -- Bologna, Italia

1995 – 2001

## Competenze Linguistiche

**Lingua madre:** Italiano

**Inglese:** B2

## Competenze Tecniche

**Platform Engineering & Cloud-Native:** Proxmox VE come base + infrastruttura interamente IaC: Terraform/Terragrunt (cluster, VM, LXC), Ansible (configurazione e installazione tooling, playbook idempotenti) e GitOps con Flux CD per il cluster; Kubernetes (Talos Linux), Docker/Podman, Helm, CI/CD (GitHub Actions); ambiente distruggibile e ricreabile in pochi minuti, dati persistenti su S3; storage distribuito (Longhorn), osservabilità (Prometheus, Grafana, alerting).

**MLOps & AI Infrastructure:** Deploy containerizzato di servizi di inferenza e memoria semantica su Kubernetes; PostgreSQL + pgvector (embeddings, ricerca vettoriale); protocollo MCP (server e client); operatività LLM end-to-end (Hindsight, Mnemosyne): migrazione e audit di basi di conoscenza, gestione di quota e rate-limit, monitoraggio e recovery; orchestrazione di agenti AI integrati in processi GitOps/CI-CD.

**Sicurezza & Zero-Trust:** HashiCorp Vault (PKI, dynamic secrets, Vault Secrets Operator), certificati mTLS con rotazione automatica, rete privata Tailscale as-code, cert-manager, Let's Encrypt, Dex/OIDC.

**Sviluppo Software:** Go, Python, Bash (attivi); Java, C/C++ (pregressa esperienza); Git.

**Cloud Provider:** AWS, Hetzner (in produzione), Google Cloud, Cloudflare, Oracle Cloud (OCI).

**AI Agents — uso professionale attivo:** Claude Code, Codex, OpenCode, Pi, Gemini, OMP e gli orchestratori di agenti self-hosted *Paperclip*, *Buzz* e *Multica*: impiegati quotidianamente per progettare, implementare e mantenere infrastrutture e processi reali, non solo come assistenti di coding.
