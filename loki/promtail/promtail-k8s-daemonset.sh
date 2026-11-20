#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — Promtail — Kubernetes DaemonSet
# Purpose: render and apply a Promtail DaemonSet (ConfigMap, DaemonSet,
#          ServiceAccount, ClusterRole, ClusterRoleBinding) that tails
#          container logs on every node via Kubernetes service discovery,
#          shipping lines to a Loki-compatible push endpoint under a given
#          tenant.
# Requires env: LOKI_PUSH_URL
# Optional env: PROMTAIL_VERSION, CLUSTER_NAME, CONTAINER_ROOT
# Usage: ./promtail-k8s-daemonset.sh <tenant-id> [<namespace>] | kubectl apply -f -
#   e.g. LOKI_PUSH_URL=https://loki.example.internal/loki/api/v1/push \
#          ./promtail-k8s-daemonset.sh my-tenant kube-system | kubectl apply -f -
#
# Note: this migrates `promtail_script.sh` from the source onboarding
# scripts, which renders a cluster-wide Promtail DaemonSet. It is a
# different deployment target from `promtail-systemd-install.sh` (migrated
# from `promtail-agent.sh`), which installs the Promtail *binary* via
# systemd for one log path on a single VM/bare-metal host — the two were
# not duplicates of each other, so both are kept. See this folder's README
# for the full comparison.
#
# The source script also hardcoded a `hostAliases` block pinning several
# internal hostnames to internal IPs, as a DNS workaround specific to that
# environment's network. That has no public equivalent and isn't something
# a generic Kubernetes cluster needs (your cluster's own DNS/egress should
# resolve LOKI_PUSH_URL normally), so it has been dropped rather than
# parameterized.
# ------------------------------------------------------------
set -euo pipefail

TENANT_ID="${1:?set tenant-id}"
K8S_NAMESPACE="${2:-kube-system}"

: "${LOKI_PUSH_URL:?set LOKI_PUSH_URL, e.g. https://loki.example.internal/loki/api/v1/push}"

# Image tag mirrors the Promtail release version (no "v" prefix on Docker
# Hub, unlike the GitHub release tag used in promtail-systemd-install.sh).
PROMTAIL_VERSION="${PROMTAIL_VERSION:-2.9.9}"
CLUSTER_NAME="${CLUSTER_NAME:-my-cluster}"
CONTAINER_ROOT="${CONTAINER_ROOT:-/var/log/pods}"
# Alternate CONTAINER_ROOT values seen in the wild, depending on container
# runtime / kubelet log driver:
#   /var/lib/docker/containers
#   /app/data/docker-images/containers

TEMPLATE=$(cat <<'YAML'
apiVersion: v1
data:
  promtail.yml: |
    scrape_configs:
    - job_name: kubernetes-pods-name
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - source_labels:
        - __meta_kubernetes_pod_label_name
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ^$
        source_labels:
        - __service__
      - action: replace
        replacement: $1
        separator: /
        source_labels:
        - __meta_kubernetes_namespace
        - __service__
        target_label: job
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: node_name
      - replacement: /var/log/pods/*$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_uid
        - __meta_kubernetes_pod_container_name
        target_label: __path__
    - job_name: kubernetes-pods-app
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - action: drop
        regex: .+
        source_labels:
        - __meta_kubernetes_pod_label_name
      - source_labels:
        - __meta_kubernetes_pod_label_app
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ^$
        source_labels:
        - __service__
      - action: replace
        replacement: $1
        separator: /
        source_labels:
        - __meta_kubernetes_namespace
        - __service__
        target_label: job
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: node_name
      - replacement: /var/log/pods/*$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_uid
        - __meta_kubernetes_pod_container_name
        target_label: __path__
    - job_name: kubernetes-pods-direct-controllers
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - action: drop
        regex: .+
        separator: ''
        source_labels:
        - __meta_kubernetes_pod_label_name
        - __meta_kubernetes_pod_label_app
      - action: drop
        regex: ^([0-9a-z-.]+)(-[0-9a-f]{8,10})$
        source_labels:
        - __meta_kubernetes_pod_controller_name
      - source_labels:
        - __meta_kubernetes_pod_controller_name
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ^$
        source_labels:
        - __service__
      - action: replace
        replacement: $1
        separator: /
        source_labels:
        - __meta_kubernetes_namespace
        - __service__
        target_label: job
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: node_name
      - replacement: /var/log/pods/*$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_uid
        - __meta_kubernetes_pod_container_name
        target_label: __path__
    - job_name: kubernetes-pods-indirect-controller
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - action: drop
        regex: .+
        separator: ''
        source_labels:
        - __meta_kubernetes_pod_label_name
        - __meta_kubernetes_pod_label_app
      - action: keep
        regex: ^([0-9a-z-.]+)(-[0-9a-f]{8,10})$
        source_labels:
        - __meta_kubernetes_pod_controller_name
      - action: replace
        regex: ^([0-9a-z-.]+)(-[0-9a-f]{8,10})$
        source_labels:
        - __meta_kubernetes_pod_controller_name
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ^$
        source_labels:
        - __service__
      - action: replace
        replacement: $1
        separator: /
        source_labels:
        - __meta_kubernetes_namespace
        - __service__
        target_label: job
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: node_name
      - replacement: /var/log/pods/*$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_uid
        - __meta_kubernetes_pod_container_name
        target_label: __path__
    - job_name: kubernetes-pods-static
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - action: drop
        regex: ^$
        source_labels:
        - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_label_component
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ^$
        source_labels:
        - __service__
      - action: replace
        replacement: $1
        separator: /
        source_labels:
        - __meta_kubernetes_namespace
        - __service__
        target_label: job
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: node_name
      - replacement: /var/log/pods/*$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
        - __meta_kubernetes_pod_container_name
        target_label: __path__
    - job_name: kubernetes-pods-logs-labeling
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - action: drop
        regex: ^$
        source_labels:
        - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_label_component
        target_label: __service__
      - source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: __host__
      - action: drop
        regex: ^$
        source_labels:
        - __service__
      - action: replace
        replacement: $1
        separator: /
        source_labels:
        - __meta_kubernetes_namespace
        - __service__
        target_label: job
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_container_name
        target_label: container
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: node_name
      - replacement: /var/log/pods/*$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
        - __meta_kubernetes_pod_container_name
        target_label: __path__
    clients:
      - url: <LOKI_PUSH_URL>
        tenant_id: <TENANT_ID>
        external_labels:
          cluster_name: <CLUSTER_NAME>
kind: ConfigMap
metadata:
  name: promtail-<K8S_NAMESPACE>
  namespace: <K8S_NAMESPACE>
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail-<K8S_NAMESPACE>
  namespace: <K8S_NAMESPACE>
spec:
  minReadySeconds: 10
  selector:
    matchLabels:
      name: promtail-<K8S_NAMESPACE>
  template:
    metadata:
      labels:
        name: promtail-<K8S_NAMESPACE>
    spec:
      containers:
      - args:
        - -config.file=/etc/promtail/promtail.yml
        env:
        - name: HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        image: grafana/promtail:<PROMTAIL_VERSION>
        imagePullPolicy: Always
        name: promtail-<K8S_NAMESPACE>
        readinessProbe:
          httpGet:
            path: /ready
            port: http-metrics
            scheme: HTTP
          initialDelaySeconds: 10
        ports:
        - containerPort: 80
          name: http-metrics
        securityContext:
          runAsUser: 0
        volumeMounts:
        - mountPath: /etc/promtail
          name: promtail
        - mountPath: <CONTAINER_ROOT>
          name: varlibdockercontainers
          readOnly: true
      serviceAccount: promtail-<K8S_NAMESPACE>
      tolerations:
      - effect: NoSchedule
        operator: Exists
      volumes:
      - configMap:
          name: promtail-<K8S_NAMESPACE>
        name: promtail
      - hostPath:
          path: <CONTAINER_ROOT>
        name: varlibdockercontainers
  updateStrategy:
    type: RollingUpdate
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: promtail-<K8S_NAMESPACE>
  namespace: <K8S_NAMESPACE>
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: promtail-<K8S_NAMESPACE>
  namespace: <K8S_NAMESPACE>
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
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: promtail-<K8S_NAMESPACE>
  namespace: <K8S_NAMESPACE>
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: promtail-<K8S_NAMESPACE>
subjects:
- kind: ServiceAccount
  name: promtail-<K8S_NAMESPACE>
  namespace: <K8S_NAMESPACE>
YAML
)

echo "${TEMPLATE}" | sed \
  -e "s#<TENANT_ID>#${TENANT_ID}#g" \
  -e "s#<LOKI_PUSH_URL>#${LOKI_PUSH_URL}#g" \
  -e "s#<K8S_NAMESPACE>#${K8S_NAMESPACE}#g" \
  -e "s#<CONTAINER_ROOT>#${CONTAINER_ROOT}#g" \
  -e "s#<CLUSTER_NAME>#${CLUSTER_NAME}#g" \
  -e "s#<PROMTAIL_VERSION>#${PROMTAIL_VERSION}#g"
