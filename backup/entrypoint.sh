#!/bin/sh
# Scheduler: run backup.sh once a day at BACKUP_TIME (HH:MM, container TZ, default UTC).
set -eu
# shellcheck source=common.sh
. /usr/local/bin/common.sh
: "${BACKUP_TIME:=03:00}"

mkdir -p "$WORK_DIR"
date +%s > "$START_FILE"
rm -f "$STATUS_FILE"

case "$BACKUP_TIME" in [0-2][0-9]:[0-5][0-9]) ;; *) log "ERROR: BACKUP_TIME must be HH:MM"; exit 1 ;; esac
require_config || exit 1

log "scheduler up: daily at $BACKUP_TIME ($(date +%Z)), keep ${BACKUP_KEEP_DAYS}d, target $REMOTE"
if [ "${BACKUP_ON_START:-false}" = "true" ]; then backup.sh || true; fi

last=""
while :; do
  now="$(date +%H:%M)"; today="$(date +%F)"
  if [ "$now" = "$BACKUP_TIME" ] && [ "$last" != "$today" ]; then
    last="$today"
    backup.sh || true   # failure is recorded in status file -> healthcheck / ping
  fi
  sleep 20
done
