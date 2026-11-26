#!/bin/sh
# Unhealthy when: last run failed, or no successful run for > MAX_AGE (default 26h)
# once the container has been up longer than that.
# shellcheck source=common.sh
. /usr/local/bin/common.sh
MAX_AGE="${BACKUP_MAX_AGE_SECONDS:-93600}"
now=$(date +%s)
started=$(cat "$START_FILE" 2>/dev/null || echo "$now")

if [ -f "$STATUS_FILE" ]; then
  # shellcheck disable=SC2046  # intentional word split: "<ok|fail> <epoch> <msg>"
  set -- $(cat "$STATUS_FILE")
  [ "$1" = "fail" ] && { echo "last backup failed: $*"; exit 1; }
  [ $((now - $2)) -gt "$MAX_AGE" ] && { echo "last success $(( (now - $2) / 3600 ))h ago"; exit 1; }
  echo "ok: last run $3"; exit 0
fi

[ $((now - started)) -gt "$MAX_AGE" ] && { echo "no backup since start"; exit 1; }
echo "waiting for first backup"; exit 0
