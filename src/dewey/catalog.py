"""The catalog: one SQLite file per scanned root, at ROOT/.dewey/catalog.db.

Why SQLite and not JSON: it's queryable (`sqlite3 catalog.db "select ..."`), it updates
in place so re-scans only re-hash files whose size/mtime changed, and it doesn't need
to fit in memory or be rewritten whole on every change.
"""
from __future__ import annotations

import hashlib
import os
import sqlite3
import stat
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from . import extract
from .config import STATE_DIRNAME, make_state_dir
from .errors import CONFIG, UNSAFE_ROOT, DeweyExit
from .progress import Progress, human_bytes, say

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS scans (
  id INTEGER PRIMARY KEY, started TEXT, finished TEXT, root TEXT,
  files INTEGER, bytes INTEGER, hashed INTEGER, reused INTEGER, units INTEGER,
  missing INTEGER, errors INTEGER);
CREATE TABLE IF NOT EXISTS files (
  id INTEGER PRIMARY KEY,
  rel_path TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  ext TEXT NOT NULL,
  kind TEXT NOT NULL,              -- file | symlink | bundle | project
  size INTEGER, mtime_ns INTEGER, birth_ns INTEGER, dev INTEGER, inode INTEGER,
  hash TEXT, hash_algo TEXT,
  snippet TEXT, photo_date TEXT, camera TEXT, link_target TEXT,
  first_seen_scan INTEGER, last_seen_scan INTEGER,
  missing INTEGER NOT NULL DEFAULT 0,
  error TEXT);
CREATE INDEX IF NOT EXISTS files_hash ON files(hash);
CREATE INDEX IF NOT EXISTS files_seen ON files(last_seen_scan);
CREATE TABLE IF NOT EXISTS scan_errors (scan_id INTEGER, rel_path TEXT, error TEXT);
CREATE TABLE IF NOT EXISTS decision_cache (
  key TEXT PRIMARY KEY, choice TEXT, confidence REAL, probabilities TEXT,
  decided_by TEXT, note TEXT, created TEXT);
CREATE TABLE IF NOT EXISTS plans (
  id INTEGER PRIMARY KEY, created TEXT, scan_id INTEGER, dest_root TEXT,
  decider TEXT, csv_path TEXT, report_path TEXT, summary TEXT,
  root TEXT);                      -- the folder that day; dest_root follows it if it has moved since
CREATE TABLE IF NOT EXISTS plan_rows (
  plan_id INTEGER, row INTEGER, file_id INTEGER, hash TEXT, size INTEGER,
  src TEXT, dst TEXT, action TEXT, status TEXT, category TEXT, decided_by TEXT,
  confidence REAL, reason TEXT, alternatives TEXT, state TEXT,
  PRIMARY KEY (plan_id, row));
CREATE TABLE IF NOT EXISTS moves (
  id INTEGER PRIMARY KEY, batch TEXT, plan_id INTEGER, row INTEGER, file_id INTEGER,
  hash TEXT, src TEXT, dst TEXT, reason TEXT, decided_by TEXT, confidence REAL,
  category TEXT, moved_at TEXT, undone_at TEXT);
CREATE INDEX IF NOT EXISTS moves_batch ON moves(batch);
CREATE TABLE IF NOT EXISTS labels (
  id INTEGER PRIMARY KEY, file_id INTEGER, hash TEXT, state TEXT, label TEXT,
  proposed TEXT, source TEXT, batch TEXT, created TEXT);
"""

UNIT_KINDS = ("bundle", "project")
SF_DATALESS = 0x40000000  # macOS: iCloud/File Provider placeholder whose bytes aren't on disk
UF_HIDDEN = 0x00008000    # macOS: hidden in Finder without a dot (~/Library is)
PARTIAL_SUFFIX = ".dewey-partial"  # a copy to another disk, until it is verified


def _is_dataless(st) -> bool:
    return bool(getattr(st, "st_flags", 0) & SF_DATALESS)


def _is_hidden(name: str, st) -> bool:
    return name.startswith(".") or bool(getattr(st, "st_flags", 0) & UF_HIDDEN)


def left_alone(rel_path: str, include_hidden: bool) -> bool:
    """A catalog path the planner never touches, whatever an older scan recorded: another folder's
    .dewey, and (unless scan.include_hidden) anything hidden or inside something hidden."""
    parts = rel_path.split("/")
    return STATE_DIRNAME in parts or (not include_hidden and any(p.startswith(".") for p in parts))


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def _private(db: Path) -> None:
    """The catalog holds file names and text previews: readable by its owner only. SQLite gives the
    -wal and -shm files beside it the same permissions as the catalog."""
    try:
        os.close(os.open(db, os.O_RDWR | os.O_CREAT, 0o600))
        for p in (db, Path(f"{db}-wal"), Path(f"{db}-shm")):
            if p.exists() and stat.S_IMODE(p.stat().st_mode) & 0o077:
                os.chmod(p, 0o600)
    except OSError:  # a disk without permissions, or a catalog that isn't ours: sqlite says what's wrong
        pass


def open_db(state_dir: Path) -> sqlite3.Connection:
    make_state_dir(state_dir)
    _private(state_dir / "catalog.db")
    conn = sqlite3.connect(state_dir / "catalog.db")
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(SCHEMA)
    if "root" not in {c["name"] for c in conn.execute("PRAGMA table_info(plans)")}:  # a catalog from before 0.2.1
        conn.execute("ALTER TABLE plans ADD COLUMN root TEXT")
        conn.commit()
    return conn


# Folders dewey won't organize: moving things around in them breaks the system or other people's files.
SYSTEM_TREES = ("/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/dev",
                "/proc", "/sys", "/boot")                       # these and everything inside them
SYSTEM_FOLDERS = ("/private", "/var", "/tmp", "/opt", "/Volumes")  # these themselves; folders inside are fine
CLOUD_FOLDERS = ("Mobile Documents", "CloudStorage")  # in ~/Library: iCloud Drive, Dropbox, Google Drive…


def unsafe_root(root: Path) -> str | None:
    """Why `root` (resolved) is no folder to organize, or None when it is fine."""
    real = lambda p: Path(os.path.realpath(p))
    if root == Path(root.anchor):
        return "it is the whole disk"
    try:
        home = Path.home().resolve()
    except RuntimeError:  # an account without a home folder: only the system's folders to mind
        home = None
    if home and root in home.parents:
        return "it holds your whole home folder, and everyone else's"
    lib = home / "Library" if home else None
    if lib and (root == lib or lib in root.parents):
        inside = root.relative_to(lib).parts
        if not (len(inside) >= 2 and inside[0] in CLOUD_FOLDERS):  # ~/Library/CloudStorage/Dropbox is fine
            return "it is in your Library, where apps keep their own files"
    if any(root == t or t in root.parents for t in map(real, SYSTEM_TREES)):
        return "it belongs to the system"
    if any(root == t for t in map(real, SYSTEM_FOLDERS)):
        return "it belongs to the system"
    return None


def check_safe_root(root: Path) -> None:
    why = unsafe_root(root)
    if why:
        raise DeweyExit(f"dewey won't organize {root}: {why}. Pick a folder of your own files instead.",
                        UNSAFE_ROOT)


def check_root(conn: sqlite3.Connection, root: Path) -> None:
    row = conn.execute("SELECT value FROM meta WHERE key='root'").fetchone()
    if row is None:
        conn.execute("INSERT INTO meta VALUES ('root', ?)", (str(root),))
        conn.commit()
    elif row["value"] != str(root):
        say(f"note: this catalog was created for {row['value']}; now scanning {root}. "
            "Paths are stored relative to the root, so that is fine if you moved the folder.")
        conn.execute("UPDATE meta SET value=? WHERE key='root'", (str(root),))
        conn.commit()


@dataclass
class Entry:
    kind: str
    abs: str
    rel: str
    name: str
    ext: str
    size: int
    mtime_ns: int
    birth_ns: int | None
    dev: int
    inode: int
    link: str | None = None


def hash_file(path: str, algo: str) -> str:
    with open(path, "rb") as fh:
        if algo == "blake3":
            import blake3  # type: ignore
            h = blake3.blake3()
            while chunk := fh.read(1 << 20):
                h.update(chunk)
            return h.hexdigest()
        return hashlib.file_digest(fh, algo).hexdigest()


def _is_bundle_dir(path: str) -> bool:
    """macOS package by structure, for suffixes nobody listed: Foo.whatever/Contents/Info.plist."""
    return any(os.path.lexists(os.path.join(path, "Contents", m)) for m in ("Info.plist", "PkgInfo"))


def _dir_size(path: str) -> int:
    total = 0
    for dp, _dn, fn in os.walk(path, onerror=lambda e: None):
        for f in fn:
            try:
                total += os.lstat(os.path.join(dp, f)).st_size
            except OSError:
                pass
    return total


def walk(root: Path, cfg: dict, state_dir: Path, errors: list):
    """Iterative DFS. Never follows symlinks. Bundles and repos come back as single units.

    skip_dirs only matches directories (not same-named files) and comes from config;
    symlinks are recorded rather than followed (no cycles, no paths escaping the root).
    Hidden files and folders (a leading dot, or hidden in Finder) are passed over unless
    scan.include_hidden: they are settings and app data, not a mess to file. A folder named .dewey
    is another folder's catalog and is passed over always.
    """
    sc = cfg["scan"]
    skip = set(sc["skip_dirs"]) | {STATE_DIRNAME}
    ignore = set(sc["ignore_files"])
    hidden_too = bool(sc.get("include_hidden", False))
    bundles = tuple(s.lower() for s in sc["bundle_suffixes"])
    markers = tuple(sc["project_markers"])
    hash_cloud = bool(sc.get("hash_cloud_files", False))
    state_real = os.path.realpath(state_dir)
    rst = os.stat(root)
    seen = {(rst.st_dev, rst.st_ino)}
    stack = [str(root)]
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except OSError as e:
            errors.append((os.path.relpath(d, root), f"{type(e).__name__}: {e.strerror or e}"))
            continue
        with it:
            for e in it:
                try:
                    if e.is_symlink():
                        st = e.stat(follow_symlinks=False)
                        if not hidden_too and _is_hidden(e.name, st):
                            continue
                        try:
                            target = os.readlink(e.path)
                        except OSError:
                            target = None
                        yield "symlink", e.path, st, target
                    elif e.is_dir(follow_symlinks=False):
                        if e.name in skip or os.path.realpath(e.path) == state_real:
                            continue
                        st = e.stat(follow_symlinks=False)
                        if not hidden_too and _is_hidden(e.name, st):
                            continue
                        key = (st.st_dev, st.st_ino)
                        if key in seen:
                            continue
                        seen.add(key)
                        if e.name.lower().endswith(bundles) or _is_bundle_dir(e.path):
                            yield "bundle", e.path, st, None
                        elif any(os.path.lexists(os.path.join(e.path, m)) for m in markers):
                            yield "project", e.path, st, None
                        else:
                            stack.append(e.path)
                    elif e.is_file(follow_symlinks=False):
                        if e.name not in ignore and not e.name.endswith(PARTIAL_SUFFIX):
                            st = e.stat(follow_symlinks=False)
                            if not hidden_too and _is_hidden(e.name, st):
                                continue
                            yield ("cloud" if not hash_cloud and _is_dataless(st) else "file"), e.path, st, None
                except OSError as ex:
                    errors.append((os.path.relpath(e.path, root), f"{type(ex).__name__}: {ex.strerror or ex}"))


UPSERT = """
INSERT INTO files (rel_path,name,ext,kind,size,mtime_ns,birth_ns,dev,inode,hash,hash_algo,
                   snippet,photo_date,camera,link_target,first_seen_scan,last_seen_scan,missing,error)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?)
ON CONFLICT(rel_path) DO UPDATE SET
  name=excluded.name, ext=excluded.ext, kind=excluded.kind, size=excluded.size,
  mtime_ns=excluded.mtime_ns, birth_ns=excluded.birth_ns, dev=excluded.dev, inode=excluded.inode,
  hash=excluded.hash, hash_algo=excluded.hash_algo, snippet=excluded.snippet,
  photo_date=excluded.photo_date, camera=excluded.camera, link_target=excluded.link_target,
  last_seen_scan=excluded.last_seen_scan, missing=0, error=excluded.error
"""


def _row(e: Entry, scan_id: int, h=None, algo=None, snip=None, pdate=None, cam=None, err=None):
    return (e.rel, e.name, e.ext, e.kind, e.size, e.mtime_ns, e.birth_ns, e.dev, e.inode,
            h, algo, snip, pdate, cam, e.link, scan_id, scan_id, err)


def _work(e: Entry, algo: str, limit: int):
    try:
        h = hash_file(e.abs, algo)
    except OSError as ex:
        return e, None, None, None, None, f"{type(ex).__name__}: {ex.strerror or ex}"
    snip = extract.snippet(e.abs, e.ext, limit)
    pdate, cam = extract.photo_info(e.abs, e.ext)
    return e, h, snip, pdate, cam, None


def scan(conn: sqlite3.Connection, root: Path, cfg: dict, state_dir: Path) -> dict:
    sc = cfg["scan"]
    algo = sc["hash"]
    if algo == "blake3":
        try:
            import blake3  # noqa: F401
        except ImportError:
            raise DeweyExit("scan.hash = 'blake3' but the blake3 package isn't installed (pip install blake3)", CONFIG)
    elif algo not in hashlib.algorithms_available:
        raise DeweyExit(f"unknown hash algorithm: {algo}", CONFIG)
    check_safe_root(root)
    check_root(conn, root)
    cur = conn.execute("INSERT INTO scans (started, root) VALUES (?, ?)", (now_iso(), str(root)))
    scan_id = cur.lastrowid
    conn.commit()

    # 1. walk ---------------------------------------------------------------
    errors: list = []
    entries: list[Entry] = []
    prog = Progress("Walking", unit="entries")
    for kind, path, st, link in walk(root, cfg, state_dir, errors):
        name = os.path.basename(path)
        size = st.st_size
        if kind in UNIT_KINDS:
            prog.update(0, extra=f"sizing {name}")
            size = _dir_size(path)
        entries.append(Entry(kind, path, os.path.relpath(path, root), name,
                             os.path.splitext(name)[1].lower() if kind in ("file", "cloud") else "",
                             size, st.st_mtime_ns, getattr(st, "st_birthtime_ns", None) or
                             (int(st.st_birthtime * 1e9) if hasattr(st, "st_birthtime") else None),
                             st.st_dev, st.st_ino, link))
        prog.update(1, extra="")
    prog.done()

    # 2. work out what actually needs hashing --------------------------------
    existing = {r["rel_path"]: r for r in conn.execute(
        "SELECT id, rel_path, size, mtime_ns, dev, inode, hash, hash_algo, snippet, photo_date, camera FROM files")}
    by_inode = {(r["dev"], r["inode"], r["size"], r["mtime_ns"]): r
                for r in existing.values() if r["hash"] and r["hash_algo"] == algo}
    todo: list[Entry] = []
    unchanged: list[tuple] = []
    reused = units = cloud = 0
    for e in entries:
        if e.kind != "file":
            units += e.kind in UNIT_KINDS
            cloud += e.kind == "cloud"
            conn.execute(UPSERT, _row(e, scan_id))
            continue
        r = existing.get(e.rel)
        if r and r["hash"] and r["hash_algo"] == algo and r["size"] == e.size and r["mtime_ns"] == e.mtime_ns:
            unchanged.append((scan_id, r["id"]))
            continue
        r2 = by_inode.get((e.dev, e.inode, e.size, e.mtime_ns))
        if r2:  # same file, renamed/moved since last scan: reuse its hash
            reused += 1
            conn.execute(UPSERT, _row(e, scan_id, r2["hash"], algo, r2["snippet"], r2["photo_date"], r2["camera"]))
            continue
        todo.append(e)
    conn.executemany("UPDATE files SET last_seen_scan=?, missing=0 WHERE id=?", unchanged)
    conn.commit()
    reused += len(unchanged)
    if unchanged:
        say(f"Reusing hashes for {len(unchanged):,} unchanged files")

    # 3. hash + extract the rest ----------------------------------------------
    total_bytes = sum(e.size for e in todo)
    prog = Progress("Hashing", total=len(todo), total_bytes=total_bytes or None)
    limit = int(sc["snippet_chars"])
    # Not `with ThreadPoolExecutor`: leaving that block waits for the whole queue, so Ctrl-C on a big
    # folder kept hashing to the end. On any exit, queued files are dropped (only the ones in flight
    # finish) and the hashes done so far are kept for the next scan.
    pool = ThreadPoolExecutor(max_workers=max(1, int(sc["workers"])))
    try:
        futures = [pool.submit(_work, e, algo, limit) for e in todo]
        for i, fut in enumerate(as_completed(futures), 1):
            e, h, snip, pdate, cam, err = fut.result()
            conn.execute(UPSERT, _row(e, scan_id, h, algo if h else None, snip, pdate, cam, err))
            if err:
                errors.append((e.rel, err))
            prog.update(1, e.size)
            if i % 1000 == 0:
                conn.commit()
    except BaseException:
        pool.shutdown(wait=False, cancel_futures=True)
        conn.commit()
        raise
    pool.shutdown()
    conn.commit()
    if todo:
        prog.done()

    # 4. anything not seen this scan is gone (scoped to this root's own catalog) ---
    missing = conn.execute("UPDATE files SET missing=1 WHERE last_seen_scan < ? AND missing=0",
                           (scan_id,)).rowcount
    nfiles = sum(1 for e in entries if e.kind == "file")
    nbytes = sum(e.size for e in entries if e.kind == "file")
    conn.execute("UPDATE scans SET finished=?, files=?, bytes=?, hashed=?, reused=?, units=?, missing=?, errors=? WHERE id=?",
                 (now_iso(), nfiles, nbytes, len(todo), reused, units, missing, len(errors), scan_id))
    conn.executemany("INSERT INTO scan_errors VALUES (?, ?, ?)", [(scan_id, r, m) for r, m in errors])
    conn.commit()
    stats = dict(scan_id=scan_id, files=nfiles, bytes=nbytes, hashed=len(todo), reused=reused,
                 units=units, cloud=cloud, missing=missing, errors=len(errors),
                 error_items=[{"path": r, "error": m} for r, m in errors[:50]])
    say(f"Scan {scan_id}: {nfiles:,} files ({human_bytes(nbytes)}), hashed {len(todo):,}, "
        f"reused {reused:,}, {units} bundle/project units, "
        + (f"{cloud:,} cloud-only (not downloaded, skipped), " if cloud else "") +
        f"{missing:,} gone since last scan, "
        f"{len(errors)} errors")
    for rel, msg in errors[:10]:
        say(f"  ! {rel}: {msg}")
    if len(errors) > 10:
        say(f"  ... {len(errors) - 10} more (see `dewey status`)")
    return stats
