#!/bin/bash
set -e

# --- BLOG GITOPS PUBLISH SCRIPT (Level 2) ---

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_REPO_PATH="$SCRIPT_DIR/../../tazlab-k8s"
MANIFEST_PATH="$K8S_REPO_PATH/apps/base/hugo-blog/hugo-blog.yaml"

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
cd "$SCRIPT_DIR/.."
git submodule update --init --recursive

# 4. Build the Docker image
echo "🏗️ Building Docker image ($IMAGE_NAME)..."
docker build -t "$IMAGE_NAME" .

# 5. Push to Docker Hub
echo "🚀 Pushing to Docker Hub..."
docker push "$IMAGE_NAME"

# 6. Update the GitOps repository
echo "📝 Updating image tag in $MANIFEST_PATH..."
sed -i "s|image: tazzo/tazlab.net:blog-.*|image: $IMAGE_NAME|" "$MANIFEST_PATH"

# 7. Commit and Push to tazlab-k8s
echo "📦 Committing and pushing to tazlab-k8s..."
cd "$K8S_REPO_PATH"
git add apps/base/hugo-blog/hugo-blog.yaml
git commit -m "chore(blog): update image to $IMAGE_TAG"
git push

echo "✅ Blog published and GitOps manifest updated!"
echo "⏳ Flux will reconcile the changes in about 60 seconds."
