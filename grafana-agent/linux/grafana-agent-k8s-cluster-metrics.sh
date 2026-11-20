#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Grafana Agent (classic, static mode) — Kubernetes cluster metrics
# Purpose: render and apply a cluster-wide Grafana Agent Deployment (RBAC +
#          ConfigMap + Deployment) that scrapes cAdvisor, kubelet, and
#          kube-state-metrics across every node via the API server proxy,
#          and remote_writes to a Mimir/Prometheus-remote_write-compatible
#          backend.
# Requires env: METRICS_REMOTE_WRITE_URL, TENANT_ID, MIMIR_USERNAME,
#               MIMIR_PASSWORD
# Optional env: GRAFANA_AGENT_K8S_IMAGE, CLUSTER_NAME, PORTAL_API_BASE_URL,
#               PORTAL_DASHBOARD_TEMPLATE_ID, PORTAL_ALERT_TECHNOLOGY_ID
# Usage: ./grafana-agent-k8s-cluster-metrics.sh <app-name> <namespace>
#
# *** Use lowercase, no special characters in <app-name>/<namespace> —
# *** must comply with Kubernetes naming conventions.
# *** kube-state-metrics must already be deployed in the cluster for the
# *** integrations/kubernetes/kube-state-metrics scrape job to return data —
# *** see https://github.com/kubernetes/kube-state-metrics.
# ------------------------------------------------------------
set -euo pipefail

APP_NAME="${1:?usage: $0 <app-name> <namespace>}"
NAMESPACE="${2:?usage: $0 <app-name> <namespace>}"

: "${METRICS_REMOTE_WRITE_URL:?set METRICS_REMOTE_WRITE_URL, e.g. https://mimir.example.internal/api/v1/push}"
: "${TENANT_ID:?set TENANT_ID, e.g. your Mimir org ID}"
: "${MIMIR_USERNAME:?set MIMIR_USERNAME for the remote_write basic_auth user}"
: "${MIMIR_PASSWORD:?set MIMIR_PASSWORD for the remote_write basic_auth user}"

GRAFANA_AGENT_K8S_IMAGE="${GRAFANA_AGENT_K8S_IMAGE:-grafana/agent:v0.40.3}"
CLUSTER_NAME="${CLUSTER_NAME:-my-k8s-cluster}"

TEMPLATE=$(cat <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-agent-<APP_NAME>
  namespace: <NAMESPACE>
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: grafana-agent-<APP_NAME>
rules:
- apiGroups:
  - ""
  resources:
  - nodes
  - nodes/proxy
  - services
  - endpoints
  - pods
  verbs:
  - get
  - list
  - watch
- nonResourceURLs:
  - /metrics
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-agent-<APP_NAME>
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: grafana-agent-<APP_NAME>
subjects:
- kind: ServiceAccount
  name: grafana-agent-<APP_NAME>
  namespace: <NAMESPACE>
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-agent-<APP_NAME>
  namespace: <NAMESPACE>
data:
  agent.yaml: |
    server:
      http_listen_port: 12345
      log_level: error
    prometheus:
      wal_directory: /tmp/grafana-agent-wal
      global:
        scrape_interval: 60s
        # Generous relative to the 60s interval on purpose — cAdvisor/kubelet
        # scrapes via the API server proxy can run slow on large, busy
        # clusters, and a dropped scrape is worse than an occasional overlap.
        scrape_timeout: 90s
        external_labels:
          cluster: <CLUSTER_NAME>
      configs:
      - name: integrations
        remote_write:
        - url: <METRICS_REMOTE_WRITE_URL>
          basic_auth:
            username: <MIMIR_USERNAME>
            password: <MIMIR_PASSWORD>
          headers:
            X-Scope-OrgID: <TENANT_ID>
          tls_config:
            insecure_skip_verify: true
        scrape_configs:
        - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          job_name: integrations/kubernetes/cadvisor
          kubernetes_sd_configs:
              - role: node
          relabel_configs:
              - replacement: kubernetes.default.svc.cluster.local:443
                target_label: __address__
              - regex: (.+)
                replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor
                source_labels:
                  - __meta_kubernetes_node_name
                target_label: __metrics_path__
          scheme: https
          tls_config:
              ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              insecure_skip_verify: false
              server_name: kubernetes
        - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          job_name: integrations/kubernetes/kubelet
          kubernetes_sd_configs:
              - role: node
          relabel_configs:
              - replacement: kubernetes.default.svc.cluster.local:443
                target_label: __address__
              - regex: (.+)
                replacement: /api/v1/nodes/$1/proxy/metrics
                source_labels:
                  - __meta_kubernetes_node_name
                target_label: __metrics_path__
          scheme: https
          tls_config:
              ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              insecure_skip_verify: false
              server_name: kubernetes
        - job_name: integrations/kubernetes/kube-state-metrics
          kubernetes_sd_configs:
              - role: service
          # Keep only prefixes we actually dashboard/alert on — kube-state-metrics
          # emits a very large label cardinality otherwise, which gets expensive
          # fast on a remote_write-billed backend.
          metric_relabel_configs:
              - source_labels: [__name__]
                regex: process_.*|kube_.*|container_.*|kubelet_.*|node_.*|machine_.*|go_.*|up|cluster.*|cluster_.*|kubernetes_.*|storage_.*|volume_.*|namespace_.*|rest_.*
                action: keep
          relabel_configs:
              - action: keep
                regex: kube-state-metrics
                source_labels:
                  - __meta_kubernetes_service_name
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana-agent-<APP_NAME>
  namespace: <NAMESPACE>
spec:
  minReadySeconds: 10
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      name: grafana-agent-<APP_NAME>
  template:
    metadata:
      labels:
        name: grafana-agent-<APP_NAME>
    spec:
      containers:
      - args:
        - -config.file=/etc/agent/agent.yaml
        command:
        - /bin/agent
        env:
        - name: HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        image: <GRAFANA_AGENT_K8S_IMAGE>
        imagePullPolicy: IfNotPresent
        name: agent
        ports:
        - containerPort: 12345
          name: http-metrics
        resources:
          limits:
            cpu: "1"
            memory: 512Mi
          requests:
            cpu: 100m
            memory: 128Mi
        volumeMounts:
        - mountPath: /etc/agent
          name: grafana-agent-<APP_NAME>
      serviceAccount: grafana-agent-<APP_NAME>
      volumes:
      - configMap:
          name: grafana-agent-<APP_NAME>
        name: grafana-agent-<APP_NAME>
YAML
)

echo "${TEMPLATE}" | sed \
  -e "s#<APP_NAME>#${APP_NAME}#g" \
  -e "s#<NAMESPACE>#${NAMESPACE}#g" \
  -e "s#<METRICS_REMOTE_WRITE_URL>#${METRICS_REMOTE_WRITE_URL}#g" \
  -e "s#<TENANT_ID>#${TENANT_ID}#g" \
  -e "s#<MIMIR_USERNAME>#${MIMIR_USERNAME}#g" \
  -e "s#<MIMIR_PASSWORD>#${MIMIR_PASSWORD}#g" \
  -e "s#<CLUSTER_NAME>#${CLUSTER_NAME}#g" \
  -e "s#<GRAFANA_AGENT_K8S_IMAGE>#${GRAFANA_AGENT_K8S_IMAGE}#g" \
  | kubectl apply -n "$NAMESPACE" -f -

kubectl rollout restart "deployment/grafana-agent-${APP_NAME}" -n "$NAMESPACE"

# Optional: register a dashboard/alert for this tenant with an
# observability portal, if one is configured.
if [[ -n "${PORTAL_API_BASE_URL:-}" ]]; then
  : "${PORTAL_DASHBOARD_TEMPLATE_ID:?set PORTAL_DASHBOARD_TEMPLATE_ID when PORTAL_API_BASE_URL is set}"
  : "${PORTAL_ALERT_TECHNOLOGY_ID:?set PORTAL_ALERT_TECHNOLOGY_ID when PORTAL_API_BASE_URL is set}"

  response1=$(curl -s --location --request POST "${PORTAL_API_BASE_URL}/api/dashboards/v1.1/create" \
    --header "tenant-id: ${TENANT_ID}" \
    --header 'Content-Type: application/json' \
    --data-raw "{\"template_ids\": [\"${PORTAL_DASHBOARD_TEMPLATE_ID}\"]}")
  echo "Dashboard API response: ${response1}"

  response2=$(curl -s --location --request POST "${PORTAL_API_BASE_URL}/api/alerts/v1.1/set" \
    --header "tenant-id: ${TENANT_ID}" \
    --header 'Content-Type: application/json' \
    --data-raw "{\"technology_id\": \"${PORTAL_ALERT_TECHNOLOGY_ID}\"}")
  echo "Alerts API response: ${response2}"
fi
