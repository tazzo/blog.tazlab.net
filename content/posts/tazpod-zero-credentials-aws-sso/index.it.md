+++
title = "Zero Credenziali sul Disco: Riscrivere TazPod con AWS IAM Identity Center"
date = 2026-03-22T19:43:22+00:00
draft = false
description = "Cronaca tecnica della migrazione completa di TazPod da Infisical ad AWS SSO: rimozione del codice legacy, implementazione del bootstrap vault-S3, sei bug scoperti in produzione e un CI/CD ricostruito da zero."
tags = ["aws", "iam-identity-center", "sso", "s3", "devops", "tazpod", "secrets-management", "golang", "docker", "ci-cd", "github-actions", "security"]
author = "Tazzo"
+++

# Zero Credenziali sul Disco: Riscrivere TazPod con AWS IAM Identity Center

## Introduzione: Il Problema che Non Riuscivo a Risolvere

Nel [precedente articolo su questo progetto](/posts/bootstrap-from-zero-vault-s3-rebirth/) ho descritto la visione architetturale: rimpiazzare Infisical con AWS IAM Identity Center come ancora del bootstrap, eliminare ogni credenziale statica dall'immagine Docker di TazPod, e rendere l'intero ciclo di rinascita riproducibile da una macchina vuota con solo un bucket S3, una passphrase e un dispositivo MFA.

Quella era la progettazione. Questo articolo racconta l'implementazione — quattro ore di lavoro che hanno prodotto TazPod 0.3.12, undici versioni di build, sei bug distinti scoperti esclusivamente durante il test live sul sistema reale, e un CI/CD pipeline ricostruito iterativamente.

---

## Fase 1: La Rimozione Chirurgica di Infisical

Il punto di partenza era `cmd/tazpod/main.go` — 613 righe, circa un terzo delle quali dedicate esclusivamente all'integrazione Infisical. La tentazione in questi casi è fare una rimozione graduale, lasciando rami di compatibilità o wrapper deprecati. Ho resistito deliberatamente a quella tentazione.

Il principio che ho applicato si chiama **Design Integrity**: il codice deve dire la verità su quello che fa il sistema. Ogni riga di codice Infisical lasciata compilabile — anche commentata, anche con un deprecation warning — è una menzogna raccontata al prossimo lettore. La rimozione deve essere totale o non è una rimozione.

Ho eliminato: le struct `SecretMapping` e `SecretsConfig`, la variabile globale `secCfg`, le costanti `SecretsYAML` e `EnvFile`, le funzioni `pullSecrets()`, `login()` (versione Infisical), `runInfisical()`, `runCmd()`, `checkInfisicalLogin()`, `loadEnclaveEnv()`, `resolveSecret()`, e il metodo `isMounted()` locale (duplicato di `utils.IsMounted`). Sono sparite anche le dipendenze `bytes` e `strings` dagli import, rimaste orfane.

Il risultato è stato un file di 250 righe invece di 613. Il compilatore ha confermato la pulizia al primo tentativo.

La stessa operazione in `internal/vault/vault.go` è stata più delicata. Le costanti Infisical (`InfisicalLocalHome`, `InfisicalKeyringLocal`, `InfisicalVaultDir`, `InfisicalKeyringVault`) erano usate da `setupBindAuth()` e da `Lock()`. Le ho rimpiazzate con le equivalenti AWS:

```go
const (
    AwsLocalHome = "/home/tazpod/.aws"
    AwsVaultDir  = MountPath + "/.aws"
    PassCache    = MountPath + "/.vault_pass"
)
```

La funzione `setupBindAuth()` ora crea un bind mount dalla directory AWS nella RAM tmpfs verso `~/.aws` nel container. Il meccanismo è identico a quello che usava per Infisical — un bind mount che rende la directory RAM indistinguibile da una directory normale per qualsiasi processo, incluso l'AWS CLI e il Go SDK.

---

## Fase 2: Il Symlink `~/.aws` — Due Implementazioni Prima di Quella Giusta

La prima implementazione del symlink per la configurazione AWS è stata un errore di granularità. Ho scritto in `SetupIdentity()` (vault.go) il codice per symlinkare il *file* `~/.aws/config` verso `/workspace/.tazpod/aws/config`. Era sbagliato per tre ragioni: symlinkavo un file invece di una directory, usavo il nome `aws` senza il punto iniziale (incoerente con il pattern degli altri tool), e l'avevo messo in Go invece che in `.bashrc`.

Il pattern corretto già esisteva nel `.bashrc` per quattro altri strumenti: `.pi`, `.omp`, `.gemini`, `.claude`. Ogni directory di tool viene symlinkava dalla workspace verso la home: `~/.pi → /workspace/.tazpod/.pi`, e così via. La logica è nel `.bashrc` perché viene eseguita ad ogni shell, garantendo la ricreazione dei symlink anche dopo un `lock` che smonta il tmpfs.

Per `~/.aws` c'era però una complessità aggiuntiva che gli altri tool non avevano: quando il vault è sbloccato, `setupBindAuth()` esegue `rm -rf ~/.aws` e lo rimpiazza con un bind mount dalla RAM. Se il loop generico del `.bashrc` girasse in una nuova shell con il vault già aperto, distruggerebbe il bind mount attivo.

La soluzione è stata un guard esplicito con `mountpoint -q`:

```bash
# AWS config: symlink ~/.aws -> /workspace/.tazpod/.aws
# Skip if already bind-mounted from the vault enclave (vault unlocked)
if ! mountpoint -q "$HOME/.aws" 2>/dev/null; then
    mkdir -p /workspace/.tazpod/.aws
    if [ ! -L "$HOME/.aws" ] || [ "$(readlink "$HOME/.aws")" != "/workspace/.tazpod/.aws" ]; then
        rm -rf "$HOME/.aws" && ln -sf /workspace/.tazpod/.aws "$HOME/.aws"
    fi
fi
```

Se `~/.aws` è un mountpoint (vault sbloccato) il blocco viene saltato. Se non lo è (vault bloccato, o prima apertura), il symlink viene creato o ricreato. Il bind mount del vault e il symlink della workspace coesistono senza conflitti, servendo due stati operativi distinti.

---

## Fase 3: Il Bug del Go AWS SDK con i Profili SSO

La funzione `NewS3Client` nel package `utils` accettava solo il nome del bucket. Ho aggiunto un secondo parametro per il profilo SSO:

```go
func NewS3Client(bucket, profile string) (*S3Client, error) {
    opts := []func(*config.LoadOptions) error{
        config.WithRegion(DefaultRegion),
    }
    if profile != "" && os.Getenv("AWS_ACCESS_KEY_ID") == "" {
        opts = append(opts, config.WithSharedConfigProfile(profile))
    }
    cfg, err := config.LoadDefaultConfig(context.TODO(), opts...)
    ...
}
```

La condizione `os.Getenv("AWS_ACCESS_KEY_ID") == ""` non è ovvia e merita una spiegazione. Durante il testing ho scoperto che passare `WithSharedConfigProfile` al Go AWS SDK causa un hang di 30+ secondi quando `AWS_ACCESS_KEY_ID` è già nell'ambiente. Il SDK cerca comunque di *caricare la configurazione* del profilo SSO — incluso un tentativo di contattare l'endpoint SSO per validare o rinfrescare i token — indipendentemente dal fatto che le credenziali statiche siano già disponibili.

La credential chain del Go SDK v2 dà priorità alle variabili d'ambiente rispetto alle credenziali del profilo. Ma il caricamento della configurazione del profilo (regione, endpoint, parametri SSO) avviene comunque se `WithSharedConfigProfile` viene passato. Saltare il profilo quando le env var sono presenti è la soluzione corretta: le credenziali statiche hanno già tutto ciò che serve.

Questo bug non si manifesta mai in ambiente di produzione — dove non ci sono credenziali statiche e il profilo SSO è l'unica fonte — ma è critico per il testing e per le situazioni di fallback.

---

## Fase 4: AWS IAM Identity Center — Setup Guidato

Il setup di IAM Identity Center è stato interattivo: l'ho fatto in collaborazione, passaggio per passaggio dalla AWS Console. I punti non ovvi che vale la pena documentare:

**La regione è us-east-1, non eu-central-1.** Anche se ho configurato IAM Identity Center dalla console di eu-central-1, il portale SSO viene creato in us-east-1. L'URL del portale — `https://ssoins-7223c4f9117b4c94.portal.us-east-1.app.aws` — contiene esplicitamente la regione. Configurare `sso_region = eu-central-1` nel profilo AWS ha prodotto `InvalidRequestException: Couldn't find Identity Center Instance`. La correzione è stata immediata una volta identificata la causa.

**Il permission set TazLabBootstrap segue il Principle of Least Privilege.** La policy inline permette solo le tre operazioni strettamente necessarie, sul singolo bucket e sul singolo prefisso:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::tazlab-storage",
      "arn:aws:s3:::tazlab-storage/tazpod/vault/*"
    ]
  }]
}
```

Nessun accesso ad altri bucket. Nessuna operazione di gestione. Se questo profilo venisse compromesso, l'attaccante potrebbe solo scaricare o sovrascrivere il file `vault.tar.aes` — che è cifrato con AES-256-GCM e inutile senza la passphrase.

Il file di configurazione persistente vive in `/workspace/.tazpod/.aws/config`, tracciato nella workspace ma non nel vault cifrato — perché non contiene segreti:

```ini
[profile tazlab-bootstrap]
sso_start_url = https://ssoins-7223c4f9117b4c94.portal.us-east-1.app.aws
sso_account_id = 468971461088
sso_role_name = TazLabBootstrap
sso_region = us-east-1
region = eu-central-1
```

---

## Fase 5: Il CI/CD Pipeline — Sette Iterazioni

Il workflow GitHub Actions esistente era semplice: buildava il CLI Go (senza iniettare la versione) e buildava sempre tutte e quattro le immagini Docker ad ogni push su master. Ho ricostruito tutto in sette commit iterativi, ognuno che risolveva un problema specifico.

**Iterazione 1: versione nel binario.** Il comando di build non usava `-ldflags`, producendo sempre un binario con `Version = "dev"`. Corretto a:
```yaml
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.Version=${VERSION}" -o tazpod cmd/tazpod/main.go
```

**Iterazione 2: pubblicazione automatica della release.** Aggiunto uno step con `gh release create` che pubblica il binario compilato come asset GitHub. Questo rende `scripts/install.sh` funzionante senza intervento manuale.

**Iterazione 3: build selettiva.** Le immagini Docker non devono essere rebuildate ad ogni commit. Ho aggiunto un check che analizza `git diff --name-only HEAD~1 HEAD`:
- Se cambiano `cmd/`, `internal/`, o `VERSION` → build CLI + release
- Se cambiano `.tazpod/Dockerfile*` o `dotfiles/` → build Docker

**Iterazione 4: permessi GitHub Token.** Il step `gh release create` falliva con HTTP 403. La causa: `GITHUB_TOKEN` ha permessi limitati per default nei workflow. Soluzione:
```yaml
permissions:
  contents: write
```

**Iterazione 5: il binario non è in git.** Con `bin/tazpod` (15MB) tracciato da git, ogni push richiedeva 30-35 secondi di upload HTTPS. Rimosso con `git rm --cached bin/tazpod`, aggiunto `bin/` al `.gitignore`. I push successivi: meno di 1 secondo.

**Iterazione 6: il build CLI deve girare sempre.** Con la build condizionale, quando solo i Dockerfile cambiavano il binario non veniva compilato. Ma `Dockerfile.base` contiene `COPY tazpod /home/tazpod/.local/bin/tazpod` — senza il file nel build context, la Docker build fallisce. Il `Setup Go` e il `Build CLI` step non hanno condizioni: girano sempre. Solo `Publish GitHub Release` è condizionato.

**Iterazione 7: GHA Docker cache.** Aggiunto `cache-from` e `cache-to` con `type=gha` e uno scope per layer (`tazpod-base`, `tazpod-aws`, `tazpod-k8s`, `tazpod-ai`). La prima build popola la cache; le successive riusano i layer invariati. Su una modifica a `Dockerfile.ai` (il layer finale), i tre layer precedenti vengono recuperati dalla cache in secondi.

---

## Fase 6: Il Metodo di Autenticazione Git — 30 Secondi vs 1 Secondo

Durante il lavoro sul CI/CD ho identificato che ogni `git push` impiegava 30-35 secondi sistematicamente, causando timeout degli strumenti. La causa era il metodo di autenticazione usato fino a quel momento:

```bash
# SBAGLIATO
git -c http.extraheader="Authorization: Basic $(echo -n x-access-token:${TOKEN} | base64)" push
```

Il metodo `http.extraheader` con Base64 aggiunge overhead al protocollo di negoziazione HTTP di git — una fase di handshake che con GitHub risulta significativamente più lenta rispetto al metodo nativo.

Il metodo corretto usa un credential helper inline che implementa il protocollo credential standard di git:

```bash
# CORRETTO
git -c credential.helper="!f() { echo 'username=x-access-token'; echo \"password=${TOKEN}\"; }; f" push origin master
```

La differenza misurata: 30-35 secondi contro 0.8-1.2 secondi. Il benchmark è stato effettuato su commit identici dello stesso repository. Il metodo corretto usa il protocollo che GitHub si aspetta nativamente, senza layer di codifica aggiuntivi.

---

## Fase 7: I Sei Bug del Test Live

È questa la parte che differenzia un'implementazione progettata a tavolino da una verificata su un sistema reale. Tutti e sei i bug erano invisibili in fase di sviluppo — nessuno era individuabile senza eseguire il flusso completo su una macchina host reale.

**Bug 1: `loadConfigs()` non chiamata nel path senza argomenti.** In `main()`, `loadConfigs()` veniva invocata solo dopo il controllo degli argomenti. Quando `tazpod` veniva eseguito senza argomenti, `smartEntry()` leggeva `cfg` ancora al valore zero. Risultato: `❌ container_name mancante in config.yaml`. Fix: `loadConfigs()` come prima istruzione di `smartEntry()`.

**Bug 2: path del vault hardcodato.** `vault.VaultFile` è costante a `/workspace/.tazpod/vault/vault.tar.aes` — il path assoluto valido dentro il container, dove il progetto è sempre montato su `/workspace`. Sull'host, il progetto può stare ovunque. Fix: `filepath.Join(cwd, ".tazpod/vault/vault.tar.aes")` relativo alla working directory corrente dell'host.

**Bug 3: unlock chiede la password sudo all'utente host.** `vault.Unlock()` esegue `sudo mount -t tmpfs` per creare il tmpfs in RAM. Dentro il container, l'utente `tazpod` ha `NOPASSWD sudo`. Sull'host, l'utente non ha quel privilegio. La separazione architettuale corretta: login e pull vault sull'host (dove c'è il browser per SSO), unlock dentro il container (dove ci sono i permessi sudo). Implementato con `execInContainer()`, un helper che esegue comandi interattivi via `docker exec -it`.

**Bug 4: `aws` CLI non trovata nel bootstrap.** `docker exec bash -c "..."` apre una shell non-interattiva che non sourcia `.bashrc`. Il symlink `~/.aws` non viene creato, la configurazione AWS non è trovata. Fix: passare `-e AWS_CONFIG_FILE=/workspace/.tazpod/.aws/config` esplicitamente a `docker exec`, bypassando completamente il symlink.

**Bug 5: la sequenza non si interrompe su errore.** `tazpod login` usciva con codice 0 anche in caso di errore — `main()` non propagava il codice di uscita dei subcomandi falliti. Il `&&` nella catena shell non fermava l'esecuzione. Fix: `os.Exit(1)` nei path di errore di `login()` e `pullVault()`.

**Bug 6: la passphrase corrotta dal buffer TTY.** Con `bash -c "tazpod login && tazpod pull vault && tazpod unlock"`, i tre comandi condividono lo stesso TTY. Durante il flusso SSO — mentre il browser è aperto, l'utente naviga e inserisce il codice MFA — i keystroke vengono bufferizzati nel TTY. Quando arriva il momento di leggere la passphrase vault con `term.ReadPassword`, il buffer TTY contiene già caratteri che vengono letti come parte della passphrase. Il risultato è `❌ WRONG PASSWORD` con la passphrase corretta. Fix: ogni passo (login, pull, unlock) gira in un `execInContainer` separato, con il proprio TTY pulito. `execInContainer` ritorna `bool` per interrompere la sequenza in caso di fallimento.

Questi sei bug, risolti in sequenza nelle versioni da 0.3.5 a 0.3.12, descrivono in modo preciso la differenza tra ambiente di sviluppo (container, cwd prevedibile, TTY controllato) e ambiente di produzione (host reale, utente diverso, sessioni terminale con I/O non deterministico).

---

## Riflessioni: Cosa Cambia con Zero Credenziali sul Disco

Il risultato finale è un binario che, eseguito su un host con solo Docker installato, gestisce autonomamente l'intero flusso di bootstrap: verifica la presenza di un progetto inizializzato, porta su il container se necessario, e — se non c'è un vault locale — guida l'utente attraverso `aws sso login`, il download da S3, e la decrifratura in RAM.

Il tutto senza che nessuna credenziale AWS statica tocchi mai il disco dell'host.

L'immagine Docker che gira nel container (`tazzo/tazpod-aws:latest`) contiene l'AWS CLI — ma non credenziali. La configurazione SSO in `/workspace/.tazpod/.aws/config` contiene l'URL del portale e il nome del ruolo — ma non token, non chiavi, non segreti. Il vault cifrato su S3 contiene tutto il resto — ma è inutile senza la passphrase che vive solo in testa.

L'architettura ha ora tre caratteristiche che prima non aveva: è verificabile (puoi ispezionare ogni file e non trovare credenziali), è riproducibile (la sequenza `tazpod` → SSO → pull → unlock funziona da qualsiasi host con Docker), ed è resiliente al furto (rubare il laptop dà accesso all'immagine Docker e al file di configurazione SSO pubblico, non ai segreti).

Il prossimo passo — che chiude il ciclo descritto nell'articolo precedente — è il provisioning di tazlab-vault su Oracle Cloud e la migrazione dei segreti applicativi da Infisical a HashiCorp Vault CE. Ma questa è un'altra sessione.
