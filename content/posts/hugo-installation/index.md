+++
title = "Hugo Installation Details"
date = 2025-12-21T23:07:21Z
draft = false
description = "Setup details for installing Hugo using Docker Compose and configuring the Blowfish theme."
tags = ["hugo", "docker", "docker-compose", "blog", "web-development"]
author = "Tazzo"
+++

This post describes the Hugo installation setup.

## Docker Compose Configuration

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
    restart: always
    networks:
      - frontend

networks:
  frontend:
    external: true
```

## Blowfish Theme Installation

The Blowfish theme is used for this blog. It's a powerful and highly customizable theme built with Tailwind CSS. The theme is added as a git submodule in the `themes/blowfish` directory.

To install the theme and its dependencies, the following commands were used:

1.  Add the Blowfish theme as a submodule:
    ```bash
    git submodule add https://github.com/nunocoracao/blowfish.git themes/blowfish
    ```

2.  Install dependencies (if applicable, following theme-specific instructions).

The configuration for the theme is managed through the files in `config/_default/`.

## Deployment on Kubernetes

The blog is deployed on a Kubernetes cluster. The deployment uses a `git-sync` sidecar container to automatically update the blog content whenever changes are pushed to the GitHub repository. Persistent storage is provided by Longhorn.

---
*Generated via Gemini CLI*