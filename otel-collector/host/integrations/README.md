# otel-collector / host / integrations

Per-datastore receiver config fragments for the **host-level OTel
Collector Contrib** (`otelcol-contrib`, installed as a `.deb` package by
`../linux/*.sh`). Each script here renders a small YAML snippet — a
receiver (plus, where useful, a `filelog`/`journald` receiver for the
datastore's own logs, and a `resource` processor stamping
`service.name`/`tenant.id`) — and prints the exact steps to merge it into
the host collector's main config.

This is a genuinely different integration mechanism from
[`../../../grafana-agent/integrations/`](../../../grafana-agent/integrations/):
those scripts install the classic Grafana Agent and drive its built-in
Prometheus *exporter* integrations (`mongodb_exporter`, `mysqld_exporter`,
...), scraped over `remote_write`. The scripts here instead configure the
OTel Collector's own native receivers (`mongodbreceiver`, `mysqlreceiver`,
...) — or, where no native receiver exists for a datastore, a `prometheus`
receiver pointed at that datastore's own exporter — running *inside* the
same host-level `otelcol-contrib` process, exporting over OTLP.

None of these scripts install the collector binary or touch its main
config file directly — that's `../linux/`'s job. Each one only writes a
fragment under `/etc/otelcol-contrib/conf.d/` and tells you which
receivers/processors to add to the main config's `receivers:`/
`processors:`/`service.pipelines:` blocks. `otelcol-contrib` does not
reliably deep-merge pipeline receiver/processor *lists* across multiple
`--config` files (map keys merge, but list values are replaced), so the
merge step is intentionally manual rather than papering over that with an
`--config` flag that silently drops receivers.

## Files

| File | What it does |
|---|---|
| `cassandra.sh` | Renders a `prometheus` receiver scrape job against an already-running Cassandra Prometheus exporter (e.g. criteo/cassandra_exporter), plus `filelog`/`journald` receivers for Cassandra's own logs. Cassandra has no first-class OTel Collector Contrib receiver with the same maturity as Mongo/MySQL's — see the script header for the JMX-based `cassandrareceiver` alternative. |
| `mongodb.sh` | Renders the native `mongodbreceiver` (direct wire-protocol connection to `mongod`/`mongos`, one replica-set member per invocation) plus `filelog`/`journald` receivers, and documents the read-only metrics user to create. |
| `mysql.sh` | Renders the native `mysqlreceiver` (direct connection to `mysqld`/`mariadbd`) plus `filelog`/`journald` receivers, and documents the `GRANT` needed for the metrics user. |
| `redis.sh` | Renders the native `redis` receiver plus `filelog`/`journald` receivers, with an opt-in `transform/redis` processor to convert the `redis_uptime` counter to a gauge (handles it resetting to 0 on every Redis restart). |
| `rabbitmq.sh` | Enables RabbitMQ's built-in `rabbitmq_prometheus` plugin (when co-located with the broker) and renders a `prometheus` receiver scrape job against it, plus a `journald` receiver. RabbitMQ exposes its own Prometheus endpoint, so no separate exporter binary is needed. |
| `scylladb.sh` | Renders a `prometheus` receiver scrape job against an externally-run `scylla_exporter`. Like Cassandra, ScyllaDB has no native OTel Collector receiver. |
| `elasticsearch.sh` | Renders the native `elasticsearch` receiver (direct REST API connection, cluster/node/index stats) plus `filelog`/`journald` receivers. A genuinely different mechanism from `grafana-agent/integrations/elasticsearch.sh`'s `elasticsearch_exporter` scrape. |
| `kafka-ssl.sh` | Renders a `prometheus` receiver with scrape jobs for per-broker `kafka_exporter`, ZooKeeper exporter, and a consumer-lag exporter, plus a `filelog` receiver. Despite the name (kept for traceability to its source file), the source config had no actual TLS/SASL settings — see the script header. |

## What each integration collects

- **Cassandra** — whatever the pointed-at Prometheus exporter exposes
  (JVM/heap, read/write latency, compaction, cache hit rates, typically),
  plus `/var/log/cassandra/*.log` and the `cassandra` journald unit.
- **MongoDB** (`mongodbreceiver`) — lock acquisition counts/time/wait
  counts, operation latency, active reads/writes, command/query/insert/
  update/delete rates (both overall and `repl_*` replication-specific),
  page faults, WiredTiger cache bytes read, uptime, health — via a direct
  `mongodb://` wire-protocol connection (TLS optional). Plus `/var/log/
  mongo/*.log` and the `mongodb` journald unit.
- **MySQL/MariaDB** (`mysqlreceiver`) — connection/thread stats, InnoDB
  metrics, and sampled statement-digest events (slow/representative
  queries, bounded by `digest_text_limit`/`time_limit`/`limit` so this
  doesn't grow unbounded) — via a direct connection as a dedicated
  read-only user. Plus `/var/log/mysql/*.log` and the `mysqld`/`mysql`
  journald units.
- **Redis** (`redis` receiver) — keyspace stats, memory usage, replication
  and connected-client metrics, uptime — via a direct Redis connection.
  Plus its own log file and `redis`/`redis-sentinel` journald units.
- **RabbitMQ** — whatever `rabbitmq_prometheus` exposes (queue depth,
  message rates, connection/channel counts, node memory/disk alarms) via
  its built-in Prometheus-format endpoint. Plus the `rabbitmq-server`
  journald unit.
- **ScyllaDB** — whatever `scylla_exporter` exposes; no Scylla-specific
  processing is added, just a static scrape target (mirrors
  `grafana-agent/integrations/scylladb.sh`'s approach for the same
  reason: no native receiver exists).
- **Elasticsearch** (`elasticsearch` receiver) — cluster/node health, shard
  allocation, index stats, disk usage — via a direct REST API connection
  (`_local` node scope, `_all` indices). Plus `/var/log/elasticsearch/*.log`
  and the `otelcol-contrib`/`ssh` journald units.
- **Kafka** (`kafka_exporter` + ZooKeeper exporter + an optional consumer-
  lag exporter) — the same metrics shape as
  `grafana-agent/integrations/kafka.sh`'s external scrape job, just
  rendered as an OTel `prometheus` receiver instead of a Grafana Agent one.
  Plus Kafka's own log files.

## Key configuration choices

- **Fragment files, manual merge, not auto-include** — every script writes
  to `${OTELCOL_CONF_DIR:-/etc/otelcol-contrib/conf.d}/<name>.yaml` and
  prints (or comments) the exact lines to add to the main collector
  config's `receivers:`/`processors:`/`service.pipelines:` blocks, rather
  than silently wiring a second `--config` flag. Pipeline receiver lists
  don't deep-merge across `--config` files in `otelcol-contrib`, so an
  automatic include would quietly drop receivers depending on file order —
  explicit, visible merge steps avoid that footgun.
- **Native receivers where they exist, `prometheus` scrape where they
  don't** — MongoDB, MySQL, and Redis have first-class OTel Collector
  Contrib receivers that connect to the datastore directly; Cassandra,
  RabbitMQ, and ScyllaDB either have no receiver of comparable maturity or
  (RabbitMQ) already expose Prometheus-format metrics natively, so those
  three use the generic `prometheus` receiver against an exporter/plugin
  instead. This mirrors which technologies got a native Grafana Agent
  integration vs. a static scrape target in
  `grafana-agent/integrations/`, for the same underlying reason.
- **`service.name` / `tenant.id` as resource attributes, not an
  `X-Scope-OrgID` header** — these configs export via an `otlp` exporter,
  not a Mimir/Cortex `remote_write`, so there's no per-tenant HTTP header
  to set. Multi-tenancy instead comes from a `resource`/`resource/<name>`
  processor stamping `tenant.id` (and `service.name`,
  `deployment.environment`) onto every signal, set from `TENANT_ID` /
  `DEPLOYMENT_ENVIRONMENT` env vars.
- **One collector per replica-set member for MongoDB** — the
  `mongodbreceiver` takes a `hosts:` list of its own endpoints to dial
  directly; `mongodb.sh` is written to be run once per replica-set member
  (each with its own `MONGODB_HOST`) rather than trying to fan one
  collector out across a whole replica set.
- **Credentials and hosts are env vars, never hardcoded** — every
  connection string is built at runtime from `*_HOST`/`*_USER`/
  `*_PASSWORD` (or equivalent) env vars; see each script's header and the
  root `.env.example` for the full list. Note that `mysql.sh`'s
  `MYSQL_HOST`/`MYSQL_USER`/`MYSQL_PASSWORD` are deliberately distinct
  from `grafana-agent/integrations/mysql.sh`'s `MYSQL_EXPORTER_*` vars —
  this mechanism talks to `mysqld` directly, there is no exporter process
  in the loop.
- **User-creation / grant steps documented alongside the receiver they
  serve** — `mongodb.sh` includes the `db.createUser`/`db.updateUser`
  commands for the read-only metrics user as a comment block in the
  generated fragment; `mysql.sh` does the same for the `GRANT ... TO
  '<user>'@'<host>'` statement the metrics user needs. Neither script runs
  these for you — they touch the database server, not the collector host,
  and the collector host script normally runs on may not even have
  `mysql`/`mongosh` installed.

## Usage

```bash
# cassandra.sh
export CASSANDRA_EXPORTER_HOST="10.0.0.20:9500"
export TENANT_ID="my-tenant"
sudo ./cassandra.sh

# mongodb.sh (run once per replica-set member you want metrics from)
export MONGODB_HOST="10.0.0.11:27017"
export MONGODB_USER="otel_metrics_reader"
export MONGODB_PASSWORD="change-me"
export MONGODB_REPLICA_SET="my-replica-set"   # optional
export TENANT_ID="my-tenant"
sudo ./mongodb.sh

# mysql.sh
export MYSQL_HOST="10.0.0.12:3306"
export MYSQL_USER="otel_metrics_reader"
export MYSQL_PASSWORD="change-me"
export TENANT_ID="my-tenant"
sudo ./mysql.sh

# redis.sh
export REDIS_HOST="10.0.0.15:6379"
export REDIS_PASSWORD="change-me"
sudo ./redis.sh

# rabbitmq.sh
export RABBITMQ_EXPORTER_TARGET="10.0.0.18:15692"
sudo ./rabbitmq.sh

# scylladb.sh
export SCYLLA_EXPORTER_TARGET="10.0.0.17:9180"
sudo ./scylladb.sh

# elasticsearch.sh
export ELASTICSEARCH_EXPORTER_HOST="10.0.0.16:9200"
export ELASTICSEARCH_EXPORTER_USER="elastic"
export ELASTICSEARCH_EXPORTER_PASSWORD="change-me"
sudo ./elasticsearch.sh

# kafka-ssl.sh
export KAFKA_EXPORTER_TARGETS="kafka-broker-1.example.com:7076,kafka-broker-2.example.com:7076"
export ZOOKEEPER_EXPORTER_TARGETS="zookeeper-1.example.com:7075"   # optional
export KAFKA_LAG_EXPORTER_TARGETS="kafka-lag-exporter.example.com:9308"  # optional
sudo ./kafka-ssl.sh
```

After each script runs, follow the merge steps it prints to wire the new
receiver(s) into `/etc/otelcol-contrib/config.yaml`'s pipelines, then
`sudo systemctl restart otelcol-contrib`.

See [`../linux/`](../linux/) for the collector install itself and the
shared base config these fragments merge into, and the root
[`.env.example`](../../../.env.example) for the full list of variables
these scripts read.
