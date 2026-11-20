# vigilo

[![Lint](https://github.com/Kaustubhwagh001/vigilo/actions/workflows/lint.yml/badge.svg)](https://github.com/Kaustubhwagh001/vigilo/actions/workflows/lint.yml)

Fleet-onboarding scripts for observability — wire OpenTelemetry Collector,
Grafana Agent, and Promtail onto your hosts, containers, and datastores, and
ship telemetry into **a Mimir/Loki/Elasticsearch stack you already run**.

## What vigilo is (and isn't) today

This is the **agent/client side**: the install scripts that get metrics,
logs, and traces *out* of your systems. It is not yet a self-contained
observability stack you can `docker compose up` and watch dashboards fill
in — there's no bundled Mimir/Loki/Tempo server, no Grafana dashboards, and
no alerting rules here yet. Point these scripts at infrastructure you
already operate. See the Roadmap below for what's planned.

## What's inside

| Folder | What it is |
|---|---|
| [`otel-collector/`](otel-collector/README.md) | OpenTelemetry Collector: per-app (`agent/`, + legacy Elastic APM bridge) and host-level (`host/`, Linux+Windows package install, 8 datastore receivers) |
| [`grafana-agent/`](grafana-agent/README.md) | Grafana Agent (classic) host/infra and datastore-integration onboarding (10 integrations) |
| [`alloy/`](alloy/README.md) | Grafana Alloy (River config) — the Grafana Agent successor; currently Windows host + custom-log onboarding |
| [`loki/`](loki/README.md) | Promtail log-shipping agent, host and Kubernetes |
| [`docs/`](docs/nodejs-instrumentation.md) | App-side instrumentation guides |

Every script reads its secrets and endpoints from environment variables —
copy [`.env.example`](.env.example) to `.env` and fill in real values before
running anything.

## Known limitation: Grafana Agent (classic) is end-of-life

`grafana-agent/` uses the classic, static-mode Grafana Agent — not Alloy,
its successor — because that's what the source deployments actually ran.
Upstream Grafana Agent is archived with no binaries published past
`v0.43.4`. A few scripts pin an older version/asset-name pairing
deliberately (see [`grafana-agent/README.md`](grafana-agent/README.md) for
which ones and why) — don't casually bump `GRAFANA_AGENT_VERSION` across
every script at once. [`alloy/`](alloy/README.md) is where the migration
path lands: it's a separate folder (different config language — River, not
YAML) with the first Alloy content now in place for Windows hosts. Linux
hosts and the datastore integrations under `grafana-agent/integrations/`
are not yet migrated to Alloy.

## Roadmap

- [ ] Mimir / Loki / Tempo server-side config (storage, retention, compactor)
- [ ] Grafana dashboards + provisioning
- [ ] Alerting rules (Prometheus/Mimir + SLO burn-rate)
- [ ] `examples/docker-compose/` — a runnable local demo of the full stack
- [ ] Grafana Agent → Alloy migration
- [ ] Architecture diagram
