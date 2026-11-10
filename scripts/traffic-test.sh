#!/usr/bin/env bash
# Burn a subject's budget through the MaaS gateway and show the HTTP status
# code of every call.
#
# Usage:
#   ./scripts/traffic-test.sh
#   ./scripts/traffic-test.sh --count 20 --max-tokens 64
#   ./scripts/traffic-test.sh --model publishers/llm/models/facebook/opt-125m
#
# The loop records the HTTP status of every call and stops at the first 402 or
# 429 by default. Both mean an admission filter rejected the request: the
# external_metering balance check returns 429 when the entitlement's
# hasAccess is false, whether the budget is tokens or dollars. The feature the
# check reads is the filter's feature_key (see enable-maas-metering.sh
# --feature). Without that filter installed, calls keep returning 200 and the
# script reports "all calls admitted".
#
# Identity comes from MAAS_API_KEY when set, otherwise from `oc whoami -t`.
# The username the gateway meters against comes from the request headers
# (x-maas-username or the authenticated user), so run it as the same user whose
# balance you set with set-balance.sh.

set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-https://maas.apps.jland-odh-nt-c-pool-zgvss.aws.rh-ods.com}"
MODEL="${MODEL:-publishers/llm/models/facebook/opt-125m}"
COUNT="${COUNT:-10}"
MAX_TOKENS="${MAX_TOKENS:-16}"
DELAY_SECS="${DELAY_SECS:-0.3}"
PROMPT="${PROMPT:-Hello}"
STOP_ON_EXHAUSTED=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    --delay) DELAY_SECS="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --keep-going) STOP_ON_EXHAUSTED=0; shift ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! "${COUNT}" =~ ^[0-9]+$ || "${COUNT}" -eq 0 ]]; then
  echo "--count must be a positive integer" >&2
  exit 2
fi

if [[ -z "${MAAS_API_KEY:-}" ]]; then
  MAAS_API_KEY="$(oc whoami -t)"
fi

PAYLOAD=$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%d}' \
  "${MODEL}" "${PROMPT}" "${MAX_TOKENS}")
URL="${GATEWAY_URL%/}/v1/chat/completions"

echo "gateway: ${GATEWAY_URL}"
echo "model:   ${MODEL}"
echo "count:   ${COUNT} (max_tokens ${MAX_TOKENS})"
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
  elif [[ "${CODE}" == "402" || "${CODE}" == "429" ]]; then
    exhausted_count=$((exhausted_count + 1))
  else
    fail_count=$((fail_count + 1))
  fi

  printf '%-4s %-6s %8s %8s %8s | %8s %8s\n' \
    "${i}" "${CODE}" "${prompt_t}" "${compl_t}" "${total_t}" "${sum_prompt}" "${sum_completion}"

  if [[ "${CODE}" == "402" || "${CODE}" == "429" ]]; then
    echo "  body: $(printf '%s' "${BODY}" | head -c 200)"
  fi

  if [[ ( "${CODE}" == "402" || "${CODE}" == "429" ) && "${STOP_ON_EXHAUSTED}" -eq 1 ]]; then
    echo
    echo "balance exhausted at request ${i} - gateway returned HTTP ${CODE}"
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
  echo "Outcome: HTTP 402/429 observed - Admission Hook rejected the request."
elif [[ "${ok_count}" -eq 0 ]]; then
  echo "Outcome: no successful calls." >&2
  exit 1
else
  echo "Outcome: all calls admitted. Balance not exhausted; raise --count or lower the balance with set-balance.sh."
fi
