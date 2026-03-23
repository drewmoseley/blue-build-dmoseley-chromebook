#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SHELLCHECK_TARGETS=(
  files/system/usr/libexec/chromebook-audio-setup.sh
)

SYSTEMD_UNITS=(
  /usr/lib/systemd/system/chromebook-audio-setup.service
)

check_executable_bits() {
  local path

  for path in \
    files/system/usr/libexec/chromebook-audio-setup.sh; do
    if [[ ! -x "${path}" ]]; then
      echo "${path} must be executable." >&2
      exit 1
    fi
  done
}

run_shellcheck() {
  echo "Running shellcheck"

  if command -v podman >/dev/null 2>&1; then
    podman run --rm \
      -v "${REPO_ROOT}:/src:ro" \
      -w /src \
      docker.io/koalaman/shellcheck:stable \
      "${SHELLCHECK_TARGETS[@]}"
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    docker run --rm \
      -v "${REPO_ROOT}:/src:ro" \
      -w /src \
      koalaman/shellcheck:stable \
      "${SHELLCHECK_TARGETS[@]}"
    return
  fi

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${SHELLCHECK_TARGETS[@]}"
    return
  fi

  echo "shellcheck is unavailable: install shellcheck or provide podman/docker" >&2
  exit 1
}

run_systemd_verify() {
  local tmpdir
  tmpdir="$(mktemp -d /tmp/systemd-verify.XXXXXX)"
  trap 'rm -rf "${tmpdir}"' RETURN

  echo "Running systemd-analyze verify"

  mkdir -p \
    "${tmpdir}/usr/lib/systemd/system" \
    "${tmpdir}/usr/libexec"

  cp files/system/usr/lib/systemd/system/chromebook-audio-setup.service \
    "${tmpdir}/usr/lib/systemd/system/"
  cp files/system/usr/libexec/chromebook-audio-setup.sh \
    "${tmpdir}/usr/libexec/"

  cat > "${tmpdir}/usr/lib/systemd/system/local-fs.target" <<'EOF'
[Unit]
Description=Stub local-fs.target
EOF

  cat > "${tmpdir}/usr/lib/systemd/system/sound.target" <<'EOF'
[Unit]
Description=Stub sound.target
EOF

  cat > "${tmpdir}/usr/lib/systemd/system/sysinit.target" <<'EOF'
[Unit]
Description=Stub sysinit.target
EOF

  cat > "${tmpdir}/usr/lib/systemd/system/basic.target" <<'EOF'
[Unit]
Description=Stub basic.target
EOF

  cat > "${tmpdir}/usr/lib/systemd/system/multi-user.target" <<'EOF'
[Unit]
Description=Stub multi-user.target
EOF

  systemd-analyze verify --root="${tmpdir}" "${SYSTEMD_UNITS[@]}"
}

check_executable_bits
run_shellcheck
run_systemd_verify
