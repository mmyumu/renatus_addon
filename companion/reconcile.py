"""Fusion des sources : evenements de l'addon (SavedVariables) + journaux de combat.

Regles (docs/ARCHITECTURE.md §8.2) :
  - une mort du journal de combat ENRICHIT la mort enregistree par l'addon (meme personnage,
    meme instant a quelques secondes pres) : on ne cree jamais de mort qui n'existe pas ;
  - l'ecart d'horloge entre le PC et le serveur est estime sur les morts presentes des deux
    cotes (mediane), puis la correspondance se fait a +/- 5 s ;
  - affrontements PvP : seulement contre des personnages deja connus du registre
    (ENEMY_SEEN de la guilde rivale) et impliquant des membres connus de la guilde.
Tout ce qui sort d'ici est une PROPOSITION : le redacteur la valide en jeu.
"""
from __future__ import annotations

import statistics
from dataclasses import dataclass
from typing import Any

from .combatlog import Analysis, Death

ANCHOR_WINDOW = 300.0   # recherche des paires pour estimer le decalage
MATCH_WINDOW = 5.0


@dataclass
class Chronicle:
    """Vue minimale des SavedVariables de Guild Chronicle."""
    events: dict[str, dict[str, Any]]
    press_done: dict[str, str]

    @classmethod
    def from_saved(cls, saved: dict[str, Any]) -> "Chronicle":
        db = saved.get("GuildChronicleDB") or {}
        events = db.get("events") or {}
        if isinstance(events, list):  # ne devrait pas arriver (cles = identifiants)
            events = {e.get("id"): e for e in events if isinstance(e, dict)}
        return cls(events=events, press_done=db.get("pressDone") or {})

    def of_kind(self, kind: str) -> list[dict[str, Any]]:
        return [e for e in self.events.values() if isinstance(e, dict) and e.get("k") == kind]

    def members(self) -> dict[str, str]:
        """GUID -> nom des auteurs connus (membres equipes de l'addon)."""
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
    """Decalage (serveur - PC) en secondes, d'apres les morts presentes des deux cotes."""
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
    """Renvoie (elements pour Press.lua, avertissements)."""
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
            continue  # mort inconnue de l'addon (privee, ou membre sans addon) : on n'invente rien
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
