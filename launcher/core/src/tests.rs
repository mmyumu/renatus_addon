use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use crate::addon::{install_zip, installed_version, toc_version};
use crate::config::Config;
use crate::release::{pick, GhAsset, GhRelease};
use crate::wow::{addons_dir, candidates, detect, resolve_flavor_dir};

fn zip_of(files: &[(&str, &str)]) -> Vec<u8> {
    let mut zip = ZipWriter::new(std::io::Cursor::new(Vec::new()));
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

fn release_zip(version: &str) -> Vec<u8> {
    let toc = format!("## Interface: 16001\n## Version: {version}\nCore\\Init.lua\n");
    zip_of(&[
        ("Renatus/", ""),
        ("Renatus/Renatus.toc", &toc),
        ("Renatus/Core/Init.lua", "-- new"),
    ])
}

/// Archive layout up to 0.11: the press data addon shipped next to Renatus.
fn legacy_release_zip(version: &str) -> Vec<u8> {
    let toc = format!("## Interface: 16001\n## Version: {version}\nCore\\Init.lua\n");
    zip_of(&[
        ("Renatus/", ""),
        ("Renatus/Renatus.toc", &toc),
        ("Renatus/Core/Init.lua", "-- old"),
        ("Renatus_Press/", ""),
        ("Renatus_Press/Renatus_Press.toc", "## Version: 1"),
        ("Renatus_Press/Press.lua", "RenatusPress = {} -- empty"),
    ])
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap()
}

#[test]
fn toc_version_reads_the_version_line() {
    assert_eq!(
        toc_version("## Title: X\n## Version: 0.11.0\r\n"),
        Some("0.11.0".into())
    );
    assert_eq!(toc_version("## Title: X\n"), None);
    assert_eq!(toc_version("## Version:   \n"), None);
}

#[test]
fn fresh_install_creates_only_renatus() {
    let dir = tempfile::tempdir().unwrap();
    let addons = dir.path().join("Interface/AddOns");
    assert_eq!(
        install_zip(&addons, &release_zip("0.12.0")).unwrap(),
        "0.12.0"
    );
    assert_eq!(installed_version(&addons), Some("0.12.0".into()));
    assert!(!addons.join("Renatus_Press").exists());
    assert!(!addons.join("Renatus_Admin").exists());
    assert!(!addons.join(".renatus-staging").exists());
}

#[test]
fn update_replaces_renatus_removes_legacy_press_keeps_admin() {
    let dir = tempfile::tempdir().unwrap();
    let addons = dir.path().to_path_buf();
    fs::create_dir_all(addons.join("Renatus/Old")).unwrap();
    fs::write(addons.join("Renatus/Renatus.toc"), "## Version: 0.11.0").unwrap();
    fs::write(addons.join("Renatus/Old/Removed.lua"), "--").unwrap();
    fs::create_dir_all(addons.join("Renatus_Press")).unwrap();
    fs::write(
        addons.join("Renatus_Press/Press.lua"),
        "written by the companion",
    )
    .unwrap();
    fs::create_dir_all(addons.join("Renatus_Admin")).unwrap();
    fs::write(addons.join("Renatus_Admin/Press.lua"), "officer data").unwrap();
    fs::create_dir_all(addons.join("OtherAddon")).unwrap();

    assert_eq!(
        install_zip(&addons, &release_zip("0.12.0")).unwrap(),
        "0.12.0"
    );
    assert!(
        !addons.join("Renatus/Old").exists(),
        "Renatus is mirrored, stale files go"
    );
    assert_eq!(read(&addons.join("Renatus/Core/Init.lua")), "-- new");
    assert!(
        !addons.join("Renatus_Press").exists(),
        "obsolete data addon removed"
    );
    assert_eq!(
        read(&addons.join("Renatus_Admin/Press.lua")),
        "officer data",
        "the officers' addon is never touched"
    );
    assert!(addons.join("OtherAddon").is_dir());
    assert!(!addons.join(".renatus-previous").exists());
}

#[test]
fn bad_archives_leave_the_installed_addon_alone() {
    let dir = tempfile::tempdir().unwrap();
    let addons = dir.path().to_path_buf();
    fs::create_dir_all(addons.join("Renatus")).unwrap();
    fs::write(addons.join("Renatus/Renatus.toc"), "## Version: 0.11.0").unwrap();

    let no_toc = zip_of(&[("Renatus/Core/Init.lua", "--")]);
    let outside = zip_of(&[
        ("Renatus/Renatus.toc", "## Version: 1"),
        ("../evil.lua", "--"),
    ]);
    let other = zip_of(&[
        ("Renatus/Renatus.toc", "## Version: 1"),
        ("Other/x.lua", "--"),
    ]);
    for archive in [no_toc, outside, other, b"not a zip".to_vec()] {
        assert!(install_zip(&addons, &archive).is_err());
        assert_eq!(installed_version(&addons), Some("0.11.0".into()));
        assert!(!addons.join(".renatus-staging").exists());
    }
    assert!(!dir.path().join("evil.lua").exists());
}

fn gh(tag: &str, prerelease: bool, asset: Option<&str>) -> GhRelease {
    GhRelease {
        tag_name: tag.into(),
        body: Some(format!("  notes {tag} \n")),
        draft: false,
        prerelease,
        html_url: format!("https://example/{tag}"),
        assets: asset
            .map(|name| GhAsset {
                name: name.into(),
                browser_download_url: format!("https://example/{name}"),
                size: 42,
            })
            .into_iter()
            .collect(),
    }
}

#[test]
fn pick_takes_the_newest_addon_release() {
    let releases = vec![
        gh(
            "launcher-v0.2.0",
            false,
            Some("Renatus.Launcher_0.2.0_x64-setup.exe"),
        ),
        gh("v0.13.0-test.1", true, Some("Renatus-0.13.0-test.1.zip")),
        gh("v0.12.1", false, None),
        gh("v0.12.0", false, Some("Renatus-0.12.0.zip")),
        gh("v0.11.0", false, Some("Renatus-0.11.0.zip")),
    ];
    let stable = pick(&releases, false).unwrap();
    assert_eq!(stable.version, "0.12.0");
    assert_eq!(stable.notes, "notes v0.12.0");
    assert_eq!(stable.url, "https://example/Renatus-0.12.0.zip");
    assert_eq!(pick(&releases, true).unwrap().version, "0.13.0-test.1");

    let mut drafts = releases.clone();
    drafts.iter_mut().for_each(|r| r.draft = true);
    assert_eq!(pick(&drafts, true), None);
}

#[test]
fn resolve_accepts_any_folder_around_forever() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("World of Warcraft");
    let flavor = root.join("_forever_");
    fs::create_dir_all(addons_dir(&flavor)).unwrap();
    fs::create_dir_all(root.join("_retail_")).unwrap();

    for start in [
        root.clone(),
        flavor.clone(),
        flavor.join("Interface"),
        addons_dir(&flavor),
        root.join("_retail_"),
    ] {
        assert_eq!(
            resolve_flavor_dir(&start),
            Some(flavor.clone()),
            "{start:?}"
        );
    }
    assert_eq!(resolve_flavor_dir(dir.path()), None);
}

#[test]
fn detect_uses_registry_then_usual_folders() {
    let dir = tempfile::tempdir().unwrap();
    let flavor = dir.path().join("Wow/_forever_");
    fs::create_dir_all(&flavor).unwrap();

    let list = candidates(
        &[PathBuf::from("/missing"), dir.path().join("Wow")],
        &['C', 'D'],
    );
    assert_eq!(list[2], PathBuf::from(r"C:\World of Warcraft"));
    assert!(list.contains(&PathBuf::from(r"D:\Program Files (x86)\World of Warcraft")));
    assert_eq!(detect(&list), Some(flavor));
    assert_eq!(detect(&[PathBuf::from("/missing")]), None);
}

#[test]
fn config_round_trips_and_survives_garbage() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sub/config.json");
    assert_eq!(Config::load(&path), Config::default());
    assert!(Config::default().autostart);

    let config = Config {
        wow_path: Some("C:/Wow/_forever_".into()),
        test_channel: true,
        autostart: false,
    };
    config.save(&path).unwrap();
    assert_eq!(Config::load(&path), config);

    fs::write(&path, "{ broken").unwrap();
    assert_eq!(Config::load(&path), Config::default());
    fs::write(&path, r#"{"testChannel": true}"#).unwrap();
    assert!(Config::load(&path).test_channel);
}

#[test]
fn legacy_archive_installs_renatus_and_skips_press() {
    let dir = tempfile::tempdir().unwrap();
    let addons = dir.path().to_path_buf();
    assert_eq!(
        install_zip(&addons, &legacy_release_zip("0.11.0")).unwrap(),
        "0.11.0"
    );
    assert_eq!(read(&addons.join("Renatus/Core/Init.lua")), "-- old");
    assert!(!addons.join("Renatus_Press").exists());
}
