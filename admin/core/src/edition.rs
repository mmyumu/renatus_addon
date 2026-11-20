//! Page layout of a gazette edition (EDITION item of Press.lua).
//!
//! The addon draws a layout from plain data (Renatus/UI/Newsprint.lua): pages of rows
//! of cells holding typed blocks. New layouts are therefore an app update only: the
//! members' addon never changes for them. Built here as pages -> rows -> cells, the
//! layout travels flat (`titles` + `cells` with page and row numbers): the addon's
//! sync refuses tables nested deeper than 8 levels.
//!
//! Stories refer to articles by rank ("@1" = the front page: most votes, then the
//! editorial order given here), so the guild's votes can still change the front page.
//! Quotes and portraits refer to their article by key: they stay with it.

use serde_json::{json, Value};

use crate::chronicle::str_of;

/// Layout templates: (name, description for the editor and the AI).
pub const TEMPLATES: &[(&str, &str)] = &[
    (
        "classique",
        "une en deux colonnes, en bref dessous, colonne des autres articles à droite",
    ),
    (
        "grande_une",
        "une sur toute la largeur en trois colonnes, puis trois encadrés ; page 2 pour la suite",
    ),
    (
        "trois_colonnes",
        "journal à l'ancienne : en bref à gauche, une au centre, sommaire à droite",
    ),
    (
        "portrait",
        "grand portrait d'un personnage à gauche, une à droite (il faut un portrait)",
    ),
];

/// The addon refuses events larger than 6000 bytes; keep a wide margin.
pub const MAX_BYTES: usize = 3000;

pub fn is_template(name: &str) -> bool {
    TEMPLATES.iter().any(|(n, _)| *n == name)
}

fn story(a: &str, cols: u32, head: Option<&str>) -> Value {
    let mut b = json!({"t": "story", "a": a, "cols": cols, "drop": true});
    if let Some(h) = head {
        b["head"] = json!(h);
    }
    b
}

fn cell(w: u32, blocks: Vec<Value>) -> Value {
    json!({"w": w, "blocks": blocks})
}

fn row(h: Option<f64>, cells: Vec<Value>) -> Value {
    match h {
        Some(h) => json!({"h": h, "cells": cells}),
        None => json!({"cells": cells}),
    }
}

/// What the articles offer to the layout.
struct Parts {
    count: usize,
    quote: Option<String>,
    portrait: Option<String>,
}

fn parts(articles: &[Value]) -> Parts {
    let key_with = |field: &str| {
        articles.iter().find_map(|a| {
            let p = a.get("p")?;
            str_of(p, field)?;
            str_of(p, "key").map(str::to_string)
        })
    };
    Parts {
        count: articles.len(),
        quote: key_with("quote"),
        portrait: key_with("portrait"),
    }
}

fn quote(p: &Parts) -> Option<Value> {
    p.quote.as_ref().map(|k| json!({"t": "quote", "a": k}))
}

fn portrait(p: &Parts) -> Option<Value> {
    p.portrait
        .as_ref()
        .map(|k| json!({"t": "portrait", "a": k}))
}

/// Inner pages: the articles from rank `from` on, two per row, two rows per page.
fn following(p: &Parts, from: usize, title: &str) -> Vec<Value> {
    let ranks: Vec<String> = (from..=p.count).map(|i| format!("@{i}")).collect();
    let rows: Vec<Value> = ranks
        .chunks(2)
        .map(|pair| {
            row(
                None,
                pair.iter()
                    .map(|a| cell(6, vec![story(a, 1, Some("m"))]))
                    .collect(),
            )
        })
        .collect();
    rows.chunks(2)
        .map(|r| json!({"title": title, "rows": r}))
        .collect()
}

fn pages(template: &str, p: &Parts) -> Vec<Value> {
    let some = |v: Option<Value>| v.into_iter().collect::<Vec<_>>();
    match template {
        "grande_une" => {
            let mut boxes = Vec::new();
            boxes.push(cell(
                4,
                some(portrait(p))
                    .into_iter()
                    .chain([json!({"t": "figure"})])
                    .collect(),
            ));
            if p.count >= 2 {
                boxes.push(cell(4, vec![json!({"t": "teaser", "a": "@2", "lines": 4})]));
            }
            boxes.push(cell(
                4,
                some(quote(p))
                    .into_iter()
                    .chain([json!({"t": "brief", "max": 4})])
                    .collect(),
            ));
            let mut out = vec![json!({"rows": [
                row(Some(0.6), vec![cell(12, vec![story("@1", 3, Some("xl"))])]),
                row(None, boxes),
            ]})];
            out.extend(following(p, 2, "Suite de l'édition"));
            out
        }
        "trois_colonnes" => {
            let mut center = vec![story("@1", 2, Some("l"))];
            center.extend(some(quote(p)));
            let mut right = some(portrait(p));
            right.extend([json!({"t": "contents"}), json!({"t": "letters"})]);
            vec![json!({"rows": [row(None, vec![
                cell(3, vec![json!({"t": "brief", "max": 8}), json!({"t": "figure"})]),
                cell(6, center),
                cell(3, right),
            ])]})]
        }
        "portrait" if p.portrait.is_some() => {
            let mut left = some(portrait(p));
            left.extend(some(quote(p)));
            left.push(json!({"t": "figure"}));
            let mut rows = vec![row(
                Some(0.64),
                vec![cell(5, left), cell(7, vec![story("@1", 2, Some("l"))])],
            )];
            let mut bottom = Vec::new();
            for i in 2..=p.count.min(3) {
                bottom.push(cell(4, vec![json!({"t": "teaser", "a": format!("@{i}")})]));
            }
            bottom.push(cell(4, vec![json!({"t": "brief", "max": 4})]));
            rows.push(row(None, bottom));
            let mut out = vec![json!({"rows": rows})];
            out.extend(following(p, 4, "Suite de l'édition"));
            out
        }
        _ => {
            let mut left = vec![story("@1", 2, None)];
            left.extend(some(quote(p)));
            left.push(json!({"t": "brief"}));
            let mut right = some(portrait(p));
            right.extend([
                json!({"t": "contents"}),
                json!({"t": "figure"}),
                json!({"t": "letters"}),
            ]);
            vec![json!({"rows": [row(None, vec![cell(8, left), cell(4, right)])]})]
        }
    }
}

/// Template to use: the requested one if it exists and fits, else one chosen from
/// what the articles offer (varying from week to week).
pub fn choose(requested: Option<&str>, articles: &[Value], edition: &str) -> &'static str {
    let p = parts(articles);
    let fits = |name: &str| name != "portrait" || p.portrait.is_some();
    if let Some(r) = requested {
        if let Some((name, _)) = TEMPLATES.iter().find(|(n, _)| *n == r) {
            if fits(name) {
                return name;
            }
        }
    }
    if p.count <= 1 {
        return "classique";
    }
    let options: Vec<&'static str> = TEMPLATES
        .iter()
        .map(|(n, _)| *n)
        .filter(|n| fits(n))
        .collect();
    let seed = edition
        .bytes()
        .fold(0usize, |h, b| h.wrapping_mul(31).wrapping_add(b as usize));
    options[seed % options.len()]
}

/// pages -> rows -> cells, flattened as the addon expects: (page titles, cells).
fn flatten(pages: &[Value]) -> (Vec<String>, Vec<Value>) {
    let mut titles = Vec::new();
    let mut cells = Vec::new();
    for (pi, page) in pages.iter().enumerate() {
        titles.push(str_of(page, "title").unwrap_or("").to_string());
        for (ri, row) in page["rows"].as_array().into_iter().flatten().enumerate() {
            for c in row["cells"].as_array().into_iter().flatten() {
                let mut cell = json!({"pg": pi + 1, "r": ri + 1, "w": c["w"], "b": c["blocks"]});
                if let Some(h) = row.get("h") {
                    cell["h"] = h.clone();
                }
                cells.push(cell);
            }
        }
    }
    (titles, cells)
}

/// The EDITION item for these (accepted) articles, in editorial order.
pub fn item(template: &str, articles: &[Value], edition: &str) -> Value {
    let p = parts(articles);
    let mut template = template;
    if !is_template(template) || (template == "portrait" && p.portrait.is_none()) {
        template = "classique";
    }
    let mut flat = flatten(&pages(template, &p));
    if serde_json::to_string(&flat).map_or(usize::MAX, |s| s.len()) > MAX_BYTES {
        template = "classique";
        flat = flatten(&pages(template, &p));
    }
    let (titles, cells) = flat;
    json!({
        "id": format!("ia:{edition}:maquette"), "kind": "EDITION",
        "p": {"edition": edition, "template": template, "titles": titles, "cells": cells},
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn art(key: &str, quote: bool, portrait: bool) -> Value {
        let mut p = json!({"key": key, "title": "T", "body": "B"});
        if quote {
            p["quote"] = json!("B");
        }
        if portrait {
            p["portrait"] = json!("Alice");
        }
        json!({"id": key, "kind": "ARTICLE", "p": p})
    }

    fn blocks(v: &Value) -> Vec<Value> {
        let mut out = Vec::new();
        for c in v["p"]["cells"].as_array().unwrap() {
            assert!(c["pg"].as_u64().unwrap() >= 1 && c["r"].as_u64().unwrap() >= 1);
            out.extend(c["b"].as_array().unwrap().iter().cloned());
        }
        out
    }

    /// Nesting as the addon's sync counts it: message, event, p, cells, cell, b, block.
    fn depth(v: &Value) -> usize {
        match v {
            Value::Array(a) => 1 + a.iter().map(depth).max().unwrap_or(0),
            Value::Object(o) => 1 + o.values().map(depth).max().unwrap_or(0),
            _ => 0,
        }
    }

    #[test]
    fn every_template_is_small_and_shows_the_front_page() {
        let arts: Vec<Value> = (1..=5)
            .map(|i| art(&format!("k{i}"), i == 2, i == 1))
            .collect();
        for (name, _) in TEMPLATES {
            let it = item(name, &arts, "2026-S47");
            assert_eq!(it["p"]["template"], *name);
            let size = serde_json::to_string(&it["p"]).unwrap().len();
            assert!(size < MAX_BYTES, "{name}: {size}");
            // message (1) + event (1) + p and below: at most 8 tables deep.
            assert!(2 + depth(&it["p"]) <= 8, "{name}: trop imbriqué");
            let b = blocks(&it);
            assert!(
                b.iter().any(|b| b["t"] == "story" && b["a"] == "@1"),
                "{name}"
            );
            assert!(
                b.iter().any(|b| b["t"] == "quote" && b["a"] == "k2"),
                "{name}: citation"
            );
            assert!(
                b.iter().any(|b| b["t"] == "portrait" && b["a"] == "k1"),
                "{name}: portrait"
            );
        }
    }

    #[test]
    fn choice_respects_request_and_needs() {
        let plain = vec![art("a", false, false), art("b", false, false)];
        assert_eq!(choose(Some("grande_une"), &plain, "E"), "grande_une");
        assert_ne!(
            choose(Some("portrait"), &plain, "E"),
            "portrait",
            "pas de portrait"
        );
        assert_ne!(choose(None, &plain, "E1"), "portrait");
        assert_eq!(choose(Some("inconnu"), &plain[..1], "E"), "classique");
        let with = vec![art("a", false, true), art("b", false, false)];
        assert_eq!(choose(Some("portrait"), &with, "E"), "portrait");
        let it = item("portrait", &plain, "E");
        assert_eq!(
            it["p"]["template"], "classique",
            "portrait sans portrait : la une classique"
        );
    }

    #[test]
    fn long_editions_get_inner_pages() {
        let arts: Vec<Value> = (1..=5)
            .map(|i| art(&format!("k{i}"), false, false))
            .collect();
        let it = item("grande_une", &arts, "E");
        assert_eq!(it["p"]["titles"], json!(["", "Suite de l'édition"]));
        assert_eq!(it["p"]["cells"][0]["h"], 0.6);
        let b = blocks(&it);
        for i in 2..=5 {
            assert!(b
                .iter()
                .any(|b| b["t"] == "story" && b["a"] == format!("@{i}")));
        }
    }
}
