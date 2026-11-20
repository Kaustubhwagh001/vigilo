#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — MongoDB
# Purpose: install the Grafana Agent static binary and enable its built-in
#          mongodb_exporter integration against a MongoDB node, remote_writing
#          metrics to a Mimir/Prometheus-remote_write-compatible backend,
#          one X-Scope-OrgID header per tenant passed on the command line.
# Requires env: METRICS_REMOTE_WRITE_URL, MONGODB_HOST, MONGODB_USER,
#               MONGODB_PASSWORD
# Optional env: MONGODB_SERVICE_NAME, MONGODB_CLUSTER_NAME,
#               GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL,
#               PORTAL_API_BASE_URL, PORTAL_DASHBOARD_TEMPLATE_ID,
#               PORTAL_ALERT_TECHNOLOGY_ID, PORTAL_REGISTER_SCRIPT_URL
# Usage: sudo ./mongodb.sh <tenant-id> [<tenant-id> ...]
#
# Note: this migrates `mongodb-script-v0.26.1.sh` from the source onboarding
# scripts. Mirrors the structure of grafana-agent/linux/grafana-agent-host-
# install.sh — see that file (and ../linux/README.md) for the shared env var
# conventions this repo uses for per-exporter Grafana Agent installs.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${MONGODB_HOST:?set MONGODB_HOST, e.g. 10.0.0.11:27017}"
: "${MONGODB_USER:?set MONGODB_USER, the read-only metrics account for mongodb_exporter}"
: "${MONGODB_PASSWORD:?set MONGODB_PASSWORD}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <tenant-id> [<tenant-id> ...]" >&2
  exit 1
fi

# Relabels let one dashboard/alert set key off stable service/cluster names
# instead of the ephemeral scrape __address__ — set these per host when you
# have more than one MongoDB node reporting into the same tenant.
MONGODB_SERVICE_NAME="${MONGODB_SERVICE_NAME:-mongodb-node1}"
MONGODB_CLUSTER_NAME="${MONGODB_CLUSTER_NAME:-mongodb-cluster}"

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

SERVICE="mongodb_exporter.service"

echo "Tenant ID(s): $*"

id -u grafana-agent &>/dev/null || sudo useradd --no-create-home --shell /bin/false grafana-agent

curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/${ARTIFACT_NAME}.zip"
unzip -o "${ARTIFACT_NAME}.zip"
chmod a+x "${ARTIFACT_NAME}"
sudo mv "${ARTIFACT_NAME}" "/usr/local/bin/${ARTIFACT_NAME}-${GRAFANA_AGENT_VERSION}"

if [[ ! -e /etc/grafana-agent-mongodb-config.yaml ]]; then
  sudo tee /etc/grafana-agent-mongodb-config.yaml >/dev/null <<EOF
prometheus:
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-mongodb-wal
server:
  log_level: error

integrations:
  mongodb_exporter:
    enabled: true
    mongodb_uri: mongodb://${MONGODB_USER}:${MONGODB_PASSWORD}@${MONGODB_HOST}
    relabel_configs:
      - replacement: '${MONGODB_SERVICE_NAME}'
        source_labels:
          - __address__
        target_label: service_name
      - replacement: '${MONGODB_CLUSTER_NAME}'
        source_labels:
          - __address__
        target_label: mongodb_cluster

  prometheus_remote_write:
EOF
fi

# Idempotency guard: only append a tenant's remote_write block if that
# tenant isn't already configured, so re-running the script for a new
# tenant doesn't duplicate existing ones.
for tenant in "$@"; do
  if ! grep -q "X-Scope-OrgID: ${tenant}$" /etc/grafana-agent-mongodb-config.yaml; then
    tenant_block="  - url: ${METRICS_REMOTE_WRITE_URL}"$'\n'"    headers:"$'\n'"      X-Scope-OrgID: ${tenant}"
    echo "${tenant_block}" | sudo tee -a /etc/grafana-agent-mongodb-config.yaml >/dev/null
  fi
done

sudo tee /etc/systemd/system/mongodb_exporter.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (MongoDB metrics)
Wants=network-online.target
After=network-online.target

[Service]
User=grafana-agent
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/${ARTIFACT_NAME}-${GRAFANA_AGENT_VERSION} \\
    -server.grpc.address=127.0.0.1:9095 \\
    -server.http.address=127.0.0.1:12345 \\
    --config.file /etc/grafana-agent-mongodb-config.yaml

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
# on a SaaS backend. PORTAL_DASHBOARD_TEMPLATE_ID accepts a comma-separated
# list if you need more than one template applied.
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

# Optional: hand off to a fleet-registration script hosted on your own
# mirror (e.g. to record this host against inventory/CMDB). No public
# equivalent exists for this step, so it's opt-in via env var.
if [[ -n "${PORTAL_REGISTER_SCRIPT_URL:-}" ]]; then
  curl -fsSL --noproxy "*" -L -O "${PORTAL_REGISTER_SCRIPT_URL}"
  chmod a+x server-info.sh
  for tenant in "$@"; do
    bash server-info.sh "$tenant" mongodb
  done
fi
