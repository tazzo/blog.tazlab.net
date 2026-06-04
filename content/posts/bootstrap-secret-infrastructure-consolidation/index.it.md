+++
title = "Consolidamento del Cluster e Riduzione dei Bootstrap Token a uno solo"
date = 2026-06-04T18:00:00+00:00
draft = false
tags = ["Kubernetes", "HashiCorp Vault", "Terraform", "Flux", "GitOps", "Secrets Management", "External Secrets Operator", "Vault Secrets Operator", "Reloader"]
description = "Due progetti di consolidamento dell'infrastruttura secret: portare i segreti di bootstrap su Vault con un singolo token scoped, e migrare ESO da Terraform a Flux come VSO, con Reloader e ExternalSecret per dex e oauth2-proxy."
+++

## Il Problema Architetturale

L'infrastruttura secret di TazLab si era evoluta in modo disordinato. Da un lato, i segreti per il bootstrap del cluster erano sparsi in sei file dentro `~/secrets/`, mescolando credenziali Proxmox, token GitHub, chiavi Talos, token Vault, credenziali Tailscale e certificati TLS. Era funzionale ma fragile: la cartella `~/secrets/` era l'unica fonte di verità, senza una gerarchia chiara tra segreti di bootstrap e segreti di workload.

Dall'altro lato, l'External Secrets Operator (ESO) era ancora installato da Terraform, mentre Vault Secrets Operator (VSO) era già gestito da Flux. Un'asimmetria che rendeva difficile l'upgrade di ESO e violate la divisione architetturale che mi ero dato: **Tutto ciò che è provider-agnostic deve stare in Flux. Tutto ciò che è provider-specific deve stare in Terraform**.

Il progetto si è articolato in due fasi: prima ridurre i bootstrap secret a Vault, poi portare ESO in Flux. Otto review, un destroy+create alla fine, e un sistema più pulito.

In questo articolo racconto il ragionamento dietro ogni scelta, gli errori che ho fatto e come le review iterative li hanno intercettati.

## Progetto 1: Portare i Bootstrap Secret su Vault

### Il Contesto

Quando `create.sh` avvia un cluster, ha bisogno di accedere a una serie di segreti prima che qualsiasi operatore (ESO, VSO) possa funzionare: le credenziali Proxmox per creare le VM, il token GitHub per bootstrappare Flux, la chiave Talos per la crittografia etcd, le credenziali OAuth di Tailscale, il token di ESO per autenticarsi su Vault, e il certificato CA di Vault.

Questi segreti erano tutti in `~/secrets/`, letti direttamente da file. Funzionava, ma la cartella si era riempita. L'idea è stata: e se TazPod (dove girano gli script) potesse parlare direttamente con Vault via Tailscale, e il bootstrap fetchasse tutto da lì con un singolo token scoped?

TazPod è già sulla tailnet. Vault è su Hetzner, raggiungibile via Tailscale. Non c'erano problemi di connettività. Bastava creare un token Vault con policy di sola lettura su un path specifico, e modificare `create.sh` per fetchare i segreti all'avvio.

### La Soluzione

Il cuore del cambiamento è stato semplice: un'unica chiamata `vault read -format=json secret/data/tazlab-k8s/bootstrap` invece di 8 letture separate. Il segreto contiene tutti gli 8 field (PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET, GITHUB_TOKEN, TALOS_SECRETBOX_KEY, TAILSCALE_OPERATOR_CLIENT_ID/SECRET, VAULT_CA_CRT, ESO_READER_TOKEN) in un unico path KV v2.

```bash
# create.sh — Step 0
export VAULT_ADDR="https://lushycorp-vault.magellanic-gondola.ts.net:8200"
export VAULT_SKIP_VERIFY=true

if timeout 5 vault status >/dev/null 2>&1 && [[ -f ~/secrets/bootstrap-token.txt ]]; then
  export VAULT_TOKEN="$(cat ~/secrets/bootstrap-token.txt | tr -d "'\"\t\r\n ")"
  timeout 3 vault token renew >/dev/null 2>&1 || true

  SECRETS_JSON=$(vault read -format=json secret/data/tazlab-k8s/bootstrap 2>/dev/null)
  if [[ -n "$SECRETS_JSON" ]]; then
    parse_trim() { echo "$SECRETS_JSON" | jq -r ".data.data.$1 // \"\"" | tr -d "'\"\t\r\n "; }
    parse_raw()  { echo "$SECRETS_JSON" | jq -r ".data.data.$1 // \"\""; }

    export PROXMOX_TOKEN_ID=$(parse_trim PROXMOX_TOKEN_ID)
    export PROXMOX_TOKEN_SECRET=$(parse_trim PROXMOX_TOKEN_SECRET)
    # ... altri field
  fi
fi
```

Se Vault non è raggiungibile, la funzione `resolve()` cade sul fallback dei file locali. `~/secrets/` non viene mai toccata — resta l'ancora di recovery immutabile.

### Cosa le Review Hanno Insegnato

Ho passato questo progetto attraverso **cinque review** con agenti diversi. Ogni review ha trovato un edge case che non avevo considerato:

1. **La guard clause di `resolve()` sovrascriveva Vault** — la funzione eseguiva dopo lo Step 0 e overwrittava le variabili appena prese da Vault. La soluzione: un controllo `if [[ -n "${!var_name}" && ! -f "${!var_name}" ]]` per saltare la risoluzione se già popolata da Vault.

2. **`tr -d "'\" "` corrompeva i certificati PEM** — la stessa funzione usata per stripare spazi dai token distruggeva `-----BEGIN CERTIFICATE-----`. Branch condizionale per variabili CA_CRT/CERT.

3. **`export` dimenticato su VAULT_ADDR e VAULT_TOKEN** — senza export, il CLI vault parlava a localhost. Già alla terza review.

4. **8 chiamate separate `vault kv get` vs 1 chiamata `vault read`** — la prima soffriva di permission block (il token scoped non poteva queryare mount metadata). Raggruppare tutto in un unico secret e usare `vault read + jq` ha risolto.

5. **Il TTL del bootstrap token era cappato a 32gg** — Vault di default ha `max_lease_ttl = 768h`. Aggiunto `vault token renew` all'inizio di create.sh.

Ognuno di questi era tecnicamente piccolo (un carattere, un export, un flag), ma ognuno avrebbe rotto il bootstrap in produzione.

## Progetto 2: ESO da Terraform a Flux

### Il Cambiamento di Prospettiva

Quando avevo progettato la divisione tra Terraform e Flux, pensavo che ESO sarebbe stato inutile su cloud. L'idea era: su AWS userò AWS Secrets Manager, su GCP userò Secret Manager, quindi ESO non serve. Per questo l'avevo lasciato in Terraform — era un "dettaglio del provider".

Con il tempo ho capito che non è così. Ho un Vault personale (Hetzner) che funziona indipendentemente dal provider sottostante. Che il cluster sia su Proxmox, AWS EKS o GCP GKE, Vault è sempre lì, e ESO + VSO sono gli operatori che ci parlano. ESO non è provider-specific — è un operatore Kubernetes come un altro.

Inoltre i miei piani per il cloud si sono ampliati: non solo Kubernetes gestito (EKS, GKE), ma anche VM raw su Hetzner, Google Cloud, AWS. In tutti questi scenari, il mio Vault resta la fonte di verità per i segreti, e ESO/VSO sono i canali di delivery nel cluster.

Per questo ESO doveva stare in Flux, non in Terraform. Come VSO.

### Cosa è Cambiato

Il progetto originale era semplice: spostare l'HelmRelease di ESO da `k8s-engine/main.tf` a Flux, seguendo lo stesso pattern di VSO. Poi sono emerse altre due cose:

1. **Il Reloader era stato rimosso** durante la migrazione VSO (perché VSO ha `rolloutRestartTargets` nativo). Ma ESO non ha questa funzionalità. Se un secret viene ruotato, i pod non ripartono. La soluzione è stata reinstallare Reloader (Stakater, v1.2.1, `watchGlobally: true`) e aggiungere l'annotazione `reloader.stakater.com/auto: "true"` su `metadata.annotations` del Deployment — non su `spec.template.metadata`, errore scoperto in review.

2. **Dex e oauth2-proxy stavano usando path `merged`** su Vault — e io non me n'ero accorto.

### I Path `merged`: un Problema Ereditato

Durante la migrazione VSO (progetto 13-vso-static-migration, fine Maggio), qualcuno — probabilmente un agente che cercava di fare le cose in modo pulito — aveva consolidato i segreti di dex e oauth2-proxy in path `merged` su Vault. Invece di mantenere `DEX_GOOGLE_CLIENT_ID` e `DEX_GOOGLE_CLIENT_SECRET` su due path separati (come erano in origine), li aveva fusi in un unico path `tazlab-k8s/static/auth/dex/merged`. Stessa cosa per oauth2-proxy.

Il problema è che VSO `VaultStaticSecret` legge da un solo path Vault. Se due field devono finire nello stesso K8s Secret ma vengono da path Vault diversi, VSO non può farlo. Il path `merged` era la soluzione aggirata: si prende tutto da un path solo. Peccato che fosse uno snapshot one-shot, creato manualmente e mai più aggiornato. Se il segreto Google OAuth viene ruotato, il path `merged` resta al valore vecchio, e il sistema continua a usare credenziali stale senza che nessuno se ne accorga.

Io non me n'ero accorto. I test passavano, il sistema funzionava, e nessuno aveva ruotato quei segreti nel frattempo. È emerso solo durante le review di questo progetto, quando abbiamo analizzato cosa fosse ancora in ESO e perché. Il wildcard TLS, per lo stesso identico motivo (CRT e KEY in due path separati), non era mai stato migrato a VSO — e quella era stata una decisione cosciente. I merged path di dex e oauth2-proxy invece erano passati inosservati.

La soluzione è stata riportare dex e oauth2-proxy su ESO ExternalSecret. ESO sa fare merge multi-path nativamente via `remoteRef` multiple con template. Esattamente come facevano prima della migrazione VSO.

## Il Processo di Review Iterativo

In totale, i due progetti hanno passato **otto review**. Ogni review trovava ancora qualcosa. Non perché il progetto fosse mal progettato, ma perché ogni review guardava da una prospettiva diversa: un agente guardava il codice, un altro l'architettura, un altro il DAG di Flux, un altro la compatibilità Ansible.

Il pattern era sempre lo stesso: la struttura era giusta, la soluzione era corretta, ma c'erano piccoli dettagli — una variabile d'ambiente non esportata, un'annotazione nel posto sbagliato, una sintassi YAML errata in un task Ansible, una tabella markdown senza pipe. Cose che in fase di pianificazione sfuggono, ma che una review mirata intercetta.

Il valore delle review non è stato scoprire problemi architetturali — quelli erano già risolti in fase di design. È stato scoprire i **bug da distrazione** che in un sistema reale avrebbero causato downtime.

## Cosa Resta in Terraform

Dopo questi due progetti, l'engine layer di Terraform fa solo il bootstrap nudo:

- I namespace `external-secrets` e `tailscale` (servono per i bootstrap secret)
- I segreti bootstrap `vault-ca-cert`, `vault-eso-token`, `tailscale-operator-oauth`
- CoreDNS user-managed (provider-specific: su Proxmox serve forwarding Tailscale DNS)
- Flux bootstrap (entry point)

Tutto il resto — operatori, secret delivery, app — è in Flux. Provider-agnostico.

## Lezioni Apprese

1. **La divisione Terraform/Flux è chiara solo sulla carta** — nella pratica ogni componente va valutato singolarmente. ESO sembrava provider-specific (perché pensavo di usare secret manager nativi sul cloud), ma ho capito che con un Vault personale è provider-agnostico.

2. **Le review iterative funzionano** — non per trovare buchi architetturali, ma per intercettare i bug da dettaglio che in un sistema complesso fanno la differenza tra un deployment riuscito e una notte di debugging.

3. **I merged path su Vault sono insidiosi** — creare un path che combina più field è una soluzione valida solo se c'è un processo automatico che lo mantiene sincronizzato. Altrimenti è un bug in attesa di manifestarsi.

4. **Un singolo bootstrap token** con policy scoped è più gestibile di 6 file separati. La cartella `~/secrets/` resta come fallback immutabile, ma la source primaria è Vault.

Alla fine, il sistema è più pulito, più documentato (wiki + Mnemosyne), e ogni componente sta nel posto architetturale giusto. Il prossimo passo sarà un ciclo di validazione completo su una piattaforma cloud diversa.
