---
title: "Le Fondamenta dell'Accessibilità: Traefik, Cert-Manager e il Pivot Filosofico del Castello"
date: 2026-01-30T06:42:00+01:00
draft: false
tags: ["kubernetes", "traefik", "cert-manager", "terraform", "devops", "security", "letsencrypt"]
categories: ["Infrastructure", "Security"]
author: "Taz"
description: "Cronaca tecnica dell'implementazione di Traefik e Cert-Manager nel Castello Effimero: la scelta del passaggio alla sfida HTTP-01 per garantire l'agnosticismo tecnologico."
---

# Le Fondamenta dell'Accessibilità: Traefik, Cert-Manager e il Pivot Filosofico del Castello

Dopo aver blindato il cuore del **Castello Effimero** con la cifratura di etcd e aver stabilito il ponte sicuro con Infisical, l'infrastruttura si trovava in uno stato di "solitudine sicura". Il cluster era protetto, ma isolato. In questa nuova tappa del mio diario tecnico, documento il processo di implementazione dei due pilastri che permettono al Castello di comunicare con il mondo esterno in modo sicuro e automatizzato: **Traefik** e **Cert-Manager**.

L'obiettivo della giornata era ambizioso: trasformare un cluster "nudo" in una piattaforma pronta alla produzione, capace di gestire il traffico HTTPS e il ciclo di vita dei certificati SSL senza alcun intervento manuale. Lungo il percorso, mi sono scontrato con scelte architetturali che hanno messo alla prova la filosofia stessa del progetto, portandomi a un cambiamento di rotta radicale.

---

## Il Preludio della Fiducia: TazPod come Identity Anchor

Nessuna automazione può iniziare senza un'identità verificata. Nel contesto del Castello Effimero, dove la portabilità è il dogma supremo, non posso permettermi di lasciare chiavi di accesso seminate sul disco rigido del mio laptop. Qui entra in gioco **TazPod**.

Il processo di bootstrap inizia sempre nel terminale. Attraverso il comando `tazpod pull`, attivo il "Ghost Mount": un'area di memoria cifrata, isolata tramite Linux Namespaces, dove risiedono i token di sessione di **Infisical**. È questo passaggio che permette a Terraform di autenticarsi verso l'istanza EU di Infisical e recuperare i segreti del cluster (come il token di Proxmox o le chiavi S3). 

Ho popolato il file `secrets.tfvars` attingendo da questa enclave sicura. Questo approccio garantisce che le credenziali "madre" non vengano mai scritte in chiaro sul filesystem persistente, mantenendo il mio ambiente di lavoro pronto a scomparire in qualsiasi momento senza lasciare tracce. Una volta che Terraform ha i suoi token, la danza del provisioning ha inizio.

---

## Fase 1: Traefik - Il Regista del Traffico

Per gestire il traffico in ingresso, la scelta è ricaduta su **Traefik**. In Kubernetes, un Ingress Controller è il componente che ascolta le richieste provenienti dall'esterno e le smista ai servizi corretti all'interno del cluster.

### Il Ragionamento: Perché Traefik e non Nginx?
Ho deciso di utilizzare Traefik principalmente per la sua natura "Cloud Native" e la sua capacità di auto-configurarsi leggendo le annotazioni delle risorse Kubernetes. Rispetto all'Ingress di Nginx, Traefik offre una gestione più fluida dei Custom Resource Definitions (CRD), come l'**IngressRoute**, che permette una granularità di configurazione superiore per il routing del traffico.

Avrei potuto scegliere un approccio basato su un **DaemonSet**, facendo girare Traefik su ogni nodo, ma per il cluster "Blue" (composto da un solo worker operativo) ho optato per un **Deployment** classico con una singola replica. Questo riduce il consumo di risorse e semplifica la gestione della persistenza, qualora fosse necessaria. In un'architettura più vasta, lo scaling sarebbe gestito da un Horizontal Pod Autoscaler basato sulle metriche di traffico.

### Integrazione IaC
Traefik non è stato installato via Flux, ma integrato direttamente nel `main.tf` di **ephemeral-castle**. Questa è una scelta di design fondamentale: l'Ingress è un componente dell'infrastruttura di base, non un'applicazione. Deve nascere insieme al cluster.

```hcl
# Traefik Ingress Controller Configuration
resource "helm_release" "traefik" {
  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  namespace  = kubernetes_namespace.traefik.metadata[0].name
  version    = "34.0.0"

  values = [
    <<-EOT
      deployment:
        kind: Deployment
        replicas: 1
      podSecurityContext:
        fsGroup: 65532
      additionalArguments:
        - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
        - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      ports:
        web:
          exposedPort: 80
        websecure:
          exposedPort: 443
      service:
        enabled: true
        type: LoadBalancer
        annotations:
          # Static IP from MetalLB Pool
          metallb.universe.tf/loadBalancerIPs: 192.168.1.240
      persistence:
        enabled: false # Switched to stateless
    EOT
  ]
  depends_on = [helm_release.longhorn, kubectl_manifest.metallb_config]
}
```

---

## Fase 2: Cert-Manager e il Pivot Filosofico

Un Ingress senza HTTPS è un'arma spuntata. Per automatizzare il rilascio dei certificati TLS via **Let's Encrypt**, ho introdotto **Cert-Manager**. Qui si è consumato il vero scontro ideologico della giornata.

### L'Errore Iniziale: La tentazione del DNS-01
Inizialmente, ho configurato Cert-Manager per utilizzare la sfida **DNS-01** tramite Cloudflare. Il vantaggio tecnico è innegabile: permette di generare certificati **Wildcard** (`*.tazlab.net`), semplificando enormemente la gestione dei sottodomini. Ho creato l'integrazione con Infisical per recuperare il Cloudflare API Token e ho visto con soddisfazione il primo certificato wildcard apparire nel cluster.

### L'Investigazione: Il tradimento dell'Agnosticismo
Mentre osservavo il certificato pronto, ho capito che stavo violando il primo comandamento dell'Ephemeral Castle: **l'indipendenza dal fornitore**.
Legando l'infrastruttura di base a Cloudflare, stavo creando un "lock-in". Se un domani volessi donare questo progetto alla comunità o utilizzarlo per un cliente che usa DNS diversi, dovrei riscrivere la logica del `ClusterIssuer`.

**Ho deciso di fare un passo indietro.** Ho distrutto la configurazione Cloudflare e sono passato alla sfida **HTTP-01**.

### Deep-Dive: DNS-01 vs HTTP-01
- **DNS-01**: Cert-manager scrive un record TXT nel tuo DNS per provare la proprietà. Permette i wildcard ma richiede un'integrazione specifica per ogni provider (Cloudflare, Route53, ecc.).
- **HTTP-01**: Cert-manager espone un file temporaneo sulla porta 80. Let's Encrypt lo legge e valida il dominio. È universale e agnostico rispetto al DNS, ma non permette i wildcard.

Per il Castello, l'agnosticismo è più importante della comodità di un unico certificato. Ogni app (Blog, Grafana, ecc.) richiederà ora il proprio certificato specifico. È una scelta più pulita e coerente con un'architettura modulare.

---

## Fase 3: Analisi degli Errori e "The Ephemeral Way"

Il passaggio da una configurazione all'altra non è stato indolore. Durante l'aggiornamento di Traefik tramite Terraform, il comando è andato in timeout.

### Lo Struggle: Helm in limbo
Ho visto la risorsa `helm_release.traefik` bloccata in stato `pending-install`. Quando Terraform va in timeout durante un'installazione Helm, il cluster rimane in uno stato inconsistente: la release esiste nel database di Helm ma Terraform ha perso il "puntamento" (state).

Al tentativo successivo, ricevevo l'errore:
`Error: cannot re-use a name that is still in use`

**Il processo mentale di risoluzione:**
1. Ho controllato lo stato reale con `helm list -n traefik`.
2. Ho provato a importare la risorsa nello stato di Terraform (`terraform import`), ma la release era segnata come "failed" e non importabile.
3. Ho adottato la soluzione "Ephemeral": ho disinstallato manualmente Traefik con `helm uninstall`, rimosso la risorsa dallo stato di Terraform (`terraform state rm`) e cancellato il namespace per pulire ogni residuo di PVC.
4. Ho rilanciato `terraform apply`.

Questo approccio "tabula rasa" è il cuore del progetto. Invece di debuggare per ore un database Helm corrotto, riporto il sistema allo stato zero e lascio che il codice dichiarativo lo ricostruisca correttamente.

---

## Fase 4: La Configurazione Finale Agnostica

Ecco come si presenta ora il `ClusterIssuer` universale nel Castello. Non ha bisogno di API token esterni, gli basta un'email per Let's Encrypt.

```hcl
# letsencrypt-issuer.tf (integrated in main.tf)
resource "kubectl_manifest" "letsencrypt_issuer" {
  yaml_body = <<-EOT
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: letsencrypt-issuer
    spec:
      acme:
        email: ${var.acme_email}
        server: https://acme-v02.api.letsencrypt.org/directory
        privateKeySecretRef:
          name: letsencrypt-issuer-account-key
        solvers:
        - http01:
            ingress:
              class: traefik
  EOT
  depends_on = [helm_release.cert_manager, helm_release.traefik]
}
```

Abbiamo inoltre implementato il **Zero-Hardcoding** totale. Ogni IP, ogni dominio (`tazlab.net`) e ogni parametro è gestito via `variables.tf` e `terraform.tfvars`. Il codice è ora una "scatola vuota" pronta ad essere riempita con qualsiasi configurazione.

---

## Riflessioni post-lab: Cosa significa questo setup?

Con l'implementazione di Traefik e Cert-Manager (HTTP-01), il Castello ha completato la sua fase di "Infrastruttura di Base". 

### Cosa abbiamo imparato:
1.  **Stateless è meglio**: Rimuovendo ACME da Traefik e delegandolo a Cert-Manager, abbiamo reso l'Ingress Controller totalmente stateless. Possiamo distruggerlo e ricrearlo senza preoccuparci di perdere i file `.json` dei certificati.
2.  **L'indipendenza ha un prezzo**: Rinunciare ai wildcard cert è un piccolo fastidio operativo, ma garantisce che il Castello possa "atterrare" su qualsiasi provider DNS senza modifiche al codice core.
3.  **Il Castello è una Fabbrica**: La struttura attuale permette di clonare l'intera cartella del provider Proxmox, cambiare tre righe nel file `.tfvars` e avere un nuovo cluster funzionante in meno di 10 minuti.

Mancano ancora degli elementi per definire questa base "completa" (Prometheus e Grafana sono i prossimi sulla lista), ma la via è tracciata. Il resto del lavoro è ora nelle mani di **Flux**, che inizierà a popolare il Castello con le applicazioni reali, partendo dal Blog che state leggendo.

---
*Fine della Cronaca Tecnica - Fase 3: Ingress e Automazione Certificati*
