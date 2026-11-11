# metering-poc

Experimental proof-of-concept for AI Gateway / MaaS **usage metering talk-back**:

**Praxis** (token capture) → **CloudEvents** (GenAI-aligned) → **metering relay**
(optional, adds priced cost) → **OpenMeter** (pricing + entitlement) →
**price editor UI / Grafana** (budgets and spend).

This is **not** product code and is **not** a CI gate for [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service).

## Start here

- **[ADR 0001 — PoC plan](docs/adr/0001-metering-poc-openmeter-talkback.md)** — detailed architecture, Praxis evaluation gates, OpenMeter pricing model, talk-back contract, and phased delivery.
- **[ADR 0002 — Envoy budget filter](docs/adr/0002-envoy-budget-filter.md)** — proposed post-Kuadrant Envoy filter that returns 402 when the authenticated user is over budget. Design only; not implemented.
- **[Metering tenant setup](docs/metering-tenant-setup.md)** — expected customer, subscription, entitlements, models and prices for one tenant, plus the command sequence that reproduces them.

Product intent lives in `models-as-a-service` under `METERING_PROPOSAL/` (`overview.md`, `talkback.md`).

## Architecture

```mermaid
flowchart TB
  subgraph client["Clients and operators"]
    TT["traffic-test.sh<br/>smoke-test.sh<br/>curl"]
    BROWSER["Operator browser"]
  end

  subgraph ingress["openshift-ingress"]
    GW["Envoy<br/>maas-default-gateway"]
    AUTH["Kuadrant / Authorino<br/>authentication"]
    BUDGET["Custom Envoy budget filter<br/>ADR 0002 — proposed, not implemented"]
    EPP["Praxis ExtProc<br/>payload-processing, chain ipp<br/>external_metering + token_count"]
    ENABLE["enable-maas-metering.sh<br/>patches ConfigMap, restarts deployment"]
    GW -->|"ext_authz"| AUTH
    AUTH -->|"auth decision + identity headers"| GW
    GW -.->|"ADR 0002 future placement"| BUDGET
    BUDGET -.->|"402: You outta money fool!"| GW
    ENABLE -.->|"injects filters"| EPP
    GW --> EPP
  end

  subgraph maas["models-as-a-service"]
    SA["ServiceAccount<br/>openclaw-app"]
    MODEL["Model server<br/>facebook/opt-125m"]
  end

  subgraph meter["metering"]
    OM["OpenMeter API<br/>:6443"]
    RELAY["Metering relay<br/>openmeter-metering-proxy :6443<br/>prices usage events"]
    UI["Price editor UI<br/>openmeter-price-editor :8080<br/>plans, budgets, enforcement"]
    KAFKA["Kafka"]
    SINK["Sink worker"]
    CH[("ClickHouse<br/>usage events")]
    PG[("PostgreSQL<br/>customers, entitlements")]
    REDIS[("Redis")]
    GRAF["Grafana<br/>Infinity datasource"]
    SCRIPTS["seed-openmeter.sh<br/>seed-pricing.sh<br/>set-balance.sh"]
  end

  TT -->|"Bearer token + x-maas-username"| GW
  SA -.->|"oc create token"| TT
  BROWSER -->|"HTTPS route"| UI
  EPP -->|"proxied inference request"| MODEL
  MODEL -->|"response + usage"| EPP
  EPP -->|"balance check + usage report<br/>metering_url"| RELAY
  EPP -.->|"token-only mode:<br/>direct metering_url"| OM
  RELAY -->|"priced CloudEvent<br/>with data.cost"| OM
  RELAY -->|"passthrough OpenMeter calls"| OM
  UI -->|"plan versions, budgets, usage"| OM
  UI -->|"enforcement toggle"| RELAY
  OM --> KAFKA
  KAFKA --> SINK
  SINK --> CH
  OM --- PG
  OM --- REDIS
  GRAF -->|"REST API queries"| OM
  SCRIPTS -->|"meters, features, plans,<br/>customers, entitlements"| OM
```

The inference path is client → Envoy gateway → Praxis ExtProc → model. The
ExtProc's `external_metering` filter checks the subject's entitlement before the
call and emits a CloudEvent after the response; `token_count` supplies the usage
numbers. For token-only metering, `metering_url` points directly at OpenMeter.
For dollar budgets it points at the metering relay instead: the relay prices
each CloudEvent from the active plan's rate cards (`data.cost`) and forwards it,
and passes the balance check and every other OpenMeter call through unchanged.
The same Flask image runs the price editor UI, which edits plan rate cards,
sets budgets, and toggles enforcement.

OpenMeter stores events through Kafka into ClickHouse and keeps customers and
entitlements in PostgreSQL. Grafana and the price editor query the OpenMeter
REST API; the editor also talks to the relay for the enforcement switch. The
dashed budget-filter path is the ADR 0002 proposal and is not deployed.

## Status

Phase 0 findings are recorded in ADR 0001 §13. The PoC runs end to end on the
cluster: the gateway reports usage, OpenMeter stores it, the meter aggregates
it, and an exhausted entitlement is enforced at the gateway with HTTP 402.

Deployment assets for the cluster PoC live under `deploy/` and `scripts/`:

- `deploy/openmeter/` — Helm values and install notes for OpenMeter on
  OpenShift, including its bundled ClickHouse, Kafka, PostgreSQL and Redis.
- `scripts/install-openmeter.sh` — install OpenMeter into the `metering`
  namespace. The API listens on port 6443 and is exposed through an edge route.
- `scripts/seed-openmeter.sh` — create the meter, feature, customer and
  metered entitlement that the gateway filter expects. Usernames must match
  OpenMeter's key regex (lowercase, digits, underscores).
- `scripts/seed-pricing.sh` — create the per-model token meters, features, the
  `inference_payg` plan with rate cards, and a customer subscription. Required
  for dollar budgets and for the price editor to have rates to show.
- `scripts/enable-maas-metering.sh` — inject the `external_metering` and
  `token_count` filters into the `ipp` chain of the gateway ExtProc
  (`openshift-ingress`, deployment `payload-processing`). The script also
  sets `opendatahub.io/managed: "false"` on the ConfigMap and Deployment.
  `maas-controller` honours that, but `ai-gateway-controller` still re-renders
  on its 5-minute resync, so re-run the script after a reconcile.
- `deploy/maas/traffic-account.yaml` — ServiceAccount `openclaw-app` in
  `models-as-a-service`. `scripts/traffic-test.sh` mints a token for it and
  meters traffic as the OpenMeter subject `openclaw_app`.
- `scripts/smoke-test.sh` — send one inference request through the gateway and
  confirm OpenMeter received the usage event with non-zero token counts.
- `ui/`, `deploy/ui/ui.yaml` — one Flask image deployed twice in `metering`:
  `openmeter-price-editor` serves the price/budget UI on port 8080 behind an
  edge Route, and `openmeter-metering-proxy` is the metering relay on port
  6443. The relay prices gateway CloudEvents before forwarding them to
  OpenMeter and proxies the entitlement balance check. Build and deploy steps
  are in `ui/README.md`.
- `deploy/extproc/budget-status-402.yaml` — Envoy Lua filter that rewrites the
  metering filter's budget-exhaustion reply from 429 to 402, matching the
  rejection body so ordinary rate limiting stays 429.
- `deploy/grafana/` and `scripts/install-grafana.sh` — Grafana in the `metering`
  namespace with the Infinity datasource pointed at the in-cluster OpenMeter
  API, plus a provisioned `OpenMeter usage` dashboard (tokens by subject,
  entitlement balance and usage for one subject, entitlements table, recent
  events). No Prometheus needed: OpenMeter exposes no `/metrics`, so the
  dashboard queries the REST API directly.

## Viewing usage in Grafana

```bash
./scripts/install-grafana.sh
oc get route grafana -n metering -o jsonpath='{.spec.host}'
```

Open `https://<host>` and pick the **OpenMeter usage** dashboard in the
OpenMeter folder. The `Subject` textbox (default `openclaw_app`) controls the
balance and usage panels. anonymous viewer access is enabled for the PoC; the admin password is in Secret
`grafana-admin` (the install script ends by printing the command that reads it).

The dashboard uses Grafana time-range macros (`${__from:date:iso}`,
`${__to:date:iso}`) against:

| Panel | OpenMeter endpoint |
| --- | --- |
| Tokens by subject | `GET /api/v1/meters/tokens_total/query?groupBy=subject` |
| Balance / usage | `GET /api/v1/customers/{subject}/entitlements/inference_tokens/value` |
| Entitlements | `GET /api/v1/entitlements` |
| Recent events | `GET /api/v1/events?from=&to=` |

The Infinity plugin is downloaded from grafana.com on first start
(`GF_INSTALL_PLUGINS`), so the pod needs egress to grafana.com. Grafana data is
on an `emptyDir`; dashboards and the datasource come from ConfigMaps, so a
restart re-provisions them.

## Price editor UI and metering relay

The price editor gives operators two screens: per-model unit prices on the
active OpenMeter plan, and the budgets that cut subjects off. Saving a price
creates the next plan version, publishes it, and moves active subscriptions to
it. The same image also runs the metering relay.

```bash
# Build in-cluster, then deploy both the editor and the relay.
cd ui
oc new-build --binary --strategy=docker --name=maas-metering-poc -n metering \
  --to=maas-metering-poc:latest
oc start-build maas-metering-poc -n metering --from-dir=. --follow
oc apply -f ../deploy/ui/ui.yaml

oc get route openmeter-price-editor -n metering -o jsonpath='{.spec.host}'
```

Open `https://<host>` for the editor. The relay is reachable in-cluster at
`http://openmeter-metering-proxy.metering.svc.cluster.local:6443` and is the
`metering_url` to use for dollar budgets. Point both ExtProc chains at it:
`ipp` answers the gateway balance check, and `post-auth` owns provider calls.

```bash
URL=http://openmeter-metering-proxy.metering.svc.cluster.local:6443

./scripts/enable-maas-metering.sh --chain ipp --key extproc.yaml \
  --feature inference_cost --url "$URL"

./scripts/enable-maas-metering.sh \
  --namespace models-as-a-service \
  --configmap payload-processing-external-model-plugins \
  --deployment payload-processing-external-model \
  --chain post-auth --key extproc.yaml \
  --feature inference_cost --url "$URL"
```

The relay is **required** for dollar pricing. The gateway's
`external_metering` filter reports token counts only and has no pricing
support, so it cannot emit a `cost` field. The relay looks up the active plan's
per-token rates, adds `data.cost`, and forwards the event; it also passes the
entitlement balance check through to OpenMeter. Token-only metering does not
need the relay. Full API, build and deployment notes are in `ui/README.md`.

The deployed MaaS ExtProc image (`quay.io/opendatahub/odh-praxis-extproc`)
already contains the Rust `external_metering` and `token_count` filters, so the
gateway side is a configuration change rather than a custom image build.

## Quick start

```bash
./scripts/install-openmeter.sh
./scripts/seed-openmeter.sh --user cluster_admin --grant 100000
./scripts/enable-maas-metering.sh
MAAS_API_KEY="$(oc whoami -t)" ./scripts/smoke-test.sh
```

Drive billable traffic as a ServiceAccount and exhaust its dollar budget:

```bash
oc apply -f deploy/maas/traffic-account.yaml
./scripts/set-balance.sh --user openclaw_app --dollars 5
./scripts/traffic-test.sh --count 20
```

`traffic-test.sh` mints its token with
`oc create token openclaw-app -n models-as-a-service --duration=1h`, so no
secret is stored. It sends `x-maas-username: openclaw_app` and stops at the
first HTTP 402.

Pass `--use-me` to meter as the current `oc` user instead: the token comes from
`oc whoami -t` and the subject defaults to `oc whoami` normalized to an
OpenMeter key. Set that subject's balance first, or override it with
`--username`.

## Container runtime

Prefer **Podman** for local compose. Docker-compatible commands are fine as an alternative (see ADR deploy notes).
