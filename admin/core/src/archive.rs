//! The whole journal, kept by Renatus Admin outside the game.
//!
//! In game, old facts end up summed up by their author (BILAN events, docs/ARCHITECTURE.md
//! §10) so the SavedVariables stop growing. The gazette still needs them: records,
//! milestones and anniversaries are counted over the whole journal (`derived`). So every
//! time the app reads the SavedVariables it copies the events it has not seen yet into
//! an archive, and the journal the app works on is the archive plus the SavedVariables.
//!
//! The archive is a JSON Lines file (one event per line) next to the account's
//! SavedVariables folder: `WTF/Account/<account>/Renatus.archive.jsonl`. The game never
//! reads nor deletes it. Deletions are honoured: an event its author deleted (`del`, or a
//! TOMBSTONE seen once) is emptied in the archive too.

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::chronicle::str_of;

pub const FILE_NAME: &str = "Renatus.archive.jsonl";

/// Fields of a deleted event kept by the addon (Store.lua, `strip`).
const KEPT_WHEN_DELETED: &[&str] = &["v", "id", "a", "n", "s", "t", "k", "g", "vis"];

/// The archive of the account whose SavedVariables file is `sv`
/// (`.../WTF/Account/<account>/SavedVariables/Renatus.lua`).
pub fn path_for(sv: &Path) -> PathBuf {
    let account = sv.parent().and_then(Path::parent).unwrap_or(Path::new("."));
    account.join(FILE_NAME)
}

/// What one merge did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Merge {
    /// Events the archive holds after the merge.
    pub total: usize,
    /// Events newly copied into the archive.
    pub added: usize,
    /// Events only the archive holds (summed up in game).
    pub only_archived: usize,
}

fn is_deleted(e: &Value) -> bool {
    e.get("del")
        .is_some_and(|d| !d.is_null() && d != &Value::Bool(false))
}

fn strip(e: &Value) -> Value {
    let mut out = Map::new();
    for k in KEPT_WHEN_DELETED {
        if let Some(v) = e.get(*k) {
            out.insert((*k).to_string(), v.clone());
        }
    }
    out.insert("p".into(), Value::Object(Map::new()));
    out.insert("del".into(), Value::Bool(true));
    Value::Object(out)
}

/// The archived events, and whether the file needs writing again (a line cut short when
/// the app stopped while writing: skipped, never fatal, and dropped from the file).
fn read(path: &Path) -> Result<(Vec<Value>, bool), String> {
    let text = match fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((Vec::new(), false)),
        Err(e) => return Err(format!("archive {} illisible : {e}", path.display())),
    };
    let mut damaged = !text.is_empty() && !text.ends_with('\n');
    let mut out = Vec::new();
    for l in text.lines().filter(|l| !l.trim().is_empty()) {
        match serde_json::from_str::<Value>(l) {
            Ok(e) if str_of(&e, "id").is_some() => out.push(e),
            _ => damaged = true,
        }
    }
    Ok((out, damaged))
}

fn line(e: &Value) -> String {
    let mut s = serde_json::to_string(e).unwrap_or_default();
    s.push('\n');
    s
}

/// Copies into the archive at `path` the events of `events` (the SavedVariables) it
/// lacks, applies deletions, then adds to `events` those only the archive still holds.
pub fn merge(path: &Path, events: &mut Map<String, Value>) -> Result<Merge, String> {
    let (stored, mut rewrite) = read(path)?;
    let mut index: HashMap<String, usize> = HashMap::new();
    let mut archive: Vec<Value> = Vec::with_capacity(stored.len());
    for e in stored {
        let id = str_of(&e, "id").unwrap_or_default().to_string();
        match index.get(&id) {
            Some(&i) => archive[i] = e, // a later line replaces an earlier one
            None => {
                index.insert(id, archive.len());
                archive.push(e);
            }
        }
    }
    let mut appended: Vec<Value> = Vec::new();
    for (id, e) in events.iter() {
        if !e.is_object() {
            continue;
        }
        match index.get(id) {
            None => {
                index.insert(id.clone(), archive.len());
                archive.push(e.clone());
                appended.push(e.clone());
            }
            Some(&i) => {
                if is_deleted(e) && !is_deleted(&archive[i]) {
                    archive[i] = strip(&archive[i]);
                    rewrite = true;
                }
            }
        }
    }
    // A TOMBSTONE empties its author's target, even when the game no longer has it.
    let targets: Vec<(String, String)> = archive
        .iter()
        .filter(|e| str_of(e, "k") == Some("TOMBSTONE"))
        .filter_map(|e| {
            let target = e.get("refs")?.get(0)?.as_str()?.to_string();
            Some((target, str_of(e, "a")?.to_string()))
        })
        .collect();
    for (target, author) in targets {
        if let Some(&i) = index.get(&target) {
            let t = &archive[i];
            if !is_deleted(t) && str_of(t, "a") == Some(author.as_str()) {
                archive[i] = strip(t);
                rewrite = true;
            }
        }
    }
    if rewrite {
        let tmp = path.with_extension("jsonl.tmp");
        let mut text = String::new();
        for e in &archive {
            text.push_str(&line(e));
        }
        fs::write(&tmp, text).map_err(|e| format!("archive {} : {e}", tmp.display()))?;
        fs::rename(&tmp, path).map_err(|e| format!("archive {} : {e}", path.display()))?;
    } else if !appended.is_empty() {
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|e| format!("archive {} : {e}", path.display()))?;
        let mut text = String::new();
        for e in &appended {
            text.push_str(&line(e));
        }
        f.write_all(text.as_bytes())
            .map_err(|e| format!("archive {} : {e}", path.display()))?;
    }
    let mut only = 0;
    for e in archive.iter() {
        let id = str_of(e, "id").unwrap_or_default();
        match events.get_mut(id) {
            None => {
                events.insert(id.to_string(), e.clone());
                only += 1;
            }
            // deleted in the archive (TOMBSTONE the game no longer has): deleted here too
            Some(cur) if is_deleted(e) && !is_deleted(cur) => *cur = e.clone(),
            Some(_) => {}
        }
    }
    Ok(Merge {
        total: archive.len(),
        added: appended.len(),
        only_archived: only,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn events(list: &[Value]) -> Map<String, Value> {
        list.iter()
            .map(|e| (str_of(e, "id").unwrap().to_string(), e.clone()))
            .collect()
    }

    #[test]
    fn keeps_what_the_game_summed_up() {
        let dir = tempfile::tempdir().unwrap();
        let sv = dir.path().join("ACC/SavedVariables/Renatus.lua");
        fs::create_dir_all(sv.parent().unwrap()).unwrap();
        let path = path_for(&sv);
        assert_eq!(path, dir.path().join("ACC").join(FILE_NAME));

        let quest =
            json!({"id": "P-1:1", "a": "P-1", "k": "QUEST_DONE", "t": 10, "p": {"title": "Q"}});
        let boss = json!({"id": "P-1:2", "a": "P-1", "k": "BOSS_KILL", "t": 20, "p": {}});
        let mut first = events(&[quest.clone(), boss.clone()]);
        let m = merge(&path, &mut first).unwrap();
        assert_eq!((m.total, m.added, m.only_archived), (2, 2, 0));

        // Later the game has summed both up (BILAN): the archive still gives them back.
        let bilan = json!({"id": "P-1:3", "a": "P-1", "k": "BILAN", "t": 30, "p": {}});
        let mut second = events(&[bilan]);
        let m = merge(&path, &mut second).unwrap();
        assert_eq!((m.total, m.added, m.only_archived), (3, 1, 2));
        assert_eq!(second["P-1:1"]["p"]["title"], "Q");
        assert_eq!(second.len(), 3);

        // Read again with nothing new: nothing appended.
        let mut third = events(&[]);
        let m = merge(&path, &mut third).unwrap();
        assert_eq!((m.total, m.added), (3, 0));
        assert_eq!(fs::read_to_string(&path).unwrap().lines().count(), 3);
    }

    #[test]
    fn deletions_reach_the_archive() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE_NAME);
        let note = json!({"id": "P-1:1", "a": "P-1", "n": "Bob", "s": 1, "k": "ANECDOTE", "t": 10, "vis": "G", "p": {"title": "Secret"}});
        let other = json!({"id": "P-2:1", "a": "P-2", "k": "ANECDOTE", "t": 10, "p": {"title": "Pas à toi"}});
        merge(&path, &mut events(&[note.clone(), other.clone()])).unwrap();

        // Emptied in game (del): emptied in the archive.
        let mut gone = note.clone();
        gone["del"] = json!(true);
        gone["p"] = json!({});
        let mut evs = events(&[gone]);
        merge(&path, &mut evs).unwrap();
        let text = fs::read_to_string(&path).unwrap();
        assert!(!text.contains("Secret"), "{text}");
        assert_eq!(evs["P-1:1"]["del"], true);

        // A TOMBSTONE seen once empties its author's target only.
        let tomb = json!({"id": "P-3:1", "a": "P-3", "k": "TOMBSTONE", "t": 20, "refs": ["P-2:1"], "p": {}});
        let mut evs = events(&[tomb]);
        merge(&path, &mut evs).unwrap();
        assert_eq!(evs["P-2:1"]["p"]["title"], "Pas à toi", "not its author");
        let tomb = json!({"id": "P-2:2", "a": "P-2", "k": "TOMBSTONE", "t": 20, "refs": ["P-2:1"], "p": {}});
        let mut evs = events(&[tomb]);
        merge(&path, &mut evs).unwrap();
        assert_eq!(evs["P-2:1"]["del"], true);
        assert!(!fs::read_to_string(&path).unwrap().contains("Pas à toi"));
    }

    #[test]
    fn a_broken_line_is_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE_NAME);
        fs::write(
            &path,
            "{\"id\":\"P-1:1\",\"k\":\"DEATH\"}\n{\"id\":\"P-1:2\",\"k\"",
        )
        .unwrap();
        let mut evs = Map::new();
        let m = merge(&path, &mut evs).unwrap();
        assert_eq!((m.total, m.only_archived), (1, 1));
        // the file is written again, clean: the next additions are not glued to the debris
        let mut evs = events(&[json!({"id": "P-1:3", "k": "DEATH"})]);
        merge(&path, &mut evs).unwrap();
        let mut evs = Map::new();
        assert_eq!(merge(&path, &mut evs).unwrap().total, 2);
    }
}
