//! Launcher settings, saved as JSON in the user's app config folder.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Config {
    /// The `_forever_` folder.
    pub wow_path: Option<PathBuf>,
    /// Also install test versions (GitHub prereleases).
    pub test_channel: bool,
    /// Start with Windows. Re-applied at each start, so it survives updates.
    pub autostart: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            wow_path: None,
            test_channel: false,
            autostart: true,
        }
    }
}

impl Config {
    /// Missing or unreadable file: defaults (the launcher must always start).
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
}
