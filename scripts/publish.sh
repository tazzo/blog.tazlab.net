#!/bin/bash
set -e

# --- BLOG PUBLISH SCRIPT (Image Only) ---

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# 1. Check for uncommitted changes in blog-src
if ! git diff-index --quiet HEAD --; then
    echo "❌ Error: You have uncommitted changes in blog-src. Please commit first."
    exit 1
fi

# 2. Get the current Git SHA
GIT_SHA=$(git rev-parse --short HEAD)
IMAGE_TAG="blog-$GIT_SHA"
IMAGE_NAME="tazzo/tazlab.net:$IMAGE_TAG"

echo "🔖 Current Git SHA: $GIT_SHA"

# 3. Update submodules (Themes)
echo "🔄 Updating git submodules..."
git submodule update --init --recursive

# 4. Build the Docker image
echo "🏗️ Building Docker image ($IMAGE_NAME)..."
docker build -t "$IMAGE_NAME" .

# 5. Push to Docker Hub
echo "🚀 Pushing to Docker Hub..."
docker push "$IMAGE_NAME"

echo "✅ Image $IMAGE_NAME published successfully!"
echo "📡 Flux will detect the new image and update the cluster automatically."