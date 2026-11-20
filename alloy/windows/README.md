# alloy / windows

Grafana Alloy (River config) for Windows hosts: self-monitoring, host and
MSSQL metrics via `windows_exporter`, Windows Event Log shipping, and an
optional custom application log tail — all `remote_write`/`loki.write`d to
a Mimir/Loki-compatible backend.

This is genuinely **Alloy** config (River syntax — `prometheus.exporter.*`,
`discovery.relabel`, `prometheus.scrape`, `loki.source.windowsevent`, etc.),
not Grafana Agent's static-mode YAML. See the top-level
[`../README.md`](../README.md) for why that distinction matters in this
repo.

## Files

| File | What it monitors |
|---|---|
| `windows-host-monitoring.alloy` | Alloy's own process health (`prometheus.exporter.self`), generic `windows_exporter` host metrics (CPU, memory, disk, network, services, time sync, and the `mssql` collector — safe to leave enabled even without SQL Server installed), and the Windows `Application` + `System` event logs shipped to Loki. |
| `windows-custom-logs.alloy` | The same pipeline as `windows-host-monitoring.alloy`, plus a `loki.source.file` tail of a custom application's own log file on disk (for apps that log to a flat file instead of the Windows Event Log). |
| `alloy-windows-install.ps1` | Downloads the official Grafana Alloy Windows installer, runs it silently, and installs one of the configs above as the service config. |

## Resolved: a duplicate file in the source material

The source material originally shipped this as two separate files,
`windows-host-monitoring.alloy` and `windows-mssql.alloy` — functionally
identical (same `enabled_collectors` list, which already included `"mssql"`
in *both*, same relabel rules, same log pipeline), differing only in which
Mimir/Loki endpoint and tenant ID they pointed at. Now that both read those
values from the same env vars, there was no remaining difference, so
they've been collapsed into the one `windows-host-monitoring.alloy` file
above rather than shipped as a confusing pair.

## Key configuration choices

- **`sys.env()` for all secrets/endpoints** — River doesn't support
  shell-style `${VAR}` substitution in the config file itself (that's a
  Grafana Agent Static flag, `-config.expand-env`); Alloy's standard
  library always has `sys.env("NAME")` available, so endpoints, tenant IDs,
  and anything else environment-specific are read that way instead of
  being hardcoded.
- **`area` relabel/log-label value genericized to `"example"`** — the
  source config hardcoded a company-identifying short name here; it's a
  free-form label, so any value works for your environment.
- **Installer URL moved into `alloy-windows-install.ps1`** — the source
  material had a bare installer download URL (using a literal `domain`
  placeholder, not a real hostname) sitting above the first River block,
  which isn't valid River syntax on its own. It's now a proper installer
  script step, pointed at the real public Grafana Alloy GitHub release
  asset (verified against the GitHub releases API — see the script's
  header comment).
- **No MSSQL connection string anywhere** — the `mssql` collector entry
  never connects to SQL Server directly; all MSSQL metrics come from
  `windows_exporter`'s WMI/perfmon-based `mssql` collector running locally
  on the host.

## Apply

```powershell
# One-time install (downloads + silently installs the Alloy Windows
# installer, then installs the chosen config as the service config)
$env:METRICS_REMOTE_WRITE_URL = "https://mimir.example.internal/api/v1/push"
$env:LOKI_PUSH_URL            = "https://loki.example.internal/loki/api/v1/push"
$env:TENANT_ID                = "tenant-a"
$env:ALLOY_CONFIG_FILE        = "windows-host-monitoring.alloy"
.\alloy-windows-install.ps1

# Or, if Alloy is already installed, validate/run a config directly:
alloy run windows-host-monitoring.alloy
```

See the root [`.env.example`](../../.env.example) for the full list of
variables these configs read, with example values.
