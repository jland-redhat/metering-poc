#!/usr/bin/env bash
# Burn a subject's budget through the MaaS gateway and show the HTTP status
# code of every call.
#
# Usage:
#   ./scripts/traffic-test.sh
#   ./scripts/traffic-test.sh --use-me
#   ./scripts/traffic-test.sh --count 20 --max-tokens 64
#   ./scripts/traffic-test.sh --model publishers/llm/models/facebook/opt-125m
#   ./scripts/traffic-test.sh --username openclaw_app --service-account openclaw-app
#
# Identity: by default the script mints a short-lived token for the
# ServiceAccount "openclaw-app" in models-as-a-service with
#
#   oc create token openclaw-app -n models-as-a-service --duration=1h
#
# and meters the traffic as the OpenMeter subject "openclaw_app" by sending
# x-maas-username: openclaw_app on every call. Set --username to change the
# subject, --service-account to use another ServiceAccount, or MAAS_API_KEY to
# skip token minting and use a fixed bearer token.
#
# --use-me switches identity to the current oc user instead: the bearer token
# comes from `oc whoami -t`, and the subject defaults to `oc whoami` normalized
# to an OpenMeter key (lowercase, digits, underscores). Pass --username to
# override the subject. The gateway meters as that header value, so set its
# balance with set-balance.sh.
#
# The loop records the HTTP status of every call and stops at the first 402 by
# default. A 402 means the admission filter rejected the request: the
# external_metering balance check found hasAccess false, whether the budget is
# tokens or dollars, and the gateway rewrites that reply to 402. A bare 429 is
# rate limiting, not budget exhaustion. The feature the
# check reads is the filter's feature_key (see enable-maas-metering.sh
# --feature). Without that filter installed, calls keep returning 200 and the
# script reports "all calls admitted".
#
# The gateway meters as --username, so set that subject's balance with
# set-balance.sh before running.

set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-https://maas.apps.jland-odh-nt-c-pool-zgvss.aws.rh-ods.com}"
MODEL="${MODEL:-publishers/llm/models/facebook/opt-125m}"
COUNT="${COUNT:-10}"
MAX_TOKENS="${MAX_TOKENS:-16}"
DELAY_SECS="${DELAY_SECS:-0.3}"
PROMPT="${PROMPT:-Hello}"
STOP_ON_EXHAUSTED=1
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-openclaw-app}"
SERVICE_ACCOUNT_NAMESPACE="${SERVICE_ACCOUNT_NAMESPACE:-models-as-a-service}"
MAAS_USERNAME="${MAAS_USERNAME:-}"
USE_ME=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    --delay) DELAY_SECS="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --username) MAAS_USERNAME="$2"; shift 2 ;;
    --service-account) SERVICE_ACCOUNT="$2"; shift 2 ;;
    --service-account-namespace) SERVICE_ACCOUNT_NAMESPACE="$2"; shift 2 ;;
    --use-me) USE_ME=1; shift ;;
    --keep-going) STOP_ON_EXHAUSTED=0; shift ;;
    -h|--help)
      awk 'NR==1{next} /^set -euo pipefail/{exit} {sub(/^# ?/,""); print}' "$0"
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! "${COUNT}" =~ ^[0-9]+$ || "${COUNT}" -eq 0 ]]; then
  echo "--count must be a positive integer" >&2
  exit 2
fi

openmeter_key() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}

if [[ "${USE_ME}" -eq 1 ]]; then
  OC_USER="$(oc whoami 2>/dev/null || true)"
  if [[ -z "${OC_USER}" ]]; then
    echo "--use-me requires an active oc session (oc whoami failed)" >&2
    exit 1
  fi
  if [[ -z "${MAAS_USERNAME}" ]]; then
    MAAS_USERNAME="$(openmeter_key "${OC_USER}")"
    echo "using oc user ${OC_USER} as OpenMeter subject ${MAAS_USERNAME}" >&2
  fi
  if [[ -z "${MAAS_API_KEY:-}" ]]; then
    if ! MAAS_API_KEY="$(oc whoami -t 2>/dev/null)"; then
      echo "--use-me cannot read a token from oc whoami -t; log in again" >&2
      exit 1
    fi
  fi
else
  MAAS_USERNAME="${MAAS_USERNAME:-openclaw_app}"
  if [[ -z "${MAAS_API_KEY:-}" ]]; then
    if ! MAAS_API_KEY="$(oc create token "${SERVICE_ACCOUNT}" \
        -n "${SERVICE_ACCOUNT_NAMESPACE}" --duration=1h 2>/dev/null)"; then
      echo "cannot mint token for ServiceAccount ${SERVICE_ACCOUNT} in ${SERVICE_ACCOUNT_NAMESPACE}; falling back to oc whoami -t" >&2
      MAAS_API_KEY="$(oc whoami -t)"
    fi
  fi
fi

if [[ ! "${MAAS_USERNAME}" =~ ^[a-z0-9]+(_[a-z0-9]+)*$ ]]; then
  echo "subject '${MAAS_USERNAME}' is not a valid OpenMeter key" >&2
  echo "it must match ^[a-z0-9]+(?:_[a-z0-9]+)*\$; pass --username with a valid key" >&2
  exit 2
fi

PAYLOAD=$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%d}' \
  "${MODEL}" "${PROMPT}" "${MAX_TOKENS}")
URL="${GATEWAY_URL%/}/v1/chat/completions"

echo "gateway:  ${GATEWAY_URL}"
echo "model:    ${MODEL}"
echo "username: ${MAAS_USERNAME}"
echo "count:    ${COUNT} (max_tokens ${MAX_TOKENS})"
echo

sum_prompt=0
sum_completion=0
ok_count=0
exhausted_count=0
fail_count=0

printf '%-4s %-6s %8s %8s %8s | %8s %8s\n' \
  '#' 'HTTP' 'prompt' 'compl' 'total' 'Σprompt' 'Σcompl'
printf '%s\n' '----------------------------------------------------------------'

for i in $(seq 1 "${COUNT}"); do
  RESP=$(curl -skS --connect-timeout 10 --max-time 120 -w '\n%{http_code}' \
    -X POST "${URL}" \
    -H "Authorization: Bearer ${MAAS_API_KEY}" \
    -H "x-maas-username: ${MAAS_USERNAME}" \
    -H 'Content-Type: application/json' \
    -d "${PAYLOAD}" 2>/dev/null || printf '\n000')
  BODY=$(printf '%s' "${RESP}" | sed '$d')
  CODE=$(printf '%s' "${RESP}" | tail -n1)

  prompt_t=0
  compl_t=0
  total_t=0

  if [[ "${CODE}" == "200" ]]; then
    ok_count=$((ok_count + 1))
    read -r prompt_t compl_t total_t <<<"$(printf '%s' "${BODY}" | python3 -I -c 'import json,sys
try:
    u = json.load(sys.stdin).get("usage") or {}
except Exception:
    u = {}
p = u.get("prompt_tokens", u.get("input_tokens", 0)) or 0
c = u.get("completion_tokens", u.get("output_tokens", 0)) or 0
t = u.get("total_tokens", p + c) or 0
print(int(p), int(c), int(t))' 2>/dev/null || echo '0 0 0')"
    sum_prompt=$((sum_prompt + prompt_t))
    sum_completion=$((sum_completion + compl_t))
  elif [[ "${CODE}" == "402" ]]; then
    exhausted_count=$((exhausted_count + 1))
  else
    fail_count=$((fail_count + 1))
  fi

  printf '%-4s %-6s %8s %8s %8s | %8s %8s\n' \
    "${i}" "${CODE}" "${prompt_t}" "${compl_t}" "${total_t}" "${sum_prompt}" "${sum_completion}"

  if [[ "${CODE}" == "402" || "${CODE}" == "429" ]]; then
    echo "  body: $(printf '%s' "${BODY}" | head -c 200)"
  fi

  if [[ "${CODE}" == "402" && "${STOP_ON_EXHAUSTED}" -eq 1 ]]; then
    echo
    echo "balance exhausted at request ${i} - gateway returned HTTP 402"
    break
  fi

  if [[ "${i}" -lt "${COUNT}" ]]; then
    sleep "${DELAY_SECS}"
  fi
done

echo
echo "summary: ok=${ok_count} exhausted=${exhausted_count} other=${fail_count}"
echo "tokens:  prompt=${sum_prompt} completion=${sum_completion} total=$((sum_prompt + sum_completion))"

if [[ "${exhausted_count}" -gt 0 ]]; then
  echo "Outcome: HTTP 402 observed - Admission Hook rejected the request."
elif [[ "${ok_count}" -eq 0 ]]; then
  echo "Outcome: no successful calls." >&2
  exit 1
else
  echo "Outcome: all calls admitted. Balance not exhausted; raise --count or lower the balance with set-balance.sh."
fi
