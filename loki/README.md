# loki

Log aggregation. Currently covers the log-shipping agent side; Loki's own
server-side config (storage backend, retention, compactor) is a roadmap
item — see the root README.

## What's here

| Folder | Purpose |
|---|---|
| [`promtail/`](promtail/README.md) | Installs Promtail for two deployment targets: a single host via systemd, or a Kubernetes DaemonSet |

See [`promtail/README.md`](promtail/README.md) for why both scripts exist
rather than one — they're genuinely different deployment shapes, not a
duplicate pair.
