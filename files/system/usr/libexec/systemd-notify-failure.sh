#!/usr/bin/env bash
#

set -Eeuo pipefail
TO="${MAIL_TO:-root}"
UNIT="${1:-unknown}"
HOST="$(hostname -f)"
TS="$(date -u +'%FT%TZ')"

{
  echo "Host: $HOST"
  echo "Unit: $UNIT"
  echo "When: $TS"
  echo
  systemctl status "$UNIT" --no-pager || true
  echo
  echo "---- recent journal for $UNIT ----"
  journalctl -u "$UNIT" -b --no-pager -n 3000 || true
} | mail -s "❌ $UNIT FAILED on $(hostname -s) @ $TS - ddm-auto-report" "$TO"
