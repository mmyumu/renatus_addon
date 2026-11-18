"""Gazette redigee par IA : faits verifies -> demande -> articles proposes au redacteur.

Garde-fous (docs/ARCHITECTURE.md §7, §8.4) :
  - seuls les evenements PARTAGES (vis G) de la guilde sont lus ;
  - consentement : un personnage n'apparait que s'il a coche « La gazette IA peut parler de moi »
    (evenement AI_CONSENT, le dernier choix compte). Sinon ses evenements ne sont pas envoyes,
    et un fait d'un autre membre qui le nomme est retire (ou son nom remplace par « un membre ») ;
  - les rivaux ne sont jamais nommes aupres de l'IA : alias « Rival A (voleur gnome) » ;
  - provenance conservee : declare a la main (« selon X »), deduit (« suppose »), journal de combat ;
  - la reponse est verifiee : sources existantes, aucun nom non autorise, longueur bornee.
    Un article qui echoue est rejete, pas corrige ;
  - rien n'est publie : les articles vont dans Press.lua, le redacteur valide en jeu.
"""
from __future__ import annotations

import collections
import datetime as dt
import hashlib
import json
import re
from dataclasses import dataclass, field
from typing import Any

from .reconcile import Chronicle

MAX_FACTS = 150
MAX_BODY = 3500       # octets (meme limite que les articles ecrits a la main)
MAX_TITLE = 90
MAX_ARTICLES = 5
HIDDEN = {"VOTE", "AI_CONSENT", "ARTICLE", "LETTER"}  # pas des faits (ou deja de la redaction)

CLASSES = {
    "WARRIOR": "guerrier", "PALADIN": "paladin", "HUNTER": "chasseur", "ROGUE": "voleur", "PRIEST": "prêtre",
    "DEATHKNIGHT": "chevalier de la mort", "SHAMAN": "chaman", "MAGE": "mage", "WARLOCK": "démoniste",
    "MONK": "moine", "DRUID": "druide", "DEMONHUNTER": "chasseur de démons", "EVOKER": "évocateur",
}
EXP_TYPES = {"DUNGEON": "donjon", "RAID": "raid", "PVP": "champ de bataille", "QUESTING": "sortie en groupe"}


@dataclass
class Fact:
    key: str
    when: float
    text: str
    refs: list[str]
    names: set[str] = field(default_factory=set)   # membres nommes dans le fait


@dataclass
class Brief:
    """Tout ce qui sera envoye a l'IA, et ce qu'il faut pour verifier la reponse."""
    facts: list[Fact]
    allowed: set[str]          # membres consentants
    forbidden: set[str]        # noms qui ne doivent jamais sortir (non consentants, rivaux)
    rival_guild: str | None
    excluded: collections.Counter  # raisons d'exclusion (pour l'affichage)
    since: float
    until: float

    @property
    def by_key(self) -> dict[str, Fact]:
        return {f.key: f for f in self.facts}


def _word_re(names: set[str]) -> re.Pattern | None:
    names = {n for n in names if n}
    if not names:
        return None
    alts = "|".join(sorted((re.escape(n) for n in names), key=len, reverse=True))
    return re.compile(rf"(?<![\w-])({alts})(?![\w-])", re.IGNORECASE)


def consent(ch: Chronicle) -> dict[str, bool]:
    """GUID d'auteur -> dernier choix publie (sequence la plus haute)."""
    best: dict[str, tuple[int, bool]] = {}
    for e in ch.of_kind("AI_CONSENT"):
        if e.get("vis") != "G":
            continue
        s = int(e.get("s") or 0)
        if e.get("a") not in best or s > best[e["a"]][0]:
            best[e["a"]] = (s, bool((e.get("p") or {}).get("ok")))
    return {a: ok for a, (_, ok) in best.items()}


def main_guild(ch: Chronicle) -> str | None:
    counts = collections.Counter(e.get("g") for e in ch.events.values()
                                 if isinstance(e, dict) and e.get("vis") == "G" and e.get("g"))
    return counts.most_common(1)[0][0] if counts else None


class _Rivals:
    """Alias stables pour les personnages de la guilde rivale."""

    def __init__(self, ch: Chronicle):
        self.info: dict[str, dict[str, Any]] = {}
        self.guild = None
        for kind in ("ENEMY_SEEN", "ENEMY_NOTE", "WANTED", "PVP_CLASH"):
            for e in sorted(ch.of_kind(kind), key=lambda e: e.get("t", 0)):
                p = e.get("p") or {}
                name = p.get("name") or p.get("enemy")
                if not name:
                    continue
                d = self.info.setdefault(name.lower(), {"name": name})
                for k in ("class", "race", "guild"):
                    if p.get(k) and k not in d:
                        d[k] = p[k]
                if kind == "ENEMY_SEEN" and p.get("guild"):
                    self.guild = p["guild"]
        self.alias: dict[str, str] = {}

    def names(self) -> set[str]:
        return {d["name"] for d in self.info.values()}

    def __call__(self, name: str | None) -> str:
        if not name:
            return "un rival"
        key = name.lower()
        if key not in self.alias:
            n = len(self.alias)
            letter = chr(ord("A") + n % 26) + (str(n // 26 + 1) if n >= 26 else "")
            d = self.info.get(key, {})
            desc = " ".join(x for x in (CLASSES.get(str(d.get("class", "")).upper(), ""), d.get("race", "")) if x)
            self.alias[key] = f"Rival {letter}" + (f" ({desc})" if desc else "")
        return self.alias[key]


def _when(t: float) -> str:
    jours = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
    d = dt.datetime.fromtimestamp(t)
    return f"{jours[d.weekday()]} {d:%d/%m %Hh%M}"


def build(ch: Chronicle, since: float, until: float) -> Brief:
    guild = main_guild(ch)
    choice = consent(ch)
    authors = ch.members()
    allowed = {authors[a] for a, ok in choice.items() if ok and a in authors}
    allowed_guids = {a for a, ok in choice.items() if ok}
    # Membres connus sans consentement : auteurs sans « oui » + membres vus dans les expeditions.
    members = set(authors.values())
    for e in ch.of_kind("EXPEDITION"):
        members.update(p.get("n") for p in (e.get("pt") or []) if isinstance(p, dict) and p.get("n"))
    members.discard(None)
    rivals = _Rivals(ch)
    forbidden_members = members - allowed
    forbidden = forbidden_members | rivals.names()
    member_re = _word_re(forbidden_members)
    rival_re = _word_re(rivals.names())
    excluded: collections.Counter = collections.Counter()

    def scrub(text: str) -> str | None:
        """Rivaux -> alias ; un membre non consentant dans le texte -> fait retire."""
        if rival_re:
            text = rival_re.sub(lambda m: rivals(m.group(1)), text)
        if member_re and member_re.search(text):
            return None
        return text

    events = [e for e in ch.events.values()
              if isinstance(e, dict) and e.get("vis") == "G" and e.get("g") == guild
              and since <= float(e.get("t", 0)) < until and e.get("k") not in HIDDEN]
    events.sort(key=lambda e: (e.get("t", 0), e.get("id", "")))

    raw: list[tuple[float, str, list[str], set[str]]] = []
    seen_rivals: dict[str, list[dict]] = collections.defaultdict(list)
    quests: dict[str, list[dict]] = collections.defaultdict(list)

    for e in events:
        if e.get("a") not in allowed_guids:
            excluded["auteur sans consentement"] += 1
            continue
        k, p, who = e.get("k"), e.get("p") or {}, e.get("n", "?")
        zone = (e.get("loc") or {}).get("i") or (e.get("loc") or {}).get("z")
        where = f" à {zone}" if zone else ""
        prov = e.get("prov") or "OBS"
        names = {who}
        if k == "ENEMY_SEEN":
            seen_rivals[e["a"]].append(e)
            continue
        if k == "QUEST_DONE":
            quests[e["a"]].append(e)
            continue
        text = None
        if k == "LEVEL_UP":
            text = f"{who} atteint le niveau {p.get('lvl', '?')}{where}"
        elif k == "DEATH":
            text = f"{who} meurt{where}" + (f" au niveau {p['lvl']}" if p.get("lvl") else "")
            if p.get("cause"):
                text += f" ({p['cause']})"
            if p.get("enemies"):
                text += " ; rivaux aperçus juste avant (supposé, pas forcément les tueurs) : " + \
                        ", ".join(rivals(n) for n in p["enemies"])
        elif k == "DEATH_CAUSE":
            victim = p.get("victim")
            if victim and victim not in allowed:
                excluded["nomme un membre sans consentement"] += 1
                continue
            names.add(victim)
            killer = p.get("killer") or ""
            cause = p.get("cause") or "?"
            if killer and killer.lower() in rivals.info:
                cause = cause.replace(killer, rivals(killer))
            text = f"d'après le journal de combat de {who} : {victim} est mort(e) — {cause}"
        elif k == "BOSS_KILL":
            text = f"{who} et son groupe triomphent de {p.get('name') or 'un boss'}{where}"
        elif k == "ZONE_FIRST_VISIT":
            text = f"{who} découvre {zone or 'une nouvelle contrée'}"
        elif k == "EXPEDITION":
            kept = [x.get("n") for x in (e.get("pt") or []) if isinstance(x, dict) and x.get("n") in allowed]
            hidden = len([x for x in (e.get("pt") or []) if isinstance(x, dict) and x.get("n") not in allowed])
            names.update(kept)
            label = EXP_TYPES.get(p.get("type"), "expédition")
            text = f"{label} {p.get('inst') or zone or ''}".strip() + f" : groupe mené par {who}"
            if kept:
                text += " avec " + ", ".join(n for n in kept if n != who)
            others = hidden + int(p.get("others") or 0)
            if others:
                text += f" (+{others} autre(s) participant(s) non nommé(s))"
            bits = [f"{int(p.get('duration', 0)) // 60} min"]
            for key, lab in (("bosses", "boss vaincu(s)"), ("deaths", "mort(s)"), ("quests", "quête(s)")):
                if p.get(key):
                    bits.append(f"{p[key]} {lab}")
            if p.get("bossNames"):
                bits.append("boss : " + ", ".join(p["bossNames"]))
            text += " — " + ", ".join(bits)
            if "finish" in (e.get("ded") or []):
                text += " (heure de fin estimée)"
        elif k == "PVP_CLASH":
            member = p.get("member") or who
            if member not in allowed:
                excluded["nomme un membre sans consentement"] += 1
                continue
            names.add(member)
            verb = "l'emporte face à" if p.get("result") == "win" else "tombe face à"
            text = f"{member} {verb} {rivals(p.get('name') or p.get('enemy'))}"
        elif k == "WANTED":
            text = f"{who} placarde un avis de recherche contre {rivals(p.get('name'))}"
            if p.get("reason"):
                text += f" — motif : {p['reason']}"
        elif k == "WANTED_CLOSE":
            text = f"{who} lève l'avis de recherche contre {rivals(p.get('name'))}"
        elif k == "ENEMY_NOTE":
            text = f"{who} annote la fiche de {rivals(p.get('name'))}"
            if p.get("nickname"):
                text += f" et le/la surnomme « {p['nickname']} »"
        elif k == "ANECDOTE":
            text = f"anecdote racontée par {who} : {p.get('title', '')}"
            if p.get("desc"):
                text += f" — {p['desc']}"
        elif k == "PROFESSION":
            text = f"{who} atteint {p.get('rank', '?')} en {p.get('skill', '?')}"
        elif k == "RARE_ITEM":
            text = f"{who} obtient {p.get('item', 'un objet rare')}"
        elif k == "GUILD_JOIN":
            text = f"{who} rejoint la guilde"
        if not text:
            excluded[f"type non pris en charge ({k})"] += 1
            continue
        if prov == "MAN" and k not in ("ANECDOTE", "WANTED", "WANTED_CLOSE", "ENEMY_NOTE"):
            text = f"selon {who} (déclaré, non vérifié) : {text}"
        elif prov == "DED":
            text += " (déduit, non observé)"
        text = scrub(text)
        if text is None:
            excluded["nomme un membre sans consentement"] += 1
            continue
        raw.append((float(e["t"]), text, [e["id"]], names))

    for author, evs in seen_rivals.items():
        who = authors.get(author, "?")
        distinct = sorted({rivals((x.get("p") or {}).get("name")) for x in evs})
        guilds = {(x.get("p") or {}).get("guild") for x in evs} - {None}
        text = (f"{who} a croisé {len(evs)} fois des membres de la guilde rivale "
                f"{'/'.join(sorted(guilds)) or ''} cette semaine : " + ", ".join(distinct[:8]))
        raw.append((float(evs[-1]["t"]), text, [x["id"] for x in evs][-10:], {who}))
    for author, evs in quests.items():
        who = authors.get(author, "?")
        titles = [(x.get("p") or {}).get("title") for x in evs if (x.get("p") or {}).get("title")]
        text = f"{who} termine {len(evs)} quête(s)" + (" dont « " + " », « ".join(titles[:3]) + " »" if titles else "")
        text = scrub(text)
        if text:
            raw.append((float(evs[-1]["t"]), text, [x["id"] for x in evs][-10:], {who}))

    raw.sort(key=lambda r: r[0])
    if len(raw) > MAX_FACTS:
        excluded["au-delà des 150 faits les plus récents"] += len(raw) - MAX_FACTS
        raw = raw[-MAX_FACTS:]
    facts = [Fact(f"F{i}", t, f"{_when(t)} — {text}", refs, names) for i, (t, text, refs, names) in enumerate(raw, 1)]
    return Brief(facts, allowed, forbidden, rivals.guild, excluded, since, until)


PROMPT = """Tu es la rédaction de « La Gazette », le journal satirique d'une guilde de World of Warcraft.
Écris entre 2 et {max_articles} articles en français pour l'édition du {start} au {end}, à partir
UNIQUEMENT des faits numérotés ci-dessous.

Règles impératives :
1. N'invente rien : aucun événement, nom, chiffre, lieu, boss, objet ou dialogue rapporté qui ne
   figure pas dans les faits. Tu peux commenter, exagérer le ton, faire des hypothèses présentées
   comme telles (« on murmure que… » à propos d'un fait réel), mais jamais créer un fait.
2. Ne nomme que les personnages présents dans les faits. Les rivaux sont désignés par leur alias
   (« Rival A … ») : n'essaie pas de deviner leur vrai nom.
3. Respecte la provenance : un fait « déclaré, non vérifié » s'écrit « selon X » ; un fait
   « supposé » ou « déduit » reste au conditionnel ; les rivaux aperçus avant une mort ne sont pas
   les tueurs.
4. Humour bienveillant : on taquine les personnages et leurs exploits ou déboires en jeu, jamais
   les joueurs réels (physique, vie privée, origine, etc.). Pas d'insulte ni de contenu choquant.
5. Chaque article cite dans « refs » les numéros des faits qu'il utilise (au moins un).
6. Titre : 80 caractères au plus. Corps : 1200 caractères au plus, texte brut sans Markdown.
7. Varie les formats (Une, Brève, Nécrologie, Chronique PvP, Carnet mondain…) et les styles
   (journaliste sarcastique, chroniqueur épique, rédacteur de faits divers…).
{guild_line}
Réponds par un unique objet JSON, sans texte autour :
{{"articles": [{{"title": "...", "format": "...", "style": "...", "body": "...", "refs": ["F1", "F4"]}}]}}

Faits de la semaine :
{facts}
"""


def prompt(brief: Brief) -> str:
    start = dt.datetime.fromtimestamp(brief.since).strftime("%d/%m/%Y")
    end = dt.datetime.fromtimestamp(brief.until).strftime("%d/%m/%Y")
    guild_line = (f"La guilde rivale s'appelle « {brief.rival_guild} » (le nom de la guilde peut être cité).\n"
                  if brief.rival_guild else "")
    return PROMPT.format(max_articles=MAX_ARTICLES, start=start, end=end, guild_line=guild_line,
                         facts="\n".join(f"{f.key}. {f.text}" for f in brief.facts))


def _extract_json(text: str) -> Any:
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("pas d'objet JSON dans la réponse")
    return json.loads(text[start:end + 1])


def check(brief: Brief, answer: str, edition: str) -> tuple[list[dict[str, Any]], list[str]]:
    """Reponse de l'IA -> (elements Press.lua, problemes). Un article douteux est rejete."""
    try:
        data = _extract_json(answer)
    except (ValueError, json.JSONDecodeError) as exc:
        return [], [f"réponse illisible : {exc}"]
    arts = data.get("articles") if isinstance(data, dict) else None
    if not isinstance(arts, list):
        return [], ["réponse sans liste « articles »"]
    facts = brief.by_key
    forbidden_re = _word_re(brief.forbidden)
    items, notes = [], []
    for n, a in enumerate(arts[:MAX_ARTICLES], 1):
        if not isinstance(a, dict):
            notes.append(f"article {n} : format invalide")
            continue
        title, body = str(a.get("title") or "").strip(), str(a.get("body") or "").strip()
        refs = [str(r).strip() for r in (a.get("refs") or []) if str(r).strip()]
        label = f"article {n} « {title[:40]} »"
        if not title or not body:
            notes.append(f"{label} : titre ou texte vide — rejeté")
            continue
        if len(title) > MAX_TITLE or len(body.encode("utf-8")) > MAX_BODY:
            notes.append(f"{label} : trop long — rejeté")
            continue
        unknown = [r for r in refs if r not in facts]
        if not refs or unknown:
            notes.append(f"{label} : sources absentes ou inventées ({', '.join(unknown) or 'aucune'}) — rejeté")
            continue
        if forbidden_re:
            hit = forbidden_re.search(title + "\n" + body)
            if hit:
                notes.append(f"{label} : nomme « {hit.group(1)} » (sans consentement ou rival) — rejeté")
                continue
        event_ids: list[str] = []
        for r in refs:
            for i in facts[r].refs:
                if i not in event_ids:
                    event_ids.append(i)
        digest = hashlib.sha1((title + "\0" + body).encode("utf-8")).hexdigest()[:10]
        items.append({
            "id": f"ia:{edition}:{digest}", "kind": "ARTICLE", "refs": event_ids[:40],
            "p": {"title": title, "body": body, "format": str(a.get("format") or "Brève")[:40],
                  "style": str(a.get("style") or "Rédaction")[:60], "ia": True, "edition": edition},
        })
    return items, notes
