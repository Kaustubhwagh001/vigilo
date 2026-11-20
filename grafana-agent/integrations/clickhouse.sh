#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — ClickHouse
# Purpose: install the Grafana Agent static binary, scrape node_exporter +
#          process_exporter (generic host metrics) plus a static target for
#          ClickHouse's own built-in Prometheus metrics endpoint,
#          remote_writing metrics to a Mimir/Prometheus-remote_write-
#          compatible backend.
# Requires env: METRICS_REMOTE_WRITE_URL, TENANT_ID, CLICKHOUSE_EXPORTER_TARGET
# Optional env: GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL
# Usage: sudo ./clickhouse.sh
#
# Note: this migrates `grafana-agentv22clickhouseconf.yml` from the source
# onboarding material. ClickHouse has no dedicated Grafana Agent
# integration — like scylladb.sh, this wraps the config in the same
# binary-install/systemd scaffolding used by the rest of this folder (see
# grafana-agent/linux/grafana-agent-host-install.sh), scraping ClickHouse's
# *own* Prometheus endpoint as a static target rather than a separate
# exporter process.
#
# Unlike most other scripts here, the source config used one TENANT_ID
# value, not a positional per-tenant loop — reproduced that way below
# (matching scylladb.sh's precedent).
#
# This script only installs Grafana Agent on the host that will scrape
# ClickHouse (the "collector" side). It does NOT touch the ClickHouse
# server itself — ClickHouse must have its Prometheus endpoint enabled
# separately, on the ClickHouse host, before this script's scrape target
# will return anything. That's a one-time, ClickHouse-side config change
# (from the source `onbardclickhosuereadme.md`), reproduced here as
# reference only — apply it by hand on the ClickHouse host:
#
#   cat <<'CLICKHOUSE_PROMETHEUS_XML' > /etc/clickhouse-server/config.d/prometheus.xml
#   <clickhouse>
#       <prometheus>
#           <endpoint>/metrics</endpoint>
#           <port>9363</port>
#
#           <metrics>true</metrics>
#           <events>true</events>
#           <asynchronous_metrics>true</asynchronous_metrics>
#       </prometheus>
#   </clickhouse>
#   CLICKHOUSE_PROMETHEUS_XML
#
#   systemctl restart clickhouse-server.service
#   systemctl status clickhouse-server.service
#
#   # Sanity-check the endpoint locally on the ClickHouse host:
#   curl http://localhost:9363/metrics
#
# (The source readme also `wget`'d the Grafana Agent binary from an
# internal mirror at that point, to install Grafana Agent directly on the
# ClickHouse host itself. This script instead follows this folder's
# standard convention — GRAFANA_AGENT_VERSION / ARTIFACT_BASE_URL pulling
# from the real public grafana/agent GitHub releases, verified against the
# GitHub releases API — and assumes Grafana Agent scrapes ClickHouse
# remotely via CLICKHOUSE_EXPORTER_TARGET, which also works if run
# directly on the ClickHouse host with CLICKHOUSE_EXPORTER_TARGET=localhost:9363.)
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${TENANT_ID:?set TENANT_ID, e.g. your Mimir/Loki org ID}"
: "${CLICKHOUSE_EXPORTER_TARGET:?set CLICKHOUSE_EXPORTER_TARGET, e.g. clickhouse.example.internal:9363 (host:port of a ClickHouse node with its Prometheus endpoint enabled)}"

# Pin the agent version explicitly rather than always pulling ":latest" —
# makes installs reproducible and lets an operator roll back by changing
# one env var. Grafana Agent (classic/static mode) is archived upstream in
# favor of Grafana Alloy; check https://github.com/grafana/agent/releases
# for the newest release still published there, or point ARTIFACT_BASE_URL
# at your own internal mirror if you vendor the binary.
GRAFANA_AGENT_VERSION="${GRAFANA_AGENT_VERSION:-v0.44.2}"
ARTIFACT_BASE_URL="${ARTIFACT_BASE_URL:-https://github.com/grafana/agent/releases/download/${GRAFANA_AGENT_VERSION}}"
# Verified against the GitHub releases API for this tag: v0.44.2 postdates
# the grafana-agent-* asset rename (that happened around v0.31), so the
# asset is named `grafana-agent-linux-amd64.zip`.
ARTIFACT_NAME="grafana-agent-linux-amd64"

SERVICE="grafana-agent-clickhouse.service"

echo "Tenant ID: ${TENANT_ID}"

id -u grafana-agent &>/dev/null || sudo useradd --no-create-home --shell /bin/false grafana-agent

curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/${ARTIFACT_NAME}.zip"
unzip -o "${ARTIFACT_NAME}.zip"
chmod a+x "${ARTIFACT_NAME}"
sudo mv "${ARTIFACT_NAME}" /usr/local/bin/

sudo tee /etc/grafana-agent-clickhouse-config.yaml >/dev/null <<EOF
prometheus:
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-clickhouse-wal
  configs:
    - name: integrations
      remote_write:
        - url: ${METRICS_REMOTE_WRITE_URL}
          headers:
            X-Scope-OrgID: ${TENANT_ID}
      scrape_configs:
        - job_name: 'clickhouse_exporter'
          metrics_path: /metrics
          static_configs:
            - targets:
              - ${CLICKHOUSE_EXPORTER_TARGET}
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
    - url: ${METRICS_REMOTE_WRITE_URL}
      headers:
        X-Scope-OrgID: ${TENANT_ID}
EOF

sudo tee /etc/systemd/system/grafana-agent-clickhouse.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (ClickHouse metrics)
Wants=network-online.target
After=network-online.target

[Service]
User=grafana-agent
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/${ARTIFACT_NAME} \\
    --server.grpc-listen-address 127.0.0.1 \\
    --server.grpc-listen-port 9098 \\
    --config.file /etc/grafana-agent-clickhouse-config.yaml

Restart=always

[Install]
WantedBy=multi-user.target
EOM

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"
sudo systemctl status "$SERVICE" --no-pager || true
