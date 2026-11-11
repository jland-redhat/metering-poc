#!/usr/bin/env bash
# Add the external_metering filter to the MaaS gateway ExtProc chain.
#
# Envoy on the maas-default-gateway calls the ExtProc service in
# openshift-ingress (deployment payload-processing), which reads its chains
# from the payload-processing-plugins ConfigMap. That chain sees the x-maas-*
# identity headers injected by Authorino; the models-as-a-service
# payload-processing-external-model ExtProc serves provider-side traffic
# instead.
#
# The ai-gateway-controller renders this ConfigMap from its own templates and
# resyncs it every --resync-interval (default 5m). The script sets
#
#   opendatahub.io/managed: "false"
#
# on both the ConfigMap and the ExtProc Deployment so maas-controller skips
# these praxis resources. ai-gateway-controller (commit e9723ca) still
# re-renders them on resync, so the injection remains temporary and this
# script must be re-run after a reconcile.
#
# Usage:
#   ./scripts/enable-maas-metering.sh [--url http://openmeter-metering-proxy.metering.svc.cluster.local:6443]
#                                     [--feature inference_tokens]
#                                     [--chain post-auth] [--key extproc.yaml]
#                                     [--namespace models-as-a-service]
#                                     [--configmap payload-processing-external-model-plugins]
#                                     [--deployment payload-processing-external-model]
#                                     [--default-username openclaw_app]
#
# Model calls are handled by the payload-processing-external-model ExtProc in
# models-as-a-service, chain "post-auth". That is the chain that has the
# provider credentials and sees the model response:
#   ./scripts/enable-maas-metering.sh \
#     --namespace models-as-a-service \
#     --configmap payload-processing-external-model-plugins \
#     --deployment payload-processing-external-model \
#     --chain post-auth

set -euo pipefail

NAMESPACE="${NAMESPACE:-openshift-ingress}"
CONFIGMAP="${CONFIGMAP:-payload-processing-plugins}"
DEPLOYMENT="${DEPLOYMENT:-payload-processing}"
CHAIN_NAME="${CHAIN_NAME:-ipp}"
CONFIG_KEY="${CONFIG_KEY:-extproc.yaml}"
# Port 6443, not 80/443: the payload-processing NetworkPolicy only allows DNS
# and TCP 443/6443 egress, and OVN applies the policy after service DNAT, so
# port 80 would be blocked once translated to the pod port.
METERING_URL="${METERING_URL:-http://openmeter-api.metering.svc.cluster.local:6443}"
FEATURE_KEY="${FEATURE_KEY:-inference_tokens}"
SOURCE_NAME="${SOURCE_NAME:-maas-gateway}"
# Used when no identity header is available to the filter. The ipp chain never
# sees the x-maas-* headers (see ADR 0001), so this value is what gateway
# traffic is metered as. Must satisfy the OpenMeter customer-key regex
# ^[a-z0-9]+(?:_[a-z0-9]+)*$ (no hyphens).
DEFAULT_USERNAME="${DEFAULT_USERNAME:-openclaw_app}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) METERING_URL="$2"; shift 2 ;;
    --feature) FEATURE_KEY="$2"; shift 2 ;;
    --chain) CHAIN_NAME="$2"; shift 2 ;;
    --key) CONFIG_KEY="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --configmap) CONFIGMAP="$2"; shift 2 ;;
    --deployment) DEPLOYMENT="$2"; shift 2 ;;
    --default-username) DEFAULT_USERNAME="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# pre-extproc.yaml is served by payload-pre-processing; extproc.yaml by
# payload-processing.
case "${CONFIG_KEY}" in
  pre-*) DEPLOYMENT="payload-pre-processing" ;;
  *) DEPLOYMENT="${DEPLOYMENT}" ;;
esac

# Tell the ai-gateway-controller to leave both objects alone. Without this the
# next reconcile restores its template and drops the injected filter.
oc annotate configmap "${CONFIGMAP}" -n "${NAMESPACE}" \
  opendatahub.io/managed=false --overwrite
oc annotate deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
  opendatahub.io/managed=false --overwrite

oc get configmap "${CONFIGMAP}" -n "${NAMESPACE}" \
  -o jsonpath="{.data.${CONFIG_KEY//./\\.}}" > "${WORKDIR}/${CONFIG_KEY}"

METERING_URL="${METERING_URL}" FEATURE_KEY="${FEATURE_KEY}" SOURCE_NAME="${SOURCE_NAME}" \
CHAIN_NAME="${CHAIN_NAME}" DEFAULT_USERNAME="${DEFAULT_USERNAME}" \
python3 - "${WORKDIR}/${CONFIG_KEY}" > "${WORKDIR}/extproc-metered.yaml" <<'PY'
import os
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()

chain_name = os.environ["CHAIN_NAME"]
try:
    chain = next(i for i, line in enumerate(lines) if line.strip() == f"- name: {chain_name}")
except StopIteration:
    sys.exit(f"{chain_name} filter chain not found in extproc.yaml")

try:
    filters = next(i for i in range(chain, len(lines)) if lines[i].strip() == "filters:")
except StopIteration:
    sys.exit("filters key not found under post-auth")

indent = " " * (len(lines[filters]) - len(lines[filters].lstrip()) + 2)

# Drop a previously injected block so re-runs are idempotent and update the
# metering URL instead of leaving a stale one behind. The block is the
# external_metering item plus every following line indented deeper than it.
start = None
for i in range(filters + 1, len(lines)):
    if lines[i].strip() == "- filter: external_metering":
        start = i
        break
if start is not None:
    item_indent = len(lines[start]) - len(lines[start].lstrip())
    end = start + 1
    while end < len(lines):
        stripped = lines[end].strip()
        if stripped and (len(lines[end]) - len(lines[end].lstrip())) <= item_indent:
            break
        end += 1
    del lines[start:end]

# token_count parses the provider response and publishes token.input/output/
# total in filter_metadata; external_metering reads those during its response
# phase. Without it every usage event reports zero tokens.
has_token_count = any(line.strip() == "- filter: token_count" for line in lines)

block = [
    f"{indent}- filter: external_metering",
    f"{indent}  metering_url: \"{os.environ['METERING_URL']}\"",
    f"{indent}  allow_private_endpoint: true",
    f"{indent}  timeout_seconds: 5",
    f"{indent}  feature_key: \"{os.environ['FEATURE_KEY']}\"",
    f"{indent}  source: \"{os.environ['SOURCE_NAME']}\"",
    f"{indent}  fail_open: true",
    f"{indent}  identity_header_prefix: \"x-maas-\"",
    f"{indent}  default_username: \"{os.environ['DEFAULT_USERNAME']}\"",
    f"{indent}  default_model: \"unknown\"",
]
if not has_token_count:
    block += [
        f"{indent}- filter: token_count",
        f"{indent}  provider: openai",
    ]

out = lines[: filters + 1] + block + lines[filters + 1 :]
if not out[-1]:
    out.pop()
print("\n".join(out))
PY

python3 - "${WORKDIR}/extproc-metered.yaml" "${CONFIG_KEY}" > "${WORKDIR}/patch.json" <<'PY'
import json
import sys

key = sys.argv[2]
updated = open(sys.argv[1], encoding="utf-8").read()
print(json.dumps({"data": {key: updated}}))
PY

oc patch configmap "${CONFIGMAP}" -n "${NAMESPACE}" --type merge -p "$(cat "${WORKDIR}/patch.json")"

oc rollout restart "deployment/${DEPLOYMENT}" -n "${NAMESPACE}"
oc rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=180s

echo "external_metering enabled on ${CONFIG_KEY} (${CHAIN_NAME}); metering_url=${METERING_URL} feature=${FEATURE_KEY}"
