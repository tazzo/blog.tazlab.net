---
title: "Proteggere la Chiave di Volta di TazLab: Backup Storici su S3 con TazPod"
date: 2026-05-21T11:00:00+02:00
draft: false
tags: ["Go", "Security", "S3", "Backup", "Cryptography", "DevOps"]
categories: ["Engineering", "Infrastructure"]
author: "Taz"
description: "Come gestire la retention e lo storico di un archivio cifrato con AES-GCM su S3 senza sprecare chiamate API. Il trucco del plaintext hash sidecar applicato al Vault di TazLab."
---

# Proteggere la Chiave di Volta di TazLab: Backup Storici su S3 con TazPod

Nel design di un'infrastruttura auto-ospitata (*homelab* o *private cloud* che sia), la gestione delle chiavi di cifratura iniziali è un classico problema dell'uovo e della gallina. Se tutto l'ecosistema è cifrato, dove si conservano le chiavi che servono per decifrarlo al boot? 

In TazLab, la risposta a questa domanda è il **Vault** di TazPod. Prima di proseguire, è importante chiarire un dettaglio terminologico fondamentale: in questo contesto, per "Vault" non intendiamo un server HashiCorp Vault attivo e raggiungibile in rete (che pure utilizziamo all'interno del cluster Kubernetes). Parliamo invece del **pacchetto cifrato di credenziali** (`vault.tar.aes`) gestito dal nostro CLI tool TazPod. 

Questo archivio contiene le chiavi root, i seed di cifratura e le credenziali di bootstrap necessarie per configurare la rete Tailscale, sbloccare i nodi Talos e recuperare i database da zero. Se l'intera infrastruttura fisica dovesse essere rasa al suolo, la combinazione di questo singolo file cifrato e dei backup distribuiti su S3 permetterebbe all'intero sistema di rinascere da zero. È, a tutti gli effetti, la chiave di volta di TazLab.

Oggi documento come ho evoluto questo meccanismo di backup implementando una politica di retention sicura e ottimizzata dal punto di vista dei costi API S3 su TazPod v0.3.31 e v0.3.32.

---

## 1. Il Rischio del Backup a Singolo File

Fino alla versione precedente di TazPod, il comando `tazpod push vault` si limitava a caricare l'archivio cifrato su S3 sovrascrivendo la chiave fissa `tazpod/vault/vault.tar.aes`. 

Questo approccio presentava un rischio operativo inaccettabile in una strategia di *disaster recovery*: **la corruzione dell'ancora di salvezza**. Se una modifica locale errata o un dump parziale avesse corrotto il database delle chiavi locale e io avessi eseguito il push (o se il demone di sincronizzazione automatica lo avesse fatto in background), avrei sovrascritto l'unico backup valido su S3. In quel momento, l'intera infrastruttura sarebbe diventata irrecuperabile.

La soluzione ovvia era implementare una politica di *retention* basata sullo storico delle versioni. La scelta architetturale è caduta su un modello a **50 versioni storiche** ordinate per timestamp:
*   La versione più recente viene copiata in `tazpod/vault/vault.tar.aes` per fungere da puntatore statico rapido.
*   Ogni singola operazione di push genera in parallelo una copia archiviata con percorso `tazpod/vault/history/vault-<TIMESTAMP>.tar.aes`.
*   Un processo di *pruning* automatico e asincrono mantiene il conteggio complessivo della cartella `history/` limitato a $N=50$ elementi.

---

## 2. La Sfida Crittografica: Cifratura Non Deterministica e API S3

L'implementazione dello storico ha sollevato un problema di efficienza delle chiamate S3. Il Vault viene protetto localmente tramite cifratura **AES-256-GCM**. 

Per motivi di sicurezza, la cifratura in modalità GCM (Galois/Counter Mode) richiede un vettore di inizializzazione (*Initialization Vector* o *nonce*) casuale e univoco per ogni singola operazione di cifratura. Questo significa che, anche se i file in chiaro contenuti nel Vault rimangono rigorosamente identici, cifrare lo stesso archivio due volte in momenti diversi produce due file binari con hash SHA256 completamente differenti.

```
Plaintext (Vault Identico) 
   │
   ├──> Cifratura T1 (Nonce A) ──> vault.tar.aes (Hash: 3a9f...)
   │
   └──> Cifratura T2 (Nonce B) ──> vault.tar.aes (Hash: f82c...)
```

Se il demone di sincronizzazione automatica di TazPod si fosse limitato a confrontare l'hash del file cifrato locale con quello presente su S3, avrebbe rilevato una differenza ad ogni singolo ciclo (di default 5 minuti). Di conseguenza:
1.  Avrebbe eseguito un upload su S3 ad ogni ciclo, consumando banda inutile.
2.  Avrebbe saturato rapidamente la retention a 50 copie con duplicati identici nel contenuto, cancellando le vere versioni storiche precedenti.
3.  Avrebbe generato costi superflui di scritture S3 API.

---

## 3. Il Trucco del Plaintext Hash Sidecar

Per risolvere questo vincolo crittografico, ho implementato il pattern del **Plaintext Hash sidecar**. 

Prima che TazPod esegua la cifratura dell'archivio, calcola lo SHA256 in chiaro del solo archivio tar non cifrato. Questo hash, che è deterministico al 100% poiché dipende esclusivamente dal contenuto dei segreti, viene salvato localmente in un file sidecar chiamato `last-content.hash`.

Durante l'esecuzione di `pushVaultInternal()`, TazPod segue questo flusso logico:

1.  Legge l'hash in chiaro locale da `last-content.hash`.
2.  Esegue una chiamata rapida `HeadObject` su S3 per verificare i metadati del file `vault.tar.aes` attualmente registrato sul cloud.
3.  Nel `HeadObject` recupera un metadato personalizzato denominato `content-sha256`, che contiene l'hash del plaintext registrato al momento del caricamento.
4.  Se l'hash locale e quello restituito da S3 coincidono, TazPod interrompe l'operazione stampando nei log:
    `Vault unchanged, skipping push`

In questo modo, se il Vault non subisce modifiche reali da parte dell'operatore, il demone di sincronizzazione effettua solo chiamate `HEAD` di lettura (estremamente economiche e veloci) ed evita del tutto le chiamate di scrittura `PUT` e la creazione di copie storiche duplicate.

Ecco lo snippet Go che implementa questo controllo:

```go
if contentHash != "" {
    lastMeta, headErr := s3.HeadObject("tazpod/vault/vault.tar.aes")
    if headErr == nil {
        if lastHash, ok := lastMeta["content-sha256"]; ok && lastHash == contentHash {
            slog.Info("Vault unchanged, skipping push")
            return nil
        }
    }
}
```

---

## 4. Diagnosi Tecniche e Lezioni Apprese

Durante il ciclo di build e test, due bug significativi hanno richiesto un intervento metodico.

### L'inganno del confronto nullo (Il Bug `"" == ""`)
Nella prima versione del codice di skip, non avevo utilizzato l'idioma `ok` per verificare l'esistenza della chiave nella mappa dei metadati di `HeadObject`. La riga originaria era semplicemente:
`if lastMeta["content-sha256"] == contentHash`

Al primo avvio dopo l'aggiornamento del software, il metadato su S3 non esisteva ancora (poiché il vecchio archivio era stato caricato senza metadati), restituendo una stringa vuota `""`. Allo stesso modo, in assenza del file sidecar locale, `contentHash` valeva `""`. Il confronto `"" == ""` restituiva `true`, facendo saltare silenziosamente il primo push di configurazione. L'introduzione della verifica sull'esistenza del metadato (`ok`) ha risolto il falso skip.

### Il Bug della configurazione orfana (v0.3.32)
Dopo il deploy iniziale, la cancellazione accidentale del file `config.yaml` su un container di test ha innescato un comportamento anomalo: l'assenza del file configurava la retention delle copie storiche a `0` a causa di un ritorno anticipato (*early return*) non gestito correttamente nella funzione `loadConfigs()`. Una retention a zero indicava al sistema di eliminare *tutte* le copie archiviate su S3 ad ogni push.

La correzione ha previsto l'applicazione dei valori di default a livello di inizializzazione della struct di configurazione, garantendo che anche in caso di file mancanti o errori di parsing minori, la retention non scenda mai sotto il valore di sicurezza di 50 copie.

---

## Conclusioni

L'evoluzione del backup di TazPod dimostra come l'ottimizzazione dell'infrastruttura richieda spesso di guardare oltre la semplice automazione. L'introduzione del plaintext hash sidecar ci permette di dormire sonni tranquilli grazie alla retention storica su S3, senza dover pagare un tributo economico e di performance in chiamate API ridondanti dovute alla natura non-deterministica della crittografia AES-GCM.
