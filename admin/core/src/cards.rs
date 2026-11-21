//! Album cards proposed with each gazette issue (CARD_SET items in Press.lua).
//!
//! Which facts deserve a card is decided here, by fixed rules (the same id schemes as the
//! addon's former local catalogue, `Album.Legacy`): members (four variants each), every
//! ten levels, first kill of a boss, outings of two members or more, anecdotes, deaths with
//! a known killer, published articles, enemies who matter. The AI only writes each card's
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
    t: f64,
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
            Some("LEVEL_UP") => m.level = m.level.max(num_of(p, "lvl") as i64),
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
            t: m.first,
        };
        let who = format!("{} ({})", m.name, m.class.as_deref().unwrap_or("?"));
        push(base(
            format!("M:{guid}:common"),
            "common",
            "Membre de la guilde.".into(),
            format!("Carte de membre de {who}, la plus simple."),
        ));
        push(base(
            format!("M:{guid}:rare"),
            "rare",
            format!("{} expéditions, {} boss vaincus.", m.expeditions, m.bosses),
            format!(
                "{who} : {} expéditions, {} boss vaincus.",
                m.expeditions, m.bosses
            ),
        ));
        push(base(
            format!("M:{guid}:epic"),
            "epic",
            "Un destin encore à écrire.".into(),
            format!("{who}, version épique : un titre flatteur ou moqueur."),
        ));
        let legend = m
            .anecdote
            .as_ref()
            .map(|a| format!("Souvenir : {a}"))
            .unwrap_or_else(|| "Légende en devenir.".into());
        push(base(
            format!("M:{guid}:legendary"),
            "legendary",
            legend.clone(),
            format!("{who}, version légendaire. {legend}"),
        ));
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
                        class: Option<String>| {
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
                );
            }
            Some("DEATH") => {
                let Some(k) = p.get("killer").filter(|k| str_of(k, "n").is_some()) else {
                    continue;
                };
                let killer = str_of(k, "n").unwrap_or("?").to_string();
                let player = k.get("pl").and_then(Value::as_bool).unwrap_or(false);
                let env = k.get("env").is_some();
                let spell = str_of(k, "sp").map(str::to_string);
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
                );
            }
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

Réponds uniquement par un objet JSON :
{\"cartes\": [{\"id\": \"…\", \"nom\": \"…\", \"texte\": \"…\"}]}

Cartes :
{cards}";

/// The request sent to the AI: only the cards it may write.
pub fn prompt(cards: &[Candidate]) -> String {
    let lines: Vec<String> = cards
        .iter()
        .filter(|c| c.ai)
        .take(MAX_AI)
        .map(|c| format!("- id {} ({}) : {}", c.id, c.rarity, c.facts))
        .collect();
    PROMPT
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
        let saved = crate::lua::loads(
            r#"RenatusDB = { ["events"] = {
                ["P-A:1"] = { ["id"] = "P-A:1", ["a"] = "P-A", ["n"] = "Dakey", ["c"] = "ROGUE", ["k"] = "LEVEL_UP", ["t"] = 10, ["vis"] = "G", ["p"] = { ["lvl"] = 21 } },
                ["P-A:2"] = { ["id"] = "P-A:2", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "AI_CONSENT", ["t"] = 11, ["s"] = 2, ["vis"] = "G", ["p"] = { ["ok"] = true } },
                ["P-A:3"] = { ["id"] = "P-A:3", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "BOSS_KILL", ["t"] = 12, ["vis"] = "G", ["occ"] = "ENC:1", ["p"] = { ["enc"] = 1, ["name"] = "Hogger" } },
                ["P-B:1"] = { ["id"] = "P-B:1", ["a"] = "P-B", ["n"] = "Bob", ["c"] = "MAGE", ["k"] = "BOSS_KILL", ["t"] = 13, ["vis"] = "G", ["occ"] = "ENC:1", ["p"] = { ["enc"] = 1, ["name"] = "Hogger" } },
                ["P-B:2"] = { ["id"] = "P-B:2", ["a"] = "P-B", ["n"] = "Bob", ["k"] = "DEATH", ["t"] = 14, ["vis"] = "G", ["p"] = { ["killer"] = { ["n"] = "Ladou", ["pl"] = true, ["sp"] = "Frappe" } } },
                ["P-C:1"] = { ["id"] = "P-C:1", ["a"] = "P-C", ["n"] = "Carol", ["k"] = "CARD_PROFILE", ["t"] = 15, ["vis"] = "G", ["p"] = { ["optOut"] = true } },
                ["P-A:4"] = { ["id"] = "P-A:4", ["a"] = "P-A", ["n"] = "Dakey", ["k"] = "LEVEL_UP", ["t"] = 16, ["vis"] = "P", ["p"] = { ["lvl"] = 60 } },
            } }"#,
        )
        .unwrap();
        Chronicle::from_saved(&saved)
    }

    #[test]
    fn rules_choose_the_cards() {
        let ch = chronicle();
        let cards = candidates(&ch, &HashSet::new());
        let ids: Vec<&str> = cards.iter().map(|c| c.id.as_str()).collect();
        for id in [
            "M:P-A:common",
            "M:P-A:legendary",
            "L:P-A:10",
            "L:P-A:20",
            "M:P-B:rare",
            "X:ENC:1",
            "D:P-B:2",
            "E:ladou",
        ] {
            assert!(ids.contains(&id), "{id} missing from {ids:?}");
        }
        assert!(!ids.contains(&"L:P-A:30"), "private level ignored");
        assert!(
            !ids.iter().any(|i| i.contains("P-C")),
            "opted out of the album"
        );
        let boss = cards.iter().find(|c| c.id == "X:ENC:1").unwrap();
        assert_eq!(boss.rarity, "epic", "two members");
        assert_eq!(boss.text, "Vaincu par Bob, Dakey.");
        assert!(cards.iter().find(|c| c.id == "M:P-A:rare").unwrap().ai);
        assert!(
            !cards.iter().find(|c| c.id == "M:P-B:rare").unwrap().ai,
            "Bob did not agree to the AI"
        );
        // already published: left out
        let done: HashSet<String> = ["X:ENC:1".to_string()].into();
        assert!(!candidates(&ch, &done).iter().any(|c| c.id == "X:ENC:1"));
    }

    #[test]
    fn ai_answer_is_checked() {
        let ch = chronicle();
        let mut cards = candidates(&ch, &HashSet::new());
        let p = prompt(&cards);
        assert!(p.contains("M:P-A:epic") && !p.contains("M:P-B:epic"));
        let answer = r#"Voici : {"cartes": [
            {"id": "M:P-A:epic", "nom": "Dakey, l'ombre du marché", "texte": "Vend tout, même ce qui n'est pas à lui."},
            {"id": "M:P-A:rare", "nom": "Un voleur", "texte": "Sans nom."},
            {"id": "M:P-B:epic", "nom": "Bob le magnifique", "texte": "Non consentant."},
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
        assert_eq!(get("M:P-B:epic").name, "Bob", "not allowed for Bob");
        assert_eq!(
            get("L:P-A:10").text,
            "Niveau 10 atteint. Le plus dur reste à venir, comme toujours."
        );
        assert!(notes.iter().any(|n| n.contains("1 carte(s) rédigée(s)")));
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
