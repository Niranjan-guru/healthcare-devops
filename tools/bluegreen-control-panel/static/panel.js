// Blue-Green control panel UI. Values are rendered with textContent only.
"use strict";

const $ = (id) => document.getElementById(id);
const TOKEN = document.querySelector('meta[name="panel-token"]').content;
const seen = [];
let busy = false;

async function api(path, options = {}) {
  const response = await fetch(path, { cache: "no-store", ...options });
  const body = await response.json().catch(() => ({}));
  return { ok: response.ok, status: response.status, body };
}

async function post(path, payload) {
  $("message").textContent = "Sending request to Jenkins…";
  const { ok, body } = await api(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Panel-Token": TOKEN },
    body: JSON.stringify(payload),
  });
  $("message").textContent = ok ? body.message : `Not started: ${body.error || "unknown error"}`;
  refreshStatus();
}

function renderEnv(env, info, productionEnv) {
  const card = $(`card-${env}`);
  const tag = $(`tag-${env}`);
  card.classList.toggle("live-now", productionEnv === env);
  if (!info) {
    tag.textContent = "NOT DEPLOYED"; tag.className = "tag off";
    $(`status-${env}`).textContent = "not deployed yet";
    $(`pods-${env}`).textContent = "-"; $(`version-${env}`).textContent = "-";
    return;
  }
  const on = info.desired > 0;
  tag.textContent = productionEnv === env ? "LIVE" : (on ? "ON (idle)" : "OFF");
  tag.className = "tag " + (productionEnv === env ? "live" : (on ? "on" : "off"));
  $(`status-${env}`).textContent = on ? (productionEnv === env ? "ON - serving production" : "ON - not serving traffic") : "OFF (scaled to 0)";
  $(`pods-${env}`).textContent = `${info.ready} / ${info.desired}`;
  $(`version-${env}`).textContent = info.verified_version || "(never verified)";
}

async function refreshStatus() {
  const { ok, body } = await api("/api/status");
  if (!ok) return;
  $("jenkins-link").href = body.jenkins_url;
  $("open-app").href = body.app_url;
  const cluster = body.cluster || {};
  const production = cluster.production ? cluster.production.selector.environment : null;
  if (cluster.environments) {
    renderEnv("blue", cluster.environments.blue, production);
    renderEnv("green", cluster.environments.green, production);
  }
  const jenkins = body.jenkins || {};
  const last = jenkins.last_build;
  busy = Boolean(jenkins.in_queue || (last && last.building) || (cluster.lock && cluster.lock.length));
  const build = $("build");
  build.replaceChildren();
  if (jenkins.error) {
    build.textContent = jenkins.error;
  } else if (last) {
    const state = last.building ? "RUNNING" : (last.result || "-");
    const link = document.createElement("a");
    link.href = last.url + "console"; link.target = "_blank"; link.rel = "noopener";
    link.textContent = last.displayName;
    const status = document.createElement("strong");
    status.textContent = ` ${state}`; status.className = `result-${state}`;
    build.append(link, status, document.createTextNode(`  ${last.description || ""}`));
    if (jenkins.in_queue) build.append(document.createTextNode("  (another build queued)"));
  }
  for (const env of ["blue", "green"]) $(`btn-${env}`).disabled = busy || production === env;
  $("btn-deploy").disabled = busy;
  $("btn-rollback").disabled = busy;
}

async function refreshLive() {
  const { body } = await api("/api/live");
  const live = $("live");
  let env = "down";
  if (body && !body.error) {
    env = body.environment;
    $("live-env").textContent = env.toUpperCase();
    $("live-version").textContent = body.version;
    $("live-pod").textContent = body.pod;
  } else {
    $("live-env").textContent = "UNREACHABLE";
    $("live-version").textContent = "-"; $("live-pod").textContent = "-";
  }
  live.dataset.env = env;
  seen.push(env);
  if (seen.length > 30) seen.shift();
  const timeline = $("timeline");
  timeline.replaceChildren(...seen.map((e) => { const s = document.createElement("span"); s.className = e; s.title = e; return s; }));
}

$("btn-blue").addEventListener("click", () => post("/api/activate", { environment: "blue", stop_previous: $("stop-previous").checked }));
$("btn-green").addEventListener("click", () => post("/api/activate", { environment: "green", stop_previous: $("stop-previous").checked }));
$("btn-deploy").addEventListener("click", () => post("/api/deploy", { stop_previous: $("stop-previous").checked }));
$("btn-rollback").addEventListener("click", () => {
  if (confirm("Switch production back to the previous environment?")) post("/api/rollback", {});
});

refreshStatus();
refreshLive();
setInterval(refreshStatus, 5000);
setInterval(refreshLive, 2000);
