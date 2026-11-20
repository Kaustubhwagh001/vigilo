#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — Kafka brokers
# Purpose: install the Grafana Agent static binary and configure it to
#          scrape per-broker kafka_exporter / ZooKeeper exporter targets,
#          plus the agent's built-in kafka_exporter integration, remote_writing
#          metrics to a Mimir/Prometheus-remote_write-compatible backend.
# Requires env: METRICS_REMOTE_WRITE_URL, TENANT_ID, KAFKA_EXPORTER_TARGETS,
#               KAFKA_BROKER_URIS
# Optional env: GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL,
#               ZOOKEEPER_EXPORTER_TARGETS, KAFKA_CLUSTER_NAME,
#               PORTAL_API_BASE_URL, PORTAL_DASHBOARD_TEMPLATE_ID,
#               PORTAL_ALERT_TECHNOLOGY_ID, PORTAL_REGISTER_SCRIPT_URL
# Usage: sudo ./kafka.sh
#
# Note: this migrates `kafka-script.sh` from the source onboarding scripts.
# Mirrors the structure of grafana-agent/linux/grafana-agent-crio-exporter.sh
# and grafana-agent-docker-exporter.sh — see those for the shared env var
# conventions this repo uses for per-exporter Grafana Agent installs.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${TENANT_ID:?set TENANT_ID, e.g. your Mimir/Loki org ID}"
: "${KAFKA_EXPORTER_TARGETS:?set KAFKA_EXPORTER_TARGETS, comma-separated host:port list of per-broker kafka_exporter instances, e.g. kafka-broker-1.example.com:7076,kafka-broker-2.example.com:7076}"
: "${KAFKA_BROKER_URIS:?set KAFKA_BROKER_URIS, comma-separated kafka broker host:port list for the built-in kafka_exporter integration, e.g. kafka-broker-1.example.com:9092,kafka-broker-2.example.com:9092}"

KAFKA_CLUSTER_NAME="${KAFKA_CLUSTER_NAME:-kafka-cluster}"

# Pin the agent version explicitly rather than always pulling ":latest" —
# makes installs reproducible and lets an operator roll back by changing
# one env var. Grafana Agent (classic/static mode) is archived upstream in
# favor of Grafana Alloy; check https://github.com/grafana/agent/releases
# for the newest release still published there, or point ARTIFACT_BASE_URL
# at your own internal mirror if you vendor the binary.
GRAFANA_AGENT_VERSION="${GRAFANA_AGENT_VERSION:-v0.40.3}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/grafana/agent/releases/download/${GRAFANA_AGENT_VERSION}}"
# NOTE: the real release asset is `grafana-agent-linux-amd64.zip` (verified
# against the GitHub releases API for this tag) — unlike the sibling scripts
# in grafana-agent/linux/, which reference `agent-linux-amd64.zip`. That
# looks like a copy-paste slip over there (flagged in the sanitization
# report for this folder); don't "fix" this file to match them.
ARTIFACT_NAME="grafana-agent-linux-amd64"

SERVICE="kafka_exporter.service"

echo "Tenant ID: ${TENANT_ID}"

# Renders a comma-separated list as an indented YAML sequence, one
# "- item" per line, so operators can pass target lists as plain env vars
# instead of hand-editing YAML.
csv_to_yaml_list() {
  local csv="$1" indent="$2" item
  local IFS=','
  for item in $csv; do
    printf '%s- %s\n' "$indent" "$item"
  done
}

curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/${ARTIFACT_NAME}.zip"
unzip -o "${ARTIFACT_NAME}.zip"
chmod a+x "${ARTIFACT_NAME}"
sudo mv "${ARTIFACT_NAME}" /usr/local/bin/

KAFKA_TARGETS_YAML="$(csv_to_yaml_list "${KAFKA_EXPORTER_TARGETS}" "                ")"
KAFKA_URIS_YAML="$(csv_to_yaml_list "${KAFKA_BROKER_URIS}" "      ")"

# ZooKeeper exporter targets are optional — some Kafka deployments (e.g.
# KRaft mode) don't run ZooKeeper at all.
ZOOKEEPER_JOB_YAML=""
if [[ -n "${ZOOKEEPER_EXPORTER_TARGETS:-}" ]]; then
  ZOOKEEPER_TARGETS_YAML="$(csv_to_yaml_list "${ZOOKEEPER_EXPORTER_TARGETS}" "                ")"
  ZOOKEEPER_JOB_YAML="$(cat <<EOF
        - job_name: integrations/kafka-zookeeper
          static_configs:
            - targets:
${ZOOKEEPER_TARGETS_YAML}
EOF
)"
fi

if [[ ! -e /etc/grafana-agent-kafka-config.yaml ]]; then
  CONFIG="$(cat <<EOF
prometheus:
  configs:
    - name: integrations
      remote_write:
        - url: ${METRICS_REMOTE_WRITE_URL}
          headers:
            X-Scope-OrgID: ${TENANT_ID}
      scrape_configs:
        - job_name: integrations/kafka
          static_configs:
            - targets:
${KAFKA_TARGETS_YAML}
${ZOOKEEPER_JOB_YAML}
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-kafka-wal
server:
  http_listen_port: 12340
  http_listen_address: 127.0.0.1
  log_level: error

integrations:
  kafka_exporter:
    enabled: true
    kafka_cluster_name: ${KAFKA_CLUSTER_NAME}
    kafka_uris:
${KAFKA_URIS_YAML}
  prometheus_remote_write:
    - url: ${METRICS_REMOTE_WRITE_URL}
      headers:
        X-Scope-OrgID: ${TENANT_ID}
EOF
)"
  printf '%s\n' "${CONFIG}" | sudo tee /etc/grafana-agent-kafka-config.yaml >/dev/null
fi

sudo tee /etc/systemd/system/kafka_exporter.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (Kafka metrics)
Wants=network-online.target
After=network-online.target

[Service]
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/${ARTIFACT_NAME} \\
    --server.grpc-listen-address 127.0.0.1 \\
    --server.grpc-listen-port 9095 \\
    --config.file /etc/grafana-agent-kafka-config.yaml

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
  response1=$(curl -s --location --request POST "${PORTAL_API_BASE_URL}/api/dashboards/v1.1/create" \
    --header "tenant-id: ${TENANT_ID}" \
    --header 'Content-Type: application/json' \
    --data-raw "{\"template_ids\": [\"${PORTAL_DASHBOARD_TEMPLATE_ID}\"]}")
  echo "Dashboard API response: ${response1}"

  if [[ -n "${PORTAL_ALERT_TECHNOLOGY_ID:-}" ]]; then
    response2=$(curl -s --location --request POST "${PORTAL_API_BASE_URL}/api/alerts/v1.1/set" \
      --header "tenant-id: ${TENANT_ID}" \
      --header 'Content-Type: application/json' \
      --data-raw "{\"technology_id\": \"${PORTAL_ALERT_TECHNOLOGY_ID}\"}")
    echo "Alerts API response: ${response2}"
  fi
fi

# Optional: hand off to a fleet-registration script hosted on your own
# mirror (e.g. to record this host against inventory/CMDB). No public
# equivalent exists for this step, so it's opt-in via env var.
if [[ -n "${PORTAL_REGISTER_SCRIPT_URL:-}" ]]; then
  curl -fsSL --noproxy "*" -L -O "${PORTAL_REGISTER_SCRIPT_URL}"
  chmod a+x server-info.sh
  bash server-info.sh "${TENANT_ID}" kafka
fi
