#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — MySQL
# Purpose: install the Grafana Agent static binary and enable its built-in
#          mysqld_exporter integration against a MySQL instance,
#          remote_writing metrics to a Mimir/Prometheus-remote_write-
#          compatible backend, one X-Scope-OrgID header per tenant passed
#          on the command line.
# Requires env: METRICS_REMOTE_WRITE_URL, MYSQL_EXPORTER_HOST,
#               MYSQL_EXPORTER_USER, MYSQL_EXPORTER_PASSWORD
# Optional env: GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL,
#               PORTAL_API_BASE_URL, PORTAL_DASHBOARD_TEMPLATE_ID,
#               PORTAL_ALERT_TECHNOLOGY_ID
# Usage: sudo ./mysql.sh <tenant-id> [<tenant-id> ...]
#
# Note: this migrates `mysql-script.sh` from the source onboarding scripts.
# Mirrors the structure of grafana-agent/linux/grafana-agent-host-install.sh
# — see that file (and ../linux/README.md) for the shared env var
# conventions this repo uses for per-exporter Grafana Agent installs.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${MYSQL_EXPORTER_HOST:?set MYSQL_EXPORTER_HOST, e.g. 10.0.0.12:3306}"
: "${MYSQL_EXPORTER_USER:?set MYSQL_EXPORTER_USER, the metrics-reader account for mysqld_exporter}"
: "${MYSQL_EXPORTER_PASSWORD:?set MYSQL_EXPORTER_PASSWORD}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <tenant-id> [<tenant-id> ...]" >&2
  exit 1
fi

# Pin the agent version explicitly rather than always pulling ":latest" —
# makes installs reproducible and lets an operator roll back by changing
# one env var. Grafana Agent (classic/static mode) is archived upstream in
# favor of Grafana Alloy; check https://github.com/grafana/agent/releases
# for the newest release still published there, or point ARTIFACT_BASE_URL
# at your own internal mirror if you vendor the binary.
GRAFANA_AGENT_VERSION="${GRAFANA_AGENT_VERSION:-v0.26.1}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/grafana/agent/releases/download/${GRAFANA_AGENT_VERSION}}"
# Verified against the GitHub releases API for this tag: v0.26.1 predates
# the grafana-agent-* asset rename (that happened around v0.31), so the
# asset here is still named `agent-linux-amd64.zip`. If you bump
# GRAFANA_AGENT_VERSION past v0.31.x, switch ARTIFACT_NAME to
# `grafana-agent-linux-amd64` (see elasticsearch.sh / oracle.sh for that
# convention) or the download below will 404.
ARTIFACT_NAME="agent-linux-amd64"

SERVICE="mysql_exporter.service"

echo "Tenant ID(s): $*"

curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/${ARTIFACT_NAME}.zip"
unzip -o "${ARTIFACT_NAME}.zip"
chmod a+x "${ARTIFACT_NAME}"
sudo mv "${ARTIFACT_NAME}" /usr/local/bin/

if [[ ! -e /etc/grafana-agent-mysql-config.yaml ]]; then
  sudo tee /etc/grafana-agent-mysql-config.yaml >/dev/null <<EOF
prometheus:
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-mysql-wal
server:
  http_listen_port: 12346
  http_listen_address: 127.0.0.1
  log_level: error

integrations:
  mysqld_exporter:
    # go-sql-driver DSN format: user:password@(host:port)/
    data_source_name: ${MYSQL_EXPORTER_USER}:${MYSQL_EXPORTER_PASSWORD}@(${MYSQL_EXPORTER_HOST})/
    enabled: true
  prometheus_remote_write:
EOF
fi

# Idempotency guard: only append a tenant's remote_write block if that
# tenant isn't already configured, so re-running the script for a new
# tenant doesn't duplicate existing ones.
for tenant in "$@"; do
  if ! grep -q "X-Scope-OrgID: ${tenant}$" /etc/grafana-agent-mysql-config.yaml; then
    tenant_block="  - url: ${METRICS_REMOTE_WRITE_URL}"$'\n'"    headers:"$'\n'"      X-Scope-OrgID: ${tenant}"
    echo "${tenant_block}" | sudo tee -a /etc/grafana-agent-mysql-config.yaml >/dev/null
  fi
done

sudo tee /etc/systemd/system/mysql_exporter.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (MySQL metrics)
Wants=network-online.target
After=network-online.target

[Service]
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/${ARTIFACT_NAME} \\
    --server.grpc-listen-address 127.0.0.1 \\
    --server.grpc-listen-port 9096 \\
    --config.file /etc/grafana-agent-mysql-config.yaml

Restart=always

[Install]
WantedBy=multi-user.target
EOM

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"
sudo systemctl status "$SERVICE" --no-pager || true

# Optional: register a dashboard/alert set for this tenant with an
# observability portal, if one is configured. Skipped entirely when
# PORTAL_API_BASE_URL isn't set, so the agent install itself never depends
# on a SaaS backend.
if [[ -n "${PORTAL_API_BASE_URL:-}" ]]; then
  : "${PORTAL_DASHBOARD_TEMPLATE_ID:?set PORTAL_DASHBOARD_TEMPLATE_ID when PORTAL_API_BASE_URL is set}"
  IFS=',' read -r -a _template_ids <<< "${PORTAL_DASHBOARD_TEMPLATE_ID}"
  _ids_json=$(printf '"%s",' "${_template_ids[@]}"); _ids_json="[${_ids_json%,}]"

  for tenant in "$@"; do
    response1=$(curl -s --location --request POST "${PORTAL_API_BASE_URL}/api/dashboards/v1.1/create" \
      --header "tenant-id: ${tenant}" \
      --header 'Content-Type: application/json' \
      --data-raw "{\"template_ids\": ${_ids_json}}")
    echo "Dashboard API response: ${response1}"

    if [[ -n "${PORTAL_ALERT_TECHNOLOGY_ID:-}" ]]; then
      response2=$(curl -s --location --request POST "${PORTAL_API_BASE_URL}/api/alerts/v1.1/set" \
        --header "tenant-id: ${tenant}" \
        --header 'Content-Type: application/json' \
        --data-raw "{\"technology_id\": \"${PORTAL_ALERT_TECHNOLOGY_ID}\"}")
      echo "Alerts API response: ${response2}"
    fi
  done
fi
