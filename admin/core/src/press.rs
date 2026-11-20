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
