"""Articles ecrits a la main par le redacteur (dossier articles/, un fichier .md par article).

Format :
    ---
    title: Une expédition réussie
    format: Édition spéciale
    style: Journaliste sarcastique
    refs: Player-1-ABC:12, Player-1-DEF:4
    ---
    Corps de l'article...

Les `refs` sont les identifiants des evenements cites (commande `facts`). Elles sont verifiees :
un article qui cite un evenement inconnu est signale. Le texte n'est jamais modifie.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

MAX_BODY = 3500  # octets : environ 15 messages d'addon


@dataclass
class Article:
    path: Path
    title: str
    body: str
    format: str = "Brève"
    style: str = "Rédaction"
    refs: list[str] = field(default_factory=list)

    @property
    def id(self) -> str:
        digest = hashlib.sha1((self.title + "\0" + self.body).encode("utf-8")).hexdigest()[:12]
        return f"art:{self.path.stem}:{digest}"

    def to_item(self) -> dict[str, Any]:
        item: dict[str, Any] = {"id": self.id, "kind": "ARTICLE",
                                "p": {"title": self.title, "body": self.body, "format": self.format, "style": self.style}}
        if self.refs:
            item["refs"] = list(self.refs)
        return item


def parse(path: Path) -> Article:
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    meta: dict[str, str] = {}
    body = text
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end < 0:
            raise ValueError(f"{path.name} : en-tête non fermé")
        for line in text[4:end].splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                meta[k.strip().lower()] = v.strip()
        body = text[end + 4:].lstrip("\n")
    title = meta.get("title") or meta.get("titre")
    if not title:
        raise ValueError(f"{path.name} : titre manquant (title: ...)")
    refs = [r.strip() for r in (meta.get("refs") or meta.get("sources") or "").split(",") if r.strip()]
    return Article(path, title, body.strip(), meta.get("format", "Brève"), meta.get("style", "Rédaction"), refs)


def load_dir(folder: Path, known_ids: set[str]) -> tuple[list[Article], list[str]]:
    articles, notes = [], []
    for path in sorted(folder.glob("*.md")):
        try:
            a = parse(path)
        except (ValueError, OSError) as exc:
            notes.append(str(exc))
            continue
        if len(a.body.encode("utf-8")) > MAX_BODY:
            notes.append(f"{path.name} : trop long ({len(a.body.encode('utf-8'))} octets, max {MAX_BODY}) — ignoré.")
            continue
        unknown = [r for r in a.refs if r not in known_ids]
        if unknown:
            notes.append(f"{path.name} : source(s) inconnue(s) ou privée(s) dans ton journal : {', '.join(unknown)}")
        articles.append(a)
    return articles, notes
