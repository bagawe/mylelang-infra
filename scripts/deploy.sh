#!/usr/bin/env bash
# Deploy the My Lelang dev stack on the VPS (build on host, no registry).
# Triggered by GitHub Actions (push to develop) over SSH, or run manually.
set -euo pipefail

ROOT="${MYLELANG_ROOT:-/opt/mylelang}"
INFRA_DIR="$ROOT/mylelang-infra"
ENV_FILE="$INFRA_DIR/env/dev.env"

APP_BRANCH="${APP_BRANCH:-develop}"   # backend + web deploy from develop
INFRA_BRANCH="${INFRA_BRANCH:-main}"  # infra repo tracks main

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

update_repo() {
  local dir="$1" branch="$2"
  log "Updating $(basename "$dir") ($branch)"
  git -C "$dir" fetch --all --prune
  git -C "$dir" checkout "$branch"
  git -C "$dir" reset --hard "origin/$branch"
}

[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE. Create it from env/dev.env.example."; exit 1; }

update_repo "$INFRA_DIR" "$INFRA_BRANCH"
update_repo "$ROOT/mylelangbackend" "$APP_BRANCH"
update_repo "$ROOT/mylelangweb" "$APP_BRANCH"

cd "$INFRA_DIR"
COMPOSE=(docker compose --env-file env/dev.env -f compose.yaml)

log "Building images on host"
"${COMPOSE[@]}" build

log "Starting datastores (+ ClamAV)"
"${COMPOSE[@]}" up -d postgres redis minio clamav

log "Ensuring upload bucket exists"
"${COMPOSE[@]}" run --rm minio-init || true

log "Applying database migrations"
"${COMPOSE[@]}" run --rm migrate

log "Rolling out app services"
"${COMPOSE[@]}" up -d

log "Pruning dangling images"
docker image prune -f >/dev/null || true

log "Deploy complete"
"${COMPOSE[@]}" ps
