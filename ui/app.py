"""Minimal price editor for the OpenMeter MaaS metering PoC.

Serves one page that lists the unit prices on the active version of an
OpenMeter plan and lets an operator change them. A change creates the next
plan version, publishes it, and moves active customer subscriptions onto the
new version with immediate timing.

Environment:
  OPENMETER_URL   base URL of the OpenMeter API (default: in-cluster service)
  PLAN_KEY        plan key to edit (default: inference_payg)
  CUSTOMER_KEY    optional; when set, only this customer's subscriptions move
  PORT            listen port (default: 8080)
"""

import os

import requests
from flask import Flask, jsonify, render_template, request

OPENMETER_URL = os.environ.get(
    "OPENMETER_URL", "http://openmeter-api.metering.svc.cluster.local:6443"
).rstrip("/")
PLAN_KEY = os.environ.get("PLAN_KEY", "inference_payg")
CUSTOMER_KEY = os.environ.get("CUSTOMER_KEY", "")
PORT = int(os.environ.get("PORT", "8080"))

app = Flask(__name__)


class OpenMeterError(Exception):
    def __init__(self, message, status=502):
        super().__init__(message)
        self.status = status


def api(method, path, body=None):
    url = f"{OPENMETER_URL}{path}"
    try:
        resp = requests.request(method, url, json=body, timeout=15)
    except requests.RequestException as exc:
        raise OpenMeterError(f"cannot reach OpenMeter at {OPENMETER_URL}: {exc}") from exc
    if resp.status_code >= 400:
        detail = resp.text[:500]
        try:
            detail = resp.json().get("detail", detail)
        except ValueError:
            pass
        raise OpenMeterError(f"{method} {path} returned {resp.status_code}: {detail}", 502)
    if not resp.content:
        return None
    return resp.json()


def list_plans():
    data = api("GET", f"/api/v1/plans?key={PLAN_KEY}")
    items = data.get("items", []) if isinstance(data, dict) else data
    return [p for p in items if p.get("key") == PLAN_KEY]


def active_plan():
    plans = list_plans()
    for plan in plans:
        if plan.get("status") == "active":
            return plan
    if not plans:
        raise OpenMeterError(f"plan {PLAN_KEY} not found", 404)
    return max(plans, key=lambda p: p.get("version", 0))


def features_by_key():
    data = api("GET", "/api/v1/features")
    items = data.get("items", []) if isinstance(data, dict) else data
    return {f.get("key"): f for f in items or []}


def customers():
    """Return customer records (key plus id).

    The subscription list endpoint takes a customer id or key, but some keys
    (for example htpasswd-cluster-admin-user) contain hyphens, which the path
    validator rejects; always address customers by id when one is available.
    """
    data = api("GET", "/api/v1/customers")
    items = data.get("items", []) if isinstance(data, dict) else data
    records = [
        {"key": c.get("key"), "id": c.get("id")}
        for c in items or []
        if c.get("key")
    ]
    if CUSTOMER_KEY:
        records = [c for c in records if c["key"] == CUSTOMER_KEY]
    return records


def customer_subscriptions(customer):
    ref = customer.get("id") or customer.get("key")
    data = api("GET", f"/api/v1/customers/{ref}/subscriptions")
    items = data.get("items", []) if isinstance(data, dict) else data
    return items or []


def describe(plan, features):
    """Flatten a plan's rate cards into display rows."""
    rows = []
    for phase in plan.get("phases", []):
        for card in phase.get("rateCards", []):
            feature = features.get(card.get("featureKey"), {})
            price = card.get("price") or {}
            filters = feature.get("meterGroupByFilters") or {}
            rows.append(
                {
                    "key": card.get("key"),
                    "name": card.get("name"),
                    "featureKey": card.get("featureKey"),
                    "meterSlug": feature.get("meterSlug") or card.get("meterSlug"),
                    "model": filters.get("model") or "(all models)",
                    "priceType": price.get("type"),
                    "amount": price.get("amount"),
                }
            )
    return rows


def current_state():
    plan = active_plan()
    features = features_by_key()
    subs = []
    for customer in customers():
        try:
            subscriptions = customer_subscriptions(customer)
        except OpenMeterError:
            continue
        for sub in subscriptions:
            subs.append(
                {
                    "id": sub.get("id"),
                    "customer": customer.get("key"),
                    "status": sub.get("status"),
                    "version": (sub.get("plan") or {}).get("version"),
                }
            )
    return {
        "plan": {
            "key": plan.get("key"),
            "name": plan.get("name"),
            "version": plan.get("version"),
            "status": plan.get("status"),
            "currency": plan.get("currency"),
        },
        "rateCards": describe(plan, features),
        "subscriptions": subs,
        "config": {"openmeterUrl": OPENMETER_URL, "planKey": PLAN_KEY},
    }


def apply_prices(new_amounts):
    """Create a new plan version with the given prices and publish it."""
    plan = active_plan()
    features = features_by_key()
    old_rows = {row["key"]: row for row in describe(plan, features)}

    unknown = set(new_amounts) - set(old_rows)
    if unknown:
        raise OpenMeterError(f"unknown rate card key(s): {', '.join(sorted(unknown))}", 400)

    balances = {}
    for key, row in old_rows.items():
        amount = new_amounts.get(key, row["amount"])
        try:
            value = float(amount)
        except (TypeError, ValueError):
            raise OpenMeterError(f"price for {key} is not a number: {amount!r}", 400)
        if value < 0:
            raise OpenMeterError(f"price for {key} must not be negative", 400)
        balances[key] = value

    if all(abs(balances[k] - float(old_rows[k]["amount"])) < 1e-12 for k in balances):
        return {"changed": False, "message": "prices unchanged; no new version created"}

    draft = api("POST", f"/api/v1/plans/{PLAN_KEY}/next")
    draft_id = draft.get("id")

    phases = []
    for phase in draft.get("phases", []):
        cards = []
        for card in phase.get("rateCards", []):
            cards.append(
                {
                    "type": "usage_based",
                    "key": card.get("key"),
                    "name": card.get("name"),
                    "featureKey": card.get("featureKey"),
                    "billingCadence": card.get("billingCadence"),
                    "price": {
                        "type": "unit",
                        "amount": f"{balances[card.get('key')]:.10g}",
                    },
                }
            )
        phases.append(
            {
                "key": phase.get("key"),
                "name": phase.get("name"),
                "duration": phase.get("duration"),
                "rateCards": cards,
            }
        )

    api(
        "PUT",
        f"/api/v1/plans/{draft_id}",
        {"name": draft.get("name"), "phases": phases},
    )
    published = api("POST", f"/api/v1/plans/{draft_id}/publish")
    new_version = published.get("version")

    moved = []
    errors = []
    for customer in customers():
        label = customer.get("key")
        try:
            subscriptions = customer_subscriptions(customer)
        except OpenMeterError as exc:
            errors.append({"subscription": None, "customer": label, "error": str(exc)})
            continue
        for sub in subscriptions:
            if sub.get("status") != "active":
                continue
            if (sub.get("plan") or {}).get("version") != plan.get("version"):
                continue
            try:
                api(
                    "POST",
                    f"/api/v1/subscriptions/{sub.get('id')}/change",
                    {"plan": {"key": PLAN_KEY, "version": new_version}, "timing": "immediate"},
                )
                moved.append({"subscription": sub.get("id"), "customer": label})
            except OpenMeterError as exc:
                errors.append({"subscription": sub.get("id"), "customer": label, "error": str(exc)})

    return {
        "changed": True,
        "oldVersion": plan.get("version"),
        "newVersion": new_version,
        "moved": moved,
        "errors": errors,
    }


@app.get("/")
def index():
    return render_template("index.html", plan_key=PLAN_KEY)


@app.get("/healthz")
def healthz():
    return "ok"


@app.get("/api/state")
def state():
    try:
        return jsonify(current_state())
    except OpenMeterError as exc:
        return jsonify({"error": str(exc)}), exc.status


def usage_costs(start, end):
    """Combine meter usage with the active plan's unit prices.

    Returns one row per (customer, meter, model) with tokens and cost, so that
    a dashboard can show live spend without reimplementing price arithmetic.
    """
    plan = active_plan()
    features = features_by_key()
    rates = {}
    for row in describe(plan, features):
        try:
            amount = float(row["amount"])
        except (TypeError, ValueError):
            continue
        rates[(row["meterSlug"], row["model"])] = (amount, row["key"])

    rows = []
    for meter_slug in sorted({slug for slug, _ in rates}):
        data = api(
            "GET",
            f"/api/v1/meters/{meter_slug}/query?from={start}&to={end}"
            "&groupBy=subject&groupBy=model",
        )
        for point in data.get("data", []) or []:
            subject = point.get("subject")
            model = (point.get("groupBy") or {}).get("model")
            tokens = point.get("value") or 0
            amount, card = rates.get((meter_slug, model), (None, None))
            rows.append(
                {
                    "subject": subject,
                    "meter": meter_slug,
                    "model": model or "(none)",
                    "tokens": tokens,
                    "unitPrice": amount,
                    "rateCard": card,
                    "cost": round(tokens * amount, 8) if amount is not None else None,
                    "from": point.get("windowStart"),
                    "to": point.get("windowEnd"),
                }
            )
    return {"plan": {"key": plan.get("key"), "version": plan.get("version")}, "rows": rows}


@app.get("/api/costs")
def costs():
    start = request.args.get("from", "1970-01-01T00:00:00Z")
    end = request.args.get("to", "2100-01-01T00:00:00Z")
    try:
        return jsonify(usage_costs(start, end))
    except OpenMeterError as exc:
        return jsonify({"error": str(exc)}), exc.status


@app.post("/api/prices")
def set_prices():
    payload = request.get_json(silent=True) or {}
    amounts = payload.get("prices")
    if not isinstance(amounts, dict) or not amounts:
        return jsonify({"error": "body must be {\"prices\": {\"<rateCardKey>\": <amount>}}"}), 400
    try:
        result = apply_prices(amounts)
        result["state"] = current_state()
        return jsonify(result)
    except OpenMeterError as exc:
        return jsonify({"error": str(exc)}), exc.status


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
