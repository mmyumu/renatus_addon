//! Choosing the addon release to install from the GitHub releases list.
//!
//! The repository holds two kinds of releases: the addon (`v0.12.0`, asset
//! `Renatus-0.12.0.zip`) and the launcher itself (`launcher-v0.1.0`). Only
//! the first kind is considered here.

use serde::Deserialize;

/// Subset of a GitHub release (`GET /repos/{owner}/{repo}/releases`).
#[derive(Debug, Clone, Deserialize)]
pub struct GhRelease {
    pub tag_name: String,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub draft: bool,
    #[serde(default)]
    pub prerelease: bool,
    #[serde(default)]
    pub html_url: String,
    #[serde(default)]
    pub assets: Vec<GhAsset>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GhAsset {
    pub name: String,
    pub browser_download_url: String,
    #[serde(default)]
    pub size: u64,
}

/// The addon release the launcher should have installed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AddonRelease {
    pub version: String,
    pub notes: String,
    pub url: String,
    pub size: u64,
    pub page: String,
}

/// Picks the most recent addon release (GitHub lists newest first).
/// Test versions (`v0.12.0-test.1`, published as prereleases) are only
/// taken when `include_test` is set.
///
/// The newest release wins even if its number is lower: deleting a broken
/// release on GitHub is enough to roll everybody back.
pub fn pick(releases: &[GhRelease], include_test: bool) -> Option<AddonRelease> {
    releases.iter().find_map(|r| {
        if r.draft || (r.prerelease && !include_test) {
            return None;
        }
        let version = r.tag_name.strip_prefix('v')?;
        if !version.starts_with(|c: char| c.is_ascii_digit()) {
            return None;
        }
        let expected = format!("Renatus-{version}.zip");
        let asset = r.assets.iter().find(|a| a.name == expected)?;
        Some(AddonRelease {
            version: version.to_string(),
            notes: r.body.clone().unwrap_or_default().trim().to_string(),
            url: asset.browser_download_url.clone(),
            size: asset.size,
            page: r.html_url.clone(),
        })
    })
}
