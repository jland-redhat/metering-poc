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
count. The app never multiplies by 1000 or similar — a price of `0.002` means
USD 0.002 per token.

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

Each subject with a metered entitlement has a token budget. The budget is the
sum of the entitlement's active **grants**. OpenMeter burns the grant down as
usage is metered, and `GET /api/v1/customers/{id}/entitlements/{feature}/value`
returns:

- `usage` — tokens consumed in the current period
- `balance` — tokens left across active grants
- `overage` — tokens used past the grants
- `hasAccess` — whether the entitlement is still satisfied

The Budgets table shows those values plus an estimated `Spent (USD)`, which is
the subject's recorded usage priced at the active plan's current rates.

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
| `GET` | `/api/budgets` | One row per metered entitlement with budget, usage, balance, spent |
| `POST` | `/api/budgets` | Body `{"subject": "<subjectKey>", "tokens": <amount>}`; overrides the entitlement grant |
| `GET` | `/api/costs?from=&to=` | Usage joined to prices; one row per subject/meter/model with `cost` |

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
```

The Deployment runs as UID 1001 with a restricted security context, exposes
`/healthz` for probes, and is fronted by an edge Route:

```
https://openmeter-price-editor-metering.apps.<cluster-domain>/
```

The deployment pulls `quay.io/jland/maas-metering-poc:latest` with
`imagePullPolicy: Always`, so a new `:latest` push is picked up on the next pod
restart.

## Known gaps

- **No dollar-denominated cap.** Budgets are token counts, because that is what
  OpenMeter grants. A dollar cap would need a conversion rule per model and an
  enforcement point that prices usage as it arrives.
- **No enforcement.** See ADR 0002. The ExtProc filter that would return 402 is
  not implemented.
- **No invoices.** The `openmeter-jobs` binary is missing from the
  `v1.0.0-beta.213` image, so billing CronJobs cannot run. Spend in this app and
  in Grafana is computed on read.
- **Subscription creation is manual.** New users are metered but not
  subscribed; assigning them a plan is a follow-up.
