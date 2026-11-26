//! Typesetting for the gazette's printed pages (src/print.rs): embedded fonts, measuring,
//! French hyphenation, justified paragraphs, and a canvas that draws text and rules on
//! a pixmap.

use std::collections::HashMap;
use std::sync::OnceLock;

use ab_glyph::{point, Font, FontRef, PxScale, ScaleFont};
use tiny_skia::{
    Color, FillRule, Paint, PathBuilder, Pixmap, PixmapPaint, Rect, Stroke, Transform,
};

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Face {
    /// Masthead (blackletter).
    Mast,
    /// Headlines, quotes, drop caps.
    Title,
    TitleItalic,
    Body,
    Italic,
    Semi,
    Bold,
}

struct Fonts {
    faces: Vec<(Face, FontRef<'static>)>,
}

fn fonts() -> &'static Fonts {
    static FONTS: OnceLock<Fonts> = OnceLock::new();
    FONTS.get_or_init(|| {
        let load = |bytes: &'static [u8]| FontRef::try_from_slice(bytes).expect("embedded font");
        Fonts {
            faces: vec![
                (
                    Face::Mast,
                    load(include_bytes!(
                        "../assets/fonts/UnifrakturMaguntia-Book.ttf"
                    )),
                ),
                (
                    Face::Title,
                    load(include_bytes!("../assets/fonts/IMFeENrm28P.ttf")),
                ),
                (
                    Face::TitleItalic,
                    load(include_bytes!("../assets/fonts/IMFeENit28P.ttf")),
                ),
                (
                    Face::Body,
                    load(include_bytes!("../assets/fonts/CrimsonText-Regular.ttf")),
                ),
                (
                    Face::Italic,
                    load(include_bytes!("../assets/fonts/CrimsonText-Italic.ttf")),
                ),
                (
                    Face::Semi,
                    load(include_bytes!("../assets/fonts/CrimsonText-SemiBold.ttf")),
                ),
                (
                    Face::Bold,
                    load(include_bytes!("../assets/fonts/CrimsonText-Bold.ttf")),
                ),
            ],
        }
    })
}

fn font(face: Face) -> &'static FontRef<'static> {
    &fonts().faces.iter().find(|(f, _)| *f == face).unwrap().1
}

/// Scale for a font size in px per em (as in CSS), whatever the font's own metrics.
fn scale(f: &FontRef<'static>, size: f32) -> PxScale {
    let units = f.units_per_em().unwrap_or(1000.0);
    PxScale::from(size * f.height_unscaled() / units)
}

/// The non-breaking spaces of French typography are drawn as plain spaces.
fn glyph_char(c: char) -> char {
    match c {
        '\u{a0}' | '\u{202f}' => ' ',
        '\u{2019}' => '\'',
        c => c,
    }
}

/// Some fonts lack the typographic apostrophe: fall back to the plain one.
fn glyph_of(f: &FontRef<'static>, c: char) -> ab_glyph::GlyphId {
    let g = f.glyph_id(c);
    if g.0 == 0 {
        f.glyph_id(glyph_char(c))
    } else {
        g
    }
}

/// Width of a text on one line.
pub fn width(face: Face, size: f32, text: &str) -> f32 {
    let f = font(face);
    let sf = f.as_scaled(scale(f, size));
    let mut w = 0.0;
    let mut prev = None;
    for c in text.chars() {
        let g = glyph_of(
            f,
            if c == '\u{a0}' || c == '\u{202f}' {
                ' '
            } else {
                c
            },
        );
        if let Some(p) = prev {
            w += sf.kern(p, g);
        }
        w += sf.h_advance(g);
        prev = Some(g);
    }
    w
}

/// Distance from the top of a line to its baseline.
pub fn ascent(face: Face, size: f32) -> f32 {
    let f = font(face);
    f.as_scaled(scale(f, size)).ascent()
}

/// Height of a line of text (without extra spacing).
pub fn line_height(face: Face, size: f32) -> f32 {
    let f = font(face);
    let sf = f.as_scaled(scale(f, size));
    sf.ascent() - sf.descent()
}

/// French capitals (accented letters included).
pub fn upper(text: &str) -> String {
    text.to_uppercase()
}

// ---------------------------------------------------------------------------
// Simple wrapped text (captions, teasers, briefs)
// ---------------------------------------------------------------------------

/// Lines of a text wrapped at `w` (explicit "\n" kept), without hyphenation.
pub fn wrap(face: Face, size: f32, w: f32, text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let space = width(face, size, " ");
    for para in text.split('\n') {
        let mut line = String::new();
        let mut lw = 0.0;
        for word in glue(para) {
            let ww = width(face, size, &word);
            if !line.is_empty() && lw + space + ww > w {
                out.push(std::mem::take(&mut line));
                lw = 0.0;
            }
            if !line.is_empty() {
                line.push(' ');
                lw += space;
            }
            line.push_str(&word);
            lw += ww;
        }
        out.push(line);
    }
    out
}

/// Height of a wrapped text with `spacing` px between lines.
pub fn measure(face: Face, size: f32, w: f32, text: &str, spacing: f32) -> f32 {
    let n = wrap(face, size, w, text).len() as f32;
    if n == 0.0 {
        return 0.0;
    }
    n * line_height(face, size) + (n - 1.0) * spacing
}

/// Words of a paragraph, French punctuation kept with its word (no line starting with
/// "»", ":" or "?", none ending with "«").
pub fn glue(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut open = false;
    for w in text.split_whitespace() {
        let closing = matches!(w, "»" | ":" | ";" | "!" | "?" | "!»" | "?»" | "…" | "—»")
            || w.starts_with('»') && w.chars().count() <= 3;
        if open {
            let last = out.last_mut().unwrap();
            last.push('\u{a0}');
            last.push_str(w);
            open = w == "«" || w == "—";
        } else if closing && !out.is_empty() {
            let last = out.last_mut().unwrap();
            last.push('\u{a0}');
            last.push_str(w);
        } else {
            out.push(w.to_string());
            open = w == "«";
        }
    }
    out
}

// ---------------------------------------------------------------------------
// French hyphenation (Liang's algorithm, hyph-utf8 patterns)
// ---------------------------------------------------------------------------

struct Patterns {
    table: HashMap<String, Vec<u8>>,
    longest: usize,
}

fn patterns() -> &'static Patterns {
    static PATTERNS: OnceLock<Patterns> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        let mut table = HashMap::new();
        let mut longest = 0;
        for pat in include_str!("../assets/hyph-fr.pat.txt").split_whitespace() {
            let mut letters = String::new();
            let mut digits = vec![0u8];
            for c in pat.chars() {
                if let Some(d) = c.to_digit(10) {
                    *digits.last_mut().unwrap() = d as u8;
                } else {
                    letters.push(c);
                    digits.push(0);
                }
            }
            longest = longest.max(letters.chars().count());
            table.insert(letters, digits);
        }
        Patterns { table, longest }
    })
}

const LEFT_MIN: usize = 2;
const RIGHT_MIN: usize = 3;

/// Char positions where a word of letters may be hyphenated (break before that char).
fn breaks(word: &str) -> Vec<usize> {
    let chars: Vec<char> = word.chars().collect();
    let n = chars.len();
    if n < LEFT_MIN + RIGHT_MIN {
        return Vec::new();
    }
    let p = patterns();
    let padded: Vec<char> = std::iter::once('.')
        .chain(word.to_lowercase().chars())
        .chain(std::iter::once('.'))
        .collect();
    if padded.len() != n + 2 {
        return Vec::new();
    }
    let mut points = vec![0u8; padded.len() + 1];
    for i in 0..padded.len() {
        for j in i + 1..=(i + p.longest).min(padded.len()) {
            let sub: String = padded[i..j].iter().collect();
            if let Some(d) = p.table.get(&sub) {
                for (k, v) in d.iter().enumerate() {
                    points[i + k] = points[i + k].max(*v);
                }
            }
        }
    }
    // points[k + 1]: between padded[k] and padded[k + 1], i.e. before char k of the word.
    (LEFT_MIN..=n - RIGHT_MIN)
        .filter(|&k| points[k + 1] % 2 == 1)
        .collect()
}

/// Ways to cut a word at the end of a line: (head with its hyphen, tail), longest head
/// first. Only the letters after an elision ("l'", "qu'") and before trailing punctuation
/// are hyphenated; words with digits or inner hyphens are not.
pub fn splits(word: &str) -> Vec<(String, String)> {
    // Compound words ("Serres-Rocheuses") break after their own hyphens first.
    if let Some(i) = word.rfind('-').filter(|&i| i > 0 && i + 1 < word.len()) {
        let (head, tail) = word.split_at(i + 1);
        let mut out: Vec<(String, String)> = splits(tail)
            .into_iter()
            .map(|(h, t)| (format!("{head}{h}"), t))
            .collect();
        out.push((head.to_string(), tail.to_string()));
        out.extend(
            splits(&word[..i])
                .into_iter()
                .map(|(h, t)| (h, format!("{t}-{tail}"))),
        );
        return out;
    }
    let chars: Vec<char> = word.chars().collect();
    let start = chars
        .iter()
        .rposition(|c| *c == '\'' || *c == '\u{2019}')
        .map_or(0, |i| i + 1);
    let lead: usize = chars[..start].iter().filter(|c| !c.is_alphabetic()).count();
    let mut end = chars.len();
    while end > start && !chars[end - 1].is_alphabetic() {
        end -= 1;
    }
    let mut s = start;
    while s < end && !chars[s].is_alphabetic() {
        s += 1;
    }
    let core: String = chars[s..end].iter().collect();
    if core.is_empty() || !core.chars().all(char::is_alphabetic) || lead > 1 {
        return Vec::new();
    }
    let mut out: Vec<(String, String)> = breaks(&core)
        .into_iter()
        .map(|k| {
            let at = s + k;
            let head: String = chars[..at].iter().collect();
            let tail: String = chars[at..].iter().collect();
            (format!("{head}-"), tail)
        })
        .collect();
    out.reverse();
    out
}

// ---------------------------------------------------------------------------
// Article bodies: paragraphs, justified lines, positions to resume from
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum ParaKind {
    Text,
    /// "## " line: a subheading.
    Head,
}

#[derive(Debug, Clone)]
pub struct Para {
    pub kind: ParaKind,
    pub words: Vec<String>,
}

/// An article body, parsed: one paragraph per non-empty line.
#[derive(Debug, Clone)]
pub struct Body {
    pub paras: Vec<Para>,
}

impl Body {
    pub fn parse(text: &str) -> Body {
        let mut paras = Vec::new();
        for line in text.lines() {
            let t = line.trim();
            if t.is_empty() {
                continue;
            }
            if let Some(h) = t.strip_prefix("##") {
                let h = h.trim_start_matches('#').trim();
                if !h.is_empty() {
                    paras.push(Para {
                        kind: ParaKind::Head,
                        words: glue(&upper(h)),
                    });
                }
                continue;
            }
            paras.push(Para {
                kind: ParaKind::Text,
                words: glue(t),
            });
        }
        Body { paras }
    }

    /// First letter (for a drop cap), if the body starts with a letter.
    pub fn first_letter(&self) -> Option<char> {
        let p = self.paras.first()?;
        if p.kind != ParaKind::Text {
            return None;
        }
        let c = p.words.first()?.chars().next()?;
        c.is_alphabetic().then_some(c)
    }
}

/// A place in a body: paragraph, word, and char offset in that word (after a hyphen cut).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Pos {
    pub para: usize,
    pub word: usize,
    pub offset: usize,
}

#[derive(Debug, Clone)]
pub enum LineKind {
    /// Words with their x (relative to the line), and whether to justify.
    Text(Vec<(String, f32)>),
    Head(String),
}

#[derive(Debug, Clone)]
pub struct Line {
    pub kind: LineKind,
    /// Where this line starts in the body.
    pub start: Pos,
    /// Vertical room it takes (text line, or subheading with its space above).
    pub h: f32,
    /// Extra x (first-line indent, drop cap).
    pub x: f32,
}

/// Typesetting settings of a body.
#[derive(Debug, Clone, Copy)]
pub struct Style {
    pub size: f32,
    pub leading: f32,
    pub indent: f32,
}

impl Style {
    pub fn line(&self) -> f32 {
        line_height(Face::Body, self.size) + self.leading
    }
}

fn word_from(body: &Body, pos: Pos) -> String {
    let w = &body.paras[pos.para].words[pos.word];
    w.chars().skip(pos.offset).collect()
}

/// Breaks `body` from `from` into lines; `width(i)` is the width of line i (a drop cap
/// narrows the first ones; `indent(i)` its x). Greedy, with French hyphenation; lines
/// are justified except the last one of each paragraph.
pub fn break_lines(
    body: &Body,
    from: Pos,
    st: Style,
    width_of: &dyn Fn(usize) -> f32,
    x_of: &dyn Fn(usize) -> f32,
) -> Vec<Line> {
    let mut out: Vec<Line> = Vec::new();
    let space = width(Face::Body, st.size, " ");
    let mut pos = from;
    while pos.para < body.paras.len() {
        let para = &body.paras[pos.para];
        if para.kind == ParaKind::Head {
            let text = para.words.join(" ");
            let lines = wrap(Face::Semi, st.size * 0.92, width_of(out.len()), &text);
            for (k, l) in lines.into_iter().enumerate() {
                let space_above = k == 0 && !out.is_empty();
                out.push(Line {
                    kind: LineKind::Head(l),
                    start: pos,
                    h: st.line() * if space_above { 1.5 } else { 1.0 },
                    x: x_of(out.len()),
                });
            }
            pos = Pos {
                para: pos.para + 1,
                word: 0,
                offset: 0,
            };
            continue;
        }
        // Lines of this paragraph.
        let first_of_para = pos.word == 0 && pos.offset == 0;
        let after_head = pos.para > 0 && body.paras[pos.para - 1].kind == ParaKind::Head;
        let mut first_line = true;
        while pos.word < para.words.len() {
            let i = out.len();
            let indent =
                if first_line && first_of_para && !after_head && pos.para > 0 && x_of(i) == 0.0 {
                    st.indent
                } else {
                    0.0
                };
            let avail = width_of(i) - indent;
            let start = pos;
            let mut words: Vec<(String, f32)> = Vec::new();
            let mut used = 0.0;
            loop {
                if pos.word >= para.words.len() {
                    break;
                }
                let w = word_from(body, pos);
                let ww = width(Face::Body, st.size, &w);
                let gap = if words.is_empty() { 0.0 } else { space };
                if used + gap + ww <= avail {
                    words.push((w, used + gap));
                    used += gap + ww;
                    pos = Pos {
                        para: pos.para,
                        word: pos.word + 1,
                        offset: 0,
                    };
                    continue;
                }
                // Hyphenate the word that does not fit (avoid when the line is nearly full).
                if avail - used > space * 3.0 || words.is_empty() {
                    let cut = splits(&w)
                        .into_iter()
                        .find(|(head, _)| used + gap + width(Face::Body, st.size, head) <= avail);
                    if let Some((head, tail)) = cut {
                        let taken = w.chars().count() - tail.chars().count();
                        words.push((head.clone(), used + gap));
                        used += gap + width(Face::Body, st.size, &head);
                        pos.offset += taken;
                        break;
                    }
                }
                if words.is_empty() {
                    // Longer than the line: put it anyway.
                    words.push((w, 0.0));
                    used = ww;
                    pos = Pos {
                        para: pos.para,
                        word: pos.word + 1,
                        offset: 0,
                    };
                }
                break;
            }
            let last = pos.word >= para.words.len();
            if !last && words.len() > 1 {
                let extra = (avail - used) / (words.len() - 1) as f32;
                if extra < space * 4.0 {
                    for (k, w) in words.iter_mut().enumerate() {
                        w.1 += extra * k as f32;
                    }
                }
            }
            let x = x_of(i) + indent;
            out.push(Line {
                kind: LineKind::Text(words),
                start,
                h: st.line(),
                x,
            });
            first_line = false;
        }
        pos = Pos {
            para: pos.para + 1,
            word: 0,
            offset: 0,
        };
    }
    out
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

pub type Rgb = (u8, u8, u8);

pub const INK: Rgb = (33, 20, 13);
pub const INK_DIM: Rgb = (97, 69, 43);
pub const RED: Rgb = (140, 20, 13);

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Align {
    Left,
    Center,
    Right,
}

pub struct Canvas {
    pub pix: Pixmap,
}

impl Canvas {
    /// A page of aged paper: the parchment colour of the addon under its paper texture.
    pub fn paper(w: u32, h: u32) -> Canvas {
        let mut pix = Pixmap::new(w, h).expect("page size");
        pix.fill(Color::from_rgba8(219, 199, 153, 255));
        if let Ok(tex) = Pixmap::decode_png(include_bytes!("../assets/paper.png")) {
            let sx = w as f32 / tex.width() as f32;
            let sy = h as f32 / tex.height() as f32;
            pix.draw_pixmap(
                0,
                0,
                tex.as_ref(),
                &PixmapPaint {
                    quality: tiny_skia::FilterQuality::Bicubic,
                    ..PixmapPaint::default()
                },
                Transform::from_scale(sx, sy),
                None,
            );
        }
        Canvas { pix }
    }

    pub fn png(&self) -> Result<Vec<u8>, String> {
        self.pix.encode_png().map_err(|e| e.to_string())
    }

    /// JPEG: the paper's grain makes PNG pages weigh megabytes, too much for Discord.
    pub fn jpeg(&self) -> Result<Vec<u8>, String> {
        let (w, h) = (self.pix.width(), self.pix.height());
        let (w16, h16) = (u16::try_from(w).map_err(|e| e.to_string())?, u16::try_from(h).map_err(|e| e.to_string())?);
        // Opaque page: premultiplied RGBA is plain RGBA.
        let rgb: Vec<u8> = self.pix.data().chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
        let mut out = Vec::new();
        jpeg_encoder::Encoder::new(&mut out, 88)
            .encode(&rgb, w16, h16, jpeg_encoder::ColorType::Rgb)
            .map_err(|e| e.to_string())?;
        Ok(out)
    }

    fn paint(color: Rgb, alpha: f32) -> Paint<'static> {
        let mut p = Paint::default();
        p.set_color(Color::from_rgba8(
            color.0,
            color.1,
            color.2,
            (alpha.clamp(0.0, 1.0) * 255.0) as u8,
        ));
        p.anti_alias = true;
        p
    }

    pub fn rect(&mut self, x: f32, y: f32, w: f32, h: f32, color: Rgb, alpha: f32) {
        if let Some(r) = Rect::from_xywh(x, y, w.max(0.5), h.max(0.5)) {
            self.pix
                .fill_rect(r, &Self::paint(color, alpha), Transform::identity(), None);
        }
    }

    /// A rule (horizontal or vertical line) in ink.
    pub fn rule(&mut self, x: f32, y: f32, w: f32, h: f32, alpha: f32) {
        self.rect(x, y, w, h, INK, alpha);
    }

    pub fn circle(
        &mut self,
        cx: f32,
        cy: f32,
        r: f32,
        fill: Option<(Rgb, f32)>,
        stroke: Option<(Rgb, f32, f32)>,
    ) {
        let Some(path) = PathBuilder::from_circle(cx, cy, r) else {
            return;
        };
        if let Some((c, a)) = fill {
            self.pix.fill_path(
                &path,
                &Self::paint(c, a),
                FillRule::Winding,
                Transform::identity(),
                None,
            );
        }
        if let Some((c, a, w)) = stroke {
            let s = Stroke {
                width: w,
                ..Stroke::default()
            };
            self.pix
                .stroke_path(&path, &Self::paint(c, a), &s, Transform::identity(), None);
        }
    }

    /// One line of text; (x, y) = top left of the line. Returns its width.
    pub fn text(&mut self, face: Face, size: f32, color: Rgb, x: f32, y: f32, text: &str) -> f32 {
        let f = font(face);
        let sc = scale(f, size);
        let sf = f.as_scaled(sc);
        let base = y + sf.ascent();
        let mut caret = x;
        let mut prev = None;
        let (w, h) = (self.pix.width() as i32, self.pix.height() as i32);
        let data = self.pix.data_mut();
        for c in text.chars() {
            let g = glyph_of(
                f,
                if c == '\u{a0}' || c == '\u{202f}' {
                    ' '
                } else {
                    c
                },
            );
            if let Some(p) = prev {
                caret += sf.kern(p, g);
            }
            let glyph = g.with_scale_and_position(sc, point(caret, base));
            if let Some(og) = f.outline_glyph(glyph) {
                let b = og.px_bounds();
                og.draw(|gx, gy, cov| {
                    let px = b.min.x as i32 + gx as i32;
                    let py = b.min.y as i32 + gy as i32;
                    if px < 0 || py < 0 || px >= w || py >= h || cov <= 0.0 {
                        return;
                    }
                    let a = cov.min(1.0);
                    let i = ((py * w + px) * 4) as usize;
                    for (k, s) in [color.0, color.1, color.2].into_iter().enumerate() {
                        let d = data[i + k] as f32;
                        data[i + k] = (s as f32 * a + d * (1.0 - a)).round() as u8;
                    }
                    let d = data[i + 3] as f32;
                    data[i + 3] = (255.0 * a + d * (1.0 - a)).round() as u8;
                });
            }
            caret += sf.h_advance(g);
            prev = Some(g);
        }
        caret - x
    }

    /// Text wrapped at `w`, aligned; returns its height.
    #[allow(clippy::too_many_arguments)]
    pub fn para(
        &mut self,
        face: Face,
        size: f32,
        color: Rgb,
        x: f32,
        y: f32,
        w: f32,
        text: &str,
        spacing: f32,
        align: Align,
        max_lines: Option<usize>,
    ) -> f32 {
        let mut lines = wrap(face, size, w, text);
        if let Some(m) = max_lines {
            if lines.len() > m {
                lines.truncate(m);
                if let Some(last) = lines.last_mut() {
                    while !last.is_empty() && width(face, size, &format!("{last} …")) > w {
                        match last.rfind(' ') {
                            Some(i) => last.truncate(i),
                            None => last.clear(),
                        }
                    }
                    last.push_str(" …");
                }
            }
        }
        let lh = line_height(face, size);
        let mut yy = y;
        for (i, l) in lines.iter().enumerate() {
            let lw = width(face, size, l);
            let lx = match align {
                Align::Left => x,
                Align::Center => x + (w - lw) / 2.0,
                Align::Right => x + w - lw,
            };
            self.text(face, size, color, lx, yy, l);
            yy += lh;
            if i + 1 < lines.len() {
                yy += spacing;
            }
        }
        yy - y
    }

    /// Body lines (from break_lines) at (x, y).
    pub fn lines(&mut self, st: Style, x: f32, y: f32, lines: &[Line]) {
        let mut yy = y;
        for l in lines {
            match &l.kind {
                LineKind::Text(words) => {
                    for (w, wx) in words {
                        self.text(Face::Body, st.size, INK, x + l.x + wx, yy, w);
                    }
                }
                LineKind::Head(t) => {
                    let off = l.h - st.line();
                    self.text(Face::Semi, st.size * 0.92, RED, x + l.x, yy + off, t);
                }
            }
            yy += l.h;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hyphenates_french_words() {
        let s = splits("informatique,");
        assert!(!s.is_empty());
        for (head, tail) in &s {
            assert!(head.ends_with('-'));
            assert_eq!(
                format!("{}{}", head.trim_end_matches('-'), tail),
                "informatique,"
            );
            assert!(tail.chars().filter(|c| c.is_alphabetic()).count() >= RIGHT_MIN);
        }
        assert!(splits("l'organisation")
            .iter()
            .all(|(h, _)| h.starts_with("l'")));
        assert!(splits("12345").is_empty());
        assert!(splits("le").is_empty());
        let compound = splits("Serres-Rocheuses,");
        assert!(compound
            .iter()
            .any(|(h, t)| h == "Serres-" && t == "Rocheuses,"));
        // Every cut gives back the word: the added hyphen aside, head + tail = word.
        for (h, t) in &compound {
            let own = format!("{h}{t}") == "Serres-Rocheuses,";
            let added = format!("{}{t}", h.strip_suffix('-').unwrap()) == "Serres-Rocheuses,";
            assert!(own || added, "{h} | {t}");
        }
    }

    #[test]
    fn french_punctuation_stays_with_its_word() {
        assert_eq!(
            glue("Il dit « bonjour » : oui !"),
            vec!["Il", "dit", "«\u{a0}bonjour\u{a0}»\u{a0}:", "oui\u{a0}!"]
        );
    }

    #[test]
    fn lines_resume_where_they_stopped() {
        let body = Body::parse("Un premier paragraphe assez long pour tenir sur plusieurs lignes de texte justifié.\n## Intertitre\nEt la suite.");
        let st = Style {
            size: 24.0,
            leading: 4.0,
            indent: 20.0,
        };
        let all = break_lines(&body, Pos::default(), st, &|_| 220.0, &|_| 0.0);
        assert!(all.len() >= 4);
        assert!(all.iter().any(|l| matches!(l.kind, LineKind::Head(_))));
        // Resuming from the third line gives the same lines as the end of the full run.
        let from = all[2].start;
        let rest = break_lines(&body, from, st, &|_| 220.0, &|_| 0.0);
        assert_eq!(rest.len(), all.len() - 2);
        let mut c = Canvas::paper(300, 400);
        c.lines(st, 10.0, 10.0, &all);
        assert!(c.png().unwrap().len() > 100);
    }
}
