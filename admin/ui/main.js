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
  for (const id of ["deaths", "refresh-rival", "prepare-gazette", "write-gazette", "install-admin", "app-update", "propose-gazette", "discard-gazette"]) $(id).disabled = busy;

  // Home
  $("app-version").textContent = s.appVersion;
  $("app-update").textContent = s.appUpdate ? `Installer la ${s.appUpdate}` : "Vérifier les mises à jour";
  $("app-hint").textContent = s.appUpdate
    ? `Nouvelle version ${s.appUpdate} disponible : l'application redémarrera.`
    : "Elle se met aussi à jour toute seule à chaque démarrage.";
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
  renderSelection(s.selection, busy);
  renderDraft(s.draft, busy);
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

const TEMPLATES = {
  classique: "Classique", grande_une: "Grande une", trois_colonnes: "Trois colonnes", portrait: "Portrait",
};

// Facts offered for the next issue. The ticks live here (render runs at every state
// push); the list is rebuilt only for a new selection.
let selectionKey = null;
let selection = null;
const ticked = new Set();

function day(t) {
  return new Date(t * 1000).toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit" });
}

function factRow(c) {
  const row = document.createElement("label");
  row.className = "fact" + (c.used ? " told" : "");
  const box = document.createElement("input");
  box.type = "checkbox";
  box.checked = ticked.has(c.key);
  box.dataset.key = c.key;
  box.addEventListener("change", () => {
    if (box.checked) ticked.add(c.key); else ticked.delete(c.key);
    countFacts();
  });
  const text = document.createElement("span");
  text.className = "text";
  text.textContent = c.text;
  row.append(box, text);
  const note = c.used ?? (c.partly ? "en partie déjà paru" : null);
  if (note) {
    const u = document.createElement("span");
    u.className = "used";
    u.textContent = note;
    row.appendChild(u);
  }
  return row;
}

function countFacts() {
  const n = ticked.size;
  $("facts-count").textContent = `${n} fait(s) coché(s)`;
  $("preview").disabled = n === 0;
}

function fillFacts() {
  const recent = selection.candidates.filter((c) => c.recent).reverse();
  const older = selection.candidates.filter((c) => !c.recent).reverse();
  for (const [box, list] of [[$("facts-recent"), recent], [$("facts-older"), older]]) {
    box.textContent = "";
    for (const c of list) box.appendChild(factRow(c));
    if (list.length === 0) {
      const empty = document.createElement("p");
      empty.className = "hint fact";
      empty.textContent = "Aucun fait.";
      box.appendChild(empty);
    }
  }
  $("selection-title").textContent = selection.afterIssue
    ? `Depuis le dernier numéro (écrit le ${day(selection.since)}) : ${recent.length} fait(s)`
    : `7 derniers jours (pas encore de numéro) : ${recent.length} fait(s)`;
  $("facts-older-title").textContent = `Plus anciens (jusqu'à 30 jours) : ${older.length} fait(s)`;
  countFacts();
}

function renderSelection(sel, busy) {
  $("selection").hidden = !sel;
  $("prepare-gazette").textContent = sel ? "Actualiser la liste" : "Choisir les faits";
  if (!sel) { selectionKey = null; return; }
  if (sel.edition !== selectionKey) {
    selectionKey = sel.edition;
    selection = sel;
    ticked.clear();
    for (const c of sel.candidates) if (c.checked) ticked.add(c.key);
    $("preview-summary").textContent = "";
    $("preview-prompt").hidden = true;
    fillFacts();
  }
  $("write-gazette").disabled = busy;
}

function tick(which) {
  ticked.clear();
  for (const c of selection.candidates) if (which(c)) ticked.add(c.key);
  fillFacts();
}

// Gazette draft: what came back, what the checks rejected, the articles as written.
function renderDraft(d, busy) {
  $("draft").hidden = !d;
  if (!d) return;
  const articles = d.items.filter((i) => i.kind === "ARTICLE");
  const layout = d.items.find((i) => i.kind === "EDITION");
  const template = layout ? TEMPLATES[layout.p.template] ?? layout.p.template : "aucune";
  const cards = d.items.filter((i) => i.kind === "CARD_SET").flatMap((i) => i.p.cards);
  $("draft-title").textContent =
    `Brouillon · rédigé le ${when(d.at)} · ${articles.length} article(s) · maquette : ${template} · ${cards.length} carte(s)`;
  renderCards(cards);
  $("draft-notes").textContent = d.notes.join("\n");
  const list = $("draft-articles");
  list.textContent = "";
  for (const a of articles) {
    const p = a.p;
    const div = document.createElement("div");
    div.className = "article";
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = [`#${p.order}`, p.format, p.style, p.portrait && `portrait : ${p.portrait}`]
      .filter(Boolean).join(" · ");
    const h = document.createElement("h3");
    h.textContent = p.title;
    div.append(meta, h);
    if (p.quote) {
      const q = document.createElement("blockquote");
      q.textContent = `« ${p.quote} »`;
      div.appendChild(q);
    }
    const body = document.createElement("div");
    body.className = "body";
    body.textContent = p.body;
    div.appendChild(body);
    list.appendChild(div);
  }
  $("draft-answer").textContent = d.answer ?? "(aucune réponse)";
  $("propose-gazette").disabled = busy || d.items.length === 0;
}

// Album cards published with the issue: number, rarity, name, text.
const RARITY = { common: "Commune", uncommon: "Peu commune", rare: "Rare", epic: "Épique", legendary: "Légendaire" };
function renderCards(cards) {
  const box = $("draft-cards");
  box.textContent = "";
  if (cards.length === 0) return;
  const h = document.createElement("div");
  h.className = "label";
  h.textContent = `Cartes de l'album (${cards.length})`;
  box.appendChild(h);
  for (const c of cards) {
    const div = document.createElement("div");
    div.className = `album-card ${c.r}`;
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = [`N° ${String(c.no).padStart(3, "0")}`, RARITY[c.r] ?? c.r, c.s].join(" · ");
    const name = document.createElement("strong");
    name.textContent = c.n;
    const text = document.createElement("div");
    text.textContent = c.f;
    div.append(meta, name, text);
    box.appendChild(div);
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
$("app-update").addEventListener("click", () => call("update_app"));
$("refresh-rival").addEventListener("click", () => call("refresh_rival", { rival: $("rival").value }));
$("prepare-gazette").addEventListener("click", () => { selectionKey = null; call("prepare_gazette"); });
$("facts-all").addEventListener("click", () => tick(() => true));
$("facts-none").addEventListener("click", () => tick(() => false));
$("facts-default").addEventListener("click", () => tick((c) => c.checked));
$("write-gazette").addEventListener("click", () => call("write_gazette", { keys: [...ticked] }));
$("propose-gazette").addEventListener("click", () => call("propose_gazette"));
$("discard-gazette").addEventListener("click", () => call("discard_gazette"));
$("pick-articles").addEventListener("click", () => call("pick_articles_dir"));
$("open-articles").addEventListener("click", () => call("open_folder", { which: "articles" }));
$("pick-wow").addEventListener("click", () => { settingsShown = false; call("pick_wow_folder"); });
$("open-addons").addEventListener("click", () => call("open_folder", { which: "addons" }));
$("preview").addEventListener("click", async () => {
  try {
    const p = await invoke("preview_gazette", { keys: [...ticked] });
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
