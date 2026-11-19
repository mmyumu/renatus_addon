//! Reading the installed version and installing a release archive into
//! `Interface/AddOns`, with the same rules as `tools/deploy.sh`:
//! `Renatus` is replaced as a whole, `Renatus_Press/Press.lua` is never
//! overwritten (the companion writes it).

use std::fs;
use std::io::{self, Cursor};
use std::path::{Component, Path};

use zip::ZipArchive;

pub const ADDON: &str = "Renatus";
pub const PRESS: &str = "Renatus_Press";
const PRESS_DATA: &str = "Press.lua";
const STAGING: &str = ".renatus-staging";
const PREVIOUS: &str = ".renatus-previous";

/// Value of the `## Version:` line of a .toc file.
pub fn toc_version(toc: &str) -> Option<String> {
    toc.lines()
        .find_map(|line| line.trim().strip_prefix("## Version:"))
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// Version of the Renatus addon installed in `addons`, if any.
pub fn installed_version(addons: &Path) -> Option<String> {
    let toc = fs::read_to_string(addons.join(ADDON).join(format!("{ADDON}.toc"))).ok()?;
    toc_version(&toc)
}

/// Installs a release archive (`Renatus/…` and `Renatus_Press/…` at its root)
/// into `addons` and returns the installed version.
///
/// The archive is fully extracted next to the addons first, so a broken
/// download never leaves a half-written addon; the old `Renatus` folder is
/// then swapped with the new one and put back if the swap fails.
pub fn install_zip(addons: &Path, archive: &[u8]) -> Result<String, String> {
    fs::create_dir_all(addons).map_err(|e| io_error("création du dossier AddOns", &e))?;
    let staging = addons.join(STAGING);
    let previous = addons.join(PREVIOUS);
    remove_dir(&staging)?;
    remove_dir(&previous)?;

    let result = extract(archive, &staging).and_then(|()| swap_in(addons, &staging, &previous));
    let _ = remove_dir(&staging);
    result
}

fn extract(archive: &[u8], staging: &Path) -> Result<(), String> {
    let mut zip =
        ZipArchive::new(Cursor::new(archive)).map_err(|e| format!("Archive illisible : {e}"))?;
    for i in 0..zip.len() {
        let mut entry = zip
            .by_index(i)
            .map_err(|e| format!("Archive illisible : {e}"))?;
        // enclosed_name rejects absolute paths and `..` (zip slip).
        let rel = entry
            .enclosed_name()
            .ok_or_else(|| format!("Chemin refusé dans l'archive : {}", entry.name()))?;
        match rel.components().next() {
            Some(Component::Normal(top)) if top == ADDON || top == PRESS => {}
            _ => {
                return Err(format!(
                    "Fichier inattendu dans l'archive : {}",
                    entry.name()
                ))
            }
        }
        let dest = staging.join(&rel);
        if entry.is_dir() {
            fs::create_dir_all(&dest).map_err(|e| io_error("extraction", &e))?;
            continue;
        }
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| io_error("extraction", &e))?;
        }
        let mut out = fs::File::create(&dest).map_err(|e| io_error("extraction", &e))?;
        io::copy(&mut entry, &mut out).map_err(|e| io_error("extraction", &e))?;
    }
    Ok(())
}

fn swap_in(addons: &Path, staging: &Path, previous: &Path) -> Result<String, String> {
    let new_addon = staging.join(ADDON);
    let version = installed_version(staging).ok_or_else(|| {
        format!("L'archive ne contient pas {ADDON}/{ADDON}.toc avec une version.")
    })?;

    let target = addons.join(ADDON);
    if target.exists() {
        fs::rename(&target, previous).map_err(|e| io_error("remplacement de l'addon", &e))?;
    }
    if let Err(e) = fs::rename(&new_addon, &target) {
        if previous.exists() {
            let _ = fs::rename(previous, &target);
        }
        return Err(io_error("remplacement de l'addon", &e));
    }
    let _ = remove_dir(previous);

    let new_press = staging.join(PRESS);
    if new_press.is_dir() {
        install_press(&new_press, &addons.join(PRESS))?;
    }
    Ok(version)
}

/// Copies the press files, keeping an existing Press.lua.
fn install_press(from: &Path, to: &Path) -> Result<(), String> {
    fs::create_dir_all(to).map_err(|e| io_error("installation de Renatus_Press", &e))?;
    let entries = fs::read_dir(from).map_err(|e| io_error("installation de Renatus_Press", &e))?;
    for entry in entries {
        let entry = entry.map_err(|e| io_error("installation de Renatus_Press", &e))?;
        let dest = to.join(entry.file_name());
        if !entry.path().is_file() || (entry.file_name() == PRESS_DATA && dest.exists()) {
            continue;
        }
        fs::copy(entry.path(), &dest).map_err(|e| io_error("installation de Renatus_Press", &e))?;
    }
    Ok(())
}

fn remove_dir(path: &Path) -> Result<(), String> {
    match fs::remove_dir_all(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(io_error("nettoyage", &e)),
        _ => Ok(()),
    }
}

fn io_error(step: &str, e: &io::Error) -> String {
    format!("Erreur pendant {step} : {e}")
}
