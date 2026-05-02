+++
title = "Blackout Test: Power Loss e Resurrezione del TazLab"
date = 2026-04-29T00:00:00+00:00
draft = false
tags = ["Kubernetes", "Talos OS", "Flux", "Longhorn", "Proxmox", "Disaster Recovery", "High Availability", "Home Lab", "Power Loss"]
description = "Un blackout improvviso ha spento il cluster TazLab. Riavvio manuale del PC, e in 10 minuti tutto era tornato operativo — quasi tutto. Ecco cosa ha funzionato, cosa no, e perché."
+++

## Il Momento del Panico

Apro il terminale, lancio `kubectl get nodes`, e niente. Timeout. Riprovo. Sempre niente.

Il primo pensiero è sempre lo stesso: "cosa ho rotto stavolta?". È un riflesso condizionato di chi gestisce un cluster home lab — ogni volta che qualcosa non risponde, la colpa è quasi sempre un mio esperimento finito male. Controllo l'IP del nodo, controllo il Proxmox, controllo il firewall. Niente.

Poi mi ricordo: ieri sera è saltata la corrente.

Ed è in quel momento che capisco: non ho rotto niente io. È stato il blackout. Ma c'è un secondo problema che non avevo considerato: il mini PC che ospita Proxmox non ha il riavvio automatico configurato. Il BIOS è impostato su "power off" dopo un'interruzione di corrente, non su "power on". Quindi la macchina era semplicemente spenta, in attesa che qualcuno premesse il pulsante.

Non era un guasto. Era l'assenza di un'infrastruttura che si riaccendesse da sola.

## Dieci Minuti di Attesa

Vado fisicamente al PC, premo il pulsante, e aspetto. Proxmox parte, le VM Talos si avviano, ed io mi siedo a guardare il terminale come si guarda un toast che non salta mai.

Dieci minuti dopo, tutto era su.

Non sto esagerando. I nodi Talos erano `Ready`, etcd aveva rieletto il leader, i controller Flux — kustomize-controller, helm-controller, source-controller — stavano riconciliando. I pod risalivano visibilmente: prima cert-manager e Traefik, poi External Secrets, poi le applicazioni. Il blog, il wiki, il database PostgreSQL, Mnemosyne — tutto funzionante. Non ho digitato un singolo `kubectl` per sistemare le cose. Il cluster si è ripreso da solo, esattamente come era stato progettato.

Flux ha un comportamento che ho imparato ad apprezzare in questo frangente: guarda il repository Git, legge tutte le Kustomization, e le applica in ordine di dipendenza. Prima i namespace, poi gli operatori, poi le configurazioni, poi le applicazioni. È un DAG (Directed Acyclic Graph) dichiarativo. Quando è partito dopo il reboot, ha semplicemente ripetuto lo stesso processo del bootstrap iniziale — solo che questa volta i nodi c'erano già, il database era già stato recuperato, e le immagini erano già in cache. È stato veloce.

## Quasi Tutto: I Volumi Che Non Ce L'Hanno Fatta

Quando dico "quasi tutto", parlo di Longhorn.

Dei cinque volumi gestiti da Longhorn, uno era sano — il database PostgreSQL — e gli altri quattro erano in stato `faulted`. Il database è sopravvissuto perché PostgreSQL usa il Write-Ahead Log (WAL): quando si riavvia dopo uno spegnimento brusco, rilegge il log delle transazioni e recupera tutto ciò che era stato confermato prima del crash. È una protezione vecchia di decenni, e funziona.

Gli altri volumi — Prometheus, pgAdmin, la configurazione di OpenClaw — non hanno questa protezione. Con Longhorn configurato a una singola replica, non c'era una seconda copia sana da promuovere al posto di quella corrotta dallo spegnimento improvviso.

Questo non è un bug di Longhorn. È una conseguenza diretta dell'architettura: ho un singolo host fisico che simula un cluster. Longhorn gestisce il ciclo di vita dei volumi attraverso due componenti: l'**engine**, che espone il volume come dispositivo a blocchi, e le **repliche**, che conservano i dati su disco. Dopo un power loss, l'engine prova a ripartire, ma se l'unica replica disponibile ha un timestamp di fallimento, si ferma. Con più repliche, Longhorn sceglie quella più recente e sana, e ricostruisce le altre.

In un vero cluster con tre nodi e due repliche per volume, un nodo che si spegne non causa la perdita del dato — le altre repliche continuano a funzionare, l'engine viene spostato su un nodo sano, e il volume resta accessibile. Qui, con una sola macchina fisica, non c'è spazio per questa ridondanza.

La domanda giusta da farsi non è "perché Longhorn ha fallito?", ma "perché PostgreSQL ha funzionato?". La risposta è il Write-Ahead Log: ogni transazione viene scritta prima su un log sequenziale e solo dopo applicata ai dati. Un crash improvviso significa che all'avvio PostgreSQL rilegge il log, trova l'ultimo checkpoint valido, e recupera — o scarta — le transazioni non ancora completate. Longhorn non ha questo livello di protezione a livello di volume: se l'engine si ferma mentre sta scrivendo, la replica può rimanere in uno stato inconsistente.

## Perché Ha Funzionato (Quasi) Tutto

Il risultato più importante di questo evento non è quello che si è rotto, ma quello che ha retto.

Talos Linux, il sistema operativo immutabile dei nodi, è ripartito senza interventi. etcd ha ricostruito il quorum. Flux ha letto lo stato desiderato dal repository Git e lo ha riconciliato senza che io dovessi fare nulla. Le applicazioni stateless (blog, wiki) erano su e funzionanti in pochi minuti. Il database PostgreSQL ha ripreso a servire query dopo aver recuperato il suo WAL.

Questa è la dimostrazione pratica che l'architettura a tre strati che ho costruito funziona:

- **Talos** gestisce il sistema operativo, immutabile e auto-recuperante
- **Flux** gestisce lo stato desiderato, sempre allineato al repository Git
- **Longhorn** gestisce lo storage, ma paga lo scotto della configurazione minima

Il cluster non aveva bisogno di me per ripartire. Aveva solo bisogno che il PC venisse riacceso.

## Il Salvataggio di Prometheus

C'è un'altra storia in questa storia. Prometheus aveva dieci giga di metriche storiche intrappolate in un volume faulted. Avrei potuto cancellare tutto e ricrearlo da zero — ma ho deciso di provare un salvataggio manuale.

Su Longhorn, quando un volume va in `faulted` con `auto-salvage: true`, il sistema tenta automaticamente il recupero. Con una sola replica, però, non c'è una copia sana da confrontare, e il salvataggio automatico fallisce. Ma se i dati sulla replica sono effettivamente consistenti e il problema è solo il flag di fallimento, si può intervenire manualmente.

Ho scalato lo StatefulSet di Prometheus a zero, ho rimosso i campi `failedAt` e `lastFailedAt` dalla replica Longhorn, e ho impostato il `nodeID` del volume. L'engine è ripartito, il volume si è riattaccato, e ho riscalato il pod. Tutte le metriche — dieci giga di storia — erano intatte.

Per i volumi di pgAdmin e OpenClaw non ho tentato nemmeno il salvataggio. Erano dati sacrificabili — configurazione locale e workspace — e la procedura corretta per dati non critici dopo un fault è: buttare via, ricreare, andare avanti. Flux si è occupato di ricreare i PVC nuovi e puliti.

## La Lezione

Questo evento mi ha insegnato tre cose.

La prima è che l'architettura che ho progettato per il TazLab — Talos + Flux + Longhorn — regge uno spegnimento non programmato meglio di quanto mi aspettassi. Non è un cluster enterprise, ma si comporta come tale per la maggior parte dei carichi di lavoro.

La seconda è che la configurazione a singola replica di Longhorn è il punto debole. Funziona benissimo per un laboratorio dove i dati si possono buttare, ma è proprio lì che si manifesta il problema quando il nodo si spegne male. È una scelta consapevole: ho un solo host fisico, e due repliche sullo stesso disco non danno vera resilienza.

La terza è che l'auto-power-on del BIOS non è un dettaglio da trascurare. Il cluster ha retto benissimo, ma non poteva ripartire da solo perché il PC era fisicamente spento. Un dettaglio così banale ha reso necessario un intervento manuale, mentre tutto il resto — Talos, etcd, Flux, i pod — si sarebbe ripreso autonomamente.

## Conclusioni

Un blackout è il test definitivo per un'infrastruttura. Non puoi imbrogliare: o il cluster si riprende da solo, o non lo fa. Il TazLab si è ripreso. Non perfettamente — i volumi faulted lo dimostrano — ma abbastanza bene da convincermi che la direzione di progettazione è quella giusta.

Se il TazLab fosse un cluster enterprise con cinque o più nodi, questo blackout sarebbe stato un non-evento. I nodi Talos sarebbero ridondanti, etcd avrebbe avuto tre o cinque membri, i volumi Longhorn avrebbero avuto repliche su nodi diversi, e il carico di lavoro si sarebbe spostato automaticamente. Non avrei nemmeno notato il problema — avrei visto qualche pod rischedulato e basta.

Ma il TazLab non è un cluster enterprise. È un laboratorio su un singolo mini PC che simula un cluster. E in questo contesto, il test è stato superato. Il cluster ha fatto tutto quello che poteva fare, e lo ha fatto bene. Il limite non è nell'architettura — è nell'hardware, ed è una scelta consapevole.

La prossima volta che salterà la corrente, però, il PC si riaccenderà da solo. Ho già aggiunto il debito tecnico (TD-023) per ricordarmi di configurare quella dannata impostazione del BIOS.
