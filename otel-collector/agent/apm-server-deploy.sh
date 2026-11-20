#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — OTel Collector agent / Elastic APM server bridge
# Purpose: render and apply a K8s Deployment+Service+ConfigMap
#          for a per-app Elastic APM server (legacy trace intake,
#          used alongside the OTel collector for apps not yet
#          fully migrated to OTLP export).
# Requires env: ELASTICSEARCH_URL, ELASTICSEARCH_USERNAME,
#               ELASTICSEARCH_PASSWORD
# Usage: ./apm-server-deploy.sh <tenant-id> <app-name> <namespace>
# ------------------------------------------------------------
set -euo pipefail

TENANT_ID="${1:-default}"
APP_NAME="${2:-default}"
NAMESPACE="${3:-default}"

: "${ELASTICSEARCH_URL:?set ELASTICSEARCH_URL, e.g. https://elastic.example.com:443}"
: "${ELASTICSEARCH_USERNAME:?set ELASTICSEARCH_USERNAME}"
: "${ELASTICSEARCH_PASSWORD:?set ELASTICSEARCH_PASSWORD}"
APM_SERVER_IMAGE="${APM_SERVER_IMAGE:-docker.elastic.co/apm/apm-server:7.17.1}"

TEMPLATE=$(cat <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: <APP_NAME>-apm-server-config
  namespace: <NAMESPACE>
  labels:
    app: "<APP_NAME>-apm-server"
    chart: "apm-server-7.17.1"
    heritage: "Helm"
    release: "<APP_NAME>-apm-server"
data:
  apm-server.yml: |
    apm-server:
      host: "0.0.0.0:8200"
    output.elasticsearch:
      hosts: ["<ELASTICSEARCH_URL>"]
      username: "<ELASTICSEARCH_USERNAME>"
      password: "<ELASTICSEARCH_PASSWORD>"
    output.elasticsearch.bulk_max_size: 500
    output.elasticsearch.timeout: 300
    output.elasticsearch.worker: 10
    # Buffer up to 50k events in memory before blocking — tune down on
    # memory-constrained nodes, tune up if the ES cluster sees write spikes.
    queue.mem.events: 50000
    logging.level: error
    queue.mem.flush.min_events: 100
    queue.mem.flush.timeout: 10
    output.elasticsearch.index: "apm-<TENANT_ID>-<APP_NAME>-%{[observer.version]}-%{[processor.event]}-%{+yyyy.MM.dd}"
    setup.template.name: "apm-server-<TENANT_ID>-<APP_NAME>"
    setup.template.pattern: "apm-<TENANT_ID>-<APP_NAME>-*"
---
apiVersion: v1
kind: Service
metadata:
  name: <APP_NAME>-apm-server
  namespace: <NAMESPACE>
  labels:
    app: "<APP_NAME>-apm-server"
    release: "<APP_NAME>-apm-server"
    heritage: Helm
spec:
  type: ClusterIP
  ports:
    - port: 8200
      protocol: TCP
      name: http
      targetPort: 8200
  selector:
    app: "<APP_NAME>-apm-server"
    release: "<APP_NAME>-apm-server"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <APP_NAME>-apm-server
  namespace: <NAMESPACE>
  labels:
    app: "<APP_NAME>-apm-server"
    release: "<APP_NAME>-apm-server"
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app: "<APP_NAME>-apm-server"
      release: "<APP_NAME>-apm-server"
  template:
    metadata:
      labels:
        app: "<APP_NAME>-apm-server"
        release: "<APP_NAME>-apm-server"
    spec:
      securityContext:
        fsGroup: 1000
        runAsGroup: 0
        runAsUser: 1000
      serviceAccountName: default
      volumes:
        - name: apm-server-config
          configMap:
            name: <APP_NAME>-apm-server-config
            defaultMode: 0600
      containers:
      - name: apm-server
        image: "<APM_SERVER_IMAGE>"
        imagePullPolicy: "IfNotPresent"
        securityContext:
          privileged: false
          runAsGroup: 0
          runAsNonRoot: true
          runAsUser: 1000
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: http
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: http
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        ports:
          - containerPort: 8200
            name: http
        resources:
          limits:
            cpu: "2"
            memory: 2Gi
          requests:
            cpu: "1"
            memory: 1Gi
        volumeMounts:
          - name: apm-server-config
            mountPath: /usr/share/apm-server/apm-server.yml
            subPath: apm-server.yml
            readOnly: true
YAML
)

echo "${TEMPLATE}" | sed \
  -e "s#<TENANT_ID>#${TENANT_ID}#g" \
  -e "s#<APP_NAME>#${APP_NAME}#g" \
  -e "s#<NAMESPACE>#${NAMESPACE}#g" \
  -e "s#<ELASTICSEARCH_URL>#${ELASTICSEARCH_URL}#g" \
  -e "s#<ELASTICSEARCH_USERNAME>#${ELASTICSEARCH_USERNAME}#g" \
  -e "s#<ELASTICSEARCH_PASSWORD>#${ELASTICSEARCH_PASSWORD}#g" \
  -e "s#<APM_SERVER_IMAGE>#${APM_SERVER_IMAGE}#g"
