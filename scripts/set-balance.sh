#!/usr/bin/env bash
# Set a MaaS user's OpenMeter budget for the demo.
#
# Usage:
#   ./scripts/set-balance.sh
#   ./scripts/set-balance.sh --user cluster_admin --tokens 50
#   ./scripts/set-balance.sh --user cluster_admin --dollars 25.00
#
# The script ensures the customer, meter, feature and metered entitlement exist,
# then replaces the subject's entitlement with one that issues the requested
# grant, and resets its usage period as of now. The reset is what zeroes the
# usage already counted in the month, so the value endpoint reports
# balance == the grant and hasAccess == true right after the run.
#
# Token mode uses the inference_tokens feature (tokens_total meter). Dollar
# mode uses the inference_cost feature (cost_usd meter), which counts the cost
# field that the metering relay adds to each gateway event.
#
# It port-forwards svc/openmeter-api, so it only needs a valid oc session.

set -euo pipefail

NAMESPACE="${NAMESPACE:-metering}"
LOCAL_PORT="${LOCAL_PORT:-48888}"
USER_NAME="${USER_NAME:-cluster_admin}"
TOKENS="${TOKENS:-50}"
MODE="tokens"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --tokens) TOKENS="$2"; MODE="tokens"; shift 2 ;;
    --dollars) TOKENS="$2"; MODE="dollars"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --local-port) LOCAL_PORT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "${MODE}" == "dollars" ]]; then
  FEATURE_KEY="inference_cost"
  METER_SLUG="cost_usd"
  METER_JSON='{
  "slug": "cost_usd",
  "name": "Inference cost",
  "description": "Priced cost in USD of each gateway request",
  "aggregation": "SUM",
  "eventType": "inference.tokens.used",
  "valueProperty": "$.cost"
}'
  FEATURE_JSON="{
  \"key\": \"${FEATURE_KEY}\",
  \"name\": \"Inference cost (USD)\",
  \"meterSlug\": \"cost_usd\"
}"
  if [[ ! "${TOKENS}" =~ ^[0-9]+([.][0-9]+)?$ || "${TOKENS}" =~ ^0+([.]0+)?$ ]]; then
    echo "--dollars must be a positive number" >&2
    exit 2
  fi
else
  FEATURE_KEY="inference_tokens"
  METER_SLUG="tokens_total"
  METER_JSON='{
  "slug": "tokens_total",
  "name": "Inference tokens",
  "description": "Total tokens reported by the AI gateway",
  "aggregation": "SUM",
  "eventType": "inference.tokens.used",
  "valueProperty": "$.total_tokens"
}'
  FEATURE_JSON="{
  \"key\": \"${FEATURE_KEY}\",
  \"name\": \"Inference tokens\",
  \"meterSlug\": \"tokens_total\"
}"
  if [[ ! "${TOKENS}" =~ ^[0-9]+$ || "${TOKENS}" -eq 0 ]]; then
    echo "--tokens must be a positive integer" >&2
    exit 2
  fi
fi

if [[ ! "${USER_NAME}" =~ ^[a-z0-9]+(_[a-z0-9]+)*$ ]]; then
  echo "username '${USER_NAME}' is not a valid OpenMeter key" >&2
  echo "it must match ^[a-z0-9]+(?:_[a-z0-9]+)*\$ (lowercase, digits, underscores)" >&2
  exit 2
fi

API="http://127.0.0.1:${LOCAL_PORT}"
PF_LOG="$(mktemp)"
RESP_FILE="$(mktemp)"
PF_PID=""

cleanup() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" 2>/dev/null || true
  fi
  rm -f "${PF_LOG}" "${RESP_FILE}"
}
trap cleanup EXIT

oc port-forward -n "${NAMESPACE}" svc/openmeter-api "${LOCAL_PORT}:6443" >"${PF_LOG}" 2>&1 &
PF_PID=$!

for _ in $(seq 1 30); do
  if curl -fsS "${API}/api/v1/meters" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "${API}/api/v1/meters" >/dev/null 2>&1; then
  echo "OpenMeter API did not become reachable on ${API}" >&2
  cat "${PF_LOG}" >&2
  exit 1
fi

request() {
  # request METHOD PATH [BODY] -> prints body; fails on non-2xx
  local method="$1" path="$2" body="${3:-}"
  local code
  if [[ -n "${body}" ]]; then
    code=$(curl -sS -o "${RESP_FILE}" -w '%{http_code}' -X "${method}" \
      "${API}${path}" -H 'Content-Type: application/json' -d "${body}")
  else
    code=$(curl -sS -o "${RESP_FILE}" -w '%{http_code}' -X "${method}" "${API}${path}")
  fi
  if [[ "${code}" != 2* ]]; then
    echo "${method} ${path} returned ${code}: $(cat "${RESP_FILE}")" >&2
    return 1
  fi
  cat "${RESP_FILE}"
}

# Meter and feature are idempotent prerequisites; ignore "already exists".
curl -sS -o /dev/null -X POST "${API}/api/v1/meters" -H 'Content-Type: application/json' -d "${METER_JSON}" || true
curl -sS -o /dev/null -X POST "${API}/api/v1/features" -H 'Content-Type: application/json' -d "${FEATURE_JSON}" || true

# Customer must exist before the entitlement. 404 means create it.
CUSTOMER_CODE=$(curl -sS -o "${RESP_FILE}" -w '%{http_code}' "${API}/api/v1/customers/${USER_NAME}")
if [[ "${CUSTOMER_CODE}" == "404" ]]; then
  echo "Creating customer ${USER_NAME}"
  request POST /api/v1/customers "{
    \"name\": \"${USER_NAME}\",
    \"key\": \"${USER_NAME}\",
    \"usageAttribution\": { \"subjectKeys\": [\"${USER_NAME}\"] }
  }" >/dev/null
elif [[ "${CUSTOMER_CODE}" != 2* ]]; then
  echo "GET customer returned ${CUSTOMER_CODE}: $(cat "${RESP_FILE}")" >&2
  exit 1
fi

# Drop any existing entitlement for this feature. There is no PATCH, and a
# second metered entitlement for the same feature would make the value lookup
# ambiguous.
EXISTING_IDS=$(request GET "/api/v1/subjects/${USER_NAME}/entitlements" \
  | python3 -I -c 'import json,sys
for e in json.load(sys.stdin):
    if e.get("featureKey") == sys.argv[1]:
        print(e["id"])' "${FEATURE_KEY}")
for id in ${EXISTING_IDS}; do
  echo "Deleting entitlement ${id}"
  request DELETE "/api/v1/subjects/${USER_NAME}/entitlements/${id}" >/dev/null
done

if [[ "${MODE}" == "dollars" ]]; then
  echo "Creating entitlement for ${USER_NAME} with balance \$${TOKENS}"
else
  echo "Creating entitlement for ${USER_NAME} with balance ${TOKENS} tokens"
fi
request POST "/api/v1/subjects/${USER_NAME}/entitlements" "{
  \"type\": \"metered\",
  \"featureKey\": \"${FEATURE_KEY}\",
  \"usagePeriod\": { \"interval\": \"MONTH\" },
  \"issueAfterReset\": ${TOKENS}
}" >/dev/null

# A new entitlement keeps the month's usage anchor, so tokens already burned
# this month still count against the fresh grant. Reset the usage period to now
# so the grant is actually available.
NEW_ID=$(request GET "/api/v1/subjects/${USER_NAME}/entitlements" \
  | python3 -I -c 'import json,sys
for e in json.load(sys.stdin):
    if e.get("featureKey") == sys.argv[1]:
        print(e["id"])' "${FEATURE_KEY}")
EFFECTIVE_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
request POST "/api/v1/subjects/${USER_NAME}/entitlements/${NEW_ID}/reset" \
  "{\"effectiveAt\":\"${EFFECTIVE_AT}\"}" >/dev/null

VALUE=$(request GET "/api/v1/subjects/${USER_NAME}/entitlements/${FEATURE_KEY}/value")

echo
echo "subject: ${USER_NAME}"
echo "${VALUE}" | python3 -I -c 'import json, sys
v = json.load(sys.stdin)
for k in ("balance", "usage", "overage", "hasAccess"):
    print("%-10s %s" % (k + ":", v.get(k)))'
