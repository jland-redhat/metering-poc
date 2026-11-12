#!/usr/bin/env bash
# Repair the two recurring failures in this PoC:
#
#   1. The external_metering filter disappears from the payload-processing
#      ExtProc chain (ai-gateway-controller resync, or a pod restart after the
#      ConfigMap was reverted). Symptom: traffic is admitted, no usage events.
#   2. openmeter-sink-worker keeps logging "2/2 brokers are down" after a
#      Kafka restart and never consumes the backlog. Symptom: the relay
#      accepts events, OpenMeter/dashboard counts stay flat.
#
# The script only acts on faults it finds. It is safe to re-run.
#
# Usage:
#   ./scripts/fix-metering.sh
#   ./scripts/fix-metering.sh --scale-controller
#   ./scripts/fix-metering.sh --feature inference_tokens
#
# --scale-controller scales ai-gateway-controller to 0 replicas first, which
# stops the periodic re-render of payload-processing-plugins. Without it the
# script re-injects the filter but the controller may revert it again.
#
# Exit codes: 0 healthy or repaired, 1 nothing could be done (missing
# metering namespace or OpenMeter), 2 usage error.

set -euo pipefail

NAMESPACE="${NAMESPACE:-metering}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"
DEPLOYMENT="${DEPLOYMENT:-payload-processing}"
CONFIGMAP="${CONFIGMAP:-payload-processing-plugins}"
CONFIG_KEY="${CONFIG_KEY:-extproc.yaml}"
CHAIN_NAME="${CHAIN_NAME:-ipp}"
FEATURE_KEY="${FEATURE_KEY:-inference_cost}"
METERING_URL="${METERING_URL:-http://openmeter-metering-proxy.metering.svc.cluster.local:6443}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-redhat-ods-applications}"
CONTROLLER_DEPLOYMENT="${CONTROLLER_DEPLOYMENT:-ai-gateway-controller}"
SCALE_CONTROLLER=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scale-controller) SCALE_CONTROLLER=1; shift ;;
    --feature) FEATURE_KEY="$2"; shift 2 ;;
    --url) METERING_URL="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
ok() { printf 'ok    %s\n' "$*"; }
fix() { printf 'fix   %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*"; }

if ! oc whoami >/dev/null 2>&1; then
  echo "not logged in to a cluster; run 'oc login' first" >&2
  exit 1
fi

if ! oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "namespace ${NAMESPACE} does not exist." >&2
  echo "Nothing to repair: install OpenMeter on this cluster first." >&2
  echo "  ./scripts/install-openmeter.sh" >&2
  echo "  ./scripts/seed-pricing.sh --customer openclaw_app" >&2
  exit 1
fi

if ! oc get deployment openmeter-metering-proxy -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "openmeter-metering-proxy is missing in ${NAMESPACE}." >&2
  echo "Deploy the relay and editor first:" >&2
  echo "  (build the ui image, then) oc apply -f deploy/ui/ui.yaml" >&2
  exit 1
fi

say "== relay and OpenMeter =="
if oc exec -n "${NAMESPACE}" deploy/openmeter-price-editor -- \
    python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/healthz", timeout=5)' \
    >/dev/null 2>&1; then
  ok "metering relay answers /healthz"
else
  warn "metering relay health check failed; restarting"
  oc rollout restart "deploy/openmeter-price-editor" -n "${NAMESPACE}" >/dev/null
  oc rollout status "deploy/openmeter-price-editor" -n "${NAMESPACE}" --timeout=180s >/dev/null
  fix "restarted openmeter-price-editor"
fi

say "== ExtProc filter =="
filter_count() {
  local source="$1"
  if [[ "${source}" == "configmap" ]]; then
    oc get configmap "${CONFIGMAP}" -n "${GATEWAY_NAMESPACE}" \
      -o jsonpath="{.data.${CONFIG_KEY//./\\.}}" 2>/dev/null | grep -c 'external_metering' || true
  else
    oc exec "deploy/${DEPLOYMENT}" -n "${GATEWAY_NAMESPACE}" -- \
      cat "/etc/praxis/${CONFIG_KEY}" 2>/dev/null | grep -c 'external_metering' || true
  fi
}

if [[ "${SCALE_CONTROLLER}" -eq 1 ]]; then
  replicas=$(oc get deployment "${CONTROLLER_DEPLOYMENT}" -n "${CONTROLLER_NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  if [[ -z "${replicas}" ]]; then
    warn "${CONTROLLER_DEPLOYMENT} not found in ${CONTROLLER_NAMESPACE}; skipping"
  elif [[ "${replicas}" == "0" ]]; then
    ok "${CONTROLLER_DEPLOYMENT} already scaled to 0"
  else
    oc scale "deploy/${CONTROLLER_DEPLOYMENT}" -n "${CONTROLLER_NAMESPACE}" --replicas=0 >/dev/null
    oc rollout status "deploy/${CONTROLLER_DEPLOYMENT}" -n "${CONTROLLER_NAMESPACE}" --timeout=120s >/dev/null
    fix "scaled ${CONTROLLER_DEPLOYMENT} to 0 (stops the ConfigMap resync)"
  fi
fi

cm_filters=$(filter_count configmap)
if [[ "${cm_filters}" -eq 0 ]]; then
  fix "injecting external_metering into ${CONFIGMAP}/${CONFIG_KEY}"
  "${SCRIPT_DIR}/enable-maas-metering.sh" \
    --chain "${CHAIN_NAME}" --key "${CONFIG_KEY}" \
    --feature "${FEATURE_KEY}" --url "${METERING_URL}" | tail -3
  cm_filters=$(filter_count configmap)
fi

if [[ "${cm_filters}" -eq 0 ]]; then
  warn "could not inject external_metering into ${CONFIGMAP}"
else
  ok "${CONFIGMAP} has external_metering (feature ${FEATURE_KEY})"
fi

pod_filters=$(filter_count pod)
if [[ "${pod_filters}" -eq 0 ]]; then
  fix "restarting ${DEPLOYMENT} so it loads the injected config"
  oc rollout restart "deploy/${DEPLOYMENT}" -n "${GATEWAY_NAMESPACE}" >/dev/null
  oc rollout status "deploy/${DEPLOYMENT}" -n "${GATEWAY_NAMESPACE}" --timeout=180s >/dev/null
  pod_filters=$(filter_count pod)
fi

if [[ "${pod_filters}" -eq 0 ]]; then
  warn "${DEPLOYMENT} pod still has no external_metering; check its logs"
else
  ok "${DEPLOYMENT} pod loaded external_metering"
fi

say "== ingestion =="
sink_errors=$(oc logs deployment/openmeter-sink-worker -n "${NAMESPACE}" --since=2m 2>/dev/null \
  | grep -c 'brokers are down' || true)
if [[ "${sink_errors}" -gt 0 ]]; then
  fix "sink worker has stale Kafka connections; restarting it"
  oc rollout restart deploy/openmeter-sink-worker -n "${NAMESPACE}" >/dev/null
  oc rollout status deploy/openmeter-sink-worker -n "${NAMESPACE}" --timeout=180s >/dev/null
  ok "openmeter-sink-worker restarted"
else
  ok "openmeter-sink-worker has no recent broker errors"
fi

say
say "State:"
printf '  %-28s %s\n' "controller replicas" \
  "$(oc get deployment "${CONTROLLER_DEPLOYMENT}" -n "${CONTROLLER_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 'n/a')"
printf '  %-28s %s\n' "configmap filter" "${cm_filters}"
printf '  %-28s %s\n' "pod filter" "${pod_filters}"
printf '  %-28s %s\n' "sink broker errors (2m)" "${sink_errors}"
say
say "Verify with: ./scripts/traffic-test.sh --count 2"
say "Budget:      ./scripts/set-balance.sh --user openclaw_app --dollars 5"
