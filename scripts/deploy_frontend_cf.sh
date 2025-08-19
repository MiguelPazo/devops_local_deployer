#!/bin/bash

log() {
  echo "$(date +"%Y-%m-%d %H:%M:%S") - $*"
}

# === PARSE ARGUMENTS ===
for arg in "$@"; do
  case $arg in
    --project=*) PROJECT="${arg#*=}" ;;
    --app=*) APP="${arg#*=}" ;;
    --env=*) ENVIRONMENT="${arg#*=}" ;;
    *) log "Unknown argument: $arg"; exit 1 ;;
  esac
done

export AWS_PAGER=""

if [[ -z "$PROJECT" || -z "$APP" || -z "$ENVIRONMENT" ]]; then
  log "Params required: --project=project1 --app=app1 --env=dev"
  exit 1
fi

# === CHECK DEPENDENCIES ===
for cmd in aws jq tar npm git; do
  if ! command -v $cmd &> /dev/null; then
    log "$cmd is not installed. Please install it before running this script."
    exit 1
  fi
done

# === LOAD CONFIG FILE PATHS ===
BASE_DIR="/deploy_projects/$PROJECT"
CONFIG_FILE="$BASE_DIR/$APP/config.json"
PROJECTS_CONFIG_FILE="/deploy_projects/projects_config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  log "Configuration file '$CONFIG_FILE' not found."
  exit 1
fi

if [[ ! -f "$PROJECTS_CONFIG_FILE" ]]; then
  log "projects_config.json file not found"
  exit 1
fi

# === VALIDATE TYPE ===
TYPE=$(jq -r '.general.TYPE' "$CONFIG_FILE")
if [[ "$TYPE" != "frontend_cloudfront_s3" ]]; then
  log "Unsupported TYPE in config.json: $TYPE. Only 'frontend_cloudfront_s3' is supported."
  exit 1
fi

# === LOAD APP INFO FROM projects_config.json ===
APP_NAME=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" '.[$PROJECT][$APP].APP_NAME' "$PROJECTS_CONFIG_FILE")
REPO_HTTP=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" '.[$PROJECT][$APP].REPO_HTTP' "$PROJECTS_CONFIG_FILE")

if [[ "$APP_NAME" == "null" || "$REPO_HTTP" == "null" ]]; then
  log "App '$APP' not found in $PROJECTS_CONFIG_FILE"
  exit 1
fi

# === LOAD ENVIRONMENT CONFIG VALUES ===
NODEJS_VERSION=$(jq -r ."$ENVIRONMENT".NODEJS_VERSION "$CONFIG_FILE")
NPM_VERSION=$(jq -r ."$ENVIRONMENT".NPM_VERSION "$CONFIG_FILE")
BUILD_DIR=$(jq -r ."$ENVIRONMENT".BUILD_DIR "$CONFIG_FILE")
BUCKET_S3_PUBLISH=$(jq -r ."$ENVIRONMENT".BUCKET_S3_PUBLISH "$CONFIG_FILE")
BUCKET_S3_RELEASE=$(jq -r ."$ENVIRONMENT".BUCKET_S3_RELEASE "$CONFIG_FILE")
BUCKET_S3_RELEASE_PREFIX=$(jq -r ."$ENVIRONMENT".BUCKET_S3_RELEASE_PREFIX "$CONFIG_FILE")
CLOUDFRONT_DIST_ID=$(jq -r ."$ENVIRONMENT".CLOUDFRONT_DIST_ID "$CONFIG_FILE")
CLOUDFRONT_INVALIDATION_PATHS=$(jq -r ."$ENVIRONMENT".CLOUDFRONT_INVALIDATION_PATHS "$CONFIG_FILE")

if [[ -z "$NODEJS_VERSION" || "$NODEJS_VERSION" == "null" || \
      -z "$NPM_VERSION" || "$NPM_VERSION" == "null" || \
      -z "$BUILD_DIR" || "$BUILD_DIR" == "null" || \
      -z "$BUCKET_S3_PUBLISH" || "$BUCKET_S3_PUBLISH" == "null" || \
      -z "$BUCKET_S3_RELEASE" || "$BUCKET_S3_RELEASE" == "null" || \
      -z "$BUCKET_S3_RELEASE_PREFIX" || "$BUCKET_S3_RELEASE_PREFIX" == "null" || \
      -z "$CLOUDFRONT_DIST_ID" || "$CLOUDFRONT_DIST_ID" == "null" || \
      -z "$CLOUDFRONT_INVALIDATION_PATHS" || "$CLOUDFRONT_INVALIDATION_PATHS" == "null" ]]; then
  log "❌ Missing or invalid configuration values for environment: $ENVIRONMENT"
  exit 1
fi

# === CLONE REPOSITORY ===
if [[ -z "$GIT_USERNAME" || -z "$GIT_TOKEN" ]]; then
  log "Missing GIT_USERNAME or GIT_TOKEN environment variables"
  exit 1
fi

GIT_BRANCH=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" --arg ENVAPP "$ENVIRONMENT" '.[$PROJECT][$APP].GIT_BANCHES[$ENVAPP]' "$PROJECTS_CONFIG_FILE")

if [[ -z "$GIT_BRANCH" || "$GIT_BRANCH" == "null" ]]; then
  log "Missing GIT_BRANCH for environment '$ENVIRONMENT' in config.json"
  exit 1
fi

UUID=$(uuidgen)
APP_PATH="/tmp/${APP_NAME}/${UUID}"

log "Cloning repository into $APP_PATH..."
AUTH_REPO_URL=$(echo "$REPO_HTTP" | sed "s#https://#https://${GIT_USERNAME}:${GIT_TOKEN}@#")
git clone "$AUTH_REPO_URL" "$APP_PATH" || { log "Failed to clone repository"; exit 1; }

# === CHECKOUT ENVIRONMENT BRANCH ===
cd "$APP_PATH" || exit 1
if git ls-remote --exit-code --heads origin "$GIT_BRANCH" &>/dev/null; then
  git fetch origin "$GIT_BRANCH"
  git checkout -b "$GIT_BRANCH" origin/"$GIT_BRANCH"
  git branch
else
  log "Remote branch '$GIT_BRANCH' does not exist in repository"
  exit 1
fi

# === GET VERSION ===
PACKAGE_JSON="$APP_PATH/package.json"
if [[ ! -f "$PACKAGE_JSON" ]]; then
  log "package.json not found in $APP_PATH"
  exit 1
fi

VERSION=$(jq -r .version "$PACKAGE_JSON")
if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
  log "Could not extract version from package.json"
  exit 1
fi

# === ENSURE NVM IS LOADED ===
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"

# === INSTALL NODEJS & NPM VERSION IF NEEDED ===
if ! nvm ls "$NODEJS_VERSION" | grep -q "$NODEJS_VERSION"; then
  log "Installing Node.js $NODEJS_VERSION..."
  nvm install "$NODEJS_VERSION"
fi

nvm use "$NODEJS_VERSION"

CURRENT_NPM_VERSION=$(npm -v)

if [[ "$CURRENT_NPM_VERSION" != "$NPM_VERSION" ]]; then
  log "Installing NPM $NPM_VERSION..."
  npm install -g "npm@$NPM_VERSION" || { log "Failed to install NPM $NPM_VERSION"; exit 1; }
fi

# === COPY .env FILE BASED ON ENVIRONMENT ===
ENV_FILE_SRC="$BASE_DIR/$APP/deploy/$ENVIRONMENT/.env"
ENV_FILE_DEST="$APP_PATH/.env"

if [[ -f "$ENV_FILE_SRC" ]]; then
  log "Copying $ENV_FILE_SRC to $ENV_FILE_DEST"
  cp -f "$ENV_FILE_SRC" "$ENV_FILE_DEST" || { log "Failed to copy .env file"; exit 1; }
else
  log "⚠️ Warning: .env file not found for environment '$ENVIRONMENT' at $ENV_FILE_SRC"
fi

# === BUILD PROJECT ===
log "Entering app directory: $APP_PATH"
cd "$APP_PATH" || exit 1

# === INSTALL DEPENDENCIES ===
if [[ -d "node_modules" ]]; then
  log "Removing existing node_modules..."
  rm -rf node_modules
fi

log "Installing npm dependencies..."
npm install || { log "npm install failed"; exit 1; }

log "Building the project..."
npm run build || { log "npm run build failed"; exit 1; }

# === CREATE TAR.GZ ARCHIVE ===
ARCHIVE_NAME="${APP_NAME}-${VERSION}.tar.gz"
ARCHIVE_PATH="/tmp/$ARCHIVE_NAME"

log "Creating archive: $ARCHIVE_PATH from $BUILD_DIR..."
tar -czf "$ARCHIVE_PATH" -C "$BUILD_DIR" . || { log "Error creating archive."; exit 1; }

# === UPLOAD ARCHIVE TO BUILD BUCKET ===
S3_ARCHIVE_PATH="s3://${BUCKET_S3_RELEASE}${BUCKET_S3_RELEASE_PREFIX}/${ARCHIVE_NAME}"
log "Uploading archive to $S3_ARCHIVE_PATH..."
aws s3 cp "$ARCHIVE_PATH" "$S3_ARCHIVE_PATH" || { log "Error uploading archive to S3."; exit 1; }

# === DELETE EXISTING CONTENT FROM RELEASE BUCKET ===
log "Deleting all objects from s3://$BUCKET_S3_PUBLISH..."
aws s3 rm "s3://$BUCKET_S3_PUBLISH" --recursive || { log "Error deleting contents of release bucket."; exit 1; }

# === SYNC BUILD_DIR TO RELEASE BUCKET ===
log "Syncing $BUILD_DIR with s3://$BUCKET_S3_PUBLISH..."
aws s3 sync "$BUILD_DIR" "s3://$BUCKET_S3_PUBLISH" --delete || { log "Error syncing to release bucket."; exit 1; }

# === INVALIDATE CLOUDFRONT CACHE ===
log "Invalidating CloudFront cache for distribution $CLOUDFRONT_DIST_ID..."
aws cloudfront create-invalidation --distribution-id "$CLOUDFRONT_DIST_ID" --paths "$CLOUDFRONT_INVALIDATION_PATHS" || { log "Error invalidating CloudFront cache."; exit 1; }

log "Cleaning up $APP_PATH..."
rm -rf "$APP_PATH"

log "✅ Deployment complete for app '$PROJECT/$APP' in environment '$ENVIRONMENT'"
