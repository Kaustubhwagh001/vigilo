#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Promtail — generic Linux host (systemd)
# Purpose: install the Promtail binary as a systemd service on a generic
#          Linux host and configure it to tail one log path, shipping lines
#          to a Loki-compatible push endpoint under a given tenant.
# Requires env: LOKI_PUSH_URL, TENANT_ID
# Optional env: PROMTAIL_VERSION, ARTIFACT_BASE_URL, PORTAL_API_BASE_URL
# Usage: sudo ./promtail-systemd-install.sh <logs-path> <app> <svc> <tenant-id>
#   e.g. sudo ./promtail-systemd-install.sh '/var/log/nginx/*.log' storage nginx my-tenant
#
# Note: this migrates `promtail-agent.sh` from the source onboarding
# scripts, which installs the Promtail *binary* via systemd for a single
# log path on a VM/bare-metal host. It is a different deployment target
# from `promtail-k8s-daemonset.sh` (migrated from `promtail_script.sh`),
# which renders a Kubernetes DaemonSet that tails container logs across a
# cluster — the two were not duplicates of each other, so both are kept.
# See this folder's README for the full comparison.
#
# The source script prompted interactively for logs-path/app/svc via
# `read -p`. That's replaced here with positional args for scriptability,
# consistent with the positional-arg convention used elsewhere in this repo
# (e.g. otel-collector/agent/otel-collector-deploy.sh).
# ------------------------------------------------------------
set -euo pipefail

LOGS_PATH="${1:?set logs-path, e.g. /var/log/nginx/*.log}"
APP="${2:?set app/organization name, e.g. storage}"
SVC="${3:?set service name, e.g. nginx}"
TENANT_ID="${4:?set tenant-id}"

: "${LOKI_PUSH_URL:?set LOKI_PUSH_URL, e.g. https://loki.example.internal/loki/api/v1/push}"

# Pin the version explicitly rather than always pulling ":latest" — makes
# installs reproducible and lets an operator roll back by changing one env
# var. See https://github.com/grafana/loki/releases for available tags;
# point ARTIFACT_BASE_URL at your own mirror if you vendor the binary.
PROMTAIL_VERSION="${PROMTAIL_VERSION:-2.9.9}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}}"

# Labels and selectors (derived from the args above)
JOBNAME="job_name: ${SVC}"
LABEL_ORGANIZATION="app: ${APP}"
LABEL_SERVICE="svc: ${SVC}"
LABEL_HOSTNAME="host: $(hostname)"

CONFIG_DIR="/etc/promtail-${APP}-${SVC}"
CONFIG_FILE="${CONFIG_DIR}/config-promtail.yml"
SERVICE_FILE="/etc/systemd/system/promtail-${SVC}.service"
BINARY_FILE="promtail-linux-amd64"
BINARY_PATH="/usr/local/bin"

echo "Creating directory & downloading package"

sudo mkdir -p "${CONFIG_DIR}"
cd /tmp

curl -fsSL --noproxy '*' -O -L "${ARTIFACT_BASE_URL}/${BINARY_FILE}.zip"
unzip -o "/tmp/${BINARY_FILE}.zip" -d "${BINARY_PATH}/"
sudo chmod a+x "${BINARY_PATH}/${BINARY_FILE}"

echo "Adding Promtail config for tenant ${TENANT_ID}"

sudo tee "${CONFIG_FILE}" >/dev/null <<EOM
server:
  disable: true

positions:
  filename: /tmp/positions.yaml

clients:
  - url: ${LOKI_PUSH_URL}
    tenant_id: ${TENANT_ID}
scrape_configs:
  - ${JOBNAME}
    static_configs:
      - targets:
          - localhost
        labels:
          ${LABEL_ORGANIZATION}
          ${LABEL_SERVICE}
          ${LABEL_HOSTNAME}
          __path__: ${LOGS_PATH}
    pipeline_stages:
    # Example only — add your own regex/labels stages here to extract
    # structured fields (status code, upstream address, log level, ...)
    # out of unstructured log lines before they're shipped to Loki.
    - match:
        selector: '{svc="${SVC}"}'
        stages:
        - labels:
            Host:
EOM

echo "Adding Promtail service file"

sudo tee "${SERVICE_FILE}" >/dev/null <<EOM
[Unit]
Description=Promtail service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${BINARY_PATH}/${BINARY_FILE} -config.file ${CONFIG_FILE}

[Install]
WantedBy=multi-user.target
EOM

echo "Starting & enabling Promtail service (promtail-${SVC})"

sudo systemctl daemon-reload
sudo systemctl enable --now "promtail-${SVC}.service"
sudo systemctl status "promtail-${SVC}.service" --no-pager || true

# Optional: register a Loki dashboard for this tenant with an observability
# portal, if one is configured. Skipped entirely when PORTAL_API_BASE_URL
# isn't set, so the agent install itself never depends on a SaaS backend.
if [[ -n "${PORTAL_API_BASE_URL:-}" ]]; then
  curl -s --noproxy "*" --location --request GET "${PORTAL_API_BASE_URL}/api/dashboards/createdashboard2/loki" \
    --header 'Content-Type: application/json' \
    -d "{\"tenantID\": \"${TENANT_ID}\"}"
fi
