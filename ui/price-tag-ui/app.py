"""Price Tag demo UI.

Demo-only companion for the Price Tag metering PoC: adjusts budgets
(quota_policy / quota_overrides) and pricing (model_pricing), and shows
recent usage from usage_events. Writes go straight to PostgreSQL — the same
rows the Price Tag admin API would write — because the admin HTTP API is
behind an OIDC session the PoC does not configure.

NOT for production: no auth, no tenancy, no TLS. Expose via
`oc port-forward` only.
"""

import os

import psycopg2
import psycopg2.extras
from flask import Flask, flash, redirect, render_template_string, request

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgres://metering:metering@price-tag-postgres.metering.svc.cluster.local:5432/metering?sslmode=disable",
)

app = Flask(__name__)
app.secret_key = os.environ.get("SESSION_SECRET", "price-tag-demo")

TEMPLATE = """
<!doctype html>
<html>
<head>
<title>Price Tag demo</title>
<style>
  body { font-family: -apple-system, sans-serif; margin: 2rem; background: #f7f7f8; color: #1a1a1a; }
  h1 { font-size: 1.4rem; } h2 { font-size: 1.1rem; margin-top: 2rem; }
  table { border-collapse: collapse; background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.08); }
  th, td { border: 1px solid #ddd; padding: .35rem .7rem; font-size: .85rem; text-align: left; }
  th { background: #eee; }
  form { display: inline-block; margin: .3rem 0; background: #fff; padding: .8rem 1rem;
         box-shadow: 0 1px 2px rgba(0,0,0,.08); }
  input, select { margin: 0 .4rem; }
  input[type=number] { width: 7rem; }
  .flash { background: #dff0d8; border: 1px solid #c9e2b0; padding: .4rem .8rem; margin: .5rem 0; }
  .muted { color: #777; font-size: .8rem; }
  .deny { color: #b00; font-weight: 600; } .ok { color: #070; }
</style>
</head>
<body>
<h1>Price Tag — budgets &amp; pricing (demo)</h1>
{% with m = get_flashed_messages() %}
  {% if m %}{% for x in m %}<div class="flash">{{ x }}</div>{% endfor %}{% endif %}
{% endwith %}

<h2>Safety-net policy (quota_policy)</h2>
<form method="post" action="/budgets/policy">
  default monthly USD <input type="number" step="0.01" name="default_monthly_usd" value="{{ policy.default_monthly_usd }}">
  enforced <select name="enforced"><option value="true" {{ 'selected' if policy.enforced }}>yes</option>
  <option value="false" {{ 'selected' if not policy.enforced }}>no</option></select>
  <button>save</button>
</form>
<div class="muted">changed by {{ policy.updated_by or '—' }} at {{ policy.updated_at }}</div>

<h2>Per-user budget overrides (quota_overrides)</h2>
<form method="post" action="/budgets/override">
  user <input name="principal" placeholder="kube:admin" required>
  monthly USD <input type="number" step="0.01" name="monthly_usd" value="0" required>
  <button>set</button>
</form>
<table>
<tr><th>user</th><th>monthly USD</th><th>changed by</th><th>at</th><th></th></tr>
{% for o in overrides %}
<tr>
  <td>{{ o.principal }}</td><td>{{ '%.2f'|format(o.monthly_usd) }}</td>
  <td>{{ o.updated_by }}</td><td>{{ o.updated_at }}</td>
  <td><form method="post" action="/budgets/override/delete"><input type="hidden" name="principal" value="{{ o.principal }}"><button>remove</button></form></td>
</tr>
{% endfor %}
</table>
<div class="muted">budget changes take up to ~60s to affect admission (Price Tag quota decision cache).</div>

<h2>Month-to-date spend per user</h2>
<table>
<tr><th>user</th><th>requests</th><th>tokens</th><th>spend USD</th></tr>
{% for s in spend %}
<tr><td>{{ s.username }}</td><td>{{ s.requests }}</td><td>{{ s.tokens }}</td><td>{{ '%.4f'|format(s.spend) }}</td></tr>
{% else %}
<tr><td colspan="4" class="muted">no usage yet</td></tr>
{% endfor %}
</table>

<h2>Admission decisions (live check)</h2>
<form method="get" action="/">
  user <input name="check_user" placeholder="kube:admin" value="{{ check_user or '' }}">
  <button>check</button>
</form>
{% if decision %}
<table>
<tr><th>user</th><th>hasAccess</th><th>denyReason</th><th>budget USD</th><th>spend USD</th><th>source</th></tr>
<tr>
  <td>{{ decision.username }}</td>
  <td class="{{ 'deny' if not decision.has_access else 'ok' }}">{{ decision.has_access }}</td>
  <td>{{ decision.deny_reason or '' }}</td>
  <td>{{ '%.2f'|format(decision.quota_usd) }}</td>
  <td>{{ '%.4f'|format(decision.spend_usd) }}</td>
  <td>{{ decision.source }}</td>
</tr>
</table>
{% endif %}

<h2>Model pricing (model_pricing)</h2>
<div class="muted">costs are USD per 1M tokens; edits only affect NEW events (past events keep their frozen cost).</div>
<form method="post" action="/pricing">
  model <input name="model" list="models" placeholder="publishers/llm/models/facebook/opt-125m" required size="40">
  <datalist id="models">{% for p in pricing %}<option value="{{ p.model }}">{% endfor %}</datalist>
  input $/Mtok <input type="number" step="0.000001" name="input_cost" required>
  output $/Mtok <input type="number" step="0.000001" name="output_cost" required>
  <button>set</button>
</form>
<table>
<tr><th>model</th><th>input $/Mtok</th><th>output $/Mtok</th></tr>
{% for p in pricing[:50] %}
<tr><td>{{ p.model }}</td><td>{{ p.input_cost_per_mtok }}</td><td>{{ p.output_cost_per_mtok }}</td></tr>
{% endfor %}
</table>
<div class="muted">showing first 50 of {{ pricing|length }} models</div>

<h2>Recent usage events</h2>
<table>
<tr><th>time</th><th>user</th><th>model</th><th>prompt</th><th>completion</th><th>cost USD</th></tr>
{% for e in events %}
<tr><td>{{ e.timestamp }}</td><td>{{ e.username }}</td><td>{{ e.model }}</td>
    <td>{{ e.prompt_tokens }}</td><td>{{ e.completion_tokens }}</td><td>{{ '%.6f'|format(e.cost_usd) }}</td></tr>
{% else %}
<tr><td colspan="6" class="muted">no events yet — send a request through the gateway</td></tr>
{% endfor %}
</table>
<script>
  // Hot reload: refresh every 10s unless the user is typing in a form.
  setInterval(function () {
    var el = document.activeElement;
    if (el && (el.tagName === 'INPUT' || el.tagName === 'SELECT')) return;
    window.location.reload();
  }, 10000);
</script>
</body>
</html>
"""


def db():
    return psycopg2.connect(DATABASE_URL)


def fetch_all(conn, sql, args=()):
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(sql, args)
        return cur.fetchall()


def quota_decision(conn, username):
    """Same resolution Price Tag's quotaDecision performs (user override > default)."""
    row = fetch_all(
        conn,
        """
        SELECT pol.default_monthly_usd, pol.enforced,
               COALESCE(ou.monthly_usd, pol.default_monthly_usd) AS quota_usd,
               CASE WHEN ou.principal IS NULL THEN 'default' ELSE 'user_override' END AS source
        FROM (SELECT default_monthly_usd, enforced FROM quota_policy WHERE id = true) pol
        LEFT JOIN quota_overrides ou ON ou.scope = 'user' AND ou.principal = %s
        """,
        (username,),
    )[0]
    spend = fetch_all(
        conn,
        """
        SELECT COALESCE(SUM(cost_usd), 0) AS spend
        FROM usage_events
        WHERE username = %s AND timestamp >= date_trunc('month', NOW())
        """,
        (username,),
    )[0]["spend"]
    has_access = (not row["enforced"]) or spend < float(row["quota_usd"])
    return {
        "username": username,
        "has_access": has_access,
        "deny_reason": None if has_access else "quota_exhausted",
        "quota_usd": float(row["quota_usd"]),
        "spend_usd": float(spend),
        "source": row["source"],
    }


@app.route("/")
def index():
    check_user = request.args.get("check_user", "").strip()
    with db() as conn:
        policy = fetch_all(
            conn,
            "SELECT default_monthly_usd, enforced, updated_by, updated_at FROM quota_policy WHERE id = true",
        )[0]
        overrides = fetch_all(
            conn,
            "SELECT principal, monthly_usd, updated_by, updated_at FROM quota_overrides ORDER BY principal",
        )
        spend = fetch_all(
            conn,
            """
            SELECT username, COUNT(*) AS requests,
                   COALESCE(SUM(prompt_tokens + completion_tokens), 0) AS tokens,
                   COALESCE(SUM(cost_usd), 0) AS spend
            FROM usage_events
            WHERE timestamp >= date_trunc('month', NOW())
            GROUP BY username ORDER BY spend DESC
            """,
        )
        pricing = fetch_all(
            conn,
            "SELECT model, input_cost_per_mtok, output_cost_per_mtok FROM model_pricing ORDER BY model",
        )
        events = fetch_all(
            conn,
            "SELECT timestamp, username, model, prompt_tokens, completion_tokens, cost_usd "
            "FROM usage_events ORDER BY timestamp DESC LIMIT 25",
        )
        decision = quota_decision(conn, check_user) if check_user else None
    return render_template_string(
        TEMPLATE,
        policy=policy,
        overrides=overrides,
        spend=spend,
        pricing=pricing,
        events=events,
        decision=decision,
        check_user=check_user,
    )


@app.route("/budgets/policy", methods=["POST"])
def save_policy():
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE quota_policy SET default_monthly_usd = %s, enforced = %s, "
                "updated_by = 'demo-ui', updated_at = NOW() WHERE id = true",
                (request.form["default_monthly_usd"], request.form["enforced"] == "true"),
            )
    flash("safety-net policy updated")
    return redirect("/")


@app.route("/budgets/override", methods=["POST"])
def save_override():
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO quota_overrides (scope, principal, monthly_usd, updated_by) "
                "VALUES ('user', %s, %s, 'demo-ui') "
                "ON CONFLICT (scope, principal) DO UPDATE SET monthly_usd = EXCLUDED.monthly_usd, "
                "updated_by = EXCLUDED.updated_by, updated_at = NOW()",
                (request.form["principal"].strip(), request.form["monthly_usd"]),
            )
    flash("override saved for " + request.form["principal"])
    return redirect("/")


@app.route("/budgets/override/delete", methods=["POST"])
def delete_override():
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "DELETE FROM quota_overrides WHERE scope = 'user' AND principal = %s",
                (request.form["principal"],),
            )
    flash("override removed for " + request.form["principal"])
    return redirect("/")


@app.route("/pricing", methods=["POST"])
def save_pricing():
    with db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE model_pricing SET input_cost_per_mtok = %s, output_cost_per_mtok = %s "
                "WHERE model = %s",
                (
                    request.form["input_cost"],
                    request.form["output_cost"],
                    request.form["model"].strip(),
                ),
            )
            if cur.rowcount == 0:
                cur.execute(
                    "INSERT INTO model_pricing (model, provider, input_cost_per_mtok, output_cost_per_mtok) "
                    "VALUES (%s, '', %s, %s)",
                    (
                        request.form["model"].strip(),
                        request.form["input_cost"],
                        request.form["output_cost"],
                    ),
                )
    flash("pricing saved for " + request.form["model"])
    return redirect("/")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
