#!/bin/sh
# Shared config for backup.sh / restore.sh / healthcheck.sh. Sourced, not executed.
# shellcheck disable=SC2034  # vars are used by the scripts that source this file

: "${POSTGRES_HOST:=postgres}"
: "${POSTGRES_PORT:=5432}"
: "${BACKUP_PREFIX:=postgres}"
: "${BACKUP_KEEP_DAYS:=14}"
: "${WORK_DIR:=/work}"
STATUS_FILE="$WORK_DIR/status"
START_FILE="$WORK_DIR/started"

export PGHOST="$POSTGRES_HOST" PGPORT="$POSTGRES_PORT" PGUSER="$POSTGRES_USER" PGPASSWORD="$POSTGRES_PASSWORD"

# rclone remote "r2:" configured purely from env (no config file on disk).
if [ -z "${R2_ENDPOINT:-}" ] && [ -n "${R2_ACCOUNT_ID:-}" ]; then
  R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER="${R2_PROVIDER:-Cloudflare}"
export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT:-}"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
export RCLONE_CONFIG_R2_REGION=auto
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true   # token needs only object read/write, not bucket admin
REMOTE="r2:${R2_BUCKET:-}/${BACKUP_PREFIX}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [backup] $*"; }

require_config() {
  missing=""
  for v in POSTGRES_USER POSTGRES_PASSWORD R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET BACKUP_PASSPHRASE; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || missing="$missing $v"
  done
  if [ -n "$missing" ]; then
    log "ERROR: missing env:$missing"
    return 1
  fi
}

# gpg symmetric AES256; passphrase via fd 3 so it never shows up in `ps`.
encrypt() { # in out
  mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
  printf '%s' "$BACKUP_PASSPHRASE" | gpg --batch --yes --quiet --pinentry-mode loopback \
    --passphrase-fd 3 --symmetric --cipher-algo AES256 --compress-algo none \
    -o "$2" "$1" 3<&0 </dev/null
}
decrypt() { # in out
  mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
  printf '%s' "$BACKUP_PASSPHRASE" | gpg --batch --yes --quiet --pinentry-mode loopback \
    --passphrase-fd 3 --decrypt -o "$2" "$1" 3<&0 </dev/null
}

ping_url() { # suffix: "" (success) | "/fail" | "/start"
  [ -n "${BACKUP_PING_URL:-}" ] || return 0
  wget -q -T 10 -O /dev/null "${BACKUP_PING_URL}$1" 2>/dev/null || log "WARN: ping ${BACKUP_PING_URL}$1 failed"
}
