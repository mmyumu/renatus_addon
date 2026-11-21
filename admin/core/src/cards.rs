//! Album cards proposed with each gazette issue (CARD_SET items in Press.lua).
//!
//! Which facts deserve a card is decided here, by fixed rules (the same id schemes as the
//! addon's former local catalogue, `Album.Legacy`): members (four versions, earned one by one), every
//! ten levels, first kill of a boss, outings of two members or more, anecdotes, deaths with
//! a player or a fall for a killer, published articles, enemies who matter, the first rare item
//! brought back, the guild's bestiary (each kind of creature killed, once) and its terrors (a
//! creature that killed a member: one per creature and member, named by the AI).
//! Bosses and creatures carry their npc id (the card shows their 3D model), items their item
//! id (the card shows their icon): from the game's own data, never from the AI. The AI only writes each card's
//! name and text, for the members who agreed to the AI gazette; the others, and any card
//! the AI leaves out or gets wrong, get a plain text. Cards are numbered after the last
//! published or pending one; an officer publishes them in game with the issue.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde_json::{json, Value};

use crate::chronicle::{num_of, payload, str_of, Chronicle};
use crate::gazette;

pub const MAX_NAME: usize = 40;
pub const MAX_TEXT: usize = 140;
/// Cards sent to the AI in one request (the rest keep their plain text).
pub const MAX_AI: usize = 80;
/// Size of one CARD_SET payload, well under the sync limit (6000 bytes once encoded).
const MAX_SET_BYTES: usize = 4000;

/// A card to publish, before its number.
#[derive(Debug, Clone)]
pub struct Candidate {
    pub id: String,
    pub series: &'static str,
    pub rarity: &'static str,
    pub name: String,
    pub text: String,
    pub class: Option<String>,
    pub guid: Option<String>,
    pub icon: Option<&'static str>,
    /// What happened, for the AI.
    pub facts: String,
    /// The AI may write it (no member who refused the AI gazette is involved).
    pub ai: bool,
    /// Member the card is about: the AI's name must keep it.
    pub keep_name: Option<String>,
    /// Force and endurance chosen by the AI (fighters only; else `default_stats`).
    pub stats: Option<(i64, i64)>,
    /// What the card shows instead of an icon (Art).
    pub art: Art,
    t: f64,
}

/// Picture of a card taken from the game's own data, never chosen by the AI: a creature's
/// 3D model (its npc id, as the game's GUIDs give it) or an item's icon (its item id).
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Art {
    pub npc: Option<i64>,
    pub item: Option<i64>,
}

impl Art {
    fn npc(id: Option<i64>) -> Self {
        Art {
            npc: id.filter(|n| *n > 0),
            item: None,
        }
    }
}

/// Npc id from a creature's name, by the base set's creatures (Renatus/Core/Cards.lua):
/// a boss or a beast the guild meets that has a card there.
fn known_creatures() -> HashMap<String, i64> {
    crate::revise::base_set()
        .1
        .iter()
        .filter_map(|c| {
            let npc = c.get("npc").and_then(Value::as_i64)?;
            Some((str_of(c, "n")?.to_lowercase(), npc))
        })
        .collect()
}

impl Candidate {
    /// Someone who fights (member, enemy): the card has a force and an endurance.
    pub fn fighter(&self) -> bool {
        matches!(
            self.series,
            "members" | "founders" | "sworn" | "mobs" | "terreurs"
        )
    }

    /// Force and endurance shown on the card, if it is a fighter.
    pub fn final_stats(&self) -> Option<(i64, i64)> {
        self.fighter().then(|| {
            self.stats
                .unwrap_or_else(|| default_stats(self.rarity, self.class.as_deref()))
        })
    }
}

/// When the versions of a member's card are earned (the common one comes on arrival):
/// rare: (group outings, bosses), either; epic: (level, bosses), either;
/// legendary: (level with an anecdote, bosses), either.
const MEMBER_RARE: (usize, usize) = (5, 3);
const MEMBER_EPIC: (i64, usize) = (60, 10);
const MEMBER_LEGENDARY: (i64, usize) = (60, 25);

/// Highest force or endurance.
pub const STAT_MAX: i64 = 12;
/// How far the AI may stray from the rarity's budget (force + endurance).
const STAT_SLACK: i64 = 2;

/// Force + endurance of a card of this rarity (same table as the addon, Core/Album.lua).
pub fn stat_budget(rarity: &str) -> i64 {
    match rarity {
        "uncommon" => 6,
        "rare" => 9,
        "epic" => 13,
        "legendary" => 17,
        _ => 4,
    }
}

/// The rule when the AI gives nothing: the budget split by class (same as the addon's
/// Album.DefaultStats: a mage hits hard and breaks easily, a warrior the other way round).
pub fn default_stats(rarity: &str, class: Option<&str>) -> (i64, i64) {
    let budget = stat_budget(rarity);
    let share = match class.unwrap_or("") {
        "WARRIOR" => 0.45,
        "PALADIN" => 0.4,
        "HUNTER" => 0.55,
        "ROGUE" => 0.6,
        "PRIEST" => 0.35,
        "MAGE" => 0.65,
        "WARLOCK" => 0.6,
        _ => 0.5,
    };
    let force = (budget as f64 * share + 0.5).floor() as i64;
    (force, budget - force)
}

/// Ids already published (events) or waiting in Press.lua, and the highest number used.
pub fn published(ch: &Chronicle, pending: &[Value]) -> (HashSet<String>, i64) {
    let mut ids = HashSet::new();
    let mut max = 0;
    let sets = ch
        .of_kind("CARD_SET")
        .filter(|e| str_of(e, "vis") == Some("G") && e.get("del").is_none())
        .chain(
            pending
                .iter()
                .filter(|i| str_of(i, "kind") == Some("CARD_SET")),
        );
    for e in sets {
        for c in payload(e)
            .get("cards")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(id) = str_of(c, "id") {
                ids.insert(id.to_string());
            }
            max = max.max(num_of(c, "no") as i64);
        }
    }
    (ids, max)
}

/// Rarity of a creature's card by its kind (UnitClassification): modest in the bestiary,
/// higher for a terror (a creature that killed a member).
fn mob_rarity(cls: &str, terror: bool) -> &'static str {
    let rank = match cls {
        "worldboss" | "rareelite" => 3,
        "rare" => 2,
        "elite" => 1,
        _ => 0,
    };
    let rarities = ["common", "uncommon", "rare", "epic", "legendary"];
    rarities[if terror {
        (rank + 2).min(4)
    } else {
        rank.min(3)
    }]
}

fn kind_fr(cls: &str) -> &'static str {
    match cls {
        "worldboss" => "boss du monde",
        "rareelite" => "rare élite",
        "rare" => "rare",
        "elite" => "élite",
        _ => "normale",
    }
}

fn level_rarity(lvl: i64) -> &'static str {
    match lvl {
        60.. => "legendary",
        50..=59 => "epic",
        40..=49 => "rare",
        20..=39 => "uncommon",
        _ => "common",
    }
}

fn first_name(s: &str) -> String {
    s.split_whitespace().next().unwrap_or(s).to_lowercase()
}

fn public(ch: &Chronicle) -> Vec<&Value> {
    let mut list: Vec<&Value> = ch
        .all()
        .filter(|e| str_of(e, "vis") == Some("G") && e.get("del").is_none())
        .collect();
    list.sort_by(|a, b| num_of(a, "t").total_cmp(&num_of(b, "t")));
    list
}

/// Members who asked not to be in the others' album (latest CARD_PROFILE).
fn opted_out(ch: &Chronicle) -> HashSet<String> {
    let mut best: HashMap<String, (f64, bool)> = HashMap::new();
    for e in ch.of_kind("CARD_PROFILE") {
        let Some(a) = str_of(e, "a") else { continue };
        let t = num_of(e, "t");
        let out = payload(e)
            .get("optOut")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if best.get(a).is_none_or(|(bt, _)| t > *bt) {
            best.insert(a.to_string(), (t, out));
        }
    }
    best.into_iter()
        .filter(|(_, (_, out))| *out)
        .map(|(a, _)| a)
        .collect()
}

/// Every card the journal deserves that is not published yet, oldest facts first.
pub fn candidates(ch: &Chronicle, already: &HashSet<String>) -> Vec<Candidate> {
    let events = public(ch);
    let consent = gazette::consent(ch);
    let agrees = |guid: &str| consent.get(guid).copied().unwrap_or(false);
    let out_of_album = opted_out(ch);
    let mut out = Vec::new();
    let mut push = |c: Candidate| {
        if !already.contains(&c.id) && !out.iter().any(|x: &Candidate| x.id == c.id) {
            out.push(c);
        }
    };

    // Members: who they are (name, class), what they did.
    struct Member {
        name: String,
        class: Option<String>,
        first: f64,
        level: i64,
        expeditions: usize,
        bosses: usize,
        anecdote: Option<String>,
    }
    let mut members: BTreeMap<String, Member> = BTreeMap::new();
    for e in &events {
        let (Some(a), Some(n)) = (str_of(e, "a"), str_of(e, "n")) else {
            continue;
        };
        let m = members.entry(a.to_string()).or_insert(Member {
            name: n.to_string(),
            class: None,
            first: num_of(e, "t"),
            level: 0,
            expeditions: 0,
            bosses: 0,
            anecdote: None,
        });
        if let Some(c) = str_of(e, "c") {
            m.class = Some(c.to_string());
        }
        let p = payload(e);
        match str_of(e, "k") {
            // the member's own level: level ups, deaths, card profile (sent at login)
            Some("LEVEL_UP") | Some("DEATH") | Some("CARD_PROFILE") => {
                m.level = m.level.max(num_of(p, "lvl") as i64)
            }
            Some("EXPEDITION") => m.expeditions += 1,
            Some("BOSS_KILL") => m.bosses += 1,
            Some("ANECDOTE") if m.anecdote.is_none() => {
                m.anecdote = str_of(p, "title").map(str::to_string)
            }
            _ => {}
        }
    }
    for (guid, m) in &members {
        if out_of_album.contains(guid) {
            continue;
        }
        let ai = agrees(guid);
        let base = |id: String, rarity: &'static str, text: String, facts: String| Candidate {
            id,
            series: "members",
            rarity,
            name: m.name.clone(),
            text,
            class: m.class.clone(),
            guid: Some(guid.clone()),
            icon: None,
            facts,
            ai,
            keep_name: Some(m.name.clone()),
            stats: None,
            art: Art::default(),
            t: m.first,
        };
        let who = format!("{} ({})", m.name, m.class.as_deref().unwrap_or("?"));
        // The versions of a member's card are earned: common on arrival, then rare, epic,
        // legendary (MEMBER_RARE, MEMBER_EPIC, MEMBER_LEGENDARY), each in the issue after.
        push(base(
            format!("M:{guid}:common"),
            "common",
            "Membre de la guilde.".into(),
            format!("Carte de membre de {who}, la plus simple : il vient d'arriver."),
        ));
        let record = format!(
            "{} sorties en groupe, {} boss vaincus, niveau {}",
            m.expeditions, m.bosses, m.level
        );
        if m.expeditions >= MEMBER_RARE.0 || m.bosses >= MEMBER_RARE.1 {
            push(base(
                format!("M:{guid}:rare"),
                "rare",
                format!("{} expéditions, {} boss vaincus.", m.expeditions, m.bosses),
                format!("{who}, version rare, gagnée sur le terrain : {record}."),
            ));
        }
        if m.level >= MEMBER_EPIC.0 || m.bosses >= MEMBER_EPIC.1 {
            push(base(
                format!("M:{guid}:epic"),
                "epic",
                if m.level >= MEMBER_EPIC.0 {
                    "Le sommet atteint. Le reste n'est que détail.".into()
                } else {
                    format!("{} boss au tableau. Ça commence à se savoir.", m.bosses)
                },
                format!("{who}, version épique : un titre flatteur ou moqueur. {record}."),
            ));
        }
        if (m.level >= MEMBER_LEGENDARY.0 && m.anecdote.is_some()) || m.bosses >= MEMBER_LEGENDARY.1
        {
            let legend = m
                .anecdote
                .as_ref()
                .map(|a| format!("Souvenir : {a}"))
                .unwrap_or_else(|| format!("{} boss vaincus. On en parlera longtemps.", m.bosses));
            push(base(
                format!("M:{guid}:legendary"),
                "legendary",
                legend.clone(),
                format!("{who}, version légendaire. {legend} ({record})."),
            ));
        }
        let mut lvl = 10;
        while lvl <= m.level {
            let mut c = base(
                format!("L:{guid}:{lvl}"),
                level_rarity(lvl),
                if lvl >= 60 {
                    "Le sommet. La guilde s'incline (un peu).".into()
                } else {
                    format!("Niveau {lvl} atteint. Le plus dur reste à venir, comme toujours.")
                },
                format!("{who} atteint le niveau {lvl}."),
            );
            c.name = format!("{}, niveau {lvl}", m.name);
            push(c);
            lvl += 10;
        }
    }

    // Facts of the journal.
    let mut boss_seen: BTreeSet<String> = BTreeSet::new();
    let mut killers: HashMap<String, (String, Option<String>, usize)> = HashMap::new();
    let mut met: HashMap<String, (String, Option<String>, usize)> = HashMap::new();
    let mut sworn: HashMap<String, BTreeSet<String>> = HashMap::new();
    let mut boss_authors: HashMap<String, BTreeSet<String>> = HashMap::new();
    // Npc ids by creature name: what the journal already knows (bestiary, other deaths,
    // bosses), then the base set. An event without the id (an older addon, a death recap
    // without it) borrows it from another one about the same creature.
    let mut known = known_creatures();
    for e in &events {
        let p = payload(e);
        let named = match str_of(e, "k") {
            Some("MOB_KILL") | Some("BOSS_KILL") => Some(p),
            Some("DEATH") => p.get("killer").filter(|k| k.get("pl").is_none()),
            _ => None,
        };
        if let Some(v) = named {
            if let (Some(name), Some(npc)) = (
                str_of(v, "name").or(str_of(v, "n")),
                v.get("npc").and_then(Value::as_i64),
            ) {
                known.insert(name.to_lowercase(), npc);
            }
        }
    }
    for e in &events {
        if let (Some("BOSS_KILL"), Some(n)) = (str_of(e, "k"), str_of(e, "n")) {
            let key = str_of(e, "occ")
                .or(str_of(e, "id"))
                .unwrap_or("")
                .to_string();
            boss_authors.entry(key).or_default().insert(n.to_string());
        }
    }
    for e in &events {
        let p = payload(e);
        let id = str_of(e, "id").unwrap_or("");
        let n = str_of(e, "n").unwrap_or("?");
        let a = str_of(e, "a").unwrap_or("");
        if out_of_album.contains(a) {
            continue;
        }
        let t = num_of(e, "t");
        let ai = agrees(a);
        let mut fact = |id: String,
                        series: &'static str,
                        rarity: &'static str,
                        name: String,
                        text: String,
                        icon: &'static str,
                        facts: String,
                        class: Option<String>,
                        art: Art| {
            push(Candidate {
                id,
                series,
                rarity,
                name,
                text,
                class,
                guid: None,
                icon: Some(icon),
                facts,
                ai,
                keep_name: None,
                stats: None,
                art,
                t,
            })
        };
        match str_of(e, "k") {
            Some("BOSS_KILL") => {
                let boss = str_of(p, "name").unwrap_or("Boss").to_string();
                let key = p
                    .get("enc")
                    .map(Value::to_string)
                    .unwrap_or_else(|| boss.clone());
                if !boss_seen.insert(key) {
                    continue;
                }
                let occ = str_of(e, "occ").unwrap_or(id).to_string();
                let authors: Vec<String> = boss_authors
                    .get(&occ)
                    .map(|s| s.iter().cloned().collect())
                    .unwrap_or_else(|| vec![n.to_string()]);
                let by = authors.join(", ");
                fact(
                    format!("X:{occ}"),
                    "expeditions",
                    if authors.len() >= 2 { "epic" } else { "rare" },
                    boss.clone(),
                    format!("Vaincu par {by}."),
                    "INV_Misc_Head_Dragon_01",
                    format!("Premier {boss} vaincu par la guilde : {by}."),
                    None,
                    Art::npc(
                        p.get("npc")
                            .and_then(Value::as_i64)
                            .or_else(|| known.get(&boss.to_lowercase()).copied()),
                    ),
                );
            }
            Some("EXPEDITION") => {
                let pt = e.get("pt").and_then(Value::as_array);
                let Some(pt) = pt.filter(|pt| pt.len() >= 2) else {
                    continue;
                };
                let mut names = vec![n.to_string()];
                names.extend(pt.iter().filter_map(|x| str_of(x, "n").map(str::to_string)));
                let inst = str_of(p, "inst").unwrap_or("Expédition").to_string();
                let with = names.join(", ");
                fact(
                    format!("XP:{}", str_of(e, "occ").unwrap_or(id)),
                    "expeditions",
                    if pt.len() >= 4 { "epic" } else { "rare" },
                    inst.clone(),
                    format!("Avec {with}."),
                    "INV_Misc_Map02",
                    format!("Sortie à {inst} avec {with}."),
                    None,
                    Art::default(),
                );
            }
            Some("ANECDOTE") => {
                let title = str_of(p, "title").unwrap_or("Anecdote").to_string();
                let desc = str_of(p, "desc").unwrap_or("").to_string();
                fact(
                    format!("A:{id}"),
                    "faits",
                    "uncommon",
                    title.clone(),
                    desc.clone(),
                    "INV_Scroll_03",
                    format!("Anecdote racontée par {n} : {title}. {desc}"),
                    None,
                    Art::default(),
                );
            }
            // First kill of a kind of creature by a member (Collectors/Kills.lua): the guild's
            // bestiary, one card per creature, with its 3D model.
            Some("MOB_KILL") => {
                let Some(npc) = p.get("npc").and_then(Value::as_i64).filter(|n| *n > 0) else {
                    continue;
                };
                let Some(mob) = str_of(p, "name").filter(|m| !m.is_empty()) else {
                    continue;
                };
                let cls = str_of(p, "cls").unwrap_or("normal");
                let level = p
                    .get("lvl")
                    .and_then(Value::as_i64)
                    .map(|l| format!(", niveau {l}"))
                    .unwrap_or_default();
                push(Candidate {
                    id: format!("B:{npc}"),
                    series: "mobs",
                    rarity: mob_rarity(cls, false),
                    name: mob.to_string(),
                    text: format!("Vaincu pour la première fois par {n}."),
                    class: None,
                    guid: None,
                    icon: Some("Ability_Hunter_Pet_Wolf"),
                    facts: format!(
                        "Créature « {mob} » ({}{level}), tuée pour la première fois dans la guilde par {n}. Garde le nom de la créature.",
                        kind_fr(cls)
                    ),
                    ai,
                    keep_name: Some(mob.to_string()),
                    stats: None,
                    art: Art::npc(Some(npc)),
                    t,
                });
            }
            Some("DEATH") => {
                let Some(k) = p.get("killer").filter(|k| str_of(k, "n").is_some()) else {
                    continue;
                };
                let killer = str_of(k, "n").unwrap_or("?").to_string();
                let player = k.get("pl").and_then(Value::as_bool).unwrap_or(false);
                let env = k.get("env").is_some();
                let spell = str_of(k, "sp").map(str::to_string);
                if !player && !env {
                    // Killed by a creature: a terror, one per creature and member (the same
                    // creature killing the same member again adds nothing). The AI names it.
                    let npc = k
                        .get("npc")
                        .and_then(Value::as_i64)
                        .or_else(|| known.get(&killer.to_lowercase()).copied());
                    let key = npc.map_or_else(|| killer.to_lowercase(), |n| n.to_string());
                    let cls = str_of(k, "cls").unwrap_or("normal");
                    push(Candidate {
                        id: format!("T:{key}:{a}"),
                        series: "terreurs",
                        rarity: mob_rarity(cls, true),
                        name: killer.clone(),
                        text: format!("A eu la peau de {n}. Il s'en vante encore."),
                        class: None,
                        guid: None,
                        icon: Some("Ability_Rogue_FeignDeath"),
                        facts: format!(
                            "Créature « {killer} » ({}) qui a tué {n}{}. Carte « terreur » : donne-lui un prénom ou un surnom en gardant son espèce, par exemple « Sven le loup gris ».",
                            kind_fr(cls),
                            spell.as_ref().map(|s| format!(" (coup fatal : {s})")).unwrap_or_default()
                        ),
                        ai,
                        keep_name: Some(killer.clone()),
                        stats: None,
                        art: Art::npc(npc),
                        t,
                    });
                    continue;
                }
                if player {
                    let entry = killers.entry(first_name(&killer)).or_insert((
                        killer.clone(),
                        str_of(k, "c").map(str::to_string),
                        0,
                    ));
                    entry.2 += 1;
                }
                fact(
                    format!("D:{id}"),
                    "faits",
                    if player { "rare" } else { "common" },
                    format!(
                        "{n}{}{killer}",
                        if env { ", victime de " } else { ", tué par " }
                    ),
                    spell
                        .as_ref()
                        .map(|s| format!("D'un coup de « {s} ». La guilde se souvient."))
                        .unwrap_or_else(|| "Un moment de solitude, immortalisé.".into()),
                    "Ability_Rogue_FeignDeath",
                    format!(
                        "{n} est mort, {} {killer}{}.",
                        if player {
                            "tué par le joueur"
                        } else {
                            "tué par"
                        },
                        spell.map(|s| format!(" (sort : {s})")).unwrap_or_default()
                    ),
                    str_of(e, "c").map(str::to_string),
                    Art::default(),
                );
            }
            // A correction of a published article (revise.rs) is not a new article.
            Some("ARTICLE") if p.get("replaces").is_some() => {}
            Some("ARTICLE") => {
                let title = str_of(p, "title").unwrap_or("Article").to_string();
                let front = num_of(p, "order") as i64 == 1;
                fact(
                    format!("U:{id}"),
                    "une",
                    if front { "epic" } else { "rare" },
                    title.clone(),
                    format!(
                        "{}Paru le {}.",
                        str_of(p, "format")
                            .map(|f| format!("{f}. "))
                            .unwrap_or_default(),
                        chrono::DateTime::from_timestamp(t as i64, 0)
                            .map(|d| d.format("%d/%m/%Y").to_string())
                            .unwrap_or_default()
                    ),
                    "INV_Misc_Note_06",
                    format!("Article de la gazette : « {title} »."),
                    None,
                    Art::default(),
                );
            }
            // Loot (Collectors/Loot.lua): the first one in the guild to bring back an item.
            Some("RARE_ITEM") => {
                let Some(item) = p.get("id").and_then(Value::as_i64).filter(|i| *i > 0) else {
                    continue;
                };
                let name = str_of(p, "item").unwrap_or("Objet").to_string();
                let quality = num_of(p, "q") as i64;
                fact(
                    format!("I:{item}"),
                    "butin",
                    match quality {
                        5.. => "legendary",
                        4 => "epic",
                        _ => "rare",
                    },
                    name.clone(),
                    format!("Rapporté par {n}. Personne ne sait où le ranger."),
                    "INV_Misc_Bag_10",
                    format!("{n} est le premier de la guilde à obtenir l'objet « {name} »."),
                    None,
                    Art {
                        npc: None,
                        item: Some(item),
                    },
                );
            }
            Some("ENEMY_SEEN") | Some("PVP_CLASH") => {
                if let Some(name) = str_of(p, "name") {
                    let entry = met.entry(first_name(name)).or_insert((
                        name.to_string(),
                        str_of(p, "class").map(str::to_string),
                        0,
                    ));
                    entry.2 += 1;
                }
            }
            Some("ENEMY_NOTE") => {
                if p.get("sworn").and_then(Value::as_bool) == Some(true) {
                    if let Some(name) = str_of(p, "name") {
                        sworn
                            .entry(first_name(name))
                            .or_default()
                            .insert(a.to_string());
                    }
                }
            }
            _ => {}
        }
    }

    // Enemies who matter: sworn (two members), killers, met three times or more.
    let mut keys: BTreeSet<String> = met.keys().cloned().collect();
    keys.extend(killers.keys().cloned());
    keys.extend(sworn.keys().cloned());
    for key in keys {
        let votes = sworn.get(&key).map_or(0, BTreeSet::len);
        let kills = killers.get(&key).map_or(0, |k| k.2);
        let seen = met.get(&key).map_or(0, |m| m.2);
        let is_sworn = votes >= 2 || kills >= 5;
        if !(is_sworn || kills > 0 || seen >= 3) {
            continue;
        }
        let (name, class) = killers
            .get(&key)
            .or(met.get(&key))
            .map(|(n, c, _)| (n.clone(), c.clone()))
            .unwrap_or_else(|| (key.clone(), None));
        let text = if kills > 0 {
            format!("A envoyé {kills} des nôtres au cimetière.")
        } else {
            format!("{seen} rencontres. Il commence à nous connaître.")
        };
        push(Candidate {
            id: format!("E:{key}"),
            series: "sworn",
            rarity: if is_sworn {
                "epic"
            } else if kills > 0 {
                "rare"
            } else {
                "uncommon"
            },
            name: name.clone(),
            text: text.clone(),
            class,
            guid: None,
            icon: Some("Ability_DualWield"),
            facts: format!("Ennemi de la guilde : {name}. {text}"),
            ai: true,
            keep_name: Some(name),
            stats: None,
            art: Art::default(),
            t: f64::MAX,
        });
    }
    out.sort_by(|a, b| a.t.total_cmp(&b.t).then_with(|| a.id.cmp(&b.id)));
    out
}

const PROMPT: &str = "Tu es la rédaction de « La Gazette », le journal satirique d'une guilde de World of Warcraft. Avec ce numéro paraissent des cartes à collectionner de l'album de la guilde.

Pour chaque carte ci-dessous, écris :
- « nom » : le titre de la carte, {max_name} caractères au plus. Pour une carte de membre ou d'ennemi, garde son nom tel quel dans le titre (tu peux ajouter un surnom : « Dakey, l'ombre du marché »).
- « texte » : une phrase d'ambiance, {max_text} caractères au plus, drôle et bienveillante, fidèle aux faits donnés, sans rien inventer de vérifiable.
- pour les cartes marquées « combattant » : « force » et « endurance », deux entiers de 0 à {stat_max}, dont la somme reste proche du budget indiqué (à {slack} près). Répartis-les selon le personnage et les faits : qui frappe fort, qui encaisse, qui fuit.

Réponds uniquement par un objet JSON :
{\"cartes\": [{\"id\": \"…\", \"nom\": \"…\", \"texte\": \"…\", \"force\": 0, \"endurance\": 0}]}
(« force » et « endurance » seulement pour les combattants.)

Cartes :
{cards}";

/// The request sent to the AI: only the cards it may write.
pub fn prompt(cards: &[Candidate]) -> String {
    let lines: Vec<String> = cards
        .iter()
        .filter(|c| c.ai)
        .take(MAX_AI)
        .map(|c| {
            let fighter = if c.fighter() {
                format!(
                    " [combattant, budget force + endurance : {}]",
                    stat_budget(c.rarity)
                )
            } else {
                String::new()
            };
            format!("- id {} ({}){fighter} : {}", c.id, c.rarity, c.facts)
        })
        .collect();
    PROMPT
        .replace("{stat_max}", &STAT_MAX.to_string())
        .replace("{slack}", &STAT_SLACK.to_string())
        .replace("{max_name}", &MAX_NAME.to_string())
        .replace("{max_text}", &MAX_TEXT.to_string())
        .replace("{cards}", &lines.join("\n"))
}

fn json_object(text: &str) -> Option<Value> {
    let (start, end) = (text.find('{')?, text.rfind('}')?);
    if end <= start {
        return None;
    }
    serde_json::from_str(&text[start..=end]).ok()
}

fn squash(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Applies the AI's names and texts to the cards it was allowed to write; returns the
/// problems (a rejected card keeps its plain text).
pub fn apply(cards: &mut [Candidate], answer: &str) -> Vec<String> {
    let Some(data) = json_object(answer) else {
        return vec!["cartes : réponse illisible, textes simples conservés".into()];
    };
    let Some(list) = data.get("cartes").and_then(Value::as_array) else {
        return vec!["cartes : réponse sans liste « cartes », textes simples conservés".into()];
    };
    let mut notes = Vec::new();
    let mut done = 0;
    for item in list {
        let Some(id) = str_of(item, "id") else {
            continue;
        };
        let Some(card) = cards.iter_mut().find(|c| c.id == id && c.ai) else {
            notes.push(format!("cartes : id inconnu ignoré ({id})"));
            continue;
        };
        if card.fighter() {
            match (
                item.get("force").and_then(Value::as_i64),
                item.get("endurance").and_then(Value::as_i64),
            ) {
                (Some(fo), Some(en))
                    if (0..=STAT_MAX).contains(&fo)
                        && (0..=STAT_MAX).contains(&en)
                        && (fo + en - stat_budget(card.rarity)).abs() <= STAT_SLACK =>
                {
                    card.stats = Some((fo, en));
                }
                (None, None) => {}
                _ => notes.push(format!(
                    "cartes : force/endurance refusées pour {id} (hors bornes ou hors budget), règle par défaut"
                )),
            }
        }
        let name = squash(str_of(item, "nom").unwrap_or(""));
        let text = squash(str_of(item, "texte").unwrap_or(""));
        if name.is_empty() || name.chars().count() > MAX_NAME {
            notes.push(format!("cartes : nom refusé pour {id} (vide ou trop long)"));
            continue;
        }
        if let Some(keep) = &card.keep_name {
            if !name.to_lowercase().contains(&first_name(keep)) {
                notes.push(format!("cartes : « {name} » ne nomme pas {keep}, refusé"));
                continue;
            }
        }
        if text.is_empty() || text.chars().count() > MAX_TEXT {
            notes.push(format!(
                "cartes : texte refusé pour {id} (vide ou trop long)"
            ));
            continue;
        }
        card.name = name;
        card.text = text;
        done += 1;
    }
    notes.push(format!("{done} carte(s) rédigée(s) par l'IA."));
    notes
}

/// Numbers the cards after `last` and packs them into CARD_SET items for `edition`.
pub fn items(cards: &[Candidate], edition: &str, last: i64) -> Vec<Value> {
    let mut sets: Vec<Vec<Value>> = vec![Vec::new()];
    for (i, c) in cards.iter().enumerate() {
        let mut v = json!({
            "id": c.id, "no": last + 1 + i as i64, "s": c.series, "r": c.rarity, "n": c.name, "f": c.text,
        });
        if let Some(cl) = &c.class {
            v["cl"] = json!(cl);
        }
        if let Some(g) = &c.guid {
            v["g"] = json!(g);
        }
        if let Some(ic) = c.icon {
            v["ic"] = json!(ic);
        }
        if let Some((fo, en)) = c.final_stats() {
            v["fo"] = json!(fo);
            v["en"] = json!(en);
        }
        if let Some(npc) = c.art.npc {
            v["npc"] = json!(npc);
        }
        if let Some(item) = c.art.item {
            v["itm"] = json!(item);
        }
        let current = sets.last_mut().unwrap();
        current.push(v);
        let size = crate::lua::dumps_value(&json!({"set": edition, "cards": current}), 0).len();
        if size > MAX_SET_BYTES && current.len() > 1 {
            let moved = current.pop().unwrap();
            sets.push(vec![moved]);
        }
    }
    sets.into_iter()
        .filter(|s| !s.is_empty())
        .enumerate()
        .map(|(k, cards)| {
            json!({
                "id": format!("cards:{edition}:{}", k + 1),
                "kind": "CARD_SET",
                "note": format!("{} carte(s) de l'album", cards.len()),
                "p": {"set": edition, "cards": cards},
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chronicle() -> Chronicle {
        chronicle_with("")
    }

    /// The test journal, plus `extra` Lua event entries.
    fn chronicle_with(extra: &str) -> Chronicle {
        let saved = crate::lua::loads(
            &(r#"RenatusDB = { ["events"] = {"#.to_string() + extra + r#"
                ["P-A:1"] = { ["id"] = "P-A:1", ["a"] = "P-A", ["n"] = "Dakey", ["c"] = "ROGUE", ["k"] = "LEVEL_UP", ["t"] = 10, ["vis"] = "G", ["p"] = { ["lvl"] = 21 } },
                ["P-A:2"] = { ["id"] = "P-A:2", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "AI_CONSENT", ["t"] = 11, ["s"] = 2, ["vis"] = "G", ["p"] = { ["ok"] = true } },
                ["P-A:3"] = { ["id"] = "P-A:3", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "BOSS_KILL", ["t"] = 12, ["vis"] = "G", ["occ"] = "ENC:1", ["p"] = { ["enc"] = 1, ["name"] = "Hogger" } },
                ["P-B:1"] = { ["id"] = "P-B:1", ["a"] = "P-B", ["n"] = "Bob", ["c"] = "MAGE", ["k"] = "BOSS_KILL", ["t"] = 13, ["vis"] = "G", ["occ"] = "ENC:1", ["p"] = { ["enc"] = 1, ["name"] = "Hogger" } },
                ["P-B:2"] = { ["id"] = "P-B:2", ["a"] = "P-B", ["n"] = "Bob", ["k"] = "DEATH", ["t"] = 14, ["vis"] = "G", ["p"] = { ["killer"] = { ["n"] = "Ladou", ["pl"] = true, ["sp"] = "Frappe" } } },
                ["P-C:1"] = { ["id"] = "P-C:1", ["a"] = "P-C", ["n"] = "Carol", ["k"] = "CARD_PROFILE", ["t"] = 15, ["vis"] = "G", ["p"] = { ["optOut"] = true } },
                ["P-A:4"] = { ["id"] = "P-A:4", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "LEVEL_UP", ["t"] = 16, ["vis"] = "P", ["p"] = { ["lvl"] = 60 } },
            } }"#),
        )
        .unwrap();
        Chronicle::from_saved(&saved)
    }

    #[test]
    fn member_versions_are_earned() {
        let ev = |id: &str, k: &str, p: &str| {
            format!(
                r#"["{id}"] = {{ ["id"] = "{id}", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "{k}", ["t"] = 10, ["vis"] = "G", ["p"] = {{ {p} }} }},"#
            )
        };
        let cards_of = |events: Vec<String>| {
            let saved = crate::lua::loads(&format!(
                "RenatusDB = {{ [\"events\"] = {{ {} }} }}",
                events.join("\n")
            ))
            .unwrap();
            let mut ids: Vec<String> = candidates(&Chronicle::from_saved(&saved), &HashSet::new())
                .into_iter()
                .filter(|c| c.id.starts_with("M:"))
                .map(|c| c.id)
                .collect();
            ids.sort();
            ids
        };
        // on arrival: the common one only
        assert_eq!(
            cards_of(vec![ev("P-A:1", "CARD_PROFILE", r#"["lvl"] = 24"#)]),
            ["M:P-A:common"]
        );
        // five group outings: rare
        let outings: Vec<String> = (1..=5)
            .map(|i| ev(&format!("P-A:{i}"), "EXPEDITION", ""))
            .collect();
        assert_eq!(cards_of(outings), ["M:P-A:common", "M:P-A:rare"]);
        // level 60 (from the card profile): epic; with an anecdote, legendary
        let mut top = vec![ev("P-A:1", "CARD_PROFILE", r#"["lvl"] = 60"#)];
        assert_eq!(cards_of(top.clone()), ["M:P-A:common", "M:P-A:epic"]);
        top.push(ev(
            "P-A:2",
            "ANECDOTE",
            r#"["title"] = "Le saut de la falaise""#,
        ));
        assert_eq!(
            cards_of(top),
            ["M:P-A:common", "M:P-A:epic", "M:P-A:legendary"]
        );
    }

    #[test]
    fn creatures_and_items_carry_their_art() {
        let saved = crate::lua::loads(
            r#"RenatusDB = { ["events"] = {
                ["P-A:1"] = { ["id"] = "P-A:1", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "BOSS_KILL", ["t"] = 10, ["vis"] = "G", ["occ"] = "ENC:7", ["p"] = { ["enc"] = 7, ["name"] = "Boss inconnu", ["npc"] = 1234 } },
                ["P-A:2"] = { ["id"] = "P-A:2", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "BOSS_KILL", ["t"] = 11, ["vis"] = "G", ["occ"] = "ENC:8", ["p"] = { ["enc"] = 8, ["name"] = "Edwin VanCleef" } },
                ["P-A:3"] = { ["id"] = "P-A:3", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "DEATH", ["t"] = 12, ["vis"] = "G", ["p"] = { ["killer"] = { ["n"] = "Loup affamé", ["npc"] = 299, ["cls"] = "elite" } } },
                ["P-A:6"] = { ["id"] = "P-A:6", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "DEATH", ["t"] = 16, ["vis"] = "G", ["p"] = { ["killer"] = { ["n"] = "Loup affamé", ["npc"] = 299 } } },
                ["P-B:2"] = { ["id"] = "P-B:2", ["a"] = "P-B", ["n"] = "Bob", ["k"] = "DEATH", ["t"] = 17, ["vis"] = "G", ["p"] = { ["killer"] = { ["n"] = "Loup affamé", ["npc"] = 299 } } },
                ["P-B:6"] = { ["id"] = "P-B:6", ["a"] = "P-B", ["n"] = "Bob", ["k"] = "DEATH", ["t"] = 9, ["vis"] = "G", ["p"] = { ["killer"] = { ["n"] = "Traqueuse Ronce-sauvage" } } },
                ["P-B:3"] = { ["id"] = "P-B:3", ["a"] = "P-B", ["n"] = "Bob", ["k"] = "DEATH", ["t"] = 18, ["vis"] = "G", ["p"] = { ["killer"] = { ["n"] = "Chute", ["env"] = "Falling" } } },
                ["P-A:7"] = { ["id"] = "P-A:7", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "MOB_KILL", ["t"] = 19, ["vis"] = "G", ["p"] = { ["npc"] = 3819, ["name"] = "Traqueuse Ronce-sauvage", ["cls"] = "normal", ["lvl"] = 22 } },
                ["P-B:4"] = { ["id"] = "P-B:4", ["a"] = "P-B", ["n"] = "Bob", ["k"] = "MOB_KILL", ["t"] = 20, ["vis"] = "G", ["p"] = { ["npc"] = 3819, ["name"] = "Traqueuse Ronce-sauvage" } },
                ["P-B:5"] = { ["id"] = "P-B:5", ["a"] = "P-B", ["n"] = "Bob", ["k"] = "MOB_KILL", ["t"] = 21, ["vis"] = "G", ["p"] = { ["npc"] = 1000, ["name"] = "Ours rare", ["cls"] = "rareelite" } },
                ["P-A:4"] = { ["id"] = "P-A:4", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "DEATH", ["t"] = 13, ["vis"] = "G", ["p"] = { ["killer"] = { ["n"] = "Edwin VanCleef", ["pl"] = true } } },
                ["P-A:5"] = { ["id"] = "P-A:5", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "RARE_ITEM", ["t"] = 14, ["vis"] = "G", ["p"] = { ["item"] = "Lame de Cruel", ["id"] = 5191, ["q"] = 4 } },
                ["P-B:1"] = { ["id"] = "P-B:1", ["a"] = "P-B", ["n"] = "Bob", ["k"] = "RARE_ITEM", ["t"] = 15, ["vis"] = "G", ["p"] = { ["item"] = "Lame de Cruel", ["id"] = 5191, ["q"] = 4 } },
            } }"#,
        )
        .unwrap();
        let cards = candidates(&Chronicle::from_saved(&saved), &HashSet::new());
        let art = |id: &str| cards.iter().find(|c| c.id == id).map(|c| c.art);
        assert_eq!(
            art("X:ENC:7").unwrap().npc,
            Some(1234),
            "npc id from the game"
        );
        let vancleef = known_creatures()["edwin vancleef"];
        assert_eq!(
            art("X:ENC:8").unwrap().npc,
            Some(vancleef),
            "base set creature, by name"
        );
        // killed by a creature: a terror per creature and member, never twice
        let terrors: Vec<&Candidate> = cards
            .iter()
            .filter(|c| c.series == "terreurs" && c.id.starts_with("T:299:"))
            .collect();
        let ids: Vec<&str> = terrors.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(
            ids,
            ["T:299:P-A", "T:299:P-B"],
            "Dakey killed twice: one card"
        );
        assert_eq!(terrors[0].art.npc, Some(299));
        assert_eq!(terrors[0].rarity, "epic", "an elite terror");
        assert_eq!(terrors[1].rarity, "rare");
        assert_eq!(
            terrors[0].keep_name.as_deref(),
            Some("Loup affamé"),
            "the AI keeps the species"
        );
        assert!(terrors[0].fighter() && terrors[0].final_stats().is_some());
        assert!(
            !cards.iter().any(|c| c.id == "D:P-A:3"),
            "no death card for a creature kill"
        );
        assert_eq!(
            art("D:P-A:4").unwrap().npc,
            None,
            "killed by a player: a death card"
        );
        assert!(art("D:P-B:3").is_some(), "a fall: a death card");
        // a death without the npc id borrows it from the bestiary
        assert_eq!(art("T:3819:P-B").unwrap().npc, Some(3819));
        // bestiary: one card per creature, the first killer named
        let mobs: Vec<&Candidate> = cards.iter().filter(|c| c.series == "mobs").collect();
        assert_eq!(mobs.len(), 2);
        let traqueuse = mobs.iter().find(|c| c.id == "B:3819").unwrap();
        assert_eq!(
            (traqueuse.rarity, traqueuse.art.npc),
            ("common", Some(3819))
        );
        assert!(traqueuse.text.contains("Dakey"));
        assert_eq!(
            mobs.iter().find(|c| c.id == "B:1000").unwrap().rarity,
            "epic"
        );
        let item = cards.iter().find(|c| c.id == "I:5191").unwrap();
        assert_eq!(
            (item.series, item.rarity, item.art.item),
            ("butin", "epic", Some(5191))
        );
        assert_eq!(
            cards.iter().filter(|c| c.id == "I:5191").count(),
            1,
            "the first one only"
        );
        assert!(item.text.contains("Dakey"));
        let set = items(&cards, "E1", 0);
        let all: Vec<&Value> = set
            .iter()
            .flat_map(|s| s["p"]["cards"].as_array().unwrap())
            .collect();
        assert!(all.iter().any(|c| c["id"] == "I:5191" && c["itm"] == 5191));
        assert!(all.iter().any(|c| c["id"] == "X:ENC:7" && c["npc"] == 1234));
    }

    #[test]
    fn rules_choose_the_cards() {
        let ch = chronicle();
        let cards = candidates(&ch, &HashSet::new());
        let ids: Vec<&str> = cards.iter().map(|c| c.id.as_str()).collect();
        for id in [
            "M:P-A:common",
            "L:P-A:10",
            "L:P-A:20",
            "M:P-B:common",
            "X:ENC:1",
            "D:P-B:2",
            "E:ladou",
        ] {
            assert!(ids.contains(&id), "{id} missing from {ids:?}");
        }
        assert!(!ids.contains(&"L:P-A:30"), "private level ignored");
        for id in ["M:P-A:rare", "M:P-A:epic", "M:P-A:legendary"] {
            assert!(!ids.contains(&id), "{id}: not earned yet");
        }
        assert!(
            !ids.iter().any(|i| i.contains("P-C")),
            "opted out of the album"
        );
        let boss = cards.iter().find(|c| c.id == "X:ENC:1").unwrap();
        assert_eq!(boss.rarity, "epic", "two members");
        assert_eq!(boss.text, "Vaincu par Bob, Dakey.");
        assert!(cards.iter().find(|c| c.id == "M:P-A:common").unwrap().ai);
        assert!(
            !cards.iter().find(|c| c.id == "M:P-B:common").unwrap().ai,
            "Bob did not agree to the AI"
        );
        // already published: left out
        let done: HashSet<String> = ["X:ENC:1".to_string()].into();
        assert!(!candidates(&ch, &done).iter().any(|c| c.id == "X:ENC:1"));
    }

    #[test]
    fn ai_answer_is_checked() {
        // Dakey has earned every version of the card (25 bosses)
        let bosses: String = (1..=25)
            .map(|i| format!(r#"["P-A:b{i}"] = {{ ["id"] = "P-A:b{i}", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "BOSS_KILL", ["t"] = 20, ["vis"] = "G", ["p"] = {{ ["enc"] = {i}, ["name"] = "Boss {i}" }} }},"#))
            .collect();
        let ch = chronicle_with(&bosses);
        let mut cards = candidates(&ch, &HashSet::new());
        let p = prompt(&cards);
        assert!(p.contains("M:P-A:epic") && !p.contains("M:P-B:common"));
        let answer = r#"Voici : {"cartes": [
            {"id": "M:P-A:epic", "nom": "Dakey, l'ombre du marché", "texte": "Vend tout, même ce qui n'est pas à lui.", "force": 9, "endurance": 5},
            {"id": "M:P-A:legendary", "nom": "Dakey le colosse", "texte": "Trop fort.", "force": 12, "endurance": 12},
            {"id": "M:P-A:rare", "nom": "Un voleur", "texte": "Sans nom."},
            {"id": "M:P-B:common", "nom": "Bob le magnifique", "texte": "Non consentant."},
            {"id": "L:P-A:10", "nom": "Dakey niveau 10", "texte": ""}
        ]}"#;
        let notes = apply(&mut cards, answer);
        let get = |id: &str| cards.iter().find(|c| c.id == id).unwrap();
        assert_eq!(get("M:P-A:epic").name, "Dakey, l'ombre du marché");
        assert_eq!(
            get("M:P-A:rare").name,
            "Dakey",
            "must keep the member's name"
        );
        assert_eq!(get("M:P-B:common").name, "Bob", "not allowed for Bob");
        assert_eq!(
            get("L:P-A:10").text,
            "Niveau 10 atteint. Le plus dur reste à venir, comme toujours."
        );
        assert!(notes.iter().any(|n| n.contains("2 carte(s) rédigée(s)")));
        assert_eq!(get("M:P-A:epic").final_stats(), Some((9, 5)), "AI stats");
        assert_eq!(
            get("M:P-A:legendary").final_stats(),
            Some(default_stats("legendary", Some("ROGUE"))),
            "over budget: the rule"
        );
        assert!(notes.iter().any(|n| n.contains("hors budget")));
        assert_eq!(
            get("L:P-A:10").final_stats(),
            Some((2, 2)),
            "common rogue: 2 / 2"
        );
        let set = items(&cards, "e", 0);
        let first = &set[0]["p"]["cards"][0];
        assert!(first.get("fo").is_some() || first["s"] != "members");
    }

    #[test]
    fn numbered_and_split_under_the_sync_limit() {
        let ch = chronicle();
        let mut cards = candidates(&ch, &HashSet::new());
        for c in &mut cards {
            c.text = "x".repeat(MAX_TEXT);
        }
        let many: Vec<Candidate> = (0..6).flat_map(|_| cards.clone()).collect();
        let sets = items(&many, "E1", 41);
        assert!(sets.len() > 1, "split");
        let first = &sets[0]["p"]["cards"][0];
        assert_eq!(first["no"], 42);
        for s in &sets {
            assert!(crate::lua::dumps_value(&s["p"], 0).len() <= MAX_SET_BYTES + 400);
            assert_eq!(s["kind"], "CARD_SET");
        }
        let last_set = sets.last().unwrap()["p"]["cards"].as_array().unwrap();
        assert_eq!(
            last_set.last().unwrap()["no"],
            41 + many.len() as i64,
            "numbers follow each other"
        );
        let (ids, max) = published(&ch, &sets);
        assert_eq!(max, 41 + many.len() as i64);
        assert!(ids.contains("X:ENC:1"));
    }
}
