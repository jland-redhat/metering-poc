#!/usr/bin/env bash
# Read or set Price Tag budgets for the MaaS PoC.
#
# Usage:
#   ./scripts/set-price-tag-budget.sh                          # show policy + overrides
#   ./scripts/set-price-tag-budget.sh --default 50             # default monthly USD (enforced stays as-is)
#   ./scripts/set-price-tag-budget.sh --default 50 --no-enforce
#   ./scripts/set-price-tag-budget.sh --enforce                # flip enforcement only
#   ./scripts/set-price-tag-budget.sh --user cluster_admin --usd 25
#   ./scripts/set-price-tag-budget.sh --user cluster_admin --usd 0   # exhaust a user
#
# Price Tag's admin HTTP API (/api/v1/admin/safety-net) is behind an OIDC
# session, which the PoC does not configure. All budget writes therefore go
# straight to PostgreSQL (oc exec psql) — the same rows the admin API writes:
# quota_policy (default monthly USD, enforced) and quota_overrides (per user).
set -euo pipefail

NAMESPACE="${NAMESPACE:-metering}"
POSTGRES_DEPLOYMENT="${POSTGRES_DEPLOYMENT:-price-tag-postgres}"

PSQL=(oc exec -n "${NAMESPACE}" "deploy/${POSTGRES_DEPLOYMENT}" -- psql -U metering -d metering)

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
  echo "Current safety-net policy (quota_policy):"
  "${PSQL[@]}" -c "SELECT default_monthly_usd, enforced, allowed_over_limit_models, updated_by, updated_at FROM quota_policy;"
  echo "Current per-user overrides (quota_overrides):"
  "${PSQL[@]}" -c "SELECT scope, principal, monthly_usd, updated_by, updated_at FROM quota_overrides ORDER BY principal;"
  exit 0
fi

if [[ -n "${DEFAULT_USD}${ENFORCED}" ]]; then
  SETS=()
  [[ -n "${DEFAULT_USD}" ]] && SETS+=("default_monthly_usd = ${DEFAULT_USD}")
  [[ -n "${ENFORCED}" ]] && SETS+=("enforced = ${ENFORCED}")
  JOINED="$(IFS=,; echo "${SETS[*]}")"
  echo "Updating quota_policy: ${JOINED} (updated_by=metering-poc)"
  "${PSQL[@]}" -c "UPDATE quota_policy SET ${JOINED}, updated_by = 'metering-poc', updated_at = NOW();"
fi

if [[ -n "${USER_NAME}" ]]; then
  [[ -n "${USER_USD}" ]] || { echo "--user requires --usd" >&2; exit 2; }
  echo "Setting user ${USER_NAME} monthly budget to ${USER_USD} USD"
  "${PSQL[@]}" -c "INSERT INTO quota_overrides (scope, principal, monthly_usd, updated_by)
     VALUES ('user', '${USER_NAME}', ${USER_USD}, 'metering-poc')
     ON CONFLICT (scope, principal)
     DO UPDATE SET monthly_usd = EXCLUDED.monthly_usd, updated_by = EXCLUDED.updated_by, updated_at = NOW();"
fi

echo "Done."
