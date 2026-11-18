"""Merging sources: addon events (SavedVariables) + combat logs.

Rules (docs/ARCHITECTURE.md §8.2):
  - a combat log death ENRICHES the death recorded by the addon (same character, same
    moment within a few seconds): a death that does not exist is never created;
  - the clock offset between the PC and the server is estimated from deaths present on both
    sides (median), then matching is done within +/- 5 s;
  - PvP clashes: only against characters already known to the registry (rival guild
    ENEMY_SEEN) and involving known guild members.
Everything produced here is a PROPOSAL: the editor approves it in game.
"""
from __future__ import annotations

import statistics
from dataclasses import dataclass
from typing import Any

from .combatlog import Analysis, Death

ANCHOR_WINDOW = 300.0   # pairing window used to estimate the offset
MATCH_WINDOW = 5.0


@dataclass
class Chronicle:
    """Minimal view of the Renatus SavedVariables."""
    events: dict[str, dict[str, Any]]
    press_done: dict[str, str]

    @classmethod
    def from_saved(cls, saved: dict[str, Any]) -> "Chronicle":
        db = saved.get("RenatusDB") or {}
        events = db.get("events") or {}
        if isinstance(events, list):  # should not happen (keys = ids)
            events = {e.get("id"): e for e in events if isinstance(e, dict)}
        return cls(events=events, press_done=db.get("pressDone") or {})

    def of_kind(self, kind: str) -> list[dict[str, Any]]:
        return [e for e in self.events.values() if isinstance(e, dict) and e.get("k") == kind]

    def members(self) -> dict[str, str]:
        """GUID -> name of known authors (members who have the addon)."""
        return {e["a"]: e.get("n", "?") for e in self.events.values() if isinstance(e, dict) and "a" in e}

    def known_enemies(self) -> set[str]:
        names = set()
        for kind in ("ENEMY_SEEN", "ENEMY_NOTE", "WANTED", "PVP_CLASH"):
            for e in self.of_kind(kind):
                name = (e.get("p") or {}).get("name")
                if name:
                    names.add(name.lower())
        return names

    def enriched_deaths(self) -> set[str]:
        return {r for e in self.of_kind("DEATH_CAUSE") for r in (e.get("refs") or [])}


def estimate_offset(deaths: list[Death], chronicle: Chronicle) -> float | None:
    """Offset (server - PC) in seconds, from deaths present on both sides."""
    by_author: dict[str, list[float]] = {}
    for e in chronicle.of_kind("DEATH"):
        by_author.setdefault(e.get("a", ""), []).append(float(e.get("t", 0)))
    diffs = []
    for d in deaths:
        candidates = by_author.get(d.guid, [])
        best = min(candidates, key=lambda t: abs(t - d.ts), default=None)
        if best is not None and abs(best - d.ts) <= ANCHOR_WINDOW:
            diffs.append(best - d.ts)
    if not diffs:
        return None
    return statistics.median(diffs)


def propose(analysis: Analysis, chronicle: Chronicle) -> tuple[list[dict[str, Any]], list[str]]:
    """Returns (items for Press.lua, warnings)."""
    items: list[dict[str, Any]] = []
    notes: list[str] = []
    offset = estimate_offset(analysis.deaths, chronicle)
    if offset is None:
        notes.append("Aucune mort commune entre le journal de combat et l'addon : pas de recalage possible.")
        offset = 0.0
    elif abs(offset) > 2:
        notes.append(f"Décalage d'horloge estimé : {offset:+.1f} s (corrigé).")

    deaths_by_author: dict[str, list[dict[str, Any]]] = {}
    for e in chronicle.of_kind("DEATH"):
        deaths_by_author.setdefault(e.get("a", ""), []).append(e)
    already = chronicle.enriched_deaths()
    enemies = chronicle.known_enemies()
    members = chronicle.members()
    used: set[str] = set()

    for d in analysis.deaths:
        t = d.ts + offset
        candidates = [e for e in deaths_by_author.get(d.guid, []) if abs(float(e.get("t", 0)) - t) <= MATCH_WINDOW]
        match = min(candidates, key=lambda e: abs(float(e["t"]) - t), default=None)
        if match is None:
            continue  # death unknown to the addon (private, or member without the addon): invent nothing
        if match["id"] in already or match["id"] in used:
            continue
        used.add(match["id"])
        items.append({
            "id": "dc:" + match["id"], "kind": "DEATH_CAUSE", "t": int(match["t"]), "refs": [match["id"]],
            "p": {k: v for k, v in {
                "victim": match.get("n") or d.name, "cause": d.cause, "killer": d.killer or d.source,
                "spell": d.spell, "env": d.environment,
            }.items() if v},
        })
        who = (d.killer or d.source or "").lower()
        if d.by_player and who in enemies:
            items.append({
                "id": "pl:" + match["id"], "kind": "PVP_CLASH", "t": int(match["t"]), "refs": [match["id"]],
                "p": {"name": d.killer or d.source, "enemy": d.killer or d.source, "result": "loss",
                      "member": match.get("n") or d.name, **({"spell": d.spell} if d.spell else {})},
            })

    for k in analysis.kills:
        if k.killer_guid in members and k.victim.lower() in enemies:
            t = int(k.ts + offset)
            items.append({
                "id": f"pw:{k.killer_guid}:{t}", "kind": "PVP_CLASH", "t": t,
                "p": {"name": k.victim, "enemy": k.victim, "result": "win", "member": members[k.killer_guid]},
            })
    return items, notes
