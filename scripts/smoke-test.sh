#!/usr/bin/env bash
# Send one inference request through the MaaS gateway and confirm that the
# external_metering filter reported the token usage to OpenMeter.
#
# Usage:
#   MAAS_API_KEY=<key> ./scripts/smoke-test.sh [--model publishers/llm/models/facebook/opt-125m]
#
# If MAAS_API_KEY is unset the script uses the current oc session token
# (oc whoami -t), which the gateway accepts for cluster users. Get a
# subscription key from maas-api (see the MaaS documentation) for a
# non-admin identity.

set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-https://maas.apps.jland-odh-nt-c-pool-zgvss.aws.rh-ods.com}"
MODEL="${MODEL:-publishers/llm/models/facebook/opt-125m}"
NAMESPACE="${NAMESPACE:-metering}"
LOCAL_PORT="${LOCAL_PORT:-48888}"
EXTPROC_NAMESPACE="${EXTPROC_NAMESPACE:-openshift-ingress}"
EXTPROC_DEPLOYMENT="${EXTPROC_DEPLOYMENT:-payload-processing}"

if [[ -z "${MAAS_API_KEY:-}" ]]; then
  MAAS_API_KEY="$(oc whoami -t)"
fi

FROM="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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

if [[ "${code}" != 2* ]]; then
  echo "request failed; metering is fail-open, so check the ExtProc logs" >&2
  oc logs -n "${EXTPROC_NAMESPACE}" "deploy/${EXTPROC_DEPLOYMENT}" --tail=50 || true
  exit 1
fi

PF_LOG="$(mktemp)"
# The service port is 6443 (see deploy/openmeter/values-openshift.yaml).
oc port-forward -n "${NAMESPACE}" svc/openmeter-api "${LOCAL_PORT}:6443" >"${PF_LOG}" 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true; rm -f "${PF_LOG}"' EXIT

for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${LOCAL_PORT}/api/v1/meters" >/dev/null 2>&1 && break
  sleep 1
done

echo "Querying events emitted by the gateway"
for _ in $(seq 1 20); do
  events=$(curl -fsS "http://127.0.0.1:${LOCAL_PORT}/api/v1/events?from=${FROM}&to=$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true)
  printf '%s' "${events}" | grep -q '"source":"maas-gateway"' && break
  sleep 2
done
printf '%s\n' "${events}"

echo "Querying meter tokens_total by subject"
for _ in $(seq 1 20); do
  result=$(curl -fsS "http://127.0.0.1:${LOCAL_PORT}/api/v1/meters/tokens_total/query?from=$(date -u +%Y-%m-%dT00:00:00Z)&to=$(date -u +%Y-%m-%dT23:59:59Z)&groupBy=subject" || true)
  printf '%s' "${result}" | grep -q '"value"' && break
  sleep 2
done
printf '%s\n' "${result}"

echo "ExtProc metering log lines:"
oc logs -n "${EXTPROC_NAMESPACE}" "deploy/${EXTPROC_DEPLOYMENT}" --tail=200 \
  | grep -i 'meter' || true
