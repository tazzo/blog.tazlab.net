+++
title = "Il ponte verso Vault: Tailscale, Talos e l'arte del One-Shot Rebirth in Kubernetes"
date = 2026-04-19T05:30:00+00:00
draft = false
description = "Come ho connesso un cluster Talos alla Tailnet per comunicare con Vault, preservando la filosofia del Castello Effimero e risolvendo le complesse race condition tra GitOps e il restore di PostgreSQL."
tags = ["kubernetes", "talos", "tailscale", "vault", "gitops", "flux", "postgres", "longhorn", "disaster-recovery", "devops"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# Il ponte verso Vault: Tailscale, Talos e l'arte del One-Shot Rebirth in Kubernetes

L'evoluzione dell'infrastruttura del TazLab prosegue secondo una roadmap ben definita. Il traguardo finale è chiaro: abbandonare la gestione statica dei segreti offerta dal tier gratuito di Infisical per abbracciare i segreti dinamici e la rotazione automatica garantita da HashiCorp Vault. Come ho documentato nei precedenti articoli, Vault è già stato migrato con successo su una macchina cloud isolata e protetta. Il problema che si poneva in questa specifica sessione non era più relativo a Vault in sé, ma a come far comunicare il cluster Kubernetes locale (basato su Proxmox e Talos OS) con quel Vault remoto, in modo sicuro, deterministico e, soprattutto, senza esporre porte su Internet.

La risposta ovvia a questa esigenza di rete è **Tailscale**, una VPN mesh basata su WireGuard che permette di creare reti private crittografate (Tailnet) tra nodi distribuiti ovunque. Ma nell'ecosistema del TazLab, la "risposta ovvia" deve sempre fare i conti con un principio architetturale non negoziabile: la filosofia del **Castello Effimero**. 

Il cluster Kubernetes locale non è un'entità sacra da preservare a tutti i costi. È una risorsa di calcolo usa e getta. Esisteva già un processo di "One-Shot Rebirth": uno script in grado di radere al suolo le macchine virtuali e ricostruire tutto l'ambiente da zero, ripristinando automaticamente lo stato tramite GitOps (Flux) e i dati tramite il restore del database da S3. L'inserimento di Tailscale come ponte verso Vault non doveva in alcun modo inficiare questa capacità di rigenerazione automatica. Al contrario, doveva integrarsi organicamente, dimostrando che il processo di distruzione e ricostruzione (il Rebirth) continuava a funzionare perfettamente, portando con sé anche la nuova connettività.

Questa sessione infrastrutturale si è quindi sviluppata su un doppio binario: da un lato, l'implementazione tecnica del bridge Tailscale-Talos; dall'altro, l'indagine approfondita e la risoluzione di una serie di affascinanti "race condition" che l'aggiunta di questi nuovi componenti ha fatto emergere durante il ciclo di bootstrap automatizzato.

## La gestione dei segreti in RAM: Il Bridge Tailscale-Talos

Il primo scoglio tecnico consisteva nell'unire i nodi Talos alla Tailnet. Talos è un sistema operativo minimale, immutabile e API-driven, progettato specificamente per Kubernetes. Non ha una shell, non ha SSH, e non permette l'installazione di pacchetti tradizionali. L'estensione delle sue funzionalità avviene tramite le **System Extensions**, moduli pre-compilati che vengono "cotti" all'interno dell'immagine del sistema operativo.

### L'uso delle System Extensions in Talos

Per chi non ha familiarità con questo approccio, una System Extension in Talos non è un demone che si installa a runtime. È una componente integrata a basso livello. Per avere Tailscale, ho dovuto aggiornare la configurazione di Terraform (il modulo `proxmox-talos`) per far puntare i nodi a una specifica *schematic* (un'immagine generata dalla Talos Image Factory) che includesse l'estensione `siderolabs/tailscale`. 

Questa scelta architetturale è superiore rispetto al deploy di Tailscale come DaemonSet all'interno di Kubernetes. Facendo girare Tailscale a livello di sistema operativo (OS layer), i nodi acquisiscono la connettività prima ancora che Kubernetes esegua il bootstrap. Questo garantisce che l'API server e i componenti fondamentali del control plane siano immediatamente protetti e instradati attraverso la VPN mesh, eliminando le complessità di networking e le sovrapposizioni tra il CNI (Container Network Interface) di Kubernetes e le interfacce di rete della VPN.

### La sfida dell'AuthKey e l'iniezione in RAM

Il vero problema operativo, tuttavia, risiedeva nell'autenticazione. Come faccio a far sì che un nodo appena nato si unisca automaticamente alla Tailnet? Tailscale offre le *AuthKey*, chiavi pre-generate che permettono l'iscrizione automatica dei dispositivi. Ma la regola aurea del TazLab vieta categoricamente di scrivere segreti in chiaro su disco o di salvarli nei file di stato (state file) di Terraform.

Se avessi passato l'AuthKey come variabile a Terraform, questa sarebbe finita inevitabilmente nel `terraform.tfstate`, violando i requisiti di sicurezza. La soluzione ha richiesto un approccio più chirurgico.

Ho deciso di implementare la generazione dell'AuthKey direttamente nello script di orchestrazione del bootstrap (`create.sh`), richiedendola dinamicamente tramite le API di Tailscale pochi secondi prima della creazione dei nodi. Questa chiave, generata "on the fly", vive esclusivamente in memoria (nella RAM del processo bash) e viene iniettata nei nodi Talos solo *dopo* che Terraform ha concluso il provisioning dell'infrastruttura di base.

Per farlo, ho utilizzato il comando `talosctl apply-config` per applicare una patch alla configurazione della macchina (Machine Config) utilizzando una `ExtensionServiceConfig`.

```bash
patch_talos_tailscale_extension() {
    # [...] Setup e controlli preliminari
    echo "🔧 Applying RAM-only Tailscale ExtensionServiceConfig patches via talosctl..."

    TALOSCONFIG="$talosconfig" python3 - "$env_file" <<'EOF'
# [...] Logica di parsing dell'inventario dei nodi
for ordinal, node_ip in entries:
    hostname = f"{cluster_name}-{role}-{ordinal}"
    
    extension_doc = {
        "apiVersion": "v1alpha1",
        "kind": "ExtensionServiceConfig",
        "name": "tailscale",
        "environment": [
            f"TS_AUTHKEY={os.environ['TS_AUTHKEY']}",
            f"TS_HOSTNAME={hostname}",
            "TS_EXTRA_ARGS=--advertise-tags=tag:tazlab-k8s --accept-routes=false",
            "TS_STATE_DIR=/var/lib/tailscale",
        ],
    }
    
    # [...] Generazione yaml temporaneo su /dev/shm e applicazione via talosctl
EOF
    echo "✅ Tailscale ExtensionServiceConfig patches applied without persisting TS_AUTHKEY."
}
```

La scelta di usare un costrutto in Python all'interno dello script bash ha permesso di manipolare in modo pulito e sicuro gli output YAML e le variabili d'ambiente. Il file temporaneo con la patch viene creato in `/dev/shm` (uno pseudo-filesystem residente in RAM) ed eliminato immediatamente dopo l'applicazione, garantendo che nessuna traccia della chiave permanga a lungo termine.

### Il debugging dell'AuthKey: Reusable vs Ephemeral

Durante i primi test di questa implementazione, ho riscontrato un comportamento anomalo. Il control plane (il primo nodo) si univa regolarmente alla Tailnet, ma il worker node falliva sistematicamente l'autenticazione. Esaminando i log di sistema del nodo Talos tramite `talosctl dmesg`, ho notato un errore del demone Tailscale: `invalid key`.

Il processo mentale in questi casi deve isolare le variabili. La rete funzionava? Sì, il control plane era entrato. Il patching era corretto? Sì, la configurazione arrivava a destinazione. Il problema doveva risiedere nella natura della chiave stessa.

Consultando la documentazione delle API di Tailscale, ho analizzato il payload JSON che stavo inviando per generare la chiave. Inizialmente avevo impostato i flag `ephemeral: true` (per fare in modo che i nodi venissero deregistrati automaticamente se inattivi) e `reusable: false`. L'intento era di massima sicurezza: una chiave monouso per evitare abusi. 

Tuttavia, il design del mio script `create.sh` prevedeva di generare *una singola chiave per l'intero ciclo di bootstrap* e di condividerla tra tutti i nodi. Essendo `reusable: false`, non appena il control plane la utilizzava, la chiave veniva invalidata lato server. Quando il worker node, pochi istanti dopo, tentava di autenticarsi con la medesima chiave, Tailscale la rifiutava correttamente.

La soluzione è stata cambiare il flag in `reusable: true`, mantenendo l'ephemeralità. La chiave è valida solo per la durata del ciclo di bootstrap (con una scadenza forzata a breve termine), ma può essere utilizzata da *N* nodi in quella specifica finestra temporale. Questo ha risolto l'errore e ha portato entrambi i nodi nella Tailnet con i tag corretti (`tag:tazlab-k8s`), pronti per il futuro dialogo con Vault.

## La Fisica contro la Logica: Insegnare la pazienza a GitOps

Con il ponte Tailscale in funzione, il cluster era teoricamente pronto. Ma il vero collaudo, come stabilito dai prerequisiti, era il "One-Shot Rebirth". Lo script di orchestrazione non doveva solo tirare su le VM, ma doveva lanciare Terraform per installare i componenti base (come l'operatore GitOps FluxCD, MetalLB per gli IP e Longhorn per lo storage distribuito) e poi lasciare che Flux scaricasse i manifesti da GitHub per ricostruire l'intero parco applicativo.

Il One-Shot Rebirth esisteva già, ma l'introduzione di nuove logiche ha rivelato quanto potesse essere fragile di fronte ai tempi fisici dell'infrastruttura. 

### Il concetto di GitOps e l'Eventual Consistency

GitOps, operato nel mio caso da Flux, si basa sul principio della *Eventual Consistency* (coerenza eventuale). Dichiari lo stato desiderato in un repository Git, e l'operatore all'interno del cluster lavora in cicli continui (reconciliation loop) per far convergere lo stato reale verso quello desiderato. 

In teoria, questo modello è invulnerabile all'ordine di esecuzione. Se chiedo a Flux di creare un Deployment prima che esista il Namespace che lo deve contenere, il controller fallisce il primo tentativo, aspetta, e riprova. Quando il Namespace finalmente appare, il Deployment viene creato. 

Nella pratica, però, un bootstrap da zero (from scratch) stressa questo modello all'estremo. Lo script `create.sh` è uno strumento *imperativo* che innesca un processo *dichiarativo*. Il problema sorge quando lo strumento imperativo dichiara vittoria troppo presto, abbandonando il monitoraggio prima che l'ecosistema dichiarativo abbia realmente terminato il suo lavoro di assestamento.

### L'illusione della prontezza di rete (CNI)

Il primo sintomo di questa dicotomia è emerso con i fallimenti a catena delle `HelmRelease`. Flux iniziava a scaricare e applicare i chart Helm (come Traefik o External-Secrets), ma i pod andavano in timeout o restavano in stato `ContainerCreating`.

Un'analisi con `kubectl describe pod` ha rivelato l'intoppo: `failed to setup network for sandbox... plugin type="flannel" failed`.

Cosa stava succedendo? Terraform aveva completato la sua fase. I nodi Kubernetes venivano riportati come `Ready`. Lo script procedeva a innescare Flux. Flux chiedeva all'API server di programmare i pod. L'API server ordinava a `kubelet` di avviarli. Ma il CNI (Container Network Interface), nel mio caso **Flannel**, non aveva ancora finito di distribuire i pod sui nodi, di allocare le subnet e di configurare le regole `iptables`. I container nascevano in un vuoto pneumatico senza connettività di rete.

La soluzione non consisteva nel bloccare brutalmente lo script di bootstrap con cicli di attesa (un approccio "imperativo" e fragile), ma nell'insegnare la pazienza direttamente a Flux, adottando una strategia più "Enterprise". Ho modificato la `Kustomization` di base (quella che definisce i layer fondamentali) aggiungendo degli `healthChecks` nativi.

```yaml
  healthChecks:
    - apiVersion: apps/v1
      kind: DaemonSet
      name: kube-flannel
      namespace: kube-system
    - apiVersion: apps/v1
      kind: Deployment
      name: coredns
      namespace: kube-system
```

Questo approccio garantisce che quando l'orchestratore di alto livello (Flux) inizia a chiedere risorse per le Kustomization successive (come Traefik o External-Secrets), il layer fisico e logico di basso livello sia pronto a rispondergli, congelando a cascata l'intero albero delle dipendenze GitOps finché la rete non è effettivamente solida.

## Il Paradosso del Secret di Grafana nel Disaster Recovery

L'ultimo capitolo di questa indagine infrastrutturale ha riguardato un disallineamento puramente applicativo che emerge solo durante un disastro (reale o simulato).

Nel cluster, **Grafana** viene utilizzato per la visualizzazione delle metriche e richiede l'accesso a un proprio database ospitato su PostgreSQL. La gestione iniziale delle password avviene tramite Infisical. Un operatore `ExternalSecrets` si collega a Infisical, preleva la password statica (`GRAFANA_DB_PASSWORD`) definita a tavolino, e la inietta nel namespace `monitoring` sotto forma di Kubernetes Secret. Grafana si avvia leggendo questo secret.

Questo flusso funziona perfettamente al day-zero (il primissimo avvio assoluto). Ma il One-Shot Rebirth non è un day-zero; è un **Disaster Recovery**.

### La divergenza degli stati

Quando l'operatore PGO ripristina il cluster PostgreSQL attingendo ai backup su S3, non si limita a copiare i byte dei dati. Ripristina l'intero ecosistema logico del database, inclusi gli utenti e le loro credenziali crittografate, ricreando i Secret Kubernetes necessari nel namespace `tazlab-db` (dove risiede il database). 

Questa dinamica genera una divergenza di stato formidabile:
- Da un lato, nel namespace `monitoring`, c'è un `ExternalSecret` che forza la presenza di una password "vecchia" (quella di bootstrap su Infisical).
- Dall'altro lato, il database Postgres ripristinato contiene la password "nuova", ruotata in passato e storicizzata nel backup S3. L'operatore PGO, inoltre, ha appena emesso un Secret aggiornato nel namespace `tazlab-db`.

Risultato inevitabile: Grafana si avvia con la password di Infisical, tenta di loggarsi nel DB ripristinato, e viene respinto con un eloquente `pq: password authentication failed for user "grafana"`. Grafana entra in `CrashLoopBackOff`, il monitoring fallisce, il cluster non è completamente sano.

### La sincronizzazione post-restore come ponte verso Vault

Affrontare questo paradosso ha richiesto una decisione di design importante. Avrei potuto aggiornare manualmente Infisical con la nuova password, ma questo avrebbe violato il principio cardine della totale automazione. Oppure avrei potuto creare un ennesimo tool di sincronizzazione.

La verità è che questo specifico problema (un segreto che cambia ciclo dopo ciclo e deve essere propagato) è il sintomo esatto di un limite architetturale: **la dipendenza dai segreti statici**. Finché mi affido a Infisical nel suo tier gratuito, non ho la rotazione automatica e la gestione del ciclo di vita completo del segreto, ma solo la sua distribuzione.

Per sbloccare il One-Shot Rebirth, ho implementato una funzione `sync_runtime_secrets` all'interno dello script di bootstrap. Questa funzione ha un compito molto specifico: attende pazientemente che l'operatore PGO dichiari il completamento formale del restore (`PostgresDataInitialized=True`), dopodiché sopprime l'`ExternalSecret` fallace e lo sostituisce, iniettando la verità corrente catturata direttamente dal namespace del database.

```bash
sync_runtime_secrets() {
    echo "🔐 Syncing runtime-generated secrets needed after restore..."

    # 1. Attendi che il secret generato da PGO sia disponibile
    local secret_json
    until secret_json=$(kubectl get secret -n tazlab-db tazlab-db-pguser-grafana -o json 2>/dev/null) && [[ -n "$secret_json" ]]; do
        sleep 5
    done

    # 2. Rimuovi la gestione statica di Infisical per non sovrascrivere i dati
    kubectl delete externalsecret -n monitoring tazlab-db-pguser-grafana --ignore-not-found >/dev/null 2>&1 || true

    # 3. Trasforma il secret di PGO, cambia namespace e applica in 'monitoring'
    echo "$secret_json" | python3 -c '
import json, sys
obj=json.load(sys.stdin)
obj["metadata"]["namespace"]="monitoring"
obj["metadata"]["name"]="tazlab-db-pguser-grafana"
[obj["metadata"].pop(k,None) for k in ["uid","resourceVersion","creationTimestamp","managedFields","ownerReferences","annotations"]]
obj["metadata"].setdefault("labels",{})
obj["metadata"]["labels"]["synced-by"]="ephemeral-castle-create"
print(json.dumps(obj))
' | kubectl apply -f -

    # 4. Riavvia Grafana per forzare la rilettura del secret corretto
    kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana --ignore-not-found >/dev/null 2>&1 || true
    echo "  -> synced tazlab-db-pguser-grafana into monitoring namespace"
}
```

Questa manipolazione JSON in pipeline (effettuata con un piccolo inline di Python per garantire la corretta pulizia dei metadati Kubernetes originari) trasporta in sicurezza il segreto di Grafana dal namespace del DB a quello di monitoring. Il successivo riavvio brutale dei pod di Grafana li costringe a riavviarsi montando il Secret aggiornato. Il login ha successo e il monitoring torna operativo.

### La rivelazione architetturale

Il punto cruciale è che questa pezza tecnica non è una soluzione elegante, è un **workaround doloroso**. Mi ha costretto a scrivere logica imperativa (lo script Python per spostare il secret) per risolvere un limite del mio stack dichiarativo. 

Questo workaround è stata esattamente la scintilla che ha acceso l'intero progetto successivo. L'impossibilità di gestire nativamente e fluidamente credenziali database generate post-restore è la ragione precisa per cui ho deciso di abbandonare Infisical e istanziare il mio Vault personale. Inizialmente avevo progettato di ospitarlo su Oracle Cloud nel tier Always Free, ma come ho raccontato nell'articolo dedicato al "pivot" di Lushy Corp, i limiti di disponibilità e stabilità mi hanno spinto rapidamente a optare per un solido VPS su Hetzner.

Indipendentemente da dove si trovi fisicamente, l'obiettivo non cambia: con i **segreti dinamici** di Vault, non avrò più bisogno di script Python che spostano password. Vault inietterà dinamicamente un utente temporaneo dentro PostgreSQL ogni volta che Grafana (o qualsiasi altra app) ne farà richiesta, eliminando alla radice il problema dei segreti statici desincronizzati.

Questo hack su Grafana è, a tutti gli effetti, il ponte concettuale che ha reso imperativo portare a termine il bridge Tailscale-Talos.

## Conclusioni: Il Design ripaga sempre

Al termine di questa sessione di ingegnerizzazione, ho lanciato il test finale. Ho eseguito `./destroy.sh` in background, guardando le API di Proxmox polverizzare le macchine virtuali e cancellando ogni traccia dello stato locale. Immediatamente dopo, ho eseguito `./create.sh`.

Mi sono allontanato dal terminale.

Quattordici minuti dopo, lo script ha terminato l'esecuzione riportando il corretto ottenimento dell'indirizzo IP del LoadBalancer e l'avvenuto ripristino del database. Una verifica manuale sul cluster ha confermato un ambiente immacolato: nodi correttamente associati alla Tailnet, nessun segreto locale su disco, stack GitOps interamente convergente, volumi Longhorn agganciati, PostgreSQL in replica sana, e Grafana operativo. Zero interventi manuali.

Questo risultato dimostra per l'ennesima volta la validità del framework di lavoro che sto adottando. Il tempo investito nella progettazione teorica (la fase di Design) ha fatto in modo che, durante l'implementazione pratica, non si siano mai presentati problemi di tipo architetturale. Nessuno dei paradigmi (Tailscale su Talos, GitOps, backup remoto via S3) è stato messo in discussione. 

I problemi affrontati — l'autenticazione monouso, i timeout di rete, il disallineamento dei segreti di monitoring post-restore — sono stati esclusivamente di natura cronologica e integrativa. Bug operativi che, in un'architettura solida, si affrontano e si sconfiggono isolandoli metodicamente, trasformando un caotico fallimento a cascata in una prevedibile e ordinata rinascita. 

Il ponte è costruito. Il Castello Effimero è di nuovo in piedi e, grazie alla VPN mesh, è finalmente pronto a parlare, nel prossimo passo, con l'istanza isolata di HashiCorp Vault.
