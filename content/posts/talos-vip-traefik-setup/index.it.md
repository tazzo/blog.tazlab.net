# Cronache dal Lab: L'Odissea del VIP Nativo su Talos e l'Ingress Traefik Bare-Metal

**Data:** 30 Dicembre 2025  
**Autore:** Taz (DevOps Engineer)  
**Status:** Mission Accomplished

---

## Introduzione: Il Fascino della Semplicità (Apparente)

Oggi ho affrontato una di quelle sessioni di laboratorio che iniziano con un obiettivo apparentemente semplice e finiscono per trasformarsi in una lezione magistrale di architettura Kubernetes. L'obiettivo era chiaro: configurare un punto d'ingresso (Ingress) solido per il mio cluster **Talos Linux** su Proxmox, esposto tramite un **VIP (Virtual IP)** nativo, e installare **Traefik** per gestire il traffico HTTPS con certificati automatici Let's Encrypt.

Il mantra della giornata era "Less is More". Niente MetalLB (per ora). Niente Load Balancer esterni complessi. Volevo sfruttare le capacità native di Talos per gestire l'High Availability di rete e far girare Traefik "sul ferro" (HostNetwork).

Quello che segue non è un tutorial asettico, ma la cronaca fedele delle sfide, degli errori architetturali e delle soluzioni che hanno portato al successo.

---

## Fase 1: Il VIP Nativo di Talos (Layer 2)

La prima sfida è stata garantire un indirizzo IP stabile (`192.168.1.250`) che potesse "fluttuare" tra i nodi, indipendentemente da quale macchina fisica fosse accesa.

### Il Ragionamento (The Why)
Perché un VIP nativo? In un ambiente Bare Metal (o VM su Proxmox), non abbiamo la comodità dei Load Balancer cloud (AWS ELB, Google LB) che ci forniscono un IP pubblico con un click. Le alternative classiche sono **MetalLB** (che annuncia IP via ARP/BGP) o **Kube-VIP**.
Tuttavia, Talos Linux offre una funzionalità integrata per gestire VIP condivisi direttamente nella configurazione della macchina (`machine config`). Ho scelto questa strada per ridurre le dipendenze software: se il sistema operativo può farlo, perché installare un altro pod per gestirlo?

### L'Analisi e l'Errore
Ho iniziato identificando l'interfaccia di rete sui nodi (`ens18`) e creando una patch per annunciare l'IP `192.168.1.250`.

```yaml
# vip-patch.yaml
machine:
  network:
    interfaces:
      - interface: ens18
        dhcp: true
        vip:
          ip: 192.168.1.250
```

Applicare la patch al nodo **Control Plane** (`192.168.1.253`) è stato un successo immediato. Il nodo ha iniziato a rispondere all'ARP per il nuovo IP.
Il problema è sorto quando ho tentato di applicare la stessa patch al nodo **Worker** (`192.168.1.127`) per garantire ridondanza.

> **Errore:** `virtual (shared) IP is not allowed on non-controlplane nodes`

**Analisi:** Talos, per design, limita l'uso dei VIP condivisi ai nodi Control Plane. Questo perché il caso d'uso primario è l'High Availability dell'API Server (porta 6443), non il traffico utente generico.
**Impatto:** Abbiamo dovuto accettare che il nostro VIP risiederà, per ora, solo sul Control Plane. È un *Single Point of Failure*? Sì, se il nodo CP muore, perdiamo l'IP. Ma per un laboratorio domestico è un compromesso accettabile che semplifica drasticamente lo stack.

---

## Fase 2: Helm e la Preparazione del Terreno

Con il VIP attivo, serviva il "motore" per installare le applicazioni. **Helm** è lo standard de facto. L'installazione è stata banale via script ufficiale, ma essenziale. Helm ci permette di definire la nostra infrastruttura come codice (Values files) invece che come comandi imperativi lanciati a caso.

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh && ./get_helm.sh
```

---

## Fase 3: Traefik e l'Inferno della Configurazione

Qui è iniziata la vera battaglia. Volevamo Traefik configurato in modo molto specifico:
1.  **HostNetwork:** Ascoltare direttamente sulle porte 80/443 del nodo (bypassando il livello di overlay network di K8s) per intercettare il traffico diretto al VIP.
2.  **ACME (Let's Encrypt):** Generare certificati SSL validi.
3.  **Persistence:** Salvare i certificati su disco per non rigenerarli ad ogni riavvio (e finire nel rate-limit).

### Il Primo Muro: La Sintassi di Helm
Il chart di Traefik evolve rapidamente. La mia prima configurazione del `values.yaml` usava sintassi deprecate per i redirect (`redirectTo`) e l'esposizione delle porte.
Helm rispondeva con errori criptici come `got boolean, want object`.

**Soluzione:** Ho dovuto consultare la documentazione aggiornata (tramite Context7) e scoprire che la gestione dei redirect globali è ora più robusta se passata tramite `additionalArguments` piuttosto che cercare di incastrala nella mappa delle porte.

### Il Secondo Muro: RollingUpdate vs HostNetwork
Una volta corretta la sintassi, Helm ha rifiutato l'installazione con un errore logico interessante:

> **Errore:** `maxUnavailable should be greater than 0 when using hostNetwork`

**Deep-Dive:** Quando usi `hostNetwork: true`, un Pod occupa fisicamente la porta 80 del nodo. Kubernetes non può avviare un *nuovo* Pod (aggiornamento) sullo stesso nodo finché il *vecchio* non è morto, perché la porta è occupata. La strategia di default `maxUnavailable: 0` (che cerca di non avere mai downtime) è incompatibile matematicamente con questo vincolo su un singolo nodo.
**Soluzione:** Ho dovuto modificare la `updateStrategy` per permettere `maxUnavailable: 1`.

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1
    maxSurge: 0
```

### Il Terzo Muro: Pod Security Admission (PSA)
Superato lo scoglio della configurazione, i Pod non partivano. Rimanevano in stato `CreateContainerConfigError` o non venivano creati dal DaemonSet.
Descrivendo il DaemonSet (`kubectl describe ds`), è emersa la verità:

> **Errore:** `violates PodSecurity "baseline": host namespaces (hostNetwork=true)`

**Analisi:** Talos e le versioni recenti di Kubernetes applicano di default standard di sicurezza rigidi. Un Pod che richiede `hostNetwork` è considerato "privilegiato" perché può vedere tutto il traffico del nodo. Il namespace doveva essere esplicitamente autorizzato.

**Soluzione:**
```bash
kubectl label namespace traefik pod-security.kubernetes.io/enforce=privileged --overwrite
```

---

## Fase 4: Il Paradosso della Connessione

Tutto sembrava verde. Pod Running. VIP attivo. Ma provando a connettermi a `http://192.168.1.250` (o al dominio `tazlab.net`), ricevevo un secco **Connection Refused**.

### L'Investigazione (Sherlock Mode)
1.  **VIP:** Il VIP `192.168.1.250` è sul nodo **Control Plane** (`.253`).
2.  **Pod:** Ho controllato dove girava il Pod di Traefik: `kubectl get pods -o wide`. Girava sul nodo **Worker** (`.127`).
3.  **Il Buco Nero:** Il traffico arrivava al nodo `.253` (VIP), ma su quel nodo non c'era nessun Traefik in ascolto sulla porta 80! Il router inviava i pacchetti al posto giusto, ma nessuno rispondeva.

Perché Traefik non girava sul Control Plane?
**Deep-Dive: Taints & Tolerations.** I nodi Control Plane hanno un "Taint" (una macchia) chiamata `node-role.kubernetes.io/control-plane:NoSchedule`. Questo dice allo scheduler: "Non mettere nessun carico di lavoro qui, a meno che non sia esplicitamente tollerato". Traefik, di default, non lo tollera.

### La Soluzione Architetturale Definitiva
Abbiamo dovuto prendere una decisione drastica per far funzionare tutto in armonia:
1.  Abbandonare il `DaemonSet` (che cerca di girare ovunque).
2.  Passare a un `Deployment` con **1 sola replica**.
3.  Forzare questa replica a girare **esclusivamente** sul nodo Control Plane (dove risiede il VIP).

Modifiche al `values.yaml`:

```yaml
# 1. Tollerare il Taint del Control Plane
tolerations:
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"

# 2. Forzare l'esecuzione sul nodo Control Plane
nodeSelector:
  kubernetes.io/hostname: "talos-unw-ifc" # O usare label generiche

# 3. Deployment singola replica (Cruciale per ACME)
deployment:
  kind: Deployment
  replicas: 1
```

Perché una sola replica? Perché la versione Community di Traefik non supporta lo sharing dei certificati ACME tra più istanze. Se avessimo due repliche, entrambe cercherebbero di rinnovare i certificati, andando in conflitto o venendo bannate da Let's Encrypt.

---

## Conclusioni e Stato Finale

Dopo aver applicato questa configurazione "chirurgica", il sistema ha preso vita.

1.  Il router di casa inoltra le porte 80/443 al VIP `192.168.1.250`.
2.  Il VIP porta il traffico al nodo Control Plane.
3.  Traefik (ora residente sul Control Plane) intercetta il traffico.
4.  Riconosce il dominio `tazlab.net`, richiede il certificato a Let's Encrypt, lo salva in `/data` (volume hostPath montato), e serve l'applicazione `whoami`.

**Cosa abbiamo imparato?**
Che "semplice" non significa "facile". Rimuovere strati di astrazione (come i Load Balancer esterni) ci costringe a capire profondamente come Kubernetes interagisce con la rete fisica sottostante. Abbiamo dovuto gestire manualmente l'affinità dei nodi, la sicurezza dei namespace e le strategie di update.

Il risultato è un cluster snello, senza sprechi di risorse, perfetto per un Homelab, ma costruito con la consapevolezza di ogni singolo ingranaggio.

**Prossimi passi:** Configurare i backup dei certificati (perché ora sono su un singolo nodo!) e iniziare a deployare servizi reali.

---
*Generated via Gemini CLI*
