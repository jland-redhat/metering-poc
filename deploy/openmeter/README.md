# OpenMeter on OpenShift

The OpenMeter project does not publish a Helm chart repository. The chart used
here lives in the source tree at `deploy/charts/openmeter` of
`github.com/openmeterio/openmeter` (chart version 1.0.0-beta.213 at the time of
writing). Clone the repository and install from that path.

The chart bundles every dependency it needs:

- Altinity ClickHouse operator (installed as a chart dependency)
- Kafka (Bitnami subchart)
- PostgreSQL (Bitnami subchart)
- Redis (Bitnami subchart)

On OpenShift the Bitnami subcharts need
`global.compatibility.openshift.adaptSecurityContext=force`, and the ClickHouse
operator and ClickHouse pods may require the `anyuid` SCC. The values file in
this directory sets the former and trims resource requests for a single-node
PoC.

## Install

```bash
git clone https://github.com/openmeterio/openmeter.git /tmp/openmeter
oc new-project metering

helm install openmeter /tmp/openmeter/deploy/charts/openmeter \
  --namespace metering \
  --dependency-update \
  --values deploy/openmeter/values-openshift.yaml \
  --timeout 15m
```

If pods fail to schedule with an SCC error, grant `anyuid` to the namespace's
service accounts and retry:

```bash
oc adm policy add-scc-to-group anyuid system:serviceaccounts:metering
```

Wait for the API and the workers:

```bash
oc get pods -n metering -w
oc get clickhouseinstallation -n metering -w
```

The API is exposed inside the cluster as
`http://openmeter-api.metering.svc.cluster.local:6443` and outside the cluster
through the edge route `openmeter-api` (targets the service port `http`, which
is 6443). Port 6443 is used because the OpenShift restricted SCC cannot bind 80
or 443, and 6443 is one of the few non-DNS egress ports allowed by the MaaS
gateway NetworkPolicy. The values file sets the service port; the install
script patches the Deployment's listen address and container port.

## Seed meters, features, customers and entitlements

Run `scripts/seed-openmeter.sh`. It creates:

- meter `tokens_total`, event type `inference.tokens.used`, `SUM` aggregation
  on `$.total_tokens`
- feature `inference_tokens` backed by that meter
- a customer keyed by the MaaS username
- a metered entitlement with a monthly usage period and a configurable initial
  grant (`TOKEN_GRANT`, default 100000), created under
  `/api/v1/subjects/{username}/entitlements` (the customer entitlement routes
  return 404 in `v1.0.0-beta.213`)

The username becomes the OpenMeter customer key and subject key, so it must
match `^[a-z0-9]+(?:_[a-z0-9]+)*$`. Hyphenated OpenShift usernames are
rejected; the PoC uses `cluster_admin`.

The `external_metering` filter performs a balance preflight before the request
and reports usage after the response. With an entitlement present the check
passes; with none it returns 404 and `fail_open` admits the request; when usage
exceeds the grant the filter rejects the request with HTTP 429
`token budget exhausted`.

Feature keys in OpenMeter may only contain lowercase alphanumerics and
underscores, so the feature is `inference_tokens`, not `inference-tokens`.

## Notes

- The bundled Bitnami Kafka defaults to a topic replication factor of 3, which a
  single broker cannot satisfy. Without the `kafka.extraConfigYaml` overrides in
  `values-openshift.yaml`, `__consumer_offsets` is never created, no consumer
  group forms, and the sink worker ingests nothing even though the ingest API
  returns 204.
- OpenMeter event ingest is asynchronous. Usage may take a few seconds to
  appear in entitlement balances.
- The image does not contain `openmeter-billing-worker` or `openmeter-jobs`, so
  billing is disabled and the billing CronJobs are suspended.
- The chart's bundled dependencies are not production-grade. This PoC is about
  validating the gateway-to-meter path, not the meter's own HA story.
