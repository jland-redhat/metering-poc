const state = { rows: [] };

const $ = (sel) => document.querySelector(sel);

function banner(message, kind) {
  const el = $("#banner");
  if (!message) {
    el.hidden = true;
    return;
  }
  el.hidden = false;
  el.className = `banner ${kind || ""}`;
  el.textContent = message;
}

function setStatus(message, kind) {
  const el = $("#status");
  el.textContent = message || "";
  el.className = `status ${kind || ""}`;
}

function render(data) {
  state.rows = data.rateCards;
  $("#plan-key").textContent = data.plan.key;
  $("#plan-version").textContent = data.plan.version;
  $("#plan-status").textContent = data.plan.status;

  const body = $("#prices tbody");
  body.replaceChildren();

  for (const row of data.rateCards) {
    const tr = document.createElement("tr");

    const name = document.createElement("td");
    const strong = document.createElement("strong");
    strong.textContent = row.name;
    name.append(strong);
    const key = document.createElement("div");
    key.className = "model";
    key.textContent = row.key;
    name.append(key);

    const meter = document.createElement("td");
    meter.className = "model";
    meter.textContent = row.meterSlug || "";

    const model = document.createElement("td");
    model.className = "model";
    model.textContent = row.model;

    const price = document.createElement("td");
    const input = document.createElement("input");
    input.type = "number";
    input.min = "0";
    input.step = "0.0001";
    input.value = row.amount;
    input.dataset.key = row.key;
    input.dataset.original = row.amount;
    input.setAttribute("aria-label", `Unit price for ${row.name}`);
    input.addEventListener("input", () => {
      input.classList.toggle("dirty", input.value !== input.dataset.original);
    });
    price.append(input);

    const per1k = document.createElement("td");
    per1k.className = "model num";
    per1k.textContent = row.per1k == null ? "—" : `$${row.per1k}`;

    const per1m = document.createElement("td");
    per1m.className = "model num";
    per1m.textContent = row.per1m == null ? "—" : `$${row.per1m}`;

    tr.append(name, meter, model, price, per1k, per1m);
    body.append(tr);
  }

  const subs = $("#sub-list");
  subs.replaceChildren();
  for (const sub of data.subscriptions) {
    const li = document.createElement("li");
    li.textContent = `${sub.customer} — ${sub.id} — v${sub.version} — `;
    const status = document.createElement("span");
    status.textContent = sub.status;
    if (sub.status === "active") status.className = "active";
    li.append(status);
    subs.append(li);
  }
  if (!data.subscriptions.length) {
    const li = document.createElement("li");
    li.textContent = "No subscriptions found.";
    subs.append(li);
  }
}

function renderBudgets(rows) {
  const body = $("#budget-table tbody");
  body.replaceChildren();

  for (const row of rows) {
    const tr = document.createElement("tr");

    const subject = document.createElement("td");
    const strong = document.createElement("strong");
    strong.textContent = row.subject;
    subject.append(strong);
    if (row.featureKey) {
      const key = document.createElement("div");
      key.className = "model";
      key.textContent = row.featureKey;
      subject.append(key);
    }

    const isUsd = row.unit === "USD";
    const fmt = (v) => (v == null ? "—" : isUsd ? `$${Number(v).toFixed(4)}` : v);

    const usage = document.createElement("td");
    usage.className = "model";
    usage.textContent = fmt(row.usage);

    const budget = document.createElement("td");
    const input = document.createElement("input");
    input.type = "number";
    input.min = "0";
    input.step = isUsd ? "0.01" : "1";
    input.value = row.budget ?? "";
    input.dataset.subject = row.subject;
    input.setAttribute(
      "aria-label",
      `Budget for ${row.subject} in ${row.unit || "tokens"}`,
    );
    budget.append(input);

    const unit = document.createElement("div");
    unit.className = "model";
    unit.textContent = row.unit || "tokens";
    budget.append(unit);

    const balance = document.createElement("td");
    balance.className = "model";
    balance.textContent = fmt(row.balance);

    const spent = document.createElement("td");
    spent.className = "model";
    spent.textContent = row.spent == null ? "—" : `$${row.spent}`;
    const access = document.createElement("td");
    const badge = document.createElement("span");
    badge.textContent = row.hasAccess ? "allowed" : "cut off";
    badge.className = row.hasAccess ? "active" : "denied";
    access.append(badge);

    const action = document.createElement("td");
    const save = document.createElement("button");
    save.type = "button";
    save.className = "secondary small";
    save.textContent = "Save budget";
    save.addEventListener("click", () =>
      saveBudget(row.subject, row.featureKey, row.unit, input, save),
    );
    action.append(save);

    tr.append(subject, usage, budget, balance, spent, access, action);
    body.append(tr);
  }

  if (!rows.length) {
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.colSpan = 7;
    td.textContent = "No metered entitlements found.";
    tr.append(td);
    body.append(tr);
  }
}

async function loadBudgets() {
  try {
    const res = await fetch("/api/budgets");
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    renderBudgets(data.rows);
  } catch (err) {
    banner(`Could not load budgets: ${err.message}`, "err");
  }
}

async function saveBudget(subject, featureKey, unit, input, button) {
  button.disabled = true;
  banner("");
  try {
    const res = await fetch("/api/budgets", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ subject, featureKey, amount: input.value }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    const label = unit === "USD" ? "$" : "";
    banner(
      data.changed
        ? `Budget for ${subject} (${featureKey}): ${label}${data.oldBudget} → ${label}${data.newBudget}.`
        : data.message,
      data.changed ? "ok" : "",
    );
    await loadBudgets();
  } catch (err) {
    banner(`Budget change failed: ${err.message}`, "err");
  } finally {
    button.disabled = false;
  }
}

async function load() {
  setStatus("Loading…");
  try {
    const res = await fetch("/api/state");
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    render(data);
    setStatus("");
  } catch (err) {
    setStatus("");
    banner(`Could not load state: ${err.message}`, "err");
  }
}

async function save() {
  const inputs = [...document.querySelectorAll("#prices input[type=number]")];
  const prices = {};
  for (const input of inputs) {
    if (input.value === "") {
      banner(`Price for ${input.dataset.key} is empty.`, "err");
      return;
    }
    prices[input.dataset.key] = input.value;
  }

  $("#save").disabled = true;
  setStatus("Saving…");
  banner("");
  try {
    const res = await fetch("/api/prices", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ prices }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);

    if (data.changed) {
      render(data.state);
      const moved = data.moved.length;
      const failed = data.errors.length;
      let message = `Published plan v${data.newVersion} (was v${data.oldVersion}). Moved ${moved} subscription${moved === 1 ? "" : "s"}.`;
      if (failed) {
        message += `\n${failed} subscription change${failed === 1 ? "" : "s"} failed:\n` +
          data.errors.map((e) => `  ${e.customer} ${e.subscription}: ${e.error}`).join("\n");
      }
      banner(message, failed ? "err" : "ok");
      setStatus("");
    } else {
      banner(data.message, "");
      setStatus("");
    }
  } catch (err) {
    setStatus("");
    banner(`Save failed: ${err.message}`, "err");
  } finally {
    $("#save").disabled = false;
  }
}

$("#save").addEventListener("click", save);
$("#reset").addEventListener("click", () => {
  load();
  loadBudgets();
});

load();
loadBudgets();
