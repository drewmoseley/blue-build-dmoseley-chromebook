#!/usr/bin/env bash
set -Eeuo pipefail

# ==================== CONFIG ====================
TO_EMAIL="drew.moseley@gmail.com"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

# Exclude entire transport classes from SMART checks (space-separated).
# By default, skip USB-attached disks (docks/readers often misreport).
EXCLUDE_TRAN="${EXCLUDE_TRAN:-usb}"

STATE_DIR="/var/lib/storage-health"
LAST_HASH_FILE="${STATE_DIR}/last_alert_hash.txt"
mkdir -p "${STATE_DIR}"

# Flat file log
LOG_FILE="/var/log/storage-health.log"
mkdir -p "$(dirname "$LOG_FILE")"
[[ -e "$LOG_FILE" ]] || install -m 0640 -o root -g adm /dev/null "$LOG_FILE"

# Read-only mountpoints to ignore (space-separated)
ALLOW_RO_MOUNTS="/sys /proc /run/credentials /snap /sysroot /boot/efi"

# Temperature thresholds
NVME_TEMP_WARN=80      # °C
SATA_TEMP_WARN=60      # °C

# ==================== EMAIL + LOG =====================
_log_to_file() {
  local subject="$1" body="$2"
  {
    printf -- "===== %s =====\n" "$(LC_ALL=C date -R)"
    printf -- "%s\n\n" "$subject"
    printf -- "%s\n\n" "$body"
  } >> "$LOG_FILE" 2>/dev/null || true
}

_send_to_logger() {
  local subject="$1" body="$2"
  { printf "STORAGE ALERT: %s\n\n" "$subject"; printf "%s\n" "$body"; } | logger -t storage-health
}

_send_to_mail() {
  local subject="$1" recipient="$2" body="$3"
  printf "%s\n" "${body}" | mail -s $subject $recipient
}

send_mail_and_log() {
  local subject="$1" body="$2"

  _log_to_file "$subject" "$body"
  _send_to_logger "$subject" "$body"
  _send_to_mail "$subject" "${TO_EMAIL}" "$body"
}

now_ts() { date -u +"%Y-%m-%d %H:%M:%S UTC"; }

# ==================== ZFS =======================
check_zfs() {
  if ! command -v zpool >/dev/null 2>&1; then
    printf "%s\n" "ZFS: zpool not found; skipping."
    return 0
  fi

  # Suppress alerts entirely when there are no pools
  if ! zpool list -H 1>/dev/null 2>&1; then
    printf "%s\n" "ZFS: no pools present; skipping."
    return 0
  fi
  if zpool list 2>/dev/null | grep -qi 'no pools available'; then
    printf "%s\n" "ZFS: no pools present; skipping."
    return 0
  fi

  local summary details plist events
  summary="$(zpool status -x 2>&1 || true)"

  # Healthy shortcut
  if [[ "${summary}" == "all pools are healthy" ]]; then
    printf "%s\n" "ZFS: all pools healthy."
    return 0
  fi
  # Defensive no-pool check again
  if grep -qi 'no pools available' <<<"$summary"; then
    printf "%s\n" "ZFS: no pools present; skipping."
    return 0
  fi

  details="$(zpool status -v 2>&1 || true)"
  plist="$(zpool list -o name,size,alloc,free,health -p 2>/dev/null || true)"
  events="$(timeout 2 zpool events -v 2>/dev/null || true)"

  cat <<EOF
=== ZFS ALERT ===
Summary (zpool status -x):
${summary}

Pools (zpool list):
${plist}

Details (zpool status -v):
${details}

Recent events (zpool events -v, truncated):
${events}

EOF
}

# ==================== MD RAID ===================
parse_mdstat_problem() {
  awk '
    $1 ~ /^md[0-9]+/ {
      array=$1
      status=""
      for(i=1;i<=NF;i++){ if ($i ~ /^\[[U_]+\]$/) status=$i }
      if (status == "") next
      if (status ~ /_/) print array " degraded: " status
    }
    /resync|recovery|faulty|removed/ { print "mdstat note: " $0 }
  '
}

check_mdraid() {
  if ! command -v mdadm >/dev/null 2>&1; then
    printf "%s\n" "MDRAID: mdadm not found; skipping."
    return 0
  fi
  local mdstat md_problem arrays out=""
  if [[ -r /proc/mdstat ]]; then
    mdstat="$(cat /proc/mdstat)"
    md_problem="$(printf "%s\n" "$mdstat" | parse_mdstat_problem || true)"
  else
    mdstat="(no /proc/mdstat)"
    md_problem="unable to read /proc/mdstat"
  fi

  arrays=()
  while read -r line; do
    [[ $line =~ ^(md[0-9]+): ]] && arrays+=("/dev/${BASH_REMATCH[1]}")
  done < <(printf "%s\n" "$mdstat")

  for a in "${arrays[@]}"; do
    [[ "$a" =~ p[0-9]+$ ]] && continue
    [[ -b "$a" ]] || continue
    out+=$'\n'"--- mdadm --detail ${a} ---"$'\n'
    out+="$(mdadm --detail "$a" 2>&1 || true)"$'\n'
  done

  if [[ -z "$md_problem" ]]; then
    printf "%s\n" "MDRAID: arrays present, no degradation detected."
    return 0
  fi

  cat <<EOF
=== MDRAID ALERT ===
Issues detected from /proc/mdstat:
${md_problem}

/proc/mdstat:
${mdstat}

Array details:
${out}
EOF
}

# ============== SMART / NVMe proactive ==========
_transport_is_excluded() {
  local tran="$1"
  for t in $EXCLUDE_TRAN; do
    [[ "$tran" == "$t" ]] && return 0
  done
  return 1
}

smart_scan() {
  if ! command -v smartctl >/dev/null 2>&1; then
    printf "%s\n" "SUMMARY:"
    printf "%s\n" "smartctl not installed; skipping SMART/NVMe health."
    printf "\n%s\n" "DETAILS:"
    return 0
  fi
  local summary="" details=""

  while read -r name type mp; do
    [[ "$type" != "disk" ]] && continue

    # Skip virtual/unsupported block devices
    if [[ "$name" =~ ^(zd|loop|dm-|md|sr|zram|ram) ]]; then
      continue
    fi

    # Skip disks whose children are *all* [SWAP]
    if ! lsblk -ln -o NAME,MOUNTPOINT "/dev/$name" | awk '$2 != "[SWAP]"' | grep -q .; then
      continue
    fi

    # Skip excluded transport classes (e.g., USB)
    local tran=""
    tran="$(lsblk -dn -o TRAN "/dev/$name" 2>/dev/null || true)"
    if [[ -n "$tran" ]] && _transport_is_excluded "$tran"; then
      continue
    fi

    local dev="/dev/${name}" out rc health="PASS" is_nvme=0 cw="" SAT_FLAG=()
    [[ "$name" =~ ^nvme ]] && is_nvme=1

    # If we *didn't* exclude USB and it's SATA/SAS, prefer -d sat for USB bridges
    if [[ "$tran" == "usb" ]] && [[ $is_nvme -eq 0 ]] && ! _transport_is_excluded "$tran" ]]; then
      SAT_FLAG=(-d sat)
    fi

    # Probe SMART
    out="$(smartctl "${SAT_FLAG[@]}" -H -A "$dev" 2>&1 || true)"
    rc=$?

    # If unknown USB bridge, retry with -d sat explicitly (only matters if not excluded)
    if [[ "$tran" == "usb" ]] && grep -qi 'Unknown USB bridge' <<<"$out"; then
      out="$(smartctl -d sat -H -A "$dev" 2>&1 || true)"
      rc=$?
    fi

    # Ignore empty USB bays / card readers with no media
    if grep -qiE 'no medium present|A mandatory SMART command failed' <<<"$out"; then
      continue
    fi

    # ---- FAIL detection (strict; avoid attribute "Pre-fail" noise) ----
    if grep -qiE 'overall-?health.*:\s*FAILED|SMART (Health|overall-health).*:\s*FAIL' <<<"$out"; then
      health="FAIL"
    fi

    if (( is_nvme )); then
      # NVMe Critical Warning != 0 => FAIL
      if grep -qi 'Critical Warning' <<<"$out"; then
        cw="$(grep -i 'Critical Warning' <<<"$out" | head -n1 | awk -F: '{gsub(/ /,"",$2); print $2}')"
        [[ -n "$cw" && "$cw" != "0" ]] && health="FAIL"
      fi
      # ---- WARN heuristics (NVMe) ----
      if awk 'BEGIN{IGNORECASE=1} /Media and Data Integrity Errors/ {if ($NF+0>0) exit 1}' <<<"$out"; then
        [[ "$health" != "FAIL" ]] && health="WARN"
      fi
      # (Removed "Error Information Log Entries" heuristic)
      if awk 'BEGIN{IGNORECASE=1} /Percentage Used/ {if ($NF+0>=100) exit 1}' <<<"$out"; then
        [[ "$health" != "FAIL" ]] && health="WARN"
      fi
      if awk -v thr="$NVME_TEMP_WARN" 'BEGIN{IGNORECASE=1} /Composite Temperature/ {if ($NF+0>=thr) exit 1}' <<<"$out"; then
        [[ "$health" != "FAIL" ]] && health="WARN"
      fi
    else
      # ---- WARN heuristics (SATA/SAS) ----
      if awk 'BEGIN{IGNORECASE=1} /Reallocated_Sector_Ct/       {for(i=1;i<=NF;i++) if ($i+0>0) exit 1}' <<<"$out"; then health="WARN"; fi
      if awk 'BEGIN{IGNORECASE=1} /Current_Pending_Sector/      {for(i=1;i<=NF;i++) if ($i+0>0) exit 1}' <<<"$out"; then [[ "$health" != "FAIL" ]] && health="WARN"; fi
      if awk 'BEGIN{IGNORECASE=1} /Offline_Uncorrectable/       {for(i=1;i<=NF;i++) if ($i+0>0) exit 1}' <<<"$out"; then [[ "$health" != "FAIL" ]] && health="WARN"; fi
      if awk 'BEGIN{IGNORECASE=1} /UDMA_CRC_Error_Count/        {for(i=1;i<=NF;i++) if ($i+0>=100) exit 1}' <<<"$out"; then [[ "$health" != "FAIL" ]] && health="WARN"; fi
      if awk -v thr="$SATA_TEMP_WARN" 'BEGIN{IGNORECASE=1} /(Temperature_Celsius|Temperature)/ {for(i=1;i<=NF;i++) if ($i+0>=thr) exit 1}' <<<"$out"; then [[ "$health" != "FAIL" ]] && health="WARN"; fi
    fi

    # Final sanity guard: do not report FAIL unless we really saw it
    if [[ "$health" == "FAIL" ]]; then
      if ! grep -qiE 'overall-?health.*:\s*FAILED|SMART (Health|overall-health).*:\s*FAIL|Critical Warning[^:]*:\s*[1-9A-Fa-f]' <<<"$out"; then
        health="WARN"
      fi
    fi

    # Build summary (preserve newlines)
    summary+=$(printf "%-12s : %s\n" "${dev}" "${health}")
    if [[ "$health" != "PASS" ]]; then
      details+=$'\n'"--- smartctl -H -A ${dev} ---"$'\n'"${out}"$'\n'
      # Optional note: record rc for troubleshooting, not an alert signal
      if [[ $rc -ne 0 ]]; then
        details+=$'--- note: smartctl exit code '"$rc"$' (recorded; not treated as alert) ---\n'
      fi
    fi
  done < <(lsblk -dn -o NAME,TYPE,MOUNTPOINT)

  # Output with CRLF to appease picky mail clients
  printf "%s\n" "SUMMARY:"
  if [[ -n "$summary" ]]; then
    while IFS= read -r line; do printf "%s\r\n" "$line"; done <<<"$summary"
  else
    printf "%s\r\n" "(no disks found after swap/virtual/transport filtering)"
  fi
  printf "\r\n%s\r\n" "DETAILS:"
  [[ -n "$details" ]] && printf "%s\r\n" "$details"
}

# ============== Read-only mount detection =========
check_readonly_mounts() {
  local alerts=""
  # SOURCE TARGET FSTYPE OPTIONS (use findmnt for robust parsing)
  while read -r src mp fstype opts; do
    [[ "$fstype" =~ ^(proc|sysfs|tmpfs|devtmpfs|cgroup2?|overlay|squashfs|fusectl|debugfs|tracefs|ramfs)$ ]] && continue
    for w in $ALLOW_RO_MOUNTS; do [[ "$mp" == "$w" ]] && continue 2; done
    # exact 'ro' option only (avoid 'errors=remount-ro')
    if [[ ",$opts," == *",ro,"* ]]; then
      alerts+=$(printf "Read-only mount: %s on %s (%s) opts=%s\n" "${src:-unknown}" "$mp" "$fstype" "$opts")
    fi
  done < <(findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS)

  if [[ -n "$alerts" ]]; then
    cat <<EOF
=== FILESYSTEM ALERT ===
One or more filesystems are mounted read-only:

${alerts}
EOF
  fi
}

# ==================== MAIN ======================
BODY_HDR=$(cat <<EOF
Host: ${HOSTNAME}
Time: $(now_ts)

This message is sent only when a storage health issue is detected.
EOF
)

ZFS_SECTION="$(check_zfs || true)"
MD_SECTION="$(check_mdraid || true)"
RO_SECTION="$(check_readonly_mounts || true)"

ALERTS=""
if grep -q "=== ZFS ALERT ===" <<<"${ZFS_SECTION}"; then ALERTS+="${ZFS_SECTION}"$'\n'; fi
if grep -q "=== MDRAID ALERT ===" <<<"${MD_SECTION}"; then ALERTS+="${MD_SECTION}"$'\n'; fi
if grep -q "=== FILESYSTEM ALERT ===" <<<"${RO_SECTION}"; then ALERTS+="${RO_SECTION}"$'\n'; fi

# SMART: proactive alert even if ZFS/RAID/FS are fine
readarray -t SMART_OUTPUT < <(smart_scan)
SMART_SUMMARY="$(printf "%s\n" "${SMART_OUTPUT[@]}" | sed -n '1,/^DETAILS:$/p')"
SMART_DETAILS="$(printf "%s\n" "${SMART_OUTPUT[@]}" | sed -n '/^DETAILS:$/,$p' | sed '1d')"

if printf "%s\n" "$SMART_SUMMARY" | grep -qE ' : (FAIL|WARN)$'; then
  ALERTS+=$'\n''=== SMART/NVMe PROACTIVE ALERT ==='$'\n'"${SMART_SUMMARY}"
  [[ -n "$SMART_DETAILS" ]] && ALERTS+=$'\n'"${SMART_DETAILS}"
else
  if [[ -n "$ALERTS" ]]; then
    ALERTS+=$'\n''=== SMART/NVMe Summary ==='$'\n'"${SMART_SUMMARY}"
  fi
fi

# If nothing is wrong, exit quietly (no email/log spam)
if [[ -z "$ALERTS" ]]; then
  exit 0
fi

BODY_FULL="${BODY_HDR}

${ALERTS}
"

CUR_HASH="$(printf "%s" "${BODY_FULL}" | sha256sum | awk '{print $1}')"
PREV_HASH="$(cat "${LAST_HASH_FILE}" 2>/dev/null || true)"

if [[ "${CUR_HASH}" != "${PREV_HASH}" ]]; then
  send_mail_and_log "STORAGE ALERT on ${HOSTNAME}" "${BODY_FULL}"
  echo "${CUR_HASH}" > "${LAST_HASH_FILE}"
fi
