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

### **TazLab — piattaforma Cloud-Native & AI Engineering** -- **Progetto personale**

Ago 2025 – oggi

Progetto personale evoluto da un server con container Docker a una piattaforma enterprise-grade (~80 pod): il salto è stato reso possibile dall'uso professionale degli agenti AI, impiegati attivamente per progettare, implementare e mantenere l'intera infrastruttura.

- **Piattaforma Kubernetes GitOps**: cluster multi-nodo Talos Linux (VM su Proxmox) con Flux CD e Terraform/Terragrunt; bootstrap one-shot in ~12 minuti senza interventi manuali.
- **Infrastruttura IaC**: Proxmox (base locale) + Terraform/Terragrunt per cluster, VM e LXC + Ansible (configurazione e tooling, playbook idempotenti); ogni componente può essere distrutto e ricreato in pochi minuti — backup su S3.
- **Segreti e PKI**: HashiCorp Vault come unico backend segreti (dynamic secrets con Vault Secrets Operator), PKI a 3 livelli con Root CA offline, mTLS su PostgreSQL con rotazione automatica — zero password applicative.
- **Zero-trust e disaster recovery**: rete Tailscale as-code senza IP pubblici; backup offsite su S3, recupero autonomo dopo blackout reale (~10 min), recovery completo da zero in <30 min.
- **AI Engineering**: sviluppato *Mnemosyne* (server MCP in Go, memoria semantica pgvector) e integrato *Hindsight* (memoria multi-agente, 745+ ricordi); *TazPod* (CLI Go) come workspace con agenti sempre attivi su Proxmox, raggiungibili da remoto via SSH/Tailscale — inclusa una VM dedicata all'agente *Hermes*.
- **Uso professionale degli agenti AI**: Claude Code, Codex, OpenCode, Pi, Gemini e OMP non come strumenti isolati ma integrati nei processi (GitOps, CI/CD, memoria condivisa multi-agente), e creazione dell'infrastruttura per eseguirli.
- **Documentazione e storico**: [wiki.tazlab.net](https://wiki.tazlab.net) per la documentazione dell'infrastruttura; [blog.tazlab.net](https://blog.tazlab.net) come storico di progettazione e sviluppo.
- **Orchestrazione di agenti AI**: piani di controllo self-hosted su Kubernetes per più orchestratori di agenti — *Multica* e *Buzz*; primo task completato in 29 s.

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
