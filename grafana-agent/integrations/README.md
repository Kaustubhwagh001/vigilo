# grafana-agent / integrations

Installs the classic (static-mode) Grafana Agent as a Prometheus scrape
target for third-party systems that expose their own metrics endpoint or
have a dedicated exporter, rather than being instrumented directly.

This is the *legacy* Grafana Agent — static-mode YAML config, not Grafana
Alloy's River config. It's archived upstream in favor of Alloy; see each
script's header comment for how to point at a newer build or your own
mirror.

## Files

| File | What it does |
|---|---|
| `kafka.sh` | Installs Grafana Agent and scrapes per-broker `kafka_exporter` targets plus (optionally) ZooKeeper exporter targets, in addition to running the agent's own built-in `kafka_exporter` integration against the broker list directly. |
| `kafka-connect.sh` | Installs Grafana Agent and scrapes a Kafka Connect cluster's metrics endpoint, plus the same built-in `kafka_exporter` integration (kept from the production config it was migrated from — see the script's header comment). |
| `mongodb.sh` | Installs Grafana Agent and enables its built-in `mongodb_exporter` integration against a MongoDB node. |
| `mysql.sh` | Installs Grafana Agent and enables its built-in `mysqld_exporter` integration against a MySQL instance. |
| `oracle.sh` | Installs Grafana Agent and enables its built-in `oracledb` integration against an Oracle instance. |
| `postgresql.sh` | Installs Grafana Agent and enables its built-in `postgres_exporter` integration against a PostgreSQL instance. |
| `redis.sh` | Installs `oliver006/redis_exporter` plus a **standalone Prometheus** binary that scrapes it and remote_writes directly — the one script here that doesn't use Grafana Agent at all (see "Why redis.sh is different" below). |
| `scylladb.sh` | Installs Grafana Agent with the built-in `node_exporter` + `process_exporter` integrations (generic host metrics) plus a static scrape job for an externally-run `scylla_exporter` — ScyllaDB has no built-in Grafana Agent integration. |
| `elasticsearch.sh` | Installs Grafana Agent and enables its built-in `elasticsearch_exporter` integration against an Elasticsearch cluster. |
| `clickhouse.sh` | Installs Grafana Agent with the built-in `node_exporter` + `process_exporter` integrations (generic host metrics) plus a static scrape job for ClickHouse's own built-in Prometheus metrics endpoint — ClickHouse has no dedicated Grafana Agent integration, and needs no separate exporter process either. |

## What each integration scrapes

- **Kafka** (`kafka_exporter` + ZooKeeper exporter) — see `kafka.sh` /
  `kafka-connect.sh` header comments for the exact target shape.
- **MongoDB** (`mongodb_exporter`) — connection pool, replication lag,
  opcounters, WiredTiger cache stats, via a direct `mongodb://` URI.
- **MySQL** (`mysqld_exporter`) — global status/variables, InnoDB metrics,
  slow query counters, via a `user:pass@(host:port)/` DSN.
- **Oracle** (`oracledb`) — tablespace usage, session counts, wait events,
  via an `oracle://` connection string against a given SID/service name.
- **PostgreSQL** (`postgres_exporter`) — connection counts, replication
  lag, table/index bloat stats, via a `postgresql://` DSN.
- **Redis** (`redis_exporter`) — keyspace stats, memory usage, replication
  and connected-clients metrics, scraped by Prometheus itself rather than
  Grafana Agent.
- **ScyllaDB** — relies entirely on whatever metrics `scylla_exporter` (or
  `scylla-manager-agent`) already exposes on port `9180`; this script adds
  no Scylla-specific processing, just a static target.
- **Elasticsearch** (`elasticsearch_exporter`) — cluster/node health,
  shard allocation, indexing/search latency, snapshot and SLM status.
- **ClickHouse** — relies entirely on ClickHouse's own built-in Prometheus
  endpoint (enabled via `<prometheus>` in `config.d/`, see `clickhouse.sh`'s
  header comment); this script adds no ClickHouse-specific processing,
  just a static target.

## Key configuration choices

- **Per-broker static targets, not service discovery** (`kafka.sh`) — the
  source environment ran a fixed, small number of brokers per cluster, so a
  comma-separated `*_TARGETS` env var rendered into a YAML target list was
  simpler than wiring up SD.
- **Both an external scrape job and the built-in `kafka_exporter`
  integration** (`kafka.sh`) — the external job scrapes exporters already
  running per-broker on a fixed port; the built-in integration is the
  agent's own exporter talking to the brokers directly via `kafka_uris`.
  Both are kept because that's what the production config actually ran.
- **`X-Scope-OrgID` header on `remote_write`** — this is Mimir/Cortex's
  multi-tenancy header, carrying the tenant ID(s) passed on the command
  line so one Mimir instance can serve several isolated tenants from the
  same host.
- **Idempotent config writes** — each script only appends a tenant's
  `remote_write` block if it isn't already present, so re-running the
  script to add a new tenant doesn't duplicate existing ones. (The source
  `oracle-linux-script.sh` / `psql-script.sh` had a related bug — their
  duplicate-check only ever compared against the *last* loop value, and
  `psql-script.sh`'s dashboard-registration call only used `$1` instead of
  looping over every tenant ID. Both are fixed in the migrated versions.)
- **Credentials and hosts are env vars, never hardcoded** — every
  connection string is built at runtime from `*_HOST`/`*_USER`/
  `*_PASSWORD` (or equivalent) env vars; see each script's header and the
  root `.env.example` for the full list.
- **Pinned `GRAFANA_AGENT_VERSION` / `ARTIFACT_BASE_URL`** — reproducible
  installs instead of always pulling whatever's newest. Grafana Agent
  renamed its release assets from `agent-linux-amd64.zip` to
  `grafana-agent-linux-amd64.zip` around v0.31; each script's header notes
  which convention its pinned default version uses, verified against the
  GitHub releases API at the time of writing.
- **Optional `PORTAL_*` env vars** — the source scripts also called out to
  an internal onboarding portal to auto-create dashboards/alerts and to
  register the host for inventory. There's no public equivalent of that
  portal, so those calls are gated behind `PORTAL_API_BASE_URL` /
  `PORTAL_REGISTER_SCRIPT_URL` and are skipped entirely (not even
  attempted) when those are unset — the agent install itself never depends
  on them. `oracle.sh` and `postgresql.sh` use a different dashboard-API
  shape than the others (a single tech-specific path instead of the
  `dashboards/v1.1/create` + `alerts/v1.1/set` pair) because that's what
  their source scripts actually called.

### Why `redis.sh` is different

Every other script here installs Grafana Agent itself. The Redis source
script never did — it installs `redis_exporter` plus a plain Prometheus
binary with a static `scrape_configs` entry, and `remote_write`s straight
from Prometheus. That's reproduced faithfully rather than "fixed" to use
Grafana Agent, since it reflects what was actually run in production. If
you'd rather standardize on Grafana Agent for Redis too, swap the
Prometheus install block for the same `curl`/`systemd` pattern used in
`mongodb.sh`, with a `prometheus_remote_write:` scrape job pointed at
`redis_exporter`'s `:9121/metrics`.

## Usage

```bash
export METRICS_REMOTE_WRITE_URL="https://mimir.example.internal/api/v1/push"
export TENANT_ID="your-tenant-id"

# kafka.sh
export KAFKA_EXPORTER_TARGETS="kafka-broker-1.example.com:7076,kafka-broker-2.example.com:7076"
export KAFKA_BROKER_URIS="kafka-broker-1.example.com:9092,kafka-broker-2.example.com:9092"
export ZOOKEEPER_EXPORTER_TARGETS="zookeeper-1.example.com:7075,zookeeper-2.example.com:7075"  # optional
sudo ./kafka.sh

# kafka-connect.sh
export KAFKA_CONNECT_TARGETS="kafka-connect-1.example.com:7077"
export KAFKA_CONNECT_KAFKA_URIS="kafka-broker-1.example.com:9092"
sudo ./kafka-connect.sh

# mongodb.sh
export MONGODB_HOST="10.0.0.11:27017"
export MONGODB_USER="metrics_reader"
export MONGODB_PASSWORD="change-me"
sudo ./mongodb.sh my-tenant

# mysql.sh
export MYSQL_EXPORTER_HOST="10.0.0.12:3306"
export MYSQL_EXPORTER_USER="exporter"
export MYSQL_EXPORTER_PASSWORD="change-me"
sudo ./mysql.sh my-tenant

# oracle.sh
export ORACLE_HOST="10.0.0.13:1521"
export ORACLE_USER="metrics_reader"
export ORACLE_PASSWORD="change-me"
export ORACLE_SERVICE_NAME="XE"               # optional, default shown
sudo ./oracle.sh my-tenant

# postgresql.sh
export POSTGRES_EXPORTER_HOST="10.0.0.14:5432"
export POSTGRES_EXPORTER_USER="postgres_exporter"
export POSTGRES_EXPORTER_PASSWORD="change-me"
sudo ./postgresql.sh my-tenant

# redis.sh
export REDIS_HOST="10.0.0.15:6379"
export REDIS_PASSWORD="change-me"
sudo ./redis.sh my-tenant

# scylladb.sh (single tenant, via TENANT_ID — not a positional arg)
export SCYLLA_EXPORTER_TARGET="10.0.0.17:9180"
sudo ./scylladb.sh

# elasticsearch.sh
export ELASTICSEARCH_EXPORTER_HOST="10.0.0.16:9200"
export ELASTICSEARCH_EXPORTER_USER="elastic"
export ELASTICSEARCH_EXPORTER_PASSWORD="change-me"
sudo ./elasticsearch.sh my-tenant

# clickhouse.sh (single tenant, via TENANT_ID — not a positional arg)
# Requires the ClickHouse-side prometheus.xml config applied first — see
# clickhouse.sh's header comment.
export CLICKHOUSE_EXPORTER_TARGET="clickhouse.example.internal:9363"
sudo ./clickhouse.sh
```

See [`../linux/README.md`](../linux/README.md) for the generic host-install
sibling and shared env var conventions used across this folder, and the
root [`.env.example`](../../.env.example) for the full list of variables
these scripts read.
