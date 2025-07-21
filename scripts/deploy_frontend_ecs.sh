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

# === LOAD CONFIG AND PATHS ===
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
if [[ "$TYPE" != "frontend_ecs_fargate" ]]; then
  log "Invalid pipeline type: $TYPE. This script only handles 'frontend_ecs_fargate' type."
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
  log "❌ Missing or invalid ECS configuration values (empty or 'null')."
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

ECR_IMAGE="${ECR_REGISTRY}/${ECR_REPOSITORY}:${VERSION}"

# === COPY .env FILE BASED ON ENVIRONMENT ===
ENV_FILE_SRC="$BASE_DIR/$APP/deploy/$ENVIRONMENT/.env"
ENV_FILE_DEST="$APP_PATH/.env"

if [[ -f "$ENV_FILE_SRC" ]]; then
  log "Copying $ENV_FILE_SRC to $ENV_FILE_DEST"
  cp -f "$ENV_FILE_SRC" "$ENV_FILE_DEST" || { log "Failed to copy .env file"; exit 1; }
else
  log "⚠️ Warning: .env file not found for environment '$ENVIRONMENT' at $ENV_FILE_SRC"
fi

# === DOCKER LOGIN ===
log "Logging in to ECR..."
aws ecr get-login-password --region "$ECR_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY" || { log "ECR login failed"; exit 1; }

# === DOCKER BUILD ===
BUILD_ARGS=()
if [[ "$DOCKER_BUILD_ARGS" != "null" ]]; then
  for pair in $(echo "$DOCKER_BUILD_ARGS" | jq -c '.[]'); do
    key=$(echo "$pair" | jq -r '.key')
    value=$(echo "$pair" | jq -r '.value')
    BUILD_ARGS+=("--build-arg" "${key}=${value}")
  done
fi

log "Building Docker image $ECR_IMAGE"
docker build -t "$ECR_IMAGE" "${BUILD_ARGS[@]}" --force-rm=true --no-cache=true . || { log "Docker build failed"; exit 1; }

# === DOCKER PUSH ===
log "Pushing image to ECR: $ECR_IMAGE"
docker push "$ECR_IMAGE" || { log "Docker push failed"; exit 1; }

# === TASK DEFINITION UPDATE ===
TASK_DEF_SRC="$BASE_DIR/$APP/deploy/${ENVIRONMENT}/task-definition.json"
TASK_DEF_TMP="/tmp/${APP_NAME}-${ENVIRONMENT}-task-definition.json"

if [[ ! -f "$TASK_DEF_SRC" ]]; then
  log "Task definition not found at $TASK_DEF_SRC"
  exit 1
fi

log "Updating task definition with new image..."
jq --arg IMAGE "$ECR_IMAGE" '.containerDefinitions |= map(.image = $IMAGE)' "$TASK_DEF_SRC" > "$TASK_DEF_TMP" || { log "Failed to prepare task definition"; exit 1; }

log "Registering task definition..."
TASK_DEF_OUTPUT=$(aws ecs register-task-definition --cli-input-json file://"$TASK_DEF_TMP" --region "$ECR_REGION")
TASK_DEF_ARN=$(echo "$TASK_DEF_OUTPUT" | jq -r '.taskDefinition.taskDefinitionArn')
TASK_DEF_FAMILY=$(echo "$TASK_DEF_OUTPUT" | jq -r '.taskDefinition.family')
TASK_DEF_REVISION=$(echo "$TASK_DEF_OUTPUT" | jq -r '.taskDefinition.revision')

log "Registered new task definition: ${TASK_DEF_FAMILY}:${TASK_DEF_REVISION}"

if [[ -z "$TASK_DEF_ARN" ]]; then
  log "Failed to register task definition"
  exit 1
fi

log "Updating ECS service $ECS_SERVICE in cluster $ECS_CLUSTER"

aws ecs update-service \
  --cluster "$ECS_CLUSTER" \
  --service "$ECS_SERVICE" \
  --task-definition "$TASK_DEF_ARN" \
  --region "$ECR_REGION" || { log "Failed to update ECS service"; exit 1; }

# === WAIT FOR SERVICE STABILITY ===
log "Waiting for ECS service deployment to complete (timeout: 10 minutes)..."
MAX_WAIT=600
SLEEP_INTERVAL=10
ELAPSED=0
SERVICE_JSON=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$ECR_REGION")
DEPLOYMENTS=$(echo "$SERVICE_JSON" | jq '.services[0].deployments')
PRIMARY=$(echo "$DEPLOYMENTS" | jq '[.[] | select(.status == "PRIMARY")][0]')
ACTIVE=$(echo "$DEPLOYMENTS" | jq '[.[] | select(.status == "ACTIVE")][0]')
DEPLOYMENT_ID=$(echo "$PRIMARY" | jq -r '.id')
PENDING_TASK_DEF=$(echo "$PRIMARY" | jq -r '.taskDefinition')
CURRENT_TASK_DEF=$(echo "$ACTIVE" | jq -r '.taskDefinition')

while true; do
  SERVICE_JSON=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$ECR_REGION")
  DEPLOYMENT=$(echo "$SERVICE_JSON" | jq --arg ID "$DEPLOYMENT_ID" '.services[0].deployments[] | select(.id == $ID)')

  ROLLOUT_STATE=$(echo "$DEPLOYMENT" | jq -r '.rolloutState')
  ROLLOUT_REASON=$(echo "$DEPLOYMENT" | jq -r '.rolloutStateReason')

  log "Deployment ID: $DEPLOYMENT_ID | State: $ROLLOUT_STATE"
  log "Current task definition: $CURRENT_TASK_DEF"
  [[ "$PENDING_TASK_DEF" != "$CURRENT_TASK_DEF" ]] && log "Pending task definition: $PENDING_TASK_DEF"

  if [[ "$ROLLOUT_STATE" == "COMPLETED" ]]; then
    log "✅ Deployment successful: COMPLETED"
    break
  elif [[ "$ROLLOUT_STATE" == "FAILED" || "$ROLLOUT_STATE" == "ROLLED_BACK" ]]; then
    log "❌ Deployment failed: $ROLLOUT_REASON"
    exit 1
  fi

  if (( ELAPSED >= MAX_WAIT )); then
    log "❌ Timeout: ECS service did not complete deployment in $MAX_WAIT seconds."
    exit 1
  fi

  sleep "$SLEEP_INTERVAL"
  (( ELAPSED += SLEEP_INTERVAL ))
done

log "Cleaning up $APP_PATH..."
rm -rf "$APP_PATH"

log "✅ Deployment complete for app '$PROJECT/$APP' in environment '$ENVIRONMENT'"
