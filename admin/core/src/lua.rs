//! Reading and writing Lua literals (WoW SavedVariables files, Press.lua).
//!
//! Only the subset WoW writes is supported: global assignments `Name = value`,
//! tables, strings, numbers, booleans, nil and comments. No Lua code is ever run.
//! Values become JSON values: a table whose keys are exactly 1..n becomes an
//! array, any other table an object (numeric keys turned into strings), and an
//! empty table an empty object.

use serde_json::{Map, Number, Value};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError(pub String);

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ParseError {}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

enum Key {
    Int(i64),
    Str(String),
}

impl Parser<'_> {
    fn error(&self, msg: &str) -> ParseError {
        let line = self.s[..self.i.min(self.s.len())]
            .iter()
            .filter(|&&c| c == b'\n')
            .count()
            + 1;
        ParseError(format!("{msg} (ligne {line})"))
    }

    fn skip(&mut self) {
        while self.i < self.s.len() {
            let c = self.s[self.i];
            if matches!(c, b' ' | b'\t' | b'\r' | b'\n') {
                self.i += 1;
            } else if self.s[self.i..].starts_with(b"--") {
                let (end, len) = if self.s[self.i..].starts_with(b"--[[") {
                    (find(self.s, self.i, b"]]"), 2)
                } else {
                    (find(self.s, self.i, b"\n"), 1)
                };
                self.i = end.map_or(self.s.len(), |e| e + len);
            } else {
                break;
            }
        }
    }

    fn peek(&mut self) -> Option<u8> {
        self.skip();
        self.s.get(self.i).copied()
    }

    fn expect(&mut self, ch: u8) -> Result<(), ParseError> {
        if self.peek() != Some(ch) {
            return Err(self.error(&format!("'{}' attendu", ch as char)));
        }
        self.i += 1;
        Ok(())
    }

    fn string(&mut self) -> Result<String, ParseError> {
        let quote = self.s[self.i];
        self.i += 1;
        let mut out = Vec::new();
        loop {
            let Some(&c) = self.s.get(self.i) else {
                return Err(self.error("chaine non terminee"));
            };
            if c == quote {
                self.i += 1;
                return Ok(String::from_utf8_lossy(&out).into_owned());
            }
            if c != b'\\' {
                out.push(c);
                self.i += 1;
                continue;
            }
            self.i += 1;
            let Some(&e) = self.s.get(self.i) else {
                return Err(self.error("chaine non terminee"));
            };
            let simple = match e {
                b'n' => Some(10),
                b't' => Some(9),
                b'r' => Some(13),
                b'a' => Some(7),
                b'b' => Some(8),
                b'f' => Some(12),
                b'v' => Some(11),
                b'\\' => Some(b'\\'),
                b'"' => Some(b'"'),
                b'\'' => Some(b'\''),
                b'\n' => Some(10),
                _ => None,
            };
            if let Some(b) = simple {
                out.push(b);
                self.i += 1;
            } else if e.is_ascii_digit() {
                let mut n: u32 = 0;
                let mut k = 0;
                while k < 3 && self.s.get(self.i).is_some_and(|c| c.is_ascii_digit()) {
                    n = n * 10 + u32::from(self.s[self.i] - b'0');
                    self.i += 1;
                    k += 1;
                }
                out.push((n & 0xFF) as u8);
            } else {
                return Err(self.error(&format!("echappement inconnu \\{}", e as char)));
            }
        }
    }

    fn name(&self) -> Option<&str> {
        let s = &self.s[self.i..];
        let first = *s.first()?;
        if !(first.is_ascii_alphabetic() || first == b'_') {
            return None;
        }
        let len = s
            .iter()
            .take_while(|c| c.is_ascii_alphanumeric() || **c == b'_')
            .count();
        std::str::from_utf8(&s[..len]).ok()
    }

    fn number(&mut self) -> Option<Value> {
        let start = self.i;
        let s = self.s;
        let mut j = start;
        if s.get(j) == Some(&b'-') {
            j += 1;
        }
        if s.get(j) == Some(&b'0') && matches!(s.get(j + 1), Some(b'x' | b'X')) {
            let digits = s[j + 2..]
                .iter()
                .take_while(|c| c.is_ascii_hexdigit())
                .count();
            if digits == 0 {
                return None;
            }
            let text = std::str::from_utf8(&s[j + 2..j + 2 + digits]).ok()?;
            let mut n = i64::from_str_radix(text, 16).ok()?;
            if j > start {
                n = -n;
            }
            self.i = j + 2 + digits;
            return Some(Value::from(n));
        }
        let int_len = s[j..].iter().take_while(|c| c.is_ascii_digit()).count();
        let mut k = j + int_len;
        let mut is_float = false;
        if s.get(k) == Some(&b'.') {
            let frac = s[k + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
            if int_len == 0 && frac == 0 {
                return None;
            }
            k += 1 + frac;
            is_float = true;
        } else if int_len == 0 {
            return None;
        }
        if matches!(s.get(k), Some(b'e' | b'E')) {
            let mut m = k + 1;
            if matches!(s.get(m), Some(b'+' | b'-')) {
                m += 1;
            }
            let exp = s[m..].iter().take_while(|c| c.is_ascii_digit()).count();
            if exp > 0 {
                k = m + exp;
                is_float = true;
            }
        }
        let text = std::str::from_utf8(&s[start..k]).ok()?;
        self.i = k;
        if !is_float {
            if let Ok(n) = text.parse::<i64>() {
                return Some(Value::from(n));
            }
        }
        let f: f64 = text.parse().ok()?;
        Number::from_f64(f).map(Value::Number)
    }

    fn value(&mut self) -> Result<Value, ParseError> {
        match self.peek() {
            Some(b'"' | b'\'') => return self.string().map(Value::String),
            Some(b'{') => return self.table(),
            None => return Err(self.error("valeur attendue")),
            _ => {}
        }
        if let Some(v) = self.number() {
            return Ok(v);
        }
        if let Some(word) = self.name().map(str::to_string) {
            self.i += word.len();
            return match word.as_str() {
                "true" => Ok(Value::Bool(true)),
                "false" => Ok(Value::Bool(false)),
                "nil" => Ok(Value::Null),
                _ => Err(self.error(&format!("identifiant inattendu {word}"))),
            };
        }
        Err(self.error("valeur attendue"))
    }

    fn table(&mut self) -> Result<Value, ParseError> {
        self.expect(b'{')?;
        let mut entries: Vec<(Key, Value)> = Vec::new();
        let mut n = 0i64;
        loop {
            match self.peek() {
                Some(b'}') => {
                    self.i += 1;
                    break;
                }
                None => return Err(self.error("'}' attendu")),
                Some(b'[') => {
                    self.i += 1;
                    let key = match self.value()? {
                        Value::Number(num) if num.is_i64() => Key::Int(num.as_i64().unwrap_or(0)),
                        Value::Number(num) => Key::Str(num.to_string()),
                        Value::String(s) => Key::Str(s),
                        Value::Bool(b) => Key::Str(b.to_string()),
                        _ => return Err(self.error("cle invalide")),
                    };
                    self.expect(b']')?;
                    self.expect(b'=')?;
                    entries.push((key, self.value()?));
                }
                Some(_) => {
                    let save = self.i;
                    let named = self.name().map(str::to_string);
                    let mut done = false;
                    if let Some(name) = named {
                        self.i += name.len();
                        if self.peek() == Some(b'=') {
                            self.i += 1;
                            entries.push((Key::Str(name), self.value()?));
                            done = true;
                        } else {
                            self.i = save;
                        }
                    }
                    if !done {
                        n += 1;
                        entries.push((Key::Int(n), self.value()?));
                    }
                }
            }
            if matches!(self.peek(), Some(b',' | b';')) {
                self.i += 1;
            }
        }
        // nil in a table = missing key
        entries.retain(|(_, v)| !v.is_null());
        let mut ints: Vec<i64> = Vec::new();
        let all_int = entries.iter().all(|(k, _)| match k {
            Key::Int(i) => {
                ints.push(*i);
                true
            }
            Key::Str(_) => false,
        });
        if all_int && !entries.is_empty() {
            ints.sort_unstable();
            if ints.iter().enumerate().all(|(idx, &k)| k == idx as i64 + 1) {
                entries.sort_by_key(|(k, _)| match k {
                    Key::Int(i) => *i,
                    Key::Str(_) => 0,
                });
                return Ok(Value::Array(entries.into_iter().map(|(_, v)| v).collect()));
            }
        }
        let mut map = Map::new();
        for (k, v) in entries {
            let key = match k {
                Key::Int(i) => i.to_string(),
                Key::Str(s) => s,
            };
            map.insert(key, v);
        }
        Ok(Value::Object(map))
    }

    fn assignments(&mut self) -> Result<Map<String, Value>, ParseError> {
        let mut out = Map::new();
        while self.peek().is_some() {
            let Some(name) = self.name().map(str::to_string) else {
                return Err(self.error("affectation attendue"));
            };
            self.i += name.len();
            self.expect(b'=')?;
            out.insert(name, self.value()?);
        }
        Ok(out)
    }
}

fn find(s: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    s[from..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| p + from)
}

/// Parses a SavedVariables file: `{global_name: value}`.
pub fn loads(text: &str) -> Result<Map<String, Value>, ParseError> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    Parser {
        s: text.as_bytes(),
        i: 0,
    }
    .assignments()
}

pub fn load(path: &std::path::Path) -> Result<Map<String, Value>, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{} : {e}", path.display()))?;
    loads(&String::from_utf8_lossy(&bytes)).map_err(|e| format!("{} : {e}", path.display()))
}

fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 32 || c as u32 == 127 => out.push_str(&format!("\\{:03}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Lua literal for a JSON value. Object keys are written sorted.
pub fn dumps_value(v: &Value, indent: usize) -> String {
    let pad = "\t".repeat(indent + 1);
    let close = "\t".repeat(indent);
    match v {
        Value::Null => "nil".into(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => quote(s),
        Value::Array(items) if items.is_empty() => "{}".into(),
        Value::Array(items) => {
            let body: Vec<String> = items
                .iter()
                .map(|x| format!("{pad}{},", dumps_value(x, indent + 1)))
                .collect();
            format!("{{\n{}\n{close}}}", body.join("\n"))
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().filter(|k| !map[*k].is_null()).collect();
            if keys.is_empty() {
                return "{}".into();
            }
            keys.sort();
            let body: Vec<String> = keys
                .iter()
                .map(|k| {
                    format!(
                        "{pad}[{}] = {},",
                        quote(k),
                        dumps_value(&map[*k], indent + 1)
                    )
                })
                .collect();
            format!("{{\n{}\n{close}}}", body.join("\n"))
        }
    }
}

/// `Name = value` lines.
pub fn dumps(assignments: &[(&str, &Value)]) -> String {
    assignments
        .iter()
        .map(|(name, value)| format!("{name} = {}\n", dumps_value(value, 0)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_what_wow_writes() {
        let text = "\u{feff}\nRenatusDB = {\n\t[\"events\"] = {\n\t\t[\"Player-1-A:1\"] = {\n\t\t\t[\"k\"] = \"DEATH\",\n\t\t\t[\"t\"] = 1700000000,\n\t\t\t[\"p\"] = {\n\t\t\t\t[\"enemies\"] = {\n\t\t\t\t\t\"Gorbash\", -- [1]\n\t\t\t\t\t\"Mo\\\"rg\", -- [2]\n\t\t\t\t},\n\t\t\t\t[\"x\"] = 1.5,\n\t\t\t\t[\"neg\"] = -3,\n\t\t\t\t[\"hex\"] = 0x1F,\n\t\t\t},\n\t\t\t[\"del\"] = nil,\n\t\t},\n\t},\n\t[\"pressDone\"] = {},\n\t[5] = true,\n}\nRenatusCharDB = nil\n";
        let data = loads(text).unwrap();
        let ev = &data["RenatusDB"]["events"]["Player-1-A:1"];
        assert_eq!(ev["k"], "DEATH");
        assert_eq!(ev["t"], 1_700_000_000);
        assert_eq!(ev["p"]["enemies"], json!(["Gorbash", "Mo\"rg"]));
        assert_eq!(ev["p"]["x"], 1.5);
        assert_eq!(ev["p"]["neg"], -3);
        assert_eq!(ev["p"]["hex"], 31);
        assert!(ev.get("del").is_none());
        assert_eq!(data["RenatusDB"]["pressDone"], json!({}));
        assert_eq!(data["RenatusDB"]["5"], true);
        assert_eq!(data["RenatusCharDB"], Value::Null);
    }

    #[test]
    fn decimal_escapes_are_bytes() {
        let data = loads("A = \"caf\\195\\169 \\9\"").unwrap();
        assert_eq!(data["A"], "café \t");
    }

    #[test]
    fn errors_name_the_line() {
        let err = loads("A = {\n  [\"x\"] = ,\n}").unwrap_err();
        assert!(err.0.contains("ligne 2"), "{err}");
        assert!(loads("A = os.exit()").is_err());
    }

    #[test]
    fn round_trip() {
        let v = json!({"version": 1, "items": [{"id": "a\"b\\c\nd", "p": {"n": 2.5, "ok": true}}], "empty": {}});
        let text = dumps(&[("RenatusPress", &v)]);
        let back = loads(&text).unwrap();
        assert_eq!(back["RenatusPress"], v);
    }
}
