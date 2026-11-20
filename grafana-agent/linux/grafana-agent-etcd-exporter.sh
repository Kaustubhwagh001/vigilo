#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — etcd host
# Purpose: install the Grafana Agent static binary and configure it to
#          scrape a Kubernetes control-plane etcd instance over mTLS,
#          remote_writing to a Mimir/Prometheus-remote_write-compatible
#          backend.
# Requires env: METRICS_REMOTE_WRITE_URL, TENANT_ID
# Optional env: GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL,
#               ETCD_CLIENT_CERT_FILE, ETCD_CLIENT_KEY_FILE,
#               PORTAL_API_BASE_URL, PORTAL_REGISTER_SCRIPT_URL
# Usage: sudo ./grafana-agent-etcd-exporter.sh
#
# Note: run this on (or with network access to) a Kubernetes control-plane
# node — it reuses kubeadm's etcd client cert/key for mTLS to etcd's
# metrics endpoint, which is the standard kubeadm-managed cluster layout.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/prom/push}"
: "${TENANT_ID:?set TENANT_ID, e.g. your Mimir/Loki org ID}"

# See grafana-agent-host-install.sh for why this is pinned and overridable.
GRAFANA_AGENT_VERSION="${GRAFANA_AGENT_VERSION:-v0.40.3}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/grafana/agent/releases/download/${GRAFANA_AGENT_VERSION}}"

# Defaults match kubeadm's standard PKI layout; override if your cluster
# keeps etcd client certs elsewhere.
ETCD_CLIENT_CERT_FILE="${ETCD_CLIENT_CERT_FILE:-/etc/kubernetes/pki/apiserver-etcd-client.crt}"
ETCD_CLIENT_KEY_FILE="${ETCD_CLIENT_KEY_FILE:-/etc/kubernetes/pki/apiserver-etcd-client.key}"

SERVICE="etcd_exporter.service"
IP=$(hostname -I | awk '{print $1}')

echo "Tenant ID: ${TENANT_ID}"

curl -fsSL -O --noproxy '*' "${ARTIFACT_BASE_URL}/grafana-agent-linux-amd64.zip"
unzip -o "grafana-agent-linux-amd64.zip"
chmod a+x "grafana-agent-linux-amd64"
sudo mv grafana-agent-linux-amd64 /usr/local/bin/

sudo tee /etc/grafana-agent-etcd-config.yaml >/dev/null <<EOF
metrics:
  configs:
    - name: integrations
      remote_write:
        - url: ${METRICS_REMOTE_WRITE_URL}
          headers:
            X-Scope-OrgID: ${TENANT_ID}
      scrape_configs:
        - job_name: integrations/etcd
          scheme: https
          tls_config:
            cert_file: ${ETCD_CLIENT_CERT_FILE}
            key_file: ${ETCD_CLIENT_KEY_FILE}
            # etcd's metrics cert is typically issued for the Pod/Service
            # name, not the node IP we scrape it by — skip verification
            # rather than requiring a SAN that matches every node's IP.
            insecure_skip_verify: true
          static_configs:
            - targets:
                - ${IP}:2379
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-etcd-wal
server:
  http_listen_port: 12345
  http_listen_address: 127.0.0.1
EOF

sudo tee /etc/systemd/system/etcd_exporter.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (etcd metrics)
Wants=network-online.target
After=network-online.target

[Service]
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/grafana-agent-linux-amd64 \\
    --server.grpc-listen-address 127.0.0.1 \\
    --server.grpc-listen-port 9096 \\
    --config.file /etc/grafana-agent-etcd-config.yaml

Restart=always

[Install]
WantedBy=multi-user.target
EOM

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"

# Optional: register an etcd dashboard for this tenant with an
# observability portal, if one is configured.
if [[ -n "${PORTAL_API_BASE_URL:-}" ]]; then
  curl -s --noproxy "*" --location --request POST "${PORTAL_API_BASE_URL}/api/dashboards/createdashboard2/etcd" \
    --header 'Content-Type: application/json' \
    -d "{\"tenantID\": \"${TENANT_ID}\"}"
fi

# Optional: hand off to a fleet-registration script hosted on your own
# mirror. No public equivalent exists for this step, so it's opt-in.
if [[ -n "${PORTAL_REGISTER_SCRIPT_URL:-}" ]]; then
  curl -fsSL --noproxy "*" -L -O "${PORTAL_REGISTER_SCRIPT_URL}"
  chmod a+x server-info.sh
  bash server-info.sh "${TENANT_ID}" kubernetes
fi
