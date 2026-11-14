// Healthcare Appointment Desk - frontend logic.
// All dynamic values are rendered with textContent (never as HTML markup), so
// user-supplied text such as patient names cannot inject markup.
"use strict";

const $ = (id) => document.getElementById(id);
const POLL_MS = 3000;
let currentEnv = document.body.dataset.env;
let currentVersion = $("env-version").textContent;

function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

async function getJson(url, options = {}) {
  const response = await fetch(url, { cache: "no-store", headers: { Accept: "application/json" }, ...options });
  const body = await response.json().catch(() => ({}));
  return { ok: response.ok, status: response.status, body };
}

function showToast(message) {
  const toast = $("toast");
  toast.textContent = message;
  toast.hidden = false;
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => { toast.hidden = true; }, 6000);
}

// ---- Live deployment banner (shows blue/green switches as they happen) ----
async function refreshDeployment() {
  try {
    const { ok, body } = await getJson("/api/deployment");
    if (!ok) throw new Error("status");
    if (body.environment !== currentEnv || body.version !== currentVersion) {
      showToast(`Traffic switched: ${currentEnv.toUpperCase()} (${currentVersion}) → ${body.environment.toUpperCase()} (${body.version})`);
      currentEnv = body.environment;
      currentVersion = body.version;
    }
    document.body.dataset.env = body.environment;
    $("env-name").textContent = body.environment.toUpperCase();
    $("env-word").textContent = body.environment.charAt(0).toUpperCase() + body.environment.slice(1);
    $("env-version").textContent = body.version;
    $("env-pod").textContent = body.pod;
    $("live-state").textContent = `live · ${new Date().toLocaleTimeString()}`;
    $("live-state").classList.remove("stale");
  } catch (err) {
    $("live-state").textContent = "connection lost - retrying";
    $("live-state").classList.add("stale");
  }
}

// ---- Doctors ------------------------------------------------------------------
async function loadDoctors() {
  const list = $("doctors");
  const select = $("doctor");
  const { ok, body } = await getJson("/api/doctors");
  list.replaceChildren();
  select.replaceChildren();
  if (!ok || !Array.isArray(body)) {
    list.append(el("li", "Could not load doctors.", "muted"));
    return;
  }
  for (const doctor of body) {
    const item = el("li");
    const initials = doctor.name.replace(/^Dr\.?\s*/, "").split(/\s+/).map((p) => p[0]).join("").slice(0, 2);
    const info = el("div");
    info.append(el("div", doctor.name, "doc-name"), el("div", doctor.specialty, "doc-spec"));
    item.append(el("span", initials, "avatar"), info);
    list.append(item);

    const option = el("option", `${doctor.name} — ${doctor.specialty}`);
    option.value = String(doctor.id);
    select.append(option);
  }
}

// ---- Appointments -------------------------------------------------------------
async function loadAppointments() {
  const tbody = $("appointments");
  const { ok, body } = await getJson("/api/appointments");
  tbody.replaceChildren();
  if (!ok || !Array.isArray(body)) {
    const row = el("tr"); const cell = el("td", "Could not load appointments.", "muted"); cell.colSpan = 5;
    row.append(cell); tbody.append(row);
    return;
  }
  if (body.length === 0) {
    const row = el("tr"); const cell = el("td", "No appointments on this instance yet.", "muted"); cell.colSpan = 5;
    row.append(cell); tbody.append(row);
    return;
  }
  for (const a of body) {
    const row = el("tr");
    const status = el("td"); status.append(el("span", a.status, "badge"));
    row.append(el("td", String(a.id)), el("td", a.patient_name), el("td", a.doctor), el("td", a.appointment_date), status);
    tbody.append(row);
  }
}

async function book(event) {
  event.preventDefault();
  const result = $("booking-result");
  const button = $("book-btn");
  result.className = "result";
  result.textContent = "";
  const payload = {
    doctor_id: Number($("doctor").value),
    patient_name: $("patient").value,
    appointment_date: $("date").value,
  };
  button.disabled = true;
  try {
    const { ok, status, body } = await getJson("/api/appointments", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(payload),
    });
    if (ok) {
      const a = body.appointment;
      result.classList.add("ok");
      result.textContent = `Booked #${a.id}: ${a.patient_name} with ${a.doctor} on ${a.appointment_date}.`;
      $("booking").reset();
      setDefaultDate();
      loadAppointments();
    } else {
      result.classList.add("err");
      result.textContent = `Not booked (${status}): ${body.error || "unexpected error"}`;
    }
  } catch (err) {
    result.classList.add("err");
    result.textContent = "Network error - please try again.";
  } finally {
    button.disabled = false;
  }
}

function setDefaultDate() {
  const tomorrow = new Date(Date.now() + 86400000);
  $("date").value = tomorrow.toISOString().slice(0, 10);
  $("date").min = new Date().toISOString().slice(0, 10);
}

$("booking").addEventListener("submit", book);
$("refresh-btn").addEventListener("click", loadAppointments);
setDefaultDate();
loadDoctors();
loadAppointments();
refreshDeployment();
setInterval(refreshDeployment, POLL_MS);
