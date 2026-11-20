# grafana-agent

Deployment and onboarding scripts for **Grafana Agent (classic, static
mode)** — the legacy Grafana Agent, not Grafana Alloy.

## Why this isn't under `alloy/`

Everything here uses Grafana Agent's static-mode YAML config, a different
configuration language from Alloy's River syntax. Upstream Grafana Agent is
archived in favor of Alloy, and migrating these configs to River would be a
real rewrite with real risk of behavioral drift — not a mechanical rename.
Since every script here was copied from a real, working production
deployment, it's kept honestly labeled as Grafana Agent rather than
silently relabeled "Alloy." An Alloy migration is a reasonable future
addition; see the root README's roadmap.

## What's here

| Folder | Purpose |
|---|---|
| [`linux/`](linux/README.md) | Host- and infra-component-level agent install: generic Linux hosts, CRI-O, Docker, etcd, and a cluster-wide Kubernetes metrics Deployment |
| [`integrations/`](integrations/README.md) | Per-datastore scrape-target onboarding: Kafka, Kafka Connect, MongoDB, MySQL, Oracle, PostgreSQL, Redis, ScyllaDB, Elasticsearch |

## Shared conventions across both folders

- Every script is idempotent — safe to re-run to add a new tenant without
  duplicating existing config.
- Every secret and internal endpoint is an env var, never hardcoded — see
  the root [`.env.example`](../.env.example).
- Binary installs are version-pinned (`GRAFANA_AGENT_VERSION` /
  `ARTIFACT_BASE_URL`), not `:latest`, and every pinned version's release
  asset name was independently verified against the GitHub Releases API
  before being committed here.

> ⚠️ **Don't just bump `GRAFANA_AGENT_VERSION` across every script.**
> Grafana Agent renamed its release asset from `agent-linux-amd64.zip` to
> `grafana-agent-linux-amd64.zip` around v0.31. `integrations/mysql.sh`,
> `integrations/postgresql.sh`, and `integrations/scylladb.sh` are
> deliberately pinned to the older `v0.26.1` tag *and* the old asset name
> to match what's actually verified working — overriding
> `GRAFANA_AGENT_VERSION` on just those three without also updating
> `ARTIFACT_NAME` inside the script will make the download 404. Grafana
> Agent (classic) is archived upstream in favor of Alloy as of late 2025,
> with no binaries published past `v0.43.4` — if you're onboarding a new
> host today, strongly consider migrating to Alloy instead of bumping these
> pins further.
- An optional internal "observability portal" integration (auto-creating
  dashboards/alerts, fleet registration) is preserved behind
  `PORTAL_API_BASE_URL` / `PORTAL_REGISTER_SCRIPT_URL` — unset by default,
  so none of these scripts depend on a SaaS backend to run.
