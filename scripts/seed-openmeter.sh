#!/usr/bin/env bash
# Seed OpenMeter with the meter, feature, customer and entitlement that the
# MaaS external_metering filter expects.
#
# Usage:
#   ./scripts/seed-openmeter.sh --user <maas-username> [--grant 100000]
#
# The username becomes the OpenMeter customer key and subject key, so it must
# match OpenMeter's key regex ^[a-z0-9]+(?:_[a-z0-9]+)*$ (no hyphens or
# uppercase). The script port-forwards the OpenMeter API from the cluster, so
# it only needs a valid oc session. It is idempotent: existing resources cause
# a warning instead of a failure.

set -euo pipefail

NAMESPACE="${NAMESPACE:-metering}"
LOCAL_PORT="${LOCAL_PORT:-48888}"
USER_NAME=""
GRANT="${TOKEN_GRANT:-100000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --grant) GRANT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${USER_NAME}" ]]; then
  echo "usage: $0 --user <maas-username> [--grant <tokens>]" >&2
  exit 2
fi

if [[ ! "${USER_NAME}" =~ ^[a-z0-9]+(_[a-z0-9]+)*$ ]]; then
  echo "username '${USER_NAME}' is not a valid OpenMeter key" >&2
  echo "it must match ^[a-z0-9]+(?:_[a-z0-9]+)*\$ (lowercase, digits, underscores)" >&2
  exit 2
fi

API="http://127.0.0.1:${LOCAL_PORT}"
PF_LOG="$(mktemp)"

# The service port is 6443 (see deploy/openmeter/values-openshift.yaml); port 80
# is not served by this deployment.
oc port-forward -n "${NAMESPACE}" svc/openmeter-api "${LOCAL_PORT}:6443" >"${PF_LOG}" 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true; rm -f "${PF_LOG}"' EXIT

for _ in $(seq 1 30); do
  if curl -fsS "${API}/api/v1/meters" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

post() {
  local path="$1" body="$2"
  local code
  code=$(curl -sS -o /tmp/openmeter-seed-response.json -w '%{http_code}' \
    -X POST "${API}${path}" -H 'Content-Type: application/json' -d "${body}")
  if [[ "${code}" != 2* ]]; then
    echo "POST ${path} returned ${code}: $(cat /tmp/openmeter-seed-response.json)" >&2
    return 1
  fi
  cat /tmp/openmeter-seed-response.json
  echo
}

echo "Creating meter tokens_total"
post /api/v1/meters '{
  "slug": "tokens_total",
  "name": "Inference tokens",
  "description": "Total tokens reported by the AI gateway",
  "aggregation": "SUM",
  "eventType": "inference.tokens.used",
  "valueProperty": "$.total_tokens"
}' || true

echo "Creating feature inference_tokens"
post /api/v1/features '{
  "key": "inference_tokens",
  "name": "Inference tokens",
  "meterSlug": "tokens_total"
}' || true

echo "Creating customer ${USER_NAME}"
post /api/v1/customers "{
  \"name\": \"${USER_NAME}\",
  \"key\": \"${USER_NAME}\",
  \"usageAttribution\": { \"subjectKeys\": [\"${USER_NAME}\"] }
}" || true

echo "Creating metered entitlement for ${USER_NAME} (grant ${GRANT})"
# Entitlements are created under the subject rather than the customer path in
# v1.0.0-beta.213 (the customer entitlement routes return 404).
post "/api/v1/subjects/${USER_NAME}/entitlements" "{
  \"type\": \"metered\",
  \"featureKey\": \"inference_tokens\",
  \"usagePeriod\": { \"interval\": \"MONTH\" },
  \"issueAfterReset\": ${GRANT}
}" || true

echo "Entitlement value:"
curl -fsS "${API}/api/v1/meters/tokens_total/query?from=$(date -u +%Y-%m-01T00:00:00Z)&to=$(date -u +%Y-%m-%dT23:59:59Z)&groupBy=subject" || true
echo
