#!/usr/bin/env bash
# Deploy the My Lelang dev stack on the VPS (build on host, no registry).
# Triggered by GitHub Actions (push to main) over SSH, or run manually.
set -euo pipefail

ROOT="${MYLELANG_ROOT:-/opt/mylelang}"
INFRA_DIR="$ROOT/mylelang-infra"
ENV_FILE="$INFRA_DIR/env/dev.env"

APP_BRANCH="${APP_BRANCH:-main}"      # backend + web (create develop later if needed)
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

# Postgres/MinIO publish to TAILSCALE_IP only. Empty → Docker binds 0.0.0.0 (public).
TAILSCALE_IP="$(grep -E '^TAILSCALE_IP=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
if [[ -z "$TAILSCALE_IP" ]]; then
  echo "TAILSCALE_IP is empty in $ENV_FILE."
  echo "Set it to \`tailscale ip -4\` (or 127.0.0.1 until Tailscale is installed)."
  exit 1
fi

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
