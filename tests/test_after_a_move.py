"""After a move, dewey says what is done: a plan that was applied has nothing left to move, the latest
batch is the one undo can still put back, a plan's counts follow its CSV, a destination inside the
folder isn't filed a second time, and undo takes away the destination folder apply made.

    python -m unittest discover -s tests -v
"""
from __future__ import annotations

import csv
import errno
import json
import signal
import sqlite3
import sys
import unittest
from contextlib import closing, contextmanager
from datetime import datetime
from pathlib import Path
from unittest import mock

from test_e2e import read_plan, run, snapshot, write
from test_json import run_json
from test_safety import Folder, files

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from dewey import mover  # noqa: E402


class AfterAMove(Folder):
    @property
    def state(self) -> Path:
        return self.root / ".dewey"

    def result(self, *argv, stdin: str = "") -> dict:
        code, events, err = run_json(*argv, stdin=stdin)
        self.assertEqual((code, events[-1]["event"]), (0, "result"), (events[-1], err))
        return events[-1]["data"]

    def edit(self, *edits: dict) -> None:
        self.result("edit", str(self.root), stdin=json.dumps(list(edits)))

    def journals(self) -> list[str]:
        return sorted(p.name for p in (self.state / "moves").glob("*.jsonl"))

    def two_batches(self) -> tuple[str, str, str]:
        """one.zip moved by a first batch, two.zip by a second: (the folder, first, second)."""
        R = self.planned()
        self.edit({"row": 2, "status": "skip"})
        first = self.result("apply", R)["batch"]
        self.edit({"row": 2, "status": "auto"})
        second = self.result("apply", R)["batch"]
        self.assertEqual(files(self.root), ["Archives/one.zip", "Archives/two.zip"])
        return R, first, second


class AnAppliedPlanIsDone(AfterAMove):
    """Rows a batch moved, and no undo has put back, are done. They aren't offered or moved again."""

    def test_a_plan_that_was_applied_has_nothing_left_to_move(self):
        R = self.planned()
        first = self.result("apply", R)
        self.assertEqual(first["counts"]["moved"], 2)
        dry = self.result("apply", R, "--dry-run")  # 0.2.1: the same two rows, ready to move
        self.assertEqual((dry["selected"], dry["already_moved"]), ([], 2))
        self.assertIn("2 already moved", run("apply", R, "--dry-run"))
        rows = self.result("rows", R)["rows"]
        self.assertEqual([(r["verdict"], r["dst"]) for r in rows],
                         [("moved", "Archives/one.zip"), ("moved", "Archives/two.zip")])
        self.assertIn(first["batch"], rows[0]["why"])
        again = self.result("apply", R)  # 0.2.1: a second batch, each row "source no longer exists"
        self.assertEqual((again["batch"], again["counts"]["moved"], again["skipped"]), (None, 0, []))
        self.assertEqual(self.journals(), [f"{first['batch']}.jsonl"])

    def test_once_a_batch_is_undone_its_rows_can_move_again(self):
        R = self.planned()
        self.result("apply", R)
        self.result("undo", R)
        dry = self.result("apply", R, "--dry-run")
        self.assertEqual((len(dry["selected"]), dry["already_moved"]), (2, 0))
        self.assertEqual({r["verdict"] for r in self.result("rows", R)["rows"]}, {"move"})
        self.assertEqual(self.result("apply", R)["counts"]["moved"], 2)
        self.assertEqual(files(self.root), ["Archives/one.zip", "Archives/two.zip"])

    def test_a_row_approved_later_moves_and_the_one_that_moved_is_left_out(self):
        R = self.planned()
        self.edit({"row": 2, "status": "skip"})
        self.assertEqual(self.result("apply", R)["counts"]["moved"], 1)
        self.edit({"row": 2, "status": "auto"})
        dry = self.result("apply", R, "--dry-run")
        self.assertEqual(([s["src"] for s in dry["selected"]], dry["already_moved"]), (["two.zip"], 1))
        second = self.result("apply", R)  # 0.2.1: one.zip was selected again, and skipped as gone
        self.assertEqual((second["counts"]["moved"], second["counts"]["skipped"]), (1, 0))
        self.assertEqual(files(self.root), ["Archives/one.zip", "Archives/two.zip"])

    def test_a_moved_row_says_where_it_is_now(self):
        R = self.planned()
        write(self.root / "Archives" / "one.zip", b"another file took this name after the plan was made")
        self.result("apply", R)
        renamed = self.tmp / "B"
        self.root.rename(renamed)  # and the folder itself was renamed since
        by = {r["src"]: r for r in self.result("rows", str(renamed))["rows"]}
        self.assertEqual((by["one.zip"]["verdict"], by["one.zip"]["dst"]), ("moved", "Archives/one (2).zip"))
        self.assertTrue((renamed / by["one.zip"]["dst"]).is_file())


class TheLatestBatch(AfterAMove):
    """`dewey undo` and the app's "Can be undone" are about the newest batch that can still go back."""

    @contextmanager
    def clock(self, wall: str, iso: str):
        """The time on the wall (a batch id is made from it) and the same moment with its offset."""
        class Then(datetime):
            @classmethod
            def now(cls, tz=None):
                return datetime.strptime(wall, "%Y%m%d-%H%M%S")

        with mock.patch.object(mover, "datetime", Then), mock.patch.object(mover, "now_iso", lambda: iso):
            yield

    def test_an_apply_that_moves_nothing_is_not_a_batch(self):
        R = self.planned()
        (self.root / "one.zip").unlink()
        (self.root / "two.zip").unlink()
        res = self.result("apply", R)  # 0.2.1: a batch id, and a journal that became the latest batch
        self.assertEqual((res["batch"], res["counts"]["moved"], res["counts"]["skipped"]), (None, 0, 2))
        self.assertEqual(self.journals(), [])
        self.assertIsNone(self.result("status", R)["undoable"])
        code, events, _ = run_json("undo", R)
        self.assertEqual((code, events[-1].get("code")), (1, "nothing_to_undo"))
        self.assertNotIn("undo:", run("apply", R))

    def test_a_batch_where_every_move_failed_leaves_nothing_to_undo(self):
        R = self.planned()
        with mock.patch.object(mover, "move_file", side_effect=OSError(errno.EIO, "Input/output error")):
            res = self.result("apply", R)
        self.assertEqual((res["batch"], res["counts"]["moved"], res["counts"]["failed"]), (None, 0, 2))
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])
        self.assertEqual(snapshot(self.root)[1], set())  # the Archives folder made for them is gone again
        self.assertIsNone(self.result("status", R)["undoable"])
        self.assertEqual(len(self.journals()), 1)  # what was tried stays on record

    def test_an_empty_batch_an_older_dewey_wrote_is_not_the_latest(self):
        R = self.planned()
        real = self.result("apply", R)["batch"]
        # 0.2.1 wrote this when Move was pressed a second time: every row skipped, a journal all the same
        empty = "29990101-000000-p1"
        head = {"op": "batch", "batch": empty, "plan_id": 1, "root": R, "dest_root": R,
                "started": "2999-01-01T00:00:00+00:00"}
        end = {"op": "end", "finished": "2999-01-01T00:00:01+00:00", "moved": 0, "skipped": 2, "failed": 0,
               "pruned_dirs": 0}
        write(self.state / "moves" / f"{empty}.jsonl", json.dumps(head) + "\n" + json.dumps(end) + "\n")
        status = self.result("status", R)
        self.assertEqual(status["undoable"], real)  # 0.2.1: the empty one, which `batches` doesn't list
        self.assertIn(status["undoable"], [b["batch"] for b in status["batches"]])
        undone = self.result("undo", R)  # 0.2.1: "restored 0", and the real batch stayed out
        self.assertEqual((undone["batch"], undone["restored"]), (real, 2))
        self.assertIsNone(self.result("status", R)["undoable"])

    def test_batches_are_in_the_order_they_began_whatever_the_clock_said(self):
        R = self.planned()
        self.edit({"row": 2, "status": "skip"})
        with self.clock("20261121-150000", "2026-11-21T15:00:00-05:00"):  # in New York
            first = self.result("apply", R)["batch"]
        self.edit({"row": 2, "status": "auto"})
        with self.clock("20261121-120005", "2026-11-21T12:00:05-08:00"):  # five seconds later, in Los Angeles
            second = self.result("apply", R)["batch"]
        self.assertLess(second, first)  # by its name, the newer batch is the older one
        self.assertEqual(self.result("status", R)["undoable"], second)
        self.assertEqual(self.result("undo", R)["batch"], second)  # 0.2.1: the first one
        self.assertEqual(files(self.root), ["Archives/one.zip", "two.zip"])

    def test_a_batch_that_cant_go_back_doesnt_hide_the_one_before(self):
        R, first, second = self.two_batches()
        (self.root / "Archives" / "two.zip").write_bytes(b"edited since it was filed")
        stuck = self.result("undo", R)
        self.assertEqual((stuck["batch"], stuck["restored"], stuck["skipped"]), (second, 0, 1))
        self.assertEqual(self.result("status", R)["undoable"], first)  # 0.2.1: the second, on every undo
        out = run("undo", R)
        self.assertIn(f"Undo {first}: restored 1", out)
        self.assertIn(f"--batch {second}", out)  # and how to try the one that was passed over
        self.assertEqual(files(self.root), ["Archives/two.zip", "one.zip"])
        with self.assertRaises(SystemExit) as cm:
            run("undo", R)
        self.assertEqual(cm.exception.kind, "nothing_to_undo")
        self.assertIn(second, str(cm.exception.code))
        (self.root / "Archives" / "two.zip").write_bytes(b"22222")  # as it was: asked for by name, it goes back
        self.assertEqual(self.result("undo", R, "--batch", second)["restored"], 1)
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])

    def test_a_stop_before_the_first_file_leaves_no_batch(self):
        R = self.planned()
        real = mover._Hold.begin

        def begin_then_stop(hold):
            real(hold)
            signal.raise_signal(signal.SIGINT)  # Cancel, pressed as the move began
            return hold

        with mock.patch.object(mover._Hold, "begin", begin_then_stop):
            code, events, _ = run_json("apply", R)
        last = events[-1]  # 0.2.1 named a batch here, and the app offered to undo it
        self.assertEqual((code, last["event"], last["batch"]), (130, "interrupted", None))
        self.assertEqual(self.journals(), [])
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])
        self.assertIsNone(self.result("status", R)["undoable"])


class ThePlansCounts(AfterAMove):
    """`status` and `rows` count a plan as its CSV says now, not as it was the day it was made."""

    def counts(self, command: str = "status") -> dict:
        data = self.result(command, str(self.root))
        summary = data["plans"][0]["summary"] if command == "status" else data["summary"]
        return {k: v["n"] for k, v in summary.items() if v["n"]}

    def test_the_counts_follow_edits_and_deleted_lines(self):
        self.planned()
        self.assertEqual(self.counts(), {"auto": 2})
        self.edit({"row": 1, "status": "review"})
        self.assertEqual(self.counts(), {"auto": 1, "review": 1})  # 0.2.1: 2 auto, for good
        self.assertEqual(self.counts("rows"), {"auto": 1, "review": 1})
        csv_path, rows = read_plan(self.state)
        with open(csv_path, "w", newline="", encoding="utf-8-sig") as fh:  # in Numbers: a deleted line means skip
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows[:1])
        self.assertEqual(self.counts(), {"review": 1, "skip": 1})

    def test_rows_that_moved_are_counted_as_moved(self):
        R = self.planned()
        self.edit({"row": 2, "status": "review"})
        self.result("apply", R)
        self.assertEqual(self.counts(), {"review": 1, "moved": 1})  # 0.2.1: 2 auto
        self.assertEqual(self.result("status", R)["plans"][0]["summary"]["moved"], {"n": 1, "bytes": 5})
        self.result("undo", R)
        self.assertEqual(self.counts(), {"auto": 1, "review": 1})

    def test_a_whole_folder_waits_on_its_own_until_someone_decides(self):
        write(self.root / "Letters" / "a.txt", "to whom it may concern")
        write(self.root / "Letters" / "b.txt", "yours faithfully")
        self.planned()
        self.assertEqual(self.counts(), {"auto": 2, "folder": 1})
        _, rows = read_plan(self.state)
        folder = next(int(r["row"]) for r in rows if r["action"] == "folder")
        self.edit({"row": folder, "status": "auto"})
        self.assertEqual(self.counts(), {"auto": 3})

    def test_a_plan_whose_csv_is_gone_keeps_the_counts_it_was_made_with(self):
        self.planned()
        (self.state / "plan-1.csv").unlink()
        self.assertEqual(self.counts(), {"auto": 2})


class ADestinationInsideTheFolder(AfterAMove):
    """`plan.dest` set to a folder inside the one being organized: what is in it is filed, as it would
    be in a destination anywhere else."""

    def settings(self, more: str = "") -> None:
        write(self.state / "dewey.toml", f"[plan]\ndest = {json.dumps(str(self.root / 'Sorted'))}\n{more}")

    def cycle(self) -> dict:
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--backend", "none")
        return self.result("apply", R, "--include-review")

    def under(self, folder: str) -> list[str]:
        return [p for p in files(self.root) if p.startswith(folder + "/")]

    def test_what_is_already_filed_is_not_filed_again(self):
        self.settings("max_depth = -1\n")
        write(self.root / "a.zip", b"zip")
        self.assertEqual(self.cycle()["counts"]["moved"], 1)
        self.assertEqual(files(self.root), ["Sorted/Archives/a.zip"])
        for _ in range(2):
            self.assertEqual(self.cycle()["counts"]["moved"], 0)
            self.assertEqual(files(self.root), ["Sorted/Archives/a.zip"])  # 0.2.1: a (2).zip, then a (2) (2).zip
        self.assertEqual(read_plan(self.state)[1], [])

    def test_a_duplicate_set_aside_there_stays_and_a_new_copy_joins_it(self):
        self.settings("max_depth = -1\n")
        write(self.root / "a.zip", b"the same bytes", mtime=1_600_000_000)
        write(self.root / "b.zip", b"the same bytes", mtime=1_600_000_060)
        self.cycle()
        first = files(self.root)
        self.assertEqual((len(self.under("Sorted/Archives")), len(self.under("Sorted/_Review/Duplicates"))), (1, 1))
        self.cycle()
        self.assertEqual(files(self.root), first)  # 0.2.1: both renamed "… (2).zip"
        kept = self.under("Sorted/Archives")
        write(self.root / "c.zip", b"the same bytes")
        self.cycle()
        self.assertEqual(self.under("Sorted/Archives"), kept)  # the filed copy is the one that stays
        self.assertEqual(len(self.under("Sorted/_Review/Duplicates")), 2)
        self.assertEqual(len(files(self.root)), 3)

    def test_the_destination_is_never_offered_as_a_folder_to_move(self):
        self.settings('[[rules]]\nname = "notes"\next = [".txt"]\ntarget = "Notes"\n')  # default depth: folders stay whole
        write(self.root / "a.txt", "a note")
        write(self.root / "b.txt", "another note")
        self.cycle()
        self.assertEqual(files(self.root), ["Sorted/Notes/a.txt", "Sorted/Notes/b.txt"])
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--backend", "none")
        self.assertEqual(read_plan(self.state)[1], [])  # 0.2.1: a row moving Sorted into Sorted/Documents/Sorted
        self.assertIn("`Sorted/` | a dewey filing folder", (self.state / "report-2.md").read_text())

    def test_a_row_sent_to_where_it_already_is_stays(self):
        write(self.state / "dewey.toml", "[plan]\nmax_depth = -1\n")
        write(self.root / "Sorted" / "Old" / "a.zip", b"zip")
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--backend", "none")  # a.zip: from Sorted/Old to Archives
        with closing(sqlite3.connect(self.state / "catalog.db")) as db:  # as a plan from 0.2.1 had it, with its
            db.execute("UPDATE plans SET dest_root = ?", (str(self.root / "Sorted"),))  # destination inside
            db.commit()
        self.edit({"row": 1, "dst": "Old/a.zip"})  # in that destination, the place it is in now
        self.assertEqual(self.result("rows", R)["rows"][0]["verdict"], "noop")  # 0.2.1: move, to "a (2).zip"
        self.result("apply", R)
        self.assertEqual(files(self.root), ["Sorted/Old/a.zip"])


class UndoTakesBackTheFoldersApplyMade(AfterAMove):
    def test_a_destination_that_wasnt_there_is_gone_again(self):
        for where, dest in (("outside", self.tmp / "Sorted" / "2026"),
                            ("inside", self.tmp / "inside" / "Sorted" / "2026")):
            with self.subTest(dest=where):
                self.root = self.tmp / where
                self.root.mkdir()
                R = self.planned("--dest", str(dest))
                run("apply", R)
                self.assertTrue((dest / "Archives" / "one.zip").is_file())
                self.assertIn("restored 2", run("undo", R))
                self.assertFalse(dest.parent.exists())  # 0.2.1: Sorted/2026 stayed behind, empty
                self.assertEqual(snapshot(self.root)[1], set())
                self.assertEqual(files(self.root), ["one.zip", "two.zip"])

    def test_a_destination_that_was_there_before_stays(self):
        dest = self.tmp / "Sorted"
        dest.mkdir()
        R = self.planned("--dest", str(dest))
        run("apply", R)
        run("undo", R)
        self.assertEqual((dest.is_dir(), list(dest.iterdir())), (True, []))

    def test_a_journal_cant_have_other_empty_folders_removed(self):
        dest = self.tmp / "Sorted" / "2026"
        R = self.planned("--dest", str(dest))
        batch = self.result("apply", R)["batch"]
        elsewhere = self.tmp / "An empty folder of mine"
        beside = self.tmp / "Sorted" / "Also mine"  # in a folder apply made, but not on the way to the destination
        elsewhere.mkdir()
        beside.mkdir()
        with open(self.state / "moves" / f"{batch}.jsonl", "a", encoding="utf-8") as fh:
            for d in (elsewhere, beside, self.root, self.tmp):
                fh.write(json.dumps({"op": "mkdir", "path": str(d)}) + "\n")
        self.assertIn("restored 2", run("undo", R))
        self.assertTrue(elsewhere.is_dir() and beside.is_dir() and self.root.is_dir())
        self.assertFalse(dest.exists())


if __name__ == "__main__":
    unittest.main()
