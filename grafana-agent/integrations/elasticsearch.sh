#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — Elasticsearch
# Purpose: install the Grafana Agent static binary and enable its built-in
#          elasticsearch_exporter integration against an Elasticsearch
#          cluster, remote_writing metrics to a Mimir/Prometheus-
#          remote_write-compatible backend, one X-Scope-OrgID header per
#          tenant passed on the command line.
# Requires env: METRICS_REMOTE_WRITE_URL, ELASTICSEARCH_EXPORTER_HOST,
#               ELASTICSEARCH_EXPORTER_USER, ELASTICSEARCH_EXPORTER_PASSWORD
# Optional env: ELASTICSEARCH_EXPORTER_SSL_SKIP_VERIFY,
#               GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL,
#               PORTAL_API_BASE_URL, PORTAL_DASHBOARD_TEMPLATE_ID
# Usage: sudo ./elasticsearch.sh <tenant-id> [<tenant-id> ...]
#
# Note: this migrates `elastic_onboarding.sh` from the source onboarding
# scripts. Mirrors the structure of grafana-agent/linux/grafana-agent-host-
# install.sh — see that file (and ../linux/README.md) for the shared env
# var conventions this repo uses for per-exporter Grafana Agent installs.
#
# These env var names are distinct from ELASTICSEARCH_URL/USERNAME/PASSWORD
# in .env.example — those configure otel-collector/agent's APM-server
# backend (where traces get written); these configure the cluster this
# script *monitors* via elasticsearch_exporter. They may be different
# clusters, so don't conflate the two.
#
# The dashboard-provisioning call was commented out in the source script
# (seemingly disabled mid-rollout) — it's reproduced here the same way as
# in mongodb.sh/mysql.sh/redis.sh, gated behind PORTAL_API_BASE_URL, so
# it's inert unless you opt in.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${ELASTICSEARCH_EXPORTER_HOST:?set ELASTICSEARCH_EXPORTER_HOST, e.g. 10.0.0.16:9200}"
: "${ELASTICSEARCH_EXPORTER_USER:?set ELASTICSEARCH_EXPORTER_USER, the metrics-reader account for elasticsearch_exporter}"
: "${ELASTICSEARCH_EXPORTER_PASSWORD:?set ELASTICSEARCH_EXPORTER_PASSWORD}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <tenant-id> [<tenant-id> ...]" >&2
  exit 1
fi

# The source cluster used a self-signed cert (ssl_skip_verify: true,
# hardcoded). Kept as the default here for parity, but exposed as an env
# var so anyone running this against a cluster with a real CA-issued cert
# can turn verification back on.
ELASTICSEARCH_EXPORTER_SSL_SKIP_VERIFY="${ELASTICSEARCH_EXPORTER_SSL_SKIP_VERIFY:-true}"

# Pin the agent version explicitly rather than always pulling ":latest" —
# makes installs reproducible and lets an operator roll back by changing
# one env var. Grafana Agent (classic/static mode) is archived upstream in
# favor of Grafana Alloy; check https://github.com/grafana/agent/releases
# for the newest release still published there, or point ARTIFACT_BASE_URL
# at your own internal mirror if you vendor the binary.
GRAFANA_AGENT_VERSION="${GRAFANA_AGENT_VERSION:-v0.37.3}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/grafana/agent/releases/download/${GRAFANA_AGENT_VERSION}}"
# Verified against the GitHub releases API for this tag.
ARTIFACT_NAME="grafana-agent-linux-amd64"

SERVICE="elasticsearch_exporter.service"

echo "Tenant ID(s): $*"

id -u grafana-agent &>/dev/null || sudo useradd --no-create-home --shell /bin/false grafana-agent

curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/${ARTIFACT_NAME}.zip"
unzip -o "${ARTIFACT_NAME}.zip"
chmod a+x "${ARTIFACT_NAME}"
sudo mv "${ARTIFACT_NAME}" "/usr/local/bin/${ARTIFACT_NAME}-${GRAFANA_AGENT_VERSION}"

if [[ ! -e /etc/grafana-agent-elastic-config.yaml ]]; then
  sudo tee /etc/grafana-agent-elastic-config.yaml >/dev/null <<EOF
prometheus:
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-elastic-wal
server:
  log_level: error
integrations:
  elasticsearch_exporter:
    enabled: true
    address: https://${ELASTICSEARCH_EXPORTER_USER}:${ELASTICSEARCH_EXPORTER_PASSWORD}@${ELASTICSEARCH_EXPORTER_HOST}
    all: true
    indices: true
    indices_settings: true
    cluster_settings: true
    shards: true
    snapshots: true
    aliases: true
    data_stream: true
    slm: true
    # ca / client_cert / client_private_key: set these instead of
    # ssl_skip_verify once the cluster has a CA-issued cert.
    ssl_skip_verify: ${ELASTICSEARCH_EXPORTER_SSL_SKIP_VERIFY}

  prometheus_remote_write:
EOF
fi

# Idempotency guard: only append a tenant's remote_write block if that
# tenant isn't already configured, so re-running the script for a new
# tenant doesn't duplicate existing ones.
for tenant in "$@"; do
  if ! grep -q "X-Scope-OrgID: ${tenant}$" /etc/grafana-agent-elastic-config.yaml; then
    tenant_block="  - url: ${METRICS_REMOTE_WRITE_URL}"$'\n'"    headers:"$'\n'"      X-Scope-OrgID: ${tenant}"
    echo "${tenant_block}" | sudo tee -a /etc/grafana-agent-elastic-config.yaml >/dev/null
  fi
done

sudo tee /etc/systemd/system/elasticsearch_exporter.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (Elasticsearch metrics)
Wants=network-online.target
After=network-online.target

[Service]
User=grafana-agent
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/${ARTIFACT_NAME}-${GRAFANA_AGENT_VERSION} \\
    -server.grpc.address=127.0.0.1:9092 \\
    -server.http.address=127.0.0.1:12342 \\
    --config.file /etc/grafana-agent-elastic-config.yaml

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
  : "${PORTAL_DASHBOARD_TEMPLATE_ID:?set PORTAL_DASHBOARD_TEMPLATE_ID when PORTAL_API_BASE_URL is set}"
  IFS=',' read -r -a _template_ids <<< "${PORTAL_DASHBOARD_TEMPLATE_ID}"
  _ids_json=$(printf '"%s",' "${_template_ids[@]}"); _ids_json="[${_ids_json%,}]"

  for tenant in "$@"; do
    response1=$(curl -s --location --request POST "${PORTAL_API_BASE_URL}/api/dashboards/v1.1/create" \
      --header "tenant-id: ${tenant}" \
      --header 'Content-Type: application/json' \
      --data-raw "{\"template_ids\": ${_ids_json}}")
    echo "Dashboard API response: ${response1}"
  done
fi
