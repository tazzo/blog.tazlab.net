+++
date = '2025-12-21T23:07:21Z'
draft = false
title = "Dettagli sull'installazione di Hugo"
+++

Questo post descrive la configurazione dell'installazione di Hugo.

## Configurazione di Docker Compose

Il sito Hugo è configurato tramite Docker Compose. Il file `compose.yml` definisce un servizio chiamato `hugo` che utilizza l'immagine Docker `hugomods/hugo:exts-non-root`. Questa immagine include la versione estesa di Hugo e viene eseguita come utente non-root, migliorando la sicurezza e fornendo funzionalità essenziali per un sito Hugo moderno.

Il file `compose.yml` mappa anche la directory locale del progetto su `/src` all'interno del container, consentendo a Hugo di servire i contenuti dai file locali. La porta `1313` è esposta per accedere al server di sviluppo.

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

## Installazione del tema Blowfish

Il tema Blowfish è stato installato utilizzando i sottomoduli Git. Questo metodo garantisce che il tema possa essere facilmente aggiornato e mantenuto insieme al progetto Hugo principale.

1.  **Inizializza il repository Git**:
    \`\`\`bash
    git init
    \`\`\`

2.  **Aggiungi il tema Blowfish come sottomodulo**:
    \`\`\`bash
    git submodule add -b main https://github.com/nunocoracao/blowfish.git themes/blowfish
    \`\`\`

3.  **Configura il tema**:
    Il file `hugo.toml` predefinito è stato rimosso e i file di configurazione dalla directory `config/_default/` del tema Blowfish sono stati copiati nella directory `config/_default/` del sito. La riga `theme = "blowfish"` nel file `config/_default/hugo.toml` è stata decommentata per attivare il tema.

Questa configurazione fornisce un ambiente robusto e flessibile per lo sviluppo di un sito web Hugo con il tema Blowfish.
