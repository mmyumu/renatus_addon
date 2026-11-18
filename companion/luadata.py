"""Reading and writing Lua literals (WoW SavedVariables files, Press.lua).

Only the subset used by WoW is supported: global assignments `Name = value`, tables,
strings, numbers, booleans, nil and comments. No Lua code is ever executed.
Tables whose keys are exactly 1..n become Python lists.
"""
from __future__ import annotations

import re
from typing import Any

_NUMBER = re.compile(r"-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)")
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class LuaParseError(ValueError):
    pass


class _Parser:
    def __init__(self, text: str):
        self.s = text
        self.i = 0

    def error(self, msg: str) -> LuaParseError:
        line = self.s.count("\n", 0, self.i) + 1
        return LuaParseError(f"{msg} (ligne {line})")

    def skip(self) -> None:
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                if s.startswith("--[[", self.i):
                    end = s.find("]]", self.i)
                    self.i = len(s) if end < 0 else end + 2
                else:
                    end = s.find("\n", self.i)
                    self.i = len(s) if end < 0 else end + 1
            else:
                break

    def peek(self) -> str:
        self.skip()
        return self.s[self.i] if self.i < len(self.s) else ""

    def expect(self, ch: str) -> None:
        if self.peek() != ch:
            raise self.error(f"'{ch}' attendu")
        self.i += 1

    def string(self) -> str:
        quote = self.s[self.i]
        self.i += 1
        out = bytearray()
        s = self.s
        while True:
            if self.i >= len(s):
                raise self.error("chaine non terminee")
            c = s[self.i]
            if c == quote:
                self.i += 1
                return out.decode("utf-8", errors="replace")
            if c == "\\":
                self.i += 1
                e = s[self.i]
                simple = {"n": 10, "t": 9, "r": 13, "a": 7, "b": 8, "f": 12, "v": 11,
                          "\\": 92, '"': 34, "'": 39, "\n": 10}
                if e in simple:
                    out.append(simple[e])
                    self.i += 1
                elif e.isdigit():
                    m = re.match(r"\d{1,3}", s[self.i:])
                    out.append(int(m.group(0)) & 0xFF)
                    self.i += len(m.group(0))
                else:
                    raise self.error(f"echappement inconnu \\{e}")
            else:
                out.extend(c.encode("utf-8"))
                self.i += 1

    def value(self) -> Any:
        c = self.peek()
        if c in "\"'":
            return self.string()
        if c == "{":
            return self.table()
        m = _NUMBER.match(self.s, self.i)
        if m and m.group(0) not in ("-",):
            text = m.group(0)
            self.i = m.end()
            if text.lower().startswith(("0x", "-0x")):
                return int(text, 16)
            if re.fullmatch(r"-?\d+", text):
                return int(text)
            return float(text)
        m = _NAME.match(self.s, self.i)
        if m:
            word = m.group(0)
            self.i = m.end()
            if word == "true":
                return True
            if word == "false":
                return False
            if word == "nil":
                return None
            raise self.error(f"identifiant inattendu {word}")
        raise self.error("valeur attendue")

    def table(self) -> Any:
        self.expect("{")
        result: dict[Any, Any] = {}
        n = 0
        while True:
            c = self.peek()
            if c == "}":
                self.i += 1
                break
            if c == "[":
                self.i += 1
                key = self.value()
                self.expect("]")
                self.expect("=")
                result[key] = self.value()
            else:
                m = _NAME.match(self.s, self.i)
                save = self.i
                if m:
                    self.i = m.end()
                    if self.peek() == "=":
                        self.i += 1
                        result[m.group(0)] = self.value()
                    else:
                        self.i = save
                        n += 1
                        result[n] = self.value()
                else:
                    n += 1
                    result[n] = self.value()
            if self.peek() in ",;":
                self.i += 1
        # nil in a table = missing key
        result = {k: v for k, v in result.items() if v is not None}
        keys = list(result.keys())
        if keys and all(isinstance(k, int) and not isinstance(k, bool) for k in keys) \
                and sorted(keys) == list(range(1, len(keys) + 1)):
            return [result[i] for i in range(1, len(keys) + 1)]
        if not keys:
            return {}
        return result

    def assignments(self) -> dict[str, Any]:
        out: dict[str, Any] = {}
        while self.peek():
            m = _NAME.match(self.s, self.i)
            if not m:
                raise self.error("affectation attendue")
            self.i = m.end()
            self.expect("=")
            out[m.group(0)] = self.value()
        return out


def loads(text: str) -> dict[str, Any]:
    """Parses a SavedVariables file: {global_name: value}."""
    if text.startswith("﻿"):
        text = text[1:]
    return _Parser(text).assignments()


def load(path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return loads(f.read())


def _quote(s: str) -> str:
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif o < 32 or o == 127:
            out.append(f"\\{o:03d}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def dumps_value(v: Any, indent: int = 0) -> str:
    pad = "\t" * (indent + 1)
    if v is None:
        return "nil"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            raise ValueError("nombre non representable en Lua")
        return repr(v)
    if isinstance(v, str):
        return _quote(v)
    if isinstance(v, (list, tuple)):
        if not v:
            return "{}"
        items = [f"{pad}{dumps_value(x, indent + 1)}," for x in v]
        return "{\n" + "\n".join(items) + "\n" + "\t" * indent + "}"
    if isinstance(v, dict):
        if not v:
            return "{}"
        items = []
        for k in sorted(v.keys(), key=lambda k: (not isinstance(k, (int, float)), str(k))):
            if v[k] is None:
                continue
            key = f"[{k}]" if isinstance(k, (int, float)) and not isinstance(k, bool) else f"[{_quote(str(k))}]"
            items.append(f"{pad}{key} = {dumps_value(v[k], indent + 1)},")
        return "{\n" + "\n".join(items) + "\n" + "\t" * indent + "}"
    raise TypeError(f"type non serialisable : {type(v).__name__}")


def dumps(assignments: dict[str, Any]) -> str:
    return "".join(f"{name} = {dumps_value(value)}\n" for name, value in assignments.items())
