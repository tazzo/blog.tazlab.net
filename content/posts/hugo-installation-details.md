+++
date = '2025-12-21T23:07:21Z'
draft = false
title = 'Hugo Installation Details'
+++

This post describes the Hugo installation setup.

## Docker Compo se Configuration

The Hugo site is set up using Docker Compose. The `compose.yml` file defines a service named `hugo` which uses the `hugomods/hugo:exts-non-root` Docker image. This image includes the extended version of Hugo and runs as a non-root user, enhancing security and providing essential features for a modern Hugo site.

The `compose.yml` also maps the local project directory to `/src` inside the container, allowing Hugo to serve content from the local files. Port `1313` is exposed to access the development server.

```yaml
services:
  hugo:
    image: hugomods/hugo:exts-non-root
    container_name: hugo
    command: server --bind=0.0.0.0 --buildDrafts --buildFuture --watch
    volumes:
      - ./:/src
    ports:
      - "1313:1313"
```

## Blowfish Theme Installation

The Blowfish theme was installed using Git submodules. This method ensures that the theme can be easily updated and maintained alongside the main Hugo project.

1.  **Initialize Git Repository**:
    \`\`\`bash
    git init
    \`\`\`

2.  **Add Blowfish Theme as Submodule**:
    \`\`\`bash
    git submodule add -b main https://github.com/nunocoracao/blowfish.git themes/blowfish
    \`\`\`

3.  **Configure Theme**:
    The default `hugo.toml` file was removed, and the configuration files from the Blowfish theme's `config/_default/` directory were copied to the site's `config/_default/` directory. The `theme = "blowfish"` line in `config/_default/hugo.toml` was uncommented to activate the theme.

This setup provides a robust and flexible environment for developing a Hugo website with the Blowfish theme.

## Automating Deployments with a Webhook

After setting up the blog, the next logical step for us was to automate updates. Manually pulling changes on the server every time a new post was written felt cumbersome. We wanted a classic GitOps workflow: a `git push` to the main branch should automatically update the live blog.

This is where our adventure with webhooks began, and it turned into quite a debugging marathon!

### The Tool: `webhook-receiver`

We decided to use the popular `almir/webhook` Docker image, a lightweight tool that listens for HTTP requests and runs predefined scripts. The plan was simple:
1.  GitHub sends a POST request to our webhook URL when we push a commit.
2.  The `webhook` service verifies the request using a shared secret.
3.  It then executes a script, `pull-blog.sh`, which runs `git pull` inside our Hugo project directory.

Simple, right? Well...

### The Journey Through Permissions Hell

What followed was a classic case of "it works on my machine" versus the harsh reality of Docker container security.

**Problem 1: `git: not found`**
The first webhook trigger failed immediately. We quickly realized the minimal `almir/webhook` image didn't include `git`. The first fix was to create our own `Dockerfile` based on the image and add `git` using Alpine's package manager:

```dockerfile
FROM almir/webhook:latest

USER root
RUN apk add --no-cache git
USER webhook
```

**Problem 2: GitHub Authentication**
With `git` installed, the next error was `fatal: could not read Username for 'https://github.com'`. Our `git pull` was trying to use HTTPS and didn't have credentials. While we could have used a Personal Access Token (PAT), we opted for the more secure and standard approach for server-to-server communication: **SSH Deploy Keys**.

This involved:
1.  Generating a new SSH key pair on the server.
2.  Adding the public key to our GitHub repository's "Deploy keys" section (with read-only access).
3.  Mounting the private key into the `webhook` container.

**Problem 3: The `Permission denied` Saga**
This is where things got complicated. For what felt like an eternity, every attempt was met with a `Permission denied (publickey)` error from `git`. The `webhook` user inside the container couldn't access the SSH key.

Our debugging journey went something like this:
-   **Attempt A:** Set key file permissions from the `Dockerfile`. This failed because you can't `chmod`/`chown` a volume that is mounted at *runtime* during the image *build* phase.
-   **Attempt B:** Introduce an `entrypoint.sh` script to set permissions when the container starts. This led to a rabbit hole of user-switching problems inside the container. Tools like `su-exec`, `runuser`, and `gosu` all failed with `Operation not permitted` errors, even after we granted `SETUID` and `SETGID` capabilities to the container. It was a classic battle against minimal Alpine images and Docker's security features.

**The Breakthrough**
After trying every combination of `user:` directives and entrypoint logic, we found the real culprit: the private key was being mounted as **read-only**.

A read-only file's permissions *cannot be changed*. Our `entrypoint.sh` script was failing to `chown` the key to the `webhook` user, but it was failing silently.

**The Final, Working Solution**
The correct, and much more robust, solution was:
1.  **Modify `compose.yml`**: Mount the private key to a temporary, *writable* location (`/tmp/id_rsa`).
2.  **Use an `entrypoint.sh` script**: This script, running as `root` before the main application starts, does the following:
    -   Creates the `.ssh` directory in the `webhook` user's real home (`/home/webhook/.ssh`).
    -   **Copies** the key from `/tmp/id_rsa` to `/home/webhook/.ssh/id_rsa`.
    -   Sets the correct ownership (`chown webhook:webhook`) and permissions (`chmod 600`) on the *copied* key.
    -   Removes the temporary key from `/tmp`.
3.  **Update `GIT_SSH_COMMAND`**: Ensure the environment variable points to the key's final destination: `/home/webhook/.ssh/id_rsa`.
4.  **Run the container as the `webhook` user**: We set `user: webhook` in `compose.yml` to ensure the process runs with minimal privileges after the entrypoint has done its job as root.

**The Last Mystery: The Empty Logs**
Even with everything working, the `docker logs` command remained stubbornly empty. The `webhook` service was working, but swallowing all output from our script. The final piece of the puzzle was to add this line to the top of our `pull-blog.sh` script, which forces all output to the container's standard streams:
```bash
exec >/proc/1/fd/1 2>/proc/1/fd/2
```
With that, we could finally see the `git pull` output in the logs. A long journey, but a valuable lesson in the nuances of Docker permissions and runtime logic!
