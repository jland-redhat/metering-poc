#!/usr/bin/env bash
# Install Grafana with the Infinity datasource into the `metering` namespace,
# provisioned against the in-cluster OpenMeter API.
#
#   scripts/install-grafana.sh
#
# Creates the admin password Secret, the provisioning and dashboard
# ConfigMaps, then applies deploy/grafana/grafana.yaml (Deployment, Service,
# Route). Idempotent: re-running keeps the existing admin password.
set -euo pipefail

NAMESPACE="${NAMESPACE:-metering}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_JSON="$REPO_ROOT/deploy/grafana/dashboard-openmeter.json"

oc get namespace "$NAMESPACE" >/dev/null

# Admin password: generate once, reuse on later runs.
if oc get secret grafana-admin -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Secret grafana-admin already exists, keeping its password"
else
  PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  oc create secret generic grafana-admin -n "$NAMESPACE" \
    --from-literal=password="$PASSWORD"
fi

# Provisioning (datasource + dashboard provider).
oc apply -f "$REPO_ROOT/deploy/grafana/provisioning.yaml"

# Dashboard: generated from the JSON so the file stays valid, standalone JSON.
oc create configmap grafana-dashboard-openmeter -n "$NAMESPACE" \
  --from-file=openmeter-usage.json="$DASHBOARD_JSON" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f "$REPO_ROOT/deploy/grafana/grafana.yaml"

echo "Waiting for rollout (Infinity plugin downloads from grafana.com at startup)..."
oc rollout status deploy/grafana -n "$NAMESPACE" --timeout=300s

echo
echo "Grafana URL: https://$(oc get route grafana -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
echo "Anonymous viewer access is enabled. Admin login is user 'admin'; read the"
echo "password with:"
echo "  oc get secret grafana-admin -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
