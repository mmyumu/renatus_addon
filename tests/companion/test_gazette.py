"""Gazette IA : consentement, alias des rivaux, verification des reponses (sans vraie IA)."""
import io
import json
import shutil
import sys
import tempfile
import textwrap
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from companion import gazette, llm, luadata, press
from companion.__main__ import main
from companion.reconcile import Chronicle

ME, BOB, ZOE = "Player-1-ABC", "Player-1-BBB", "Player-1-ZZZ"
G = "Les Testeurs-Forever"
NOW = time.time()


def ev(author, name, seq, kind, ago_h, p=None, **extra):
    e = {"id": f"{author}:{seq}", "a": author, "n": name, "s": seq, "k": kind, "t": int(NOW - ago_h * 3600),
         "vis": "G", "g": G, "p": p or {}, "prov": "OBS", "loc": {"z": "Elwynn"}}
    e.update(extra)
    return e


def saved(consent_bob=False):
    events = [
        ev(ME, "Testeur", 1, "AI_CONSENT", 100, {"ok": True}, prov="MAN"),
        ev(ZOE, "Zoe", 1, "AI_CONSENT", 100, {"ok": True}, prov="MAN"),
        ev(ZOE, "Zoe", 2, "AI_CONSENT", 90, {"ok": False}, prov="MAN"),   # retrait : le dernier compte
        ev(ME, "Testeur", 2, "ENEMY_SEEN", 50, {"name": "Gorbash", "guild": "Les Crocs", "class": "ROGUE", "race": "Orc"}),
        ev(ME, "Testeur", 3, "DEATH", 49, {"enemies": ["Gorbash"]}, ded=["enemies"]),
        ev(ME, "Testeur", 4, "EXPEDITION", 30, {"type": "DUNGEON", "inst": "Les Mortemines", "duration": 3600,
                                                 "bosses": 5, "deaths": 2},
           pt=[{"g": ME, "n": "Testeur"}, {"g": BOB, "n": "Bob"}]),
        ev(ME, "Testeur", 5, "ANECDOTE", 20, {"title": "Le pont", "desc": "Bob a sauté du pont"}, prov="MAN"),
        ev(ME, "Testeur", 6, "PVP_CLASH", 10, {"name": "Gorbash", "result": "win", "member": "Testeur"}, prov="MAN"),
        ev(ME, "Testeur", 7, "LEVEL_UP", 5, {"lvl": 42}, vis="P", id=f"{ME}:p1"),  # prive : jamais envoye
        ev(BOB, "Bob", 1, "LEVEL_UP", 4, {"lvl": 30}),
        ev(ZOE, "Zoe", 3, "BOSS_KILL", 3, {"name": "VanCleef"}),
        ev(ME, "Testeur", 8, "LEVEL_UP", 400, {"lvl": 41}),  # hors periode
    ]
    if consent_bob:
        events.append(ev(BOB, "Bob", 2, "AI_CONSENT", 100, {"ok": True}, prov="MAN"))
    return {"GuildChronicleDB": {"events": {e["id"]: e for e in events}, "pressDone": {}}}


def brief(**kw):
    return gazette.build(Chronicle.from_saved(saved(**kw)), NOW - 7 * 86400, NOW + 1)


class BuildTests(unittest.TestCase):
    def test_consent_and_rivals(self):
        b = brief()
        text = gazette.prompt(b)
        self.assertEqual(b.allowed, {"Testeur"})
        self.assertNotIn("Bob", text, "membre sans consentement jamais envoye")
        self.assertNotIn("Zoe", text, "consentement retire")
        self.assertNotIn("VanCleef", text)
        self.assertNotIn("Gorbash", text, "rival jamais nomme")
        self.assertIn("Rival A (voleur Orc)", text)
        self.assertIn("Les Mortemines", text)
        self.assertIn("+1 autre(s) participant(s)", text, "Bob compte sans etre nomme")
        self.assertIn("selon Testeur (déclaré, non vérifié)", text, "victoire manuelle non presentee comme verifiee")
        self.assertIn("supposé", text)
        self.assertNotIn("niveau 42", text, "evenement prive")
        self.assertNotIn("niveau 41", text, "hors periode")
        self.assertNotIn("pont", text, "anecdote qui nomme Bob retiree")
        self.assertGreaterEqual(b.excluded["nomme un membre sans consentement"], 1)

    def test_bob_consents(self):
        text = gazette.prompt(brief(consent_bob=True))
        self.assertIn("Bob", text)
        self.assertIn("niveau 30", text)


class CheckTests(unittest.TestCase):
    def answer(self, *arts):
        return "Voici :\n" + json.dumps({"articles": list(arts)}, ensure_ascii=False)

    def test_validation(self):
        b = brief()
        keys = [f.key for f in b.facts]
        good = {"title": "Les Mortemines tremblent", "body": "Testeur a encore frappé.", "refs": [keys[0], keys[1]],
                "format": "Une", "style": "épique"}
        items, notes = gazette.check(b, self.answer(
            good,
            {"title": "Invention", "body": "x", "refs": ["F999"]},
            {"title": "Indiscret", "body": "Bob et Gorbash complotent", "refs": [keys[0]]},
            {"title": "Sans source", "body": "x", "refs": []},
        ), "2026-S47")
        self.assertEqual(len(items), 1, notes)
        self.assertEqual(len(notes), 3)
        it = items[0]
        self.assertTrue(it["id"].startswith("ia:2026-S47:"))
        self.assertTrue(it["p"]["ia"])
        self.assertTrue(all(r.startswith(ME) for r in it["refs"]), "refs = vrais identifiants d'evenements")
        self.assertEqual(gazette.check(b, "pas de json", "x")[0], [])

    def test_unwrap(self):
        self.assertEqual(llm.unwrap(json.dumps({"type": "result", "result": "{\"a\":1}"})), "{\"a\":1}")
        with self.assertRaises(llm.LLMError):
            llm.unwrap(json.dumps({"type": "result", "is_error": True, "result": "quota"}))


FAKE = textwrap.dedent('''
    import json, re, sys
    prompt = sys.stdin.read()
    keys = re.findall(r"^(F\\d+)\\. ", prompt, re.M)
    art = {"title": "Édition test", "format": "Une", "style": "sarcastique",
           "body": "Testeur a fait des choses.", "refs": keys[:2]}
    print(json.dumps({"type": "result", "is_error": False, "result": json.dumps({"articles": [art]})}))
''')


class EndToEndGazette(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = self.tmp / "_forever_"
        sv = self.root / "WTF" / "Account" / "COMPTE" / "SavedVariables"
        sv.mkdir(parents=True)
        (sv / "GuildChronicle.lua").write_text(luadata.dumps(saved()), encoding="utf-8")
        (self.tmp / "fake.py").write_text(FAKE, encoding="utf-8")
        cfg = self.tmp / "config.toml"
        cmd = json.dumps([sys.executable, str(self.tmp / "fake.py")])
        cfg.write_text(f"[llm]\nenabled = true\ncommand = {cmd}\n", encoding="utf-8")
        self.cfg = cfg
        self.press = self.root / "Interface" / "AddOns" / "GuildChronicle_Press" / "Press.lua"

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def cli(self, *args):
        out = io.StringIO()
        with redirect_stdout(out):
            code = main(["--wow", str(self.root), "--config", str(self.cfg), *args])
        return code, out.getvalue()

    def test_show_gazette_and_weekly_run(self):
        code, out = self.cli("gazette", "--show")
        self.assertEqual(code, 0, out)
        self.assertIn("demande qui serait envoyée", out)
        self.assertFalse(self.press.exists(), "--show n'ecrit rien")
        code, out = self.cli("gazette")
        self.assertIn("1 article(s) proposé(s)", out)
        items = press.read_items(self.press)
        self.assertEqual(len(items), 1)
        self.assertTrue(items[0]["p"]["ia"])
        code, out = self.cli("run", "--dir", str(self.tmp))
        self.assertIn("déjà rédigée", out)
        self.assertEqual(len(press.read_items(self.press)), 1)


if __name__ == "__main__":
    unittest.main()
