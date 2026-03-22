+++
title = "Zero Credentials on Disk: Rewriting TazPod with AWS IAM Identity Center"
date = 2026-03-22T19:43:22+00:00
draft = false
description = "Technical chronicle of the complete migration of TazPod from Infisical to AWS SSO: removal of legacy code, implementation of the vault-S3 bootstrap, six bugs discovered in production, and a CI/CD pipeline rebuilt from scratch."
tags = ["aws", "iam-identity-center", "sso", "s3", "devops", "tazpod", "secrets-management", "golang", "docker", "ci-cd", "github-actions", "security"]
author = "Tazzo"
+++

# Zero Credentials on Disk: Rewriting TazPod with AWS IAM Identity Center

## Introduction: The Problem I Couldn't Solve

In the [previous article on this project](/posts/bootstrap-from-zero-vault-s3-rebirth/) I described the architectural vision: replace Infisical with AWS IAM Identity Center as the bootstrap anchor, eliminate every static credential from the TazPod Docker image, and make the entire rebirth cycle reproducible from a blank machine with only an S3 bucket, a passphrase, and an MFA device.

That was the design. This article tells the story of the implementation — four hours of work that produced TazPod 0.3.12, eleven build versions, six distinct bugs discovered exclusively during live testing on the real system, and an iteratively rebuilt CI/CD pipeline.

---

## Phase 1: The Surgical Removal of Infisical

The starting point was `cmd/tazpod/main.go` — 613 lines, roughly a third of which were dedicated exclusively to Infisical integration. The temptation in these cases is to do a gradual removal, leaving compatibility branches or deprecated wrappers. I deliberately resisted that temptation.

The principle I applied is called **Design Integrity**: the code must tell the truth about what the system does. Every line of Infisical code left compilable — even commented out, even with a deprecation warning — is a lie told to the next reader. The removal must be total or it is not a removal.

I eliminated: the `SecretMapping` and `SecretsConfig` structs, the global variable `secCfg`, the constants `SecretsYAML` and `EnvFile`, the functions `pullSecrets()`, `login()` (Infisical version), `runInfisical()`, `runCmd()`, `checkInfisicalLogin()`, `loadEnclaveEnv()`, `resolveSecret()`, and the local `isMounted()` method (a duplicate of `utils.IsMounted`). The orphaned `bytes` and `strings` imports disappeared as well.

The result was a 250-line file instead of 613. The compiler confirmed the cleanliness on the first attempt.

The same operation in `internal/vault/vault.go` was more delicate. The Infisical constants (`InfisicalLocalHome`, `InfisicalKeyringLocal`, `InfisicalVaultDir`, `InfisicalKeyringVault`) were used by `setupBindAuth()` and `Lock()`. I replaced them with their AWS equivalents:

```go
const (
    AwsLocalHome = "/home/tazpod/.aws"
    AwsVaultDir  = MountPath + "/.aws"
    PassCache    = MountPath + "/.vault_pass"
)
```

The `setupBindAuth()` function now creates a bind mount from the AWS directory in the RAM tmpfs to `~/.aws` in the container. The mechanism is identical to what it used for Infisical — a bind mount that makes the RAM directory indistinguishable from a normal directory for any process, including the AWS CLI and the Go SDK.

---

## Phase 2: The `~/.aws` Symlink — Two Implementations Before the Right One

The first implementation of the symlink for AWS configuration was an error of granularity. I wrote in `SetupIdentity()` (vault.go) the code to symlink the *file* `~/.aws/config` to `/workspace/.tazpod/aws/config`. It was wrong for three reasons: I was symlinking a file instead of a directory, using the name `aws` without the leading dot (inconsistent with the pattern of other tools), and I had placed it in Go instead of `.bashrc`.

The correct pattern already existed in `.bashrc` for four other tools: `.pi`, `.omp`, `.gemini`, `.claude`. Each tool directory is symlinked from the workspace to home: `~/.pi → /workspace/.tazpod/.pi`, and so on. The logic lives in `.bashrc` because it runs at every shell startup, guaranteeing symlink recreation even after a `lock` that unmounts the tmpfs.

For `~/.aws` there was an additional complexity that the other tools didn't have: when the vault is unlocked, `setupBindAuth()` executes `rm -rf ~/.aws` and replaces it with a bind mount from RAM. If the generic `.bashrc` loop ran in a new shell with the vault already open, it would destroy the active bind mount.

The solution was an explicit guard using `mountpoint -q`:

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

If `~/.aws` is a mountpoint (vault unlocked), the block is skipped. If it isn't (vault locked, or first launch), the symlink is created or recreated. The vault bind mount and the workspace symlink coexist without conflict, serving two distinct operational states.

---

## Phase 3: The Go AWS SDK Bug with SSO Profiles

The `NewS3Client` function in the `utils` package accepted only the bucket name. I added a second parameter for the SSO profile:

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

The condition `os.Getenv("AWS_ACCESS_KEY_ID") == ""` is not obvious and deserves an explanation. During testing I discovered that passing `WithSharedConfigProfile` to the Go AWS SDK causes a 30+ second hang when `AWS_ACCESS_KEY_ID` is already in the environment. The SDK still tries to *load the configuration* of the SSO profile — including an attempt to contact the SSO endpoint to validate or refresh tokens — regardless of whether static credentials are already available.

The Go SDK v2 credential chain gives priority to environment variables over profile credentials. But profile configuration loading (region, endpoint, SSO parameters) happens anyway if `WithSharedConfigProfile` is passed. Skipping the profile when env vars are present is the correct solution: the static credentials already have everything needed.

This bug never manifests in production — where there are no static credentials and the SSO profile is the only source — but it is critical for testing and fallback situations.

---

## Phase 4: AWS IAM Identity Center — Guided Setup

The IAM Identity Center setup was interactive: I did it collaboratively, step by step from the AWS Console. The non-obvious points worth documenting:

**The region is us-east-1, not eu-central-1.** Even though I configured IAM Identity Center from the eu-central-1 console, the SSO portal is created in us-east-1. The portal URL — `https://ssoins-7223c4f9117b4c94.portal.us-east-1.app.aws` — explicitly contains the region. Configuring `sso_region = eu-central-1` in the AWS profile produced `InvalidRequestException: Couldn't find Identity Center Instance`. The fix was immediate once the cause was identified.

**The TazLabBootstrap permission set follows the Principle of Least Privilege.** The inline policy permits only the three strictly necessary operations, on the single bucket and single prefix:

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

No access to other buckets. No management operations. If this profile were compromised, an attacker could only download or overwrite the `vault.tar.aes` file — which is encrypted with AES-256-GCM and useless without the passphrase.

The persistent configuration file lives in `/workspace/.tazpod/.aws/config`, tracked in the workspace but not in the encrypted vault — because it contains no secrets:

```ini
[profile tazlab-bootstrap]
sso_start_url = https://ssoins-7223c4f9117b4c94.portal.us-east-1.app.aws
sso_account_id = 468971461088
sso_role_name = TazLabBootstrap
sso_region = us-east-1
region = eu-central-1
```

---

## Phase 5: The CI/CD Pipeline — Seven Iterations

The existing GitHub Actions workflow was simple: it built the Go CLI (without injecting the version) and always built all four Docker images on every push to master. I rebuilt everything in seven iterative commits, each one fixing a specific problem.

**Iteration 1: version in the binary.** The build command didn't use `-ldflags`, always producing a binary with `Version = "dev"`. Fixed to:
```yaml
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.Version=${VERSION}" -o tazpod cmd/tazpod/main.go
```

**Iteration 2: automatic release publishing.** Added a step with `gh release create` that publishes the compiled binary as a GitHub asset. This makes `scripts/install.sh` functional without manual intervention.

**Iteration 3: selective build.** Docker images shouldn't be rebuilt on every commit. I added a check that analyzes `git diff --name-only HEAD~1 HEAD`:
- If `cmd/`, `internal/`, or `VERSION` change → build CLI + release
- If `.tazpod/Dockerfile*` or `dotfiles/` change → build Docker

**Iteration 4: GitHub Token permissions.** The `gh release create` step was failing with HTTP 403. The cause: `GITHUB_TOKEN` has limited permissions by default in workflows. Solution:
```yaml
permissions:
  contents: write
```

**Iteration 5: the binary is not in git.** With `bin/tazpod` (15MB) tracked by git, every push required 30-35 seconds of HTTPS upload. Removed with `git rm --cached bin/tazpod`, added `bin/` to `.gitignore`. Subsequent pushes: less than 1 second.

**Iteration 6: the CLI build must always run.** With conditional builds, when only Dockerfiles changed the binary wasn't compiled. But `Dockerfile.base` contains `COPY tazpod /home/tazpod/.local/bin/tazpod` — without the file in the build context, the Docker build fails. The `Setup Go` and `Build CLI` steps have no conditions: they always run. Only `Publish GitHub Release` is conditional.

**Iteration 7: GHA Docker cache.** Added `cache-from` and `cache-to` with `type=gha` and a scope per layer (`tazpod-base`, `tazpod-aws`, `tazpod-k8s`, `tazpod-ai`). The first build populates the cache; subsequent ones reuse unchanged layers. On a change to `Dockerfile.ai` (the final layer), the three previous layers are retrieved from cache in seconds.

---

## Phase 6: The Git Authentication Method — 30 Seconds vs 1 Second

During the CI/CD work I identified that every `git push` was systematically taking 30-35 seconds, causing tool timeouts. The cause was the authentication method used up to that point:

```bash
# WRONG
git -c http.extraheader="Authorization: Basic $(echo -n x-access-token:${TOKEN} | base64)" push
```

The `http.extraheader` method with Base64 adds overhead to git's HTTP negotiation protocol — a handshake phase that with GitHub results in significantly slower performance compared to the native method.

The correct method uses an inline credential helper that implements git's standard credential protocol:

```bash
# CORRECT
git -c credential.helper="!f() { echo 'username=x-access-token'; echo \"password=${TOKEN}\"; }; f" push origin master
```

The measured difference: 30-35 seconds versus 0.8-1.2 seconds. The benchmark was performed on identical commits to the same repository. The correct method uses the protocol GitHub expects natively, without additional encoding layers.

---

## Phase 7: The Six Bugs of Live Testing

This is the part that differentiates an implementation designed on paper from one verified on a real system. All six bugs were invisible during development — none were detectable without running the complete flow on a real host machine.

**Bug 1: `loadConfigs()` not called in the no-arguments path.** In `main()`, `loadConfigs()` was invoked only after the argument check. When `tazpod` was executed without arguments, `smartEntry()` read `cfg` still at its zero value. Result: `❌ container_name missing in config.yaml`. Fix: `loadConfigs()` as the first instruction of `smartEntry()`.

**Bug 2: hardcoded vault path.** `vault.VaultFile` is constant at `/workspace/.tazpod/vault/vault.tar.aes` — the correct absolute path inside the container, where the project is always mounted at `/workspace`. On the host, the project can be anywhere. Fix: `filepath.Join(cwd, ".tazpod/vault/vault.tar.aes")` relative to the current working directory of the host.

**Bug 3: unlock asks the host user for the sudo password.** `vault.Unlock()` executes `sudo mount -t tmpfs` to create the tmpfs in RAM. Inside the container, the `tazpod` user has `NOPASSWD sudo`. On the host, the user doesn't have that privilege. The correct architectural separation: login and vault pull on the host (where there's a browser for SSO), unlock inside the container (where there are sudo permissions). Implemented with `execInContainer()`, a helper that runs interactive commands via `docker exec -it`.

**Bug 4: `aws` CLI not found during bootstrap.** `docker exec bash -c "..."` opens a non-interactive shell that doesn't source `.bashrc`. The `~/.aws` symlink isn't created, the AWS configuration isn't found. Fix: pass `-e AWS_CONFIG_FILE=/workspace/.tazpod/.aws/config` explicitly to `docker exec`, bypassing the symlink entirely.

**Bug 5: the sequence doesn't stop on error.** `tazpod login` exited with code 0 even on failure — `main()` didn't propagate the exit codes of failed subcommands. The `&&` in the shell chain didn't stop execution. Fix: `os.Exit(1)` in the error paths of `login()` and `pullVault()`.

**Bug 6: passphrase corrupted by the TTY buffer.** With `bash -c "tazpod login && tazpod pull vault && tazpod unlock"`, the three commands share the same TTY. During the SSO flow — while the browser is open, the user navigates and enters the MFA code — keystrokes are buffered in the TTY. When the time comes to read the vault passphrase with `term.ReadPassword`, the TTY buffer already contains characters that get read as part of the passphrase. The result is `❌ WRONG PASSWORD` with the correct passphrase. Fix: each step (login, pull, unlock) runs in a separate `execInContainer` call, with its own clean TTY. `execInContainer` returns `bool` to stop the sequence in case of failure.

These six bugs, resolved in sequence across versions 0.3.5 to 0.3.12, describe precisely the difference between a development environment (container, predictable cwd, controlled TTY) and a production environment (real host, different user, terminal sessions with non-deterministic I/O).

---

## Reflections: What Changes with Zero Credentials on Disk

The final result is a binary that, run on a host with only Docker installed, autonomously manages the entire bootstrap flow: verifies the presence of an initialized project, brings up the container if necessary, and — if there's no local vault — guides the user through `aws sso login`, the S3 download, and the RAM decryption.

All without any static AWS credentials ever touching the host's disk.

The Docker image running in the container (`tazzo/tazpod-aws:latest`) contains the AWS CLI — but no credentials. The SSO configuration in `/workspace/.tazpod/.aws/config` contains the portal URL and the role name — but no tokens, no keys, no secrets. The encrypted vault on S3 contains everything else — but it's useless without the passphrase that lives only in one's head.

The architecture now has three characteristics it didn't have before: it is **verifiable** (you can inspect every file and find no credentials), **reproducible** (the sequence `tazpod` → SSO → pull → unlock works from any host with Docker), and **resilient to theft** (stealing the laptop gives access to the Docker image and the public SSO configuration file, not the secrets).

The next step — which closes the cycle described in the previous article — is the provisioning of tazlab-vault on Oracle Cloud and the migration of application secrets from Infisical to HashiCorp Vault CE. But that is another session.
