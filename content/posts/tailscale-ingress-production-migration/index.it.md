+++
title = "Tailscale Ingress in Produzione: Una Storia di Migrazione Pratica da TazLab"
date = 2026-05-24T15:00:00+02:00
draft = false
description = "Dopo aver risolto il DNS con il Tailscale Operator e migrato i segreti da Infisical a Vault, il passo successivo era coerente: portare anche l'accesso ai servizi interni sulla tailnet. Ecco come ho sostituito MetalLB e Traefik pubblico con Ingress e LoadBalancer Tailscale."
tags = ["tailscale", "kubernetes", "networking", "migration", "ingress", "metalLB", "talos", "flux", "crisp"]
categories = ["Infrastructure", "DevOps", "Networking"]
author = "Taz"
+++

# Tailscale Ingress in Produzione: Una Storia di Migrazione Pratica da TazLab

Se avete seguito la saga del cluster TazLab fin qui, conoscete il ritmo: ogni articolo descrive un passo avanti nell'architettura. Dapprima il **DNS** — risolvere il MagicDNS di Tailscale per i pod del cluster con il Tailscale Operator, dopo otto cicli destroy-create e un redesign completo della DAG Flux. Poi i **segreti** — migrare tutti i 20 segreti da Infisical a Vault in una sessione, certificando il bootstrap con un destroy/create da zero (e uscendone con un blog post intitolato One Vault In, One Vault Out).

Ora è il turno della **rete**. Dopo che il Vault è diventato il backend unico dei segreti, e dopo che il Tailscale Operator è diventato il gateway DNS tra cluster e tailnet, il passo successivo era naturale: portare l'accesso ai servizi interni — homepage, database, dashboard — sulla stessa tailnet, eliminando la dipendenza da indirizzi IP pubblici e LoadBalancer MetalLB.

Questo articolo racconta come ho migrato sei servizi da Traefik pubblico + MetalLB a Ingress e LoadBalancer nativi di Tailscale, le sorprese lungo il percorso, e cosa significa esporre servizi in una architettura tailnet-native.

## Il punto di partenza: servizi protetti, ma esposti

Prima di questa migrazione, l'architettura di esposizione dei servizi era questa:

```
         Internet
            │
      ┌─────▼──────┐
      │  Traefik   │ ← ingress pubblici con TLS wildcard
      │ + oauth2   │ ← protetti da Dex + oauth2-proxy
      └─────┬──────┘
            │
      ┌─────▼──────┐
      │  Servizi   │ ← homepage, pgAdmin, Grafana, Longhorn...
      └────────────┘

      TazPod (container)
            │
      ┌─────▼──────┐
      │  MetalLB   │ ← LoadBalancer IP 192.168.1.241
      │  Postgres  │
      └────────────┘
```

I servizi amministrativi erano protetti da **oauth2-proxy + Dex**: nessun utente non autenticato poteva accedervi. Il database era esposto su un IP MetalLB raggiungibile solo dalla rete locale. L'architettura non era insicura — ma era incoerente.

Il problema non era la sicurezza, ma il paradigma. Avevamo un'infrastruttura connessa alla tailnet (Vault su Hetzner, cluster Proxmox/Talos, TazPod), ma i servizi interni parlavano ancora il linguaggio del "cloud pubblico": ingress su FQDN pubblici, LoadBalancer su IP di rete locale, certificati TLS wildcard gestiti manualmente. Ogni servizio aveva un modo diverso di essere raggiunto: chi via Traefik, chi via MetalLB, chi via IP diretto. Il nuovo paradigma, dopo Vault e dopo il Tailscale Operator, era uno solo: **tutto passa per la tailnet**.

## La progettazione: CRISP e design review

Come per i progetti precedenti, l'intero percorso è stato gestito con la metodologia **CRISP**, partendo da una fase di Ricerca e Design prima di toccare un solo file YAML.

### La ricerca esterna: cosa dice la documentazione ufficiale

Prima di scrivere qualsiasi configurazione, ho fatto due ricerche parallele: una con Context7 sulle docs ufficiali del Tailscale Operator (validate gennaio 2026) e una manuale con deep research. L'obiettivo era chiarire esattamente come il Tailscale Operator gestisce l'esposizione dei servizi.

La scoperta principale: il Tailscale Operator supporta **tre meccanismi** di exposure, non uno solo:

1. **LoadBalancer Service** con `loadBalancerClass: tailscale` — per qualsiasi protocollo TCP/UDP (Postgres, SSH, ecc.)
2. **Annotation** `tailscale.com/expose: "true"` su un Service esistente — per esposizione rapida senza creare nuove risorse
3. **Ingress** con `ingressClassName: tailscale` — solo HTTP/HTTPS, con TLS automatico Let's Encrypt

Il database (Postgres) sarebbe stato esposto con il metodo 1. Le dashboard amministrative (homepage, pgAdmin, Longhorn, Traefik, Grafana) con il metodo 3.

Una differenza cruciale emersa dalla ricerca: l'Ingress Tailscale supporta **solo TLS sulla porta 443**. Non esiste un'esposizione in chiaro su porta 80. Questo non era un problema — i nostri back-end parlano già HTTP internamente — ma è un vincolo architetturale da conoscere.

### Il design review dell'agente

Prima di passare all'implementazione, ho lanciato un agente di **design review** per analizzare il progetto. La review ha identificato nove punti critici, di cui uno ha richiesto una decisione architetturale importante: il modello di autenticazione.

Il piano originale prevedeva di mantenere **oauth2-proxy** dietro l'Ingress Tailscale, preservando il doppio strato di sicurezza: ACL Tailscale per la rete, oauth2-proxy per l'autenticazione utente. Ma la verifica sul deployment di oauth2-proxy ha rivelato un'incompatibilità di fondo:

```bash
kubectl get deployment -n auth oauth2-proxy -o json | jq '.spec.template.spec.containers[0].args'
["--provider=oidc",
 "--upstream=static://200",     # ← non forwarda a nessuna app
 "--set-xauthrequest=true",     # ← solo middleware per Traefik
 ...
]
```

oauth2-proxy nel nostro cluster non è un reverse proxy: è configurato come **forward-auth middleware** per Traefik. Con `--upstream=static://200`, non serve alcuna applicazione — restituisce un 200 OK se l'autenticazione è valida, e Traefik si occuperà di inoltrare la richiesta all'app vera. Non può essere usato come back-end di un Ingress Tailscale.

La decisione: **Tailscale ACL + identity headers**. L'Ingress Tailscale inietta header HTTP come `Tailscale-User` e `Tailscale-User-Login` che identificano il chiamante nella tailnet. L'ACL di Tailscale blocca a livello di rete (solo device autorizzati), gli header forniscono identità per audit, e ogni applicazione mantiene il proprio login interno. Tre strati, nessun oauth2-proxy nel mezzo.

Altre decisioni emerse dalla review:

- **pgBouncer bypass intenzionale**: TazPod è l'unico consumer tailnet del database con 1-2 connessioni persistenti. Il connection pooling non servirebbe a nulla. Se in futuro si aggiungeranno altri consumer, si creerà un secondo Service tailnet che punta a pgBouncer.
- **Comment-out per rollback**: il vecchio Service MetalLB non viene cancellato ma commentato in git. Se la migrazione dovesse avere problemi, un `git revert` ripristina il percorso originale in pochi secondi.
- **Pulizia certificati wildcard**: dopo ogni migrazione, il blocco ExternalSecret del TLS wildcard e l'Ingress Traefik associato vengono rimossi.

## Bug #19471: lo scope services

Prima di poter creare qualsiasi risorsa di exposure, ho dovuto risolvere un bug noto del Tailscale Operator v1.96.x. L'OAuth client `k8s_operator` era configurato con il solo scope `devices` — sufficiente per il DNSConfig, ma non per creare proxy Ingress o LoadBalancer.

Il bug è documentato nell'issue #19471 del repository Tailscale: durante la fase di avvio, l'operatore esegue una chiamata di autoverifica verso l'endpoint `/api/v2/tailnet/-/vip-services`. Se l'OAuth client non ha lo scope `services`, l'endpoint restituisce 404, e l'operatore interpreta l'errore come `InvalidOAuth`, bloccando la creazione di qualsiasi proxy.

La soluzione: aggiornare l'OAuth client via Terraform:

```hcl
resource "tailscale_oauth_client" "k8s_operator" {
  description = "tazlab-k8s-operator"
  scopes      = ["devices", "auth_keys", "services"]
  tags        = ["tag:k8s-operator"]
}
```

```bash
terraform apply -auto-approve -var="tailscale_api_key=${TS_API_KEY}" \
  -var="tailnet=magellanic-gondola.ts.net"
kubectl delete pod -n tailscale operator-...  # riciclo per nuove credenziali
```

### HTTPS tailnet: un'API call dimenticata

Un'altra scoperta: l'Ingress Tailscale richiede che l'opzione **HTTPS** (Let's Encrypt) sia abilitata a livello di tailnet. Non lo era. Dal Terraform state: `"httpsEnabled": false`. Con una semplice chiamata API:

```bash
curl -X PATCH -H "Authorization: Bearer ${TS_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"httpsEnabled": true}' \
  "https://api.tailscale.com/api/v2/tailnet/magellanic-gondola.ts.net/settings"
```

Il problema è stato risolto in pochi secondi.

## Le ACL: nuovi tag per nuovi servizi

La migrazione ha richiesto anche un aggiornamento delle policy di accesso della tailnet. Abbiamo aggiunto due nuovi tag:

- **`tag:k8s`**: tag di default per i proxy creati dall'operatore (LoadBalancer e Ingress)
- **`tag:internal-apps`**: tag per gli Ingress delle dashboard amministrative

```json
"tagOwners": {
  "tag:k8s":           ["tag:k8s-operator"],
  "tag:internal-apps": ["tag:k8s-operator"]
}
```

E due nuove regole ACL per permettere a TazPod di raggiungere i servizi esposti:

```json
{"action": "accept", "src": ["tag:tazpod"], "dst": ["tag:k8s:5432"]},
{"action": "accept", "src": ["tag:tazpod"], "dst": ["tag:internal-apps:443"]}
```

## L'implementazione: sei servizi, tre slice

La migrazione è stata suddivisa in tre slice verticali, ciascuna implementata e validata indipendentemente.

### Slice 1: Database

Il primo servizio migrato è stato il database PostgreSQL. Il vecchio Service MetalLB (`tazlab-db-external` su `192.168.1.241:5432`) è stato sostituito da un LoadBalancer Tailscale:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: tazlab-db-tailnet
  annotations:
    tailscale.com/hostname: "tazlab-db"
    tailscale.com/tags: "tag:k8s"
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  ports:
    - port: 5432
  selector:
    postgres-operator.crunchydata.com/cluster: tazlab-db
    postgres-operator.crunchydata.com/role: master
```

Il database è ora raggiungibile da qualsiasi device nella tailnet all'indirizzo `tazlab-db.magellanic-gondola.ts.net:5432`.

**Un dettaglio importante**: il selettore del Service deve corrispondere esattamente a quello del MetalLB originale — entrambi i label `cluster: tazlab-db` **e** `role: master`. Durante la design review, l'agente ha notato che il mio primo bozzetto usava solo `role: master`, che avrebbe potuto matchare repliche in futuro.

### Slice 2: Dashboard amministrative

Le cinque dashboard (Homepage, pgAdmin, Longhorn, Traefik, Grafana) sono state migrate una alla volta, in ordine di complessità. Il meccanismo è lo stesso per tutte: un Ingress con `ingressClassName: tailscale` che punta direttamente al Service dell'applicazione.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pgadmin-tailnet
  annotations:
    tailscale.com/experimental-forward-cluster-traffic-via-ingress: "true"
    tailscale.com/tags: "tag:internal-apps"
spec:
  ingressClassName: tailscale
  tls:
    - hosts:
        - pgadmin
  defaultBackend:
    service:
      name: pgadmin
      port:
        number: 8001
```

Due annotazioni sono obbligatorie per ogni Ingress:

- **`tailscale.com/experimental-forward-cluster-traffic-via-ingress: "true"`**: permette ai pod all'interno del cluster di raggiungere l'Ingress tramite il nome MagicDNS. Senza questa annotation, il traffico hairpin (pod → stesso cluster via tailnet) non funziona.
- **`tailscale.com/tags: "tag:internal-apps"`: assegna il tag al device proxy creato dall'operatore, controllato dalle ACL della tailnet.

Ogni migrazione è stata un'operazione GitOps in due fasi:

1. **Fase 1**: creazione del nuovo Ingress Tailscale (convive con il vecchio Ingress Traefik) → validazione → commit
2. **Fase 2**: rimozione dell'Ingress Traefik e dell'ExternalSecret TLS wildcard → rimozione annotazioni MetalLB dal Service → cambio del Service da LoadBalancer a ClusterIP → commit

### L'errore YAML che ha bloccato Flux

Durante la fase 2, ho rimosso le annotazioni MetalLB da alcuni Service YAML, ma l'indentazione è risultata errata: `spec:` è finito come figlio di `metadata:` invece che allo stesso livello.

```yaml
# ERRATO
kind: Service
metadata:
  name: longhorn
  namespace: longhorn-system
  spec:                # ← indentato sotto metadata!
  type: ClusterIP
  ports: ...
```

Il dry-run di Flux falliva con: `Service "longhorn" is invalid: spec.ports: Required value`. Il messaggio non diceva "indentazione errata" — diceva "ports richiesti", portandomi a cercare il problema nel posto sbagliato.

Ho risolto correggendo l'indentazione in tre file (longhorn, traefik, pgadmin) e ripushando. Una lezione: quando Flux dice che un campo è "richiesto" e sai di averlo scritto, controlla la struttura YAML — il validatore Kubernetes interpreta l'albero in modo letterale.

### Slice 3: Link della homepage

L'ultima slice è stata la più semplice: aggiornare i link nella `services.yaml` della homepage per puntare ai nuovi hostname tailnet, e aggiungere `home.magellanic-gondola.ts.net` alla whitelist `HOMEPAGE_ALLOWED_HOSTS`.

## Il risultato

| Servizio | Prima | Dopo |
|---|---|---|
| Database | MetalLB `192.168.1.241:5432` | `tazlab-db.magellanic-gondola.ts.net:5432` |
| Homepage | Traefik `home.tazlab.net` | `home.magellanic-gondola.ts.net` |
| pgAdmin | Traefik `pgadmin.tazlab.net` | `pgadmin.magellanic-gondola.ts.net` |
| Longhorn | Traefik `longhorn.tazlab.net` | `longhorn.magellanic-gondola.ts.net` |
| Traefik | Traefik `traefik.tazlab.net` | `traefik.magellanic-gondola.ts.net` |
| Grafana | Traefik `grafana.tazlab.net` | `grafana.magellanic-gondola.ts.net` |

Tutti i servizi sono ora accessibili esclusivamente via tailnet. Nessun indirizzo IP pubblico, nessun LoadBalancer MetalLB, nessun Ingress Traefik per i servizi interni. L'unico modo per raggiungerli è essere un device autorizzato nella tailnet.

## Lezioni apprese

**Il design review trova problemi che il piano non vede.** La review ha identificato l'incompatibilità di oauth2-proxy che, se scoperta in fase di implementazione, avrebbe fermato tutto e richiesto un redesign. Costa 30 minuti di review, risparmia ore di debugging.

**La ricerca esterna è un investimento, non un costo.** Senza aver verificato la documentazione ufficiale, non avrei saputo che l'Ingress Tailscale è solo TLS, che lo scope `services` è obbligatorio, o che il clusterIP può essere definito nel DNSConfig CR. Ogni assunto non verificato è un potenziale blocco in fase di build.

**YAML è unforgiving.** L'errore di indentazione che ha bloccato Flux è stato banale ma difficile da diagnosticare perché il messaggio di errore puntava nella direzione sbagliata. La prossima volta, dopo una modifica strutturale a un file YAML, farò una validazione sintattica con `kubectl --dry-run` prima del push.

**Il paradigma tailnet è coerente.** Il filo conduttore di questa serie di articoli è la progressiva migrazione verso un'architettura tailnet-native: prima il DNS, poi i segreti, ora la rete. Ogni passo è reso possibile dal precedente, e ogni passo semplifica il successivo. È un pattern che si auto-alimenta.
