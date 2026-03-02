+++
title = "From Zero to OIDC: A Journey Through Zero Trust Authentication in Our Kubernetes Cluster"
date = 2026-02-28T15:00:00+01:00
draft = false
description = "Technical chronicle of implementing DEX + oauth2-proxy in the TazLab Kubernetes cluster: architectural choices, errors, debugging, and the solutions adopted to authenticate dashboards through Google OAuth."
tags = ["kubernetes", "dex", "oauth2", "oidc", "traefik", "zero-trust", "gitops", "flux", "external-secrets"]
author = "Tazzo"
+++

## Introduction: The Dashboard Protection Problem

When building a modern Kubernetes infrastructure, one of the most critical challenges that emerges quickly is managing access to operational dashboards. In my TazLab laboratory—a Talos Linux cluster on Proxmox with a complete GitOps stack—I had already implemented Grafana for monitoring, pgAdmin for database management, and an informational dashboard (Homepage) for navigation. All these components were accessible via Traefik Ingress, but none of them were protected by authentication. Anyone who could reach `https://grafana.tazlab.net` from my lab could access sensitive monitoring data without entering credentials.

I decided that this situation violated the fundamental **Zero Trust** principle that guides the entire Ephemeral Castle architecture. The objective of the day was therefore ambitious: implement a Single Sign-On (SSO) system using Google OAuth, where all dashboards would be protected behind a single authentication gateway. Users would need to log in once with their Google account, and then all subsequent accesses to various services would be automatically authorized, without further password prompts.

This "stage of the journey" of TazLab represented a significant turning point: the infrastructure was evolving from simply "functional" to "enterprise-ready", where security was not an afterthought but a founding principle.

---

## Phase 1: OIDC Architecture and Strategic Choices

Before writing the first YAML manifest, I had to make a series of architectural decisions that would define the entire approach. There was no single correct path; each choice involved trade-offs that would affect the long-term stability of the system.

### Why DEX and Not Keycloak? A Conscious Comparison

The most critical choice was the OIDC provider. The standards in the Kubernetes landscape are two: **Keycloak** and **DEX**. Keycloak is a complete ecosystem, extremely flexible, supported by a gigantic community, with a rich administration interface and dozens of connectors. DEX, on the other hand, is a minimalist tool: a Kubernetes-native OIDC provider that reads its configuration from YAML files, persists data via Kubernetes CRD (Custom Resource Definition), and has no web administration interface (everything is declarative).

I chose DEX for one fundamental reason: philosophical alignment with my infrastructure. TazLab is built entirely around Kubernetes as the source of truth database. Flux CD manages declarative state through version control (Git). All secrets reside in Infisical and are synchronized via External Secrets Operator. Adding Keycloak meant introducing a new "fiefdom" of data—a separate database with its own lifecycle, backups, and dependencies—that would live outside the declarative paradigm. DEX, by contrast, leverages Kubernetes CRDs for persistence: every token, every authentication session, is a native Kubernetes object stored in etcd. This means that automatic etcd backups also protect the authentication system. It means that disaster recovery is consistent with the rest of the infrastructure.

The downside of DEX is the lack of a rich web interface. If I need to modify the provider's behavior (add a new connector, change configuration), I must edit YAML files and commit them to Git, not click in a UI. Initially, this limitation seemed restrictive. But after implementing the system, I realized it was a strength: traceability. Every change to DEX is a Git commit with an author, timestamp, and documented reason in a PR. There is no "administrator who clicked the wrong button".

### oauth2-proxy as a Traefik Middleware: The ForwardAuth Pattern

Once I chose DEX as the OIDC provider, I needed a proxy to intercept HTTP requests to my dashboards, verify whether the user was already authenticated with Google, and if not, redirect them to the authentication flow. The standard solution in the Kubernetes world is **oauth2-proxy**.

oauth2-proxy is a reverse proxy specialized in OAuth2 integration. It is typically deployed as a pod in Kubernetes and configured as a **Traefik Middleware** in the `ForwardAuth` pattern. In this architectural pattern, when a request arrives at a protected Traefik Ingress, Traefik does not pass the request directly to the backend application. Instead, it sends a verification request to the oauth2-proxy service, asking: "Is this client authenticated?" If oauth2-proxy responds with HTTP 200, it means "yes, it's valid", and Traefik proceeds. If it responds with 401, Traefik blocks the request and redirects the client to the login service.

**Deep-Dive Conceptual: Traefik's ForwardAuth Pattern**

The ForwardAuth pattern is an implementation of the "external authorization service" paradigm commonly used in nginx (via `auth_request`). The idea is elegant from an architectural standpoint: the authentication decision is delegated to a specialized service, which remains completely decoupled from the actual application. This means I can protect *any* application—Grafana, pgAdmin, a simple HTML page—without modifying its code. The application doesn't even need to "know" there's a proxy in front. From its perspective, HTTP requests arrive as always. The difference is that Traefik has already verified authentication via the ForwardAuth Middleware, and passes the app some additional headers (like `X-Auth-Request-User`) that the app can use to automatically recognize the logged-in user.

This pattern is particularly powerful when combined with Traefik's ability to pass HTTP headers to the verification service and collect response headers. In the case of oauth2-proxy, the flow becomes:
1. Client requests `/dashboard` on Grafana
2. Traefik intercepts the request and sends it to oauth2-proxy for verification
3. oauth2-proxy checks whether the client has a valid session cookie
4. If yes, it responds 200 and includes in the response headers the username (e.g., `X-Auth-Request-User: roberto.tazzoli@gmail.com`)
5. Traefik passes the request to Grafana, adding those headers
6. Grafana reads the header and automatically creates a session for that user

---

## Phase 2: Initial Implementation (Confidence in Plans)

With the architectural decisions made, I proceeded with implementation. I decided to structure the project following conventions already present in TazLab:

- **`infrastructure/configs/dex/`**: ExternalSecrets that pull Google secrets from Infisical, and DEX configuration files
- **`infrastructure/instances/dex/`**: Deployment, Service, Ingress, RBAC for DEX
- **`infrastructure/auth/`**: A new layer dedicated to oauth2-proxy, Traefik middleware, and Flux configuration
- **`infrastructure/operators/monitoring/`**: Updates to Grafana ingresses to apply the ForwardAuth middleware

I created 19 YAML files in total, approximately 1500 lines of Kubernetes manifests. Each component was declarative, versioned in Git, and synchronizable by Flux. The theory was solid. Practice was about to teach me humbling lessons.

### DEX Structure: CRD Storage and Google Connectors

The DEX configuration is a pure YAML file that specifies:
- The `issuer` (the URL where DEX is accessible, e.g., `https://dex.tazlab.net`)
- The storage backend (in my case, Kubernetes CRD)
- The "connectors" (identity providers, in my case Google OAuth)
- The "static clients" (applications authorized to request tokens, in my case oauth2-proxy)

Here's a simplified snippet of how I structured the DEX ConfigMap:

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

### Why External Secrets Operator and Not Direct ConfigMap?

Google secrets (`clientID`, `clientSecret`) cannot reside in the ConfigMap in plaintext—it would be a basic violation of security principles. I decided to use **External Secrets Operator (ESO)** to synchronize secrets from Infisical (my centralized vault) and make them available as Kubernetes Secrets. This pattern is now well-established in TazLab, so the choice was natural.

I created an ExternalSecret that pulled `DEX_GOOGLE_CLIENT_ID` and `DEX_GOOGLE_CLIENT_SECRET` from Infisical:

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

The DEX Deployment mounted the Secret and injected it as environment variables:

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

## Phase 3: The First Error - The Missing `ADMIN_EMAIL`

After the first `git push`, I ran a `flux reconcile source git flux-system` and waited for Flux to synchronize all the state described in my manifests.

Reconciliation encountered an unexpected error in the ClusterRoleBinding that should have assigned the `tazlab-admin` role to the user with email `${ADMIN_EMAIL}`:

```
ClusterRoleBinding/tazlab-admin-binding dry-run failed (Invalid): ClusterRoleBinding [...] subjects[0].name: Required value
```

The `subjects[0].name` field was empty. I checked the manifest:

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

The `${ADMIN_EMAIL}` variable had not been substituted. I checked the `cluster-vars` ConfigMap in the `flux-system` namespace—where Flux stores global variables used by `postBuild.substituteFrom`:

```bash
$ kubectl get cm cluster-vars -n flux-system -o jsonpath='{.data}'
{"domain": "tazlab.net", "cluster_name": "tazlab-k8s", "traefik_lb_ip": "192.168.1.240"}
```

`ADMIN_EMAIL` was missing. Here emerged a crucial architectural insight: **the `cluster-vars` ConfigMap is not managed by GitOps, but by Terraform**. It is created during cluster bootstrap by the `k8s-flux` module in `ephemeral-castle`. I couldn't add it directly to a GitOps YAML file, because Flux did not control it. I had to modify Terraform.

I opened `/workspace/ephemeral-castle/clusters/tazlab-k8s/modules/k8s-flux/main.tf` and added the `admin_email` parameter:

```hcl
variable "admin_email" {
  type        = string
  description = "Email of TazLab admin — used by Flux for RBAC and oauth2-proxy allowlist"
}

# In the block that creates the ConfigMap:
data = {
  domain        = var.base_domain
  cluster_name  = var.cluster_name
  traefik_lb_ip = var.traefik_lb_ip
  ADMIN_EMAIL   = var.admin_email
}
```

Then I updated `clusters/tazlab-k8s/live/gitops/terragrunt.hcl` to read the email from Infisical and pass it to Terraform:

```hcl
inputs = {
  admin_email = data.infisical_secrets.github.secrets["ADMIN_EMAIL"].value
  # ... other parameters
}
```

I pushed these Terraform changes, and then ran a `kubectl patch configmap cluster-vars -n flux-system --type merge -p '{"data": {"ADMIN_EMAIL": "roberto.tazzoli@gmail.com"}}'` as an emergency patch to accelerate testing.

**Lesson learned**: When designing infrastructure with Terraform and GitOps, you must be aware of which layer "owns" which data. Terraform creates the initial blank slate of the cluster; GitOps maintains declarative state from manifests. If a configuration is generated once during bootstrap and won't change often, it belongs to Terraform. If it changes frequently and has a versioning history, it belongs to GitOps. Mixing the two levels is the fastest way to create operational confusion.

---

## Phase 4: The DEX Problem - The Variable That Doesn't Expand

After resolving the `ADMIN_EMAIL`, everything else started reconciling correctly. The DEX and oauth2-proxy pods started. I tested the login flow by navigating to `https://grafana.tazlab.net`—Traefik redirected me to DEX, which showed me the "Log in with Google" button. I clicked, Google asked me to authenticate...

And then I received an error from the Google server:

```
Error 400: invalid_request
flowName=GeneralOAuthFlow - Missing required parameter: client_id
```

Google was not receiving the `client_id`. I checked the DEX logs to understand what was happening:

```
[2026/02/28 08:14:23] [connector.go:123] provider.go: authenticating, error: invalid_request: Missing required parameter: client_id
```

The problem was silent in DEX's log. I decided to conduct a deeper investigation. I examined the config file that DEX was reading inside the pod:

```bash
$ kubectl exec -it deployment/dex -n dex -- cat /etc/dex/cfg/config.yaml | grep -A 5 "connectors:"
connectors:
  - type: google
    id: google
    name: Google
    config:
      clientID: "$GOOGLE_CLIENT_ID"
```

Aha! The `$GOOGLE_CLIENT_ID` variable was *literal* in the YAML file. DEX was not expanding environment variables inside its configuration file. I tried reading the DEX documentation to see if it supported variable substitution... and discovered that **DEX does not perform any variable expansion in the configuration file**. DEX is a Go application that reads the YAML file once at startup, unmarshals it into a Go data structure, and uses it as-is. There is no post-processing.

This was a serious architectural problem. I couldn't put secrets directly in the ConfigMap in plaintext. But I also couldn't use environment variables as placeholders in YAML files and expect DEX to expand them.

I considered several solutions:
1. **Sed wrapper**: An entrypoint that uses `sed` to substitute variables in the YAML file before launching DEX
2. **The `secretEnv` flag in DEX**: DEX has a special field for client secret that reads from an environment variable
3. **ESO template engine**: Use External Secrets Operator v2 to render the complete configuration file with real values

I initially attempted solution #1 (sed wrapper). I created a shell entrypoint:

```bash
#!/bin/sh
sed -e "s|\$GOOGLE_CLIENT_ID|${GOOGLE_CLIENT_ID}|g" \
    -e "s|\$GOOGLE_CLIENT_SECRET|${GOOGLE_CLIENT_SECRET}|g" \
    /etc/dex/cfg/config.yaml.template > /tmp/config.yaml
exec dex serve /tmp/config.yaml
```

This didn't work. When sed produced the file with empty values (if the environment variables were not defined at execution time), DEX would silently crash with a YAML parsing error.

I then tried solution #2: using the `secretEnv` field in DEX for the oauth2-proxy client secret. In the configuration file, I can tell DEX: "For this client, the secret is not in the YAML file, but in an environment variable". But this only worked for the `secret` of the static client, not for the `clientSecret` of the Google connector.

I decided to implement solution #3: **ESO template engine v2**. This is a feature of External Secrets Operator that transforms the generated Secret using a Go template engine. I create an ExternalSecret that tells ESO:

*"Go to Infisical, fetch DEX_GOOGLE_CLIENT_ID and DEX_GOOGLE_CLIENT_SECRET, then render DEX's complete configuration file using these values inside the templates `{{ .DEX_GOOGLE_CLIENT_ID }}`"*

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

When ESO recreates this ExternalSecret, it passes the secrets from the `data` block to the template engine, which substitutes `{{ .DEX_GOOGLE_CLIENT_ID }}` with the real value, and generates a Secret with the completely rendered DEX configuration file, with real values already inside.

I updated the DEX Deployment to mount the `dex-rendered-config` Secret instead of the ConfigMap:

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

After deploy, I verified that the Secret contained the real values:

```bash
$ kubectl get secret dex-rendered-config -n dex -o jsonpath='{.data.config\.yaml}' | base64 -d | grep clientID
      clientID: "502646366772-9165kme6a67a10m1s8imiv540ltoisp7.apps.googleusercontent.com"
```

Perfect. DEX was now reading the configuration file with real values.

---

## Phase 5: The Redirect That Didn't Work

After DEX started working correctly with Google, the authentication flow continued. The user (myself) was redirected to Google, authenticated, and then...

Ended up on `https://auth.tazlab.net/authenticated` with a simple message: "Authenticated". It didn't redirect back to Grafana. I had to manually re-enter `https://grafana.tazlab.net` in the address bar.

The problem was in oauth2-proxy. When it received the callback from Google, it knew the user was authenticated, but it didn't know which URL to return to. oauth2-proxy is a complex tool with many configurations, and the bug resided in how it handles **tracking the original URL after redirect**.

When Traefik calls oauth2-proxy as ForwardAuth middleware, it might not pass the original URL to the authentication service. So oauth2-proxy doesn't know where the client came from. I added the `--reverse-proxy=true` parameter:

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
  - --reverse-proxy=true  # <-- New
  - --set-xauthrequest=true
  - --authenticated-emails-file=/etc/oauth2-proxy/allowed-emails.txt
```

**Deep-Dive Conceptual: The `--reverse-proxy` Flag in oauth2-proxy**

When oauth2-proxy is exposed directly to the client (as in a traditional reverse proxy configuration), it receives standard HTTP headers: `Host`, `User-Agent`, etc. But when behind a reverse proxy like Traefik, the intermediate proxy adds "forwarded" headers: `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-Uri`. These headers tell the downstream proxy what the original request was. The `--reverse-proxy=true` flag tells oauth2-proxy: "Read these headers to reconstruct the client's original URL". That way, after Google's callback, oauth2-proxy knows to return not to itself (`auth.tazlab.net`), but to the original URL (`grafana.tazlab.net`).

Unfortunately, this didn't completely solve the problem. I realized there was further complexity: the integration between DEX, oauth2-proxy, and Grafana itself.

---

## Phase 6: Configure Grafana to Recognize the Authenticated User

Even after oauth2-proxy correctly redirected the client back to Grafana, Grafana still asked for credentials. The reason is that Grafana was not reading the `X-Auth-Request-User` header that oauth2-proxy was passing via Traefik Middleware.

Grafana has a dedicated configuration section for "proxy auth": when enabled, Grafana trusts an HTTP header (by default `X-WEBAUTH-USER`) and assumes that the user provided in the header is already authenticated. This is a common security feature in enterprise environments where there's centralized SSO.

In my case, I had to tell Grafana to enable this module and read from `X-Auth-Request-User` (the header that oauth2-proxy generates). I modified the HelmRelease of `kube-prometheus-stack`:

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

With this configuration:
- **`enabled: true`**: Activates the module
- **`header_name: X-Auth-Request-User`**: Read from this header
- **`header_property: username`**: The value in the header is the `username` field (email, in this case)
- **`auto_sign_up: true`**: If the user doesn't exist in Grafana, create them automatically on first login
- **`sync_ttl: 60`**: Every 60 seconds, synchronize user data from Infisical (if integrated)

After this change, Grafana automatically recognized the user `roberto.tazzoli@gmail.com` and logged them in without asking for a password.

---

## Phase 7: The oauth2-proxy Crash - The Silent Error

Just when I thought everything was stable, I added two parameters to oauth2-proxy that had the potential to improve behavior:

```yaml
args:
  # ... previous parameters ...
  - --url=https://auth.tazlab.net
  - --auth-logging=true
```

After the push, the oauth2-proxy pods entered **CrashLoopBackOff**. The container logs showed:

```
unknown flag: --url
```

I had used a flag that didn't exist in the v7.8.1 version of oauth2-proxy I was using. I checked the documentation and the list of supported flags... and the flag wasn't there. It was possible it had been added in a newer version, but my image was older.

What followed was a cascade of problems: Kubernetes kept trying to start the pod with the old cached configuration. Flux remained stuck in a "Reconciliation in progress" state for five minutes (the health check timeout). The CrashLoopBackOff pods restarted every 10 seconds, creating noise in the logs.

I reverted the commits that had added those flags and manually patched the deployment in the cluster to remove the problematic parameters:

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

After a few minutes, a new pod started with the correct configuration and the system stabilized.

**Critical lesson**: When writing configuration parameters for applications obtained from public images, **always verify the documentation of the specific version you're using**. A flag might not exist in the version you pulled, causing silent crashes. The solution is to use strict version pinning and document which version supports which features.

---

## Phase 8: Flux Gets Stuck - The Health Check Timeout

When the oauth2-proxy pod continuously crashed, Flux became stuck in a pathological state. The `infrastructure-auth` kustomization couldn't complete reconciliation because the health check was waiting for pods to become ready. But the pods never became ready due to the crash.

Flux has a health check timeout of 5 minutes. After 5 minutes, it marks reconciliation as failed, but remains in a "Reconciliation in progress" state waiting for the next automatic attempt (which is scheduled an hour later, unless I force it manually).

I had to break through the process:
1. I reverted the commit that contained the problematic flags
2. I forced Flux to recognize the new commit: `flux reconcile source git flux-system`
3. I forcefully deleted all old pods: `kubectl delete pods -n auth --all --grace-period=0 --force`
4. I manually patched the deployment to start the pod with the correct configuration
5. I waited for the pod to stabilize
6. Flux finally recognized that everything was in order and completed reconciliation

---

## Final Reflections: What We Built

After this "stage of the journey", TazLab now has an enterprise-ready authentication system that combines:

- **DEX** as a Kubernetes-native OIDC provider, with CRD storage and Google OAuth integration
- **oauth2-proxy** as a Traefik middleware, with ForwardAuth pattern for transparent interception
- **External Secrets Operator** with template engine to render DEX configuration with real secrets from Infisical
- **Kubernetes RBAC** with ClusterRole and ClusterRoleBinding that reads the admin email from Flux
- **Grafana** configured for auth.proxy, automatically recognizing users via X-Auth-Request-User header

The complete flow works like this:
1. User navigates to `https://grafana.tazlab.net`
2. Traefik ForwardAuth calls oauth2-proxy
3. oauth2-proxy sees there's no valid session cookie
4. oauth2-proxy redirects the client to `https://dex.tazlab.net/auth`
5. DEX shows the "Login with Google" button
6. User authenticates with Google
7. Google redirects back to `https://auth.tazlab.net/oauth2/callback`
8. oauth2-proxy processes the callback, generates a session cookie
9. oauth2-proxy redirects the client to `https://grafana.tazlab.net` (the original URL reconstructed from X-Forwarded-* headers)
10. Traefik ForwardAuth calls oauth2-proxy again, which responds with 200 and header `X-Auth-Request-User: roberto.tazzoli@gmail.com`
11. Traefik passes the request to Grafana, adding the header
12. Grafana reads the header, automatically creates a session for that user
13. Grafana responds with the dashboard

The entire system is declarative, versioned in Git, recoverable from etcd backups, and integrated with Flux for disaster recovery. There is no "external state" living outside Kubernetes. It is the concrete realization of the Zero Trust principle that guides Ephemeral Castle.

The problems encountered—the unexpanded variable, the nonexistent flag, the Flux timeout—were all resolved through a systematic debugging approach: identify the symptom, construct hypotheses, test, iterate. And most importantly, document the process so that anyone reading this chronicle can learn from my experiences without repeating the same mistakes.

This laboratory is now ready for the next chapter of its evolution: integration of new identity providers, implementation of granular RBAC, synchronization of user attributes from enterprise directories. But for now, the authentication system is stable, secure, and production-ready.
