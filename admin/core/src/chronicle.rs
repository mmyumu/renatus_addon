//! The Renatus journal as read from the SavedVariables, and merging it with combat logs.
//!
//! Rules (docs/ARCHITECTURE.md §8.2):
//!   - a combat log death ENRICHES the death recorded by the addon (same character,
//!     same moment within a few seconds): a death that does not exist is never created;
//!   - the clock offset between the PC and the server is estimated from deaths present
//!     on both sides (median), then matching is done within +/- 5 s;
//!   - PvP clashes: only against characters already known to the registry and
//!     involving known guild members.
//!
//! Everything produced here is a PROPOSAL: the editor approves it in game.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde_json::{json, Map, Value};

use crate::combatlog::{Analysis, Death};

const ANCHOR_WINDOW: f64 = 300.0;
const MATCH_WINDOW: f64 = 5.0;

/// Minimal view of the Renatus SavedVariables.
#[derive(Debug, Clone, Default)]
pub struct Chronicle {
    pub events: Map<String, Value>,
    pub press_done: Map<String, Value>,
}

pub fn str_of<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

pub fn num_of(v: &Value, key: &str) -> f64 {
    v.get(key).and_then(Value::as_f64).unwrap_or(0.0)
}

pub fn payload(e: &Value) -> &Value {
    static EMPTY: Value = Value::Null;
    e.get("p").unwrap_or(&EMPTY)
}

impl Chronicle {
    pub fn from_saved(saved: &Map<String, Value>) -> Self {
        let db = saved.get("RenatusDB").cloned().unwrap_or(Value::Null);
        let events = match db.get("events") {
            Some(Value::Object(m)) => m.clone(),
            Some(Value::Array(list)) => list
                .iter()
                .filter_map(|e| Some((str_of(e, "id")?.to_string(), e.clone())))
                .collect(),
            _ => Map::new(),
        };
        let press_done = match db.get("pressDone") {
            Some(Value::Object(m)) => m.clone(),
            _ => Map::new(),
        };
        Self { events, press_done }
    }

    pub fn load(path: &std::path::Path) -> Result<Self, String> {
        Ok(Self::from_saved(&crate::lua::load(path)?))
    }

    /// Events still standing: a deleted one (tombstone, `del`) is only an empty shell kept
    /// for the sync.
    pub fn all(&self) -> impl Iterator<Item = &Value> {
        self.events
            .values()
            .filter(|e| e.is_object() && e.get("del").is_none())
    }

    pub fn of_kind<'a>(&'a self, kind: &'a str) -> impl Iterator<Item = &'a Value> + 'a {
        self.all().filter(move |e| str_of(e, "k") == Some(kind))
    }

    /// GUID -> name of known authors (members who have the addon).
    pub fn members(&self) -> BTreeMap<String, String> {
        self.all()
            .filter_map(|e| {
                Some((
                    str_of(e, "a")?.to_string(),
                    str_of(e, "n").unwrap_or("?").to_string(),
                ))
            })
            .collect()
    }

    /// Lowercase names of enemies known to the registry.
    pub fn known_enemies(&self) -> BTreeSet<String> {
        let mut names = BTreeSet::new();
        for kind in ["ENEMY_SEEN", "ENEMY_NOTE", "WANTED", "PVP_CLASH"] {
            for e in self.of_kind(kind) {
                if let Some(n) = str_of(payload(e), "name").filter(|n| !n.is_empty()) {
                    names.insert(n.to_lowercase());
                }
            }
        }
        names
    }

    pub fn enriched_deaths(&self) -> BTreeSet<String> {
        self.of_kind("DEATH_CAUSE")
            .flat_map(|e| {
                e.get("refs")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default()
            })
            .filter_map(|r| r.as_str().map(str::to_string))
            .collect()
    }

    /// Rival guild of the most recent GUILD_CONFIG (the addon also checks the author's rank).
    pub fn configured_rival(&self) -> Option<String> {
        self.of_kind("GUILD_CONFIG")
            .filter(|e| str_of(e, "vis") == Some("G") && e.get("del").is_none())
            .max_by(|a, b| num_of(a, "t").total_cmp(&num_of(b, "t")))
            .and_then(|e| str_of(payload(e), "rival").map(str::to_string))
    }

    /// Most recent armory roster published for `guild` (the addon also checks the author's rank).
    pub fn latest_roster(&self, guild: &str) -> Option<&Value> {
        let guild = guild.to_lowercase();
        self.of_kind("RIVAL_ROSTER")
            .filter(|e| str_of(e, "vis") == Some("G") && e.get("del").is_none())
            .filter(|e| str_of(payload(e), "guild").map(str::to_lowercase) == Some(guild.clone()))
            .max_by(|a, b| {
                let at = |e: &Value| num_of(payload(e), "at").max(num_of(e, "t"));
                at(a).total_cmp(&at(b))
            })
    }

    /// Wanted posters still open: lowercase enemy name -> displayed name.
    pub fn wanted(&self) -> BTreeMap<String, String> {
        let mut last: HashMap<String, (f64, bool, String)> = HashMap::new();
        for kind in ["WANTED", "WANTED_CLOSE"] {
            for e in self.of_kind(kind) {
                let Some(name) = str_of(payload(e), "name") else {
                    continue;
                };
                let t = num_of(e, "t");
                let key = name.to_lowercase();
                if last.get(&key).is_none_or(|(lt, _, _)| t >= *lt) {
                    last.insert(key, (t, kind == "WANTED", name.to_string()));
                }
            }
        }
        last.into_iter()
            .filter(|(_, (_, open, _))| *open)
            .map(|(k, (_, _, name))| (k, name))
            .collect()
    }

    /// Public events of the guild most events belong to.
    pub fn main_guild(&self) -> Option<String> {
        // Keys of the same guild (see same_guild) count together; the full key wins.
        let mut counts: BTreeMap<&str, (usize, &str)> = BTreeMap::new();
        for e in self.all() {
            if str_of(e, "vis") == Some("G") {
                if let Some(g) = str_of(e, "g") {
                    let entry = counts.entry(guild_name(g)).or_insert((0, g));
                    entry.0 += 1;
                    if entry.1.ends_with('-') {
                        entry.1 = g;
                    }
                }
            }
        }
        counts
            .into_values()
            .max_by_key(|(n, _)| *n)
            .map(|(_, g)| g.to_string())
    }
}

fn guild_name(key: &str) -> &str {
    key.split_once('-').map_or(key, |(name, _)| name)
}

/// Do two guild keys ("Name-Realm") designate the same guild? Same name, and same realm
/// or one without realm: the game sometimes gives an empty realm (WoW Forever,
/// 2026-11-20), and the addon then wrote "Name-". Guild names cannot contain "-".
pub fn same_guild(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    match (a.split_once('-'), b.split_once('-')) {
        (Some((na, ra)), Some((nb, rb))) => na == nb && (ra.is_empty() || rb.is_empty()),
        _ => false,
    }
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    let n = v.len();
    if n % 2 == 1 {
        v[n / 2]
    } else {
        (v[n / 2 - 1] + v[n / 2]) / 2.0
    }
}

/// Offset (server - PC) in seconds, from deaths present on both sides.
pub fn estimate_offset(deaths: &[Death], ch: &Chronicle) -> Option<f64> {
    let mut by_author: HashMap<&str, Vec<f64>> = HashMap::new();
    for e in ch.of_kind("DEATH") {
        by_author
            .entry(str_of(e, "a").unwrap_or(""))
            .or_default()
            .push(num_of(e, "t"));
    }
    let diffs: Vec<f64> = deaths
        .iter()
        .filter_map(|d| {
            let best = by_author
                .get(d.guid.as_str())?
                .iter()
                .copied()
                .min_by(|a, b| (a - d.ts).abs().total_cmp(&(b - d.ts).abs()))?;
            ((best - d.ts).abs() <= ANCHOR_WINDOW).then_some(best - d.ts)
        })
        .collect();
    (!diffs.is_empty()).then(|| median(diffs))
}

fn compact(map: Map<String, Value>) -> Value {
    Value::Object(
        map.into_iter()
            .filter(|(_, v)| !v.is_null() && v.as_str() != Some(""))
            .collect(),
    )
}

/// Combat log analysis -> (Press.lua items, warnings).
pub fn propose(analysis: &Analysis, ch: &Chronicle) -> (Vec<Value>, Vec<String>) {
    let mut items = Vec::new();
    let mut notes = Vec::new();
    let offset = match estimate_offset(&analysis.deaths, ch) {
        None => {
            notes.push("Aucune mort commune entre le journal de combat et l'addon : pas de recalage possible.".into());
            0.0
        }
        Some(o) => {
            if o.abs() > 2.0 {
                notes.push(format!("Décalage d'horloge estimé : {o:+.1} s (corrigé)."));
            }
            o
        }
    };

    let mut deaths_by_author: HashMap<&str, Vec<&Value>> = HashMap::new();
    for e in ch.of_kind("DEATH") {
        deaths_by_author
            .entry(str_of(e, "a").unwrap_or(""))
            .or_default()
            .push(e);
    }
    let already = ch.enriched_deaths();
    let enemies = ch.known_enemies();
    let members = ch.members();
    let mut used: BTreeSet<String> = BTreeSet::new();

    for d in &analysis.deaths {
        let t = d.ts + offset;
        let matched = deaths_by_author
            .get(d.guid.as_str())
            .into_iter()
            .flatten()
            .filter(|e| (num_of(e, "t") - t).abs() <= MATCH_WINDOW)
            .min_by(|a, b| {
                (num_of(a, "t") - t)
                    .abs()
                    .total_cmp(&(num_of(b, "t") - t).abs())
            });
        // death unknown to the addon (private, or member without the addon): invent nothing
        let Some(m) = matched else { continue };
        let Some(id) = str_of(m, "id") else { continue };
        if already.contains(id) || !used.insert(id.to_string()) {
            continue;
        }
        let mt = num_of(m, "t") as i64;
        let victim = str_of(m, "n").unwrap_or(&d.name).to_string();
        let killer = d.killer.clone().or_else(|| d.source.clone());
        let mut p = Map::new();
        p.insert("victim".into(), json!(victim));
        p.insert("cause".into(), json!(d.cause()));
        p.insert("killer".into(), json!(killer));
        p.insert("spell".into(), json!(d.spell));
        p.insert("env".into(), json!(d.environment));
        items.push(json!({"id": format!("dc:{id}"), "kind": "DEATH_CAUSE", "t": mt, "refs": [id], "p": compact(p)}));
        let who = killer.clone().unwrap_or_default();
        if d.by_player() && enemies.contains(&who.to_lowercase()) {
            let mut p = Map::new();
            p.insert("name".into(), json!(who));
            p.insert("enemy".into(), json!(who));
            p.insert("result".into(), json!("loss"));
            p.insert("member".into(), json!(victim));
            p.insert("spell".into(), json!(d.spell));
            items.push(json!({"id": format!("pl:{id}"), "kind": "PVP_CLASH", "t": mt, "refs": [id], "p": compact(p)}));
        }
    }

    for k in &analysis.kills {
        if let Some(member) = members.get(&k.killer_guid) {
            if enemies.contains(&k.victim.to_lowercase()) {
                let t = (k.ts + offset) as i64;
                items.push(json!({
                    "id": format!("pw:{}:{t}", k.killer_guid), "kind": "PVP_CLASH", "t": t,
                    "p": {"name": k.victim, "enemy": k.victim, "result": "win", "member": member},
                }));
            }
        }
    }
    (items, notes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::combatlog::Kill;

    fn chronicle() -> Chronicle {
        let saved = crate::lua::loads(
            r#"RenatusDB = {
                ["events"] = {
                    ["Player-1-A:1"] = { ["id"] = "Player-1-A:1", ["a"] = "Player-1-A", ["n"] = "Testeur", ["k"] = "DEATH", ["t"] = 1010, ["vis"] = "G", ["g"] = "G-F", ["p"] = {} },
                    ["Player-1-A:2"] = { ["id"] = "Player-1-A:2", ["a"] = "Player-1-A", ["n"] = "Testeur", ["k"] = "ENEMY_SEEN", ["t"] = 900, ["vis"] = "G", ["g"] = "G-F", ["p"] = { ["name"] = "Gorbash" } },
                    ["Player-1-B:1"] = { ["id"] = "Player-1-B:1", ["a"] = "Player-1-B", ["n"] = "Bob", ["k"] = "GUILD_CONFIG", ["t"] = 800, ["vis"] = "G", ["p"] = { ["rival"] = "Les Crocs" } },
                    ["Player-1-B:2"] = { ["id"] = "Player-1-B:2", ["a"] = "Player-1-B", ["n"] = "Bob", ["k"] = "WANTED", ["t"] = 850, ["vis"] = "G", ["p"] = { ["name"] = "Gorbash" } },
                    ["Player-1-B:3"] = { ["id"] = "Player-1-B:3", ["a"] = "Player-1-B", ["n"] = "Bob", ["k"] = "RIVAL_ROSTER", ["t"] = 700, ["vis"] = "G", ["p"] = { ["guild"] = "Les Crocs", ["at"] = 600, ["members"] = {} } },
                    ["Player-1-B:4"] = { ["id"] = "Player-1-B:4", ["a"] = "Player-1-B", ["n"] = "Bob", ["k"] = "RIVAL_ROSTER", ["t"] = 750, ["vis"] = "G", ["p"] = { ["guild"] = "Les Crocs", ["at"] = 740, ["members"] = {} } },
                },
                ["pressDone"] = { ["dc:old"] = "published" },
            }"#,
        )
        .unwrap();
        Chronicle::from_saved(&saved)
    }

    #[test]
    fn views() {
        let ch = chronicle();
        assert_eq!(ch.members().len(), 2);
        assert!(ch.known_enemies().contains("gorbash"));
        assert_eq!(ch.configured_rival().as_deref(), Some("Les Crocs"));
        assert_eq!(
            ch.latest_roster("les crocs").and_then(|e| str_of(e, "id")),
            Some("Player-1-B:4")
        );
        assert!(ch.latest_roster("Autre").is_none());
        assert_eq!(
            ch.wanted().get("gorbash").map(String::as_str),
            Some("Gorbash")
        );
        assert_eq!(ch.press_done.len(), 1);
        assert!(same_guild("Renatûs-", "Renatûs-Realm"));
        assert!(!same_guild("Renatûs-A", "Renatûs-B"));
        assert!(!same_guild("Autre-", "Renatûs-Realm"));
    }

    #[test]
    fn deaths_enrich_known_deaths_only_and_kills_on_known_enemies() {
        let ch = chronicle();
        let analysis = Analysis {
            deaths: vec![
                Death {
                    ts: 1000.0,
                    guid: "Player-1-A".into(),
                    name: "Testeur".into(),
                    killer: Some("Gorbash".into()),
                    killer_guid: Some("Player-9-Z".into()),
                    spell: Some("Frappe".into()),
                    ..Death::default()
                },
                Death {
                    ts: 5000.0,
                    guid: "Player-1-A".into(),
                    name: "Testeur".into(),
                    ..Death::default()
                },
            ],
            kills: vec![Kill {
                ts: 2000.0,
                killer: "Bob".into(),
                killer_guid: "Player-1-B".into(),
                victim: "Gorbash".into(),
                victim_guid: "Player-9-Z".into(),
            }],
            ..Analysis::default()
        };
        let (items, notes) = propose(&analysis, &ch);
        assert!(notes[0].contains("+10.0 s"), "{notes:?}");
        assert_eq!(items.len(), 3, "{items:#?}");
        assert_eq!(items[0]["id"], "dc:Player-1-A:1");
        assert_eq!(items[0]["p"]["cause"], "Gorbash (Frappe)");
        assert_eq!(items[1]["kind"], "PVP_CLASH");
        assert_eq!(items[1]["p"]["result"], "loss");
        assert_eq!(items[2]["p"]["result"], "win");
        assert_eq!(items[2]["t"], 2010);
    }
}
