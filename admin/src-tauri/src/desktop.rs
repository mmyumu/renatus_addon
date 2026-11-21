//! Windows shell of the admin app: one window, the work happens in renatus-admin-core.
//!
//! Every 20 s it re-reads the installed addon versions (the launcher may update them)
//! and looks at the addon's SavedVariables. When the game rewrote them
//! (/reload, logout) and "automatique" is on, it proposes the combat-log deaths and, if
//! asked, writes the week's AI gazette, then notifies: "N éléments en attente, /reload".
//! The rival guild is re-read from the armory at launch, then every hour.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use renatus_admin_core::config::Config;
use renatus_admin_core::ops::{self, Proposal, Status};
use renatus_admin_core::paths::{WowPaths, ADMIN_ADDON};
use renatus_admin_core::{addon, armory, chronicle::Chronicle, edition, gazette, issues, revise};
use renatus_launcher_core::wow;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_updater::{Update, UpdaterExt};

const WATCH_EVERY: Duration = Duration::from_secs(20);
const ARMORY_EVERY: Duration = Duration::from_secs(3600);
const BUSY_RETRY: Duration = Duration::from_secs(60);
const MAX_LOG: usize = 300;
const APP_UPDATE_EVERY: Duration = Duration::from_secs(3600);

struct Shared {
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    config: Config,
    config_path: PathBuf,
    status: Option<Status>,
    roster: Option<armory::Guild>,
    log: Vec<LogLine>,
    busy: Option<String>,
    sv_seen: Option<SystemTime>,
    admin_available: Option<String>,
    /// Newer version of this app, found by the updater (installed on demand).
    app_update: Option<String>,
    draft: Option<Draft>,
    /// Facts offered for the next issue (prepare_gazette), kept for write_gazette.
    selection: Option<issues::Selection>,
}

/// AI gazette written from the window, kept here until the editor proposes or discards it.
#[derive(Serialize, Clone)]
struct Draft {
    at: i64,
    #[serde(flatten)]
    proposal: Proposal,
}

#[derive(Serialize, Clone)]
struct LogLine {
    at: i64,
    text: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct RosterMember {
    name: String,
    level: u32,
    class: String,
    race: String,
    rank: u32,
    known: bool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct RosterView {
    name: String,
    faction: Option<String>,
    count: u32,
    fetched_at: Option<i64>,
    members: Vec<RosterMember>,
}

/// What the window shows.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct View {
    config: Config,
    accounts: Vec<String>,
    status: Option<Status>,
    roster: Option<RosterView>,
    log: Vec<LogLine>,
    busy: Option<String>,
    admin_available: Option<String>,
    draft: Option<Draft>,
    selection: Option<issues::Selection>,
    app_version: String,
    app_update: Option<String>,
}

fn view(app: &AppHandle) -> View {
    let shared = app.state::<Shared>();
    let s = shared.state.lock().unwrap();
    let known: Vec<String> = s
        .status
        .as_ref()
        .map(|st| st.wanted.clone())
        .unwrap_or_default();
    let roster = s.roster.as_ref().map(|g| RosterView {
        name: g.name.clone(),
        faction: g.faction_name.clone(),
        count: g.member_count,
        fetched_at: g.fetched_at.map(|ms| ms / 1000),
        members: g
            .members
            .iter()
            .map(|m| RosterMember {
                name: m.name.clone(),
                level: m.level,
                class: armory::class_token(m.class_id).to_string(),
                race: g
                    .race_names
                    .get(&m.race_id.to_string())
                    .map(|r| armory::race_fr(r))
                    .unwrap_or_default(),
                rank: m.rank,
                known: known.iter().any(|k| armory::same_character(k, &m.name)),
            })
            .collect(),
    });
    View {
        config: s.config.clone(),
        accounts: s
            .config
            .paths()
            .map(|p| p.accounts_with_data())
            .unwrap_or_default(),
        status: s.status.clone(),
        roster,
        log: s.log.clone(),
        busy: s.busy.clone(),
        admin_available: s.admin_available.clone(),
        draft: s.draft.clone(),
        selection: s.selection.clone(),
        app_version: app.package_info().version.to_string(),
        app_update: s.app_update.clone(),
    }
}

fn publish_view(app: &AppHandle) {
    let _ = app.emit("state", view(app));
}

fn log(app: &AppHandle, lines: impl IntoIterator<Item = String>) {
    let shared = app.state::<Shared>();
    let mut s = shared.state.lock().unwrap();
    let at = ops::now();
    s.log
        .extend(lines.into_iter().map(|text| LogLine { at, text }));
    let excess = s.log.len().saturating_sub(MAX_LOG);
    s.log.drain(..excess);
}

fn save_config(app: &AppHandle, change: impl FnOnce(&mut Config)) -> Result<(), String> {
    let shared = app.state::<Shared>();
    let mut s = shared.state.lock().unwrap();
    change(&mut s.config);
    s.config.save(&s.config_path)
}

fn config(app: &AppHandle) -> Config {
    app.state::<Shared>().state.lock().unwrap().config.clone()
}

fn game_paths(cfg: &Config) -> Result<WowPaths, String> {
    cfg.paths()
        .ok_or_else(|| "Dossier du jeu inconnu : choisis-le dans Réglages.".to_string())
}

fn refresh_status(app: &AppHandle) {
    let cfg = config(app);
    let status = cfg.paths().map(|p| ops::status(&p));
    app.state::<Shared>().state.lock().unwrap().status = status;
}

// ---------------------------------------------------------------------------
// Jobs: one at a time, off the UI thread
// ---------------------------------------------------------------------------

/// Runs `work` in the background, flagged as busy (one job at a time).
async fn busy<T, F>(app: &AppHandle, label: &str, work: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce(&Config, &WowPaths, &Chronicle) -> Result<T, String> + Send + 'static,
{
    {
        let shared = app.state::<Shared>();
        let mut s = shared.state.lock().unwrap();
        if let Some(b) = &s.busy {
            return Err(format!("Patiente : {b} en cours."));
        }
        s.busy = Some(label.to_string());
    }
    publish_view(app);
    let cfg = config(app);
    let result = tauri::async_runtime::spawn_blocking(move || -> Result<T, String> {
        let paths = game_paths(&cfg)?;
        let (_, ch) = ops::load(&paths)?;
        work(&cfg, &paths, &ch)
    })
    .await
    .map_err(|e| e.to_string())
    .and_then(|r| r);
    app.state::<Shared>().state.lock().unwrap().busy = None;
    result
}

/// Runs `work` in the background; its proposal goes to Press.lua.
async fn job<F>(app: AppHandle, label: &str, work: F) -> Result<View, String>
where
    F: FnOnce(&Config, &WowPaths, &Chronicle) -> Result<Proposal, String> + Send + 'static,
{
    let result = busy(&app, label, move |cfg, paths, ch| {
        let proposal = work(cfg, paths, ch)?;
        let pending = ops::publish(paths, ch, proposal.items.clone())?;
        Ok((proposal, pending))
    })
    .await;
    match &result {
        Ok((p, pending)) => {
            let mut lines = vec![format!("— {label}")];
            lines.extend(p.notes.iter().cloned());
            lines.push(format!(
                "{} élément(s) proposé(s), {pending} en attente dans Press.lua. En jeu : /reload, puis Gazette > Rédaction.",
                p.items.len()
            ));
            log(&app, lines);
        }
        Err(e) => log(&app, [format!("— {label} : {e}")]),
    }
    refresh_status(&app);
    publish_view(&app);
    result.map(|_| view(&app))
}

fn rival_work(
    app: &AppHandle,
) -> impl FnOnce(&Config, &WowPaths, &Chronicle) -> Result<Proposal, String> {
    let app = app.clone();
    move |cfg, _, ch| {
        let (guild, proposal) = ops::rival(&cfg.rival, ch)?;
        let shared = app.state::<Shared>();
        let mut s = shared.state.lock().unwrap();
        s.roster = Some(guild);
        s.config.last_armory = Some(ops::now());
        let _ = s.config.save(&s.config_path);
        Ok(proposal)
    }
}

/// The rival guild is re-read from the armory at launch, then every hour (new members,
/// levels, ranks); a changed roster is proposed in game. If another job is running, it
/// tries again a minute later.
async fn rival_loop(app: AppHandle) {
    loop {
        let mut wait = ARMORY_EVERY;
        if !config(&app).rival.trim().is_empty() {
            let work = rival_work(&app);
            if let Err(e) = job(app.clone(), "Armurerie (toutes les heures)", work).await {
                if e.starts_with("Patiente") {
                    wait = BUSY_RETRY;
                }
            }
        }
        tokio::time::sleep(wait).await;
    }
}

// ---------------------------------------------------------------------------
// Commands called by the window
// ---------------------------------------------------------------------------

#[tauri::command]
fn get_state(app: AppHandle) -> View {
    view(&app)
}

#[tauri::command]
fn reload(app: AppHandle) -> View {
    refresh_status(&app);
    view(&app)
}

#[tauri::command]
async fn propose_deaths(app: AppHandle) -> Result<View, String> {
    job(app, "Journaux de combat", |_, paths, ch| {
        Ok(ops::deaths(paths, ch, None))
    })
    .await
}

#[tauri::command]
async fn refresh_rival(app: AppHandle, rival: String) -> Result<View, String> {
    save_config(&app, |c| c.rival = rival.trim().to_string())?;
    let work = rival_work(&app);
    job(app, "Armurerie", work).await
}

/// Writes the AI gazette as a draft shown in the Gazette tab: nothing goes to Press.lua
/// before "Proposer en jeu" (propose_gazette). `keys`: the facts ticked in the selection.
#[tauri::command]
async fn write_gazette(app: AppHandle, keys: Vec<String>) -> Result<View, String> {
    let sel = app
        .state::<Shared>()
        .state
        .lock()
        .unwrap()
        .selection
        .clone()
        .ok_or("Prépare d'abord la gazette (liste des faits).")?;
    let result = busy(&app, "Gazette", move |cfg, _, ch| {
        Ok(ops::gazette(
            ch,
            &sel,
            &keys,
            cfg.articles_dir.as_deref(),
            &cfg.llm_command,
            Duration::from_secs(cfg.llm_timeout_secs),
            &cfg.gazette_template,
        ))
    })
    .await;
    match result {
        Ok(proposal) => {
            let mut lines = vec!["— Gazette (brouillon)".to_string()];
            lines.extend(proposal.notes.iter().cloned());
            lines.push(
                "Brouillon à relire dans l'onglet Gazette, rien n'est encore dans Press.lua."
                    .into(),
            );
            log(&app, lines);
            app.state::<Shared>().state.lock().unwrap().draft = Some(Draft {
                at: ops::now(),
                proposal,
            });
        }
        Err(e) => {
            log(&app, [format!("— Gazette : {e}")]);
            publish_view(&app);
            return Err(e);
        }
    }
    publish_view(&app);
    Ok(view(&app))
}

/// Sends the draft to Press.lua, for publishing in game.
#[tauri::command]
async fn propose_gazette(app: AppHandle) -> Result<View, String> {
    let items = {
        let shared = app.state::<Shared>();
        let s = shared.state.lock().unwrap();
        match &s.draft {
            Some(d) if !d.proposal.items.is_empty() => d.proposal.items.clone(),
            _ => return Err("Aucun article à proposer.".into()),
        }
    };
    let view = job(app.clone(), "Gazette", move |_, _, _| {
        Ok(Proposal {
            items,
            notes: Vec::new(),
            answer: None,
        })
    })
    .await?;
    {
        // Its facts are now waiting in Press.lua: the next issue starts from a new selection.
        let shared = app.state::<Shared>();
        let mut s = shared.state.lock().unwrap();
        s.draft = None;
        s.selection = None;
    }
    publish_view(&app);
    Ok(View {
        draft: None,
        selection: None,
        ..view
    })
}

/// Takes pending items (ids) or single album cards (card ids) out of Press.lua.
#[tauri::command]
async fn remove_pending(
    app: AppHandle,
    items: Vec<String>,
    cards: Vec<String>,
) -> Result<View, String> {
    let what = items.len() + cards.len();
    let result = busy(&app, "Retrait", move |_, paths, ch| {
        ops::remove_pending(paths, ch, &items, &cards)
    })
    .await;
    match &result {
        Ok(left) => log(
            &app,
            [format!(
                "— Retiré de Press.lua : {what} élément(s) ; {left} en attente."
            )],
        ),
        Err(e) => log(&app, [format!("— Retrait : {e}")]),
    }
    refresh_status(&app);
    publish_view(&app);
    result.map(|_| view(&app))
}

/// The published catalogue and issues, as members see them (Éditeur tab).
#[tauri::command]
async fn published(app: AppHandle) -> Result<ops::Published, String> {
    let cfg = config(&app);
    tauri::async_runtime::spawn_blocking(move || {
        let paths = game_paths(&cfg)?;
        let (_, ch) = ops::load(&paths)?;
        Ok::<_, String>(ops::published(&paths, &ch))
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Puts one correction of something published (revise.rs) in Press.lua.
async fn propose_fix<F>(app: AppHandle, label: String, make: F) -> Result<View, String>
where
    F: FnOnce(&Chronicle, i64) -> Result<serde_json::Value, String> + Send + 'static,
{
    let result = busy(&app, "Correction", move |_, paths, ch| {
        let item = make(ch, ops::now())?;
        ops::propose_fix(paths, ch, item)
    })
    .await;
    match &result {
        Ok(left) => log(
            &app,
            [format!(
                "— {label} : proposé en jeu, {left} en attente dans Press.lua. En jeu : /reload, puis Rédaction."
            )],
        ),
        Err(e) => log(&app, [format!("— {label} : {e}")]),
    }
    refresh_status(&app);
    publish_view(&app);
    result.map(|_| view(&app))
}

#[tauri::command]
async fn revise_card(app: AppHandle, edit: revise::CardEdit) -> Result<View, String> {
    let label = format!("Correction de la carte « {} »", edit.name.trim());
    propose_fix(app, label, move |ch, now| revise::card_item(ch, &edit, now)).await
}

#[tauri::command]
async fn withdraw_card(app: AppHandle, id: String) -> Result<View, String> {
    let label = format!("Retrait de la carte {id}");
    propose_fix(app, label, move |ch, now| {
        revise::withdraw_card_item(ch, &id, now)
    })
    .await
}

#[tauri::command]
async fn revise_article(app: AppHandle, edit: revise::ArticleEdit) -> Result<View, String> {
    let label = format!("Correction de l'article « {} »", edit.title.trim());
    propose_fix(app, label, move |ch, now| {
        revise::article_item(ch, &edit, now)
    })
    .await
}

#[tauri::command]
async fn retract_article(app: AppHandle, id: String) -> Result<View, String> {
    let label = format!("Retrait de l'article {id}");
    propose_fix(app, label, move |ch, now| {
        revise::retract_article_item(ch, &id, now)
    })
    .await
}

#[tauri::command]
fn discard_gazette(app: AppHandle) -> View {
    app.state::<Shared>().state.lock().unwrap().draft = None;
    log(&app, ["— Gazette : brouillon jeté.".to_string()]);
    view(&app)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Preview {
    summary: Vec<String>,
    prompt: String,
}

/// Lists the facts offered for the next issue (new ones ticked).
#[tauri::command]
async fn prepare_gazette(app: AppHandle) -> Result<View, String> {
    let cfg = config(&app);
    let sel = tauri::async_runtime::spawn_blocking(move || {
        let paths = game_paths(&cfg)?;
        let (_, ch) = ops::load(&paths)?;
        Ok::<_, String>(ops::prepare(&paths, &ch))
    })
    .await
    .map_err(|e| e.to_string())??;
    app.state::<Shared>().state.lock().unwrap().selection = Some(sel);
    Ok(view(&app))
}

/// What would be sent to the AI for these facts.
#[tauri::command]
async fn preview_gazette(app: AppHandle, keys: Vec<String>) -> Result<Preview, String> {
    let sel = app
        .state::<Shared>()
        .state
        .lock()
        .unwrap()
        .selection
        .clone()
        .ok_or("Prépare d'abord la gazette (liste des faits).")?;
    let cfg = config(&app);
    tauri::async_runtime::spawn_blocking(move || {
        let paths = game_paths(&cfg)?;
        let (_, ch) = ops::load(&paths)?;
        let b = sel.brief_for(&keys);
        Ok(Preview {
            summary: ops::brief_summary(&b, ch.members().len()),
            prompt: gazette::prompt(&b),
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Settings {
    account: Option<String>,
    llm_command: String,
    llm_timeout_secs: u64,
    gazette_template: String,
    auto: bool,
    auto_gazette: bool,
    test_channel: bool,
}

#[tauri::command]
fn save_settings(app: AppHandle, settings: Settings) -> Result<View, String> {
    let command: Vec<String> = serde_json::from_str(&settings.llm_command).map_err(|e| {
        format!("Commande de l'IA : liste JSON attendue, ex. [\"ssh\", \"pi5\", \"…\"] ({e})")
    })?;
    if command.is_empty() {
        return Err("Commande de l'IA vide.".into());
    }
    save_config(&app, |c| {
        c.account = settings.account.filter(|a| !a.is_empty());
        c.llm_command = command;
        c.llm_timeout_secs = settings.llm_timeout_secs.clamp(30, 3600);
        c.gazette_template = if edition::is_template(&settings.gazette_template) {
            settings.gazette_template.clone()
        } else {
            "auto".into()
        };
        c.auto = settings.auto;
        c.auto_gazette = settings.auto_gazette;
        c.test_channel = settings.test_channel;
    })?;
    refresh_status(&app);
    Ok(view(&app))
}

/// Folder dialog, off the UI thread.
async fn pick_folder(app: &AppHandle, title: &'static str) -> Result<Option<PathBuf>, String> {
    let app = app.clone();
    let picked = tauri::async_runtime::spawn_blocking(move || {
        app.dialog().file().set_title(title).blocking_pick_folder()
    })
    .await
    .map_err(|e| e.to_string())?;
    picked
        .map(|p| p.into_path().map_err(|e| e.to_string()))
        .transpose()
}

#[tauri::command]
async fn pick_wow_folder(app: AppHandle) -> Result<View, String> {
    let picked = pick_folder(
        &app,
        "Dossier de World of Warcraft (celui qui contient _forever_)",
    )
    .await?;
    let Some(picked) = picked else {
        return Ok(view(&app));
    };
    let flavor = wow::resolve_flavor_dir(&picked).ok_or_else(|| {
        format!(
            "Pas de dossier {} dans {} : choisis le dossier « World of Warcraft ».",
            wow::FLAVOR,
            picked.display()
        )
    })?;
    save_config(&app, |c| c.wow_path = Some(flavor))?;
    refresh_status(&app);
    Ok(view(&app))
}

#[tauri::command]
async fn pick_articles_dir(app: AppHandle) -> Result<View, String> {
    let picked = pick_folder(&app, "Dossier des articles (.md)").await?;
    if let Some(dir) = picked {
        save_config(&app, |c| c.articles_dir = Some(dir))?;
    }
    Ok(view(&app))
}

#[tauri::command]
async fn install_admin_addon(app: AppHandle) -> Result<View, String> {
    let cfg = config(&app);
    let result = tauri::async_runtime::spawn_blocking(move || -> Result<(String, bool), String> {
        let paths = game_paths(&cfg)?;
        let release = addon::latest(cfg.test_channel)?
            .ok_or("Aucune release ne contient encore Renatus_Admin.")?;
        let first = addon::installed_version(&paths.addons(), "Renatus_Admin").is_none();
        let bytes = addon::download(&release)?;
        Ok((addon::install_zip(&paths.addons(), &bytes)?, first))
    })
    .await
    .map_err(|e| e.to_string())?;
    match &result {
        Ok((v, first)) => log(
            &app,
            [format!(
                "Renatus_Admin {v} installé. {}",
                if *first {
                    "Redémarre le jeu une fois."
                } else {
                    "En jeu : /reload"
                }
            )],
        ),
        Err(e) => log(&app, [format!("Installation de Renatus_Admin : {e}")]),
    }
    refresh_status(&app);
    result.map(|_| view(&app))
}

#[tauri::command]
fn open_folder(app: AppHandle, which: String) -> Result<(), String> {
    let cfg = config(&app);
    let paths = game_paths(&cfg)?;
    let path = match which.as_str() {
        "logs" => paths.logs(),
        "articles" => cfg.articles_dir.ok_or("Dossier des articles non choisi.")?,
        _ => paths.addons(),
    };
    std::process::Command::new("explorer")
        .arg(path)
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// Watching the SavedVariables
// ---------------------------------------------------------------------------

fn sv_modified(cfg: &Config) -> Option<SystemTime> {
    let sv = cfg.paths()?.saved_variables().ok()?;
    std::fs::metadata(sv).ok()?.modified().ok()
}

/// Versions of Renatus and Renatus_Admin on disk differ from the ones shown (installed
/// meanwhile by the launcher, the update button or a deploy)?
fn addon_versions_changed(app: &AppHandle, cfg: &Config) -> bool {
    let Some(paths) = cfg.paths() else {
        return false;
    };
    let addons = paths.addons();
    let renatus = addon::installed_version(&addons, "Renatus");
    let admin = addon::installed_version(&addons, ADMIN_ADDON);
    let shared = app.state::<Shared>();
    let s = shared.state.lock().unwrap();
    s.status
        .as_ref()
        .is_some_and(|st| st.renatus_version != renatus || st.admin_version != admin)
}

async fn watch(app: AppHandle) {
    loop {
        tokio::time::sleep(WATCH_EVERY).await;
        let cfg = config(&app);
        if addon_versions_changed(&app, &cfg) {
            refresh_status(&app);
            publish_view(&app);
        }
        let Some(modified) = sv_modified(&cfg) else {
            continue;
        };
        let changed = {
            let shared = app.state::<Shared>();
            let mut s = shared.state.lock().unwrap();
            let changed = s.sv_seen.is_some_and(|seen| seen != modified);
            s.sv_seen = Some(modified);
            changed
        };
        if !changed {
            continue;
        }
        refresh_status(&app);
        publish_view(&app);
        if !cfg.auto {
            continue;
        }
        let before = pending(&app);
        let _ = job(
            app.clone(),
            "Automatique : journaux de combat",
            |_, p, ch| Ok(ops::deaths(p, ch, None)),
        )
        .await;
        if cfg.auto_gazette {
            let due = cfg
                .paths()
                .and_then(|p| ops::load(&p).ok().map(|(_, ch)| ops::issue_due(&p, &ch)))
                .unwrap_or(false);
            if due {
                // New facts only (the default selection), plus the hand-written articles.
                let _ = job(app.clone(), "Automatique : gazette", |cfg, paths, ch| {
                    let sel = ops::prepare(paths, ch);
                    Ok(ops::gazette(
                        ch,
                        &sel,
                        &sel.checked_keys(),
                        cfg.articles_dir.as_deref(),
                        &cfg.llm_command,
                        Duration::from_secs(cfg.llm_timeout_secs),
                        &cfg.gazette_template,
                    ))
                })
                .await;
            }
        }
        let after = pending(&app);
        if after > before {
            let _ = app
                .notification()
                .builder()
                .title("Renatus Admin")
                .body(format!(
                    "{after} élément(s) en attente. En jeu : /reload, puis Gazette > Rédaction."
                ))
                .show();
        }
    }
}

fn pending(app: &AppHandle) -> usize {
    app.state::<Shared>()
        .state
        .lock()
        .unwrap()
        .status
        .as_ref()
        .map_or(0, |s| s.pending)
}

async fn check_admin_release(app: AppHandle) {
    let include_test = config(&app).test_channel;
    if let Ok(Ok(Some(r))) =
        tauri::async_runtime::spawn_blocking(move || addon::latest(include_test)).await
    {
        app.state::<Shared>().state.lock().unwrap().admin_available = Some(r.version);
        publish_view(&app);
    }
}

/// Looks for a newer signed release of this app; records it for the window.
async fn find_app_update(app: &AppHandle) -> Result<Option<Update>, String> {
    let update = app
        .updater()
        .map_err(|e| e.to_string())?
        .check()
        .await
        .map_err(|e| e.to_string())?;
    app.state::<Shared>().state.lock().unwrap().app_update =
        update.as_ref().map(|u| u.version.clone());
    publish_view(app);
    Ok(update)
}

/// Installs the update and restarts the app (does not return when it succeeds).
async fn install_app_update(app: &AppHandle, update: Update) -> Result<(), String> {
    update
        .download_and_install(|_, _| {}, || {})
        .await
        .map_err(|e| e.to_string())?;
    app.restart();
}

/// At start: installs a newer version right away.
async fn self_update(app: &AppHandle) -> Result<(), String> {
    if let Some(update) = find_app_update(app).await? {
        install_app_update(app, update).await?;
    }
    Ok(())
}

/// While the window is open: only tells that a newer version exists (installing it
/// would interrupt a job); the button in Accueil installs it.
async fn watch_app_updates(app: AppHandle) {
    loop {
        tokio::time::sleep(APP_UPDATE_EVERY).await;
        let _ = find_app_update(&app).await;
    }
}

/// "Mettre à jour" button: checks now, installs and restarts if there is something newer.
#[tauri::command]
async fn update_app(app: AppHandle) -> Result<View, String> {
    {
        let shared = app.state::<Shared>();
        let mut s = shared.state.lock().unwrap();
        if let Some(b) = &s.busy {
            return Err(format!("Patiente : {b} en cours."));
        }
        s.busy = Some("Mise à jour de l'application".to_string());
    }
    publish_view(&app);
    let current = app.package_info().version.to_string();
    let result = match find_app_update(&app).await {
        Ok(None) => {
            log(&app, [format!("Renatus Admin {current} est à jour.")]);
            Ok(())
        }
        Ok(Some(update)) => {
            log(
                &app,
                [format!(
                    "Installation de Renatus Admin {} : l'application va redémarrer.",
                    update.version
                )],
            );
            publish_view(&app);
            install_app_update(&app, update).await
        }
        Err(e) => Err(e),
    };
    app.state::<Shared>().state.lock().unwrap().busy = None;
    if let Err(e) = &result {
        log(&app, [format!("Mise à jour de Renatus Admin : {e}")]);
    }
    publish_view(&app);
    result.map(|_| view(&app))
}

fn detect_wow() -> Option<PathBuf> {
    use winreg::enums::HKEY_LOCAL_MACHINE;
    use winreg::RegKey;
    let keys = [
        (
            r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
            "InstallPath",
        ),
        (
            r"SOFTWARE\Blizzard Entertainment\World of Warcraft",
            "InstallPath",
        ),
    ];
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let registry: Vec<PathBuf> = keys
        .iter()
        .filter_map(|(key, value)| {
            hklm.open_subkey(key)
                .ok()?
                .get_value::<String, _>(value)
                .ok()
        })
        .map(PathBuf::from)
        .collect();
    let drives: Vec<char> = ('C'..='H')
        .filter(|d| PathBuf::from(format!(r"{d}:\")).exists())
        .collect();
    wow::detect(&wow::candidates(&registry, &drives))
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.set_focus();
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            let config_path = app.path().app_config_dir()?.join("config.json");
            let mut config = Config::load(&config_path);
            if config.wow_path.is_none() {
                config.wow_path = detect_wow();
            }
            let _ = config.save(&config_path);
            let sv_seen = sv_modified(&config);
            app.manage(Shared {
                state: Mutex::new(State {
                    config,
                    config_path,
                    sv_seen,
                    ..State::default()
                }),
            });
            let handle = app.handle().clone();
            refresh_status(&handle);
            tauri::async_runtime::spawn(watch(handle.clone()));
            tauri::async_runtime::spawn(check_admin_release(handle.clone()));
            tauri::async_runtime::spawn(rival_loop(handle.clone()));
            if !cfg!(debug_assertions) {
                tauri::async_runtime::spawn(watch_app_updates(handle.clone()));
                tauri::async_runtime::spawn(async move {
                    let _ = self_update(&handle).await;
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            reload,
            propose_deaths,
            refresh_rival,
            write_gazette,
            propose_gazette,
            discard_gazette,
            remove_pending,
            published,
            revise_card,
            withdraw_card,
            revise_article,
            retract_article,
            prepare_gazette,
            preview_gazette,
            save_settings,
            pick_wow_folder,
            pick_articles_dir,
            install_admin_addon,
            update_app,
            open_folder
        ])
        .run(tauri::generate_context!())
        .expect("échec du démarrage de Renatus Admin");
}
