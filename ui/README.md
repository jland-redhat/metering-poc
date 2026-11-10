# OpenMeter price editor

A small Flask app that gives the MaaS metering PoC a self-service screen for two
things:

1. **Unit prices** — the per-token price for each model and token type on the
   active OpenMeter plan.
2. **Budgets** — the token grant that decides when a subject is cut off.

It also exposes a read-only cost endpoint so the Grafana dashboard can show
spend without reimplementing price arithmetic in dashboard JSON.

Everything here targets OpenMeter `v1.0.0-beta.213`. This is PoC code, not
product code.

## How pricing is modeled in OpenMeter

The price editor does not invent a schema; it edits the objects created by
`scripts/seed-pricing.sh`:

| Object | Meaning | Example |
| --- | --- | --- |
| Meter | Counts a raw event field, grouped by a JSON path | `tokens_prompt`, `SUM($.prompt_tokens)`, `groupBy: {model: "$.model"}` |
| Feature | Names an entitlement check on top of a meter, optionally filtered by a meter group-by value | `prompt_opt125m` = `tokens_prompt` where `model == facebook/opt-125m` |
| Plan | A versioned container of phases and rate cards, in a currency | `inference_payg` |
| Rate card | `usage_based` card on a phase that prices one feature | `prompt_opt125m`, unit price `0.0015` USD per token |
| Subscription | Binds one **customer** to one plan version | `cluster_admin` → `inference_payg` v4 |
| Entitlement | A subject's access to a feature for a usage period, backed by grants | `cluster_admin`, `inference_tokens`, 50-token grant |

Four rate cards are used today:

| Rate card | Meter | Model filter | Unit price (USD/token) |
| --- | --- | --- | --- |
| `prompt_opt125m` | `tokens_prompt` | `facebook/opt-125m` | 0.0015 |
| `prompt_qwen3` | `tokens_prompt` | `Qwen/Qwen3-0.6B` | 0.005 |
| `completion_opt125m` | `tokens_completion` | `facebook/opt-125m` | 0.002 |
| `completion_qwen3` | `tokens_completion` | `Qwen/Qwen3-0.6B` | 0.01 |

The unit price is a number in the plan currency; the meter value is a token
count. The app never multiplies by 1000 or similar internally — a price of
`0.002` means USD 0.002 per token. The editor and the dashboard also show the
same rate per 1k and per 1M tokens, because per-token numbers are easy to
misread. Cost per request is just tokens used times the unit price, for example
`10 × prompt rate + 16 × completion rate`.

## What "saving a price" does

OpenMeter plans are immutable once published. Saving a changed price walks the
version chain:

1. `POST /api/v1/plans/{planKey}/next` creates a new **draft** version.
2. `PUT /api/v1/plans/{draftId}` rewrites the draft's phases and rate cards with
   the new amounts, preserving each card's `key`, `featureKey`, and cadence.
3. `POST /api/v1/plans/{draftId}/publish` activates the new version.
4. For every active subscription still on the old version,
   `POST /api/v1/subscriptions/{id}/change` moves it to the new version with
   `timing: "immediate"`.

Usage that was already recorded is **not** re-priced. Costs shown in the
dashboard use the active plan's current prices when the query runs, so the same
usage can appear to cost more after a price increase; OpenMeter invoices (when
the billing worker exists) would use the price in force at metering time.

If no price actually changed, the app returns `changed: false` and creates no
new version.

## Subscriptions are per customer, not global

A subscription belongs to a **customer**. Every event is attributed to a
subject, and the customer's `usageAttribution.subjectKeys` list decides which
subjects burn that subscription's balance.

Current state on the PoC cluster:

- Customers exist for `cluster_admin`, `htpasswd-cluster-admin-user`, and
  `quota_test`.
- Only **`cluster_admin`** has a subscription, and it is the one the price
  editor moves between plan versions.
- The other customers are metered (their events land in ClickHouse and appear
  in the dashboard) but have no plan attached, so no invoice or plan-based
  balance applies to them.

There is no "general subscription" that covers everyone. A user logging in with
a different identity gets that identity's own subject recorded, and it inherits
the active plan's prices only for display purposes in this app, because
`/api/costs` looks up the active plan's rate cards for all subjects regardless
of subscription. To give a different user a different price plan you would need
to create a customer with their subject and a subscription to the plan you
want. That is not automated yet.

The seed script creates one customer and subscription because the PoC drives
traffic as `cluster_admin`.

## Budgets: the cut-off point

Each subject with a metered entitlement has a budget. The budget is the sum of
the entitlement's active **grants**. OpenMeter burns the grant down as usage is
metered, and `GET /api/v1/customers/{id}/entitlements/{feature}/value`
returns:

- `usage` — units consumed in the current period
- `balance` — units left across active grants
- `overage` — units used past the grants
- `hasAccess` — whether the entitlement is still satisfied

Two entitlements are supported:

| Feature | Meter | Unit | Grant means |
| --- | --- | --- | --- |
| `inference_tokens` | `tokens_total` (`SUM($.total_tokens)`) | tokens | tokens allowed |
| `inference_cost` | `cost_usd` (`SUM($.cost)`) | USD | dollars allowed |

The Budgets table shows both, with the unit under each amount. `Spent (USD)`
is the subject's usage in the **current usage period** priced at the active
plan's current rates. It is not lifetime spend, so it moves with usage and
balance and drops back to zero when the monthly period rolls over. For a
dollar entitlement, `usage` already is spend, so the table shows that value.

## Dollar budgets

OpenMeter grants accept decimals: `issueAfterReset: 50.00` on a meter that
sums dollars gives a real USD budget (`balance: 50`, `hasAccess` until spend
reaches it). The gap is that the MaaS gateway reports **tokens only** — its
`inference.tokens.used` events carry `prompt_tokens`, `completion_tokens`,
`total_tokens` and `model`, but no price — and the `external_metering` filter
has no pricing support, so it cannot emit a cost.

This app closes the gap with a metering relay:

```
gateway ExtProc external_metering
    → POST {metering_url}/api/v1/customers/.../value   balance check (proxied)
    → POST {metering_url}/api/v1/events                usage report (priced)
        → openmeter-metering-proxy (this app, /meter and passthrough)
            → looks up the active plan's per-token prices for the model
            → adds data.cost = prompt_tokens × prompt rate
                               + completion_tokens × completion rate
            → forwards the event to OpenMeter
                → tokens_total meter  (tokens, unchanged)
                → cost_usd meter      ($.cost, new)
```

Every other method and path is proxied to OpenMeter unchanged, so the filter's
balance check and any other OpenMeter call pass through.

Set the relay as the filter's metering URL and seed a dollar entitlement:

```bash
./scripts/enable-maas-metering.sh --chain bbr --key pre-extproc.yaml \
  --url http://openmeter-metering-proxy.metering.svc.cluster.local:6443
./scripts/set-balance.sh --user cluster_admin --dollars 50
```

Verified end to end in this PoC: a request billing 10 prompt and 16 completion
tokens on `facebook/opt-125m` produces `cost: 0.047` at the relay, and the
subject's dollar entitlement drops from 5.00 to 4.76 after a
`Qwen/Qwen3-0.6B` request of the same size.

Limits of this approach:

- The relay prices with the **current** plan rates, at event delivery time.
  History is not re-priced, but a rate change applies to events delivered
  after it.
- A model with no matching rate card produces no `cost` and does not burn the
  dollar budget, while its tokens still count.
- The gateway load-balances calls through `payload-pre-processing`, whose
  request-only ExtProc mode hides responses, so `token_count` never sees
  usage. [deploy/extproc/response-mode.yaml](../deploy/extproc/response-mode.yaml)
  merges response buffering into that ExtProc. Without it the balance check
  runs but no usage event is reported.
- Both changes live in objects the ai-gateway-controller renders or manages;
  re-run the scripts and re-apply the EnvoyFilter after a gateway reconcile or
  upgrade.

### The best solution

The relay is a PoC workaround, not the shape this should take in a product.
The clean design puts pricing where the event is produced:

1. **Price in the gateway metering filter.** Give `external_metering` a price
   table (or a price lookup URL) so the usage CloudEvent carries
   `cost` natively, priced at the moment the response is parsed. One event,
   one writer, no proxy in the delivery path and no second network hop.
2. **Meter the cost, not the tokens, for billing.** Keep the token meters for
   reporting, but make the plan's entitlement and rate cards consume the cost
   meter so budget, invoice and dashboard all agree on one number.
3. **Enforce in the gateway, on the same number.** The budget filter from
   [ADR 0002](../docs/adr/0002-envoy-budget-filter.md) should read the same
   entitlement the balance check reads and return 402/429 at the boundary.
   Today admissions are advisory only.

Until (1) exists, the relay is the smallest change that shows a dollar budget
cutting off real traffic.

Changing a budget uses the entitlement **override** endpoint:

```
PUT /api/v1/subjects/{subject}/entitlements/{entitlementId}/override
{
  "type": "metered",
  "featureKey": "inference_tokens",
  "usagePeriod": {"anchor": "...", "interval": "MONTH"},
  "measureUsageFrom": "...",
  "issueAfterReset": <new token budget>,
  "isSoftLimit": false
}
```

That creates a new entitlement with the new grant and soft deletes the old one.
The app copies the usage period anchor and `measureUsageFrom` so already
recorded usage still counts. Raising the budget past current usage restores
`hasAccess: true`.

**Important:** setting a budget in OpenMeter only changes the entitlement's
answer. Whether the gateway actually returns an error at the cut-off depends on
the enforcement layer. In this PoC the `external_metering` ExtProc filter
reports usage and is configured `fail_open: true`; the 402 budget filter is
still a design in
[ADR 0002](../docs/adr/0002-envoy-budget-filter.md). So today the Budgets table
tells you where the line is, but the gateway does not yet stop traffic when a
subject crosses it.

## HTTP API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/` | Editor page |
| `GET` | `/healthz` | Liveness/readiness probe |
| `GET` | `/api/state` | Active plan, rate cards, subscriptions |
| `POST` | `/api/prices` | Body `{"prices": {"<rateCardKey>": <amount>}}`; creates and publishes the next plan version |
| `GET` | `/api/budgets` | One row per metered entitlement with budget, usage, balance, spent, unit and admission; optional `?subject=` filter and `?summary=1` for a single ADMIT/REJECT value |
| `POST` | `/api/budgets` | Body `{"subject": "<subjectKey>", "featureKey": "<feature>", "amount": <grant>}`; overrides the entitlement grant |
| `GET` | `/api/costs?from=&to=` | Usage joined to prices; one row per subject/meter/model with `cost`; optional `subject`, `meter` and `model` filters |
| `POST` | `/meter` | Metering relay: prices one usage CloudEvent and forwards it to OpenMeter |
| `*` | `/<path>` | Any other path proxied to OpenMeter unchanged (the filter's balance check) |

All routes return `{"error": "..."}` with a non-2xx status on failure.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPENMETER_URL` | `http://openmeter-api.metering.svc.cluster.local:6443` | OpenMeter API base URL |
| `PLAN_KEY` | `inference_payg` | Plan the editor reads and versions |
| `CUSTOMER_KEY` | unset | If set, only this customer's subscriptions are listed and moved |
| `PORT` | `8080` | Listen port |

## Running locally

The app is a thin proxy to the OpenMeter API, so point it at a reachable API.
From a machine with cluster access:

```bash
oc port-forward -n metering svc/openmeter-api 6443:6443
cd ui
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
OPENMETER_URL=http://127.0.0.1:6443 python3 app.py
```

Then open `http://127.0.0.1:8080`.

## Build and deploy

```bash
cd ui
podman build -t quay.io/jland/maas-metering-poc:v1 .
podman push quay.io/jland/maas-metering-poc:v1
oc apply -f ../deploy/ui/ui.yaml
oc rollout status deploy/openmeter-price-editor -n metering
oc rollout status deploy/openmeter-metering-proxy -n metering
```

The same image runs twice: `openmeter-price-editor` serves the page, and
`openmeter-metering-proxy` is the metering relay on port 6443 (the only ports
the gateway ExtProc NetworkPolicy allows; OVN matches the policy after service
DNAT, so the container must listen on the allowed port itself).

The Deployment runs as UID 1001 with a restricted security context, exposes
`/healthz` for probes, and is fronted by an edge Route:

```
https://openmeter-price-editor-metering.apps.<cluster-domain>/
```

The deployment pulls `quay.io/jland/maas-metering-poc:latest` with
`imagePullPolicy: Always`, so a new `:latest` push is picked up on the next pod
restart.

## Known gaps

- **Dollar budgets need the relay.** OpenMeter meters a `cost` field, but the
  gateway does not emit one. The relay in this app supplies it; a product
  should price inside the metering filter instead (see "The best solution").
- **No enforcement.** See ADR 0002. The ExtProc filter that would return 402 is
  not implemented, so an exhausted budget is reported, not applied.
- **No invoices.** The `openmeter-jobs` binary is missing from the
  `v1.0.0-beta.213` image, so billing CronJobs cannot run. Spend in this app and
  in Grafana is computed on read.
- **Subscription creation is manual.** New users are metered but not
  subscribed; assigning them a plan is a follow-up.
