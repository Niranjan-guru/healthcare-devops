"use strict";

const $ = (id) => document.getElementById(id);
const TOKEN = document.querySelector('meta[name="panel-token"]').content;
let switching = false;
let production = "";

async function getJson(path) {
  const response = await fetch(path, { cache: "no-store" });
  return response.json();
}

function setButtons() {
  $("btn-blue").disabled = switching || production === "blue";
  $("btn-green").disabled = switching || production === "green";
}

async function refreshLive() {
  try {
    const body = await getJson("/api/live");
    if (body.error) throw new Error(body.error);
    $("now").dataset.env = body.environment;
    $("now-env").textContent = body.environment.toUpperCase();
    $("now-version").textContent = `version ${body.version}`;
  } catch (err) {
    $("now").dataset.env = "unknown";
    $("now-env").textContent = "…";
    $("now-version").textContent = "waiting for the website";
  }
}

async function refreshStatus() {
  try {
    const body = await getJson("/api/status");
    const c = body.cluster || {};
    if (c.error) { $("status").textContent = c.error; return; }
    production = c.production;
    const describe = (name) => {
      const e = (c.environments || {})[name];
      if (!e) return "not deployed";
      const state = c.production === name ? "ON (live)" : (e.desired > 0 ? "ON (idle)" : "OFF");
      return `${state}${e.version ? " · " + e.version : ""}`;
    };
    $("status").textContent = `Blue: ${describe("blue")}   |   Green: ${describe("green")}`;
    setButtons();
  } catch (err) {
    $("status").textContent = "cannot reach the panel server";
  }
}

async function turnOn(env) {
  switching = true;
  setButtons();
  const result = $("result");
  result.hidden = false;
  result.className = "result";
  $("result-title").textContent = `Turning ON ${env}… (a few seconds; up to a minute if it was OFF)`;
  $("steps").replaceChildren();
  try {
    const response = await fetch("/api/switch", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Panel-Token": TOKEN },
      body: JSON.stringify({ environment: env }),
    });
    const body = await response.json();
    result.className = "result " + (body.ok ? "ok" : "err");
    $("result-title").textContent = body.ok
      ? `Done in ${body.seconds}s - the website now runs on ${env.toUpperCase()}. Click "Open the website".`
      : "Switch failed - the website was left as it was.";
    for (const step of body.steps || [body.error || "unknown error"]) {
      const li = document.createElement("li");
      li.textContent = step;
      $("steps").append(li);
    }
  } catch (err) {
    result.className = "result err";
    $("result-title").textContent = "Could not reach the panel server.";
  } finally {
    switching = false;
    await refreshStatus();
    await refreshLive();
  }
}

$("btn-blue").addEventListener("click", () => turnOn("blue"));
$("btn-green").addEventListener("click", () => turnOn("green"));
refreshStatus();
refreshLive();
setInterval(refreshLive, 2000);
setInterval(refreshStatus, 6000);
