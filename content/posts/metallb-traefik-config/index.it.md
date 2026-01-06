+++
title = "Dal Caos di HostNetwork all'Eleganza di MetalLB"
date = 2026-01-04T10:00:00Z
draft = false
description = "Transizione da hostNetwork a un vero LoadBalancer con MetalLB in un cluster Kubernetes bare-metal."
tags = ["kubernetes", "metallb", "traefik", "networking", "homelab"]
author = "Tazzo"
+++

## Introduzione: Il Limite del "Basta che Funzioni"

Fino a ieri, il nostro cluster Kubernetes viveva in una sorta di limbo architettonico. L'Ingress Controller (Traefik) era configurato in modalità `hostNetwork: true`. In termini poveri, il Pod di Traefik dirottava l'intera interfaccia di rete del nodo su cui girava, ascoltando direttamente sulle porte 80 e 443 dell'IP fisico del Control Plane.

Funziona? Sì. È una buona pratica? Assolutamente no.
Questa configurazione crea un accoppiamento forte tra il servizio logico e l'infrastruttura fisica. Se il nodo muore, il servizio muore. Inoltre, blocca quelle porte per qualsiasi altra cosa. Nei cloud provider (AWS, GCP), questo problema si risolve con un click: "Create Load Balancer". Ma noi siamo "on-premise" (o meglio, "on-homelab"), dove il lusso degli ELB (Elastic Load Balancer) non esiste.

La soluzione è **MetalLB**: un componente che simula un Load Balancer hardware all'interno del cluster, assegnando IP "virtuali" ai servizi. La missione di oggi era semplice sulla carta ma complessa nell'esecuzione: installare MetalLB, configurare una zona IP dedicata e migrare Traefik per farlo diventare un cittadino di prima classe del cluster.

---

## Fase 1: MetalLB e la Danza dei Protocolli (Layer 2)

Per un cluster domestico dove non abbiamo router BGP costosi (come i Juniper o Cisco da datacenter), MetalLB offre la modalità **Layer 2**.

**Concetto Chiave: Layer 2 & ARP**
In questa modalità, uno dei nodi del cluster "alza la mano" e dice alla rete locale: "Ehi, l'IP 192.168.1.240 sono io!". Lo fa inviando pacchetti ARP (Address Resolution Protocol). Se quel nodo muore, MetalLB elegge istantaneamente un altro nodo che inizia a urlare "No, ora sono io!". È un meccanismo di failover semplice ma efficace.

### La Sfida delle Tolleranze
Il primo ostacolo è stato architetturale. Di default, MetalLB installa dei pod chiamati "speaker" (quelli che "urlano" gli ARP) solo sui nodi Worker. Ma nel nostro cluster, il traffico entrava ancora prevalentemente dal Control Plane. Se non avessimo avuto uno speaker sul Control Plane, avremmo rischiato di avere un Load Balancer muto su metà dell'infrastruttura.

Abbiamo dovuto forzare la mano a Helm con una configurazione di `tolerations` specifica, permettendo agli speaker di "sporcarsi le mani" anche sul nodo Master:

```yaml
# metallb-values.yaml
speaker:
  tolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
    - key: "node-role.kubernetes.io/master"
      operator: "Exists"
      effect: "NoSchedule"
controller:
  tolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
```

Senza questo, gli speaker sarebbero rimasti in `Pending` sul control plane, rendendo il failover zoppo.

---

## Fase 2: La Trappola del DHCP (Networking Surgery)

Configurare MetalLB richiede un pool di indirizzi IP da assegnare. E qui abbiamo rischiato il disastro.

Il router domestico (uno Sky Hub) era configurato, come molti router consumer, per coprire l'intera subnet `192.168.1.x` con il suo server DHCP (range `.2` - `.253`).

**Il Pericolo del Conflitto IP**
Se avessimo detto a MetalLB "Usa il range `.50-.60`" senza toccare il router, avremmo creato una bomba a orologeria.
Scenario:
1. MetalLB assegna `.50` a Traefik. Tutto funziona.
2. Torno a casa, il mio telefono si connette al Wi-Fi.
3. Il router, ignaro di MetalLB, assegna `.50` al mio telefono.
4. **Risultato:** Conflitto IP. Il cluster Kubernetes e il mio telefono iniziano a litigare per chi possiede l'indirizzo. I pacchetti si perdono, le connessioni cadono. Caos.

**La Soluzione: "DHCP Shrinking"**
Prima di applicare qualsiasi YAML, siamo intervenuti sul router. Abbiamo ridotto il range DHCP drasticamente: **da `.2-.120`**.
Questo ha creato una "Terra di Nessuno" (da `.121` a `.254`) dove il router non osa avventurarsi. È in questo spazio sicuro che abbiamo ritagliato il pool per MetalLB.

```yaml
# metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: main-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.240-192.168.1.245 # Zona Sicura
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - main-pool
```

---

## Fase 3: Refactoring di Traefik (Il Grande Salto)

Con MetalLB pronto a servire IP, è arrivato il momento di staccare Traefik dall'hardware.

Le modifiche al `values.yaml` di Traefik sono state radicali:
1.  **Via `hostNetwork: true`:** Il pod ora vive nella rete virtuale del cluster, isolato e sicuro.
2.  **Via `nodeSelector`:** Non obblighiamo più Traefik a girare sul Control Plane. Può (e deve) andare sui Worker.
3.  **Service Type `LoadBalancer`:** La chiave di volta. Chiediamo al cluster un IP esterno.

Ma le migrazioni non sono mai indolori.

---

## Fase 4: Cronaca di un Debugging (The Struggle)

Appena lanciato l'aggiornamento Helm, ci siamo scontrati con due problemi classici ma educativi.

### 1. Il Deadlock del Volume (RWO)
Traefik usa un volume persistente (Longhorn) per salvare i certificati SSL (`acme.json`). Questo volume è di tipo **ReadWriteOnce (RWO)**, il che significa che può essere montato da **un solo nodo alla volta**.

Quando Kubernetes ha cercato di spostare Traefik dal Control Plane al Worker:
1. Ha creato il nuovo pod sul Worker.
2. Il vecchio pod sul Control Plane era ancora in fase di spegnimento (`Terminating`).
3. Il volume risultava ancora "agganciato" al vecchio nodo.
4. Il nuovo pod è rimasto bloccato in `ContainerCreating` con l'errore `Multi-Attach error`.

**Soluzione:** A volte Kubernetes è troppo gentile. Abbiamo dovuto forzare l'eliminazione del vecchio pod e scalare il deployment a 0 repliche per "sbloccare" il volume da Longhorn, permettendo poi al nuovo pod di montarlo pulito.

### 2. La Guerra dei Permessi (Root vs Non-Root)
Nel processo di hardening, abbiamo deciso di far girare Traefik come utente non privilegiato (UID `65532`), abbandonando `root`.
Tuttavia, il file `acme.json` esistente nel volume era stato creato dal vecchio Traefik (che girava come `root`).

Risultato?
`open /data/acme.json: permission denied`

L'utente `65532` guardava il file di proprietà di `root` e non poteva toccarlo. Il parametro `fsGroup` nel SecurityContext spesso non basta per file già esistenti su certi storage driver.

**Soluzione: Il Pattern "Init Container"**
Invece di tornare indietro e usare root (che sarebbe una sconfitta per la sicurezza), abbiamo implementato un **Init Container**. È un piccolo container effimero che parte *prima* di quello principale, esegue un comando, e muore.

Lo abbiamo configurato per girare come `root` (solo lui!), sistemare i permessi, e lasciare il campo libero a Traefik:

```yaml
# traefik-values.yaml snippet
initContainers:
  - name: volume-permissions
    image: busybox:latest
    # Comando brutale ma efficace: "Questo è tutto tuo, utente 65532"
    command: ["sh", "-c", "chown -R 65532:65532 /data && chmod 600 /data/acme.json || true"]
    securityContext:
      runAsUser: 0 # Root, necessario per chown
    volumeMounts:
      - name: data
        mountPath: /data
```

---

## Conclusioni

Oggi il cluster ha fatto un salto di qualità. Non è più un insieme di hack per far funzionare le cose in casa, ma un'infrastruttura che rispetta i pattern cloud-native.

**Cosa abbiamo ottenuto:**
1.  **Indipendenza dal Nodo:** Traefik può morire e rinascere su qualsiasi nodo; l'IP di servizio (`192.168.1.240`) lo seguirà grazie a MetalLB.
2.  **Sicurezza:** Traefik non ha più accesso all'intera rete dell'host e gira con un utente limitato.
3.  **Ordine:** Abbiamo separato chiaramente la responsabilità del router (DHCP domestico) da quella del cluster (Static IP Pool).

La lezione principale? L'automazione (Helm) è potente, ma quando si tocca lo storage persistente (Stateful) e i permessi, l'intervento umano chirurgico e la comprensione dei log (`permission denied`, `multi-attach error`) rimangono insostituibili.
