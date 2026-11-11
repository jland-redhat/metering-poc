# Spin up a metering tenant

A **metering tenant** here is one OpenMeter customer plus the subject that
carries its gateway traffic. Creating one means:

1. a customer whose `usageAttribution.subjectKeys` contains the subject,
2. a subscription to the `inference_payg` plan, so the subject's usage is
   priced,
3. metered entitlements on that subject for the budgets you enforce,
4. a model price (feature plus rate card) for every model the tenant calls,
5. a gateway identity that meters traffic as that subject.

This page lists the expected objects and gives a command sequence that
reproduces them. It does not create anything by itself; run the commands when
you want a tenant.

## Expected objects

### Subject and customer

| Object | Value in the PoC | Notes |
| --- | --- | --- |
| ServiceAccount | `openclaw-app` in `models-as-a-service` | Kubernetes names cannot contain underscores |
| OpenMeter subject | `openclaw_app` | Must match `^[a-z0-9]+(_[a-z0-9]+)*$` |
| OpenMeter customer | key `openclaw_app` | `usageAttribution.subjectKeys: ["openclaw_app"]` |
| Gateway identity header | `x-maas-username: openclaw_app` | Sent by `traffic-test.sh`; the ipp chain falls back to the filter's `default_username` |

One customer can attribute several subjects, but the PoC uses one subject per
customer so a budget maps to one identity.

### Subscription

| Field | Value |
| --- | --- |
| Plan | `inference_payg` (currency USD) |
| Customer | the tenant's customer key |
| Timing | immediate |

A subscription binds the customer to the active plan version. The plan holds
the rate cards, so two tenants on the same plan share prices. A tenant that
needs different prices needs its own plan and subscription.

### Entitlements (budgets)

| Feature | Meter | Unit | Created by |
| --- | --- | --- | --- |
| `inference_tokens` | `tokens_total` (`SUM($.total_tokens)`) | tokens | `seed-openmeter.sh`, `set-balance.sh --tokens` |
| `inference_cost` | `cost_usd` (`SUM($.cost)`) | USD | `set-balance.sh --dollars` |

Both are `metered` entitlements with `usagePeriod.interval: MONTH`. The
`external_metering` filter reads one of them, chosen with `--feature` when the
filter is installed. A tenant can have both; the filter only enforces the one
it is configured with.

### Models and prices

The plan in this repo prices two models, each with a prompt and a completion
feature:

| Model (`data.model` in the event) | Prompt feature | Completion feature | Seed rates (USD/token) |
| --- | --- | --- | --- |
| `facebook/opt-125m` | `prompt_opt125m` | `completion_opt125m` | 0.001 / 0.002 |
| `Qwen/Qwen3-0.6B` | `prompt_qwen3` | `completion_qwen3` | 0.005 / 0.010 |

The rates above are what `seed-pricing.sh` creates. The price editor may have
published later plan versions, so read `/api/state` (or the dashboard's
**Rate Card** panel) for the active prices instead of assuming these.

Meters:

| Meter | Event | Value | Group by |
| --- | --- | --- | --- |
| `tokens_total` | `inference.tokens.used` | `$.total_tokens` | — |
| `tokens_prompt` | `inference.tokens.used` | `$.prompt_tokens` | `model` |
| `tokens_completion` | `inference.tokens.used` | `$.completion_tokens` | `model` |
| `cost_usd` | `inference.tokens.used` | `$.cost` | — |

A model must satisfy two things to be priced: it must be served by MaaS (so
the gateway produces events for it), and it must have a feature whose
`meterGroupByFilters.model` matches the event's `model` value exactly. The
request path (`publishers/llm/models/facebook/opt-125m`) and the event model
(`facebook/opt-125m`) are different strings; pricing keys off the event.

## Reproduce a tenant

Run from the repo root with a valid `oc` session. These commands mutate
OpenMeter and the gateway; skip the ones for objects that already exist.
The `curl` examples below assume the OpenMeter API is reachable as `$API`:

```bash
oc port-forward -n metering svc/openmeter-api 6443:6443 &
API=http://127.0.0.1:6443
```

### 1. OpenMeter and pricing

```bash
./scripts/install-openmeter.sh          # once per cluster
./scripts/seed-pricing.sh --customer openclaw_app
```

`seed-pricing.sh` creates the two token meters, the four model features, the
`inference_payg` plan, and a subscription for the given customer. Re-running
it against an existing plan reports conflicts instead of failing.

### 2. Identity

```bash
oc apply -f deploy/maas/traffic-account.yaml
```

This creates `ServiceAccount/openclaw-app`. `traffic-test.sh` mints a token
for it with `oc create token openclaw-app -n models-as-a-service --duration=1h`
and sends `x-maas-username: openclaw_app`, so no long-lived secret is stored.

### 3. Budget

```bash
./scripts/set-balance.sh --user openclaw_app --dollars 5
```

or, for a token budget:

```bash
./scripts/set-balance.sh --user openclaw_app --tokens 100000
```

The script creates the customer if missing, the meter and feature if missing,
replaces any entitlement for that feature, and resets the usage period so the
grant is fully available.

### 4. Gateway enforcement

Dollar budget:

```bash
./scripts/enable-maas-metering.sh --chain ipp --key extproc.yaml \
  --feature inference_cost \
  --url http://openmeter-metering-proxy.metering.svc.cluster.local:6443
```

Token budget: same command with `--feature inference_tokens`.

The ipp chain does not see the `x-maas-*` headers, so `default_username`
(default `openclaw_app`) decides which subject gateway traffic is metered as.
To meter a different tenant, pass `--default-username <subject>` or send the
header from a chain that can see it.

### 5. Traffic and verification

```bash
./scripts/traffic-test.sh --count 5
```

Expected after a fresh tenant:

- `traffic-test.sh` shows HTTP 200 and non-zero prompt/completion tokens.
- `GET /api/v1/subjects/openclaw_app/entitlements/inference_cost/value`
  reports `usage` above zero and a falling `balance`.
- `GET /api/v1/meters/cost_usd/query` groups that usage under
  `openclaw_app`.
- The Grafana dashboard (default subject `openclaw_app`) shows **USD balance**,
  **Spent (USD)**, and **Spend by model**.
- Lower the budget below the spend (`set-balance.sh --user openclaw_app
  --dollars 0.01`) and the next call returns HTTP 402 with body
  `token budget exhausted`.

## Adding a model

1. Confirm MaaS serves the model and note the `model` string in the usage
   event.
2. Create two features, one per token meter, filtered on that model:

   ```bash
   curl -X POST "$API/api/v1/features" -H 'Content-Type: application/json' -d '{
     "key": "prompt_newmodel",
     "name": "Prompt tokens new-model",
     "meterSlug": "tokens_prompt",
     "meterGroupByFilters": { "model": "<event-model-string>" }
   }'
   ```

   Repeat with `tokens_completion` and a completion key.
3. Publish a new plan version with rate cards for both features. The price
   editor does this: edit the rates on the page, which calls
   `POST /api/v1/plans/{key}/next`, `PUT`, `publish`, and moves every
   subscription to the new version. Or replay `seed-pricing.sh` with the new
   features added.
4. Send one call and check the event has a `cost` field at the relay
   (`oc logs deploy/openmeter-metering-proxy -n metering`). A model with no
   matching rate card still counts tokens but does not burn a dollar budget.

## Removing a tenant

There is no one-shot teardown script. The order that avoids dangling objects:

Stop traffic as the tenant first, then remove its OpenMeter objects:

```bash
# subscription ids: GET /api/v1/subscriptions
curl -X DELETE "$API/api/v1/subscriptions/{id}"
curl -X DELETE "$API/api/v1/customers/{customer-key}"
oc delete -f deploy/maas/traffic-account.yaml
```

Deleting the customer removes its subscription and entitlements. If a subject
was metered without a customer, delete its entitlement directly:

```bash
# ids: GET /api/v1/subjects/{subject}/entitlements
curl -X DELETE "$API/api/v1/subjects/{subject}/entitlements/{id}"
```

## Limits

- **One enforced budget per filter.** The gateway filter reads one feature,
  so a tenant is cut off on tokens or dollars, not both.
- **Shared plan prices.** Per-tenant prices need a separate plan.
- **Manual subscription.** A subject that is metered but has no customer and
  subscription still produces events and dashboard rows, but no plan-based
  budget.
- **No invoices.** The `openmeter-jobs` binary is missing from the pinned
  image, so spend is computed on read, not invoiced.
