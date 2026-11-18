"""Ecriture de GuildChronicle_Press/Press.lua, lu par l'addon a chaque /reload.

Le fichier est fusionne avec l'existant (identifiants deterministes : pas de doublon) et
debarrasse des elements deja publies ou ignores en jeu (pressDone dans les SavedVariables).
Ecriture atomique : fichier temporaire puis remplacement.
"""
from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Any

from . import luadata

HEADER = ("-- Fichier ecrit par l'application compagnon (companion/). Ne pas modifier a la main :\n"
          "-- il est remplace a chaque passage du compagnon.\n")


def read_items(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        data = luadata.load(path).get("GuildChroniclePress") or {}
    except luadata.LuaParseError:
        return []
    items = data.get("items") or []
    return [i for i in items if isinstance(i, dict) and "id" in i]


def merge(existing: list[dict[str, Any]], new: list[dict[str, Any]], done: dict[str, str]) -> list[dict[str, Any]]:
    by_id: dict[str, dict[str, Any]] = {}
    for item in existing + new:
        by_id[item["id"]] = item  # le plus recent l'emporte (texte corrige, par exemple)
    kept = [i for i in by_id.values() if i["id"] not in done]
    kept.sort(key=lambda i: (i.get("t") or 0, i["id"]))
    return kept


def write(path: Path, items: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    content = HEADER + luadata.dumps({
        "GuildChroniclePress": {"version": 1, "generated": int(time.time()), "items": items},
    })
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)
    os.replace(tmp, path)
