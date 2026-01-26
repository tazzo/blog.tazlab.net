---
title: "Dalla Visione al Silicio: Implementare il Castello Effimero su Proxmox"
date: 2026-01-28T22:08:55+01:00
draft: false
tags: ["kubernetes", "terraform", "proxmox", "talos", "gitops", "devops", "longhorn", "flux"]
categories: ["Infrastructure", "Tutorials"]
author: "Taz"
description: "Cronaca tecnica della prima fase di implementazione del Castello Effimero: provisioning con Terraform, gestione di Talos OS su Proxmox e configurazione dello storage distribuito."
---

L'architettura non è solo un disegno su carta o un manifesto d'intenti. Dopo aver delineato la visione del **Castello Effimero**, è giunto il momento di sporcarsi le mani con il silicio, i hypervisor e il codice dichiarativo. Questa è la cronaca della prima fase di implementazione: la transizione da un concetto astratto a un cluster Kubernetes funzionale, nato e gestito interamente tramite Infrastructure as Code (IaC).

Ho deciso di iniziare il viaggio nel mio laboratorio locale basato su **Proxmox VE**. La scelta non è casuale: il controllo totale sull'hardware mi permette di iterare rapidamente, testare i limiti dello storage distribuito e comprendere le dinamiche di rete prima di affrontare la complessità (e i costi) del cloud pubblico.

## Il Fondamento: Talos OS e la Morte di SSH

La prima decisione critica ha riguardato il sistema operativo dei nodi. Ho scelto **Talos OS**. In un mondo abituato a Ubuntu Server o Debian, Talos rappresenta un cambio di paradigma radicale: è un sistema operativo Linux progettato esclusivamente per Kubernetes. È immutabile, minimale e, soprattutto, non ha una shell SSH.

Perché questa scelta estrema? In un'infrastruttura che ambisce a essere "effimera", la persistenza di configurazioni manuali all'interno di un nodo è il nemico. Eliminando SSH, ho eliminato la tentazione di applicare "fix temporanei" che diverrebbero permanenti. Ogni modifica deve passare per l'API di Talos tramite file di configurazione YAML. Se un nodo si comporta in modo anomalo, non lo riparo: lo distruggo e lo ricreo.

### Deep-Dive: Immutabilità e Sicurezza
L'immutabilità significa che il filesystem di root è in sola lettura. Non ci sono gestori di pacchetti come `apt` o `yum`. Questo riduce drasticamente la superficie di attacco: anche se un malintenzionato riuscisse a ottenere l'accesso a un processo nel nodo, non potrebbe installare rootkit o modificare i binari di sistema. Il quorum di sicurezza del cluster ne beneficia direttamente.

## L'Incubo del DHCP e la Transizione a Terraform

L'implementazione iniziale è stata tutt'altro che fluida. Durante i primi test, ho lasciato che i nodi acquisissero gli indirizzi IP tramite DHCP. È stato un errore fondamentale che ha portato a un incidente tecnico significativo. Dopo un riavvio programmato del server Proxmox, il server DHCP ha assegnato nuovi indirizzi ai nodi del cluster.

Il risultato? Il Control Plane è diventato irraggiungibile. `kubectl` non riusciva più a autenticarsi perché i certificati erano legati ai vecchi IP, e il quorum di etcd era distrutto. Ho passato ore a tentare di patchare manualmente i nodi con `talosctl patch`, cercando di inseguire la nuova topologia di rete.

È qui che ho capito che la gestione manuale o semi-automatica non era sufficiente. Ho deciso di migrare l'intero provisioning su **Terraform**.

### La Soluzione: Networking Statico Dichiarativo
Ho riscritto i manifesti Terraform per definire staticamente ogni interfaccia di rete. Questo garantisce che, indipendentemente dai riavvii o dalle fluttuazioni della rete, il "Castello" mantenga la sua forma.

```hcl
# Uno scorcio del file providers.tf con la configurazione dei nodi
resource "proxmox_vm_qemu" "talos_worker" {
  count       = 3
  name        = "worker-${count.index + 1}"
  target_node = "pve"
  clone       = "talos-template"

  # Configurazione di rete statica per evitare il drift degli IP
  ipconfig0 = "ip=192.168.1.15${5 + count.index}/24,gw=192.168.1.1"
  
  cores   = 4
  memory  = 8192
  
  # L'integrazione con Talos avviene via machine_config
  # generato tramite il provider Talos dedicato.
}
```

L'uso di Terraform mi ha permesso di mappare lo stato desiderato dell'infrastruttura. Se voglio aggiungere un worker, cambio semplicemente il `count` da 3 a 4. Terraform calcolerà la differenza e interagirà con le API di Proxmox per clonare la VM, assegnare l'IP corretto e iniettare la configurazione Talos.

## Storage Distribuito: La Sfida di Longhorn

Un cluster senza storage persistente è solo un esercizio accademico. Per il Castello Effimero, avevo bisogno di un sistema di storage che fosse resiliente quanto il cluster stesso. La scelta è ricaduta su **Longhorn**.

Longhorn trasforma lo spazio disco locale dei nodi worker in un pool di storage distribuito e replicato. Tuttavia, far girare Longhorn su un sistema operativo immutabile come Talos richiede accortezze specifiche. Talos non include i binari per iSCSI (necessari per il montaggio dei volumi) o NBD (Network Block Device) per impostazione predefinita.

### Analisi degli Errori: Il Problema del Mount
Inizialmente, i pod non riuscivano a passare dallo stato `ContainerCreating` a `Running`. Controllando i log del sistema con `kubectl describe pod`, ho notato un errore ricorrente: `executable file not found in $PATH` riferito a `iscsid`. 

In un sistema tradizionale, avrei installato `open-iscsi` con un comando. Su Talos, ho dovuto istruire il sistema a caricare i moduli kernel necessari tramite la `machineConfig` di Talos, utilizzando le estensioni di sistema (`system extensions`).

```yaml
# Estratto della configurazione Talos per abilitare iSCSI
machine:
  install:
    extensions:
      - image: ghcr.io/siderolabs/iscsi-tools:v0.1.4
      - image: ghcr.io/siderolabs/util-linux-tools:v2.39.3
```

Questo passaggio è fondamentale: trasforma il nodo da un'entità generica a un componente specializzato dello storage cluster. Una volta configurato, Longhorn ha iniziato a replicare i dati tra i nodi, garantendo che anche in caso di perdita totale di un worker, i volumi del blog o dei database rimangano accessibili.

## GitOps: Il Cuore Pulsante con Flux CD

Il Castello Effimero non è configurato manualmente. Una volta che Terraform ha creato le VM e Talos ha inizializzato Kubernetes, entra in gioco **Flux CD**.

Flux è un operatore GitOps che mantiene il cluster sincronizzato con un repository GitHub. Ho creato due repository distinti:
1.  **ephemeral-castle**: Contiene il codice Terraform e le configurazioni "hardware" (IP, risorse VM).
2.  **tazlab-k8s**: Contiene i manifesti Kubernetes (Deployment, Service, HelmRelease).

### Perché non un unico repository?
Ho deciso di separare l'infrastruttura dal carico di lavoro. Terraform gestisce il "ferro" (anche se virtuale), mentre Flux gestisce l'ecosistema applicativo. Questa separazione permette di distruggere l'intero cluster mantenendo intatta la logica applicativa. Quando il nuovo cluster emerge, Flux rileva la sua presenza e inizia a scaricare i manifesti, ricreando l'ambiente esattamente come era prima.

### Deep-Dive: Il Loop di Riconciliazione
Il concetto chiave di Flux è il *Reconciliation Loop*. Flux monitora costantemente il repository Git. Se modifico il numero di repliche di un microservizio nel file YAML su GitHub, Flux rileva il "drift" tra lo stato attuale del cluster e lo stato desiderato nel repository e applica la modifica in pochi secondi. Questo elimina la necessità di eseguire comandi manuali come `kubectl apply -f`.

## Sicurezza e Segreti: SOPS e l'Integrazione Git

Versionare l'infrastruttura su GitHub comporta un rischio: la fuga di segreti. Password di Proxmox, chiavi SSH, token API... niente di tutto questo deve finire in chiaro nel repository.

Ho adottato **SOPS (Secrets Operations)** criptando i file sensibili con chiavi **Age**. I file risultanti (es. `proxmox-secrets.enc.yaml`) sono perfettamente sicuri da pushare su un repository privato. Terraform e Flux sono configurati per decriptare questi file "al volo" durante l'esecuzione, garantendo che le credenziali non tocchino mai il disco in formato non cifrato.

```bash
# Esempio di cifratura di un file di segreti
sops --encrypt --age $(cat key.txt) secrets.yaml > secrets.enc.yaml
```

## Riflessioni Post-Lab: Cosa abbiamo imparato?

Questa prima tappa del viaggio ha confermato una verità fondamentale del DevOps moderno: **l'automazione è dolorosa all'inizio, ma libera in seguito**. 

Configurare gli IP statici in Terraform è stato più lento che assegnarli manualmente su Proxmox. Configurare SOPS è stato più complesso che usare variabili d'ambiente. Tuttavia, ora dispongo di un'infrastruttura che posso replicare premendo un tasto. Il Castello è "Effimero" perché la sua esistenza fisica è irrilevante; ciò che conta è il codice che lo definisce.

### Prossimi Passi
Il Castello ora respira, ma è nudo. Nelle prossime cronache, affronteremo:
1.  **L'Ingress Controller**: Configurazione di Traefik per gestire il traffico esterno e la generazione automatica di certificati SSL con Let's Encrypt.
2.  **Il Blog Hugo**: Il deploy del sito che state leggendo, completamente automatizzato via CI/CD.
3.  **Verso le Nuvole**: La replica di questa intera architettura su AWS, dimostrando la vera portabilità del Castello Effimero.

La strada è ancora lunga, ma le fondamenta sono state gettate nel cemento del codice.

---
*Fine della Cronaca Tecnina - Tappa 1*
