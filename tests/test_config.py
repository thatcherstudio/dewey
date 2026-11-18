"""Settings the Mac app reads and writes: `dewey config ROOT [--write]` and the TOML writer behind it.

    python -m unittest discover -s tests -v
"""
from __future__ import annotations

import io
import json
import shutil
import sys
import tempfile
import tomllib
import unittest
from contextlib import redirect_stderr
from pathlib import Path

from test_e2e import SystemOne, build_mess, read_plan, serve
from test_json import run_json

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))
from dewey import cli, config  # noqa: E402


class TomlWriter(unittest.TestCase):
    def test_tricky_values_round_trip(self):
        doc = {"n": 1, "yes": True, "no": False, "f": 1.0, "tiny": 1e-06, "big": 1e20, "neg": -0.5,
               "s": 'quote " backslash \\ del \x7f tab \t nl \n cr \r bell \x07 emoji 😀 accent é',
               "empty": "", "list": [], "mixed": ["a", 1, True, {"inline": "table"}],
               "table": {"k": "v", "deeper": {"x": 0}, "nothing": {}},
               "needs quotes": {"a.b": {"": "empty key", "with space": 1}},
               "rules": [{"name": "one", "ext": [".a", ".b"]}, {"name": "two", "sub": {"x": 1}}]}
        self.assertEqual(tomllib.loads(config.dumps(doc)), doc)

    def test_the_whole_default_config_round_trips(self):
        self.assertEqual(tomllib.loads(config.dumps(config.DEFAULTS)), config.DEFAULTS)

    def test_bool_is_not_an_int_and_none_is_refused(self):
        self.assertIn("a = true", config.dumps({"a": True}))
        with self.assertRaises(TypeError):
            config.dumps({"a": None})
        with self.assertRaises(ValueError):
            config.dumps({"a": "\ud800"})

    def test_defaults_differ_from_nothing(self):
        self.assertEqual(config.changed_settings(config.DEFAULTS), {})
        cats = dict(reversed(list(config.DEFAULTS["categories"].items())))
        self.assertIn("categories", config.changed_settings({**config.DEFAULTS, "categories": cats}),
                      "category order matters to the decider")
        rules = [dict(sorted(r.items())) for r in config.DEFAULTS["rules"]]  # as JSON from Swift has them
        self.assertEqual(config.changed_settings({**config.DEFAULTS, "rules": rules}), {})


class Settings(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dewey-config-"))
        self.root = self.tmp / "mess"
        self.root.mkdir()
        self.R = str(self.root)
        self.toml = self.root / ".dewey" / "dewey.toml"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def read(self) -> dict:
        code, events, err = run_json("config", self.R)
        self.assertEqual((code, events[-1]["event"]), (0, "result"), (events, err))
        return events[-1]["data"]

    def write(self, settings, *extra) -> dict:
        code, events, err = run_json("config", self.R, "--write", *extra, stdin=json.dumps(settings))
        self.assertEqual((code, events[-1]["event"]), (0, "result"), (events, err))
        return events[-1]["data"]

    def refused(self, settings, *extra, code="config") -> str:
        rc, events, _ = run_json("config", self.R, "--write", *extra, stdin=json.dumps(settings))
        self.assertEqual((rc, events[-1]["event"], events[-1]["code"]), (1, "error", code), events)
        return events[-1]["message"]

    def test_a_new_folder_shows_the_defaults(self):
        s = self.read()
        self.assertEqual((s["exists"], s["source"], s["sha256"], s["valid"]), (False, None, None, True))
        self.assertEqual(s["config"], s["defaults"])
        self.assertEqual([c["key"] for c in s["config"]["categories"]], list(config.DEFAULTS["categories"]))
        kinds = s["config"]["folders"]["kinds"]
        self.assertEqual(kinds[0], {"kind": "code", "path": "Code", "label": "code project"})
        self.assertFalse(self.toml.exists(), "reading writes nothing")

    def test_saving_writes_only_what_differs_and_reads_back_the_same(self):
        s = self.read()["config"]
        s["categories"].insert(1, {"key": "recipes", "path": "Documents/Recipes", "desc": "recipes, cooking"})
        s["plan"]["auto_confidence"] = 1  # JSON from Swift may send a whole number
        s["folders"]["kinds"][0]["path"] = "Projects"
        res = self.write(s)
        self.assertEqual((res["exists"], res["backup"]), (True, None))
        self.assertEqual(res["changed"], ["plan", "folders", "categories"])
        self.assertEqual(res["config"]["plan"]["auto_confidence"], 1.0)
        self.assertEqual(res["config"]["categories"][1]["key"], "recipes")
        text = self.toml.read_text()
        self.assertTrue(text.startswith("# dewey settings for this folder, saved by the Dewey app."))
        self.assertIn("auto_confidence = 1.0", text)
        self.assertIn('code = "Projects"', text)
        self.assertNotIn("[scan]", text)
        self.assertNotIn("[[rules]]", text, "unchanged rules stay with the defaults")
        self.assertEqual(self.read()["config"], res["config"])
        # dewey itself reads the same thing
        cfg, path = config.load(self.root / ".dewey")
        self.assertEqual((list(cfg["categories"])[1], cfg["folders"]["code"]), ("recipes", "Projects"))
        # and saving it again changes nothing but keeps the previous file
        again = self.write(res["config"])
        self.assertEqual(Path(again["backup"]).read_text(), text)
        self.assertEqual(self.toml.read_text(), text)

    def test_a_subset_keeps_every_other_setting(self):
        self.toml.parent.mkdir()
        self.toml.write_text('[scan]\nworkers = 2\nunknown_thing = "kept"\n\n[plan]\nmax_depth = 1\n')
        res = self.write({"decider": {"backend": "none"}})
        cfg = tomllib.loads(self.toml.read_text())
        self.assertEqual(cfg["scan"], {"workers": 2, "unknown_thing": "kept"})
        self.assertEqual((cfg["plan"]["max_depth"], cfg["decider"]["backend"]), (1, "none"))
        self.assertEqual(res["config"]["scan"]["workers"], 2)

    def test_back_to_the_defaults_leaves_just_the_header(self):
        self.write({"plan": {"max_depth": 2}})
        self.write(self.read()["defaults"])
        self.assertEqual(self.toml.read_text(), config.SETTINGS_HEADER)
        self.assertEqual(self.read()["config"], self.read()["defaults"])

    def test_rules_replace_the_defaults_and_the_next_plan_uses_them(self):
        build_mess(self.root)
        srv, url = serve(SystemOne)
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        s = self.read()["config"]
        s["rules"] = [{"target": "Pictures/{year}", "reason": "a PNG", "ext": [".png"], "name": "pictures"}]
        for c in s["categories"]:
            if c["key"] == "finance":
                c["path"] = "Money"
        s["decider"]["url"] = url
        self.write(s)
        self.assertIn('[[rules]]\nname = "pictures"\next = [".png"]\ntarget = "Pictures/{year}"\nreason = "a PNG"',
                      self.toml.read_text(), "rule keys in the usual order")
        self.assertEqual(run_json("run", self.R)[1][-1]["event"], "result")
        _, rows = read_plan(self.root / ".dewey")
        by = {r["src"]: r for r in rows}
        self.assertTrue(by["Screenshot 2025-03-04 at 10.11.12.png"]["dst"].startswith("Pictures/2025/"), by)
        self.assertEqual(by["Screenshot 2025-03-04 at 10.11.12.png"]["decided_by"], "rule:pictures")
        self.assertTrue(by["Chase_Statement_2024-03.txt"]["dst"].startswith("Money/"), by)

    def test_mistakes_are_refused_and_nothing_is_written(self):
        cases = [
            ({"plan": {"review_confidence": 0.9, "auto_confidence": 0.8}}, "review_confidence <= auto_confidence"),
            ({"scan": {"workers": "four"}}, "scan.workers must be a whole number"),
            ({"scan": {"workers": 0}}, "scan.workers must be 1 or more"),
            ({"plan": {"bogus": 1}}, "unknown setting plan.bogus"),
            ({"decider": {"backend": "magic"}}, "decider.backend"),
            ({"rules": [{"name": "bad", "target": "X", "name_regex": "(unclosed"}]}, "bad regex in rule bad"),
            ({"rules": [{"name": "nope"}]}, "needs name and target"),
            ({"rules": [{"name": "x", "target": "X", "ext": ".pdf"}]}, "ext must be a list of text"),
            ({"categories": [{"key": "a", "path": "A", "desc": "a"}, {"key": "a", "path": "B", "desc": "b"}]},
             "two folders for the decider are called 'a'"),
            ({"categories": [{"key": " ", "path": "A", "desc": "a"}]}, "needs a name"),
            ({"categories": [{"key": "only", "path": "A", "desc": "a"}]}, "at least 2"),
            ({"folders": {"kinds": [{"kind": "spaceships", "path": "X"}]}}, "unknown folder kind"),
        ]
        for settings, msg in cases:
            with self.subTest(msg):
                self.assertIn(msg, self.refused(settings))
                self.assertFalse(self.toml.exists())

    def test_a_broken_file_is_shown_and_can_be_replaced(self):
        self.toml.parent.mkdir()
        self.toml.write_text('[plan]\nauto_confidence = "high\n')
        s = self.read()
        self.assertEqual((s["valid"], s["config"]), (False, None))
        self.assertIn("isn't valid TOML", s["error"])
        self.assertEqual(s["raw"], '[plan]\nauto_confidence = "high\n')
        self.assertIn("start over from the defaults", self.refused({"decider": {"backend": "none"}}))
        # wrong types and impossible values are "broken" the same way
        self.toml.write_text('[plan]\nauto_confidence = "high"\n')
        self.assertIn("plan.auto_confidence must be a number", self.read()["error"])
        res = self.write({"decider": {"backend": "none"}}, "--reset")
        self.assertTrue(res["valid"])
        self.assertEqual(Path(res["backup"]).read_text(), '[plan]\nauto_confidence = "high"\n')
        self.assertEqual(tomllib.loads(self.toml.read_text()), {"decider": {"backend": "none"}})
        # and dewey's other commands say the same thing about a broken file
        self.toml.write_text("[scan]\nworkers = true\n")
        code, events, _ = run_json("status", self.R)
        self.assertEqual((events[-1]["code"], code), ("config", 1))
        self.assertIn("scan.workers must be a whole number", events[-1]["message"])

    def test_a_file_changed_since_it_was_read_is_not_overwritten(self):
        self.assertIn("changed since the settings were read", self.refused({}, "--expect-sha", "abc", code="stale"))
        first = self.write({"plan": {"max_depth": 1}}, "--expect-sha", "none")
        self.toml.write_text(self.toml.read_text() + "\n[scan]\nworkers = 3\n")  # edited in a text editor
        self.refused({"plan": {"max_depth": 2}}, "--expect-sha", first["sha256"], code="stale")
        self.assertIn("workers = 3", self.toml.read_text())
        self.write({"plan": {"max_depth": 2}}, "--expect-sha", self.read()["sha256"])
        self.assertIn("workers = 3", self.toml.read_text())

    def test_text_mode_lists_what_differs(self):
        self.write({"plan": {"max_depth": 3}})
        buf = io.StringIO()
        with redirect_stderr(buf):
            cli.main(["config", self.R])
        self.assertIn("this folder's own file", buf.getvalue())
        self.assertIn("[plan]\nmax_depth = 3", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
