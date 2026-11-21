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
  renderPending(st?.pendingItems ?? [], busy);
  renderMonitor(st);
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

// Suivi: members, sync health, recent events (read-only, built in Rust: monitor.rs).
function ago(t) {
  if (!t) return "—";
  const s = Math.max(0, Date.now() / 1000 - t);
  if (s < 90) return "à l'instant";
  if (s < 3600) return `il y a ${Math.round(s / 60)} min`;
  if (s < 86400 * 2) return `il y a ${Math.round(s / 3600)} h`;
  return `il y a ${Math.round(s / 86400)} j`;
}

function duration(d) {
  if (d == null) return "—";
  if (d < 90) return `${d} s`;
  if (d < 5400) return `${Math.round(d / 60)} min`;
  return `${Math.round(d / 3600)} h`;
}

function cell(tr, text, cls) {
  const td = document.createElement("td");
  td.textContent = text ?? "";
  if (cls) td.className = cls;
  tr.appendChild(td);
  return td;
}

function badge(td, text, cls = "") {
  const b = document.createElement("span");
  b.className = `badge ${cls}`;
  b.textContent = text;
  td.appendChild(b);
}

function fillSelect(sel, values, label) {
  const keep = sel.value;
  sel.length = 1;
  for (const v of values) sel.add(new Option(label ? label(v) : v, v));
  sel.value = values.includes(keep) ? keep : "";
}

function renderMonitor(st) {
  const m = st && !st.error ? st.monitor : null;
  const h = m?.health;
  const others = m ? m.members.filter((x) => x.equipped && !x.mine).length : 0;
  $("mon-equipped").textContent = m ? h.equipped : "—";
  $("mon-equipped-hint").textContent = m
    ? `dont ${others} autre(s) que toi` + (h.rosterSize ? ` · ${h.rosterSize} membre(s) dans la guilde` : "")
    : "";
  $("mon-last-rx").textContent = m ? ago(h.lastReceived) : "—";
  $("mon-delay").textContent = m ? duration(h.medianDelay) : "—";
  $("mon-direct").textContent = m ? `${h.direct} / ${h.relayed}` : "—";
  $("mon-missing").textContent = m ? `${h.missing} · ${h.rejected}` : "—";
  $("mon-missing").className = m && (h.missing || h.rejected) ? "error" : "";
  $("mon-saved-at").textContent = st?.savedAt ? `${when(st.savedAt)} (${ago(st.savedAt)})` : "—";
  $("mon-roster-at").textContent = m?.health.rosterAt ? when(h.rosterAt) : "pas encore";

  const ul = $("mon-alerts");
  ul.textContent = "";
  const alerts = m ? m.alerts : [];
  if (m && !alerts.some((a) => a.level === "warn")) alerts.unshift({ level: "ok", text: "Aucun problème détecté." });
  for (const a of alerts) {
    const li = document.createElement("li");
    li.className = a.level;
    li.textContent = a.text;
    ul.appendChild(li);
  }
  $("mon-alerts-box").hidden = !m;

  // Members
  const filter = $("mon-members-filter").value;
  const body = $("mon-members").querySelector("tbody");
  body.textContent = "";
  for (const x of m?.members ?? []) {
    if (filter === "equipped" && !x.equipped) continue;
    if (filter === "missing" && x.equipped) continue;
    const tr = document.createElement("tr");
    tr.className = (x.equipped ? "" : "absent") + (x.mine ? " mine" : "");
    const name = cell(tr, x.name);
    if (x.isNew) badge(name, "nouveau");
    if (x.equipped && !x.inRoster && m.health.rosterAt) badge(name, "hors guilde ?", "warn");
    cell(tr, CLASSES[x.class] ?? x.class ?? "");
    cell(tr, x.level ?? "");
    cell(tr, x.rank == null ? "" : x.rank === 0 ? "Chef" : x.rank);
    const addon = cell(tr, x.equipped ? (x.version ?? "oui") : "non");
    if (x.equipped && x.version && st.renatusVersion && x.version !== st.renatusVersion) badge(addon, "ancienne ?", "warn");
    cell(tr, x.firstSeen ? when(x.firstSeen) : "—");
    const last = cell(tr, x.lastActivity ? ago(x.lastActivity) : "—");
    if (x.lastKind) last.title = `dernier événement : ${x.lastKind}`;
    const n = cell(tr, x.equipped ? x.shared : "");
    if (x.missingCount) badge(n, `${x.missingCount} manquant(s)`, "warn");
    body.appendChild(tr);
  }

  // Activity
  const act = $("mon-activity");
  act.textContent = "";
  const max = Math.max(1, ...(m?.activity ?? []).map((d) => d.count));
  for (const d of m?.activity ?? []) {
    const b = document.createElement("div");
    b.className = "bar-day" + (d.count ? "" : " zero");
    b.style.height = `${Math.max(2, (d.count / max) * 100)}%`;
    b.title = `${d.day.split("-").reverse().join("/")} : ${d.count} événement(s)`;
    act.appendChild(b);
  }

  // Feed
  const feed = m?.feed ?? [];
  fillSelect($("mon-feed-who"), [...new Set(feed.map((f) => f.name))].sort());
  const kinds = new Map(feed.map((f) => [f.kind, f.label]));
  fillSelect($("mon-feed-kind"), [...kinds.keys()].sort((a, b) => kinds.get(a).localeCompare(kinds.get(b))), (k) => kinds.get(k));
  const who = $("mon-feed-who").value;
  const kind = $("mon-feed-kind").value;
  const fb = $("mon-feed").querySelector("tbody");
  fb.textContent = "";
  for (const f of feed) {
    if ((who && f.name !== who) || (kind && f.kind !== kind)) continue;
    const tr = document.createElement("tr");
    cell(tr, when(f.t));
    cell(tr, f.name);
    const what = cell(tr, f.label);
    if (!f.shared) badge(what, "privé");
    cell(tr, f.detail);
    cell(tr, f.by ? `${f.direct ? "de" : "relayé par"} ${f.by}${f.delay != null ? ` · ${duration(f.delay)}` : ""}` : "ici", "muted");
    fb.appendChild(tr);
  }
}

for (const id of ["mon-members-filter", "mon-feed-who", "mon-feed-kind"]) {
  $(id).addEventListener("change", () => state && renderMonitor(state.status));
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
    : `30 derniers jours (aucun numéro paru, ou remise à zéro) : ${recent.length} fait(s)`;
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
const SERIES = {
  members: "Membres", founders: "Fondateurs", expeditions: "Exploits", une: "À la une",
  faits: "Faits divers", sworn: "Avis de recherche", legends: "Légendes", butin: "Butin",
  mobs: "Bestiaire de la guilde", terreurs: "Terreurs",
  // base set (Renatus/Core/Cards.lua)
  est: "Royaumes de l'Est", kalimdor: "Kalimdor", donjons: "Donjons et raids", personnages: "Personnages",
  heros: "Classes et races", bestiaire: "Bestiaire", tresors: "Trésors et curiosités",
};
function cardMeta(c) {
  return [c.no !== undefined && `N° ${String(c.no).padStart(3, "0")}`, RARITY[c.r] ?? c.r, SERIES[c.s] ?? c.s,
    c.fo !== undefined && `force ${c.fo} · endurance ${c.en}`,
    c.npc && `modèle 3D (créature ${c.npc})`, c.itm && `icône de l'objet ${c.itm}`].filter(Boolean).join(" · ");
}
// onRemove(card): adds a "Retirer" button on each card (pending sets).
function renderCards(cards, box = $("draft-cards"), onRemove = null) {
  box.textContent = "";
  if (cards.length === 0) return;
  const h = document.createElement("div");
  h.className = "label";
  h.textContent = `Cartes de l'album (${cards.length})`;
  box.appendChild(h);
  for (const c of cards) {
    const div = document.createElement("div");
    div.className = `album-card ${c.r ?? ""}`;
    const meta = document.createElement("div");
    meta.className = "meta";
    const name = document.createElement("strong");
    const text = document.createElement("div");
    if (c.del) {
      meta.textContent = "Retrait du catalogue (ceux qui l'ont la gardent)";
      name.textContent = c.id;
    } else {
      meta.textContent = cardMeta(c);
      name.textContent = c.n;
      text.textContent = c.f;
    }
    if (onRemove) {
      const x = document.createElement("button");
      x.className = "small remove";
      x.textContent = "Retirer";
      x.disabled = !!state?.busy;
      x.addEventListener("click", () => onRemove(c));
      div.appendChild(x);
    }
    div.append(meta, name, text);
    box.appendChild(div);
  }
}

// Items waiting in Press.lua: what each one is, its text, and a way to take it out.
const KINDS = {
  ARTICLE: "Article", EDITION: "Mise en page", CARD_SET: "Cartes de l'album", DEATH_CAUSE: "Mort",
  PVP_CLASH: "Combat JcJ", GUILD_CONFIG: "Réglage de guilde", RIVAL_ROSTER: "Effectif rival",
};
function pendingLabel(i) {
  const p = i.p ?? {};
  switch (i.kind) {
    case "ARTICLE":
      if (p.replaces) return `${p.retract ? "Retrait" : "Correction"} : ${p.title ?? p.replaces}`;
      return `${p.title ?? "(sans titre)"}${p.ia ? " · IA" : ""}`;
    case "EDITION": return `${TEMPLATES[p.template] ?? p.template ?? "libre"} · ${(p.titles ?? []).filter(Boolean).join(", ") || "gazette"}`;
    case "CARD_SET":
      if (String(p.set ?? "").startsWith("fix:")) {
        const c = (p.cards ?? [])[0] ?? {};
        return c.del ? `Retrait de la carte ${c.id}` : `Correction : ${c.n ?? c.id}`;
      }
      return `${(p.cards ?? []).length} carte(s)`;
    case "DEATH_CAUSE": return `${p.victim ?? "?"} : ${p.cause ?? "?"}`;
    case "PVP_CLASH": return `${p.member ?? "?"} ${p.result === "win" ? "a vaincu" : "a été vaincu par"} ${p.name ?? "?"}`;
    case "GUILD_CONFIG": {
      const b = p.boosters;
      return `guilde rivale : ${p.rival || "aucune"}` + (b ? ` ; boosters ${b.day}/jour, +${b.bonus} bonus, ${b.cap} max` : "");
    }
    default: return i.note ?? i.id;
  }
}

function confirmRemove(what, args) {
  if (window.confirm(`Retirer ${what} de Press.lua ? Il ne sera pas proposé en jeu.`)) {
    call("remove_pending", { items: [], cards: [], ...args });
  }
}

function renderPending(items, busy) {
  $("pending-box").hidden = items.length === 0;
  $("pending-title").textContent = `En attente en jeu (${items.length})`;
  const list = $("pending-list");
  list.textContent = "";
  for (const i of items) {
    const div = document.createElement("div");
    div.className = "pending-item";
    const head = document.createElement("div");
    head.className = "head";
    const what = document.createElement("span");
    what.className = "what";
    const kind = document.createElement("span");
    kind.className = "kind";
    kind.textContent = KINDS[i.kind] ?? i.kind;
    what.append(kind, pendingLabel(i));
    const x = document.createElement("button");
    x.className = "small";
    x.textContent = "Retirer";
    x.disabled = busy;
    x.addEventListener("click", () => confirmRemove(`« ${pendingLabel(i)} »`, { items: [i.id] }));
    head.append(what, x);
    div.appendChild(head);
    if (i.kind === "ARTICLE") {
      const d = document.createElement("details");
      const sum = document.createElement("summary");
      sum.textContent = [i.p.format, i.p.style].filter(Boolean).join(" · ") || "Lire";
      const body = document.createElement("div");
      body.className = "body";
      body.textContent = (i.p.quote ? `« ${i.p.quote} »\n\n` : "") + (i.p.body ?? "");
      d.append(sum, body);
      div.appendChild(d);
    } else if (i.kind === "CARD_SET") {
      const box = document.createElement("div");
      box.className = "pending-cards";
      renderCards(i.p.cards ?? [], box, (c) => confirmRemove(`la carte « ${c.n} »`, { cards: [c.id] }));
      div.appendChild(box);
    }
    list.appendChild(div);
  }
}

// Éditeur: the published catalogue and issues, as members see them; a correction or a
// withdrawal goes to Press.lua like any publication (core/src/revise.rs).
let published = null;
// The card or article being edited: { key: "card:<id>" | "article:<id>", values, error }.
let editing = null;
const openIssues = new Set();
let issuesSeen = false;

function dayFr(t) {
  return new Date(t * 1000).toLocaleDateString("fr-FR");
}

async function loadPublished() {
  $("editor-status").textContent = "Lecture du journal…";
  try {
    published = await invoke("published");
    $("editor-status").textContent = `Relu à ${new Date().toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" })}. Ce que tu publies en jeu apparaît ici après un /reload.`;
  } catch (e) {
    published = null;
    $("editor-status").textContent = String(e);
  }
  renderEditor();
}

function renderEditor() {
  renderCatalogue();
  renderArchive();
}

// feminine: "corrigée"/"retirée" (a card) or "corrigé"/"retiré" (an article).
function flagLine(x, feminine) {
  const e = feminine ? "e" : "";
  const flags = [
    x.withdrawn && `retiré${e}`,
    x.revised && `corrigé${e} le ${dayFr(x.revised)}`,
    x.pending && "correction en attente en jeu",
  ].filter(Boolean);
  const div = document.createElement("div");
  div.className = "flags";
  div.textContent = flags.join(" · ");
  return div;
}

function button(label, onClick, cls = "small") {
  const b = document.createElement("button");
  b.className = cls;
  b.textContent = label;
  b.addEventListener("click", onClick);
  return b;
}

// Sends a correction; on success the editor closes and the lists are read again.
async function propose(command, args) {
  try {
    render(await invoke(command, args));
    editing = null;
    await loadPublished();
  } catch (e) {
    if (editing) {
      editing.error = String(e);
      renderEditor();
    } else {
      report(e);
      $("editor-status").textContent = String(e);
    }
  }
}

function field(label, input) {
  const l = document.createElement("label");
  l.append(label, input);
  return l;
}

// A text input bound to editing.values[key].
function bound(key, tag = "input", attrs = {}) {
  const el = document.createElement(tag);
  if (tag === "input") el.type = attrs.type ?? "text";
  for (const [k, v] of Object.entries(attrs)) if (k !== "type") el[k] = v;
  el.value = editing.values[key] ?? "";
  el.addEventListener("input", () => { editing.values[key] = el.value; });
  return el;
}

function formButtons(onSubmit) {
  const div = document.createElement("div");
  div.className = "actions";
  const err = document.createElement("p");
  err.className = "error";
  err.textContent = editing.error ?? "";
  div.append(
    button("Proposer en jeu", onSubmit, ""),
    button("Annuler", () => { editing = null; renderEditor(); }, ""),
  );
  const box = document.createElement("div");
  box.append(err, div);
  return box;
}

function cardEdit(c) {
  return {
    id: c.id, name: c.n ?? "", flavor: c.f ?? "", rarity: c.r, icon: c.ic ?? "",
    force: c.fo ?? null, endurance: c.en ?? null,
  };
}

function cardView(pc) {
  const c = pc.card;
  const div = document.createElement("div");
  div.className = `album-card ${c.r}${pc.withdrawn ? " withdrawn" : ""}`;
  const meta = document.createElement("div");
  meta.className = "meta";
  meta.textContent = `${cardMeta(c)} · ${pc.base ? "set de base" : `paru le ${dayFr(pc.t)}`}`;
  const name = document.createElement("strong");
  name.textContent = c.n;
  const text = document.createElement("div");
  text.textContent = c.f ?? "";
  const actions = document.createElement("div");
  actions.className = "actions";
  actions.appendChild(button("Modifier", () => {
    const values = cardEdit(c);
    values.force = values.force ?? "";
    values.endurance = values.endurance ?? "";
    editing = { key: `card:${c.id}`, values, error: null };
    renderEditor();
  }));
  if (pc.withdrawn) {
    actions.appendChild(button("Rétablir", () => {
      if (window.confirm(`Remettre « ${c.n} » au catalogue ?`)) propose("revise_card", { edit: cardEdit(c) });
    }));
  } else {
    actions.appendChild(button("Retirer", () => {
      if (window.confirm(`Retirer « ${c.n} » du catalogue ? Elle ne sortira plus des boosters ; ceux qui l'ont la gardent.`)) {
        propose("withdraw_card", { id: c.id });
      }
    }));
  }
  div.append(meta, name, text, flagLine(pc, true), actions);
  return div;
}

function cardForm(pc) {
  const c = pc.card;
  const div = document.createElement("div");
  div.className = `album-card ${editing.values.rarity}`;
  const meta = document.createElement("div");
  meta.className = "meta";
  meta.textContent = `${cardMeta(c)} · ${c.id}`;
  const form = document.createElement("div");
  form.className = "edit-form";
  const rarity = document.createElement("select");
  for (const [k, label] of Object.entries(RARITY)) rarity.add(new Option(label, k));
  rarity.value = editing.values.rarity;
  rarity.addEventListener("change", () => {
    editing.values.rarity = rarity.value;
    div.className = `album-card ${rarity.value}`;
  });
  const stats = document.createElement("div");
  stats.className = "inline";
  stats.append(
    field(pc.base ? "Force (vide : aucune)" : "Force (vide : règle par rareté)",
      bound("force", "input", { type: "number", min: 0, max: 12 })),
    field("Endurance", bound("endurance", "input", { type: "number", min: 0, max: 12 })),
  );
  form.append(
    field("Nom", bound("name", "input", { maxLength: 60 })),
    field("Texte", bound("flavor", "textarea", { rows: 3, maxLength: 200 })),
    field("Rareté", rarity),
    field(pc.base ? "Icône (Interface\\Icons\\…, vide : celle d'origine)" : "Icône (Interface\\Icons\\…, vide : celle de la série)",
      bound("icon")),
    stats,
    formButtons(() => {
      const v = editing.values;
      const num = (x) => (String(x).trim() === "" ? null : Number(x));
      editing.error = null;
      propose("revise_card", { edit: { ...v, force: num(v.force), endurance: num(v.endurance) } });
    }),
  );
  div.append(meta, form);
  return div;
}

function renderCatalogue() {
  const box = $("catalogue");
  box.textContent = "";
  const cards = published?.cards ?? [];
  const q = $("catalogue-search").value.trim().toLowerCase();
  const r = $("catalogue-rarity").value;
  const origin = $("catalogue-origin").value;
  const shown = cards.filter((pc) => {
    const c = pc.card;
    if (r && c.r !== r) return false;
    if (origin && pc.base !== (origin === "base")) return false;
    if (!q) return true;
    return [c.n, c.f, String(c.no ?? "")].some((v) => (v ?? "").toLowerCase().includes(q));
  });
  $("catalogue-title").textContent = cards.length
    ? `Catalogue de l'album (${shown.length} sur ${cards.length} carte(s))`
    : "Catalogue de l'album";
  if (cards.length === 0) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = published ? "Aucune carte publiée." : "";
    box.appendChild(p);
  }
  shown.sort((a, b) => a.base - b.base);   // guild cards first, then the base set
  for (const pc of shown) {
    box.appendChild(editing?.key === `card:${pc.card.id}` ? cardForm(pc) : cardView(pc));
  }
}

function articleEdit(a) {
  return { id: a.id, title: a.title, body: a.body, quote: a.quote ?? "", format: a.format ?? "", style: a.style ?? "" };
}

function articleView(a) {
  const div = document.createElement("div");
  div.className = `article${a.withdrawn ? " withdrawn" : ""}`;
  const meta = document.createElement("div");
  meta.className = "meta";
  meta.textContent = [a.order && `#${a.order}`, a.format, a.style, a.ia && "IA", `paru le ${dayFr(a.t)}`]
    .filter(Boolean).join(" · ");
  const h = document.createElement("h3");
  h.textContent = a.title;
  div.append(meta, h, flagLine(a, false));
  if (a.quote) {
    const q = document.createElement("blockquote");
    q.textContent = `« ${a.quote} »`;
    div.appendChild(q);
  }
  const more = document.createElement("details");
  const sum = document.createElement("summary");
  sum.textContent = "Lire";
  const body = document.createElement("div");
  body.className = "body";
  body.textContent = a.body;
  more.append(sum, body);
  const actions = document.createElement("div");
  actions.className = "actions";
  actions.appendChild(button("Modifier", () => {
    editing = { key: `article:${a.id}`, values: articleEdit(a), error: null };
    renderEditor();
  }));
  if (a.withdrawn) {
    actions.appendChild(button("Rétablir", () => {
      if (window.confirm(`Remettre « ${a.title} » dans son numéro ?`)) propose("revise_article", { edit: articleEdit(a) });
    }));
  } else {
    actions.appendChild(button("Retirer", () => {
      if (window.confirm(`Retirer « ${a.title} » de son numéro, pour toute la guilde ?`)) {
        propose("retract_article", { id: a.id });
      }
    }));
  }
  div.append(more, actions);
  return div;
}

function articleForm(a) {
  const div = document.createElement("div");
  div.className = "article";
  const form = document.createElement("div");
  form.className = "edit-form";
  const labels = document.createElement("div");
  labels.className = "inline";
  labels.append(
    field("Rubrique (vide : aucune)", bound("format", "input", { maxLength: 40 })),
    field("Style (vide : aucun)", bound("style", "input", { maxLength: 40 })),
  );
  form.append(
    field("Titre", bound("title", "input", { maxLength: 90 })),
    labels,
    field("Citation en exergue (vide : aucune)", bound("quote", "input", { maxLength: 140 })),
    field("Texte", bound("body", "textarea", { rows: 14, maxLength: 3500 })),
    formButtons(() => {
      editing.error = null;
      propose("revise_article", { edit: { ...editing.values } });
    }),
  );
  const meta = document.createElement("div");
  meta.className = "meta";
  meta.textContent = `Correction de l'article paru le ${dayFr(a.t)}${a.ia ? " (IA)" : ""}`;
  div.append(meta, form);
  return div;
}

function renderArchive() {
  const box = $("archive");
  box.textContent = "";
  const issues = published?.issues ?? [];
  if (issues.length === 0) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = published ? "Aucun numéro publié." : "";
    box.appendChild(p);
    return;
  }
  if (!issuesSeen) {
    issuesSeen = true;
    openIssues.add(issues[0].key ?? "-");
  }
  for (const issue of issues) {
    const key = issue.key ?? "-";
    const d = document.createElement("details");
    d.className = "issue";
    d.open = openIssues.has(key) || issue.articles.some((a) => editing?.key === `article:${a.id}`);
    d.addEventListener("toggle", () => { if (d.open) openIssues.add(key); else openIssues.delete(key); });
    const sum = document.createElement("summary");
    const live = issue.articles.filter((a) => !a.withdrawn).length;
    sum.textContent = issue.key
      ? `N° ${issue.number} · paru le ${dayFr(issue.t)} · ${live} article(s)`
      : `Articles d'avant les numéros · ${live} article(s)`;
    d.appendChild(sum);
    for (const a of issue.articles) {
      d.appendChild(editing?.key === `article:${a.id}` ? articleForm(a) : articleView(a));
    }
    box.appendChild(d);
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
    if (tab.dataset.tab === "editor") loadPublished();
  });
}

$("deaths").addEventListener("click", () => call("propose_deaths"));
$("editor-reload").addEventListener("click", () => loadPublished());
for (const sub of document.querySelectorAll(".subtab")) {
  sub.addEventListener("click", () => {
    for (const t of document.querySelectorAll(".subtab")) t.classList.toggle("active", t === sub);
    for (const p of document.querySelectorAll(".subpage")) p.hidden = p.id !== `sub-${sub.dataset.sub}`;
  });
}
$("catalogue-search").addEventListener("input", () => renderCatalogue());
$("catalogue-rarity").addEventListener("change", () => renderCatalogue());
$("catalogue-origin").addEventListener("change", () => renderCatalogue());
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
