# First run: MaaS gateway metering to OpenMeter

Date: 2026-11-09
Cluster: `jland-odh-nt-c-pool-zgvss` (AWS, OpenShift)
Gateway host: `maas.apps.jland-odh-nt-c-pool-zgvss.aws.rh-ods.com`

This is a chronological record of the first end-to-end attempt, including the
dead ends, so the next run does not repeat them. All resources were created in
the `metering` namespace. Nothing in the existing MaaS installation was
replaced or deleted.

## 1. Reconnaissance

- Confirmed cluster access with `oc whoami`, `oc whoami --show-server`,
  `oc get nodes`, `oc get ns`.
- Confirmed the MaaS installation exists: `models-as-a-service` namespace,
  gateway `maas-default-gateway`, AuthPolicy `maas-gateway-auth` in
  `openshift-ingress`, model `publishers/llm/models/facebook/opt-125m`.
- Found two ExtProc deployments:
  - `models-as-a-service/payload-processing-external-model` — has a plugins
    ConfigMap `payload-processing-external-model-plugins`, but this is not on
    the client request path.
  - `openshift-ingress/payload-processing` — uses ConfigMap
    `payload-processing-plugins`, filter chain `ipp`. This is the active path.
- Confirmed the deployed image is `quay.io/opendatahub/odh-praxis-extproc` and
  already contains the `external_metering` and `token_count` filters, so no
  custom image build was needed.
- Read the Rust filter source in `praxis-proxy-ai` to learn the config keys and
  the OpenMeter endpoints and payloads the filter uses.

## 2. OpenMeter install

The project publishes no Helm repository (`helm repo add openmeter ...`
returned 404 on every candidate URL), so the chart was installed from the
source tree:

```bash
git clone --depth 1 https://github.com/openmeterio/openmeter.git /tmp/openmeter
helm upgrade --install openmeter /tmp/openmeter/deploy/charts/openmeter \
  --namespace metering \
  --values deploy/openmeter/values-openshift.yaml \
  --timeout 15m
```

Chart version: `1.0.0-beta.213`. It bundles Altinity ClickHouse operator,
Bitnami Kafka, Bitnami PostgreSQL and Bitnami Redis.

Problems hit, in order:

1. Bitnami subcharts failed on OpenShift security context. Fixed with
   `global.compatibility.openshift.adaptSecurityContext: force`, plus `anyuid`
   for the namespace service accounts.
2. PostgreSQL user/database mismatch. The chart generates a `postgres://application:application@...`
   URL but the bundled PostgreSQL only created the `openmeter` database. The
   API crash-looped. Worked around by forcing `?sslmode=disable` in the
   connection URL; the chart's default template did not include it.
3. The API container listens on `:80`, which the restricted SCC cannot bind.
   Tried `8080`, then `443` with `NET_BIND_SERVICE`; 443 still failed under
   `restricted-v2`. Settled on `6443`, patched in the install script:
   - Deployment arg `0.0.0.0:6443`, container port 6443
   - Service port 6443
   - Edge route `openmeter-api` targeting the `http` port
4. Billing worker crash-loops because the image does not contain
   `openmeter-billing-worker` or `openmeter-jobs`. Set `billingWorker.replicaCount: 0`
   and suspended the billing CronJobs.

## 3. API shape

- The beta serves `/api/v1` only. `/api/v2` routes return 404.
- Entitlements are created under the subject:
  `POST /api/v1/subjects/{subject}/entitlements`. The customer entitlement
  routes return 404.
- OpenMeter keys must match `^[a-z0-9]+(?:_[a-z0-9]+)*$`. The OpenShift user
  `htpasswd-cluster-admin-user` was rejected because of hyphens; the PoC uses
  `cluster_admin`.

Seed script created:

- meter `tokens_total`, event type `inference.tokens.used`, `SUM` on
  `$.total_tokens`
- feature `inference_tokens`
- customer/subject `cluster_admin`
- metered entitlement with monthly period and grant 100000

## 4. Gateway filter wiring

First attempts put `external_metering` into the wrong ConfigMap
(`models-as-a-service/payload-processing-external-model-plugins`). Requests
were admitted but no event was reported; that ExtProc is not in the client
path.

The active ConfigMap is `openshift-ingress/payload-processing-plugins`. The
filter must be first in the `ipp` chain, before the `headers` filter, because
`headers` strips the `x-maas-*` headers.

### Controller reconciliation

`ai-gateway-controller` in `redhat-ods-applications` owns both the ConfigMap
and the Deployment through server-side apply. Manual edits were reverted in
under a minute (managedFields showed the controller as manager). The working
procedure is:

```bash
oc patch cm payload-processing-plugins -n openshift-ingress --type merge -p ...
oc rollout restart deploy/payload-processing -n openshift-ingress
oc rollout status deploy/payload-processing -n openshift-ingress --timeout=180s
```

The ConfigMap can be reverted later, but the running pod keeps the config it
started with. `scripts/enable-maas-metering.sh` encapsulates this.

### URL and egress

- The `payload-processing` NetworkPolicy allows egress only to DNS and TCP
  443/6443. OVN applies policy after service DNAT, so plain HTTP to the service
  on port 6443 works; port 80 and 8080 did not.
- Tried the edge route over HTTPS first. The router certificate for the
  wildcard apps domain is self-signed, and the filter's HTTP client is built at
  startup with a fixed root store and then cached, so TLS verification failed
  and `SSL_CERT_FILE` plus a mounted CA did not help. Reverted to the in-cluster
  plain-HTTP service URL: `http://openmeter-api.metering.svc.cluster.local:6443`.
- Changing `metering_url` requires an ExtProc restart even though the config
  file hot-reloads, because the client is cached.

### Identity

The x-maas headers injected by Authorino are not visible to this ExtProc, so
`default_username` is required. Value must satisfy the OpenMeter key regex;
`cluster_admin` is used.

## 5. Events accepted but never stored

The gateway logged `metering usage report sent status=204`, the ingest API
returned 204, but `/api/v1/events` stayed empty and the sink worker logged
nothing.

A typed probe event proved the pipeline:

```bash
curl -X POST "$H/api/v1/events" -H 'Content-Type: application/cloudevents+json' \
  -d '{"specversion":"1.0","id":"probe3-...","source":"probe","type":"inference.tokens.used","subject":"clusteradmin","time":"...","data":{"total_tokens":42}}'
```

It was stored and the meter aggregated 42, so the sink worker was only failing
for gateway events. Root cause found in the Kafka broker log:

```
CreateTopics result(s): CreatableTopic(name='__consumer_offsets' ...)
INVALID_REPLICATION_FACTOR (Unable to replicate the partition 3 time(s):
... only 1 broker(s) are registered.)
```

Bitnami defaults to replication factor 3; a single broker can never satisfy
it, so `__consumer_offsets` was never created, no consumer group formed, and
the sink worker silently ingested nothing. The earlier probe succeeded only
because it used a different code path.

Fix, in `deploy/openmeter/values-openshift.yaml`:

```yaml
kafka:
  extraConfigYaml:
    offsets.topic.replication.factor: 1
    transaction.state.log.replication.factor: 1
    transaction.state.log.min.isr: 1
    default.replication.factor: 1
```

After the broker rolled, the sink worker briefly saw connection errors while
the broker pod IP changed, then logged a partition assignment for
`om_default_events-0` and ingestion worked.

## 6. Zero token counts

Events now appeared but every `total_tokens` was 0. The `external_metering`
filter reads token counts from filter metadata written by the `token_count`
filter (`token.input`, `token.output`, `token.total`, `token.cache_read`,
`token.cache_write`). Without `token_count` in the chain the metadata is
absent and the filter reports zeros.

Added:

```yaml
- filter: token_count
  provider: openai
```

Result: non-streaming request reported 11 prompt + 3 completion = 14 total;
the meter aggregated it under `cluster_admin`. Streaming requests also produced
non-zero counts.

## 7. Balance check and enforcement

- With no entitlement the balance preflight returns 404 and `fail_open` admits
  the request.
- Created a subject entitlement, then set the grant to 1 and sent a request:
  the gateway rejected it with HTTP 429 `token budget exhausted`.
- Restored the grant to 100000.

## 8. Final state

- Gateway request returns HTTP 200.
- ExtProc logs `metering usage report sent status=204`.
- OpenMeter has the event (`cluster_admin`, non-zero tokens) and the meter
  `tokens_total` shows the accumulated value.
- Over-grant requests are rejected with HTTP 429.

## 9. Cleanup

- Removed the debug `RUST_LOG` environment and the router-CA volume/mount from
  the `payload-processing` Deployment.
- Deleted temporary ConfigMaps `payload-processing-plugins-metered` and
  `openshift-router-ca` in `openshift-ingress`.
- Verified `payload-processing-external-model-plugins` has no stray
  `external_metering` block.

Leftover: the test entitlement for subject `quota_test` (grant 5) is still in
OpenMeter. Harmless, and can be deleted through the API.

## 10. Known limitations

- The ConfigMap injection is not durable. `ai-gateway-controller` reverts it;
  re-run `scripts/enable-maas-metering.sh` after gateway or tenant changes. A
  supported extension point is needed for a durable fix.
- OpenMeter ingest is asynchronous; usage can take a few seconds to show up.
- The bundled Kafka/PostgreSQL/Redis/ClickHouse setup is single-node and not
  production-grade. This PoC validates the gateway-to-meter path only.
