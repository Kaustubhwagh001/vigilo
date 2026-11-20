#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — PostgreSQL
# Purpose: install the Grafana Agent static binary and enable its built-in
#          postgres_exporter integration against a PostgreSQL instance,
#          remote_writing metrics to a Mimir/Prometheus-remote_write-
#          compatible backend, one X-Scope-OrgID header per tenant passed
#          on the command line.
# Requires env: METRICS_REMOTE_WRITE_URL, POSTGRES_EXPORTER_HOST,
#               POSTGRES_EXPORTER_USER, POSTGRES_EXPORTER_PASSWORD
# Optional env: POSTGRES_EXPORTER_DBNAME, POSTGRES_EXPORTER_SSLMODE,
#               GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL,
#               PORTAL_API_BASE_URL, PORTAL_REGISTER_SCRIPT_URL
# Usage: sudo ./postgresql.sh <tenant-id> [<tenant-id> ...]
#
# Note: this migrates `psql-script.sh` from the source onboarding scripts.
# Mirrors the structure of grafana-agent/linux/grafana-agent-host-install.sh
# — see that file (and ../linux/README.md) for the shared env var
# conventions this repo uses for per-exporter Grafana Agent installs.
#
# The source script's dashboard-provisioning call used a different shape
# than its mongodb/mysql/redis siblings (a single POST to a tech-specific
# path, instead of the dashboards/v1.1/create + alerts/v1.1/set pair), and
# only ever used the first tenant ID ($1) rather than looping over all of
# them — the loop below fixes that so every tenant passed in gets
# registered, same idempotent intent as the original.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${POSTGRES_EXPORTER_HOST:?set POSTGRES_EXPORTER_HOST, e.g. 10.0.0.14:5432}"
: "${POSTGRES_EXPORTER_USER:?set POSTGRES_EXPORTER_USER, the metrics-reader account for postgres_exporter}"
: "${POSTGRES_EXPORTER_PASSWORD:?set POSTGRES_EXPORTER_PASSWORD}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <tenant-id> [<tenant-id> ...]" >&2
  exit 1
fi

POSTGRES_EXPORTER_DBNAME="${POSTGRES_EXPORTER_DBNAME:-postgres}"
POSTGRES_EXPORTER_SSLMODE="${POSTGRES_EXPORTER_SSLMODE:-disable}"

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

SERVICE="postgresql_exporter.service"

echo "Tenant ID(s): $*"

curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/${ARTIFACT_NAME}.zip"
unzip -o "${ARTIFACT_NAME}.zip"
chmod a+x "${ARTIFACT_NAME}"
sudo mv "${ARTIFACT_NAME}" /usr/local/bin/

if [[ ! -e /etc/grafana-agent-postgresql-config.yaml ]]; then
  sudo tee /etc/grafana-agent-postgresql-config.yaml >/dev/null <<EOF
prometheus:
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-postgresql-wal
server:
  http_listen_port: 12347
  http_listen_address: 127.0.0.1
  log_level: error

integrations:
  postgres_exporter:
    data_source_names:
      - postgresql://${POSTGRES_EXPORTER_USER}:${POSTGRES_EXPORTER_PASSWORD}@${POSTGRES_EXPORTER_HOST}/${POSTGRES_EXPORTER_DBNAME}?sslmode=${POSTGRES_EXPORTER_SSLMODE}
    enabled: true
  prometheus_remote_write:
EOF
fi

# Idempotency guard: only append a tenant's remote_write block if that
# tenant isn't already configured, so re-running the script for a new
# tenant doesn't duplicate existing ones.
for tenant in "$@"; do
  if ! grep -q "X-Scope-OrgID: ${tenant}$" /etc/grafana-agent-postgresql-config.yaml; then
    tenant_block="  - url: ${METRICS_REMOTE_WRITE_URL}"$'\n'"    headers:"$'\n'"      X-Scope-OrgID: ${tenant}"
    echo "${tenant_block}" | sudo tee -a /etc/grafana-agent-postgresql-config.yaml >/dev/null
  fi
done

sudo tee /etc/systemd/system/postgresql_exporter.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (PostgreSQL metrics)
Wants=network-online.target
After=network-online.target

[Service]
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/${ARTIFACT_NAME} \\
    --server.grpc-listen-address 127.0.0.1 \\
    --server.grpc-listen-port 9097 \\
    --config.file /etc/grafana-agent-postgresql-config.yaml

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
    curl --noproxy "*" --location --request POST "${PORTAL_API_BASE_URL}/api/dashboards/createdashboard2/psql" \
      --header 'Content-Type: application/json' \
      -d "{\"tenantID\": \"${tenant}\"}"
  done
fi

# Optional: hand off to a fleet-registration script hosted on your own
# mirror (e.g. to record this host against inventory/CMDB). No public
# equivalent exists for this step, so it's opt-in via env var.
if [[ -n "${PORTAL_REGISTER_SCRIPT_URL:-}" ]]; then
  curl -fsSL --noproxy "*" -L -O "${PORTAL_REGISTER_SCRIPT_URL}"
  chmod a+x server-info.sh
  for tenant in "$@"; do
    bash server-info.sh "$tenant" postgresql
  done
fi
