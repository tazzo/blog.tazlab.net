#!/bin/bash

# Controlla se ImageMagick è installato
if ! command -v convert &>/dev/null; then
  echo "Errore: ImageMagick non è installato. Installa con: sudo apt install imagemagick"
  exit 1
fi

echo "Inizio conversione ricorsiva e pulizia PNG..."

# -type f: solo file
# -iname: cerca *.png ignorando maiuscole/minuscole
find . -type f -iname "*.png" -exec bash -c '
    for file do
        # Definisce il nome del file di destinazione
        target="${file%.*}.jpg"
        
        # Converte e, se ha successo (&&), rimuove il file originale
        if convert "$file" -quality 85 "$target"; then
            echo "Successo: $file -> $target"
            rm "$file"
        else
            echo "Errore nella conversione di: $file (il file originale è stato mantenuto)"
        fi
    done
' bash {} +

echo "Processo completato!"
