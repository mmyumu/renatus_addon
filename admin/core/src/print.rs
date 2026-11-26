//! The gazette printed as images (for Discord): the same pages as in game
//! (Renatus/UI/Newsprint.lua and TabGazette.lua, ported), but nothing is clickable, so
//! every article is printed in full. A page grows as tall as its stories need, so a
//! story is read in one go on its page; only past MAX_BOTTOM is it cut ("Suite page N").
//! A teaser ends with "Lire page N", and articles only teased (or cut) run on "Suites"
//! pages in three columns, as in a real newspaper.
//!
//! Issues are assembled as the addon does (Views.Editions): numbers (special issues
//! apart), the period each covers, the readers' letters, the latest layout (EDITION).

use std::collections::{BTreeMap, HashSet};

use serde_json::Value;

use crate::chronicle::{num_of, payload, same_guild, str_of, Chronicle};
use crate::gazette::local;
use crate::revise;
use crate::special;
use crate::typeset::{
    self, break_lines, line_height, measure, upper, width, Align, Body, Canvas, Face, Line,
    LineKind, Pos, Style, INK, INK_DIM, RED,
};

const DAY: f64 = 86400.0;

// ---------------------------------------------------------------------------
// Issues, as the addon assembles them
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct Article {
    pub id: String,
    pub t: f64,
    pub title: String,
    pub body: String,
    pub kind: Option<String>,
    pub author: Option<String>,
    pub ia: bool,
    pub key: Option<String>,
    pub quote: Option<String>,
    pub portrait: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Letter {
    pub t: f64,
    pub author: String,
    pub title: String,
    pub body: String,
}

#[derive(Debug, Clone)]
pub struct Edition {
    pub key: String,
    pub number: usize,
    /// Title of a special issue (hors-série).
    pub special: Option<String>,
    pub t: f64,
    pub since: f64,
    pub till: f64,
    pub articles: Vec<Article>,
    pub letters: Vec<Letter>,
    /// p of the latest EDITION of this issue.
    pub layout: Option<Value>,
}

impl Edition {
    /// "N° 12" or "Hors-série n° 2".
    pub fn name(&self) -> String {
        match &self.special {
            Some(_) => format!("Hors-série n° {}", self.number),
            None => format!("N° {}", self.number),
        }
    }
}

const MONTHS: [&str; 12] = [
    "janvier",
    "février",
    "mars",
    "avril",
    "mai",
    "juin",
    "juillet",
    "août",
    "septembre",
    "octobre",
    "novembre",
    "décembre",
];

/// "26 novembre 2026", as UI.Date.
pub fn date_label(t: f64) -> String {
    use chrono::Datelike;
    let d = local(t);
    format!("{} {} {}", d.day(), MONTHS[d.month0() as usize], d.year())
}

fn week_start(t: f64) -> i64 {
    use chrono::{Datelike, Timelike};
    let d = local(t);
    let back = d.weekday().num_days_from_monday() as i64 * 86400
        + d.hour() as i64 * 3600
        + d.minute() as i64 * 60
        + d.second() as i64;
    t as i64 - back
}

/// Published issues, most recent first (Views.Editions).
pub fn editions(ch: &Chronicle) -> Vec<Edition> {
    let mut list: Vec<Edition> = Vec::new();
    for issue in revise::archive(ch, &[]) {
        for a in issue.articles.into_iter().filter(|a| !a.withdrawn) {
            let key = issue
                .key
                .clone()
                .unwrap_or_else(|| format!("semaine:{}", week_start(a.t)));
            let art = Article {
                id: a.id,
                t: a.t,
                title: a.title,
                body: a.body,
                kind: a.format,
                author: a.author,
                ia: a.ia,
                key: a.key,
                quote: a.quote,
                portrait: a.portrait,
            };
            match list.iter_mut().find(|e| e.key == key) {
                Some(e) => {
                    e.t = e.t.max(art.t);
                    e.articles.push(art);
                }
                None => list.push(Edition {
                    key,
                    number: 0,
                    special: None,
                    t: art.t,
                    since: 0.0,
                    till: 0.0,
                    articles: vec![art],
                    letters: Vec::new(),
                    layout: None,
                }),
            }
        }
    }
    // Latest layout of each issue.
    let mut layouts: BTreeMap<String, (f64, Value)> = BTreeMap::new();
    for ev in ch.of_kind("EDITION") {
        let p = payload(ev);
        let Some(key) = str_of(p, "edition") else {
            continue;
        };
        let t = num_of(ev, "t");
        if layouts.get(key).is_none_or(|(lt, _)| t > *lt) {
            layouts.insert(key.to_string(), (t, p.clone()));
        }
    }
    for e in &mut list {
        if let Some((t, p)) = layouts.get(&e.key) {
            e.t = *t;
            e.layout = Some(p.clone());
        }
        e.till = e
            .layout
            .as_ref()
            .and_then(|p| p.get("till"))
            .and_then(Value::as_f64)
            .unwrap_or(e.t);
    }
    list.sort_by(|x, y| y.t.total_cmp(&x.t).then_with(|| y.key.cmp(&x.key)));
    // Readers' letters: with the issue they name, else the latest one published before.
    for ev in ch.of_kind("LETTER") {
        let p = payload(ev);
        let t = num_of(ev, "t");
        let idx = str_of(p, "edition")
            .and_then(|k| list.iter().position(|e| e.key == k))
            .or_else(|| list.iter().position(|e| e.t <= t));
        if let Some(i) = idx {
            list[i].letters.push(Letter {
                t,
                author: str_of(ev, "n").unwrap_or("?").to_string(),
                title: str_of(p, "title").unwrap_or("").to_string(),
                body: str_of(p, "desc").unwrap_or("").to_string(),
            });
        }
    }
    let (mut regular, mut specials) = (0, 0);
    let mut last_till: Option<f64> = None;
    for e in list.iter_mut().rev() {
        e.letters.sort_by(|a, b| a.t.total_cmp(&b.t));
        if special::is_special(&e.key) {
            specials += 1;
            e.number = specials;
            let lay = e.layout.as_ref();
            e.special = Some(
                lay.and_then(|p| str_of(p, "special"))
                    .filter(|s| !s.is_empty())
                    .unwrap_or("Hors-série")
                    .to_string(),
            );
            e.since = lay
                .and_then(|p| p.get("since"))
                .and_then(Value::as_f64)
                .unwrap_or(e.till - 7.0 * DAY);
        } else {
            regular += 1;
            e.number = regular;
            e.since = last_till.unwrap_or(e.till - 7.0 * DAY);
            last_till = Some(e.till);
        }
    }
    list
}

// ---------------------------------------------------------------------------
// Layout data: pages -> rows -> cells -> blocks (N.Sanitize, N.Default, N.Pages)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct Cell {
    w: f32,
    blocks: Vec<Value>,
}

#[derive(Debug, Clone)]
struct Row {
    h: Option<f32>,
    cells: Vec<Cell>,
}

#[derive(Debug, Clone)]
struct Page {
    title: String,
    rows: Vec<Row>,
}

const LIMITS_PAGES: usize = 4;
const LIMITS_ROWS: usize = 4;
const LIMITS_CELLS: usize = 4;
const LIMITS_BLOCKS: usize = 6;

fn default_layout() -> Vec<Page> {
    let b = |v: Value| v;
    vec![Page {
        title: String::new(),
        rows: vec![Row {
            h: None,
            cells: vec![
                Cell {
                    w: 8.0,
                    blocks: vec![
                        b(serde_json::json!({"t": "story", "a": "@1", "cols": 2, "drop": true})),
                        b(serde_json::json!({"t": "brief"})),
                    ],
                },
                Cell {
                    w: 4.0,
                    blocks: vec![
                        serde_json::json!({"t": "contents"}),
                        serde_json::json!({"t": "figure"}),
                        serde_json::json!({"t": "letters"}),
                    ],
                },
            ],
        }],
    }]
}

fn sanitize(p: &Value) -> Option<Vec<Page>> {
    let cells = p.get("cells")?.as_array()?;
    let titles: Vec<String> = p
        .get("titles")
        .and_then(Value::as_array)
        .map(|t| {
            t.iter()
                .map(|s| s.as_str().unwrap_or("").to_string())
                .collect()
        })
        .unwrap_or_default();
    let mut pages: BTreeMap<u64, BTreeMap<u64, Row>> = BTreeMap::new();
    for c in cells {
        let pg = c.get("pg").and_then(Value::as_u64).unwrap_or(1);
        let r = c.get("r").and_then(Value::as_u64).unwrap_or(1);
        let w = c
            .get("w")
            .and_then(Value::as_f64)
            .unwrap_or(6.0)
            .clamp(1.0, 12.0) as f32;
        let blocks: Vec<Value> = c
            .get("b")
            .and_then(Value::as_array)
            .map(|b| {
                b.iter()
                    .filter(|x| str_of(x, "t").is_some())
                    .take(LIMITS_BLOCKS)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        let row = pages.entry(pg).or_default().entry(r).or_insert(Row {
            h: None,
            cells: Vec::new(),
        });
        if let Some(h) = c.get("h").and_then(Value::as_f64) {
            row.h = Some(h.clamp(0.1, 1.0) as f32);
        }
        if row.cells.len() < LIMITS_CELLS {
            row.cells.push(Cell { w, blocks });
        }
    }
    let out: Vec<Page> = pages
        .into_iter()
        .take(LIMITS_PAGES)
        .map(|(pg, rows)| Page {
            title: titles.get(pg as usize - 1).cloned().unwrap_or_default(),
            rows: rows.into_values().take(LIMITS_ROWS).collect(),
        })
        .collect();
    (!out.is_empty()).then_some(out)
}

fn resolve(ed: &Edition, r: &str) -> Option<usize> {
    if let Some(n) = r.strip_prefix('@').and_then(|n| n.parse::<usize>().ok()) {
        return (n >= 1 && n <= ed.articles.len()).then(|| n - 1);
    }
    ed.articles
        .iter()
        .position(|a| a.key.as_deref() == Some(r) || a.id == r)
}

/// Final pages: the layout, plus extra pages for articles no block shows when there is
/// no "contents" block (N.Pages). Returns the pages and the articles they place.
fn layout_pages(ed: &Edition) -> (Vec<Page>, HashSet<usize>) {
    let mut pages = ed
        .layout
        .as_ref()
        .and_then(sanitize)
        .unwrap_or_else(default_layout);
    let mut placed = HashSet::new();
    let mut has_contents = false;
    for pg in &pages {
        for r in &pg.rows {
            for c in &r.cells {
                for b in &c.blocks {
                    match str_of(b, "t") {
                        Some("story") | Some("teaser") => {
                            if let Some(i) = str_of(b, "a").and_then(|a| resolve(ed, a)) {
                                placed.insert(i);
                            }
                        }
                        Some("contents") => has_contents = true,
                        _ => {}
                    }
                }
            }
        }
    }
    let rest: Vec<usize> = (0..ed.articles.len())
        .filter(|i| !placed.contains(i))
        .collect();
    if !rest.is_empty() && !has_contents {
        let rows: Vec<Row> = rest
            .chunks(2)
            .map(|pair| Row {
                h: None,
                cells: pair
                    .iter()
                    .map(|i| Cell {
                        w: 6.0,
                        blocks: vec![serde_json::json!({"t": "story", "a": format!("@{}", i + 1), "cols": 1})],
                    })
                    .collect(),
            })
            .collect();
        for two in rows.chunks(2) {
            pages.push(Page {
                title: "Suite de l'édition".into(),
                rows: two.to_vec(),
            });
        }
    }
    (pages, placed)
}

// ---------------------------------------------------------------------------
// Geometry (the addon's, doubled, on a taller page)
// ---------------------------------------------------------------------------

pub const PAGE_W: u32 = 1400;
pub const PAGE_H: u32 = 1860;
const X0: f32 = 48.0;
const BODY_TOP: f32 = 222.0;
const BODY_TOP_INNER: f32 = 148.0;
const BODY_BOTTOM: f32 = PAGE_H as f32 - 72.0;
/// How far a page may grow to keep its stories whole (a sanity bound, not a layout one).
const MAX_BOTTOM: f32 = 3.0 * PAGE_H as f32;
const GUTTER: f32 = 52.0;
const ROW_GAP: f32 = 28.0;
const BLOCK_GAP: f32 = 24.0;
const COL_GAP: f32 = 28.0;
const SOFT_SHARE: f32 = 0.45;
const TEXT: f32 = 21.0;
const SMALL: f32 = 18.0;
const BODY: Style = Style {
    size: 24.0,
    leading: 3.0,
    indent: 24.0,
};
/// Columns of the "Suites" pages.
const JUMP_COLS: usize = 3;

fn body_w() -> f32 {
    PAGE_W as f32 - 2.0 * X0
}

// ---------------------------------------------------------------------------
// Rendering context
// ---------------------------------------------------------------------------

/// Where an article's text goes on after its page: a continuation (from a place in its
/// body) or the whole article (only teased on its page).
#[derive(Debug, Clone)]
struct Jump {
    article: usize,
    from: Option<Pos>,
    /// Page it jumps from.
    page: usize,
}

struct Ctx<'a> {
    ed: &'a Edition,
    ch: &'a Chronicle,
    guild: Option<String>,
    placed: HashSet<usize>,
    /// Jumps found while drawing, in order.
    jumps: Vec<Jump>,
    /// Page of each jump (second pass), by article.
    jump_page: BTreeMap<usize, usize>,
    /// First page where each article is printed as a story.
    story_page: BTreeMap<usize, usize>,
    /// Page being drawn.
    page: usize,
}

impl Ctx<'_> {
    fn article(&self, b: &Value) -> Option<usize> {
        str_of(b, "a").and_then(|a| resolve(self.ed, a))
    }

    /// The article goes on in the "Suites" pages; returns the page it goes on at. A
    /// continuation replaces a whole reprint: the article was printed after all.
    fn add_jump(&mut self, article: usize, from: Option<Pos>) -> String {
        match self.jumps.iter_mut().find(|j| j.article == article) {
            Some(j) => {
                if from.is_some() && j.from.is_none() {
                    j.from = from;
                    j.page = self.page;
                }
            }
            None => self.jumps.push(Jump {
                article,
                from,
                page: self.page,
            }),
        }
        match self.jump_page.get(&article) {
            Some(p) => format!("{p}"),
            None => "9".into(),
        }
    }

    /// Page a teaser sends to: where the article is printed as a story, else the
    /// "Suites" pages that print it whole.
    fn read_page(&mut self, article: usize) -> String {
        match self.story_page.get(&article) {
            Some(p) => format!("{p}"),
            None => self.add_jump(article, None),
        }
    }
}

fn byline(a: &Article) -> String {
    let mut bits = Vec::new();
    if let Some(au) = &a.author {
        bits.push(if a.ia {
            format!("Rédigé par IA, relu par {au}")
        } else {
            format!("Par {au}")
        });
    }
    bits.push(date_label(a.t));
    bits.join("  ·  ")
}

fn plain(body: &str) -> String {
    body.lines()
        .map(|l| l.trim().trim_start_matches('#').trim())
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

fn section_title(cv: &mut Canvas, label: &str, x: f32, y: f32, w: f32) -> f32 {
    cv.text(Face::Semi, SMALL + 1.0, INK, x, y, &upper(label));
    cv.rule(x, y + 28.0, w, 2.0, 0.6);
    40.0
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Fixed,
    Soft,
    Fill,
}

fn kind_of(t: &str) -> Option<Kind> {
    Some(match t {
        "story" => Kind::Fill,
        "contents" | "brief" => Kind::Soft,
        "teaser" | "quote" | "figure" | "portrait" | "notice" | "wanted" | "letters" => Kind::Fixed,
        _ => return None,
    })
}

fn head_size(b: &Value, w: f32) -> f32 {
    match str_of(b, "head") {
        Some("xl") => 60.0,
        Some("l") => 48.0,
        Some("m") => 38.0,
        Some("s") => 31.0,
        _ if w >= 1120.0 => 56.0,
        _ if w >= 760.0 => 48.0,
        _ if w >= 500.0 => 38.0,
        _ => 31.0,
    }
}

/// Story header: kicker, headline (3 lines at most), byline. Returns its height.
fn story_header(cv: Option<&mut Canvas>, a: &Article, b: &Value, x: f32, y: f32, w: f32) -> f32 {
    let size = head_size(b, w);
    let kicker = str_of(b, "kicker")
        .map(str::to_string)
        .or_else(|| a.kind.clone())
        .unwrap_or_else(|| "À la une".into());
    let by = byline(a);
    let lines = typeset::wrap(Face::Title, size, w, &a.title).len().min(3) as f32;
    let th = lines * line_height(Face::Title, size) * 0.92;
    let h = 30.0 + th + 8.0 + 30.0;
    if let Some(cv) = cv {
        cv.text(Face::Semi, SMALL, RED, x, y, &upper(&kicker));
        para_tight(
            cv,
            Face::Title,
            size,
            INK,
            x,
            y + 30.0,
            w,
            &a.title,
            Some(3),
        );
        cv.text(Face::Italic, SMALL, INK_DIM, x, y + 30.0 + th + 8.0, &by);
    }
    h
}

/// Headline lines a little tighter than the font's own line height.
#[allow(clippy::too_many_arguments)]
fn para_tight(
    cv: &mut Canvas,
    face: Face,
    size: f32,
    color: typeset::Rgb,
    x: f32,
    y: f32,
    w: f32,
    text: &str,
    max: Option<usize>,
) {
    let lh = line_height(face, size) * 0.92;
    let mut lines = typeset::wrap(face, size, w, text);
    if let Some(m) = max {
        lines.truncate(m);
    }
    for (i, l) in lines.iter().enumerate() {
        cv.text(face, size, color, x, y + i as f32 * lh, l);
    }
}

fn story_cols(b: &Value, w: f32) -> (usize, f32) {
    let mut cols = b
        .get("cols")
        .and_then(Value::as_f64)
        .map(|c| c as usize)
        .unwrap_or(if w >= 1120.0 {
            3
        } else if w >= 760.0 {
            2
        } else {
            1
        })
        .clamp(1, 4);
    while cols > 1 && (w - (cols - 1) as f32 * COL_GAP) / (cols as f32) < 240.0 {
        cols -= 1;
    }
    // Lines no longer than a newspaper column: a lone story on a wide row gets more.
    while (w - (cols - 1) as f32 * COL_GAP) / (cols as f32) > 680.0 {
        cols += 1;
    }
    (cols, (w - (cols - 1) as f32 * COL_GAP) / cols as f32)
}

/// Lines split into columns of at most `col_h`: (column of each line, last placed + 1).
fn distribute(lines: &[Line], cols: usize, col_h: f32) -> Vec<Vec<usize>> {
    let mut out = vec![Vec::new(); cols];
    let mut c = 0;
    let mut acc = 0.0;
    for (i, l) in lines.iter().enumerate() {
        let next_is_text = lines
            .get(i + 1)
            .is_some_and(|n| matches!(n.kind, LineKind::Text(_)));
        // A subheading never ends a column.
        let need = if matches!(l.kind, LineKind::Head(_)) && next_is_text {
            l.h + BODY.line()
        } else {
            l.h
        };
        if acc + need > col_h + 0.5 {
            c += 1;
            acc = 0.0;
            if c >= cols {
                break;
            }
        }
        out[c].push(i);
        acc += l.h;
    }
    out
}

fn drop_letter_size() -> f32 {
    BODY.line() * 2.0 + line_height(Face::Body, BODY.size) * 0.66
}

/// How a story's text sits in its columns.
struct Plan {
    lines: Vec<Line>,
    /// Lines of each column.
    cut: Vec<Vec<usize>>,
    col_h: f32,
    first: Option<char>,
    cap_size: f32,
    /// Where the text goes on (none: it all fits) and the column holding "Suite page N".
    next: Option<(Pos, usize, f32)>,
}

/// Lays out a story's text in `cols` columns at most `max_h` high, balanced when it fits.
fn plan(a: &Article, drop: bool, cols: usize, col_w: f32, max_h: f32) -> Option<Plan> {
    let body = Body::parse(&a.body);
    let lh = BODY.line();
    if max_h < 2.0 * lh || body.paras.is_empty() {
        return None;
    }
    let first = if drop { body.first_letter() } else { None };
    let cap_size = drop_letter_size() / 0.62;
    let drop_w = first.map_or(0.0, |c| width(Face::Title, cap_size, &c.to_string()) + 12.0);
    let start = Pos {
        para: 0,
        word: 0,
        offset: usize::from(first.is_some()),
    };
    let beside = if first.is_some() { 3 } else { 0 };
    let lines = break_lines(
        &body,
        start,
        BODY,
        &|i| if i < beside { col_w - drop_w } else { col_w },
        &|i| if i < beside { drop_w } else { 0.0 },
    );
    let total: f32 = lines.iter().map(|l| l.h).sum();
    let mut col_h = max_h
        .min((total / cols as f32).ceil() + lh)
        .max(lh * (beside as f32 + 1.0));
    let mut cut;
    loop {
        cut = distribute(&lines, cols, col_h);
        let placed: usize = cut.iter().map(Vec::len).sum();
        if placed >= lines.len() || col_h >= max_h {
            break;
        }
        col_h = (col_h + lh).min(max_h);
    }
    let placed: usize = cut.iter().map(Vec::len).sum();
    let mut next = None;
    if placed < lines.len() {
        // Room for "Suite page N" at the foot of the last column used.
        let last = cut.iter().rposition(|c| !c.is_empty()).unwrap_or(0);
        let mut used: f32 = cut[last].iter().map(|&i| lines[i].h).sum();
        while used + lh > col_h + 0.5 && !cut[last].is_empty() {
            let i = cut[last].pop().unwrap();
            used -= lines[i].h;
        }
        // Never jump in the middle of a hyphenated word.
        let mut n = cut.iter().flatten().max().map_or(0, |&i| i + 1);
        while lines[n].start.offset > 0 && !cut[last].is_empty() {
            let i = cut[last].pop().unwrap();
            used -= lines[i].h;
            n = i;
        }
        next = Some((lines[n].start, last, used));
    } else {
        col_h = cut
            .iter()
            .map(|c| c.iter().map(|&i| lines[i].h).sum::<f32>())
            .fold(0.0, f32::max);
    }
    Some(Plan {
        lines,
        cut,
        col_h,
        first,
        cap_size,
        next,
    })
}

/// Height of a story's whole text (to fit rows to their content).
fn story_text_h(a: &Article, b: &Value, w: f32) -> f32 {
    let (cols, col_w) = story_cols(b, w);
    let drop = b.get("drop").and_then(Value::as_bool) != Some(false);
    plan(a, drop, cols, col_w, f32::MAX / 4.0).map_or(0.0, |p| p.col_h)
}

/// Story text flowed into columns; the rest jumps to a "Suites" page. Returns the height
/// used.
#[allow(clippy::too_many_arguments)]
fn flow(
    cv: &mut Canvas,
    ctx: &mut Ctx,
    art: usize,
    drop: bool,
    x: f32,
    y: f32,
    cols: usize,
    col_w: f32,
    max_h: f32,
) -> f32 {
    let lh = BODY.line();
    let Some(pl) = plan(&ctx.ed.articles[art], drop, cols, col_w, max_h) else {
        if !ctx.ed.articles[art].body.trim().is_empty() && max_h >= lh {
            let p = ctx.add_jump(art, Some(Pos::default()));
            cv.text(Face::Italic, TEXT, RED, x, y, &format!("Lire page {p} ›"));
        }
        return max_h.min(lh);
    };
    if let Some(c) = pl.first {
        let top = y + BODY.line() * 2.0 + typeset::ascent(Face::Body, BODY.size)
            - typeset::ascent(Face::Title, pl.cap_size);
        cv.text(
            Face::Title,
            pl.cap_size,
            RED,
            x - 2.0,
            top + 2.0,
            &c.to_string(),
        );
    }
    for (c, idx) in pl.cut.iter().enumerate() {
        let cx = x + c as f32 * (col_w + COL_GAP);
        let ls: Vec<Line> = idx.iter().map(|&i| pl.lines[i].clone()).collect();
        cv.lines(BODY, cx, y, &ls);
    }
    if let Some((from, c, used)) = pl.next {
        let p = ctx.add_jump(art, Some(from));
        let cx = x + c as f32 * (col_w + COL_GAP);
        let label = format!("Suite page {p} ›");
        let lw = width(Face::Italic, TEXT, &label);
        cv.text(
            Face::Italic,
            TEXT,
            RED,
            cx + col_w - lw,
            y + used + 2.0,
            &label,
        );
    }
    pl.col_h
}

fn teaser_h(a: &Article, w: f32, lines: usize) -> f32 {
    let snippet = plain(&a.body);
    let th = typeset::wrap(Face::Title, 30.0, w, &a.title).len().min(3) as f32
        * line_height(Face::Title, 30.0)
        * 0.92;
    let n = typeset::wrap(Face::Body, TEXT, w, &snippet)
        .len()
        .min(lines) as f32;
    let sh = n * line_height(Face::Body, TEXT) + (n - 1.0).max(0.0) * 2.0;
    24.0 + 6.0 + th + 8.0 + sh + 6.0 + 28.0
}

fn draw_teaser(
    cv: &mut Canvas,
    ctx: &mut Ctx,
    art: usize,
    x: f32,
    y: f32,
    w: f32,
    lines: usize,
) -> f32 {
    let a = &ctx.ed.articles[art];
    let h = teaser_h(a, w, lines);
    let kicker = a.kind.clone().unwrap_or_else(|| "Article".into());
    cv.text(Face::Semi, SMALL - 1.0, RED, x, y, &upper(&kicker));
    let th = typeset::wrap(Face::Title, 30.0, w, &a.title).len().min(3) as f32
        * line_height(Face::Title, 30.0)
        * 0.92;
    para_tight(
        cv,
        Face::Title,
        30.0,
        INK,
        x,
        y + 30.0,
        w,
        &a.title.clone(),
        Some(3),
    );
    let snippet = plain(&a.body);
    let sh = cv.para(
        Face::Body,
        TEXT,
        INK,
        x,
        y + 30.0 + th + 8.0,
        w,
        &snippet,
        2.0,
        Align::Left,
        Some(lines),
    );
    let p = ctx.read_page(art);
    cv.text(
        Face::Italic,
        TEXT,
        RED,
        x,
        y + 30.0 + th + 8.0 + sh + 6.0,
        &format!("Lire page {p} ›"),
    );
    h
}

fn lines_of(b: &Value, default: usize) -> usize {
    b.get("lines")
        .and_then(Value::as_f64)
        .map_or(default, |n| n as usize)
        .clamp(1, 8)
}

fn unplaced(ctx: &Ctx) -> Vec<usize> {
    (0..ctx.ed.articles.len())
        .filter(|i| !ctx.placed.contains(i))
        .collect()
}

// In brief: notable shared events of the period (Types.Describe for importance >= 3).

fn zone_of(ev: &Value) -> Option<String> {
    let loc = ev.get("loc")?;
    str_of(loc, "i")
        .or_else(|| str_of(loc, "z"))
        .map(str::to_string)
}

fn s(v: &Value, k: &str) -> String {
    match v.get(k) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => "?".into(),
    }
}

fn describe(ev: &Value) -> Option<String> {
    let p = payload(ev);
    let text = match str_of(ev, "k")? {
        "LEVEL_UP" => format!("atteint le niveau {}", s(p, "lvl")),
        "BOSS_KILL" => format!(
            "triomphe de {}",
            str_of(p, "name")
                .map_or_else(|| format!("la rencontre n°{}", s(p, "enc")), str::to_string)
        ),
        "EXPEDITION" => {
            let wh = str_of(p, "inst")
                .map(str::to_string)
                .or_else(|| zone_of(ev))
                .unwrap_or("?".into());
            let mut t =
                str_of(p, "title")
                    .map(str::to_string)
                    .unwrap_or_else(|| match str_of(p, "type") {
                        Some("RAID") => format!("raid : {wh}"),
                        Some("DUNGEON") => format!("expédition dans {wh}"),
                        Some("PVP") => format!("bataille : {wh}"),
                        _ => format!("expédition en {wh}"),
                    });
            let mut bits = Vec::new();
            if let Some(d) = p.get("duration").and_then(Value::as_f64) {
                bits.push(format!("{} min", (d / 60.0).floor()));
            }
            if let Some(b) = p.get("bosses").and_then(Value::as_f64).filter(|b| *b > 0.0) {
                bits.push(format!("{b} boss"));
            }
            if let Some(d) = p.get("deaths").and_then(Value::as_f64).filter(|d| *d > 0.0) {
                bits.push(format!("{d} mort(s)"));
            }
            if !bits.is_empty() {
                t = format!("{t} ({})", bits.join(", "));
            }
            t
        }
        "GUILD_JOIN" => format!("rejoint la guilde {}", s(p, "guild")),
        "RARE_ITEM" => format!("obtient {}", str_of(p, "item").unwrap_or("un objet rare")),
        "ANECDOTE" => str_of(p, "title").unwrap_or("anecdote").to_string(),
        "PVP_CLASH" => {
            let enemy = str_of(p, "enemy")
                .or_else(|| str_of(p, "name"))
                .unwrap_or("un ennemi");
            let r = match str_of(p, "result") {
                Some("win") => format!("l'emporte face à {enemy}"),
                Some("loss") => format!("tombe face à {enemy}"),
                _ => format!("affronte {enemy}"),
            };
            match str_of(p, "member").filter(|m| Some(*m) != str_of(ev, "n")) {
                Some(m) => format!("rapporte : {m} {r}"),
                None => r,
            }
        }
        "PVP_KILL" => {
            if let Some(n) = str_of(p, "name") {
                let g = str_of(p, "guild")
                    .map(|g| format!(" <{g}>"))
                    .unwrap_or_default();
                format!("remporte une victoire honorable sur {n}{g}")
            } else {
                let who = [
                    str_of(p, "race").unwrap_or(""),
                    &str_of(p, "className").unwrap_or("").to_lowercase(),
                ]
                .join(" ")
                .trim()
                .to_string();
                let who = if who.is_empty() { "ennemi".into() } else { who };
                let lvl = p
                    .get("level")
                    .map(|_| format!(" de niveau {}", s(p, "level")))
                    .unwrap_or_default();
                format!("remporte une victoire honorable sur un {who}{lvl}")
            }
        }
        "WANTED" => format!("placarde un avis de recherche contre {}", s(p, "name")),
        "ARTICLE" => format!("publie dans la gazette : « {} »", s(p, "title")),
        "MOUNT" => format!("obtient une monture : {}", s(p, "name")),
        _ => return None,
    };
    Some(format!("{} {text}", str_of(ev, "n").unwrap_or("?")))
}

fn shared(ctx: &Ctx, ev: &Value) -> bool {
    str_of(ev, "vis") == Some("G")
        && match (&ctx.guild, str_of(ev, "g")) {
            (Some(g), Some(eg)) => same_guild(g, eg),
            _ => true,
        }
}

fn brief_lines(ctx: &Ctx, max: usize) -> Vec<String> {
    let mut evs: Vec<&Value> = ctx
        .ch
        .all()
        .filter(|e| {
            let t = num_of(e, "t");
            t >= ctx.ed.since && t < ctx.ed.till && shared(ctx, e)
        })
        .collect();
    evs.sort_by(|a, b| {
        num_of(b, "t")
            .total_cmp(&num_of(a, "t"))
            .then_with(|| str_of(b, "id").cmp(&str_of(a, "id")))
    });
    evs.into_iter()
        .filter_map(describe)
        .take(max)
        .map(|l| format!("• {l}"))
        .collect()
}

fn max_of(b: &Value, default: usize) -> usize {
    b.get("max")
        .and_then(Value::as_f64)
        .map_or(default, |n| n as usize)
        .clamp(1, 12)
}

fn quote_of(ctx: &Ctx, b: &Value) -> Option<(String, Option<String>)> {
    if let Some(t) = str_of(b, "text") {
        return Some((t.to_string(), str_of(b, "by").map(str::to_string)));
    }
    let a = &ctx.ed.articles[ctx.article(b)?];
    let q = a.quote.clone()?;
    Some((
        q,
        Some(str_of(b, "by").map_or_else(|| a.title.clone(), str::to_string)),
    ))
}

fn quote_text(q: &str) -> String {
    let q = q
        .trim()
        .trim_start_matches('«')
        .trim_end_matches('»')
        .trim();
    format!("« {q} »")
}

fn figure_of(ctx: &Ctx, b: &Value) -> Option<(String, String)> {
    if let Some(v) = str_of(b, "value").filter(|v| *v != "deaths") {
        return Some((v.to_string(), str_of(b, "label").unwrap_or("").to_string()));
    }
    let deaths = ctx
        .ch
        .of_kind("DEATH")
        .filter(|e| {
            let t = num_of(e, "t");
            t >= ctx.ed.since && t < ctx.ed.till && shared(ctx, e)
        })
        .count();
    if deaths == 0 {
        return None;
    }
    let label = str_of(b, "label").map(str::to_string).unwrap_or_else(|| {
        if deaths == 1 {
            "décès dans la guilde depuis le dernier numéro. Un seul : la rédaction s'ennuie.".into()
        } else {
            "décès dans la guilde depuis le dernier numéro. Les esprits gardiens font des heures supplémentaires.".into()
        }
    });
    Some((deaths.to_string(), label))
}

struct Who {
    name: String,
    class: Option<String>,
    level: Option<i64>,
    caption: Option<String>,
}

const CLASS_FR: [(&str, &str); 13] = [
    ("WARRIOR", "Guerrier"),
    ("PALADIN", "Paladin"),
    ("HUNTER", "Chasseur"),
    ("ROGUE", "Voleur"),
    ("PRIEST", "Prêtre"),
    ("DEATHKNIGHT", "Chevalier de la mort"),
    ("SHAMAN", "Chaman"),
    ("MAGE", "Mage"),
    ("WARLOCK", "Démoniste"),
    ("MONK", "Moine"),
    ("DRUID", "Druide"),
    ("DEMONHUNTER", "Chasseur de démons"),
    ("EVOKER", "Évocateur"),
];

const CLASS_RGB: [(&str, (u8, u8, u8)); 9] = [
    ("WARRIOR", (199, 156, 110)),
    ("MAGE", (64, 199, 235)),
    ("ROGUE", (255, 245, 105)),
    ("DRUID", (255, 125, 10)),
    ("HUNTER", (171, 212, 115)),
    ("SHAMAN", (0, 112, 222)),
    ("PRIEST", (255, 255, 255)),
    ("WARLOCK", (135, 135, 237)),
    ("PALADIN", (245, 140, 186)),
];

fn first_name(n: &str) -> &str {
    n.split('-').next().unwrap_or(n)
}

fn portrait_of(ctx: &Ctx, b: &Value) -> Option<Who> {
    let art = ctx.article(b).map(|i| &ctx.ed.articles[i]);
    let name = str_of(b, "name")
        .map(str::to_string)
        .or_else(|| art.and_then(|a| a.portrait.clone()))
        .filter(|n| !n.is_empty())?;
    let mut who = Who {
        name: name.clone(),
        class: None,
        level: None,
        caption: str_of(b, "caption")
            .map(str::to_string)
            .or_else(|| art.map(|a| a.title.clone())),
    };
    let roster = ctx
        .ch
        .monitor
        .get("roster")
        .and_then(|r| r.get("members"))
        .and_then(Value::as_array);
    if let Some(m) = roster.into_iter().flatten().find(|m| {
        str_of(m, "name").is_some_and(|n| {
            n.eq_ignore_ascii_case(&name) || first_name(n).eq_ignore_ascii_case(&name)
        })
    }) {
        who.name = first_name(str_of(m, "name").unwrap_or(&name)).to_string();
        who.class = str_of(m, "class").map(str::to_string);
        who.level = m.get("level").and_then(Value::as_i64);
    }
    let mut evs: Vec<&Value> = ctx
        .ch
        .all()
        .filter(|e| str_of(e, "n").is_some_and(|n| n.eq_ignore_ascii_case(&name)))
        .collect();
    evs.sort_by(|a, b| num_of(b, "t").total_cmp(&num_of(a, "t")));
    for e in evs {
        if who.class.is_none() {
            who.class = str_of(e, "c").map(str::to_string);
        }
        if who.level.is_none() && str_of(e, "k") == Some("LEVEL_UP") {
            who.level = payload(e).get("lvl").and_then(Value::as_i64);
        }
    }
    Some(who)
}

fn portrait_sub(who: &Who) -> String {
    let cls = who.class.as_deref().map(|c| {
        CLASS_FR
            .iter()
            .find(|(k, _)| *k == c)
            .map_or(c, |(_, v)| v)
            .to_string()
    });
    match (cls, who.level) {
        (Some(c), Some(l)) => format!("{c} de niveau {l}"),
        (Some(c), None) => c,
        (None, Some(l)) => format!("Niveau {l}"),
        (None, None) => String::new(),
    }
}

const MEDAL: f32 = 132.0;

/// The engraved medallion: a ring, the class colour washed in ink, the initial.
fn medallion(cv: &mut Canvas, who: &Who, x: f32, y: f32) {
    let r = MEDAL / 2.0;
    let (cx, cy) = (x + r, y + r);
    cv.circle(cx, cy, r - 3.0, Some((INK_DIM, 0.18)), None);
    if let Some(rgb) = who
        .class
        .as_deref()
        .and_then(|c| CLASS_RGB.iter().find(|(k, _)| *k == c))
        .map(|(_, v)| *v)
    {
        cv.circle(cx, cy, r - 14.0, Some((rgb, 0.35)), None);
    }
    cv.circle(cx, cy, r - 4.0, None, Some((INK, 0.85, 5.0)));
    cv.circle(cx, cy, r - 12.0, None, Some((INK, 0.6, 1.5)));
    let initial: String = who
        .name
        .chars()
        .next()
        .map(|c| c.to_uppercase().collect())
        .unwrap_or_default();
    let size = 72.0;
    let iw = width(Face::Title, size, &initial);
    let ih = line_height(Face::Title, size);
    cv.text(
        Face::Title,
        size,
        INK,
        cx - iw / 2.0,
        cy - ih / 2.0 + 4.0,
        &initial,
    );
}

fn letter_text(ctx: &Ctx, b: &Value) -> String {
    if let Some(t) = str_of(b, "text") {
        return t.to_string();
    }
    match ctx.ed.letters.last() {
        None => "Une remarque, un démenti, une rumeur ? Écris à la rédaction : ta lettre paraît dans ce numéro.".into(),
        Some(l) => {
            let mut ex: String = l.body.chars().take(90).collect();
            if l.body.chars().count() > 90 {
                if let Some(i) = ex.rfind(' ') {
                    ex.truncate(i);
                }
                ex.push('…');
            }
            let n = ctx.ed.letters.len();
            format!("{n} lettre{}. La dernière, de {} : « {ex} »", if n > 1 { "s" } else { "" }, l.author)
        }
    }
}

fn letters_link(ctx: &Ctx) -> String {
    let n = ctx.ed.letters.len();
    if n > 0 {
        format!("Le courrier ({n}) se lit dans l'addon, onglet Gazette.")
    } else {
        "Écrire à la rédaction : dans l'addon, onglet Gazette.".into()
    }
}

fn wanted_of<'c>(ctx: &'c Ctx, b: &Value) -> Option<&'c Value> {
    let mut closed: BTreeMap<String, f64> = BTreeMap::new();
    for e in ctx.ch.of_kind("WANTED_CLOSE") {
        if let Some(n) = str_of(payload(e), "name") {
            let t = num_of(e, "t");
            let c = closed.entry(n.to_lowercase()).or_insert(t);
            *c = c.max(t);
        }
    }
    let mut list: Vec<&Value> = ctx.ch.of_kind("WANTED").collect();
    list.sort_by(|a, b| num_of(b, "t").total_cmp(&num_of(a, "t")));
    list.into_iter().map(payload).find(|p| {
        let Some(n) = str_of(p, "name") else {
            return false;
        };
        str_of(b, "name").is_none_or(|w| w.eq_ignore_ascii_case(n))
            && closed
                .get(&n.to_lowercase())
                .is_none_or(|c| *c <= num_of(p, "t"))
    })
}

fn wanted_lines(p: &Value) -> String {
    let mut l = Vec::new();
    if let Some(n) = str_of(p, "nickname") {
        l.push(format!("« {n} »"));
    }
    if let Some(r) = str_of(p, "reason") {
        l.push(r.to_string());
    }
    if let Some(r) = str_of(p, "reward") {
        l.push(format!("Récompense : {r}"));
    }
    l.join("\n")
}

fn frame(cv: &mut Canvas, x: f32, y: f32, w: f32, h: f32) {
    cv.rule(x, y, w, 2.0, 1.0);
    cv.rule(x, y + h - 2.0, w, 2.0, 1.0);
    cv.rule(x, y, 2.0, h, 1.0);
    cv.rule(x + w - 2.0, y, 2.0, h, 1.0);
}

/// Natural height of a block at width w (0: nothing to show).
fn block_measure(ctx: &Ctx, b: &Value, w: f32) -> f32 {
    match str_of(b, "t").unwrap_or("") {
        "story" => ctx.article(b).map_or(0.0, |i| {
            story_header(None, &ctx.ed.articles[i], b, 0.0, 0.0, w) + 3.0 * BODY.line()
        }),
        "teaser" => ctx
            .article(b)
            .map_or(0.0, |i| teaser_h(&ctx.ed.articles[i], w, lines_of(b, 3))),
        "contents" => {
            let rest = unplaced(ctx);
            if rest.is_empty() {
                return 0.0;
            }
            44.0 + rest
                .iter()
                .map(|&i| teaser_h(&ctx.ed.articles[i], w, 3) + 28.0)
                .sum::<f32>()
        }
        "brief" => {
            let l = brief_lines(ctx, max_of(b, 6));
            if l.is_empty() {
                0.0
            } else {
                40.0 + measure(Face::Body, TEXT, w, &l.join("\n"), 6.0)
            }
        }
        "quote" => quote_of(ctx, b).map_or(0.0, |(t, by)| {
            16.0 + measure(Face::TitleItalic, 32.0, w - 24.0, &quote_text(&t), 0.0)
                + by.map_or(8.0, |by| {
                    14.0 + measure(Face::Italic, SMALL, w, &format!("— {by}"), 0.0)
                })
                + 16.0
        }),
        "figure" => figure_of(ctx, b).map_or(0.0, |(v, label)| {
            let vw = width(Face::Title, 72.0, &v) + 24.0;
            40.0 + measure(Face::Body, TEXT, w - vw, &label, 2.0).max(84.0) + 8.0
        }),
        "portrait" => portrait_of(ctx, b).map_or(0.0, |who| {
            let wide = w >= 360.0;
            let tw = if wide { w - MEDAL - 24.0 } else { w };
            let th = measure(Face::Title, 32.0, tw, &who.name, 0.0)
                + 28.0
                + who
                    .caption
                    .as_ref()
                    .map_or(0.0, |c| measure(Face::Body, TEXT, tw, c, 2.0) + 8.0);
            40.0 + if wide {
                MEDAL.max(th)
            } else {
                MEDAL + 12.0 + th
            }
        }),
        "notice" => {
            let (t, x) = (str_of(b, "title"), str_of(b, "text"));
            if t.is_none() && x.is_none() {
                return 0.0;
            }
            20.0 + t.map_or(0.0, |t| measure(Face::Title, 28.0, w - 32.0, t, 0.0) + 8.0)
                + x.map_or(0.0, |x| measure(Face::Body, TEXT, w - 32.0, x, 2.0))
                + 20.0
        }
        "wanted" => wanted_of(ctx, b).map_or(0.0, |p| {
            16.0 + 48.0
                + measure(
                    Face::Title,
                    32.0,
                    w - 32.0,
                    str_of(p, "name").unwrap_or(""),
                    0.0,
                )
                + 8.0
                + measure(Face::Body, TEXT, w - 32.0, &wanted_lines(p), 4.0)
                + 20.0
        }),
        "letters" => 40.0 + measure(Face::Body, TEXT, w, &letter_text(ctx, b), 2.0) + 12.0 + 28.0,
        _ => 0.0,
    }
}

fn block_draw(cv: &mut Canvas, ctx: &mut Ctx, b: &Value, x: f32, y: f32, w: f32, h: f32) {
    match str_of(b, "t").unwrap_or("") {
        "story" => {
            let Some(i) = ctx.article(b) else { return };
            let a = ctx.ed.articles[i].clone();
            let top = story_header(Some(cv), &a, b, x, y, w);
            let (cols, col_w) = story_cols(b, w);
            let drop = b.get("drop").and_then(Value::as_bool) != Some(false);
            flow(cv, ctx, i, drop, x, y + top, cols, col_w, h - top);
        }
        "teaser" => {
            if let Some(i) = ctx.article(b) {
                draw_teaser(cv, ctx, i, x, y, w, lines_of(b, 3));
            }
        }
        "contents" => {
            let rest = unplaced(ctx);
            let title = str_of(b, "title").unwrap_or("Dans cette édition");
            let mut top = y + section_title(cv, title, x, y, w) + 4.0;
            for i in rest {
                let th = teaser_h(&ctx.ed.articles[i], w, 3);
                if top + th > y + h + 1.0 {
                    // Not shown here: printed whole on a "Suites" page all the same.
                    ctx.read_page(i);
                    continue;
                }
                draw_teaser(cv, ctx, i, x, top, w, 3);
                cv.rule(x, top + th + 12.0, w, 1.0, 0.4);
                top += th + 28.0;
            }
        }
        "brief" => {
            let lines = brief_lines(ctx, max_of(b, 6));
            let top = y + section_title(cv, str_of(b, "title").unwrap_or("En bref"), x, y, w);
            let mut shown: Vec<String> = Vec::new();
            for l in lines {
                shown.push(l);
                if measure(Face::Body, TEXT, w, &shown.join("\n"), 6.0) > y + h - top {
                    shown.pop();
                    break;
                }
            }
            cv.para(
                Face::Body,
                TEXT,
                INK,
                x,
                top,
                w,
                &shown.join("\n"),
                6.0,
                Align::Left,
                None,
            );
        }
        "quote" => {
            let Some((t, by)) = quote_of(ctx, b) else {
                return;
            };
            cv.rule(x, y, w, 4.0, 1.0);
            cv.para(
                Face::TitleItalic,
                32.0,
                RED,
                x + 12.0,
                y + 16.0,
                w - 24.0,
                &quote_text(&t),
                0.0,
                Align::Center,
                None,
            );
            if let Some(by) = by {
                let label = format!("— {by}");
                let bh = measure(Face::Italic, SMALL, w, &label, 0.0);
                cv.para(
                    Face::Italic,
                    SMALL,
                    INK_DIM,
                    x,
                    y + h - 16.0 - bh,
                    w,
                    &label,
                    0.0,
                    Align::Right,
                    None,
                );
            }
            cv.rule(x, y + h - 3.0, w, 2.0, 1.0);
        }
        "figure" => {
            let Some((v, label)) = figure_of(ctx, b) else {
                return;
            };
            let default = if ctx.ed.special.is_some() {
                "Le chiffre du numéro"
            } else {
                "Le chiffre de la semaine"
            };
            let top = y + section_title(cv, str_of(b, "title").unwrap_or(default), x, y, w);
            let vw = width(Face::Title, 72.0, &v) + 24.0;
            cv.text(Face::Title, 72.0, RED, x, top - 6.0, &v);
            cv.para(
                Face::Body,
                TEXT,
                INK,
                x + vw,
                top + 8.0,
                w - vw,
                &label,
                2.0,
                Align::Left,
                None,
            );
        }
        "portrait" => {
            let Some(who) = portrait_of(ctx, b) else {
                return;
            };
            let top = y + section_title(cv, str_of(b, "title").unwrap_or("Le portrait"), x, y, w);
            let wide = w >= 360.0;
            let mx = if wide { x } else { x + (w - MEDAL) / 2.0 };
            medallion(cv, &who, mx, top);
            let (tx, mut ty, tw, al) = if wide {
                (x + MEDAL + 24.0, top + 4.0, w - MEDAL - 24.0, Align::Left)
            } else {
                (x, top + MEDAL + 12.0, w, Align::Center)
            };
            ty += cv.para(Face::Title, 32.0, INK, tx, ty, tw, &who.name, 0.0, al, None) + 2.0;
            ty += cv.para(
                Face::Italic,
                SMALL,
                INK_DIM,
                tx,
                ty,
                tw,
                &portrait_sub(&who),
                0.0,
                al,
                None,
            ) + 8.0;
            if let Some(c) = &who.caption {
                cv.para(Face::Body, TEXT, INK, tx, ty, tw, c, 2.0, al, None);
            }
        }
        "notice" => {
            frame(cv, x, y, w, h);
            let mut top = y + 20.0;
            if let Some(t) = str_of(b, "title") {
                top += cv.para(
                    Face::Title,
                    28.0,
                    INK,
                    x + 16.0,
                    top,
                    w - 32.0,
                    t,
                    0.0,
                    Align::Center,
                    None,
                ) + 8.0;
            }
            if let Some(t) = str_of(b, "text") {
                cv.para(
                    Face::Body,
                    TEXT,
                    INK,
                    x + 16.0,
                    top,
                    w - 32.0,
                    t,
                    2.0,
                    Align::Center,
                    None,
                );
            }
        }
        "wanted" => {
            let Some(p) = wanted_of(ctx, b) else { return };
            let p = p.clone();
            frame(cv, x, y, w, h);
            cv.rule(x + 6.0, y + 6.0, w - 12.0, 1.0, 0.5);
            cv.para(
                Face::Title,
                40.0,
                RED,
                x + 16.0,
                y + 14.0,
                w - 32.0,
                str_of(b, "title").unwrap_or("RECHERCHÉ"),
                0.0,
                Align::Center,
                None,
            );
            let nh = cv.para(
                Face::Title,
                32.0,
                INK,
                x + 16.0,
                y + 64.0,
                w - 32.0,
                str_of(&p, "name").unwrap_or(""),
                0.0,
                Align::Center,
                None,
            );
            cv.para(
                Face::Body,
                TEXT,
                INK,
                x + 16.0,
                y + 64.0 + nh + 8.0,
                w - 32.0,
                &wanted_lines(&p),
                4.0,
                Align::Center,
                None,
            );
        }
        "letters" => {
            let top = y + section_title(
                cv,
                str_of(b, "title").unwrap_or("Courrier des lecteurs"),
                x,
                y,
                w,
            );
            let th = cv.para(
                Face::Body,
                TEXT,
                INK,
                x,
                top,
                w,
                &letter_text(ctx, b),
                2.0,
                Align::Left,
                None,
            );
            cv.para(
                Face::Italic,
                SMALL,
                RED,
                x,
                top + th + 12.0,
                w,
                &letters_link(ctx),
                0.0,
                Align::Left,
                None,
            );
        }
        _ => {}
    }
}

/// One cell's blocks in (x, y, w, h): fixed blocks at their height, soft ones at most
/// theirs, stories share the rest (N drawCell).
fn draw_cell(cv: &mut Canvas, ctx: &mut Ctx, cell: &Cell, x: f32, y: f32, w: f32, h: f32) {
    struct It<'b> {
        b: &'b Value,
        kind: Kind,
        nat: f32,
        h: f32,
    }
    let mut items: Vec<It> = Vec::new();
    for b in &cell.blocks {
        let Some(kind) = str_of(b, "t").and_then(kind_of) else {
            continue;
        };
        let nat = block_measure(ctx, b, w);
        if nat > 0.0 {
            items.push(It {
                b,
                kind,
                nat,
                h: 0.0,
            });
        }
    }
    if items.is_empty() {
        return;
    }
    let gaps = |n: usize| n.saturating_sub(1) as f32 * BLOCK_GAP;
    let mut fixed_h: f32 = items
        .iter()
        .filter(|i| i.kind == Kind::Fixed)
        .map(|i| i.nat)
        .sum();
    while fixed_h + gaps(items.len()) > h {
        let Some(k) = items.iter().rposition(|i| i.kind == Kind::Fixed) else {
            break;
        };
        fixed_h -= items[k].nat;
        // A teaser dropped from the page is still printed whole on a "Suites" page.
        if str_of(items[k].b, "t") == Some("teaser") {
            if let Some(i) = ctx.article(items[k].b) {
                ctx.read_page(i);
            }
        }
        items.remove(k);
    }
    let left = (h - fixed_h - gaps(items.len())).max(0.0);
    let softs = items.iter().filter(|i| i.kind == Kind::Soft).count();
    let fills = items.iter().filter(|i| i.kind == Kind::Fill).count();
    let cap = (if fills > 0 { left * SOFT_SHARE } else { left }) / softs.max(1) as f32;
    let mut soft_used = 0.0;
    for it in &mut items {
        it.h = match it.kind {
            Kind::Fixed => it.nat,
            Kind::Soft => {
                let v = it.nat.min(cap);
                soft_used += v;
                v
            }
            Kind::Fill => 0.0,
        };
    }
    let fill_h = if fills > 0 {
        (left - soft_used).max(0.0) / fills as f32
    } else {
        0.0
    };
    for it in &mut items {
        if it.kind == Kind::Fill {
            it.h = fill_h;
        }
    }
    let mut cy = y;
    let n = items.len();
    for i in 0..n {
        if items[i].h > 8.0 {
            block_draw(cv, ctx, items[i].b, x, cy, w, items[i].h);
            cy += items[i].h;
            if i + 1 < n {
                if items[i].kind != Kind::Fixed || items[i + 1].kind != Kind::Fixed {
                    cv.rule(x, cy + BLOCK_GAP / 2.0, w, 1.0, 0.35);
                }
                cy += BLOCK_GAP;
            }
        }
    }
}

/// Height a cell needs to show everything (stories in full).
fn cell_need(ctx: &Ctx, cell: &Cell, w: f32) -> f32 {
    let mut h = 0.0;
    let mut n: usize = 0;
    for b in &cell.blocks {
        let Some(kind) = str_of(b, "t").and_then(kind_of) else {
            continue;
        };
        let nat = if kind == Kind::Fill {
            ctx.article(b).map_or(0.0, |i| {
                let a = &ctx.ed.articles[i];
                story_header(None, a, b, 0.0, 0.0, w) + story_text_h(a, b, w)
            })
        } else {
            block_measure(ctx, b, w)
        };
        if nat > 0.0 {
            h += nat;
            n += 1;
        }
    }
    h + n.saturating_sub(1) as f32 * BLOCK_GAP
}

/// A page of the layout in the body area (N.Draw). Unlike the game's fixed page, rows
/// fit their content: a row that needs less gives its room to those that need more, and
/// the page ends where the content does. Returns that bottom.
fn draw_body(cv: &mut Canvas, ctx: &mut Ctx, page: &Page, top: f32, bottom: f32) -> f32 {
    let (x0, width) = (X0, body_w());
    let body_h = bottom - top;
    let rows = &page.rows;
    let avail = body_h - rows.len().saturating_sub(1) as f32 * ROW_GAP;
    let fixed: f32 = rows.iter().filter_map(|r| r.h).map(|h| h * body_h).sum();
    let free = rows.iter().filter(|r| r.h.is_none()).count();
    let scale = if fixed > avail { avail / fixed } else { 1.0 };
    let rest = if free > 0 {
        (avail - fixed * scale).max(0.0) / free as f32
    } else {
        0.0
    };
    let widths = |r: &Row| -> Vec<f32> {
        let total: f32 = r.cells.iter().map(|c| c.w).sum();
        let cw = width - r.cells.len().saturating_sub(1) as f32 * GUTTER;
        r.cells.iter().map(|c| cw * c.w / total).collect()
    };
    let mut hs: Vec<f32> = rows
        .iter()
        .map(|r| r.h.map_or(rest, |h| h * body_h * scale))
        .collect();
    if free == 0 {
        // The last row takes what the others leave.
        let others: f32 = hs.iter().rev().skip(1).sum();
        if let Some(last) = hs.last_mut() {
            *last = (avail - others).max(0.0);
        }
    }
    let needs: Vec<f32> = rows
        .iter()
        .map(|r| {
            r.cells
                .iter()
                .zip(widths(r))
                .map(|(c, w)| cell_need(ctx, c, w))
                .fold(0.0, f32::max)
        })
        .collect();
    let surplus: f32 = hs.iter().zip(&needs).map(|(h, n)| (h - n).max(0.0)).sum();
    let deficit: f32 = hs.iter().zip(&needs).map(|(h, n)| (n - h).max(0.0)).sum();
    for (h, n) in hs.iter_mut().zip(&needs) {
        if *n <= *h {
            *h = *n;
        } else if deficit > 0.0 {
            *h += (surplus * (*n - *h) / deficit).min(*n - *h);
        }
    }
    let mut y = top;
    for (ri, r) in rows.iter().enumerate() {
        let rh = hs[ri].ceil();
        let mut x = x0;
        let ws = widths(r);
        for (ci, c) in r.cells.iter().enumerate() {
            let w = ws[ci];
            draw_cell(cv, ctx, c, x, y, w, rh);
            x += w + GUTTER;
            if ci + 1 < r.cells.len() {
                cv.rule(x - GUTTER / 2.0, y, 1.0, rh, 0.6);
            }
        }
        y += rh;
        if ri + 1 < rows.len() {
            cv.rule(x0, y + ROW_GAP / 2.0 - 1.0, width, 2.0, 0.85);
            y += ROW_GAP;
        }
    }
    y
}

// ---------------------------------------------------------------------------
// "Suites" pages: the rest of each article, in three columns
// ---------------------------------------------------------------------------

/// A piece of the "Suites" pages: header lines then body lines, flowed in columns.
enum Item {
    /// Kicker, headline, byline of a piece (height).
    Head {
        art: usize,
        whole: bool,
        h: f32,
    },
    Text(Line),
}

fn jump_col_w() -> f32 {
    (body_w() - (JUMP_COLS - 1) as f32 * GUTTER) / JUMP_COLS as f32
}

const JUMP_HEAD: f32 = 34.0;

fn jump_head_h(a: &Article, whole: bool, w: f32) -> f32 {
    let th = typeset::wrap(Face::Title, JUMP_HEAD, w, &a.title).len() as f32
        * line_height(Face::Title, JUMP_HEAD)
        * 0.92;
    let quote = if whole {
        a.quote.as_ref().map_or(0.0, |q| {
            measure(Face::TitleItalic, 26.0, w - 16.0, &quote_text(q), 0.0) + 32.0
        })
    } else {
        0.0
    };
    28.0 + th + 6.0 + if whole { 30.0 } else { 0.0 } + quote + 14.0
}

#[allow(clippy::too_many_arguments)]
fn draw_jump_head(
    cv: &mut Canvas,
    ctx: &Ctx,
    art: usize,
    whole: bool,
    from_page: usize,
    x: f32,
    y: f32,
    w: f32,
) {
    let a = &ctx.ed.articles[art];
    let kicker = if whole {
        upper(a.kind.as_deref().unwrap_or("Article"))
    } else if from_page == 1 {
        "SUITE DE LA UNE".to_string()
    } else {
        format!("SUITE DE LA PAGE {from_page}")
    };
    cv.text(Face::Semi, SMALL - 1.0, RED, x, y, &kicker);
    let mut yy = y + 28.0;
    let lh = line_height(Face::Title, JUMP_HEAD) * 0.92;
    for l in typeset::wrap(Face::Title, JUMP_HEAD, w, &a.title) {
        cv.text(Face::Title, JUMP_HEAD, INK, x, yy, &l);
        yy += lh;
    }
    yy += 6.0;
    if whole {
        cv.text(Face::Italic, SMALL, INK_DIM, x, yy, &byline(a));
        yy += 30.0;
        if let Some(q) = &a.quote {
            cv.rule(x, yy + 4.0, w, 2.0, 0.8);
            let qh = cv.para(
                Face::TitleItalic,
                26.0,
                RED,
                x + 8.0,
                yy + 14.0,
                w - 16.0,
                &quote_text(q),
                0.0,
                Align::Center,
                None,
            );
            cv.rule(x, yy + 14.0 + qh + 10.0, w, 1.0, 0.8);
        }
    }
}

/// A "Suites" page: its items (column, item) and the height its longest column takes.
struct JumpPage {
    items: Vec<(usize, Item)>,
    used: f32,
}

/// "Suites" pages for the jumps, and the page each jump starts on (first "Suites" page =
/// `first`). Columns are filled one after the other; the last page is balanced.
fn jump_pages(ctx: &Ctx, jumps: &[Jump], first: usize) -> (Vec<JumpPage>, BTreeMap<usize, usize>) {
    let full = BODY_BOTTOM - 2.0 - (BODY_TOP_INNER + 8.0);
    let (pages, starts) = jump_flow(ctx, jumps, first, &|_| full);
    let n = pages.len();
    if n == 0 {
        return (pages, starts);
    }
    // Shortest last page that keeps the same number of pages.
    let (mut lo, mut hi) = (BODY.line() * 2.0, full);
    for _ in 0..14 {
        let mid = (lo + hi) / 2.0;
        let (p, _) = jump_flow(ctx, jumps, first, &|i| if i + 1 == n { mid } else { full });
        if p.len() == n {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    jump_flow(ctx, jumps, first, &|i| if i + 1 == n { hi } else { full })
}

fn jump_flow(
    ctx: &Ctx,
    jumps: &[Jump],
    first: usize,
    col_h_of: &dyn Fn(usize) -> f32,
) -> (Vec<JumpPage>, BTreeMap<usize, usize>) {
    let cw = jump_col_w();
    let mut pages: Vec<Vec<(usize, Item)>> = vec![Vec::new()];
    let mut starts = BTreeMap::new();
    let (mut col, mut acc) = (0usize, 0.0f32);
    let mut used: Vec<f32> = vec![0.0];
    let next_col = |pages: &mut Vec<Vec<(usize, Item)>>,
                    used: &mut Vec<f32>,
                    col: &mut usize,
                    acc: &mut f32| {
        *col += 1;
        *acc = 0.0;
        if *col >= JUMP_COLS {
            *col = 0;
            pages.push(Vec::new());
            used.push(0.0);
        }
    };
    for j in jumps {
        let a = &ctx.ed.articles[j.article];
        let whole = j.from.is_none();
        let hh = jump_head_h(a, whole, cw);
        let body = Body::parse(&a.body);
        let lines = break_lines(&body, j.from.unwrap_or_default(), BODY, &|_| cw, &|_| 0.0);
        // Keep a header with at least two lines of its text.
        let gap = |acc: f32| if acc > 0.0 { BLOCK_GAP * 1.5 } else { 0.0 };
        let need = hh + lines.iter().take(2).map(|l| l.h).sum::<f32>();
        if acc > 0.0 && acc + gap(acc) + need > col_h_of(pages.len() - 1) {
            next_col(&mut pages, &mut used, &mut col, &mut acc);
        }
        acc += gap(acc);
        starts.insert(j.article, first + pages.len() - 1);
        pages.last_mut().unwrap().push((
            col,
            Item::Head {
                art: j.article,
                whole,
                h: hh,
            },
        ));
        acc += hh;
        let u = used.last_mut().unwrap();
        *u = u.max(acc);
        for (k, l) in lines.into_iter().enumerate() {
            // A subheading never ends a column; the first line after a jump is not indented.
            let need = if matches!(l.kind, LineKind::Head(_)) {
                l.h + BODY.line()
            } else {
                l.h
            };
            if acc + need > col_h_of(pages.len() - 1) {
                next_col(&mut pages, &mut used, &mut col, &mut acc);
            }
            let mut l = l;
            if k == 0 && !whole {
                l.x = 0.0;
            }
            acc += l.h;
            let u = used.last_mut().unwrap();
            *u = u.max(acc);
            pages.last_mut().unwrap().push((col, Item::Text(l)));
        }
    }
    let pages = pages
        .into_iter()
        .zip(used)
        .filter(|(items, _)| !items.is_empty())
        .map(|(items, used)| JumpPage { items, used })
        .collect();
    (pages, starts)
}

fn draw_jump_page(
    cv: &mut Canvas,
    ctx: &Ctx,
    items: &[(usize, Item)],
    from: &BTreeMap<usize, usize>,
    bottom: f32,
) {
    let cw = jump_col_w();
    let top = BODY_TOP_INNER + 8.0;
    let mut ys = [top; JUMP_COLS];
    let mut gaps_after_text = [false; JUMP_COLS];
    for (col, it) in items {
        let x = X0 + *col as f32 * (cw + GUTTER);
        match it {
            Item::Head { art, whole, h } => {
                if ys[*col] > top {
                    ys[*col] += BLOCK_GAP * 1.5;
                    if gaps_after_text[*col] {
                        cv.rule(
                            x + cw * 0.3,
                            ys[*col] - BLOCK_GAP * 0.75,
                            cw * 0.4,
                            1.0,
                            0.5,
                        );
                    }
                }
                draw_jump_head(
                    cv,
                    ctx,
                    *art,
                    *whole,
                    from.get(art).copied().unwrap_or(1),
                    x,
                    ys[*col],
                    cw,
                );
                ys[*col] += h;
            }
            Item::Text(l) => {
                cv.lines(BODY, x, ys[*col], std::slice::from_ref(l));
                ys[*col] += l.h;
                gaps_after_text[*col] = true;
            }
        }
    }
    for c in 1..JUMP_COLS {
        let x = X0 + c as f32 * (cw + GUTTER) - GUTTER / 2.0;
        cv.rule(x, top, 1.0, bottom - top, 0.6);
    }
}

// ---------------------------------------------------------------------------
// Masthead, running head, footer
// ---------------------------------------------------------------------------

const MASTHEAD: &str = "La Gazette de la Guilde";

fn number_label(ed: &Edition) -> String {
    match ed.special {
        Some(_) => format!("HORS-SÉRIE N° {}", ed.number),
        None => format!("ÉDITION N° {}", ed.number),
    }
}

fn issue_label(ed: &Edition) -> String {
    let label = format!("Paru le {}", date_label(ed.t));
    match &ed.special {
        Some(s) => format!("« {s} »   ·   {label}"),
        None => label,
    }
}

fn masthead(cv: &mut Canvas, ed: &Edition, guild: Option<&str>) {
    let w = PAGE_W as f32;
    let left = guild.map_or("Le journal de la guilde".to_string(), |g| {
        format!("Le journal de <{}>", g.split('-').next().unwrap_or(g))
    });
    cv.text(Face::Italic, SMALL, INK_DIM, X0, 26.0, &left);
    let n = number_label(ed);
    let nw = width(Face::Semi, SMALL, &n);
    cv.text(Face::Semi, SMALL, INK_DIM, w - X0 - nw, 26.0, &n);
    let size = 96.0;
    let mw = width(Face::Mast, size, MASTHEAD);
    cv.text(Face::Mast, size, INK, (w - mw) / 2.0, 42.0, MASTHEAD);
    cv.rule(X0 - 8.0, 158.0, w - 2.0 * X0 + 16.0, 4.0, 1.0);
    cv.rule(X0 - 8.0, 166.0, w - 2.0 * X0 + 16.0, 1.5, 1.0);
    let count = ed.articles.len();
    let info = format!(
        "{}   ·   {count} article{}   ·   Prix : un sou de cuivre",
        issue_label(ed),
        if count > 1 { "s" } else { "" }
    );
    let iw = width(Face::Body, TEXT, &info);
    cv.text(Face::Body, TEXT, INK, (w - iw) / 2.0, 172.0, &info);
    cv.rule(X0 - 8.0, 202.0, w - 2.0 * X0 + 16.0, 1.5, 1.0);
}

fn running_head(cv: &mut Canvas, ed: &Edition, title: &str) {
    let w = PAGE_W as f32;
    cv.text(Face::Mast, 44.0, INK, X0, 22.0, MASTHEAD);
    let info = format!("{}  ·  {}", number_label(ed), issue_label(ed));
    let iw = width(Face::Italic, SMALL, &info);
    cv.text(Face::Italic, SMALL, INK_DIM, w - X0 - iw, 44.0, &info);
    cv.text(Face::Semi, TEXT, RED, X0, 88.0, &upper(title));
    cv.rule(X0 - 8.0, 120.0, w - 2.0 * X0 + 16.0, 4.0, 1.0);
    cv.rule(X0 - 8.0, 128.0, w - 2.0 * X0 + 16.0, 1.5, 1.0);
}

/// Room below the body: the footer.
const FOOT_H: f32 = PAGE_H as f32 - BODY_BOTTOM;

fn footer(cv: &mut Canvas, bottom: f32, page: usize, pages: usize) {
    let w = PAGE_W as f32;
    cv.rule(X0 - 8.0, bottom + 8.0, w - 2.0 * X0 + 16.0, 1.5, 1.0);
    cv.text(
        Face::Italic,
        SMALL,
        INK_DIM,
        X0,
        bottom + 20.0,
        "Faits vérifiés, ton inventé. Sources, archives et courrier : dans l'addon Renatus, onglet Gazette.",
    );
    let r = format!("Page {page} sur {pages}");
    let rw = width(Face::Italic, SMALL, &r);
    cv.text(Face::Italic, SMALL, INK_DIM, w - X0 - rw, bottom + 20.0, &r);
}

// ---------------------------------------------------------------------------
// Whole issue
// ---------------------------------------------------------------------------

fn page_top(i: usize) -> f32 {
    if i == 0 {
        BODY_TOP
    } else {
        BODY_TOP_INNER + 8.0
    }
}

/// Where each layout page's body ends: PAGE_H's at least, more when its stories need it
/// to be printed whole (up to MAX_BOTTOM). Leaves no jump behind.
fn page_bottoms(ctx: &mut Ctx, pages: &[Page]) -> Vec<f32> {
    let out = pages
        .iter()
        .enumerate()
        .map(|(i, pg)| {
            ctx.page = i + 1;
            let need = draw_body(&mut Canvas::paper(8, 8), ctx, pg, page_top(i), MAX_BOTTOM);
            (need + 4.0).clamp(BODY_BOTTOM - 2.0, MAX_BOTTOM)
        })
        .collect();
    ctx.jumps.clear();
    out
}

/// The pages of an issue as JPEG images: its layout pages, then the "Suites" pages. Each
/// page is as tall as its content: shorter than PAGE_H when it has little, taller when
/// its stories need it.
pub fn render(ch: &Chronicle, ed: &Edition) -> Result<Vec<Vec<u8>>, String> {
    let (pages, placed) = layout_pages(ed);
    let guild = ch.main_guild();
    let mut story_page = BTreeMap::new();
    for (i, pg) in pages.iter().enumerate() {
        for b in pg
            .rows
            .iter()
            .flat_map(|r| &r.cells)
            .flat_map(|c| &c.blocks)
        {
            if str_of(b, "t") == Some("story") {
                if let Some(a) = str_of(b, "a").and_then(|a| resolve(ed, a)) {
                    story_page.entry(a).or_insert(i + 1);
                }
            }
        }
    }
    let mut ctx = Ctx {
        ed,
        ch,
        guild: guild.clone(),
        placed,
        jumps: Vec::new(),
        jump_page: BTreeMap::new(),
        story_page,
        page: 1,
    };
    let limits = page_bottoms(&mut ctx, &pages);
    // First pass: what jumps, from which page, and how tall each page is.
    let mut bottoms = Vec::new();
    for (i, pg) in pages.iter().enumerate() {
        ctx.page = i + 1;
        let mut scratch = Canvas::paper(8, 8);
        bottoms.push(draw_body(
            &mut scratch,
            &mut ctx,
            pg,
            page_top(i),
            limits[i],
        ));
    }
    let jumps = ctx.jumps.clone();
    let from: BTreeMap<usize, usize> = jumps.iter().map(|j| (j.article, j.page)).collect();
    let (jpages, starts) = jump_pages(&ctx, &jumps, pages.len() + 1);
    let total = pages.len() + jpages.len();
    // Second pass: draw, with the page numbers of the jumps.
    ctx.jumps.clear();
    ctx.jump_page = starts;
    let mut out = Vec::new();
    for (i, pg) in pages.iter().enumerate() {
        ctx.page = i + 1;
        let mut cv = Canvas::paper(PAGE_W, (bottoms[i] + FOOT_H).ceil() as u32);
        if i == 0 {
            masthead(&mut cv, ed, guild.as_deref());
        } else {
            let title = if pg.title.is_empty() {
                format!("Page {}", i + 1)
            } else {
                pg.title.clone()
            };
            running_head(&mut cv, ed, &title);
        }
        let bottom = draw_body(&mut cv, &mut ctx, pg, page_top(i), limits[i]);
        footer(&mut cv, bottom, i + 1, total);
        out.push(cv.jpeg()?);
    }
    for (k, jp) in jpages.iter().enumerate() {
        let bottom = BODY_TOP_INNER + 8.0 + jp.used;
        let mut cv = Canvas::paper(PAGE_W, (bottom + FOOT_H).ceil() as u32);
        running_head(&mut cv, ed, "Suites");
        draw_jump_page(&mut cv, &ctx, &jp.items, &from, bottom);
        footer(&mut cv, bottom, pages.len() + k + 1, total);
        out.push(cv.jpeg()?);
    }
    Ok(out)
}

/// The issue a user names: "12" (regular n° 12), "hs2" (special n° 2), a key, or nothing
/// (the latest regular issue).
pub fn find<'e>(list: &'e [Edition], which: Option<&str>) -> Option<&'e Edition> {
    match which {
        None => list.iter().find(|e| e.special.is_none()),
        Some(w) => {
            let w = w.trim().to_lowercase();
            if let Some(n) = w
                .strip_prefix("hs")
                .and_then(|n| n.trim().parse::<usize>().ok())
            {
                return list.iter().find(|e| e.special.is_some() && e.number == n);
            }
            if let Ok(n) = w.trim_start_matches("n°").trim().parse::<usize>() {
                return list.iter().find(|e| e.special.is_none() && e.number == n);
            }
            list.iter().find(|e| e.key.to_lowercase() == w)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Map};

    fn chronicle(events: Vec<Value>) -> Chronicle {
        let mut m = Map::new();
        for e in events {
            m.insert(str_of(&e, "id").unwrap().to_string(), e);
        }
        Chronicle {
            events: m,
            ..Chronicle::default()
        }
    }

    fn article(id: &str, t: f64, edition: &str, order: i64, words: usize) -> Value {
        let body = (0..words)
            .map(|i| format!("mot{i} pour remplir"))
            .collect::<Vec<_>>()
            .join(" ");
        json!({"id": id, "k": "ARTICLE", "t": t, "n": "Alice", "vis": "G",
               "p": {"title": format!("Titre {id}"), "body": format!("{body}\n## Intertitre\nFin."),
                     "edition": edition, "key": id, "order": order, "ia": true, "format": "Enquête"}})
    }

    #[test]
    fn issues_are_numbered_like_the_addon() {
        let ch = chronicle(vec![
            article("a1", 1000.0, "2026-11-01-1000", 1, 5),
            article("a2", 2_000_000.0, "2026-11-20-1000", 1, 5),
            article("h1", 1_500_000.0, "hs:noel", 1, 5),
            json!({"id": "e1", "k": "EDITION", "t": 2_000_100.0, "p": {"edition": "2026-11-20-1000", "till": 1_999_000.0, "cells": []}}),
        ]);
        let list = editions(&ch);
        assert_eq!(list.len(), 3);
        let latest = find(&list, None).unwrap();
        assert_eq!(latest.number, 2);
        assert_eq!(latest.till, 1_999_000.0);
        assert_eq!(latest.since, 1000.0);
        let hs = find(&list, Some("hs1")).unwrap();
        assert_eq!(hs.special.as_deref(), Some("Hors-série"));
        assert_eq!(find(&list, Some("1")).unwrap().key, "2026-11-01-1000");
    }

    #[test]
    fn every_article_is_printed_whole() {
        let mut evs: Vec<Value> = (1..=5)
            .map(|i| article(&format!("k{i}"), 1000.0 + i as f64, "E", i, 160))
            .collect();
        evs.push(json!({"id": "ed", "k": "EDITION", "t": 2000.0, "p": crate::edition::item("grande_une", &evs, "E")["p"].clone()}));
        let ch = chronicle(evs);
        let list = editions(&ch);
        let ed = &list[0];
        let pages = render(&ch, ed).unwrap();
        // Front page and "suite de l'édition", each grown to hold its stories: no "Suites".
        assert_eq!(pages.len(), 2);
        assert!(pages.iter().all(|p| p.starts_with(&[0xFF, 0xD8])));
        // Pages kept at PAGE_H: every article cut or teased has a jump, and the jumps fit
        // in the "Suites" pages.
        let (lp, placed) = layout_pages(ed);
        let mut ctx = Ctx {
            ed,
            ch: &ch,
            guild: None,
            placed,
            jumps: Vec::new(),
            jump_page: BTreeMap::new(),
            story_page: BTreeMap::new(),
            page: 1,
        };
        for pg in &lp {
            draw_body(
                &mut Canvas::paper(8, 8),
                &mut ctx,
                pg,
                BODY_TOP,
                BODY_BOTTOM,
            );
        }
        assert!(!ctx.jumps.is_empty());
        let (jp, starts) = jump_pages(&ctx, &ctx.jumps.clone(), lp.len() + 1);
        assert_eq!(starts.len(), ctx.jumps.len());
        // All the text of each jump is laid out.
        let lines: usize = jp
            .iter()
            .flat_map(|p| &p.items)
            .filter(|(_, i)| matches!(i, Item::Text(_)))
            .count();
        assert!(lines > 10);
    }

    #[test]
    fn stories_are_not_cut_when_the_page_can_grow() {
        let mut evs: Vec<Value> = (1..=5)
            .map(|i| article(&format!("k{i}"), 1000.0 + i as f64, "E", i, 160))
            .collect();
        evs.push(json!({"id": "ed", "k": "EDITION", "t": 2000.0, "p": crate::edition::item("grande_une", &evs, "E")["p"].clone()}));
        let ch = chronicle(evs);
        let list = editions(&ch);
        let ed = &list[0];
        let (lp, placed) = layout_pages(ed);
        let mut ctx = Ctx {
            ed,
            ch: &ch,
            guild: None,
            placed,
            jumps: Vec::new(),
            jump_page: BTreeMap::new(),
            story_page: BTreeMap::new(),
            page: 1,
        };
        let limits = page_bottoms(&mut ctx, &lp);
        assert!(ctx.jumps.is_empty());
        assert!(limits.iter().any(|&b| b > BODY_BOTTOM), "{limits:?}");
        for (i, pg) in lp.iter().enumerate() {
            ctx.page = i + 1;
            draw_body(
                &mut Canvas::paper(8, 8),
                &mut ctx,
                pg,
                page_top(i),
                limits[i],
            );
        }
        assert!(
            ctx.jumps.iter().all(|j| j.from.is_none()),
            "aucune suite : {:?}",
            ctx.jumps
        );
    }
}
