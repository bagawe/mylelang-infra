#!/usr/bin/env bash
# Daily PostgreSQL backup for the My Lelang dev stack.
# Dumps the DB from the running postgres container and keeps N days of gzipped
# dumps. Schedule via cron, e.g.:
#   0 2 * * * /opt/mylelang/mylelang-infra/scripts/pg-backup.sh >> /var/log/mylelang-pg-backup.log 2>&1
set -euo pipefail

ROOT="${MYLELANG_ROOT:-/opt/mylelang}"
INFRA_DIR="$ROOT/mylelang-infra"
ENV_FILE="$INFRA_DIR/env/dev.env"
BACKUP_DIR="${BACKUP_DIR:-$ROOT/backups/postgres}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/${POSTGRES_DB}-${STAMP}.sql.gz"

cd "$INFRA_DIR"
docker compose --env-file env/dev.env -f compose.yaml exec -T postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --clean --if-exists \
  | gzip > "$OUT"

echo "Backup written: $OUT ($(du -h "$OUT" | cut -f1))"

# Prune old backups.
find "$BACKUP_DIR" -name "${POSTGRES_DB}-*.sql.gz" -type f -mtime "+${RETENTION_DAYS}" -delete
echo "Pruned backups older than ${RETENTION_DAYS} days"
