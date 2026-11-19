"""Files end up where the person expects: a folder that was renamed or copied applies and undoes
inside itself, hidden files and other folders' catalogs are left alone, system folders are refused,
and a move to another disk keeps Finder tags and the creation date.

    python -m unittest discover -s tests -v
"""
from __future__ import annotations

import errno
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_e2e import read_plan, run, snapshot, write
from test_json import run_json

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from dewey import catalog, macos, mover  # noqa: E402


def files(root: Path) -> list[str]:
    return sorted(snapshot(root)[0])


class Folder(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dewey-safety-")).resolve()
        self.root = self.tmp / "A"
        self.root.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def planned(self, *extra) -> str:
        """Two archives a rule claims, scanned and planned rules-only."""
        write(self.root / "one.zip", b"11111")
        write(self.root / "two.zip", b"22222")
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--backend", "none", *extra)
        return R


class MovedOrCopiedFolder(Folder):
    def test_a_copy_applies_and_undoes_inside_itself(self):
        self.planned()
        copy = self.tmp / "A copy"
        shutil.copytree(self.root, copy)
        out = run("apply", str(copy))
        self.assertIn(f"was made when this folder was at {self.root}", out)
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])                  # the original: untouched
        self.assertEqual(files(copy), ["Archives/one.zip", "Archives/two.zip"])
        self.assertIn("restored 2", run("undo", str(copy)))
        self.assertEqual(files(copy), ["one.zip", "two.zip"])
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])

    def test_undo_works_after_the_folder_is_renamed(self):
        R = self.planned()
        run("apply", R)
        self.assertEqual(files(self.root), ["Archives/one.zip", "Archives/two.zip"])
        renamed = self.tmp / "B"
        self.root.rename(renamed)
        code, events, _ = run_json("undo", str(renamed))
        self.assertEqual(code, 0)
        res = events[-1]["data"]
        self.assertEqual((res["restored"], res["skipped"]), (2, 0))
        self.assertEqual(files(renamed), ["one.zip", "two.zip"])
        self.assertFalse((renamed / "Archives").exists())                           # the folder apply made is gone too
        self.assertFalse(self.root.exists())                                        # nothing reappeared at the old place

    def test_a_renamed_folder_finds_its_plan_and_applies_it(self):
        self.planned()
        renamed = self.tmp / "B"
        self.root.rename(renamed)
        state = renamed / ".dewey"
        code, events, _ = run_json("status", str(renamed))
        plan = events[-1]["data"]["plans"][0]
        self.assertEqual((plan["csv"], plan["report"]), (str(state / "plan-1.csv"), str(state / "report-1.md")))
        code, events, _ = run_json("rows", str(renamed))
        rows = events[-1]["data"]
        self.assertEqual((rows["dest_root"], rows["csv"]), (str(renamed), str(state / "plan-1.csv")))
        code, events, _ = run_json("edit", str(renamed), stdin=json.dumps([{"row": 1, "status": "skip"}]))
        self.assertEqual(events[-1]["data"]["csv"], str(state / "plan-1.csv"))
        run("apply", str(renamed))
        self.assertEqual(len([f for f in files(renamed) if f.startswith("Archives/")]), 1)
        self.assertFalse(self.root.exists())

    def test_a_destination_inside_the_folder_follows_it_and_one_outside_stays(self):
        out = self.tmp / "Sorted elsewhere"
        for dest, lands in ((self.root / "Sorted", lambda r: r / "Sorted"), (out, lambda r: out)):
            with self.subTest(dest=dest.name):
                self.planned("--dest", str(dest))
                renamed = self.tmp / f"B-{dest.name}"
                self.root.rename(renamed)
                run("apply", str(renamed))
                self.assertTrue((lands(renamed) / "Archives" / "one.zip").is_file())
                self.assertFalse(self.root.exists())
                run("undo", str(renamed))
                self.assertTrue((renamed / "one.zip").is_file())
                self.assertFalse((lands(renamed) / "Archives").exists())
                shutil.rmtree(renamed)
                self.root.mkdir()

    def test_a_plan_from_before_0_2_1_follows_the_folder_too(self):
        self.planned()
        conn = sqlite3.connect(self.root / ".dewey" / "catalog.db")
        conn.execute("UPDATE plans SET root = NULL")                                 # 0.2.0 had no such column
        conn.commit()
        conn.close()
        renamed = self.tmp / "B"
        self.root.rename(renamed)
        run("apply", str(renamed))
        self.assertEqual(files(renamed), ["Archives/one.zip", "Archives/two.zip"])
        self.assertFalse(self.root.exists())

    def test_a_journal_entry_without_its_relative_paths_moves_nothing(self):
        R = self.planned()
        outside = self.tmp / "elsewhere" / "secret.txt"
        write(outside, "secret")
        rec = {"op": "move", "kind": "file", "row": 1, "size": 6, "mtime_ns": 0,
               "from": str(self.root / "grabbed.txt"), "to": str(outside)}
        write(self.root / ".dewey" / "moves" / "20990101-000000-p1.jsonl",
              json.dumps({"op": "batch", "batch": "20990101-000000-p1"}) + "\n" + json.dumps(rec) + "\n")
        out = run("undo", R)
        self.assertIn("restored 0, skipped 1", out)
        self.assertTrue(outside.is_file())
        self.assertFalse((self.root / "grabbed.txt").exists())


class HiddenFiles(Folder):
    def scan_paths(self) -> list[str]:
        run("scan", str(self.root))
        conn = sqlite3.connect(self.root / ".dewey" / "catalog.db")
        try:
            return sorted(r[0] for r in conn.execute("SELECT rel_path FROM files WHERE missing=0"))
        finally:
            conn.close()

    def build(self):
        write(self.root / ".hushlogin", b"")
        write(self.root / ".secrets.zip", b"zip")
        write(self.root / ".config" / "tool" / "settings.txt", "a setting")
        write(self.root / ".oh-my-thing" / ".git" / "HEAD", "ref")                  # a hidden project
        write(self.root / "Stuff" / ".env", "KEY=1")
        write(self.root / "Stuff" / "notes.txt", "notes")
        write(self.root / "plain.zip", b"zipzip")
        os.symlink("plain.zip", self.root / ".link")

    def test_hidden_files_and_folders_are_left_alone(self):
        self.build()
        self.assertEqual(self.scan_paths(), ["Stuff/notes.txt", "plain.zip"])
        run("plan", str(self.root), "--backend", "none")
        _, rows = read_plan(self.root / ".dewey")
        self.assertEqual([r["src"] for r in rows], ["plain.zip", "Stuff"])          # Stuff: its whole-folder row

    @unittest.skipUnless(hasattr(os, "chflags"), "needs BSD file flags (macOS)")
    def test_hidden_in_finder_counts_as_hidden(self):
        write(self.root / "Library" / "prefs.txt", "prefs")
        write(self.root / "tucked.zip", b"zip")
        write(self.root / "plain.zip", b"zipzip")
        for name in ("Library", "tucked.zip"):
            os.chflags(self.root / name, catalog.UF_HIDDEN)
        self.assertEqual(self.scan_paths(), ["plain.zip"])

    def test_include_hidden_brings_them_back(self):
        self.build()
        write(self.root / ".dewey" / "dewey.toml", "[scan]\ninclude_hidden = true\n")
        paths = self.scan_paths()
        for p in (".hushlogin", ".secrets.zip", ".config/tool/settings.txt", ".link", "Stuff/.env", ".oh-my-thing"):
            self.assertIn(p, paths)

    def test_a_catalog_from_an_older_scan_still_plans_nothing_hidden(self):
        self.build()
        toml = self.root / ".dewey" / "dewey.toml"
        write(toml, "[scan]\ninclude_hidden = true\n")
        self.scan_paths()                                                            # as 0.2.0 scanned: everything
        toml.unlink()
        run("plan", str(self.root), "--backend", "none")
        _, rows = read_plan(self.root / ".dewey")
        self.assertEqual([r["src"] for r in rows], ["plain.zip", "Stuff"])

    def test_another_folders_catalog_is_never_cataloged(self):
        inner = self.root / "inner"
        write(inner / "a.zip", b"zipzip")
        run("scan", str(inner))
        run("plan", str(inner), "--backend", "none")
        write(self.root / "x.zip.dewey-partial", b"half a copy")
        write(self.root / ".dewey" / "dewey.toml", "[scan]\ninclude_hidden = true\n[plan]\nmax_depth = -1\n")
        self.assertEqual(self.scan_paths(), ["inner/a.zip"])

    def test_git_files_still_mark_a_folder_as_code(self):
        write(self.root / "tool" / ".gitignore", "build/\n")
        write(self.root / "tool" / "notes.txt", "notes")
        run("scan", str(self.root))
        run("plan", str(self.root), "--backend", "none")
        _, rows = read_plan(self.root / ".dewey")
        self.assertEqual([(r["src"], r["category"]) for r in rows], [("tool", "code")])


class UnsafeRoots(unittest.TestCase):
    def test_which_folders_are_refused(self):
        home = Path("/Users/someone")
        with mock.patch.object(Path, "home", return_value=home):
            for p in ("/", "/Users", "/Users/someone/Library", "/Users/someone/Library/Application Support/App",
                      "/Users/someone/Library/Mobile Documents", "/Users/someone/Library/CloudStorage",
                      "/System/Library", "/Library/Fonts", "/Applications", "/usr/local/bin",
                      os.path.realpath("/etc"), os.path.realpath("/tmp"), os.path.realpath("/var"), "/Volumes"):
                self.assertIsNotNone(catalog.unsafe_root(Path(p)), p)
            for p in ("/Users/someone", "/Users/someone/Downloads", "/Users/someone/Documents/Library",
                      "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs",
                      "/Users/someone/Library/CloudStorage/Dropbox/Scans", "/Volumes/Backup", "/Volumes/Backup/Photos",
                      "/Users/Shared/Scans", os.path.realpath("/tmp") + "/scratch"):
                self.assertIsNone(catalog.unsafe_root(Path(p)), p)

    def test_scan_plan_and_apply_refuse_and_undo_still_works(self):
        tmp = Path(tempfile.mkdtemp(prefix="dewey-safety-")).resolve()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        root = tmp / "Library"                                                       # a pretend ~/Library
        write(root / "one.zip", b"11111")
        run("scan", str(root))
        run("plan", str(root), "--backend", "none")
        run("apply", str(root))
        with mock.patch.object(Path, "home", return_value=tmp):
            for cmd in (("scan",), ("plan", "--backend", "none"), ("apply",)):
                code, events, _ = run_json(cmd[0], str(root), *cmd[1:])
                self.assertEqual((code, events[-1]["event"], events[-1]["code"]), (1, "error", "unsafe_root"), cmd)
                self.assertIn("where apps keep their own files", events[-1]["message"])
            code, events, _ = run_json("undo", str(root))                           # what an older dewey moved comes back
            self.assertEqual((code, events[-1]["data"]["restored"]), (0, 1))
        self.assertTrue((root / "one.zip").is_file())


class MoveToAnotherDisk(unittest.TestCase):
    """The copy+verify path, with the first rename made to fail the way a second disk does."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dewey-safety-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.src = self.tmp / "report.txt"
        self.dst = self.tmp / "out" / "report.txt"
        write(self.src, "the report")
        self.dst.parent.mkdir()

    def move(self) -> str:
        real = mover._noclobber_rename
        calls = []

        def other_disk(a, b):
            calls.append(a)
            if len(calls) == 1:
                raise OSError(errno.EXDEV, "Cross-device link")
            real(a, b)

        with mock.patch.object(mover, "_noclobber_rename", side_effect=other_disk):
            return mover.move_file(self.src, self.dst, None, None)

    def test_the_copy_is_synced_before_the_source_is_deleted(self):
        order = []
        real_sync, real_unlink = mover._sync, os.unlink
        with mock.patch.object(mover, "_sync", side_effect=lambda p: (order.append(("sync", Path(p).name)), real_sync(p))), \
             mock.patch.object(mover.os, "unlink", side_effect=lambda p: (order.append(("unlink", Path(p).name)), real_unlink(p))):
            self.assertEqual(self.move(), "copy+verify")
        self.assertEqual(order, [("sync", "report.txt.dewey-partial"), ("unlink", "report.txt.dewey-partial"),
                                 ("sync", "out"), ("unlink", "report.txt")])
        self.assertEqual(self.dst.read_text(), "the report")
        self.assertEqual([p.name for p in self.dst.parent.iterdir()], ["report.txt"])
        self.assertFalse(self.src.exists())

    def test_a_copy_that_cant_be_synced_leaves_the_source(self):
        def disk_error(p):
            raise OSError(errno.EIO, "Input/output error")

        with mock.patch.object(mover, "_sync", side_effect=disk_error):
            with self.assertRaises(OSError):
                self.move()
        self.assertEqual(self.src.read_text(), "the report")
        self.assertEqual(list(self.dst.parent.iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin", "Finder tags and creation dates are macOS")
    def test_finder_tags_where_from_and_the_creation_date_come_along(self):
        attrs = {"com.apple.metadata:kMDItemWhereFroms": "https://example.com/report",
                 "com.apple.metadata:_kMDItemUserTags": "Red"}
        for k, v in attrs.items():
            subprocess.run(["xattr", "-w", k, v, str(self.src)], check=True)
        modified = 1_600_000_000_987_654_321
        os.utime(self.src, ns=(modified, modified))
        created = 1_500_000_000_123_456_789                                         # created years before it was last edited
        macos.set_created_ns(self.src, created)
        self.assertEqual(self.move(), "copy+verify")
        for k, v in attrs.items():
            got = subprocess.run(["xattr", "-p", k, str(self.dst)], capture_output=True, text=True)
            self.assertEqual(got.stdout.strip(), v, k)
        self.assertEqual(macos.created_ns(self.dst), created)
        self.assertEqual(os.stat(self.dst).st_mtime_ns, modified)


if __name__ == "__main__":
    unittest.main()
