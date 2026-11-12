const $ = (sel) => document.querySelector(sel);

let meters = [];

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

function setStatus(sel, message, kind) {
  const el = $(sel);
  el.textContent = message || "";
  el.className = `status ${kind || ""}`;
}

function cell(text, className) {
  const td = document.createElement("td");
  if (className) td.className = className;
  td.textContent = text == null || text === "" ? "—" : text;
  return td;
}

function renderMeters(rows) {
  const body = $("#meter-table tbody");
  body.replaceChildren();

  for (const meter of rows) {
    const tr = document.createElement("tr");

    const slug = document.createElement("td");
    const strong = document.createElement("strong");
    strong.textContent = meter.slug;
    slug.append(strong);

    const features = cell(
      (meter.features || []).length ? meter.features.join(", ") : "no features",
      "model",
    );

    const query = document.createElement("td");
    const button = document.createElement("button");
    button.type = "button";
    button.className = "secondary small";
    button.textContent = "Query";
    button.addEventListener("click", () => {
      $("#meter-select").value = meter.slug;
      $("#query").scrollIntoView({ behavior: "smooth" });
    });
    query.append(button);

    tr.append(
      slug,
      cell(meter.name),
      cell(meter.aggregation, "model"),
      cell(meter.eventType, "model"),
      cell(meter.valueProperty, "model"),
      features,
      query,
    );
    body.append(tr);
  }

  if (!rows.length) {
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.colSpan = 7;
    td.textContent = "No meters found.";
    tr.append(td);
    body.append(tr);
  }
}

function renderFeatures(rows) {
  const body = $("#feature-table tbody");
  body.replaceChildren();

  for (const feature of rows) {
    const tr = document.createElement("tr");
    const filters = feature.meterGroupByFilters || {};
    const pairs = Object.entries(filters).map(([k, v]) => `${k}=${v}`);
    tr.append(
      cell(feature.key, "model"),
      cell(feature.name),
      cell(feature.meterSlug, "model"),
      cell(pairs.length ? pairs.join(", ") : "(all)", "model"),
    );
    body.append(tr);
  }

  if (!rows.length) {
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.colSpan = 4;
    td.textContent = "No features found.";
    tr.append(td);
    body.append(tr);
  }
}

function renderSelect(rows, aggregations) {
  const meterSelect = $("#meter-select");
  const previous = meterSelect.value;
  meterSelect.replaceChildren();
  for (const meter of rows) {
    const option = document.createElement("option");
    option.value = meter.slug;
    option.textContent = `${meter.slug} (${meter.aggregation})`;
    meterSelect.append(option);
  }
  if (previous && rows.some((m) => m.slug === previous)) {
    meterSelect.value = previous;
  }

  const aggregation = $("#aggregation");
  const chosen = aggregation.value;
  aggregation.replaceChildren();
  for (const name of aggregations || []) {
    const option = document.createElement("option");
    option.value = name;
    option.textContent = name;
    aggregation.append(option);
  }
  if (chosen && (aggregations || []).includes(chosen)) {
    aggregation.value = chosen;
  } else {
    aggregation.value = "SUM";
  }
}

function render(data) {
  meters = data.meters || [];
  renderMeters(meters);
  renderFeatures(data.features || []);
  renderSelect(meters, data.aggregations || []);
}

async function load() {
  banner("");
  try {
    const res = await fetch("/api/metrics");
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    render(data);
  } catch (err) {
    banner(`Could not load metrics: ${err.message}`, "err");
  }
}

function renderCreateResults(results) {
  const wrap = $("#create-result");
  const body = wrap.querySelector("tbody");
  body.replaceChildren();
  for (const result of results) {
    const tr = document.createElement("tr");
    tr.append(
      cell(result.step, "model"),
      cell(result.status, result.ok ? "model ok" : "model denied"),
      cell(
        typeof result.response === "string"
          ? result.response
          : JSON.stringify(result.response),
        "model",
      ),
    );
    body.append(tr);
  }
  wrap.hidden = false;
}

async function createMetric(event) {
  event.preventDefault();
  const form = event.target;
  const data = Object.fromEntries(new FormData(form).entries());
  const button = $("#create-btn");
  button.disabled = true;
  banner("");
  setStatus("#create-status", "Creating…");

  try {
    const res = await fetch("/api/metrics", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(data),
    });
    const payload = await res.json();
    renderCreateResults(payload.results || []);
    if (!res.ok) throw new Error(payload.error || `HTTP ${res.status}`);
    if (payload.state) render(payload.state);
    const failed = (payload.results || []).filter((r) => !r.ok);
    if (failed.length) {
      setStatus(
        "#create-status",
        `Created with errors: ${failed.map((f) => `${f.step} HTTP ${f.status}`).join(", ")}`,
        "err",
      );
    } else {
      setStatus("#create-status", "Created.", "ok");
      form.reset();
    }
  } catch (err) {
    banner(`Create metric failed: ${err.message}`, "err");
    setStatus("#create-status", "");
  } finally {
    button.disabled = false;
  }
}

async function queryMeter(event) {
  event.preventDefault();
  const form = event.target;
  const params = new URLSearchParams();
  for (const [key, value] of new FormData(form).entries()) {
    if (value) params.set(key, value);
  }
  const button = $("#query-btn");
  button.disabled = true;
  banner("");
  setStatus("#query-status", "Querying…");

  try {
    const res = await fetch(`/api/metrics/usage?${params.toString()}`);
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);

    const table = $("#usage-table");
    const body = table.querySelector("tbody");
    body.replaceChildren();
    for (const row of data.rows || []) {
      const tr = document.createElement("tr");
      tr.append(
        cell(row.subject),
        cell(row.model, "model"),
        cell(row.value, "model num"),
        cell(row.from && row.to ? `${row.from} → ${row.to}` : null, "model"),
      );
      body.append(tr);
    }
    if (!(data.rows || []).length) {
      const tr = document.createElement("tr");
      const td = document.createElement("td");
      td.colSpan = 4;
      td.textContent = "No values for that meter and window.";
      tr.append(td);
      body.append(tr);
    }
    $("#usage-total").textContent = data.total == null ? "—" : data.total;
    table.hidden = false;
    setStatus("#query-status", "");
  } catch (err) {
    banner(`Meter query failed: ${err.message}`, "err");
    setStatus("#query-status", "");
  } finally {
    button.disabled = false;
  }
}

$("#metric-form").addEventListener("submit", createMetric);
$("#query-form").addEventListener("submit", queryMeter);

load();
