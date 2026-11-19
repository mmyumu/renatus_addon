"""Renatus companion CLI (python -m companion <command>). See HELP for the user-facing text."""
from __future__ import annotations

HELP = """Compagnon Renatus : python -m companion <commande> [options]

Commandes :
  status    ce que le compagnon voit (journal de l'addon, journaux de combat, presse en attente)
  facts     faits numerotes de la periode (pour ecrire un article a la main)
  deaths    causes de mort et affrontements PvP d'apres les journaux de combat -> Press.lua
  articles  articles .md du dossier articles/ -> Press.lua
  gazette   gazette de la semaine redigee par l'IA (faits partages + consentement) -> Press.lua
  run       deaths + articles (+ gazette si [llm] enabled = true et pas encore faite cette semaine)

Rien n'est publie automatiquement : apres /reload, le redacteur valide chaque element dans
l'onglet Gazette > Redaction. Le compagnon ne lit que des fichiers et n'ecrit que Press.lua.
"""

import argparse
import datetime as dt
import sys
import tomllib
from pathlib import Path

from . import articles as articles_mod
from . import combatlog, gazette, llm, luadata, press
from .reconcile import Chronicle, propose
from .wowfiles import WowPaths

HERE = Path(__file__).resolve().parent


def load_config(path: Path | None) -> dict:
    path = path or HERE / "config.toml"
    if path.is_file():
        with open(path, "rb") as f:
            return tomllib.load(f)
    return {}


def local_path(root: str) -> Path:
    """A Windows path ("C:/...") seen from WSL or Linux becomes /mnt/c/...; anything else is kept."""
    import os
    import re
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", root)
    if m and os.name != "nt":
        mounted = Path("/mnt") / m.group(1).lower() / m.group(2).replace("\\", "/")
        if mounted.parent.exists() or Path("/mnt", m.group(1).lower()).is_dir():
            return mounted
    return Path(root)


def build_paths(args, cfg) -> WowPaths:
    root = args.wow or cfg.get("wow_path")
    if not root:
        sys.exit("Indique le dossier du jeu : --wow \"C:/…/World of Warcraft/_forever_\" (ou wow_path dans config.toml).")
    return WowPaths(local_path(root), args.account or cfg.get("account"))


def load_chronicle(paths: WowPaths) -> Chronicle:
    return Chronicle.from_saved(luadata.load(paths.saved_variables))


def describe(e: dict) -> str:
    p = e.get("p") or {}
    k = e.get("k")
    zone = (e.get("loc") or {}).get("i") or (e.get("loc") or {}).get("z") or ""
    text = {
        "LEVEL_UP": lambda: f"atteint le niveau {p.get('lvl')}",
        "DEATH": lambda: "meurt" + (f" (ennemis présents, supposé : {', '.join(p['enemies'])})" if p.get("enemies") else ""),
        "BOSS_KILL": lambda: f"triomphe de {p.get('name') or p.get('enc')}",
        "QUEST_DONE": lambda: f"termine la quête « {p.get('title') or p.get('q')} »",
        "ZONE_FIRST_VISIT": lambda: f"découvre {zone}",
        "EXPEDITION": lambda: f"expédition {p.get('type', '')} {p.get('inst') or zone} ({int(p.get('duration', 0)) // 60} min, "
                              f"{p.get('bosses', 0)} boss, {p.get('deaths', 0)} mort(s))",
        "ENEMY_SEEN": lambda: f"aperçoit {p.get('name')} <{p.get('guild')}>",
        "PVP_CLASH": lambda: f"{'l emporte face à' if p.get('result') == 'win' else 'tombe face à'} {p.get('name')}",
        "ANECDOTE": lambda: f"anecdote : {p.get('title')} — {p.get('desc', '')}",
        "WANTED": lambda: f"avis de recherche contre {p.get('name')} : {p.get('reason', '')}",
        "DEATH_CAUSE": lambda: f"cause de la mort de {p.get('victim')} : {p.get('cause')}",
    }.get(k, lambda: k)()
    return f"{e.get('n', '?')} {text}" + (f" [{zone}]" if zone and k != "ZONE_FIRST_VISIT" else "")


def cmd_status(paths: WowPaths, args) -> int:
    print(f"Dossier du jeu : {paths.root}")
    try:
        sv = paths.saved_variables
    except FileNotFoundError as exc:
        print(exc)
        return 1
    ch = load_chronicle(paths)
    public = [e for e in ch.events.values() if e.get("vis") == "G"]
    print(f"Journal de l'addon : {sv}")
    print(f"  {len(ch.events)} événement(s), dont {len(public)} partagé(s) ; {len(ch.members())} auteur(s)")
    if ch.events:
        last = max(float(e.get("t", 0)) for e in ch.events.values())
        print(f"  dernier : {dt.datetime.fromtimestamp(last):%d/%m/%Y %H:%M} (le fichier est réécrit à chaque /reload ou déconnexion)")
    logs = paths.combat_logs()
    print(f"Journaux de combat : {len(logs)} dans {paths.logs}" + ("" if logs else " (tape /combatlog en jeu pour en créer)"))
    pending = press.merge(press.read_items(paths.press), [], ch.press_done)
    print(f"Presse en attente de validation en jeu : {len(pending)} ({paths.press})")
    return 0


def cmd_facts(paths: WowPaths, args) -> int:
    ch = load_chronicle(paths)
    since = dt.datetime.now().timestamp() - args.days * 86400
    events = sorted((e for e in ch.events.values()
                     if e.get("vis") == "G" and float(e.get("t", 0)) >= since and e.get("k") not in ("VOTE",)),
                    key=lambda e: e["t"])
    if not events:
        print(f"Aucun événement partagé sur les {args.days} derniers jours.")
        return 0
    print(f"Faits partagés des {args.days} derniers jours (provenance entre crochets) :\n")
    for n, e in enumerate(events, 1):
        when = dt.datetime.fromtimestamp(float(e["t"])).strftime("%d/%m %H:%M")
        print(f"{n:3d}. {when}  {describe(e)}  [{e.get('prov', 'OBS')}]  id={e['id']}")
    print("\nCite les identifiants dans la ligne « refs: » de ton article.")
    return 0


def _publish(paths: WowPaths, ch: Chronicle, items: list, dry_run: bool) -> None:
    merged = press.merge(press.read_items(paths.press), items, ch.press_done)
    if dry_run:
        print(f"(simulation) {len(merged)} élément(s) seraient écrits dans {paths.press}")
        return
    press.write(paths.press, merged)
    print(f"{len(merged)} élément(s) en attente dans {paths.press}")
    print("En jeu : /reload, puis Gazette > Rédaction pour publier ou ignorer.")


def gather_deaths(paths: WowPaths, ch: Chronicle, args) -> list:
    logs = [Path(args.log)] if getattr(args, "log", None) else paths.combat_logs()
    if not logs:
        print("Aucun journal de combat (tape /combatlog en jeu avant de jouer).")
        return []
    items = []
    for log in logs:
        analysis = combatlog.analyse_file(log)
        found, notes = propose(analysis, ch)
        print(f"{log.name} : {len(analysis.deaths)} mort(s) de joueur, {len(analysis.kills)} coup(s) fatal(s) "
              f"sur des joueurs -> {len(found)} proposition(s)")
        for n in notes:
            print("  " + n)
        items.extend(found)
    return items


def gather_articles(paths: WowPaths, ch: Chronicle, args) -> list:
    folder = Path(args.dir) if getattr(args, "dir", None) else HERE / "articles"
    if not folder.is_dir():
        print(f"Pas de dossier d'articles ({folder}).")
        return []
    public = {i for i, e in ch.events.items() if e.get("vis") == "G"}
    found, notes = articles_mod.load_dir(folder, public)
    for n in notes:
        print("  " + n)
    print(f"{len(found)} article(s) dans {folder}")
    return [a.to_item() for a in found]


def edition_key(until: float) -> str:
    year, week, _ = dt.date.fromtimestamp(until).isocalendar()
    return f"{year}-S{week:02d}"


def edition_done(paths: WowPaths, ch: Chronicle, edition: str) -> bool:
    prefix = f"ia:{edition}:"
    pending = press.read_items(paths.press)
    return any(i.startswith(prefix) for i in ch.press_done) or any(i["id"].startswith(prefix) for i in pending)


def gather_gazette(paths: WowPaths, ch: Chronicle, args, cfg: dict, auto: bool = False) -> list:
    until = dt.datetime.now().timestamp()
    since = until - getattr(args, "days", 7) * 86400
    edition = edition_key(until)
    if auto and edition_done(paths, ch, edition):
        print(f"Gazette IA : édition {edition} déjà rédigée (python -m companion gazette pour en refaire une).")
        return []
    brief = gazette.build(ch, since, until)
    total = len(ch.members())
    print(f"Gazette IA {edition} : {len(brief.allowed)} membre(s) consentant(s) sur {total} équipé(s) de l'addon ; "
          f"{len(brief.facts)} fait(s) retenu(s).")
    for reason, n in brief.excluded.most_common():
        print(f"  écarté : {n} × {reason}")
    if not brief.facts:
        print("  Rien à raconter (ou personne n'a coché « La gazette IA peut parler de moi » en jeu).")
        return []
    text = gazette.prompt(brief)
    if getattr(args, "show", False):
        print("\n----- demande qui serait envoyée à l'IA -----\n" + text)
        return []
    print("  rédaction en cours (cela peut prendre une ou deux minutes)…")
    try:
        answer = llm.run(text, cfg.get("llm") or {})
    except llm.LLMError as exc:
        print(f"  IA indisponible : {exc}")
        return []
    items, notes = gazette.check(brief, answer, edition)
    for n in notes:
        print("  " + n)
    print(f"  {len(items)} article(s) proposé(s).")
    return items


def cmd_gazette(paths, args, cfg) -> int:
    ch = load_chronicle(paths)
    items = gather_gazette(paths, ch, args, cfg)
    if items or not args.show:
        _publish(paths, ch, items, args.dry_run)
    return 0


def cmd_deaths(paths, args) -> int:
    ch = load_chronicle(paths)
    _publish(paths, ch, gather_deaths(paths, ch, args), args.dry_run)
    return 0


def cmd_articles(paths, args) -> int:
    ch = load_chronicle(paths)
    _publish(paths, ch, gather_articles(paths, ch, args), args.dry_run)
    return 0


def cmd_run(paths, args, cfg) -> int:
    ch = load_chronicle(paths)
    items = gather_deaths(paths, ch, args) + gather_articles(paths, ch, args)
    if (cfg.get("llm") or {}).get("enabled"):
        items += gather_gazette(paths, ch, args, cfg, auto=True)
    _publish(paths, ch, items, args.dry_run)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="python -m companion", description=HELP,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--wow", help="dossier _forever_ du jeu")
    parser.add_argument("--account", help="nom du dossier de compte sous WTF/Account")
    parser.add_argument("--config", type=Path, help="fichier de configuration (défaut : companion/config.toml)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    f = sub.add_parser("facts")
    f.add_argument("--days", type=int, default=7)
    g = sub.add_parser("gazette")
    g.add_argument("--days", type=int, default=7, help="période couverte (défaut : 7 jours)")
    g.add_argument("--show", action="store_true", help="affiche la demande qui serait envoyée, sans appeler l'IA")
    g.add_argument("--dry-run", action="store_true", help="appelle l'IA mais n'écrit rien")
    for name in ("deaths", "articles", "run"):
        p = sub.add_parser(name)
        p.add_argument("--dry-run", action="store_true", help="n'écrit rien")
        if name in ("deaths", "run"):
            p.add_argument("--log", help="un fichier de journal précis (défaut : tous ceux du dossier Logs)")
        if name in ("articles", "run"):
            p.add_argument("--dir", help="dossier des articles .md (défaut : companion/articles)")
    args = parser.parse_args(argv)
    cfg = load_config(args.config)
    paths = build_paths(args, cfg)
    try:
        if args.cmd in ("gazette", "run"):
            return {"gazette": cmd_gazette, "run": cmd_run}[args.cmd](paths, args, cfg)
        return {"status": cmd_status, "facts": cmd_facts, "deaths": cmd_deaths,
                "articles": cmd_articles}[args.cmd](paths, args)
    except FileNotFoundError as exc:
        print(exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
