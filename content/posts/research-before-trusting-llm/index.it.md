+++
title = "Follow-Up: Non Fidarti dell'LLM — Dalla Ricerca all'Hardening Enterprise"
date = 2026-05-09T17:00:00+02:00
draft = false
tags = ["Kubernetes", "Talos OS", "Flux", "Tailscale", "DNS", "LLM", "Infisical", "Registry", "Enterprise", "Hardening"]
description = "Cronaca dell'implementazione tecnica post-ricerca: transizione verso un'architettura nativa per la risoluzione DNS, hardening del runtime Talos e stabilizzazione del bootstrap del cluster."
author = "Tazzo"
+++

## L'Ultima Volta: Analisi dello Stato Precedente

Nell'articolo precedente è emerso come una ricerca documentale approfondita abbia reso necessaria una revisione completa del progetto `15-tailscale-operator-hardening`. L'analisi ha confermato che la CRD `DNSConfig` del Tailscale Operator è funzionale solo se accoppiata a Service di tipo `ExternalName` con annotazione `tailscale.com/tailnet-fqdn`. Inoltre, il comportamento del controller CoreDNS di Talos v1.12 ha imposto il passaggio a una strategia di gestione diretta dello stack DNS ("Disable & Replace").

L'obiettivo di questa fase è stato trasformare i risultati della ricerca in un'implementazione stabile, eliminando i workaround temporanei precedentemente adottati (relay DaemonSet e mapping statici).

## Fase 1: Implementazione ExternalName e Risoluzione delle ACL

Il primo obiettivo tecnico è stato l'attivazione della risoluzione nativa per il Vault tramite l'Operator. Ho rimosso il relay DaemonSet e dichiarato un Service `ExternalName` nel namespace `tailscale`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: lushycorp-vault
  namespace: tailscale
  annotations:
    tailscale.com/tailnet-fqdn: lushycorp-vault.magellanic-gondola.ts.net
spec:
  type: ExternalName
  externalName: lushycorp-vault.magellanic-gondola.ts.net
```

**Analisi del fallimento iniziale**: Al deploy del manifest, l'Operator ha riportato un errore di provisioning (Status 400): `"requested tags [tag:k8s] are invalid or not permitted"`.
L'investigazione ha confermato che l'Operator tentava di registrare il proxy egress utilizzando il tag predefinito `tag:k8s`, non presente nelle ACL di Tailscale configurate in `ephemeral-castle`.

**Risoluzione**: Invece di modificare le ACL del tailnet, ho applicato il principio di minimo privilegio configurando l'Operator per utilizzare il tag già autorizzato `tag:k8s-operator` tramite i valori Helm:

```yaml
  values:
    operator:
      proxy:
        tags: ["tag:k8s-operator"]
```

L'applicazione della modifica ha permesso la corretta istanziazione del pod di proxy egress.

## Fase 2: Transizione a CoreDNS Managed su Talos

La gestione del DNS su Talos v1.12 richiede un approccio dichiarativo per evitare che il controller `machined` sovrascriva le configurazioni custom. Ho proceduto con la disabilitazione del controller nativo e il deploy di uno stack CoreDNS utente-managed.

Configurazione applicata via Terraform:
1.  **Disabilitazione**: `cluster.coreDNS.disabled: true`.
2.  **Kubelet Config**: `machine.kubelet.clusterDNS: ["10.96.0.10"]` per indirizzare il traffico DNS verso l'IP di servizio del nuovo stack.
3.  **Deploy**: Iniezione dell'intero stack (SA, RBAC, Deployment, Service, ConfigMap) come `inlineManifest` nella configurazione del Control Plane.

**Troubleshooting**: Durante il primo avvio, CoreDNS ha riportato l'errore `plugin/forward: not an IP address or file: "nameserver.tailscale.svc.cluster.local"`. Il plugin `forward` richiede un indirizzo IP esplicito come target, non supportando la risoluzione ricorsiva per i propri target di inoltro.

## Fase 3: IP Pinning e Invarianti di Design

Per eliminare la dipendenza da indirizzi IP dinamici e rendere l'infrastruttura resiliente a cicli di `destroy/create`, ho implementato un IP statico (Pinning) per il nameserver dell'Operator.

Ho dichiarato un Service aggiuntivo nel repository `tazlab-k8s`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nameserver-static
  namespace: tailscale
spec:
  type: ClusterIP
  clusterIP: 10.96.0.101 # Costante di design
  selector:
    app: nameserver
  ports:
    - name: udp
      port: 53
      targetPort: 1053
```

Il Corefile punta ora stabilmente a `10.96.0.101`, garantendo la persistenza della catena di risoluzione DNS a prescindere dallo stato del cluster.

## Fase 4: Registry Authentication via Container Runtime

È stata rimossa la logica di creazione dei pull secret tramite script bash, spostando l'autenticazione a livello di runtime `containerd`. Utilizzando il provider Terraform di **Infisical**, le credenziali per `ghcr.io` vengono ora iniettate direttamente nella configurazione dei nodi Talos:

```hcl
# Recupero dinamico da Infisical
data "infisical_secrets" "bootstrap" {
  env_slug     = "dev"
  workspace_id = var.infisical_workspace_id
  folder_path  = "/ephemeral-castle/tazlab-k8s/proxmox"
}

# Configurazione runtime
registries = {
  config = {
    "ghcr.io" = {
      auth = {
        username = "x-access-token"
        password = data.infisical_secrets.bootstrap.secrets["GITHUB_TOKEN"].value
      }
    }
  }
}
```

Questo approccio garantisce l'autenticazione node-wide, eliminando la necessità di gestire `ImagePullSecrets` nei singoli namespace.

## Fase 5: Risoluzione della Race Condition (TD-026)

L'ultimo step ha riguardato la stabilità del bootstrap del cluster. `oauth2-proxy` presentava una dipendenza critica dalla disponibilità di Dex. Per risolvere il debito tecnico **TD-026**, ho introdotto un `initContainer` nel deployment del proxy:

```yaml
initContainers:
  - name: wait-for-dex
    image: curlimages/curl:8.7.1
    args:
      - --retry
      - "30"
      - --retry-delay
      - "5"
      - https://dex.tazlab.net/.well-known/openid-configuration
```

La modifica assicura che il processo principale di `oauth2-proxy` venga avviato solo dopo la conferma della raggiungibilità dell'endpoint OIDC, garantendo una convergenza deterministica del cluster.

## Conclusioni

L'implementazione del progetto `15-tailscale-operator-hardening` ha permesso di allineare il cluster TazLab agli standard enterprise, eliminando i workaround non dichiarativi. 

Le lezioni apprese confermano l'efficacia di un workflow strutturato:
1.  **Priorità alla documentazione**: La ricerca esterna ha evitato l'implementazione di architetture fragili.
2.  **IaC e Invarianti**: L'uso di IP statici e configurazioni a livello di runtime aumenta la prevedibilità del sistema.
3.  **Metodologia CRISP**: La separazione tra design e implementazione, supportata da verifiche empiriche, ha garantito la riuscita del progetto.

Con il ClusterSecretStore ora in grado di risolvere e contattare Vault in modo nativo, l'infrastruttura è pronta per la fase di migrazione dei segreti.
