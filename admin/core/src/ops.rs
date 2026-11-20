//! What the admin app does, shared by the command line and the window.
//! Every operation that proposes something returns Press.lua items; `publish`
//! merges them into Renatus_Admin/Press.lua. Nothing reaches the guild until an
//! officer clicks "Publier" in game.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;

use crate::chronicle::{num_of, str_of, Chronicle};
use crate::paths::{WowPaths, ADMIN_ADDON};
use crate::{armory, articles, combatlog, gazette, llm, press};

pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

/// Items + messages for the user.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Proposal {
    pub items: Vec<Value>,
    pub notes: Vec<String>,
}

impl Proposal {
    pub fn extend(&mut self, other: Proposal) {
        self.items.extend(other.items);
        self.notes.extend(other.notes);
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub wow_path: String,
    pub saved_variables: Option<String>,
    pub saved_at: Option<i64>,
    pub error: Option<String>,
    pub events: usize,
    pub shared: usize,
    pub authors: usize,
    pub last_event: Option<i64>,
    pub combat_logs: usize,
    pub pending: usize,
    pub renatus_version: Option<String>,
    pub admin_version: Option<String>,
    pub configured_rival: Option<String>,
    pub wanted: Vec<String>,
}

pub fn load(paths: &WowPaths) -> Result<(PathBuf, Chronicle), String> {
    let sv = paths.saved_variables()?;
    let ch = Chronicle::load(&sv)?;
    Ok((sv, ch))
}

fn modified(path: &Path) -> Option<i64> {
    let t = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(chrono::DateTime::<chrono::Utc>::from(t).timestamp())
}

pub fn status(paths: &WowPaths) -> Status {
    let addons = paths.addons();
    let mut st = Status {
        wow_path: paths.root.display().to_string(),
        saved_variables: None,
        saved_at: None,
        error: None,
        events: 0,
        shared: 0,
        authors: 0,
        last_event: None,
        combat_logs: paths.combat_logs().len(),
        pending: 0,
        renatus_version: crate::addon::installed_version(&addons, "Renatus"),
        admin_version: crate::addon::installed_version(&addons, ADMIN_ADDON),
        configured_rival: None,
        wanted: Vec::new(),
    };
    match load(paths) {
        Err(e) => st.error = Some(e),
        Ok((sv, ch)) => {
            st.saved_at = modified(&sv);
            st.saved_variables = Some(sv.display().to_string());
            st.events = ch.events.len();
            st.shared = ch.all().filter(|e| str_of(e, "vis") == Some("G")).count();
            st.authors = ch.members().len();
            st.last_event = ch.all().map(|e| num_of(e, "t") as i64).max();
            st.pending = press::merge(
                press::read_items(&paths.press()),
                Vec::new(),
                &ch.press_done,
            )
            .len();
            st.configured_rival = ch.configured_rival();
            st.wanted = ch.wanted().into_values().collect();
        }
    }
    st
}

/// Combat-log deaths and PvP clashes (all logs, or one file).
pub fn deaths(paths: &WowPaths, ch: &Chronicle, only: Option<&Path>) -> Proposal {
    let logs = match only {
        Some(p) => vec![p.to_path_buf()],
        None => paths.combat_logs(),
    };
    let mut out = Proposal::default();
    if logs.is_empty() {
        out.notes
            .push("Aucun journal de combat (non utilisé : les morts viennent de l'addon).".into());
    }
    for log in logs {
        let name = log
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        match combatlog::analyse_file(&log) {
            Err(e) => out.notes.push(e),
            Ok(analysis) => {
                let (items, notes) = crate::chronicle::propose(&analysis, ch);
                out.notes.push(format!(
                    "{name} : {} mort(s) de joueur, {} coup(s) fatal(s) sur des joueurs -> {} proposition(s)",
                    analysis.deaths.len(),
                    analysis.kills.len(),
                    items.len()
                ));
                out.notes
                    .extend(notes.into_iter().map(|n| format!("  {n}")));
                out.items.extend(items);
            }
        }
    }
    out
}

pub fn articles(dir: &Path, ch: &Chronicle) -> Proposal {
    let public: BTreeSet<String> = ch
        .events
        .iter()
        .filter(|(_, e)| str_of(e, "vis") == Some("G"))
        .map(|(id, _)| id.clone())
        .collect();
    let (found, mut notes) = articles::load_dir(dir, &public);
    notes.push(format!("{} article(s) dans {}", found.len(), dir.display()));
    Proposal {
        items: found.iter().map(articles::Article::to_item).collect(),
        notes,
    }
}

pub fn brief(ch: &Chronicle, days: u32, until: i64) -> gazette::Brief {
    let until = until as f64;
    gazette::build(ch, until - f64::from(days) * 86400.0, until)
}

/// Is this week's AI edition already written (pending or handled in game)?
pub fn edition_done(paths: &WowPaths, ch: &Chronicle, edition: &str) -> bool {
    let prefix = format!("ia:{edition}:");
    ch.press_done.keys().any(|i| i.starts_with(&prefix))
        || press::read_items(&paths.press())
            .iter()
            .any(|i| str_of(i, "id").is_some_and(|id| id.starts_with(&prefix)))
}

pub fn brief_summary(b: &gazette::Brief, authors: usize) -> Vec<String> {
    let mut notes = vec![format!(
        "{} membre(s) consentant(s) sur {authors} équipé(s) de l'addon ; {} fait(s) retenu(s).",
        b.allowed.len(),
        b.facts.len()
    )];
    notes.extend(
        b.excluded
            .iter()
            .map(|(reason, n)| format!("  écarté : {n} × {reason}")),
    );
    if b.facts.is_empty() {
        notes.push(
            "Rien à raconter (ou personne n'a coché « La gazette IA peut parler de moi » en jeu)."
                .into(),
        );
    }
    notes
}

/// Writes this week's gazette with the AI (blocking: one or two minutes).
pub fn gazette(ch: &Chronicle, days: u32, command: &[String], timeout: Duration) -> Proposal {
    let until = now();
    let edition = gazette::edition_key(until as f64);
    let b = brief(ch, days, until);
    let mut out = Proposal {
        items: Vec::new(),
        notes: brief_summary(&b, ch.members().len()),
    };
    out.notes.insert(0, format!("Gazette IA {edition}"));
    if b.facts.is_empty() {
        return out;
    }
    match llm::run(&gazette::prompt(&b), command, timeout) {
        Err(e) => out.notes.push(format!("IA indisponible : {e}")),
        Ok(answer) => {
            let (items, notes) = gazette::check(&b, &answer, &edition);
            out.notes.extend(notes);
            out.notes
                .push(format!("{} article(s) proposé(s).", items.len()));
            out.items = items;
        }
    }
    out
}

/// The rival guild from the armory: GUILD_CONFIG (if it differs from the one in force)
/// and RIVAL_ROSTER with the profiles of the enemies the guild already knows.
pub fn rival(rival: &str, ch: &Chronicle) -> Result<(armory::Guild, Proposal), String> {
    let g = armory::GuildRef::parse(rival)
        .ok_or("Indique la guilde rivale (nom ou lien de l'armurerie).")?;
    let guild = armory::fetch_guild(&g)?;
    let mut out = Proposal::default();
    let now = now();
    let in_force = ch.configured_rival();
    if in_force.as_deref().map(str::to_lowercase) != Some(guild.name.to_lowercase()) {
        out.items.push(armory::guild_config_item(&guild.name, now));
        out.notes.push(format!(
            "Réglage de guilde proposé : guilde rivale = {} (actuellement : {}).",
            guild.name,
            in_force.unwrap_or_else(|| "aucune".into())
        ));
    }
    let known: Vec<String> = ch.known_enemies().into_iter().collect();
    let (profiles, notes) = armory::fetch_profiles(&g, &guild, &known);
    out.notes.extend(notes);
    out.items
        .push(armory::roster_item(&g, &guild, &profiles, now));
    out.notes.push(format!(
        "{} : {} membre(s) ; {} fiche(s) détaillée(s) (ennemis déjà connus).",
        guild.name,
        guild.members.len(),
        profiles.len()
    ));
    Ok((guild, out))
}

/// Merges `items` into Press.lua (minus what was already handled); returns the pending count.
pub fn publish(paths: &WowPaths, ch: &Chronicle, items: Vec<Value>) -> Result<usize, String> {
    let file = paths.press();
    let merged = press::merge(press::read_items(&file), items, &ch.press_done);
    press::write(&file, &merged, now())?;
    Ok(merged.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn status_and_publish_on_a_fake_install() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("_forever_");
        let sv = root.join("WTF/Account/ACC/SavedVariables");
        fs::create_dir_all(&sv).unwrap();
        fs::write(
            sv.join("Renatus.lua"),
            r#"RenatusDB = { ["events"] = { ["P-1:1"] = { ["id"] = "P-1:1", ["a"] = "P-1", ["n"] = "Testeur", ["k"] = "LEVEL_UP", ["t"] = 10, ["vis"] = "G", ["p"] = {} } }, ["pressDone"] = { ["old"] = "ignored" } }"#,
        )
        .unwrap();
        fs::create_dir_all(root.join("Interface/AddOns/Renatus")).unwrap();
        fs::write(
            root.join("Interface/AddOns/Renatus/Renatus.toc"),
            "## Version: 0.12.0",
        )
        .unwrap();
        let paths = WowPaths::new(&root, None);
        let st = status(&paths);
        assert_eq!(st.error, None);
        assert_eq!((st.events, st.shared, st.authors), (1, 1, 1));
        assert_eq!(st.renatus_version.as_deref(), Some("0.12.0"));
        assert_eq!(st.admin_version, None);

        let (_, ch) = load(&paths).unwrap();
        let items = vec![
            armory::guild_config_item("Les Crocs", 5),
            serde_json::json!({"id": "old", "kind": "ARTICLE", "p": {}}),
        ];
        assert_eq!(
            publish(&paths, &ch, items).unwrap(),
            1,
            "already handled items are dropped"
        );
        assert_eq!(status(&paths).pending, 1);
        assert!(!edition_done(&paths, &ch, "2026-S47"));
    }
}
