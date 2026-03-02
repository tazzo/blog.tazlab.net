+++
title = "Da Zero a OIDC: Il Diario di Viaggio dell'Autenticazione Zero Trust nel Nostro Cluster Kubernetes"
date = 2026-02-28T15:00:00+01:00
draft = false
description = "Cronaca tecnica dell'implementazione di DEX + oauth2-proxy nel cluster Kubernetes TazLab: scelte architettoniche, errori, debugging e le soluzioni adottate per autenticare i dashboard attraverso Google OAuth."
tags = ["kubernetes", "dex", "oauth2", "oidc", "traefik", "zero-trust", "gitops", "flux", "external-secrets"]
author = "Tazzo"
+++

## Introduzione: Il Problema della Protezione dei Dashboard

Quando costruisci un'infrastruttura Kubernetes moderna, uno dei problemi più critici che emergi rapidamente è la gestione dell'accesso ai dashboard operazionali. Nel mio laboratorio TazLab—un cluster Talos Linux su Proxmox con stack completo GitOps — avevo già implementato Grafana per il monitoraggio, pgAdmin per la gestione del database PostgreSQL, e una dashboard informativa (Homepage) per la navigazione. Tutti questi componenti erano accessibili via Traefik Ingress, ma nessuno di essi era protetto da autenticazione. Chiunque potesse raggiungere `https://grafana.tazlab.net` dal mio laboratorio poteva accedere a dati sensibili di monitoraggio senza inserire credenziali.

Ho deciso che questa situazione violava il principio fondamentale di **Zero Trust** che guida l'intera architettura di Ephemeral Castle. L'obiettivo della giornata era dunque ambizioso: implementare un sistema di Single Sign-On (SSO) tramite Google OAuth, dove tutti le dashboard sarebbero state protette dietro un'unica porta d'ingresso di autenticazione. L'utente avrebbe dovuto fare login una sola volta con il proprio account Google, e poi tutti gli accessi successivi ai vari servizi sarebbero stati autorizzati automaticamente, senza ulteriori prompt di password.

Questa "tappa del viaggio" di TazLab rappresenta una svolta significativa: l'infrastruttura stava evolvendo da un ambiente semplicemente "funzionante" a un ambiente "enterprise-ready", dove la sicurezza non era un'aggiunta ma un principio fondante.

---

## Fase 1: L'Architettura OIDC e le Scelte Strategiche

Prima di scrivere il primo manifesto YAML, ho dovuto prendere una serie di decisioni architettoniche che avrebbero definito l'intero approccio. Non esisteva una sola strada corretta; ogni scelta implicava trade-off che avrebbero influenzato la stabilità a lungo termine del sistema.

### Perché DEX e Non Keycloak? Una Comparazione Consapevole

La scelta più critica è stata il provider OIDC. Gli standard nel panorama Kubernetes sono due: **Keycloak** e **DEX**. Keycloak è un ecosistema completo, estremamente flessibile, supportato da una comunità gigantesca, con un'interfaccia di amministrazione ricca e decine di connettori. DEX, invece, è uno strumento minimalista: un provider OIDC Kubernetes-native che legge la propria configurazione da file YAML, persiste i dati tramite CRD (Custom Resource Definition) di Kubernetes stesso, e non ha interfaccia web di amministrazione (tutto è dichiarativo).


Ho scelto DEX per una ragione fondamentale: l'allineamento filosofico con la mia infrastruttura. TazLab è costruita completamente attorno a Kubernetes come database dei fatti. Flux CD gestisce lo stato dichiarativo attraverso il controllo versione (Git). Tutti i segreti risiedono in Infisical e vengono sincronizzati tramite External Secrets Operator. Aggiungere Keycloak significava introdurre un nuovo strato di dati—un database separato con il suo ciclo di vita, i suoi backup, le sue dipendenze—che vivrebbe fuori dal paradigma dichiarativo. DEX, al contrario, sfrutta le CRD di Kubernetes per la persistenza: ogni token, ogni sessione di autenticazione, è un oggetto nativo di Kubernetes memorizzato in etcd. Questo significa che i backup automatici di etcd proteggono anche il sistema di autenticazione. Significa che la disaster recovery è coerente con il resto dell'infrastruttura.

La controindicazione di DEX è la mancanza di un'interfaccia web ricca. Se devo modificare il comportamento del provider (aggiungere un nuovo connettore, cambiare la configurazione), devo editare file YAML e committarli in Git, non cliccare in una UI. Inizialmente, questa limitazione sembrava restrittiva. Ma dopo aver implementato il sistema, mi sono reso conto che era un punto di forza: la tracciabilità. Ogni modifica a DEX è un commit Git con un autore, un timestamp, un motivo documentato in un PR. Non esiste "l'amministratore che ha clickato il pulsante sbagliato".

### oauth2-proxy Come Middleware Traefik: Il Pattern ForwardAuth

Una volta scelto DEX come OIDC provider, mi è stato necessario un proxy che intercettasse le richieste HTTP ai miei dashboard, verificasse se l'utente era già autenticato con Google, e se no, lo redirigesse al flusso di autenticazione. La soluzione standard nel mondo Kubernetes è **oauth2-proxy**.

oauth2-proxy è un reverse proxy specializzato nell'integrazione OAuth2. Viene tipicamente distribuito come pod in Kubernetes e configurato come un **Middleware Traefik** nel modello `ForwardAuth`. In questo pattern architetturale, quando una richiesta arriva a un Ingress Traefik protetto, Traefik non passa direttamente la richiesta all'applicazione backend. Invece, invia una richiesta di verifica al servizio oauth2-proxy, chiedendogli: "Questo cliente è autenticato?" Se oauth2-proxy risponde con HTTP 200, significa "sì, è valido", e Traefik procede. Se risponde con 401, Traefik blocca la richiesta e redirige il client al servizio di login.

**Deep-Dive Concettuale: Il Pattern ForwardAuth di Traefik**

Il pattern ForwardAuth è un'implementazione del paradigma di "external authorization service" che viene comunemente usato anche in nginx (tramite `auth_request`). L'idea è elegante dal punto di vista architetturale: la decisione di autenticazione è delegata a un servizio specializzato, il quale rimane completamente disaccoppiato dall'applicazione vera. Questo significa che posso proteggere *qualsiasi* applicazione—Grafana, pgAdmin, una semplice pagina HTML—senza modificarne il codice. L'applicazione non ha nemmeno bisogno di "sapere" che c'è un proxy davanti. Dal suo punto di vista, arrivano richieste HTTP come sempre. La differenza è che Traefik ha già verificato l'autenticazione tramite il Middleware ForwardAuth, e passa all'app alcuni header aggiuntivi (come `X-Auth-Request-User`) che l'app può usare per riconoscere automaticamente l'utente loggato.

Questo pattern è particolarmente potente quando combinato con la possibilità di Traefik di passare header HTTP verso il servizio di verifica e raccogliere header di risposta. Nel caso di oauth2-proxy, il flusso diventa:
1. Client richiede `/dashboard` su Grafana
2. Traefik intercetta la richiesta e la invia a oauth2-proxy per verifica
3. oauth2-proxy controlla se il client ha il cookie di sessione valido
4. Se sì, risponde 200 e include negli header di risposta il nome utente (es. `X-Auth-Request-User: roberto.tazzoli@gmail.com`)
5. Traefik passa la richiesta a Grafana, aggiungendo quegli header
6. Grafana legge l'header e crea automaticamente una sessione per quell'utente

---

## Fase 2: L'Implementazione Iniziale (La Fiducia Nei Piani)

Con le decisioni architettoniche prese, ho proceduto all'implementazione. Ho deciso di strutturare il progetto seguendo le convenzioni già presenti in TazLab:

- **`infrastructure/configs/dex/`**: ExternalSecrets che tirano i segreti Google da Infisical, e i file di configurazione di DEX
- **`infrastructure/instances/dex/`**: Deployment, Service, Ingress, RBAC per DEX
- **`infrastructure/auth/`**: Un nuovo layer dedicato a oauth2-proxy, middleware Traefik, e la configurazione di Flux
- **`infrastructure/operators/monitoring/`**: Aggiornamenti agli ingress di Grafana per applicare il middleware ForwardAuth

Ho creato 19 file YAML in totale, circa 1500 righe di manifesti Kubernetes. Ogni componente era dichiarativo, versionato in Git, sincronizzabile da Flux. La teoria era solida. La pratica stava per insegnarmi lezioni umilianti.

### La Struttura di DEX: CRD Storage e Connettori Google

La configurazione di DEX è un file YAML puro che specifica:
- L'`issuer` (l'URL dove DEX è accessibile, es. `https://dex.tazlab.net`)
- Lo storage backend (nel mio caso, CRD di Kubernetes)
- I "connettori" (i provider di identità, nel mio caso Google OAuth)
- I "static clients" (le applicazioni autorizzate a chiedere token, nel mio caso oauth2-proxy)

Ecco un snippet semplificato di come ho strutturato il ConfigMap di DEX:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dex-config
  namespace: dex
data:
  config.yaml: |
    issuer: https://dex.tazlab.net

    storage:
      type: kubernetes
      config:
        inCluster: true

    web:
      http: 0.0.0.0:5556
      allowedOrigins:
        - https://dex.tazlab.net

    connectors:
      - type: google
        id: google
        name: Google
        config:
          clientID: $GOOGLE_CLIENT_ID
          clientSecret: $GOOGLE_CLIENT_SECRET
          redirectURI: https://dex.tazlab.net/callback

    staticClients:
      - id: oauth2-proxy
        secret: $OAUTH2_PROXY_CLIENT_SECRET
        redirectURIs:
          - https://auth.tazlab.net/oauth2/callback
        name: oauth2-proxy
```

### Perché External Secrets Operator e Non ConfigMap Diretto?

I segreti Google (`clientID`, `clientSecret`) non possono risiedere nel ConfigMap in plaintext—sarebbe una violazione basilare dei principi di sicurezza. Ho deciso di utilizzare **External Secrets Operator (ESO)** per sincronizzare i segreti da Infisical (la mia cassaforte centralizzata) e renderli disponibili come Kubernetes Secrets. Questo pattern è ormai consolidato in TazLab, quindi la scelta era naturale.

Ho creato un ExternalSecret che tirava `DEX_GOOGLE_CLIENT_ID` e `DEX_GOOGLE_CLIENT_SECRET` da Infisical:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: dex-google-secrets
  namespace: dex
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: tazlab-secrets
  target:
    name: dex-google-secrets
    creationPolicy: Owner
  data:
    - secretKey: DEX_GOOGLE_CLIENT_ID
      remoteRef:
        key: DEX_GOOGLE_CLIENT_ID
    - secretKey: DEX_GOOGLE_CLIENT_SECRET
      remoteRef:
        key: DEX_GOOGLE_CLIENT_SECRET
    - secretKey: OAUTH2_PROXY_CLIENT_SECRET
      remoteRef:
        key: OAUTH2_PROXY_CLIENT_SECRET
```

Il Deployment di DEX montava il Secret e lo iniettava come variabili di ambiente:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dex
  namespace: dex
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: dex
          image: ghcr.io/dexidp/dex:v2.41.1
          args:
            - dex
            - serve
            - /etc/dex/cfg/config.yaml
          env:
            - name: GOOGLE_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: dex-google-secrets
                  key: DEX_GOOGLE_CLIENT_ID
            - name: GOOGLE_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: dex-google-secrets
                  key: DEX_GOOGLE_CLIENT_SECRET
```

---

## Fase 3: Il Primo Errore - L'`ADMIN_EMAIL` Sparito

Dopo il primo `git push`, ho lanciato un `flux reconcile source git flux-system` e ho aspettato che Flux sincronizzasse tutto lo stato descritto nei miei manifesti.

La riconciliazione ha incontrato un errore inaspettato nella ClusterRoleBinding che doveva assegnare il ruolo `tazlab-admin` all'utente con email `${ADMIN_EMAIL}`:

```
ClusterRoleBinding/tazlab-admin-binding dry-run failed (Invalid): ClusterRoleBinding [...] subjects[0].name: Required value
```

Il campo `subjects[0].name` era vuoto. Ho controllato il manifesto:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tazlab-admin-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tazlab-admin
subjects:
  - kind: User
    name: ${ADMIN_EMAIL}
```

La variabile `${ADMIN_EMAIL}` non era stata sostituita. Ho verificato il ConfigMap `cluster-vars` nel namespace `flux-system`—quello dove Flux memorizza le variabili globali usate dai `postBuild.substituteFrom`:

```bash
$ kubectl get cm cluster-vars -n flux-system -o jsonpath='{.data}'
{"domain": "tazlab.net", "cluster_name": "tazlab-k8s", "traefik_lb_ip": "192.168.1.240"}
```

Mancava `ADMIN_EMAIL`. Qui emergeva un insight architetturale cruciale: **il ConfigMap `cluster-vars` non è gestito da GitOps, ma da Terraform**. È creato durante il bootstrap del cluster dal modulo `k8s-flux` in `ephemeral-castle`. Non potevo aggiungerlo direttamente in un file YAML di GitOps, perché Flux non lo controllava. Dovevo modificare Terraform.

Ho aperto `/workspace/ephemeral-castle/clusters/tazlab-k8s/modules/k8s-flux/main.tf` e agigiunto il parametro `admin_email`:

```hcl
variable "admin_email" {
  type        = string
  description = "Email dell'admin TazLab — usata da Flux per RBAC e oauth2-proxy allowlist"
}

# Nel blocco che crea il ConfigMap:
data = {
  domain        = var.base_domain
  cluster_name  = var.cluster_name
  traefik_lb_ip = var.traefik_lb_ip
  ADMIN_EMAIL   = var.admin_email
}
```

Poi ho aggiornato `clusters/tazlab-k8s/live/gitops/terragrunt.hcl` per leggere l'email da Infisical e passarla a Terraform:

```hcl
inputs = {
  admin_email = data.infisical_secrets.github.secrets["ADMIN_EMAIL"].value
  # ... altri parametri
}
```

Ho fatto il push di questi cambiamenti su Terraform, e poi un `kubectl patch configmap cluster-vars -n flux-system --type merge -p '{"data": {"ADMIN_EMAIL": "roberto.tazzoli@gmail.com"}}'` come patch di emergenza per accelerare il test.

**Lezione appresa**: Quando progetti un'infrastruttura con Terraform e GitOps, devi essere consapevole di quale strato "possiede" quale dato. Terraform crea il foglio bianco iniziale del cluster; GitOps mantiene lo stato dichiarativo dai manifesti. Se una configurazione è generata una volta durante il bootstrap e non cambierà spesso, appartiene a Terraform. Se cambia frequentemente e ha una storia di versioning, appartiene a GitOps. Mescolare i due livelli è il modo migliore per creare confusione operativa.

---

## Fase 4: Il Problema DEX - La Variabile che Non Viene Espansa

Dopo aver risolto l'`ADMIN_EMAIL`, tutto il resto ha iniziato a riconciliare correttamente. I pod di DEX e oauth2-proxy sono partiti. Ho testato il flusso di login navigando a `https://grafana.tazlab.net`—Traefik mi ha redirigeto a DEX, che mi ha mostrato il pulsante "Log in with Google". Ho cliccato, Google mi ha chiesto di autenticarmi...

E poi ho ricevuto un errore dal server Google:

```
Errore 400: invalid_request
flowName=GeneralOAuthFlow - Missing required parameter: client_id
```

Google non stava ricevendo il `client_id`. Ho controllato i log di DEX per capire cosa stesse accadendo:

```
[2026/02/28 08:14:23] [connector.go:123] provider.go: authenticating, error: invalid_request: Missing required parameter: client_id
```

Il problema era silenzioso nel log di DEX. Ho deciso di fare un'indagine più profonda. Ho esaminato il config file che DEX stava leggendo dentro il pod:

```bash
$ kubectl exec -it deployment/dex -n dex -- cat /etc/dex/cfg/config.yaml | grep -A 5 "connectors:"
connectors:
  - type: google
    id: google
    name: Google
    config:
      clientID: "$GOOGLE_CLIENT_ID"
```

Aha! La variabile `$GOOGLE_CLIENT_ID` era *letterale* nel file YAML. DEX non stava espandendo le variabili d'ambiente dentro il suo file di configurazione. Ho provato a leggere la documentazione di DEX per capire se supportasse la sostituzione di variabili... e ho scoperto che **DEX non fa nessuna espansione di variabili nel ifile di configurazione**. DEX è un'applicazione Go che legge il file YAML una sola volta all'avvio, lo unmarshalla in una struttura dati Go, e lo usa così. Non c'è alcun post-processing.

Questo era un problema architetturale serio. Non potevo mettere i segreti direttamente nel ConfigMap in plaintext. Ma non potevo nemmeno usare le variabili d'ambiente come placeholder nei file YAML e aspettarmi che DEX le espandesse.

Ho considerato alcune soluzioni:
1. **Sed wrapper**: Un entrypoint che usa `sed` per sostituire le variabili nel file YAML prima di lanciare DEX
2. **Il flag `secretEnv` di DEX**: DEX ha un campo speciale per il client secret che legge da una variabile d'ambiente
3. **ESO template engine**: Usare External Secrets Operator v2 per renderizzare il file di configurazione completo con i valori veri

Ho tentato inizialmente la soluzione #1 (sed wrapper). Ho creato un entrypoint shell:

```bash
#!/bin/sh
sed -e "s|\$GOOGLE_CLIENT_ID|${GOOGLE_CLIENT_ID}|g" \
    -e "s|\$GOOGLE_CLIENT_SECRET|${GOOGLE_CLIENT_SECRET}|g" \
    /etc/dex/cfg/config.yaml.template > /tmp/config.yaml
exec dex serve /tmp/config.yaml
```

Questo non ha funzionato, sed ha prodotto il file con valori vuoti (se le variabili d'ambiente non erano definite al momento dell'esecuzione), DEX crashava silenziosamente con un errore di parsing YAML.

Ho quindi provato la soluzione #2: usare il campo `secretEnv` di DEX per il client secret di oauth2-proxy. Nel file di configurazione, posso dire a DEX: "Per questo client, il secret non è nel file YAML, ma nella variabile d'ambiente". Però questo funzionava solo per il `secret` del client statico, non per il `clientSecret` del connettore Google.

Ho deciso di implementare la soluzione #3: **ESO template engine v2**. Questo è un feature di External Secrets Operator che trasforma il Secret generato tramite un motore Go template. Creo un ExternalSecret che dice a ESO:

*"Vai in Infisical, prendi DEX_GOOGLE_CLIENT_ID e DEX_GOOGLE_CLIENT_SECRET, poi renderizza il file di configurazione completo di DEX usando questi valori dentro i template `{{ .DEX_GOOGLE_CLIENT_ID }}`"*

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: dex-config-rendered
  namespace: dex
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: tazlab-secrets
  target:
    name: dex-rendered-config
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        config.yaml: |
          issuer: https://dex.tazlab.net

          storage:
            type: kubernetes
            config:
              inCluster: true

          connectors:
            - type: google
              id: google
              name: Google
              config:
                clientID: "{{ .DEX_GOOGLE_CLIENT_ID }}"
                clientSecret: "{{ .DEX_GOOGLE_CLIENT_SECRET }}"
                redirectURI: https://dex.tazlab.net/callback

          staticClients:
            - id: oauth2-proxy
              secretEnv: OAUTH2_PROXY_CLIENT_SECRET
              redirectURIs:
                - https://auth.tazlab.net/oauth2/callback
              name: oauth2-proxy
  data:
    - secretKey: DEX_GOOGLE_CLIENT_ID
      remoteRef:
        key: DEX_GOOGLE_CLIENT_ID
    - secretKey: DEX_GOOGLE_CLIENT_SECRET
      remoteRef:
        key: DEX_GOOGLE_CLIENT_SECRET
```

Quando ESO ricrea questo ExternalSecret, passa i segreti dal block `data` al template engine, che sostituisce `{{ .DEX_GOOGLE_CLIENT_ID }}` con il valore vero, e genera un Secret con il file di configurazione completamente renderizzato, con i valori veri già dentro.

Ho aggiornato il Deployment di DEX per montare il Secret `dex-rendered-config` anziché il ConfigMap:

```yaml
spec:
  volumes:
    - name: config
      secret:
        secretName: dex-rendered-config
        items:
          - key: config.yaml
            path: config.yaml
```

Dopo il deploy, ho verificato che il Secret contenesse i valori veri:

```bash
$ kubectl get secret dex-rendered-config -n dex -o jsonpath='{.data.config\.yaml}' | base64 -d | grep clientID
      clientID: "502646366772-9165kme6a67a10m1s8imiv540ltoisp7.apps.googleusercontent.com"
```

Perfetto. DEX stava leggendo il file di configurazione con i valori veri.

---

## Fase 5: Il Redirect Che Non Funzionava

Dopo che DEX iniziò a lavorare correttamente con Google, il flusso di autenticazione proseguì. L'utente (me stesso) veniva redirigeto a Google, si autenticava, e poi...

Finiva su `https://auth.tazlab.net/authenticated` con un semplice messaggio: "Authenticated". Non veniva redirigeto a Grafana. Dovevo rimettere manualmente `https://grafana.tazlab.net` nella barra degli indirizzi.

Il problema era in oauth2-proxy. Quando riceveva il callback da Google, sapeva che l'utente era autenticato, ma non sapeva a quale URL ritornare. oauth2-proxy è uno strumento complesso con molte configurazioni, e il bug risiede nel modo in cui gestisce il **tracking dell'URL di origine dopo il redirect**.

Quando Traefik chiama oauth2-proxy come middleware ForwardAuth, potrebbe non passare l'URL originale al servizio di autenticazione. Quindi oauth2-proxy non sa da dove è venuto il client. Aggiunsi il parametro `--reverse-proxy=true`:

```yaml
args:
  - --provider=oidc
  - --oidc-issuer-url=https://dex.tazlab.net
  - --client-id=oauth2-proxy
  - --client-secret=$(OAUTH2_PROXY_CLIENT_SECRET)
  - --cookie-secret=$(OAUTH2_PROXY_COOKIE_SECRET)
  - --cookie-secure=true
  - --cookie-domain=.tazlab.net
  - --redirect-url=https://auth.tazlab.net/oauth2/callback
  - --upstream=static://200
  - --http-address=:4180
  - --reverse-proxy=true  # <-- Nuovo
  - --set-xauthrequest=true
  - --authenticated-emails-file=/etc/oauth2-proxy/allowed-emails.txt
```

**Deep-Dive Concettuale: Il Flag `--reverse-proxy` in oauth2-proxy**

Quando oauth2-proxy è esposto direttamente al client (come in una configurazione reverse proxy tradizionale), riceve gli header HTTP standard: `Host`, `User-Agent`, ecc. Ma quando è dietro un reverse proxy come Traefik, il proxy intermedio aggiunge header "forwarded": `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-Uri`. Questi header indicano al proxy downstream quale era la richiesta originale. Il flag `--reverse-proxy=true` dice a oauth2-proxy: "Leggi questi header per ricostruire l'URL originale del client". Così, dopo il callback di Google, oauth2-proxy sa di ritornare non a se stesso (`auth.tazlab.net`), ma all'URL originale (`grafana.tazlab.net`).

Purtroppo, questo non ha risolto completamente il problema. Ho realizzato che c'era un'ulteriore complessità: l'integrazione fra DEX, oauth2-proxy e Grafana stessa.

---

## Fase 6: Configurare Grafana per Riconoscere l'Utente Autenticato

Anche dopo che oauth2-proxy ridirigeva correttamente il client a Grafana, Grafana chiedeva comunque le credenziali. La ragione è che Grafana non stava leggendo l'header `X-Auth-Request-User` che oauth2-proxy passava via Traefik Middleware.

Grafana ha una sezione di configurazione dedicata ai "proxy auth": quando abilitata, Grafana fiduciosamente legge un header HTTP (di default `X-WEBAUTH-USER`) e assume che l'utente fornito dall'header sia già autenticato. Questa è una feature di sicurezza comune negli ambienti aziendali dove c'è un SSO centralizzato.

Nel mio caso, dovevo dire a Grafana di abilitare questo modulo e di leggere da `X-Auth-Request-User` (l'header che oauth2-proxy genera). Ho modificato il HelmRelease di `kube-prometheus-stack`:

```yaml
grafana:
  enabled: true
  grafana.ini:
    auth.proxy:
      enabled: true
      header_name: X-Auth-Request-User
      header_property: username
      auto_sign_up: true
      sync_ttl: 60
```

Con questa configurazione:
- **`enabled: true`**: Attiva il modulo
- **`header_name: X-Auth-Request-User`**: Leggi da questo header
- **`header_property: username`**: Il valore nell'header è il campo `username` (email, in questo caso)
- **`auto_sign_up: true`**: Se l'utente non esiste in Grafana, crealo automaticamente sulla prima login
- **`sync_ttl: 60`**: Ogni 60 secondi, sincronizza i dati dell'utente da Infisical (se integrato)

Dopo questo cambio, Grafana ha riconosciuto automaticamente l'utente `roberto.tazzoli@gmail.com` e lo ha loggato senza chiedere password.

---

## Fase 7: Il Crash di oauth2-proxy - L'Errore Silenzioso

Proprio quando credevo che tutto fosse stabile, ho aggiunto due parametri a oauth2-proxy che avevano il potenziale di migliorare il comportamento:

```yaml
args:
  # ... parametri precedenti ...
  - --url=https://auth.tazlab.net
  - --auth-logging=true
```

Dopo il push, i pod di oauth2-proxy entrarono in **CrashLoopBackOff**. I log del container mostravano:

```
unknown flag: --url
```

Avevo usato un flag che non esisteva nella versione v7.8.1 di oauth2-proxy che stavo usando. Ho controllato la documentazione e la lista dei flag supportati... e il flag non c'era. Era possibile che fosse stato aggiunto in una versione più recente, ma la mia immagine era precedente.

Quello che seguì fu una sequenza di problemi a cascata: Kubernetes continuava a cercare di far partire il pod con la vecchia configurazione cacheata. Flux è rimasto bloccato in uno stato di "Reconciliation in progress" per cinque minuti (il timeout dei health check). I pod in CrashLoopBackOff si riavviavano ogni 10 secondi, creando rumore nei log.

Ho riversionato i commit che avevano aggiunto quei flag e ho patchato manualmente il deployment nel cluster per rimuovere i parametri problematici:

```bash
kubectl patch deployment oauth2-proxy -n auth --type json -p '[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/args",
    "value": [
      "--provider=oidc",
      "--oidc-issuer-url=https://dex.tazlab.net",
      "--client-id=oauth2-proxy",
      "--client-secret=$(OAUTH2_PROXY_CLIENT_SECRET)",
      "--cookie-secret=$(OAUTH2_PROXY_COOKIE_SECRET)",
      "--cookie-secure=true",
      "--cookie-domain=.tazlab.net",
      "--whitelist-domain=.tazlab.net",
      "--redirect-url=https://auth.tazlab.net/oauth2/callback",
      "--upstream=static://200",
      "--http-address=:4180",
      "--skip-provider-button=true",
      "--set-xauthrequest=true",
      "--reverse-proxy=true",
      "--authenticated-emails-file=/etc/oauth2-proxy/allowed-emails.txt",
      "--silence-ping-logging=true"
    ]
  }
]'
```

Dopo alcuni minuti, un nuovo pod è partito con la configurazione corretta e il sistema si è stabilizzato.

**Lezione critica**: Quando scrivi parametri di configurazione per applicazioni che ottengono da immagini pubbliche, **verifica sempre la documentazione della versione specifica che stai usando**. Un flag potrebbe non esistere nella versione che stai usando, causando crash silenziosi. La soluzione è usare version pinning rigoroso e documentare quale versione supporta quali feature.

---

## Fase 8: Flux Rimane Bloccato - Il Timeout dei Health Check

Quando il pod di oauth2-proxy crashava continuamente, Flux rimase bloccato in uno stato patologico. La kustomization `infrastructure-auth` non riusciva a completare la riconciliazione perché il health check attendeva che i pod diventassero ready. Ma i pod non diventavano mai ready a causa del crash.

Flux ha un timeout di health check di 5 minuti. Dopo 5 minuti, marca la riconciliazione come fallita, ma rimane in uno stato di "Reconciliation in progress" aspettando il prossimo tentativo automatico (che è programmato per un'ora dopo, a meno che non lo forzi manualmente).

Ho dovuto forare il processo:
1. Ho revertito il commit che conteneva i flag problematici
2. Ho forzato Flux a riconoscere il nuovo commit: `flux reconcile source git flux-system`
3. Ho cancellato forzatamente tutti i pod vecchi: `kubectl delete pods -n auth --all --grace-period=0 --force`
4. Ho patchato il deployment manualmente per far partire il pod con la configurazione corretta
5. Ho aspettato che il pod stabilizzasse
6. Flux ha riconosciuto infine che tutto era in ordine e ha completato la riconciliazione

---

## Riflessioni Finali: Cosa Abbiamo Costruito

Dopo questa "tappa del viaggio", TazLab ha ora un sistema di autenticazione enterprise-ready che combina:

- **DEX** come provider OIDC Kubernetes-native, con CRD storage e integrazione Google OAuth
- **oauth2-proxy** come middleware Traefik, con ForwardAuth pattern per intercettazione trasparente
- **External Secrets Operator** con template engine per renderizzare la configurazione di DEX con i segreti veri da Infisical
- **Kubernetes RBAC** con ClusterRole e ClusterRoleBinding che legge l'email dell'admin da Flux
- **Grafana** configurato per auth.proxy, riconoscendo automaticamente gli utenti via header X-Auth-Request-User

Il flusso completo funziona così:
1. Utente navigua a `https://grafana.tazlab.net`
2. Traefik ForwardAuth chiama oauth2-proxy
3. oauth2-proxy vede che non c'è un cookie di sessione valido
4. oauth2-proxy ridirige il client a `https://dex.tazlab.net/auth`
5. DEX mostra il pulsante "Login with Google"
6. Utente si autentica con Google
7. Google redirige indietro a `https://auth.tazlab.net/oauth2/callback`
8. oauth2-proxy elabora il callback, genera un cookie di sessione
9. oauth2-proxy ridirige il client a `https://grafana.tazlab.net` (l'URL originale ricostruito dai header X-Forwarded-*)
10. Traefik ForwardAuth chiama di nuovo oauth2-proxy, che rispondecon 200 e header `X-Auth-Request-User: roberto.tazzoli@gmail.com`
11. Traefik passa la richiesta a Grafana, aggiungendo l'header
12. Grafana legge l'header, crea automaticamente una sessione per quell'utente
13. Grafana risponde con la dashboard

L'intero sistema è dichiarativo, versionato in Git, recuperabile da backup di etcd, integrabile con Flux per la disaster recovery. Non c'è "stato esterno" che vive fuori Kubernetes. È la realizzazione concreta del principio Zero Trust che guida Ephemeral Castle.

I problemi incontrati—la variabile non espansa, il flag inesistente, il timeout di Flux—sono stati tutti risolti grazie a un approccio sistematico di debugging: identificare il sintomo, costruire ipotesi, testare, iterare. E soprattutto, documentare il processo in modo che chi legga questo diario possa imparare dalle mie esperienze senza ripetere gli stessi errori.

Questo laboratorio è ora pronto per il prossimo capitolo della sua evoluzione: l'integrazione di nuovi provider di identità, l'implementazione di RBAC granulare, la sincronizzazione di attributi utente da directory aziendali. Ma per adesso, il sistema di autenticazione è stabile, sicuro, e pronto per la produzione.

