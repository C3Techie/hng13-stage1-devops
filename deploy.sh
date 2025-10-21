#!/usr/bin/env bash

# DevOps Stage 1 — Automated Deployment Script
# - Single-file, production-grade bash script
# - Deploys a Dockerized app to a remote Linux server, configures Nginx, validates health
# - Implements: prompts + flags, logging, traps, idempotency, cleanup

set -Eeuo pipefail
IFS=$'\n\t'

########################################
# Global defaults and constants
########################################
SCRIPT_NAME=${0##*/}
START_TS=$(date +%Y%m%d-%H%M%S)
LOG_DIR=${LOG_DIR:-"$(pwd)/logs"}
LOG_FILE="$LOG_DIR/deploy_${START_TS}.log"

# Exit codes per stage
EC_INPUT=10
EC_GIT=20
EC_SSH=30
EC_REMOTE_SETUP=40
EC_DEPLOY=50
EC_NGINX=60
EC_VALIDATE=70
EC_CLEANUP=90

# Defaults (can be overridden by flags or prompts)
BRANCH="main"
SSH_PORT="22"
REMOTE_DIR=""
PROJECT_NAME=""
NON_INTERACTIVE="false"
CLEANUP_ONLY="false"

########################################
# Logging helpers
########################################
init_logging() {
  mkdir -p "$LOG_DIR"
  # Redirect all stdout/stderr to tee, keep interactive prompts clean by writing them to /dev/tty
  exec > >(tee -a "$LOG_FILE") 2>&1
  log info "Logging to $LOG_FILE"
}

log() {
  local level=$1; shift || true
  local msg=$*
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg"
}

die() {
  local code=$1; shift
  log error "$* (exit=$code)"
  exit "$code"
}

on_error() {
  local exit_code=$?
  local line_no=$1
  log error "Unexpected error at line $line_no (exit=$exit_code). See $LOG_FILE"
  exit "$exit_code"
}

trap 'on_error $LINENO' ERR
trap 'log info "Script finished. Log: $LOG_FILE"' EXIT

########################################
# Usage
########################################
usage() {
  cat <<USAGE
$SCRIPT_NAME - Automated Docker deployment to a remote Linux server

Required inputs (via flags or interactive prompts):
  --repo-url URL             Git repository URL (https://github.com/user/repo.git)
  --pat TOKEN                GitHub Personal Access Token (repo read access). Will not be logged.
  --ssh-user USER            SSH username for remote server
  --ssh-host HOST            Remote server IP or DNS name
  --ssh-key PATH             Path to private SSH key file
  --app-port PORT            Internal container app port to expose and proxy (e.g., 3000)

Optional:
  --branch NAME              Git branch to deploy (default: main)
  --ssh-port PORT            SSH port (default: 22)
  --project-name NAME        Override project/container/compose project name (defaults to repo name)
  --remote-dir PATH          Remote deploy dir (default: /opt/apps/<project-name>)
  --non-interactive          Fail if required inputs missing instead of prompting
  --cleanup                  Cleanup deployed resources on remote and exit
  --help                     Show this help

Examples:
  $SCRIPT_NAME --repo-url https://github.com/user/app.git --pat ***** \\
    --ssh-user ubuntu --ssh-host 203.0.113.10 --ssh-key ~/.ssh/id_rsa --app-port 3000

  $SCRIPT_NAME --cleanup --ssh-user ubuntu --ssh-host 203.0.113.10 --ssh-key ~/.ssh/id_rsa \
    --project-name app --remote-dir /opt/apps/app
USAGE
}

########################################
# Prompt helpers (keep secrets off logs)
########################################
prompt_var() {
  # $1=var_name, $2=prompt text, $3=secret(true/false), $4=default(optional)
  local __var_name=$1; shift
  local __prompt=$1; shift
  local __secret=${1:-false}; shift || true
  local __default=${1:-}; shift || true

  local __value=${!__var_name:-}
  if [[ -z "$__value" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die $EC_INPUT "Missing required input: $__var_name"
    fi
    if [[ -n "$__default" ]]; then
      printf '%s [%s]: ' "$__prompt" "$__default" > /dev/tty
    else
      printf '%s: ' "$__prompt" > /dev/tty
    fi
    if [[ "$__secret" == "true" ]]; then
      read -r -s __value < /dev/tty
      printf '\n' > /dev/tty
    else
      read -r __value < /dev/tty
    fi
    if [[ -z "$__value" && -n "$__default" ]]; then
      __value="$__default"
    fi
  fi
  printf -v "$__var_name" '%s' "$__value"
}

########################################
# Args parsing
########################################
REPO_URL=""
PAT=""
SSH_USER=""
SSH_HOST=""
SSH_KEY=""
APP_PORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --pat) PAT="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-host) SSH_HOST="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --app-port) APP_PORT="$2"; shift 2 ;;
    --project-name) PROJECT_NAME="$2"; shift 2 ;;
    --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE="true"; shift ;;
    --cleanup) CLEANUP_ONLY="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log warn "Unknown arg: $1"; usage; exit 0 ;;
  esac
done

init_logging

########################################
# Collect and validate inputs
########################################
prompt_var REPO_URL "Git repository URL (https)"
prompt_var PAT "GitHub Personal Access Token (will not echo)" true
prompt_var BRANCH "Git branch" false "${BRANCH}"
prompt_var SSH_USER "SSH username"
prompt_var SSH_HOST "SSH host (IP or DNS)"
prompt_var SSH_KEY "SSH private key path" false "${SSH_KEY}"
prompt_var APP_PORT "Application internal container port (e.g., 3000)"

if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME=$(basename "$REPO_URL")
  PROJECT_NAME=${PROJECT_NAME%.git}
fi

if [[ -z "$REMOTE_DIR" ]]; then
  REMOTE_DIR="/opt/apps/${PROJECT_NAME}"
fi

# Basic validation
[[ $REPO_URL =~ ^https?:// ]] || die $EC_INPUT "repo-url must be http(s) URL"
[[ -n "$PAT" ]] || die $EC_INPUT "PAT is required"
[[ -n "$SSH_USER" ]] || die $EC_INPUT "ssh-user is required"
[[ -n "$SSH_HOST" ]] || die $EC_INPUT "ssh-host is required"
[[ -n "$SSH_KEY" ]] || die $EC_INPUT "ssh-key is required"
[[ -f "$SSH_KEY" ]] || die $EC_INPUT "ssh-key file not found: $SSH_KEY"
[[ "$APP_PORT" =~ ^[0-9]{2,5}$ ]] || die $EC_INPUT "app-port must be a number"

log info "Project: $PROJECT_NAME | Branch: $BRANCH | Remote: $SSH_USER@$SSH_HOST:$SSH_PORT | Remote dir: $REMOTE_DIR | App port: $APP_PORT"

########################################
# Tooling checks
########################################
need_cmd() { command -v "$1" >/dev/null 2>&1 || die $EC_INPUT "Required command not found: $1"; }

need_cmd git; need_cmd ssh; need_cmd scp; need_cmd sed; need_cmd awk; need_cmd grep; need_cmd curl

########################################
# Local clone/pull with PAT auth via header (avoid printing token)
########################################
LOCAL_WS_DIR="$(pwd)/_workspace"
LOCAL_CLONE_DIR="$LOCAL_WS_DIR/$PROJECT_NAME"
mkdir -p "$LOCAL_WS_DIR"

if [[ ! -d "$LOCAL_CLONE_DIR/.git" ]]; then
  log info "Cloning repository into $LOCAL_CLONE_DIR"
  git -c http.extraHeader="Authorization: Bearer ${PAT}" clone \
      --branch "$BRANCH" --single-branch "$REPO_URL" "$LOCAL_CLONE_DIR" \
      || die $EC_GIT "git clone failed"
else
  log info "Repository exists. Pulling latest changes for branch $BRANCH"
  (
    cd "$LOCAL_CLONE_DIR"
    git -c http.extraHeader="Authorization: Bearer ${PAT}" fetch origin "$BRANCH" || die $EC_GIT "git fetch failed"
    git checkout -B "$BRANCH" "origin/$BRANCH" || die $EC_GIT "git checkout failed"
  )
fi

# Verify Dockerfile or compose present
(
  cd "$LOCAL_CLONE_DIR"
  if [[ -f Dockerfile ]] || [[ -f docker-compose.yml ]] || [[ -f docker-compose.yaml ]] || [[ -f compose.yml ]] || [[ -f compose.yaml ]]; then
    log info "Found container definition in cloned project"
  else
    die $EC_GIT "No Dockerfile or compose file found in repo"
  fi
)

########################################
# SSH connectivity
########################################
SSH_OPTS=( -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -o ConnectTimeout=15 )

log info "Testing SSH connectivity to $SSH_USER@$SSH_HOST:$SSH_PORT"
if ! ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "echo ok" >/dev/null 2>&1; then
  die $EC_SSH "SSH connection failed. Check user/host/key/port and security groups"
fi

########################################
# Cleanup mode (remove resources and exit)
########################################
remote_cleanup() {
  log info "Starting remote cleanup for project=$PROJECT_NAME dir=$REMOTE_DIR"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" bash -s <<EOF || die $EC_CLEANUP "Cleanup failed"
set -Eeuo pipefail
PROJECT_NAME="$PROJECT_NAME"
REMOTE_DIR="$REMOTE_DIR"

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then echo "docker compose"; exit 0; fi
  if command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; exit 0; fi
  echo ""; exit 0
}

COMPOSE=
if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"; elif command -v docker-compose >/dev/null 2>&1; then COMPOSE="docker-compose"; fi

set +e
if [[ -n "\$COMPOSE" ]] && [[ -f "\$REMOTE_DIR/docker-compose.yml" || -f "\$REMOTE_DIR/docker-compose.yaml" || -f "\$REMOTE_DIR/compose.yml" || -f "\$REMOTE_DIR/compose.yaml" ]]; then
  sudo \$COMPOSE -p "\$PROJECT_NAME" -f "\$REMOTE_DIR/docker-compose.yml" down -v 2>/dev/null || true
  sudo \$COMPOSE -p "\$PROJECT_NAME" -f "\$REMOTE_DIR/docker-compose.yaml" down -v 2>/dev/null || true
  sudo \$COMPOSE -p "\$PROJECT_NAME" -f "\$REMOTE_DIR/compose.yml" down -v 2>/dev/null || true
  sudo \$COMPOSE -p "\$PROJECT_NAME" -f "\$REMOTE_DIR/compose.yaml" down -v 2>/dev/null || true
fi
sudo docker rm -f "\$PROJECT_NAME" 2>/dev/null || true
sudo docker image rm -f "\$PROJECT_NAME:latest" 2>/dev/null || true

# Remove Nginx config
if [[ -d /etc/nginx/sites-enabled || -d /etc/nginx/sites-available ]]; then
  sudo rm -f "/etc/nginx/sites-enabled/\$PROJECT_NAME" "/etc/nginx/sites-available/\$PROJECT_NAME" 2>/dev/null || true
  if [[ -f /etc/nginx/sites-enabled/default ]]; then sudo rm -f /etc/nginx/sites-enabled/default || true; fi
else
  sudo rm -f "/etc/nginx/conf.d/\$PROJECT_NAME.conf" 2>/dev/null || true
fi
sudo nginx -t && sudo systemctl reload nginx 2>/dev/null || true

# Remove files
sudo rm -rf "\$REMOTE_DIR"
echo "CLEANUP_DONE"
EOF
  log info "Cleanup complete."
}

if [[ "$CLEANUP_ONLY" == "true" ]]; then
  remote_cleanup
  exit 0
fi

########################################
# Remote environment preparation
########################################
log info "Preparing remote environment (Docker, Compose, Nginx)"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" bash -s <<'REMOTE_SETUP' || die $EC_REMOTE_SETUP "Remote preparation failed"
set -Eeuo pipefail

need_cmd() { command -v "$1" >/dev/null 2>&1; }

PM=""
if need_cmd apt-get; then PM="apt"; fi
if [[ -z "$PM" ]] && need_cmd dnf; then PM="dnf"; fi
if [[ -z "$PM" ]] && need_cmd yum; then PM="yum"; fi
if [[ -z "$PM" ]] && need_cmd zypper; then PM="zypper"; fi

install_pkgs() {
  case "$PM" in
    apt)
      sudo apt-get update -y
      sudo apt-get install -y ca-certificates curl gnupg lsb-release
      # Docker engine + compose plugin + nginx
      sudo apt-get install -y docker.io docker-compose-plugin nginx
      ;;
    dnf)
      sudo dnf -y install dnf-plugins-core || true
      sudo dnf -y install docker nginx curl || true
      # compose plugin may be in docker-ce or extras; fallback to docker-compose
      if ! docker compose version >/dev/null 2>&1; then
        sudo dnf -y install docker-compose || true
      fi
      ;;
    yum)
      sudo yum -y install docker nginx curl || true
      if ! docker compose version >/dev/null 2>&1; then
        sudo yum -y install docker-compose || true
      fi
      ;;
    zypper)
      sudo zypper refresh -y || true
      sudo zypper install -y docker nginx curl || true
      if ! docker compose version >/dev/null 2>&1; then
        sudo zypper install -y docker-compose || true
      fi
      ;;
    *)
      echo "Unsupported package manager" >&2
      exit 1
      ;;
  esac
}

install_pkgs

# Enable and start services
sudo systemctl enable --now docker || sudo service docker start || true
sudo systemctl enable --now nginx || sudo service nginx start || true

# Add current user to docker group (best-effort)
if id -nG "$USER" | grep -qw docker; then :; else
  sudo groupadd -f docker || true
  sudo usermod -aG docker "$USER" || true
fi

docker --version || true
if docker compose version >/dev/null 2>&1; then docker compose version || true; fi
if command -v docker-compose >/dev/null 2>&1; then docker-compose --version || true; fi
nginx -v || true
REMOTE_SETUP

########################################
# Transfer project files
########################################
log info "Syncing project files to remote: $REMOTE_DIR"
# Ensure target dir exists and is writable by ssh user
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "sudo mkdir -p '$REMOTE_DIR' && sudo chown -R '$SSH_USER':'$SSH_USER' '$REMOTE_DIR'"

if command -v rsync >/dev/null 2>&1; then
  rsync -az -e "ssh -p $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=accept-new" --delete "$LOCAL_CLONE_DIR/" "$SSH_USER@$SSH_HOST:$REMOTE_DIR/"
else
  # Fallback: scp (no --delete)
  scp -r -P "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$LOCAL_CLONE_DIR"/* "$SSH_USER@$SSH_HOST:$REMOTE_DIR/" || true
fi

########################################
# Deploy containers on remote
########################################
log info "Deploying containers on remote host"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" bash -s <<EOF || die $EC_DEPLOY "Remote deploy failed"
set -Eeuo pipefail
PROJECT_NAME="$PROJECT_NAME"
REMOTE_DIR="$REMOTE_DIR"
APP_PORT="$APP_PORT"

cd "$REMOTE_DIR"

has_compose_file=false
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
  if [[ -f "\$f" ]]; then has_compose_file=true; export COMPOSE_FILE="\$f"; break; fi
done

if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"; elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"; else COMPOSE_CMD=""; fi

if [[ "\$has_compose_file" == "true" && -n "\$COMPOSE_CMD" ]]; then
  echo "Using compose: \$COMPOSE_CMD (project=\$PROJECT_NAME, file=\$COMPOSE_FILE)"
  sudo \$COMPOSE_CMD -p "\$PROJECT_NAME" -f "\$COMPOSE_FILE" down --remove-orphans || true
  sudo \$COMPOSE_CMD -p "\$PROJECT_NAME" -f "\$COMPOSE_FILE" up -d --build
else
  echo "Compose not available or compose file missing. Falling back to Dockerfile build/run"
  [[ -f Dockerfile ]] || { echo "No Dockerfile found" >&2; exit 1; }
  sudo docker rm -f "\$PROJECT_NAME" 2>/dev/null || true
  sudo docker build -t "\$PROJECT_NAME:latest" .
  # Map host APP_PORT to container APP_PORT
  sudo docker run -d --name "\$PROJECT_NAME" -p "\$APP_PORT:\$APP_PORT" --restart unless-stopped "\$PROJECT_NAME:latest"
fi

# Quick container status
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | (grep -E "^\$PROJECT_NAME\b" || true)
EOF

########################################
# Configure Nginx reverse proxy
########################################
log info "Configuring Nginx reverse proxy on remote"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" bash -s <<EOF || die $EC_NGINX "Nginx configuration failed"
set -Eeuo pipefail
PROJECT_NAME="$PROJECT_NAME"
APP_PORT="$APP_PORT"

NGX_AVAILABLE="/etc/nginx/sites-available"
NGX_ENABLED="/etc/nginx/sites-enabled"
NGX_CONF_D="/etc/nginx/conf.d"

CONF_CONTENT="server {\n  listen 80;\n  server_name _;\n\n  location / {\n    proxy_set_header Host \$host;\n    proxy_set_header X-Real-IP \$remote_addr;\n    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n    proxy_set_header X-Forwarded-Proto \$scheme;\n    proxy_pass http://127.0.0.1:${APP_PORT};\n    proxy_http_version 1.1;\n    proxy_set_header Connection \"\";\n  }\n\n  # SSL placeholder: integrate Certbot or self-signed in future\n}"

if [[ -d "\$NGX_AVAILABLE" && -d "\$NGX_ENABLED" ]]; then
  echo -e "\$CONF_CONTENT" | sudo tee "\$NGX_AVAILABLE/\$PROJECT_NAME" >/dev/null
  sudo ln -sf "\$NGX_AVAILABLE/\$PROJECT_NAME" "\$NGX_ENABLED/\$PROJECT_NAME"
  if [[ -f "\$NGX_ENABLED/default" ]]; then sudo rm -f "\$NGX_ENABLED/default" || true; fi
else
  # RHEL/CentOS style
  echo -e "\$CONF_CONTENT" | sudo tee "\$NGX_CONF_D/\$PROJECT_NAME.conf" >/dev/null
fi

sudo nginx -t
sudo systemctl reload nginx || sudo service nginx reload
EOF

########################################
# Validation
########################################
log info "Validating services on remote"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" bash -s <<EOF || die $EC_VALIDATE "Validation failed"
set -Eeuo pipefail
PROJECT_NAME="$PROJECT_NAME"
APP_PORT="$APP_PORT"

echo "Docker service: $(systemctl is-active docker 2>/dev/null || echo unknown)"
sudo docker ps --format 'table {{.Names}}\t{{.Status}}' | (grep -E "^\$PROJECT_NAME\b" || (echo "Container not found" && exit 1))

echo "Nginx: $(systemctl is-active nginx 2>/dev/null || echo unknown)"

set +e
curl -fsS http://127.0.0.1/ >/dev/null && echo "Nginx proxy OK on /" || { echo "Nginx proxy test failed"; exit 1; }
curl -fsS http://127.0.0.1:80/ >/dev/null && echo "Port 80 OK" || { echo "Port 80 test failed"; exit 1; }
EOF

log info "Deployment successful! Access the app via http://$SSH_HOST/ (ensure port 80 open)."

exit 0
