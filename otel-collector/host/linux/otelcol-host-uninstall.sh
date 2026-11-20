#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — OTel Collector host agent (Linux) — uninstall
# Purpose: back up the running config, stop the service, and remove the
#          otelcol-contrib package installed by otelcol-host-install.sh.
# Requires env: (none)
# Optional env: BACKUP_DIR
# Usage: sudo ./otelcol-host-uninstall.sh
# ------------------------------------------------------------
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/tmp/otelcol-contrib-backup}"
mkdir -p "${BACKUP_DIR}"

if [[ -f /etc/otelcol-contrib/config.yaml ]]; then
  backup_path="${BACKUP_DIR}/config.yaml.$(date +%Y%m%d%H%M%S)"
  cp /etc/otelcol-contrib/config.yaml "${backup_path}"
  echo "Backed up running config to ${backup_path}"
fi

systemctl stop otelcol-contrib 2>/dev/null || true
systemctl disable otelcol-contrib 2>/dev/null || true

dpkg -P otelcol-contrib 2>/dev/null || true

rm -rf /etc/otelcol-contrib
rm -f ./otelcol-contrib_*.deb /root/otelcol-contrib_*.deb /tmp/otelcol-contrib_*.deb 2>/dev/null || true

echo "otelcol-contrib removed. Config backup (if any) is in ${BACKUP_DIR}"
