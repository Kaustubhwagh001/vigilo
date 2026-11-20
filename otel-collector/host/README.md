# otel-collector / host

Installs the official **`otelcol-contrib`** package directly on a Linux or
Windows host (not Kubernetes) to collect host-level telemetry —
`hostmetrics`, local log files, Windows Event Log, journald — and ship it
to a central OTLP backend. This is a different deployment tier from
[`otel-collector/agent/`](../agent/README.md): that one is a *per-application*
collector receiving OTLP from app code, deployed as a Kubernetes
Deployment/DaemonSet. This one is a *per-host* package install that watches
the machine itself (CPU/mem/disk/network, process table, syslog/journald/
Event Log) — the two are complementary, not alternatives.

## Files

| File | What it does |
|---|---|
| `linux/otelcol-host-install.sh` | Downloads the official `.deb` release, installs it with `dpkg -i`, renders `/etc/otelcol-contrib/config.yaml` from env vars, and runs it as the package's systemd service. |
| `linux/otelcol-host-uninstall.sh` | Backs up the running config, stops the service, and removes the package and its config. |
| `windows/otelcol-host-install.ps1` | Downloads the official `.tar.gz` release, renders `config.yaml` from env vars, validates it, and registers/starts it as a Windows service via `sc.exe`. |
| `windows/otelcol-host-uninstall.ps1` | Backs up the running config, stops and deletes the service, and removes the install directory. |
| [`integrations/`](integrations/) | Per-datastore receiver fragments (Cassandra, MongoDB, Redis, ScyllaDB, etc.) layered on top of the host collector installed here — see that folder for details. |

## Why one package install instead of a container

Host-level telemetry (hostmetrics, syslog, journald, Windows Event Log)
needs access to the host's `/proc`, log directories, and event subsystem
that's awkward to grant a container running alongside it. Installing the
official package directly, as a systemd/Windows service, is the simplest
way to get that access without extra mount/capability plumbing — this
mirrors `grafana-agent/linux`'s approach to the same problem for Grafana
Agent, just for OTel Collector Contrib instead.

## OpenTelemetry Collector version

The install scripts pin **v0.138.0** by default, overridable via
`COLLECTOR_VERSION` (Linux) / `$env:COLLECTOR_VERSION` (Windows). The
source material referenced three versions in use or available at
different points — v0.116.0 (an older pin), v0.138.0 (what the Windows
install flow actually downloaded in practice), and v0.144.0 (newest
release at time of writing, mentioned as "latest" but never shown
actually installed). All three were confirmed against the real
`open-telemetry/opentelemetry-collector-releases` GitHub releases API,
with the expected `otelcol-contrib_<version>_linux_amd64.deb` /
`_windows_amd64.tar.gz` asset names present on each. v0.138.0 was chosen
as the default because it's the version with direct evidence of a working
install, not just a mention; v0.144.0 remains a reasonable choice if you
want to track closer to upstream. Set `COLLECTOR_VERSION` to pin
whichever you need — don't bump it blindly across a fleet without testing.

## Config dedup: one generic template + env-var "recipes", not six near-duplicate files

The source material included **six-plus Linux "host collector" YAML
files** that all define `receivers: hostmetrics` with the same overall
shape (hostmetrics + resourcedetection + resource attributes + OTLP
export), differing only in small, mechanical ways:

- **Two were near-identical to each other**, not just to the rest: a test
  config for the `googlecloudmonitoring` receiver (pulling metrics *from*
  Google Cloud Monitoring's API, not from the local host) and a "sample"
  copy of the same thing, differing only in which `metric_descriptor_filter`
  / `metric_name` values were listed. One of those filters referenced a
  real bank's name in a metric path — removed entirely, not sanitized
  into a placeholder, since it had no reason to be in a shared template.
  Neither was migrated as a file: `googlecloudmonitoring` is a pull-based
  cloud API receiver, not a host-level scrape, so it doesn't fit this
  tier's job. If you need it, see the [upstream receiver
  docs](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/googlecloudmonitoringreceiver)
  and add it to your own rendered config.
- **The rest differed only in**: which `resource/env` attribute values
  were hardcoded (environment name, tenant ID, a `service.name`/`Service_name`/
  `Service.name` spelling that should all just be `service.name`), which
  `journald` units were tailed (`scylla-server` vs. `crio-server` vs.
  none), which process names the `process` scraper's `include` regex kept
  (`kafka.*`/`scylla.*` vs. `java.*` vs. nothing extra), and one extra
  Prometheus static-scrape job pointed at a role-specific exporter
  (a Kafka exporter + Kafka lag exporter + Zookeeper exporter on one host;
  a CRI-O exporter on another; a commented-out `blackbox_exporter` probe
  block on a third). None of that is a *structural* difference — it's
  config values.
- One file (`default otel config.yml` in the source) wasn't a host
  template at all — it's the package's stock out-of-the-box default
  config (otlp/jaeger/zipkin/opencensus receivers, `debug` exporter, no
  `hostmetrics`). Not migrated as a file; mentioned in Troubleshooting
  below, since it's genuinely useful as "what ships before you run the
  installer."

Given that, shipping five or six nearly-identical full YAML files would
mean every real fix has to be copy-pasted five times. Instead,
`linux/otelcol-host-install.sh` renders **one config from one template**,
parameterized by env vars, and the role-specific knowledge from those
source files is captured as **recipes** — env var combinations — below,
rather than as separate files:

| Role | `PROCESS_NAME_FILTER` | `ENABLE_JOURNALD` / `JOURNALD_UNITS` | `EXTRA_PROMETHEUS_TARGETS` | `SERVICE_NAME` |
|---|---|---|---|---|
| Generic host (default) | `otelcol.*,systemd.*,node.*` | `false` | (unset) | `host` |
| Kafka + ScyllaDB host | `java.*,kafka.*,scylla.*,node.*,otelcol.*,systemd.*` | `true` / `ssh,scylla-server` | Kafka + Kafka-lag + Zookeeper exporter `host:port`s, comma-separated | `kafka` |
| CRI-O container host | `otelcol.*,systemd.*` | `true` / `ssh,crio-server` | the host's CRI-O exporter `host:port` | `crio` |
| Network-probe / "blackbox" host | `otelcol.*,systemd.*` | `false` | your `blackbox_exporter`'s `host:port`, if running one locally | `blackbox` |

Add a cloud resourcedetection detector (`gcp`, `ec2`, `azure`, `ecs`,
`docker`) to `RESOURCE_DETECTORS` (default `env,system`) if the host runs
on that platform.

**Windows was a genuine 1-for-1 dedup**: the source had
`windows-metrics-config.yaml` and `windows-log-config.yml`, and the latter
is a strict superset of the former (identical `hostmetrics`/
`resourcedetection`/`resource/env`/exporters — the log config just adds
the two `windowseventlog` receivers, the `logs/windows` pipeline, and a
commented-out `filelog` block for a custom app log path). `windows/
otelcol-host-install.ps1` renders the superset; `EVENTLOG_CHANNELS`
(default `Application,System`) controls which Event Log channels it
watches.

## Troubleshooting

```powershell
# Service status / logs (Linux)
systemctl status otelcol-contrib
journalctl -u otelcol-contrib -f

# Service status (Windows)
Get-Service ObservabilityCollector

# Confirm the rendered config is valid before trusting a failed start
otelcol-contrib validate --config /etc/otelcol-contrib/config.yaml   # Linux
.\otelcol-contrib.exe validate --config .\config.yaml                 # Windows

# Confirm the backend hostname actually resolves from this host
nslookup <your-otlp-backend-hostname>

# Inspect what the systemd unit itself looks like (Linux; installed by the package)
cat /lib/systemd/system/otelcol-contrib.service
```

Before filing "it's not sending data," check (in order): the service is
actually running, the rendered `/etc/otelcol-contrib/config.yaml` has the
`otlp` exporter pointed at a reachable `OTLP_BACKEND_ENDPOINT`, and DNS for
that endpoint resolves from the host (not just from your laptop).

### Upgrading or rolling back

Re-run `otelcol-host-install.sh` / `otelcol-host-install.ps1` with a
different `COLLECTOR_VERSION` — `dpkg -i` happily upgrades an existing
install in place on Linux, and the Windows script stops/recreates the
service before restarting it. There's no separate "upgrade" script; the
installer is idempotent.

### Uninstalling

```bash
sudo ./linux/otelcol-host-uninstall.sh          # backs up config to /tmp/otelcol-contrib-backup, then removes the package
```

```powershell
.\windows\otelcol-host-uninstall.ps1             # backs up config, deletes the service, removes the install dir
```

## Usage

```bash
# Linux
export OTLP_BACKEND_ENDPOINT="otel-gateway.example.internal:4317"
export TENANT_ID="my-tenant"
sudo ./linux/otelcol-host-install.sh
```

```powershell
# Windows
$env:OTLP_BACKEND_ENDPOINT = "otel-gateway.example.internal:4317"
$env:TENANT_ID = "my-tenant"
.\windows\otelcol-host-install.ps1
```

See the root [`.env.example`](../../.env.example) for the full list of
variables these scripts read, with example values.

## Debian/Ubuntu only (Linux)

`linux/otelcol-host-install.sh` installs the `.deb` package via `dpkg`.
RPM-based distros need the `.rpm` asset from the same [releases
page](https://github.com/open-telemetry/opentelemetry-collector-releases/releases) —
not covered by this script.
