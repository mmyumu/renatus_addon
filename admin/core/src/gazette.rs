//! AI-written gazette: verified facts -> prompt -> articles proposed to the editor.
//!
//! Safeguards (docs/ARCHITECTURE.md §7, §8.4):
//!   - only the guild's SHARED events (vis G) are read;
//!   - consent: a character only appears if they ticked "La gazette IA peut parler de moi"
//!     (AI_CONSENT event, latest choice wins). Otherwise their events are not sent, and
//!     another member's fact naming them is dropped;
//!   - enemy players (rival guild or not) are named with a description:
//!     "Décimeur (chasseur Tauren, <Les Cousins Maudits>)", "Gorbash (voleur Orc, guilde rivale)";
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

pub const MAX_BODY: usize = 3500;
pub const MAX_TITLE: usize = 90;
/// Default of the "articles at most" setting (config::Config::max_articles).
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
    "TRADE_OFFER",
    "TRADE_REPLY",
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
    /// Family of the fact, for the editor's table (never sent to the AI).
    pub cat: &'static str,
    /// Consenting members the text names, for the editor's table.
    pub who: Vec<String>,
}

impl Brief {
    /// The same brief restricted to the facts with these keys (the editor's selection).
    pub fn select(&self, keys: &[String]) -> Brief {
        let mut b = self.clone();
        b.facts.retain(|f| keys.contains(&f.key));
        b
    }
}

/// A published issue, as the AI reads it again: (title, body) of its articles in order.
#[derive(Debug, Clone, Serialize)]
pub struct PastIssue {
    pub edition: String,
    pub when: f64,
    pub articles: Vec<(String, String)>,
}

/// How many published issues the AI reads again before writing the next one.
pub const PAST_ISSUES: usize = 3;

/// The latest issues published before `until` (ARTICLE events with an edition), oldest
/// first. An article naming a member without consent is left out.
fn past_issues(ch: &Chronicle, until: f64, forbidden: &Names) -> Vec<PastIssue> {
    let mut by_edition: BTreeMap<String, Vec<&Value>> = BTreeMap::new();
    for e in ch.of_kind("ARTICLE") {
        let t = num_of(e, "t");
        if str_of(e, "vis") != Some("G") || t >= until {
            continue;
        }
        if let Some(ed) = str_of(payload(e), "edition") {
            by_edition.entry(ed.to_string()).or_default().push(e);
        }
    }
    let mut issues: Vec<PastIssue> = by_edition
        .into_iter()
        .map(|(edition, mut arts)| {
            arts.sort_by(|a, b| {
                num_of(payload(a), "order")
                    .total_cmp(&num_of(payload(b), "order"))
                    .then(num_of(a, "t").total_cmp(&num_of(b, "t")))
            });
            let when = arts.iter().map(|a| num_of(a, "t")).fold(0.0, f64::max);
            let articles = arts
                .iter()
                .map(|a| (s(payload(a), "title"), s(payload(a), "body")))
                .filter(|(t, b)| !b.is_empty() && forbidden.find(&format!("{t}\n{b}")).is_none())
                .collect();
            PastIssue {
                edition,
                when,
                articles,
            }
        })
        .filter(|i| !i.articles.is_empty())
        .collect();
    issues.sort_by(|a, b| a.when.total_cmp(&b.when));
    let skip = issues.len().saturating_sub(PAST_ISSUES);
    issues.drain(..skip);
    issues
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
    /// Consenting members' character sex ("homme" / "femme"), by name, for the grammar.
    pub sexes: BTreeMap<String, &'static str>,
    /// Exclusion reasons and counts, most frequent first.
    pub excluded: Vec<(String, usize)>,
    /// The latest published issues, oldest first: the newsroom's memory.
    pub past: Vec<PastIssue>,
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

/// Enemy characters as the facts name them: name, class, race and guild (the rival guild
/// said as such). Honorable kills name every victim since addon 1.0.7.
struct Rivals {
    info: HashMap<String, (String, String, String, String)>, // lower -> (name, class, race, guild)
    guild: Option<String>,
    alias: HashMap<String, String>,
}

impl Rivals {
    fn new(ch: &Chronicle) -> Self {
        let mut info: HashMap<String, (String, String, String, String)> = HashMap::new();
        let mut seen_guild = None;
        for kind in [
            "ENEMY_SEEN",
            "ENEMY_NOTE",
            "WANTED",
            "PVP_CLASH",
            "PVP_KILL",
        ] {
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
                let d = info.entry(name.to_lowercase()).or_insert_with(|| {
                    (
                        name.to_string(),
                        String::new(),
                        String::new(),
                        String::new(),
                    )
                });
                if d.1.is_empty() {
                    d.1 = str_of(p, "class").unwrap_or("").to_string();
                }
                if d.2.is_empty() {
                    d.2 = str_of(p, "race").unwrap_or("").to_string();
                }
                if let Some(g) = str_of(p, "guild").filter(|g| !g.is_empty()) {
                    d.3 = g.to_string(); // latest wins (events sorted by time)
                    if kind == "ENEMY_SEEN" {
                        seen_guild = Some(g.to_string());
                    }
                }
            }
        }
        // The guild setting first; before it existed, the guild of the rivals met.
        let guild = ch.configured_rival().or(seen_guild);
        Self {
            info,
            guild,
            alias: HashMap::new(),
        }
    }

    fn alias(&mut self, name: Option<&str>) -> String {
        let Some(name) = name.filter(|n| !n.is_empty()) else {
            return "un ennemi".into();
        };
        let key = name.to_lowercase();
        if let Some(a) = self.alias.get(&key) {
            return a.clone();
        }
        let mut bits: Vec<String> = Vec::new();
        let mut shown = name.to_string();
        if let Some((full, class, race, guild)) = self.info.get(&key) {
            shown = full.clone();
            let who = [class_fr(class), race.as_str()]
                .iter()
                .filter(|x| !x.is_empty())
                .copied()
                .collect::<Vec<_>>()
                .join(" ");
            if !who.is_empty() {
                bits.push(who);
            }
            if !guild.is_empty() {
                let rival = self
                    .guild
                    .as_ref()
                    .is_some_and(|g| g.eq_ignore_ascii_case(guild));
                bits.push(if rival {
                    "guilde rivale".to_string()
                } else {
                    format!("<{guild}>")
                });
            }
        }
        let alias = if bits.is_empty() {
            shown
        } else {
            format!("{shown} ({})", bits.join(", "))
        };
        self.alias.insert(key, alias.clone());
        alias
    }
}

pub(crate) fn local(t: f64) -> chrono::DateTime<Local> {
    Local
        .timestamp_opt(t as i64, 0)
        .single()
        .unwrap_or_else(Local::now)
}

/// Battlegrounds and arenas: matches set up by the game, not fights met on the front
/// (same rule as the addon's `Views.InHunt`).
pub(crate) fn in_battleground(e: &Value) -> bool {
    e.get("loc")
        .and_then(|l| str_of(l, "it"))
        .is_some_and(|it| it == "pvp" || it == "arena")
}

/// Combat events of a battleground: told as a match, never counted as fights, deaths or
/// victories of the front (our kills there are not even recorded, so deaths alone would
/// read as a lopsided score).
pub(crate) fn bg_combat(e: &Value) -> bool {
    in_battleground(e)
        && matches!(
            str_of(e, "k"),
            Some("DEATH" | "PVP_KILL" | "ENEMY_SEEN" | "DEATH_CAUSE")
        )
}

/// Within this gap, fights with enemy players belong to the same "affrontement".
const FIGHT_GAP: f64 = 1800.0;
/// From this many fights, they are told as one affrontement instead of one by one.
const FIGHT_MIN: usize = 3;

/// One fight with enemy players: honorable kill, declared clash, or death with enemies around.
struct Fight {
    t: f64,
    id: String,
    text: String,
    member: String,
    win: bool,
    zone: String,
    rivals: Vec<String>,
}

impl Fight {
    fn of(
        e: &Value,
        who: &str,
        zone: &str,
        text: &str,
        id: &str,
        rivals: &mut Rivals,
    ) -> Option<Fight> {
        let p = payload(e);
        let k = str_of(e, "k")?;
        let named = |key: &str| str_of(p, key).filter(|n| !n.is_empty());
        let (win, member, names): (bool, String, Vec<String>) = match k {
            "PVP_KILL" => (
                true,
                who.to_string(),
                named("name").map(str::to_string).into_iter().collect(),
            ),
            "PVP_CLASH" => (
                s(p, "result") == "win",
                named("member").unwrap_or(who).to_string(),
                named("name")
                    .or_else(|| named("enemy"))
                    .map(str::to_string)
                    .into_iter()
                    .collect(),
            ),
            "DEATH" => {
                let enemies = names_list(p.get("enemies").unwrap_or(&Value::Null));
                let by_player = p.get("killer").and_then(|k| k.get("cl")).is_some();
                if enemies.is_empty() && !by_player {
                    return None;
                }
                (false, who.to_string(), enemies)
            }
            _ => return None,
        };
        Some(Fight {
            t: num_of(e, "t"),
            id: id.to_string(),
            text: text.to_string(),
            member,
            win,
            zone: zone.to_string(),
            rivals: names.iter().map(|n| rivals.alias(Some(n))).collect(),
        })
    }
}

/// Fights close in time -> one fact per affrontement (alone or few: one fact each).
fn fight_facts(mut fights: Vec<Fight>) -> Vec<(f64, String, Vec<String>)> {
    fights.sort_by(|a, b| a.t.total_cmp(&b.t));
    let mut groups: Vec<Vec<Fight>> = Vec::new();
    for f in fights {
        match groups.last_mut() {
            Some(g) if f.t - g[g.len() - 1].t <= FIGHT_GAP => g.push(f),
            _ => groups.push(vec![f]),
        }
    }
    let mut out = Vec::new();
    for g in groups {
        if g.len() < FIGHT_MIN {
            out.extend(g.into_iter().map(|f| (f.t, f.text, vec![f.id])));
            continue;
        }
        let uniq = |it: &mut dyn Iterator<Item = String>| {
            let mut v: Vec<String> = Vec::new();
            for x in it {
                if !x.is_empty() && !v.contains(&x) {
                    v.push(x);
                }
            }
            v
        };
        let members = uniq(&mut g.iter().map(|f| f.member.clone()));
        let zones = uniq(&mut g.iter().map(|f| f.zone.clone()));
        let rivals = uniq(&mut g.iter().flat_map(|f| f.rivals.clone()));
        let wins = g.iter().filter(|f| f.win).count();
        let losses = g.len() - wins;
        let major = g.len() >= 5 || members.len() >= 2;
        let (start, end) = (g[0].t, g[g.len() - 1].t);
        let hour = |t: f64| local(t).format("%Hh%M").to_string();
        let mut text = format!(
            "{} {}de {} à {} : {} face à la faction adverse — {} victoire(s) honorable(s) ou déclarée(s), {} mort(s) ou défaite(s) côté guilde",
            if major { "AFFRONTEMENT MAJEUR" } else { "Escarmouche" },
            if zones.is_empty() { String::new() } else { format!("à {} ", zones.join(", ")) },
            hour(start),
            hour(end),
            members.join(", "),
            wins,
            losses
        );
        if !rivals.is_empty() {
            text += &format!(" ; ennemis impliqués : {}", rivals.join(", "));
        }
        let detail: Vec<String> = g.iter().take(8).map(|f| f.text.clone()).collect();
        text += &format!(". Détail : {}", detail.join(" ; "));
        if g.len() > 8 {
            text += &format!(" ; et {} autre(s)", g.len() - 8);
        }
        let mut refs: Vec<String> = g.iter().map(|f| f.id.clone()).collect();
        refs.truncate(20);
        out.push((end, text, refs));
    }
    out
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

/// Key of an issue, from when it was written: "2026-11-20-2147" (one issue per draft).
pub fn edition_key(until: f64) -> String {
    local(until).format("%Y-%m-%d-%H%M").to_string()
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

/// First kills of creature species (MOB_KILL), one fact per member: the rare and elite
/// ones first, then the highest levels.
/// When a grouped fact (quests, rivals seen, bestiary) spans several events: " entre lundi
/// 23/11 22h10 et mardi 24/11 21h47". A fact is dated by its last event, so without this
/// span the writer reads "69 quests at 21h47" as all turned in at once. Empty for one event.
fn span(evs: &[&Value]) -> String {
    let (Some(first), Some(last)) = (evs.first(), evs.last()) else {
        return String::new();
    };
    let (start, end) = (num_of(first, "t"), num_of(last, "t"));
    if evs.len() < 2 || when(start) == when(end) {
        return String::new();
    }
    format!(" entre {} et {}", when(start), when(end))
}

fn bestiary_fact(who: &str, evs: &[&Value]) -> (f64, String, Vec<String>) {
    let rank = |cls: &str| match cls {
        "worldboss" => 0,
        "rareelite" => 1,
        "rare" => 2,
        "elite" => 3,
        _ => 4,
    };
    let label = |cls: &str| match cls {
        "worldboss" => " (boss mondial)",
        "rareelite" => " (rare élite)",
        "rare" => " (rare)",
        "elite" => " (élite)",
        _ => "",
    };
    let mut list: Vec<&Value> = evs.to_vec();
    list.sort_by(|a, b| {
        let (pa, pb) = (payload(a), payload(b));
        rank(str_of(pa, "cls").unwrap_or(""))
            .cmp(&rank(str_of(pb, "cls").unwrap_or("")))
            .then(num_of(pb, "lvl").total_cmp(&num_of(pa, "lvl")))
    });
    let names: Vec<String> = list
        .iter()
        .take(6)
        .filter_map(|e| {
            let p = payload(e);
            str_of(p, "name").map(|n| format!("{n}{}", label(str_of(p, "cls").unwrap_or(""))))
        })
        .collect();
    let mut text = format!(
        "{who} abat pour la première fois {} espèce(s) de créatures{}",
        evs.len(),
        span(evs)
    );
    if !names.is_empty() {
        text += &format!(", dont : {}", names.join(", "));
    }
    let ids: Vec<String> = evs
        .iter()
        .filter_map(|x| str_of(x, "id").map(str::to_string))
        .collect();
    let tail = ids[ids.len().saturating_sub(10)..].to_vec();
    (num_of(evs[evs.len() - 1], "t"), text, tail)
}

/// "a giflé Alice": emotes aimed at a guild member (Collectors/Counters.lua).
fn emote_fr(token: &str, to: &str) -> Option<String> {
    let verb = match token {
        "SLAP" => "giflé",
        "KISS" => "embrassé",
        "HUG" => "serré dans ses bras",
        "LOVE" => "déclaré sa flamme à",
        "CHICKEN" => "traité de poule mouillée",
        "RUDE" => "fait un geste grossier à",
        "SPIT" => "craché sur",
        "ROFL" => "ri aux éclats devant",
        "LAUGH" => "ri au nez de",
        "BONK" => "assommé",
        "POKE" => "poussé du doigt",
        "TICKLE" => "chatouillé",
        "CUDDLE" => "câliné",
        "FLEX" => "montré ses muscles à",
        "DANCE" => "dansé avec",
        "CHEER" => "acclamé",
        "THANK" => "remercié",
        "BOW" => "salué bien bas",
        "INSULT" => "insulté",
        "FLIRT" => "flirté avec",
        "CRY" => "pleuré sur l'épaule de",
        "APPLAUD" => "applaudi",
        "GIGGLE" => "gloussé devant",
        "MOON" => "montré ses fesses à",
        "PITY" => "pris en pitié",
        "SHOO" => "chassé",
        "BITE" => "mordu",
        "PRAISE" => "porté aux nues",
        _ => return None,
    };
    Some(format!("a {verb} {to}"))
}

fn gold(copper: f64) -> String {
    let c = copper.round() as i64;
    let (g, s) = (c / 10000, (c / 100) % 100);
    if g > 0 {
        format!("{g} po {s} pa")
    } else {
        format!("{s} pa")
    }
}

/// A member's daily trivia (COUNTERS), summed: one fact. Emotes aimed at a member without
/// consent are left out (their count is returned).
fn counters_fact(
    who: &str,
    evs: &[&Value],
    allowed: &BTreeSet<String>,
) -> (Option<(f64, String, Vec<String>)>, usize) {
    let mut sums: BTreeMap<&str, f64> = BTreeMap::new();
    let mut emotes: BTreeMap<(String, String), f64> = BTreeMap::new();
    let mut dropped = 0;
    for e in evs {
        let p = payload(e);
        for key in [
            "jumps", "drunk", "spirit", "bagfull", "fish", "hearth", "earned", "spent",
        ] {
            *sums.entry(key).or_default() += num_of(p, key);
        }
        for x in p
            .get("emotes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let (Some(token), Some(to)) = (str_of(x, "e"), str_of(x, "to")) else {
                continue;
            };
            if !allowed.contains(to) {
                dropped += 1;
                continue;
            }
            *emotes
                .entry((token.to_string(), to.to_string()))
                .or_default() += num_of(x, "n");
        }
    }
    let mut bits: Vec<String> = Vec::new();
    for (key, one, many) in [
        ("jumps", "saut", "sauts"),
        ("drunk", "cuite", "cuites"),
        (
            "spirit",
            "visite à l'ange de la résurrection",
            "visites à l'ange de la résurrection",
        ),
        ("bagfull", "fois « sacs pleins »", "fois « sacs pleins »"),
        ("fish", "poisson pêché", "poissons pêchés"),
        (
            "hearth",
            "pierre de foyer utilisée",
            "pierres de foyer utilisées",
        ),
    ] {
        let n = sums[key];
        if n > 0.0 {
            bits.push(format!("{n} {}", if n > 1.0 { many } else { one }));
        }
    }
    if sums["earned"] > 0.0 {
        bits.push(format!("{} gagnés", gold(sums["earned"])));
    }
    if sums["spent"] > 0.0 {
        bits.push(format!("{} dépensés", gold(sums["spent"])));
    }
    let mut list: Vec<((String, String), f64)> = emotes.into_iter().collect();
    list.sort_by(|a, b| b.1.total_cmp(&a.1));
    let gestures: Vec<String> = list
        .iter()
        .take(6)
        .filter_map(|((token, to), n)| {
            emote_fr(token, to).map(|t| {
                if *n > 1.0 {
                    format!("{t} ({n} fois)")
                } else {
                    t
                }
            })
        })
        .collect();
    if bits.is_empty() && gestures.is_empty() {
        return (None, dropped);
    }
    let to = evs.iter().map(|e| num_of(e, "t")).fold(0.0, f64::max);
    let from = evs
        .iter()
        .map(|e| {
            Some(num_of(payload(e), "from"))
                .filter(|f| *f > 0.0)
                .unwrap_or(num_of(e, "t"))
        })
        .fold(to, f64::min);
    let day = |t: f64| local(t).format("%d/%m").to_string();
    let mut text = format!(
        "petites statistiques de {who} (du {} au {})",
        day(from),
        day(to)
    );
    if !bits.is_empty() {
        text += &format!(" : {}", bits.join(", "));
    }
    if !gestures.is_empty() {
        text += &format!(" ; {who} {}", gestures.join(", "));
    }
    let ids: Vec<String> = evs
        .iter()
        .filter_map(|x| str_of(x, "id").map(str::to_string))
        .collect();
    (Some((to, text, ids)), dropped)
}

const RECORDS: &str = "Records & jalons";
const OTHER: &str = "Divers";

/// Family of a fact, from the kind of its first source event.
fn category(kind: &str) -> &'static str {
    match kind {
        "LEVEL_UP" | "PROFESSION" | "REPUTATION" | "MONEY" | "MOUNT" | "RARE_ITEM"
        | "HEARTH_BIND" | "COUNTERS" => "Progression",
        "DEATH" | "DEATH_CAUSE" | "NEAR_DEATH" | "RESCUED" => "Morts & frayeurs",
        "BOSS_KILL" | "EXPEDITION" | "MOB_KILL" => "Expéditions & combats",
        "ZONE_FIRST_VISIT" | "QUEST_DONE" => "Exploration & quêtes",
        "PVP_CLASH" | "PVP_KILL" | "ENEMY_SEEN" | "WANTED" | "WANTED_CLOSE" | "ENEMY_NOTE" => {
            "Rivaux & JcJ"
        }
        "DUEL" | "ROLL_EXTREME" | "ANECDOTE" | "GUILD_JOIN" => "Vie de guilde",
        _ => OTHER,
    }
}

pub fn build(ch: &Chronicle, since: f64, until: f64) -> Brief {
    build_split(ch, since, until, since)
}

/// Like `build`, but grouped facts (quests, rivals seen) never mix events from before and
/// after `split`, so that each fact is either "recent" (t >= split) or older.
pub fn build_split(ch: &Chronicle, since: f64, until: f64, split: f64) -> Brief {
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
    let sexes: BTreeMap<String, &'static str> = ch
        .sexes()
        .into_iter()
        .filter(|(a, _)| allowed_guids.contains(a) && authors.contains_key(a))
        .map(|(a, sex)| (authors[&a].clone(), sex))
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
    // Enemy players are named; only members without consent are forbidden.
    let forbidden: BTreeSet<String> = forbidden_members.clone();
    let member_re = Names::new(&forbidden_members);
    let mut excluded: BTreeMap<String, usize> = BTreeMap::new();
    let mut exclude =
        |reason: &str, n: usize| *excluded.entry(reason.to_string()).or_default() += n;

    // The guild's shared events, all time: records and milestones need the history.
    let mut shared: Vec<&Value> = ch
        .all()
        .filter(|e| {
            str_of(e, "vis") == Some("G")
                && guild
                    .as_deref()
                    .zip(str_of(e, "g"))
                    .is_some_and(|(main, g)| crate::chronicle::same_guild(main, g))
                && num_of(e, "t") < until
                && !HIDDEN.contains(&str_of(e, "k").unwrap_or(""))
        })
        .collect();
    shared.sort_by(|a, b| {
        num_of(a, "t")
            .total_cmp(&num_of(b, "t"))
            .then_with(|| str_of(a, "id").cmp(&str_of(b, "id")))
    });
    let events: Vec<&Value> = shared
        .iter()
        .filter(|e| num_of(e, "t") >= since)
        .copied()
        .collect();

    let mut raw: Vec<(f64, String, Vec<String>)> = Vec::new();
    // grouped per (author, recent?)
    let mut seen_rivals: BTreeMap<(String, bool), Vec<&Value>> = BTreeMap::new();
    let mut quests: BTreeMap<(String, bool), Vec<&Value>> = BTreeMap::new();
    let mut bestiary: BTreeMap<(String, bool), Vec<&Value>> = BTreeMap::new();
    let mut counters: BTreeMap<(String, bool), Vec<&Value>> = BTreeMap::new();
    // Deaths and kills in a battleground, per (author, battleground, recent?): one match fact.
    let mut matches: BTreeMap<(String, String, bool), Vec<&Value>> = BTreeMap::new();
    // Events several members recorded (same `occ`: a boss, an expedition, a duel): one fact.
    let mut occurrences: HashMap<String, usize> = HashMap::new();
    // Fights with enemy players: close ones become a single "affrontement" fact.
    let mut fights: Vec<Fight> = Vec::new();

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
        let recent = num_of(e, "t") >= split;
        if bg_combat(e) {
            match k {
                "DEATH" | "PVP_KILL" => matches.entry((author, zone, recent)).or_default().push(e),
                _ => exclude("champ de bataille ou arène", 1),
            }
            continue;
        }
        if k == "ENEMY_SEEN" {
            seen_rivals.entry((author, recent)).or_default().push(e);
            continue;
        }
        if k == "QUEST_DONE" {
            quests.entry((author, recent)).or_default().push(e);
            continue;
        }
        if k == "MOB_KILL" {
            bestiary.entry((author, recent)).or_default().push(e);
            continue;
        }
        if k == "COUNTERS" {
            counters.entry((author, recent)).or_default().push(e);
            continue;
        }
        let occ = str_of(e, "occ").map(str::to_string);
        if let Some(i) = occ.as_ref().and_then(|o| occurrences.get(o)) {
            if let Some(id) = str_of(e, "id") {
                raw[*i].2.push(id.to_string());
            }
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
                let cause = Some(s(p, "cause"))
                    .filter(|c| !c.is_empty())
                    .unwrap_or("?".into());
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
            "PVP_KILL" => {
                let victim = match str_of(p, "name").filter(|n| !n.is_empty()) {
                    Some(name) => rivals.alias(Some(name)),
                    None => {
                        let mut v = format!("un {} {}", s(p, "race"), class_fr(&s(p, "class")))
                            .split_whitespace()
                            .collect::<Vec<_>>()
                            .join(" ");
                        if v == "un" {
                            v = "un ennemi".into();
                        }
                        if !s(p, "level").is_empty() {
                            v += &format!(" de niveau {}", s(p, "level"));
                        }
                        v
                    }
                };
                Some(format!(
                    "{who} remporte une victoire honorable sur {victim}{at}"
                ))
            }
            "WANTED" => {
                let mut t = format!(
                    "{who} placarde un avis de recherche contre {}",
                    rivals.alias(str_of(p, "name"))
                );
                if !s(p, "nickname").is_empty() {
                    t += &format!(" (surnommé « {} »)", s(p, "nickname"));
                }
                if !s(p, "reason").is_empty() {
                    t += &format!(" — motif : {}", s(p, "reason"));
                }
                if !s(p, "reward").is_empty() {
                    t += &format!(" — prime offerte : {}", s(p, "reward"));
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
            "DUEL" => {
                let (winner, loser) = (s(p, "winner"), s(p, "loser"));
                Some(if p.get("fled").and_then(Value::as_bool) == Some(true) {
                    format!("{loser} prend la fuite devant {winner} lors d'un duel{at}")
                } else {
                    format!("{winner} bat {loser} en duel{at}")
                })
            }
            "NEAR_DEATH" => {
                let mut t = format!(
                    "{who} survit de justesse à un combat{at}, avec {} % de vie",
                    s(p, "pct")
                );
                if !s(p, "lvl").is_empty() {
                    t += &format!(" (niveau {})", s(p, "lvl"));
                }
                Some(t)
            }
            "RESCUED" => Some(format!("{who} revient à la vie grâce à {}{at}", s(p, "by"))),
            "ROLL_EXTREME" => {
                let how = match s(p, "kind").as_str() {
                    "need" => "à un jet de besoin",
                    "greed" => "à un jet de cupidité",
                    _ => "en lançant les dés (1-100)",
                };
                let mut t = format!("{who} fait {} {how}", s(p, "roll"));
                if !s(p, "item").is_empty() {
                    t += &format!(" pour {}", s(p, "item"));
                }
                Some(t)
            }
            "REPUTATION" => Some(format!(
                "{who} devient {} auprès de {}",
                s(p, "standing"),
                s(p, "faction")
            )),
            "MONEY" => Some(format!(
                "{who} possède pour la première fois {} pièces d'or",
                s(p, "gold")
            )),
            "MOUNT" => Some(format!("{who} obtient une monture : {}", s(p, "name"))),
            "HEARTH_BIND" => {
                let mut t = format!("{who} lie sa pierre de foyer à {}", s(p, "place"));
                if !s(p, "from").is_empty() {
                    t += &format!(" (auparavant : {})", s(p, "from"));
                }
                Some(t)
            }
            _ => None,
        };
        let Some(mut text) = text else {
            exclude(&format!("type non pris en charge ({k})"), 1);
            continue;
        };
        if prov == "MAN" && !["ANECDOTE", "WANTED", "WANTED_CLOSE", "ENEMY_NOTE"].contains(&k) {
            text = format!("selon {who} (déclaré, non vérifié) : {text}");
        }
        // "DED" (only PvP victories) is not marked: the game counted the victory, only the
        // victim's name is deduced (seen dead nearby), and that is nearly always the case,
        // so the AI kept writing "déduit, non observé" after every single victory.
        // A non-consenting member in the text -> fact dropped.
        if member_re.find(&text).is_some() {
            exclude("nomme un membre sans consentement", 1);
            continue;
        }
        let id = str_of(e, "id").unwrap_or("").to_string();
        if let Some(fight) = Fight::of(e, &who, &zone, &text, &id, &mut rivals) {
            fights.push(fight);
            continue;
        }
        if let Some(o) = occ {
            occurrences.insert(o, raw.len());
        }
        raw.push((num_of(e, "t"), text, vec![id]));
    }
    raw.extend(fight_facts(fights));

    for ((author, _), evs) in &seen_rivals {
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
            "{who} a croisé {} fois{} des membres de la guilde rivale {} : {}",
            evs.len(),
            span(evs),
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
    for ((author, _), evs) in &quests {
        let who = authors.get(author).cloned().unwrap_or_else(|| "?".into());
        let titles: Vec<&str> = evs
            .iter()
            .filter_map(|x| str_of(payload(x), "title"))
            .take(3)
            .collect();
        let mut text = format!("{who} termine {} quête(s){}", evs.len(), span(evs));
        if !titles.is_empty() {
            text += &format!(", dont « {} »", titles.join(" », « "));
        }
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

    for ((author, zone, _), evs) in &matches {
        let who = authors.get(author).cloned().unwrap_or_else(|| "?".into());
        let count = |k: &str| evs.iter().filter(|x| str_of(x, "k") == Some(k)).count();
        let mut bits = Vec::new();
        for (n, lab) in [
            (count("DEATH"), "mort(s)"),
            (count("PVP_KILL"), "victoire(s) honorable(s)"),
        ] {
            if n > 0 {
                bits.push(format!("{n} {lab}"));
            }
        }
        let place = if zone.is_empty() {
            "champ de bataille".to_string()
        } else {
            format!("champ de bataille {zone}")
        };
        let text = format!(
            "{place} (match organisé par le jeu, pas un affrontement du front) — bilan de {who} : {}",
            bits.join(", ")
        );
        let ids: Vec<String> = evs
            .iter()
            .filter_map(|x| str_of(x, "id").map(str::to_string))
            .collect();
        let tail = ids[ids.len().saturating_sub(10)..].to_vec();
        raw.push((num_of(evs[evs.len() - 1], "t"), text, tail));
    }
    for ((author, _), evs) in &bestiary {
        let who = authors.get(author).cloned().unwrap_or_else(|| "?".into());
        raw.push(bestiary_fact(&who, evs));
    }
    for ((author, _), evs) in &counters {
        let who = authors.get(author).cloned().unwrap_or_else(|| "?".into());
        let (fact, dropped) = counters_fact(&who, evs, &allowed);
        if dropped > 0 {
            exclude("nomme un membre sans consentement", dropped);
        }
        raw.extend(fact);
    }
    // Facts so far come from the guild's events: their family follows their sources'.
    let by_id: HashMap<&str, &str> = shared
        .iter()
        .filter_map(|e| Some((str_of(e, "id")?, str_of(e, "k").unwrap_or(""))))
        .collect();
    let mut raw: Vec<(f64, String, Vec<String>, &'static str)> = raw
        .into_iter()
        .map(|(t, text, refs)| {
            let cat = refs
                .iter()
                .find_map(|r| by_id.get(r.as_str()))
                .map_or(OTHER, |k| category(k));
            (t, text, refs, cat)
        })
        .collect();
    let consenting: BTreeSet<String> = allowed_guids.iter().map(|g| (*g).clone()).collect();
    // Records, milestones and honours ignore battleground deaths and kills, like the fights.
    let front: Vec<&Value> = shared.iter().filter(|e| !bg_combat(e)).copied().collect();
    for fact in crate::derived::facts(&crate::derived::Input {
        events: &front,
        consenting: &consenting,
        since,
        until,
        split,
    }) {
        if member_re.find(&fact.1).is_some() {
            exclude("nomme un membre sans consentement", 1);
            continue;
        }
        raw.push((fact.0, fact.1, fact.2, RECORDS));
    }

    raw.sort_by(|a, b| a.0.total_cmp(&b.0));
    let named: Vec<(&String, Names)> = allowed.iter().map(|n| (n, Names::new([n]))).collect();
    let facts = raw
        .into_iter()
        .enumerate()
        .map(|(i, (t, text, refs, cat))| Fact {
            key: format!("F{}", i + 1),
            when: t,
            who: named
                .iter()
                .filter(|(_, re)| re.find(&text).is_some())
                .map(|(n, _)| (*n).clone())
                .collect(),
            text: format!("{} — {text}", when(t)),
            refs,
            cat,
        })
        .collect();
    let mut excluded: Vec<(String, usize)> = excluded.into_iter().collect();
    excluded.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    Brief {
        facts,
        allowed,
        forbidden,
        rival_guild: rivals.guild.clone(),
        sexes,
        excluded,
        past: past_issues(ch, until, &member_re),
        since,
        until,
    }
}

/// The columnists an issue's articles can be written by: (name shown as the article's
/// style, how they write). Each generation draws `TONES_PER_ISSUE` of them, so that
/// every issue gets its own voices. A tone is a voice: it fits any kind of article.
pub const TONES: &[(&str, &str)] = &[
    ("éditorialiste pince-sans-rire", "ironie de rédaction, commentaires faussement sérieux, chute sèche"),
    ("journaliste people", "façon magazine people (Paris Match, Voici) : potins, EXCLU en majuscules, sous-entendus et questions qui insinuent, émotions surjouées, le moindre détail en scandale"),
    ("grand reporter de magazine", "reportage feutré et révérencieux, destins et grands moments, le moindre fait traité comme un moment d'Histoire"),
    ("narrateur animalier", "voix grave et fascinée de documentaire, qui observe les membres comme une espèce sauvage dans son habitat"),
    ("commentateur sportif", "direct, envolées, ralentis, statistiques brandies, consultant qui perd sa voix"),
    ("barde épique", "le souffle des chansons de geste, réservé aux exploits les plus dérisoires"),
    ("détective de polar", "narrateur désabusé, phrases courtes, chaque fait est un indice"),
    ("chroniqueur absurde", "presse parodique : titres d'actualité sérieux pour des faits dérisoires, logique décalée assumée jusqu'au bout"),
    ("conteur", "« il était une fois », ton doux et naïf de conte pour enfants, morale finale"),
    ("critique d'art", "chaque exploit ou déboire lu comme une performance d'art contemporain, vocabulaire prétentieux"),
    ("correspondant de guerre", "lettre du front, solennelle et émue, bien plus que les faits ne le méritent"),
];

pub const TONES_PER_ISSUE: usize = 3;

/// Offbeat sections, unlike tones a form of article: (section, what it holds). Each
/// generation draws one, for one article of the issue.
pub const RUBRICS: &[(&str, &str)] = &[
    ("Météo", "le bulletin météo du journal, où les membres sont le temps qu'il fait : prévisions, alertes, éclaircies"),
    ("Chronique judiciaire", "compte rendu d'audience : le procès d'un membre pour un délit imaginaire tiré des faits, pièces à conviction, plaidoirie, condamnation ou relaxe"),
    ("Sciences", "la page Sciences, vulgarisée comme dans un magazine : « selon une étude de la rédaction », chiffres des faits, hypothèses des chercheurs, conclusion amusée"),
    ("La critique", "le critique de la gazette note un donjon ou une contrée comme un restaurant, en étoiles, d'après la visite des membres : accueil, service, addition"),
    ("Bourse", "les cours de la période : or gagné et dépensé, sauts, morts, quêtes traités comme des valeurs qui montent ou plongent, avec l'analyse des marchés"),
    ("Petites annonces", "quelques petites annonces courtes tirées des faits (à vendre, cherche, perdu, déménagement), rédigées par la rédaction, chacune finie par « s'adresser à » le membre concerné"),
    ("Horoscope", "quelques membres, chacun avec un signe ou un ascendant fantaisiste : d'abord un constat au passé composé tiré d'un fait réel de la période (« cette semaine, vous avez… »), puis les prédictions et conseils des astres au futur ou à l'impératif, seuls inventés et jamais un fait passé : ils rebondissent sur ce fait (sa suite logique poussée trop loin, un titre de quête pris au mot, les clichés Amour, Travail, Santé ou chiffre porte-bonheur appliqués au jeu), pas de l'absurde sans rapport"),
];

/// Draws `n` distinct entries of `list` from `seed` (a small xorshift: no need for more).
fn draw(
    list: &[(&'static str, &'static str)],
    n: usize,
    seed: u64,
) -> Vec<(&'static str, &'static str)> {
    // splitmix64 first, so that close seeds (consecutive nanoseconds) still draw apart.
    let mut x = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
    x = (x ^ (x >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    x = (x ^ (x >> 31)) | 1;
    let mut pool = list.to_vec();
    let mut out = Vec::new();
    while out.len() < n && !pool.is_empty() {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.push(pool.remove((x % pool.len() as u64) as usize));
    }
    out
}

pub fn draw_tones(seed: u64) -> Vec<(&'static str, &'static str)> {
    draw(TONES, TONES_PER_ISSUE, seed)
}

pub fn draw_rubric(seed: u64) -> (&'static str, &'static str) {
    draw(RUBRICS, 1, !seed)[0]
}

/// The built-in prompt. The settings can replace it (`Config::gazette_prompt`): the
/// `{placeholders}` below are filled in the same way, and `{facts}` is the one it needs.
pub const PROMPT: &str = "Tu es la rédaction de « La Gazette », le journal humoristique d'une guilde de World of Warcraft.
Écris entre 2 et {max_articles} articles en français pour l'édition du {start} au {end}, à partir
UNIQUEMENT des faits numérotés ci-dessous.

Règles impératives :
1. N'invente rien : aucun événement, nom, chiffre, lieu, boss, objet ou dialogue rapporté qui ne
   figure pas dans les faits. Tu peux commenter, exagérer le ton, faire des hypothèses présentées
   comme telles à propos d'un fait réel, mais jamais créer un fait.
2. Ne nomme que les personnages présents dans les faits. Les joueurs ennemis (guilde rivale ou
   autres) sont nommés par leur nom de personnage : tu peux t'en moquer comme des nôtres.
3. Respecte la provenance : un fait « déclaré, non vérifié » s'écrit « selon X » ; un fait
   « supposé » reste au conditionnel ; les rivaux aperçus avant une mort ne sont pas
   les tueurs.
4. Humour bienveillant : on taquine les personnages et leurs exploits ou déboires en jeu, jamais
   les joueurs réels (physique, vie privée, origine, etc.). Pas d'insulte ni de contenu choquant.
5. Chaque article cite dans « refs » les numéros des faits qu'il utilise (au moins un).
6. Titre : 80 caractères au plus. Corps : 1200 caractères au plus, texte brut sans Markdown,
   sauf des intertitres : une ligne qui commence par « ## ».
7. Varie les formats (Une, Brève, Nécrologie, Chronique PvP, Carnet mondain…). Ce numéro a
   {tone_count} chroniqueurs, chacun avec son ton :
{tones}
   Confie chaque article au chroniqueur qui lui va le mieux, chacun au moins une fois, et
   écris son nom dans « style » (il s'affiche comme signature ; le format, lui, est la
   rubrique). Tiens le ton d'un bout à l'autre de l'article, naturellement, sans forcer : ce
   sont des voix, pas des parodies appuyées. Un même chroniqueur ne répète pas ses tournures
   d'un article à l'autre (ouverture, formule, chute).
   Ce numéro a aussi une rubrique décalée, « {rubric} » : {rubric_desc}. Écris-y un seul
   article, si les faits s'y prêtent : son format est « {rubric} », et son « style » est un
   nom de métier adapté à la rubrique (« notre critique », « notre analyste »…), pas un
   des chroniqueurs.
8. L'ordre des articles compte : le premier fait la une. Un fait « AFFRONTEMENT MAJEUR » mérite
   un article à lui seul (la une, sauf événement plus marquant) ; une « Escarmouche », une brève.
   Un « champ de bataille » est un match organisé par le jeu (équipes et adversaires tirés au
   sort), pas une bataille du front : raconte-le à part, en chronique sportive (match, équipe,
   temps de jeu), jamais mêlé aux affrontements ni en récit de guerre contre la faction
   adverse. Ses morts ne sont pas un score : nos victoires n'y sont pas relevées.
9. Facultatif, pour la mise en page : « exergue » = une phrase courte (120 caractères au plus)
   recopiée MOT POUR MOT du corps de l'article ; « portrait » = le nom d'UN personnage nommé
   dans l'article, si l'article tourne autour de lui.
10. Choisis la maquette de l'édition parmi : {templates}.
11. Tu n'es pas obligé d'utiliser tous les faits : garde les plus marquants ou les plus drôles.
    Les « petites statistiques » (sauts, cuites, émotes…) sont un vivier de gags et de brèves.
12. Les faits RECORD, JALON, PALMARÈS, DUO et ANNIVERSAIRE sont calculés sur le journal
    Renatus (depuis que chacun a installé l'addon), pas sur toute la vie des personnages :
    présente-les comme des records « de la gazette » ou « depuis nos archives », jamais
    comme des records absolus.
    Un fait qui regroupe plusieurs événements (quêtes, rivaux croisés, créatures abattues)
    porte la date du dernier ; « entre … et … » donne sa durée réelle : jamais « d'un coup ».
13. Varie d'un numéro à l'autre. Si les titres des numéros précédents figurent plus bas, ils
    servent de mémoire de la rédaction : fais suivre un feuilleton, rappelle un gag récurrent,
    note un retour. Mais ne reprends pas leurs titres ni leurs angles, et ne t'en sers jamais
    comme source : seuls les faits numérotés font foi, et les refs ne citent que des faits
    numérotés.
14. Équilibre le numéro entre les membres : celui qui a le plus joué peut avoir un peu plus
    de place, mais au plus 40 % des articles (2 sur 5, 4 sur 10) tournent autour d'un même
    personnage. Ses autres exploits peuvent se regrouper dans une brève ou un article
    collectif ; préfère mettre en avant d'autres membres présents dans les faits, même pour
    un fait plus modeste.
{guild_line}{sex_line}
Réponds par un unique objet JSON, sans texte autour :
{\"maquette\": \"...\", \"articles\": [{\"title\": \"...\", \"format\": \"...\", \"style\": \"...\", \"body\": \"...\", \"refs\": [\"F1\", \"F4\"], \"exergue\": \"...\", \"portrait\": \"...\"}]}

{past}Faits retenus pour cette édition :
{facts}
";

/// Placeholders a prompt template may use; `{facts}` is required (see `check_template`).
pub const PLACEHOLDERS: &[&str] = &[
    "{facts}",
    "{start}",
    "{end}",
    "{max_articles}",
    "{tones}",
    "{tone_count}",
    "{rubric}",
    "{rubric_desc}",
    "{templates}",
    "{guild_line}",
    "{sex_line}",
    "{past}",
];

/// A prompt without the facts would let the AI write about nothing real.
pub fn check_template(template: &str) -> Result<(), String> {
    if template.contains("{facts}") {
        Ok(())
    } else {
        Err("Le prompt doit contenir {facts} (la liste des faits numérotés).".into())
    }
}

pub fn prompt(brief: &Brief, max_articles: usize) -> String {
    prompt_in(PROMPT, brief, max_articles)
}

/// `prompt` from another template (the settings' custom prompt).
pub fn prompt_in(template: &str, brief: &Brief, max_articles: usize) -> String {
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(1);
    prompt_with(
        template,
        brief,
        max_articles,
        &draw_tones(seed),
        draw_rubric(seed),
    )
}

pub fn prompt_with(
    template: &str,
    brief: &Brief,
    max_articles: usize,
    tones: &[(&str, &str)],
    (rubric, rubric_desc): (&str, &str),
) -> String {
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
    // Only the members these facts name: their sex, so that the French agrees.
    let sexes: Vec<String> = brief
        .sexes
        .iter()
        .filter(|(n, _)| {
            let name = Names::new([*n]);
            brief.facts.iter().any(|f| name.find(&f.text).is_some())
        })
        .map(|(n, s)| format!("{n} ({s})"))
        .collect();
    let sex_line = if sexes.is_empty() {
        String::new()
    } else {
        format!(
            "Personnages de la guilde, pour accorder le genre (« elle », « arrivée », « la championne ») : {}.\n",
            sexes.join(", ")
        )
    };
    let past = if brief.past.is_empty() {
        String::new()
    } else {
        // Titles only: whole articles made the AI copy their voice, issue after issue.
        let mut text = String::from(
            "Titres des numéros précédents (déjà publiés, pour mémoire seulement — pas des sources) :\n",
        );
        for issue in &brief.past {
            text += &format!("\nNuméro du {} :\n", date(issue.when));
            for (title, _) in &issue.articles {
                text += &format!("- {title}\n");
            }
        }
        text + "\n"
    };
    let templates: Vec<String> = crate::edition::TEMPLATES
        .iter()
        .map(|(n, d)| format!("« {n} » ({d})"))
        .collect();
    template
        .replace("{max_articles}", &max_articles.to_string())
        .replace("{tone_count}", &tones.len().to_string())
        .replace("{rubric}", rubric)
        .replace("{rubric_desc}", rubric_desc)
        .replace(
            "{tones}",
            &tones
                .iter()
                .map(|(n, d)| format!("   - « {n} » : {d}"))
                .collect::<Vec<_>>()
                .join("\n"),
        )
        .replace("{templates}", &templates.join(", "))
        .replace("{start}", &date(brief.since))
        .replace("{end}", &date(brief.until))
        .replace("{guild_line}", &guild_line)
        .replace("{sex_line}", &sex_line)
        .replace("{past}", &past)
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

/// Layout template the AI asked for ("maquette"), if any (checked by edition::choose).
pub fn requested_template(answer: &str) -> Option<String> {
    extract_json(answer)
        .ok()?
        .get("maquette")
        .and_then(Value::as_str)
        .map(|t| t.trim().to_lowercase())
}

fn squash(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub const MAX_QUOTE: usize = 140;

/// AI answer -> (Press.lua items, problems). A dubious article is rejected; a dubious
/// pull quote or portrait is only dropped (the article stands without it).
pub fn check(
    brief: &Brief,
    answer: &str,
    edition: &str,
    max_articles: usize,
) -> (Vec<Value>, Vec<String>) {
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
    for (n, a) in arts.iter().take(max_articles).enumerate() {
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
        // Pull quote: verbatim from the body, or nothing (never an invented quotation).
        let quote = squash(text_of(a, "exergue").trim_matches(|c: char| "«»\"“” ".contains(c)));
        let quote = if quote.is_empty() {
            None
        } else if quote.chars().count() > MAX_QUOTE || !squash(&body).contains(&quote) {
            notes.push(format!(
                "{label} : exergue absent du texte ou trop long — ignoré"
            ));
            None
        } else {
            Some(quote)
        };
        // Portrait: a consenting member, named in the article.
        let portrait = text_of(a, "portrait");
        let portrait = if portrait.is_empty() {
            None
        } else {
            let known = brief
                .allowed
                .iter()
                .find(|n| n.to_lowercase() == portrait.to_lowercase());
            match known {
                Some(n) if Names::new([n]).find(&format!("{title}\n{body}")).is_some() => {
                    Some(n.clone())
                }
                _ => {
                    notes.push(format!(
                        "{label} : portrait de « {portrait} » refusé (pas nommé dans l'article ou sans consentement)"
                    ));
                    None
                }
            }
        };
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
        let mut p = json!({"title": title, "body": body, "format": format, "style": style, "ia": true,
            "edition": edition, "key": digest, "order": items.len() + 1});
        if let Some(q) = quote {
            p["quote"] = json!(q);
        }
        if let Some(n) = portrait {
            p["portrait"] = json!(n);
        }
        items.push(json!({
            "id": format!("ia:{edition}:{digest}"), "kind": "ARTICLE", "refs": event_ids, "p": p,
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
    fn each_issue_draws_distinct_tones() {
        for seed in 0..200u64 {
            let tones = draw_tones(seed);
            assert_eq!(tones.len(), TONES_PER_ISSUE);
            let names: BTreeSet<_> = tones.iter().map(|(n, _)| n).collect();
            assert_eq!(names.len(), TONES_PER_ISSUE, "seed {seed}");
        }
        let all: BTreeSet<_> = (0..200u64).flat_map(draw_tones).map(|(n, _)| n).collect();
        assert_eq!(all.len(), TONES.len(), "every tone can come up");
        let brief = build(&chronicle(), 0.0, 2000.0);
        let rubrics: BTreeSet<_> = (0..200u64).map(|s| draw_rubric(s).0).collect();
        assert_eq!(rubrics.len(), RUBRICS.len(), "every rubric can come up");
        let p = prompt_with(PROMPT, &brief, MAX_ARTICLES, &draw_tones(7), draw_rubric(7));
        for (n, d) in draw_tones(7) {
            assert!(p.contains(&format!("« {n} » : {d}")), "{p}");
        }
        let (r, d) = draw_rubric(7);
        assert!(p.contains(&format!("« {r} » : {d}")), "{p}");
        assert!(!p.contains("{tones}") && !p.contains("{tone_count}") && !p.contains("{rubric"));
    }

    #[test]
    fn facts_respect_consent_and_alias_rivals() {
        let brief = build(&chronicle(), 0.0, 2000.0);
        let texts: Vec<&str> = brief.facts.iter().map(|f| f.text.as_str()).collect();
        assert_eq!(texts.len(), 3, "{texts:#?}");
        assert!(texts[0].ends_with("Alice atteint le niveau 20"));
        assert!(texts[1].contains(
            "a croisé 1 fois des membres de la guilde rivale Les Crocs : Gorbash (voleur Orc, guilde rivale)"
        ));
        assert!(
            texts[2].contains("Alice tombe face à Gorbash (voleur Orc, guilde rivale)"),
            "{texts:#?}"
        );
        assert!(brief.forbidden.contains("Bob") && !brief.forbidden.contains("Gorbash"));
        assert_eq!(brief.rival_guild.as_deref(), Some("Les Crocs"));
        let reasons: BTreeMap<_, _> = brief.excluded.iter().cloned().collect();
        assert_eq!(reasons["auteur sans consentement"], 1);
        assert_eq!(
            reasons["nomme un membre sans consentement"], 1,
            "anecdote naming Bob"
        );
        let p = prompt(&brief, MAX_ARTICLES);
        assert!(p.contains("F2. ") && p.contains("« Les Crocs »") && p.contains("Gorbash"));
        assert!(p.contains("Équilibre le numéro entre les membres"));
    }

    #[test]
    fn answer_check_rejects_invented_sources_and_forbidden_names() {
        let brief = build(&chronicle(), 0.0, 2000.0);
        let answer = r#"Voici : {"articles": [
            {"title": "Alice grimpe", "body": "Niveau 20 !", "refs": ["F1"], "format": "Brève"},
            {"title": "Inventé", "body": "x", "refs": ["F9"]},
            {"title": "Gorbash frappe", "body": "y", "refs": ["F2"]},
            {"title": "Bob frappe", "body": "z", "refs": ["F2"]},
            {"title": "Bobby", "body": "Bobby n'est pas Bob-le-Rouge", "refs": ["F2"]}
        ]}"#;
        let (items, notes) = check(&brief, answer, "2026-11-20-2147", MAX_ARTICLES);
        // enemies may be named, a member without consent may not
        assert_eq!(items.len(), 3, "{notes:?}");
        assert_eq!(items[0]["refs"], json!(["A:2"]));
        assert_eq!(items[0]["p"]["ia"], true);
        assert!(items[0]["id"]
            .as_str()
            .unwrap()
            .starts_with("ia:2026-11-20-2147:"));
        assert!(notes[0].contains("F9"));
        assert!(notes[1].contains("« Bob »"), "{notes:?}");
        assert!(check(&brief, "pas de json", "x", MAX_ARTICLES).1[0].contains("illisible"));
    }

    #[test]
    fn quotes_must_be_verbatim_and_portraits_consented() {
        let brief = build(&chronicle(), 0.0, 2000.0);
        let answer = r#"{"maquette": " Grande_Une ", "articles": [
            {"title": "Alice grimpe", "body": "Alice atteint le niveau 20.\nLa  montagne tremble.", "refs": ["F1"],
             "exergue": "« La montagne tremble. »", "portrait": "alice"},
            {"title": "Encore Alice", "body": "Alice monte.", "refs": ["F1"],
             "exergue": "Une phrase inventée", "portrait": "Bob"}
        ]}"#;
        let (items, notes) = check(&brief, answer, "E", MAX_ARTICLES);
        assert_eq!(items.len(), 2, "{notes:?}");
        let p = &items[0]["p"];
        assert_eq!(p["quote"], "La montagne tremble.");
        assert_eq!(p["portrait"], "Alice");
        assert_eq!(p["order"], 1);
        assert_eq!(items[1]["p"]["order"], 2);
        assert!(items[0]["p"]["key"].as_str().is_some());
        assert!(items[1]["p"].get("quote").is_none() && items[1]["p"].get("portrait").is_none());
        assert_eq!(notes.len(), 2, "{notes:?}");
        assert_eq!(requested_template(answer).as_deref(), Some("grande_une"));
        assert!(prompt(&brief, MAX_ARTICLES).contains("« portrait »"));
    }

    #[test]
    fn enemies_are_named_with_their_guild() {
        let mut ch = chronicle();
        let (k, v) = ev(
            "A:20",
            "A",
            "Alice",
            "PVP_KILL",
            1500,
            json!({"name": "Décimeur", "guild": "Les Cousins Maudits", "class": "HUNTER", "race": "Tauren"}),
        );
        ch.events.insert(k, v);
        let (k, v) = ev(
            "A:21",
            "A",
            "Alice",
            "PVP_KILL",
            1600,
            json!({"name": "Gorbash", "guild": "Les Crocs"}),
        );
        ch.events.insert(k, v);
        let brief = build(&ch, 0.0, 2000.0);
        let all: String = brief
            .facts
            .iter()
            .map(|f| f.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            all.contains("Décimeur (chasseur Tauren, <Les Cousins Maudits>)"),
            "{all}"
        );
        assert!(all.contains("Gorbash (voleur Orc, guilde rivale)"), "{all}");
        assert!(all.contains("ennemis impliqués"), "{all}");
        assert!(!brief.forbidden.contains("Décimeur"));
    }

    #[test]
    fn prompt_gives_the_sex_of_named_members() {
        let mut ch = chronicle();
        let (k, v) = ev("A:40", "A", "Alice", "CARD_PROFILE", 100, json!({"sex": 3}));
        ch.events.insert(k, v);
        let brief = build(&ch, 0.0, 2000.0);
        assert_eq!(brief.sexes.get("Alice"), Some(&"femme"));
        let p = prompt(&brief, MAX_ARTICLES);
        assert!(
            p.contains("pour accorder le genre") && p.contains("Alice (femme)"),
            "{p}"
        );
        // nobody named in the facts: no line
        let none = brief.select(&[]);
        assert!(!prompt(&none, MAX_ARTICLES).contains("accorder le genre"));
    }

    #[test]
    fn wanted_poster_keeps_its_reward() {
        let mut ch = chronicle();
        let (k, v) = ev(
            "A:30",
            "A",
            "Alice",
            "WANTED",
            1500,
            json!({"name": "Décimeur", "nickname": "le Boucher", "reason": "camping",
                   "reward": "100 pièces de vantardise"}),
        );
        ch.events.insert(k, v);
        let brief = build(&ch, 0.0, 2000.0);
        let fact = brief
            .facts
            .iter()
            .find(|f| f.text.contains("avis de recherche"))
            .expect("wanted fact");
        assert!(fact.text.contains("« le Boucher »"), "{}", fact.text);
        assert!(fact.text.contains("motif : camping"), "{}", fact.text);
        assert!(
            fact.text
                .contains("prime offerte : 100 pièces de vantardise"),
            "{}",
            fact.text
        );
    }

    #[test]
    fn fights_close_in_time_become_one_affrontement() {
        let mut ch = chronicle();
        let kill = |id: &str, t: i64, p: Value| ev(id, "A", "Alice", "PVP_KILL", t, p);
        let orc = json!({"race": "Orc", "class": "WARRIOR", "level": 25});
        for (id, t, p) in [
            (
                "A:10",
                5000,
                json!({"name": "Gorbash", "guild": "Les Crocs"}),
            ),
            ("A:11", 5300, orc.clone()),
            ("A:12", 5600, orc.clone()),
            ("A:13", 6000, orc.clone()),
            ("A:14", 6200, orc.clone()),
            // more than 30 min later: told on its own
            ("A:15", 9000, orc.clone()),
        ] {
            let (k, v) = kill(id, t, p);
            ch.events.insert(k, v);
        }
        let (k, v) = ev(
            "A:16",
            "A",
            "Alice",
            "PVP_CLASH",
            6100,
            json!({"name": "Gorbash", "result": "loss"}),
        );
        ch.events.insert(k, v);
        let brief = build(&ch, 4000.0, 10000.0);
        let texts: Vec<&str> = brief.facts.iter().map(|f| f.text.as_str()).collect();
        assert_eq!(texts.len(), 2, "{texts:#?}");
        let big = brief
            .facts
            .iter()
            .find(|f| f.text.contains("AFFRONTEMENT MAJEUR"))
            .expect("regroupé");
        assert!(
            big.text.contains("5 victoire(s)") && big.text.contains("1 mort(s)"),
            "{}",
            big.text
        );
        assert!(
            big.text.contains("Gorbash (voleur Orc, guilde rivale)"),
            "{}",
            big.text
        );
        assert!(
            big.text.contains("un Orc guerrier de niveau 25"),
            "{}",
            big.text
        );
        assert_eq!(big.refs.len(), 6);
        assert!(texts.iter().any(|t| t
            .ends_with("Alice remporte une victoire honorable sur un Orc guerrier de niveau 25")));
        assert!(prompt(&brief, MAX_ARTICLES).contains("AFFRONTEMENT MAJEUR"));
    }

    #[test]
    fn battleground_deaths_are_a_match_not_a_fight() {
        let mut ch = chronicle();
        let av = json!({"z": "Vallée d'Alterac", "i": "Vallée d'Alterac", "it": "pvp"});
        let mut add = |id: String, k: &str, t: i64, p: Value| {
            let (key, mut v) = ev(&id, "A", "Alice", k, t, p);
            v["loc"] = av.clone();
            ch.events.insert(key, v);
        };
        // ten deaths with enemies around: would be an affrontement and a milestone on the front
        for i in 0..10 {
            add(
                format!("A:{}", 20 + i),
                "DEATH",
                5000 + 60 * i,
                json!({"lvl": 59, "enemies": ["Gorbash"]}),
            );
        }
        add("A:40".into(), "PVP_KILL", 5100, json!({"name": "Gorbash"}));
        add(
            "A:41".into(),
            "ENEMY_SEEN",
            5200,
            json!({"name": "Gorbash", "guild": "Les Crocs"}),
        );
        let brief = build(&ch, 4000.0, 10000.0);
        let texts: Vec<&str> = brief.facts.iter().map(|f| f.text.as_str()).collect();
        assert_eq!(texts.len(), 1, "{texts:#?}");
        assert!(
            texts[0].ends_with("champ de bataille Vallée d'Alterac (match organisé par le jeu, pas un affrontement du front) — bilan de Alice : 10 mort(s), 1 victoire(s) honorable(s)"),
            "{}",
            texts[0]
        );
        assert_eq!(brief.facts[0].refs.len(), 10);
        let reasons: BTreeMap<_, _> = brief.excluded.iter().cloned().collect();
        assert_eq!(reasons.get("champ de bataille ou arène"), Some(&1));
        assert!(prompt(&brief, MAX_ARTICLES).contains("chronique sportive"));
    }

    #[test]
    fn trivia_bestiary_duplicates_and_past_issues() {
        let mut ch = chronicle();
        let mut add = |(id, e): (String, Value)| {
            ch.events.insert(id, e);
        };
        add(ev(
            "A:10",
            "A",
            "Alice",
            "MOB_KILL",
            1010,
            json!({"name": "Loup", "cls": "normal", "lvl": 5}),
        ));
        add(ev(
            "A:11",
            "A",
            "Alice",
            "MOB_KILL",
            1011,
            json!({"name": "Ours rare", "cls": "rare", "lvl": 3}),
        ));
        add(ev(
            "A:12",
            "A",
            "Alice",
            "COUNTERS",
            1012,
            json!({"from": 900, "jumps": 412, "drunk": 2, "earned": 123456,
                "emotes": [{"e": "SLAP", "to": "Bob", "n": 3}, {"e": "KISS", "to": "Alice", "n": 1}]}),
        ));
        // the same duel, recorded by both duellists (Carl consents too)
        add(ev(
            "C:1",
            "C",
            "Carl",
            "AI_CONSENT",
            100,
            json!({"ok": true}),
        ));
        let mut d1 = ev(
            "A:13",
            "A",
            "Alice",
            "DUEL",
            1013,
            json!({"winner": "Alice", "loser": "Carl"}),
        );
        d1.1["occ"] = json!("DUEL:Alice:Carl:1");
        let mut d2 = ev(
            "C:2",
            "C",
            "Carl",
            "DUEL",
            1013,
            json!({"winner": "Alice", "loser": "Carl"}),
        );
        d2.1["occ"] = json!("DUEL:Alice:Carl:1");
        add(d1);
        add(d2);
        // a published issue
        let mut art = ev(
            "A:14",
            "A",
            "Alice",
            "ARTICLE",
            500,
            json!({"title": "Le lac", "body": "Alice nage.", "edition": "E1"}),
        );
        art.1["refs"] = json!(["A:2"]);
        add(art);
        let mut shy = ev(
            "A:15",
            "A",
            "Alice",
            "ARTICLE",
            501,
            json!({"title": "Bob", "body": "Bob nage.", "edition": "E1"}),
        );
        shy.1["refs"] = json!(["A:2"]);
        add(shy);
        let brief = build(&ch, 900.0, 2000.0);
        let texts: Vec<&str> = brief.facts.iter().map(|f| f.text.as_str()).collect();
        let find = |needle: &str| texts.iter().find(|t| t.contains(needle)).copied();
        let bestiary = find("abat pour la première fois").expect("bestiary");
        assert!(
            bestiary.ends_with("2 espèce(s) de créatures, dont : Ours rare (rare), Loup"),
            "{bestiary}"
        );
        let stats = find("petites statistiques").expect("counters");
        assert!(
            stats.contains("412 sauts, 2 cuites, 12 po 34 pa gagnés"),
            "{stats}"
        );
        assert!(
            stats.contains("Alice a embrassé Alice") && !stats.contains("Bob"),
            "{stats}"
        );
        let duels: Vec<&Fact> = brief
            .facts
            .iter()
            .filter(|f| f.text.contains("en duel"))
            .collect();
        assert_eq!(duels.len(), 1, "one fact for both records");
        assert_eq!(duels[0].refs, ["A:13", "C:2"]);
        assert_eq!(brief.past.len(), 1);
        assert_eq!(
            brief.past[0].articles,
            [("Le lac".to_string(), "Alice nage.".to_string())]
        );
        let p = prompt(&brief, MAX_ARTICLES);
        assert!(p.contains("Numéro du ") && p.contains("- Le lac\n"), "{p}");
        assert!(!p.contains("Alice nage"), "titles only: {p}");
        assert!(!p.contains("Bob nage"));
        assert!(p.find("numéros précédents") < p.find("Faits retenus"));
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
