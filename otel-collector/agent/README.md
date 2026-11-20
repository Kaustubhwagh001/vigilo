# otel-collector / agent

Deploys a per-application OpenTelemetry Collector plus a legacy Elastic APM
server, both scoped to one app's namespace.

## Files

| File | What it does |
|---|---|
| `otel-collector-deploy.sh` | Renders and applies the collector's ConfigMap, Service, and Deployment/DaemonSet. Receives OTLP (gRPC `4317` / HTTP `4318`), batches, and exports to logging (debug), an OTLP/HTTP backend, and the Elastic APM bridge. |
| `apm-server-deploy.sh` | Renders and applies an Elastic APM server (ConfigMap, Service, Deployment) that forwards to Elasticsearch — a bridge for services still speaking the Elastic APM protocol instead of native OTLP. |
| `deploy.sh` | Interactive entrypoint: prompts for app name / namespace / deploy mode, then runs both scripts above and prints the OTLP endpoint to hand to app developers. |

## Key configuration choices

- **Deployment vs. DaemonSet** — `deploy.sh` lets the operator choose per
  environment: `Deployment` (single replica, fine for dev/staging traffic)
  or `DaemonSet` (one collector per node, for production traffic volume).
- **`batch` processor at 1000 spans / 30s** — caps request overhead to the
  backend without holding spans in memory too long.
- **`sending_queue` of 50000 with retry/backoff** — absorbs backend hiccups
  (10s initial retry, up to 30s intervals, 360s max elapsed) instead of
  dropping spans on a transient failure.
- **Elastic bridge kept alongside OTLP export** — lets teams migrate off the
  legacy Elastic APM agent at their own pace without losing trace data in
  the meantime.

## Usage

```bash
export OTLP_HTTP_BACKEND_ENDPOINT="https://otel-gateway.example.internal"
export ELASTICSEARCH_URL="https://elastic.example.com:443"
export ELASTICSEARCH_USERNAME="your-username"
export ELASTICSEARCH_PASSWORD="your-password"

./deploy.sh my-tenant
```

See [`docs/nodejs-instrumentation.md`](../../docs/nodejs-instrumentation.md)
for wiring an application to send traces to the collector this deploys.
