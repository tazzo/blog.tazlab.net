+++
title = "Una sessione infrastrutturale più tranquilla del solito: quando la progettazione riduce il caos"
date = 2026-04-08T06:00:00+00:00
draft = false
description = "Il diario tecnico del passo foundation su Hetzner con Tailscale: una build andata abbastanza liscia non per caso, ma grazie a ore di progettazione, scomposizione del problema e uso guidato degli LLM."
tags = ["hetzner", "tailscale", "ansible", "terraform", "devops", "llm", "automation", "infrastructure", "architecture"]
categories = ["Infrastructure", "DevOps", "Architecture"]
author = "Taz"
+++

# Una sessione infrastrutturale più tranquilla del solito: quando la progettazione riduce il caos

## Obiettivo della sessione

Questa tappa del progetto aveva un obiettivo molto preciso: chiudere il passo **foundation** della pipeline Hetzner, cioè arrivare a una macchina runtime capace di nascere da golden image, essere bootstrapata via SSH pubblico, entrare correttamente in Tailscale, spostare il piano operativo sul canale privato e dimostrare di convergere in modo ripetibile anche al secondo run.

Detto in forma più concreta, il target era il progetto `hetzner-tailscale-foundation`: non ancora Vault, non ancora lifecycle completo del servizio applicativo, ma il primo vero strato operativo su cui tutto il resto potrà appoggiarsi. Se questa base non è pulita, ogni fase successiva diventa rumorosa: quando qualcosa si rompe non capisco più se il problema è nel provisioning, nella rete, nei segreti, nel runtime, oppure nel servizio finale. Chiudere bene la foundation significa togliere ambiguità al resto del viaggio.

La cosa interessante è che questa sessione è stata relativamente tranquilla. Non perfetta, ma ordinata. Ci sono stati un paio di problemi reali, anche istruttivi, ma non è stata una maratona di caos. Ed è proprio questo il punto che voglio fissare: non è andata bene perché il problema fosse banale. È andata bene perché il lavoro più difficile era già stato fatto prima dell’implementazione.

## La parte invisibile che ha reso visibile la fluidità

Se guardassi solo l’ultima esecuzione potrei raccontarla così: ho lanciato la build, ho corretto alcuni dettagli di integrazione reale, ho validato il passaggio su Tailscale, ho verificato il rerun idempotente e ho chiuso con `destroy.sh`. Sarebbe un racconto corretto, ma incompleto. Il punto decisivo è che questa build non è nata da un “fammi questa infrastruttura” lanciato a un LLM sperando che tutto si componga da solo in modo elegante.

Prima di arrivare qui c’erano già state ore di discussione, ridefinizione del problema, chiarimento dei vincoli, review dei comportamenti reali di TazPod, correzione delle assunzioni sbagliate e soprattutto una scelta fondamentale: **spezzare il progetto in parti più piccole**. Prima la golden image, poi la foundation, solo dopo la convergenza Vault. Questa scomposizione ha abbassato drasticamente il numero di variabili attive in ogni fase.

È qui che la metodologia `CRISP` e il passaggio successivo in `crisp-build` hanno avuto valore reale. Non tanto come etichetta metodologica, ma come disciplina. Ho usato un contesto per progettare, discutere, correggere il piano e fissare i contratti. Solo dopo ho aperto il cantiere implementativo. Il beneficio pratico è stato enorme: quando qualcosa non tornava, la deviazione era leggibile. Non dovevo indagare un blob di provisioning+runtime+rete+Vault tutto insieme, ma un singolo gradino del sistema.

## Perché dividere in sottoprogetti cambia davvero il risultato

Questa è probabilmente la lezione più forte della sessione. Se avessi cercato di fare nello stesso momento golden image, foundation, bootstrap Tailscale, segreti e primo lifecycle di Vault, avrei ottenuto un classico effetto domino. Ogni errore avrebbe sporcato tutti i livelli sovrastanti, rendendo il troubleshooting ambiguo. Una VM che non risponde avrebbe potuto significare immagine difettosa, ACL sbagliata, playbook non idempotente, token di bootstrap errato, policy Tailscale incoerente o semplice rete locale instabile.

Separando invece il percorso in più passi, ho ottenuto l’opposto. La golden image era già stata chiusa e validata come gate autonomo. Questo significava che durante la foundation potevo trattare il runtime di base come affidabile, e concentrarmi solo su provisioning, bootstrap di rete e convergenza operativa. In termini di ingegneria è una riduzione fortissima della superficie di diagnosi. Non è solo “project management”: è riduzione concreta dell’entropia tecnica.

È la differenza tra lanciare un’operazione con dieci ipotesi aperte e lanciare un’operazione dove sette ipotesi sono già state chiuse prima. Quando poi compaiono problemi reali, come è successo qui, la loro natura è molto più leggibile. E infatti è esattamente quello che è successo.

## L’implementazione vera: creare una foundation pulita e verificabile

Il lavoro implementativo si è concentrato nel nuovo workspace sotto `ephemeral-castle/runtimes/lushycorp-vault/hetzner/`. Ho costruito lì tutti i pezzi necessari per la foundation:

- layer Terraform per VM, firewall bootstrap e output locali,
- baseline Ansible per la verifica runtime,
- ruolo Ansible per il bootstrap Tailscale,
- `create.sh` e `destroy.sh` con log separati per fase,
- helper script per inventory generation e validazione dei tag,
- sorgente di verità esplicita per la golden image approvata.

Questa scelta ha un significato preciso: il progetto non doveva dipendere da memoria implicita o da ID ricordati a voce. Se l’immagine approvata è `lushycorp-vault-base-20260404-v4` con ID `373384231`, quella informazione deve vivere in un file consumato davvero dagli script, non in una nota mentale o in una frase persa in un documento di design.

Il cuore del provisioning foundation è stato volutamente semplice. Terraform crea una VM da golden image approvata, apre solo il minimo necessario nel cloud firewall per la fase A e genera l’inventory pubblico da usare per il primo bootstrap. Ansible entra via SSH pubblico, verifica il modello utente, installa o controlla i componenti necessari e porta il nodo dentro Tailscale. A quel punto il sistema deve essere in grado di spostarsi sul piano privato e continuare a operare lì.

Un esempio molto rappresentativo del livello Terraform è questo:

```hcl
resource "hcloud_server" "foundation" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.image_id
  location    = var.location
  ssh_keys    = [var.ssh_key_name]
  firewall_ids = [
    hcloud_firewall.foundation_bootstrap.id,
  ]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  labels = merge(local.foundation_labels, {
    image_name = var.image_name
    image_id   = var.image_id
  })
}
```

Qui si vede bene il senso del passo: nessuna fantasia infrastrutturale, nessun layer opaco, solo il minimo indispensabile per generare una macchina coerente e tracciabile, con output utili ai passi successivi.

## I problemi che sono emersi erano problemi “buoni”

Il primo punto interessante è che i problemi emersi non hanno mai messo in discussione l’architettura complessiva. Questo non significa che fossero banali. Significa che erano **problemi di integrazione reale**, non segnali di un progetto sbagliato.

Il primo errore serio è apparso al momento del `tailscale up` sulla VM runtime. La macchina era stata creata correttamente, l’accesso iniziale via SSH funzionava, il daemon Tailscale si installava, ma il join falliva con un messaggio molto preciso: i tag richiesti non erano validi o non consentiti. Questo è esattamente il tipo di problema che una build live deve far emergere. Il design diceva correttamente che il nodo doveva entrare con `tag:tazlab-vault` e `tag:vault-api`. La realtà del control plane Tailscale diceva invece che l’OAuth client bootstrap non aveva ancora il modello di ownership giusto per assegnarli.

Questa diagnosi è stata importante perché ha mostrato la qualità del piano: non ho dovuto ripensare l’intera foundation, ho dovuto correggere un contratto reale tra bootstrap client e policy tailnet. Ho aggiornato l’ACL source of truth e la definizione dell’OAuth client in `ephemeral-castle/tailscale/`, applicando direttamente il fix sul tailnet reale. È un dettaglio apparentemente piccolo, ma dice molto: il progetto aveva bisogno di un allineamento del control plane, non di una riscrittura della pipeline.

## Il secondo problema: il nodo era online, ma SSH su Tailscale non passava

Dopo aver corretto il problema dei tag, il runtime entrava effettivamente in Tailscale e mostrava i tag attesi. Sembrava tutto risolto. Invece il passaggio successivo — Ansible via Tailscale — continuava a fallire. Questo è stato il punto più istruttivo dell’intera sessione, perché sulla carta il nodo era sano:

- `tailscale ping` rispondeva,
- il nodo compariva nel tailnet,
- i tag erano corretti,
- `sshd` era attivo,
- l’interfaccia `tailscale0` aveva il suo IP.

Eppure l’SSH al `100.x` andava in timeout.

Qui si è vista di nuovo la differenza tra caos e indagine leggibile. Il fatto che il peer fosse vivo ma il trasporto applicativo no mi diceva che non ero davanti a un fallimento globale di Tailscale. C’erano due possibilità: una ACL incompleta sul piano di controllo, oppure una particolarità del lato operatore. In realtà erano entrambe vere.

Da un lato mancava esplicitamente la porta `22` nel path ACL `tag:tazpod -> tag:tazlab-vault`. Questo era un errore reale di policy e andava corretto sulla tailnet. Dall’altro lato c’era un aspetto ancora più interessante: nel mio ambiente operatore locale Tailscale gira in **userspace-networking**, quindi `tailscale ping` può funzionare perfettamente anche se il sistema host non ha routing kernel diretto verso gli indirizzi `100.x`.

Questa distinzione è molto importante. Un uso superficiale degli strumenti avrebbe portato facilmente alla conclusione sbagliata: “Tailscale è su, quindi SSH al `100.x` dovrebbe funzionare”. Invece no. In userspace mode il mesh è sano, ma il percorso TCP dal sistema host può comunque richiedere un bridge esplicito.

## La correzione finale è stata piccola, ma molto istruttiva

La soluzione non è stata forzare il sistema locale a comportarsi come un nodo con routing kernel pieno, ma adattare il transport switch al contesto reale. Ho quindi cambiato la generazione dell’inventory Tailscale in modo che usasse `tailscale nc` come `ProxyCommand` SSH. In questo modo Ansible non dipende più dal fatto che il mio host locale sappia raggiungere direttamente il `100.x` a livello di stack di rete tradizionale: usa il canale userspace offerto dal daemon Tailscale locale.

È un fix piccolo, ma dal punto di vista del design è eccellente, perché rende il sistema più robusto rispetto all’ambiente operatore reale. Non sto scrivendo una foundation che funziona solo nel laboratorio ideale; sto chiudendo una foundation che funziona anche nel contesto concreto in cui oggi la sto usando.

La parte chiave dell’inventory generato è diventata questa:

```ini
[foundation_tailscale]
foundation-node ansible_host=100.83.183.124 ansible_user=admin ansible_ssh_private_key_file=/home/tazpod/secrets/ssh/lushycorp-vault/id_ed25519 ansible_ssh_common_args='-o ProxyCommand="tailscale nc %h %p" -o StrictHostKeyChecking=accept-new'
```

Questa riga racconta una lezione più ampia: i sistemi reali non falliscono sempre sui concetti grandi. Spesso falliscono nei punti di contatto tra un progetto ben pensato e un ambiente operativo con caratteristiche specifiche. La differenza la fa la capacità di leggere il problema senza generalizzare troppo in fretta.

## Il risultato finale: create, rerun, destroy

Una volta corretti questi dettagli, il progetto ha chiuso il suo obiettivo esattamente come previsto. Il `create.sh` è arrivato fino in fondo. La VM è nata dalla golden image, ha superato il bootstrap pubblico, è entrata nel tailnet come `lushycorp-vault-foundation`, ha mostrato i tag corretti, ha risposto sul path Tailscale e ha eseguito il baseline check via Ansible sul canale privato. Anche la verifica `podman --version` è passata senza sorprese.

Ancora più importante, il **rerun** ha confermato la sanità del piano. Terraform è andato in no-op, Tailscale non ha richiesto mutazioni inutili, e il sistema ha mostrato il comportamento che mi aspettavo da una foundation ben progettata: non solo “funziona una volta”, ma converge quando lo rilancio.

Infine ho eseguito anche `destroy.sh` e ho verificato il cleanup locale. Questo passaggio per me è essenziale. Un progetto infrastructure-as-code non è davvero chiuso quando crea una macchina: è chiuso quando sa anche rimuoverla in modo pulito, lasciando il workspace leggibile e pronto al ciclo successivo. È lì che si vede se la pipeline è solo una demo o un processo riapribile.

## La lezione sugli LLM è la parte più importante del post

Tutto questo conferma in modo molto concreto una cosa che avevo già intuito e scritto in altri momenti: gli LLM sono potenti, ma il risultato non dipende solo dalla loro capacità generativa. Dipende enormemente da **come vengono guidati**.

Se l’approccio è “fammi questa infrastruttura” e poi attendo che emerga un sistema ben fatto da una richiesta generica, il rischio è altissimo. Posso ottenere output plausibili, ma fragili, poco coerenti con il contesto reale, o costruiti su assunzioni non verificate. Un modello linguistico può produrre una quantità impressionante di materiale utile, ma non sostituisce automaticamente il lavoro di chiarificazione del problema.

Quello che questa sessione mostra è quasi l’opposto: quando l’operatore sa cosa sta costruendo, sa spezzare il problema, sa individuare i veri vincoli e usa l’LLM dentro una struttura disciplinata, il moltiplicatore cambia scala. Non è più un generatore di testo che prova a improvvisare un’infrastruttura. Diventa un acceleratore della capacità ingegneristica di chi lo sta guidando.

La formula più onesta che mi porto via è questa: **più chi usa l’LLM conosce il dominio, più il moltiplicatore si alza**. Se la comprensione è debole, il modello amplifica ambiguità. Se la comprensione è forte, il modello amplifica velocità, ampiezza di esplorazione e qualità dell’implementazione.

## Riflessioni post-lab

Questa tappa non è memorabile perché “non ci sono stati problemi”. I problemi ci sono stati, ed è giusto così. È memorabile perché i problemi erano del tipo giusto: piccoli, reali, leggibili e correggibili senza demolire il progetto. Questo è il segnale migliore possibile per una foundation.

La cosa più soddisfacente, in questa fase, non è aver portato su una VM su Hetzner con Tailscale. È aver verificato che la combinazione di progettazione preventiva, scomposizione del lavoro e uso guidato di un LLM produce un’esecuzione molto più fluida di quella che avrei ottenuto con un approccio più impulsivo o monolitico.

In fondo è proprio questo il senso di questa sessione: meno improvvisazione durante la build, più intelligenza prima della build. E quando questo accade, anche una tappa infrastrutturale complessa può diventare, finalmente, una sessione più tranquilla del solito.
