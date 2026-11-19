#!/usr/bin/env bash
# Send one inference request through the MaaS gateway and confirm Price Tag
# metered it and answers the entitlement check.
#
# Usage:
#   MAAS_API_KEY=<key> ./scripts/price-tag-smoke-test.sh [--model <model>] [--user <user>]
#
# If MAAS_API_KEY is unset the script uses the current oc session token.
# The entitlement check runs the same endpoint the gateway's
# external_metering / enmaas_policy filters consult.
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:?set GATEWAY_URL to the MaaS gateway base URL}"
MODEL="${MODEL:-publishers/llm/models/facebook/opt-125m}"
NAMESPACE="${NAMESPACE:-metering}"
LOCAL_PORT="${LOCAL_PORT:-48889}"
EXTPROC_NAMESPACE="${EXTPROC_NAMESPACE:-openshift-ingress}"
EXTPROC_DEPLOYMENT="${EXTPROC_DEPLOYMENT:-payload-processing}"

if [[ -z "${MAAS_API_KEY:-}" ]]; then
  MAAS_API_KEY="$(oc whoami -t)"
fi

USER_NAME="${USER_NAME:-cluster_admin}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --user) USER_NAME="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "Sending chat completion through MaaS"
response=$(curl -skS -w '\n%{http_code}' -X POST "${GATEWAY_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${MAAS_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in five words.\"}],
    \"max_tokens\": 32
  }")

body=$(printf '%s' "${response}" | head -n -1)
code=$(printf '%s' "${response}" | tail -n 1)
echo "Gateway returned HTTP ${code}"
printf '%s\n' "${body}" | head -c 2000
echo

if [[ "${code}" != 2* && "${code}" != "429" ]]; then
  echo "request failed; metering is fail-open, so check the ExtProc logs" >&2
  oc logs -n "${EXTPROC_NAMESPACE}" "deploy/${EXTPROC_DEPLOYMENT}" --tail=50 || true
  exit 1
fi

oc port-forward -n "${NAMESPACE}" svc/price-tag "${LOCAL_PORT}:6443" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${LOCAL_PORT}/health" >/dev/null 2>&1 && break
  sleep 1
done

echo "Waiting for the usage event to land"
sleep 3

echo "Price Tag month-to-date usage + admission decision for ${USER_NAME}:"
curl -fsS "http://127.0.0.1:${LOCAL_PORT}/api/v1/customers/${USER_NAME}/entitlements/inference_tokens/value" || true
echo

echo "Usage events in Price Tag (direct DB):"
oc exec -n "${NAMESPACE}" deploy/price-tag-postgres -- \
  psql -U metering -d metering -c \
  "SELECT username, model, prompt_tokens, completion_tokens, cost_usd, timestamp
     FROM usage_events ORDER BY timestamp DESC LIMIT 5;"
