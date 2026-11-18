"""Lecture des journaux de combat (Logs/WoWCombatLog*.txt) ecrits par le client avec /combatlog.

Le fichier n'est lu qu'APRES coup, depuis le disque : aucun lien avec le processus du jeu.
On n'extrait que le strict necessaire :
  - morts de joueurs (UNIT_DIED) avec le dernier coup recu (cause) ;
  - coups fatals (PARTY_KILL) : qui a acheve qui.
Les horodatages du fichier sont en heure locale (avec, sur les clients recents, le decalage
UTC en heures en suffixe : "-5", "+1"...).
"""
from __future__ import annotations

import datetime as _dt
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Iterator

_LINE = re.compile(
    r"^(?P<mo>\d{1,2})/(?P<d>\d{1,2})(?:/(?P<y>\d{4}))?\s+"
    r"(?P<h>\d{1,2}):(?P<mi>\d{2}):(?P<s>\d{2})(?:\.(?P<ms>\d{1,4}))?"
    r"(?P<tz>[+-]\d{1,2})?\s{2}(?P<rest>.*)$"
)

DAMAGE_EVENTS = {
    "SWING_DAMAGE", "RANGE_DAMAGE", "SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE",
    "SPELL_BUILDING_DAMAGE", "DAMAGE_SPLIT", "ENVIRONMENTAL_DAMAGE",
}
ENVIRONMENT = {
    "Falling": "chute", "Drowning": "noyade", "Fatigue": "épuisement",
    "Fire": "feu", "Lava": "lave", "Slime": "vase",
}
CAUSE_WINDOW = 10.0     # le dernier coup doit dater de moins de 10 s avant la mort
KILL_WINDOW = 1.5       # PARTY_KILL et UNIT_DIED quasi simultanes


@dataclass
class LogEvent:
    ts: float
    event: str
    fields: list[str]

    def get(self, i: int) -> str | None:
        return self.fields[i] if i < len(self.fields) else None


@dataclass
class Death:
    ts: float
    guid: str
    name: str
    source: str | None = None          # dernier attaquant (nom sans royaume)
    source_guid: str | None = None
    spell: str | None = None
    environment: str | None = None     # libelle francais (chute, noyade...)
    killer: str | None = None          # coup fatal (PARTY_KILL), si connu
    killer_guid: str | None = None

    @property
    def cause(self) -> str:
        if self.environment:
            return self.environment
        who = self.killer or self.source
        if not who:
            return "cause indéterminée"
        if self.spell:
            return f"{who} ({self.spell})"
        return who

    @property
    def by_player(self) -> bool:
        guid = self.killer_guid or self.source_guid or ""
        return guid.startswith("Player-")


@dataclass
class Kill:
    ts: float
    killer: str
    killer_guid: str
    victim: str
    victim_guid: str


@dataclass
class Analysis:
    deaths: list[Death] = field(default_factory=list)
    kills: list[Kill] = field(default_factory=list)
    lines: int = 0
    skipped: int = 0


def split_fields(rest: str) -> list[str]:
    """Decoupe sur les virgules en respectant guillemets, crochets et parentheses."""
    out, cur, depth, quoted = [], [], 0, False
    for ch in rest:
        if quoted:
            if ch == '"':
                quoted = False
            else:
                cur.append(ch)
            continue
        if ch == '"':
            quoted = True
        elif ch in "[(":
            depth += 1
            cur.append(ch)
        elif ch in "])":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur).rstrip("\r\n"))
    return out


def parse_timestamp(m: re.Match, default_year: int) -> float:
    year = int(m.group("y") or default_year)
    ms = m.group("ms") or "0"
    micro = int(ms.ljust(6, "0")[:6])
    naive = _dt.datetime(year, int(m.group("mo")), int(m.group("d")),
                         int(m.group("h")), int(m.group("mi")), int(m.group("s")), micro)
    tz = m.group("tz")
    if tz is not None:
        return naive.replace(tzinfo=_dt.timezone(_dt.timedelta(hours=int(tz)))).timestamp()
    return naive.timestamp()  # heure locale du PC (celui qui a ecrit le fichier)


def parse_line(line: str, default_year: int) -> LogEvent | None:
    m = _LINE.match(line)
    if not m:
        return None
    fields = split_fields(m.group("rest"))
    if not fields:
        return None
    return LogEvent(parse_timestamp(m, default_year), fields[0], fields[1:])


def short_name(name: str | None) -> str | None:
    if not name or name == "nil":
        return None
    return name.split("-", 1)[0]


def iter_events(lines: Iterable[str], default_year: int | None = None) -> Iterator[LogEvent]:
    year = default_year or _dt.date.today().year
    for line in lines:
        ev = parse_line(line, year)
        if ev:
            yield ev


def analyse(events: Iterable[LogEvent]) -> Analysis:
    """Morts de joueurs avec cause, et coups fatals sur des joueurs."""
    result = Analysis()
    last_hit: dict[str, tuple[float, str | None, str | None, str | None, str | None]] = {}
    last_kill: dict[str, Kill] = {}
    for ev in events:
        result.lines += 1
        e, f = ev.event, ev.fields
        # f : 0 srcGUID, 1 srcName, 2 srcFlags, 3 srcRaidFlags, 4 dstGUID, 5 dstName, 6 dstFlags, 7 dstRaidFlags, 8.. suite
        if len(f) < 8:
            result.skipped += 1
            continue
        dst_guid = f[4]
        if not dst_guid.startswith("Player-"):
            continue  # seules les morts de joueurs nous interessent
        if e in DAMAGE_EVENTS:
            spell = env = None
            if e == "ENVIRONMENTAL_DAMAGE":
                env = next((ENVIRONMENT[x] for x in f[8:] if x in ENVIRONMENT), "environnement")
            elif e == "SWING_DAMAGE":
                spell = "mêlée"
            else:
                spell = ev.get(9)
            last_hit[dst_guid] = (ev.ts, short_name(f[1]), f[0] if f[0] != "0000000000000000" else None, spell, env)
        elif e == "PARTY_KILL":
            k = Kill(ev.ts, short_name(f[1]) or "?", f[0], short_name(f[5]) or "?", dst_guid)
            last_kill[dst_guid] = k
            if f[0].startswith("Player-"):
                result.kills.append(k)
        elif e == "UNIT_DIED":
            d = Death(ev.ts, dst_guid, short_name(f[5]) or "?")
            hit = last_hit.pop(dst_guid, None)
            if hit and ev.ts - hit[0] <= CAUSE_WINDOW:
                d.source, d.source_guid, d.spell, d.environment = hit[1], hit[2], hit[3], hit[4]
            k = last_kill.pop(dst_guid, None)
            if k and abs(ev.ts - k.ts) <= KILL_WINDOW:
                d.killer, d.killer_guid = k.killer, k.killer_guid
            result.deaths.append(d)
    return result


def analyse_file(path: Path, default_year: int | None = None) -> Analysis:
    if default_year is None:
        default_year = _dt.datetime.fromtimestamp(path.stat().st_mtime).year
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return analyse(iter_events(f, default_year))
