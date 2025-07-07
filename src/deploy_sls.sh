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

# === VALIDATE SLS CREDENTIAL ===
if [[ -z "$SERVERLESS_ACCESS_KEY" ]]; then
  echo "Missing SLS credential: SERVERLESS_ACCESS_KEY"
  exit 1
fi

# === CHECK DEPENDENCIES ===
for cmd in jq npm sls pyenv yq; do
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
if [[ "$TYPE" != "webservice_sls_python" ]]; then
  echo "Invalid pipeline type: $TYPE. This script only handles 'webservice_sls_python' type."
  exit 1
fi

# === LOAD APP INFO FROM projects_config.json ===
APP_NAME=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" '.[$PROJECT][$APP].APP_NAME' "$PROJECTS_CONFIG_FILE")
REPO_HTTP=$(jq -r --arg PROJECT "$PROJECT" --arg APP "$APP" '.[$PROJECT][$APP].REPO_HTTP' "$PROJECTS_CONFIG_FILE")

if [[ "$APP_NAME" == "null" || "$REPO_HTTP" == "null" ]]; then
  echo "App '$APP' not found in $PROJECTS_CONFIG_FILE"
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

# === READ PYTHON RUNTIME FROM serverless.yaml ===
if [[ -f "$APP_PATH/serverless.yaml" ]]; then
  SERVERLESS_YML="$APP_PATH/serverless.yaml"
elif [[ -f "$APP_PATH/serverless.yml" ]]; then
  SERVERLESS_YML="$APP_PATH/serverless.yml"
else
  echo "Neither serverless.yaml nor serverless.yml found in $APP_PATH"
  exit 1
fi


PYTHON_RUNTIME=$(yq '.provider.runtime' "$SERVERLESS_YML")
if [[ -z "$PYTHON_RUNTIME" || "$PYTHON_RUNTIME" != python* ]]; then
  echo "Unable to determine python runtime from serverless.yaml"
  exit 1
fi

PYTHON_VERSION_BASE="${PYTHON_RUNTIME#python}"  # e.g. "3.10"
PYTHON_VERSION_INSTALLED=$(pyenv versions --bare | grep -E "^$PYTHON_VERSION_BASE([.][0-9]+)?$" | sort -V | tail -n1)

if [[ -z "$PYTHON_VERSION_INSTALLED" ]]; then
  echo "Installing Python $PYTHON_VERSION_BASE with pyenv..."
  pyenv install "$PYTHON_VERSION_BASE" || { echo "Failed to install Python $PYTHON_VERSION_BASE"; exit 1; }
  PYTHON_VERSION_INSTALLED="$PYTHON_VERSION_BASE"
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

# === REMOVE provider.profile FROM serverless.yaml ===
echo "Removing 'provider.profile' from serverless.yaml..."
yq 'del(.provider.profile)' "$SERVERLESS_YML" > "$SERVERLESS_YML.tmp" && mv "$SERVERLESS_YML.tmp" "$SERVERLESS_YML"

# === COPY PARAMS FILE ===
PARAM_SRC="$BASE_DIR/$APP/deploy/$ENVIRONMENT/params-$ENVIRONMENT.yml"
PARAM_DEST="$APP_PATH/env/params-$ENVIRONMENT.yml"

if [[ ! -f "$PARAM_SRC" ]]; then
  echo "Params file '$PARAM_SRC' not found."
  exit 1
fi

mkdir -p "$APP_PATH/env"
cp "$PARAM_SRC" "$PARAM_DEST" || { echo "Failed to copy params file"; exit 1; }

# === DEPLOY SERVERLESS WITH PYENV_EXEC ===
echo "Deploying with Serverless Framework using Python $PYTHON_VERSION_INSTALLED..."
PYENV_VERSION="$PYTHON_VERSION_INSTALLED" pyenv exec sls deploy -s "$ENVIRONMENT"
DEPLOY_EXIT_CODE=$?

# === CLEANUP PARAMS FILE ===
echo "Cleaning up params file..."
rm -f "$PARAM_DEST"

if [[ $DEPLOY_EXIT_CODE -ne 0 ]]; then
  echo "❌ sls deploy failed"
  exit 1
fi

echo "Cleaning up $APP_PATH..."
rm -rf "$APP_PATH"

echo "✅ SLS deployment complete for '$PROJECT/$APP' in environment '$ENVIRONMENT'"
