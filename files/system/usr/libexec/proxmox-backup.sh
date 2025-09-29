#!/usr/bin/env bash
set -Eeuo pipefail

TO="drew.moseley@gmail.com"
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
HOSTID=$(hostname -s)

/usr/bin/proxmox-backup-client backup \
  ${HOSTID}-alletc.pxar:/etc \
  ${HOSTID}-root.pxar:/root \
  ${HOSTID}-home-dmoseley.pxar:/home/dmoseley \
  ${HOSTID}-work-dmoseley.pxar:/work/dmoseley \
  --keyfile /root/pbs-client.key \
  --backup-id ${HOSTID}-$(hostname -s) |& tee "$LOG"
rc=${PIPESTATUS[0]}

if (( rc == 0 )); then
  mail -s "✅ ${HOSTID}→PBS root, home and etc backup OK on $(hostname -s) @ $(date -u +%FT%TZ) - ddm-auto-report" \
       "$TO" < "$LOG"
else
  mail -s "❌ ${HOSTID}→PBS root, home and etc backup ERR on $(hostname -s) @ $(date -u +%FT%TZ) - ddm-auto-report" \
       "$TO" < "$LOG"
fi

exit 0
