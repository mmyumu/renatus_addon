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
    /// Gazette prompt template (gazette::PROMPT unless the settings replace it).
    pub prompt: &'a str,
    /// The exact request to send instead of building it from `prompt` (edited by hand
    /// in the window's preview).
    pub request: Option<&'a str>,
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
    /// Custom gazette prompt template; empty: the built-in gazette::PROMPT (which then
    /// follows the app's updates).
    pub gazette_prompt: String,
    /// After each /reload: combat-log deaths, then the armory once a day.
    pub auto: bool,
    /// Last armory refresh (Unix seconds).
    pub last_armory: Option<i64>,
    /// Also install test versions of Renatus_Admin.
    pub test_channel: bool,
    /// Discord webhook the gazette is posted to (empty: none). A secret: whoever has it
    /// can post under the gazette's name, so it is never printed.
    pub discord_webhook: String,
    /// Post by itself to Discord each issue published in game (and update it when an
    /// article is corrected or withdrawn).
    pub discord_auto: bool,
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
            gazette_prompt: String::new(),
            auto: true,
            last_armory: None,
            test_channel: false,
            discord_webhook: String::new(),
            discord_auto: true,
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
            prompt: self.gazette_prompt(),
            request: None,
        }
    }

    /// The gazette prompt template in use. A custom one without `{facts}` (edited by hand
    /// in the file) falls back to the built-in one.
    pub fn gazette_prompt(&self) -> &str {
        if self.gazette_prompt.trim().is_empty()
            || crate::gazette::check_template(&self.gazette_prompt).is_err()
        {
            crate::gazette::PROMPT
        } else {
            &self.gazette_prompt
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

    #[test]
    fn custom_gazette_prompt_needs_the_facts() {
        let mut c = Config::default();
        assert_eq!(c.gazette_options().prompt, crate::gazette::PROMPT);
        c.gazette_prompt = "Numéro spécial Noël.\n{facts}".into();
        assert_eq!(c.gazette_options().prompt, c.gazette_prompt);
        c.gazette_prompt = "Sans les faits".into();
        assert_eq!(c.gazette_options().prompt, crate::gazette::PROMPT);
    }
}
