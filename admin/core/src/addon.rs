//! Installing and updating the officers' addon (Renatus_Admin) from the GitHub
//! releases. The members' launcher never installs it.
//!
//! `Renatus_Admin` is mirrored from the archive, except `Press.lua`, which this
//! app writes and which is kept as it is.

use std::fs;
use std::io::{self, Cursor};
use std::path::{Component, Path};
use std::time::Duration;

use renatus_launcher_core::release::GhRelease;
use zip::ZipArchive;

use crate::paths::ADMIN_ADDON;

pub const RELEASES_API: &str =
    "https://api.github.com/repos/mmyumu/renatus_addon/releases?per_page=30";
const PRESS_DATA: &str = "Press.lua";
const STAGING: &str = ".renatus-admin-staging";
const PREVIOUS: &str = ".renatus-admin-previous";
const MAX_ARCHIVE: usize = 20 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdminRelease {
    pub version: String,
    pub url: String,
}

/// Version written in `<addons>/<name>/<name>.toc`.
pub fn installed_version(addons: &Path, name: &str) -> Option<String> {
    let toc = fs::read_to_string(addons.join(name).join(format!("{name}.toc"))).ok()?;
    renatus_launcher_core::addon::toc_version(&toc)
}

/// Newest addon release carrying a Renatus_Admin archive.
pub fn pick(releases: &[GhRelease], include_test: bool) -> Option<AdminRelease> {
    releases.iter().find_map(|r| {
        if r.draft || (r.prerelease && !include_test) {
            return None;
        }
        let version = r.tag_name.strip_prefix('v')?;
        if !version.starts_with(|c: char| c.is_ascii_digit()) {
            return None;
        }
        let expected = format!("{ADMIN_ADDON}-{version}.zip");
        let asset = r.assets.iter().find(|a| a.name == expected)?;
        Some(AdminRelease {
            version: version.to_string(),
            url: asset.browser_download_url.clone(),
        })
    })
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .user_agent("renatus-admin")
        .timeout(Duration::from_secs(120))
        .build()
}

pub fn latest(include_test: bool) -> Result<Option<AdminRelease>, String> {
    let releases: Vec<GhRelease> = agent()
        .get(RELEASES_API)
        .set("Accept", "application/vnd.github+json")
        .call()
        .map_err(|e| format!("GitHub injoignable : {e}"))?
        .into_json()
        .map_err(|e| format!("Réponse GitHub illisible : {e}"))?;
    Ok(pick(&releases, include_test))
}

pub fn download(release: &AdminRelease) -> Result<Vec<u8>, String> {
    let resp = agent()
        .get(&release.url)
        .call()
        .map_err(|e| format!("Téléchargement impossible : {e}"))?;
    let mut bytes = Vec::new();
    io::Read::read_to_end(
        &mut io::Read::take(resp.into_reader(), MAX_ARCHIVE as u64 + 1),
        &mut bytes,
    )
    .map_err(|e| format!("Téléchargement interrompu : {e}"))?;
    if bytes.len() > MAX_ARCHIVE {
        return Err("Archive trop grosse.".into());
    }
    Ok(bytes)
}

fn io_error(what: &str, e: &io::Error) -> String {
    format!("Erreur pendant {what} : {e}")
}

fn remove_dir(path: &Path) -> Result<(), String> {
    match fs::remove_dir_all(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(io_error("le nettoyage", &e)),
        _ => Ok(()),
    }
}

/// Installs a `Renatus_Admin-<v>.zip` archive into `addons`; returns the version.
pub fn install_zip(addons: &Path, archive: &[u8]) -> Result<String, String> {
    fs::create_dir_all(addons).map_err(|e| io_error("la création du dossier AddOns", &e))?;
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
        let rel = entry
            .enclosed_name()
            .ok_or_else(|| format!("Chemin refusé dans l'archive : {}", entry.name()))?;
        match rel.components().next() {
            Some(Component::Normal(top)) if top == ADMIN_ADDON => {}
            _ => {
                return Err(format!(
                    "Fichier inattendu dans l'archive : {}",
                    entry.name()
                ))
            }
        }
        let dest = staging.join(&rel);
        if entry.is_dir() {
            fs::create_dir_all(&dest).map_err(|e| io_error("l'extraction", &e))?;
            continue;
        }
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| io_error("l'extraction", &e))?;
        }
        let mut out = fs::File::create(&dest).map_err(|e| io_error("l'extraction", &e))?;
        io::copy(&mut entry, &mut out).map_err(|e| io_error("l'extraction", &e))?;
    }
    Ok(())
}

fn swap_in(addons: &Path, staging: &Path, previous: &Path) -> Result<String, String> {
    let version = installed_version(staging, ADMIN_ADDON).ok_or_else(|| {
        format!("L'archive ne contient pas {ADMIN_ADDON}/{ADMIN_ADDON}.toc avec une version.")
    })?;
    let new_addon = staging.join(ADMIN_ADDON);
    let target = addons.join(ADMIN_ADDON);
    if target.exists() {
        fs::rename(&target, previous).map_err(|e| io_error("le remplacement de l'addon", &e))?;
    }
    if let Err(e) = fs::rename(&new_addon, &target) {
        if previous.exists() {
            let _ = fs::rename(previous, &target);
        }
        return Err(io_error("le remplacement de l'addon", &e));
    }
    let kept = previous.join(PRESS_DATA);
    if kept.is_file() {
        fs::copy(&kept, target.join(PRESS_DATA))
            .map_err(|e| io_error("la conservation de Press.lua", &e))?;
    }
    let _ = remove_dir(previous);
    Ok(version)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    fn zip_of(files: &[(&str, &str)]) -> Vec<u8> {
        let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (name, content) in files {
            if name.ends_with('/') {
                zip.add_directory(*name, SimpleFileOptions::default())
                    .unwrap();
            } else {
                zip.start_file(*name, SimpleFileOptions::default()).unwrap();
                zip.write_all(content.as_bytes()).unwrap();
            }
        }
        zip.finish().unwrap().into_inner()
    }

    #[test]
    fn install_mirrors_the_addon_and_keeps_press_data() {
        let dir = tempfile::tempdir().unwrap();
        let addons = dir.path();
        fs::create_dir_all(addons.join("Renatus_Admin")).unwrap();
        fs::write(addons.join("Renatus_Admin/Old.lua"), "--").unwrap();
        fs::write(addons.join("Renatus_Admin/Press.lua"), "mine").unwrap();
        let archive = zip_of(&[
            ("Renatus_Admin/", ""),
            (
                "Renatus_Admin/Renatus_Admin.toc",
                "## Version: 0.12.0\nPanel.lua\n",
            ),
            ("Renatus_Admin/Panel.lua", "-- new"),
            ("Renatus_Admin/Press.lua", "RenatusPress = {}"),
        ]);
        assert_eq!(install_zip(addons, &archive).unwrap(), "0.12.0");
        assert!(!addons.join("Renatus_Admin/Old.lua").exists());
        assert_eq!(
            fs::read_to_string(addons.join("Renatus_Admin/Press.lua")).unwrap(),
            "mine"
        );
        assert_eq!(
            installed_version(addons, "Renatus_Admin").as_deref(),
            Some("0.12.0")
        );
        assert!(!addons.join(PREVIOUS).exists() && !addons.join(STAGING).exists());
    }

    #[test]
    fn foreign_files_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let archive = zip_of(&[("Renatus/Renatus.toc", "## Version: 1")]);
        assert!(install_zip(dir.path(), &archive)
            .unwrap_err()
            .contains("inattendu"));
    }

    #[test]
    fn picks_the_newest_release_with_an_admin_archive() {
        let releases: Vec<GhRelease> = serde_json::from_str(
            r#"[
              {"tag_name":"launcher-v0.1.0","assets":[]},
              {"tag_name":"v0.13.0-test.1","prerelease":true,"assets":[{"name":"Renatus_Admin-0.13.0-test.1.zip","browser_download_url":"t"}]},
              {"tag_name":"v0.12.0","assets":[{"name":"Renatus-0.12.0.zip","browser_download_url":"m"},{"name":"Renatus_Admin-0.12.0.zip","browser_download_url":"a"}]},
              {"tag_name":"v0.11.0","assets":[{"name":"Renatus-0.11.0.zip","browser_download_url":"old"}]}
            ]"#,
        )
        .unwrap();
        assert_eq!(
            pick(&releases, false),
            Some(AdminRelease {
                version: "0.12.0".into(),
                url: "a".into()
            })
        );
        assert_eq!(pick(&releases, true).unwrap().version, "0.13.0-test.1");
    }
}
