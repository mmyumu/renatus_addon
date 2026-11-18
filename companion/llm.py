"""Calling the AI through an external command (default: Claude Code in non-interactive mode).

The prompt is written to the command's standard input; the answer is read from its output.
Command examples (config.toml, [llm] section):
  - Claude Code installed on this PC:
        command = ["claude", "-p", "--output-format", "json", "--tools", "", "--no-session-persistence"]
  - Claude Code on another machine (Raspberry Pi) over SSH (passwordless SSH key):
        command = ["ssh", "pi5", "cd /tmp && ~/.local/bin/claude -p --output-format json --tools '' --no-session-persistence"]
    (over SSH the remote command is a single string: the empty argument is written '' in it.)
The AI gets no tools (--tools ""): it only reads the prompt and answers.
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
    """Claude Code --output-format json output -> answer text; otherwise raw text."""
    text = out.strip()
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return text
    if isinstance(data, dict) and "result" in data and data.get("type") == "result":
        if data.get("is_error"):
            raise LLMError(f"erreur de l'IA : {str(data.get('result'))[:500]}")
        return str(data["result"])
    return text  # the command returned the articles JSON directly
