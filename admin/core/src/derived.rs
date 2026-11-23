//! Facts computed over the whole journal rather than read off one event: the guild's
//! records, members' milestones, anniversaries, the period's honours list and its
//! inseparable duo. They give the gazette new angles from the same events.
//!
//! Everything is counted from what the Renatus journal holds (since each member installed
//! the addon), never from the characters' whole lives: the texts say so. Only consenting
//! members are named; a former record held by someone else is "un autre membre".

use std::collections::{BTreeMap, BTreeSet, HashMap};

use chrono::{Months, NaiveDate};
use serde_json::Value;

use crate::chronicle::{num_of, payload, str_of};
use crate::gazette::local;

/// (time, text, event ids)
pub type Raw = (f64, String, Vec<String>);

/// A record only counts once this many earlier results exist.
const MIN_PRIOR: usize = 3;
const MAX_REFS: usize = 20;
const JOURNAL: &str = "compté depuis le début du journal Renatus";

pub struct Input<'a> {
    /// The guild's shared events, all time, sorted by time (any author).
    pub events: &'a [&'a Value],
    /// GUIDs of consenting members.
    pub consenting: &'a BTreeSet<String>,
    pub since: f64,
    pub until: f64,
    /// Start of the new issue: the honours list and the duo cover [split, until).
    pub split: f64,
}

impl Input<'_> {
    fn in_period(&self, t: f64) -> bool {
        (self.since..self.until).contains(&t)
    }
    fn ok(&self, guid: &str) -> bool {
        self.consenting.contains(guid)
    }
}

pub fn facts(inp: &Input) -> Vec<Raw> {
    let mut out = records(inp);
    out.extend(milestones(inp));
    out.extend(anniversaries(inp));
    out.extend(honours(inp));
    out.extend(duo(inp));
    out
}

fn id(e: &Value) -> String {
    str_of(e, "id").unwrap_or("").to_string()
}
fn author(e: &Value) -> &str {
    str_of(e, "a").unwrap_or("")
}
fn name(e: &Value) -> &str {
    str_of(e, "n").unwrap_or("?")
}
fn kind(e: &Value) -> &str {
    str_of(e, "k").unwrap_or("")
}
fn day(t: f64) -> NaiveDate {
    local(t).date_naive()
}
fn date_fr(t: f64) -> String {
    local(t).format("%d/%m/%Y").to_string()
}
fn tail(mut ids: Vec<String>) -> Vec<String> {
    if ids.len() > MAX_REFS {
        ids.drain(..ids.len() - MAX_REFS);
    }
    ids
}

/// Expeditions once each: several members record the same one (same `occ`).
fn expeditions<'a>(events: &[&'a Value]) -> Vec<&'a Value> {
    let mut seen = BTreeSet::new();
    events
        .iter()
        .filter(|e| kind(e) == "EXPEDITION")
        .filter(|e| {
            seen.insert(
                str_of(e, "occ")
                    .map(str::to_string)
                    .unwrap_or_else(|| id(e)),
            )
        })
        .copied()
        .collect()
}

/// Members of an expedition: its author and its participants (guid -> name).
fn crew(e: &Value) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    out.insert(author(e).to_string(), name(e).to_string());
    for p in e.get("pt").and_then(Value::as_array).into_iter().flatten() {
        if let (Some(g), Some(n)) = (str_of(p, "g"), str_of(p, "n")) {
            out.insert(g.to_string(), n.to_string());
        }
    }
    out
}

fn place(e: &Value) -> String {
    let p = payload(e);
    str_of(p, "inst")
        .or_else(|| {
            e.get("loc")
                .and_then(|l| str_of(l, "i").or_else(|| str_of(l, "z")))
        })
        .unwrap_or("")
        .to_string()
}

fn minutes(m: f64) -> String {
    let m = m.round() as i64;
    if m >= 60 {
        format!("{} h {:02}", m / 60, m % 60)
    } else {
        format!("{m} min")
    }
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

struct Entry {
    t: f64,
    value: f64,
    guid: String,
    /// "Alice", "le groupe d'Alice à Mortemines"
    holder: String,
    refs: Vec<String>,
}

struct Metric {
    label: &'static str,
    /// A record nobody wants (most deaths...).
    shameful: bool,
    lower_wins: bool,
    /// Below this, beating the record is not news.
    min: f64,
    show: fn(f64) -> String,
    entries: Vec<Entry>,
}

fn count_of(unit: &'static str) -> fn(f64) -> String {
    match unit {
        "morts" => |v| format!("{v} mort(s)"),
        "quêtes" => |v| format!("{v} quête(s)"),
        "victoires" => |v| format!("{v} victoire(s) honorable(s)"),
        "niveaux" => |v| format!("{v} niveau(x)"),
        "espèces" => |v| format!("{v} espèce(s)"),
        "contrées" => |v| format!("{v} contrée(s)"),
        "sauts" => |v| format!("{v} sauts"),
        "cuites" => |v| format!("{v} cuite(s)"),
        "boss" => |v| format!("{v} boss"),
        _ => |v| format!("{v}"),
    }
}

/// Per member and per day: how many events of `kind` (or the sum of a COUNTERS field).
fn daily(inp: &Input, kind_: &str, field: Option<&str>) -> Vec<Entry> {
    let mut buckets: BTreeMap<(String, NaiveDate), Entry> = BTreeMap::new();
    for e in inp.events.iter().filter(|e| kind(e) == kind_) {
        let value = match field {
            Some(f) => num_of(payload(e), f),
            None => 1.0,
        };
        if value <= 0.0 {
            continue;
        }
        let t = num_of(e, "t");
        let b = buckets
            .entry((author(e).to_string(), day(t)))
            .or_insert_with(|| Entry {
                t,
                value: 0.0,
                guid: author(e).to_string(),
                holder: name(e).to_string(),
                refs: Vec::new(),
            });
        b.value += value;
        b.t = b.t.max(t);
        b.refs.push(id(e));
    }
    buckets
        .into_values()
        .map(|mut b| {
            b.refs = tail(b.refs);
            b
        })
        .collect()
}

fn per_expedition(inp: &Input, value: fn(&Value) -> f64) -> Vec<Entry> {
    expeditions(inp.events)
        .into_iter()
        .map(|e| {
            let at = place(e);
            let holder = if at.is_empty() {
                format!("le groupe de {}", name(e))
            } else {
                format!("le groupe de {} ({at})", name(e))
            };
            Entry {
                t: num_of(e, "t"),
                value: value(e),
                guid: author(e).to_string(),
                holder,
                refs: vec![id(e)],
            }
        })
        .collect()
}

fn metrics(inp: &Input) -> Vec<Metric> {
    let m = |label, shameful, min, unit, entries| Metric {
        label,
        shameful,
        lower_wins: false,
        min,
        show: count_of(unit),
        entries,
    };
    let mut list = vec![
        m(
            "le plus de morts en une journée",
            true,
            3.0,
            "morts",
            daily(inp, "DEATH", None),
        ),
        m(
            "le plus de quêtes terminées en une journée",
            false,
            10.0,
            "quêtes",
            daily(inp, "QUEST_DONE", None),
        ),
        m(
            "le plus de victoires honorables en une journée",
            false,
            3.0,
            "victoires",
            daily(inp, "PVP_KILL", None),
        ),
        m(
            "le plus de niveaux gagnés en une journée",
            false,
            2.0,
            "niveaux",
            daily(inp, "LEVEL_UP", None),
        ),
        m(
            "le plus de nouvelles espèces de créatures abattues en une journée",
            false,
            10.0,
            "espèces",
            daily(inp, "MOB_KILL", None),
        ),
        m(
            "le plus de contrées découvertes en une journée",
            false,
            3.0,
            "contrées",
            daily(inp, "ZONE_FIRST_VISIT", None),
        ),
        m(
            "le plus de sauts en une journée",
            false,
            200.0,
            "sauts",
            daily(inp, "COUNTERS", Some("jumps")),
        ),
        m(
            "le plus de cuites en une journée",
            true,
            2.0,
            "cuites",
            daily(inp, "COUNTERS", Some("drunk")),
        ),
        m(
            "le plus de morts en une seule expédition",
            true,
            3.0,
            "morts",
            per_expedition(inp, |e| num_of(payload(e), "deaths")),
        ),
        m(
            "le plus de boss vaincus en une seule expédition",
            false,
            2.0,
            "boss",
            per_expedition(inp, |e| num_of(payload(e), "bosses")),
        ),
    ];
    list.push(Metric {
        label: "la plus longue expédition",
        shameful: false,
        lower_wins: false,
        min: 60.0,
        show: minutes,
        entries: per_expedition(inp, |e| num_of(payload(e), "duration") / 60.0),
    });
    list.push(Metric {
        label: "la survie la plus juste (le moins de vie restante après un combat)",
        shameful: false,
        lower_wins: true,
        min: f64::INFINITY,
        show: |v| format!("{v} % de vie"),
        entries: inp
            .events
            .iter()
            .filter(|e| kind(e) == "NEAR_DEATH" && num_of(payload(e), "pct") > 0.0)
            .map(|e| Entry {
                t: num_of(e, "t"),
                value: num_of(payload(e), "pct"),
                guid: author(e).to_string(),
                holder: name(e).to_string(),
                refs: vec![id(e)],
            })
            .collect(),
    });
    list
}

/// Records beaten during the period: one fact per metric, the latest holder against the
/// record that stood before the period (beaten twice in a week: told once).
fn records(inp: &Input) -> Vec<Raw> {
    let mut out = Vec::new();
    for mut m in metrics(inp) {
        m.entries.sort_by(|a, b| a.t.total_cmp(&b.t));
        let mut best: Option<usize> = None;
        // (record before the period, latest record beaten in it)
        let mut beaten: Option<(usize, usize)> = None;
        for (i, e) in m.entries.iter().enumerate() {
            let Some(b) = best else {
                best = Some(i);
                continue;
            };
            let old = &m.entries[b];
            let beats = if m.lower_wins {
                e.value < old.value
            } else {
                e.value > old.value
            };
            if !beats {
                continue;
            }
            let enough = if m.lower_wins {
                e.value <= m.min
            } else {
                e.value >= m.min
            };
            if i >= MIN_PRIOR && enough && inp.in_period(e.t) && inp.ok(&e.guid) {
                beaten = Some((beaten.map_or(b, |(before, _)| before), i));
            }
            best = Some(i);
        }
        let Some((before, i)) = beaten else { continue };
        let (old, e) = (&m.entries[before], &m.entries[i]);
        let old_holder = if inp.ok(&old.guid) {
            old.holder.clone()
        } else {
            "un autre membre".to_string()
        };
        out.push((
            e.t,
            format!(
                "{} de la guilde — {} : {} avec {} le {} ; ancien record : {} par {} le {} ({JOURNAL})",
                if m.shameful { "RECORD PEU ENVIABLE" } else { "RECORD" },
                m.label,
                e.holder,
                (m.show)(e.value),
                date_fr(e.t),
                (m.show)(old.value),
                old_holder,
                date_fr(old.t),
            ),
            e.refs.clone(),
        ));
    }
    out
}

// ---------------------------------------------------------------------------
// Milestones: the Nth event of a kind, for a member and for the whole guild
// ---------------------------------------------------------------------------

const MILESTONES: &[(&str, &str, &[usize])] = &[
    ("DEATH", "mort", &[10, 25, 50, 100, 200, 500]),
    ("QUEST_DONE", "quête terminée", &[100, 250, 500, 1000, 2000]),
    (
        "PVP_KILL",
        "victoire honorable",
        &[10, 25, 50, 100, 250, 500],
    ),
    ("BOSS_KILL", "boss vaincu", &[10, 25, 50, 100]),
    ("ZONE_FIRST_VISIT", "contrée découverte", &[25, 50, 100]),
    (
        "MOB_KILL",
        "espèce de créature abattue",
        &[100, 250, 500, 1000],
    ),
];
const GUILD_MILESTONES: &[(&str, &str, &[usize])] = &[
    ("DEATH", "mort", &[50, 100, 250, 500, 1000, 2500]),
    (
        "QUEST_DONE",
        "quête terminée",
        &[500, 1000, 2500, 5000, 10000],
    ),
    ("PVP_KILL", "victoire honorable", &[50, 100, 250, 500, 1000]),
    ("BOSS_KILL", "boss vaincu", &[50, 100, 250, 500]),
];

fn milestones(inp: &Input) -> Vec<Raw> {
    let mut out = Vec::new();
    for (k, what, marks) in MILESTONES {
        let mut count: HashMap<&str, usize> = HashMap::new();
        for e in inp.events.iter().filter(|e| kind(e) == *k) {
            let n = count.entry(author(e)).or_default();
            *n += 1;
            let t = num_of(e, "t");
            if marks.contains(n) && inp.in_period(t) && inp.ok(author(e)) {
                out.push((
                    t,
                    format!("JALON — {} : {}e {what} ({JOURNAL})", name(e), n),
                    vec![id(e)],
                ));
            }
        }
    }
    for (k, what, marks) in GUILD_MILESTONES {
        let mut n = 0;
        for e in inp.events.iter().filter(|e| kind(e) == *k) {
            n += 1;
            let t = num_of(e, "t");
            if marks.contains(&n) && inp.in_period(t) {
                let who = if inp.ok(author(e)) {
                    name(e).to_string()
                } else {
                    "un membre".to_string()
                };
                out.push((
                    t,
                    format!("JALON DE LA GUILDE — {n}e {what} de toute la guilde, signée {who} ({JOURNAL})"),
                    vec![id(e)],
                ));
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Anniversaries: months in the guild (GUILD_JOIN), years in the journal
// ---------------------------------------------------------------------------

fn anniversaries(inp: &Input) -> Vec<Raw> {
    let mut out = Vec::new();
    let mut joined: BTreeMap<&str, &Value> = BTreeMap::new();
    let mut first: BTreeMap<&str, &Value> = BTreeMap::new();
    for e in inp.events {
        first.entry(author(e)).or_insert(e);
        if kind(e) == "GUILD_JOIN" {
            joined.insert(author(e), e); // the latest join counts
        }
    }
    let mut push = |e: &Value, months: u32, text: String| {
        let start = local(num_of(e, "t"));
        let Some(when) = start.checked_add_months(Months::new(months)) else {
            return;
        };
        let t = when.timestamp() as f64;
        if inp.in_period(t) && inp.ok(author(e)) {
            out.push((t, text, vec![id(e)]));
        }
    };
    for e in joined.values() {
        for months in [1, 3, 6, 12, 24, 36, 48, 60] {
            let span = if months < 12 {
                format!("{months} mois")
            } else {
                format!("{} an(s)", months / 12)
            };
            push(
                e,
                months,
                format!(
                    "ANNIVERSAIRE — {} fête ses {span} dans la guilde (arrivée le {})",
                    name(e),
                    date_fr(num_of(e, "t"))
                ),
            );
        }
    }
    for (a, e) in &first {
        if joined.contains_key(a) {
            continue;
        }
        for years in 1..=5u32 {
            push(
                e,
                years * 12,
                format!(
                    "ANNIVERSAIRE — {} tient le journal Renatus depuis {years} an(s) (premier événement le {})",
                    name(e),
                    date_fr(num_of(e, "t"))
                ),
            );
        }
    }
    out
}

// ---------------------------------------------------------------------------
// The period's honours list and duo
// ---------------------------------------------------------------------------

fn recent<'a>(inp: &Input<'a>) -> Vec<&'a Value> {
    inp.events
        .iter()
        .filter(|e| (inp.split..inp.until).contains(&num_of(e, "t")))
        .copied()
        .collect()
}

fn honours(inp: &Input) -> Vec<Raw> {
    let events = recent(inp);
    let active: BTreeSet<&str> = events
        .iter()
        .map(|e| author(e))
        .filter(|a| inp.ok(a))
        .collect();
    if active.len() < 2 {
        return Vec::new();
    }
    // category -> guid -> (score, name, ids)
    type Board = BTreeMap<String, (f64, String, Vec<String>)>;
    type Category = (&'static str, f64, fn(f64) -> String, Board);
    let mut boards: Vec<Category> = vec![
        ("le plus de morts", 2.0, count_of("morts"), Board::new()),
        ("le plus de quêtes", 5.0, count_of("quêtes"), Board::new()),
        (
            "le plus de niveaux gagnés",
            2.0,
            count_of("niveaux"),
            Board::new(),
        ),
        (
            "le plus de victoires honorables",
            2.0,
            count_of("victoires"),
            Board::new(),
        ),
        (
            "le plus de nouvelles espèces abattues",
            5.0,
            count_of("espèces"),
            Board::new(),
        ),
        (
            "le plus de contrées découvertes",
            2.0,
            count_of("contrées"),
            Board::new(),
        ),
        ("le plus de sauts", 100.0, count_of("sauts"), Board::new()),
        (
            "le plus de temps en expédition",
            30.0,
            minutes,
            Board::new(),
        ),
    ];
    let mut add = |board: usize, guid: &str, who: &str, v: f64, ev: &str| {
        if !inp.ok(guid) || v <= 0.0 {
            return;
        }
        let entry = boards[board]
            .3
            .entry(guid.to_string())
            .or_insert_with(|| (0.0, who.to_string(), Vec::new()));
        entry.0 += v;
        entry.2.push(ev.to_string());
    };
    for e in &events {
        let (a, n, i) = (author(e), name(e), id(e));
        match kind(e) {
            "DEATH" => add(0, a, n, 1.0, &i),
            "QUEST_DONE" => add(1, a, n, 1.0, &i),
            "LEVEL_UP" => add(2, a, n, 1.0, &i),
            "PVP_KILL" => add(3, a, n, 1.0, &i),
            "MOB_KILL" => add(4, a, n, 1.0, &i),
            "ZONE_FIRST_VISIT" => add(5, a, n, 1.0, &i),
            "COUNTERS" => add(6, a, n, num_of(payload(e), "jumps"), &i),
            _ => {}
        }
    }
    for e in expeditions(&events) {
        let m = num_of(payload(e), "duration") / 60.0;
        for (g, n) in crew(e) {
            add(7, &g, &n, m, &id(e));
        }
    }
    let mut lines = Vec::new();
    let mut refs = Vec::new();
    for (label, min, show, board) in &boards {
        let Some(top) = board.values().map(|x| x.0).reduce(f64::max) else {
            continue;
        };
        if top < *min {
            continue;
        }
        let leaders: Vec<&(f64, String, Vec<String>)> =
            board.values().filter(|x| x.0 == top).take(3).collect();
        let names: Vec<&str> = leaders.iter().map(|x| x.1.as_str()).collect();
        lines.push(format!("{label} : {} ({})", names.join(" et "), show(top)));
        for l in leaders {
            refs.extend(l.2.iter().rev().take(4).cloned());
        }
    }
    if lines.is_empty() {
        return Vec::new();
    }
    let last = events
        .iter()
        .map(|e| num_of(e, "t"))
        .fold(inp.split, f64::max);
    vec![(
        last,
        format!(
            "PALMARÈS depuis le {} (entre les {} membres actifs qui acceptent la gazette) — {}",
            date_fr(inp.split),
            active.len(),
            lines.join(" ; ")
        ),
        tail(refs),
    )]
}

fn duo(inp: &Input) -> Vec<Raw> {
    let events = recent(inp);
    // (guid, guid) -> (names, outings, minutes, ids)
    type Together = (String, String, usize, f64, Vec<String>);
    let mut pairs: BTreeMap<(String, String), Together> = BTreeMap::new();
    for e in expeditions(&events) {
        let people: Vec<(String, String)> =
            crew(e).into_iter().filter(|(g, _)| inp.ok(g)).collect();
        for (i, (ga, na)) in people.iter().enumerate() {
            for (gb, nb) in &people[i + 1..] {
                let p = pairs
                    .entry((ga.clone(), gb.clone()))
                    .or_insert_with(|| (na.clone(), nb.clone(), 0, 0.0, Vec::new()));
                p.2 += 1;
                p.3 += num_of(payload(e), "duration") / 60.0;
                p.4.push(id(e));
            }
        }
    }
    let best = pairs
        .into_values()
        .filter(|p| p.2 >= 2)
        .max_by(|a, b| a.2.cmp(&b.2).then(a.3.total_cmp(&b.3)));
    let Some((a, b, n, m, ids)) = best else {
        return Vec::new();
    };
    let last = events
        .iter()
        .map(|e| num_of(e, "t"))
        .fold(inp.split, f64::max);
    vec![(
        last,
        format!(
            "DUO INSÉPARABLE depuis le {} — {a} et {b} : {n} sorties ensemble, {} au total",
            date_fr(inp.split),
            minutes(m)
        ),
        tail(ids),
    )]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const DAY: f64 = 86400.0;

    fn ev(id: &str, a: &str, n: &str, k: &str, t: f64, p: Value) -> Value {
        json!({"id": id, "a": a, "n": n, "k": k, "t": t, "vis": "G", "p": p})
    }

    fn run(events: &[Value], ok: &[&str], since: f64, until: f64, split: f64) -> Vec<Raw> {
        let refs: Vec<&Value> = events.iter().collect();
        let consenting: BTreeSet<String> = ok.iter().map(|s| s.to_string()).collect();
        facts(&Input {
            events: &refs,
            consenting: &consenting,
            since,
            until,
            split,
        })
    }

    #[test]
    fn a_record_needs_history_and_names_only_consenting_members() {
        let mut evs = Vec::new();
        // four earlier days of deaths: 1, 2, 4 (by Bob, no consent), 1
        let mut n = 0;
        for (d, who, count) in [(1.0, "A", 1), (2.0, "A", 2), (3.0, "B", 4), (4.0, "A", 1)] {
            for _ in 0..count {
                n += 1;
                let nm = if who == "A" { "Alice" } else { "Bob" };
                evs.push(ev(
                    &format!("{who}:{n}"),
                    who,
                    nm,
                    "DEATH",
                    d * DAY + n as f64,
                    json!({}),
                ));
            }
        }
        // the new period: Alice dies 5 times in a day
        for i in 0..5 {
            evs.push(ev(
                &format!("A:x{i}"),
                "A",
                "Alice",
                "DEATH",
                10.0 * DAY + i as f64,
                json!({}),
            ));
        }
        let out = run(&evs, &["A"], 9.0 * DAY, 11.0 * DAY, 9.0 * DAY);
        let rec: Vec<&Raw> = out.iter().filter(|f| f.1.starts_with("RECORD")).collect();
        assert_eq!(rec.len(), 1, "{out:#?}");
        let text = &rec[0].1;
        assert!(text.starts_with("RECORD PEU ENVIABLE de la guilde — le plus de morts en une journée : Alice avec 5 mort(s)"), "{text}");
        assert!(
            text.contains("ancien record : 4 mort(s) par un autre membre"),
            "{text}"
        );
        assert!(text.contains("journal Renatus"));
        assert_eq!(rec[0].2.len(), 5);
        // Bob beating it: never named, no fact
        let out = run(&evs, &[], 9.0 * DAY, 11.0 * DAY, 9.0 * DAY);
        assert!(out.iter().all(|f| !f.1.starts_with("RECORD")));
    }

    #[test]
    fn milestones_and_anniversaries() {
        let mut evs = vec![ev("A:0", "A", "Alice", "GUILD_JOIN", 0.0, json!({}))];
        for i in 1..=10 {
            evs.push(ev(
                &format!("A:{i}"),
                "A",
                "Alice",
                "DEATH",
                20.0 * DAY + i as f64,
                json!({}),
            ));
        }
        let out = run(&evs, &["A"], 15.0 * DAY, 40.0 * DAY, 15.0 * DAY);
        let texts: Vec<&str> = out.iter().map(|f| f.1.as_str()).collect();
        assert!(
            texts
                .iter()
                .any(|t| t.starts_with("JALON — Alice : 10e mort (")),
            "{texts:#?}"
        );
        assert!(
            texts
                .iter()
                .any(|t| t.starts_with("ANNIVERSAIRE — Alice fête ses 1 mois dans la guilde")),
            "{texts:#?}"
        );
    }

    #[test]
    fn honours_and_duo_cover_the_new_issue_only() {
        let exp = |id: &str, t: f64| {
            let mut e = ev(
                id,
                "A",
                "Alice",
                "EXPEDITION",
                t,
                json!({"duration": 3600, "inst": "Mortemines"}),
            );
            e["pt"] =
                json!([{"g": "A", "n": "Alice"}, {"g": "C", "n": "Carl"}, {"g": "B", "n": "Bob"}]);
            e["occ"] = json!(id);
            e
        };
        let evs = vec![
            exp("A:1", 10.0 * DAY),
            exp("A:2", 11.0 * DAY),
            ev("C:1", "C", "Carl", "DEATH", 10.0 * DAY, json!({})),
            ev("C:2", "C", "Carl", "DEATH", 10.5 * DAY, json!({})),
            ev("A:3", "A", "Alice", "QUEST_DONE", 3.0 * DAY, json!({})),
        ];
        let out = run(&evs, &["A", "C"], 0.0, 12.0 * DAY, 9.0 * DAY);
        let palmares = out
            .iter()
            .find(|f| f.1.starts_with("PALMARÈS"))
            .expect("palmarès");
        assert!(
            palmares.1.contains("le plus de morts : Carl (2 mort(s))"),
            "{}",
            palmares.1
        );
        assert!(
            palmares
                .1
                .contains("le plus de temps en expédition : Alice et Carl (2 h 00)"),
            "{}",
            palmares.1
        );
        assert!(!palmares.1.contains("quêtes"), "older than the issue");
        let duo = out.iter().find(|f| f.1.starts_with("DUO")).expect("duo");
        assert!(
            duo.1
                .contains("Alice et Carl : 2 sorties ensemble, 2 h 00 au total"),
            "{}",
            duo.1
        );
        assert!(!duo.1.contains("Bob"));
    }
}
