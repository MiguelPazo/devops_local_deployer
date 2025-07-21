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
for cmd in aws jq docker git xmllint; do
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
if [[ "$TYPE" != "webservice_sam_java" ]]; then
  log "Unsupported TYPE in config.json: $TYPE. Only 'webservice_sam_java' is supported."
  exit 1
fi

# === LOAD APP INFO FROM projects_config.json ===
APP_NAME=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" '.[$PROJECT][$APP].APP_NAME' "$PROJECTS_CONFIG_FILE")
REPO_HTTP=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" '.[$PROJECT][$APP].REPO_HTTP' "$PROJECTS_CONFIG_FILE")

if [[ "$APP_NAME" == "null" || "$REPO_HTTP" == "null" ]]; then
  log "App '$APP' not found in $PROJECTS_CONFIG_FILE"
  exit 1
fi

# === LOAD CONFIGURATION ===
JAVA_VERSION=$(jq -r ."$ENVIRONMENT".JAVA_VERSION "$CONFIG_FILE")
MAVEN_VERSION=$(jq -r ."$ENVIRONMENT".MAVEN_VERSION "$CONFIG_FILE")
BUILD_COMMAND=$(jq -r ."$ENVIRONMENT".BUILD_COMMAND "$CONFIG_FILE")

if [[ -z "$JAVA_VERSION" || "$JAVA_VERSION" == "null" || \
      -z "$MAVEN_VERSION" || "$MAVEN_VERSION" == "null" || \
      -z "$BUILD_COMMAND" || "$BUILD_COMMAND" == "null" ]]; then
  log "❌ Missing or invalid configuration values (empty or 'null')."
  exit 1
fi

# === CLONE REPOSITORY ===
if [[ -z "$GIT_USERNAME" || -z "$GIT_TOKEN" ]]; then
  log "Missing GIT_USERNAME or GIT_TOKEN environment variables"
  exit 1
fi

GIT_BRANCH=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" --arg ENVAPP "$ENVIRONMENT" '.[$PROJECT][$APP].GIT_BANCHES[$ENVAPP]' "$PROJECTS_CONFIG_FILE")

if [[ -z "$GIT_BRANCH" || "$GIT_BRANCH" == "null" ]]; then
  log "Missing GIT_BRANCH for project '$PROJECT' and '$APP' for environment '$ENVIRONMENT' in $PROJECTS_CONFIG_FILE"
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

# === GET VERSION FROM pom.xml ===
POM_FILE="$APP_PATH/pom.xml"
if [[ ! -f "$POM_FILE" ]]; then
  log "pom.xml not found in $APP_PATH"
  exit 1
fi

VERSION=$(xmllint --xpath "/*[local-name()='project']/*[local-name()='version']/text()" "$POM_FILE" 2>/dev/null)
if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
  log "Could not extract version from package.json"
  exit 1
fi

# Load SDKMAN
if [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
  source "$HOME/.sdkman/bin/sdkman-init.sh"
else
  log "SDKMAN is not available at \$HOME/.sdkman"
  exit 1
fi

# Install Java
log "Installing Java version $JAVA_VERSION using SDKMAN..."
echo "n" | sdk install java $JAVA_VERSION || { log "Failed to install Java"; exit 1; }

# Install Maven
log "Installing Maven version $MAVEN_VERSION using SDKMAN..."
echo "n" | sdk install maven $MAVEN_VERSION || { log "Failed to install Maven"; exit 1; }

# Activate versions
sdk use java $JAVA_VERSION || { log "Failed to activate Java $JAVA_VERSION"; exit 1; }
sdk use maven $MAVEN_VERSION || { log "Failed to activate Maven $MAVEN_VERSION"; exit 1; }

# === COPY PROPERTIES FILE ===
log "Copying application.properties for environment '$ENVIRONMENT'..."
PARAMS_FILE="$BASE_DIR/deploy/$ENVIRONMENT/application.properties"
DEST_PARAMS_FILE="$APP_PATH/src/main/resources/application.properties"
TOML_FILE="$BASE_DIR/samconfig.toml"
DEST_TOML_FILE="$APP_PATH/samconfig.toml"

cp -f "$PARAMS_FILE" "$DEST_PARAMS_FILE"
cp -f "$TOML_FILE" "$DEST_TOML_FILE"

# === BUILD JAVA APP ===
cd "$APP_PATH"
log "Running build command: $BUILD_COMMAND"
eval "$BUILD_COMMAND"
if [[ $? -ne 0 ]]; then
  log "Build command failed"
  exit 1
fi

# === SAM BUILD ===
log "Running sam build..."
sam build
if [[ $? -ne 0 ]]; then
  log "SAM build failed"
  exit 1
fi

# === SAM DEPLOY ===
log "Deploying with SAM to environment '$ENVIRONMENT'..."
sam deploy --config-env "$ENVIRONMENT"
if [[ $? -ne 0 ]]; then
  log "SAM deploy failed"
  exit 1
fi

log "✅ SAM Java Lambda deployed successfully to '$ENVIRONMENT'"
