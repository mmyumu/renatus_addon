//! The WoW Forever armory (armorywowforever.com): the rival guild's roster and
//! the profile of its members we already know in game.
//!
//! The site's own pages read a JSON API:
//!   - `/api/guild/forever/{region}/{server}/{slug}`
//!   - `/api/character/forever/{region}/{server}/{First-Last}`
//!
//! We stay polite: one guild request per refresh, character profiles only for
//! enemies already in the registry (at most `MAX_PROFILES`), one per second.

use std::collections::BTreeMap;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::articles::sha1_hex;

pub const SITE: &str = "https://armorywowforever.com";
pub const MAX_PROFILES: usize = 15;
/// Keeps the RIVAL_ROSTER event under the sync's 6000-byte limit.
pub const MAX_MEMBERS: usize = 80;
const USER_AGENT: &str = "renatus-admin";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuildRef {
    pub region: String,
    pub server: String,
    pub slug: String,
}

/// Armory slug of a guild name: "C'est Dieu qui pilote" -> "cest-dieu-qui-pilote".
pub fn slug(name: &str) -> String {
    name.trim()
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace() || *c == '-')
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("-")
}

impl GuildRef {
    /// From an armory link (`.../g/forever/eu/pvp/slug`) or a guild name (EU PvP realm).
    pub fn parse(input: &str) -> Option<Self> {
        let input = input.trim();
        if input.is_empty() {
            return None;
        }
        if let Some(pos) = input.find("/g/") {
            let parts: Vec<&str> = input[pos + 3..]
                .split(['/', '?', '#'])
                .filter(|p| !p.is_empty())
                .collect();
            if let [_flavor, region, server, slug, ..] = parts.as_slice() {
                return Some(Self {
                    region: region.to_lowercase(),
                    server: server.to_lowercase(),
                    slug: percent_decode(slug),
                });
            }
            return None;
        }
        let s = slug(input);
        (!s.is_empty()).then(|| Self {
            region: "eu".into(),
            server: "pvp".into(),
            slug: s,
        })
    }

    pub fn page_url(&self) -> String {
        format!(
            "{SITE}/g/forever/{}/{}/{}",
            self.region,
            self.server,
            encode(&self.slug)
        )
    }

    pub fn api_url(&self) -> String {
        format!(
            "{SITE}/api/guild/forever/{}/{}/{}",
            self.region,
            self.server,
            encode(&self.slug)
        )
    }

    pub fn character_api_url(&self, name: &str) -> String {
        let path = name.split_whitespace().collect::<Vec<_>>().join("-");
        format!(
            "{SITE}/api/character/forever/{}/{}/{}",
            self.region,
            self.server,
            encode(&path)
        )
    }
}

fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Some(v) = std::str::from_utf8(&b[i + 1..i + 3])
                .ok()
                .and_then(|h| u8::from_str_radix(h, 16).ok())
            {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Member {
    pub name: String,
    #[serde(default)]
    pub level: u32,
    #[serde(default)]
    pub class_id: u32,
    #[serde(default)]
    pub race_id: u32,
    #[serde(default)]
    pub rank: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Guild {
    pub name: String,
    #[serde(default)]
    pub faction_name: Option<String>,
    #[serde(default)]
    pub member_count: u32,
    #[serde(default)]
    pub race_names: BTreeMap<String, String>,
    #[serde(default)]
    pub members: Vec<Member>,
    /// Milliseconds.
    #[serde(default)]
    pub fetched_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Character {
    pub name: String,
    #[serde(default)]
    pub level: u32,
    #[serde(default)]
    pub race: Option<String>,
    #[serde(default)]
    pub class_id: u32,
    #[serde(default)]
    pub guild: Option<String>,
    /// Milliseconds.
    #[serde(default)]
    pub last_login: Option<i64>,
    #[serde(default)]
    pub average_ilvl: Option<f64>,
    #[serde(default)]
    pub gearscore: Option<f64>,
}

/// Class token, as the game's UnitClass returns it.
pub fn class_token(id: u32) -> &'static str {
    match id {
        1 => "WARRIOR",
        2 => "PALADIN",
        3 => "HUNTER",
        4 => "ROGUE",
        5 => "PRIEST",
        6 => "DEATHKNIGHT",
        7 => "SHAMAN",
        8 => "MAGE",
        9 => "WARLOCK",
        10 => "MONK",
        11 => "DRUID",
        12 => "DEMONHUNTER",
        13 => "EVOKER",
        _ => "",
    }
}

/// Race name as a French client shows it (the armory answers in English).
pub fn race_fr(name: &str) -> String {
    match name {
        "Human" => "Humain",
        "Orc" => "Orc",
        "Dwarf" => "Nain",
        "Night Elf" => "Elfe de la nuit",
        "Undead" => "Mort-vivant",
        "Tauren" => "Tauren",
        "Gnome" => "Gnome",
        "Troll" => "Troll",
        "Goblin" => "Gobelin",
        "Blood Elf" => "Elfe de sang",
        "Draenei" => "Draeneï",
        "Worgen" => "Worgen",
        "Pandaren" => "Pandaren",
        other => other,
    }
    .to_string()
}

/// Does an in-game name ("Ladou") designate this armory character ("Ladou Pipø")?
pub fn same_character(game_name: &str, armory_name: &str) -> bool {
    let g = game_name.trim().to_lowercase();
    let a = armory_name.trim().to_lowercase();
    !g.is_empty() && (g == a || a.split_whitespace().next() == Some(g.as_str()))
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .user_agent(USER_AGENT)
        .timeout(Duration::from_secs(30))
        .build()
}

fn get_json<T: serde::de::DeserializeOwned>(url: &str) -> Result<T, String> {
    let resp = agent().get(url).call().map_err(|e| match e {
        ureq::Error::Status(404, _) => {
            "introuvable sur l'armurerie (vérifie le nom ou colle le lien de la page)".to_string()
        }
        ureq::Error::Status(code, _) => format!("l'armurerie répond {code} (réessaie plus tard)"),
        other => format!("armurerie injoignable : {other}"),
    })?;
    resp.into_json::<T>()
        .map_err(|e| format!("réponse de l'armurerie illisible : {e}"))
}

pub fn fetch_guild(guild: &GuildRef) -> Result<Guild, String> {
    get_json(&guild.api_url())
}

pub fn fetch_character(guild: &GuildRef, name: &str) -> Result<Character, String> {
    get_json(&guild.character_api_url(name))
}

/// Profiles of the roster members matching `wanted` in-game names (polite: 1 request/s).
pub fn fetch_profiles(
    guild: &GuildRef,
    roster: &Guild,
    wanted: &[String],
) -> (Vec<Character>, Vec<String>) {
    let mut out = Vec::new();
    let mut notes = Vec::new();
    let targets: Vec<&Member> = roster
        .members
        .iter()
        .filter(|m| wanted.iter().any(|w| same_character(w, &m.name)))
        .take(MAX_PROFILES)
        .collect();
    for (i, m) in targets.iter().enumerate() {
        if i > 0 {
            std::thread::sleep(Duration::from_secs(1));
        }
        match fetch_character(guild, &m.name) {
            Ok(c) => out.push(c),
            Err(e) => notes.push(format!("{} : {e}", m.name)),
        }
    }
    (out, notes)
}

/// Press.lua item: the roster (and known profiles) to publish to the guild.
pub fn roster_item(guild_ref: &GuildRef, guild: &Guild, profiles: &[Character], now: i64) -> Value {
    let mut members: Vec<&Member> = guild.members.iter().collect();
    members.sort_by(|a, b| b.level.cmp(&a.level).then_with(|| a.name.cmp(&b.name)));
    members.truncate(MAX_MEMBERS);
    let list: Vec<Value> = members
        .iter()
        .map(|m| {
            let race = guild
                .race_names
                .get(&m.race_id.to_string())
                .map(|r| race_fr(r));
            let mut v = json!({"n": m.name, "lvl": m.level, "rk": m.rank});
            if !class_token(m.class_id).is_empty() {
                v["cl"] = json!(class_token(m.class_id));
            }
            if let Some(r) = race {
                v["ra"] = json!(r);
            }
            if let Some(c) = profiles.iter().find(|c| c.name == m.name) {
                if let Some(gs) = c.gearscore {
                    v["gs"] = json!(gs.round() as i64);
                }
                if let Some(il) = c.average_ilvl {
                    v["il"] = json!(il.round() as i64);
                }
                if let Some(ll) = c.last_login {
                    v["ll"] = json!(ll / 1000);
                }
            }
            v
        })
        .collect();
    let at = guild.fetched_at.map_or(now, |ms| ms / 1000);
    let day = chrono::DateTime::from_timestamp(now, 0)
        .map(|d| d.format("%Y%m%d").to_string())
        .unwrap_or_default();
    json!({
        "id": format!("roster:{}:{day}", guild_ref.slug),
        "kind": "RIVAL_ROSTER",
        "t": now,
        "note": format!("{} membre(s), armurerie", guild.member_count.max(list.len() as u32)),
        "p": {
            "guild": guild.name,
            "count": guild.member_count,
            "faction": guild.faction_name,
            "at": at,
            "src": guild_ref.page_url(),
            "members": list,
        },
    })
}

/// Do two roster payloads list the same members (name, level, rank, class, race, gear)?
/// The last login and the date of the reading are left out: they change every day.
pub fn same_roster(a: &Value, b: &Value) -> bool {
    fn members(p: &Value) -> Option<Vec<String>> {
        let mut out: Vec<String> = p
            .get("members")?
            .as_array()?
            .iter()
            .map(|m| {
                ["n", "lvl", "rk", "cl", "ra", "gs", "il"]
                    .iter()
                    .map(|k| m.get(*k).map(Value::to_string).unwrap_or_default())
                    .collect::<Vec<_>>()
                    .join("|")
            })
            .collect();
        out.sort();
        Some(out)
    }
    let guild = |p: &Value| {
        p.get("guild")
            .and_then(Value::as_str)
            .map(str::to_lowercase)
    };
    guild(a).is_some() && guild(a) == guild(b) && members(a).is_some() && members(a) == members(b)
}

/// Press.lua item: make `rival` the guild's rival (published by an officer in game).
pub fn guild_config_item(rival: &str, now: i64) -> Value {
    json!({
        "id": format!("cfg:{}", sha1_hex(&rival.to_lowercase(), 10)),
        "kind": "GUILD_CONFIG",
        "t": now,
        "p": {"rival": rival},
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const GUILD: &str = r#"{"schema":1,"name":"Cest Dieu qui pilote","slug":"cest-dieu-qui-pilote","region":"eu","server":"pvp",
        "faction":"HORDE","factionName":"Horde","memberCount":3,"classNames":{"1":"Warrior","8":"Mage"},
        "raceNames":{"5":"Undead","6":"Tauren","96":"Windshaper Skyborne"},
        "members":[{"name":"Zellt Vurtne","server":"pvp","level":35,"classId":8,"raceId":5,"rank":5},
                   {"name":"Ladou Pipø","level":25,"classId":1,"raceId":6,"rank":2},
                   {"name":"Duø Pipø","level":37,"classId":7,"raceId":96,"rank":2}],
        "fetchedAt":1795115502896,"gearscores":{"ladou-pipø":159}}"#;
    const CHARACTER: &str = r#"{"schema":10,"name":"Ladou Pipø","level":25,"race":"Tauren","classId":1,"className":"Warrior",
        "guild":"Cest Dieu qui pilote","lastLogin":1794953181000,"averageIlvl":16,"gearscore":159,"items":[]}"#;

    #[test]
    fn guild_refs_from_links_and_names() {
        let g = GuildRef::parse(
            "https://armorywowforever.com/g/forever/eu/pvp/cest-dieu-qui-pilote?x=1",
        )
        .unwrap();
        assert_eq!(g.slug, "cest-dieu-qui-pilote");
        assert_eq!(GuildRef::parse("C'est Dieu  qui pilote"), Some(g.clone()));
        assert_eq!(
            g.api_url(),
            "https://armorywowforever.com/api/guild/forever/eu/pvp/cest-dieu-qui-pilote"
        );
        assert_eq!(
            g.character_api_url("Ladou Pipø"),
            "https://armorywowforever.com/api/character/forever/eu/pvp/Ladou-Pip%C3%B8"
        );
        assert_eq!(
            GuildRef::parse("https://x/g/forever/eu/pvp/l%C3%A9a")
                .unwrap()
                .slug,
            "léa"
        );
        assert_eq!(GuildRef::parse("  "), None);
    }

    #[test]
    fn roster_item_from_api_answers() {
        let guild: Guild = serde_json::from_str(GUILD).unwrap();
        let ladou: Character = serde_json::from_str(CHARACTER).unwrap();
        let g = GuildRef::parse("Cest Dieu qui pilote").unwrap();
        let item = roster_item(&g, &guild, &[ladou], 1_795_115_600);
        assert_eq!(item["kind"], "RIVAL_ROSTER");
        assert_eq!(item["id"], "roster:cest-dieu-qui-pilote:20261119");
        let members = item["p"]["members"].as_array().unwrap();
        assert_eq!(members[0]["n"], "Duø Pipø", "highest level first");
        assert_eq!(members[0]["ra"], "Windshaper Skyborne");
        assert_eq!(members[1]["cl"], "MAGE");
        assert_eq!(members[1]["ra"], "Mort-vivant");
        assert_eq!(members[2]["gs"], 159);
        assert_eq!(members[2]["ll"], 1_794_953_181);
        assert_eq!(item["p"]["at"], 1_795_115_502);
        // the published event must stay small enough for the addon's sync
        let lua = crate::lua::dumps_value(&item["p"], 0);
        assert!(lua.len() < 6000);
    }

    #[test]
    fn unchanged_roster_is_recognised() {
        let guild: Guild = serde_json::from_str(GUILD).unwrap();
        let g = GuildRef::parse("Cest Dieu qui pilote").unwrap();
        let a = roster_item(&g, &guild, &[], 1_795_115_600);
        // another day: other id, other date, same members
        let mut b = roster_item(&g, &guild, &[], 1_795_202_000);
        b["p"]["at"] = json!(1_795_202_000);
        b["p"]["members"][0]["ll"] = json!(1_795_200_000);
        assert!(same_roster(&a["p"], &b["p"]));
        b["p"]["members"][0]["lvl"] = json!(99);
        assert!(!same_roster(&a["p"], &b["p"]), "a level up is news");
        let mut c = a.clone();
        c["p"]["members"].as_array_mut().unwrap().pop();
        assert!(!same_roster(&a["p"], &c["p"]), "a member left");
        let mut d = a.clone();
        d["p"]["guild"] = json!("Autre");
        assert!(!same_roster(&a["p"], &d["p"]));
    }

    #[test]
    fn game_names_match_first_names() {
        assert!(same_character("Ladou", "Ladou Pipø"));
        assert!(same_character("ladou pipø", "Ladou Pipø"));
        assert!(!same_character("Lad", "Ladou Pipø"));
        assert!(!same_character("", "Ladou Pipø"));
    }

    #[test]
    fn guild_config_item_is_stable() {
        assert_eq!(
            guild_config_item("Les Crocs", 1)["id"],
            guild_config_item("les crocs", 2)["id"]
        );
        assert_eq!(guild_config_item("X", 1)["p"]["rival"], "X");
    }
}
