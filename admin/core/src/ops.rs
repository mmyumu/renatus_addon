//! What the admin app does, shared by the command line and the window.
//! Every operation that proposes something returns Press.lua items; `publish`
//! merges them into Renatus_Admin/Press.lua. Nothing reaches the guild until an
//! officer clicks "Publier" in game.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{json, Value};

use crate::chronicle::{num_of, payload, str_of, Chronicle};
use crate::config::GazetteOptions;
use crate::paths::{WowPaths, ADMIN_ADDON};
use crate::{
    armory, articles, cards, combatlog, edition, gazette, issues, llm, press, revise, special,
};

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
    /// The pending items themselves (Press.lua minus what was handled in game).
    pub pending_items: Vec<Value>,
    pub renatus_version: Option<String>,
    pub admin_version: Option<String>,
    pub configured_rival: Option<String>,
    pub wanted: Vec<String>,
    /// "Suivi" tab: members, sync health, recent events.
    pub monitor: Option<crate::monitor::Monitor>,
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
        pending_items: Vec::new(),
        renatus_version: crate::addon::installed_version(&addons, "Renatus"),
        admin_version: crate::addon::installed_version(&addons, ADMIN_ADDON),
        configured_rival: None,
        wanted: Vec::new(),
        monitor: None,
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
            st.pending_items = press::merge(
                press::read_items(&paths.press()),
                Vec::new(),
                &ch.press_done,
            );
            st.pending = st.pending_items.len();
            st.configured_rival = ch.configured_rival();
            st.wanted = ch.wanted().into_values().collect();
            st.monitor = Some(crate::monitor::build(
                &ch,
                now(),
                st.renatus_version.as_deref(),
            ));
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

/// The facts offered for a special issue (see special.rs).
pub fn prepare_special(
    paths: &WowPaths,
    ch: &Chronicle,
    theme: &special::Special,
    since: f64,
    until: f64,
) -> Result<issues::Selection, String> {
    special::prepare(ch, &pending(paths, ch), theme, since, until, now() as f64)
}

/// Is a new issue due (automatic mode)? None waiting in Press.lua, and the latest one
/// covers up to a week ago or more.
pub fn issue_due(paths: &WowPaths, ch: &Chronicle) -> bool {
    let waiting = pending(paths, ch);
    if waiting
        .iter()
        .any(|i| str_of(i, "kind") == Some("EDITION") && !issues::in_special(i))
    {
        return false;
    }
    issues::last_issue_end(ch, &waiting)
        .is_none_or(|t| now() as f64 - t >= issues::ISSUE_EVERY_DAYS * 86400.0)
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
/// issue's page layout. `opts.template`: a name from edition::TEMPLATES, or "auto" for the
/// AI's choice (checked, with a fallback).
pub fn gazette(
    ch: &Chronicle,
    sel: &issues::Selection,
    keys: &[String],
    articles_dir: Option<&Path>,
    opts: &GazetteOptions,
) -> Proposal {
    let (command, timeout, template) = (opts.command, opts.timeout, opts.template);
    let edition = &sel.edition;
    let b = sel.brief_for(keys);
    let mut out = Proposal {
        items: Vec::new(),
        notes: brief_summary(&b, ch.members().len()),
        answer: None,
    };
    out.notes.insert(
        0,
        match &sel.special {
            Some(s) => format!("Hors-série « {} » ({edition})", s.title),
            None => format!("Gazette {edition}"),
        },
    );
    if opts.request.is_some() {
        out.notes
            .insert(1, "Demande relue et envoyée telle quelle.".into());
    } else if opts.prompt != gazette::PROMPT {
        out.notes
            .insert(1, "Prompt personnalisé (Réglages).".into());
    }
    let mut items = Vec::new();
    let mut wanted = (template != "auto").then(|| template.to_string());
    if !b.facts.is_empty() {
        let request = match opts.request {
            Some(text) => text.to_string(),
            None => gazette::prompt_in(opts.prompt, &b, opts.max_articles),
        };
        match llm::run(&request, command, timeout) {
            Err(e) => out.notes.push(format!("IA indisponible : {e}")),
            Ok(answer) => {
                let (ai, notes) = gazette::check(&b, &answer, edition, opts.max_articles);
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
    // Hand-written articles wait for the next regular issue.
    if let Some(dir) = articles_dir.filter(|_| sel.special.is_none()) {
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
    if let Some(s) = &sel.special {
        // The addon numbers special issues apart and shows their title and period.
        layout["p"]["special"] = json!(s.title);
        layout["p"]["since"] = json!(sel.since);
    }
    out.notes.push(format!(
        "Mise en page : {}.",
        str_of(&layout["p"], "template").unwrap_or("?")
    ));
    out.items = items;
    out.items.push(layout);
    if sel.special.is_some() {
        // Album cards go with the regular issues.
        return out;
    }
    let (card_items, notes) = album_cards(ch, &sel.pending_cards, edition, opts);
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
    opts: &GazetteOptions,
) -> (Vec<Value>, Vec<String>) {
    let (mut items, mut notes) = new_cards(ch, pending, edition, opts);
    let rerated = revise::rerate_items(ch, pending, edition);
    let count: usize = rerated
        .iter()
        .map(|i| i["p"]["cards"].as_array().map_or(0, Vec::len))
        .sum();
    if count > 0 {
        notes.push(format!(
            "{count} carte(s) déjà publiée(s) changent de rareté (règles de l'album)."
        ));
    }
    items.extend(rerated);
    (items, notes)
}

/// The rarity corrections of the published cards alone (revise::rerate_items), without
/// waiting for the next issue.
pub fn rerate(paths: &WowPaths, ch: &Chronicle) -> Proposal {
    let items = revise::rerate_items(ch, &pending(paths, ch), &now().to_string());
    let count: usize = items
        .iter()
        .map(|i| i["p"]["cards"].as_array().map_or(0, Vec::len))
        .sum();
    let notes = vec![if count > 0 {
        format!("{count} carte(s) déjà publiée(s) changent de rareté (règles de l'album).")
    } else {
        "Toutes les cartes publiées suivent déjà les règles de rareté.".into()
    }];
    Proposal {
        items,
        notes,
        answer: None,
    }
}

/// The new cards of an issue (album_cards).
fn new_cards(
    ch: &Chronicle,
    pending: &[Value],
    edition: &str,
    opts: &GazetteOptions,
) -> (Vec<Value>, Vec<String>) {
    let (command, timeout) = (opts.command, opts.timeout);
    let (done, last) = cards::published(ch, pending);
    let mut list = cards::candidates(ch, &done);
    let mut taken = cards::taken_names(ch, pending);
    if list.is_empty() {
        return (
            Vec::new(),
            vec!["Aucune nouvelle carte pour l'album.".into()],
        );
    }
    let mut notes = Vec::new();
    // Every card the AI may write goes to it, in batches; one it did not write waits for
    // the next issue rather than being published with a plain text.
    let todo: Vec<cards::Candidate> = list.iter().filter(|c| c.ai).cloned().collect();
    let mut written = std::collections::HashSet::new();
    for batch in todo.chunks(cards::BATCH) {
        match llm::run(&cards::prompt(batch, &taken), command, timeout) {
            Ok(answer) => {
                let (done, problems) = cards::apply(&mut list, &answer, &mut taken);
                written.extend(done);
                notes.extend(problems);
            }
            Err(e) => {
                notes.push(format!("Cartes : IA indisponible ({e})."));
                break;
            }
        }
    }
    if !todo.is_empty() {
        notes.push(format!("{} carte(s) rédigée(s) par l'IA.", written.len()));
    }
    let plain = list.iter().filter(|c| !c.ai).count();
    if plain > 0 {
        notes.push(format!(
            "{plain} carte(s) en texte simple (membres qui refusent la gazette IA)."
        ));
    }
    let postponed = todo.len() - written.len();
    if postponed > 0 {
        notes.push(format!(
            "{postponed} carte(s) pas rédigée(s) par l'IA : reportée(s) à la prochaine édition."
        ));
    }
    list.retain(|c| !c.ai || written.contains(&c.id));
    if list.is_empty() {
        return (Vec::new(), notes);
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

/// Removes pending items (`items`: their ids) and single album cards (`cards`: card ids,
/// taken out of their CARD_SET) from Press.lua; returns the pending count.
pub fn remove_pending(
    paths: &WowPaths,
    ch: &Chronicle,
    items: &[String],
    cards: &[String],
) -> Result<usize, String> {
    let file = paths.press();
    let kept = press::merge(press::read_items(&file), Vec::new(), &ch.press_done);
    let kept = press::remove(kept, items, cards);
    press::write(&file, &kept, now())?;
    Ok(kept.len())
}

/// The published catalogue and issues, as members see them, for the editor (revise.rs).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Published {
    pub cards: Vec<revise::PublishedCard>,
    pub issues: Vec<revise::Issue>,
}

pub fn published(paths: &WowPaths, ch: &Chronicle) -> Published {
    let pending = pending(paths, ch);
    Published {
        cards: revise::catalogue(ch, &pending),
        issues: revise::archive(ch, &pending),
    }
}

/// Puts a correction (revise.rs) in Press.lua, in place of an older correction of the same
/// card or article still pending; returns the pending count.
pub fn propose_fix(paths: &WowPaths, ch: &Chronicle, item: Value) -> Result<usize, String> {
    let id = str_of(&item, "id").ok_or("Correction sans id.")?;
    let prefix = match id.rsplit_once(':') {
        Some((head, _)) => format!("{head}:"),
        None => return Err("Correction sans id.".into()),
    };
    let file = paths.press();
    let mut kept = press::merge(press::read_items(&file), Vec::new(), &ch.press_done);
    kept.retain(|i| str_of(i, "id").is_none_or(|x| !x.starts_with(&prefix)));
    kept.push(item);
    press::write(&file, &kept, now())?;
    Ok(kept.len())
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
    use crate::config::Config;
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
            &Config::default().gazette_options(),
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
