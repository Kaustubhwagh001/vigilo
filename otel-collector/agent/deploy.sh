#!/usr/bin/env bash
# ------------------------------------------------------------
# vigilo — OTel Collector agent orchestrator
# Purpose: interactively onboard an application onto the per-app
#          OTel Collector + Elastic APM bridge, and apply both to
#          the cluster.
# Requires env (validated by the two scripts this calls, not here):
#               OTLP_HTTP_BACKEND_ENDPOINT, ELASTICSEARCH_URL,
#               ELASTICSEARCH_USERNAME, ELASTICSEARCH_PASSWORD
# Usage: ./deploy.sh <tenant-id>
# ------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TENANT_ID="${1:-default}"

echo "*** Use lowercase, no special characters — must comply with Kubernetes naming conventions ***"
read -rp "Enter application name: " APP_NAME
read -rp "Enter deployment namespace: " KUBE_NS
read -rp "Enter 1 for Deployment (dev/staging) or 2 for DaemonSet (prod): " MODE

case "$MODE" in
  1) DEPLOY_MODE=Deployment ;;
  2) DEPLOY_MODE=DaemonSet ;;
  *)
    echo "Unrecognized input — proceeding with Deployment"
    DEPLOY_MODE=Deployment
    ;;
esac

"${SCRIPT_DIR}/otel-collector-deploy.sh" "$APP_NAME" "$KUBE_NS" "$DEPLOY_MODE" | kubectl apply -f -
"${SCRIPT_DIR}/apm-server-deploy.sh" "$TENANT_ID" "$APP_NAME" "$KUBE_NS" | kubectl apply -f -

echo "Share with app devs — OTLP endpoint: http://otel-collector-${APP_NAME}.${KUBE_NS}.svc.cluster.local:4318"
