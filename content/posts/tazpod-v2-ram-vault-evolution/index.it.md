---
title: "TazPod v2.0: La Resa a Root e la Rivoluzione della RAM"
date: 2026-02-06T22:43:00+01:00
draft: false
tags: ["Go", "Security", "Docker", "Zero Trust", "DevOps", "Cryptography", "Post-Mortem", "Linux"]
categories: ["Engineering", "Security"]
author: "Taz"
description: "Un post-mortem onesto sul fallimento dell'architettura 'Ghost Mode' basata su LUKS e Namespace. Analisi tecnica del passaggio a un sistema di RAM Vault volatile con crittografia AES-GCM e gestione multi-progetto."
---

# TazPod v2.0: La Resa a Root e la Rivoluzione della RAM

Nel mondo del DevOps e della Security Engineering, esiste una linea sottile tra l'architettura sicura e l'architettura inutilizzabile. Con **TazPod v1.0**, avevo costruito quello che sulla carta sembrava un capolavoro di isolamento: una "Ghost Mode" che sfruttava i Namespace Linux e i device LUKS per rendere i segreti invisibili persino ai processi concorrenti nello stesso container.

Oggi, con il rilascio della **v2.0**, documento ufficialmente il fallimento di quell'approccio e la completa riscrittura del core del sistema. Questa è la cronaca di come la stabilità operativa ha vinto sulla paranoica teorica, e di come ho imparato a smettere di combattere contro l'utente `root`.

## 1. Il Crollo della "Ghost Mode": Un Post-Mortem

L'ambizione della v1.0 era alta: utilizzare `unshare --mount` per creare uno spazio di mount privato all'interno del container, dove decriptare un volume LUKS (`vault.img`). L'idea era che, uscendo dalla shell, il namespace collassasse e i segreti svanissero.

### L'Instabilità dei Loop Device
Il primo segnale di cedimento strutturale è arrivato durante le sessioni di sviluppo intensivo. Il kernel Linux gestisce i *loop device* (i file montati come dischi) come risorse globali. All'interno di un container Docker — che è già un ambiente isolato e spesso "privilegiato" in modo precario per permettere queste operazioni — la gestione dei lock sui device mapper si è rivelata disastrosa.

L'errore `Failed to create loop device` o `Device or resource busy` è diventato una costante. Spesso, un container terminato in modo non pulito lasciava il file `vault.img` "appeso" a un loop device fantasma sull'host. Questo richiedeva un riavvio della macchina o interventi chirurgici con `losetup -d` che rompevano il flusso di lavoro.

### La Perdita di Dati (The Data Loss Event)
Il punto di rottura è stato un evento di corruzione del filesystem. LUKS e ext4 non amano essere terminati bruscamente. In due occasioni distinte, un crash del container ha lasciato il volume criptato in uno stato inconsistente ("dirty bit"), rendendo impossibile il remount.

Ho perso dati. E tra quei dati, ho perso sessioni preziose di **Mnemosyne** (la memoria a lungo termine della mia AI), che avevo imprudentemente deciso di salvare dentro il vault per "massima sicurezza". Questo evento mi ha costretto a riconsiderare l'intera strategia: **un sistema di sicurezza che rende i dati inaccessibili al proprietario legittimo è un sistema fallito.**

## 2. La Resa a Root: Analisi della Minaccia

Mentre lottavo per stabilizzare i mount point, ho dovuto affrontare una verità scomoda riguardante il modello di minaccia.

La "Ghost Mode" proteggeva i segreti da altri processi *non privilegiati*. Ma TazPod gira come container `--privileged` per poter effettuare i mount. Chiunque abbia accesso di root al container (o all'host) può banalmente usare `nsenter` per entrare nel namespace "segreto" o fare un dump della memoria RAM.

### Il Paradosso dell'Isolamento
Ho speso settimane a costruire un castello di carte con `unshare` e `mount --make-private`, solo per realizzare che stavo proteggendo i segreti da... me stesso. Un attaccante capace di compromettere l'host avrebbe comunque avuto accesso a tutto.

Ho deciso quindi di cambiare approccio: **accettare che Root vede tutto**. Invece di cercare di nascondere i dati a un utente onnipotente tramite l'isolamento del kernel, ho deciso di ridurre la finestra temporale e la superficie fisica in cui i dati esistono in chiaro.

## 3. Architettura v2.0: Il RAM Vault (tmpfs + AES-GCM)

La nuova architettura elimina completamente la dipendenza da `cryptsetup`, `dm-crypt` e dai loop device. Abbiamo spostato la sicurezza dal livello blocco (kernel) al livello applicativo (Go) e volatile (RAM).

### Storage: Il Formato `vault.tar.aes`
Invece di un filesystem ext4 criptato, ora i dati a riposo sono un semplice archivio TAR compresso e cifrato.

Per la crittografia, ho scelto **AES-256-GCM** (Galois/Counter Mode).
*   **Perché GCM?** A differenza della modalità CBC (Cipher Block Chaining), GCM offre la **crittografia autenticata**. Questo significa che il file non solo è illeggibile, ma è anche protetto da manomissioni. Se un bit del file cifrato su disco viene corrotto o alterato, la fase di decrittazione fallisce immediatamente con un errore di autenticazione, proteggendo l'integrità dei segreti.
*   **Derivazione della Chiave:** Utilizzo PBKDF2 con un salt casuale generato a ogni salvataggio per derivare la chiave AES dalla passphrase utente.

### Runtime: La Volatilità di `tmpfs`
Quando l'utente lancia `tazpod unlock`, la CLI non tocca il disco.
1.  **Mount:** Viene montato un volume `tmpfs` (RAM Disk) da 64MB su `/home/tazpod/secrets`.
    ```go
    // Codice interno per il mount volatile
    func mountRAM() {
        cmd := exec.Command("sudo", "mount", "-t", "tmpfs", 
            "-o", "size=64M,mode=0700,uid=1000,gid=1000", 
            "tmpfs", MountPath)
        cmd.Run()
    }
    ```
2.  **Decrypt & Extract:** Il file `vault.tar.aes` viene letto in memoria, decriptato on-the-fly e il flusso TAR risultante viene scompattato direttamente nel mount point in RAM.
3.  **Zero Trace:** Nessun file temporaneo viene mai scritto sul disco fisico dell'host.

### Ciclo di Vita: Pull, Save, Lock
La gestione della persistenza è stata completamente rivista per adattarsi alla natura effimera della RAM.

*   **`tazpod pull`:** Scarica i segreti da Infisical, li scrive nella RAM e innesca immediatamente un **Auto-Save**.
*   **Auto-Save:** La CLI legge ricorsivamente il contenuto della RAM, crea un nuovo TAR in memoria, lo cifra e sovrascrive atomicamente il file `vault.tar.aes` su disco.
*   **`tazpod lock` (o exit):** Il comando finale è brutale ed efficace: `umount /home/tazpod/secrets`. I dati svaniscono istantaneamente. Non c'è bisogno di sovrascritture sicure (`shred`), perché i bit non hanno mai toccato i piatti magnetici o le celle NAND.

## 4. Developer Experience: Risolvere le Frizioni

Oltre alla sicurezza, la v1.0 soffriva di problemi di usabilità che rallentavano il mio flusso di lavoro quotidiano.

### Il Problema della Collisione dei Nomi
Inizialmente, il nome del container era hardcoded (`tazpod-lab`). Questo impediva di lavorare su due progetti contemporaneamente (es. `tazlab-k8s` e `blog-src`).

Ho introdotto una logica di inizializzazione dinamica in `tazpod init`.
```go
// Generazione di un identificativo univoco per il progetto
cwd, _ := os.Getwd()
folderName := filepath.Base(cwd)
r := rand.New(rand.NewSource(time.Now().UnixNano()))
randomSuffix := fmt.Sprintf("%04d", r.Intn(10000))
containerName := fmt.Sprintf("tazpod-%s-%s", folderName, randomSuffix)
```
Ora, ogni cartella di progetto ha il suo container dedicato (es. `tazpod-backend-8492`), isolato dagli altri, con il proprio vault e la propria configurazione.

### Hot Reloading: Sviluppare la CLI nella CLI
Sviluppare TazPod *usando* TazPod presentava una sfida "Inception". Come testare la nuova versione della CLI senza dover ricostruire l'intera immagine Docker (che richiede minuti) ad ogni modifica?

Ho implementato un workflow di **Hot Reload**:
1.  Compilazione del binario Go sull'host (`task build`).
2.  Copia del binario in `~/.local/bin` (per l'uso host).
3.  Iniezione diretta nel container attivo:
    ```bash
    docker cp bin/tazpod tazpod-lab:/home/tazpod/.local/bin/tazpod
    ```
Questo ha ridotto il ciclo di feedback da 4 minuti a 3 secondi, permettendomi di iterare rapidamente sulla logica di crittografia e mount.

## 5. Mnemosyne: La Memoria Fuori dal Vault

Una delle lezioni più dure della v1.0 è stata la perdita delle sessioni AI. Per **Mnemosyne**, la persistenza è più importante della segretezza assoluta. Le chat con Gemini contengono contesto architetturale, non password.

Nella v2.0, ho deciso di **disaccoppiare** la memoria dell'AI dal vault dei segreti.
Durante la fase di `setupBindAuth`, la CLI crea un symlink strategico:
- **Host:** I log risiedono in `/workspace/.tazpod/.gemini` (sul disco dell'host, persistenti).
- **Container:** Vengono linkati in `~/.gemini`.

Questo garantisce che, anche se distruggo il vault o resetto il container, la "coscienza" del progetto sopravvive. I segreti (token API per parlare con Gemini) restano nel RAM Vault, ma i ricordi sono salvati su disco standard.

## Conclusioni: La Semplicità è una Feature di Sicurezza

TazPod v2.0 è, paradossalmente, tecnologicamente meno avanzato della v1.0. Non usa feature esoteriche del kernel, non manipola i namespace di rete o di mount in modi creativi. È solo un file criptato e un disco RAM.

Tuttavia, è infinitamente più robusto.
*   Non si rompe se Proxmox ha un load alto.
*   Non corrompe i dati se il container crasha.
*   È portabile su qualsiasi sistema Linux senza richiedere moduli kernel specifici per la crittografia.

Ho imparato che in DevOps, la complessità è spesso un debito tecnico travestito da "best practice". Ridurre la superficie di attacco ha significato, in questo caso, ridurre la complessità dell'architettura. Ora i miei segreti vivono in una bolla di sapone digitale (la RAM): effimera, fragile se toccata, ma perfettamente isolata finché esiste.

Il prossimo passo? Portare questa filosofia di "semplicità resiliente" nel cuore del cluster Kubernetes, dove Mnemosyne troverà la sua casa definitiva.

---
*Cronaca Tecnica a cura di Taz - Ingegneria dei Sistemi e Infrastrutture Zero-Trust.*
