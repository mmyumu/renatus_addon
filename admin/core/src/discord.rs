//! Posting the gazette to Discord through a webhook: the printed pages (src/print.rs) as
//! images, with a short message (number, date, headlines). Only issues already published
//! in game are posted; a log (discord.json, next to the settings) remembers what was, so
//! an issue is never posted twice and its messages can be found again.
//!
//! The webhook URL is a secret (whoever has it posts under the gazette's name): it never
//! appears in an error message or in the output.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::chronicle::Chronicle;
use crate::print::{date_label, Edition};

/// Name the messages are signed with: the masthead.
pub const USERNAME: &str = "La Gazette de la Guilde";
/// Discord: at most 10 files per message, 2000 characters of text.
const FILES_PER_MESSAGE: usize = 10;
const CONTENT_MAX: usize = 2000;

/// Accepts only Discord webhook URLs, so the pages never go anywhere else.
pub fn check_webhook(url: &str) -> Result<(), String> {
    let url = url.trim();
    let ok = [
        "https://discord.com/api/webhooks/",
        "https://discordapp.com/api/webhooks/",
        "https://ptb.discord.com/api/webhooks/",
        "https://canary.discord.com/api/webhooks/",
    ]
    .iter()
    .any(|p| url.starts_with(p) && url.len() > p.len() + 10);
    if url.is_empty() {
        Err("aucun webhook Discord dans les réglages".into())
    } else if ok {
        Ok(())
    } else {
        Err("le webhook Discord doit commencer par https://discord.com/api/webhooks/".into())
    }
}

/// An issue posted to Discord.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Posted {
    /// Discord message ids, in order.
    pub messages: Vec<String>,
    /// When (Unix seconds).
    pub t: i64,
    pub pages: usize,
    /// What the issue held then (articles and their corrections): changes when it does.
    pub stamp: String,
}

/// What was posted, by issue key.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Log {
    pub posted: BTreeMap<String, Posted>,
    /// Issues published in game after this time (Unix seconds) are posted by themselves;
    /// those from before only by hand. Set on the first automatic check.
    pub since: i64,
}

impl Log {
    pub fn load(path: &Path) -> Log {
        fs::read_to_string(path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let tmp = path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        fs::write(&tmp, text).map_err(|e| e.to_string())?;
        fs::rename(&tmp, path).map_err(|e| e.to_string())
    }
}

/// What an issue holds, to notice a correction or a withdrawal after it was posted.
pub fn stamp(ed: &Edition) -> String {
    use sha1::{Digest, Sha1};
    let mut h = Sha1::new();
    for a in &ed.articles {
        for part in [
            &a.id,
            &a.title,
            &a.body,
            a.quote.as_deref().unwrap_or(""),
            a.portrait.as_deref().unwrap_or(""),
        ] {
            h.update(part.as_bytes());
            h.update([0]);
        }
    }
    if let Some(l) = &ed.layout {
        h.update(l.to_string().as_bytes());
    }
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

fn title(ed: &Edition) -> String {
    match &ed.special {
        Some(s) => format!("{USERNAME} — Hors-série n° {} : « {s} »", ed.number),
        None => format!("{USERNAME} — N° {}", ed.number),
    }
}

/// The text that goes with the pages: number, date, headlines.
pub fn content(ed: &Edition, pages: usize) -> String {
    let n = ed.articles.len();
    let mut out = format!(
        "## {}\nParu le {}  ·  {n} article{}  ·  {pages} page{}\n",
        title(ed),
        date_label(ed.t),
        if n > 1 { "s" } else { "" },
        if pages > 1 { "s" } else { "" },
    );
    let foot =
        "\n-# Sources, archives et courrier des lecteurs : dans l'addon Renatus, onglet Gazette.";
    for (i, a) in ed.articles.iter().enumerate() {
        let line = if i == 0 {
            format!("\n**À la une :** {}\n", a.title)
        } else {
            format!("- {}\n", a.title)
        };
        if out.chars().count() + line.chars().count() + foot.chars().count() + 8 > CONTENT_MAX {
            out.push_str("- …\n");
            break;
        }
        out.push_str(&line);
    }
    out.push_str(foot);
    out
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .user_agent("renatus-admin")
        .timeout(Duration::from_secs(120))
        .build()
}

/// A request error without the URL (it holds the webhook's secret).
fn describe(e: ureq::Error) -> (String, Option<f64>) {
    match e {
        ureq::Error::Status(code, resp) => {
            let body: Value = resp.into_json().unwrap_or(Value::Null);
            let retry = body.get("retry_after").and_then(Value::as_f64);
            let msg = body
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let hint = match code {
                401 | 403 | 404 => " (webhook supprimé ou invalide : recrée-le dans Discord)",
                413 => " (images trop lourdes)",
                _ => "",
            };
            (
                format!("Discord répond {code} {msg}{hint}")
                    .trim()
                    .to_string(),
                retry.filter(|_| code == 429),
            )
        }
        ureq::Error::Transport(t) => (format!("Discord injoignable ({})", t.kind()), None),
    }
}

/// multipart/form-data body: payload_json, then the files.
fn multipart(payload: &Value, files: &[(String, &[u8])]) -> (String, Vec<u8>) {
    let boundary = format!("renatus-{:x}", crate::ops::now() as u64 ^ 0x5eed_cafe_f00d);
    let mut body = Vec::new();
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n{payload}\r\n"
        )
        .as_bytes(),
    );
    for (i, (name, data)) in files.iter().enumerate() {
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"files[{i}]\"; filename=\"{name}\"\r\nContent-Type: image/jpeg\r\n\r\n"
            )
            .as_bytes(),
        );
        body.extend_from_slice(data);
        body.extend_from_slice(b"\r\n");
    }
    body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
    (format!("multipart/form-data; boundary={boundary}"), body)
}

/// Sends a request, waiting once if Discord asks to slow down.
fn send(
    method: &str,
    url: &str,
    ctype: Option<&str>,
    body: &[u8],
) -> Result<Option<Value>, String> {
    for attempt in 0..2 {
        let mut req = agent().request(method, url);
        if let Some(c) = ctype {
            req = req.set("Content-Type", c);
        }
        match req.send_bytes(body) {
            Ok(resp) => {
                if resp.status() == 204 {
                    return Ok(None);
                }
                return resp
                    .into_json()
                    .map(Some)
                    .map_err(|e| format!("réponse de Discord illisible ({e})"));
            }
            Err(e) => {
                let (msg, retry) = describe(e);
                match retry {
                    Some(s) if attempt == 0 => {
                        std::thread::sleep(Duration::from_secs_f64(s.clamp(0.5, 30.0)))
                    }
                    _ => return Err(msg),
                }
            }
        }
    }
    Err("Discord demande d'attendre : réessaie dans une minute".into())
}

fn page_name(i: usize) -> String {
    format!("gazette-page-{}.jpg", i + 1)
}

/// The messages of an issue: (payload, files) for each group of 10 pages.
/// One Discord message: its payload_json and its files (name, bytes).
type Message<'p> = (Value, Vec<(String, &'p [u8])>);

fn messages<'p>(ed: &Edition, pages: &'p [Vec<u8>]) -> Vec<Message<'p>> {
    let total = pages.len();
    let mut out = Vec::new();
    for (m, chunk) in pages.chunks(FILES_PER_MESSAGE).enumerate() {
        let first = m * FILES_PER_MESSAGE;
        let files: Vec<(String, &[u8])> = chunk
            .iter()
            .enumerate()
            .map(|(k, p)| (page_name(first + k), p.as_slice()))
            .collect();
        let attachments: Vec<Value> = (0..chunk.len())
            .map(|k| {
                json!({"id": k, "filename": page_name(first + k),
                       "description": format!("{}, page {} sur {total}", title(ed), first + k + 1)})
            })
            .collect();
        let mut payload = json!({
            "username": USERNAME,
            "allowed_mentions": {"parse": []},
            "attachments": attachments,
        });
        payload["content"] = json!(if m == 0 {
            content(ed, total)
        } else {
            String::new()
        });
        out.push((payload, files));
    }
    out
}

/// Posts the pages (several messages past 10 pages); returns the message ids.
pub fn post(webhook: &str, ed: &Edition, pages: &[Vec<u8>]) -> Result<Vec<String>, String> {
    check_webhook(webhook)?;
    let url = format!("{}?wait=true", webhook.trim());
    let mut ids = Vec::new();
    for (payload, files) in messages(ed, pages) {
        let (ctype, body) = multipart(&payload, &files);
        let msg = send("POST", &url, Some(&ctype), &body)?;
        if let Some(id) = msg
            .as_ref()
            .and_then(|v| v.get("id"))
            .and_then(Value::as_str)
        {
            ids.push(id.to_string());
        }
    }
    Ok(ids)
}

/// Replaces the pages and text of messages already posted, in place (same spot in the
/// channel). With another number of messages, posts anew and deletes the old ones.
pub fn update(
    webhook: &str,
    ids: &[String],
    ed: &Edition,
    pages: &[Vec<u8>],
) -> Result<Vec<String>, String> {
    check_webhook(webhook)?;
    let msgs = messages(ed, pages);
    if msgs.len() != ids.len() {
        let new = post(webhook, ed, pages)?;
        delete(webhook, ids)?;
        return Ok(new);
    }
    for ((payload, files), id) in msgs.into_iter().zip(ids) {
        let url = format!("{}/messages/{id}", webhook.trim());
        let (ctype, body) = multipart(&payload, &files);
        send("PATCH", &url, Some(&ctype), &body)?;
    }
    Ok(ids.to_vec())
}

/// Posts an issue, or updates it if it was already posted; records it in the log.
/// Returns what was done, for the activity log.
pub fn publish(
    webhook: &str,
    ch: &Chronicle,
    ed: &Edition,
    log: &mut Log,
    now: i64,
) -> Result<String, String> {
    let pages = crate::print::render(ch, ed)?;
    let done = log.posted.get(&ed.key).cloned();
    let (ids, what) = match &done {
        Some(p) if !p.messages.is_empty() => {
            (update(webhook, &p.messages, ed, &pages)?, "mis à jour")
        }
        _ => (post(webhook, ed, &pages)?, "posté"),
    };
    log.posted.insert(
        ed.key.clone(),
        Posted {
            messages: ids,
            t: now,
            pages: pages.len(),
            stamp: stamp(ed),
        },
    );
    Ok(format!(
        "Discord : {} {what} ({} page(s)).",
        ed.name(),
        pages.len()
    ))
}

/// After the game saved: posts the issues published in game since `log.since` and not
/// posted yet, and updates the posted ones that changed (corrected or withdrawn
/// article). The first time, only remembers the time: older issues go by hand.
pub fn sync(webhook: &str, ch: &Chronicle, log: &mut Log, now: i64) -> Result<Vec<String>, String> {
    check_webhook(webhook)?;
    if log.since == 0 {
        log.since = now;
        return Ok(vec![
            "Discord : les numéros publiés en jeu à partir de maintenant y seront postés (les anciens : bouton dans l'Éditeur).".into(),
        ]);
    }
    let mut out = Vec::new();
    let mut list = crate::print::editions(ch);
    list.reverse(); // oldest first: the channel keeps the order of publication
    for ed in &list {
        let todo = match log.posted.get(&ed.key) {
            None => ed.t >= log.since as f64,
            Some(p) => p.stamp != stamp(ed),
        };
        if todo {
            out.push(publish(webhook, ch, ed, log, now)?);
        }
    }
    Ok(out)
}

/// Deletes messages posted by this webhook (a message already gone is fine).
pub fn delete(webhook: &str, ids: &[String]) -> Result<(), String> {
    check_webhook(webhook)?;
    for id in ids {
        let url = format!("{}/messages/{id}", webhook.trim());
        match send("DELETE", &url, None, &[]) {
            Ok(_) => {}
            Err(e) if e.starts_with("Discord répond 404") => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::print::Article;

    fn ed(n: usize) -> Edition {
        Edition {
            key: "2026-11-25-0127".into(),
            number: 5,
            special: None,
            t: 1_764_000_000.0,
            since: 0.0,
            till: 0.0,
            articles: (0..n)
                .map(|i| Article {
                    id: format!("a{i}"),
                    t: 0.0,
                    title: format!("Titre numéro {i} assez long pour remplir la place disponible"),
                    body: "Texte".into(),
                    kind: None,
                    author: None,
                    ia: true,
                    key: None,
                    quote: None,
                    portrait: None,
                })
                .collect(),
            letters: Vec::new(),
            layout: None,
        }
    }

    #[test]
    fn only_discord_webhooks() {
        assert!(check_webhook("").is_err());
        assert!(check_webhook("https://example.com/api/webhooks/1/abc").is_err());
        assert!(check_webhook("https://discord.com/api/webhooks/123456/abcdefghijk").is_ok());
    }

    #[test]
    fn content_stays_within_discord_limits() {
        let c = content(&ed(3), 4);
        assert!(
            c.contains("N° 5")
                && c.contains("**À la une :** Titre numéro 0")
                && c.contains("4 pages")
        );
        let long = content(&ed(200), 9);
        assert!(long.chars().count() <= CONTENT_MAX);
        assert!(long.contains("- …"));
    }

    #[test]
    fn the_body_holds_payload_and_files() {
        let (ctype, body) = multipart(&json!({"content": "x"}), &[("p.jpg".into(), &[1u8, 2, 3])]);
        let boundary = ctype.split("boundary=").nth(1).unwrap();
        let text = String::from_utf8_lossy(&body);
        assert!(
            text.contains("name=\"payload_json\"")
                && text.contains("name=\"files[0]\"; filename=\"p.jpg\"")
        );
        assert!(text.ends_with(&format!("--{boundary}--\r\n")));
    }
}
