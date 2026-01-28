#!/bin/bash
set -e

# --- BLOG PUBLISH SCRIPT ---

# 1. Update submodules (Themes)
echo "🔄 Updating git submodules..."
git submodule update --init --recursive

# 2. Build the Docker image
echo "🏗️ Building Docker image (tazzo/tazlab.net:blog)..."
docker build -t tazzo/tazlab.net:blog .

# 3. Push to Docker Hub
echo "🚀 Pushing to Docker Hub..."
docker push tazzo/tazlab.net:blog

echo "✅ Blog published successfully!"
