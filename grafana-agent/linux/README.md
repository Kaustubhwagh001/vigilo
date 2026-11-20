# grafana-agent / linux

Installs and configures **Grafana Agent (classic, static mode)** — not
Grafana Alloy — on Linux hosts and in Kubernetes, scraping host- and
infra-component-level metrics and `remote_write`-ing them to a
Mimir/Prometheus-remote_write-compatible backend. Grafana Agent's classic
static-mode YAML config is a different config language from Alloy's River,
so these scripts deliberately stay out of an `alloy/` directory.

## Files

| File | What it does |
|---|---|
| `grafana-agent-host-install.sh` | Installs the agent binary as a systemd (or SysV init, as a fallback) service on a generic Linux host. Scrapes the bundled `node_exporter` + `process_exporter` integrations and `remote_write`s metrics per tenant, one `X-Scope-OrgID` header per tenant ID passed on the command line. |
| `grafana-agent-crio-exporter.sh` | Same install, configured to scrape a CRI-O exporter on `:9090` on the local host. |
| `grafana-agent-docker-exporter.sh` | Same install, configured to scrape the Docker engine's metrics endpoint on `:8080` on the local host. |
| `grafana-agent-etcd-exporter.sh` | Same install, configured to scrape a Kubernetes control-plane etcd instance over mTLS on `:2379`, reusing kubeadm's etcd client cert/key. |
| `grafana-agent-k8s-cluster-metrics.sh` | Renders and applies a cluster-wide Grafana Agent Deployment (RBAC + ConfigMap + Deployment) that scrapes cAdvisor, kubelet, and kube-state-metrics across every node via the API server proxy. |

## Key configuration choices

- **`scrape_interval: 60s` everywhere** — matches the rest of this repo's
  host/infra scrape cadence; fine-grained enough for alerting without
  flooding the remote_write path.
- **`scrape_timeout: 90s` for the Kubernetes job** (`grafana-agent-k8s-cluster-metrics.sh`)
  — deliberately longer than the 60s interval, since cAdvisor/kubelet
  scrapes proxied through the API server can run slow on large, busy
  clusters; a timed-out scrape is worse than an occasional overlap.
- **`metric_relabel_configs` keep-list on kube-state-metrics** — keeps only
  the metric-name prefixes actually used for dashboards/alerts
  (`kube_.*`, `container_.*`, `node_.*`, etc.), since kube-state-metrics
  emits far more label cardinality than most clusters need, and
  remote_write-billed backends charge per active series.
- **`insecure_skip_verify: true` on the etcd scrape target** — etcd's
  serving cert is issued for its Pod/Service name, not the node IP it's
  scraped by here, so strict verification would fail; this is a narrower,
  deliberate exception (only on the etcd job), not a blanket TLS bypass.
- **`resources` limits added to the Kubernetes Deployment** — the original
  production manifest set none; this repo adds conservative
  `100m/128Mi` requests and `1 CPU/512Mi` limits so the example doesn't
  run unbounded on a shared cluster. Raise these for large clusters with
  many nodes/services to scrape.
- **No binary install path is `latest`** — `GRAFANA_AGENT_VERSION` /
  `GRAFANA_AGENT_K8S_IMAGE` are both pinned to an explicit version and
  overridable via env var, so re-running a script doesn't silently change
  what's deployed.
- **Portal/dashboard registration is always optional** — every script that
  previously called a proprietary dashboard/alert-creation API or a
  fleet-registration script now gates that call behind
  `PORTAL_API_BASE_URL` / `PORTAL_REGISTER_SCRIPT_URL`. Leave them unset
  and the scripts only install and configure the agent — no SaaS backend
  required to make this repo runnable end-to-end.

## Duplicate-script decision

The source onboarding scripts included two versions of the generic Linux
host script: `jobsv_linux_script.sh` and `linux_script2.sh`. They were
byte-identical except for four extra lines in `linux_script2.sh` that
skipped dashboard/alert creation for one hardcoded production tenant ID.
`linux_script2.sh` was treated as the canonical, more recent version (it's
a strict superset of the other), migrated as `grafana-agent-host-install.sh`,
with the hardcoded tenant-skip removed during sanitization (it only made
sense for one specific real tenant). `jobsv_linux_script.sh` was **not**
migrated.

## Usage

```bash
# Generic Linux host, one or more tenants
export METRICS_REMOTE_WRITE_URL="https://mimir.example.internal/api/v1/push"
sudo ./grafana-agent-host-install.sh tenant-a tenant-b

# CRI-O host
export METRICS_REMOTE_WRITE_URL="https://mimir.example.internal/api/v1/push"
export TENANT_ID="tenant-a"
sudo ./grafana-agent-crio-exporter.sh

# Docker host
export METRICS_REMOTE_WRITE_URL="https://mimir.example.internal/api/v1/push"
export TENANT_ID="tenant-a"
sudo ./grafana-agent-docker-exporter.sh

# etcd / Kubernetes control-plane host
export METRICS_REMOTE_WRITE_URL="https://mimir.example.internal/api/prom/push"
export TENANT_ID="tenant-a"
sudo ./grafana-agent-etcd-exporter.sh

# Cluster-wide Kubernetes metrics (requires kube-state-metrics already deployed)
export METRICS_REMOTE_WRITE_URL="https://mimir.example.internal/api/v1/push"
export TENANT_ID="tenant-a"
export MIMIR_USERNAME="mimir"
export MIMIR_PASSWORD="your-password"
./grafana-agent-k8s-cluster-metrics.sh my-app my-namespace
```

Optional portal integration (skipped entirely if unset):

```bash
export PORTAL_API_BASE_URL="https://observability-portal.example.com"
export PORTAL_DASHBOARD_TEMPLATE_ID="your-template-id"
export PORTAL_ALERT_TECHNOLOGY_ID="your-technology-id"
```

See the root [`.env.example`](../../.env.example) for the full list of
variables these scripts read, with example values.
