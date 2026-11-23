"""One thing dewey can't use is said plainly, and is that thing's problem only: one bad dst cell is
one refused row, a plan CSV saved with semicolons is read as it was meant, a folder the system won't
let dewey into is its own error, and a plan that has nothing to ask the model doesn't need it running.

    python -m unittest discover -s tests -v
"""
from __future__ import annotations

import csv
import errno
import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

from test_e2e import SystemOne, read_plan, run, serve, write
from test_json import run_json
from test_safety import Folder, files

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from dewey import catalog, cli  # noqa: E402
from dewey.planner import CSV_FIELDS  # noqa: E402

AS_ROOT = hasattr(os, "geteuid") and os.geteuid() == 0  # root is let in everywhere: nothing to test


class Plain(Folder):
    @property
    def state(self) -> Path:
        return self.root / ".dewey"

    def event(self, *argv, stdin: str = "") -> dict:
        """The closing event of `dewey ARGV --json`."""
        _code, events, _err = run_json(*argv, stdin=stdin)
        return events[-1]

    def result(self, *argv, stdin: str = "") -> dict:
        ev = self.event(*argv, stdin=stdin)
        self.assertEqual(ev["event"], "result", ev)
        return ev["data"]

    def error(self, *argv, stdin: str = "") -> dict:
        ev = self.event(*argv, stdin=stdin)
        self.assertEqual(ev["event"], "error", ev)
        return ev

    def rewrite(self, change=lambda rows: None, delimiter: str = ",", header: bool = True) -> Path:
        """Save the plan CSV again, as a person would from a spreadsheet."""
        csv_path, rows = read_plan(self.state)
        change({r["src"]: r for r in rows})
        with open(csv_path, "w", newline="", encoding="utf-8-sig") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), delimiter=delimiter)
            if header:
                w.writeheader()
            w.writerows(rows)
        return csv_path

    def setUp(self):
        super().setUp()
        self.unlock: list[tuple[Path, int]] = []

    def tearDown(self):
        for path, mode in reversed(self.unlock):  # before the folder is deleted, or it can't be
            os.chmod(path, mode)
        super().tearDown()

    def locked(self, path: Path) -> None:
        """No permissions on `path` until the test ends."""
        self.unlock.append((path, path.stat().st_mode))
        os.chmod(path, 0)


class OneBadCell(Plain):
    """A dst the disk can't use refuses its own row. 0.2.1 failed `rows` and `apply` for the whole
    plan, so the Review tab couldn't open the plan to fix the cell."""

    def test_a_name_too_long_is_that_rows_problem(self):
        R = self.planned()
        self.rewrite(lambda rows: rows["one.zip"].update(dst=f"Archives/{'x' * 300}/one.zip"))
        rows = {r["src"]: r for r in self.result("rows", R)["rows"]}
        self.assertEqual((rows["one.zip"]["verdict"], rows["two.zip"]["verdict"]), ("refused", "move"))
        self.assertIn("longer than 255 bytes", rows["one.zip"]["why"])
        dry = self.result("apply", R, "--dry-run")
        self.assertEqual([s["src"] for s in dry["selected"]], ["two.zip"])
        self.assertEqual([r["src"] for r in dry["refused"]], ["one.zip"])
        moved = self.result("apply", R)
        self.assertEqual(moved["counts"]["moved"], 1)
        self.assertEqual(files(self.root), ["Archives/two.zip", "one.zip"])

    def test_a_name_of_255_bytes_is_fine_and_bytes_are_what_count(self):
        R = self.planned()
        fits, too_long = "x" * 255, "é" * 128  # 128 letters, 256 bytes
        self.rewrite(lambda rows: (rows["one.zip"].update(dst=f"{fits}/one.zip"),
                                   rows["two.zip"].update(dst=f"{too_long}/two.zip")))
        rows = {r["src"]: r for r in self.result("rows", R)["rows"]}
        self.assertEqual((rows["one.zip"]["verdict"], rows["two.zip"]["verdict"]), ("move", "refused"))

    @unittest.skipIf(AS_ROOT, "root can enter any folder")
    def test_a_folder_on_the_way_that_cant_be_entered_is_that_rows_problem(self):
        R = self.planned()
        (self.root / "Locked" / "in").mkdir(parents=True)
        self.locked(self.root / "Locked")
        self.rewrite(lambda rows: rows["one.zip"].update(dst="Locked/in/one.zip"))
        rows = {r["src"]: r for r in self.result("rows", R)["rows"]}
        self.assertEqual((rows["one.zip"]["verdict"], rows["two.zip"]["verdict"]), ("refused", "move"))
        self.assertIn("Permission denied", rows["one.zip"]["why"])
        self.assertEqual([s["src"] for s in self.result("apply", R, "--dry-run")["selected"]], ["two.zip"])

    def test_edit_turns_down_a_name_too_long(self):
        R = self.planned()
        csv_path, _ = read_plan(self.state)
        before = csv_path.read_bytes()
        ev = self.error("edit", R, stdin=json.dumps([{"row": 1, "dst": f"Archives/{'x' * 256}.zip"}]))
        self.assertEqual(ev["code"], "bad_edit")
        self.assertIn("row 1", ev["message"])
        self.assertEqual(csv_path.read_bytes(), before)
        self.result("edit", R, stdin=json.dumps([{"row": 1, "dst": f"Archives/{'x' * 251}.zip"}]))  # 255: fine


class OtherSeparators(Plain):
    """Excel and Numbers save `;` between cells where the decimal comma is used. Read as commas,
    that file has no `row` column, every line counts as deleted, and a deleted line means skip:
    0.2.1 said "0 files to move" and nothing else."""

    def test_semicolons_and_tabs_are_read_as_cells(self):
        for name, delimiter in (("semicolons", ";"), ("tabs", "\t")):
            with self.subTest(name):
                R = self.planned()
                self.rewrite(lambda rows: (rows["one.zip"].update(status="skip"),
                                           rows["two.zip"].update(reason="a; b, c\td")), delimiter=delimiter)
                dry = self.result("apply", R, "--dry-run")
                self.assertEqual([s["src"] for s in dry["selected"]], ["two.zip"])
                rows = {r["src"]: r for r in self.result("rows", R)["rows"]}
                self.assertEqual([(r["status"], r["in_csv"]) for r in rows.values()], [("skip", True), ("auto", True)])
                # the app's Save writes the file dewey's own way again, every line still there
                self.result("edit", R, stdin=json.dumps([{"row": 1, "status": "review"}]))
                csv_path, saved = read_plan(self.state)
                self.assertEqual(csv_path.read_text(encoding="utf-8-sig").splitlines()[0], ",".join(CSV_FIELDS))
                self.assertEqual([(r["src"], r["status"], r["reason"]) for r in saved],
                                 [("one.zip", "review", "Compressed archive"), ("two.zip", "auto", "a; b, c\td")])
                self.tearDown()
                self.setUp()

    def test_a_first_line_with_no_row_column_is_an_error_not_a_plan_of_skips(self):
        R = self.planned()
        self.rewrite(header=False)  # the header line deleted: the first row is taken for it
        for argv in (("rows", R), ("apply", R, "--dry-run"), ("apply", R),
                     ("edit", R)):
            with self.subTest(argv=argv):
                ev = self.error(*argv, stdin='[{"row": 1, "status": "skip"}]')
                self.assertEqual(ev["code"], "bad_edit")
                self.assertIn("no `row` column", ev["message"])
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])
        status = self.result("status", R)  # the folder still opens; the counts are the plan's own
        self.assertEqual(status["plans"][0]["summary"]["auto"]["n"], 2)

    def test_a_file_with_nothing_in_it_still_means_every_line_was_deleted(self):
        R = self.planned()
        read_plan(self.state)[0].write_bytes(b"")
        dry = self.result("apply", R, "--dry-run")
        self.assertEqual(dry["selected"], [])
        self.assertEqual({r["status"] for r in self.result("rows", R)["rows"]}, {"skip"})


@unittest.skipIf(AS_ROOT, "root can read any folder")
class NoAccess(Plain):
    """The system turns dewey away from the folder (the macOS privacy question answered "Don't
    Allow", or its permissions). 0.2.1: `PermissionError: [Errno 13] …` with the code `internal`."""

    def test_a_folder_dewey_may_not_read_has_its_own_code_and_says_where_to_allow_it(self):
        R = self.planned()
        self.locked(self.state)
        for cmd in ("status", "scan", "rows", "config", "undo", "plan"):
            with self.subTest(cmd):
                ev = self.error(cmd, R)
                self.assertEqual(ev["code"], "no_access")
                self.assertIn(str(self.state), ev["message"])
                self.assertIn("Privacy & Security > Files and Folders", ev["message"])
                self.assertNotIn("PermissionError", ev["message"])

    def test_in_a_terminal_it_is_a_sentence_not_a_traceback(self):
        R = self.planned()
        self.locked(self.state)
        with self.assertRaises(SystemExit) as stop:
            run("status", R)
        self.assertIn("macOS didn't let dewey open", str(stop.exception.code))
        self.assertEqual(getattr(stop.exception, "kind", None), "no_access")

    def test_a_catalog_dewey_may_not_open_is_named(self):
        R = self.planned()
        self.locked(self.state / "catalog.db")
        for cmd in ("status", "scan", "undo"):  # 0.2.1: "OperationalError: unable to open database file"
            with self.subTest(cmd):
                ev = self.error(cmd, R)
                self.assertEqual(ev["code"], "no_access")
                self.assertIn("catalog.db", ev["message"])

    def test_the_privacy_refusal_reads_the_same(self):
        """macOS answers a folder it protects with EPERM, wherever dewey first touches it."""
        R = self.planned()
        refusal = PermissionError(errno.EPERM, "Operation not permitted", str(self.root))
        with mock.patch.object(catalog, "scan", side_effect=refusal):
            ev = self.error("scan", R)
        self.assertEqual(ev["code"], "no_access")
        self.assertIn(f"open {self.root} (Operation not permitted)", ev["message"])
        self.assertIn("do that", cli._no_access(PermissionError("no file named")))

    def test_a_plan_csv_dewey_may_not_read_doesnt_take_the_folder_with_it(self):
        R = self.planned()
        self.locked(read_plan(self.state)[0])
        status = self.result("status", R)
        self.assertEqual(status["plans"][0]["summary"]["auto"]["n"], 2)  # the counts the plan was made with
        self.assertEqual(self.error("rows", R)["code"], "no_access")


class TheModelOnlyWhenItIsNeeded(Plain):
    """`dewey plan` tries the model once before it sends the queue. 0.2.1 tried it whenever a file
    was left for the model, also when every one of them had its answer from an earlier plan."""

    def setUp(self):
        super().setUp()
        self.srv, self.url = serve(SystemOne)
        self.addCleanup(self.stop_model)
        write(self.root / "Chase_Statement_2024-03.txt", "Chase Freedom statement. Previous balance. Payments.")
        write(self.root / "one.zip", b"11111")

    def stop_model(self):
        if self.srv:
            self.srv.shutdown()
            self.srv.server_close()
            self.srv = None

    def test_a_plan_whose_answers_are_all_known_doesnt_need_the_model_running(self):
        R = str(self.root)
        run("scan", R)
        self.assertIn("Decider ok", run("plan", R, "--url", self.url))
        first = read_plan(self.state)[1]
        self.stop_model()
        out = run("plan", R, "--url", self.url)
        self.assertIn("Reusing 1 cached decisions", out)
        self.assertNotIn("Decider", out)
        again = read_plan(self.state)[1]
        self.assertEqual(len(list(self.state.glob("plan-*.csv"))), 2)
        self.assertEqual([(r["src"], r["dst"], r["status"]) for r in again],
                         [(r["src"], r["dst"], r["status"]) for r in first])

    def test_one_file_without_an_answer_still_needs_it(self):
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--url", self.url)
        self.stop_model()
        write(self.root / "meeting notes.txt", "Meeting minutes. Policy review. Attendees.")
        run("scan", R)
        ev = self.error("plan", R, "--url", self.url)
        self.assertEqual(ev["code"], "decider")
        self.assertEqual(len(list(self.state.glob("plan-*.csv"))), 1)

    def test_a_folder_only_rules_cover_never_asks(self):
        os.remove(self.root / "Chase_Statement_2024-03.txt")
        self.stop_model()
        R = str(self.root)
        run("scan", R)
        self.assertNotIn("Decider", run("plan", R, "--url", self.url))
        self.assertEqual([r["src"] for r in read_plan(self.state)[1]], ["one.zip"])


if __name__ == "__main__":
    unittest.main()
