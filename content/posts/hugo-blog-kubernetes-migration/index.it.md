+++
title = "Migrazione di un Blog Hugo su Kubernetes"
date = 2026-01-06T00:42:51Z
draft = false
description = "Una cronaca tecnica della migrazione di un blog Hugo da Docker Compose a un cluster Kubernetes con Longhorn e Traefik."
tags = ["kubernetes", "hugo", "migrazione", "longhorn", "traefik", "homelab"]
author = "Tazzo"
+++

## Introduzione: L'Illusione della Semplicitá

Oggi l'obiettivo sembrava banale: prendere un blog statico generato con **Hugo**, che attualmente gira pacificamente in un container Docker gestito tramite Compose, e spostarlo all'interno del cluster Kubernetes.

Sulla carta, è un'operazione da cinque minuti. Prendi il `compose.yml`, lo traduci in un Deployment e un Servizio, applichi, fatto. In realtà, questa migrazione si è trasformata in una masterclass sulla differenza tra la **gestione dei volumi locali** (Docker) e lo **storage distribuito** (Kubernetes/Longhorn), e su come i permessi dei file possano diventare il nemico pubblico numero uno.

Questa non è una guida "copia-incolla". È la cronaca di come abbiamo sezionato il problema, analizzato i fallimenti e costruito una soluzione resiliente.

**Ebbene sì, il blog che state leggendo ora gira su Kubernetes in self-hosting su Proxmox sul mio mini PC di casa!**

---

## Fase 1: Il Paradosso dello Storage

Il punto di partenza era un semplice `docker-compose.yml` che usavo per lo sviluppo locale:

```yaml
services:
  hugo:
    image: hugomods/hugo:exts-non-root
    command: server --bind=0.0.0.0 --buildDrafts --watch
    volumes:
      - ./:/src  # <--- IL COLPEVOLE
```

Notate quella riga `volumes`. In Docker, stavo mappando la cartella corrente del mio host all'interno del container. È immediato: modifico un file sul mio laptop, Hugo se ne accorge e rigenera il sito.

### Il Problema Concettuale
Quando passiamo a Kubernetes, quel "mio laptop" non esiste più. Il Pod può essere schedulato su qualsiasi nodo del cluster. Non possiamo fare affidamento su file presenti sul filesystem dell'host (a meno di non usare `hostPath`, che però è un anti-pattern perché vincola il Pod a un nodo specifico, rompendo l'Alta Disponibilità).

La soluzione architetturale è usare un **PersistentVolumeClaim (PVC)** appoggiato a **Longhorn**. Longhorn replica i dati su più nodi, garantendo che se un nodo muore, i dati del blog sopravvivono e il Pod può ripartire altrove.

Ma qui sorge il paradosso: **Un volume Longhorn nuovo è vuoto.** 
Se avvio il Pod di Hugo attaccato a questo volume vuoto, Hugo crasherà istantaneamente perché non troverà il file `config.toml`.

### Strategia di Ingestione
Avevamo tre strade:
1.  **Git-Sync Sidecar:** Un container affiancato che clona costantemente il repo Git nel volume condiviso. Elegante, ma complesso per un blog personale.
2.  **InitContainer:** Un container che parte prima dell'app, clona il repo e muore.
3.  **Copia One-Off:** Avviare il Pod, aspettare che fallisca (o resti appeso) e copiare manualmente i dati una volta sola.

Abbiamo optato per una variante ibrida. Dato che l'obiettivo era mantenere la modalità "watch" per editare i file live (magari tramite editor remoto in futuro), abbiamo deciso di trattare il volume come la "Single Source of Truth".

---

## Fase 2: L'Architettura del Manifesto

Perché un **Deployment** e non un **StatefulSet**?

Spesso si associa lo StatefulSet alle applicazioni che hanno bisogno di stabilità dello storage. Tuttavia, Hugo (in modalità server) non ha bisogno di identità di rete stabili (come `hugo-0`, `hugo-1`). Ha solo bisogno dei suoi file. Un Deployment con strategia `Recreate` (per evitare che due pod scrivano contemporaneamente sullo stesso volume RWO) è sufficiente e più semplice da gestire.

Ecco il manifesto finale commentato:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hugo-blog
  namespace: hugo-blog # Isolamento prima di tutto
spec:
  replicas: 1
  strategy:
    type: Recreate # Evita il lock del volume Longhorn
  selector:
    matchLabels:
      app: hugo-blog
  template:
    metadata:
      labels:
        app: hugo-blog
    spec:
      # IL SEGRETO DEI PERMESSI
      securityContext:
        fsGroup: 1000 
      containers:
        - name: hugo
          image: hugomods/hugo:exts-non-root
          args:
            - server
            - --bind=0.0.0.0
            - --baseURL=https://blog.tazlab.net/
            - --appendPort=false
          ports:
            - containerPort: 1313
          volumeMounts:
            - name: blog-src
              mountPath: /src
      volumes:
        - name: blog-src
          persistentVolumeClaim:
            claimName: hugo-blog-pvc
```

### Deep Dive: `fsGroup: 1000`
Questo è stato il momento critico dell'indagine. L'immagine `hugomods/hugo:exts-non-root` è costruita per girare, come dice il nome, senza privilegi di root (UID 1000). 
Tuttavia, quando Kubernetes monta un volume (specialmente con certi driver CSI come Longhorn), la directory di mount può appartenere a `root` per default.

Risultato? Il container parte, prova a scrivere nella cartella `/src` (per la cache o file di lock) e riceve un `Permission Denied`.

L'istruzione `fsGroup: 1000` nel `securityContext` dice a Kubernetes: "Ehi, qualsiasi volume montato in questo Pod deve essere leggibile e scrivibile dal gruppo 1000". Kubernetes applica ricorsivamente un `chown` o gestisce i permessi ACL al momento del mount, risolvendo il problema alla radice.

---

## Fase 3: La Rete e il Discovery

Una volta che il Pod gira, deve essere raggiungibile. Qui entra in gioco **Traefik**, il nostro Ingress Controller.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hugo-blog-ingress
  annotations:
    # La magia di Let's Encrypt
    traefik.ingress.kubernetes.io/router.tls.certresolver: myresolver
spec:
  ingressClassName: traefik
  rules:
    - host: blog.tazlab.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hugo-blog
                port:
                  number: 80
```

Durante il setup, ho dovuto verificare quale fosse il nome esatto del resolver configurato in Traefik. Un rapido controllo su `traefik-values.yaml` ha confermato che l'ID era `myresolver`. Senza questa corrispondenza esatta, i certificati SSL non verrebbero mai generati.

Un dettaglio spesso trascurato: **BaseURL**.
Hugo genera i link interni basandosi sulla sua configurazione. Se gira sulla porta interna 1313, tenderà a creare link tipo `http://localhost:1313/post`. Ma noi siamo dietro un Reverse Proxy (Traefik) che serve sulla porta HTTPS 443.
L'argomento `--baseURL=https://blog.tazlab.net/` e `--appendPort=false` forza Hugo a generare link corretti per il mondo esterno, a prescindere dalla porta su cui ascolta il container.

---

## Fase 4: Operazione "Trapianto Dati"

Con il manifesto applicato, il Pod è andato in stato `Running`, ma serviva una pagina bianca o un errore, perché `/src` era vuota.

Qui abbiamo usato la forza bruta intelligente: `kubectl cp`.

```bash
# Copia locale -> Pod remoto
kubectl cp ./blog hugo-blog/hugo-blog-pod-xyz:/src
```

Grazie al `fsGroup` configurato in precedenza, i file copiati hanno mantenuto i permessi corretti per essere letti dal processo Hugo. Immediatamente, il watcher di Hugo ha rilevato i nuovi file (`config.toml`, `content/`) e ha compilato il sito in pochi millisecondi.

---

## Riflessioni Post-Lab

Questa migrazione ha spostato il blog da un'entità "pet" (legata al mio computer) a "cattle" (parte del cluster).

1.  **Resilienza:** Se il nodo dove gira Hugo muore, Longhorn ha replicato i dati su un altro nodo. Kubernetes rischedula il Pod, che si attacca alla replica dei dati e riparte. Tempo di downtime: secondi.
2.  **Scalabilità:** Non ne abbiamo bisogno ora, ma potremmo scalare a più repliche (rimuovendo la modalità `--watch` e usando Nginx per servire puramente gli statici).
3.  **Sicurezza:** Tutto gira in HTTPS, con certificati rinnovati automaticamente, e il container non ha privilegi di root.

La lezione di oggi è che in Kubernetes, **lo storage è un cittadino di prima classe**. Non è più solo una cartella su disco; è una risorsa di rete con le sue regole di accesso, permessi e ciclo di vita. Ignorare questo aspetto è la via più veloce per un `CrashLoopBackOff`.

