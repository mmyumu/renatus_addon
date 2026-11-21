//! Writing Renatus_Admin/Press.lua, read by the addon on every /reload.
//!
//! The file is merged with the existing one (deterministic ids: no duplicates) and
//! cleared of items already published or ignored in game (pressDone in the
//! SavedVariables). Atomic write: temporary file then rename.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde_json::{json, Map, Value};

use crate::chronicle::{num_of, str_of};

const HEADER: &str = "-- File written by the Renatus admin app. Do not edit by hand:\n\
-- it is replaced every time the app proposes something.\n";

pub fn read_items(path: &Path) -> Vec<Value> {
    let Ok(data) = crate::lua::load(path) else {
        return Vec::new();
    };
    data.get("RenatusPress")
        .and_then(|p| p.get("items"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter(|i| str_of(i, "id").is_some())
                .cloned()
                .collect()
        })
        .unwrap_or_default()
}

/// Existing + new items (the newer copy of an id wins), minus those already handled in game.
pub fn merge(existing: Vec<Value>, new: Vec<Value>, done: &Map<String, Value>) -> Vec<Value> {
    let mut by_id: BTreeMap<String, Value> = BTreeMap::new();
    for item in existing.into_iter().chain(new) {
        if let Some(id) = str_of(&item, "id") {
            by_id.insert(id.to_string(), item);
        }
    }
    let mut kept: Vec<Value> = by_id
        .into_iter()
        .filter(|(id, _)| !done.contains_key(id))
        .map(|(_, v)| v)
        .collect();
    kept.sort_by(|a, b| {
        num_of(a, "t")
            .total_cmp(&num_of(b, "t"))
            .then_with(|| str_of(a, "id").cmp(&str_of(b, "id")))
    });
    kept
}

/// `items` without the items whose id is in `drop`, and without the album cards whose id is
/// in `drop_cards`. A card set keeps its numbers contiguous (from its first one, nothing is
/// published yet) and goes away once empty.
pub fn remove(items: Vec<Value>, drop: &[String], drop_cards: &[String]) -> Vec<Value> {
    items
        .into_iter()
        .filter(|i| str_of(i, "id").is_none_or(|id| !drop.iter().any(|d| d == id)))
        .filter_map(|mut item| {
            if str_of(&item, "kind") != Some("CARD_SET") || drop_cards.is_empty() {
                return Some(item);
            }
            let cards = item.get_mut("p")?.get_mut("cards")?.as_array_mut()?;
            let first = cards
                .iter()
                .map(|c| num_of(c, "no"))
                .fold(f64::INFINITY, f64::min);
            let before = cards.len();
            cards.retain(|c| str_of(c, "id").is_none_or(|id| !drop_cards.iter().any(|d| d == id)));
            if cards.is_empty() {
                return None;
            }
            if cards.len() != before && first.is_finite() {
                cards.sort_by(|a, b| num_of(a, "no").total_cmp(&num_of(b, "no")));
                for (n, c) in cards.iter_mut().enumerate() {
                    c["no"] = json!(first as i64 + n as i64);
                }
            }
            Some(item)
        })
        .collect()
}

pub fn render(items: &[Value], now: i64) -> String {
    let press = json!({"version": 1, "generated": now, "items": items});
    format!("{HEADER}{}", crate::lua::dumps(&[("RenatusPress", &press)]))
}

pub fn write(path: &Path, items: &[Value], now: i64) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("{} : {e}", parent.display()))?;
    }
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, render(items, now)).map_err(|e| format!("{} : {e}", tmp.display()))?;
    fs::rename(&tmp, path).map_err(|e| format!("{} : {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remove_drops_items_and_cards_and_renumbers() {
        let items = vec![
            json!({"id": "art", "kind": "ARTICLE", "p": {}}),
            json!({"id": "set", "kind": "CARD_SET", "p": {"cards": [
                {"id": "c1", "no": 7}, {"id": "c2", "no": 8}, {"id": "c3", "no": 9}
            ]}}),
            json!({"id": "solo", "kind": "CARD_SET", "p": {"cards": [{"id": "c4", "no": 10}]}}),
        ];
        let out = remove(
            items,
            &["art".to_string()],
            &["c2".to_string(), "c4".to_string()],
        );
        assert_eq!(out.len(), 1, "the article and the emptied set are gone");
        let cards = out[0]["p"]["cards"].as_array().unwrap();
        let kept: Vec<(&str, i64)> = cards
            .iter()
            .map(|c| (c["id"].as_str().unwrap(), c["no"].as_i64().unwrap()))
            .collect();
        assert_eq!(kept, [("c1", 7), ("c3", 8)]);
    }

    #[test]
    fn merge_dedupes_drops_done_and_sorts() {
        let done: Map<String, Value> = [("b".to_string(), json!("ignored"))].into_iter().collect();
        let merged = merge(
            vec![
                json!({"id": "a", "t": 5, "p": {"v": 1}}),
                json!({"id": "b", "t": 1}),
            ],
            vec![
                json!({"id": "a", "t": 5, "p": {"v": 2}}),
                json!({"id": "c", "t": 2}),
            ],
            &done,
        );
        let ids: Vec<&str> = merged.iter().filter_map(|i| str_of(i, "id")).collect();
        assert_eq!(ids, ["c", "a"]);
        assert_eq!(merged[1]["p"]["v"], 2);
    }

    #[test]
    fn written_file_reads_back() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("Renatus_Admin/Press.lua");
        let items = vec![
            json!({"id": "x", "kind": "ARTICLE", "p": {"title": "Une « vraie »", "body": "a\nb"}}),
        ];
        write(&path, &items, 42).unwrap();
        assert_eq!(read_items(&path), items);
        assert!(fs::read_to_string(&path)
            .unwrap()
            .starts_with("-- File written"));
    }
}
