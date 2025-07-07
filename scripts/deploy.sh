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
  echo "Missing required parameters: --project=project1 --app=app1 --env=dev"
  exit 1
fi

if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "qa" && "$ENVIRONMENT" != "prod" ]]; then
  echo "Invalid environment: $ENVIRONMENT"
  echo "Valid values are: dev, qa, prod"
  exit 1
fi

# === VALIDATE AWS CREDENTIALS ===
REQUIRED_VARS=("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_SESSION_TOKEN")
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var}" ]]; then
    echo "Missing AWS credential: $var"
    echo "Please run: source awsconfig --profile <profile_name>"
    exit 1
  fi
done

# === CHECK PROJECTS PATH FILE ===
PROJECTS_CONFIG_FILE="/deploy_projects/projects_config.json"
if [[ ! -f "$PROJECTS_CONFIG_FILE" ]]; then
  echo "File 'projects_config.json' not found."
  echo "Please create it following the structure in 'projects_path.sample.json'"
  exit 1
fi

# === LOAD CONFIG FILE ===
CONFIG_FILE="/deploy_projects/$PROJECT/$APP/config.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Configuration file not found at $CONFIG_FILE"
  exit 1
fi

# === READ TYPE FROM CONFIG ===
TYPE=$(jq -r '.general.TYPE' "$CONFIG_FILE")
if [[ -z "$TYPE" || "$TYPE" == "null" ]]; then
  echo "Missing or invalid 'general.TYPE' in config.json"
  exit 1
fi

# === CONFIG DEPENDENCIES ===
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"
nvm use default

# === MARK START TIME ===
START_TIME=$(date +%s)
START_HUMAN=$(date "+%Y-%m-%d %H:%M:%S")
echo "🕐 Deployment started at: $START_HUMAN"

echo "pipeline type: $TYPE"

# === DISPATCH TO CORRECT PIPELINE ===
case "$TYPE" in
  frontend_cloudfront_s3)
    deploy_frontend_cf --project="$PROJECT" --app="$APP" --env="$ENVIRONMENT"
    ;;
  frontend_ecs_fargate)
    deploy_frontend_ecs --project="$PROJECT" --app="$APP" --env="$ENVIRONMENT"
    ;;
  webservice_sls_python)
    deploy_sls --project="$PROJECT" --app="$APP" --env="$ENVIRONMENT"
    ;;
  webservice_ecs_fargate)
    deploy_ecs --project="$PROJECT" --app="$APP" --env="$ENVIRONMENT"
    ;;
  *)
    echo "Unknown pipeline type: $TYPE"
    exit 1
    ;;
esac

# === MARK END TIME AND DURATION ===
END_TIME=$(date +%s)
END_HUMAN=$(date "+%Y-%m-%d %H:%M:%S")
ELAPSED=$((END_TIME - START_TIME))

# Format duration to HH:MM:SS
HOURS=$((ELAPSED / 3600))
MINUTES=$(((ELAPSED % 3600) / 60))
SECONDS=$((ELAPSED % 60))
DURATION=$(printf "%02dh:%02dm:%02ds" $HOURS $MINUTES $SECONDS)

# === FINAL SUMMARY ===
echo ""
echo "==========================================="
echo "✅ Deployment finished at: $END_HUMAN"
echo "📊 Duration: $DURATION"
echo "🕐 Started:  $START_HUMAN"
echo "🛑 Ended:    $END_HUMAN"
echo "==========================================="
