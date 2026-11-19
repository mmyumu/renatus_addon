// Window of the launcher: shows the state pushed by the Rust side ("state"
// event) and calls its commands. All the work happens in Rust.
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (id) => document.getElementById(id);

function render(s) {
  $("installed").textContent = s.installed ?? "pas installé";
  $("available").textContent = s.available ?? "—";
  $("wow").textContent = s.wowPath ?? "introuvable : clique sur « Changer »";
  $("open").disabled = !s.wowPath;
  $("check").disabled = s.busy;
  $("autostart").checked = s.autostart;
  $("test").checked = s.testChannel;
  $("version").textContent = `Launcher ${s.launcherVersion}`;

  const msg = $("message");
  msg.className = "";
  if (s.busy) {
    msg.textContent = "Vérification…";
  } else if (s.error) {
    msg.textContent = s.error;
    msg.className = "error";
  } else if (s.lastCheck) {
    const at = new Date(s.lastCheck * 1000).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
    const upToDate = s.installed && s.installed === s.available;
    msg.textContent = (upToDate ? "À jour" : "Aucune version publiée") + ` (vérifié à ${at})`;
    msg.className = upToDate ? "ok" : "";
  } else {
    msg.textContent = "";
  }

  $("notes-card").hidden = !s.notes;
  $("notes").textContent = s.notes ?? "";
}

function showError(e) {
  const msg = $("message");
  msg.textContent = String(e);
  msg.className = "error";
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
$("pick").addEventListener("click", () => call("pick_wow_folder"));
$("open").addEventListener("click", () => call("open_addons_folder"));
$("autostart").addEventListener("change", (e) => call("set_autostart", { enabled: e.target.checked }));
$("test").addEventListener("change", (e) => call("set_test_channel", { enabled: e.target.checked }));

listen("state", (event) => render(event.payload));
call("get_state");
