//! Admin app settings, saved as JSON (app config folder, or --config for the CLI).

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

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

    pub fn paths(&self) -> Option<crate::paths::WowPaths> {
        self.wow_path
            .as_ref()
            .map(|p| crate::paths::WowPaths::new(p.clone(), self.account.clone()))
    }
}
