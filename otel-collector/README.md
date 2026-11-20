# otel-collector

OpenTelemetry Collector deployment patterns.

## What's here

| Folder | Purpose |
|---|---|
| [`agent/`](agent/README.md) | Per-application collector deployed alongside each service (Deployment for dev/staging, DaemonSet for prod), plus a legacy Elastic APM bridge for consumers not yet reading OTLP directly |
| [`host/`](host/README.md) | Host-level collector — installs the official `otelcol-contrib` package directly on Linux/Windows machines (not Kubernetes), collecting `hostmetrics` + local logs/Event Log/journald and exporting to a central OTLP backend |

A central `gateway/` tier (tail sampling, routing, fan-out to Mimir/Loki/Tempo)
is not included yet — see the roadmap in the root README.

## Why per-app collectors

Running one collector per application (rather than only a shared cluster-wide
gateway) keeps each team's export queue, retry policy, and backend bridge
isolated — a slow or misconfigured backend for one app can't back-pressure
another app's telemetry pipeline.

## Why also a host-level collector

Per-app collectors only see what the app itself exports over OTLP. They
can't see host-level signals — CPU/memory/disk pressure on the node, the
process table, syslog/journald, Windows Event Log — that often explain
*why* an app's telemetry degraded. `host/` fills that gap with a
package-level install scoped to the machine, independent of whatever
applications happen to be running on it.
