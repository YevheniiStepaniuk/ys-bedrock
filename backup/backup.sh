#!/bin/sh
# One backup run: every non-template database + cluster globals (roles), each
# dumped -> verified -> encrypted -> uploaded to R2. Then prune old backups.
#
# Layout:  r2:<bucket>/<prefix>/<YYYY-MM-DD>T<HHMMSS>Z/{globals.sql.gpg,<db>.dump.gpg}
#
# Manual run:  docker exec pg-backup backup.sh
set -eu
# shellcheck source=common.sh
. /usr/local/bin/common.sh

fail() {
  log "FAILED: $*"
  echo "fail $(date +%s) $*" > "$STATUS_FILE"
  ping_url /fail
  exit 1
}

require_config || fail "not configured"
ping_url /start

RUN="$(date -u +%Y-%m-%dT%H%M%SZ)"
TMP="$WORK_DIR/run-$RUN"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

log "run $RUN -> $REMOTE/$RUN/"

pg_isready -q -t 10 || fail "postgres not ready"

# Cluster globals: roles (incl. password hashes) + tablespaces.
pg_dumpall --globals-only -f "$TMP/globals.sql" || fail "pg_dumpall globals"
encrypt "$TMP/globals.sql" "$TMP/globals.sql.gpg" || fail "encrypt globals"
rclone copyto "$TMP/globals.sql.gpg" "$REMOTE/$RUN/globals.sql.gpg" || fail "upload globals"
rm -f "$TMP/globals.sql" "$TMP/globals.sql.gpg"

DBS="$(psql -d postgres -Atc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1")" \
  || fail "list databases"
[ -n "$DBS" ] || fail "no databases found"

for db in $DBS; do
  f="$TMP/$db.dump"
  pg_dump -d "$db" -Fc -Z 6 -f "$f" || fail "pg_dump $db"
  # Verify archive is readable before shipping it.
  pg_restore -l "$f" > /dev/null || fail "verify $db"
  encrypt "$f" "$f.gpg" || fail "encrypt $db"
  rclone copyto "$f.gpg" "$REMOTE/$RUN/$db.dump.gpg" || fail "upload $db"
  log "  $db: $(du -h "$f.gpg" | cut -f1) uploaded"
  rm -f "$f" "$f.gpg"
done

# Retention: delete objects older than N days (R2 has no real dirs, so this is enough).
if [ "$BACKUP_KEEP_DAYS" -gt 0 ] 2>/dev/null; then
  rclone delete --min-age "${BACKUP_KEEP_DAYS}d" "$REMOTE" || log "WARN: prune failed"
fi

echo "ok $(date +%s) $RUN" > "$STATUS_FILE"
ping_url ""
log "done: $RUN ($(echo "$DBS" | wc -w) db)"
