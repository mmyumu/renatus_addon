//! Articles written by hand by the editor (one .md file per article).
//!
//! ```text
//! ---
//! title: Une expédition réussie
//! format: Édition spéciale
//! style: Journaliste sarcastique
//! refs: Player-1-ABC:12, Player-1-DEF:4
//! ---
//! Corps de l'article...
//! ```
//!
//! `refs` are the ids of the cited events. They are checked: an article citing an
//! unknown event is reported. The text is never modified.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};
use sha1::{Digest, Sha1};

/// Bytes: about 15 addon messages.
pub const MAX_BODY: usize = 3500;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Article {
    pub path: PathBuf,
    pub title: String,
    pub body: String,
    pub format: String,
    pub style: String,
    pub refs: Vec<String>,
}

pub fn sha1_hex(text: &str, len: usize) -> String {
    let digest = Sha1::digest(text.as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    hex[..len].to_string()
}

impl Article {
    /// Same id as the former Python companion: items already handled stay handled.
    pub fn id(&self) -> String {
        let stem = self
            .path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        format!(
            "art:{stem}:{}",
            sha1_hex(&format!("{}\0{}", self.title, self.body), 12)
        )
    }

    pub fn to_item(&self) -> Value {
        let mut item = json!({
            "id": self.id(), "kind": "ARTICLE",
            "p": {"title": self.title, "body": self.body, "format": self.format, "style": self.style},
        });
        if !self.refs.is_empty() {
            item["refs"] = json!(self.refs);
        }
        item
    }
}

pub fn parse(path: &Path, text: &str) -> Result<Article, String> {
    let name = path
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let text = text.replace("\r\n", "\n");
    let mut meta = std::collections::HashMap::new();
    let mut body = text.as_str();
    if let Some(rest) = text.strip_prefix("---\n") {
        let end = rest
            .find("\n---")
            .ok_or_else(|| format!("{name} : en-tête non fermé"))?;
        for line in rest[..end].lines() {
            if let Some((k, v)) = line.split_once(':') {
                meta.insert(k.trim().to_lowercase(), v.trim().to_string());
            }
        }
        body = rest[end + 4..].trim_start_matches('\n');
    }
    let title = meta
        .get("title")
        .or_else(|| meta.get("titre"))
        .filter(|t| !t.is_empty())
        .ok_or_else(|| format!("{name} : titre manquant (title: ...)"))?
        .clone();
    let refs = meta
        .get("refs")
        .or_else(|| meta.get("sources"))
        .map(|r| {
            r.split(',')
                .map(str::trim)
                .filter(|r| !r.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    Ok(Article {
        path: path.to_path_buf(),
        title,
        body: body.trim().to_string(),
        format: meta
            .get("format")
            .cloned()
            .unwrap_or_else(|| "Brève".into()),
        style: meta
            .get("style")
            .cloned()
            .unwrap_or_else(|| "Rédaction".into()),
        refs,
    })
}

/// Articles of a folder, and problems found (unreadable, too long, unknown sources).
pub fn load_dir(folder: &Path, known_ids: &BTreeSet<String>) -> (Vec<Article>, Vec<String>) {
    let mut articles = Vec::new();
    let mut notes = Vec::new();
    let mut paths: Vec<PathBuf> = std::fs::read_dir(folder)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|x| x == "md"))
                .collect()
        })
        .unwrap_or_default();
    paths.sort();
    for path in paths {
        let parsed = std::fs::read_to_string(&path)
            .map_err(|e| format!("{} : {e}", path.display()))
            .and_then(|text| parse(&path, &text));
        let a = match parsed {
            Ok(a) => a,
            Err(e) => {
                notes.push(e);
                continue;
            }
        };
        let name = path
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        if a.body.len() > MAX_BODY {
            notes.push(format!(
                "{name} : trop long ({} octets, max {MAX_BODY}) — ignoré.",
                a.body.len()
            ));
            continue;
        }
        let unknown: Vec<&str> = a
            .refs
            .iter()
            .filter(|r| !known_ids.contains(*r))
            .map(String::as_str)
            .collect();
        if !unknown.is_empty() {
            notes.push(format!(
                "{name} : source(s) inconnue(s) ou privée(s) dans ton journal : {}",
                unknown.join(", ")
            ));
        }
        articles.push(a);
    }
    (articles, notes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn front_matter_and_id() {
        let a = parse(
            Path::new("articles/une.md"),
            "---\r\ntitle: Drame à Elwynn\r\nrefs: P-1:2, P-1:3\r\n---\r\n\r\nSelon nos sources...\r\n",
        )
        .unwrap();
        assert_eq!(a.title, "Drame à Elwynn");
        assert_eq!(a.refs, ["P-1:2", "P-1:3"]);
        assert_eq!(a.format, "Brève");
        assert_eq!(a.body, "Selon nos sources...");
        // sha1("Drame à Elwynn\0Selon nos sources...")[:12], as the Python companion computed it
        assert_eq!(
            a.id(),
            format!(
                "art:une:{}",
                sha1_hex("Drame à Elwynn\0Selon nos sources...", 12)
            )
        );
        assert_eq!(sha1_hex("abc", 12), "a9993e364706");
        assert!(parse(Path::new("x.md"), "---\nformat: x\n---\nbody")
            .unwrap_err()
            .contains("titre manquant"));
    }
}
