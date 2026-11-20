//! AI-written gazette: verified facts -> prompt -> articles proposed to the editor.
//!
//! Safeguards (docs/ARCHITECTURE.md §7, §8.4):
//!   - only the guild's SHARED events (vis G) are read;
//!   - consent: a character only appears if they ticked "La gazette IA peut parler de moi"
//!     (AI_CONSENT event, latest choice wins). Otherwise their events are not sent, and
//!     another member's fact naming them is dropped;
//!   - rivals are never named to the AI: alias "Rival A (voleur gnome)";
//!   - provenance kept: declared by hand ("selon X"), deduced ("supposé"), combat log;
//!   - the answer is checked: existing sources, no unauthorised name, bounded length.
//!     A failing article is rejected, never fixed;
//!   - nothing is published: articles go to Press.lua, the editor approves them in game.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use chrono::{Datelike, Local, TimeZone, Timelike};
use serde::Serialize;
use serde_json::{json, Value};

use crate::articles::sha1_hex;
use crate::chronicle::{num_of, payload, str_of, Chronicle};

pub const MAX_FACTS: usize = 150;
pub const MAX_BODY: usize = 3500;
pub const MAX_TITLE: usize = 90;
pub const MAX_ARTICLES: usize = 5;
/// Not facts (or already editorial content, or settings).
const HIDDEN: &[&str] = &[
    "VOTE",
    "AI_CONSENT",
    "ARTICLE",
    "LETTER",
    "GUILD_CONFIG",
    "RIVAL_ROSTER",
    "BOOSTER_OPEN",
    "TOMBSTONE",
];

fn class_fr(class: &str) -> &'static str {
    match class.to_uppercase().as_str() {
        "WARRIOR" => "guerrier",
        "PALADIN" => "paladin",
        "HUNTER" => "chasseur",
        "ROGUE" => "voleur",
        "PRIEST" => "prêtre",
        "DEATHKNIGHT" => "chevalier de la mort",
        "SHAMAN" => "chaman",
        "MAGE" => "mage",
        "WARLOCK" => "démoniste",
        "MONK" => "moine",
        "DRUID" => "druide",
        "DEMONHUNTER" => "chasseur de démons",
        "EVOKER" => "évocateur",
        _ => "",
    }
}

fn exp_type(t: &str) -> &'static str {
    match t {
        "DUNGEON" => "donjon",
        "RAID" => "raid",
        "PVP" => "champ de bataille",
        "QUESTING" => "sortie en groupe",
        _ => "expédition",
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Fact {
    pub key: String,
    pub when: f64,
    pub text: String,
    pub refs: Vec<String>,
}

/// Everything sent to the AI, plus what is needed to check the answer.
#[derive(Debug, Clone, Serialize)]
pub struct Brief {
    pub facts: Vec<Fact>,
    /// Consenting members.
    pub allowed: BTreeSet<String>,
    /// Names that must never go out (non-consenting members, rivals).
    pub forbidden: BTreeSet<String>,
    pub rival_guild: Option<String>,
    /// Exclusion reasons and counts, most frequent first.
    pub excluded: Vec<(String, usize)>,
    pub since: f64,
    pub until: f64,
}

// ---------------------------------------------------------------------------
// Whole-word, case-insensitive name matching ("Bob" but not "Bobby" nor "Bob-x")
// ---------------------------------------------------------------------------

fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_' || c == '-'
}

#[derive(Debug, Clone, Default)]
pub struct Names {
    /// Longest first, as an alternation tried in order.
    names: Vec<String>,
}

impl Names {
    pub fn new<'a>(names: impl IntoIterator<Item = &'a String>) -> Self {
        let mut names: Vec<String> = names
            .into_iter()
            .filter(|n| !n.is_empty())
            .cloned()
            .collect();
        names.sort();
        names.dedup();
        names.sort_by_key(|n| std::cmp::Reverse(n.chars().count()));
        Self { names }
    }

    /// Length in bytes of `name` at the start of `text`, compared case-insensitively.
    fn prefix_len(text: &str, name: &str) -> Option<usize> {
        let mut t = text.char_indices();
        for nc in name.chars() {
            let (_, tc) = t.next()?;
            if !tc.to_lowercase().eq(nc.to_lowercase()) {
                return None;
            }
        }
        Some(t.next().map_or(text.len(), |(i, _)| i))
    }

    /// First match: (start, end) byte offsets.
    fn find_from(&self, text: &str, from: usize) -> Option<(usize, usize)> {
        if self.names.is_empty() {
            return None;
        }
        for (i, _) in text[from..].char_indices().map(|(i, c)| (i + from, c)) {
            if text[..i].chars().next_back().is_some_and(is_word) {
                continue;
            }
            for name in &self.names {
                if let Some(len) = Self::prefix_len(&text[i..], name) {
                    if !text[i + len..].chars().next().is_some_and(is_word) {
                        return Some((i, i + len));
                    }
                }
            }
        }
        None
    }

    pub fn find<'t>(&self, text: &'t str) -> Option<&'t str> {
        self.find_from(text, 0).map(|(a, b)| &text[a..b])
    }

    pub fn replace_all(&self, text: &str, mut with: impl FnMut(&str) -> String) -> String {
        let mut out = String::new();
        let mut pos = 0;
        while let Some((a, b)) = self.find_from(text, pos) {
            out.push_str(&text[pos..a]);
            out.push_str(&with(&text[a..b]));
            pos = b;
        }
        out.push_str(&text[pos..]);
        out
    }
}

// ---------------------------------------------------------------------------

/// Author GUID -> latest published consent (highest sequence).
pub fn consent(ch: &Chronicle) -> BTreeMap<String, bool> {
    let mut best: BTreeMap<String, (i64, bool)> = BTreeMap::new();
    for e in ch.of_kind("AI_CONSENT") {
        if str_of(e, "vis") != Some("G") {
            continue;
        }
        let Some(a) = str_of(e, "a") else { continue };
        let s = num_of(e, "s") as i64;
        let ok = payload(e)
            .get("ok")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if best.get(a).is_none_or(|(bs, _)| s > *bs) {
            best.insert(a.to_string(), (s, ok));
        }
    }
    best.into_iter().map(|(a, (_, ok))| (a, ok)).collect()
}

/// Stable aliases for rival guild characters.
struct Rivals {
    info: HashMap<String, (String, String, String)>, // lower -> (name, class, race)
    guild: Option<String>,
    alias: HashMap<String, String>,
}

impl Rivals {
    fn new(ch: &Chronicle) -> Self {
        let mut info: HashMap<String, (String, String, String)> = HashMap::new();
        let mut guild = None;
        for kind in ["ENEMY_SEEN", "ENEMY_NOTE", "WANTED", "PVP_CLASH"] {
            let mut evs: Vec<&Value> = ch.of_kind(kind).collect();
            evs.sort_by(|a, b| num_of(a, "t").total_cmp(&num_of(b, "t")));
            for e in evs {
                let p = payload(e);
                let Some(name) = str_of(p, "name")
                    .or_else(|| str_of(p, "enemy"))
                    .filter(|n| !n.is_empty())
                else {
                    continue;
                };
                let d = info
                    .entry(name.to_lowercase())
                    .or_insert_with(|| (name.to_string(), String::new(), String::new()));
                if d.1.is_empty() {
                    d.1 = str_of(p, "class").unwrap_or("").to_string();
                }
                if d.2.is_empty() {
                    d.2 = str_of(p, "race").unwrap_or("").to_string();
                }
                if kind == "ENEMY_SEEN" {
                    if let Some(g) = str_of(p, "guild").filter(|g| !g.is_empty()) {
                        guild = Some(g.to_string());
                    }
                }
            }
        }
        Self {
            info,
            guild,
            alias: HashMap::new(),
        }
    }

    fn names(&self) -> BTreeSet<String> {
        self.info.values().map(|d| d.0.clone()).collect()
    }

    fn is_known(&self, name: &str) -> bool {
        self.info.contains_key(&name.to_lowercase())
    }

    fn alias(&mut self, name: Option<&str>) -> String {
        let Some(name) = name.filter(|n| !n.is_empty()) else {
            return "un rival".into();
        };
        let key = name.to_lowercase();
        if let Some(a) = self.alias.get(&key) {
            return a.clone();
        }
        let n = self.alias.len();
        let mut letter = ((b'A' + (n % 26) as u8) as char).to_string();
        if n >= 26 {
            letter.push_str(&(n / 26 + 1).to_string());
        }
        let desc = self
            .info
            .get(&key)
            .map(|(_, class, race)| {
                [class_fr(class), race.as_str()]
                    .iter()
                    .filter(|x| !x.is_empty())
                    .copied()
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .unwrap_or_default();
        let alias = if desc.is_empty() {
            format!("Rival {letter}")
        } else {
            format!("Rival {letter} ({desc})")
        };
        self.alias.insert(key, alias.clone());
        alias
    }
}

fn local(t: f64) -> chrono::DateTime<Local> {
    Local
        .timestamp_opt(t as i64, 0)
        .single()
        .unwrap_or_else(Local::now)
}

fn when(t: f64) -> String {
    const DAYS: [&str; 7] = [
        "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
    ];
    let d = local(t);
    format!(
        "{} {:02}/{:02} {:02}h{:02}",
        DAYS[d.weekday().num_days_from_monday() as usize],
        d.day(),
        d.month(),
        d.hour(),
        d.minute()
    )
}

/// ISO week of `until`: "2026-S47".
pub fn edition_key(until: f64) -> String {
    let w = local(until).iso_week();
    format!("{}-S{:02}", w.year(), w.week())
}

fn s(v: &Value, key: &str) -> String {
    match v.get(key) {
        Some(Value::String(x)) => x.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

fn names_list(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|l| {
            l.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

pub fn build(ch: &Chronicle, since: f64, until: f64) -> Brief {
    let guild = ch.main_guild();
    let choice = consent(ch);
    let authors = ch.members();
    let allowed: BTreeSet<String> = choice
        .iter()
        .filter(|(a, ok)| **ok && authors.contains_key(*a))
        .map(|(a, _)| authors[a].clone())
        .collect();
    let allowed_guids: BTreeSet<&String> = choice
        .iter()
        .filter(|(_, ok)| **ok)
        .map(|(a, _)| a)
        .collect();
    // Known members without consent: authors without a "yes" + members seen in expeditions.
    let mut members: BTreeSet<String> = authors.values().cloned().collect();
    for e in ch.of_kind("EXPEDITION") {
        for p in e.get("pt").and_then(Value::as_array).into_iter().flatten() {
            if let Some(n) = str_of(p, "n") {
                members.insert(n.to_string());
            }
        }
    }
    let mut rivals = Rivals::new(ch);
    let forbidden_members: BTreeSet<String> = members.difference(&allowed).cloned().collect();
    let rival_names = rivals.names();
    let forbidden: BTreeSet<String> = forbidden_members.union(&rival_names).cloned().collect();
    let member_re = Names::new(&forbidden_members);
    let rival_re = Names::new(&rival_names);
    let mut excluded: BTreeMap<String, usize> = BTreeMap::new();
    let mut exclude =
        |reason: &str, n: usize| *excluded.entry(reason.to_string()).or_default() += n;

    let mut events: Vec<&Value> = ch
        .all()
        .filter(|e| {
            str_of(e, "vis") == Some("G")
                && str_of(e, "g").map(str::to_string) == guild
                && (since..until).contains(&num_of(e, "t"))
                && !HIDDEN.contains(&str_of(e, "k").unwrap_or(""))
        })
        .collect();
    events.sort_by(|a, b| {
        num_of(a, "t")
            .total_cmp(&num_of(b, "t"))
            .then_with(|| str_of(a, "id").cmp(&str_of(b, "id")))
    });

    let mut raw: Vec<(f64, String, Vec<String>)> = Vec::new();
    let mut seen_rivals: BTreeMap<String, Vec<&Value>> = BTreeMap::new();
    let mut quests: BTreeMap<String, Vec<&Value>> = BTreeMap::new();

    for e in events {
        let author = str_of(e, "a").unwrap_or("").to_string();
        if !allowed_guids.contains(&author) {
            exclude("auteur sans consentement", 1);
            continue;
        }
        let k = str_of(e, "k").unwrap_or("");
        let p = payload(e);
        let who = str_of(e, "n").unwrap_or("?").to_string();
        let loc = e.get("loc").cloned().unwrap_or(Value::Null);
        let zone = str_of(&loc, "i")
            .or_else(|| str_of(&loc, "z"))
            .unwrap_or("")
            .to_string();
        let at = if zone.is_empty() {
            String::new()
        } else {
            format!(" à {zone}")
        };
        let prov = str_of(e, "prov").unwrap_or("OBS");
        if k == "ENEMY_SEEN" {
            seen_rivals.entry(author).or_default().push(e);
            continue;
        }
        if k == "QUEST_DONE" {
            quests.entry(author).or_default().push(e);
            continue;
        }
        let text: Option<String> = match k {
            "LEVEL_UP" => Some(format!(
                "{who} atteint le niveau {}{at}",
                Some(s(p, "lvl"))
                    .filter(|x| !x.is_empty())
                    .unwrap_or("?".into())
            )),
            "DEATH" => {
                let mut t = format!("{who} meurt{at}");
                if !s(p, "lvl").is_empty() {
                    t += &format!(" au niveau {}", s(p, "lvl"));
                }
                if !s(p, "cause").is_empty() {
                    t += &format!(" ({})", s(p, "cause"));
                }
                let enemies = names_list(p.get("enemies").unwrap_or(&Value::Null));
                if !enemies.is_empty() {
                    let aliases: Vec<String> =
                        enemies.iter().map(|n| rivals.alias(Some(n))).collect();
                    t += &format!(
                        " ; rivaux aperçus juste avant (supposé, pas forcément les tueurs) : {}",
                        aliases.join(", ")
                    );
                }
                Some(t)
            }
            "DEATH_CAUSE" => {
                let victim = s(p, "victim");
                if !victim.is_empty() && !allowed.contains(&victim) {
                    exclude("nomme un membre sans consentement", 1);
                    continue;
                }
                let killer = s(p, "killer");
                let mut cause = Some(s(p, "cause"))
                    .filter(|c| !c.is_empty())
                    .unwrap_or("?".into());
                if !killer.is_empty() && rivals.is_known(&killer) {
                    cause = cause.replace(&killer, &rivals.alias(Some(&killer)));
                }
                Some(format!(
                    "d'après le journal de combat de {who} : {victim} est mort(e) — {cause}"
                ))
            }
            "BOSS_KILL" => Some(format!(
                "{who} et son groupe triomphent de {}{at}",
                Some(s(p, "name"))
                    .filter(|x| !x.is_empty())
                    .unwrap_or("un boss".into())
            )),
            "ZONE_FIRST_VISIT" => Some(format!(
                "{who} découvre {}",
                if zone.is_empty() {
                    "une nouvelle contrée"
                } else {
                    &zone
                }
            )),
            "EXPEDITION" => {
                let pt: Vec<&Value> = e
                    .get("pt")
                    .and_then(Value::as_array)
                    .map(|l| l.iter().collect())
                    .unwrap_or_default();
                let kept: Vec<String> = pt
                    .iter()
                    .filter_map(|x| str_of(x, "n"))
                    .filter(|n| allowed.contains(*n))
                    .map(str::to_string)
                    .collect();
                let hidden = pt
                    .iter()
                    .filter(|x| str_of(x, "n").is_none_or(|n| !allowed.contains(n)))
                    .count();
                let place = Some(s(p, "inst"))
                    .filter(|x| !x.is_empty())
                    .unwrap_or(zone.clone());
                let mut t = format!("{} {place}", exp_type(&s(p, "type")))
                    .trim()
                    .to_string();
                t += &format!(" : groupe mené par {who}");
                let others_named: Vec<&String> = kept.iter().filter(|n| **n != who).collect();
                if !kept.is_empty() {
                    t += &format!(
                        " avec {}",
                        others_named
                            .iter()
                            .map(|s| s.as_str())
                            .collect::<Vec<_>>()
                            .join(", ")
                    );
                }
                let others = hidden + num_of(p, "others") as usize;
                if others > 0 {
                    t += &format!(" (+{others} autre(s) participant(s) non nommé(s))");
                }
                let mut bits = vec![format!("{} min", num_of(p, "duration") as i64 / 60)];
                for (key, lab) in [
                    ("bosses", "boss vaincu(s)"),
                    ("deaths", "mort(s)"),
                    ("quests", "quête(s)"),
                ] {
                    let n = num_of(p, key);
                    if n != 0.0 {
                        bits.push(format!("{} {lab}", s(p, key)));
                    }
                }
                let bosses = names_list(p.get("bossNames").unwrap_or(&Value::Null));
                if !bosses.is_empty() {
                    bits.push(format!("boss : {}", bosses.join(", ")));
                }
                t += &format!(" — {}", bits.join(", "));
                if names_list(e.get("ded").unwrap_or(&Value::Null))
                    .iter()
                    .any(|d| d == "finish")
                {
                    t += " (heure de fin estimée)";
                }
                Some(t)
            }
            "PVP_CLASH" => {
                let member = Some(s(p, "member"))
                    .filter(|x| !x.is_empty())
                    .unwrap_or(who.clone());
                if !allowed.contains(&member) {
                    exclude("nomme un membre sans consentement", 1);
                    continue;
                }
                let verb = if s(p, "result") == "win" {
                    "l'emporte face à"
                } else {
                    "tombe face à"
                };
                let enemy = str_of(p, "name").or_else(|| str_of(p, "enemy"));
                Some(format!("{member} {verb} {}", rivals.alias(enemy)))
            }
            "WANTED" => {
                let mut t = format!(
                    "{who} placarde un avis de recherche contre {}",
                    rivals.alias(str_of(p, "name"))
                );
                if !s(p, "reason").is_empty() {
                    t += &format!(" — motif : {}", s(p, "reason"));
                }
                Some(t)
            }
            "WANTED_CLOSE" => Some(format!(
                "{who} lève l'avis de recherche contre {}",
                rivals.alias(str_of(p, "name"))
            )),
            "ENEMY_NOTE" => {
                let mut t = format!(
                    "{who} annote la fiche de {}",
                    rivals.alias(str_of(p, "name"))
                );
                if !s(p, "nickname").is_empty() {
                    t += &format!(" et le/la surnomme « {} »", s(p, "nickname"));
                }
                Some(t)
            }
            "ANECDOTE" => {
                let mut t = format!("anecdote racontée par {who} : {}", s(p, "title"));
                if !s(p, "desc").is_empty() {
                    t += &format!(" — {}", s(p, "desc"));
                }
                Some(t)
            }
            "PROFESSION" => Some(format!(
                "{who} atteint {} en {}",
                Some(s(p, "rank"))
                    .filter(|x| !x.is_empty())
                    .unwrap_or("?".into()),
                Some(s(p, "skill"))
                    .filter(|x| !x.is_empty())
                    .unwrap_or("?".into())
            )),
            "RARE_ITEM" => Some(format!(
                "{who} obtient {}",
                Some(s(p, "item"))
                    .filter(|x| !x.is_empty())
                    .unwrap_or("un objet rare".into())
            )),
            "GUILD_JOIN" => Some(format!("{who} rejoint la guilde")),
            _ => None,
        };
        let Some(mut text) = text else {
            exclude(&format!("type non pris en charge ({k})"), 1);
            continue;
        };
        if prov == "MAN" && !["ANECDOTE", "WANTED", "WANTED_CLOSE", "ENEMY_NOTE"].contains(&k) {
            text = format!("selon {who} (déclaré, non vérifié) : {text}");
        } else if prov == "DED" {
            text += " (déduit, non observé)";
        }
        // Rivals -> aliases; a non-consenting member in the text -> fact dropped.
        let text = rival_re.replace_all(&text, |m| rivals.alias(Some(m)));
        if member_re.find(&text).is_some() {
            exclude("nomme un membre sans consentement", 1);
            continue;
        }
        let id = str_of(e, "id").unwrap_or("").to_string();
        raw.push((num_of(e, "t"), text, vec![id]));
    }

    for (author, evs) in &seen_rivals {
        let who = authors.get(author).cloned().unwrap_or_else(|| "?".into());
        let distinct: BTreeSet<String> = evs
            .iter()
            .map(|x| rivals.alias(str_of(payload(x), "name")))
            .collect();
        let guilds: BTreeSet<&str> = evs
            .iter()
            .filter_map(|x| str_of(payload(x), "guild"))
            .collect();
        let list: Vec<&str> = distinct.iter().take(8).map(String::as_str).collect();
        let text = format!(
            "{who} a croisé {} fois des membres de la guilde rivale {} cette semaine : {}",
            evs.len(),
            guilds.into_iter().collect::<Vec<_>>().join("/"),
            list.join(", ")
        );
        let ids: Vec<String> = evs
            .iter()
            .filter_map(|x| str_of(x, "id").map(str::to_string))
            .collect();
        let tail = ids[ids.len().saturating_sub(10)..].to_vec();
        raw.push((num_of(evs[evs.len() - 1], "t"), text, tail));
    }
    for (author, evs) in &quests {
        let who = authors.get(author).cloned().unwrap_or_else(|| "?".into());
        let titles: Vec<&str> = evs
            .iter()
            .filter_map(|x| str_of(payload(x), "title"))
            .take(3)
            .collect();
        let mut text = format!("{who} termine {} quête(s)", evs.len());
        if !titles.is_empty() {
            text += &format!(" dont « {} »", titles.join(" », « "));
        }
        let text = rival_re.replace_all(&text, |m| rivals.alias(Some(m)));
        if member_re.find(&text).is_some() {
            continue;
        }
        let ids: Vec<String> = evs
            .iter()
            .filter_map(|x| str_of(x, "id").map(str::to_string))
            .collect();
        let tail = ids[ids.len().saturating_sub(10)..].to_vec();
        raw.push((num_of(evs[evs.len() - 1], "t"), text, tail));
    }

    raw.sort_by(|a, b| a.0.total_cmp(&b.0));
    if raw.len() > MAX_FACTS {
        exclude(
            "au-delà des 150 faits les plus récents",
            raw.len() - MAX_FACTS,
        );
        raw.drain(..raw.len() - MAX_FACTS);
    }
    let facts = raw
        .into_iter()
        .enumerate()
        .map(|(i, (t, text, refs))| Fact {
            key: format!("F{}", i + 1),
            when: t,
            text: format!("{} — {text}", when(t)),
            refs,
        })
        .collect();
    let mut excluded: Vec<(String, usize)> = excluded.into_iter().collect();
    excluded.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    Brief {
        facts,
        allowed,
        forbidden,
        rival_guild: rivals.guild.clone(),
        excluded,
        since,
        until,
    }
}

const PROMPT: &str = "Tu es la rédaction de « La Gazette », le journal satirique d'une guilde de World of Warcraft.
Écris entre 2 et {max_articles} articles en français pour l'édition du {start} au {end}, à partir
UNIQUEMENT des faits numérotés ci-dessous.

Règles impératives :
1. N'invente rien : aucun événement, nom, chiffre, lieu, boss, objet ou dialogue rapporté qui ne
   figure pas dans les faits. Tu peux commenter, exagérer le ton, faire des hypothèses présentées
   comme telles (« on murmure que… » à propos d'un fait réel), mais jamais créer un fait.
2. Ne nomme que les personnages présents dans les faits. Les rivaux sont désignés par leur alias
   (« Rival A … ») : n'essaie pas de deviner leur vrai nom.
3. Respecte la provenance : un fait « déclaré, non vérifié » s'écrit « selon X » ; un fait
   « supposé » ou « déduit » reste au conditionnel ; les rivaux aperçus avant une mort ne sont pas
   les tueurs.
4. Humour bienveillant : on taquine les personnages et leurs exploits ou déboires en jeu, jamais
   les joueurs réels (physique, vie privée, origine, etc.). Pas d'insulte ni de contenu choquant.
5. Chaque article cite dans « refs » les numéros des faits qu'il utilise (au moins un).
6. Titre : 80 caractères au plus. Corps : 1200 caractères au plus, texte brut sans Markdown.
7. Varie les formats (Une, Brève, Nécrologie, Chronique PvP, Carnet mondain…) et les styles
   (journaliste sarcastique, chroniqueur épique, rédacteur de faits divers…).
{guild_line}
Réponds par un unique objet JSON, sans texte autour :
{\"articles\": [{\"title\": \"...\", \"format\": \"...\", \"style\": \"...\", \"body\": \"...\", \"refs\": [\"F1\", \"F4\"]}]}

Faits de la semaine :
{facts}
";

pub fn prompt(brief: &Brief) -> String {
    let date = |t: f64| local(t).format("%d/%m/%Y").to_string();
    let guild_line = brief
        .rival_guild
        .as_ref()
        .map(|g| {
            format!("La guilde rivale s'appelle « {g} » (le nom de la guilde peut être cité).\n")
        })
        .unwrap_or_default();
    let facts: Vec<String> = brief
        .facts
        .iter()
        .map(|f| format!("{}. {}", f.key, f.text))
        .collect();
    PROMPT
        .replace("{max_articles}", &MAX_ARTICLES.to_string())
        .replace("{start}", &date(brief.since))
        .replace("{end}", &date(brief.until))
        .replace("{guild_line}", &guild_line)
        .replace("{facts}", &facts.join("\n"))
}

fn extract_json(text: &str) -> Result<Value, String> {
    let (Some(start), Some(end)) = (text.find('{'), text.rfind('}')) else {
        return Err("pas d'objet JSON dans la réponse".into());
    };
    if end <= start {
        return Err("pas d'objet JSON dans la réponse".into());
    }
    serde_json::from_str(&text[start..=end]).map_err(|e| e.to_string())
}

/// AI answer -> (Press.lua items, problems). A dubious article is rejected.
pub fn check(brief: &Brief, answer: &str, edition: &str) -> (Vec<Value>, Vec<String>) {
    let data = match extract_json(answer) {
        Ok(d) => d,
        Err(e) => return (Vec::new(), vec![format!("réponse illisible : {e}")]),
    };
    let Some(arts) = data.get("articles").and_then(Value::as_array) else {
        return (Vec::new(), vec!["réponse sans liste « articles »".into()]);
    };
    let facts: HashMap<&str, &Fact> = brief.facts.iter().map(|f| (f.key.as_str(), f)).collect();
    let forbidden = Names::new(&brief.forbidden);
    let mut items = Vec::new();
    let mut notes = Vec::new();
    let text_of = |a: &Value, k: &str| match a.get(k) {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Null) | None => String::new(),
        Some(v) => v.to_string(),
    };
    for (n, a) in arts.iter().take(MAX_ARTICLES).enumerate() {
        let n = n + 1;
        if !a.is_object() {
            notes.push(format!("article {n} : format invalide"));
            continue;
        }
        let title = text_of(a, "title");
        let body = text_of(a, "body");
        let refs: Vec<String> = a
            .get("refs")
            .and_then(Value::as_array)
            .map(|l| {
                l.iter()
                    .map(|r| match r {
                        Value::String(s) => s.trim().to_string(),
                        v => v.to_string(),
                    })
                    .filter(|r| !r.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let short: String = title.chars().take(40).collect();
        let label = format!("article {n} « {short} »");
        if title.is_empty() || body.is_empty() {
            notes.push(format!("{label} : titre ou texte vide — rejeté"));
            continue;
        }
        if title.chars().count() > MAX_TITLE || body.len() > MAX_BODY {
            notes.push(format!("{label} : trop long — rejeté"));
            continue;
        }
        let unknown: Vec<&str> = refs
            .iter()
            .filter(|r| !facts.contains_key(r.as_str()))
            .map(String::as_str)
            .collect();
        if refs.is_empty() || !unknown.is_empty() {
            let list = if unknown.is_empty() {
                "aucune".to_string()
            } else {
                unknown.join(", ")
            };
            notes.push(format!(
                "{label} : sources absentes ou inventées ({list}) — rejeté"
            ));
            continue;
        }
        if let Some(hit) = forbidden.find(&format!("{title}\n{body}")) {
            notes.push(format!(
                "{label} : nomme « {hit} » (sans consentement ou rival) — rejeté"
            ));
            continue;
        }
        let mut event_ids: Vec<String> = Vec::new();
        for r in &refs {
            for i in &facts[r.as_str()].refs {
                if !event_ids.contains(i) {
                    event_ids.push(i.clone());
                }
            }
        }
        event_ids.truncate(40);
        let digest = sha1_hex(&format!("{title}\0{body}"), 10);
        let format: String = Some(text_of(a, "format"))
            .filter(|x| !x.is_empty())
            .unwrap_or("Brève".into())
            .chars()
            .take(40)
            .collect();
        let style: String = Some(text_of(a, "style"))
            .filter(|x| !x.is_empty())
            .unwrap_or("Rédaction".into())
            .chars()
            .take(60)
            .collect();
        items.push(json!({
            "id": format!("ia:{edition}:{digest}"), "kind": "ARTICLE", "refs": event_ids,
            "p": {"title": title, "body": body, "format": format, "style": style, "ia": true, "edition": edition},
        }));
    }
    (items, notes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(id: &str, a: &str, n: &str, k: &str, t: i64, p: Value) -> (String, Value) {
        (
            id.to_string(),
            json!({"id": id, "a": a, "n": n, "k": k, "t": t, "vis": "G", "g": "Renatus-Forever", "s": 1, "p": p}),
        )
    }

    fn chronicle() -> Chronicle {
        let events = [
            ev("A:1", "A", "Alice", "AI_CONSENT", 100, json!({"ok": true})),
            ev("B:1", "B", "Bob", "AI_CONSENT", 100, json!({"ok": false})),
            ev("A:2", "A", "Alice", "LEVEL_UP", 1000, json!({"lvl": 20})),
            ev("B:2", "B", "Bob", "LEVEL_UP", 1001, json!({"lvl": 30})),
            ev(
                "A:3",
                "A",
                "Alice",
                "ENEMY_SEEN",
                1002,
                json!({"name": "Gorbash", "guild": "Les Crocs", "class": "ROGUE", "race": "Orc"}),
            ),
            ev(
                "A:4",
                "A",
                "Alice",
                "PVP_CLASH",
                1003,
                json!({"name": "Gorbash", "result": "loss"}),
            ),
            ev(
                "A:5",
                "A",
                "Alice",
                "ANECDOTE",
                1004,
                json!({"title": "Bob tombe dans le lac"}),
            ),
            ev(
                "A:6",
                "A",
                "Alice",
                "GUILD_CONFIG",
                1005,
                json!({"rival": "Les Crocs"}),
            ),
        ];
        Chronicle {
            events: events.into_iter().collect(),
            ..Chronicle::default()
        }
    }

    #[test]
    fn facts_respect_consent_and_alias_rivals() {
        let brief = build(&chronicle(), 0.0, 2000.0);
        let texts: Vec<&str> = brief.facts.iter().map(|f| f.text.as_str()).collect();
        assert_eq!(texts.len(), 3, "{texts:#?}");
        assert!(texts[0].ends_with("Alice atteint le niveau 20"));
        assert!(texts[1].contains("a croisé 1 fois des membres de la guilde rivale Les Crocs cette semaine : Rival A (voleur Orc)"));
        assert!(
            texts[2].contains("Alice tombe face à Rival A (voleur Orc)"),
            "{texts:#?}"
        );
        assert!(brief.forbidden.contains("Bob") && brief.forbidden.contains("Gorbash"));
        assert_eq!(brief.rival_guild.as_deref(), Some("Les Crocs"));
        let reasons: BTreeMap<_, _> = brief.excluded.iter().cloned().collect();
        assert_eq!(reasons["auteur sans consentement"], 1);
        assert_eq!(
            reasons["nomme un membre sans consentement"], 1,
            "anecdote naming Bob"
        );
        let p = prompt(&brief);
        assert!(p.contains("F2. ") && p.contains("« Les Crocs »") && !p.contains("Gorbash"));
    }

    #[test]
    fn answer_check_rejects_invented_sources_and_forbidden_names() {
        let brief = build(&chronicle(), 0.0, 2000.0);
        let answer = r#"Voici : {"articles": [
            {"title": "Alice grimpe", "body": "Niveau 20 !", "refs": ["F1"], "format": "Brève"},
            {"title": "Inventé", "body": "x", "refs": ["F9"]},
            {"title": "Gorbash frappe", "body": "y", "refs": ["F2"]},
            {"title": "Bobby", "body": "Bobby n'est pas Bob-le-Rouge", "refs": ["F2"]}
        ]}"#;
        let (items, notes) = check(&brief, answer, "2026-S47");
        assert_eq!(items.len(), 2, "{notes:?}");
        assert_eq!(items[0]["refs"], json!(["A:2"]));
        assert_eq!(items[0]["p"]["ia"], true);
        assert!(items[0]["id"].as_str().unwrap().starts_with("ia:2026-S47:"));
        assert!(notes[0].contains("F9"));
        assert!(notes[1].contains("« Gorbash »"));
        assert!(check(&brief, "pas de json", "x").1[0].contains("illisible"));
    }

    #[test]
    fn whole_word_names() {
        let names = Names::new(
            &["Bob".to_string(), "Élise".to_string()]
                .into_iter()
                .collect::<Vec<_>>(),
        );
        assert_eq!(names.find("salut bob !"), Some("bob"));
        assert_eq!(names.find("Bobby, Bob-x"), None);
        assert_eq!(names.find("ÉLISE"), Some("ÉLISE"));
        assert_eq!(
            names.replace_all("Bob et bob", |m| format!("<{m}>")),
            "<Bob> et <bob>"
        );
    }
}
