"""Appel de l'IA par une commande externe (par defaut : Claude Code en mode non interactif).

La demande est envoyee sur l'entree standard de la commande ; la reponse est lue sur sa sortie.
Exemples de commande (config.toml, section [llm]) :
  - Claude Code installe sur ce PC :
        command = ["claude", "-p", "--output-format", "json", "--tools", "", "--no-session-persistence"]
  - Claude Code sur une autre machine (Raspberry Pi) via SSH (cle SSH sans mot de passe) :
        command = ["ssh", "pi5", "cd /tmp && ~/.local/bin/claude -p --output-format json --tools '' --no-session-persistence"]
    (via SSH la commande distante est une seule chaine : l'argument vide s'ecrit '' dedans.)
Aucun outil n'est donne a l'IA (--tools "") : elle ne fait que lire la demande et repondre.
"""
from __future__ import annotations

import json
import subprocess
from typing import Any

DEFAULT_COMMAND = ["claude", "-p", "--output-format", "json", "--tools", "", "--no-session-persistence"]


class LLMError(RuntimeError):
    pass


def run(prompt: str, cfg: dict[str, Any]) -> str:
    command = cfg.get("command") or DEFAULT_COMMAND
    if isinstance(command, str):
        raise LLMError("[llm] command doit être une liste, ex. [\"claude\", \"-p\", ...]")
    timeout = float(cfg.get("timeout", 600))
    try:
        proc = subprocess.run(command, input=prompt.encode("utf-8"), capture_output=True, timeout=timeout)
    except FileNotFoundError as exc:
        raise LLMError(f"commande introuvable : {command[0]} ({exc})") from exc
    except subprocess.TimeoutExpired as exc:
        raise LLMError(f"pas de réponse après {timeout:.0f} s") from exc
    out = proc.stdout.decode("utf-8", errors="replace")
    err = proc.stderr.decode("utf-8", errors="replace").strip()
    if proc.returncode != 0:
        raise LLMError(f"la commande a échoué (code {proc.returncode}) : {(err or out)[-500:]}")
    return unwrap(out)


def unwrap(out: str) -> str:
    """Sortie --output-format json de Claude Code -> texte de la reponse ; sinon texte brut."""
    text = out.strip()
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return text
    if isinstance(data, dict) and "result" in data and data.get("type") == "result":
        if data.get("is_error"):
            raise LLMError(f"erreur de l'IA : {str(data.get('result'))[:500]}")
        return str(data["result"])
    return text  # la commande a directement renvoye le JSON des articles
