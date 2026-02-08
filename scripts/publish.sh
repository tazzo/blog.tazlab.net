#!/bin/bash
set -e

# --- BLOG PUBLISH SCRIPT (TazPod + Kaniko + Docker Hub) ---

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
# Docker Hub Repository
IMAGE_NAME="tazzo/tazlab.net:$IMAGE_TAG"

echo "🔖 Current Git SHA: $GIT_SHA"

# 3. Update submodules (Themes)
echo "🔄 Updating git submodules..."
git submodule update --init --recursive

# 4. Setup Kaniko Authentication
DOCKER_USERNAME="roberto.tazzoli@gmail.com"

# Setup DOCKER_PASSWORD using TazPod mechanism
if [[ -z "$DOCKER_PASSWORD" ]]; then
    # Fallback to reading file if env var is missing but we are in TazPod
    if [[ -f "/home/tazpod/secrets/docker-password" ]]; then
        DOCKER_PASSWORD=$(cat /home/tazpod/secrets/docker-password)
    else
        echo "❌ Error: DOCKER_PASSWORD is not set."
        echo "Please add it to Infisical at /ephemeral-castle/tazlab-k8s/proxmox"
        exit 1
    fi
fi

echo "🔐 Configuring Kaniko Auth for Docker Hub ($DOCKER_USERNAME)..."
mkdir -p ~/.docker
cat <<EOF > ~/.docker/config.json
{
    "auths": {
        "https://index.docker.io/v1/": {
            "auth": "$(echo -n "${DOCKER_USERNAME}:${DOCKER_PASSWORD}" | base64)"
        }
    }
}
EOF

# 5. Build and Push with Kaniko
echo "🏗️ Building and Pushing Docker image to Docker Hub ($IMAGE_NAME)..."
# Using --force because we are running inside a container that is not the official kaniko image
/usr/local/bin/kaniko \
    --context "$(pwd)" \
    --dockerfile "$(pwd)/Dockerfile" \
    --destination "$IMAGE_NAME" \
    --force

echo "✅ Image $IMAGE_NAME published successfully to Docker Hub via Kaniko!"
echo "📡 Flux will detect the new image and update the cluster automatically."
