//! Special issues ("hors-série"): an issue on a theme, published beside the regular ones.
//!
//! A special issue never moves the regular gazette along: its key starts with `PREFIX`,
//! so the period of the next regular issue and the facts it offers ignore it (issues.rs).
//! Its theme picks the period, the facts ticked by default and an editorial brief added
//! to the prompt (`{special}`, see gazette::PROMPT). The addon numbers special issues apart
//! and shows them as such (EDITION payload `special`: their title).

use chrono::{Datelike, Duration, NaiveDate, TimeZone, Weekday};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::chronicle::Chronicle;
use crate::gazette::{self, local};
use crate::issues::{self, Candidate, Selection};

/// Key prefix of special issues ("hs:2026-12-24-2130").
pub const PREFIX: &str = "hs:";
const DAY: f64 = 86400.0;
/// A theme is recalled from this many days before its date...
pub const REMIND_BEFORE: i64 = 10;
/// ...to this many days after.
pub const REMIND_AFTER: i64 = 1;

pub fn is_special(edition: &str) -> bool {
    edition.starts_with(PREFIX)
}

pub fn edition_key(now: f64) -> String {
    format!("{PREFIX}{}", gazette::edition_key(now))
}

/// Kind of special issue: what the facts ticked by default are.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// A holiday or a free theme: every fact of the period.
    Theme,
    /// Records, milestones and major clashes of a long period.
    Retro,
    /// One member: their facts.
    Portrait,
    /// A short period (a raid night, a PvP weekend): every fact.
    Event,
}

/// When a theme comes back each year.
#[derive(Clone, Copy)]
enum When {
    Never,
    Fixed(u32, u32),
    /// Days after Easter Sunday (negative: before).
    Easter(i64),
    /// The n-th given weekday of a month (n = -1: the last one).
    Nth(u32, Weekday, i32),
    /// Mother's day in France: last Sunday of May, a week later when it is Pentecost.
    MothersDay,
}

/// Default period: how far back it starts.
#[derive(Clone, Copy)]
enum Span {
    Days(f64),
    /// From the 1st of this month (of the previous one before the 10th).
    Month,
    /// From July 1st.
    Summer,
    /// From January 1st.
    Year,
}

struct Theme {
    key: &'static str,
    title: &'static str,
    kind: Kind,
    when: When,
    span: Span,
    brief: &'static str,
}

const PORTRAIT_BRIEF: &str = "tout le numéro est consacré à {member} : la une raconte son parcours sur la période, puis ses \
exploits, ses déboires, ses rivaux, ses compagnons de route. Glisse un « questionnaire de Proust » dont les réponses \
sont tirées des faits (« Son plus grand exploit ? », « Son pire ennemi ? », « Son lieu préféré ? »…), jamais des paroles \
qu'on lui prêterait. La règle 14 (équilibre entre les membres) ne s'applique pas à ce numéro.";

const THEMES: &[Theme] = &[
    Theme { key: "nouvel-an", title: "Spécial Nouvel An", kind: Kind::Theme, when: When::Fixed(1, 1), span: Span::Days(30.0),
        brief: "les vœux de la rédaction et les bonnes résolutions de chaque membre pour l'année, tirées de ce qu'il a fait (ou raté) ces derniers temps." },
    Theme { key: "galette", title: "Spécial Galette des rois", kind: Kind::Theme, when: When::Fixed(1, 6), span: Span::Days(30.0),
        brief: "la galette des rois : qui a eu la fève (le plus chanceux de la période : butin, jet de dés, survie) est couronné roi ou reine ; le partage de la galette, les jaloux, la couronne en carton." },
    Theme { key: "chandeleur", title: "Spécial Chandeleur", kind: Kind::Theme, when: When::Fixed(2, 2), span: Span::Days(30.0),
        brief: "la Chandeleur : les retournements de situation comme des crêpes qu'on fait sauter, les ratés restés collés au plafond, les réussites dorées à point." },
    Theme { key: "saint-valentin", title: "Spécial Saint-Valentin", kind: Kind::Theme, when: When::Fixed(2, 14), span: Span::Days(30.0),
        brief: "la Saint-Valentin (en Azeroth, « De l'amour dans l'air ») : les duos, les rencontres, les sauvetages, les coups de foudre (ennemis compris), le courrier du cœur. Les couples sont de jeu, jamais des insinuations sur les joueurs réels." },
    Theme { key: "carnaval", title: "Spécial Carnaval", kind: Kind::Theme, when: When::Easter(-47), span: Span::Days(30.0),
        brief: "Mardi gras et le carnaval : le monde à l'envers, les membres vus sous un autre jour, défilé de chars, masques et déguisements (montures, métiers, tenues)." },
    Theme { key: "poisson-avril", title: "Numéro du 1er avril", kind: Kind::Theme, when: When::Fixed(4, 1), span: Span::Days(30.0),
        brief: "numéro du 1er avril : des titres si incroyables qu'on les croirait canulars, mais chaque article finit par révéler que, si, c'est vrai (les faits le prouvent). Aucune fausse nouvelle : la blague, c'est que tout est vrai." },
    Theme { key: "paques", title: "Spécial Pâques", kind: Kind::Theme, when: When::Easter(0), span: Span::Days(30.0),
        brief: "Pâques (en Azeroth, le « Jardin des nobles ») : la chasse aux œufs, ce que les membres ont déniché (butins rares, trouvailles, lieux découverts), les cloches revenues de Rome." },
    Theme { key: "premier-mai", title: "Spécial Fête du Travail", kind: Kind::Theme, when: When::Fixed(5, 1), span: Span::Days(30.0),
        brief: "la Fête du Travail : les forçats de la guilde (quêtes, métiers, or gagné), leurs revendications syndicales, le défilé, le muguet." },
    Theme { key: "fete-meres", title: "Spécial Fête des mères", kind: Kind::Theme, when: When::MothersDay, span: Span::Days(30.0),
        brief: "la fête des mères : ceux qui veillent sur les autres (soins, sauvetages, accompagnement des plus jeunes), les cadeaux de fête des mères (butins), les bêtises qu'on cache à maman." },
    Theme { key: "fete-peres", title: "Spécial Fête des pères", kind: Kind::Theme, when: When::Nth(6, Weekday::Sun, 3), span: Span::Days(30.0),
        brief: "la fête des pères : les vétérans et les mentors de la guilde, ceux qui portent les autres, les blagues de papa, la cravate offerte (un butin)." },
    Theme { key: "fete-musique", title: "Spécial Fête de la musique", kind: Kind::Theme, when: When::Fixed(6, 21), span: Span::Days(30.0),
        brief: "la Fête de la musique (en Azeroth, la fête du Feu du solstice) : les exploits racontés en chansons, critiques de concert, le palmarès des tubes de la guilde." },
    Theme { key: "quatorze-juillet", title: "Spécial 14 Juillet", kind: Kind::Theme, when: When::Fixed(7, 14), span: Span::Days(30.0),
        brief: "le 14 Juillet : le défilé des troupes de la guilde, la remise de médailles pour les faits d'armes (et les décorations pour les déboires), le feu d'artifice, le bal." },
    Theme { key: "rentree", title: "Spécial Rentrée", kind: Kind::Theme, when: When::Fixed(9, 1), span: Span::Days(30.0),
        brief: "la rentrée : le bulletin scolaire de chaque membre (appréciations des professeurs d'après ses faits), la liste des fournitures, les bonnes résolutions." },
    Theme { key: "brasseurs", title: "Spécial Fête des Brasseurs", kind: Kind::Theme, when: When::Fixed(9, 20), span: Span::Days(30.0),
        brief: "la fête des Brasseurs d'Azeroth : chaque exploit dégusté comme une bière (robe, mousse, amertume), les cuites relevées, la course de béliers." },
    Theme { key: "halloween", title: "Spécial Halloween", kind: Kind::Theme, when: When::Fixed(10, 31), span: Span::Days(30.0),
        brief: "Halloween (en Azeroth, la Sanssaint) : les morts, les frayeurs, les ennemis et les créatures croisés racontés en histoires d'épouvante, à lire à la bougie." },
    Theme { key: "beaujolais", title: "Spécial Beaujolais nouveau", kind: Kind::Theme, when: When::Nth(11, Weekday::Thu, 3), span: Span::Days(30.0),
        brief: "le Beaujolais nouveau est arrivé : les membres et leurs exploits notés comme des crus (robe, nez, bouche, garde), notes de dégustation, les cuites relevées." },
    Theme { key: "noel", title: "Spécial Noël", kind: Kind::Theme, when: When::Fixed(12, 25), span: Span::Days(30.0),
        brief: "Noël (en Azeroth, le Voile d'hiver) : un conte de Noël, les lettres au Père Noël des membres, les cadeaux reçus (butins), qui a été sage et qui aura du charbon." },
    Theme { key: "retro-mois", title: "Rétrospective du mois", kind: Kind::Retro, when: When::Never, span: Span::Month,
        brief: "la rétrospective du mois : les records, les jalons et les grands affrontements de la période, un palmarès façon cérémonie de remise de prix." },
    Theme { key: "retro-ete", title: "Rétrospective de l'été", kind: Kind::Retro, when: When::Fixed(8, 31), span: Span::Summer,
        brief: "la rétrospective de l'été : les records, les jalons et les grands affrontements des vacances, comme un album de souvenirs de vacances." },
    Theme { key: "retro-annee", title: "Rétrospective de l'année", kind: Kind::Retro, when: When::Fixed(12, 31), span: Span::Year,
        brief: "la rétrospective de l'année, pour la Saint-Sylvestre : les records, les jalons et les grands affrontements de l'année, un palmarès façon cérémonie, les vœux pour l'an prochain." },
    Theme { key: "portrait", title: "Spécial {member}", kind: Kind::Portrait, when: When::Never, span: Span::Days(365.0),
        brief: PORTRAIT_BRIEF },
    Theme { key: "evenement", title: "Édition spéciale", kind: Kind::Event, when: When::Never, span: Span::Days(1.0),
        brief: "une édition spéciale sur un événement de la guilde, comme un direct : la période est courte, raconte-la pas à pas, heure par heure si les faits le permettent." },
    Theme { key: "libre", title: "Hors-série", kind: Kind::Theme, when: When::Never, span: Span::Days(7.0),
        brief: "" },
];

/// Easter Sunday (Gregorian calendar; anonymous algorithm, "Meeus/Jones/Butcher").
fn easter(year: i32) -> NaiveDate {
    let a = year % 19;
    let b = year / 100;
    let c = year % 100;
    let d = b / 4;
    let e = b % 4;
    let f = (b + 8) / 25;
    let g = (b - f + 1) / 3;
    let h = (19 * a + b - d - g + 15) % 30;
    let i = c / 4;
    let k = c % 4;
    let l = (32 + 2 * e + 2 * i - h - k) % 7;
    let m = (a + 11 * h + 22 * l) / 451;
    let month = (h + l - 7 * m + 114) / 31;
    let day = (h + l - 7 * m + 114) % 31 + 1;
    NaiveDate::from_ymd_opt(year, month as u32, day as u32).expect("valid Easter date")
}

fn nth_weekday(year: i32, month: u32, wd: Weekday, n: i32) -> Option<NaiveDate> {
    if n > 0 {
        let first = NaiveDate::from_ymd_opt(year, month, 1)?;
        let shift = (7 + wd.num_days_from_monday() as i64
            - first.weekday().num_days_from_monday() as i64)
            % 7;
        Some(first + Duration::days(shift + 7 * (n as i64 - 1)))
    } else {
        let next = if month == 12 {
            NaiveDate::from_ymd_opt(year + 1, 1, 1)?
        } else {
            NaiveDate::from_ymd_opt(year, month + 1, 1)?
        };
        let last = next - Duration::days(1);
        let shift = (7 + last.weekday().num_days_from_monday() as i64
            - wd.num_days_from_monday() as i64)
            % 7;
        Some(last - Duration::days(shift))
    }
}

fn date_in(when: When, year: i32) -> Option<NaiveDate> {
    match when {
        When::Never => None,
        When::Fixed(m, d) => NaiveDate::from_ymd_opt(year, m, d),
        When::Easter(days) => Some(easter(year) + Duration::days(days)),
        When::Nth(m, wd, n) => nth_weekday(year, m, wd, n),
        When::MothersDay => {
            let last = nth_weekday(year, 5, Weekday::Sun, -1)?;
            let pentecost = easter(year) + Duration::days(49);
            Some(if last == pentecost {
                last + Duration::days(7)
            } else {
                last
            })
        }
    }
}

/// Days from `today` to the theme's nearest date within the reminder window.
fn days_to(when: When, today: NaiveDate) -> Option<i64> {
    (today.year() - 1..=today.year() + 1)
        .filter_map(|y| date_in(when, y))
        .map(|d| (d - today).num_days())
        .find(|n| (-REMIND_AFTER..=REMIND_BEFORE).contains(n))
}

fn start_of(date: NaiveDate) -> f64 {
    let midnight = date.and_hms_opt(0, 0, 0).expect("midnight");
    chrono::Local
        .from_local_datetime(&midnight)
        .earliest()
        .map(|d| d.timestamp() as f64)
        .unwrap_or_else(|| midnight.and_utc().timestamp() as f64)
}

fn span_start(span: Span, now: f64) -> f64 {
    let today = local(now).date_naive();
    let ymd = |y, m, d| NaiveDate::from_ymd_opt(y, m, d).map(start_of);
    match span {
        Span::Days(n) => Some(now - n * DAY),
        Span::Month => {
            let (y, m) = if today.day() < 10 {
                if today.month() == 1 {
                    (today.year() - 1, 12)
                } else {
                    (today.year(), today.month() - 1)
                }
            } else {
                (today.year(), today.month())
            };
            ymd(y, m, 1)
        }
        Span::Summer => {
            let y = if today.month() < 7 {
                today.year() - 1
            } else {
                today.year()
            };
            ymd(y, 7, 1)
        }
        Span::Year => ymd(today.year(), 1, 1),
    }
    .unwrap_or(now - 30.0 * DAY)
}

/// A theme as the window offers it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThemeView {
    pub key: &'static str,
    pub title: &'static str,
    pub kind: Kind,
    pub brief: &'static str,
    /// Default period.
    pub since: f64,
    pub until: f64,
    /// Days to its date when it is near (the reminder), negative once passed.
    pub days: Option<i64>,
}

pub fn themes(now: f64) -> Vec<ThemeView> {
    let today = local(now).date_naive();
    THEMES
        .iter()
        .map(|t| ThemeView {
            key: t.key,
            title: t.title,
            kind: t.kind,
            brief: t.brief,
            since: span_start(t.span, now),
            until: now,
            days: days_to(t.when, today),
        })
        .collect()
}

/// A special issue being prepared: its kind, title and editorial brief (as edited in
/// the window), and the member of a portrait.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Special {
    pub kind: Kind,
    pub title: String,
    pub brief: String,
    #[serde(default)]
    pub member: Option<String>,
}

impl Special {
    /// Title and brief with the portrait's member filled in.
    pub fn resolved(&self) -> Special {
        let member = self.member.as_deref().unwrap_or("").trim();
        let fill = |s: &str| s.replace("{member}", member).trim().to_string();
        Special {
            kind: self.kind,
            title: fill(&self.title),
            brief: fill(&self.brief),
            member: (!member.is_empty()).then(|| member.to_string()),
        }
    }

    /// The prompt's `{special}` block.
    pub fn prompt_block(&self) -> String {
        let mut text = format!(
            "NUMÉRO HORS-SÉRIE « {} » : ce n'est pas l'édition régulière mais un numéro spécial, publié à part.\n",
            self.title
        );
        if !self.brief.is_empty() {
            text += &format!("Thème du numéro : {}\n", self.brief);
        }
        text += "Tout le numéro suit ce thème (titres, formats, rubrique décalée comprise), sans le forcer \
quand un fait ne s'y prête pas. Le thème donne l'angle, jamais des faits : la règle 1 tient toujours.\n\n";
        text
    }

    fn ticks(&self, c: &Candidate) -> bool {
        match self.kind {
            Kind::Theme | Kind::Event => true,
            Kind::Portrait => self
                .member
                .as_ref()
                .is_some_and(|m| c.who.iter().any(|w| w == m)),
            Kind::Retro => c.cat == gazette::RECORDS || c.text.contains("AFFRONTEMENT MAJEUR"),
        }
    }
}

/// The facts of `since..until` offered for a special issue. Unlike a regular issue,
/// facts already told stay ticked: a special issue may well tell them again.
pub fn prepare(
    ch: &Chronicle,
    pending: &[Value],
    special: &Special,
    since: f64,
    until: f64,
    now: f64,
) -> Result<Selection, String> {
    let special = special.resolved();
    if special.title.is_empty() {
        return Err("Donne un titre au hors-série.".into());
    }
    if special.kind == Kind::Portrait && special.member.is_none() {
        return Err("Choisis le membre du portrait.".into());
    }
    let until = until.min(now);
    if since >= until {
        return Err("La période du hors-série est vide (début après la fin).".into());
    }
    let brief = gazette::build(ch, since, until);
    let used = issues::cited(ch, pending);
    let candidates = brief
        .facts
        .iter()
        .map(|f| {
            let uses: Vec<_> = f.refs.iter().filter_map(|r| used.get(r)).collect();
            let all = !f.refs.is_empty() && uses.len() == f.refs.len();
            let mut c = Candidate {
                key: f.key.clone(),
                text: f.text.clone(),
                when: f.when,
                cat: f.cat,
                who: f.who.clone(),
                recent: true,
                used: if all {
                    uses.first().map(|u| u.label())
                } else {
                    None
                },
                partly: !all && !uses.is_empty(),
                checked: false,
            };
            c.checked = special.ticks(&c);
            c
        })
        .collect();
    Ok(Selection {
        edition: edition_key(now),
        since,
        until,
        after_issue: false,
        candidates,
        brief,
        pending_cards: Vec::new(),
        special: Some(special),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }

    #[test]
    fn movable_feasts() {
        assert_eq!(easter(2026), d(2026, 4, 5));
        assert_eq!(easter(2027), d(2027, 3, 28));
        assert_eq!(date_in(When::Easter(-47), 2026), Some(d(2026, 2, 17)));
        // Pentecost 2026 is May 24, not the last Sunday of May (31)
        assert_eq!(date_in(When::MothersDay, 2026), Some(d(2026, 5, 31)));
        assert_eq!(date_in(When::MothersDay, 2027), Some(d(2027, 5, 30)));
        assert_eq!(
            date_in(When::Nth(6, Weekday::Sun, 3), 2026),
            Some(d(2026, 6, 21))
        );
        assert_eq!(
            date_in(When::Nth(11, Weekday::Thu, 3), 2026),
            Some(d(2026, 11, 19))
        );
    }

    #[test]
    fn mothers_day_moves_after_pentecost() {
        let mut moved = 0;
        for y in 2000..2100 {
            let last = nth_weekday(y, 5, Weekday::Sun, -1).unwrap();
            let got = date_in(When::MothersDay, y).unwrap();
            if last == easter(y) + Duration::days(49) {
                assert_eq!(got, last + Duration::days(7), "{y}");
                moved += 1;
            } else {
                assert_eq!(got, last, "{y}");
            }
        }
        assert!(
            moved > 0,
            "some years see Pentecost on the last Sunday of May"
        );
    }

    #[test]
    fn reminders_come_before_the_date() {
        let today = d(2026, 12, 18);
        assert_eq!(days_to(When::Fixed(12, 25), today), Some(7));
        assert_eq!(
            days_to(When::Fixed(1, 1), d(2026, 12, 25)),
            Some(7),
            "next year"
        );
        assert_eq!(days_to(When::Fixed(12, 25), d(2026, 12, 26)), Some(-1));
        assert_eq!(days_to(When::Fixed(12, 25), d(2026, 11, 25)), None);
        assert_eq!(days_to(When::Never, today), None);
    }

    #[test]
    fn portrait_needs_a_member_and_fills_it() {
        let s = Special {
            kind: Kind::Portrait,
            title: "Spécial {member}".into(),
            brief: PORTRAIT_BRIEF.into(),
            member: Some("Alice".into()),
        };
        let r = s.resolved();
        assert_eq!(r.title, "Spécial Alice");
        assert!(r.brief.starts_with("tout le numéro est consacré à Alice"));
        assert!(r.prompt_block().contains("HORS-SÉRIE « Spécial Alice »"));
    }
}
