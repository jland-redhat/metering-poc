# ADR 0001 — Metering PoC: Praxis capture → OpenMeter (GenAI CloudEvents) → talk-back go/no-go

- **Status:** Proposed
- **Date:** 2026-11-04
- **Authors:** Jamie Land
- **Repo:** https://github.com/jland-redhat/metering-poc
- **Related product docs (source of intent):**
  - `opendatahub-io/models-as-a-service` → `METERING_PROPOSAL/overview.md`
  - `opendatahub-io/models-as-a-service` → `METERING_PROPOSAL/talkback.md`
- **External targets:**
  - Praxis AI (`token_count`, `external_metering`, identity filters) — https://praxis.fast/
  - OpenMeter (Kong) — CloudEvents ingest + entitlements — https://openmeter.io/
  - OpenTelemetry GenAI semantic conventions (canonical home moved) —
    - Redirect notice: https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/
    - Living registry: https://github.com/open-telemetry/semantic-conventions-genai
    - Attribute docs: https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/registry/attributes/gen-ai.md

---

## 1. Context

### 1.1 Product posture we are proving (not shipping)

The AI Gateway / MaaS **3.7 usage-metering** lean is:

1. **Accurate multi-type usage capture** is the highest priority.
2. **Cost of record, wallets, and cut-off policy** live in an **external meter**.
3. Platform owns **export** (CloudEvents) and an **entitlement adaptor** that mirrors meter decisions into a gateway seam as **local go/no-go**.
4. Admit on the productized hot path **must not** call the meter per request.
5. Monetize 360 is a commercial target but is a poor fit for a **quick PoC**. OpenMeter is the stand-in meter for this repository.

This ADR defines a **throwaway-friendly but architecture-faithful PoC** that proves the export + rate + talk-back loop end-to-end, while explicitly calling out where PoC shortcuts diverge from the product lean (especially sync entitlement on the Praxis hot path).

### 1.2 Why this PoC exists

We need a concrete, runnable system that demonstrates:

| Proof point | Why it matters for the proposal |
| --- | --- |
| Capture **different token types** from inference responses | Customer / TP must: input, output, cache, reasoning (not a single collapsed counter) |
| Attribute usage to **user / organization / subscription** + **model** | FinOps rating / allocation keys |
| Emit **CloudEvents** shaped with **GenAI semantic convention** attribute names | Portable external envelope; not a vendor-private schema |
| **OpenMeter** rates those events with **different prices** by model × token type | External meter owns pricing SoT |
| A **high-level talk-back service** exposes go/no-go for a subject | Seeds the entitlement-adaptor contract before a real gateway seam |

### 1.3 Constraints

- Prefer **Praxis as-is** for capture and (where usable) CE emission.
- Proposed 3.7 product pieces (Gateway SoR projector, generic adaptor, shared admit seam, MaaS capture profiles) **do not exist yet** — PoC may stub or approximate them.
- Next implementer **must evaluate** whether stock Praxis filters suffice, or whether a **thin custom Praxis filter / sidecar projector** is required for GenAI-shaped multi-type CE.
- Runtime preference for local demos: **Podman** (Docker-compatible compose files OK).
- This repo is **experimental** — not a product deliverable and not a silent merge gate for MaaS TP.

---

## 2. Decision

We will build a multi-component PoC in this repository with the following locked choices:

1. **Meter:** OpenMeter (self-hosted compose for local; optional cloud later).
2. **Capture path:** Praxis AI gateway filters — start from **`token_count`** (+ `stream_usage_inject` / `model_to_header` as needed) and evaluate **`external_metering`** for CE emission vs a PoC-owned emitter.
3. **Event envelope:** CloudEvents 1.0 JSON, with `data` fields aligned to **OTel GenAI usage / request attributes** (see §5).
4. **Pricing:** OpenMeter meters + features + rate cards differentiated by **`gen_ai.response.model` (or request model) × token type**.
5. **Talk-back:** A minimal HTTP service that **polls OpenMeter entitlements** and exposes **`GET /v1/entitlements/{subject}/decision`** returning go/no-go (+ optional remaining). It does **not** enforce admit inside Praxis for the product-shaped path (optional demo hook only).
6. **Attribution subject:** Composite key documented in §5.3 (`principal` + `subscription` + optional `organization`).

### 2.1 Consequences

**Positive**

- Fast path to a demo without Monetize 360 onboarding.
- Reuses real Praxis token parsing (including cache / reasoning when providers report them).
- Forces an explicit CE ↔ GenAI mapping early, which the product CE contract needs anyway.
- Talk-back stub makes the adaptor contract tangible before gateway seam design freezes.

**Negative / trade-offs**

- Praxis `external_metering` today performs a **sync pre-request balance check** — that matches EnMaaS/Price Tag coupling, **not** the 3.7 product lean (local go/no-go only). PoC must treat that as optional / demo-only and keep talk-back as the **canonical** entitlement read for product storytelling.
- GenAI conventions are still **development** stability and recently **moved repos**; pin a commit/version of the attribute list.
- Stock `external_metering` CE payloads may **not** already be GenAI-named or multi-event-per-token-type; mapping work is expected.
- OpenMeter is a stand-in; connectors for Price Tag / Monetize remain future work.

---

## 3. Goals and non-goals

### 3.1 Goals (PoC Must)

1. Run a local stack: mock/upstream model (or recorded fixtures) → Praxis → OpenMeter → talk-back API.
2. Capture at least: **input**, **output**, and when available **cache_read** / **reasoning** token counts from Praxis `token_count` metadata.
3. Emit CloudEvents into OpenMeter for those counts, attributed with subject + model.
4. Configure OpenMeter so **different models** and **different token types** have **different unit prices**.
5. Drive spend / entitlement to exhaustion and show talk-back flipping **go → no-go**, then restore after a grant/top-up.
6. Document exact CE examples, OpenMeter meter/feature/rate-card YAML, and a short demo script.

### 3.2 Goals (PoC Should)

1. Map CE `data` keys 1:1 to GenAI attribute names where practical (`gen_ai.usage.input_tokens`, etc.).
2. Support organization + subscription dimensions on events and talk-back queries.
3. Emit **one CE per billable slice** (recommended) *or* one CE with multiple usage fields + OpenMeter meters that JSONPath each field — pick one and document why.
4. Optional: wire Praxis admit to talk-back **only** as a labeled “anti-pattern demo” vs “product lean demo” profile.

### 3.3 Non-goals (explicit)

- Productized MaaS CRDs (`MaaSModelRef` capture profiles, weights, portal UX).
- Durable Gateway SoR / Loki OOTB path / OTel UsageEvent product shape.
- Monetize 360, Price Tag production connectors (may add later as sibling ADRs).
- Invoice / payment / tax / Stripe customer portal polish.
- Hot-path reserve-then-settle like LiteLLM.
- Making this PoC a CI gate for `models-as-a-service`.
- Perfect GenAI span semantics (agents, tools, retrieval) — **usage + model + subject only** for v1 of the PoC.

---

## 4. Architecture

### 4.1 Target PoC topology

```text
┌─────────────────┐     chat/completions      ┌──────────────────────────────┐
│ Demo client /   │ ─────────────────────────▶│ Praxis AI                    │
│ curl / k6       │◀───────────────────────── │  model_to_header             │
└─────────────────┘     response + usage      │  stream_usage_inject (opt)   │
                                              │  token_count                 │
                                              │  [emitter: external_metering │
                                              │    OR custom CE projector]   │
                                              │  (optional identity filters) │
                                              └──────────────┬───────────────┘
                                                             │ CloudEvents
                                                             │ POST /api/v3/openmeter/events
                                                             ▼
                                              ┌──────────────────────────────┐
                                              │ OpenMeter                    │
                                              │  meters + features + plans   │
                                              │  entitlements / wallets      │
                                              └──────────────┬───────────────┘
                                                             │ poll entitlements.value
                                                             ▼
                                              ┌──────────────────────────────┐
                                              │ talkback-service (PoC)       │
                                              │  GET .../decision → go|no-go │
                                              └──────────────────────────────┘
```

### 4.2 Mapping to product planes (honesty table)

| Product lean (3.7) | PoC approximation | Allowed? |
| --- | --- | --- |
| Proxy → Praxis sidecar → durable SoR → CE projector | Direct CE emit from Praxis filter / thin projector | Yes for PoC |
| Adaptor polls meter → pushes local gateway seam | talk-back **exposes** decision via HTTP; no gateway seam yet | Yes (high-level) |
| Admit reads **local** go/no-go only | Default: admit **not** coupled; optional profile may call talk-back or use `external_metering` sync check | Sync path = demo anti-pattern, labeled |
| Price Tag / Monetize | OpenMeter | Yes |
| Weights on MaaS objects | Out of scope | N/A |

### 4.3 Suggested repo layout

```text
metering-poc/
  README.md
  docs/
    adr/
      0001-metering-poc-openmeter-talkback.md   # this file
    contracts/
      cloudevents-genai-usage.md                # normative CE examples
      talkback-api.md                           # OpenAPI-ish contract
    demo/
      script.md                                 # operator walkthrough
  deploy/
    openmeter/                                  # compose + seed config
    praxis/                                     # Praxis config YAML(s)
  services/
    talkback/                                   # Go or Python HTTP service
    # optional: ce-projector/                   # if custom filter deferred
  scripts/
    seed-openmeter.sh
    emit-sample-events.sh
    demo-exhaustion.sh
  fixtures/
    openai-chat-completion-usage.json
    openai-chat-completion-usage-cached-reasoning.json
```

---

## 5. CloudEvents × GenAI conventions

### 5.1 Normative references

Pin GenAI attribute names from the dedicated registry (conventions moved out of the core semconv site; the agent-spans URL is a redirect stub):

- https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/registry/attributes/gen-ai.md

**PoC-required attributes (when known):**

| GenAI attribute | Role |
| --- | --- |
| `gen_ai.request.model` | Client-requested model id |
| `gen_ai.response.model` | Served model id (prefer for pricing when present) |
| `gen_ai.provider.name` | Provider / system (openai, anthropic, …) — use current registry name; verify at pin time |
| `gen_ai.usage.input_tokens` | Prompt / input tokens (includes cached per convention notes) |
| `gen_ai.usage.output_tokens` | Completion / output tokens |
| `gen_ai.usage.cache_read.input_tokens` | Cached input subset (when reported) |
| `gen_ai.usage.cache_write.input_tokens` | Cache write subset (when reported) |
| `gen_ai.usage.reasoning.output_tokens` | Reasoning / thinking subset of output (when reported) |

**PoC attribution extensions (not GenAI registry — namespaced):**

| Attribute | Role |
| --- | --- |
| `maas.principal` | Authenticated user / agent id |
| `maas.subscription` | Subscription id |
| `maas.organization` | Organization id (optional / best-effort) |
| `maas.usage_complete` | `true` / `false` — never emit silent successful zero |

> Implementer note: prefer **dot-separated names matching GenAI** inside CE `data`, even though OpenMeter examples often use flat keys like `tokens` / `type`. Either flatten for OpenMeter JSONPath *or* keep GenAI names and teach meters `$.['gen_ai.usage.input_tokens']` / equivalent. **Decide in Phase 1 spike and document in `docs/contracts/`.**

### 5.2 Recommended emit strategy (default lean)

**One CloudEvent per billable slice** after a successful response:

| `type` (CE) | `data.tokens` (or GenAI field) | `data.token_type` | Notes |
| --- | --- | --- | --- |
| `gen_ai.usage.tokens` | N | `input` | From `token.input` minus cache breakdown rules as documented |
| `gen_ai.usage.tokens` | N | `output` | From `token.output` (non-reasoning portion if split) |
| `gen_ai.usage.tokens` | N | `cache_read` | Only if metadata key present |
| `gen_ai.usage.tokens` | N | `cache_write` | Only if metadata key present |
| `gen_ai.usage.tokens` | N | `reasoning` | Only if metadata key present |

**Rationale:** Matches OpenMeter’s LLM example (`groupBy` on model + type) and makes **different prices per type** trivial via `meterGroupByFilters`.

**Alternative (acceptable if spike prefers):** single CE containing all GenAI usage fields; multiple OpenMeter meters each JSONPath one field. Slightly fewer HTTP posts; more meter objects.

### 5.3 Subject / identity

CloudEvents `subject` should be a **stable, documented encoding** of attribution, for example:

```text
org/{organization}/sub/{subscription}/principal/{principal}
```

If organization is absent: `sub/{subscription}/principal/{principal}`.

Also duplicate fields inside `data` for OpenMeter groupBy / debugging:

```json
{
  "specversion": "1.0",
  "id": "01JBEXAMPLE",
  "source": "metering-poc/praxis",
  "type": "gen_ai.usage.tokens",
  "time": "2026-11-04T20:00:00.001Z",
  "subject": "org/acme/sub/team-a/principal/alice",
  "datacontenttype": "application/json",
  "data": {
    "tokens": "1200",
    "token_type": "input",
    "gen_ai.request.model": "gpt-4o",
    "gen_ai.response.model": "gpt-4o-2024-08-06",
    "gen_ai.provider.name": "openai",
    "maas.principal": "alice",
    "maas.subscription": "team-a",
    "maas.organization": "acme",
    "maas.usage_complete": true
  }
}
```

Identity sources to evaluate (in order of preference):

1. Praxis verified auth metadata / `identity_header_guard` (`x-tenant-username`, `x-tenant-subscription`, `x-tenant-organization-id`, `x-tenant-model`, …) — see [external_metering](https://praxis.fast/ai/v0.8.0/filters/external_metering/).
2. Demo static defaults for local compose.
3. **Never** trust raw client headers when a verified metadata tier exists.

### 5.4 Incomplete usage

If `token_count` yields no usable counts:

- Do **not** POST a zero success event as if usage were complete.
- Either skip emit and increment a PoC metric `usage_emit_incomplete_total`, or emit with `maas.usage_complete=false` and exclude from billable meters (document which).

---

## 6. Praxis capture plan (evaluate before building custom)

### 6.1 What already exists (use first)

| Filter / feature | Capability | PoC relevance |
| --- | --- | --- |
| [`token_count`](https://praxis.fast/ai/v0.8.0/filters/token_count/) | Parses streaming + non-streaming usage for openai / anthropic / google / bedrock / azure into metadata: `token.input`, `token.output`, `token.total`, plus `token.cache_read`, `token.cache_write`, `token.reasoning` when reported | **Primary capture** |
| [`stream_usage_inject`](https://praxis.fast/ai/v0.8.0/examples/configs/stream-usage-inject.yaml/) | Forces OpenAI stream usage inclusion | Required for streaming OpenAI demos |
| [`model_to_header`](https://praxis.fast/ai/v0.8.0/examples/configs/token-counting.yaml/) | Model id for metrics / downstream | Use for model attribution |
| [`external_metering`](https://praxis.fast/ai/v0.8.0/filters/external_metering/) | Pre-request balance check + post-response CE usage report to `metering_url`; identity headers; fail-open | **Evaluate as emitter**; sync check is product anti-pattern |
| Token counting example | Documents cache as breakdown of input; reasoning as breakdown of output (provider-specific) | Ground truth for double-count rules |

### 6.2 Evaluation checklist (mandatory Phase 0 / Phase 1 gate)

The next implementer **must** answer these before writing a custom filter:

1. **Metadata completeness:** For OpenAI Chat Completions (non-stream + stream) and at least one second provider, which of `token.input|output|cache_read|cache_write|reasoning` are populated from real fixtures?
2. **`external_metering` payload shape:** What exact CloudEvent `type` / `data` fields does it emit today? Does it emit **one event with totals only**, or per-type slices? Does it include subscription / org?
3. **OpenMeter compatibility:** Can stock events be ingested as-is with meter JSONPath, or is a reshape required?
4. **GenAI naming:** Can we configure stock filters to emit GenAI attribute names, or only via a shim?
5. **Hot-path coupling:** Can `external_metering` be configured to **report-only** (no balance check), or must we disable/replace the preflight for the product-lean demo profile?
6. **Version pin:** Which Praxis image tag (`ghcr.io/praxis-proxy/ai:…`) is used, and are dogfood-only patches required?

### 6.3 Decision tree for custom work

```text
IF external_metering can emit (or be lightly configured to emit)
   multi-type usage + subject dims into OpenMeter
THEN use stock filters; document gaps only
ELSE IF a tiny out-of-process projector can read Praxis access logs / metrics / webhook
THEN prefer projector over forking Praxis (faster PoC)
ELSE build a thin custom Praxis filter that:
   - reads token.* metadata
   - maps to GenAI CE slices
   - POSTs to OpenMeter
   - does NOT perform sync entitlement (talk-back owns that story)
```

Custom filter acceptance bar (if built):

- ≤1 small Rust filter **or** Go sidecar projector — no general-purpose billing engine.
- Unit tests with fixtures under `fixtures/`.
- Feature-flag / separate listener profile from any sync-balance demo.

---

## 7. OpenMeter billing plan

### 7.1 Meter definition (recommended)

Single SUM meter with groupBy on model + token_type (+ optional provider):

```yaml
meters:
  - slug: genai_tokens_total
    description: GenAI billable tokens
    eventType: gen_ai.usage.tokens
    aggregation: SUM
    valueProperty: $.tokens
    groupBy:
      model: $.gen_ai.response.model   # or flattened $.model after spike
      token_type: $.token_type
      provider: $.gen_ai.provider.name
```

> Adjust JSONPaths to the final CE shape chosen in §5.

### 7.2 Features + prices (proof of differentiated pricing)

Create features filtered by groupBy, each with a usage-based rate card. Example matrix (illustrative):

| Feature key | Filters | Unit price (example) |
| --- | --- | --- |
| `gpt4o_input` | model=gpt-4o, token_type=input | $2.50 / 1M |
| `gpt4o_output` | model=gpt-4o, token_type=output | $10.00 / 1M |
| `gpt4o_cache_read` | model=gpt-4o, token_type=cache_read | $1.25 / 1M |
| `gpt4o_reasoning` | model=gpt-4o, token_type=reasoning | $10.00 / 1M |
| `llama_input` | model=llama-3.1-8b, token_type=input | $0.20 / 1M |
| `llama_output` | model=llama-3.1-8b, token_type=output | $0.20 / 1M |

Use OpenMeter **plans / rate cards / entitlements** so a customer subject has:

- A **metered entitlement** or **credit/wallet** that declines with rated usage, **or**
- Hard limits per feature (`isSoftLimit: false`) for a simpler cut-off demo.

**PoC Must:** show two models with different prices and at least two token types with different prices, then query aggregated usage / invoice preview / entitlement balance via OpenMeter APIs.

### 7.3 Customer / subject seeding

Script `scripts/seed-openmeter.sh` should:

1. Create customer(s) whose keys match CE `subject` (or OpenMeter customer key ↔ subject mapping table in docs).
2. Attach plan / entitlements with a small allowance so exhaustion is easy in demo.
3. Print talk-back curl examples.

### 7.4 Local runtime

- Prefer official OpenMeter compose / quickstart (Kafka + ClickHouse + Postgres + API).
- Document Podman:

```bash
podman compose -f deploy/openmeter/compose.yaml up -d
# Docker alternative:
# docker compose -f deploy/openmeter/compose.yaml up -d
```

---

## 8. Talk-back service (high-level)

### 8.1 Purpose

Prove the **adaptor-facing read model**: given attribution keys, return the meter’s current **go/no-go** decision. This is intentionally thin — not the full gateway ingest seam.

### 8.2 API (draft)

`GET /v1/entitlements/decision`

Query params (all that apply):

| Param | Required | Description |
| --- | --- | --- |
| `principal` | yes | User / agent id |
| `subscription` | yes | Subscription id |
| `organization` | no | Org id |
| `feature_key` | no | OpenMeter feature to check; default from config |
| `model` | no | Optional future scope; ignore in v1 if entitlement is wallet-wide |

Response:

```json
{
  "subject": {
    "principal": "alice",
    "subscription": "team-a",
    "organization": "acme"
  },
  "decision": "go",
  "as_of": "2026-11-04T20:01:00Z",
  "reason": "quota_ok",
  "remaining": { "amount": 42.5, "currency": "USD" },
  "source": "openmeter",
  "freshness_sla_seconds": 30
}
```

Align field names with `METERING_PROPOSAL/talkback.md` “Recommended talk-back contract”.

### 8.3 Behavior

1. Map query subject → OpenMeter customer key.
2. Call OpenMeter `customers.entitlements.value` (or wallet/balance equivalent chosen in spike).
3. Map `hasAccess` → `decision: go|no-go`.
4. No caching required for v1 (optional short TTL later).
5. On OpenMeter errors: return `503` with `decision` omitted **or** configurable fail-open `go` with `reason=meter_unreachable` — default **fail-open for PoC**, document product open question (fail-open vs fail-closed on stale).

### 8.4 Explicitly out of talk-back v1

- Pushing into Envoy/Praxis local state.
- Writing CRs.
- Per-request calls from Praxis admit (unless optional anti-pattern profile).
- Pricing computation.

### 8.5 Implementation sketch

- Language: Go (fits MaaS ecosystem) or Python (faster spike) — implementer choice; prefer Go if sharing types with future adaptor.
- Config: `OPENMETER_URL`, `OPENMETER_API_KEY` (empty for local), `DEFAULT_FEATURE_KEY`.
- Tests: httptest against mocked OpenMeter responses for go, no-go, and unreachable.

---

## 9. Work phases

### Phase 0 — Spike (1–2 days)

**Deliverables**

- Pin Praxis image + OpenMeter version.
- Capture matrix from fixtures → `token.*` metadata (§6.2).
- Inspect / log `external_metering` CE bodies.
- Decision record in this ADR’s “Implementation notes” section: stock vs projector vs custom filter.

**Exit criteria:** Written go/no-go on custom filter; sample CE JSON committed under `docs/contracts/`.

### Phase 1 — OpenMeter seed + synthetic emit

**Deliverables**

- Compose stack up via Podman.
- Meters / features / rate cards for ≥2 models × ≥2 token types.
- `scripts/emit-sample-events.sh` posts GenAI-shaped CEs (no Praxis required yet).
- Verify usage aggregates and entitlement drain in OpenMeter UI/API.

**Exit criteria:** Differentiated pricing visible; entitlement can reach no-access.

### Phase 2 — Praxis path

**Deliverables**

- `deploy/praxis/` config: token capture (+ stream inject) + chosen emitter.
- Upstream: mock OpenAI-compatible server returning rich `usage` (include cache + reasoning fixtures).
- End-to-end: real request → CE(s) in OpenMeter.

**Exit criteria:** At least input+output billed; cache/reasoning if fixture supports.

### Phase 3 — Talk-back service

**Deliverables**

- `services/talkback` with contract in `docs/contracts/talkback-api.md`.
- Demo script: generate traffic → poll decision → exhaust → no-go → grant → go.

**Exit criteria:** Demo script succeeds unattended.

### Phase 4 — Hardening / narrative

**Deliverables**

- README demo (Podman-first + Docker alternative).
- “Product lean vs PoC shortcuts” section for stakeholders.
- Backport learnings into `METERING_PROPOSAL/talkback.md` (CE field names, OpenMeter as BYO example) via a follow-up PR in models-as-a-service — **not** required to merge this PoC.

---

## 10. Acceptance criteria (demo script Must)

Use Given / When / Then as one logical block per criterion:

- **Given** OpenMeter is seeded with distinct prices for model A input vs model A output vs model B input,
  **When** synthetic or Praxis-driven events for those slices are ingested,
  **Then** OpenMeter usage/cost views show different rated amounts per slice (not a single blended counter).

- **Given** a customer entitlement with a small hard limit or credit balance,
  **When** usage events consume past the limit,
  **Then** `GET /v1/entitlements/decision` returns `decision=no-go` with a stable `reason`.

- **Given** a no-go customer,
  **When** an operator grants additional entitlement / credit in OpenMeter,
  **Then** talk-back returns `decision=go` without restarting Praxis.

- **Given** an OpenAI-shaped response fixture including cache and reasoning fields Praxis understands,
  **When** the capture path runs,
  **Then** those token types are present in emitted CE `data` (or explicitly listed as “provider reported / filter gap” in the spike notes).

- **Given** the product-lean demo profile,
  **When** inference requests are served,
  **Then** Praxis does **not** depend on per-request OpenMeter entitlement HTTP for admit (talk-back remains the entitlement story).

---

## 11. Risks and open questions

| Risk / question | Mitigation |
| --- | --- |
| `external_metering` CE schema ≠ GenAI / multi-type | Spike early; projector shim |
| Sync balance check confuses stakeholders | Two named profiles: `product-lean` vs `enmaas-like` |
| GenAI attribute renames (dev stability) | Pin registry commit SHA in README |
| Double-counting cache/reasoning | Follow Praxis token-counting comments; document billable vs breakdown |
| Subject key mismatch OpenMeter customer | Single seeding script owns the mapping |
| OpenMeter compose weight (Kafka/CH) | Document resource needs; allow cloud trial fallback |
| Scope creep into full adaptor + gateway seam | Hard non-goal until ADR 0002 |

**Open product questions this PoC informs but does not decide**

- Gateway ingest seam shape (API / CR / shared store).
- Fail-open vs fail-closed on stale entitlement.
- Deny code **402** vs other (distinct from QoS **429**).
- Whether CE birthplace remains Gateway projector in product while PoC emits from Praxis.

---

## 12. Security notes (PoC)

- No real customer PII in fixtures; use synthetic principals.
- Do not commit API keys; use env / local `.env` (gitignored).
- If `allow_private_endpoint` is required for Praxis→OpenMeter on a cluster network, document SSRF implications (Praxis already restricts by default).
- Talk-back is **unauthenticated** in local compose; for any shared/dev cluster, put basic auth or network policy in front.

---

## 13. Implementation notes (fill during Phase 0)

> Next AI / human implementer: replace this section with findings — do not delete the questions.

- Praxis image tag: `quay.io/opendatahub/odh-praxis-extproc@sha256:889a9f6e59b60ddc0165739869207a6bdd3e79b6d6a6b3ac09f0b3405f366dd3`
  (runs as `praxis-extproc 0.1.0`, built on `praxis-ai-filters` v0.9.0).
- OpenMeter version: chart `1.0.0-beta.213` / app `v1.0.0-beta.213`, installed
  from `openmeterio/openmeter` `deploy/charts/openmeter`. The project publishes
  no Helm chart repository.
- `external_metering` availability: registered unconditionally in
  `praxis-ai-filters` v0.9.0 (`filters/src/register.rs`) and present in the
  deployed image. `praxis-extproc -c <file> -t` accepts a chain containing the
  filter, so no custom image is required.
- Filter configuration used for the PoC (verified end to end):

  ```yaml
  - filter: external_metering
    metering_url: "http://openmeter-api.metering.svc.cluster.local:6443"
    allow_private_endpoint: true
    timeout_seconds: 5
    feature_key: "inference_tokens"
    source: "maas-gateway"
    fail_open: true
    identity_header_prefix: "x-maas-"
    default_username: "cluster_admin"
    default_model: "unknown"
  - filter: token_count
    provider: openai
  ```

  `default_username` is required: Authorino's `x-maas-*` headers are not
  visible to this ExtProc, and without a default the filter skips metering
  entirely. The value must satisfy OpenMeter's customer key regex.
  `token_count` is also required: it parses the provider response and publishes
  `token.input` / `token.output` / `token.total` in `filter_metadata`, which
  `external_metering` reads in its response phase. Without it every usage event
  reports zero tokens.
- Active ExtProc for gateway traffic: deployment `payload-processing` in
  `openshift-ingress`, ConfigMap `payload-processing-plugins`, chain `ipp`,
  wired by the gateway `EnvoyFilter` at `payload-processing.openshift-ingress:9004`.
  The `payload-processing-external-model` ExtProc in `models-as-a-service`
  serves provider-side traffic and is not on this path; injecting the filter
  there has no effect.
- Filter order: `external_metering` is inserted as the first item of `ipp`,
  before the `headers` filter, because `headers` removes all `x-maas-*`
  request headers.
- `token_count` matrix (provider × token keys observed): `provider: openai`
  against the simulated OPT-125M model. Non-streaming completion returned
  `prompt_tokens: 11`, `completion_tokens: 3`, `total_tokens: 14`, and the
  CloudEvent carried those values. Streaming (`stream: true`) and
  non-streaming both produce a usage event. The event always carries
  `prompt_tokens`, `completion_tokens`, `total_tokens`, `cached_input_tokens`,
  `cache_creation_tokens` and `reasoning_tokens`, defaulting missing counts to
  zero.
- `external_metering` sample CE observed through the gateway:

  ```json
  {"specversion":"1.0","id":"5fde71e14eebd8de16f3000000000000",
   "source":"maas-gateway","type":"inference.tokens.used",
   "subject":"cluster_admin","datacontenttype":"application/json",
   "time":"2026-11-09T21:15:40Z",
   "data":{"cache_creation_tokens":0,"cached_input_tokens":0,
           "completion_tokens":3,"cost_center":"","duration_ms":15,
           "group":"","model":"facebook/opt-125m","organization_id":"",
           "prompt_tokens":11,"provider":"","reasoning_tokens":0,
           "subscription":"","total_tokens":14,"user":"cluster_admin",
           "user_agent":"curl/8.18.0"}}
  ```
- Emit strategy chosen (per-slice vs multi-field): multi-field, one event per
  response carrying all token types.
- Custom filter / projector required? No. The stock Rust filter emits the
  CloudEvent and performs the entitlement preflight. The Go
  `external-metering` IPP plugin exists as an alternative but is not needed for
  the MaaS external-model path.
- OpenMeter JSONPaths final: meter `tokens_total`, event type
  `inference.tokens.used`, `SUM` aggregation on `$.total_tokens`. Feature key
  must be `inference_tokens` because OpenMeter feature and meter slugs allow
  only lowercase alphanumerics and underscores.
- Talk-back ↔ customer key mapping: OpenMeter customer key = MaaS username,
  with `usageAttribution.subjectKeys` set to the same value so the CloudEvent
  `subject` is attributed correctly. Keys must match
  `^[a-z0-9]+(?:_[a-z0-9]+)*$`; hyphenated OpenShift usernames (for example
  `htpasswd-cluster-admin-user`) are rejected with HTTP 400, so the PoC uses
  `cluster_admin`. A productized integration needs a deterministic
  username → valid-key mapping.
- Entitlements in `v1.0.0-beta.213` are created under the subject:
  `POST /api/v1/subjects/{subject}/entitlements`. The
  `/api/v1/customers/{key}/entitlements` routes return 404. The balance path
  returns 200 with `hasAccess`, usage and balance when an entitlement exists,
  404 when none exists (`fail_open` admits the request), and the filter rejects
  with HTTP 429 `token budget exhausted` when usage exceeds the grant.
- No consumer ever joined a Kafka group until the replication factor was fixed.
  The bundled Bitnami Kafka defaults to `offsets.topic.replication.factor=3`
  on a single broker, so `__consumer_offsets` never gets created, the sink
  worker silently consumes nothing, and events stay invisible while the ingest
  API keeps returning 204. `deploy/openmeter/values-openshift.yaml` sets
  `kafka.extraConfigYaml` with replication factor and min ISR of 1.
- OpenShift service ports and NetworkPolicy: the `payload-processing`
  NetworkPolicy allows only DNS and TCP 443/6443 egress, and OVN matches the
  policy after service DNAT. A service port 443 → pod 8080 mapping is blocked.
  The OpenMeter API therefore listens on 6443 (unprivileged for the restricted
  SCC, which refuses even `NET_BIND_SERVICE` binds to 443) and the filter calls
  it over plain HTTP on that port.
- TLS to the API route from the filter does not work in this cluster: the
  router's edge certificate is self-signed for the wildcard apps domain and
  the filter's HTTP client is built at startup with a fixed root store, so
  mounting the router CA and setting `SSL_CERT_FILE` does not help. The filter
  also caches its HTTP client, so a `metering_url` change needs an ExtProc
  restart even though the config file hot-reloads.
- Controller ownership: `ai-gateway-controller` renders
  `payload-processing-plugins` and the `payload-processing` Deployment itself,
  so a manual `extproc.yaml` edit is reverted within about 30 seconds.
  `scripts/enable-maas-metering.sh` patches the ConfigMap and immediately
  restarts the Deployment so the new pod starts with the metered config; a
  durable productized solution needs a supported extension point in the
  controller template.
- OpenMeter image gaps in `v1.0.0-beta.213`: the image does not contain
  `openmeter-billing-worker` or `openmeter-jobs`, so the billing worker and
  billing CronJobs cannot run (billing is disabled/suspended), and the API
  serves only `/api/v1` (no `/api/v2`).

---

## 14. References

### Product

- MaaS metering one-pager + talk-back working tab (`METERING_PROPOSAL/`)
- Price Tag entitlement shape (`hasAccess`) as prior art for talk-back mapping

### Praxis

- https://praxis.fast/ai/v0.8.0/filters/token_count/
- https://praxis.fast/ai/v0.8.0/filters/external_metering/
- https://praxis.fast/ai/v0.8.0/examples/configs/token-counting.yaml/
- https://praxis.fast/ai/v0.8.0/examples/configs/stream-usage-inject.yaml/

### OpenMeter

- https://openmeter.io/docs/metering/events/usage-events
- https://openmeter.io/docs/metering/guides/common-examples (LLM tokens)
- https://openmeter.io/docs/billing/entitlements/quickstart
- https://openmeter.io/docs/product-catalog/feature (`meterGroupByFilters`)

### GenAI semconv

- https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/ (moved notice)
- https://github.com/open-telemetry/semantic-conventions-genai
- https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/registry/attributes/gen-ai.md

---

## 15. Decision summary (one paragraph)

We will prove the metering proposal’s export + external-pricing + entitlement talk-back loop by driving **Praxis `token_count`** (and stock metering filters where they fit) into **OpenMeter** via **GenAI-aligned CloudEvents**, with differentiated prices by **model × token type**, and a **minimal talk-back HTTP API** that surfaces OpenMeter go/no-go for principal/subscription/(org). Custom Praxis work is allowed only after a documented spike shows stock `external_metering` cannot satisfy multi-type GenAI-shaped emit; sync hot-path balance checks remain an optional labeled demo, not the product lean.
