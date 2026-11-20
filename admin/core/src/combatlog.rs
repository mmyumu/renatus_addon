//! Reading combat logs (Logs/WoWCombatLog*.txt) written by the client with /combatlog.
//!
//! The file is only read afterwards, from disk: no link with the game process.
//! Only the bare minimum is extracted:
//!   - player deaths (UNIT_DIED) with the last hit taken (cause);
//!   - killing blows (PARTY_KILL): who finished whom.
//!
//! Timestamps are in local time; recent clients append the UTC offset in hours ("-5", "+1"...).

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::sync::OnceLock;

use chrono::{Datelike, FixedOffset, Local, NaiveDate, TimeZone};
use regex::Regex;

const DAMAGE_EVENTS: &[&str] = &[
    "SWING_DAMAGE",
    "RANGE_DAMAGE",
    "SPELL_DAMAGE",
    "SPELL_PERIODIC_DAMAGE",
    "SPELL_BUILDING_DAMAGE",
    "DAMAGE_SPLIT",
    "ENVIRONMENTAL_DAMAGE",
];
const ENVIRONMENT: &[(&str, &str)] = &[
    ("Falling", "chute"),
    ("Drowning", "noyade"),
    ("Fatigue", "épuisement"),
    ("Fire", "feu"),
    ("Lava", "lave"),
    ("Slime", "vase"),
];
/// The last hit must be less than 10 s before the death.
const CAUSE_WINDOW: f64 = 10.0;
/// PARTY_KILL and UNIT_DIED almost simultaneous.
const KILL_WINDOW: f64 = 1.5;

#[derive(Debug, Clone)]
pub struct LogEvent {
    pub ts: f64,
    pub event: String,
    pub fields: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Death {
    pub ts: f64,
    pub guid: String,
    pub name: String,
    /// Last attacker (name without realm).
    pub source: Option<String>,
    pub source_guid: Option<String>,
    pub spell: Option<String>,
    /// French label (falling, drowning...).
    pub environment: Option<String>,
    /// Killing blow (PARTY_KILL), if known.
    pub killer: Option<String>,
    pub killer_guid: Option<String>,
}

impl Death {
    pub fn cause(&self) -> String {
        if let Some(env) = &self.environment {
            return env.clone();
        }
        match (self.killer.as_ref().or(self.source.as_ref()), &self.spell) {
            (None, _) => "cause indéterminée".into(),
            (Some(who), Some(spell)) => format!("{who} ({spell})"),
            (Some(who), None) => who.clone(),
        }
    }

    pub fn by_player(&self) -> bool {
        self.killer_guid
            .as_ref()
            .or(self.source_guid.as_ref())
            .is_some_and(|g| g.starts_with("Player-"))
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kill {
    pub ts: f64,
    pub killer: String,
    pub killer_guid: String,
    pub victim: String,
    pub victim_guid: String,
}

#[derive(Debug, Clone, Default)]
pub struct Analysis {
    pub deaths: Vec<Death>,
    pub kills: Vec<Kill>,
    pub lines: usize,
    pub skipped: usize,
}

/// Splits on commas, honouring quotes, brackets and parentheses.
pub fn split_fields(rest: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut depth = 0i32;
    let mut quoted = false;
    for ch in rest.chars() {
        if quoted {
            if ch == '"' {
                quoted = false;
            } else {
                cur.push(ch);
            }
            continue;
        }
        match ch {
            '"' => quoted = true,
            '[' | '(' => {
                depth += 1;
                cur.push(ch);
            }
            ']' | ')' => {
                depth -= 1;
                cur.push(ch);
            }
            ',' if depth == 0 => out.push(std::mem::take(&mut cur)),
            _ => cur.push(ch),
        }
    }
    out.push(cur.trim_end_matches(['\r', '\n']).to_string());
    out
}

fn line_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"^(?P<mo>\d{1,2})/(?P<d>\d{1,2})(?:/(?P<y>\d{4}))?\s+(?P<h>\d{1,2}):(?P<mi>\d{2}):(?P<s>\d{2})(?:\.(?P<ms>\d{1,4}))?(?P<tz>[+-]\d{1,2})?\s{2}(?P<rest>.*)$",
        )
        .expect("valid regex")
    })
}

pub fn parse_line(line: &str, default_year: i32) -> Option<LogEvent> {
    let m = line_re().captures(line)?;
    let num = |k: &str| m.name(k).and_then(|x| x.as_str().parse::<u32>().ok());
    let year = m
        .name("y")
        .and_then(|y| y.as_str().parse().ok())
        .unwrap_or(default_year);
    let ms = m.name("ms").map_or("0", |x| x.as_str());
    let micro: u32 = format!("{ms:0<6}")[..6].parse().ok()?;
    let naive = NaiveDate::from_ymd_opt(year, num("mo")?, num("d")?)?.and_hms_micro_opt(
        num("h")?,
        num("mi")?,
        num("s")?,
        micro,
    )?;
    let ts = match m.name("tz") {
        Some(tz) => {
            let hours: i32 = tz.as_str().parse().ok()?;
            FixedOffset::east_opt(hours * 3600)?
                .from_local_datetime(&naive)
                .single()?
                .timestamp_micros()
        }
        // local time of the PC (the one that wrote the file)
        None => Local
            .from_local_datetime(&naive)
            .earliest()?
            .timestamp_micros(),
    } as f64
        / 1e6;
    let mut fields = split_fields(&m["rest"]);
    if fields.is_empty() {
        return None;
    }
    let event = fields.remove(0);
    Some(LogEvent { ts, event, fields })
}

fn short_name(name: &str) -> Option<String> {
    if name.is_empty() || name == "nil" {
        return None;
    }
    Some(name.split('-').next().unwrap_or(name).to_string())
}

/// Player deaths with cause, and killing blows on players.
pub fn analyse(events: impl IntoIterator<Item = LogEvent>) -> Analysis {
    type Hit = (
        f64,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
    );
    let mut result = Analysis::default();
    let mut last_hit: HashMap<String, Hit> = HashMap::new();
    let mut last_kill: HashMap<String, Kill> = HashMap::new();
    for ev in events {
        result.lines += 1;
        let f = &ev.fields;
        // f: 0 srcGUID, 1 srcName, 2 srcFlags, 3 srcRaidFlags, 4 dstGUID, 5 dstName, 6 dstFlags, 7 dstRaidFlags, 8.. rest
        if f.len() < 8 {
            result.skipped += 1;
            continue;
        }
        let dst_guid = &f[4];
        if !dst_guid.starts_with("Player-") {
            continue; // only player deaths matter
        }
        let e = ev.event.as_str();
        if DAMAGE_EVENTS.contains(&e) {
            let (mut spell, mut env) = (None, None);
            if e == "ENVIRONMENTAL_DAMAGE" {
                env = Some(
                    f[8..]
                        .iter()
                        .find_map(|x| ENVIRONMENT.iter().find(|(k, _)| k == x).map(|(_, v)| *v))
                        .unwrap_or("environnement")
                        .to_string(),
                );
            } else if e == "SWING_DAMAGE" {
                spell = Some("mêlée".to_string());
            } else {
                spell = f.get(9).cloned();
            }
            let src = (f[0] != "0000000000000000").then(|| f[0].clone());
            last_hit.insert(
                dst_guid.clone(),
                (ev.ts, short_name(&f[1]), src, spell, env),
            );
        } else if e == "PARTY_KILL" {
            let k = Kill {
                ts: ev.ts,
                killer: short_name(&f[1]).unwrap_or_else(|| "?".into()),
                killer_guid: f[0].clone(),
                victim: short_name(&f[5]).unwrap_or_else(|| "?".into()),
                victim_guid: dst_guid.clone(),
            };
            if f[0].starts_with("Player-") {
                result.kills.push(k.clone());
            }
            last_kill.insert(dst_guid.clone(), k);
        } else if e == "UNIT_DIED" {
            let mut d = Death {
                ts: ev.ts,
                guid: dst_guid.clone(),
                name: short_name(&f[5]).unwrap_or_else(|| "?".into()),
                ..Death::default()
            };
            if let Some(hit) = last_hit.remove(dst_guid) {
                if ev.ts - hit.0 <= CAUSE_WINDOW {
                    (d.source, d.source_guid, d.spell, d.environment) =
                        (hit.1, hit.2, hit.3, hit.4);
                }
            }
            if let Some(k) = last_kill.remove(dst_guid) {
                if (ev.ts - k.ts).abs() <= KILL_WINDOW {
                    d.killer = Some(k.killer);
                    d.killer_guid = Some(k.killer_guid);
                }
            }
            result.deaths.push(d);
        }
    }
    result
}

pub fn analyse_lines<'a>(lines: impl IntoIterator<Item = &'a str>, default_year: i32) -> Analysis {
    analyse(
        lines
            .into_iter()
            .filter_map(|l| parse_line(l, default_year)),
    )
}

pub fn analyse_file(path: &Path) -> Result<Analysis, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{} : {e}", path.display()))?;
    let year = file
        .metadata()
        .and_then(|m| m.modified())
        .map(|t| chrono::DateTime::<Local>::from(t).year())
        .unwrap_or_else(|_| Local::now().year());
    let mut reader = BufReader::new(file);
    let mut buf = Vec::new();
    let mut events = Vec::new();
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf) {
            Ok(0) => break,
            Ok(_) => {
                if let Some(ev) = parse_line(
                    String::from_utf8_lossy(&buf).trim_end_matches(['\r', '\n']),
                    year,
                ) {
                    events.push(ev);
                }
            }
            Err(e) => return Err(format!("{} : {e}", path.display())),
        }
    }
    Ok(analyse(events))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ME: &str = "Player-1-ABC";

    fn log() -> Vec<String> {
        vec![
            format!("11/18/2026 21:00:00.100+1  SWING_DAMAGE,Creature-0-1,\"Hogger\",0x10a48,0x0,{ME},\"Testeur-Forever\",0x511,0x0,1,2"),
            format!("11/18/2026 21:00:01.000+1  SPELL_DAMAGE,Creature-0-1,\"Hogger\",0x10a48,0x0,{ME},\"Testeur-Forever\",0x511,0x0,6253,\"Coup de massue\",0x1,40"),
            format!("11/18/2026 21:00:01.500+1  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,{ME},\"Testeur-Forever\",0x511,0x0"),
            "11/18/2026 21:05:00.000+1  ENVIRONMENTAL_DAMAGE,0000000000000000,nil,0x0,0x0,Player-1-BBB,\"Bob\",0x511,0x0,Falling,300".into(),
            "11/18/2026 21:05:00.200+1  UNIT_DIED,0000000000000000,nil,0x0,0x0,Player-1-BBB,\"Bob\",0x511,0x0".into(),
            "11/18/2026 21:10:00.000+1  PARTY_KILL,Player-1-BBB,\"Bob\",0x511,0x0,Player-9-ZZZ,\"Gorbash-Forever\",0x548,0x0".into(),
            "11/18/2026 21:10:00.100+1  UNIT_DIED,0000000000000000,nil,0x0,0x0,Player-9-ZZZ,\"Gorbash-Forever\",0x548,0x0".into(),
            "garbage line".into(),
        ]
    }

    #[test]
    fn deaths_with_cause_and_kills() {
        let lines = log();
        let a = analyse_lines(lines.iter().map(String::as_str), 2026);
        assert_eq!(a.lines, 7);
        assert_eq!(a.deaths.len(), 3);
        let me = &a.deaths[0];
        assert_eq!(me.name, "Testeur");
        assert_eq!(me.cause(), "Hogger (Coup de massue)");
        assert!(!me.by_player());
        assert_eq!(a.deaths[1].cause(), "chute");
        assert_eq!(a.deaths[2].killer.as_deref(), Some("Bob"));
        assert!(a.deaths[2].by_player());
        assert_eq!(a.kills.len(), 1);
        assert_eq!(a.kills[0].victim, "Gorbash");
        // 21:00:01.5 at UTC+1 = 20:00:01.5 UTC
        let expected = chrono::Utc
            .with_ymd_and_hms(2026, 11, 18, 20, 0, 1)
            .unwrap()
            .timestamp() as f64
            + 0.5;
        assert!((me.ts - expected).abs() < 1e-6, "{}", me.ts);
    }

    #[test]
    fn fields_keep_quoted_commas() {
        assert_eq!(
            split_fields("A,\"b,c\",[1,2],(x,y)"),
            vec!["A", "b,c", "[1,2]", "(x,y)"]
        );
    }
}
