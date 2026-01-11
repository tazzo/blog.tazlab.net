#!/bin/bash

# Controllo dipendenze
if ! command -v mogrify &>/dev/null; then
  echo "Errore: ImageMagick non trovato. Installa con: sudo apt install imagemagick"
  exit 1
fi

echo "Ridimensionamento ricorsivo delle immagini JPG a max 1024x1024..."

# Trova tutti i file .jpg o .jpeg ricorsivamente
# -resize "1024x1024>" indica a ImageMagick di ridimensionare SOLO se
# l'immagine è più grande di queste dimensioni, mantenendo le proporzioni.
find . -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -print0 | xargs -0 mogrify -resize "600x600>"

echo "Ottimizzazione completata! I file più grandi di 1024px sono stati sovrascritti."
