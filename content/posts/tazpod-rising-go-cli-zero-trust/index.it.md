---
title: "TazPod Rising: Dalle Ceneri di DevPod a una CLI Zero Trust in Go"
date: 2026-01-20T10:00:00+00:00
draft: false
tags: ["DevOps", "Go", "Security", "Docker", "Zero Trust", "Open Source", "Linux Namespaces"]
description: "Cronaca tecnica della creazione di TazPod: come il fallimento di un approccio 'convenience-first' ha portato allo sviluppo di un container blindato basato su Go, Linux Namespaces e crittografia LUKS."
---

## Introduzione: Il Momento della Fenice

Nel precedente episodio di questo diario tecnico, ho documentato il fallimento drammatico del tentativo di trasformare DevPod in una enclave Zero Trust. Il conflitto fondamentale tra l'architettura "Convenience-First" di DevPod e i miei requisiti di sicurezza ha portato a una conclusione inevitabile: dovevo abbandonare completamente lo strumento.

Tuttavia, come ogni ingegnere sa, il fallimento è spesso la madre dell'innovazione. Le ceneri di DevPod sono diventate il terreno fertile per qualcosa di nuovo: **TazPod**, una CLI personalizzata in Go progettata da zero per affrontare le sfide di sicurezza specifiche che DevPod non poteva gestire.

Questa è la storia di come ho costruito TazPod dalla v1.0 alla v9.9, trasformandolo dalla fragilità degli script Bash alla robustezza di Go, dai mount globali all'isolamento dei namespace, e dai compromessi di convenienza alla vera sicurezza Zero Trust.

---

## Fase 1: Le Fondamenta in Go - TazPod v1.0

La prima decisione tecnica è stata radicale: abbandonare l'idea di un ambiente che si autoconfigura "magicamente" via SSH. Avevo bisogno di determinismo.

### Il Ragionamento: Perché Go?

Dopo l'incubo degli script Bash in DevPod, avevo bisogno di un linguaggio con:
1.  **Tipizzazione forte** per prevenire errori a runtime.
2.  **Eccellente integrazione con Docker** attraverso l'SDK.
3.  **Compilazione cross-platform** per la futura portabilità.
4.  **Gestione robusta degli errori** senza la fragilità delle "trap" di Bash.

Go offre un vantaggio critico per un tool di questo tipo: l'accesso diretto alle syscall del sistema operativo e la capacità di compilare in un singolo binario statico.

### L'Architettura: Design Command-First

Ho strutturato TazPod attorno a un set centrale di comandi, gestiti da uno switch principale nel `main.go`. Questo approccio trasforma il container in un "Demone di Sviluppo". È lì, in attesa (`sleep infinity`), ma inerte. La magia avviene quando ci entriamo.

```go
// cmd/tazpod/main.go (Snippet della funzione up)
func up() {
    // ... caricamento configurazione ...
    runCmd("docker", "run", "-d", 
        "--name", cfg.ContainerName, 
        "--privileged", // Necessario per montare i loop device
        "--network", "host", 
        "-e", "DISPLAY="+display, 
        "-v", cwd+":/workspace", // Mount del progetto corrente
        "-w", "/workspace", 
        cfg.Image, 
        "sleep", "infinity") // Il container resta vivo in attesa
}
```

La prima implementazione era essenzialmente una traduzione diretta degli script Bash. Funzionava, ma soffriva ancora dello stesso problema di mount globale che affliggeva DevPod. Chiunque avesse accesso `docker exec` poteva vedere i segreti.

---

## Fase 2: La Svolta di Sicurezza - TazPod v2.0 (Ghost Edition)

Durante una revisione della sicurezza il 17 gennaio, ho identificato una falla critica: se sbloccavo il vault e un altro utente accedeva al container, poteva leggere tutti i segreti. La soluzione è arrivata da una fonte inaspettata: i **Linux Mount Namespaces**.

### Il Concetto: "Ghost Mode"

L'idea era rivoluzionaria: invece di montare il vault globalmente, creare un namespace isolato dove solo la sessione corrente potesse vedere i segreti montati.

In Linux, i mount point sono globali per namespace. Se creo un nuovo namespace di mount e monto un disco al suo interno, quel disco esiste *solo* per i processi che vivono in quel namespace. Per il processo padre (e per l'host), quel mount point è semplicemente una directory vuota.

### L'Implementazione: Magia di `unshare`

La chiave è stata usare `unshare -m` per creare un nuovo namespace di mount. Ecco cosa succede "sotto il cofano" quando un utente digita la password del vault:

1.  **Trigger**: L'utente lancia `tazpod pull`.
2.  **Fork & Unshare**: Il binario Go esegue se stesso con privilegi elevati usando `unshare`:
    ```bash
    sudo unshare --mount --propagation private /usr/local/bin/tazpod internal-ghost
    ```
3.  **Enclave Creation**: Il nuovo processo `internal-ghost` nasce in un universo parallelo di mount.
4.  **Decryption**: All'interno di questo universo, usiamo `cryptsetup` per aprire il file `vault.img` (montato via loop device) e montarlo su `/home/tazpod/secrets`.
5.  **Drop Privileges**: Una volta montato il disco, il processo "degrada" i suoi privilegi da root all'utente `tazpod` e lancia una shell Bash.

**Il Risultato**:
*   **Tu** (nella ghost shell): Vedi i segreti, usi kubectl, lavori normalmente.
*   **Intrusi** (in altre shell): Vedono una directory `~/secrets` vuota.
*   **Exit**: Quando esci, il namespace sparisce, portando con sé il mount.

---

## Fase 3: La Rivoluzione dell'IDE - TazPod v3.0

Con DevPod andato, ho perso l'esperienza integrata di VS Code. Ho deciso di abbracciare un **workflow puramente da terminale** con Neovim (configurazione LazyVim).

### L'Integrazione LazyVim

Ho investito tempo significativo per perfezionare il setup di Neovim direttamente nell'immagine Docker base. Volevo che l'IDE fosse pronto immediatamente, senza dover attendere il download dei plugin al primo avvio.

```dockerfile
# Installazione LazyVim e sync plugin headless
RUN git clone https://github.com/LazyVim/LazyVim ~/.config/nvim && \
    nvim --headless "+Lazy! sync" +qa && \
    nvim --headless "+MasonInstall all" +qa
```

**Il Risultato**: Un ambiente di sviluppo completo pronto in secondi, con Tree-sitter, LSP e tutti i plugin pre-compilati.

---

## Fase 4: La Battaglia per la Persistenza di Infisical

Risolto l'isolamento del filesystem, ho dovuto affrontare la gestione dell'identità. Uso **Infisical** per gestire i segreti centralizzati. Tuttavia, Infisical ha bisogno di salvare un token di sessione locale (solitamente in `~/.infisical`).

Se il container è effimero, ad ogni riavvio dovrei fare login. Inaccettabile. Se salvo il token su un volume Docker, è esposto in chiaro sull'host. Inaccettabile.

### L'Investigazione: Il Bug "Cannibale"

L'idea era semplice: spostare la cartella `.infisical` dentro il vault criptato e usare un bind-mount per farla apparire nella home utente solo quando il vault è aperto.

Durante l'implementazione in Go, ho incontrato un bug critico che ho soprannominato "Il Cannibale". La funzione di migrazione, pensata per spostare i vecchi token nel vault, aveva un difetto logico che portava alla cancellazione del contenuto se i percorsi coincidevano.

### La Soluzione: Il Bridge Blindato

Ho riscritto la logica implementando controlli rigorosi:

1.  **Check preliminare**: Verifico se il mount è già attivo leggendo `/proc/mounts`.
2.  **Doppio Bridge**: Monto sia la configurazione (`.infisical`) che il keyring di sistema (`infisical-keyring`) dentro il vault (`.infisical-vault` e `.infisical-keyring`).
3.  **Ownership Recursiva**: Un problema ricorrente era che i file creati durante il mount (da root) non erano leggibili dall'utente. Ho aggiunto un `chown -R tazpod:tazpod` forzato su tutta la struttura `.tazpod` ad ogni operazione di init o mount.

Ora, la sessione sopravvive ai riavvii, ma esiste fisicamente solo all'interno del file criptato `vault.img`.

---

## Fase 5: Da Hack a Prodotto (TazPod v9.9)

A questo punto, avevo un sistema funzionante ma grezzo. Per renderlo un vero strumento "Zero Trust" utilizzabile da altri, serviva una pulizia profonda e una standardizzazione.

### Standardizzazione e "Smart Init"

Ho introdotto il comando `tazpod init`. Invece di dover copiare manualmente file di configurazione, la CLI ora analizza la directory corrente e genera:
1.  Una cartella nascosta `.tazpod/`.
2.  Un `config.yaml` pre-compilato, permettendo di scegliere il "verticale" (base, k8s, gemini) tramite un argomento (es. `tazpod init gemini`).
3.  Un template di `secrets.yml` per mappare le variabili d'ambiente di Infisical.
4.  Un `.gitignore` che esclude automaticamente il vault e la memoria locale dell'AI (montata in `./.gemini` per persistere i ricordi del progetto).

### Il Problema della Collisione dei Nomi

Lanciando più progetti TazPod contemporaneamente, ho notato che Docker andava in conflitto sui nomi dei container (`tazpod-lab`). Ho implementato una logica di naming dinamico in Go nella versione v9.9:

```go
cwd, _ := os.Getwd()
dirName := filepath.Base(cwd)
 rng := rand.New(rand.NewSource(time.Now().UnixNano()))
containerName := fmt.Sprintf("tazpod-%s-%d", dirName, rng.Intn(9000000)+1000000)
```

Ora ogni progetto ha un'identità unica, permettendo di lavorare su più cluster o clienti in parallelo senza sovrapposizioni.

---

## Riflessioni Post-Sviluppo

Il passaggio da DevPod a TazPod è stato un esercizio di sottrazione. Ho rimosso l'interfaccia grafica, ho rimosso l'agente di sincronizzazione, ho rimosso l'astrazione SSH gestita.

In cambio, ho ottenuto:
1.  **Sicurezza Verificabile**: So esattamente dove risiede ogni byte di dati sensibili (nella RAM del processo Ghost).
2.  **Portabilità Totale**: Il progetto è autocontenuto. Basta avere Docker e il binario TazPod.
3.  **Velocità**: Senza overhead di agenti, l'avvio della shell è istantaneo una volta scaricata l'immagine.

### Il Progetto su GitHub

Ho deciso di rilasciare TazPod come progetto Open Source sotto licenza MIT. Non è solo uno script personale, ma un framework completo per chi, come me, vive nel terminale e non vuole compromessi sulla sicurezza.

L'installazione è ora ridotta a una singola riga:
```bash
curl -sSL https://raw.githubusercontent.com/tazzo/tazpod/master/scripts/install.sh | bash
```

Per maggiori dettagli tecnici e per consultare la documentazione completa del progetto, vi invito a visitare il repository ufficiale su GitHub: [https://github.com/tazzo/tazpod](https://github.com/tazzo/tazpod).


Il prossimo passo? Utilizzare TazPod per completare il refactoring Terraform del cluster TazLab, sapendo che le chiavi di accesso sono finalmente al sicuro.

