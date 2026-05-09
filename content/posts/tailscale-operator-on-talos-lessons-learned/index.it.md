+++
title = "Quando il Piano non Basta: Deployare Tailscale Operator su Talos"
date = 2026-05-08T20:00:00+02:00
draft = false
tags = ["Kubernetes", "Talos OS", "Flux", "Tailscale", "GitOps", "DNS", "CRISP", "Design Review", "Home Lab"]
description = "Deployare il Tailscale Kubernetes Operator su un cluster Talos sembrava un progetto CRISP lineare. Dopo otto cicli destroy-create, tre redesign del DNS e una scoperta sulle API Infisical, ecco cosa ho imparato."
author = "Tazzo"
+++

## L'Obiettivo: DNS per il Vault

Il contesto è semplice. Il cluster TazLab ha un'istanza HashiCorp Vault su una VM Hetzner, connessa alla tailnet tramite Tailscale. Il passo successivo è integrare Vault come backend di segreti per il cluster — un ClusterSecretStore di External Secrets Operator che punti a `lushycorp-vault.magellanic-gondola.ts.net:8200`.

Il problema è che i pod del cluster non possono risolvere MagicDNS names. I nodi Talos sono nella tailnet (grazie al System Extension di Tailscale), ma i pod hanno solo accesso a CoreDNS che, a sua volta, è un Deployment senza `hostNetwork`. Il resolver locale di Tailscale (`100.100.100.100`) non è raggiungibile dai pod.

La soluzione progettata: deployare il **Tailscale Kubernetes Operator** e usare la sua CRD `DNSConfig` per creare un nameserver DNS con accesso alla tailnet, poi configurare CoreDNS per forwardare `magellanic-gondola.ts.net` verso quel nameserver. Un piano lineare, ben incapsulato nel progetto CRISP `10-operator-dns-resolution`.

O almeno, così sembrava.

## Il Primo Errore: DNSConfig Non Risolve Nodi Arbitrari

Dopo ore passate a progettare la DAG Flux a tre layer, a scrivere i task, a fare review del design, arriva il momento del deploy. L'Operator parte senza problemi — namespace, ExternalSecret, HelmRelease, tutto in ordine. La CRD `DNSConfig` viene creata, il nameserver pod parte.

Ma i test DNS falliscono. `kubectl exec` da un pod qualsiasi — **NXDOMAIN**. Il nameserver non risolve.

Il problema? **La CRD DNSConfig risolve solo hostname di proxy gestiti dall'Operator.** Egress proxy, Ingress con `tailscale.com/experimental-forward-cluster-traffic-via-ingress` — questi vengono automaticamente registrati nel nameserver. Un nodo tailnet normale come `lushycorp-vault` non viene risolto.

La documentazione della CRD è chiara, ma chiara in modo subdolo: dice "DNSConfig makes a subset of Tailscale MagicDNS names resolvable." Quel "subset" sono i proxy. Non i nodi. Non mi ero accorto di questa limitazione durante la fase di design perché nel README del progetto avevo scritto genericamente "MagicDNS resolution", senza specificare che intendevo nodi arbitrari. Un classico errore di astrazione: ho assunto che la soluzione fosse più generale di quanto non fosse.

## La Trappola degli ACL di Tailscale

Un altro ostacolo durante l'implementazione è stata la gestione degli ACL di Tailscale. Il design prevedeva di creare un gruppo `tag:tazlab-k8s` che includesse sia il tag esistente che il nuovo `tag:k8s-operator`, in modo che l'ACL rule `tag:tazlab-k8s → tag:vault-api:8200` coprisse automaticamente l'Operator.

Il problema: **Tailscale non permette di includere tag in un gruppo**. I gruppi (`group:`) accettano solo indirizzi email di utenti, non tag macchina. È una limitazione documentata della sintassi ACL. La regola che avevo progettato — `"groups": { "group:tazlab-k8s": ["tag:tazlab-k8s", "tag:k8s-operator"] }` — è stata rifiutata dal validatore di Tailscale con un errore criptico.

La soluzione è stata molto più semplice: aggiungere una ACL rule diretta per `tag:k8s-operator → tag:vault-api:8200`. Due regole invece di una. Poche righe, zero magia.

## Due Strade, Due Risultati

A questo punto avevo quattro opzioni:

1. **Usare l'IP tailnet diretto** — `100.82.13.87:8200` invece del nome DNS. Funziona per TCP, ma il certificato TLS del Vault è emesso per il nome, non per l'IP. Servirebbe aggiungere l'IP al SAN del certificato o bypassare la verifica TLS. Entrambe soluzioni fragili.
2. **Creare un Connector CR** — Il Connector crea un dispositivo tailnet gestito dall'Operator, ma non risolve il nome di un nodo esterno. È un nuovo dispositivo, non un proxy per uno esistente.
3. **DNS relay su hostNetwork** — Un DaemonSet che corre sulla rete host del nodo, dove Tailscale è accessibile (o almeno così pensavo).
4. **Modificare il deploy di CoreDNS** per funzionare sulla rete host. Invasivo e toccherebbe la config di Talos.

Ho scelto la tre: un DaemonSet CoreDNS con `hostNetwork: true`, su una porta alternativa (5353 — perché la 53 è già occupata dal CoreDNS di sistema di Talos). Il relay doveva forwardare le query a `100.100.100.100`, il resolver MagicDNS di Tailscale.

Peccato che **anche il relay hostNetwork non raggiunge `100.100.100.100`**. Il Talos System Extension di Tailscale non espone il resolver virtuale all'host — `tailscaled` gestisce le query DNS internamente. Ho dovuto ripiegare su un mapping statico via il plugin `hosts` di CoreDNS: `lushycorp-vault.magellanic-gondola.ts.net → 100.82.13.87`.

Non è elegante. È un workaround funzionante. E ha un debito tecnico evidente: se l'IP di Vault cambia, il mapping va aggiornato.

## Il Secondo Errore: L'InlineManifest Ignorato

Talos ha un meccanismo chiamato `inlineManifest` che permette di injectare risorse Kubernetes direttamente nella machine config. Il progetto usa questo per creare il ConfigMap `coredns` in `kube-system` con un Corefile custom che blocca le query IPv6 e configura il forwarding.

La modifica per il MagicDNS: aggiungere un server block per `magellanic-gondola.ts.net` che forwarda al relay. Aggiorno il modulo Terraform `proxmox-talos`, lancio `terragrunt apply`, la config viene applicata. Ma il Corefile running è sempre quello default.

**Perché?** Talos ha un controller proprietario che gestisce il ConfigMap di CoreDNS. L'inlineManifest viene applicato — il ConfigMap `coredns` viene creato — ma il controller di Talos lo sovrascrive immediatamente col suo template interno. È un conflitto di ownership che non avevo previsto.

La soluzione pratica: patchare il ConfigMap `kube-system/coredns` dopo ogni cluster create, tramite lo script `create.sh`. Non è la strada enterprise — il ConfigMap dovrebbe essere dichiarativo, non patchato a mano — ma è l'unica cosa che ha funzionato.

## La Scoperta dell'Endpoint EU di Infisical

Durante il deploy dell'ExternalSecret per le credenziali OAuth dell'Operator, mi sono trovato con il Secret vuoto. Le chiavi `TAILSCALE_OPERATOR_CLIENT_ID` e `TAILSCALE_OPERATOR_CLIENT_SECRET` non arrivavano da Infisical. L'ExternalSecret era stato creato (ESO segnalava `SecretSynced`), ma i valori erano stringhe vuote.

Il problema era un errore di configurazione **molto** più subdolo di un typo. Il nostro `setup.sh` è sempre stato configurato per pushare segreti all'endpoint `app.infisical.com`. Ma il workspace di Infisical del TazLab è sulla **regione EU**, che usa un dominio diverso: `eu.infisical.com`. Per settimane, tutti i tentativi di pushare segreti sono falliti con un 401 che ho interpretato come "credenziali scadute", quando invece era "stai sbagliando endpoint".

Una volta corretto l'endpoint, l'autenticazione ha funzionato, le chiavi sono arrivate, e l'ExternalSecret ha iniziato a popolare i valori corretti. Il problema più interessante: la **ClusterSecretStore** di ESO era già configurata correttamente — `hostAPI: https://eu.infisical.com` — ma lo script di setup no. Il mismatch tra i due era passato inosservato perché le credenziali per i segreti esistenti (GITHUB_TOKEN, GEMINI_API_KEY, etc.) erano state create manualmente.

## Il Rate-Limit Anonimo di ghcr.io

Un problema che non c'entrava nulla col design ma che ha bloccato tutto per ore: il rate-limit anonimo di ghcr.io.

I cluster Talos, dopo un destroy+create, hanno nodi vergini senza immagini in cache. Quando `flux_bootstrap_git` installa i controller Flux, deve pullare le immagini da ghcr.io. Esonerate dal limite anonimo di 100 pull per 6 ore per IP.

I primi controller (source-controller, kustomize-controller) pullano senza problemi. Ma l'helm-controller è l'ultimo. E quando arriva il suo turno, la quota anonima è esaurita. Il pod resta in `ContainerCreating` per minuti, poi va in timeout, la DAG Flux si blocca, e tutto il bootstrap si ferma.

La soluzione: creare un Docker registry secret con il GitHub token (`x-access-token`) e patcharlo sui ServiceAccount dei namespace interessati. Le pull autenticate non hanno rate-limit. Ho dovuto estendere `create.sh` per creare questo secret in 6 namespace strategici appena il cluster era operativo, prima che i controller iniziassero a pullare.

## La DAG che Abbiamo Scoperto Essere Troppo Lunga

Il progetto CRISP originale aveva una DAG a 2 layer:
1. **Layer 1**: namespace, ExternalSecret, HelmRepository
2. **Layer 2**: HelmRelease, DNSConfig, Service, ConfigMap

Il problema: HelmRelease installa le CRD, ma DNSConfig viene applicato nella stessa Kustomization prima che le CRD siano pronte. Flux retry risolve (riprova dopo pochi secondi), ma viola l'obiettivo "zero transient errors" che ci eravamo prefissati. La review ha evidenziato che mettere una Custom Resource nella stessa Kustomization del suo operatore è un errore di design classico — e l'avevamo fatto comunque.

La soluzione è stata una DAG a 3 layer, dove ogni Kustomization ha una singola responsabilità:
1. **Layer 1** (`infrastructure-tailscale`): namespace + credenziali ESO + HelmRepository — DAG root, parte in parallelo con gli altri root
2. **Layer 2** (`infrastructure-operators-tailscale`): HelmRelease puro — installa CRD e avvia l'Operator, dipende da Layer 1
3. **Layer 3** (`infrastructure-tailscale-dns`): DNSConfig + Service + ConfigMap — si applica quando Layer 2 ha completato

Ogni layer è garantito dal precedente grazie a `dependsOn` + `wait: true`. Zero transienti. Ma la DAG è più lunga da spiegare e da mantenere.

## Un'intera Sessione per un Fix di Bootstrap

Una volta completato il codice, ho fatto quello che faccio sempre: destroy e create del cluster per verificare che tutto funzioni one-shot.

La prima volta ha funzionato — dopo 22 minuti. Poi ho distrutto e ricreato. 9 minuti. Poi ancora. Ogni volta che distruggevo e ricreavo il cluster, succedeva qualcosa di diverso: il rate-limit di ghcr.io, il Corefile che non veniva applicato, lo storage che aspettava gitops inutilmente.

Alla fine, dopo **8 cicli destroy-create**, avevo corretto tutti i problemi:

- **ghcr.io pull secret** creato dopo l'engine layer in 6 namespace
- **Corefile patchato** via `kubectl create configmap` nello script di creazione
- **Storage parallelizzato** con networking+gitops invece che sequenziale
- **Infisical endpoint** corretto da `app.infisical.com` a `eu.infisical.com`
- **Kubernetes_manifest** rimosso dal modulo Terraform (conflitto con Terragrunt)
- **Ogni modifica** committata nel branch feat del progetto

L'ultimo ciclo è andato liscio: 9 minuti, zero interventi. Il cluster è nato con l'Operator deployato, il DNS funzionante, il blog online. Ma ci sono voluti 8 tentativi per arrivarci.

## Lo Storage Che Aspettava Tutti

Un ultimo problema nel processo di cluster creation: lo storage layer (che deploya Longhorn) era sequenziale dopo networking E gitops, anche se dipende solo dal networking. La correzione è stata banale: lanciare storage in background appena networking finisce, in parallelo con gitops. Un guadagno di circa 70 secondi sul ciclo totale di rebuild.

## Il Debito Lasciato

Il cluster funziona. Il Vault è raggiungibile via DNS. Ma ho lasciato dei debiti tecnici che andranno affrontati a breve:

1. **Mapping statico del relay DNS** — `lushycorp-vault` → `100.82.13.87` è hardcodato. Se l'IP tailnet di Vault cambia, il DNS si rompe. La soluzione ideale sarebbe un forward dinamico a `100.100.100.100`, ma non è raggiungibile dai nodi Talos.

2. **CoreDNS patchato in create.sh** — Il vero Corefile non è gestito da Terraform né da GitOps. È uno script bash che fa `kubectl apply`. Serve un modo dichiarativo per configurare CoreDNS su Talos senza che venga sovrascritto.

3. **DNSConfig CR zavorra** — La CRD `dnsconfig.yaml` è ancora deployata, ma non serve a nulla. Non risolve nodi arbitrari. Andrebbe rimossa.

4. **ghcr.io pull secret** — Funziona ma è uno script bash. Dovrebbe essere un meccanismo permanente, inline nel bootstrap o un mutating webhook.

5. **Auth race (TD-026)** — `oauth2-proxy` parte prima di Dex e crasha in loop finché Dex non è pronto. Un init container che polla l'endpoint OIDC risolverebbe il problema.

## Riflessioni

Questo progetto mi ha insegnato che la differenza tra un piano CRISP e un cluster funzionante è fatta di piccole scoperte: una CRD che non fa quello che credi, un endpoint API che cambia per regione, un controller Talos che sovrascrive i tuoi manifest.

Il design review è servito tantissimo — ha catturato errori di DAG e di placement che avrebbero causato problemi ben peggiori. Ma non ha catturato il problema della CRD DNSConfig, perché la documentazione non era stata letta con sufficiente profondità. Farò in modo che nella prossima review, ogni CRD venga analizzata insieme alla documentazione ufficiale, non solo al README del progetto.
