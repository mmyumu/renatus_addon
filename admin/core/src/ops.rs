//! What the admin app does, shared by the command line and the window.
//! Every operation that proposes something returns Press.lua items; `publish`
//! merges them into Renatus_Admin/Press.lua. Nothing reaches the guild until an
//! officer clicks "Publier" in game.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};

use crate::chronicle::{num_of, payload, str_of, Chronicle};
use crate::paths::{WowPaths, ADMIN_ADDON};
use crate::{armory, articles, cards, combatlog, edition, gazette, issues, llm, press};

pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

/// Items + messages for the user.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Proposal {
    pub items: Vec<Value>,
    pub notes: Vec<String>,
    /// The AI's raw answer (gazette only), so the editor can read what came back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answer: Option<String>,
}

impl Proposal {
    pub fn extend(&mut self, other: Proposal) {
        self.items.extend(other.items);
        self.notes.extend(other.notes);
        if other.answer.is_some() {
            self.answer = other.answer;
        }
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
        answer: None,
    }
}

/// Items waiting in Press.lua (not yet handled in game).
pub fn pending(paths: &WowPaths, ch: &Chronicle) -> Vec<Value> {
    press::read_items(&paths.press())
        .into_iter()
        .filter(|i| str_of(i, "id").is_none_or(|id| !ch.press_done.contains_key(id)))
        .collect()
}

/// The facts offered for the next gazette issue (see issues.rs).
pub fn prepare(paths: &WowPaths, ch: &Chronicle) -> issues::Selection {
    issues::prepare(ch, &pending(paths, ch), now() as f64)
}

/// Is a new issue due (automatic mode)? None waiting in Press.lua, and the latest one
/// covers up to a week ago or more.
pub fn issue_due(paths: &WowPaths, ch: &Chronicle) -> bool {
    let waiting = pending(paths, ch);
    if waiting.iter().any(|i| str_of(i, "kind") == Some("EDITION")) {
        return false;
    }
    issues::last_issue_end(ch, &waiting)
        .is_none_or(|t| now() as f64 - t >= issues::FIRST_DAYS * 86400.0)
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

/// Hand-written articles (.md) not handled yet, for the issue being written.
fn hand_written(dir: &Path, ch: &Chronicle) -> (Vec<Value>, Vec<String>) {
    let public: BTreeSet<String> = ch
        .events
        .iter()
        .filter(|(_, e)| str_of(e, "vis") == Some("G"))
        .map(|(id, _)| id.clone())
        .collect();
    let (found, mut notes) = articles::load_dir(dir, &public);
    let items: Vec<Value> = found
        .iter()
        .map(articles::Article::to_item)
        .filter(|i| str_of(i, "id").is_none_or(|id| !ch.press_done.contains_key(id)))
        .collect();
    notes.push(format!(
        "{} article(s) écrit(s) à la main ajouté(s) au numéro ({}).",
        items.len(),
        dir.display()
    ));
    (items, notes)
}

/// Writes a gazette issue (blocking: one or two minutes with the AI): the AI's articles
/// from the facts `keys` of `sel`, the hand-written articles of `articles_dir`, then the
/// issue's page layout. `template`: a name from edition::TEMPLATES, or "auto" for the
/// AI's choice (checked, with a fallback).
#[allow(clippy::too_many_arguments)]
pub fn gazette(
    ch: &Chronicle,
    sel: &issues::Selection,
    keys: &[String],
    articles_dir: Option<&Path>,
    command: &[String],
    timeout: Duration,
    template: &str,
) -> Proposal {
    let edition = &sel.edition;
    let b = sel.brief_for(keys);
    let mut out = Proposal {
        items: Vec::new(),
        notes: brief_summary(&b, ch.members().len()),
        answer: None,
    };
    out.notes.insert(0, format!("Gazette {edition}"));
    let mut items = Vec::new();
    let mut wanted = (template != "auto").then(|| template.to_string());
    if !b.facts.is_empty() {
        match llm::run(&gazette::prompt(&b), command, timeout) {
            Err(e) => out.notes.push(format!("IA indisponible : {e}")),
            Ok(answer) => {
                let (ai, notes) = gazette::check(&b, &answer, edition);
                out.notes.extend(notes);
                out.notes
                    .push(format!("{} article(s) de l'IA retenu(s).", ai.len()));
                if wanted.is_none() {
                    wanted = gazette::requested_template(&answer);
                }
                out.answer = Some(answer);
                items.extend(ai);
            }
        }
    }
    if let Some(dir) = articles_dir {
        let (mut mine, notes) = hand_written(dir, ch);
        out.notes.extend(notes);
        for a in &mut mine {
            a["p"]["edition"] = json!(edition);
            a["p"]["order"] = json!(items.len() + 1);
            items.push(a.clone());
        }
    }
    if items.is_empty() {
        out.notes.push("Aucun article : pas de numéro.".into());
        return out;
    }
    let mut layout = edition::item(
        edition::choose(wanted.as_deref(), &items, edition),
        &items,
        edition,
    );
    layout["p"]["till"] = json!(sel.until);
    out.notes.push(format!(
        "Mise en page : {}.",
        str_of(&layout["p"], "template").unwrap_or("?")
    ));
    out.items = items;
    out.items.push(layout);
    let (card_items, notes) = album_cards(ch, &sel.pending_cards, edition, command, timeout);
    out.notes.extend(notes);
    out.items.extend(card_items);
    out
}

/// The album cards published with an issue: chosen by rules, written by the AI when the
/// members involved agreed to it (cards.rs).
pub fn album_cards(
    ch: &Chronicle,
    pending: &[Value],
    edition: &str,
    command: &[String],
    timeout: Duration,
) -> (Vec<Value>, Vec<String>) {
    let (done, last) = cards::published(ch, pending);
    let mut list = cards::candidates(ch, &done);
    if list.is_empty() {
        return (
            Vec::new(),
            vec!["Aucune nouvelle carte pour l'album.".into()],
        );
    }
    let mut notes = Vec::new();
    if list.iter().any(|c| c.ai) {
        match llm::run(&cards::prompt(&list), command, timeout) {
            Ok(answer) => notes.extend(cards::apply(&mut list, &answer)),
            Err(e) => notes.push(format!("Cartes : IA indisponible ({e}), textes simples.")),
        }
    }
    let items = cards::items(&list, edition, last);
    notes.push(format!(
        "{} carte(s) pour l'album, n° {} à {}.",
        list.len(),
        last + 1,
        last + list.len() as i64
    ));
    (items, notes)
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
    let item = armory::roster_item(&g, &guild, &profiles, now);
    let published = ch.latest_roster(&guild.name);
    if published.is_some_and(|ev| armory::same_roster(payload(ev), &item["p"])) {
        out.notes.push(format!(
            "{} : {} membre(s), effectif inchangé depuis le dernier publié : rien à proposer.",
            guild.name,
            guild.members.len()
        ));
    } else {
        out.items.push(item);
        out.notes.push(format!(
            "{} : {} membre(s) ; {} fiche(s) détaillée(s) (ennemis déjà connus).",
            guild.name,
            guild.members.len(),
            profiles.len()
        ));
    }
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
        assert!(issue_due(&paths, &ch), "no issue yet");

        // An issue with only hand-written articles (no fact ticked: the AI is not called).
        let md = dir.path().join("articles");
        fs::create_dir_all(&md).unwrap();
        fs::write(
            md.join("edito.md"),
            "---\ntitle: Édito\nformat: Éditorial\nstyle: Rédaction\n---\nBonjour.\n",
        )
        .unwrap();
        let sel = prepare(&paths, &ch);
        let p = gazette(
            &ch,
            &sel,
            &[],
            Some(&md),
            &[],
            Duration::from_secs(1),
            "auto",
        );
        assert_eq!(p.items.len(), 3, "{:?}", p.notes);
        assert_eq!(
            p.items[2]["kind"], "CARD_SET",
            "the member's cards come with the issue"
        );
        assert_eq!(p.items[2]["p"]["set"], sel.edition.as_str());
        assert_eq!(p.items[2]["p"]["cards"][0]["no"], 1);
        assert_eq!(p.items[0]["p"]["edition"], sel.edition.as_str());
        assert_eq!(p.items[0]["p"]["order"], 1);
        assert_eq!(p.items[1]["kind"], "EDITION");
        assert_eq!(p.items[1]["p"]["till"], sel.until);
        publish(&paths, &ch, p.items).unwrap();
        assert!(!issue_due(&paths, &ch), "an issue is waiting in Press.lua");
    }
}
