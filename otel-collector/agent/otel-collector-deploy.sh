#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — OTel Collector agent (per-app)
# Purpose: render and apply a per-application OpenTelemetry
#          Collector (Deployment or DaemonSet) that receives
#          OTLP from the app and fans out to a logging exporter
#          (debug), an OTLP/HTTP backend, and the Elastic APM
#          bridge for legacy consumers.
# Requires env: OTLP_HTTP_BACKEND_ENDPOINT
# Usage: ./otel-collector-deploy.sh <app-name> <namespace> [Deployment|DaemonSet]
# ------------------------------------------------------------
set -euo pipefail

APP_NAME="${1:-default}"
NAMESPACE="${2:-default}"
DEPLOY_MODE="${3:-Deployment}"

: "${OTLP_HTTP_BACKEND_ENDPOINT:?set OTLP_HTTP_BACKEND_ENDPOINT, e.g. https://otel-gateway.example.internal}"
COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.91.0}"

TEMPLATE=$(cat <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
 name: otel-collector-conf-<APP_NAME>
 namespace: <NAMESPACE>
 labels:
   app: opentelemetry-<APP_NAME>
   component: otel-collector-conf-<APP_NAME>
data:
 otel-collector-config: |
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     # Batch before export to cut request overhead to the backend —
     # 1000 spans or 30s, whichever comes first.
     batch:
       send_batch_size: 1000
       timeout: 30s

   exporters:
     logging:
       loglevel: error
     otlphttp:
       endpoint: <OTLP_HTTP_BACKEND_ENDPOINT>
       sending_queue:
         num_consumers: 20
         enabled: true
         queue_size: 50000
       timeout: 30s
       retry_on_failure:
         enabled: true
         max_interval: "30s"
         initial_interval: "10s"
         max_elapsed_time: "360s"

     # Bridges traces to the legacy per-app Elastic APM server
     # deployed by apm-server-deploy.sh, for consumers not yet
     # reading OTLP directly.
     elastic:
       apm_server_url: "http://<APP_NAME>-apm-server.<NAMESPACE>.svc.cluster.local:8200"

   service:
     pipelines:
       traces:
         exporters:
           - logging
           - elastic
           - otlphttp
         processors: [batch]
         receivers:
           - otlp
       metrics:
         exporters:
           - logging
         receivers:
           - otlp

---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector-<APP_NAME>
  namespace: <NAMESPACE>
  labels:
    app: opentelemetry-<APP_NAME>
    component: otel-collector-<APP_NAME>
spec:
  ports:
  - name: otlp-grpc # OpenTelemetry gRPC receiver
    port: 4317
    protocol: TCP
    targetPort: 4317
  - name: otlp-http # OpenTelemetry HTTP receiver
    port: 4318
    protocol: TCP
    targetPort: 4318
  selector:
    component: otel-collector-<APP_NAME>

---
apiVersion: apps/v1
kind: <DEPLOY_MODE>
metadata:
  name: otel-collector-<APP_NAME>
  namespace: <NAMESPACE>
  labels:
    app: opentelemetry-<APP_NAME>
    component: otel-collector-<APP_NAME>
spec:
  selector:
    matchLabels:
      app: opentelemetry-<APP_NAME>
      component: otel-collector-<APP_NAME>
  template:
    metadata:
      labels:
        app: opentelemetry-<APP_NAME>
        component: otel-collector-<APP_NAME>
    spec:
      containers:
      - command:
          - "/otelcol-contrib"
          - "--config=/conf/otel-collector-config.yaml"
        image: <COLLECTOR_IMAGE>
        name: otel-collector
        ports:
        - containerPort: 55679 # zPages
        - containerPort: 4317  # OTLP gRPC receiver
        - containerPort: 4318  # OTLP HTTP receiver
        volumeMounts:
        - name: otel-collector-config-vol
          mountPath: /conf
        resources:
          limits:
            cpu: 2
            memory: 2Gi
          requests:
            cpu: 1
            memory: 1Gi
      volumes:
        - configMap:
            name: otel-collector-conf-<APP_NAME>
            items:
              - key: otel-collector-config
                path: otel-collector-config.yaml
          name: otel-collector-config-vol
YAML
)

echo "${TEMPLATE}" | sed \
  -e "s#<APP_NAME>#${APP_NAME}#g" \
  -e "s#<NAMESPACE>#${NAMESPACE}#g" \
  -e "s#<DEPLOY_MODE>#${DEPLOY_MODE}#g" \
  -e "s#<OTLP_HTTP_BACKEND_ENDPOINT>#${OTLP_HTTP_BACKEND_ENDPOINT}#g" \
  -e "s#<COLLECTOR_IMAGE>#${COLLECTOR_IMAGE}#g"
