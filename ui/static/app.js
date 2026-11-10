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

    tr.append(name, meter, model, price);
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
$("#reset").addEventListener("click", load);

load();
