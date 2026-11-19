#!/usr/bin/env bash
# Read or set Price Tag budgets for the MaaS PoC.
#
# Usage:
#   ./scripts/set-price-tag-budget.sh                          # show policy
#   ./scripts/set-price-tag-budget.sh --default 50             # default monthly USD, enforced
#   ./scripts/set-price-tag-budget.sh --default 50 --no-enforce
#   ./scripts/set-price-tag-budget.sh --user cluster_admin --usd 25
#   ./scripts/set-price-tag-budget.sh --user cluster_admin --usd 0   # exhaust a user
#
# The default (safety-net) budget goes through the admin API
# (PUT /api/v1/admin/safety-net) via port-forward. Price Tag has no HTTP
# route for per-user overrides yet, so --user writes the quota_overrides
# row directly in PostgreSQL (oc exec psql).
set -euo pipefail

NAMESPACE="${NAMESPACE:-metering}"
LOCAL_PORT="${LOCAL_PORT:-48889}"
POSTGRES_DEPLOYMENT="${POSTGRES_DEPLOYMENT:-price-tag-postgres}"

API="http://127.0.0.1:${LOCAL_PORT}"

PORT_FORWARD_PID=""
cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then kill "${PORT_FORWARD_PID}" 2>/dev/null || true; fi
}
trap cleanup EXIT

start_port_forward() {
  oc port-forward -n "${NAMESPACE}" "svc/price-tag" "${LOCAL_PORT}:6443" >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!
  for _ in $(seq 1 30); do
    curl -fsS "${API}/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "price-tag service did not become reachable on ${API}" >&2
  exit 1
}

DEFAULT_USD=""
ENFORCED=""
USER_NAME=""
USER_USD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --default) DEFAULT_USD="$2"; shift 2 ;;
    --enforce) ENFORCED="true"; shift ;;
    --no-enforce) ENFORCED="false"; shift ;;
    --user) USER_NAME="$2"; shift 2 ;;
    --usd) USER_USD="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${DEFAULT_USD}${ENFORCED}${USER_NAME}" ]]; then
  start_port_forward
  echo "Current safety-net policy:"
  curl -fsS "${API}/api/v1/admin/safety-net"
  echo
  echo "Current per-user overrides:"
  oc exec -n "${NAMESPACE}" "deploy/${POSTGRES_DEPLOYMENT}" -- \
    psql -U metering -d metering -c "SELECT scope, principal, monthly_usd, updated_by, updated_at FROM quota_overrides ORDER BY principal;"
  exit 0
fi

if [[ -n "${DEFAULT_USD}${ENFORCED}" ]]; then
  start_port_forward
  BODY="{"
  [[ -n "${DEFAULT_USD}" ]] && BODY+="\"default_monthly_usd\": ${DEFAULT_USD}, "
  [[ -n "${ENFORCED}" ]] && BODY+="\"enforced\": ${ENFORCED}, "
  BODY="${BODY%, }}\""
  echo "Updating safety-net policy: ${BODY}"
  curl -fsS -X PUT "${API}/api/v1/admin/safety-net" \
    -H 'Content-Type: application/json' -d "${BODY}"
  echo
fi

if [[ -n "${USER_NAME}" ]]; then
  [[ -n "${USER_USD}" ]] || { echo "--user requires --usd" >&2; exit 2; }
  echo "Setting user ${USER_NAME} monthly budget to ${USER_USD} USD (direct DB write)"
  oc exec -n "${NAMESPACE}" "deploy/${POSTGRES_DEPLOYMENT}" -- \
    psql -U metering -d metering -c \
    "INSERT INTO quota_overrides (scope, principal, monthly_usd, updated_by)
     VALUES ('user', '${USER_NAME}', ${USER_USD}, 'metering-poc')
     ON CONFLICT (scope, principal)
     DO UPDATE SET monthly_usd = EXCLUDED.monthly_usd, updated_by = EXCLUDED.updated_by, updated_at = NOW();"
fi

echo "Done."
