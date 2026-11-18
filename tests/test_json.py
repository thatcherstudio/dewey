"""The --json interface the Mac app drives: clean event streams, full results, CSV edits, errors as
events, and Ctrl-C / SIGINT that stops promptly and stays undoable.

    python -m unittest discover -s tests -v
"""
from __future__ import annotations

import _thread
import csv
import hashlib
import io
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from test_e2e import SystemOne, build_mess, read_plan, run, serve, snapshot, write

SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))
from dewey import catalog, cli, config, mover, progress  # noqa: E402

TERMINAL = {"result", "error", "interrupted"}


def run_json(*argv, stdin: str = "") -> tuple[object, list[dict], str]:
    """Run `dewey ARGV --json` in-process: (exit code, events, stderr). Every stdout line must parse."""
    out, err = io.StringIO(), io.StringIO()
    code = 0
    with redirect_stdout(out), redirect_stderr(err), mock.patch.object(sys, "stdin", io.StringIO(stdin)):
        try:
            cli.main([*argv, "--json"])
        except SystemExit as e:
            code = e.code
    return code, [json.loads(line) for line in out.getvalue().splitlines()], err.getvalue()


class SlowSystemOne(SystemOne):
    def do_POST(self):
        time.sleep(0.3)
        super().do_POST()


class JsonInterface(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dewey-json-"))
        self.root = self.tmp / "mess"
        self.root.mkdir()
        build_mess(self.root)
        self.state = self.root / ".dewey"
        self.R = str(self.root)
        self.srv, self.url = serve(SystemOne)

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def final(self, events: list[dict]) -> dict:
        """Exactly one closing event, and it is the last line."""
        closing = [e for e in events if e["event"] in TERMINAL]
        self.assertEqual(len(closing), 1, events)
        self.assertIs(events[-1], closing[0])
        return closing[0]

    def result(self, *argv, stdin: str = "") -> dict:
        code, events, err = run_json(*argv, stdin=stdin)
        ev = self.final(events)
        self.assertEqual((code, ev["event"]), (0, "result"), (ev, err))
        return ev["data"]

    def error(self, *argv, stdin: str = "", exit_code: int = 1) -> dict:
        code, events, _ = run_json(*argv, stdin=stdin)
        ev = self.final(events)
        self.assertEqual((code, ev["event"]), (exit_code, "error"), ev)
        return ev

    def write_csv(self, edits: dict, drop: tuple = (), extra_col: str | None = None) -> Path:
        csv_path, rows = read_plan(self.state)
        rows = [r for r in rows if r["src"] not in drop]
        for r in rows:
            r.update(edits.get(r["src"], {}))
            if extra_col:
                r[extra_col] = f"note {r['row']}"
        with open(csv_path, "w", newline="", encoding="utf-8-sig") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        return csv_path

    def by_src(self, data: dict) -> dict:
        return {r["src"]: r for r in data["rows"]}

    # --- every command ---------------------------------------------------------------------

    def test_every_command_streams_clean_json(self):
        before = snapshot(self.root)
        R = self.R
        self.assertTrue(self.result("init", R)["created"])
        doc = self.result("doctor", R, "--url", self.url)
        self.assertTrue(doc["ok"] and doc["decider"]["ok"])

        code, events, _ = run_json("scan", R)
        scan = self.final(events)["data"]
        phases = {e["phase"] for e in events if e["event"] == "progress"}
        self.assertLessEqual({"walk", "hash"}, phases)
        for ph in ("walk", "hash"):
            self.assertTrue(any(e.get("phase") == ph and e["done"] for e in events), ph)
        self.assertEqual((scan["errors"], scan["error_items"], scan["units"]), (0, [], 2))

        code, events, _ = run_json("plan", R, "--url", self.url)
        plan = self.final(events)["data"]
        self.assertIn("decide", {e.get("phase") for e in events})
        self.assertIsInstance(plan["csv"], str)
        _, rows = read_plan(self.state)
        files = [r for r in rows if r["action"] != "folder"]
        for status in ("auto", "review", "skip"):
            self.assertEqual(plan["summary"][status]["n"], sum(r["status"] == status for r in files), status)

        self.assertEqual(len(self.result("rows", R)["rows"]), len(rows))
        dry = self.result("apply", R, "--dry-run")
        self.assertTrue(dry["dry_run"])
        applied = self.result("apply", R)
        self.assertFalse(applied["dry_run"])
        self.assertEqual(applied["counts"]["moved"], len(dry["selected"]))

        status = self.result("status", R)
        self.assertEqual(status["undoable"], applied["batch"])
        self.assertEqual(status["batches"][0]["moves"], applied["counts"]["moved"])
        self.assertGreater(self.result("export-labels", R)["count"], 0)

        undo = self.result("undo", R)
        self.assertEqual((undo["restored"], undo["skipped"], undo["skipped_items"]),
                         (applied["counts"]["moved"], 0, []))
        self.assertEqual(snapshot(self.root), before)
        self.assertEqual(self.result("app-info")["protocol"], cli.PROTOCOL)

    def test_status_of_a_fresh_folder_is_not_an_error(self):
        st = self.result("status", self.R)
        self.assertEqual(st["catalog"], False)
        self.assertFalse((self.state / "catalog.db").exists())        # reading status created nothing
        with self.assertRaises(SystemExit) as cm:                       # text mode: unchanged
            run("status", self.R)
        self.assertIn("no catalog yet", str(cm.exception.code))

    def test_doctor_reports_a_dead_decider_as_data(self):
        doc = self.result("doctor", self.R, "--url", "http://127.0.0.1:9")
        self.assertEqual((doc["ok"], doc["decider"]["ok"]), (False, False))

    # --- the plan as the app sees it -----------------------------------------------------------

    def test_dry_run_lists_every_row_and_matches_apply(self):
        for i in range(60):
            write(self.root / f"installer-{i:02d}.dmg", f"dmg {i}")
        run("scan", self.R)
        run("plan", self.R, "--url", self.url)
        self.write_csv({"meeting minutes.docx": {"category": "finanse"}})
        dry = self.result("apply", self.R, "--dry-run")
        srcs = {s["src"] for s in dry["selected"]}
        self.assertLessEqual({f"installer-{i:02d}.dmg" for i in range(60)}, srcs)   # not just the first 40
        self.assertEqual([(r["src"], "finanse" in r["why"]) for r in dry["refused"]],
                         [("meeting minutes.docx", True)])
        self.assertIn("more", run("apply", self.R, "--dry-run"))                     # text mode still truncates

        applied = self.result("apply", self.R)
        root = self.root.resolve()
        moved = {(os.path.relpath(m["from"], root), os.path.relpath(m["to"], root)) for m in applied["moved"]}
        self.assertEqual(moved, {(s["src"], s["dst"]) for s in dry["selected"]})
        self.assertEqual(applied["refused"], dry["refused"])

    def test_rows_show_csv_edits_as_apply_reads_them(self):
        run("scan", self.R)
        run("plan", self.R, "--url", self.url)
        csv_path = self.write_csv({"Chase_Statement_2024-03.txt": {"category": "other"},   # "leave it here"
                                   "meeting minutes.docx": {"category": "finanse"},        # typo
                                   "data.csv": {"dst": "Data/Exports/"},                   # into a folder
                                   "script.py": {"dst": "Notes"},                          # an existing folder
                                   "Résumé.txt": {"category": "work"}},                    # a real correction
                                  drop=("setup.dmg",))                                     # deleted = skip
        data = self.result("rows", self.R)
        by = self.by_src(data)
        self.assertEqual((by["Chase_Statement_2024-03.txt"]["verdict"], by["Chase_Statement_2024-03.txt"]["category"]),
                         ("stay", "other"))
        self.assertEqual(by["meeting minutes.docx"]["verdict"], "refused")
        self.assertIn("finanse", by["meeting minutes.docx"]["why"])
        self.assertEqual(by["data.csv"]["dst"], "Data/Exports/data.csv")
        self.assertEqual(by["script.py"]["dst"], "Notes/script.py")
        self.assertEqual(by["Résumé.txt"]["dst"], "Documents/Work/Résumé.txt")
        self.assertEqual((by["setup.dmg"]["in_csv"], by["setup.dmg"]["status"], by["setup.dmg"]["edited"]),
                         (False, "skip", True))
        self.assertEqual((by["empty.txt"]["edited"], by["empty.txt"]["dst"]), (False, by["empty.txt"]["planned"]["dst"]))
        self.assertEqual([c["key"] for c in data["categories"]], list(config.DEFAULTS["categories"]))  # in order
        self.assertIn({"kind": "code", "path": "Code"}, data["folder_kinds"])
        self.assertEqual(data["csv_sha256"], hashlib.sha256(csv_path.read_bytes()).hexdigest())

        dry = self.result("apply", self.R, "--dry-run")                    # rows says what apply will do
        self.assertEqual({(r["src"], r["dst"]) for r in data["rows"] if r["status"] == "auto" and r["verdict"] == "move"},
                         {(s["src"], s["dst"]) for s in dry["selected"]})

    def test_edit_changes_only_what_it_was_sent(self):
        run("scan", self.R)
        run("plan", self.R, "--url", self.url)
        csv_path = self.write_csv({}, drop=("setup.dmg",), extra_col="my notes")
        _, before = read_plan(self.state)
        data = self.result("rows", self.R)
        by = self.by_src(data)
        todo, resume, dmg = by["todo notes.md"], by["Résumé.txt"], by["setup.dmg"]
        self.assertEqual(todo["status"], "review")
        edits = [{"row": todo["row"], "status": "Auto "}, {"row": resume["row"], "category": "work"},
                 {"row": dmg["row"], "category": "data"}]
        res = self.result("edit", self.R, "--expect-sha", data["csv_sha256"], stdin=json.dumps(edits))
        self.assertEqual(res["changed"], 3)
        raw = csv_path.read_bytes()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"))
        self.assertEqual(res["csv_sha256"], hashlib.sha256(raw).hexdigest())
        _, after = read_plan(self.state)
        self.assertIn("my notes", after[0])
        touched = {todo["row"], resume["row"], dmg["row"]}
        self.assertEqual([r for r in after if int(r["row"]) not in touched],
                         [r for r in before if int(r["row"]) not in touched])            # nothing else changed
        a = {r["src"]: r for r in after}
        self.assertEqual(a["todo notes.md"]["status"], "auto")
        self.assertEqual(a["todo notes.md"]["my notes"], f"note {todo['row']}")
        self.assertEqual((a["setup.dmg"]["status"], a["setup.dmg"]["category"]), ("skip", "data"))  # back, still skipped

        by = self.by_src(self.result("rows", self.R))
        self.assertEqual(by["Résumé.txt"]["dst"], "Documents/Work/Résumé.txt")
        self.assertEqual((by["setup.dmg"]["in_csv"], by["setup.dmg"]["status"]), (True, "skip"))
        self.result("apply", self.R)
        self.assertTrue((self.root / "Notes" / "todo notes (2).md").exists())            # the approved row moved
        self.assertTrue((self.root / "setup.dmg").exists())                              # the skipped one stayed

    def test_bad_or_stale_edits_leave_the_csv_alone(self):
        run("scan", self.R)
        run("plan", self.R, "--url", self.url)
        csv_path, _ = read_plan(self.state)
        original = csv_path.read_bytes()
        bad = [[{"row": 1, "status": "maybe"}], [{"row": 99999, "status": "auto"}], [{"row": 1, "src": "x"}],
               [{"row": "1", "status": "auto"}], [{"row": 1, "dst": 5}], {"row": 1},
               [{"row": 1, "status": "skip"}, {"row": 2, "status": "nope"}]]            # all or nothing
        for edits in bad:
            with self.subTest(edits=edits):
                self.assertEqual(self.error("edit", self.R, stdin=json.dumps(edits))["code"], "bad_edit")
                self.assertEqual(csv_path.read_bytes(), original)
        self.assertEqual(self.error("edit", self.R, stdin="{oops")["code"], "bad_edit")
        stale = self.error("edit", self.R, "--expect-sha", "0" * 64, stdin='[{"row": 1, "status": "skip"}]')
        self.assertEqual(stale["code"], "stale")
        self.assertEqual(csv_path.read_bytes(), original)
        self.assertFalse(list(self.state.glob("*.dewey-tmp")))

    # --- errors -----------------------------------------------------------------------------

    def test_errors_are_events_with_codes(self):
        empty = self.tmp / "empty"
        empty.mkdir()
        self.assertEqual(self.error("scan", str(self.tmp / "nope"))["code"], "not_a_folder")
        self.assertEqual(self.error("rows", str(empty))["code"], "no_catalog")
        run("scan", self.R)
        self.assertEqual(self.error("rows", self.R)["code"], "no_plan")
        self.assertEqual(self.error("plan", self.R, "--url", "http://127.0.0.1:9")["code"], "decider")
        self.assertEqual(self.error("undo", self.R)["code"], "nothing_to_undo")
        self.assertEqual(self.error("apply", exit_code=2)["code"], "usage")
        with mock.patch.object(catalog, "scan", side_effect=RuntimeError("disk on fire")):
            code, events, err = run_json("scan", self.R)
        ev = self.final(events)
        self.assertEqual((code, ev["code"], ev["message"]), (1, "internal", "RuntimeError: disk on fire"))
        self.assertIn("Traceback", err)
        (self.state / "dewey.toml").write_text("[plan\nmax_depth = 0\n")
        ev = self.error("status", self.R)
        self.assertEqual(ev["code"], "config")
        self.assertIn("isn't valid TOML", ev["message"])

    # --- stopping -------------------------------------------------------------------------------

    def test_ctrl_c_during_apply_names_the_batch(self):
        before = snapshot(self.root)
        run("scan", self.R)
        run("plan", self.R, "--url", self.url)
        real = mover.move_file

        def move_then_interrupt(*a, **kw):
            real(*a, **kw)
            raise KeyboardInterrupt

        with mock.patch.object(mover, "move_file", side_effect=move_then_interrupt):
            code, events, _ = run_json("apply", self.R)
        ev = self.final(events)
        self.assertEqual((code, ev["event"]), (130, "interrupted"))
        self.assertTrue((self.state / "moves" / f"{ev['batch']}.jsonl").exists())
        self.assertEqual(self.result("undo", self.R, "--batch", ev["batch"])["restored"], 1)
        self.assertEqual(snapshot(self.root), before)

    def interrupt_after(self, seconds: float, *argv) -> tuple[object, list[dict], float]:
        timer = threading.Timer(seconds, _thread.interrupt_main)
        t0 = time.monotonic()
        timer.start()
        try:
            code, events, _ = run_json(*argv)
        finally:
            timer.cancel()
        return code, events, time.monotonic() - t0

    def test_ctrl_c_during_hashing_stops_fast_and_keeps_hashes(self):
        for i in range(60):
            write(self.root / f"slow-{i:02d}.txt", f"slow file {i}")
        real = catalog._work

        def slow(*a):
            time.sleep(0.2)
            return real(*a)

        with mock.patch.object(catalog, "_work", slow):  # ~80 files x 0.2 s / 4 workers = ~4 s if it ran on
            code, events, elapsed = self.interrupt_after(0.5, "scan", self.R)
        self.assertEqual((code, self.final(events)["event"]), (130, "interrupted"))
        self.assertLess(elapsed, 1.5)
        with sqlite3.connect(self.state / "catalog.db") as db:
            hashed = db.execute("SELECT COUNT(*) FROM files WHERE hash IS NOT NULL").fetchone()[0]
        self.assertGreater(hashed, 0)
        self.assertGreaterEqual(self.result("scan", self.R)["reused"], hashed)  # the next scan picks them up

    def test_ctrl_c_during_deciding_stops_fast_and_keeps_answers(self):
        for i in range(40):
            write(self.root / f"memo-{i:02d}.txt", f"meeting memo number {i}")
        srv, url = serve(SlowSystemOne)
        try:
            run("scan", self.R)  # ~50 questions x 0.3 s / 4 workers = ~4 s if it ran on
            code, events, elapsed = self.interrupt_after(1.2, "plan", self.R, "--url", url)
        finally:
            srv.shutdown()
            srv.server_close()
        self.assertEqual((code, self.final(events)["event"]), (130, "interrupted"))
        self.assertLess(elapsed, 2.2)
        with sqlite3.connect(self.state / "catalog.db") as db:
            cached = db.execute("SELECT COUNT(*) FROM decision_cache").fetchone()[0]
        self.assertGreater(cached, 0)
        _, events, _ = run_json("plan", self.R, "--url", self.url)
        self.assertIn(f"Reusing {cached:,} cached decisions", [e.get("text") for e in events])

    def test_real_sigint_to_a_subprocess(self):
        for i in range(40):
            write(self.root / f"memo-{i:02d}.txt", f"meeting memo number {i}")
        srv, url = serve(SlowSystemOne)
        try:
            run("scan", self.R)
            p = subprocess.Popen([sys.executable, "-m", "dewey", "plan", self.R, "--url", url, "--json"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 env={**os.environ, "PYTHONPATH": str(SRC)})
            lines = []
            for line in p.stdout:  # wait until it is really deciding, then cancel like the app does
                lines.append(line)
                if json.loads(line).get("phase") == "decide":
                    break
            p.send_signal(signal.SIGINT)
            out, err = p.communicate(timeout=10)
        finally:
            srv.shutdown()
            srv.server_close()
        events = [json.loads(l) for l in lines + out.splitlines()]
        self.assertEqual((p.returncode, self.final(events)["event"]), (130, "interrupted"), err)

    # --- text mode is untouched ----------------------------------------------------------------

    def test_text_mode_never_writes_stdout(self):
        self.result("scan", self.R)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            cli.main(["plan", self.R, "--url", self.url])
            cli.main(["status", self.R])
        self.assertEqual(out.getvalue(), "")
        self.assertIn("Plan 1", err.getvalue())
        self.assertFalse(progress.json_mode())


if __name__ == "__main__":
    unittest.main()
