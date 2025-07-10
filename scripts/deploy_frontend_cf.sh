#!/bin/bash

# === PARSE ARGUMENTS ===
for arg in "$@"; do
  case $arg in
    --project=*) PROJECT="${arg#*=}" ;;
    --app=*) APP="${arg#*=}" ;;
    --env=*) ENVIRONMENT="${arg#*=}" ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

export AWS_PAGER=""

if [[ -z "$PROJECT" || -z "$APP" || -z "$ENVIRONMENT" ]]; then
  echo "Params required: --project=project1 --app=app1 --env=dev"
  exit 1
fi

if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "qa" && "$ENVIRONMENT" != "prod" ]]; then
  echo "Invalid environment: $ENVIRONMENT"
  echo "Valid values are: dev, qa, prod"
  exit 1
fi

# === CHECK DEPENDENCIES ===
for cmd in aws jq tar npm git; do
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd is not installed. Please install it before running this script."
    exit 1
  fi
done

# === LOAD CONFIG FILE PATHS ===
BASE_DIR="/deploy_projects/$PROJECT"
CONFIG_FILE="$BASE_DIR/$APP/config.json"
PROJECTS_CONFIG_FILE="/deploy_projects/projects_config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Configuration file '$CONFIG_FILE' not found."
  exit 1
fi

if [[ ! -f "$PROJECTS_CONFIG_FILE" ]]; then
  echo "projects_config.json file not found"
  exit 1
fi

# === VALIDATE TYPE ===
TYPE=$(jq -r '.general.TYPE' "$CONFIG_FILE")
if [[ "$TYPE" != "frontend_cloudfront_s3" ]]; then
  echo "Unsupported TYPE in config.json: $TYPE. Only 'frontend_cloudfront_s3' is supported."
  exit 1
fi

# === LOAD APP INFO FROM projects_config.json ===
APP_NAME=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" '.[$PROJECT][$APP].APP_NAME' "$PROJECTS_CONFIG_FILE")
REPO_HTTP=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" '.[$PROJECT][$APP].REPO_HTTP' "$PROJECTS_CONFIG_FILE")

if [[ "$APP_NAME" == "null" || "$REPO_HTTP" == "null" ]]; then
  echo "App '$APP' not found in $PROJECTS_CONFIG_FILE"
  exit 1
fi

# === LOAD ENVIRONMENT CONFIG VALUES ===
BUILD_DIR=$(jq -r ."$ENVIRONMENT".BUILD_DIR "$CONFIG_FILE")
BUCKET_S3_RELEASE=$(jq -r ."$ENVIRONMENT".BUCKET_S3_RELEASE "$CONFIG_FILE")
BUCKET_S3_BUILD=$(jq -r ."$ENVIRONMENT".BUCKET_S3_BUILD "$CONFIG_FILE")
BUCKET_S3_PREFIX=$(jq -r ."$ENVIRONMENT".BUCKET_S3_PREFIX "$CONFIG_FILE")
CLOUDFRONT_DIST_ID=$(jq -r ."$ENVIRONMENT".CLOUDFRONT_DIST_ID "$CONFIG_FILE")
INVALIDATION_PATHS=$(jq -r ."$ENVIRONMENT".CLOUDFRONT_INVALIDATION_PATHS "$CONFIG_FILE")

if [[ -z "$BUILD_DIR" || "$BUILD_DIR" == "null" || \
      -z "$BUCKET_S3_RELEASE" || "$BUCKET_S3_RELEASE" == "null" || \
      -z "$BUCKET_S3_BUILD" || "$BUCKET_S3_BUILD" == "null" || \
      -z "$BUCKET_S3_PREFIX" || "$BUCKET_S3_PREFIX" == "null" || \
      -z "$CLOUDFRONT_DIST_ID" || "$CLOUDFRONT_DIST_ID" == "null" || \
      -z "$INVALIDATION_PATHS" || "$INVALIDATION_PATHS" == "null" ]]; then
  echo "❌ Missing or invalid configuration values for environment: $ENVIRONMENT"
  exit 1
fi

# === CLONE REPOSITORY ===
if [[ -z "$GIT_USERNAME" || -z "$GIT_TOKEN" ]]; then
  echo "Missing GIT_USERNAME or GIT_TOKEN environment variables"
  exit 1
fi

GIT_BRANCH=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" --arg ENVAPP "$ENVIRONMENT" '.[$PROJECT][$APP].GIT_BANCHES[$ENVAPP]' "$PROJECTS_CONFIG_FILE")

if [[ -z "$GIT_BRANCH" || "$GIT_BRANCH" == "null" ]]; then
  echo "Missing GIT_BRANCH for environment '$ENVIRONMENT' in config.json"
  exit 1
fi

UUID=$(uuidgen)
APP_PATH="/tmp/${APP_NAME}/${UUID}"

echo "Cloning repository into $APP_PATH..."
AUTH_REPO_URL=$(echo "$REPO_HTTP" | sed "s#https://#https://${GIT_USERNAME}:${GIT_TOKEN}@#")
git clone "$AUTH_REPO_URL" "$APP_PATH" || { echo "Failed to clone repository"; exit 1; }

# === CHECKOUT ENVIRONMENT BRANCH ===
cd "$APP_PATH" || exit 1
if git ls-remote --exit-code --heads origin "$GIT_BRANCH" &>/dev/null; then
  git fetch origin "$GIT_BRANCH"
  git checkout -b "$GIT_BRANCH" origin/"$GIT_BRANCH"
  git branch
else
  echo "Remote branch '$GIT_BRANCH' does not exist in repository"
  exit 1
fi

# === GET VERSION ===
PACKAGE_JSON="$APP_PATH/package.json"
if [[ ! -f "$PACKAGE_JSON" ]]; then
  echo "package.json not found in $APP_PATH"
  exit 1
fi

VERSION=$(jq -r .version "$PACKAGE_JSON")
if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
  echo "Could not extract version from package.json"
  exit 1
fi

# === BUILD PROJECT ===
echo "Entering app directory: $APP_PATH"
cd "$APP_PATH" || exit 1

# === INSTALL DEPENDENCIES ===
if [[ -d "node_modules" ]]; then
  echo "Removing existing node_modules..."
  rm -rf node_modules
fi

echo "Installing npm dependencies..."
npm install || { echo "npm install failed"; exit 1; }

echo "Building the project..."
npm run build || { echo "npm run build failed"; exit 1; }

# === CREATE TAR.GZ ARCHIVE ===
ARCHIVE_NAME="${APP_NAME}-${VERSION}.tar.gz"
ARCHIVE_PATH="/tmp/$ARCHIVE_NAME"

echo "Creating archive: $ARCHIVE_PATH from $BUILD_DIR..."
tar -czf "$ARCHIVE_PATH" -C "$BUILD_DIR" . || { echo "Error creating archive."; exit 1; }

# === UPLOAD ARCHIVE TO BUILD BUCKET ===
S3_ARCHIVE_PATH="s3://${BUCKET_S3_BUILD}${BUCKET_S3_PREFIX}/${ARCHIVE_NAME}"
echo "Uploading archive to $S3_ARCHIVE_PATH..."
aws s3 cp "$ARCHIVE_PATH" "$S3_ARCHIVE_PATH" || { echo "Error uploading archive to S3."; exit 1; }

# === DELETE EXISTING CONTENT FROM RELEASE BUCKET ===
echo "Deleting all objects from s3://$BUCKET_S3_RELEASE..."
aws s3 rm "s3://$BUCKET_S3_RELEASE" --recursive || { echo "Error deleting contents of release bucket."; exit 1; }

# === SYNC BUILD_DIR TO RELEASE BUCKET ===
echo "Syncing $BUILD_DIR with s3://$BUCKET_S3_RELEASE..."
aws s3 sync "$BUILD_DIR" "s3://$BUCKET_S3_RELEASE" --delete || { echo "Error syncing to release bucket."; exit 1; }

# === INVALIDATE CLOUDFRONT CACHE ===
echo "Invalidating CloudFront cache for distribution $CLOUDFRONT_DIST_ID..."
aws cloudfront create-invalidation --distribution-id "$CLOUDFRONT_DIST_ID" --paths "$INVALIDATION_PATHS" || { echo "Error invalidating CloudFront cache."; exit 1; }

echo "Cleaning up $APP_PATH..."
rm -rf "$APP_PATH"

echo "✅ Deployment complete for app '$PROJECT/$APP' in environment '$ENVIRONMENT'"
