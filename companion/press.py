"""Writing Renatus_Press/Press.lua, read by the addon on every /reload.

The file is merged with the existing one (deterministic ids: no duplicates) and cleared of
items already published or ignored in game (pressDone in the SavedVariables).
Atomic write: temporary file then replace.
"""
from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Any

from . import luadata

HEADER = ("-- File written by the companion app (companion/). Do not edit by hand:\n"
          "-- it is replaced on every companion run.\n")


def read_items(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        data = luadata.load(path).get("RenatusPress") or {}
    except luadata.LuaParseError:
        return []
    items = data.get("items") or []
    return [i for i in items if isinstance(i, dict) and "id" in i]


def merge(existing: list[dict[str, Any]], new: list[dict[str, Any]], done: dict[str, str]) -> list[dict[str, Any]]:
    by_id: dict[str, dict[str, Any]] = {}
    for item in existing + new:
        by_id[item["id"]] = item  # the most recent wins (corrected text, for instance)
    kept = [i for i in by_id.values() if i["id"] not in done]
    kept.sort(key=lambda i: (i.get("t") or 0, i["id"]))
    return kept


def write(path: Path, items: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    content = HEADER + luadata.dumps({
        "RenatusPress": {"version": 1, "generated": int(time.time()), "items": items},
    })
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)
    os.replace(tmp, path)
