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

# 4. Force Kubernetes to pull the new image
echo "🔄 Restarting deployment in Kubernetes..."
kubectl --kubeconfig /home/taz/kubernetes/ephemeral-castle/cluster-configs/blue-kubeconfig rollout restart deployment/hugo-blog -n hugo-blog

echo "✅ Blog published and updated in cluster successfully!"
