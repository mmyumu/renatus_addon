//! Corrections of what is already published: album cards (CARD_SET) and gazette articles
//! (ARTICLE). Reads them as the addon resolves them (Renatus/Core/Album.lua,
//! Album.Published; Renatus/Core/Views.lua, Views.Revise) and writes the corrections as
//! Press.lua items that an officer publishes in game:
//! - a card: a CARD_SET holding that card again (same id: the addon keeps its first number,
//!   date and slot, and owners see the new content), or `{ id, del = true }` to withdraw it
//!   from the catalogue (owners keep it). Publishing it again brings it back.
//! - an article: an ARTICLE whose `replaces` is the original's id (title, body, pull quote,
//!   format, style; an empty string clears one), or with `retract` to withdraw it. A
//!   correction carries neither `edition` nor `refs`: it is not a new article for the next
//!   issue (issues.rs) nor a new card (cards.rs).
//!
//! The base set shipped with the addon (Renatus/Core/Cards.lua, exported to base_cards.json)
//! is corrected and withdrawn the same way, by its ids; its cards keep their B-xxx number.
//!
//! The addon only accepts corrections from an officer (or the article's author); this side
//! has no roster, so it shows every correction it finds.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::chronicle::{num_of, payload, str_of, Chronicle};
use crate::gazette::{MAX_BODY, MAX_QUOTE, MAX_TITLE};

pub const RARITIES: &[&str] = &["common", "uncommon", "rare", "epic", "legendary"];
/// Same bounds as the addon (Album.FromPayload).
pub const STAT_MAX: i64 = 12;
const MAX_NAME: usize = 60;
const MAX_FLAVOR: usize = 200;
const MAX_LABEL: usize = 40;

fn by_time<'a>(events: impl Iterator<Item = &'a Value>) -> Vec<&'a Value> {
    let mut list: Vec<&Value> = events.filter(|e| str_of(e, "vis") == Some("G")).collect();
    list.sort_by(|a, b| {
        num_of(a, "t")
            .total_cmp(&num_of(b, "t"))
            .then_with(|| str_of(a, "id").cmp(&str_of(b, "id")))
    });
    list
}

fn waiting(pending: &[Value], prefix: &str) -> bool {
    pending
        .iter()
        .any(|i| str_of(i, "id").is_some_and(|id| id.starts_with(prefix)))
}

fn chars(s: &str) -> usize {
    s.chars().count()
}

// ---------------------------------------------------------------------------
// Album cards
// ---------------------------------------------------------------------------

pub fn card_prefix(id: &str) -> String {
    format!("fix:card:{id}:")
}

/// A card of the published catalogue, as the addon resolves it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublishedCard {
    /// The card as last published (a CARD_SET entry), with its first number.
    pub card: Value,
    /// First publication.
    pub t: f64,
    /// Latest correction.
    pub revised: Option<f64>,
    /// Out of the catalogue (owners keep it).
    pub withdrawn: bool,
    /// A correction of it waits in Press.lua.
    pub pending: bool,
    /// Card of the base set, shipped with the addon (Renatus/Core/Cards.lua).
    pub base: bool,
}

/// The base set (Renatus/Core/Cards.lua) as CARD_SET entries, exported by
/// tools/export_base_cards.lua (tests/run.lua checks it is up to date).
const BASE_CARDS: &str = include_str!("base_cards.json");

/// Release date and cards of the base set.
pub fn base_set() -> (f64, Vec<Value>) {
    let data: Value = serde_json::from_str(BASE_CARDS).unwrap_or_default();
    let cards = data
        .get("cards")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    (num_of(&data, "date"), cards)
}

/// The catalogue members see: the base set, then the published cards in order of first
/// publication, each with its latest correction.
pub fn catalogue(ch: &Chronicle, pending: &[Value]) -> Vec<PublishedCard> {
    let mut list: Vec<PublishedCard> = Vec::new();
    let mut slot: HashMap<String, usize> = HashMap::new();
    let (date, base) = base_set();
    for c in base {
        let Some(id) = str_of(&c, "id") else { continue };
        slot.insert(id.to_string(), list.len());
        list.push(PublishedCard {
            card: c,
            t: date,
            revised: None,
            withdrawn: false,
            pending: false,
            base: true,
        });
    }
    for e in by_time(ch.of_kind("CARD_SET")) {
        let t = num_of(e, "t");
        for c in payload(e)
            .get("cards")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let Some(id) = str_of(c, "id") else { continue };
            if c.get("del").and_then(Value::as_bool) == Some(true) {
                if let Some(&i) = slot.get(id) {
                    list[i].withdrawn = true;
                }
                continue;
            }
            let valid = str_of(c, "n").is_some_and(|n| !n.is_empty())
                && str_of(c, "r").is_some_and(|r| RARITIES.contains(&r));
            if !valid {
                continue;
            }
            match slot.get(id) {
                Some(&i) => {
                    let mut card = c.clone();
                    card["no"] = list[i].card["no"].clone();
                    list[i].card = card;
                    list[i].revised = Some(t);
                    list[i].withdrawn = false;
                }
                None => {
                    slot.insert(id.to_string(), list.len());
                    list.push(PublishedCard {
                        card: c.clone(),
                        t,
                        revised: None,
                        withdrawn: false,
                        pending: false,
                        base: false,
                    });
                }
            }
        }
    }
    for pc in &mut list {
        let id = str_of(&pc.card, "id").unwrap_or_default().to_string();
        pc.pending = waiting(pending, &card_prefix(&id));
    }
    list
}

/// What the editor changes on a card; the rest (number, series, member, model) stays.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CardEdit {
    pub id: String,
    pub name: String,
    pub flavor: String,
    pub rarity: String,
    /// Icon file name (Interface\Icons\...); empty: the series' default.
    #[serde(default)]
    pub icon: String,
    /// Force and endurance, both or neither (neither: the addon's rule by rarity and class).
    pub force: Option<i64>,
    pub endurance: Option<i64>,
}

fn card_set(id: &str, card: Value, now: i64) -> Value {
    json!({
        "id": format!("{}{now}", card_prefix(id)),
        "kind": "CARD_SET",
        "p": {"set": format!("fix:{now}"), "cards": [card]},
    })
}

fn find_card(ch: &Chronicle, id: &str) -> Result<PublishedCard, String> {
    catalogue(ch, &[])
        .into_iter()
        .find(|c| str_of(&c.card, "id") == Some(id))
        .ok_or_else(|| format!("Carte {id} absente du catalogue publié."))
}

/// A correction of a published card (also brings a withdrawn one back).
pub fn card_item(ch: &Chronicle, edit: &CardEdit, now: i64) -> Result<Value, String> {
    let current = find_card(ch, &edit.id)?;
    let name = edit.name.trim();
    let flavor = edit.flavor.trim();
    let icon = edit.icon.trim();
    if name.is_empty() || chars(name) > MAX_NAME {
        return Err(format!("Nom : 1 à {MAX_NAME} caractères."));
    }
    if chars(flavor) > MAX_FLAVOR {
        return Err(format!("Texte : {MAX_FLAVOR} caractères au plus."));
    }
    if !RARITIES.contains(&edit.rarity.as_str()) {
        return Err(format!("Rareté inconnue : {}.", edit.rarity));
    }
    if chars(icon) > 80 || !icon.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err("Icône : un nom de fichier d'icône (lettres, chiffres, _).".into());
    }
    let mut card = current.card;
    let obj = card.as_object_mut().ok_or("Carte illisible.")?;
    obj.insert("n".into(), json!(name));
    obj.insert("f".into(), json!(flavor));
    obj.insert("r".into(), json!(edit.rarity));
    if icon.is_empty() {
        obj.remove("ic");
    } else {
        obj.insert("ic".into(), json!(icon));
    }
    match (edit.force, edit.endurance) {
        (Some(fo), Some(en)) => {
            if !(0..=STAT_MAX).contains(&fo) || !(0..=STAT_MAX).contains(&en) {
                return Err(format!("Force et endurance : de 0 à {STAT_MAX}."));
            }
            obj.insert("fo".into(), json!(fo));
            obj.insert("en".into(), json!(en));
        }
        (None, None) => {
            obj.remove("fo");
            obj.remove("en");
            obj.remove("it");
        }
        _ => return Err("Force et endurance : les deux, ou aucune.".into()),
    }
    Ok(card_set(&edit.id, card, now))
}

/// Withdraws a published card from the catalogue (owners keep it).
pub fn withdraw_card_item(ch: &Chronicle, id: &str, now: i64) -> Result<Value, String> {
    let current = find_card(ch, id)?;
    if current.withdrawn {
        return Err("Cette carte est déjà retirée.".into());
    }
    Ok(card_set(id, json!({"id": id, "del": true}), now))
}

// ---------------------------------------------------------------------------
// Gazette articles
// ---------------------------------------------------------------------------

pub fn article_prefix(id: &str) -> String {
    format!("fix:article:{id}:")
}

/// A published article, as the addon resolves it (latest correction applied).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublishedArticle {
    pub id: String,
    pub t: f64,
    pub title: String,
    pub body: String,
    pub quote: Option<String>,
    pub format: Option<String>,
    pub style: Option<String>,
    pub order: Option<i64>,
    pub ia: bool,
    pub revised: Option<f64>,
    pub withdrawn: bool,
    pub pending: bool,
}

/// An issue of the gazette: its published articles.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Issue {
    /// p.edition (None: articles from before issues existed).
    pub key: Option<String>,
    pub number: usize,
    pub t: f64,
    pub articles: Vec<PublishedArticle>,
}

fn opt(p: &Value, key: &str) -> Option<String> {
    str_of(p, key).filter(|s| !s.is_empty()).map(str::to_string)
}

/// Fields of a correction applied to an article; an empty string clears an optional one.
fn apply(a: &mut PublishedArticle, p: &Value) {
    if let Some(s) = opt(p, "title") {
        a.title = s;
    }
    if let Some(s) = opt(p, "body") {
        a.body = s;
    }
    for (key, field) in [
        ("quote", &mut a.quote),
        ("format", &mut a.format),
        ("style", &mut a.style),
    ] {
        if let Some(s) = str_of(p, key) {
            *field = (!s.is_empty()).then(|| s.to_string());
        }
    }
    a.ia = p.get("ia").and_then(Value::as_bool) == Some(true);
}

/// Published issues, most recent first, with their articles in editorial order.
pub fn archive(ch: &Chronicle, pending: &[Value]) -> Vec<Issue> {
    let events = by_time(ch.of_kind("ARTICLE"));
    let replaces = |e: &Value| str_of(payload(e), "replaces").map(str::to_string);
    let fix_of: HashMap<String, String> = events
        .iter()
        .filter_map(|e| Some((str_of(e, "id")?.to_string(), replaces(e)?)))
        .collect();
    let root = |mut id: String| {
        for _ in 0..50 {
            match fix_of.get(&id) {
                Some(next) => id = next.clone(),
                None => break,
            }
        }
        id
    };
    // Latest correction of each original (events are sorted by time).
    let mut latest: HashMap<String, &Value> = HashMap::new();
    for e in &events {
        if let Some(target) = replaces(e) {
            latest.insert(root(target), e);
        }
    }
    let mut issues: Vec<Issue> = Vec::new();
    for e in events.iter().filter(|e| replaces(e).is_none()) {
        let Some(id) = str_of(e, "id") else { continue };
        let p = payload(e);
        let mut a = PublishedArticle {
            id: id.to_string(),
            t: num_of(e, "t"),
            title: str_of(p, "title").unwrap_or("(sans titre)").to_string(),
            body: str_of(p, "body").unwrap_or_default().to_string(),
            quote: opt(p, "quote"),
            format: opt(p, "format"),
            style: opt(p, "style"),
            order: p.get("order").and_then(Value::as_f64).map(|n| n as i64),
            ia: p.get("ia").and_then(Value::as_bool) == Some(true),
            revised: None,
            withdrawn: false,
            pending: waiting(pending, &article_prefix(id)),
        };
        if let Some(fix) = latest.get(id) {
            let fp = payload(fix);
            a.revised = Some(num_of(fix, "t"));
            if fp.get("retract").and_then(Value::as_bool) == Some(true) {
                a.withdrawn = true;
            } else {
                apply(&mut a, fp);
            }
        }
        let key = opt(p, "edition");
        let issue = match issues.iter_mut().find(|i| i.key == key) {
            Some(i) => i,
            None => {
                issues.push(Issue {
                    key,
                    number: 0,
                    t: 0.0,
                    articles: Vec::new(),
                });
                issues.last_mut().unwrap()
            }
        };
        issue.t = issue.t.max(a.t);
        issue.articles.push(a);
    }
    issues.sort_by(|a, b| a.t.total_cmp(&b.t));
    for (n, issue) in issues.iter_mut().enumerate() {
        issue.number = n + 1;
        issue.articles.sort_by(|x, y| {
            x.order
                .unwrap_or(99)
                .cmp(&y.order.unwrap_or(99))
                .then_with(|| y.t.total_cmp(&x.t))
        });
    }
    issues.reverse();
    issues
}

/// What the editor changes on an article.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArticleEdit {
    pub id: String,
    pub title: String,
    pub body: String,
    #[serde(default)]
    pub quote: String,
    #[serde(default)]
    pub format: String,
    #[serde(default)]
    pub style: String,
}

fn find_article(ch: &Chronicle, id: &str) -> Result<PublishedArticle, String> {
    archive(ch, &[])
        .into_iter()
        .flat_map(|i| i.articles)
        .find(|a| a.id == id)
        .ok_or_else(|| format!("Article {id} absent des numéros publiés."))
}

fn article_fix(id: &str, p: Value, now: i64) -> Value {
    json!({"id": format!("{}{now}", article_prefix(id)), "kind": "ARTICLE", "p": p})
}

/// A correction of a published article (also brings a withdrawn one back).
pub fn article_item(ch: &Chronicle, edit: &ArticleEdit, now: i64) -> Result<Value, String> {
    let current = find_article(ch, &edit.id)?;
    let title = edit.title.trim();
    let body = edit.body.trim();
    let quote = edit.quote.trim();
    let format = edit.format.trim();
    let style = edit.style.trim();
    if title.is_empty() || chars(title) > MAX_TITLE {
        return Err(format!("Titre : 1 à {MAX_TITLE} caractères."));
    }
    if body.is_empty() || chars(body) > MAX_BODY {
        return Err(format!("Texte : 1 à {MAX_BODY} caractères."));
    }
    if chars(quote) > MAX_QUOTE {
        return Err(format!("Citation : {MAX_QUOTE} caractères au plus."));
    }
    if chars(format) > MAX_LABEL || chars(style) > MAX_LABEL {
        return Err(format!(
            "Rubrique et style : {MAX_LABEL} caractères au plus."
        ));
    }
    let mut p = json!({
        "replaces": edit.id, "title": title, "body": body,
        "quote": quote, "format": format, "style": style,
    });
    if current.ia {
        p["ia"] = json!(true);
    }
    Ok(article_fix(&edit.id, p, now))
}

/// Withdraws a published article from its issue.
pub fn retract_article_item(ch: &Chronicle, id: &str, now: i64) -> Result<Value, String> {
    let current = find_article(ch, id)?;
    if current.withdrawn {
        return Err("Cet article est déjà retiré.".into());
    }
    Ok(article_fix(
        id,
        json!({"replaces": id, "retract": true, "title": current.title}),
        now,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Map;

    fn ev(id: &str, k: &str, t: f64, p: Value) -> Value {
        json!({"id": id, "a": "A", "n": "Off", "k": k, "t": t, "vis": "G", "s": 1, "p": p})
    }

    fn chronicle(events: Vec<Value>) -> Chronicle {
        let mut map = Map::new();
        for e in events {
            map.insert(e["id"].as_str().unwrap().to_string(), e);
        }
        Chronicle {
            events: map,
            press_done: Map::new(),
        }
    }

    fn card(id: &str, no: i64, name: &str) -> Value {
        json!({"id": id, "no": no, "s": "expeditions", "r": "rare", "n": name, "f": "Texte", "fo": 3, "en": 4})
    }

    #[test]
    fn catalogue_keeps_first_number_applies_corrections_and_withdrawals() {
        let ch = chronicle(vec![
            ev(
                "A:1",
                "CARD_SET",
                10.0,
                json!({"set": "E1", "cards": [card("X:1", 1, "Hogger"), card("X:2", 2, "Bob")]}),
            ),
            ev(
                "A:2",
                "CARD_SET",
                20.0,
                json!({"set": "fix:20", "cards": [card("X:1", 99, "Hogger, enfin")]}),
            ),
            ev(
                "A:3",
                "CARD_SET",
                30.0,
                json!({"set": "fix:30", "cards": [{"id": "X:2", "del": true}]}),
            ),
        ]);
        let pending = vec![json!({"id": "fix:card:X:2:40", "kind": "CARD_SET"})];
        let all = catalogue(&ch, &pending);
        let list: Vec<&PublishedCard> = all.iter().filter(|c| !c.base).collect();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].card["n"], "Hogger, enfin");
        assert_eq!(list[0].card["no"], 1, "first number kept");
        assert_eq!((list[0].t, list[0].revised), (10.0, Some(20.0)));
        assert!(!list[0].pending);
        assert!(list[1].withdrawn && list[1].pending);
    }

    #[test]
    fn base_set_is_listed_and_corrected_by_id() {
        let (date, base) = base_set();
        assert!(base.len() > 100, "base_cards.json read");
        assert!(date > 0.0);
        let ch = chronicle(vec![ev(
            "A:1",
            "CARD_SET",
            date + 10.0,
            json!({"set": "fix:1", "cards": [{"id": "AZ:est:elwynn", "del": true}]}),
        )]);
        let list = catalogue(&ch, &[]);
        let elwynn = list
            .iter()
            .find(|c| c.card["id"] == "AZ:est:elwynn")
            .unwrap();
        assert!(elwynn.base && elwynn.withdrawn);
        assert_eq!(elwynn.card["no"], "B-001");
        let edit = CardEdit {
            id: "AZ:est:elwynn".into(),
            name: "Elwynn".into(),
            flavor: "Des loups.".into(),
            rarity: "rare".into(),
            icon: String::new(),
            force: None,
            endurance: None,
        };
        let item = card_item(&ch, &edit, 99).unwrap();
        let c = &item["p"]["cards"][0];
        assert_eq!(
            (c["id"].as_str(), c["no"].as_str(), c["s"].as_str()),
            (Some("AZ:est:elwynn"), Some("B-001"), Some("est"))
        );
        assert!(
            c.get("ic").is_none(),
            "empty icon: the card's own candidates"
        );
    }

    #[test]
    fn card_correction_is_checked_and_keeps_the_rest() {
        let ch = chronicle(vec![ev(
            "A:1",
            "CARD_SET",
            10.0,
            json!({"set": "E1", "cards": [card("X:1", 7, "Hogger")]}),
        )]);
        let mut edit = CardEdit {
            id: "X:1".into(),
            name: " Hogger le Grand ".into(),
            flavor: "Nouveau".into(),
            rarity: "epic".into(),
            icon: "INV_Misc_Head_Gnoll_01".into(),
            force: None,
            endurance: None,
        };
        let item = card_item(&ch, &edit, 50).unwrap();
        assert_eq!(item["id"], "fix:card:X:1:50");
        assert_eq!(item["kind"], "CARD_SET");
        let c = &item["p"]["cards"][0];
        assert_eq!(
            (c["n"].as_str(), c["r"].as_str(), c["no"].as_i64()),
            (Some("Hogger le Grand"), Some("epic"), Some(7))
        );
        assert_eq!(c["s"], "expeditions");
        assert!(c.get("fo").is_none(), "no stats: the addon's rule");
        assert!(item["p"].get("edition").is_none());
        edit.force = Some(13);
        edit.endurance = Some(1);
        assert!(card_item(&ch, &edit, 50).is_err());
        edit.force = Some(2);
        edit.endurance = None;
        assert!(card_item(&ch, &edit, 50).is_err());
        edit.endurance = Some(2);
        edit.icon = "../evil".into();
        assert!(card_item(&ch, &edit, 50).is_err());
        edit.icon = String::new();
        edit.rarity = "mythic".into();
        assert!(card_item(&ch, &edit, 50).is_err());
        edit.id = "nope".into();
        assert!(card_item(&ch, &edit, 50).is_err());
        let w = withdraw_card_item(&ch, "X:1", 60).unwrap();
        assert_eq!(w["p"]["cards"][0], json!({"id": "X:1", "del": true}));
    }

    #[test]
    fn archive_groups_issues_and_resolves_corrections() {
        let ch = chronicle(vec![
            ev(
                "A:1",
                "ARTICLE",
                10.0,
                json!({"title": "Une", "body": "v1", "edition": "E1", "order": 1, "quote": "Q", "ia": true}),
            ),
            ev(
                "A:2",
                "ARTICLE",
                11.0,
                json!({"title": "Deux", "body": "x", "edition": "E1", "order": 2}),
            ),
            ev(
                "A:3",
                "ARTICLE",
                20.0,
                json!({"title": "Suite", "body": "y", "edition": "E2", "order": 1}),
            ),
            ev(
                "A:4",
                "ARTICLE",
                30.0,
                json!({"replaces": "A:1", "title": "Une (rectifié)", "body": "v2", "quote": ""}),
            ),
            ev(
                "A:5",
                "ARTICLE",
                40.0,
                json!({"replaces": "A:4", "title": "Une v3", "body": "v3"}),
            ),
            ev(
                "A:6",
                "ARTICLE",
                50.0,
                json!({"replaces": "A:2", "retract": true, "title": "Deux"}),
            ),
        ]);
        let issues = archive(&ch, &[]);
        assert_eq!(issues.len(), 2, "corrections are not issues");
        assert_eq!(
            (issues[0].key.as_deref(), issues[0].number),
            (Some("E2"), 2)
        );
        let e1 = &issues[1].articles;
        assert_eq!(e1.len(), 2);
        assert_eq!(
            (e1[0].id.as_str(), e1[0].title.as_str(), e1[0].body.as_str()),
            ("A:1", "Une v3", "v3")
        );
        assert_eq!(e1[0].revised, Some(40.0));
        assert_eq!(
            e1[0].quote,
            Some("Q".into()),
            "the latest correction does not touch the quote"
        );
        assert!(!e1[0].ia, "the latest correction is not marked IA");
        assert!(e1[1].withdrawn);
    }

    #[test]
    fn article_correction_carries_no_edition_nor_refs() {
        let ch = chronicle(vec![ev(
            "A:1",
            "ARTICLE",
            10.0,
            json!({"title": "Une", "body": "v1", "edition": "E1", "ia": true}),
        )]);
        let edit = ArticleEdit {
            id: "A:1".into(),
            title: "Une".into(),
            body: "v2".into(),
            quote: String::new(),
            format: "Brève".into(),
            style: String::new(),
        };
        let item = article_item(&ch, &edit, 70).unwrap();
        assert_eq!(item["id"], "fix:article:A:1:70");
        let p = &item["p"];
        assert_eq!(
            (
                p["replaces"].as_str(),
                p["body"].as_str(),
                p["ia"].as_bool()
            ),
            (Some("A:1"), Some("v2"), Some(true))
        );
        assert_eq!(p["quote"], "", "an empty field clears the original's");
        assert!(p.get("edition").is_none() && item.get("refs").is_none());
        let mut bad = edit.clone();
        bad.title = "  ".into();
        assert!(article_item(&ch, &bad, 70).is_err());
        let r = retract_article_item(&ch, "A:1", 80).unwrap();
        assert_eq!(r["p"]["retract"], true);
        assert_eq!(r["p"]["title"], "Une");
    }
}
