# alloy

Grafana Alloy — the actively-maintained successor to Grafana Agent — using
River config syntax. This is intentionally a separate top-level folder from
[`../grafana-agent/`](../grafana-agent/README.md): Grafana Agent (classic,
static-mode YAML) and Alloy (River) are different config languages for a
different (if related) product, so this repo keeps them apart rather than
mixing file formats in one directory. See
[`../grafana-agent/linux/README.md`](../grafana-agent/linux/README.md)'s
opening paragraph for the inverse case of this same rule.

## What's here

| Folder | What it is |
|---|---|
| [`windows/`](windows/README.md) | Windows host self-monitoring, `windows_exporter` host + MSSQL metrics, Windows Event Log shipping, and custom app log tailing. |

This is the first content in `alloy/` — everything else in this repo
predates Alloy and still runs classic Grafana Agent or standalone
exporters/Prometheus. See the root [`README.md`](../README.md)'s "Known
limitation" section for where the Grafana Agent → Alloy migration stands.

## Conventions

- Config files use the `.alloy` extension (not `.river` — Grafana's own
  tooling and `alloy run`/`alloy fmt` expect `.alloy`).
- Secrets and environment-specific values are read via River's
  `sys.env("VAR_NAME")` standard-library function, not hardcoded — Alloy
  has no config-level `${VAR}` expansion flag the way Grafana Agent Static
  does.
- Comments in `.alloy` files use `//` or `/* */` — River does not support
  `#` comments.
