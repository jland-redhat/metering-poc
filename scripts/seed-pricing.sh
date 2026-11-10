#!/usr/bin/env bash
# Seed OpenMeter with per-token-type, per-model pricing.
#
# Creates:
#   - meters tokens_prompt / tokens_completion (SUM over the
#     inference.tokens.used event, grouped by model)
#   - one feature per (token type, model) pair, each bound to its meter via
#     meterGroupByFilters so only that model's usage counts
#   - plan inference_payg with four usage_based rate cards (unit prices)
#   - a subscription for the given customer key on that plan
#
# Rates (USD per token):
#   facebook/opt-125m  prompt $0.001  completion $0.002
#   Qwen/Qwen3-0.6B    prompt $0.005  completion $0.010
#
# Usage:
#   ./scripts/seed-pricing.sh --customer <customer-key>
#
# Idempotent-ish: duplicate creates return 4xx and are reported, not fatal.
# Note: the plan is published on first run; re-running the publish step on an
# already-published plan returns an error that can be ignored.

set -euo pipefail

NAMESPACE="${NAMESPACE:-metering}"
LOCAL_PORT="${LOCAL_PORT:-48889}"
CUSTOMER_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer) CUSTOMER_KEY="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${CUSTOMER_KEY}" ]]; then
  echo "usage: $0 --customer <customer-key>" >&2
  exit 2
fi

API="http://127.0.0.1:${LOCAL_PORT}"
PF_LOG="$(mktemp)"

# Service port is 6443 (see deploy/openmeter/values-openshift.yaml).
oc port-forward -n "${NAMESPACE}" svc/openmeter-api "${LOCAL_PORT}:6443" >"${PF_LOG}" 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true; rm -f "${PF_LOG}"' EXIT

for _ in $(seq 1 30); do
  if curl -fsS "${API}/api/v1/meters" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

request() {
  local method="$1" path="$2" body="$3"
  local code
  code=$(curl -sS -o /tmp/openmeter-pricing-response.json -w '%{http_code}' \
    -X "${method}" "${API}${path}" -H 'Content-Type: application/json' -d "${body}")
  echo "${method} ${path} -> ${code}"
  if [[ "${code}" != 2* ]]; then
    cat /tmp/openmeter-pricing-response.json
    echo
  fi
}

echo "Creating meters tokens_prompt / tokens_completion (groupBy model)"
request POST /api/v1/meters '{
  "slug": "tokens_prompt",
  "name": "Prompt tokens",
  "description": "Prompt tokens reported by the AI gateway",
  "aggregation": "SUM",
  "eventType": "inference.tokens.used",
  "valueProperty": "$.prompt_tokens",
  "groupBy": { "model": "$.model" }
}'
request POST /api/v1/meters '{
  "slug": "tokens_completion",
  "name": "Completion tokens",
  "description": "Completion tokens reported by the AI gateway",
  "aggregation": "SUM",
  "eventType": "inference.tokens.used",
  "valueProperty": "$.completion_tokens",
  "groupBy": { "model": "$.model" }
}'

echo "Creating features (one per token type and model)"
feature() {
  request POST /api/v1/features "{
    \"key\": \"$1\",
    \"name\": \"$2\",
    \"meterSlug\": \"$3\",
    \"meterGroupByFilters\": { \"model\": \"$4\" }
  }"
}
feature prompt_opt125m     "Prompt tokens opt-125m"     tokens_prompt     "facebook/opt-125m"
feature prompt_qwen3       "Prompt tokens Qwen3-0.6B"   tokens_prompt     "Qwen/Qwen3-0.6B"
feature completion_opt125m "Completion tokens opt-125m" tokens_completion "facebook/opt-125m"
feature completion_qwen3   "Completion tokens Qwen3-0.6B" tokens_completion "Qwen/Qwen3-0.6B"

echo "Creating plan inference_payg"
PLAN_ID=$(request POST /api/v1/plans '{
  "key": "inference_payg",
  "name": "Inference pay-as-you-go",
  "currency": "USD",
  "phases": [{
    "key": "standard",
    "name": "Standard",
    "duration": null,
    "rateCards": [
      { "type": "usage_based", "key": "prompt_opt125m", "name": "Prompt tokens (opt-125m)", "featureKey": "prompt_opt125m", "billingCadence": "P1M", "price": { "type": "unit", "amount": "0.001" } },
      { "type": "usage_based", "key": "prompt_qwen3", "name": "Prompt tokens (Qwen3-0.6B)", "featureKey": "prompt_qwen3", "billingCadence": "P1M", "price": { "type": "unit", "amount": "0.005" } },
      { "type": "usage_based", "key": "completion_opt125m", "name": "Completion tokens (opt-125m)", "featureKey": "completion_opt125m", "billingCadence": "P1M", "price": { "type": "unit", "amount": "0.002" } },
      { "type": "usage_based", "key": "completion_qwen3", "name": "Completion tokens (Qwen3-0.6B)", "featureKey": "completion_qwen3", "billingCadence": "P1M", "price": { "type": "unit", "amount": "0.010" } }
    ]
  }]
}' | tail -1 | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

if [[ -z "${PLAN_ID}" ]]; then
  # Plan may already exist from a previous run; look it up.
  PLAN_ID=$(curl -fsS "${API}/api/v1/plans" \
    | tr ',' '\n' | grep -m1 '"key":"inference_payg"' >/dev/null \
    && curl -fsS "${API}/api/v1/plans" \
    | sed -n 's/.*{"alignment[^{]*"id":"\([^"]*\)","key":"inference_payg".*/\1/p')
fi

echo "Publishing plan ${PLAN_ID}"
request POST "/api/v1/plans/${PLAN_ID}/publish" '{}'

echo "Creating subscription for ${CUSTOMER_KEY}"
request POST /api/v1/subscriptions "{
  \"plan\": { \"key\": \"inference_payg\" },
  \"customerKey\": \"${CUSTOMER_KEY}\"
}"

echo
echo "Per-model usage so far:"
curl -fsS "${API}/api/v1/meters/tokens_prompt/query?from=$(date -u +%Y-%m-01T00:00:00Z)&to=$(date -u +%Y-%m-%dT23:59:59Z)&groupBy=subject&groupBy=model"
echo
curl -fsS "${API}/api/v1/meters/tokens_completion/query?from=$(date -u +%Y-%m-01T00:00:00Z)&to=$(date -u +%Y-%m-%dT23:59:59Z)&groupBy=subject&groupBy=model"
echo
echo "Note: automatic invoice generation requires the openmeter-jobs binary,"
echo "which the v1.0.0-beta.213 image does not ship (chart bug); see"
echo "deploy/openmeter/values-openshift.yaml billingWorker note."
