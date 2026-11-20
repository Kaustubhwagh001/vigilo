#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — CRI-O host
# Purpose: install the Grafana Agent static binary and configure it to
#          scrape a CRI-O exporter running on this host, remote_writing
#          metrics to a Mimir/Prometheus-remote_write-compatible backend.
# Requires env: METRICS_REMOTE_WRITE_URL, TENANT_ID
# Optional env: GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL,
#               PORTAL_API_BASE_URL, PORTAL_DASHBOARD_TEMPLATE_ID
# Usage: sudo ./grafana-agent-crio-exporter.sh
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${TENANT_ID:?set TENANT_ID, e.g. your Mimir/Loki org ID}"

# See grafana-agent-host-install.sh for why this is pinned and overridable.
GRAFANA_AGENT_VERSION="${GRAFANA_AGENT_VERSION:-v0.40.3}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/grafana/agent/releases/download/${GRAFANA_AGENT_VERSION}}"

SERVICE="crio_exporter.service"

echo "Tenant ID: ${TENANT_ID}"

curl -fsSL --noproxy "*" -O "${ARTIFACT_BASE_URL}/grafana-agent-linux-amd64.zip"
unzip -o "grafana-agent-linux-amd64.zip"
chmod a+x "grafana-agent-linux-amd64"
sudo mv grafana-agent-linux-amd64 /usr/local/bin/

ip=$(hostname -I | awk '{print $1}')

if [[ ! -e /etc/grafana-agent-crio-config.yaml ]]; then
  sudo tee /etc/grafana-agent-crio-config.yaml >/dev/null <<EOF
prometheus:
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-crio-wal
  configs:
    - name: integrations
      remote_write:
      - url: ${METRICS_REMOTE_WRITE_URL}
        headers:
          X-Scope-OrgID: ${TENANT_ID}
      scrape_configs:
        - job_name: 'crio-exporter'
          metrics_path: /metrics
          static_configs:
            - targets:
              - ${ip}:9090

server:
  http_listen_port: 12348
  http_listen_address: 127.0.0.1
  log_level: error
EOF
fi

sudo tee /etc/systemd/system/crio_exporter.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (CRI-O metrics)
Wants=network-online.target
After=network-online.target

[Service]
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/grafana-agent-linux-amd64 \\
    --server.grpc-listen-address 127.0.0.1 \\
    --server.grpc-listen-port 9096 \\
    --config.file /etc/grafana-agent-crio-config.yaml

Restart=always

[Install]
WantedBy=multi-user.target
EOM

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"
sudo systemctl status "$SERVICE" --no-pager || true

# Optional: register a dashboard for this tenant with an observability
# portal, if one is configured. Skipped entirely when PORTAL_API_BASE_URL
# isn't set.
if [[ -n "${PORTAL_API_BASE_URL:-}" ]]; then
  : "${PORTAL_DASHBOARD_TEMPLATE_ID:?set PORTAL_DASHBOARD_TEMPLATE_ID when PORTAL_API_BASE_URL is set}"
  response1=$(curl -s --location --request POST "${PORTAL_API_BASE_URL}/api/dashboards/v1.1/create" \
    --header "tenant-id: ${TENANT_ID}" \
    --header 'Content-Type: application/json' \
    --data-raw "{\"template_ids\": [\"${PORTAL_DASHBOARD_TEMPLATE_ID}\"]}")
  echo "Dashboard API response: ${response1}"
fi
