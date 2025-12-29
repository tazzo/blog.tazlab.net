+++
date = '2025-12-21T23:07:21Z'
draft = false
title = 'Hugo Installation Details'
+++

This post describes the Hugo installation setup.

## Docker Compoo00se Configuration
![HUGO](images/hugo.jpeg)
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
