#!/usr/bin/env bash
# Install OpenMeter and its development dependencies (ClickHouse, Kafka,
# PostgreSQL, Redis) into the cluster.
#
# The OpenMeter project has no chart repository, so the chart is installed from
# a clone of github.com/openmeterio/openmeter.

set -euo pipefail

NAMESPACE="${NAMESPACE:-metering}"
CHART_REPO="${CHART_REPO:-/tmp/openmeter}"
VALUES_FILE="$(dirname "$0")/../deploy/openmeter/values-openshift.yaml"

if [[ ! -d "${CHART_REPO}/deploy/charts/openmeter" ]]; then
  git clone https://github.com/openmeterio/openmeter.git "${CHART_REPO}"
fi

oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || oc new-project "${NAMESPACE}"

# Undo the post-install patches below if a previous run applied them. Helm
# cannot merge a list whose map key (containerPort) we changed, so the live
# objects must match the chart output before the upgrade.
if oc get deploy openmeter-api -n "${NAMESPACE}" >/dev/null 2>&1; then
  oc patch deploy openmeter-api -n "${NAMESPACE}" --type json -p '[
    {"op":"replace","path":"/spec/template/spec/containers/0/args/1","value":"0.0.0.0:80"},
    {"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":80}
  ]' >/dev/null || true
  # The service keeps port 6443 (from values); normalise it to a single
  # chart-shaped port so helm can merge the list cleanly.
  oc patch svc openmeter-api -n "${NAMESPACE}" --type merge \
    -p '{"spec":{"ports":[{"name":"http","port":6443,"protocol":"TCP","targetPort":"http"}]}}' >/dev/null || true
fi

helm upgrade --install openmeter "${CHART_REPO}/deploy/charts/openmeter" \
  --namespace "${NAMESPACE}" \
  --dependency-update \
  --server-side=false \
  --values "${VALUES_FILE}" \
  --timeout 15m

# --- Post-install fixes -----------------------------------------------------
# These are not expressible through chart values, and a helm upgrade reverts
# them, so this script always re-applies them.

# 1. The chart hardcodes a postgres URL without sslmode; Bitnami postgres has
#    TLS disabled, so lib/pq fails with "SSL is not enabled on the server".
#    Rewrite only the URL line so the rest of the rendered config is preserved.
cfg="$(oc get configmap openmeter -n "${NAMESPACE}" -o jsonpath='{.data.config\.yaml}')"
cfg="${cfg/application@openmeter-postgres:5432\/application/application@openmeter-postgres:5432\/application?sslmode=disable}"
oc patch configmap openmeter -n "${NAMESPACE}" --type merge \
  -p "$(jq -n --arg c "${cfg}" '{data:{"config.yaml":$c}}')"

# 2. The chart hardcodes the API listen address and container port to 80, which
#    the OpenShift restricted SCC cannot bind (even with NET_BIND_SERVICE). Port
#    6443 is used instead: it is unprivileged for the SCC and is one of the few
#    non-DNS egress ports the MaaS gateway NetworkPolicy allows.
#    The service port (6443) comes from deploy/openmeter/values-openshift.yaml.
oc patch deploy openmeter-api -n "${NAMESPACE}" --type json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/args/1","value":"0.0.0.0:6443"},
  {"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":6443}
]'

# 3. Expose the API with an edge route so it is reachable from outside the
#    cluster. The route targets the service port by name.
if oc get route openmeter-api -n "${NAMESPACE}" >/dev/null 2>&1; then
  oc patch route openmeter-api -n "${NAMESPACE}" --type merge \
    -p '{"spec":{"port":{"targetPort":"http"},"tls":{"termination":"edge","insecureEdgeTerminationPolicy":"None"}}}'
else
  oc create route edge openmeter-api -n "${NAMESPACE}" \
    --service openmeter-api --port http
fi

# 4. The billing CronJobs run an openmeter-jobs binary that does not exist in
#    the image; billing is unused in this PoC.
oc get cronjobs -n "${NAMESPACE}" -o name | xargs -r -n1 oc patch -n "${NAMESPACE}" --type merge -p '{"spec":{"suspend":true}}'

oc rollout status deploy/openmeter-api -n "${NAMESPACE}" --timeout=180s || true

oc get pods -n "${NAMESPACE}"
echo
echo "OpenMeter API: http://openmeter-api.${NAMESPACE}.svc.cluster.local"
