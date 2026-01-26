---
title: "Il Battesimo del Fuoco: Resilienza, Deadlock e Disaster Recovery nel Cluster TazLab"
date: 2026-01-26T21:30:00+00:00
draft: false
tags: ["Kubernetes", "Talos", "Longhorn", "Traefik", "Terraform", "Disaster Recovery", "DevOps"]
description: "Cronaca tecnica di una sessione di stress test estremo: dal collasso della rete al deadlock dello storage, fino alla stabilizzazione IaC del cluster."
---

## Introduzione: Il Peso della Teoria contro la Realtà del Ferro

Nelle scorse settimane ho dedicato molto tempo alla costruzione di una workstation immutabile e sicura. Tuttavia, un'officina perfettamente organizzata non serve a nulla se il "cantiere" — il mio cluster Kubernetes basato su Talos Linux e Proxmox — non è in grado di reggere l'urto di un guasto reale. Il mindset di oggi non era improntato alla costruzione, ma alla distruzione controllata. Volevo capire dove si spezza il filo della resilienza.

L'obiettivo della sessione era chiaro: ora che l'infrastruttura è gestita tramite **Terraform** e vanta 4 nodi worker, è tempo di testare le promesse dell'Alta Affidabilità (HA). Ma, come spesso accade nei sistemi distribuiti, ciò che sulla carta è una transizione indolore, nella realtà può trasformarsi in un effetto domino catastrofico. In questa cronaca documenterò come un semplice cambio di IP e uno spegnimento forzato abbiano portato il cluster sull'orlo del collasso, e come ho deciso di ricostruire le fondamenta per impedire che accada di nuovo.

---

## Fase 1: Espansione e Consolidamento IaC

Il primo passo è stato l'allineamento del cluster alla nuova configurazione desiderata. Ho deciso di utilizzare **Terraform** per gestire l'intero ciclo di vita dei nodi su Proxmox. L'uso di un approccio Infrastructure as Code (IaC) non è solo una questione di comodità; è una necessità per garantire la replicabilità del "Castello Effimero" di cui ho scritto in precedenza.

Ho configurato 4 nodi worker, distribuendo i carichi di lavoro in modo che nessun singolo nodo fosse un Single Point of Failure (SPOF). 

### Deep-Dive: Perché 4 Worker e 3 Control Plane?
In Kubernetes, il concetto di **Quorum** è vitale. Il piano di controllo (Control Plane) utilizza `etcd`, un database distribuito basato sull'algoritmo di consenso Raft. Per sopravvivere alla perdita di un nodo, serve un numero dispari di membri (3 è il minimo sindacale). Per i worker, il numero 4 permette di implementare strategie di **Antiaffinity** robuste: posso permettermi di perdere un nodo per manutenzione e avere ancora 3 nodi su cui distribuire le repliche, mantenendo un'alta densità di risorse senza sovraccaricare il ferro.

---

## Fase 2: Il Disastro Inaspettato - L'Effetto Domino del Cambio IP

Il test è iniziato con un evento apparentemente banale: il cambio dell'IP del nodo di Control Plane. Quello che doveva essere un aggiornamento di routine si è trasformato in un incubo operativo.

### Il Sintomo
Improvvisamente, i servizi interni al cluster hanno smesso di comunicare. I log di **CoreDNS** e **Longhorn** hanno iniziato a mostrare errori di tipo `No route to host` o `Connection refused` verso l'endpoint `10.96.0.1:443`.

### L'Investigazione
Ho iniziato l'indagine controllando lo stato dei pod con `kubectl get pods -A`. Molti erano in `CrashLoopBackOff`. Analizzando i log del `longhorn-manager`:
```text
time="2026-01-25T20:45:28Z" level=error msg="Failed to list nodes" error="Get \"https://10.96.0.1:443/api/v1/nodes\": dial tcp 10.96.0.1:443: connect: no route to host"
```

Il problema era profondo: il servizio interno di Kubernetes (`kubernetes.default`) puntava ancora al vecchio IP fisico del Control Plane (`.71`) invece del nuovo (`.253`). Nonostante io avessi aggiornato il `kubeconfig` esterno, le tabelle di routing interne (gestite da `kube-proxy` e `iptables`) erano rimaste incastrate.

### La Soluzione: Patching Manuale degli Endpoints
Ho deciso di intervenire chirurgicamente sull'oggetto `Endpoints` nel namespace `default`. Questa è un'operazione rischiosa perché solitamente gestita dal controller manager, ma in uno stato di partizione della rete, l'intervento manuale era l'unica via.

```bash
# Ho estratto la configurazione, corretto l'IP e riapplicata
kubectl patch endpoints kubernetes -p '{"subsets":[{"addresses":[{"ip":"192.168.1.253"}],"ports":[{"name":"https","port":6443,"protocol":"TCP"}]}]}' --kubeconfig=kubeconfig
```

Subito dopo, ho forzato un riavvio di `coredns` e `kube-proxy`. La rete ha ripreso a respirare, ma le ferite erano ancora aperte a livello di storage.

---

## Fase 3: Il Deadlock di Longhorn e lo Storage RWO

Risolta la rete, mi sono scontrato con la dura realtà dello storage distribuito. Avevo spento forzatamente alcuni nodi durante la fase di instabilità.

### Il Problema: I Volumi Fantasma
Longhorn utilizza volumi di tipo **RWO (ReadWriteOnce)**. Questo significa che un volume può essere montato da un solo nodo alla volta. Quando il nodo `worker-new-03` è stato spento bruscamente, il cluster Kubernetes lo ha marcato come `NotReady`, ma Longhorn ha mantenuto il "lock" sul volume di Traefik, pensando che il nodo potesse tornare da un momento all'altro.

Ho visto il nuovo pod di Traefik bloccato in `ContainerCreating` per minuti, con questo errore negli eventi:
`Multi-Attach error for volume "pvc-..." Volume is already exclusively attached to one node and can't be attached to another.`

### Analisi degli Errori: Perché non si sblocca da solo?
Ho analizzato il comportamento: Kubernetes aspetta circa 5 minuti prima di evincere i pod da un nodo morto. Tuttavia, anche dopo l'evizione, il CSI (Container Storage Interface) non stacca il volume se non riceve conferma che il nodo originale è spento. È una misura di protezione contro la corruzione dei dati (Split-Brain).

### La Soluzione: Forzare la Mano al Cluster
Ho deciso di procedere con una pulizia aggressiva dei **VolumeAttachments** e dei pod zombi.

```bash
# Cancellazione forzata del pod zombi
kubectl delete pod traefik-79fcb6d7fd-pwp9v -n traefik --force --grace-period=0

# Rimozione del VolumeAttachment stale
kubectl delete volumeattachment csi-5f3b43f479e048a26187... --kubeconfig=kubeconfig
```

Solo dopo queste azioni, Longhorn ha permesso al nuovo nodo di "prendere possesso" del disco. Questo mi ha insegnato che lo spegnimento forzato in un ambiente con storage RWO richiede quasi sempre un intervento umano per ripristinare la disponibilità del servizio.

---

## Fase 4: Il Limite di Traefik e la Necessità della Statelessness

Durante i test di replica, ho provato ad alzare il numero di istanze di Traefik a 2. Il risultato è stato un fallimento immediato.

### Il Ragionamento: Perché volevo 2 repliche?
In un'ottica di Alta Affidabilità, avere una sola istanza di Ingress Controller è un rischio inaccettabile. Se il nodo che ospita Traefik muore, il blog cade (come abbiamo visto nel test). Un normale `Deployment` dovrebbe permettermi di scalare orizzontalmente.

### Lo Scontro con la Realtà
Traefik è configurato per generare certificati SSL tramite Let's Encrypt e salvarli in un file `acme.json`. Per persistere questi certificati tra i riavvii, ho usato un volume Longhorn. 
H Qui sta l'errore architetturale: essendo il volume RWO, la seconda replica di Traefik non poteva partire perché il disco era già occupato dalla prima. 

**Ho deciso** quindi di mantenere momentaneamente una sola replica, ma ho tracciato un piano per migrare a **cert-manager**. Usando i Secret di Kubernetes per i certificati, Traefik diventerà completamente **stateless**, permettendoci di scalare a 3 o più repliche senza conflitti di disco.

---

## Fase 5: Il Test dei 5 Minuti - Automazione vs Prudenza

Ho voluto fare un ultimo esperimento scientifico: spegnere un nodo e cronometrare quanto tempo ci mette il cluster a reagire da solo.

1.  **T+0:** Spento forzatamente `worker-new-01`.
2.  **T+1:** Il nodo è `NotReady`. Il pod è ancora considerato `Running`.
3.  **T+5:** Kubernetes marca il pod come `Terminating` e ne crea uno nuovo su un altro nodo.
4.  **T+8:** Il nuovo pod è ancora in `Init:0/1`, bloccato dal volume Longhorn.

### Conclusione del Test
L'automazione di Kubernetes funziona per il calcolo, ma fallisce per lo storage persistente RWO in caso di guasti hardware improvvisi. Senza un sistema di **Fencing** (che spegne fisicamente il nodo tramite Proxmox API), il recupero automatico non è garantito in tempi brevi.

---

## Riflessioni Post-Lab: La Roadmap verso lo Zero Trust

Questa sessione di "stress e sofferenza" è stata più istruttiva di mille installazioni pulite. Ho imparato che la resilienza non è un tasto che si preme, ma un equilibrio che si costruisce pezzo dopo pezzo.

### Cosa significa questo per la stabilità a lungo termine?
Il cluster ora è molto più solido perché:
1.  **IP Statici e VIP:** Ho spostato tutta la gestione sul VIP `.250`. Se un nodo di controllo muore, il `kubeconfig` non deve cambiare.
2.  **Configurazione di Rete:** Ho corretto le rotte interne, assicurando che i componenti di sistema parlino con l'API corretta.
3.  **Gestione dello Storage:** Ora conosco i limiti di Longhorn e so come intervenire in caso di deadlock.

### Prossimi Passi
Ho già messo a bilancio due grandi lavori:
*   **Ristrutturazione Traefik:** Migrazione a `cert-manager` per eliminare i volumi RWO e permettere il multi-replica.
*   **Sicurezza Etcd:** Implementazione della `secretbox` e della Disk Encryption su Talos per proteggere i segreti a riposo.

In conclusione, il cluster TazLab ha superato il suo battesimo del fuoco. Non è ancora perfetto, ma è diventato un sistema capace di fallire con dignità e di essere riparato con precisione chirurgica. La strada verso il "Castello Effimero" prosegue, un deadlock alla volta.
