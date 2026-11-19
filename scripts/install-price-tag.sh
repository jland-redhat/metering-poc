#!/usr/bin/env bash
# Install the Price Tag metering service (PoC) into the "metering" namespace.
#
# Deploys PostgreSQL + the price-tag service (image quay.io/maas/price-tag,
# built from the vendored pricetag-metering source on the ai-gateway-controller
# pricetag-poc branch). The service is not exposed via a Route; admin and seed
# access goes through `oc port-forward` (see set-price-tag-budget.sh).
#
# Usage: ./scripts/install-price-tag.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-metering}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

oc get ns "${NAMESPACE}" >/dev/null 2>&1 || oc create ns "${NAMESPACE}"

oc apply -f "${SCRIPT_DIR}/../deploy/price-tag/postgres.yaml"
oc apply -f "${SCRIPT_DIR}/../deploy/price-tag/price-tag.yaml"

oc rollout status "deployment/price-tag-postgres" -n "${NAMESPACE}" --timeout=180s
oc rollout status "deployment/price-tag" -n "${NAMESPACE}" --timeout=300s

echo "Price Tag installed in namespace ${NAMESPACE}"
echo "Service: http://price-tag.${NAMESPACE}.svc.cluster.local:6443"
echo "Point the gateway at it with:"
echo "  ./scripts/enable-maas-metering.sh --url http://price-tag.${NAMESPACE}.svc.cluster.local:6443 --feature inference_tokens"
