# Instrumenting a Node.js app for OpenTelemetry

How to wire a Node.js / Express service up to emit traces through the
[OTel Collector agent](../otel-collector/agent/README.md).

## 1. Example app

```bash
npm install express
```

```js
/* app.js */
const express = require("express");
const PORT = process.env.PORT || "8080";
const app = express();

app.get("/", (req, res) => {
  res.send("Hello World");
});

app.listen(parseInt(PORT, 10), () => {
  console.log(`Listening for requests on http://localhost:${PORT}`);
});
```

```bash
node app.js
# Listening for requests on http://localhost:8080
```

## 2. Install the tracing SDK

Core SDK and API:

```bash
npm install @opentelemetry/sdk-node @opentelemetry/api
npm install @opentelemetry/exporter-trace-otlp-http
npm install @opentelemetry/auto-instrumentations-node
```

Add specific instrumentations only for the libraries the service actually
uses — don't install the ones below for a service with no Kafka/Mongo/Redis
dependency:

```bash
npm install @opentelemetry/instrumentation-express
npm install @opentelemetry/instrumentation-http
npm install @opentelemetry/instrumentation-mongodb
npm install @opentelemetry/instrumentation-mysql
npm install @opentelemetry/instrumentation-redis
npm install opentelemetry-instrumentation-sequelize
npm install opentelemetry-instrumentation-socket.io
npm install opentelemetry-instrumentation-elasticsearch
npm install opentelemetry-instrumentation-kafkajs
```

## 3. Set up tracing before app code runs

Tracing setup must execute before the rest of your application loads it —
either via `node -r ./tracing.js app.js`, or by requiring it as the very
first line of your entrypoint:

```js
require("./tracing");
```

`tracing.js` — replace the resource attributes with values that describe
your own service:

```js
/* tracing.js */
const opentelemetry = require("@opentelemetry/sdk-node");
const { BatchSpanProcessor } = require("@opentelemetry/sdk-trace-base");
const { getNodeAutoInstrumentations } = require("@opentelemetry/auto-instrumentations-node");
const { OTLPTraceExporter } = require("@opentelemetry/exporter-trace-otlp-http");
const { SemanticResourceAttributes } = require("@opentelemetry/semantic-conventions");
const { Resource } = require("@opentelemetry/resources");
const { HttpInstrumentation } = require("@opentelemetry/instrumentation-http");
const { ExpressInstrumentation } = require("@opentelemetry/instrumentation-express");

// The OTel Collector agent's OTLP/HTTP endpoint, e.g.
// http://otel-collector-<app-name>.<namespace>.svc.cluster.local:4318/v1/traces
const traceEndpoint = `${process.env.OTEL_EXPORTER_OTLP_ENDPOINT}/v1/traces`;
const serviceName = process.env.OTEL_SERVICE_NAME;

const exporter = new OTLPTraceExporter({
  url: traceEndpoint,
  concurrencyLimit: 10,
});

const sdk = new opentelemetry.NodeSDK({
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: serviceName,
    [SemanticResourceAttributes.K8S_POD_NAME]: process.env.HOSTNAME,
    platform: process.env.OTEL_RESOURCE_PLATFORM,
    sub_platform: process.env.OTEL_RESOURCE_SUB_PLATFORM,
    component_type: process.env.OTEL_RESOURCE_COMPONENT_TYPE,
    env: process.env.OTEL_RESOURCE_ENV,
  }),
  spanProcessor: new BatchSpanProcessor(exporter, {
    maxQueueSize: 100,        // spans dropped once this is exceeded
    maxExportBatchSize: 10,
    scheduledDelayMillis: 500,
    exportTimeoutMillis: 30000,
  }),
  instrumentations: [
    new HttpInstrumentation({
      ignoreIncomingPaths: [/\/metrics/, /\/intake/],
    }),
    new ExpressInstrumentation({
      requestHook: (spanInfo, requestInfo) => {
        spanInfo.setAttribute("express.body", JSON.stringify(requestInfo.request.body));
      },
    }),
    // Add other instrumentations (Mongo, MySQL, Redis, Kafka, ...) here,
    // matching only what app.js actually imports.
  ],
});

sdk.start()
  .then(() => console.log("Tracing initialized"))
  .catch((error) => console.log("Error initializing tracing", error));

process.on("SIGTERM", () => {
  sdk.shutdown()
    .then(() => console.log("Tracing terminated"))
    .catch((error) => console.log("Error terminating tracing", error))
    .finally(() => process.exit(0));
});
```

> **Note on the `express.body` request hook above:** logging full request
> bodies into span attributes can leak PII/secrets into your tracing
> backend. Only do this for internal/debug environments, and scrub
> sensitive fields first.
