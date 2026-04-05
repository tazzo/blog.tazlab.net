+++
title = "Golden Image runtime su Hetzner: il percorso fino alla versione finale"
date = 2026-04-06T14:00:00+00:00
draft = false
description = "Come ho portato a termine la mia prima pipeline completa per una golden image runtime su Hetzner, usando Ansible per la prima volta, con più cicli di validazione e una chiusura operativa pulita."
tags = ["hetzner", "golden-image", "ansible", "devops", "automation", "infrastructure", "linux", "testing"]
categories = ["Infrastructure", "DevOps"]
author = "Taz"
+++

## Obiettivo della sessione

L’obiettivo era semplice da descrivere ma non banale da chiudere bene: arrivare a una **golden image runtime stabile e riusabile** su Hetzner, pronta per essere consumata nella fase successiva della foundation.

In pratica volevo eliminare bootstrap pesanti a runtime e spostare il lavoro in build-time: preparare una VM builder, configurarla, validarla, congelarla in snapshot, poi verificare che da quello snapshot nascano macchine coerenti e prevedibili.

A livello di metodo ho imposto una regola operativa chiara: non fermarmi alla “prima volta che sembra funzionare”, ma chiudere il ciclo completo fino a una versione finale verificata su istanze fresche. Questo ha portato a più iterazioni (`v1` → `v4`), ma è stato il passaggio necessario per trasformare un risultato locale in un artefatto affidabile.

## Perché una golden image prima della foundation

Quando si costruisce una foundation infrastrutturale, mescolare provisioning, installazione pacchetti, hardening e bootstrap applicativo nello stesso momento crea un effetto domino difficile da diagnosticare. Se qualcosa fallisce, non è mai immediato capire se il problema è:

- nello strato di rete,
- nello strato di accesso,
- nello strato runtime,
- o in una race condition durante il bootstrap.

La golden image separa le responsabilità:

1. **Build-time**: preparo il runtime base una volta sola, in modo ripetibile.
2. **Deploy-time**: istanzio e convergo rete/foundation con meno variabili in gioco.

Questo approccio riduce la superficie di errore e rende più leggibile il troubleshooting. Non è solo una scelta “elegante”: è una scelta pratica quando vuoi consegnare una pipeline che regge anche le sessioni successive, non solo la demo del momento.

## Il profilo builder: scelta economica ma sufficiente

Un vincolo esplicito della sessione era usare il profilo più conveniente possibile, purché adeguato:

- **`cx23`**
- **4 GB RAM**
- **40 GB SSD**
- shared CPU

La scelta è stata mantenuta per tutte le iterazioni finali. Questo è importante perché evita di costruire una pipeline che funziona solo su tagli più costosi e poi degrada quando la riporti su profili realistici.

In altre parole, ho voluto verificare il comportamento nel perimetro economico reale del progetto, non in un ambiente “comodo”.

## Primo uso reale di Ansible nel mio flusso

Questa è stata la prima volta in cui ho usato **Ansible** in modo centrale nel mio processo, non come tool secondario. La differenza operativa è stata netta: passare da azioni manuali a una configurazione dichiarativa ripetibile.

Il playbook ha coperto la baseline runtime con:

- pacchetti necessari al runtime,
- modello utenti coerente (`admin` operativo, `vault` non interattivo),
- hardening SSH (password disabilitata),
- configurazioni di sistema minime ma deterministiche.

Esempio del cuore del playbook usato in build:

```yaml
- name: Configure Hetzner runtime golden image baseline
  hosts: builder
  become: true
  vars:
    runtime_packages:
      - podman
      - python3
      - curl
      - jq
      - ca-certificates
      - gnupg
      - apt-transport-https

  tasks:
    - name: Update apt cache
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600

    - name: Install runtime baseline packages
      ansible.builtin.apt:
        name: "{{ runtime_packages }}"
        state: present

    - name: Ensure admin user exists
      ansible.builtin.user:
        name: admin
        shell: /bin/bash
        groups: sudo
        append: true
        create_home: true
        state: present

    - name: Ensure vault service user exists (no login)
      ansible.builtin.user:
        name: vault
        shell: /usr/sbin/nologin
        create_home: false
        system: true
        state: present
```

Il valore pratico non è stato “Ansible in sé”, ma il fatto che ogni correzione entrava nel playbook e non restava workaround manuale dimenticato nella sessione successiva.

## Il ciclo di build e validazione

Il flusso operativo completo è stato:

1. create builder VM,
2. apply baseline con Ansible,
3. validazioni tecniche,
4. poweroff builder,
5. snapshot,
6. test su VM nuova da snapshot,
7. cleanup risorse transitorie.

Questo ciclo è stato ripetuto più volte fino a rimuovere tutte le incoerenze rilevate tra “builder funziona” e “istanza fresca funziona davvero”.

### Perché più snapshot (v1, v2, v3, v4)

È il punto più importante della sessione: la stabilità vera non si misura sul nodo che hai appena configurato, ma su una macchina nuova nata dall’artefatto.

Ogni iterazione ha eliminato un difetto pratico emerso solo al momento del re-test su istanza fresca. Alla fine, invece di tenere una catena di snapshot “quasi buoni”, ho scelto una politica più pulita:

- promuovere solo la versione finale valida,
- eliminare le versioni intermedie,
- fissare un ID unico di handoff.

## Il difetto più concreto: comportamento diverso tra utenti

Una parte della stabilizzazione è stata garantire che i comandi risultassero disponibili non solo in root ma anche nell’utente operativo.

Questo tipo di problema è tipico nelle pipeline immagine: installazioni apparentemente corrette ma legate a path utente o contesti shell differenti. La soluzione finale è stata rendere la pubblicazione del binario esplicita in un path di sistema (`/usr/local/bin`), così da uniformare la visibilità per root/admin nelle istanze create da snapshot.

La lezione qui è diretta: quando validi una golden image, non basta verificare “comando presente”. Devi verificare **presenza + esecuzione + utente target**.

## La parte che sembrava un bug immagine ma non lo era

In una fase avanzata ho visto test fallire con VM dichiarate `running`. Il sospetto iniziale può facilmente andare verso snapshot corrotto o bootstrap incompleto. In realtà il problema era diverso: connettività locale instabile nella rete di lavoro (hotspot), in particolare sul percorso IPv6 in alcune finestre temporali.

Questo ha un impatto pratico enorme sul debugging: puoi perdere ore a cambiare immagine quando il problema è nel path client→server.

Per evitare falsi positivi ho separato i due piani:

- qualità artefatto immagine,
- affidabilità del canale di test.

Da qui la decisione operativa finale per la pipeline test: default robusto IPv4 in contesti mobili, IPv6-only come modalità esplicita quando la rete locale è confermata.

## Hardening del test harness

Per chiudere bene la sessione non mi sono limitato a “test passato una volta”. Ho consolidato anche gli strumenti operativi.

Ho strutturato tre script principali:

- generazione inventory dinamico,
- build golden image end-to-end,
- test immagine con validazioni e cleanup.

Esempio di intent del test script (in forma sintetica):

```bash
./scripts/test-image.sh \
  --image-id 373384231 \
  --server-name lv-img-script-test-ipv4-final
```

Il punto chiave è che il test non si limita al ping SSH. Verifica esplicitamente i binari attesi su entrambi gli utenti operativi, e chiude il ciclo cancellando la VM di test al termine.

## Risultato finale

Artefatto finale promosso:

- **Snapshot name**: `lushycorp-vault-base-20260404-v4`
- **Image ID**: `373384231`

Criteri soddisfatti:

- baseline runtime applicata in modo ripetibile,
- validazione su istanza fresca,
- comportamento coerente per utente root/admin,
- test harness stabile con cleanup esplicito,
- nessuna VM lasciata attiva a fine run.

## Cosa mi porto via da questa tappa

Questa sessione non è stata solo “costruire un’immagine”. È stata una tappa di maturazione del processo.

Le cose che hanno fatto davvero la differenza:

1. **Separare build-time e deploy-time** per ridurre il rumore diagnostico.
2. **Usare Ansible come fonte di verità** della configurazione, non come supporto occasionale.
3. **Validare sempre su istanze nuove**, non fermarsi alla macchina builder.
4. **Distinguere bug infrastrutturale da bug di rete locale** prima di cambiare artefatto.
5. **Chiudere con cleanup rigoroso** per non inquinare il ciclo successivo.

Dal punto di vista operativo, la pipeline della golden image è ora in uno stato utilizzabile: non perfetta in astratto, ma sufficientemente deterministica per diventare input affidabile della fase foundation.

Ed è esattamente il tipo di risultato che cercavo: meno “script che funziona oggi”, più “processo che posso riaprire domani senza ricominciare da zero”.
