//! Windows shell of the launcher: tray icon, window, background update loop.
//!
//! Every 10 minutes (or on demand) it reads the GitHub releases, installs the
//! newest addon release if it differs from the installed one, and shows a
//! notification. The launcher updates itself through tauri-plugin-updater.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use renatus_launcher_core::{addon, config::Config, release, wow};
use serde::Serialize;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, WindowEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt as _};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_updater::UpdaterExt;
use tokio::sync::Notify;

const RELEASES_API: &str = "https://api.github.com/repos/mmyumu/renatus_addon/releases?per_page=30";
const CHECK_EVERY: Duration = Duration::from_secs(10 * 60);
const SELF_UPDATE_EVERY: Duration = Duration::from_secs(6 * 60 * 60);
const MAX_ARCHIVE: u64 = 100 * 1024 * 1024;
const MINIMIZED_ARG: &str = "--minimized";

struct Shared {
    state: Mutex<State>,
    wake: Notify,
}

struct State {
    config: Config,
    config_path: PathBuf,
    installed: Option<String>,
    available: Option<release::AddonRelease>,
    last_check: Option<u64>,
    error: Option<String>,
    busy: bool,
    launcher: LauncherCheck,
}

/// State of the launcher's own update check.
#[derive(Default)]
struct LauncherCheck {
    /// Newest launcher version seen on GitHub.
    latest: Option<String>,
    last_check: Option<u64>,
    error: Option<String>,
    busy: bool,
}

/// What the window shows.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct View {
    wow_path: Option<String>,
    installed: Option<String>,
    available: Option<String>,
    notes: Option<String>,
    release_page: Option<String>,
    last_check: Option<u64>,
    error: Option<String>,
    busy: bool,
    test_channel: bool,
    autostart: bool,
    launcher_version: String,
    launcher_latest: Option<String>,
    launcher_last_check: Option<u64>,
    launcher_error: Option<String>,
    launcher_busy: bool,
}

fn view(app: &AppHandle) -> View {
    let shared = app.state::<Shared>();
    let s = shared.state.lock().unwrap();
    View {
        wow_path: s.config.wow_path.as_ref().map(|p| p.display().to_string()),
        installed: s.installed.clone(),
        available: s.available.as_ref().map(|r| r.version.clone()),
        notes: s.available.as_ref().map(|r| r.notes.clone()),
        release_page: s.available.as_ref().map(|r| r.page.clone()),
        last_check: s.last_check,
        error: s.error.clone(),
        busy: s.busy,
        test_channel: s.config.test_channel,
        autostart: s.config.autostart,
        launcher_version: app.package_info().version.to_string(),
        launcher_latest: s.launcher.latest.clone(),
        launcher_last_check: s.launcher.last_check,
        launcher_error: s.launcher.error.clone(),
        launcher_busy: s.launcher.busy,
    }
}

fn publish(app: &AppHandle) {
    let _ = app.emit("state", view(app));
}

fn save_config(app: &AppHandle, change: impl FnOnce(&mut Config)) -> Result<(), String> {
    let shared = app.state::<Shared>();
    let mut s = shared.state.lock().unwrap();
    change(&mut s.config);
    s.config.save(&s.config_path)
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Finding the game
// ---------------------------------------------------------------------------

fn registry_paths() -> Vec<PathBuf> {
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
        (
            r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft",
            "InstallLocation",
        ),
    ];
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    keys.iter()
        .filter_map(|(key, value)| {
            hklm.open_subkey(key)
                .ok()?
                .get_value::<String, _>(value)
                .ok()
        })
        .map(PathBuf::from)
        .collect()
}

fn detect_wow() -> Option<PathBuf> {
    let drives: Vec<char> = ('C'..='H')
        .filter(|d| PathBuf::from(format!(r"{d}:\")).exists())
        .collect();
    wow::detect(&wow::candidates(&registry_paths(), &drives))
}

// ---------------------------------------------------------------------------
// Addon updates
// ---------------------------------------------------------------------------

struct Outcome {
    installed: Option<String>,
    available: Option<release::AddonRelease>,
    /// (version, first install) when this check installed something.
    updated: Option<(String, bool)>,
}

async fn fetch_and_install(
    wow_path: Option<PathBuf>,
    test_channel: bool,
) -> Result<Outcome, String> {
    let flavor = wow_path
        .as_deref()
        .and_then(wow::resolve_flavor_dir)
        .ok_or("Dossier _forever_ introuvable : choisis le dossier du jeu avec « Changer ».")?;
    let addons = wow::addons_dir(&flavor);
    let before = addon::installed_version(&addons);

    let client = reqwest::Client::builder()
        .user_agent("renatus-launcher")
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|e| e.to_string())?;
    let releases: Vec<release::GhRelease> = client
        .get(RELEASES_API)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .and_then(|r| r.error_for_status())
        .map_err(|e| format!("GitHub injoignable : {e}"))?
        .json()
        .await
        .map_err(|e| format!("Réponse GitHub illisible : {e}"))?;

    let Some(wanted) = release::pick(&releases, test_channel) else {
        return Ok(Outcome {
            installed: before,
            available: None,
            updated: None,
        });
    };
    if before.as_deref() == Some(wanted.version.as_str()) {
        return Ok(Outcome {
            installed: before,
            available: Some(wanted),
            updated: None,
        });
    }
    if wanted.size > MAX_ARCHIVE {
        return Err(format!("Archive trop grosse ({} octets).", wanted.size));
    }
    let bytes = client
        .get(&wanted.url)
        .send()
        .await
        .and_then(|r| r.error_for_status())
        .map_err(|e| format!("Téléchargement impossible : {e}"))?
        .bytes()
        .await
        .map_err(|e| format!("Téléchargement interrompu : {e}"))?;
    let version = tauri::async_runtime::spawn_blocking(move || addon::install_zip(&addons, &bytes))
        .await
        .map_err(|e| e.to_string())??;
    Ok(Outcome {
        installed: Some(version.clone()),
        available: Some(wanted),
        updated: Some((version, before.is_none())),
    })
}

async fn check(app: &AppHandle) {
    let (wow_path, test_channel) = {
        let shared = app.state::<Shared>();
        let mut s = shared.state.lock().unwrap();
        if s.busy {
            return;
        }
        s.busy = true;
        (s.config.wow_path.clone(), s.config.test_channel)
    };
    publish(app);

    let result = fetch_and_install(wow_path, test_channel).await;
    let updated = {
        let shared = app.state::<Shared>();
        let mut s = shared.state.lock().unwrap();
        s.busy = false;
        s.last_check = Some(now());
        match result {
            Ok(outcome) => {
                s.installed = outcome.installed;
                s.available = outcome.available;
                s.error = None;
                outcome.updated
            }
            Err(e) => {
                s.error = Some(e);
                None
            }
        }
    };
    publish(app);

    if let Some((version, first)) = updated {
        let body = if first {
            "Redémarre le jeu une fois pour qu'il le détecte."
        } else {
            "En jeu : /reload"
        };
        let _ = app
            .notification()
            .builder()
            .title(format!("Renatus {version} installé"))
            .body(body)
            .show();
    }
}

/// Checks for a new launcher version (periodically or on demand) and installs it,
/// which restarts the launcher.
async fn self_update(app: &AppHandle) {
    {
        let shared = app.state::<Shared>();
        let mut s = shared.state.lock().unwrap();
        if s.launcher.busy {
            return;
        }
        s.launcher.busy = true;
        s.launcher.error = None;
    }
    publish(app);

    let result = install_launcher_update(app).await;
    {
        let shared = app.state::<Shared>();
        let mut s = shared.state.lock().unwrap();
        s.launcher.busy = false;
        s.launcher.last_check = Some(now());
        if let Err(e) = result {
            s.launcher.error = Some(format!("Mise à jour du launcher impossible : {e}"));
        }
    }
    publish(app);
}

async fn install_launcher_update(app: &AppHandle) -> Result<(), String> {
    let update = app
        .updater()
        .map_err(|e| e.to_string())?
        .check()
        .await
        .map_err(|e| e.to_string())?;
    let latest = update
        .as_ref()
        .map(|u| u.version.clone())
        .unwrap_or_else(|| app.package_info().version.to_string());
    app.state::<Shared>().state.lock().unwrap().launcher.latest = Some(latest);
    publish(app);
    if let Some(update) = update {
        update
            .download_and_install(|_, _| {}, || {})
            .await
            .map_err(|e| e.to_string())?;
        app.restart();
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Commands called by the window
// ---------------------------------------------------------------------------

#[tauri::command]
fn get_state(app: AppHandle) -> View {
    view(&app)
}

#[tauri::command]
fn check_now(app: AppHandle) {
    app.state::<Shared>().wake.notify_one();
}

#[tauri::command]
fn check_launcher_now(app: AppHandle) {
    tauri::async_runtime::spawn(async move { self_update(&app).await });
}

#[tauri::command]
async fn pick_wow_folder(app: AppHandle) -> Result<View, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.dialog()
        .file()
        .set_title("Dossier de World of Warcraft (celui qui contient _forever_)")
        .pick_folder(move |picked| {
            let _ = tx.send(picked);
        });
    let Some(picked) = rx.await.map_err(|e| e.to_string())? else {
        return Ok(view(&app));
    };
    let picked = picked.into_path().map_err(|e| e.to_string())?;
    let flavor = wow::resolve_flavor_dir(&picked).ok_or_else(|| {
        format!(
            "Pas de dossier {} dans {} : choisis le dossier « World of Warcraft ».",
            wow::FLAVOR,
            picked.display()
        )
    })?;
    save_config(&app, |c| c.wow_path = Some(flavor))?;
    app.state::<Shared>().wake.notify_one();
    Ok(view(&app))
}

#[tauri::command]
fn set_test_channel(app: AppHandle, enabled: bool) -> Result<View, String> {
    save_config(&app, |c| c.test_channel = enabled)?;
    app.state::<Shared>().wake.notify_one();
    Ok(view(&app))
}

#[tauri::command]
fn set_autostart(app: AppHandle, enabled: bool) -> Result<View, String> {
    apply_autostart(&app, enabled)?;
    save_config(&app, |c| c.autostart = enabled)?;
    Ok(view(&app))
}

#[tauri::command]
fn open_addons_folder(app: AppHandle) -> Result<(), String> {
    let path = {
        let shared = app.state::<Shared>();
        let s = shared.state.lock().unwrap();
        s.config.wow_path.as_deref().map(wow::addons_dir)
    };
    let path = path.ok_or("Dossier du jeu inconnu.")?;
    std::process::Command::new("explorer")
        .arg(path)
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

fn apply_autostart(app: &AppHandle, enabled: bool) -> Result<(), String> {
    let launcher = app.autolaunch();
    let current = launcher.is_enabled().unwrap_or(!enabled);
    match (enabled, current) {
        (true, false) => launcher.enable().map_err(|e| e.to_string()),
        (false, true) => launcher.disable().map_err(|e| e.to_string()),
        _ => Ok(()),
    }
}

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

fn show_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Ouvrir", true, None::<&str>)?;
    let check = MenuItem::with_id(app, "check", "Vérifier l'addon", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quitter", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &check, &quit])?;
    let mut tray = TrayIconBuilder::with_id("main")
        .tooltip("Renatus")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_window(app),
            "check" => app.state::<Shared>().wake.notify_one(),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_window(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;
    Ok(())
}

pub fn run() {
    tauri::Builder::default()
        // Must come first: a second launch only brings the running one forward.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_window(app)
        }))
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            Some(vec![MINIMIZED_ARG]),
        ))
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
            let handle = app.handle().clone();
            let _ = apply_autostart(&handle, config.autostart);

            let found = config.wow_path.is_some();
            app.manage(Shared {
                state: Mutex::new(State {
                    config,
                    config_path,
                    installed: None,
                    available: None,
                    last_check: None,
                    error: None,
                    busy: false,
                    launcher: LauncherCheck::default(),
                }),
                wake: Notify::new(),
            });
            build_tray(app)?;

            // Started with Windows: stay in the tray, unless the game still has to be found.
            if !std::env::args().any(|a| a == MINIMIZED_ARG) || !found {
                show_window(&handle);
            }

            let checker = handle.clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    check(&checker).await;
                    let shared = checker.state::<Shared>();
                    tokio::select! {
                        _ = shared.wake.notified() => {}
                        _ = tokio::time::sleep(CHECK_EVERY) => {}
                    }
                }
            });
            if !cfg!(debug_assertions) {
                tauri::async_runtime::spawn(async move {
                    loop {
                        self_update(&handle).await;
                        tokio::time::sleep(SELF_UPDATE_EVERY).await;
                    }
                });
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the window keeps the launcher in the tray.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            check_now,
            check_launcher_now,
            pick_wow_folder,
            set_test_channel,
            set_autostart,
            open_addons_folder
        ])
        .run(tauri::generate_context!())
        .expect("échec du démarrage du launcher Renatus");
}
