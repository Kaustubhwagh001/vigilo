#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — ScyllaDB
# Purpose: install the Grafana Agent static binary, scrape node_exporter +
#          process_exporter (generic host metrics) plus a static target
#          for an externally-run scylla_exporter, remote_writing metrics
#          to a Mimir/Prometheus-remote_write-compatible backend.
# Requires env: METRICS_REMOTE_WRITE_URL, TENANT_ID, SCYLLA_EXPORTER_TARGET
# Optional env: GRAFANA_AGENT_VERSION, ARTIFACT_BASE_URL
# Usage: sudo ./scylladb.sh
#
# Note: this migrates `scylla_script.sh` from the source onboarding
# scripts. The source was a bare Grafana Agent config snippet (no install
# logic at all) — this wraps it in the same binary-install/systemd
# scaffolding used by the rest of this folder (see
# grafana-agent/linux/grafana-agent-host-install.sh), since ScyllaDB has
# no built-in Grafana Agent integration and the source always paired its
# host metrics config with a hand-run scylla_exporter scrape target.
#
# Unlike the other scripts here, the source config used one TENANT_ID
# value, not a positional per-tenant loop — reproduced that way below.
# ------------------------------------------------------------
set -euo pipefail

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${TENANT_ID:?set TENANT_ID, e.g. your Mimir/Loki org ID}"
: "${SCYLLA_EXPORTER_TARGET:?set SCYLLA_EXPORTER_TARGET, e.g. 10.0.0.17:9180 (host:port of a running scylla_exporter / scylla-manager-agent)}"

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

SERVICE="grafana-agent-scylladb.service"

echo "Tenant ID: ${TENANT_ID}"

curl -fsSL -O --noproxy "*" "${ARTIFACT_BASE_URL}/${ARTIFACT_NAME}.zip"
unzip -o "${ARTIFACT_NAME}.zip"
chmod a+x "${ARTIFACT_NAME}"
sudo mv "${ARTIFACT_NAME}" /usr/local/bin/

sudo tee /etc/grafana-agent-scylladb-config.yaml >/dev/null <<EOF
prometheus:
  global:
    scrape_interval: 60s
  wal_directory: /tmp/grafana-agent-scylladb-wal
  configs:
    - name: integrations
      remote_write:
        - url: ${METRICS_REMOTE_WRITE_URL}
          headers:
            X-Scope-OrgID: ${TENANT_ID}
      scrape_configs:
        - job_name: 'scylla-exporter'
          metrics_path: /metrics
          static_configs:
            - targets:
              - ${SCYLLA_EXPORTER_TARGET}
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

sudo tee /etc/systemd/system/grafana-agent-scylladb.service >/dev/null <<EOM
[Unit]
Description=Grafana Agent (ScyllaDB metrics)
Wants=network-online.target
After=network-online.target

[Service]
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/${ARTIFACT_NAME} \\
    --server.grpc-listen-address 127.0.0.1 \\
    --server.grpc-listen-port 9098 \\
    --config.file /etc/grafana-agent-scylladb-config.yaml

Restart=always

[Install]
WantedBy=multi-user.target
EOM

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"
sudo systemctl status "$SERVICE" --no-pager || true
