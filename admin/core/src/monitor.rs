//! Monitoring ("Suivi" tab): is the addon working for everyone?
//!
//! Built from the officer's SavedVariables only:
//!   - the events (all shared events received through the sync, plus the account's own);
//!   - `RenatusDB.monitor`, local health data kept by the addon and never broadcast:
//!     members seen on the addon channel (with their addon version), sync counters and
//!     the last guild roster snapshot.
//!
//! Nothing here proposes anything: it is a read-only dashboard.

use std::collections::{BTreeMap, BTreeSet};

use chrono::TimeZone;
use serde::Serialize;
use serde_json::Value;

use crate::chronicle::{num_of, payload, str_of, Chronicle};

const DAY: i64 = 86_400;
/// A member counts as new during this many days after first being seen.
pub const NEW_DAYS: i64 = 7;
/// An equipped member silent for this long gets an alert.
pub const SILENT_DAYS: i64 = 14;
const FEED_LEN: usize = 300;
const ACTIVITY_DAYS: i64 = 30;

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Monitor {
    pub health: Health,
    pub alerts: Vec<Alert>,
    pub members: Vec<Member>,
    /// Events per day (local date), oldest first, `ACTIVITY_DAYS` entries.
    pub activity: Vec<DayCount>,
    pub feed: Vec<FeedItem>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Health {
    /// Persistent counters kept by the addon (0 with an older addon).
    pub received: i64,
    pub rejected: i64,
    pub last_reject: Option<String>,
    pub last_reject_at: Option<i64>,
    pub last_received: Option<i64>,
    /// Members seen on the addon channel (any message), persisted.
    pub peers: usize,
    pub equipped: usize,
    pub roster_size: usize,
    pub roster_at: Option<i64>,
    /// Median seconds between an event and its reception here (last 30 days).
    pub median_delay: Option<i64>,
    pub direct: usize,
    pub relayed: usize,
    pub missing: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Alert {
    /// "warn" or "info".
    pub level: &'static str,
    pub text: String,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Member {
    pub name: String,
    pub guid: Option<String>,
    pub class: Option<String>,
    pub rank: Option<i64>,
    pub level: Option<i64>,
    pub in_roster: bool,
    /// Authored events or was seen on the addon channel.
    pub equipped: bool,
    /// Addon version announced by the member (recent addons only).
    pub version: Option<String>,
    /// Events of this account (private ones exist only for the officer's own characters).
    pub mine: bool,
    pub first_seen: Option<i64>,
    pub last_activity: Option<i64>,
    pub last_peer: Option<i64>,
    pub shared: usize,
    pub last_kind: Option<String>,
    /// Missing shared sequence numbers (at most 20 listed).
    pub missing: Vec<i64>,
    pub missing_count: usize,
    pub is_new: bool,
    /// Consent to the AI gazette: "yes", "no", or "never" (authored events but never
    /// announced a choice: their facts are left out). None when the author is unknown.
    pub ai_consent: Option<&'static str>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DayCount {
    pub day: String,
    pub count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedItem {
    pub id: String,
    pub t: i64,
    pub name: String,
    pub kind: String,
    pub label: String,
    pub detail: String,
    pub shared: bool,
    pub prov: String,
    pub by: Option<String>,
    pub direct: bool,
    pub delay: Option<i64>,
}

pub fn kind_label(kind: &str) -> &str {
    match kind {
        "LEVEL_UP" => "Niveau",
        "DEATH" => "Mort",
        "BOSS_KILL" => "Boss vaincu",
        "QUEST_DONE" => "Quête",
        "ZONE_FIRST_VISIT" => "Nouvelle zone",
        "EXPEDITION" => "Expédition",
        "GUILD_JOIN" => "Entrée en guilde",
        "PROFESSION" => "Métier",
        "RARE_ITEM" => "Objet rare",
        "ANECDOTE" => "Anecdote",
        "ENEMY_SEEN" => "Ennemi aperçu",
        "PVP_CLASH" => "Combat JcJ",
        "PVP_KILL" => "Victoire JcJ",
        "ENEMY_NOTE" => "Note sur un ennemi",
        "WANTED" => "Avis de recherche",
        "WANTED_CLOSE" => "Avis clos",
        "ARTICLE" => "Article",
        "EDITION" => "Numéro de gazette",
        "VOTE" => "Vote",
        "AI_CONSENT" => "Consentement IA",
        "GUILD_CONFIG" => "Réglage de guilde",
        "RIVAL_ROSTER" => "Effectif rival",
        "MOB_KILL" => "Créature tuée",
        "BOOSTER_OPEN" => "Booster ouvert",
        "CARD_SET" => "Cartes publiées",
        "CARD_PROFILE" => "Profil de carte",
        "TOMBSTONE" => "Suppression",
        "DEATH_CAUSE" => "Cause de mort",
        "LETTER" => "Courrier",
        other => other,
    }
}

fn text(v: &Value, key: &str) -> Option<String> {
    match v.get(key)? {
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

/// One short line about an event, for the feed.
fn detail(e: &Value) -> String {
    let p = payload(e);
    let loc = e.get("loc").cloned().unwrap_or(Value::Null);
    let zone = text(&loc, "i").or_else(|| text(&loc, "z"));
    let kind = str_of(e, "k").unwrap_or("");
    let main = match kind {
        "LEVEL_UP" => text(p, "lvl").map(|l| format!("niveau {l}")),
        "DEATH" => {
            let mut s = text(p, "lvl")
                .map(|l| format!("niveau {l}"))
                .unwrap_or_default();
            if let Some(c) = text(p, "cause") {
                s = if s.is_empty() { c } else { format!("{s}, {c}") };
            }
            Some(s).filter(|s| !s.is_empty())
        }
        "RARE_ITEM" => text(p, "item"),
        "MOB_KILL" => text(p, "name"),
        "BOOSTER_OPEN" => p
            .get("cards")
            .and_then(Value::as_array)
            .map(|c| format!("{} carte(s)", c.len())),
        "GUILD_JOIN" => text(p, "guild"),
        "PVP_KILL" => text(p, "name").or_else(|| {
            let bits: Vec<String> = ["race", "className", "level"]
                .iter()
                .filter_map(|k| text(p, k))
                .collect();
            Some(bits.join(" ")).filter(|b| !b.is_empty())
        }),
        "AI_CONSENT" => p
            .get("ok")
            .and_then(Value::as_bool)
            .map(|ok| if ok { "accepté" } else { "refusé" }.to_string()),
        "TOMBSTONE" => e
            .get("refs")
            .and_then(Value::as_array)
            .map(|r| format!("{} événement(s)", r.len())),
        _ => None,
    };
    let main = main.or_else(|| {
        ["title", "name", "enemy", "guild", "rival", "zone"]
            .iter()
            .find_map(|k| text(p, k))
    });
    match (main, zone) {
        (Some(m), Some(z)) if kind != "ZONE_FIRST_VISIT" => format!("{m} · {z}"),
        (Some(m), _) => m,
        (None, Some(z)) => z,
        (None, None) => String::new(),
    }
}

fn day_of(t: i64) -> String {
    chrono::Local
        .timestamp_opt(t, 0)
        .single()
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

/// "1.0.10" > "1.0.9"; anything unparsable compares as 0.
fn version_key(v: &str) -> Vec<u64> {
    v.split(|c: char| !c.is_ascii_digit())
        .filter(|s| !s.is_empty())
        .take(3)
        .map(|s| s.parse().unwrap_or(0))
        .collect()
}

fn first_word(name: &str) -> &str {
    name.split_whitespace().next().unwrap_or(name)
}

/// Same character? Event names are "Dakey", roster names "Dakey Dak" on WoW Forever.
fn same_name(a: &str, b: &str) -> bool {
    let (a, b) = (a.to_lowercase(), b.to_lowercase());
    a == b || first_word(&a) == b || a == first_word(&b)
}

/// Received from the author themselves. Older addons compared the sender's full
/// name ("Renaa Fitzherak") with the event's short one ("Renaa"): recomputed here.
fn is_direct(e: &Value, rx: &Value) -> bool {
    rx.get("direct").and_then(Value::as_bool) == Some(true)
        || matches!((str_of(rx, "by"), str_of(e, "n")), (Some(by), Some(n)) if same_name(by, n))
}

pub fn build(ch: &Chronicle, now: i64, installed: Option<&str>) -> Monitor {
    let mon = &ch.monitor;
    let mut m = Monitor::default();
    let mut members: Vec<Member> = Vec::new();

    // 1. Guild roster snapshot.
    let roster = mon.get("roster");
    if let Some(list) = roster
        .and_then(|r| r.get("members"))
        .and_then(Value::as_array)
    {
        m.health.roster_at = roster.map(|r| num_of(r, "at") as i64).filter(|t| *t > 0);
        m.health.roster_size = list.len();
        for r in list {
            let Some(name) = str_of(r, "name") else {
                continue;
            };
            members.push(Member {
                name: name.to_string(),
                guid: str_of(r, "guid").map(str::to_string),
                class: str_of(r, "class").map(str::to_string),
                rank: r.get("rank").and_then(Value::as_i64),
                level: r.get("level").and_then(Value::as_i64),
                in_roster: true,
                ..Member::default()
            });
        }
    }

    // 2. Authors of events (shared sequences, private events of this account).
    #[derive(Default)]
    struct Author {
        name: String,
        class: Option<String>,
        seqs: BTreeSet<i64>,
        shared: usize,
        private: bool,
        first: Option<i64>,
        last: Option<(i64, String)>,
    }
    let mut authors: BTreeMap<String, Author> = BTreeMap::new();
    for e in ch.events.values() {
        let Some(a) = str_of(e, "a") else { continue };
        let au = authors.entry(a.to_string()).or_default();
        if let Some(n) = str_of(e, "n") {
            au.name = n.to_string();
        }
        if au.class.is_none() {
            au.class = str_of(e, "c").map(str::to_string);
        }
        let shared = str_of(e, "vis") == Some("G");
        if shared {
            if let Some(s) = e.get("s").and_then(Value::as_i64) {
                au.seqs.insert(s);
            }
        }
        if e.get("del").is_some() {
            continue;
        }
        if shared {
            au.shared += 1;
        } else {
            au.private = true;
        }
        let t = num_of(e, "t") as i64;
        if t > 0 {
            au.first = Some(au.first.map_or(t, |f| f.min(t)));
            if au.last.as_ref().is_none_or(|(l, _)| t > *l) {
                au.last = Some((t, str_of(e, "k").unwrap_or("?").to_string()));
            }
        }
    }
    for (guid, au) in authors {
        let idx = members
            .iter()
            .position(|x| x.guid.as_deref() == Some(guid.as_str()))
            .or_else(|| {
                members
                    .iter()
                    .position(|x| x.guid.is_none() && x.in_roster && same_name(&x.name, &au.name))
            })
            .unwrap_or_else(|| {
                members.push(Member {
                    name: au.name.clone(),
                    ..Member::default()
                });
                members.len() - 1
            });
        let row = &mut members[idx];
        row.mine |= au.private || ch.own.contains(&guid);
        row.guid = Some(guid);
        row.class = row.class.take().or(au.class);
        row.equipped = true;
        row.shared += au.shared;
        row.first_seen = au.first;
        if let Some((t, k)) = au.last {
            row.last_activity = Some(t);
            row.last_kind = Some(k);
        }
        if let Some(&top) = au.seqs.iter().next_back() {
            let missing: Vec<i64> = (1..=top).filter(|s| !au.seqs.contains(s)).collect();
            row.missing_count = missing.len();
            row.missing = missing.into_iter().take(20).collect();
        }
    }

    // 3. Members seen on the addon channel.
    if let Some(peers) = mon.get("peers").and_then(Value::as_object) {
        m.health.peers = peers.len();
        for (name, p) in peers {
            let idx = members
                .iter()
                .position(|x| same_name(&x.name, name))
                .unwrap_or_else(|| {
                    members.push(Member {
                        name: name.clone(),
                        ..Member::default()
                    });
                    members.len() - 1
                });
            let row = &mut members[idx];
            row.equipped = true;
            row.version = str_of(p, "ver").map(str::to_string);
            let seen = Some(num_of(p, "seen") as i64).filter(|t| *t > 0);
            let first = Some(num_of(p, "first") as i64).filter(|t| *t > 0);
            row.last_peer = seen;
            row.last_activity = row.last_activity.max(seen);
            row.first_seen = match (row.first_seen, first) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            };
        }
    }

    let consent = crate::gazette::consent(ch);
    for row in &mut members {
        if row.equipped {
            row.ai_consent = row.guid.as_ref().map(|g| match consent.get(g) {
                Some(true) => "yes",
                Some(false) => "no",
                None => "never",
            });
        }
        row.is_new =
            row.equipped && !row.mine && row.first_seen.is_some_and(|f| now - f < NEW_DAYS * DAY);
    }
    members.sort_by(|a, b| {
        b.equipped
            .cmp(&a.equipped)
            .then(b.last_activity.cmp(&a.last_activity))
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    // 4. Sync health.
    let sync = mon.get("sync").cloned().unwrap_or(Value::Null);
    m.health.received = num_of(&sync, "received") as i64;
    m.health.rejected = num_of(&sync, "rejected") as i64;
    m.health.last_reject = str_of(&sync, "lastReject").map(str::to_string);
    m.health.last_reject_at = Some(num_of(&sync, "lastRejectAt") as i64).filter(|t| *t > 0);
    let mut delays = Vec::new();
    let mut last_rx = None::<i64>;
    for e in ch.all() {
        let Some(rx) = e.get("rx") else { continue };
        let at = num_of(rx, "at") as i64;
        last_rx = last_rx.max(Some(at).filter(|t| *t > 0));
        if is_direct(e, rx) {
            m.health.direct += 1;
        } else {
            m.health.relayed += 1;
        }
        let t = num_of(e, "t") as i64;
        if at > 0 && t > 0 && now - at < ACTIVITY_DAYS * DAY {
            delays.push((at - t).max(0));
        }
    }
    delays.sort_unstable();
    m.health.median_delay = delays.get(delays.len() / 2).copied();
    m.health.last_received = Some(num_of(&sync, "lastReceived") as i64)
        .filter(|t| *t > 0)
        .or(last_rx);
    m.health.equipped = members.iter().filter(|x| x.equipped).count();
    m.health.missing = members.iter().map(|x| x.missing_count).sum();

    // Our own characters run the installed addon: the channel never tells us our own
    // version (an older addon recorded its own echo as a peer, with a stale version).
    if let Some(inst) = installed {
        for x in members.iter_mut().filter(|x| x.mine) {
            x.version = Some(inst.to_string());
        }
    }

    // 5. Alerts.
    let mut alerts = Vec::new();
    if m.health.rejected > 0 {
        alerts.push(Alert {
            level: "warn",
            text: format!(
                "{} événement(s) rejeté(s) à la réception. Dernier : {}.",
                m.health.rejected,
                m.health.last_reject.as_deref().unwrap_or("motif inconnu")
            ),
        });
    }
    for x in &members {
        if x.missing_count > 0 {
            let list: Vec<String> = x.missing.iter().map(i64::to_string).collect();
            alerts.push(Alert {
                level: "warn",
                text: format!(
                    "Il te manque {} événement(s) de {} (n° {}{}). La synchro les redemande ; si ça dure, {} doit se connecter hors instance.",
                    x.missing_count,
                    x.name,
                    list.join(", "),
                    if x.missing_count > x.missing.len() { "…" } else { "" },
                    x.name
                ),
            });
        }
    }
    if let Some(inst) = installed {
        for x in &members {
            if let Some(v) = &x.version {
                if version_key(v) < version_key(inst) {
                    alerts.push(Alert {
                        level: "warn",
                        text: format!(
                            "{} a l'addon {v}, la dernière est {inst} : le launcher devrait le mettre à jour.",
                            x.name
                        ),
                    });
                }
            }
        }
    }
    for x in &members {
        if x.equipped && !x.mine {
            if let Some(last) = x.last_activity {
                if now - last > SILENT_DAYS * DAY {
                    alerts.push(Alert {
                        level: "info",
                        text: format!(
                            "{} ne s'est pas manifesté depuis {} jours.",
                            x.name,
                            (now - last) / DAY
                        ),
                    });
                }
            }
        }
    }
    for x in members.iter().filter(|x| x.ai_consent == Some("never")) {
        alerts.push(Alert {
            level: "warn",
            text: format!(
                "{} n'a jamais annoncé son choix pour la gazette IA : ses faits en sont exclus. Remède : décocher puis recocher « La gazette rédigée par IA peut parler de moi » dans les options de Renatus.",
                x.name
            ),
        });
    }
    for x in members.iter().filter(|x| x.is_new && !x.mine) {
        alerts.push(Alert {
            level: "info",
            text: format!("Nouveau membre équipé : {}.", x.name),
        });
    }
    if m.health.roster_at.is_none() {
        alerts.push(Alert {
            level: "info",
            text: "Liste de la guilde pas encore relevée : il faut la nouvelle version de l'addon, puis /reload en jeu.".into(),
        });
    }
    if !members.iter().any(|x| x.equipped && !x.mine) {
        alerts.push(Alert {
            level: "info",
            text: "Aucun autre membre équipé vu pour l'instant.".into(),
        });
    }
    m.alerts = alerts;

    // 6. Activity per day and recent feed.
    let start = now - (ACTIVITY_DAYS - 1) * DAY;
    let mut per_day: BTreeMap<String, usize> = (0..ACTIVITY_DAYS)
        .map(|i| (day_of(start + i * DAY), 0))
        .collect();
    let mut all: Vec<&Value> = ch.all().collect();
    for e in &all {
        if let Some(c) = per_day.get_mut(&day_of(num_of(e, "t") as i64)) {
            *c += 1;
        }
    }
    m.activity = per_day
        .into_iter()
        .map(|(day, count)| DayCount { day, count })
        .collect();
    all.sort_by(|a, b| num_of(b, "t").total_cmp(&num_of(a, "t")));
    m.feed = all
        .into_iter()
        .take(FEED_LEN)
        .map(|e| {
            let kind = str_of(e, "k").unwrap_or("?").to_string();
            let rx = e.get("rx");
            let t = num_of(e, "t") as i64;
            FeedItem {
                id: str_of(e, "id").unwrap_or("").to_string(),
                t,
                name: str_of(e, "n").unwrap_or("?").to_string(),
                label: kind_label(&kind).to_string(),
                detail: detail(e),
                kind,
                shared: str_of(e, "vis") == Some("G"),
                prov: str_of(e, "prov").unwrap_or("OBS").to_string(),
                by: rx.and_then(|r| str_of(r, "by")).map(str::to_string),
                direct: rx.is_some_and(|r| is_direct(e, r)),
                delay: rx
                    .map(|r| num_of(r, "at") as i64 - t)
                    .filter(|d| *d >= 0 && t > 0),
            }
        })
        .collect();
    m.members = members;
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    fn chronicle() -> Chronicle {
        let saved = crate::lua::loads(&format!(
            r#"RenatusDB = {{
                ["events"] = {{
                    ["Player-1-A:1"] = {{ ["id"] = "Player-1-A:1", ["a"] = "Player-1-A", ["n"] = "Dakey", ["c"] = "ROGUE", ["k"] = "LEVEL_UP", ["s"] = 1, ["t"] = {t1}, ["vis"] = "G", ["p"] = {{ ["lvl"] = 20 }} }},
                    ["Player-1-A:2"] = {{ ["id"] = "Player-1-A:2", ["a"] = "Player-1-A", ["n"] = "Dakey", ["k"] = "AI_CONSENT", ["s"] = 2, ["t"] = {t1}, ["vis"] = "G", ["p"] = {{ ["ok"] = true }} }},
                    ["Player-1-A:p1"] = {{ ["id"] = "Player-1-A:p1", ["a"] = "Player-1-A", ["n"] = "Dakey", ["k"] = "DEATH", ["t"] = {t2}, ["vis"] = "P", ["p"] = {{}} }},
                    ["Player-1-B:1"] = {{ ["id"] = "Player-1-B:1", ["a"] = "Player-1-B", ["n"] = "Renaa", ["k"] = "QUEST_DONE", ["s"] = 1, ["t"] = {t2}, ["vis"] = "G", ["p"] = {{ ["title"] = "Les loups" }}, ["rx"] = {{ ["by"] = "Renaa Fitzherak", ["at"] = {t3} }} }},
                    ["Player-1-B:4"] = {{ ["id"] = "Player-1-B:4", ["a"] = "Player-1-B", ["n"] = "Renaa", ["k"] = "BOOSTER_OPEN", ["s"] = 4, ["t"] = {t3}, ["vis"] = "G", ["p"] = {{ ["cards"] = {{ 1, 2, 3, 4, 5 }} }}, ["rx"] = {{ ["by"] = "Dakey", ["at"] = {t3} }} }},
                }},
                ["seq"] = {{ ["Player-1-A"] = {{ ["public"] = 1, ["private"] = 1 }} }},
                ["monitor"] = {{
                    ["peers"] = {{
                        ["Renaa Fitzherak"] = {{ ["first"] = {t2}, ["seen"] = {t3}, ["proto"] = 1, ["ver"] = "1.0.0" }},
                        ["Ryju Rey"] = {{ ["first"] = {old}, ["seen"] = {old}, ["proto"] = 1, ["ver"] = "1.0.1" }},
                    }},
                    ["sync"] = {{ ["received"] = 2, ["rejected"] = 1, ["lastReject"] = "autre guilde (de Mallory)" }},
                    ["roster"] = {{ ["at"] = {t3}, ["members"] = {{
                        {{ ["name"] = "Dakey Dak", ["rank"] = 1, ["level"] = 21, ["class"] = "ROGUE", ["guid"] = "Player-1-A" }},
                        {{ ["name"] = "Renaa Fitzherak", ["rank"] = 3, ["level"] = 18, ["class"] = "PRIEST" }},
                        {{ ["name"] = "Hurtige Henning", ["rank"] = 4, ["level"] = 10, ["class"] = "MAGE" }},
                    }} }},
                }},
            }}"#,
            t1 = NOW - 20 * DAY,
            t2 = NOW - 2 * DAY,
            t3 = NOW - DAY,
            old = NOW - 30 * DAY,
        ))
        .unwrap();
        Chronicle::from_saved(&saved)
    }

    fn member<'a>(m: &'a Monitor, name: &str) -> &'a Member {
        m.members.iter().find(|x| x.name == name).unwrap()
    }

    #[test]
    fn members_merge_roster_authors_and_peers() {
        let m = build(&chronicle(), NOW, Some("1.0.1"));
        assert_eq!(m.members.len(), 4, "{:#?}", m.members);
        let dakey = member(&m, "Dakey Dak");
        assert!(dakey.equipped && dakey.mine && dakey.in_roster);
        assert_eq!(
            dakey.version.as_deref(),
            Some("1.0.1"),
            "own row: installed version"
        );
        assert_eq!(dakey.shared, 2);
        let renaa = member(&m, "Renaa Fitzherak");
        assert!(renaa.equipped && !renaa.mine && renaa.is_new);
        assert_eq!(renaa.guid.as_deref(), Some("Player-1-B"));
        assert_eq!(renaa.version.as_deref(), Some("1.0.0"));
        assert_eq!(renaa.missing, vec![2, 3]);
        assert_eq!(renaa.last_kind.as_deref(), Some("BOOSTER_OPEN"));
        assert_eq!(renaa.ai_consent, Some("never"));
        assert_eq!(member(&m, "Dakey Dak").ai_consent, Some("yes"));
        let hurtige = member(&m, "Hurtige Henning");
        assert!(!hurtige.equipped && hurtige.in_roster);
        let ryju = member(&m, "Ryju Rey");
        assert!(ryju.equipped && !ryju.in_roster && !ryju.is_new);
        assert_eq!(
            m.members.last().unwrap().name,
            "Hurtige Henning",
            "sans addon en dernier"
        );
    }

    #[test]
    fn health_and_alerts() {
        let m = build(&chronicle(), NOW, Some("1.0.1"));
        assert_eq!(m.health.rejected, 1);
        assert_eq!(m.health.peers, 2);
        assert_eq!(m.health.equipped, 3);
        assert_eq!((m.health.direct, m.health.relayed), (1, 1));
        assert_eq!(m.health.missing, 2);
        let texts: Vec<&str> = m.alerts.iter().map(|a| a.text.as_str()).collect();
        let has = |s: &str| texts.iter().any(|t| t.contains(s));
        assert!(has("rejeté"), "{texts:#?}");
        assert!(has("n° 2, 3"), "{texts:#?}");
        assert!(has("Renaa Fitzherak a l'addon 1.0.0"), "{texts:#?}");
        assert!(
            has("Ryju Rey ne s'est pas manifesté depuis 30 jours"),
            "{texts:#?}"
        );
        assert!(has("Nouveau membre équipé : Renaa"), "{texts:#?}");
        assert!(!has("Dakey Dak ne s'est"), "pas d'alerte sur soi-même");
        assert!(has("Renaa Fitzherak n'a jamais annoncé"), "{texts:#?}");
        assert!(!has("Dakey Dak n'a jamais"), "{texts:#?}");
        assert!(!has("Ryju Rey n'a jamais"), "auteur inconnu : pas d'alerte");
    }

    #[test]
    fn feed_and_activity() {
        let m = build(&chronicle(), NOW, None);
        assert_eq!(m.feed.len(), 5);
        assert_eq!(m.feed[0].kind, "BOOSTER_OPEN");
        assert_eq!(m.feed[0].detail, "5 carte(s)");
        assert_eq!(m.feed[0].by.as_deref(), Some("Dakey"));
        assert!(!m.feed[0].direct);
        let quest = m.feed.iter().find(|f| f.kind == "QUEST_DONE").unwrap();
        assert_eq!(quest.detail, "Les loups");
        assert_eq!(quest.delay, Some(DAY));
        assert_eq!(m.activity.len(), ACTIVITY_DAYS as usize);
        assert_eq!(m.activity.iter().map(|d| d.count).sum::<usize>(), 5);
    }

    #[test]
    fn versions_compare_numerically() {
        assert!(version_key("1.0.9") < version_key("1.0.10"));
        assert!(version_key("0.12.0-test.8") < version_key("1.0.0"));
    }
}
