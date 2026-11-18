"""Tests du compagnon : python -m unittest discover -s tests/companion -t ."""
import datetime as dt
import io
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from companion import articles, combatlog, luadata, press
from companion.__main__ import main
from companion.reconcile import Chronicle, propose

TZ = dt.timezone(dt.timedelta(hours=-5))


def ts(h, m, s):
    return dt.datetime(2026, 11, 18, h, m, s, tzinfo=TZ).timestamp()


def line(h, m, s, rest):
    return f"11/18/2026 {h:02d}:{m:02d}:{s:02d}.000-5  {rest}\n"


ME = "Player-1-ABC"
BOB = "Player-1-BBB"
GOR = "Player-2-GOR"
ADV = "Player-1-ABC,0000000000000000,50,100,0,0,0,-1,0,0,0,1.0,2.0,0,0.0,60"
LOG_LINES = [
    "11/18/2026 20:59:00.000-5  COMBAT_LOG_VERSION,21,ADVANCED_LOG_ENABLED,1,BUILD_VERSION,1.60.1,PROJECT_ID,1\n",
    line(21, 0, 0, f'SPELL_DAMAGE,Creature-0-1-2-3-4-5,"Ronfleur le Maladroit",0xa48,0x0,{ME},"Testeur-Forever",0x511,0x0,1234,"Coup de pioche",0x1,{ADV},120,0,1,0,0,0,nil,nil,nil'),
    line(21, 0, 1, f'UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,{ME},"Testeur-Forever",0x511,0x0,0'),
    line(21, 5, 0, f'ENVIRONMENTAL_DAMAGE,0000000000000000,nil,0x80000000,0x80000000,{BOB},"Bob-Forever",0x512,0x0,{ADV},Falling,500,0,1,0,0,0,nil,nil,nil'),
    line(21, 5, 0, f'UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,{BOB},"Bob-Forever",0x512,0x0,0'),
    line(21, 10, 0, f'SPELL_DAMAGE,{GOR},"Gorbash-Forever",0x548,0x0,{ME},"Testeur-Forever",0x511,0x0,12294,"Frappe mortelle",0x1,{ADV},300,0,1,0,0,0,nil,nil,nil'),
    line(21, 10, 0, f'PARTY_KILL,{GOR},"Gorbash-Forever",0x548,0x0,{ME},"Testeur-Forever",0x511,0x0,0'),
    line(21, 10, 0, f'UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,{ME},"Testeur-Forever",0x511,0x0,0'),
    line(21, 20, 0, f'PARTY_KILL,{ME},"Testeur-Forever",0x511,0x0,{GOR},"Gorbash-Forever",0x548,0x0,0'),
    line(21, 20, 0, f'UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,{GOR},"Gorbash-Forever",0x548,0x0,0'),
    line(21, 30, 0, f'UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Player-9-ZZZ,"Inconnu-Forever",0x512,0x0,0'),
    "ligne illisible\n",
]

SKEW = 3  # le serveur a 3 s d'avance sur le PC


def saved_variables():
    def ev(eid, author, name, kind, t, **extra):
        e = {"id": eid, "a": author, "n": name, "k": kind, "t": int(t), "vis": "G", "s": int(eid.split(":")[1]),
             "g": "Les Testeurs-Forever", "p": {}, "prov": "OBS"}
        e.update(extra)
        return e
    events = [
        ev(f"{ME}:1", ME, "Testeur", "DEATH", ts(21, 0, 1) + SKEW, miss=["killer"]),
        ev(f"{BOB}:1", BOB, "Bob", "DEATH", ts(21, 5, 0) + SKEW),
        ev(f"{ME}:2", ME, "Testeur", "ENEMY_SEEN", ts(21, 9, 0) + SKEW, p={"name": "Gorbash", "guild": "Les Crocs"}),
        ev(f"{ME}:3", ME, "Testeur", "DEATH", ts(21, 10, 0) + SKEW, p={"enemies": ["Gorbash"]}),
    ]
    return {"RenatusDB": {"schema": 1, "events": {e["id"]: e for e in events}, "pressDone": {}},
            "RenatusCharDB": None}


class LuaDataTests(unittest.TestCase):
    def test_wow_style_file(self):
        text = (
            'RenatusDB = {\n\t["events"] = {\n\t\t["Player-1-ABC:p1"] = {\n'
            '\t\t\t["k"] = "LEVEL_UP",\n\t\t\t["p"] = {\n\t\t\t\t["lvl"] = 21,\n\t\t\t},\n'
            '\t\t\t["pt"] = {\n\t\t\t\t{\n\t\t\t\t\t["n"] = "Mélisande",\n\t\t\t\t}, -- [1]\n\t\t\t},\n'
            '\t\t\t["x"] = -1.5e2,\n\t\t\t["q"] = "dit \\"bonjour\\"\\n\\\\fin\\233",\n\t\t},\n\t},\n'
            '\t["empty"] = {\n\t},\n\t["flag"] = true,\n}\nRenatusCharDB = nil\n')
        data = luadata.loads(text)
        ev = data["RenatusDB"]["events"]["Player-1-ABC:p1"]
        self.assertEqual(ev["p"]["lvl"], 21)
        self.assertEqual(ev["pt"][0]["n"], "Mélisande")
        self.assertEqual(ev["x"], -150.0)
        self.assertTrue(ev["q"].startswith('dit "bonjour"\n\\fin'))
        self.assertEqual(data["RenatusDB"]["empty"], {})
        self.assertIsNone(data["RenatusCharDB"])

    def test_roundtrip(self):
        value = {"items": [{"id": "a", "p": {"body": 'L1\nL2 "q" \\ é', "n": 3, "f": 0.5, "b": False}}], "v": 1}
        self.assertEqual(luadata.loads(luadata.dumps({"X": value}))["X"], value)

    def test_rejects_code(self):
        with self.assertRaises(luadata.LuaParseError):
            luadata.loads('X = os.execute("rm")')


class CombatLogTests(unittest.TestCase):
    def setUp(self):
        self.analysis = combatlog.analyse(combatlog.iter_events(LOG_LINES))

    def test_deaths_and_causes(self):
        deaths = self.analysis.deaths
        self.assertEqual([d.name for d in deaths], ["Testeur", "Bob", "Testeur", "Gorbash", "Inconnu"])
        first = deaths[0]
        self.assertEqual(first.name, "Testeur")
        self.assertEqual(first.cause, "Ronfleur le Maladroit (Coup de pioche)")
        self.assertAlmostEqual(first.ts, ts(21, 0, 1))
        self.assertEqual(deaths[1].cause, "chute")
        pvp = deaths[2]
        self.assertTrue(pvp.by_player)
        self.assertEqual(pvp.killer, "Gorbash")
        self.assertEqual(pvp.cause, "Gorbash (Frappe mortelle)")
        self.assertEqual(deaths[3].cause, "Testeur")  # coup fatal connu, sans sort
        self.assertEqual(deaths[4].cause, "cause indéterminée")

    def test_kills_on_players(self):
        self.assertEqual([(k.killer, k.victim) for k in self.analysis.kills],
                         [("Gorbash", "Testeur"), ("Testeur", "Gorbash")])

    def test_split_fields(self):
        self.assertEqual(combatlog.split_fields('A,"b, c",[(1,2),3],d'), ["A", "b, c", "[(1,2),3]", "d"])

    def test_old_timestamp_without_year(self):
        ev = combatlog.parse_line("11/18 21:00:00.123  UNIT_DIED,a,b,c,d,e,f,g,h", 2026)
        self.assertEqual(ev.event, "UNIT_DIED")


class ReconcileTests(unittest.TestCase):
    def setUp(self):
        self.ch = Chronicle.from_saved(saved_variables())
        self.items, self.notes = propose(combatlog.analyse(combatlog.iter_events(LOG_LINES)), self.ch)
        self.by_id = {i["id"]: i for i in self.items}

    def test_enriches_existing_deaths_only(self):
        causes = [i for i in self.items if i["kind"] == "DEATH_CAUSE"]
        self.assertEqual(sorted(i["refs"][0] for i in causes), sorted([f"{ME}:1", f"{BOB}:1", f"{ME}:3"]))
        self.assertEqual(self.by_id[f"dc:{BOB}:1"]["p"]["cause"], "chute")
        # la mort de "Inconnu" n'existe pas dans l'addon : rien n'est invente
        self.assertFalse(any("Inconnu" in str(i) for i in self.items))
        self.assertTrue(any("Décalage" in n for n in self.notes))

    def test_pvp_only_against_known_enemies(self):
        loss = self.by_id[f"pl:{ME}:3"]
        self.assertEqual(loss["p"]["result"], "loss")
        self.assertEqual(loss["p"]["member"], "Testeur")
        win = [i for i in self.items if i["kind"] == "PVP_CLASH" and i["p"]["result"] == "win"]
        self.assertEqual(len(win), 1)
        self.assertEqual(win[0]["p"]["name"], "Gorbash")

    def test_already_enriched_is_skipped(self):
        sv = saved_variables()
        sv["RenatusDB"]["events"]["X:1"] = {"id": "X:1", "a": "X", "k": "DEATH_CAUSE", "t": 0, "refs": [f"{ME}:1"]}
        items, _ = propose(combatlog.analyse(combatlog.iter_events(LOG_LINES)), Chronicle.from_saved(sv))
        self.assertNotIn(f"dc:{ME}:1", {i["id"] for i in items})


class PressAndArticlesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_merge_drops_done_and_dedups(self):
        a, b = {"id": "a", "t": 1}, {"id": "b", "t": 2}
        merged = press.merge([a, b], [{"id": "b", "t": 2, "p": {"x": 1}}], {"a": "published"})
        self.assertEqual(merged, [{"id": "b", "t": 2, "p": {"x": 1}}])

    def test_article_parsing_and_checks(self):
        folder = self.tmp / "articles"
        folder.mkdir()
        (folder / "une.md").write_text("---\ntitle: Drame\nrefs: A:1, Z:9\n---\nTexte.\n", encoding="utf-8")
        (folder / "sans_titre.md").write_text("Texte sans en-tête", encoding="utf-8")
        found, notes = articles.load_dir(folder, {"A:1"})
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].refs, ["A:1", "Z:9"])
        self.assertTrue(any("Z:9" in n for n in notes))
        self.assertTrue(any("titre manquant" in n for n in notes))
        self.assertTrue(found[0].to_item()["id"].startswith("art:une:"))


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp()) / "_forever_"
        sv = self.root / "WTF" / "Account" / "COMPTE" / "SavedVariables"
        sv.mkdir(parents=True)
        (sv / "Renatus.lua").write_text(luadata.dumps(saved_variables()), encoding="utf-8")
        logs = self.root / "Logs"
        logs.mkdir()
        (logs / "WoWCombatLog-111826_210000.txt").write_text("".join(LOG_LINES), encoding="utf-8")
        self.articles = self.root.parent / "articles"
        self.articles.mkdir()
        (self.articles / "a.md").write_text(f"---\ntitle: Gorbash frappe encore\nrefs: {ME}:3\n---\nSelon nos sources.\n",
                                            encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.root.parent)

    def run_cli(self, *args):
        out = io.StringIO()
        with redirect_stdout(out):
            code = main(["--wow", str(self.root), *args])
        return code, out.getvalue()

    def test_status_run_and_idempotence(self):
        code, out = self.run_cli("status")
        self.assertEqual(code, 0, out)
        self.assertIn("4 événement(s)", out)
        code, out = self.run_cli("run", "--dir", str(self.articles))
        self.assertEqual(code, 0, out)
        press_file = self.root / "Interface" / "AddOns" / "Renatus_Press" / "Press.lua"
        items = press.read_items(press_file)
        self.assertEqual(len(items), 6)  # 3 causes + 1 defaite + 1 victoire + 1 article
        self.run_cli("run", "--dir", str(self.articles))
        self.assertEqual(len(press.read_items(press_file)), 6, "pas de doublon")
        code, out = self.run_cli("facts", "--days", "100000")
        self.assertIn(f"id={ME}:3", out)

    @unittest.skipUnless(shutil.which("lua"), "interpreteur lua absent")
    def test_press_file_loads_in_lua(self):
        self.run_cli("run", "--dir", str(self.articles))
        press_file = self.root / "Interface" / "AddOns" / "Renatus_Press" / "Press.lua"
        script = f'dofile([[{press_file}]]); print(#RenatusPress.items, RenatusPress.items[1].kind)'
        out = subprocess.run(["lua", "-e", script], capture_output=True, text=True, check=True).stdout.split()
        self.assertEqual(out[0], "6")


if __name__ == "__main__":
    unittest.main()
