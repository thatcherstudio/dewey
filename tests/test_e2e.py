"""End-to-end: build a messy folder, run scan -> plan -> apply -> undo against fake
decision-model servers, and prove undo restores the tree byte-for-byte.

    python -m unittest discover -s tests -v
"""
from __future__ import annotations

import csv
import errno
import hashlib
import io
import json
import math
import os
import shutil
import sqlite3
import sys
import tempfile
import threading
import unittest
import zipfile
from contextlib import closing, redirect_stderr
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from dewey import cli  # noqa: E402

KEYWORDS = [  # (needle, choice, confidence)
    ("statement", "finance", 0.95), ("invoice", "finance", 0.93), ("resume", "personal", 0.90),
    ("guide", "manuals", 0.91), ("meeting", "work", 0.88), ("todo", "notes", 0.70),
    (".py", "code", 0.95), (".csv", "data", 0.92),
]


def fake_choice(state: dict, options: dict) -> tuple[str, float, dict]:
    hay = (state.get("file_name", "") + " " + state.get("extension", "") + " " +
           state.get("text_preview", "")).lower()
    for needle, choice, conf in KEYWORDS:
        if needle in hay and choice in options:
            break
    else:
        choice, conf = "other", 0.45
    rest = (1 - conf) / max(1, len(options) - 1)
    probs = {k: (conf if k == choice else rest) for k in options}
    if choice == "other":
        probs["finance"] = 0.30
    return choice, conf, probs


class SystemOne(BaseHTTPRequestHandler):
    requests: list = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        q = body.get("questions", {}).get("folder", {})
        if self.path != "/v1/systemone" or q.get("type") != "choice" or not isinstance(q.get("criteria"), dict):
            self.send_response(400); self.end_headers(); self.wfile.write(b'{"error":"bad request"}'); return
        SystemOne.requests.append(body)
        choice, conf, probs = fake_choice(body["state"], q["criteria"])
        # like laya-serve 0.4: `confidence` is normalized entropy, `answer_confidence` is p(choice)
        entropy = -sum(p * math.log(p) for p in probs.values() if p > 0)
        out = {"model": "laya-fake-0.1", "answers": {"folder": {
            "type": "choice", "choice": choice, "probabilities": probs, "answer_confidence": conf,
            "confidence": round(1 - entropy / math.log(len(probs)), 4) if len(probs) > 1 else 1.0}}}
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)


class Chat(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        user = body["messages"][-1]["content"]
        state = json.loads(user.split("File:\n", 1)[1])
        choice, conf, _ = fake_choice(state, {k: "" for k in ("finance", "personal", "manuals", "work",
                                                               "notes", "code", "data", "other")})
        text = f'<think>looking at it</think>\n{{"choice": "{choice}", "confidence": 0.99}}'
        data = json.dumps({"choices": [{"message": {"role": "assistant", "content": text}}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)


class Canned(BaseHTTPRequestHandler):
    """Answers every POST with Canned.body, whatever was asked."""
    body = b"{}"

    def log_message(self, *a):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200); self.send_header("Content-Length", str(len(Canned.body))); self.end_headers()
        self.wfile.write(Canned.body)


def serve(handler):
    srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def write(p: Path, data: bytes | str, mtime: float | None = None):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data.encode() if isinstance(data, str) else data)
    if mtime:
        os.utime(p, (mtime, mtime))


def make_docx(p: Path, text: str):
    p.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(p, "w") as z:
        z.writestr("[Content_Types].xml", "<Types/>")
        z.writestr("word/document.xml", f"<w:document><w:body><w:p><w:r><w:t>{text}</w:t></w:r></w:p></w:body></w:document>")


def build_mess(root: Path):
    t0 = 1_700_000_000
    write(root / "invoice_4411.txt", "Invoice #4411. Amount due $120. Thank you for your business.", t0)
    write(root / "copy" / "invoice_4411.txt", "Invoice #4411. Amount due $120. Thank you for your business.", t0 + 50)
    write(root / "Downloads" / "invoice_4411 copy.txt", "Invoice #4411. Amount due $120. Thank you for your business.", t0 - 50)
    write(root / "Chase_Statement_2024-03.txt", "Chase Freedom statement. Previous balance. Payments.")
    write(root / "Screenshot 2025-03-04 at 10.11.12.png", b"\x89PNG fake")
    write(root / "empty.txt", b"")
    write(root / "setup.dmg", b"dmg" * 100)
    write(root / "bracket.stl", b"solid bracket")
    write(root / "Report.final.download", b"partial")
    write(root / "~$budget.xlsx", b"lock")
    make_docx(root / "meeting minutes.docx", "Meeting minutes. Policy review. Attendees.")
    write(root / "todo notes.md", "todo: order feed, fix fence")
    write(root / "Notes" / "todo notes.md", "an older, different note")          # forces a rename
    write(root / "script.py", "print('hi')\n")
    write(root / "data.csv", "a,b\n1,2\n")
    write(root / "mystery.bin", os.urandom(256))
    write(root / "Résumé.txt", "Resume. Work history. Education.")
    write(root / "deep" / "deeper" / "router_guide.txt", "Router user guide. Installation instructions.")
    write(root / ".DS_Store", b"finder junk")
    write(root / "project" / ".git" / "HEAD", "ref: refs/heads/main")
    write(root / "project" / "src" / "main.py", "print('repo')")
    write(root / "Thing.app" / "Contents" / "Info.plist", "<plist/>")
    os.symlink("invoice_4411.txt", root / "link_to_invoice")
    try:
        from PIL import Image
        img = Image.new("RGB", (8, 8))
        exif = img.getexif(); exif[271] = "Apple"; exif[272] = "iPhone 15 Pro"
        exif.get_ifd(0x8769)[36867] = "2023:07:04 12:00:00"
        (root / "photos").mkdir()
        img.save(root / "photos" / "IMG_0001.jpg", exif=exif)
    except ImportError:
        pass


def snapshot(root: Path) -> tuple[dict, set]:
    files, dirs = {}, set()
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d != ".dewey"]
        rel = os.path.relpath(dp, root)
        if rel != ".":
            dirs.add(rel)
        for f in fn:
            p = os.path.join(dp, f)
            r = os.path.relpath(p, root)
            if os.path.islink(p):
                files[r] = "LINK:" + os.readlink(p)
            else:
                with open(p, "rb") as fh:
                    files[r] = hashlib.sha256(fh.read()).hexdigest()
    return files, dirs


def run(*argv) -> str:
    buf = io.StringIO()
    with redirect_stderr(buf):
        cli.main(list(argv))
    return buf.getvalue()


def read_plan(state: Path) -> tuple[Path, list[dict]]:
    p = sorted(state.glob("plan-*.csv"), key=lambda x: int(x.stem.split("-")[1]))[-1]
    with open(p, newline="", encoding="utf-8-sig") as fh:
        return p, list(csv.DictReader(fh))


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="dewey-test-"))
        self.root = self.tmp / "mess"
        self.root.mkdir()
        build_mess(self.root)
        self.state = self.root / ".dewey"
        self.srv, self.url = serve(SystemOne)

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_full_cycle_and_exact_undo(self):
        before = snapshot(self.root)
        R = str(self.root)
        run("init", R)
        toml = self.state / "dewey.toml"                 # opt in to filing files from inside folders
        toml.write_text(toml.read_text().replace("max_depth = 0 ", "max_depth = -1"))
        out = run("scan", R)
        self.assertIn("2 bundle/project units", out)
        out = run("scan", R)
        self.assertIn("hashed 0", out)

        out = run("plan", R, "--url", self.url)
        self.assertIn("Decider ok", out)
        csv_path, rows = read_plan(self.state)
        by_src = {r["src"]: r for r in rows}
        # duplicates: the copy outside Downloads with the oldest birth/mtime stays
        dup_rows = [r for r in rows if r["action"] == "duplicate"]
        self.assertEqual(len(dup_rows), 2)
        self.assertTrue(all(r["dst"].startswith("_Review/Duplicates/") for r in dup_rows))
        # rules
        self.assertEqual(by_src["empty.txt"]["dst"], "_Review/Empty/empty.txt")
        self.assertEqual(by_src["setup.dmg"]["dst"], "Installers/setup.dmg")
        self.assertEqual(by_src["bracket.stl"]["dst"], "3D & CAD/bracket.stl")
        self.assertEqual(by_src["Screenshot 2025-03-04 at 10.11.12.png"]["dst"],
                         "Screenshots/2025/Screenshot 2025-03-04 at 10.11.12.png")   # date from the name
        self.assertEqual(by_src["Report.final.download"]["dst"], "_Review/Junk/Report.final.download")
        self.assertEqual(by_src["~$budget.xlsx"]["dst"], "_Review/Junk/~$budget.xlsx")
        if "photos/IMG_0001.jpg" in by_src:
            self.assertEqual(by_src["photos/IMG_0001.jpg"]["dst"], "Photos/2023/IMG_0001.jpg")
            self.assertIn("iPhone 15 Pro", by_src["photos/IMG_0001.jpg"]["reason"])
        # decision model
        self.assertEqual(by_src["Chase_Statement_2024-03.txt"]["dst"], "Documents/Finance/Chase_Statement_2024-03.txt")
        self.assertEqual(by_src["meeting minutes.docx"]["category"], "work")       # text came from the docx
        self.assertEqual(by_src["todo notes.md"]["status"], "review")               # 0.70 -> review tier
        self.assertEqual(by_src["todo notes.md"]["dst"], "Notes/todo notes (2).md")  # clash with existing file
        self.assertEqual(by_src["mystery.bin"]["status"], "skip")                   # model said "other"
        self.assertEqual(by_src["deep/deeper/router_guide.txt"]["dst"], "Documents/Manuals/router_guide.txt")
        # units, symlinks, ignored files never appear
        for src in by_src:
            self.assertFalse(src.startswith(("project/", "Thing.app")), src)
            self.assertNotIn(".DS_Store", src)
            self.assertNotEqual(src, "link_to_invoice")
        self.assertTrue((self.state / "report-1.md").read_text().count("## Summary") == 1)
        # Laya's context is 512 tokens: the preview we send stays short
        self.assertTrue(all(len(b["state"].get("text_preview", "")) <= 400 for b in SystemOne.requests))

        # edit the CSV like a person would: approve one review row, correct one category, reject one
        for r in rows:
            if r["src"] == "todo notes.md":
                r["status"] = "auto"
            if r["src"] == "Résumé.txt":
                r["category"] = "work"                     # correction -> dst recomputed
            if r["src"] == "script.py":
                r["status"] = "skip"                       # rejection
        with open(csv_path, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)

        out = run("apply", R, "--dry-run")
        self.assertIn("Dry run", out)
        self.assertEqual(snapshot(self.root), before)

        out = run("apply", R, "--prune-empty")
        self.assertIn("Moved", out)
        after, _ = snapshot(self.root)
        self.assertIn("Documents/Finance/Chase_Statement_2024-03.txt", after)
        self.assertIn("Notes/todo notes (2).md", after)
        self.assertIn("Documents/Work/Résumé.txt", after)
        self.assertIn("script.py", after)                          # rejected: stayed
        self.assertIn("mystery.bin", after)                        # unsure: stayed
        self.assertIn("project/src/main.py", after)                # project untouched
        self.assertFalse((self.root / "deep").exists())           # pruned after its only file moved
        batch_json = next((self.state / "moves").glob("*-p1.json"))
        summary = json.loads(batch_json.read_text())
        self.assertEqual(summary["counts"]["failed"], 0)
        moved = {Path(m["from"]).name: m for m in summary["moved"]}
        self.assertIn("reason", moved["setup.dmg"])
        self.assertTrue(summary["undo"].startswith("dewey undo"))

        out = run("export-labels", R)
        labels = [json.loads(l) for l in (self.state / "labels.jsonl").read_text().splitlines()]
        sources = {(l["state"]["file_name"], l["source"], l["label"]) for l in labels}
        self.assertIn(("Résumé.txt", "corrected", "work"), sources)
        self.assertIn(("Chase_Statement_2024-03.txt", "accepted", "finance"), sources)
        run("export-labels", R, "--include-rejected", "-o", str(self.tmp / "all.jsonl"))
        self.assertIn('"rejected"', (self.tmp / "all.jsonl").read_text())

        out = run("scan", R)                                       # catalog followed the moves
        self.assertIn("hashed 0", out)
        out = run("status", R)
        self.assertIn("Batch", out)

        out = run("undo", R)
        self.assertIn("skipped 0", out)
        self.assertEqual(snapshot(self.root), before)              # byte-for-byte, same folders

    def test_default_leaves_every_folder_whole(self):
        write(self.root / "Shop" / "seed-rope" / "spool.stl", b"solid spool")    # a folder without markers
        write(self.root / "Shop" / "seed-rope" / "notes.md", "rope machine notes")
        write(self.root / "Shop" / "seed-rope" / "spool copy.stl", b"solid spool")  # dupe inside a folder
        write(self.root / "spool.stl", b"solid spool")                            # loose dupe of it
        before, R = snapshot(self.root), str(self.root)
        run("scan", R)
        out = run("plan", R, "--url", self.url)
        self.assertIn("whole folders to review", out)
        _, rows = read_plan(self.state)
        files = [r for r in rows if r["action"] != "folder"]
        self.assertEqual([r["src"] for r in files if "/" in r["src"]], [])      # nothing pulled out of a folder
        dup = {r["src"]: r for r in rows if r["action"] == "duplicate"}
        self.assertIn("spool.stl", dup)                                         # loose copy goes to review...
        self.assertIn("Shop/seed-rope/", dup["spool.stl"]["reason"])             # ...the folder's copy is kept
        self.assertIn("invoice_4411.txt", dup)
        folders = {r["src"]: r for r in rows if r["action"] == "folder"}
        self.assertEqual(folders["Shop"]["dst"], "3D & CAD/Shop")                # .stl inside: a 3D project
        self.assertEqual(folders["project"]["dst"], "Code/project")              # .git marker
        self.assertNotIn("Notes", folders)                                       # dewey's own filing folder
        self.assertTrue(all(r["status"] == "review" for r in folders.values()))
        report = (self.state / "report-1.md").read_text()
        self.assertIn("## Folders kept whole", report)
        self.assertIn("| `Shop/` | 3D-print / CAD project |", report)

        run("apply", R)                                                         # auto rows only
        for k in before[0]:
            if "/" in k:
                self.assertTrue((self.root / k).exists(), k)                    # every folder intact

        out = run("apply", R, "--include-review")                               # approve the folder rows
        self.assertIn("whole folders", out)
        after = snapshot(self.root)[0]
        self.assertEqual({k: v for k, v in after.items() if k.startswith("3D & CAD/Shop/")},
                         {"3D & CAD/" + k: v for k, v in before[0].items() if k.startswith("Shop/")})
        self.assertIn("Code/project/src/main.py", after)                        # moved as one piece
        self.assertFalse((self.root / "Shop").exists())
        out = run("scan", R)
        self.assertIn("hashed 0", out)                                          # the catalog followed them
        run("undo", R)
        run("undo", R)
        self.assertEqual(snapshot(self.root), before)

    def edit_plan(self, edits: dict, encoding: str = "utf-8") -> list[dict]:
        csv_path, rows = read_plan(self.state)
        for r in rows:
            r.update(edits.get(r["src"], {}))
        with open(csv_path, "w", newline="", encoding=encoding) as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
        return rows

    def test_folder_category_edits(self):
        write(self.root / "Shop" / "spool.stl", b"solid spool")
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--url", self.url)
        self.edit_plan({"Shop": {"category": "design"},                          # another kind: its home
                        "copy": {"category": "mixed"},                           # a kind with no home: stays
                        "deep": {"category": "cadd"},                            # a typo: refused
                        "project": {"status": "skip"}, "Downloads": {"status": "skip"}})
        out = run("apply", R, "--include-review")
        self.assertTrue((self.root / "Design" / "Shop" / "spool.stl").exists())
        self.assertTrue((self.root / "copy" / "invoice_4411.txt").exists())
        self.assertIn("'cadd' isn't a folder key", out)
        self.assertTrue((self.root / "deep" / "deeper" / "router_guide.txt").exists())

    def test_csv_edits_mean_what_they_say(self):
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--url", self.url)
        csv_path, _ = read_plan(self.state)
        self.assertTrue(csv_path.read_bytes().startswith(b"\xef\xbb\xbf"))   # BOM: Excel reads it as UTF-8
        self.edit_plan({"Chase_Statement_2024-03.txt": {"category": "other"},  # "leave it here"
                        "meeting minutes.docx": {"category": "finanse"},        # typo
                        "data.csv": {"dst": "Data/Exports/"},                   # into a folder, not "rename to Exports"
                        "script.py": {"dst": "Notes"},                          # an existing folder
                        "Résumé.txt": {"category": "work"}},                    # a real correction
                       encoding="utf-8-sig")                                    # as Excel's "CSV UTF-8" saves
        out = run("apply", R)
        self.assertTrue((self.root / "Chase_Statement_2024-03.txt").exists())
        self.assertTrue((self.root / "meeting minutes.docx").exists())
        self.assertIn("'finanse' isn't a folder key", out)
        self.assertTrue((self.root / "Data" / "Exports" / "data.csv").exists())
        self.assertTrue((self.root / "Notes" / "script.py").exists())
        self.assertTrue((self.root / "Documents" / "Work" / "Résumé.txt").exists())   # accented name survived
        run("export-labels", R)
        labels = {(l["state"]["file_name"], l["source"], l["label"])
                  for l in map(json.loads, (self.state / "labels.jsonl").read_text().splitlines())}
        self.assertIn(("Chase_Statement_2024-03.txt", "corrected", "other"), labels)
        self.assertIn(("Résumé.txt", "corrected", "work"), labels)
        self.assertNotIn("meeting minutes.docx", {l[0] for l in labels})       # refused: not a label

    def test_cross_volume_dest_copies_and_verifies(self):
        shm = Path("/dev/shm")
        if not shm.is_dir() or os.stat(shm).st_dev == os.stat(self.tmp).st_dev:
            self.skipTest("no second filesystem available")
        dest = Path(tempfile.mkdtemp(prefix="dewey-dest-", dir=shm))
        try:
            before = snapshot(self.root)
            R = str(self.root)
            run("scan", R)
            run("plan", R, "--backend", "none", "--dest", str(dest))
            out = run("apply", R)
            self.assertIn("Moved", out)
            self.assertTrue((dest / "Installers" / "setup.dmg").is_file())
            summary = json.loads(next((self.state / "moves").glob("*.json")).read_text())
            self.assertTrue(all(m["method"] == "copy+verify" for m in summary["moved"]))
            run("undo", R)
            self.assertEqual(snapshot(self.root), before)
            self.assertEqual(list(dest.iterdir()), [])
        finally:
            shutil.rmtree(dest, ignore_errors=True)

    def test_chat_backend_never_auto_moves_by_default(self):
        srv, url = serve(Chat)
        try:
            R = str(self.root)
            run("scan", R)
            out = run("plan", R, "--backend", "chat", "--url", url, "--model", "qwen-fake")
            self.assertIn("uncalibrated", out)
            _, rows = read_plan(self.state)
            model_rows = [r for r in rows if r["decided_by"].startswith("chat:")]
            self.assertTrue(model_rows)
            self.assertTrue(all(r["status"] != "auto" for r in model_rows))
            self.assertTrue(all(float(r["confidence"]) <= 0.84 for r in model_rows))
        finally:
            srv.shutdown()
            srv.server_close()

    def test_icloud_placeholders_are_not_read(self):
        from unittest import mock
        from dewey import catalog
        real = catalog._is_dataless
        R = str(self.root)
        with mock.patch.object(catalog, "_is_dataless", lambda st: st.st_size == 300 or real(st)), \
             mock.patch.object(catalog, "hash_file", wraps=catalog.hash_file) as hf:
            out = run("scan", R)
            self.assertIn("1 cloud-only", out)
            self.assertFalse(any(str(c.args[0]).endswith("setup.dmg") for c in hf.call_args_list))
        run("plan", R, "--backend", "none")
        _, rows = read_plan(self.state)
        self.assertNotIn("setup.dmg", {r["src"] for r in rows})
        self.assertIn("iCloud placeholders", (self.state / "report-1.md").read_text())

    def test_dead_decider_fails_fast(self):
        R = str(self.root)
        run("scan", R)
        with self.assertRaises(SystemExit):
            run("plan", R, "--url", "http://127.0.0.1:9")

    def doctor(self, *extra) -> tuple[object, str]:
        """Run `dewey doctor`; return (exit code or None, output). Any other exception fails the test."""
        buf = io.StringIO()
        try:
            with redirect_stderr(buf):
                cli.main(["doctor", str(self.root), *extra])
        except SystemExit as e:
            return e.code, buf.getvalue()
        return None, buf.getvalue()

    def test_odd_decider_responses_fail_cleanly(self):
        srv, url = serve(Canned)
        try:
            odd = {  # the real laya-serve response is untested: none of these may crash doctor
                "systemone": [b'{"answers": {"folder": {"choice": "finance", "confidence": null}}}',
                              b'{"answers": {"folder": {"choice": "finance", "confidence": 95}}}',
                              b'{"answers": {"folder": {"choice": "finance", "probabilities": {"finance": "high"}}}}',
                              b'[1, 2]', b'not json', b'\xff\xfe'],
                "chat": [b'{"choices": [{"message": {"content": ["a", "list"]}}]}', b'{"choices": "nope"}'],
            }
            for backend, bodies in odd.items():
                for body in bodies:
                    with self.subTest(backend=backend, body=body):
                        Canned.body = body
                        code, out = self.doctor("--backend", backend, "--url", url)
                        self.assertEqual(code, 1, out)
                        self.assertIn("decider FAILED", out)
            # the tiers use p(choice): answer_confidence, else probabilities[choice], else confidence
            good = [(b'{"answers": {"folder": {"choice": "finance", "confidence": null, "probabilities": {"finance": 0.9}}}}', "0.90"),
                    (b'{"answers": {"folder": {"choice": "finance", "confidence": 0.5, "answer_confidence": 0.92, '
                     b'"probabilities": {"finance": 0.92}}}}', "0.92"),          # laya-serve
                    (b'{"answers": {"folder": {"choice": "finance", "confidence": 0.5, '
                     b'"probabilities": {"finance": 0.9}}}}', "0.90"),           # LAYA_JEV_STRICT
                    (b'{"answers": {"folder": {"choice": "finance", "confidence": 0.8}}}', "0.80")]
            for body, shown in good:
                with self.subTest(body=body):
                    Canned.body = body
                    code, out = self.doctor("--url", url)
                    self.assertIsNone(code, out)
                    self.assertIn(f"answered 'finance' ({shown})", out)
        finally:
            srv.shutdown()
            srv.server_close()

    def test_url_without_scheme_is_a_clear_error(self):
        code, _ = self.doctor("--url", "127.0.0.1:8000")
        self.assertIn("must start with http://", str(code))

    def test_undo_removes_folders_finder_opened(self):
        before = snapshot(self.root)
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--url", self.url)
        run("apply", R)
        write(self.root / "Documents" / "Finance" / ".DS_Store", b"Finder was here")
        write(self.root / "Documents" / ".DS_Store", b"Finder was here")
        run("undo", R)
        self.assertFalse((self.root / "Documents").exists())
        self.assertEqual(snapshot(self.root), before)

    def test_blocked_folder_fails_one_row_not_the_batch(self):
        write(self.root / "Installers", "a plain file where the Installers folder would go")
        before = snapshot(self.root)
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--url", self.url)
        out = run("apply", R)
        self.assertIn("failed 1", out)
        self.assertTrue((self.root / "setup.dmg").is_file())                     # the blocked one stayed
        self.assertTrue((self.root / "Documents" / "Finance" / "Chase_Statement_2024-03.txt").is_file())
        out = run("undo", R)
        self.assertIn("skipped 0", out)
        self.assertEqual(snapshot(self.root), before)

    def test_ctrl_c_during_first_move_is_undoable(self):
        from dewey import mover
        before = snapshot(self.root)
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--url", self.url)
        real = mover.move_file

        def move_then_interrupt(*a, **kw):
            real(*a, **kw)  # the file really moves, then Ctrl-C lands before the database records it
            raise KeyboardInterrupt

        with mock.patch.object(mover, "move_file", side_effect=move_then_interrupt):
            with self.assertRaises(SystemExit) as cm:
                run("apply", R)
        self.assertEqual(cm.exception.code, 130)
        self.assertNotEqual(snapshot(self.root), before)
        out = run("undo", R)                                     # no --batch: must find the interrupted batch
        self.assertIn("restored 1", out)
        self.assertEqual(snapshot(self.root), before)
        with self.assertRaises(SystemExit):                      # and now there's nothing left to undo
            run("undo", R)

    def test_an_undo_that_is_stopped_has_put_back_what_it_says(self):
        from dewey import mover
        before = snapshot(self.root)
        R = str(self.root)
        run("scan", R)
        run("plan", R, "--url", self.url)
        run("apply", R)
        moved = snapshot(self.root)

        def undone() -> int:
            with closing(sqlite3.connect(self.state / "catalog.db")) as db:
                return db.execute("SELECT COUNT(*) FROM moves WHERE undone_at IS NOT NULL").fetchone()[0]

        real, calls = mover.move_file, []

        def three_then_interrupt(*a, **kw):
            if len(calls) == 3:
                raise KeyboardInterrupt
            calls.append(a)
            return real(*a, **kw)

        with mock.patch.object(mover, "move_file", side_effect=three_then_interrupt):
            with self.assertRaises(SystemExit) as cm:
                out = run("undo", R)
        self.assertEqual(cm.exception.code, 130)
        self.assertNotIn(snapshot(self.root), (before, moved))
        self.assertEqual(undone(), 3)  # 0.2.0: 0, so History said nothing had come back
        out = run("undo", R)           # and the rest comes back the same way
        self.assertNotIn("restored 0", out)
        self.assertEqual(snapshot(self.root), before)
        with self.assertRaises(SystemExit):
            run("undo", R)

    def test_failed_cross_volume_copy_leaves_no_partial(self):
        from dewey import mover
        src = self.tmp / "src.bin"
        write(src, b"x" * 4096)
        dst = self.tmp / "out" / "src.bin"
        dst.parent.mkdir()

        def exdev(*a):
            raise OSError(errno.EXDEV, "Cross-device link")

        def half_copy(s, d, **kw):
            Path(d).write_bytes(b"x" * 100)
            raise OSError(errno.ENOSPC, "No space left on device")

        with mock.patch.object(mover, "_noclobber_rename", side_effect=exdev), \
             mock.patch.object(mover.shutil, "copy2", side_effect=half_copy):
            with self.assertRaises(OSError):
                mover.move_file(src, dst, None, None)
        self.assertEqual(list(dst.parent.iterdir()), [])          # no .dewey-partial left on the "drive"
        self.assertEqual(src.read_bytes(), b"x" * 4096)

    def test_projects_without_git_and_unlisted_bundles_stay_whole(self):
        write(self.root / "cool-lib-main" / "package.json", '{"name": "cool-lib"}')   # GitHub ZIP: no .git
        write(self.root / "cool-lib-main" / "README.md", "# cool-lib user guide")
        write(self.root / "cool-lib-main" / "test" / "data.csv", "a,b\n")
        write(self.root / "Odd.thing" / "Contents" / "Info.plist", "<plist/>")        # suffix not listed
        write(self.root / "Odd.thing" / "Contents" / "Resources" / "statement.txt", "statement")
        R = str(self.root)
        out = run("scan", R)
        self.assertIn("4 bundle/project units", out)
        run("plan", R, "--url", self.url)
        _, rows = read_plan(self.state)
        self.assertEqual([r["src"] for r in rows if r["src"].startswith(("cool-lib-main/", "Odd.thing/"))], [])


if __name__ == "__main__":
    unittest.main()
