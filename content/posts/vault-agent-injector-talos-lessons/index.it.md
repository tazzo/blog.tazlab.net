+++
title = "Vault Agent Injector su Talos: cosa ho imparato"
date = 2026-05-29T16:00:00+02:00
draft = false
description = "Deployare Vault Agent Injector su un cluster Talos K8s con Vault esterno su Hetzner sembrava l'ultimo miglio di un percorso già tracciato. In realtà è stato dove ho incontrato gli errori più istruttivi: un bug dell'injector, un default di Tailscale su Linux, una race condition DNS in Podman, e un sidecar che non voleva saperne di funzionare."
tags = ["vault", "vault-agent-injector", "jwt", "kubernetes", "talos", "tailscale", "podman", "crisp", "secret-management", "grafana"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# Vault Agent Injector su Talos: cosa ho imparato

Se hai seguito la storia del cluster TazLab finora, sai che il percorso verso i segreti dinamici è stato un'avanzata lenta ma metodica. Prima la migrazione dei segreti statici da Infisical a Vault. Poi l'esposizione dei servizi sulla tailnet con Tailscale Operator. Poi i primi passi verso i segreti dinamici: JWT auth, database engine, e un incidente PKI che ha distrutto il cluster.

L'ultimo miglio era il Vault Agent Injector: il componente che permette ai pod di ricevere credenziali direttamente da Vault senza passare da Kubernetes Secret. Deployare l'injector, configurare l'autenticazione JWT, e migrare Grafana da un ExternalSecret statico a credenziali PostgreSQL dinamiche.

Sembrava lineare. Non lo è stato.

## Il bug più subdolo: Tailscale su Linux non accetta rotte

Il primo problema l'ho incontrato prima ancora di toccare l'injector. Vault, che gira su una VM Hetzner in un container Podman, doveva poter raggiungere l'endpoint JWKS del cluster Kubernetes per validare i JWT dei pod. Avevo esposto l'API server sulla tailnet con un Service di tipo LoadBalancer. Il VIP era `100.110.87.98`. Da Vault, irraggiungibile.

`tailscale ping 100.110.87.98` rispondeva: `no matching peer`.

Ho controllato le ACL: regola `tag:tazlab-vault → tag:k8s:6443` presente. Ho controllato i proxy pod: Running. Ho controllato il device Tailscale: registrato. Tutto apparentemente corretto, ma niente funzionava.

La causa era un default di Tailscale su Linux che non conoscevo. Su Windows, macOS, e Android, Tailscale accetta automaticamente le rotte annunciate da altri nodi. Su Linux, no. Il flag `--accept-routes` è `false` per default, e i VIP Anycast dei Tailscale Services — la tecnologia alla base dei LoadBalancer e dei ProxyGroup — non sono instradabili senza di esso.

La soluzione è stata un semplice comando sulla VM Hetzner:

```bash
sudo tailscale set --accept-routes=true --accept-dns=true
```

Un flag. Ore di debug. La lezione è chiara: se usate Tailscale su Linux e i VIP dei servizi non sono raggiungibili, controllate `--accept-routes`. È il primo posto dove guardare.

## ProxyGroup kube-apiserver: meglio della soluzione precedente

Il Service LoadBalancer che avevo creato per esporre l'API server è stato sostituito da un ProxyGroup di tipo `kube-apiserver`. È il pattern ufficiale Tailscale per esporre il control plane, e supporta HA nativa con TLS via Let's Encrypt.

```yaml
apiVersion: tailscale.com/v1alpha1
kind: ProxyGroup
metadata:
  name: lushycorp-apiserver-proxy
  namespace: tailscale
spec:
  type: kube-apiserver
  replicas: 2
  tags: ["tag:k8s"]
  kubeAPIServer:
    mode: noauth
```

Il ProxyGroup ha risolto anche un problema di tag: il vecchio LoadBalancer usava `tag:k8s`, ma la regola ACL puntava a `tag:k8s:6443` che non funzionava con il nuovo meccanismo di grants richiesto da Tailscale Services. Con il ProxyGroup, ho allineato tutto: grants `tag:tazlab-vault → tag:k8s:443` e autoApprovers per i servizi.

## vault-k8s bug #660: quando l'injector genera la configurazione sbagliata

Con il cluster pronto e il JWKS endpoint raggiungibile, ho deployato il Vault Agent Injector tramite Helm:

```bash
# Chart hashicorp/vault, injector-only mode
# server.enabled=false, global.externalVaultAddr set
```

Ho creato un pod di test con le annotazioni per l'autenticazione JWT. L'init container `vault-agent-init` falliva con un errore criptico:

```
Error creating jwt auth method: missing 'path' value
```

La configurazione generata dall'injector era:

```json
{
  "auto_auth": {
    "method": {
      "type": "jwt",
      "mount_path": "auth/jwt",
      "config": {
        "role": "smoketest",
        "token_path": "/var/run/secrets/..."
      }
    }
  }
}
```

Il problema è sottile ma devastante: per il metodo di autenticazione `kubernetes`, il parametro si chiama `token_path`. Per il metodo `jwt`, il parametro obbligatorio si chiama `path`. L'injector (vault-k8s v1.7.2) genera `token_path` in entrambi i casi, quindi per JWT il parametro `path` è assente e la configurazione viene rifiutata.

È un bug noto, tracciato come [hashicorp/vault-k8s issue #660](https://github.com/hashicorp/vault-k8s/issues/660). Il workaround è forzare il parametro `path` con un'annotazione esplicita:

```yaml
vault.hashicorp.com/auth-config-path: "/var/run/secrets/kubernetes.io/serviceaccount/token"
vault.hashicorp.com/auth-config-remove-jwt-after-reading: "false"
```

Senza la prima, il path non viene generato. Senza la seconda, su filesystem read-only (come quelli di Talos), l'agent tenta di cancellare il JWT dopo averlo letto — e crasha.

## Multi-issuer: perché bound_issuer era sbagliato

Con il workaround applicato, l'autenticazione arrivava fino a Vault, ma veniva rifiutata:

```
error validating token: invalid issuer (iss) claim
```

Il token del ServiceAccount di Kubernetes contiene un campo `iss` che dichiara chi ha emesso il token. Il mio `bound_issuer` su Vault era configurato come `https://lushycorp-k8s.magellanic-gondola.ts.net:6443`. Ma il token conteneva:

```json
"iss": "https://lushycorp-k8s.magellanic-gondola.ts.net:6443,https://kubernetes.default.svc.cluster.local"
```

Due issuer, concatenati. È il multi-issuer di Talos: la configurazione `service-account-issuer` dell'API server accetta una lista separata da virgole, e il JWT risultante include TUTTI gli issuer nel campo `iss`. Vault deve matchare esattamente quella stringa — virgola inclusa.

## Il sidecar che non funzionava: PodSecurity, read-only FS, e runAsUser

Con l'autenticazione JWT funzionante e il database engine configurato, la smoke test passava: l'init container scriveva le credenziali in `/vault/secrets/` e il pod partiva. Ma il sidecar `vault-agent` — quello che dovrebbe rimanere in esecuzione per rinnovare i token — crashava immediatamente.

La causa era duplice. Primo, Talos applica PodSecurity `restricted` che richiede `runAsUser` esplicito su ogni container. Grafana non ce l'aveva, e l'annotazione `agent-run-as-same-user: "true"` falliva perché l'UID del container principale era `nil`. Secondo, il sidecar cerca di scrivere file di cache su `/tmp`, ma su Talos alcuni mount sono read-only.

Ho risolto aggiungendo `securityContext.runAsUser: 1000` al container Grafana e le annotazioni per allineare l'UID del sidecar:

```yaml
grafana:
  containerSecurityContext:
    runAsUser: 1000
    runAsGroup: 1000
  podAnnotations:
    vault.hashicorp.com/agent-run-as-user: "1000"
    vault.hashicorp.com/agent-run-as-group: "1000"
    vault.hashicorp.com/agent-share-process-namespace: "true"
```

Questo pattern è necessario per TUTTI i pod iniettati su Talos.

## Podman DNS: una race condition all'avvio

Vault gira in un container Podman sulla VM Hetzner. Durante la sessione, avevo fixato manualmente il DNS del container aggiungendo `nameserver 100.100.100.100` nel `/etc/resolv.conf`. Ma la volta dopo un reboot, il problema si sarebbe ripresentato.

La causa? Il systemd unit di Vault non dipendeva da `tailscaled.service`, quindi il container partiva prima che Tailscale avesse aggiornato il resolver di sistema. Al boot, il container vedeva i DNS di Hetzner, non quelli di Tailscale.

Ho patchato il systemd unit e aggiornato il template Ansible:

```ini
[Unit]
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 30); do tailscale status >/dev/null 2>&1 && break; sleep 1; done'
```

Ora il container aspetta che Tailscale sia pronto prima di avviarsi.

## Grafana senza ExternalSecret: la migrazione pulita

L'ultima fase è stata migrare Grafana da un ExternalSecret statico (con password PostgreSQL in un Kubernetes Secret) a credenziali dinamiche via Vault Agent Injector.

La configurazione finale richiede:

1. Annotazioni per l'injection (JWT auth, path, template)
2. Env var `GF_DATABASE_USER__FILE` e `GF_DATABASE_PASSWORD__FILE` che leggono da `/vault/secrets/`
3. `grafana.ini.database.user: ''` per usare solo le env var
4. Rimozione dell'ExternalSecret e del secrets.yaml

Un ostacolo imprevisto: il deployment Helm di `kube-prometheus-stack` non espone `podAnnotations` direttamente. I valori passati al chart vengono processati, ma la chiave giusta è `grafana.podAnnotations`, non `grafana.annotations`. E in più, il template Consul Template per l'annotazione (`{{- with secret ...}}`) usa le doppie graffe che Helm interpreta come template Go. La soluzione: single-quote YAML attorno al template.

## Cosa ho imparato

1. **--accept-routes su Linux non è opzionale.** Se usate Tailscale Services (ProxyGroup o LoadBalancer), ogni client Linux deve accettare le rotte esplicitamente. Desktop e mobile lo fanno automaticamente; Linux no.

2. **vault-k8s v1.7.2 ha un bug con JWT.** Il parametro `token_path` non esiste per il metodo JWT. Vuole `path`. Fino a che HashiCorp non fixa l'issue #660, servono due annotazioni di workaround.

3. **Multi-issuer non è opzionale su Talos.** Se configurate `service-account-issuer` con più di un issuer, il JWT li contiene tutti concatenati. Vault deve matchare esattamente.

4. **Talos + sidecar non funziona senza runAsUser.** PodSecurity restricted richiede UID esplicito. Allineate UID del container principale e del sidecar con `agent-run-as-user` e `containerSecurityContext`.

5. **Podman + Tailscale DNS è una race condition.** Se il container parte prima di Tailscale, il DNS è sbagliato. La soluzione: dipendenza esplicita nel systemd unit.

6. **Helm + Consul Template è un problema noto.** Le doppie graffe nei valori Helm vanno in conflitto. Single-quote YAML funziona ed è il pattern più usato nella community.
