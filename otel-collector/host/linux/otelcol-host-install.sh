#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — OTel Collector host agent (Linux)
# Purpose: install the official otelcol-contrib .deb package on a Linux
#          host, render a hostmetrics + local-log config from env vars,
#          and run it as the package's systemd service, exporting OTLP
#          to a central backend. This is the host-level tier — a
#          different deployment from otel-collector/agent/, which is a
#          per-application collector run as a Kubernetes
#          Deployment/DaemonSet.
# Requires env: OTLP_BACKEND_ENDPOINT
# Optional env: COLLECTOR_VERSION, TENANT_ID, DEPLOYMENT_ENVIRONMENT,
#               SERVICE_NAME, RESOURCE_DETECTORS, PROCESS_NAME_FILTER,
#               SYSLOG_PATH, ENABLE_JOURNALD, JOURNALD_UNITS,
#               EXTRA_PROMETHEUS_TARGETS, OTELCOL_CONF_DIR,
#               GOOGLE_APPLICATION_CREDENTIALS
# Usage: sudo ./otelcol-host-install.sh
# ------------------------------------------------------------
set -euo pipefail

: "${OTLP_BACKEND_ENDPOINT:?set OTLP_BACKEND_ENDPOINT, e.g. otel-gateway.example.internal:4317}"

# Pin the collector version explicitly rather than always pulling
# "latest" — makes installs reproducible and lets an operator roll back
# by changing one env var. v0.138.0 is pinned as the default below: it's
# the version this install flow was last verified against (asset names
# confirmed via the GitHub releases API); v0.144.0 was the newest release
# at time of writing if you want to track closer to upstream HEAD instead.
# See https://github.com/open-telemetry/opentelemetry-collector-releases/releases
COLLECTOR_VERSION="${COLLECTOR_VERSION:-0.138.0}"

# tenant.id / deployment.environment / service.name resource attributes —
# TENANT_ID is shared with grafana-agent/linux's X-Scope-OrgID convention
# (see root .env.example) since both describe "which tenant does this
# host's telemetry belong to".
TENANT_ID="${TENANT_ID:-default}"
DEPLOYMENT_ENVIRONMENT="${DEPLOYMENT_ENVIRONMENT:-prod}"
SERVICE_NAME="${SERVICE_NAME:-host}"

# resourcedetection detectors — "env,system" always; append cloud
# detectors (gcp, ec2, azure, ecs, docker) per the role recipes in
# otel-collector/host/README.md.
RESOURCE_DETECTORS="${RESOURCE_DETECTORS:-env,system}"

# Comma-separated regexes for the hostmetrics `process` scraper's include
# list — keeps per-process metrics to processes you actually care about
# instead of every PID on the box. Role recipes in the README give good
# values for Kafka/Scylla, CRI-O, etc. hosts.
PROCESS_NAME_FILTER="${PROCESS_NAME_FILTER:-otelcol.*,systemd.*,node.*}"

# Local syslog path fed to the filelog receiver. Debian/Ubuntu ships
# /var/log/syslog; RHEL-family hosts should set SYSLOG_PATH=/var/log/messages.
SYSLOG_PATH="${SYSLOG_PATH:-/var/log/syslog}"

# journald is opt-in: only some roles (Kafka+Scylla, CRI-O hosts) need
# specific unit logs pulled via journald rather than syslog.
ENABLE_JOURNALD="${ENABLE_JOURNALD:-false}"
JOURNALD_UNITS="${JOURNALD_UNITS:-ssh}"

# Optional extra static Prometheus scrape targets (comma-separated
# host:port), for a local exporter the host also runs (e.g. a CRI-O
# exporter, a Kafka/Zookeeper exporter, a blackbox_exporter probe). Left
# unset, only the collector's own :8888 self-scrape runs.
EXTRA_PROMETHEUS_TARGETS="${EXTRA_PROMETHEUS_TARGETS:-}"

# Fragment directory other otel-collector/host/integrations/*.sh scripts
# write datastore-specific receiver/processor snippets into. Those
# fragments are NOT auto-merged (otelcol-contrib doesn't reliably merge
# pipeline receiver lists across multiple --config files) — they're
# meant to be spliced into this config by hand; see each fragment's own
# wiring-instructions comment.
OTELCOL_CONF_DIR="${OTELCOL_CONF_DIR:-/etc/otelcol-contrib/conf.d}"

ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
PACKAGE="otelcol-contrib_${COLLECTOR_VERSION}_linux_${ARCH}.deb"
DOWNLOAD_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${COLLECTOR_VERSION}/${PACKAGE}"

echo "Downloading ${DOWNLOAD_URL}"
curl -fsSL -O "${DOWNLOAD_URL}"
dpkg -i "${PACKAGE}"
rm -f "${PACKAGE}"

# --- Build YAML fragments from the comma-separated env vars above ---

process_names_yaml=""
IFS=',' read -ra _proc_names <<< "${PROCESS_NAME_FILTER}"
for n in "${_proc_names[@]}"; do
  process_names_yaml+="            - \"${n}\""$'\n'
done

journald_block=""
logs_receivers="filelog"
if [[ "${ENABLE_JOURNALD}" == "true" ]]; then
  journald_units_yaml=""
  IFS=',' read -ra _units <<< "${JOURNALD_UNITS}"
  for u in "${_units[@]}"; do
    journald_units_yaml+="      - ${u}"$'\n'
  done
  journald_block=$(cat <<EOF

  journald:
    directory: /run/log/journal
    units:
${journald_units_yaml}    priority: info
EOF
)
  logs_receivers="journald, filelog"
fi

extra_scrape_job=""
if [[ -n "${EXTRA_PROMETHEUS_TARGETS}" ]]; then
  extra_targets_yaml=""
  IFS=',' read -ra _targets <<< "${EXTRA_PROMETHEUS_TARGETS}"
  for t in "${_targets[@]}"; do
    extra_targets_yaml+="                - '${t}'"$'\n'
  done
  extra_scrape_job=$(cat <<EOF

        - job_name: 'extra-local-exporters'
          static_configs:
            - targets:
${extra_targets_yaml}
EOF
)
fi

mkdir -p /etc/otelcol-contrib
mkdir -p "${OTELCOL_CONF_DIR}"

cat > /etc/otelcol-contrib/config.yaml <<EOF
# Rendered by vigilo otel-collector/host/linux/otelcol-host-install.sh.
# Re-run the installer with updated env vars rather than hand-editing
# receivers/processors below — manual edits are overwritten on re-install.
# Datastore/app-specific receiver fragments live under ${OTELCOL_CONF_DIR}/
# (see otel-collector/host/integrations/*.sh) and must be merged in by hand.

receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
        metrics:
          system.cpu.utilization:
            enabled: true
          system.cpu.logical.count:
            enabled: true
          system.cpu.physical.count:
            enabled: true
          system.cpu.frequency:
            enabled: true
      disk: {}
      load: {}
      filesystem: {}
      memory:
        metrics:
          system.memory.limit:
            enabled: true
      network: {}
      paging: {}
      process:
        mute_process_name_error: true
        mute_process_exe_error: true
        mute_process_io_error: true
        include:
          match_type: regexp
          names:
${process_names_yaml}      processes: {}
      system: {}

  # Self-scrape of the collector's own metrics, plus any EXTRA_PROMETHEUS_TARGETS.
  prometheus:
    config:
      scrape_configs:
        - job_name: 'otel-collector-binary'
          scrape_interval: 30s
          static_configs:
            - targets: ['localhost:8888']${extra_scrape_job}

  filelog:
    start_at: beginning
    include_file_name: false
    include_file_path: true
    include:
      - ${SYSLOG_PATH}
${journald_block}
processors:
  batch:
    send_batch_size: 1000
    timeout: 10s

  # Auto-detect resource attributes from environment & OS (and cloud
  # metadata APIs, if RESOURCE_DETECTORS adds gcp/ec2/azure/ecs/docker).
  resourcedetection:
    detectors: [${RESOURCE_DETECTORS}]
    timeout: 2s
    system:
      hostname_sources: [os]
      resource_attributes:
        os.description:
          enabled: true
        os.type:
          enabled: true
        host.arch:
          enabled: true
        host.id:
          enabled: true
        host.ip:
          enabled: true
        host.cpu.family:
          enabled: true
        host.cpu.model.id:
          enabled: true
        host.cpu.model.name:
          enabled: true
        host.cpu.vendor.id:
          enabled: true
        host.cpu.cache.l2.size:
          enabled: true

  resource/env:
    attributes:
      - key: deployment.environment
        value: "${DEPLOYMENT_ENVIRONMENT}"
        action: upsert
      - key: tenant.id
        value: "${TENANT_ID}"
        action: upsert
      - key: service.name
        value: "${SERVICE_NAME}"
        action: upsert

extensions:
  health_check: {}
  zpages: {}

exporters:
  otlp:
    endpoint: "${OTLP_BACKEND_ENDPOINT}"
    tls:
      insecure: true

service:
  telemetry:
    metrics:
      address: 0.0.0.0:8888

  extensions: [health_check, zpages]

  pipelines:
    metrics/internal:
      receivers: [prometheus, hostmetrics]
      processors: [resourcedetection, resource/env, batch]
      exporters: [otlp]

    logs:
      receivers: [${logs_receivers}]
      processors: [resourcedetection, resource/env, batch]
      exporters: [otlp]
EOF

# Optional: GCP resource detection (resourcedetection's "gcp" detector)
# only needs credentials when running off-GCE (rare — on a GCE VM the
# metadata server covers it for free). Append to the package's
# EnvironmentFile rather than editing the systemd unit directly, so a
# package upgrade doesn't clobber it. Not required unless you've actually
# added "gcp" to RESOURCE_DETECTORS and need creds off-GCE.
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  if ! grep -q '^GOOGLE_APPLICATION_CREDENTIALS=' /etc/otelcol-contrib/otelcol-contrib.conf 2>/dev/null; then
    echo "GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS}" >> /etc/otelcol-contrib/otelcol-contrib.conf
  fi
fi

systemctl daemon-reload
systemctl enable otelcol-contrib
systemctl restart otelcol-contrib

echo "otelcol-contrib ${COLLECTOR_VERSION} installed and running."
echo "Check status with: systemctl status otelcol-contrib"
echo "Tail logs with:     journalctl -u otelcol-contrib -f"
