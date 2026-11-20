#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — Oracle
# Purpose: install the Grafana Agent static binary and enable its built-in
#          oracledb integration against an Oracle instance, remote_writing
#          metrics to a Mimir/Prometheus-remote_write-compatible backend,
#          one X-Scope-OrgID header per tenant passed on the command line.
# Requires env: METRICS_REMOTE_WRITE_URL, ORACLE_HOST, ORACLE_USER,
#               ORACLE_PASSWORD
# Optional env: ORACLE_SERVICE_NAME, GRAFANA_AGENT_VERSION,
#               ARTIFACT_BASE_URL, PORTAL_API_BASE_URL,
#               PORTAL_REGISTER_SCRIPT_URL
# Usage: sudo ./oracle.sh <tenant-id> [<tenant-id> ...]
#
# Note: this migrates `oracle-linux-script.sh` from the source onboarding
# scripts. Mirrors the structure of grafana-agent/linux/grafana-agent-host-
# install.sh — see that file (and ../linux/README.md) for the shared env var
# conventions this repo uses for per-exporter Grafana Agent installs.
#
# The source script's dashboard-provisioning call used a different shape
# than its siblings (a single POST per tenant to a tech-specific path,
# instead of the dashboards/v1.1/create + alerts/v1.1/set pair used
# elsewhere) and its host-registration hand-off was already commented out
# upstream — both are reproduced faithfully below, still gated behind
# PORTAL_API_BASE_URL / PORTAL_REGISTER_SCRIPT_URL.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${ORACLE_HOST:?set ORACLE_HOST, e.g. 10.0.0.13:1521}"
: "${ORACLE_USER:?set ORACLE_USER, the metrics-reader account for oracledb_exporter}"
: "${ORACLE_PASSWORD:?set ORACLE_PASSWORD}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <tenant-id> [<tenant-id> ...]" >&2
  exit 1
fi

ORACLE_SERVICE_NAME="${ORACLE_SERVICE_NAME:-XE}"

# Pin the agent version explicitly rather than always pulling ":latest" —
# makes installs reproducible and lets an operator roll back by changing
# one env var. Grafana Agent (classic/static mode) is archived upstream in
# favor of Grafana Alloy; check https://github.com/grafana/agent/releases
# for the newest release still published there, or point ARTIFACT_BASE_URL
# at your own internal mirror if you vendor the binary.
#
# The source script had no version pinned at all (just a generic
# "grafana-agent-linux-amd64.zip" on an internal mirror). v0.37.3 is
# defaulted here because it's verified (via the GitHub releases API) to
# ship an asset under that exact name — bump freely, just keep the asset
# name in step with whichever side of the v0.31 rename your version falls.
GRAFANA_AGENT_VERSION="${GRAFANA_AGENT_VERSION:-v0.37.3}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/grafana/agent/releases/download/${GRAFANA_AGENT_VERSION}}"
ARTIFACT_NAME="grafana-agent-linux-amd64"

SERVICE="oracle_exporter.service"

echo "Tenant ID(s): $*"

curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/${ARTIFACT_NAME}.zip"
unzip -o "${ARTIFACT_NAME}.zip"
chmod a+x "${ARTIFACT_NAME}"
sudo mv "${ARTIFACT_NAME}" /usr/local/bin/

if [[ ! -e /etc/grafana-agent-oracle-config.yaml ]]; then
  sudo tee /etc/grafana-agent-oracle-config.yaml >/dev/null <<EOF
prometheus:
  global:
    scrape_interval: 60s
  # Add labels for this DB here, e.g.:
  #   external_labels:
  #     application: my-app
  wal_directory: /tmp/grafana-agent-oracle-wal
server:
  log_level: error
integrations:
  oracledb:
    enabled: true
    connection_string: oracle://${ORACLE_USER}:${ORACLE_PASSWORD}@${ORACLE_HOST}/${ORACLE_SERVICE_NAME}
  prometheus_remote_write:
EOF
fi

# Idempotency guard: only append a tenant's remote_write block if that
# tenant isn't already configured, so re-running the script for a new
# tenant doesn't duplicate existing ones.
for tenant in "$@"; do
  if ! grep -q "X-Scope-OrgID: ${tenant}$" /etc/grafana-agent-oracle-config.yaml; then
    tenant_block="  - url: ${METRICS_REMOTE_WRITE_URL}"$'\n'"    headers:"$'\n'"      X-Scope-OrgID: ${tenant}"
    echo "${tenant_block}" | sudo tee -a /etc/grafana-agent-oracle-config.yaml >/dev/null
  fi
done

sudo tee /etc/systemd/system/oracle_exporter.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (Oracle metrics)
Wants=network-online.target
After=network-online.target

[Service]
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/${ARTIFACT_NAME} \\
          --server.grpc.address localhost:9097 \\
          --server.http.address localhost:12347 \\
          --config.file /etc/grafana-agent-oracle-config.yaml \\
          --disable-reporting

Restart=always

[Install]
WantedBy=multi-user.target
EOM

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"
sudo systemctl status "$SERVICE" --no-pager || true

# Optional: register a dashboard for this tenant with an observability
# portal, if one is configured. Skipped entirely when PORTAL_API_BASE_URL
# isn't set, so the agent install itself never depends on a SaaS backend.
if [[ -n "${PORTAL_API_BASE_URL:-}" ]]; then
  for tenant in "$@"; do
    curl --noproxy "*" --location --request POST "${PORTAL_API_BASE_URL}/api/dashboards/createdashboard2/oracle-linux" \
      --header 'Content-Type: application/json' \
      -d "{\"tenantID\": \"${tenant}\"}"
  done
fi

# Optional: hand off to a fleet-registration script hosted on your own
# mirror (e.g. to record this host against inventory/CMDB). No public
# equivalent exists for this step, so it's opt-in via env var — disabled
# by default, same as in the source script.
if [[ -n "${PORTAL_REGISTER_SCRIPT_URL:-}" ]]; then
  curl -fsSL --noproxy "*" -L -O "${PORTAL_REGISTER_SCRIPT_URL}"
  chmod a+x server-info.sh
  for tenant in "$@"; do
    bash server-info.sh "$tenant" oracle
  done
fi
