# Testing what is on the cluster (jland-aws-1-pool-6rn6z)

Quick guide to exercise the Price Tag PoC end to end.

## 0. Context

- Gateway: `https://maas.apps.jland-maas-d-pool-2s6s6.aws.rh-ods.com`
  (Route `maas-gateway-route` -> `maas-default-gateway`, Istio/Envoy)
- Praxis ExtProc: `payload-processing` in `openshift-ingress`, chain `ipp`
  in ConfigMap `payload-processing-plugins`. First two filters:
  `external_metering` (balance check + usage report against Price Tag) and
  `token_count`.
- Price Tag: namespace `metering`
  (`http://price-tag.metering.svc.cluster.local:6443`), Postgres
  `price-tag-postgres` (user/db/password `metering`).
- Model: `free-model-kserve` (llm-d-inference-sim, facebook/opt-125m) in ns
  `llm`.

## 1. Send a request through the gateway (happy path)

Needs a MaaS API key (e.g. `pricetag-poc`, bound to `simulator-subscription`).
`kube:admin` bearer tokens 403 on this path form — the AuthPolicy
subscription CEL parses the model from the first two path segments, and the
`/v1/chat/completions` form has no model in the path. Use the
`/llm/free-model` form:

```sh
curl -sk -X POST \
  "https://maas.apps.jland-maas-d-pool-2s6s6.aws.rh-ods.com/llm/free-model/v1/chat/completions" \
  -H "Authorization: Bearer <MAAS_API_KEY>" \
  -H 'Content-Type: application/json' \
  -d '{"model":"publishers/llm/models/facebook/opt-125m",
       "messages":[{"role":"user","content":"Say hello in five words."}],
       "max_tokens":32}'
```

Expect HTTP 200 + a completion. (For a new API key:
`oc create -f` a MaaSApiKey / see maas-api in `odh-ai-gateway-infra`.)

## 2. Verify metering landed

```sh
oc exec -n metering deploy/price-tag-postgres -- psql -U metering -d metering -c \
  "SELECT username, model, prompt_tokens, completion_tokens, cost_usd, timestamp
   FROM usage_events ORDER BY timestamp DESC LIMIT 5;"
```

Expect a fresh priced row (username = API-key owner identity, non-zero
`cost_usd`).

## 3. Check the admission decision

```sh
oc port-forward -n metering svc/price-tag 48889:6443 &
curl -sS http://127.0.0.1:48889/api/v1/customers/<username>/entitlements/inference_tokens/value
```

Expect `hasAccess:true`, `budgetSource` `default` or `user_override`,
`quotaUsd`, `spendUsd`.

## 4. Drive a budget exhaustion (the 429 demo)

```sh
# set the user's budget to $0 (direct DB — no HTTP API for overrides yet)
oc exec -n metering deploy/price-tag-postgres -- psql -U metering -d metering -c \
  "INSERT INTO quota_overrides (scope, principal, monthly_usd, updated_by)
   VALUES ('user','<username>',0,'test')
   ON CONFLICT (scope,principal) DO UPDATE SET monthly_usd=0;"
```

Wait up to ~60s (Price Tag quota decision cache), confirm the decision
flipped (`hasAccess:false, denyReason:"quota_exhausted"`), then repeat the
request from step 1.

Expect: **HTTP 429**, body `token budget exhausted`.

## 5. Restore

```sh
oc exec -n metering deploy/price-tag-postgres -- psql -U metering -d metering -c \
  "DELETE FROM quota_overrides WHERE principal='<username>';"
```

Wait for the cache, confirm `hasAccess:true` again, request returns 200.

## 6. Demo UI (budgets + pricing editor)

```sh
oc port-forward -n metering svc/price-tag-ui 48890:8080
# open http://127.0.0.1:48890
```

Edit default/per-user budgets, model pricing, and watch spend + recent
events. No auth — port-forward only.

## Troubleshooting

- Filter errors: `oc logs -n openshift-ingress deploy/payload-processing --tail=100`
  (look for `external_metering`, `balance check unreachable`).
- Price Tag logs: `oc logs -n metering deploy/price-tag --tail=50`.
- If the `metering` namespace was wiped: redeploy with
  `scripts/install-price-tag.sh` from the `pricetag` branch of metering-poc.
  The ext_proc filter is fail-open, so the gateway keeps admitting while
  Price Tag is down.
