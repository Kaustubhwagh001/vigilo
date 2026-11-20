#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Redis exporter + Prometheus — Redis
# Purpose: install oliver006/redis_exporter and a standalone Prometheus
#          binary (not Grafana Agent — see note below) that scrapes it and
#          remote_writes to a Mimir/Prometheus-remote_write-compatible
#          backend, one X-Scope-OrgID header per tenant passed on the
#          command line.
# Requires env: METRICS_REMOTE_WRITE_URL, REDIS_HOST, REDIS_PASSWORD
# Optional env: REDIS_EXPORTER_VERSION, PROMETHEUS_VERSION,
#               REDIS_HOSTNAME_LABEL, ARTIFACT_BASE_URL, PROMETHEUS_BASE_URL,
#               PORTAL_API_BASE_URL, PORTAL_DASHBOARD_TEMPLATE_ID,
#               PORTAL_ALERT_TECHNOLOGY_ID, PORTAL_REGISTER_SCRIPT_URL
# Usage: sudo ./redis.sh <tenant-id> [<tenant-id> ...]
#
# Note: this migrates `redis-with-password.sh` from the source onboarding
# scripts (its `redis_with_passowrd_26_july_24_bkp.sh` backup was already
# diffed and confirmed superseded, so it wasn't migrated separately).
#
# Unlike the other scripts in this folder, the source config here never
# adopted Grafana Agent — it runs a plain Prometheus binary with a static
# scrape_config pointed at redis_exporter, and remote_writes from there
# directly. Reproduced as-is rather than "modernized" to Grafana Agent,
# since that's what's actually running in the environment this was
# migrated from.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${REDIS_HOST:?set REDIS_HOST, e.g. 10.0.0.15:6379}"
: "${REDIS_PASSWORD:?set REDIS_PASSWORD}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <tenant-id> [<tenant-id> ...]" >&2
  exit 1
fi

REDIS_HOSTNAME_LABEL="${REDIS_HOSTNAME_LABEL:-redis-host}"

REDIS_EXPORTER_VERSION="${REDIS_EXPORTER_VERSION:-1.32.0}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/oliver006/redis_exporter/releases/download}"

# Pinned to the beta release the source script shipped (verified real via
# the GitHub releases API) rather than silently upgrading it — Prometheus
# has had many stable 2.x releases since; point this at a current stable
# tag (https://github.com/prometheus/prometheus/releases) for anything
# beyond a demo/reference deployment.
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-2.32.0-beta.0}"
PROMETHEUS_BASE_URL="${PROMETHEUS_BASE_URL:-https://github.com/prometheus/prometheus/releases/download}"

SERVICE="redis_exporter.service"
SERVICE2="prometheus.service"

cd /tmp

curl --noproxy "*" -O -L "${ARTIFACT_BASE_URL}/v${REDIS_EXPORTER_VERSION}/redis_exporter-v${REDIS_EXPORTER_VERSION}.linux-amd64.tar.gz"
tar xvf "redis_exporter-v${REDIS_EXPORTER_VERSION}.linux-amd64.tar.gz"
sudo mv "redis_exporter-v${REDIS_EXPORTER_VERSION}.linux-amd64/redis_exporter" /usr/local/bin/

sudo tee /etc/systemd/system/redis_exporter.service >/dev/null <<EOM
[Unit]
Description=Redis Exporter
Documentation=https://github.com/oliver006/redis_exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/redis_exporter \\
  --log-format=txt \\
  --namespace=redis \\
  --web.listen-address=:9121 \\
  --web.telemetry-path=/metrics \\
  --redis.addr=redis://${REDIS_HOST} \\
  --redis.password=${REDIS_PASSWORD}

SyslogIdentifier=redis_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOM

echo "Starting & enabling redis_exporter service"
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"

echo "Downloading prometheus package"
cd /tmp
curl --noproxy "*" -O -L "${PROMETHEUS_BASE_URL}/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
tar -xvzf "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" -C /tmp
sudo mv "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" /usr/local/bin/

if [[ ! -e /etc/prometheus.yaml ]]; then
  sudo tee /etc/prometheus.yaml >/dev/null <<EOF
scrape_configs:
  - job_name: redis_exporter
    static_configs:
      - targets: ['${REDIS_HOST%%:*}:9121']
        labels:
          alias: ${REDIS_HOSTNAME_LABEL}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: ${REDIS_HOST%%:*}:9121

global:
  scrape_interval: 10s
remote_write:
EOF
fi

# Idempotency guard: only append a tenant's remote_write block if that
# tenant isn't already configured, so re-running the script for a new
# tenant doesn't duplicate existing ones.
for tenant in "$@"; do
  if ! grep -q "X-Scope-OrgID: ${tenant}$" /etc/prometheus.yaml; then
    tenant_block="- url: ${METRICS_REMOTE_WRITE_URL}"$'\n'"  headers:"$'\n'"    X-Scope-OrgID: ${tenant}"
    echo "${tenant_block}" | sudo tee -a /etc/prometheus.yaml >/dev/null
  fi
done

sudo tee /etc/systemd/system/prometheus.service >/dev/null <<EOM
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/prometheus \\
    --web.listen-address 127.0.0.1:9090 \\
    --config.file /etc/prometheus.yaml \\
    --storage.tsdb.path /tmp/grafana-agent-redis-wal

Restart=always

[Install]
WantedBy=multi-user.target
EOM

echo "Starting & enabling prometheus service"
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE2"

# Optional: register a dashboard/alert set for this tenant with an
# observability portal, if one is configured. Skipped entirely when
# PORTAL_API_BASE_URL isn't set, so the agent install itself never depends
# on a SaaS backend. PORTAL_DASHBOARD_TEMPLATE_ID accepts a comma-separated
# list if you need more than one template applied (the source script
# applied two for Redis).
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
    bash server-info.sh "$tenant" redis
  done
fi
