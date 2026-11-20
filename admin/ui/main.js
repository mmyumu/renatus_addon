// Window of Renatus Admin: shows the state pushed by the Rust side ("state" event)
// and calls its commands. All the work happens in Rust (renatus-admin-core).
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (id) => document.getElementById(id);
const CLASSES = {
  WARRIOR: "Guerrier", PALADIN: "Paladin", HUNTER: "Chasseur", ROGUE: "Voleur", PRIEST: "Prêtre",
  DEATHKNIGHT: "Chevalier de la mort", SHAMAN: "Chaman", MAGE: "Mage", WARLOCK: "Démoniste",
  MONK: "Moine", DRUID: "Druide", DEMONHUNTER: "Chasseur de démons", EVOKER: "Évocateur",
};
let state = null;
let settingsShown = false;

function when(t) {
  if (!t) return "—";
  return new Date(t * 1000).toLocaleString("fr-FR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
}

function render(s) {
  state = s;
  const st = s.status;
  const busy = !!s.busy;
  $("busy").textContent = busy ? `${s.busy}…` : "";
  for (const id of ["deaths", "refresh-rival", "write-gazette", "articles", "install-admin"]) $(id).disabled = busy;

  // Home
  $("renatus-version").textContent = st?.renatusVersion ?? "absent";
  $("admin-version").textContent = st?.adminVersion ?? "absent";
  const avail = s.adminAvailable;
  const upToDate = st?.adminVersion && st.adminVersion === avail;
  $("install-admin").textContent = st?.adminVersion ? "Mettre à jour Renatus_Admin" : "Installer Renatus_Admin";
  $("install-admin").hidden = !!upToDate;
  $("admin-hint").textContent = avail ? `Dernière version publiée : ${avail}` : "";
  $("events").textContent = st && !st.error ? `${st.events} (${st.shared} partagés)` : "—";
  $("authors").textContent = st && !st.error ? st.authors : "—";
  $("saved-at").textContent = when(st?.savedAt);
  $("combat-logs").textContent = st ? st.combatLogs : "—";
  $("sv-error").hidden = !st?.error;
  $("sv-error").textContent = st?.error ?? "";
  $("pending").textContent = st?.pending ?? 0;
  const log = $("log");
  log.textContent = s.log.map((l) => `${when(l.at)}  ${l.text}`).join("\n");
  log.scrollTop = log.scrollHeight;

  // Rival
  if (document.activeElement !== $("rival")) $("rival").value = s.config.rival ?? "";
  $("configured-rival").textContent = st?.configuredRival ?? "aucun";
  const body = $("roster").querySelector("tbody");
  body.textContent = "";
  const r = s.roster;
  $("roster-empty").hidden = !!r;
  $("roster").hidden = !r;
  if (r) {
    $("roster-title").textContent = `${r.name} · ${r.faction ?? ""} · ${r.count} membre(s) · relevé ${when(r.fetchedAt)}`;
    const members = [...r.members].sort((a, b) => b.level - a.level || a.name.localeCompare(b.name));
    for (const m of members) {
      const tr = document.createElement("tr");
      if (m.known) tr.className = "known";
      for (const v of [m.name, m.level, CLASSES[m.class] ?? m.class, m.race, m.rank === 0 ? "Chef" : m.rank, m.known ? "avis de recherche" : ""]) {
        const td = document.createElement("td");
        td.textContent = v;
        tr.appendChild(td);
      }
      body.appendChild(tr);
    }
  }

  // Gazette
  $("articles-dir").textContent = s.config.articlesDir ?? "non choisi";
  $("open-articles").disabled = !s.config.articlesDir;

  // Settings (filled once, so typing is never overwritten)
  $("wow").textContent = s.config.wowPath ?? "introuvable : clique sur « Changer »";
  $("version").textContent = s.appVersion;
  if (!settingsShown) {
    settingsShown = true;
    const sel = $("account");
    sel.length = 1;
    for (const a of s.accounts) sel.add(new Option(a, a));
    sel.value = s.config.account ?? "";
    $("llm-command").value = JSON.stringify(s.config.llmCommand);
    $("llm-timeout").value = s.config.llmTimeoutSecs;
    $("gazette-template").value = s.config.gazetteTemplate || "auto";
    $("auto").checked = s.config.auto;
    $("auto-gazette").checked = s.config.autoGazette;
    $("test-channel").checked = s.config.testChannel;
  }
}

function report(e) {
  const log = $("log");
  log.textContent += `\n${String(e)}`;
  log.scrollTop = log.scrollHeight;
}

async function call(command, args) {
  try {
    const s = await invoke(command, args);
    if (s && s.config) render(s);
    return s;
  } catch (e) {
    report(e);
  }
}

for (const tab of document.querySelectorAll(".tab")) {
  tab.addEventListener("click", () => {
    for (const t of document.querySelectorAll(".tab")) t.classList.toggle("active", t === tab);
    for (const p of document.querySelectorAll(".page")) p.hidden = p.id !== `page-${tab.dataset.tab}`;
  });
}

$("deaths").addEventListener("click", () => call("propose_deaths"));
$("reload").addEventListener("click", () => call("reload"));
$("install-admin").addEventListener("click", () => call("install_admin_addon"));
$("refresh-rival").addEventListener("click", () => call("refresh_rival", { rival: $("rival").value }));
$("write-gazette").addEventListener("click", () => call("write_gazette"));
$("articles").addEventListener("click", () => call("propose_articles"));
$("pick-articles").addEventListener("click", () => call("pick_articles_dir"));
$("open-articles").addEventListener("click", () => call("open_folder", { which: "articles" }));
$("pick-wow").addEventListener("click", () => { settingsShown = false; call("pick_wow_folder"); });
$("open-addons").addEventListener("click", () => call("open_folder", { which: "addons" }));
$("preview").addEventListener("click", async () => {
  try {
    const p = await invoke("preview_gazette");
    $("preview-summary").textContent = p.summary.join("\n");
    $("preview-prompt").textContent = p.prompt;
    $("preview-prompt").hidden = false;
  } catch (e) {
    report(e);
  }
});
$("save-settings").addEventListener("click", async () => {
  const msg = $("settings-message");
  try {
    const s = await invoke("save_settings", {
      settings: {
        account: $("account").value || null,
        llmCommand: $("llm-command").value,
        llmTimeoutSecs: Number($("llm-timeout").value) || 600,
        gazetteTemplate: $("gazette-template").value,
        auto: $("auto").checked,
        autoGazette: $("auto-gazette").checked,
        testChannel: $("test-channel").checked,
      },
    });
    render(s);
    msg.textContent = "Enregistré.";
    msg.className = "ok";
  } catch (e) {
    msg.textContent = String(e);
    msg.className = "error";
  }
});

listen("state", (event) => render(event.payload));
call("get_state");
