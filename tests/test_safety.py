"""Files end up where the person expects: a folder that was renamed or copied applies and undoes
inside itself, hidden files and other folders' catalogs are left alone, system folders are refused,
and a move to another disk keeps Finder tags and the creation date.

    python -m unittest discover -s tests -v
"""
from __future__ import annotations

import csv
import errno
import io
import json
import os
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing, redirect_stderr
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from unittest import mock

from test_e2e import SystemOne, read_plan, run, serve, snapshot, write
from test_json import run_json

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from dewey import catalog, config, decide, extract, macos, mover, planner, remote  # noqa: E402


def files(root: Path) -> list[str]:
    return sorted(snapshot(root)[0])


CAN_LOCK = hasattr(os, "chflags") and hasattr(stat, "UF_IMMUTABLE")


def unlock(p) -> None:
    if os.path.lexists(p):
        os.chflags(p, 0, follow_symlinks=False)


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


class OddNames(Folder):
    def test_a_name_that_starts_or_ends_with_a_space_moves_as_it_is(self):
        names = [" leading.zip", "trailing.zip ", " both .zip ", "plain.zip"]
        for i, name in enumerate(names):
            write(self.root / name, b"zip %d" % i)
        R = str(self.root)
        write(self.root / ".dewey" / "dewey.toml",  # "trailing.zip " has the extension ".zip ": no default rule
              '[[rules]]\nname = "zips"\nname_regex = "zip"\ntarget = "Archives"\n')
        run("scan", R)
        run("plan", R, "--backend", "none")
        code, events, _ = run_json("rows", R)
        rows = {r["src"]: r for r in events[-1]["data"]["rows"]}
        self.assertEqual(sorted(rows), sorted(names))
        self.assertEqual({(r["verdict"], r["edited"]) for r in rows.values()}, {("move", False)}, rows)
        out = run("apply", R)  # 0.2.0: "src was edited in the CSV" for the first three, and nothing moved
        self.assertNotIn("edited", out)
        self.assertEqual(files(self.root), sorted(f"Archives/{n}" for n in names))
        run("undo", R)
        self.assertEqual(files(self.root), sorted(names))

    def test_spaces_typed_around_an_edit_still_dont_count(self):
        write(self.root / " leading.zip", b"zip")
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--backend", "none")
        csv_path, rows = read_plan(self.root / ".dewey")
        rows[0].update(dst="  Old Zips/  ", status=" AUTO ")
        with open(csv_path, "w", newline="", encoding="utf-8-sig") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        run("apply", R)
        self.assertEqual(files(self.root), ["Old Zips/ leading.zip"])


class BrokenSettings(Folder):
    def test_things_come_back_whatever_state_the_settings_file_is_in(self):
        R = self.planned()
        run("apply", R)
        for text in ('[plan]\ndest = "Sorted"\n',  # fine in 0.2.0, a config error since
                     "[plan\n"):
            write(self.root / ".dewey" / "dewey.toml", text)
            with self.assertRaises(SystemExit) as cm:
                run("status", R)
            self.assertEqual(cm.exception.kind, "config")
        self.assertIn("restored 2", run("undo", R))
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])


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


class NothingLeavesTheFence(Folder):
    """A .dewey that came with the folder, or a link inside it, never moves a file somewhere else."""

    def db(self, sql: str, *args):
        conn = sqlite3.connect(self.root / ".dewey" / "catalog.db")
        conn.execute(sql, args)
        conn.commit()
        conn.close()

    def dry_run(self) -> dict:
        code, events, _ = run_json("apply", str(self.root), "--dry-run")
        self.assertEqual(code, 0, events[-1])
        return events[-1]["data"]

    def test_a_link_in_the_folder_cant_send_files_out(self):
        outside = self.tmp / "LaunchAgents"
        outside.mkdir()
        os.symlink(outside, self.root / "Archives")                                  # where the zip rule files things
        R = self.planned()
        d = self.dry_run()
        self.assertEqual(d["selected"], [])
        self.assertEqual({(x["src"], x["why"]) for x in d["refused"]},
                         {(z, "a link in the destination leads out of it on the way (to file somewhere else, "
                              "set plan.dest)") for z in ("one.zip", "two.zip")})
        self.assertIn("2 refused", run("apply", R))
        self.assertEqual(list(outside.iterdir()), [])
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])
        self.assertTrue((self.root / "Archives").is_symlink())

    def test_a_link_that_appears_during_the_batch_is_caught_too(self):
        R = self.planned()
        outside = self.tmp / "LaunchAgents"
        outside.mkdir()
        real = mover.move_file

        def then_plant_a_link(*a, **kw):                                             # once the first file has moved
            how = real(*a, **kw)
            shutil.rmtree(self.root / "Archives")
            os.symlink(outside, self.root / "Archives")
            return how

        with mock.patch.object(mover, "move_file", side_effect=then_plant_a_link):
            out = run("apply", R)
        self.assertIn("skipped 1", out)
        self.assertEqual(list(outside.iterdir()), [])

    def test_a_planted_plan_cant_take_files_from_outside(self):
        secret = self.tmp / "elsewhere" / "secret.txt"
        write(secret, "secret")
        os.symlink(self.tmp / "elsewhere", self.root / "shortcut")
        R = self.planned()
        csv_path, rows = read_plan(self.root / ".dewey")
        for planted in ("../elsewhere/secret.txt", "shortcut/secret.txt", str(secret)):
            with self.subTest(src=planted):
                self.db("UPDATE plan_rows SET src=?, size=6, hash=NULL, file_id=NULL WHERE row=1", planted)
                csv_path.write_text(csv_path.read_text(encoding="utf-8-sig").replace(rows[0]["src"], planted),
                                    encoding="utf-8-sig")
                rows[0]["src"] = planted
                d = self.dry_run()
                self.assertNotIn(planted, [x["src"] for x in d["selected"]])
                self.assertIn(planted, [x["src"] for x in d["refused"]])
                run("apply", R)
                self.assertEqual(secret.read_text(), "secret")

    def test_the_library_and_system_folders_are_never_a_destination(self):
        R = self.planned()
        agents = self.tmp / "Library" / "LaunchAgents"
        agents.mkdir(parents=True)
        with mock.patch.object(Path, "home", return_value=self.tmp):
            for dest in (agents, self.tmp / "Library", Path("/usr/local/dewey-test")):
                with self.subTest(dest=str(dest)):
                    code, events, _ = run_json("plan", R, "--backend", "none", "--dest", str(dest))
                    self.assertEqual((code, events[-1]["code"]), (1, "unsafe_dest"))
                    self.db("UPDATE plans SET dest_root=?", str(dest))                # or planted in the catalog
                    code, events, _ = run_json("apply", R)
                    self.assertEqual((code, events[-1]["code"]), (1, "unsafe_dest"))
            self.db("UPDATE plans SET dest_root=?", str(self.tmp))                    # the home folder itself is allowed…
            code, events, _ = run_json("edit", R, stdin=json.dumps([
                {"row": 1, "dst": "Library/LaunchAgents/one.zip"}, {"row": 2, "dst": ".ssh/two.zip"}]))
            self.assertEqual(code, 0, events[-1])
            d = self.dry_run()                                                        # …its Library and dot-folders aren't
            self.assertEqual(d["selected"], [])
            self.assertEqual(len(d["refused"]), 2)
            self.assertIn("where apps keep their own files", d["refused"][0]["why"])
            self.assertIn("hidden", d["refused"][1]["why"])
        self.assertEqual(list(agents.iterdir()), [])

    def test_a_hidden_folder_is_never_a_destination(self):
        R = self.planned()
        for dest in (self.tmp / ".ssh", self.tmp / ".config" / "launch", self.tmp / ".stash" / "Sorted"):
            with self.subTest(dest=str(dest)):
                dest.mkdir(parents=True)
                code, events, _ = run_json("plan", R, "--backend", "none", "--dest", str(dest))
                self.assertEqual((code, events[-1]["code"]), (1, "unsafe_dest"))
                self.assertIn("hidden", events[-1]["message"])
                self.db("UPDATE plans SET dest_root=?", str(dest))                # or planted in the catalog
                code, events, _ = run_json("apply", R)
                self.assertEqual((code, events[-1]["code"]), (1, "unsafe_dest"))
                self.assertEqual(files(dest), [])
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])

    def test_what_an_older_dewey_filed_into_a_hidden_folder_still_comes_back(self):
        out = self.tmp / ".stash"
        with mock.patch.object(planner, "unsafe_dest", catalog.unsafe_root), \
             mock.patch.object(mover, "unsafe_dest", catalog.unsafe_root):           # all that 0.2.1 asked
            R = self.planned("--dest", str(out))
            run("apply", R)
        self.assertEqual(files(out), ["Archives/one.zip", "Archives/two.zip"])
        code, events, _ = run_json("undo", R)
        self.assertEqual((code, events[-1]["data"]["restored"]), (0, 2), events[-1])
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])

    def journal(self, head: dict, *recs: dict) -> None:
        batch = "20990101-000000-p1"
        write(self.root / ".dewey" / "moves" / f"{batch}.jsonl",
              "\n".join(json.dumps(x) for x in ({"op": "batch", "batch": batch, **head}, *recs)) + "\n")

    def test_a_planted_journal_cant_pull_files_in_from_outside(self):
        R = self.planned()
        docs = self.tmp / "Documents"
        write(docs / "taxes.pdf", "taxes!")
        write(docs / "Taxes" / "2025.pdf", "more")
        (docs / ".settings").mkdir()
        (self.tmp / "Elsewhere").mkdir()
        move = {"op": "move", "row": 1, "size": 6, "mtime_ns": 0}
        self.journal({"root": R, "dest_root": str(docs)},
                     {"op": "mkdir", "path": str(docs / ".settings")},                # empty folders it never made
                     {"op": "mkdir", "path": str(self.tmp / "Elsewhere")},
                     {**move, "kind": "file", "from_rel": "taxes.pdf", "to_rel": "taxes.pdf"},
                     {**move, "kind": "file", "from_rel": "t2.pdf", "to_rel": "taxes.pdf", "algo": "md5",
                      "hash": "d41d8cd98f00b204e9800998ecf8427e"},
                     {**move, "kind": "folder", "from_rel": "Taxes", "to_rel": "Taxes"},
                     {**move, "kind": "folder", "from_rel": "T2", "to_rel": "Taxes", "inode": 2},
                     {**move, "kind": "file", "from_rel": "x.pdf", "to_rel": "../Documents/taxes.pdf"})
        code, events, _ = run_json("undo", R)
        res = events[-1]["data"]
        self.assertEqual((code, res["restored"], res["skipped"], res["dirs_removed"]), (0, 0, 5, 0))
        self.assertTrue((docs / ".settings").is_dir() and (self.tmp / "Elsewhere").is_dir())
        self.assertEqual(files(docs), ["Taxes/2025.pdf", "taxes.pdf"])
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])

    def test_a_planted_journal_cant_name_the_library_as_where_things_went(self):
        R = self.planned()
        with mock.patch.object(Path, "home", return_value=self.tmp):
            self.journal({"root": R, "dest_root": str(self.tmp / "Library" / "Keychains")},
                         {"op": "move", "kind": "file", "row": 1, "size": 1, "from_rel": "k.db", "to_rel": "login.keychain-db"})
            code, events, _ = run_json("undo", R)
        self.assertEqual((code, events[-1]["code"]), (1, "unsafe_dest"))

    def test_real_moves_to_a_folder_outside_still_come_back(self):
        write(self.root / "Shop" / "spool.stl", b"solid spool")                      # a folder that moves whole
        write(self.root / "Shop" / "bracket.stl", b"solid bracket")
        out = self.tmp / "Sorted"
        R = self.planned("--dest", str(out))
        self.assertIn("outside this folder", run("apply", R, "--include-review"))
        self.assertEqual(files(out), ["3D & CAD/Shop/bracket.stl", "3D & CAD/Shop/spool.stl",
                                      "Archives/one.zip", "Archives/two.zip"])
        code, events, _ = run_json("undo", R)
        res = events[-1]["data"]
        self.assertEqual((res["restored"], res["skipped"]), (3, 0))
        self.assertEqual(files(self.root), ["Shop/bracket.stl", "Shop/spool.stl", "one.zip", "two.zip"])
        self.assertEqual(files(out), [])

    def test_a_file_changed_outside_stays_there(self):
        out = self.tmp / "Sorted"
        R = self.planned("--dest", str(out))
        run("apply", R)
        moved = out / "Archives" / "one.zip"
        st = os.stat(moved)
        moved.write_bytes(b"1111X")                                                  # same size, other bytes…
        os.utime(moved, ns=(st.st_atime_ns, st.st_mtime_ns))                         # …and the same modified time
        self.assertIn("restored 1, skipped 1", run("undo", R))
        self.assertTrue(moved.is_file())


class Elsewhere(BaseHTTPRequestHandler):
    """A server that sends every request on to another address."""

    def log_message(self, *a):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(302)
        self.send_header("Location", "http://127.0.0.1:9/elsewhere")
        self.send_header("Content-Length", "0")
        self.end_headers()


class WhatLeavesTheMac(Folder):
    def test_which_urls_are_this_mac(self):
        for url in ("http://127.0.0.1:8000", "http://localhost:8080/v1", "http://[::1]:8000", "https://127.8.9.1"):
            self.assertTrue(decide.is_local(url), url)
        for url in ("http://192.168.1.20:8000", "https://api.example.com/v1", "http://127.0.0.1.example.com",
                    "http://localhost.example.com", "http://0.0.0.0:8000"):
            self.assertFalse(decide.is_local(url), url)

    def sent_headers(self, url: str) -> dict:
        seen = {}

        def answer(req, timeout=None):
            seen.update({k.lower(): v for k, v in req.header_items()})
            return io.BytesIO(b"{}")

        with mock.patch.dict(os.environ, {"DEWEY_API_KEY": "sk-secret"}), \
             mock.patch.object(decide._DIRECT, "open", side_effect=answer), \
             mock.patch.object(decide._OUT, "open", side_effect=answer):
            decide._post(url, {}, 5)
        return seen

    def test_the_api_key_goes_only_to_this_mac_or_over_https(self):
        for url in ("http://127.0.0.1:8000/v1/systemone", "https://api.example.com/v1/chat/completions"):
            self.assertEqual(self.sent_headers(url).get("authorization"), "Bearer sk-secret", url)
        for url in ("http://192.168.1.20:8000/v1/systemone", "http://api.example.com/v1/chat/completions"):
            self.assertNotIn("authorization", self.sent_headers(url), url)

    def test_a_model_on_another_machine_is_said_out_loud(self):
        cfg = config._merge(config.DEFAULTS, {"decider": {"url": "http://192.168.1.20:8000"}})
        err = io.StringIO()
        with redirect_stderr(err), mock.patch.dict(os.environ, {"DEWEY_API_KEY": "sk-secret"}):
            decide.make(cfg)
        self.assertIn("the decision model is at 192.168.1.20, not on this Mac", err.getvalue())
        self.assertIn("DEWEY_API_KEY is not sent over plain http", err.getvalue())
        err = io.StringIO()
        with redirect_stderr(err):
            decide.make(config.DEFAULTS)                                             # 127.0.0.1: nothing to say
            decide.make(cfg, "none")                                                 # rules only: nothing is sent
        self.assertEqual(err.getvalue(), "")

    def elsewhere(self, toml_at: Path) -> dict:
        """The folder is scanned, and `toml_at` names a model server that isn't this Mac."""
        write(self.root / "letter.txt", "Dear Sir or Madam")
        run("scan", str(self.root))
        write(toml_at, '[decider]\nbackend = "chat"\nurl = "https://models.example.com/v1"\n')
        sent = []

        def answer(req, timeout=None):
            sent.append(req.full_url)
            return io.BytesIO(json.dumps({"choices": [{"message": {"content": '{"choice": "other"}'}}]}).encode())

        for p in (mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.tmp / "config")}),
                  mock.patch.object(decide._OUT, "open", side_effect=answer)):
            p.start()
            self.addCleanup(p.stop)
        return sent

    def test_a_server_the_folders_own_settings_name_is_asked_about_first(self):
        R = str(self.root)
        sent = self.elsewhere(self.root / ".dewey" / "dewey.toml")
        for cmd in ("plan", "run", "doctor"):
            code, events, _ = run_json(cmd, R)
            self.assertEqual((code, events[-1]["code"]), (1, "remote_decider"), cmd)
            self.assertIn("to models.example.com, which isn't this Mac.", events[-1]["message"].splitlines()[0])
        self.assertEqual(sent, [])                                                   # nothing went anywhere
        code, events, _ = run_json("plan", R, "--backend", "none")                   # rules only: nothing to ask
        self.assertEqual(code, 0, events[-1])

        code, events, _ = run_json("plan", R, "--allow-remote")
        self.assertEqual(code, 0, events[-1])
        self.assertEqual(set(sent), {"https://models.example.com/v1/chat/completions"})
        self.assertEqual(json.loads(remote.store_path().read_text()),
                         {os.path.realpath(R): ["https://models.example.com"]})
        self.assertEqual(stat.S_IMODE(remote.store_path().stat().st_mode), 0o600)
        code, events, _ = run_json("plan", R)                                        # remembered for this folder
        self.assertEqual(code, 0, events[-1])

        write(self.root / ".dewey" / "dewey.toml", '[decider]\nbackend = "chat"\nurl = "https://other.example.net/v1"\n')
        code, events, _ = run_json("plan", R)                                        # …and only for that server
        self.assertEqual((code, events[-1]["code"]), (1, "remote_decider"))
        moved = self.tmp / "renamed"
        write(self.root / ".dewey" / "dewey.toml", '[decider]\nbackend = "chat"\nurl = "https://models.example.com/v1"\n')
        shutil.copytree(self.root, moved)
        code, events, _ = run_json("plan", str(moved))                               # a copy of the folder asks again
        self.assertEqual((code, events[-1]["code"]), (1, "remote_decider"))

    def test_a_server_the_person_named_themselves_needs_no_asking(self):
        R = str(self.root)
        mine = self.tmp / "my-dewey.toml"
        sent = self.elsewhere(mine)
        code, events, _ = run_json("plan", R, "--config", str(mine))                 # a config file outside the folder
        self.assertEqual(code, 0, events[-1])
        write(self.root / ".dewey" / "dewey.toml", '[decider]\nbackend = "chat"\nurl = "https://planted.example.org"\n')
        code, events, _ = run_json("plan", R, "--url", "https://models.example.com/v1")   # typed on the command line
        self.assertEqual(code, 0, events[-1])
        self.assertEqual(set(sent), {"https://models.example.com/v1/chat/completions"})
        self.assertFalse(remote.store_path().exists())

    def test_a_proxy_is_never_put_in_front_of_this_mac(self):
        srv, url = serve(SystemOne)
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        write(self.root / "Chase_Statement_2024-03.txt", "Chase Freedom statement. Previous balance. Payments.")
        R = str(self.root)
        run("scan", R)
        dead = {k: "http://127.0.0.1:9" for k in ("http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY")}
        with mock.patch.dict(os.environ, {**dead, "no_proxy": "", "NO_PROXY": ""}):
            self.assertIn("Decider ok", run("plan", R, "--url", url))

    def test_a_redirect_is_not_followed(self):
        srv, url = serve(Elsewhere)
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        with self.assertRaisesRegex(decide.DecisionError, "HTTP 302 .* dewey doesn't follow"):
            decide._post(url + "/v1/systemone", {}, 5)

    def test_env_files_are_not_previewed(self):
        write(self.root / "prod.env", "DATABASE_PASSWORD=hunter2\n")
        write(self.root / "notes.txt", "just notes")
        self.assertIsNone(extract.snippet(str(self.root / "prod.env"), ".env", 400))
        self.assertEqual(extract.snippet(str(self.root / "notes.txt"), ".txt", 400), "just notes")


class WhatDeweyKeeps(Folder):
    """The catalog holds file names and text previews, and the readers meet files from anywhere."""

    def mode(self, p: Path) -> int:
        return stat.S_IMODE(p.stat().st_mode)

    def test_the_state_folder_and_the_catalog_are_for_the_owner_only(self):
        self.planned()
        state = self.root / ".dewey"
        self.assertEqual(self.mode(state), 0o700)
        for db in state.glob("catalog.db*"):
            self.assertEqual(self.mode(db), 0o600, db.name)

    def test_a_state_folder_from_an_older_dewey_is_made_private(self):
        R = self.planned()
        state = self.root / ".dewey"
        os.chmod(state, 0o755)
        os.chmod(state / "catalog.db", 0o644)
        run_json("status", R)
        self.assertEqual((self.mode(state), self.mode(state / "catalog.db")), (0o700, 0o600))
        shutil.rmtree(state)
        run("init", R)                                                               # init makes it private too
        self.assertEqual(self.mode(state), 0o700)

    def test_a_state_folder_somewhere_else_keeps_its_permissions(self):
        mine = self.tmp / "shared-notes"
        mine.mkdir()
        os.chmod(mine, 0o755)
        write(self.root / "one.zip", b"11111")
        run("scan", str(self.root), "--state", str(mine))
        self.assertEqual((self.mode(mine), self.mode(mine / "catalog.db")), (0o755, 0o600))

    @unittest.skipIf(extract.pypdf is None, "needs pypdf")
    def test_a_huge_pdf_is_not_opened(self):
        big = self.root / "scan-of-everything.pdf"
        write(big, b"%PDF-1.7\n")
        with mock.patch.object(extract, "PDF_MAX_BYTES", 4), \
             mock.patch.object(extract.pypdf, "PdfReader", side_effect=AssertionError("opened")):
            self.assertEqual(extract.snippet(str(big), ".pdf", 400), "(large PDF; not opened for a preview)")

    def test_the_pdf_reader_asked_for_has_the_fixes(self):
        import tomllib
        extras = tomllib.loads((Path(__file__).resolve().parents[1] / "pyproject.toml").read_text())[
            "project"]["optional-dependencies"]
        for name in ("pdf", "all"):
            self.assertIn("pypdf>=6.21.4", extras[name])


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

    def test_an_interrupt_just_after_the_source_is_gone_keeps_the_copy(self):
        real = os.unlink

        def unlink(p, *a, **kw):
            real(p, *a, **kw)
            if Path(p) == self.src:  # 0.2.1 took this for a failed unlink, and removed the copy as well
                raise KeyboardInterrupt

        with mock.patch.object(mover.os, "unlink", side_effect=unlink):
            with self.assertRaises(KeyboardInterrupt):
                self.move()
        self.assertEqual(self.dst.read_text(), "the report")
        self.assertFalse(self.src.exists())

    def test_a_link_where_the_partial_copy_goes_is_not_written_through(self):
        mine = self.tmp / "notes.txt"
        write(mine, "keep me")
        self.dst.with_name("report.txt.dewey-partial").symlink_to(mine)
        self.assertEqual(self.move(), "copy+verify")
        self.assertEqual(mine.read_text(), "keep me")
        self.assertEqual(self.dst.read_text(), "the report")
        self.assertEqual([(p.name, p.is_symlink()) for p in self.dst.parent.iterdir()], [("report.txt", False)])

    def test_something_that_cant_be_cleared_from_the_partial_copys_name_stops_the_move(self):
        taken = self.dst.with_name("report.txt.dewey-partial")
        taken.mkdir()  # not a file: it can't be removed as one, and nothing is copied into or over it
        with self.assertRaises(FileExistsError):
            self.move()
        self.assertEqual(self.src.read_text(), "the report")
        self.assertEqual([(p.name, p.is_dir(), list(p.iterdir())) for p in self.dst.parent.iterdir()],
                         [("report.txt.dewey-partial", True, [])])

    def test_an_unlink_that_fails_after_it_worked_keeps_the_copy(self):
        real = os.unlink

        def unlink(p, *a, **kw):
            real(p, *a, **kw)
            if Path(p) == self.src:  # some network disks: the file is gone, and the call says it failed
                raise OSError(errno.EIO, "Input/output error")

        with mock.patch.object(mover.os, "unlink", side_effect=unlink):
            self.assertEqual(self.move(), "copy+verify")
        self.assertEqual(self.dst.read_text(), "the report")

    @unittest.skipUnless(CAN_LOCK, "the Finder's Locked box is macOS")
    def test_a_locked_partial_copy_left_by_0_2_1_is_cleared_away(self):
        old = self.dst.with_name("report.txt.dewey-partial")
        write(old, "half of an older copy")
        os.chflags(old, stat.UF_IMMUTABLE)
        self.addCleanup(unlock, old)
        self.assertEqual(self.move(), "copy+verify")
        self.assertEqual(self.dst.read_text(), "the report")
        self.assertEqual([p.name for p in self.dst.parent.iterdir()], ["report.txt"])

    @unittest.skipUnless(CAN_LOCK, "the Finder's Locked box is macOS")
    def test_a_locked_file_that_cant_be_moved_leaves_no_partial_copy(self):
        os.chflags(self.src, stat.UF_IMMUTABLE)  # apply skips these; this is the move itself, asked anyway
        self.addCleanup(unlock, self.src)
        with self.assertRaises(OSError):
            self.move()
        self.assertEqual(self.src.read_text(), "the report")
        self.assertEqual(list(self.dst.parent.iterdir()), [])  # 0.2.1 left a locked .dewey-partial here

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


class StoppedHalfWay(Folder):
    """Ctrl-C, Cancel and Quit stop a move or an undo between two files, never inside one."""

    def moves(self) -> list[tuple]:
        with closing(sqlite3.connect(self.root / ".dewey" / "catalog.db")) as db:
            return db.execute("SELECT row, undone_at IS NOT NULL FROM moves ORDER BY row").fetchall()

    def fresh(self, name: str) -> str:
        self.root = self.tmp / name
        self.root.mkdir()
        return self.planned()

    def signal_at_unlink(self, sig, when: str, nth: int = 1):
        """Every move ends with one unlink. `sig` reaches this process around the nth one: `before`
        it (between the link and the unlink) or `after` it."""
        real, seen = os.unlink, []

        def unlink(p, *a, **kw):
            seen.append(p)
            if when == "before" and len(seen) == nth:
                signal.raise_signal(sig)  # to this thread, so it has arrived by the next line
            real(p, *a, **kw)
            if when == "after" and len(seen) == nth:
                signal.raise_signal(sig)  # to this thread, so it has arrived by the next line

        return mock.patch.object(mover.os, "unlink", side_effect=unlink)

    def test_a_stop_in_the_middle_of_a_file_waits_for_that_file(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            for when in ("before", "after"):
                with self.subTest(sig=sig.name, when=when):
                    R = self.fresh(f"{sig.name}-{when}")
                    with self.signal_at_unlink(sig, when):
                        code, events, _ = run_json("apply", R)
                    self.assertEqual((code, events[-1]["event"]), (130, "interrupted"), events[-1])
                    self.assertTrue(events[-1]["batch"])
                    # 0.2.1: `after` lost one.zip for good, `before` could leave it under both names
                    self.assertEqual(files(self.root), ["Archives/one.zip", "two.zip"])
                    self.assertEqual(self.moves(), [(1, 0)])
                    self.assertIn("restored 1, skipped 0", run("undo", R))
                    self.assertEqual(files(self.root), ["one.zip", "two.zip"])

    def test_a_stop_during_the_last_file_lets_the_batch_finish(self):
        R = self.planned()
        with self.signal_at_unlink(signal.SIGINT, "before", nth=2):
            code, events, _ = run_json("apply", R)
        self.assertEqual((code, events[-1]["event"]), (0, "result"), events[-1])
        self.assertEqual(files(self.root), ["Archives/one.zip", "Archives/two.zip"])
        self.assertEqual(self.moves(), [(1, 0), (2, 0)])

    def test_undo_waits_for_the_file_in_hand_too(self):
        R = self.planned()
        run("apply", R)
        with self.signal_at_unlink(signal.SIGINT, "after"):
            code, events, _ = run_json("undo", R)
        self.assertEqual((code, events[-1]["event"]), (130, "interrupted"), events[-1])
        self.assertEqual(files(self.root), ["Archives/one.zip", "two.zip"])  # newest first: two.zip is back, whole
        self.assertEqual(self.moves(), [(1, 0), (2, 1)])
        self.assertIn("restored 1, skipped 0", run("undo", R))
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])

    def test_in_terminal_a_stop_says_it_is_waiting_for_the_file(self):
        R = self.planned()
        said = []
        with self.signal_at_unlink(signal.SIGINT, "before"), \
             mock.patch.object(mover.os, "write", side_effect=lambda fd, data: said.append((fd, data)) or len(data)):
            with self.assertRaises(SystemExit) as cm:
                run("apply", R)
        self.assertEqual(cm.exception.code, 130)
        self.assertEqual([fd for fd, _ in said], [2])
        self.assertIn(b"Stopping after the file in hand", said[0][1])
        self.assertEqual(files(self.root), ["Archives/one.zip", "two.zip"])

    def test_a_signal_this_dewey_was_told_to_ignore_stays_ignored(self):
        R = self.planned()
        was = signal.signal(signal.SIGINT, signal.SIG_IGN)  # how a script's background job, or nohup, starts it
        try:
            with self.signal_at_unlink(signal.SIGINT, "before"):
                run("apply", R)
            self.assertIs(signal.getsignal(signal.SIGINT), signal.SIG_IGN)
        finally:
            signal.signal(signal.SIGINT, was)
        self.assertEqual(files(self.root), ["Archives/one.zip", "Archives/two.zip"])

    def test_the_handlers_that_were_there_come_back(self):
        R = self.planned()
        mine = lambda *a: None
        was = {sig: signal.signal(sig, mine) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            run("apply", R)
            run("undo", R)
            self.assertEqual([signal.getsignal(sig) for sig in was], [mine, mine])
        finally:
            for sig, handler in was.items():
                signal.signal(sig, handler)

    def test_an_interrupt_just_after_the_source_is_gone_keeps_the_file(self):
        """Where signals can't be held (a library that calls move_file off the main thread), the
        cleanup still doesn't take the only name left."""
        src, dst = self.root / "one.zip", self.root / "Archives" / "one.zip"
        write(src, b"11111")
        dst.parent.mkdir()
        real = os.unlink

        def unlink_then_interrupt(p, *a, **kw):
            real(p, *a, **kw)
            raise KeyboardInterrupt

        with mock.patch.object(mover.os, "unlink", side_effect=unlink_then_interrupt):
            with self.assertRaises(KeyboardInterrupt):
                mover.move_file(src, dst, None, None)
        self.assertEqual(files(self.root), ["Archives/one.zip"])

    def killed_at_unlink(self):
        """A kill or a power cut between a move's link and its unlink: nothing holds those."""
        def unlink(p, *a, **kw):
            raise KeyboardInterrupt

        return mock.patch.object(mover.os, "unlink", side_effect=unlink)

    def test_a_file_a_killed_move_left_under_both_names_comes_back(self):
        R = self.planned()
        with self.killed_at_unlink():
            code, _, _ = run_json("apply", R)
        self.assertEqual(code, 130)
        self.assertEqual(files(self.root), ["Archives/one.zip", "one.zip", "two.zip"])  # one file, two names
        self.assertEqual(self.moves(), [])                                               # only the journal knows
        code, events, _ = run_json("undo", R)
        res = events[-1]["data"]
        self.assertEqual((code, res["restored"], res["skipped"]), (0, 1, 0), events[-1])  # 0.2.1: skipped, for good
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])
        self.assertEqual(os.stat(self.root / "one.zip").st_nlink, 1)

    def test_moving_again_after_a_killed_move_finishes_it(self):
        R = self.planned()
        with self.killed_at_unlink():
            run_json("apply", R)
        self.assertEqual(files(self.root), ["Archives/one.zip", "one.zip", "two.zip"])
        code, events, _ = run_json("apply", R)
        self.assertEqual((code, events[-1]["data"]["counts"]["moved"]), (0, 2), events[-1])
        self.assertEqual(files(self.root), ["Archives/one.zip", "Archives/two.zip"])  # 0.2.1: and "one (2).zip"
        self.assertIn("restored 2, skipped 0", run("undo", R))
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])

    def other_disk(self):
        """The destination is another disk, as far as a move out of the folder can tell."""
        real = mover._noclobber_rename

        def rename(a, b):
            if Path(a).parent == self.root:
                raise OSError(errno.EXDEV, "Cross-device link")
            real(a, b)

        return mock.patch.object(mover, "_noclobber_rename", side_effect=rename)

    def test_a_copy_to_another_disk_killed_before_the_original_went_is_taken_back(self):
        out = self.tmp / "Sorted"
        R = self.planned("--dest", str(out))
        real = os.unlink

        def killed(p, *a, **kw):
            if Path(p) == self.root / "one.zip":
                raise KeyboardInterrupt  # stands in for the kill: the copy has its name, the original is still here
            real(p, *a, **kw)

        with self.other_disk(), mock.patch.object(mover.os, "unlink", side_effect=killed):
            code, _, _ = run_json("apply", R)
        self.assertEqual(code, 130)
        self.assertEqual((files(self.root), files(out)), (["one.zip", "two.zip"], ["Archives/one.zip"]))
        code, events, _ = run_json("undo", R)
        res = events[-1]["data"]
        self.assertEqual((code, res["restored"], res["skipped"]), (0, 1, 0), events[-1])  # 0.2.1: skipped, for good
        self.assertEqual((files(self.root), files(out)), (["one.zip", "two.zip"], []))

    def test_a_different_file_at_the_copys_place_is_not_taken_for_the_copy(self):
        out = self.tmp / "Sorted"
        R = self.planned("--dest", str(out))
        with self.other_disk(), mock.patch.object(mover, "move_file", side_effect=KeyboardInterrupt):
            run_json("apply", R)  # stopped with the move written down and not yet made
        write(out / "Archives" / "one.zip", b"1111X")  # somebody's own file, the same size
        code, events, _ = run_json("undo", R)
        res = events[-1]["data"]
        self.assertEqual((code, res["restored"], res["skipped"]), (0, 0, 1), events[-1])
        self.assertEqual(files(out), ["Archives/one.zip"])

    def test_undo_clears_the_partial_copy_a_killed_move_left(self):
        out = self.tmp / "Sorted"
        R = self.planned("--dest", str(out))

        def killed_mid_copy(src, dst, *a):
            write(dst.with_name(dst.name + ".dewey-partial"), b"111")
            raise KeyboardInterrupt

        with mock.patch.object(mover, "move_file", side_effect=killed_mid_copy):
            run_json("apply", R)
        self.assertEqual(files(out), ["Archives/one.zip.dewey-partial"])
        code, events, _ = run_json("undo", R)
        self.assertEqual(code, 0, events[-1])
        self.assertEqual((files(self.root), files(out)), (["one.zip", "two.zip"], []))

    def test_a_file_a_killed_undo_left_under_both_names_comes_back(self):
        R = self.planned()
        run("apply", R)
        with self.killed_at_unlink():
            code, _, _ = run_json("undo", R)
        self.assertEqual(code, 130)
        self.assertEqual(files(self.root), ["Archives/one.zip", "Archives/two.zip", "two.zip"])
        self.assertIn("restored 2, skipped 0", run("undo", R))
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])
        self.assertEqual(self.moves(), [(1, 1), (2, 1)])

    def test_another_file_at_the_old_place_is_still_left_alone(self):
        R = self.planned()
        run("apply", R)
        write(self.root / "one.zip", b"11111")  # the same bytes, but not the same file
        code, events, _ = run_json("undo", R)
        res = events[-1]["data"]
        self.assertEqual((code, res["restored"], res["skipped"]), (0, 1, 1), events[-1])
        self.assertIn("something now exists at the original path", res["skipped_items"][0]["why"])
        self.assertEqual(files(self.root), ["Archives/one.zip", "one.zip", "two.zip"])

    def test_two_spellings_of_one_name_are_not_two_names(self):
        a, twin, other, link = (self.root / n for n in ("Report.txt", "twin.txt", "other.txt", "link.txt"))
        write(a, "the report")
        write(other, "the report")
        os.link(a, twin)
        link.symlink_to(a)
        self.assertTrue(mover._one_file(a, twin))
        self.assertFalse(mover._one_file(a, other))
        self.assertFalse(mover._one_file(link, a))
        self.assertFalse(mover._one_file(a, self.root / "gone.txt"))
        if (self.root / "report.TXT").exists():  # this disk ignores case: taking one spelling away takes the file
            self.assertFalse(mover._one_file(a, self.root / "report.TXT"))
        write(self.root / "real" / "solo.txt", "one name")
        (self.root / "alias").symlink_to(self.root / "real")  # one folder reached two ways is one name too
        self.assertFalse(mover._one_file(self.root / "real" / "solo.txt", self.root / "alias" / "solo.txt"))


class UndoGoesOn(Folder):
    """A file undo can't read or can't put back is one skipped file. The rest still come back."""

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root reads everything")
    def test_a_file_that_cant_be_read_is_skipped_and_the_rest_come_back(self):
        for where in ("inside", "outside"):
            with self.subTest(dest=where):
                self.root = self.tmp / where
                self.root.mkdir()
                out = self.tmp / "Sorted" if where == "outside" else self.root
                R = self.planned(*(("--dest", str(out)) if where == "outside" else ()))
                run("apply", R)
                moved = out / "Archives" / "one.zip"
                os.utime(moved, ns=(1, 1))  # a new modified time: undo reads the file to see if it changed
                os.chmod(moved, 0)
                code, events, _ = run_json("undo", R)  # 0.2.1: PermissionError, and the same on every later undo
                res = events[-1].get("data") or {}
                self.assertEqual((code, res.get("restored"), res.get("skipped")), (0, 1, 1), events[-1])
                self.assertIn("can't be read", res["skipped_items"][0]["why"])
                os.chmod(moved, 0o644)
                self.assertIn("restored 1, skipped 0", run("undo", R))
                self.assertEqual(files(self.root), ["one.zip", "two.zip"])

    def test_a_file_where_its_old_folder_was_is_one_skipped_file(self):
        write(self.root / ".dewey" / "dewey.toml", "[plan]\nmax_depth = -1\n")
        write(self.root / "inbox" / "three.zip", b"33333")
        R = self.planned()
        run("apply", R, "--prune-empty")
        self.assertFalse((self.root / "inbox").exists())
        write(self.root / "inbox", "a note that took the folder's name")
        code, events, _ = run_json("undo", R)  # 0.2.1: FileExistsError, with one.zip and two.zip still out
        res = events[-1].get("data") or {}
        self.assertEqual((code, res.get("restored"), res.get("skipped")), (0, 2, 1), events[-1])
        self.assertIn("can't be made again", res["skipped_items"][0]["why"])
        self.assertEqual(files(self.root), ["Archives/three.zip", "inbox", "one.zip", "two.zip"])


class DuplicatesNeedTheCopyThatStays(Folder):
    """A duplicate is set aside in the review folder only while the copy the plan kept is still
    there, with the same contents. Otherwise it may be the only one left."""

    def copies(self, *names: str) -> tuple[str, list[str]]:
        """The same bytes under each name, scanned and planned: (the copy that stays, the others)."""
        for i, name in enumerate(names):
            write(self.root / name, b"the same bytes", mtime=1_600_000_000 + i * 60)
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--backend", "none")
        _, rows = read_plan(self.root / ".dewey")
        aside = sorted(r["src"] for r in rows if r["action"] == "duplicate")
        (kept,) = set(names) - set(aside)
        return kept, aside

    def apply(self) -> dict:
        code, events, _ = run_json("apply", str(self.root))
        self.assertEqual(code, 0, events[-1])
        return events[-1]["data"]

    def set_aside(self) -> list[str]:
        return [p.rsplit("/", 1)[1] for p in files(self.root) if p.startswith("_Review/Duplicates/")]

    def test_a_duplicate_is_set_aside_while_the_kept_copy_is_there(self):
        kept, aside = self.copies("a.zip", "b.zip")
        res = self.apply()
        self.assertEqual((res["counts"]["moved"], res["counts"]["skipped"]), (2, 0))
        self.assertEqual(self.set_aside(), aside)
        self.assertIn(f"Archives/{kept}", files(self.root))

    def test_a_duplicate_stays_when_the_kept_copy_was_deleted(self):
        kept, aside = self.copies("a.zip", "b.zip")
        (self.root / kept).unlink()
        res = self.apply()
        self.assertEqual(files(self.root), aside)  # 0.2.1: the last copy went to _Review/Duplicates
        why = {s["src"]: s["why"] for s in res["skipped"]}
        self.assertIn("the copy this duplicates is gone or changed", why[aside[0]])

    def test_a_duplicate_stays_when_the_kept_copy_was_edited(self):
        kept, aside = self.copies("a.zip", "b.zip")
        (self.root / kept).write_bytes(b"THE SAME BYTES")  # the same length, so only reading it tells
        self.apply()
        self.assertEqual(files(self.root), sorted([kept, *aside]))

    def test_a_kept_copy_that_was_only_touched_still_counts(self):
        kept, aside = self.copies("a.zip", "b.zip")
        os.utime(self.root / kept, ns=(5, 5))  # a new modified time, the same bytes
        self.apply()
        self.assertEqual(self.set_aside(), aside)

    def row(self, src: str) -> int:
        _, rows = read_plan(self.root / ".dewey")
        return next(int(r["row"]) for r in rows if r["src"] == src and r["action"] == "duplicate")

    def edit(self, *edits: dict) -> None:
        code, events, _ = run_json("edit", str(self.root), stdin=json.dumps(list(edits)))
        self.assertEqual(code, 0, events[-1])

    def test_a_copy_already_in_the_review_folder_is_not_the_copy_that_stays(self):
        kept, (first, second) = self.copies("a.zip", "b.zip", "c.zip")
        self.edit({"row": self.row(second), "status": "skip"})
        self.apply()  # the first goes to review, the second waits
        self.assertEqual(self.set_aside(), [first])
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--backend", "none")  # a new plan, with one duplicate row: the second
        self.assertTrue(self.row(second))
        kept_now = next(p for p in files(self.root) if p.endswith("/" + kept))
        (self.root / kept_now).unlink()
        self.apply()
        self.assertEqual(self.set_aside(), [first])  # the only other copy left is the one already set aside
        self.assertIn(second, files(self.root))

    def test_renaming_the_review_folder_in_settings_doesnt_switch_the_check_off(self):
        kept, aside = self.copies("a.zip", "b.zip")
        write(self.root / ".dewey" / "dewey.toml", '[plan]\nreview_dir = "_ToCheck"\n')
        (self.root / kept).unlink()
        self.apply()  # the row still says _Review/Duplicates, where the plan sent it
        self.assertEqual(files(self.root), aside)

    def test_a_duplicate_you_filed_somewhere_yourself_is_an_ordinary_move(self):
        kept, aside = self.copies("a.zip", "b.zip")
        self.edit({"row": self.row(aside[0]), "dst": "Keep/mine.zip"})
        (self.root / kept).unlink()
        self.apply()
        self.assertEqual(files(self.root), ["Keep/mine.zip"])

    def test_of_three_copies_none_is_set_aside_once_the_kept_one_is_gone(self):
        kept, aside = self.copies("a.zip", "b.zip", "c.zip")
        self.assertEqual(len(aside), 2)
        (self.root / kept).unlink()
        res = self.apply()
        self.assertEqual(files(self.root), aside)  # each of the two only duplicates the other, which is leaving too
        self.assertEqual(res["counts"]["skipped"], 3)


@unittest.skipUnless(CAN_LOCK, "the Finder's Locked box is macOS")
class LockedFiles(Folder):
    """A file locked in Finder can't be renamed or deleted. It is skipped with a reason."""

    def tearDown(self):
        for d, _, names in os.walk(self.tmp):
            for n in names:
                unlock(os.path.join(d, n))
        super().tearDown()

    def test_a_locked_file_is_skipped_and_says_why(self):
        R = self.planned()
        os.chflags(self.root / "one.zip", stat.UF_IMMUTABLE)
        code, events, _ = run_json("apply", R)
        res = events[-1]["data"]
        self.assertEqual((code, res["counts"]["moved"], res["counts"]["failed"]), (0, 1, 0), events[-1])
        self.assertEqual([(s["src"], "locked in Finder" in s["why"]) for s in res["skipped"]], [("one.zip", True)])
        self.assertEqual(files(self.root), ["Archives/two.zip", "one.zip"])

    def test_an_append_only_file_is_skipped_too(self):
        R = self.planned()
        os.chflags(self.root / "one.zip", stat.UF_APPEND)
        code, events, _ = run_json("apply", R)
        res = events[-1]["data"]
        self.assertEqual((code, res["counts"]["moved"], res["counts"]["failed"]), (0, 1, 0), events[-1])
        self.assertEqual([(s["src"], "append-only" in s["why"]) for s in res["skipped"]], [("one.zip", True)])

    def test_a_file_locked_after_it_was_filed_stays_and_says_why(self):
        R = self.planned()
        run("apply", R)
        os.chflags(self.root / "Archives" / "one.zip", stat.UF_IMMUTABLE)
        code, events, _ = run_json("undo", R)
        res = events[-1]["data"]
        self.assertEqual((code, res["restored"], res["skipped"]), (0, 1, 1), events[-1])
        self.assertIn("locked in Finder", res["skipped_items"][0]["why"])
        unlock(self.root / "Archives" / "one.zip")
        self.assertIn("restored 1, skipped 0", run("undo", R))
        self.assertEqual(files(self.root), ["one.zip", "two.zip"])


if __name__ == "__main__":
    unittest.main()
