//! Gazette issues: one per publication. What the previous issues already told (the
//! events their published articles cite, or articles still waiting in Press.lua), and
//! the facts offered for the next one, ticked by default when they are new.
//!
//! Nothing new travels for this: every ARTICLE event already carries its sources (refs),
//! synced to every member, and the addon derives "Paru dans le n° X" the same way.

use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;

use crate::chronicle::{num_of, payload, str_of, Chronicle};
use crate::gazette::{self, Brief};
use crate::special::{self, Special};

const DAY: f64 = 86400.0;
/// Without any previous issue (the first one, or after a reset in Renatus_Admin), the new
/// one covers this many days: every fact still listed comes back on top, ticked.
pub const FIRST_DAYS: f64 = 30.0;
/// Automatic mode: a new issue once the latest one is this old.
pub const ISSUE_EVERY_DAYS: f64 = 7.0;
/// Older facts listed (unticked) in the selection.
pub const LOOKBACK_DAYS: f64 = 30.0;

/// An article that already used an event.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Use {
    pub title: String,
    pub t: f64,
    /// Still waiting in Press.lua (not published in game yet).
    pub pending: bool,
}

impl Use {
    pub fn label(&self) -> String {
        let title: String = self.title.chars().take(50).collect();
        if self.pending {
            format!("en attente en jeu (« {title} »)")
        } else {
            let day = gazette::local(self.t).format("%d/%m");
            format!("paru le {day} (« {title} »)")
        }
    }
}

/// Whether an ARTICLE or EDITION (event or Press.lua item) belongs to a special issue.
pub fn in_special(item: &Value) -> bool {
    str_of(payload(item), "edition").is_some_and(special::is_special)
}

/// Event id -> the first article of a regular issue that cites it: published ones, then
/// those waiting in Press.lua. Special issues do not count: their facts stay new for the
/// regular gazette.
pub fn cited(ch: &Chronicle, pending: &[Value]) -> HashMap<String, Use> {
    let mut out: HashMap<String, Use> = HashMap::new();
    let mut published: Vec<&Value> = ch.of_kind("ARTICLE").filter(|e| !in_special(e)).collect();
    published.sort_by(|a, b| num_of(a, "t").total_cmp(&num_of(b, "t")));
    let waiting = pending
        .iter()
        .filter(|i| str_of(i, "kind") == Some("ARTICLE") && !in_special(i));
    for (item, is_pending) in published
        .into_iter()
        .map(|e| (e, false))
        .chain(waiting.map(|i| (i, true)))
    {
        let title = str_of(payload(item), "title").unwrap_or("?").to_string();
        let t = num_of(item, "t");
        for id in item
            .get("refs")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            out.entry(id.to_string()).or_insert_with(|| Use {
                title: title.clone(),
                t,
                pending: is_pending,
            });
        }
    }
    out
}

/// End of the period covered by the latest regular issue, published or waiting in
/// Press.lua: its EDITION's `till` (when it was written), else the EDITION's or the
/// articles' time. Special issues are left out.
pub fn last_issue_end(ch: &Chronicle, pending: &[Value]) -> Option<f64> {
    let editions = ch
        .of_kind("EDITION")
        .chain(
            pending
                .iter()
                .filter(|i| str_of(i, "kind") == Some("EDITION")),
        )
        .filter(|e| !in_special(e))
        .map(|e| {
            let till = num_of(payload(e), "till");
            if till > 0.0 {
                till
            } else {
                num_of(e, "t")
            }
        });
    let articles = ch
        .of_kind("ARTICLE")
        .filter(|e| str_of(payload(e), "edition").is_some() && !in_special(e))
        .map(|e| num_of(e, "t"));
    editions
        .chain(articles)
        .filter(|t| *t > 0.0)
        .reduce(f64::max)
}

/// A fact offered for the next issue.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub key: String,
    pub text: String,
    pub when: f64,
    /// Family (gazette::category) and members named, for filtering.
    pub cat: &'static str,
    pub who: Vec<String>,
    /// Since the previous issue (else: older, listed for the record).
    pub recent: bool,
    /// Already told: by which article ("paru le 20/11 (« … »)"), for all its events.
    pub used: Option<String>,
    /// Some of its events already told, not all.
    pub partly: bool,
    /// Ticked by default.
    pub checked: bool,
}

/// The facts offered for the next issue, and the brief they come from.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Selection {
    pub edition: String,
    /// Start of the new issue's period (end of the previous one).
    pub since: f64,
    pub until: f64,
    /// Whether `since` comes from a previous issue (else the last FIRST_DAYS days).
    pub after_issue: bool,
    pub candidates: Vec<Candidate>,
    #[serde(skip)]
    pub brief: Brief,
    /// Card sets waiting in Press.lua: their cards are not proposed again (cards.rs).
    #[serde(skip)]
    pub pending_cards: Vec<Value>,
    /// A special issue (special.rs), else None.
    pub special: Option<Special>,
}

impl Selection {
    /// The brief sent to the AI for these facts: its period starts at the previous issue,
    /// or earlier if older facts are ticked.
    pub fn brief_for(&self, keys: &[String]) -> Brief {
        let mut b = self.brief.select(keys);
        b.since = b.facts.iter().map(|f| f.when).fold(self.since, f64::min);
        b.special = self.special.clone();
        b
    }

    pub fn checked_keys(&self) -> Vec<String> {
        self.candidates
            .iter()
            .filter(|c| c.checked)
            .map(|c| c.key.clone())
            .collect()
    }
}

pub fn prepare(ch: &Chronicle, pending: &[Value], now: f64) -> Selection {
    let last = last_issue_end(ch, pending).filter(|t| *t < now);
    let since = last.unwrap_or(now - FIRST_DAYS * DAY);
    let from = since.min(now - LOOKBACK_DAYS * DAY);
    let brief = gazette::build_split(ch, from, now, since);
    let used = cited(ch, pending);
    let candidates = brief
        .facts
        .iter()
        .map(|f| {
            let uses: Vec<&Use> = f.refs.iter().filter_map(|r| used.get(r)).collect();
            let all = !f.refs.is_empty() && uses.len() == f.refs.len();
            let recent = f.when >= since;
            Candidate {
                key: f.key.clone(),
                text: f.text.clone(),
                when: f.when,
                cat: f.cat,
                who: f.who.clone(),
                recent,
                used: if all {
                    uses.first().map(|u| u.label())
                } else {
                    None
                },
                partly: !all && !uses.is_empty(),
                checked: recent && !all,
            }
        })
        .collect();
    Selection {
        edition: gazette::edition_key(now),
        since,
        until: now,
        after_issue: last.is_some(),
        candidates,
        brief,
        pending_cards: pending
            .iter()
            .filter(|i| crate::chronicle::str_of(i, "kind") == Some("CARD_SET"))
            .cloned()
            .collect(),
        special: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn chronicle(events: Vec<Value>) -> Chronicle {
        let mut map = serde_json::Map::new();
        for e in events {
            map.insert(e["id"].as_str().unwrap().to_string(), e);
        }
        let saved = json!({"RenatusDB": {"events": Value::Object(map)}});
        Chronicle::from_saved(saved.as_object().unwrap())
    }

    fn ev(id: &str, k: &str, t: f64, p: Value) -> Value {
        json!({"id": id, "a": "A", "n": "Alice", "k": k, "t": t, "vis": "G", "g": "Renatus-Forever", "s": 1, "p": p})
    }

    #[test]
    fn new_facts_are_ticked_told_ones_are_not() {
        let now = 100.0 * DAY;
        let mut art = ev(
            "A:9",
            "ARTICLE",
            now - 5.0 * DAY,
            json!({"title": "Le lac", "edition": "E1"}),
        );
        art["refs"] = json!(["A:2"]);
        let mut layout = ev("A:10", "EDITION", now - 4.0 * DAY, json!({"edition": "E1"}));
        layout["p"]["till"] = json!(now - 5.0 * DAY);
        let ch = chronicle(vec![
            ev("A:1", "AI_CONSENT", 0.0, json!({"ok": true})),
            ev("A:2", "LEVEL_UP", now - 6.0 * DAY, json!({"lvl": 10})),
            ev("A:3", "LEVEL_UP", now - 20.0 * DAY, json!({"lvl": 9})),
            ev("A:4", "LEVEL_UP", now - DAY, json!({"lvl": 11})),
            art,
            layout,
        ]);
        let pending = vec![
            json!({"id": "x", "kind": "ARTICLE", "refs": ["A:3"], "p": {"title": "En attente"}}),
        ];
        let s = prepare(&ch, &pending, now);
        assert!(s.after_issue);
        assert_eq!(
            s.since,
            now - 5.0 * DAY,
            "since the previous issue was written"
        );
        let by_text = |lvl: &str| {
            s.candidates
                .iter()
                .find(|c| c.text.contains(&format!("niveau {lvl}")))
                .unwrap()
                .clone()
        };
        let told = by_text("10");
        assert!(!told.recent && !told.checked);
        assert!(told.used.as_deref().unwrap().contains("Le lac"));
        let waiting = by_text("9");
        assert!(waiting.used.as_deref().unwrap().starts_with("en attente"));
        let new = by_text("11");
        assert!(new.recent && new.checked && new.used.is_none());
        assert_eq!(new.cat, "Progression");
        assert!(!new.who.is_empty(), "the member levelling up is named");
        assert_eq!(s.checked_keys(), vec![new.key.clone()]);
        let b = s.brief_for(&s.checked_keys());
        assert_eq!(b.facts.len(), 1);
        assert_eq!(b.since, s.since, "period: since the previous issue");
        assert_eq!(
            s.brief_for(std::slice::from_ref(&told.key)).since,
            told.when,
            "or from an older fact ticked"
        );
    }

    #[test]
    fn first_issue_covers_the_last_days() {
        let now = 100.0 * DAY;
        let ch = chronicle(vec![ev("A:1", "AI_CONSENT", 0.0, json!({"ok": true}))]);
        let s = prepare(&ch, &[], now);
        assert!(!s.after_issue);
        assert_eq!(s.since, now - FIRST_DAYS * DAY);
    }

    #[test]
    fn special_issues_do_not_move_the_regular_gazette() {
        let now = 100.0 * DAY;
        let mut art = ev(
            "A:9",
            "ARTICLE",
            now - 2.0 * DAY,
            json!({"title": "Spécial", "edition": "hs:x"}),
        );
        art["refs"] = json!(["A:2"]);
        let mut layout = ev(
            "A:10",
            "EDITION",
            now - 2.0 * DAY,
            json!({"edition": "hs:x"}),
        );
        layout["p"]["till"] = json!(now - 2.0 * DAY);
        let ch = chronicle(vec![
            ev("A:1", "AI_CONSENT", 0.0, json!({"ok": true})),
            ev("A:2", "LEVEL_UP", now - 3.0 * DAY, json!({"lvl": 10})),
            art,
            layout,
        ]);
        assert_eq!(
            last_issue_end(&ch, &[]),
            None,
            "a special issue is not the last issue"
        );
        let s = prepare(&ch, &[], now);
        assert!(!s.after_issue);
        let lvl = s
            .candidates
            .iter()
            .find(|c| c.text.contains("niveau 10"))
            .unwrap();
        assert!(
            lvl.checked && lvl.used.is_none(),
            "told in a special issue: still new"
        );

        let theme = Special {
            kind: special::Kind::Portrait,
            title: "Spécial {member}".into(),
            brief: "tout sur {member}".into(),
            member: Some("Alice".into()),
        };
        let hs = special::prepare(&ch, &[], &theme, now - 10.0 * DAY, now, now).unwrap();
        assert!(special::is_special(&hs.edition));
        assert!(
            hs.candidates.iter().any(|c| c.checked),
            "Alice's facts ticked"
        );
        let b = hs.brief_for(&hs.checked_keys());
        let prompt = gazette::prompt(&b, 5);
        assert!(prompt.contains("HORS-SÉRIE « Spécial Alice »"), "{prompt}");
        assert!(prompt.contains("tout sur Alice"));
        // a custom prompt without {special} still gets the theme
        let custom = gazette::prompt_in("Mon prompt.\n{facts}", &b, 5);
        assert!(custom.starts_with("NUMÉRO HORS-SÉRIE"), "{custom}");
        assert!(
            special::prepare(
                &ch,
                &[],
                &Special {
                    member: None,
                    ..theme.clone()
                },
                0.0,
                now,
                now
            )
            .is_err(),
            "a portrait needs its member"
        );
    }
}
