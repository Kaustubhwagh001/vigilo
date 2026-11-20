#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — generic Linux host
# Purpose: install the Grafana Agent static binary as a service on a
#          generic Linux host and configure it to scrape the bundled
#          node_exporter + process_exporter integrations, remote_writing
#          metrics to a Mimir/Prometheus-remote_write-compatible backend,
#          one X-Scope-OrgID header per tenant passed on the command line.
# Requires env: METRICS_REMOTE_WRITE_URL
# Optional env: GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL,
#               PORTAL_API_BASE_URL, PORTAL_DASHBOARD_TEMPLATE_ID,
#               PORTAL_ALERT_TECHNOLOGY_ID, PORTAL_REGISTER_SCRIPT_URL
# Usage: sudo ./grafana-agent-host-install.sh <tenant-id> [<tenant-id> ...]
#
# Note: this migrates `linux_script2.sh` from the source onboarding
# scripts. Its near-duplicate `jobsv_linux_script.sh` was NOT migrated —
# see the sanitization report for why.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"

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
GRAFANA_AGENT_VERSION="${GRAFANA_AGENT_VERSION:-v0.40.3}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/grafana/agent/releases/download/${GRAFANA_AGENT_VERSION}}"

SERVICE="grafana-agent.service"

echo "Tenant ID(s): $*"

id -u grafana-agent &>/dev/null || sudo useradd --no-create-home --shell /bin/false grafana-agent

curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/grafana-agent-linux-amd64.zip"
unzip -o "grafana-agent-linux-amd64.zip"
chmod a+x "grafana-agent-linux-amd64"
sudo mv grafana-agent-linux-amd64 /usr/local/bin/

# Build one remote_write stanza per tenant ID, each carrying its own
# X-Scope-OrgID so a single host can ship metrics for several tenants.
content=""
for tenant in "$@"; do
  content+="  - url: ${METRICS_REMOTE_WRITE_URL}"$'\n'
  content+="    headers:"$'\n'
  content+="      X-Scope-OrgID: ${tenant}"$'\n'
done

if [[ ! -e /etc/grafana-agent-host-config.yaml ]]; then
  sudo tee /etc/grafana-agent-host-config.yaml >/dev/null <<EOF
prometheus:
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-host-wal
server:
  http_listen_port: 12348
  http_listen_address: 127.0.0.1
  log_level: error
integrations:

  process_exporter:
    enabled: true
    process_names:
      - comm:
        - bash
        - prometheus
        - '.+'
      - cmdline:
        - '.+'

  node_exporter:
    enabled: true
    disable_collectors:
      - infiniband
  prometheus_remote_write:
EOF
fi

# Idempotency guard: only append a tenant's remote_write block if that
# tenant isn't already configured, so re-running the script for a new
# tenant doesn't duplicate existing ones.
for tenant in "$@"; do
  if ! grep -q "X-Scope-OrgID: ${tenant}$" /etc/grafana-agent-host-config.yaml; then
    tenant_block="  - url: ${METRICS_REMOTE_WRITE_URL}"$'\n'"    headers:"$'\n'"      X-Scope-OrgID: ${tenant}"
    echo "${tenant_block}" | sudo tee -a /etc/grafana-agent-host-config.yaml >/dev/null
  fi
done

if [ -e /bin/systemctl ]; then
  sudo tee /etc/systemd/system/grafana-agent.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent

[Service]
User=grafana-agent
ExecStart=/usr/local/bin/grafana-agent-linux-amd64 \\
    --server.grpc-listen-address 127.0.0.1 \\
    --server.grpc-listen-port 9098 \\
    --config.file /etc/grafana-agent-host-config.yaml

Restart=always

[Install]
WantedBy=multi-user.target
EOM

  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SERVICE"

else
  # Legacy SysV-init fallback for hosts without systemd. The init script
  # itself is a custom wrapper (not a Grafana upstream release asset) —
  # point ARTIFACT_BASE_URL at wherever you host it if you need this path.
  curl -fsSL --noproxy "*" -O "${ARTIFACT_BASE_URL}/rhel-onboarding"
  sudo cp rhel-onboarding /etc/init.d/grafana-agent
  sudo chmod +x /etc/init.d/grafana-agent
  sudo service grafana-agent start 2>/dev/null || true
  sudo chkconfig grafana-agent on
fi

# Optional: register this host's dashboards/alerts with an observability
# portal, if one is configured. Skipped entirely when PORTAL_API_BASE_URL
# isn't set, so the agent install itself never depends on a SaaS backend.
if [[ -n "${PORTAL_API_BASE_URL:-}" ]]; then
  : "${PORTAL_DASHBOARD_TEMPLATE_ID:?set PORTAL_DASHBOARD_TEMPLATE_ID when PORTAL_API_BASE_URL is set}"
  : "${PORTAL_ALERT_TECHNOLOGY_ID:?set PORTAL_ALERT_TECHNOLOGY_ID when PORTAL_API_BASE_URL is set}"
  for tenant in "$@"; do
    response1=$(curl -s --location --request POST "${PORTAL_API_BASE_URL}/api/dashboards/v1.1/create" \
      --header "tenant-id: ${tenant}" \
      --header 'Content-Type: application/json' \
      --data-raw "{\"template_ids\": [\"${PORTAL_DASHBOARD_TEMPLATE_ID}\"]}")
    echo "Dashboard API response: ${response1}"

    response2=$(curl -s --location --request POST "${PORTAL_API_BASE_URL}/api/alerts/v1.1/set" \
      --header "tenant-id: ${tenant}" \
      --header 'Content-Type: application/json' \
      --data-raw "{\"technology_id\": \"${PORTAL_ALERT_TECHNOLOGY_ID}\"}")
    echo "Alerts API response: ${response2}"
  done
fi

# Optional: hand off to a fleet-registration script hosted on your own
# mirror (e.g. to record this host against inventory/CMDB). No public
# equivalent exists for this step, so it's opt-in via env var.
if [[ -n "${PORTAL_REGISTER_SCRIPT_URL:-}" ]]; then
  curl -fsSL --noproxy "*" -L -O "${PORTAL_REGISTER_SCRIPT_URL}"
  chmod a+x server-info.sh
  for tenant in "$@"; do
    bash server-info.sh "$tenant" linux
  done
  if command -v kubelet &>/dev/null; then
    for tenant in "$@"; do
      bash server-info.sh "$tenant" kubernetes
    done
  fi
fi
