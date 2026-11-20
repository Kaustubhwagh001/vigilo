# loki / promtail

Installs Promtail, the Loki log-shipping agent, in two different ways for
two different deployment targets.

## Files

| File | What it does |
|---|---|
| `promtail-systemd-install.sh` | Installs the Promtail **binary** on a single Linux host (VM/bare-metal) and runs it as a systemd service, tailing one log path and shipping to Loki. |
| `promtail-k8s-daemonset.sh` | Renders and applies a Kubernetes **DaemonSet** (ConfigMap, DaemonSet, ServiceAccount, ClusterRole, ClusterRoleBinding) that tails every node's container logs via Kubernetes service discovery. |

### Are these the same script twice?

No — this was checked explicitly, since a prior pass on this repo found a
similarly-named pair that really was just an old backup vs. its newer
replacement. Here the two scripts are genuinely different tools for
different targets:

- `promtail-systemd-install.sh` (migrated from the source `promtail-agent.sh`,
  132 lines) downloads the `promtail-linux-amd64` **binary**, installs it
  under `/usr/local/bin`, and writes a systemd unit + a static Promtail
  config scraping **one fixed `__path__` glob** on **one host**. Good fit
  for a VM, a bare-metal box, or any host not running Kubernetes.
- `promtail-k8s-daemonset.sh` (migrated from the source `promtail_script.sh`,
  465 lines) never touches a binary directly — it templates a Kubernetes
  manifest that runs the official `grafana/promtail` **container image** as
  a DaemonSet, using `kubernetes_sd_configs` to discover every pod on every
  node and tail `/var/log/pods/...` accordingly. Good fit for a Kubernetes
  cluster, where you want one Promtail per node rather than one per app.

They share no code, no config format in common beyond both being Promtail,
and target orthogonal environments (host vs. cluster) — so both were
migrated, unmerged, rather than picking one or combining them.

## Key configuration choices

- **`X-Scope-OrgID`-equivalent: `tenant_id` on the `clients` block** — Loki's
  multi-tenancy is carried via the `tenant_id` field (the HTTP header
  `X-Scope-OrgID` is set for you), not a header you set by hand here.
- **`server.disable: true`** (systemd script) — Promtail's own HTTP/gRPC
  server is turned off since nothing in this setup scrapes Promtail's own
  metrics; drop this if you want `/metrics` exposed.
- **One systemd unit per service** (systemd script) — `promtail-<svc>.service`
  and `/etc/promtail-<app>-<svc>/` are namespaced by app+service so multiple
  independent Promtail instances (different log paths, different tenants)
  can coexist on the same host.
- **Kubernetes SD job per controller shape** (k8s script) — the DaemonSet
  config has six near-identical `scrape_configs` jobs (`kubernetes-pods-name`,
  `-app`, `-direct-controllers`, `-indirect-controller`, `-static`,
  `-logs-labeling`) because different pod types expose their "service name"
  via different labels/annotations (`name` label, `app` label, controller
  name regex, static-pod mirror annotation, ...). All six are kept from the
  production config as shipped — this is standard boilerplate for covering
  every pod-naming convention in a mixed cluster.
- **Dropped: a hardcoded `hostAliases` block** — the source k8s script
  pinned several internal hostnames to internal IPs as a DNS workaround.
  That's environment-specific and has no public equivalent, so it isn't
  reproduced; your cluster's own DNS should resolve `LOKI_PUSH_URL` without
  it.
- **Dropped: an unused `PARSER` template variable** — present in the source
  script's variables but never actually referenced in the rendered
  manifest; removed as dead code rather than carried forward.

## Usage

```bash
# Single host via systemd
export LOKI_PUSH_URL="https://loki.example.internal/loki/api/v1/push"
sudo ./promtail-systemd-install.sh '/var/log/nginx/*.log' storage nginx my-tenant

# Kubernetes DaemonSet
export LOKI_PUSH_URL="https://loki.example.internal/loki/api/v1/push"
export CLUSTER_NAME="my-cluster"
./promtail-k8s-daemonset.sh my-tenant kube-system | kubectl apply -f -
```

See each script's header comment for the full list of required/optional
env vars.
