+++
title = "Tailscale: La Spina Dorsale Sicura della Rinascita del TazLab"
date = 2026-03-24T14:35:00+00:00
draft = false
tags = ["Tailscale", "Terraform", "Infrastructure-as-Code", "TazPod", "Security", "Networking", "Zero Trust", "DevOps", "OAuth", "Automation"]
description = "Come ho costruito il tessuto connettivo per la rinascita del TazLab: una rete Tailscale interamente gestita tramite IaC, senza chiavi temporanee e integrata nel vault di TazPod."
author = "Tazzo"
+++

# Tailscale: La Spina Dorsale Sicura della Rinascita del TazLab

## Introduzione: Il Tessuto Connettivo tra i Due Mondi

Nel percorso di ricostruzione del TazLab che ho descritto nei [precedenti articoli](/posts/bootstrap-from-zero-vault-s3-rebirth/), siamo arrivati a un punto critico. Abbiamo un piano per far rinascere l'infrastruttura da un singolo bucket S3 e abbiamo blindato le credenziali di bootstrap eliminandole dal disco grazie a TazPod e AWS SSO. Ma c'è un elemento che mancava ancora: il "filo invisibile" che permette a questi componenti di parlarsi in modo sicuro, privato e agnostico rispetto al provider cloud.

L'obiettivo di oggi non era solo "attivare una VPN". L'obiettivo era progettare e implementare la **fondazione di rete** del TazLab come una risorsa Infrastructure-as-Code (IaC) pura. Niente configurazioni manuali nella console di Tailscale, niente chiavi di autenticazione temporanee che scadono dopo 90 giorni costringendomi a interventi manuali. Ho cercato una soluzione che fosse eterna, dichiarativa e integrata nel ciclo di vita effimero dei miei cluster.

---

## Il Problema delle Pre-auth Key: Un Debito Tecnico Annunciato

Il modo standard di aggiungere nodi a una Tailnet è usare le **Pre-auth Keys**. Sono comode per un setup rapido, ma presentano tre problemi fondamentali per un'infrastruttura che punta all'automazione totale:

1.  **Scadenza**: Anche se impostate alla durata massima, scadono. Questo significa che se il mio cluster deve scalare o rinascere dopo sei mesi, il bootstrap fallirà perché la chiave iniettata nel codice o nei segreti non è più valida.
2.  **Gestione Manuale**: Generare una nuova chiave richiede un'azione umana nella UI di Tailscale. È l'opposto del principio "Bootstrap from Zero" che sto perseguendo.
3.  **Mancanza di Tracciabilità IaC**: Non puoi definire una Pre-auth Key in Terraform in modo che venga ricreata automaticamente senza intervento esterno se non tramite giri tortuosi.

La soluzione architetturale corretta è l'uso di un **Client OAuth**. Un Client OAuth di Tailscale non è una chiave, ma un'identità che può *generare* chiavi di autenticazione al volo. Non scade mai (a meno di revoca esplicita) e può essere gestito programmaticamente. Questo è il componente che ho deciso di mettere al centro della rete del TazLab.

---

## La Fase IaC: Ephemeral-Castle Si Espande

Ho iniziato creando una nuova directory nel repository delle configurazioni infrastrutturali: `ephemeral-castle/tailscale/`. Qui ho depositato il codice Terraform che governa l'intera rete.

### Il Cuore Declarativo: `acl.json`

Invece di scrivere le policy di accesso direttamente nell'HCL di Terraform, ho scelto di mantenere un file `acl.json` separato. Questa scelta non è estetica: le ACL di Tailscale sono un JSON complesso e avere un file dedicato permette di validarlo indipendentemente e di leggerlo con estrema chiarezza.

La filosofia applicata è lo **Zero Trust basato sui Tag**. Nessun nodo ha accesso alla rete perché è "nella LAN". L'accesso è concesso solo se il nodo possiede un tag specifico. Ho definito cinque tag fondamentali:

*   `tag:tazlab-vault`: I nodi del cluster Vault su Oracle Cloud.
*   `tag:tazlab-k8s`: I nodi del cluster K8s principale su Proxmox/AWS.
*   `tag:vault-api`: L'identità specifica del proxy Vault.
*   `tag:tazlab-db`: L'identità specifica del proxy database.
*   `tag:tazpod`: La mia workstation di amministrazione.

Il principio del **Least Privilege** è applicato rigorosamente: il cluster K8s può parlare con il Vault solo sulla porta `8200`, e solo tramite il tag del proxy. I nodi non si vedono tra loro a livello di OS, vedono solo i servizi necessari.

```json
{
  "tagOwners": {
    "tag:tazlab-vault": ["roberto.tazzoli@gmail.com"],
    "tag:tazlab-k8s":   ["roberto.tazzoli@gmail.com"],
    "tag:vault-api":    ["roberto.tazzoli@gmail.com"],
    "tag:tazlab-db":    ["roberto.tazzoli@gmail.com"],
    "tag:tazpod":       ["roberto.tazzoli@gmail.com"]
  },
  "acls": [
    {
      "action":  "accept",
      "src":     ["tag:tazlab-vault"],
      "dst":     ["tag:tazlab-vault:8201"]
    },
    {
      "action":  "accept",
      "src":     ["tag:tazlab-k8s"],
      "dst":     ["tag:vault-api:8200"]
    },
    { "action": "accept", "src": ["tag:tazpod"], "dst": ["tag:tazlab-vault:6443,50000", "tag:tazlab-k8s:6443,50000"] }
  ]
}
```

Durante l'implementazione, ho riscontrato un errore di validazione interessante: Terraform restituiva `Error: ACL validation failed: json: unknown field "comment"`. Questo è un classico esempio di discrepanza tra la UI (che permette commenti inline nelle ACL) e l'API JSON pura, che non li accetta. Ho dovuto ripulire il file `acl.json` da ogni commento per permettere a Terraform di applicarlo con successo.

---

## La Scoperta (The "Aha!" Moment): Terraform e il Client OAuth

Inizialmente, il mio piano prevedeva l'uso di `curl` all'interno di uno script di bootstrap per creare il Client OAuth, poiché molte guide datate suggerivano che il provider Terraform di Tailscale non supportasse ancora questa risorsa.

Ho iniziato a scrivere lo script `setup.sh` usando `curl`, ma continuavo a ricevere errori `404 page not found`. Ho provato a debuggare l'URL, a cambiare il formato (usando `-` per il tailnet name, o il Tailnet ID completo), ma senza successo. Il troubleshooting stava diventando frustrante.

Invece di insistere sull'errore, ho deciso di fare un passo indietro e analizzare i sorgenti del provider Terraform `tailscale/tailscale ~> 0.17`. È stata la svolta: ho scoperto che la risorsa `tailscale_oauth_client` **esiste ed è perfettamente funzionante**. 

Ho cancellato lo script `curl` e ho riscritto tutto in Terraform:

```hcl
# OAuth client per bootstrap (genera pre-auth keys)
resource "tailscale_oauth_client" "bootstrap" {
  description = "tazlab-bootstrap"
  scopes      = ["auth_keys", "devices"]
  tags        = ["tag:tazpod"]
}
```

Questa scoperta ha cambiato radicalmente la qualità del lavoro. Ora l'identità che genera le chiavi di rete è una risorsa gestita, tracciata nel `terraform.tfstate` e ricreabile con un comando. L'idempotenza non è più un desiderio, ma una realtà tecnica.

### Il Problema dei TagOwners

Un altro ostacolo si è presentato subito dopo: `requested tags [tag:tazpod] are invalid or not permitted (400)`. 
Per creare un Client OAuth che possa assegnare un tag, l'utente (o la chiave API) che esegue l'operazione deve essere esplicitamente dichiarato come "proprietario" di quel tag nella sezione `tagOwners` delle ACL. Ho dovuto aggiornare `acl.json` includendo la mia email per ogni tag prima che Terraform potesse creare con successo il client OAuth. È un dettaglio di sicurezza fondamentale: Tailscale impedisce che un'identità compromessa possa creare nuovi client con tag arbitrari a cui non ha accesso.

---

## Integrazione con TazPod: Chiudere il Cerchio della Sicurezza

Una volta generato il Client OAuth tramite Terraform, il problema è diventato: dove salviamo il `client_id` e il `client_secret`? Non possono stare nel repository git (ovviamente) e non volevo salvarli in un file locale insicuro.

Ho utilizzato il **Vault RAM di TazPod**. Ho aggiornato lo script di orchestrazione `setup.sh` affinché, dopo l'esecuzione di Terraform, estragga automaticamente i segreti dagli output:

```bash
# Estraggo le credenziali da Terraform
OAUTH_CLIENT_ID=$(terraform output -raw oauth_client_id)
OAUTH_CLIENT_SECRET=$(terraform output -raw oauth_client_secret)

# Le salvo nel vault RAM di TazPod
echo "$OAUTH_CLIENT_ID"     > ~/secrets/tailscale-oauth-client-id
echo "$OAUTH_CLIENT_SECRET" > ~/secrets/tailscale-oauth-client-secret

# Sincronizzo con S3
(cd /workspace && tazpod save && tazpod push vault)
```

Ora, il ciclo di rinascita è completo anche per la rete. Quando eseguo `tazpod unlock`, i segreti necessari per connettersi alla Tailnet vengono montati in memoria. Qualsiasi nuovo cluster o istanza TazPod potrà usare queste credenziali per unirsi alla rete in meno di un secondo.

---

## Verifica Empirica: Il Test Live

La teoria è bella, ma i sistemi devono funzionare. Ho eseguito un test live installando Tailscale direttamente nel container `tazpod-lab` (che ancora non lo includeva). Questa mancanza è stata il trigger per un aggiornamento immediato della layer hierarchy di TazPod: Tailscale deve essere parte del DNA dell'immagine base.

Dopo aver avviato il demone `tailscaled` in modalità userspace (necessaria perché il container non ha i permessi per creare interfacce `tun` sul kernel dell'host), ho tentato la connessione usando le credenziali appena salvate nel vault:

```bash
ID=$(cat ~/secrets/tailscale-oauth-client-id)
SECRET=$(cat ~/secrets/tailscale-oauth-client-secret)

sudo tailscale up \
  --client-id="$ID" \
  --client-secret="$SECRET" \
  --hostname=tazpod-lab \
  --advertise-tags=tag:tazpod \
  --reset
```

Il risultato è stato istantaneo:
`active login: tazpod-lab.magellanic-gondola.ts.net`
`IP: 100.73.57.110`

Il nodo è apparso nella rete, correttamente taggato come `tag:tazpod`, con la scadenza delle chiavi disabilitata automaticamente dal sistema (comportamento standard di Tailscale per i nodi taggati).

---

## Riflessioni Post-Lab: Cosa Abbiamo Imparato

Questa sessione ha consolidato la fondazione di rete del TazLab in tre modi:

1.  **Indipendenza dal Provider**: Non importa se un cluster gira su OCI, AWS o nel mio salotto. Se ha l'estensione Tailscale e il Client OAuth, è parte della rete privata del TazLab istantaneamente.
2.  **Manutenibilità Zero**: Passando dai Client OAuth gestiti via IaC, ho eliminato il rischio di fallimenti dovuti a scadenze di chiavi. La rete è ora un'entità "viva" che si autogestisce.
3.  **Sicurezza Integrata**: La catena di fiducia che parte da AWS SSO e passa per il Vault RAM di TazPod ora protegge anche l'accesso alla rete.

Il prossimo passo della roadmap è il provisioning del cluster **tazlab-vault** su Oracle Cloud. Grazie al lavoro di oggi, quel cluster nascerà già parlando privatamente con il resto del mio mondo, senza che io debba mai esporre la sua porta 8200 al traffico pubblico di internet.

La rete c'è. Il castello effimero ha ora le sue mura invisibili.
