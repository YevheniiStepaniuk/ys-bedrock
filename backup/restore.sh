#!/bin/sh
# Restore from R2.
#
#   restore.sh list                         list backup runs (newest last)
#   restore.sh show  <run|latest>           list files in a run
#   restore.sh <run|latest> [db] [--into <target_db>] [--yes]
#
#   db         database to restore (default: $POSTGRES_DB)
#   --into X   restore into database X instead (created if missing) — safe test restore
#   --yes      skip confirmation (required when not on a TTY)
#
# Restoring into an existing DB DROPS AND RECREATES every object in the dump.
set -eu
# shellcheck source=common.sh
. /usr/local/bin/common.sh

die() { log "ERROR: $*"; exit 1; }
require_config || exit 1

runs() { rclone lsf --dirs-only "$REMOTE/" | sed 's|/$||' | sort; }
resolve_run() {
  if [ "$1" = "latest" ]; then
    r="$(runs | tail -n1)"; [ -n "$r" ] || die "no backups in $REMOTE"; echo "$r"
  else
    runs | grep -qx "$1" || die "run '$1' not found (try: restore.sh list)"; echo "$1"
  fi
}

case "${1:-}" in
  ""|-h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  list) runs; exit 0 ;;
  show) rclone ls "$REMOTE/$(resolve_run "${2:-latest}")/"; exit 0 ;;
esac

RUN="$(resolve_run "$1")"; shift
DB="$POSTGRES_DB"; TARGET=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --into) TARGET="${2:?--into needs a name}"; shift 2 ;;
    --yes)  YES=1; shift ;;
    -*)     die "unknown flag $1" ;;
    *)      DB="$1"; shift ;;
  esac
done
TARGET="${TARGET:-$DB}"
for n in "$DB" "$TARGET"; do
  case "$n" in *[!A-Za-z0-9_-]*|"") die "invalid database name '$n'" ;; esac
done

echo "Restore  $REMOTE/$RUN/$DB.dump.gpg"
echo "   into  database '$TARGET' on $PGHOST"
if [ "$YES" != 1 ]; then
  [ -t 0 ] || die "not a TTY: pass --yes (or use docker exec -it)"
  printf "All objects in '%s' will be dropped and recreated. Type the database name to confirm: " "$TARGET"
  read -r ans; [ "$ans" = "$TARGET" ] || die "aborted"
fi

TMP="$WORK_DIR/restore-$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
rclone copyto "$REMOTE/$RUN/$DB.dump.gpg" "$TMP/db.dump.gpg" || die "download failed (db '$DB' in run?)"
decrypt "$TMP/db.dump.gpg" "$TMP/db.dump" || die "decrypt failed (wrong BACKUP_PASSPHRASE?)"
pg_restore -l "$TMP/db.dump" > /dev/null || die "archive corrupt"

if ! psql -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$TARGET'" | grep -q 1; then
  log "creating database $TARGET"
  createdb --maintenance-db=postgres "$TARGET"
fi

log "restoring $DB ($RUN) -> $TARGET"
pg_restore -d "$TARGET" --clean --if-exists --no-owner --role="$PGUSER" --exit-on-error -j 2 "$TMP/db.dump"
log "restore complete"
