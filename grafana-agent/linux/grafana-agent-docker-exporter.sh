#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — Docker host
# Purpose: install the Grafana Agent static binary and configure it to
#          scrape the Docker engine's metrics endpoint on this host,
#          remote_writing to a Mimir/Prometheus-remote_write-compatible
#          backend.
# Requires env: METRICS_REMOTE_WRITE_URL, TENANT_ID
# Optional env: GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL,
#               PORTAL_API_BASE_URL, PORTAL_REGISTER_SCRIPT_URL
# Usage: sudo ./grafana-agent-docker-exporter.sh
#
# Note: the Docker engine must already expose metrics (dockerd
# --metrics-addr=0.0.0.0:8080 or equivalent daemon.json setting) for the
# scrape target below to return anything.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${TENANT_ID:?set TENANT_ID, e.g. your Mimir/Loki org ID}"

# See grafana-agent-host-install.sh for why this is pinned and overridable.
GRAFANA_AGENT_VERSION="${GRAFANA_AGENT_VERSION:-v0.40.3}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/grafana/agent/releases/download/${GRAFANA_AGENT_VERSION}}"

SERVICE="docker_exporter.service"
IP=$(hostname -I | awk '{print $1}')

echo "Tenant ID: ${TENANT_ID}"

curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/grafana-agent-linux-amd64.zip"
unzip -o "grafana-agent-linux-amd64.zip"
chmod a+x "grafana-agent-linux-amd64"
sudo mv grafana-agent-linux-amd64 /usr/local/bin/

sudo tee /etc/grafana-agent-docker-config.yaml >/dev/null <<EOF
metrics:
  configs:
    - name: integrations
      remote_write:
        - url: ${METRICS_REMOTE_WRITE_URL}
          headers:
            X-Scope-OrgID: ${TENANT_ID}
      scrape_configs:
        - job_name: integrations/docker
          scheme: http
          static_configs:
            - targets:
                - ${IP}:8080
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-docker-wal
server:
  http_listen_port: 12346
  log_level: error
EOF

sudo tee /etc/systemd/system/docker_exporter.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (Docker metrics)
Wants=network-online.target
After=network-online.target

[Service]
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/grafana-agent-linux-amd64 \\
    --server.http-listen-address 127.0.0.1 \\
    --server.grpc-listen-port 9099 \\
    --config.file /etc/grafana-agent-docker-config.yaml

Restart=always

[Install]
WantedBy=multi-user.target
EOM

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"

# Optional: register a Docker dashboard for this tenant with an
# observability portal, if one is configured.
if [[ -n "${PORTAL_API_BASE_URL:-}" ]]; then
  curl -s --noproxy "*" --location --request POST "${PORTAL_API_BASE_URL}/api/dashboards/createdashboard2/docker" \
    --header 'Content-Type: application/json' \
    -d "{\"tenantID\": \"${TENANT_ID}\"}"
fi

# Optional: hand off to a fleet-registration script hosted on your own
# mirror. No public equivalent exists for this step, so it's opt-in.
if [[ -n "${PORTAL_REGISTER_SCRIPT_URL:-}" ]]; then
  curl -fsSL --noproxy "*" -L -O "${PORTAL_REGISTER_SCRIPT_URL}"
  chmod a+x server-info.sh
  bash server-info.sh "${TENANT_ID}" docker
fi
