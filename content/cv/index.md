+++
title = "CV"
date = 2026-09-29T09:00:00Z
description = "The curriculum vitae of Roberto Tazzoli: platform engineering, AI infrastructure and teaching."
author = "Tazzo"
showAuthor = false
showDate = false
showReadingTime = false
showPagination = false
+++

- Phone: +39 348 809 5252
- Email: [roberto.tazzoli@gmail.com](mailto:roberto.tazzoli@gmail.com)
- Location: Borgo Virgilio (MN), Italy
- Website: [www.tazlab.net](https://www.tazlab.net/)
- GitHub: [tazzo](https://github.com/tazzo)

## Projects

### **TazLab — Cloud-Native & AI Engineering platform, designed, built and maintained with AI agents** -- **Personal project**

Jan 2025 – present

A personal project that grew from a single Docker-container server into an enterprise-grade platform (~80 pods): the leap was made possible by the professional use of AI agents, actively employed to design, implement and maintain the entire infrastructure.

- **GitOps Kubernetes platform**: multi-node cluster on Talos Linux (Proxmox VMs) managed with Flux CD and Terraform/Terragrunt; one-shot bootstrap from bare metal to a fully working cluster in ~12 minutes with zero manual intervention.
- **Fully IaC infrastructure**: Proxmox (local base) + Terraform/Terragrunt for cluster, VMs and LXCs + Ansible (configuration and tooling installation, idempotent playbooks); every component can be destroyed and recreated in minutes — data lives on S3.
- **Enterprise secrets & PKI**: HashiCorp Vault as the single secrets backend (dynamic secrets with Vault Secrets Operator), 3-tier PKI with an offline Root CA, mTLS on PostgreSQL with automatic certificate rotation — zero application passwords.
- **Zero-trust & disaster recovery**: Tailscale network as code with no public IPs; offsite S3 backups, autonomous recovery after a real power outage (~10 min), full recovery from zero in <30 min.
- **AI Engineering**: developed *Mnemosyne* (Go MCP server, pgvector semantic memory) and integrated *Hindsight* (multi-agent memory, 745+ memories migrated); *TazPod* (Go CLI) as a workspace with always-on agents on Proxmox, reachable remotely over SSH/Tailscale — including a dedicated VM running the *Hermes* agent.
- **Professional use of AI agents**: Claude Code, Codex, OpenCode, Pi, Gemini and OMP not as isolated tools but embedded into real processes (GitOps, CI/CD, shared multi-agent memory), including the ability to build the infrastructure that runs them and keep it maintained.
- **Documentation & history**: [wiki.tazlab.net](https://wiki.tazlab.net) for infrastructure documentation; [blog.tazlab.net](https://blog.tazlab.net) as the engineering and development history.
- **AI agent orchestration**: self-hosted control planes on Kubernetes for multiple agent orchestrators — *Multica* and *Buzz*; first task completed in 29 s.

## Work Experience

### **Mathematics and Physics Teacher**, Secondary School — Mantova -- Mantova, Italy

Sept 2013 – present

- **Teaching & Education**: theoretical and practical teaching of Mathematics and Physics, including curriculum design, assessment, and student preparation for state examinations.
- **IT Infrastructure Management**: administration and maintenance of the school's IT infrastructure, including the school website, electronic register, and Google Workspace platform.
- **AI Innovation & Education**: design and delivery of training courses on the conscious, ethical, and effective use of Generative Artificial Intelligence for students and staff.

### **Programmer**, Freelance -- Bologna, Italy

Nov 2007 – Apr 2011

Web portal design and development.

- Designed and developed complete web portals with dynamic front-ends and server-side interfaces for efficient content management.
- Developed high-usability administrative interfaces to optimize portal management operations.
- **Applied technical skills**: JavaScript, HTML, XML, Python, JSP, Servlet; SQL databases, RDF, OWL, Semantic Web.

### **Back-End Developer Analyst**, Objectway -- Milan, Italy

Nov 2003 – Nov 2007

Team back-end development (clients ING Bank and H3G).

- **ING Bank — Conto Arancio**: contributed to the development and integration of back-end modules for the launch of the first branchless home banking service in Italy, helping with testing and debugging for the stability of the platform.
- **H3G**: contributed to the development of a web configuration interface for pre-smartphone mobile phones and of one of the first push notification systems to customers; helped build back-end components able to handle traffic peaks of thousands of requests per second.
- **Technologies used**: Java, JavaBeans, SQL databases.

### **Research Fellow**, University of Bologna -- Bologna, Italy

Sept 2001 – Nov 2002

Design and development of Artificial Intelligence systems for medical diagnostics.

- Designed and implemented an expert system based on Neural Networks and Genetic Algorithms for automatic anomaly identification in mammographic images (early breast cancer diagnosis).
- Developed predictive models (SVM, Neural Networks) for DNA Microarray analysis, aimed at identifying genetic markers and personalizing therapies.
- **Applied technical skills**: C, C++, Java; Artificial Neural Networks, Genetic Algorithms, Support Vector Machine (SVM).

## Education

### **SSIS Bologna**, Teaching qualification (SSIS) in Mathematics and Physics -- Bologna, Italy

2007 – 2009

### **CEFRIEL — Politecnico di Milano**, Second-level Master's degree in Information Technology -- Milan, Italy

2003 – 2004

### **University of Bologna**, Degree in Physics (110/110) in Physics — Electronics, Cybernetics & Artificial Intelligence track -- Bologna, Italy

1995 – 2001

## Languages

**Mother tongue:** Italian

**English:** B2

## Skills

**Platform Engineering & Cloud-Native:** Proxmox VE as the base + fully IaC infrastructure: Terraform/Terragrunt (cluster, VMs, LXCs), Ansible (configuration and tooling installation, idempotent playbooks) and GitOps with Flux CD for the cluster; Kubernetes (Talos Linux), Docker/Podman, Helm, Kustomize, CI/CD (GitHub Actions); the whole environment can be destroyed and recreated in minutes, with persistent data on S3; distributed storage (Longhorn), observability (Prometheus, Grafana, alerting).

**MLOps & AI Infrastructure:** Containerized deployment of inference and semantic-memory services on Kubernetes; PostgreSQL + pgvector (embeddings, vector search); MCP protocol (server and client); end-to-end LLM operations (Hindsight, Mnemosyne): knowledge-base migration and audit, quota/rate-limit management, monitoring and recovery; orchestration of AI agents embedded in GitOps/CI-CD processes.

**Security & Zero-Trust:** HashiCorp Vault (PKI, dynamic secrets, Vault Secrets Operator), mTLS certificates with automatic rotation, gopass/GPG, Tailscale private network as code, cert-manager, Let's Encrypt, Dex/OIDC.

**Software Development:** Go, Python, Bash (active); Java, C/C++ (previous experience); Git.

**Cloud Providers:** AWS (S3, IAM, SSO), Hetzner (in production), Google Cloud (Gemini API), Cloudflare, Oracle Cloud (OCI).

**AI Agents — active professional use:** Claude Code, Codex, OpenCode, Pi, Gemini, OMP and the self-hosted agent orchestrators *Paperclip*, *Buzz* and *Multica*: used daily to design, implement and maintain real infrastructure and processes, not just as coding assistants.
