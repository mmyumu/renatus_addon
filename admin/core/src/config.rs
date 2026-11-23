//! Admin app settings, saved as JSON (app config folder, or --config for the CLI).

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Bounds of `max_articles`: below 2 there is no edition, above 10 the AI's answer gets
/// long enough to hit the timeout.
pub const ARTICLES_RANGE: (usize, usize) = (2, 10);

/// Settings used to write an edition (articles, layout, album cards).
#[derive(Debug, Clone)]
pub struct GazetteOptions<'a> {
    pub command: &'a [String],
    pub timeout: std::time::Duration,
    pub template: &'a str,
    pub max_articles: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Config {
    /// The `_forever_` folder.
    pub wow_path: Option<PathBuf>,
    /// Account folder under WTF/Account (None: the only one with Renatus data).
    pub account: Option<String>,
    /// Rival guild: armory link or guild name (EU PvP realm).
    pub rival: String,
    /// Folder of hand-written .md articles.
    pub articles_dir: Option<PathBuf>,
    /// Command reading the prompt on stdin and printing the answer.
    pub llm_command: Vec<String>,
    pub llm_timeout_secs: u64,
    /// Write the week's AI gazette by itself (once per week).
    pub auto_gazette: bool,
    /// Gazette layout: a name from edition::TEMPLATES, or "auto" (the AI chooses).
    pub gazette_template: String,
    /// Most articles the AI may write for one edition (bounded: see `gazette_options`).
    pub max_articles: usize,
    /// After each /reload: combat-log deaths, then the armory once a day.
    pub auto: bool,
    /// Last armory refresh (Unix seconds).
    pub last_armory: Option<i64>,
    /// Also install test versions of Renatus_Admin.
    pub test_channel: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            wow_path: None,
            account: None,
            rival: String::new(),
            articles_dir: None,
            llm_command: crate::llm::default_command(),
            llm_timeout_secs: 600,
            auto_gazette: false,
            gazette_template: "auto".into(),
            max_articles: crate::gazette::MAX_ARTICLES,
            auto: true,
            last_armory: None,
            test_channel: false,
        }
    }
}

impl Config {
    /// Missing or unreadable file: defaults (the app must always start).
    pub fn load(path: &Path) -> Self {
        fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    /// Writes through a temporary file so a crash never leaves a truncated file.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let tmp = path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        fs::write(&tmp, text).map_err(|e| e.to_string())?;
        fs::rename(&tmp, path).map_err(|e| e.to_string())
    }

    /// What writing an edition needs from the settings, with the limits kept in bounds
    /// (the file can be edited by hand).
    pub fn gazette_options(&self) -> GazetteOptions<'_> {
        GazetteOptions {
            command: &self.llm_command,
            timeout: std::time::Duration::from_secs(self.llm_timeout_secs),
            template: &self.gazette_template,
            max_articles: self.max_articles.clamp(ARTICLES_RANGE.0, ARTICLES_RANGE.1),
        }
    }

    pub fn paths(&self) -> Option<crate::paths::WowPaths> {
        self.wow_path
            .as_ref()
            .map(|p| crate::paths::WowPaths::new(p.clone(), self.account.clone()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gazette_limits_stay_in_bounds() {
        let mut c = Config::default();
        assert_eq!(
            c.gazette_options().max_articles,
            crate::gazette::MAX_ARTICLES
        );
        c.max_articles = 0;
        assert_eq!(c.gazette_options().max_articles, ARTICLES_RANGE.0);
        c.max_articles = 99;
        assert_eq!(c.gazette_options().max_articles, ARTICLES_RANGE.1);
        // An older settings file without the new field keeps the default.
        let old: Config = serde_json::from_str(r#"{"rival": "X"}"#).unwrap();
        assert_eq!(old.max_articles, crate::gazette::MAX_ARTICLES);
    }
}
