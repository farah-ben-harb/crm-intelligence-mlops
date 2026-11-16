const $ = (selector) => document.querySelector(selector);

const state = { profiles: [], modelInfo: null };

function setStatus(element, value, ok = null) {
  element.textContent = value;
  element.classList.toggle("ok", ok === true);
  element.classList.toggle("error", ok === false);
}

function initials(name) {
  return name.split(" ").map((part) => part[0]).join("").slice(0, 2);
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;",
  }[char]));
}

function renderProfiles(profiles) {
  $("#profile-count").textContent = profiles.length;
  $("#profile-list").innerHTML = profiles.map((profile) => `
    <article class="profile-item">
      <div class="profile-avatar">${escapeHtml(initials(profile.name))}</div>
      <div><h3>${escapeHtml(profile.name)}</h3><div class="skill-list">
        ${profile.skills.map((skill) => `<span class="skill">${escapeHtml(skill)}</span>`).join("")}
      </div></div>
    </article>`).join("");
}

function renderError(selector, message) {
  $(selector).innerHTML = `<div class="error-state">${escapeHtml(message)}</div>`;
}

async function fetchJson(path, options = {}) {
  const response = await fetch(path, { headers: { Accept: "application/json" }, ...options });
  if (!response.ok) {
    let detail = `Request failed (${response.status})`;
    try { detail = (await response.json()).detail || detail; } catch (_) { /* keep status */ }
    throw new Error(detail);
  }
  return response.json();
}

async function loadDashboard() {
  const checkedAt = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  $("#last-checked").textContent = `Checked ${checkedAt}`;
  try {
    const [profiles, health, ready, modelInfo] = await Promise.all([
      fetchJson("/profiles"), fetchJson("/health"), fetchJson("/ready"), fetchJson("/model-info"),
    ]);
    state.profiles = profiles; state.modelInfo = modelInfo;
    renderProfiles(profiles);
    setStatus($("#api-status"), health.status === "healthy" ? "Healthy" : health.status, health.status === "healthy");
    setStatus($("#health-value"), health.status === "healthy" ? "Operational" : health.status, health.status === "healthy");
    setStatus($("#model-status"), ready.status === "ready" ? "Ready" : ready.status, ready.status === "ready");
    setStatus($("#ready-value"), ready.status === "ready" ? "Loaded" : ready.status, ready.status === "ready");
    $("#api-status-dot").classList.add("ok"); $("#model-status-dot").classList.add("ok");
    $("#model-source").textContent = modelInfo.source || "Not reported";
    $("#model-version").textContent = modelInfo.version_id || "Not reported";
    $("#model-sha").textContent = modelInfo.sha256 || "Not reported";
  } catch (error) {
    setStatus($("#api-status"), "Unavailable", false); setStatus($("#model-status"), "Unavailable", false);
    $("#api-status-dot").classList.add("error"); $("#model-status-dot").classList.add("error");
    setStatus($("#health-value"), "Unavailable", false); setStatus($("#ready-value"), "Unavailable", false);
    renderError("#profile-list", error.message || "The API is unavailable.");
    $("#model-source").textContent = "Unavailable"; $("#model-version").textContent = "Unavailable"; $("#model-sha").textContent = "Unavailable";
  }
}

$("#prediction-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = event.currentTarget.querySelector("button");
  const result = $("#prediction-result");
  const skills = $("#skills-input").value.trim();
  if (!skills) return;
  button.disabled = true; button.innerHTML = "Predicting…";
  result.classList.remove("success"); result.querySelector("strong").textContent = "Contacting the live classifier…";
  try {
    const prediction = await fetchJson("/predict", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ skills }) });
    result.classList.add("success"); result.querySelector("strong").textContent = prediction.domain;
    setStatus($("#predict-value"), "Responding", true);
  } catch (error) {
    result.querySelector("strong").textContent = error.message || "Prediction unavailable";
    setStatus($("#predict-value"), "Unavailable", false);
  } finally { button.disabled = false; button.innerHTML = "Find role fit <span>↗</span>"; }
});

$("#refresh-button").addEventListener("click", loadDashboard);
$("#model-sha").addEventListener("click", async () => {
  const value = $("#model-sha").textContent;
  if (!value || value === "—" || value === "Unavailable") return;
  try { await navigator.clipboard.writeText(value); $("#toast").textContent = "Model SHA copied"; $("#toast").classList.add("show"); setTimeout(() => $("#toast").classList.remove("show"), 1800); } catch (_) { /* clipboard is optional */ }
});

loadDashboard();
