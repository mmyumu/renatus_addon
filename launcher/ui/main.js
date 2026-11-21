// Window of the launcher: shows the state pushed by the Rust side ("state"
// event) and calls its commands. All the work happens in Rust.
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (id) => document.getElementById(id);

const timeOf = (secs) =>
  new Date(secs * 1000).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });

function setMessage(el, text, kind = "") {
  el.textContent = text;
  el.className = kind ? `message ${kind}` : "message";
}

function renderLauncher(s) {
  $("launcher-installed").textContent = s.launcherVersion;
  $("launcher-available").textContent = s.launcherLatest ?? "—";
  $("check-launcher").disabled = s.launcherBusy;
  const msg = $("launcher-message");
  const newer = s.launcherLatest && s.launcherLatest !== s.launcherVersion;
  if (s.launcherBusy && newer) {
    setMessage(msg, `Installation de la version ${s.launcherLatest}… le launcher va redémarrer.`);
  } else if (s.launcherBusy) {
    setMessage(msg, "Vérification…");
  } else if (s.launcherError) {
    setMessage(msg, s.launcherError, "error");
  } else if (s.launcherLastCheck) {
    setMessage(msg, `À jour (vérifié à ${timeOf(s.launcherLastCheck)})`, "ok");
  } else {
    setMessage(msg, "");
  }
}

function render(s) {
  $("installed").textContent = s.installed ?? "pas installé";
  $("available").textContent = s.available ?? "—";
  $("wow").textContent = s.wowPath ?? "introuvable : clique sur « Changer »";
  $("open").disabled = !s.wowPath;
  $("check").disabled = s.busy;
  $("autostart").checked = s.autostart;
  $("test").checked = s.testChannel;
  renderLauncher(s);

  const msg = $("message");
  if (s.busy) {
    setMessage(msg, "Vérification…");
  } else if (s.error) {
    setMessage(msg, s.error, "error");
  } else if (s.lastCheck) {
    const upToDate = s.installed && s.installed === s.available;
    setMessage(msg, (upToDate ? "À jour" : "Aucune version publiée") + ` (vérifié à ${timeOf(s.lastCheck)})`,
      upToDate ? "ok" : "");
  } else {
    setMessage(msg, "");
  }

  $("notes-card").hidden = !s.notes;
  $("notes").textContent = s.notes ?? "";
}

function showError(e) {
  setMessage($("message"), String(e), "error");
}

async function call(command, args) {
  try {
    const state = await invoke(command, args);
    if (state) render(state);
  } catch (e) {
    showError(e);
  }
}

$("check").addEventListener("click", () => call("check_now"));
$("check-launcher").addEventListener("click", () => call("check_launcher_now"));
$("pick").addEventListener("click", () => call("pick_wow_folder"));
$("open").addEventListener("click", () => call("open_addons_folder"));
$("autostart").addEventListener("change", (e) => call("set_autostart", { enabled: e.target.checked }));
$("test").addEventListener("change", (e) => call("set_test_channel", { enabled: e.target.checked }));

listen("state", (event) => render(event.payload));
call("get_state");
