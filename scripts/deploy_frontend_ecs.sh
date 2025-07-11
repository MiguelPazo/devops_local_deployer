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

# === CHECK DEPENDENCIES ===
for cmd in aws jq npm; do
  if ! command -v $cmd &> /dev/null; then
    echo "$cmd is not installed. Please install it before running this script."
    exit 1
  fi
done

# === LOAD CONFIG AND PATHS ===
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
if [[ "$TYPE" != "frontend_ecs_fargate" ]]; then
  echo "Invalid pipeline type: $TYPE. This script only handles 'frontend_ecs_fargate' type."
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
ECR_REPOSITORY=$(jq -r ."$ENVIRONMENT".ECR_REPOSITORY "$CONFIG_FILE")
ECR_REGISTRY=$(jq -r ."$ENVIRONMENT".ECR_REGISTRY "$CONFIG_FILE")
ECR_REGION=$(jq -r ."$ENVIRONMENT".ECR_REGION "$CONFIG_FILE")
ECS_CLUSTER=$(jq -r ."$ENVIRONMENT".ECS_CLUSTER "$CONFIG_FILE")
ECS_SERVICE=$(jq -r ."$ENVIRONMENT".ECS_SERVICE "$CONFIG_FILE")
DOCKER_BUILD_ARGS=$(jq -c ."$ENVIRONMENT".DOCKER_BUILD_ARGS "$CONFIG_FILE")

if [[ -z "$ECR_REPOSITORY" || "$ECR_REPOSITORY" == "null" || \
      -z "$ECR_REGISTRY" || "$ECR_REGISTRY" == "null" || \
      -z "$ECR_REGION" || "$ECR_REGION" == "null" || \
      -z "$ECS_CLUSTER" || "$ECS_CLUSTER" == "null" || \
      -z "$ECS_SERVICE" || "$ECS_SERVICE" == "null" ]]; then
  echo "❌ Missing or invalid ECS configuration values (empty or 'null')."
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

ECR_IMAGE="${ECR_REGISTRY}/${ECR_REPOSITORY}:${VERSION}"

# === ENSURE NVM IS LOADED ===
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"

# === INSTALL NODEJS & NPM VERSION IF NEEDED ===
if ! nvm ls "$NODEJS_VERSION" | grep -q "$NODEJS_VERSION"; then
  echo "Installing Node.js $NODEJS_VERSION..."
  nvm install "$NODEJS_VERSION"
fi

nvm use "$NODEJS_VERSION"

CURRENT_NPM_VERSION=$(npm -v)

if [[ "$CURRENT_NPM_VERSION" != "$NPM_VERSION" ]]; then
  echo "Installing NPM $NPM_VERSION..."
  npm install -g "npm@$NPM_VERSION" || { echo "Failed to install NPM $NPM_VERSION"; exit 1; }
fi

# === COPY .env FILE BASED ON ENVIRONMENT ===
ENV_FILE_SRC="$BASE_DIR/$APP/deploy/$ENVIRONMENT/.env"
ENV_FILE_DEST="$APP_PATH/.env"

if [[ -f "$ENV_FILE_SRC" ]]; then
  echo "Copying $ENV_FILE_SRC to $ENV_FILE_DEST"
  cp -f "$ENV_FILE_SRC" "$ENV_FILE_DEST" || { echo "Failed to copy .env file"; exit 1; }
else
  echo "⚠️ Warning: .env file not found for environment '$ENVIRONMENT' at $ENV_FILE_SRC"
fi

# === BUILD PROJECT ===
echo "Entering app directory: $APP_PATH"
cd "$APP_PATH" || exit 1

if [[ -d "node_modules" ]]; then
  echo "Removing existing node_modules..."
  rm -rf node_modules
fi

echo "Installing npm dependencies..."
npm install || { echo "npm install failed"; exit 1; }

echo "Building the project..."
npm run build || { echo "npm run build failed"; exit 1; }

# === DOCKER LOGIN ===
echo "Logging in to ECR..."
aws ecr get-login-password --region "$ECR_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY" || { echo "ECR login failed"; exit 1; }

# === DOCKER BUILD ===
BUILD_ARGS=()
if [[ "$DOCKER_BUILD_ARGS" != "null" ]]; then
  for pair in $(echo "$DOCKER_BUILD_ARGS" | jq -c '.[]'); do
    key=$(echo "$pair" | jq -r '.key')
    value=$(echo "$pair" | jq -r '.value')
    BUILD_ARGS+=("--build-arg" "${key}=${value}")
  done
fi

echo "Building Docker image $ECR_IMAGE"
docker build -t "$ECR_IMAGE" "${BUILD_ARGS[@]}" --force-rm=true --no-cache=true . || { echo "Docker build failed"; exit 1; }

# === DOCKER PUSH ===
echo "Pushing image to ECR: $ECR_IMAGE"
docker push "$ECR_IMAGE" || { echo "Docker push failed"; exit 1; }

# === TASK DEFINITION UPDATE ===
TASK_DEF_SRC="$BASE_DIR/$APP/deploy/${ENVIRONMENT}/task-definition.json"
TASK_DEF_TMP="/tmp/${APP_NAME}-${ENVIRONMENT}-task-definition.json"

if [[ ! -f "$TASK_DEF_SRC" ]]; then
  echo "Task definition not found at $TASK_DEF_SRC"
  exit 1
fi

echo "Updating task definition with new image..."
jq --arg IMAGE "$ECR_IMAGE" '.containerDefinitions |= map(.image = $IMAGE)' "$TASK_DEF_SRC" > "$TASK_DEF_TMP" || { echo "Failed to prepare task definition"; exit 1; }

echo "Registering task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json file://"$TASK_DEF_TMP" --region "$ECR_REGION" | jq -r '.taskDefinition.taskDefinitionArn')
if [[ -z "$TASK_DEF_ARN" ]]; then
  echo "Failed to register task definition"
  exit 1
fi

echo "Updating ECS service $ECS_SERVICE in cluster $ECS_CLUSTER"
aws ecs update-service \
  --cluster "$ECS_CLUSTER" \
  --service "$ECS_SERVICE" \
  --task-definition "$TASK_DEF_ARN" \
  --region "$ECR_REGION" || { echo "Failed to update ECS service"; exit 1; }

# === WAIT FOR SERVICE STABILITY ===
echo "Waiting for ECS service to stabilize (timeout: 3 minutes)..."
MAX_WAIT=180
SLEEP_INTERVAL=5
ELAPSED=0

while true; do
  DESIRED=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$ECR_REGION" | jq -r '.services[0].desiredCount')
  RUNNING=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$ECR_REGION" | jq -r '.services[0].runningCount')

  echo "Desired: $DESIRED | Running: $RUNNING"

  if [[ "$DESIRED" == "$RUNNING" ]]; then
    echo "✅ ECS service is stable."
    break
  fi

  if (( ELAPSED >= MAX_WAIT )); then
    echo "❌ Timeout: ECS service did not stabilize in $MAX_WAIT seconds."
    exit 1
  fi

  sleep "$SLEEP_INTERVAL"
  (( ELAPSED += SLEEP_INTERVAL ))
done

echo "Cleaning up $APP_PATH..."
rm -rf "$APP_PATH"

echo "✅ Deployment complete for app '$PROJECT/$APP' in environment '$ENVIRONMENT'"
