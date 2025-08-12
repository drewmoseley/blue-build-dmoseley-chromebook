#!/usr/bin/env bash
set -euo pipefail

URL="https://github.com/uptane/ota-tuf/releases/download/v3.2.14/cli-3.2.14.tgz"
echo "Downloading ${URL}"
curl -fL "$URL" -o /tmp/cli.tgz
tar -C /opt -xzf /tmp/cli.tgz
rm -f /tmp/cli.tgz

echo "Installed: $(command -v uptane-sign)"
uptane-sign --help || true
