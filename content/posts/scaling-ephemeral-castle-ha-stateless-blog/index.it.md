---
title: "L'Ascesa della Fortezza: Alta Affidabilità, Immutabilità e la Nascita del Cluster Serio"
date: 2026-01-30T12:45:00+01:00
draft: false
tags: ["kubernetes", "ha", "gitops", "terraform", "traefik", "infisical", "nginx", "docker", "devops"]
categories: ["Infrastructure", "Architecture"]
author: "Taz"
description: "Cronaca tecnica del potenziamento del Castello Effimero: evoluzione verso un cluster ad Alta Affidabilità (3 CP, 2 Worker), migrazione del blog verso un'architettura stateless e implementazione di un workflow GitOps avanzato."
---

# L'Ascesa della Fortezza: Alta Affidabilità, Immutabilità e la Nascita del Cluster Serio

Il percorso di costruzione del **Castello Effimero** ha raggiunto una soglia critica. Fino ad ora, l'infrastruttura era stata un laboratorio di sperimentazione: un singolo Control Plane, un singolo Worker, un guscio funzionale ma fragile. In ingegneria dei sistemi, un cluster con un solo punto di rottura non è un cluster; è solo un ritardo programmato verso il disastro. 

In questa cronaca tecnica, documento la trasformazione del Castello in una vera fortezza ad **Alta Affidabilità (HA)**. Ho deciso di scalare l'architettura a 3 nodi di Control Plane e 2 Worker, stabilendo il minimo indispensabile per garantire la resilienza del piano di controllo e la continuità dei carichi di lavoro. Contemporaneamente, ho affrontato la migrazione della prima applicazione "reale": questo blog, che è passato da un setup dinamico e instabile a un'architettura **stateless ed immutabile**, gettando le basi per una pipeline CI/CD di livello professionale.

---

## Fase 1: Ingegnerizzare l'Alta Affidabilità (HA)

La prima decisione della giornata è stata radicale: piallare il setup esistente per far nascere un'infrastruttura capace di resistere alla perdita di un intero nodo senza interrompere il servizio.

### Il Ragionamento: Perché 3 Control Plane?
In un cluster Kubernetes, il cervello è rappresentato da **etcd**, il database distribuito che memorizza lo stato di ogni risorsa. etcd utilizza l'algoritmo di consenso **Raft** per garantire che tutti i nodi siano d'accordo sui dati. 

Ho scelto la configurazione a 3 nodi per un motivo puramente matematico legato al concetto di **Quorum**. Il quorum è il numero minimo di nodi che devono essere online affinché il cluster possa prendere decisioni. La formula è `(n/2) + 1`. 
*   Con 1 nodo, il quorum è 1 (nessuna tolleranza ai guasti).
*   Con 2 nodi, il quorum è 2 (se uno muore, il cluster si blocca).
*   Con 3 nodi, il quorum è 2. Questo significa che posso perdere un intero nodo e il Castello continuerà a funzionare perfettamente. 

Passare a 3 nodi trasforma il cluster da un giocattolo a una piattaforma di produzione.

### Dettagli dell'Infrastruttura Proxmox
Ho configurato Terraform per gestire 5 macchine virtuali su Proxmox:
*   **VIP (Virtual IP)**: `192.168.1.210` - Il punto di ingresso unico per l'API di Kubernetes.
*   **CP-01, 02, 03**: IP `.211, .212, .213` - Il cervello distribuito.
*   **Worker-01, 02**: IP `.214, .215` - Le braccia operative dove girano i Pod.

---

## Fase 2: Lo Struggle del Quorum e la Lotta contro i Fantasmi

L'implementazione dell'Alta Affidabilità si è rivelata più complessa del previsto a causa di un fenomeno che ho ribattezzato "conflitto di identità dei fantasmi".

### L'Analisi dell'Errore: etcd in stallo
Dopo aver lanciato il provisioning, i nodi sono apparsi su Proxmox, ma il cluster non riusciva a formarsi. Monitorando lo stato con `talosctl service etcd`, ho visto i servizi bloccati in stato `Preparing`. 

L'investigazione tramite `talosctl get members` ha rivelato una situazione caotica: i nuovi nodi cercavano di comunicare, ma vedevano nel database identità duplicate associate agli stessi IP. Questo è successo perché, durante i test precedenti, avevo riutilizzato gli stessi indirizzi IP senza eseguire un wipe completo dei dischi. etcd, trovando residui di una vecchia configurazione, rifiutava di formare un nuovo quorum per proteggere l'integrità dei dati.

### La Soluzione: Tabula Rasa e Shift di Rete
Ho deciso di applicare la filosofia suprema del Castello Effimero: **se non è pulito, non è affidabile**. 
1.  Ho eseguito un `talosctl reset` su tutti i nodi contemporaneamente per piallare ogni residuo magnetico sui dischi virtuali.
2.  Ho spostato l'intero range di IP del cluster (da `.22x` a `.21x`) per forzare ogni componente di rete, inclusa la cache ARP del router, a dimenticare i "fantasmi" del passato.

Dopo questo reset totale, il provisioning è filato liscio. I tre cervelli si sono riconosciuti, hanno eletto un leader e il VIP `.210` è salito online in meno di 2 minuti. Questo risultato è stato particolarmente soddisfacente dopo ore di troubleshooting su conflitti di certificati invisibili.

---

## Fase 3: La Rivoluzione Stateless - Migrazione del Blog

Con una base HA solida, era giunto il momento di deployare il primo carico di lavoro non infrastrutturale: il blog Hugo. 

### Il Ragionamento: Dallo Stato all'Immutabilità
Il setup precedente del blog era basato su un container `git-sync` che scaricava i sorgenti da GitHub e un'istanza di Hugo che compilava il sito all'interno del cluster. 

Ho deciso di abbandonare questo approccio per tre motivi fondamentali:
1.  **Sicurezza (Zero Trust)**: Il vecchio metodo richiedeva di conservare un token GitHub o una chiave SSH dentro il cluster. Rimuovendo git-sync, il cluster non ha più bisogno di sapere che esiste un repository Git dei sorgenti.
2.  **Affidabilità**: Se GitHub fosse andato giù, il blog non sarebbe partito. Ora, il blog dipende solo dall'immagine Docker salvata su Docker Hub.
3.  **Velocità**: Un'immagine immutabile contenente solo i file già compilati e un web server leggero parte in millisecondi, mentre Hugo impiegava secondi preziosi per generare il sito ad ogni avvio.

### Deep-Dive: Docker Multi-Stage Build
Per implementare questa visione, ho scritto un `Dockerfile` multi-stage. Questo approccio permette di separare l'ambiente di build dall'ambiente di runtime, garantendo immagini minuscole e sicure.

```dockerfile
# Stage 1: Builder
FROM hugomods/hugo:std AS builder
WORKDIR /src
COPY . .
# Generate static site with optimizations
RUN hugo --minify

# Stage 2: Runner
FROM nginx:stable-alpine
# Copy build artifacts, leaving behind compiler and source code
COPY --from=builder /src/public /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

---

## Fase 4: GitOps di Livello 2 - Tracciabilità Totale

Un'infrastruttura seria richiede un workflow di rilascio serio. Ho deciso di implementare un sistema di **Image Tagging basato su Git SHA**.

### Il Problema dei Tag Statici
Usare un tag come `:latest` o `:blog` è un peccato capitale in Kubernetes. Impedisce il rollback deterministico e inganna Kubernetes, che potrebbe non scaricare la nuova versione se il tag non cambia.

### La Soluzione: Lo script di pubblicazione intelligente
Ho sviluppato uno script `publish.sh` che coordina il rilascio tra due repository diversi (`blog-src` e `tazlab-k8s`).

**Il processo mentale dello script:**
1.  Verifica che non ci siano modifiche non committate (determinismo).
2.  Estrae lo SHA del commit attuale (es. `8c945ac`).
3.  Builda e pusha l'immagine `tazzo/tazlab.net:blog-8c945ac`.
4.  **Automazione GitOps**: Lo script entra nella cartella locale del repository `tazlab-k8s`, cerca il file di manifesto del blog e sostituisce il vecchio tag con quello nuovo tramite `sed`.
5.  Esegue il commit e il push automatico su `tazlab-k8s`.

In questo modo, l'aggiornamento del blog non è un'operazione manuale sul cluster, ma un cambiamento di stato dichiarato su Git. **Flux CD** rileva il nuovo commit e allinea il cluster entro 60 secondi. Questa è la vera essenza del GitOps: il codice è l'unica fonte di verità.

---

## Fase 5: La Caccia al Bug del Port Mapping

Nonostante l'architettura fosse corretta, il blog inizialmente rispondeva con un frustrante `Connection Refused`.

### L'Investigazione: Ingress vs Service
Ho iniziato l'indagine controllando lo stato dei Pod: erano `Running`. Ho controllato i log di Traefik e ho notato un comportamento inaspettato: Traefik riceveva il traffico sulla porta 80 ma non riusciva a contattare il backend.

Eseguendo `kubectl describe svc hugo-blog`, ho scoperto l'inghippo. Traefik, per impostazione predefinita nel suo chart Helm, cerca di mappare il traffico verso le porte `8000` (HTTP) e `8443` (HTTPS) dei container. Tuttavia, nel mio manifesto, avevo configurato Nginx per ascoltare sulla porta `80`. 

Inoltre, l'immagine ufficiale di Traefik gira come utente non-root e non ha i permessi per ascoltare su porte inferiori alla 1024 all'interno del Pod.

### La Soluzione: Allineamento delle porte
Ho modificato la configurazione di Traefik in `main.tf` per gestire esplicitamente il mapping:
*   **Esterno**: Porta 80 (esposta dal LoadBalancer MetalLB).
*   **Mapping**: Porta 80 del Service -> Porta 8000 del Pod Traefik.
*   **Ingress**: Traefik instrada poi verso la porta 80 dei Pod del blog (Nginx).

```hcl
# Traefik Port Configuration Fix
ports:
  web:
    exposedPort: 80
    port: 8000 # Internal port where Traefik is authorized to listen
  websecure:
    exposedPort: 443
    port: 8443
```

Dopo aver applicato questa modifica, i certificati SSL di Let's Encrypt (gestiti tramite sfida HTTP-01) sono passati istantaneamente da `pending` a `valid`. Vedere il lucchetto verde apparire su `https://blog.tazlab.net` è stato il coronamento di una lunga sessione di debugging.

---

## Riflessioni post-lab: Verso il Castello Completo

Con un cluster a 5 nodi e un'applicazione reale operativa in HA, il Castello Effimero è uscito dalla sua fase embrionale. 

### Cosa abbiamo ottenuto:
1.  **Resilienza Nata dal Consensus**: Grazie ai 3 CP, possiamo permetterci guasti hardware senza perdere il controllo della piattaforma.
2.  **Immutabilità Applicativa**: Il blog non è più un ammasso di file sincronizzati, ma un'entità congelata nel tempo, facile da scalare e impossibile da corrompere.
3.  **Automazione del Backup**: Non ho più bisogno di preoccuparmi dei file `kubeconfig`. Terraform li carica su Infisical non appena il cluster nasce, permettendomi di essere operativo su qualsiasi macchina in pochi istanti.

Il Castello è ora pronto per accogliere i prossimi pillar: l'osservabilità con **Prometheus** e **Grafana** e l'hardening del filesystem tramite la **Disk Encryption** della partizione `/var`. Ogni passo ci allontana dalla fragilità del "ferro" e ci avvicina alla libertà del codice puro.

---
*Fine della Cronaca Tecnica - Fase 4: HA e Immutabilità*
