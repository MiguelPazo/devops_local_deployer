#!/bin/bash

# ----------- CONFIGURATION ------------
IMAGE_NAME="miguelpazo/devops-local-deployer"
VERSION="1.6.0"
DOCKERFILE_PATH="."

# ----------- DOCKER LOGIN ------------
echo "🔐 Logging in to Docker Hub..."
docker login || { echo "❌ Login failed"; exit 1; }

# ----------- BUILD DOCKER IMAGE ------------
echo "⚙️ Building Docker image with tags: $VERSION and latest..."
docker build --no-cache --network host \
    -t "$IMAGE_NAME:$VERSION" \
    -t "$IMAGE_NAME:latest" \
    "$DOCKERFILE_PATH" || { echo "❌ Build failed"; exit 1; }

# ----------- PUSH TO DOCKER HUB ------------
echo "📤 Pushing image to Docker Hub with tag: $VERSION"
docker push "$IMAGE_NAME:$VERSION" || { echo "❌ Push failed for tag $VERSION"; exit 1; }

echo "📤 Pushing image to Docker Hub with tag: latest"
docker push "$IMAGE_NAME:latest" || { echo "❌ Push failed for tag latest"; exit 1; }

echo "✅ Image successfully pushed:"
echo "   - $IMAGE_NAME:$VERSION"
echo "   - $IMAGE_NAME:latest"
