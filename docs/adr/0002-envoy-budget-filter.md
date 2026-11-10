# ADR 0002 — Custom Envoy budget filter (post-Kuadrant, 402 on exhausted budget)

- **Status:** Proposed
- **Date:** 2026-11-10
- **Authors:** Jamie Land
- **Repo:** https://github.com/jland-redhat/metering-poc
- **Builds on:** [ADR 0001 — Metering PoC](0001-metering-poc-openmeter-talkback.md)
- **Implementation status:** Not implemented. This ADR records the design only.

---

## 1. Context

ADR 0001 puts metering capture and entitlement preflight inside the Praxis
`external_metering` filter. That filter reads identity from `x-maas-*` headers,
falls back to `default_username` because the headers are not visible to it, and
rejects an exhausted budget with HTTP 429 `token budget exhausted`.

Two gaps motivate this ADR:

1. **Enforcement is coupled to Praxis.** The decision lives in the same filter
   that emits usage events. We want a small, independent enforcement point at
   the Envoy layer that can be developed and reasoned about on its own.
2. **The status code is wrong for the concept.** 429 means rate limited. An
   exhausted budget is a payment condition and should be 402 Payment Required.
   ADR 0001 §11 left `402 vs 429` as an open question; this ADR chooses 402 for
   this demo path.

The feature is deliberately narrow: an Envoy HTTP filter that runs after
Kuadrant/Authorino has authenticated the request and injected identity headers,
reads the user from a header, asks whether that user is over budget, and stops
the request with 402 when they are.

---

## 2. Decision

We will add a custom Envoy HTTP filter to the MaaS gateway request path with
these locked choices:

1. **Placement:** an HTTP filter inserted **after Kuadrant/Authorino
   (`ext_authz`)** so identity headers already exist, and **before** the Praxis
   ExtProc filter whose `headers` item strips all `x-maas-*` request headers.
2. **Implementation:** a **proxy-wasm filter** (Rust or Go) deployed through the
   gateway's supported extension resource. If the deployed gateway build cannot
   load Wasm, fall back to a small ExtProc plugin. Do not fork Envoy and do not
   patch Envoy internals.
3. **Identity:** read the user from the Authorino-injected header
   (`x-maas-username` expected; the exact name is verified in Phase 0). The
   filter does **not** trust arbitrary client-supplied values. A configured
   default is allowed only for local demo when no header is present.
4. **Budget source:** query the OpenMeter entitlement value for the subject and
   feature, and treat `hasAccess: false` or a non-positive balance as over
   budget. Short-TTL cache plus single-flight per subject to keep the hot path
   from calling OpenMeter on every request.
5. **Deny response:** HTTP **402 Payment Required**, `Content-Type: text/plain`,
   body exactly:

   ```text
   You outta money fool!
   ```

6. **Failure policy:** configurable `fail_open` / `fail_closed`. Default
   `fail_open: true` for the PoC, matching ADR 0001 §8.3. Every decision and
   failure path is logged with subject, balance state and reason.

### 2.1 Consequences

**Positive**

- Enforcement becomes independent of the metering emitter and can be disabled
  or swapped without touching Praxis.
- 402 makes "budget exhausted" distinguishable from "too many requests" (429)
  and from "not authenticated" (401/403).
- Small, testable component with an explicit contract and obvious demo behavior.

**Negative / trade-offs**

- Adds a second OpenMeter reader on the request path. Caching is required, and
  cached decisions can be stale relative to asynchronous usage ingest.
- No reservation or settlement: concurrent requests can overshoot the budget by
  one cache window. This matches ADR 0001's non-goal of hot-path
  reserve-then-settle.
- Filter ordering is fragile. A controller reconciliation or gateway upgrade can
  reorder or drop the filter; the deployment procedure must be scripted and
  verified, like `scripts/enable-maas-metering.sh`.
- A Wasm filter is a new build artifact and supply-chain item for the PoC.

---

## 3. Goals and non-goals

### 3.1 Goals

1. Run a custom filter in the gateway path that can read the authenticated
   user after the Kuadrant shim.
2. Return 402 with the exact body above when that user is over budget.
3. Pass the request through unchanged when the user is under budget.
4. Keep the filter small: one identity header, one budget lookup, one deny
   response.
5. Document ordering, configuration, cache semantics and failure behavior.
6. Provide a repeatable cluster demo: small grant, exhaust, 402, top up, 200.

### 3.2 Non-goals

- Replacing `external_metering` usage emission. Capture remains ADR 0001's path.
- Per-request OpenMeter calls without caching.
- Reserve-then-settle, concurrency-safe debit, or exact budget accounting.
- Product-grade identity mapping (OpenShift usernames with hyphens still need a
  deterministic map to OpenMeter keys).
- Pricing, invoicing, wallets, or payment collection.
- Production rollout. This is a PoC demonstration.

---

## 4. Architecture

### 4.1 Request path

```text
client
  │
  ▼
Envoy (maas-default-gateway)
  │
  ├─ Kuadrant / Authorino ext_authz
  │     authenticates, injects identity headers (x-maas-*)
  │
  ├─ custom budget filter        <-- this ADR
  │     read user header
  │     cache lookup / OpenMeter entitlement value
  │     no budget → 402 "You outta money fool!"
  │
  ├─ Praxis ExtProc (payload-processing, chain ipp)
  │     headers filter strips x-maas-*
  │     token_count captures usage
  │     external_metering emits CloudEvent to OpenMeter
  │
  ▼
upstream model
```

The deny happens before the upstream call, so an over-budget request costs no
inference tokens.

### 4.2 Filter ordering

Envoy runs HTTP filters in chain order. The custom filter must satisfy both
constraints:

- **After** `envoy.filters.http.ext_authz` (Kuadrant), otherwise the identity
  header does not exist yet.
- **Before** the Praxis ExtProc filter, because the Praxis `headers` item
  removes `x-maas-*` from the request before the metering filter sees it.

Use an ordered insertion relative to the existing filters rather than a fixed
position. The exact insertion primitive depends on the gateway extension API
(`EnvoyExtensionPolicy`, `WasmPlugin`, or raw `EnvoyFilter`); Phase 0 records
which one is available and which filter name to anchor on. A conceptual patch:

```yaml
# Illustrative only. Verify the CRD and filter names on the target gateway.
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: maas-budget-filter
  namespace: openshift-ingress
spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: maas-default-gateway
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.http.ext_authz
      patch:
        operation: INSERT_AFTER
        value:
          name: maas.budget
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
            config:
              vm_config:
                runtime: envoy.wasm.runtime.v8
                code:
                  local:
                    filename: /var/local/lib/wasm/maas-budget-filter.wasm
              configuration:
                "@type": type.googleapis.com/google.protobuf.StringValue
                value: |
                  identity_header: x-maas-username
                  default_username: cluster_admin
                  openmeter_url: http://openmeter-api.metering.svc.cluster.local:6443
                  feature_key: inference_tokens
                  cache_ttl_seconds: 15
                  fail_open: true
                  deny_status: 402
                  deny_body: "You outta money fool!"
```

### 4.3 Identity header

Authorino is the only trusted source. Candidate header names, in order of
preference, verified against the live `AuthPolicy` in Phase 0:

1. `x-maas-username` — expected primary.
2. `x-tenant-username` — Praxis identity-header precedent.
3. Other `x-maas-*` / `x-tenant-*` header explicitly configured in the auth
   policy.

Rules:

- If the header is present, use it.
- If absent **and** `default_username` is configured (local demo only), use the
  default and log a warning.
- If absent and no default, apply the failure policy.
- Never read the subject from an unauthenticated client header when a verified
  header exists.

The value must be mapped to an OpenMeter subject key. Hyphenated OpenShift
usernames do not satisfy OpenMeter's key regex, so the PoC uses a configured
mapping for demo users, same limitation as ADR 0001 §13.

### 4.4 Budget lookup

OpenMeter owns the budget. The filter reads the entitlement value for
`subject = user`, `featureKey = inference_tokens` and maps the response to a
decision:

| OpenMeter result | Decision |
| --- | --- |
| `hasAccess: true`, positive balance/usage allowance | allow |
| `hasAccess: false` | deny 402 |
| balance <= 0 | deny 402 |
| entitlement not found | configure: deny or allow; default allow for PoC |
| transport error / timeout | apply `fail_open` |

The exact route is verified in Phase 0 against the deployed OpenMeter beta; the
existing filter's balance path returns `hasAccess` and usage/balance fields for
subjects with an entitlement. The filter uses a short timeout (for example
1000 ms) so a slow meter does not stall inference.

**Cache.** One entry per `(subject, feature_key)` with `cache_ttl_seconds`
(default 15). Concurrent misses for the same subject share one in-flight
lookup (single-flight). A deny result may use a shorter TTL than an allow, or
no cache, so a top-up is observed quickly. Cached decisions are logged as such.

**Freshness.** OpenMeter ingest is asynchronous, so the budget check can trail
reality by seconds. The PoC demonstrates the condition; it does not claim exact
accounting.

### 4.5 Deny response

```http
HTTP/1.1 402 Payment Required
Content-Type: text/plain
Content-Length: 21

You outta money fool!
```

The exact body is intentional for the demo. It is plain text, not JSON, so no
client parses it as an API envelope. The filter sends `local_reply` and does not
call the upstream.

---

## 5. Configuration contract

| Key | Required | Default | Meaning |
| --- | --- | --- | --- |
| `identity_header` | yes | `x-maas-username` | Header carrying the authenticated user |
| `default_username` | no | empty | Demo fallback; empty means no fallback |
| `openmeter_url` | yes | — | In-cluster API base URL |
| `openmeter_timeout_ms` | no | `1000` | Budget lookup timeout |
| `feature_key` | yes | `inference_tokens` | OpenMeter feature to check |
| `cache_ttl_seconds` | no | `15` | Allow-decision cache TTL |
| `deny_cache_ttl_seconds` | no | `0` | Deny-decision cache TTL |
| `fail_open` | yes | `true` | Allow or deny on meter errors |
| `deny_status` | no | `402` | Override only for experiments |
| `deny_body` | no | `You outta money fool!` | Exact demo body |

Configuration is loaded from the filter's inline configuration or a mounted
ConfigMap. Secrets: none in v1 (OpenMeter is unauthenticated in the PoC). If an
API key is added, mount it as a file; do not inline it in the Envoy config.

---

## 6. Work phases

### Phase 0 — Verify extension point (½ day)

- Identify the gateway implementation and its supported filter extension API
  (`EnvoyExtensionPolicy`, `WasmPlugin`, `EnvoyFilter`).
- Confirm Wasm runtime availability in the deployed Envoy build.
- Confirm filter insertion point after `ext_authz` and before the Praxis
  ExtProc.
- Confirm the actual identity header name and visibility at that point.
- Confirm the OpenMeter entitlement-value route and response shape in the
  deployed beta.
- Record findings in this ADR.

**Exit criteria:** written answers to every item above; a throwaway filter that
logs the identity header proves ordering.

### Phase 1 — Build and unit-test the filter

- Implement request-phase logic: read header, cache lookup, budget query,
  allow/deny.
- Unit tests with a mocked OpenMeter: allow, deny, not-found, timeout,
  fail-open, fail-closed, cache hit, single-flight.
- Test exact 402 status and body bytes.

**Exit criteria:** `cargo test` / `go test` green; filter builds into a Wasm
artifact reproducibly.

### Phase 2 — Wire into the gateway and demo

- Scripted apply and rollback, mirroring `scripts/enable-maas-metering.sh`.
- Demo: grant small budget → requests succeed → exhaust → 402 with exact body →
  top up → requests succeed again.
- Verify no 402 is generated by the Praxis `external_metering` path for the same
  condition (disable its sync deny for this profile or expect 429 only as a
  separate label).

**Exit criteria:** unattended demo script reaches 402 and recovers to 200.

### Phase 3 — Hardening and narrative

- Logging and metrics: decisions, cache hits, lookup latency, errors.
- Document ordering fragility and the reconciliation procedure.
- Update README and the ADR 0001 cross-reference.

---

## 7. Acceptance criteria

- **Given** a user under budget, **When** they send an inference request,
  **Then** the request reaches the upstream and returns 200.

- **Given** a user over budget, **When** they send an inference request,
  **Then** the gateway returns 402 with body exactly `You outta money fool!` and
  the upstream is not called.

- **Given** the identity header is absent and no default is configured,
  **When** a request is sent, **Then** the configured failure policy applies and
  the reason is logged.

- **Given** OpenMeter is unreachable, **When** a request is sent, **Then**
  `fail_open: true` allows it and `fail_open: false` denies it, in both cases
  with a logged reason.

- **Given** a cached allow decision, **When** another request for the same
  subject arrives within the TTL, **Then** no second OpenMeter call is made.

- **Given** an exhausted user is topped up in OpenMeter, **When** the deny cache
  TTL has elapsed, **Then** requests succeed again without restarting the
  gateway.

---

## 8. Risks and open questions

| Risk / question | Mitigation / decision owner |
| --- | --- |
| Gateway does not support Wasm | Fall back to ExtProc plugin; decide in Phase 0 |
| Filter order changes after controller reconcile | Scripted apply, verification probe, documented re-run |
| Identity header stripped before the filter | Anchor insertion before the stripping filter; Phase 0 probe |
| OpenShift username → OpenMeter key mismatch | Config mapping for demo; product needs deterministic mapping |
| Async ingest makes balance stale | Short TTL, document freshness; no exact-accounting claim |
| Cached allow overshoots budget under concurrency | Accepted PoC limitation; reserve-then-settle remains a non-goal |
| 402 body is intentionally informal | Demo only; do not ship this string in product |
| Meter outage on hot path | Configurable fail-open; product question remains open |

**Open questions**

- Which gateway extension API is authoritative for this installation?
- Should the filter deny on entitlement-not-found, or allow and let metering
  proceed?
- Should the filter and `external_metering` share a cache, or is one lookup per
  layer acceptable?
- Does the product want 402 at the gateway unconditionally, or a configurable
  deny code per tenant?

---

## 9. Security notes

- The filter trusts only the authenticated header path. It must not accept a
  client-supplied user header when Authorino has already run.
- Deny responses must not leak balance values, meters, or internal URLs; the
  body is fixed text.
- OpenMeter remains unauthenticated in the PoC. Any shared cluster must put
  network policy or auth in front of it; the filter's URL is in-cluster only.
- Do not log raw tokens or full headers. Log the subject and the decision.
- The Wasm artifact must be built from pinned sources and pinned dependencies.

---

## 10. References

- [ADR 0001 — Metering PoC](0001-metering-poc-openmeter-talkback.md)
- OpenAI-compatible gateway path and identity headers: ADR 0001 §13
- OpenMeter entitlements: https://openmeter.io/docs/billing/entitlements/quickstart
- Envoy Wasm filters: https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/wasm_filter
- Proxy-Wasm ABI: https://github.com/proxy-wasm/proxy-wasm-cpp-host

---

## 11. Decision summary

We will add a small proxy-wasm Envoy HTTP filter that runs after the
Kuadrant/Authorino shim and before the Praxis ExtProc, reads the authenticated
user from the identity header, checks that user's OpenMeter entitlement with a
short-lived cache, and returns **402 Payment Required** with the body
`You outta money fool!` when the budget is exhausted. Usage capture and
CloudEvent emission remain in ADR 0001's Praxis path. This ADR is a design
record; implementation and Phase 0 verification are still pending.
