const $ = (selector) => document.querySelector(selector);

const state = { profiles: [] };

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
  const query = $("#profile-search").value.trim().toLowerCase();
  const visible = profiles.filter((profile) => `${profile.name} ${profile.skills.join(" ")}`.toLowerCase().includes(query));
  $("#profile-count").textContent = profiles.length;
  $("#profile-caption").textContent = query ? `${visible.length} matching` : `${profiles.length} sample profiles`;
  $("#profile-list").innerHTML = visible.length ? visible.map((profile) => `
    <article class="profile-item">
      <div class="profile-avatar">${escapeHtml(initials(profile.name))}</div>
      <div><h3>${escapeHtml(profile.name)}</h3><div class="skill-list">
        ${profile.skills.map((skill) => `<span class="skill">${escapeHtml(skill)}</span>`).join("")}
      </div></div>
      <button class="profile-action" type="button" data-profile-id="${escapeHtml(profile.id)}" aria-label="Explore role fit for ${escapeHtml(profile.name)}">Explore fit <span>↗</span></button>
    </article>`).join("") : '<div class="empty-state">No profiles match that search. Try a name or skill.</div>';
  document.querySelectorAll(".profile-action").forEach((button) => {
    button.addEventListener("click", () => {
      const profile = profiles.find((item) => String(item.id) === button.dataset.profileId);
      if (!profile) return;
      $("#skills-input").value = profile.skills.join(", ");
      $("#sample-note").textContent = `Selected profile: ${profile.name}`;
      $("#prediction").scrollIntoView({ behavior: "smooth", block: "center" });
      $("#skills-input").focus({ preventScroll: true });
    });
  });
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
    const [profiles, health, ready] = await Promise.all([
      fetchJson("/profiles"), fetchJson("/health"), fetchJson("/ready"),
    ]);
    state.profiles = profiles;
    renderProfiles(profiles);
    setStatus($("#api-status"), health.status === "healthy" ? "Healthy" : health.status, health.status === "healthy");
    setStatus($("#health-value"), health.status === "healthy" ? "Operational" : health.status, health.status === "healthy");
    setStatus($("#model-status"), ready.status === "ready" ? "Ready" : "Unavailable", ready.status === "ready");
    setStatus($("#ready-value"), ready.status === "ready" ? "Loaded" : ready.status, ready.status === "ready");
    $("#api-status-dot").classList.add("ok"); $("#model-status-dot").classList.add("ok");
    const sample = profiles[0];
    if (sample && !$("#skills-input").value.trim()) {
      $("#skills-input").value = sample.skills.join(", ");
      $("#sample-note").textContent = `Ready to explore: ${sample.name}`;
      $("#prediction-result").querySelector("small").textContent = "PROFILE READY";
      $("#prediction-result").querySelector("strong").textContent = "Select Find role fit to see a live result";
    }
  } catch (error) {
    setStatus($("#api-status"), "Unavailable", false); setStatus($("#model-status"), "Unavailable", false);
    $("#api-status-dot").classList.add("error"); $("#model-status-dot").classList.add("error");
    setStatus($("#health-value"), "Unavailable", false); setStatus($("#ready-value"), "Unavailable", false);
    renderError("#profile-list", error.message || "The API is unavailable.");
  }
}

async function analyzeSkills(skills) {
  const button = $("#prediction-form").querySelector("button");
  const result = $("#prediction-result");
  if (!skills) return;
  button.disabled = true; button.innerHTML = "Predicting…";
  result.classList.remove("success"); result.querySelector("small").textContent = "FINDING A ROLE DIRECTION"; result.querySelector("strong").textContent = "Reviewing these skills…";
  try {
    const prediction = await fetchJson("/predict", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ skills }) });
    result.classList.add("success"); result.querySelector("small").textContent = "SUGGESTED ROLE FAMILY"; result.querySelector("strong").textContent = prediction.domain;
    setStatus($("#predict-value"), "Responding", true);
  } catch (error) {
    result.querySelector("small").textContent = "ROLE DIRECTION"; result.querySelector("strong").textContent = "We couldn't assess this profile right now. Please try again.";
    setStatus($("#predict-value"), "Unavailable", false);
  } finally { button.disabled = false; button.innerHTML = "Find role fit <span>↗</span>"; }
}

$("#prediction-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  await analyzeSkills($("#skills-input").value.trim());
});

$("#refresh-button").addEventListener("click", loadDashboard);
$("#profile-search").addEventListener("input", () => renderProfiles(state.profiles));
loadDashboard();
