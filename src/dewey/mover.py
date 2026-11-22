"""Apply a reviewed plan, keep a crash-safe journal, and undo it exactly.

Journal: ROOT/.dewey/moves/<batch>.jsonl, append-only, fsync'd per line, and each move
is written BEFORE it happens. If the process dies mid-run, the journal still names every
file that might have moved, and undo checks the disk rather than trusting the log.
At the end a pretty <batch>.json is written with what moved, where, and why.

Safety: never overwrites (hard-link + unlink, or check-then-rename where hard links aren't
supported), re-hashes a file if it changed since the scan, copies and verifies the hash
before deleting the source when crossing volumes, and never deletes anything else.

Paths: a plan and a journal belong to the folder, not to where the folder was that day. Both keep
paths relative to it, so a folder that was renamed, copied or mounted under another name applies
and undoes inside itself. Only a plan.dest outside the folder stays where it was.

Trust: a .dewey folder can arrive with the folder (a zip, a shared drive), plan, journal and all,
and so can links inside the folder. So nothing in them is believed about where files may go: every
move starts inside the folder and ends inside the destination with links followed (`Fence`), and a
destination outside the folder is never the Library, a system folder or anything hidden. Undo
takes something back from outside only when it is the very thing dewey moved (hash, or inode).
"""
from __future__ import annotations

import csv
import errno
import hashlib
import io
import json
import os
import shutil
import signal
import sqlite3
import stat
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path, PurePosixPath

from . import macos
from .catalog import PARTIAL_SUFFIX, hash_file, now_iso, unsafe_dest, unsafe_root
from .errors import BAD_EDIT, NO_PLAN, NOTHING_TO_UNDO, STALE, UNSAFE_DEST, DeweyExit
from .planner import CSV_FIELDS, DECIDER_PREFIXES, norm_key, plan_files
from .progress import Progress, human_bytes, json_mode, say

try:
    import fcntl
except ImportError:  # not a Unix: plain fsync it is
    fcntl = None

PRUNABLE = {".DS_Store"}


class Journal:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.fh = open(path, "a", encoding="utf-8")

    def write(self, rec: dict) -> None:
        self.fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        self.fh.flush()
        os.fsync(self.fh.fileno())

    def close(self) -> None:
        self.fh.close()


class _Hold:
    """Ctrl-C, Cancel and Quit (SIGINT, SIGTERM) wait for the file in hand.

    Python turns a signal into a KeyboardInterrupt wherever it happens to be. In the middle of a move
    that was between the link and the unlink (the file stayed under both names), or just after the
    unlink, inside the `try` whose cleanup then removed the other name as well: the file was gone.
    So while a batch moves files the signal is only noted, and `stop_if_asked()`, called between two
    files, raises the KeyboardInterrupt there. Off the main thread Python delivers no signals, and
    there is nothing to hold.
    """

    def __init__(self):
        self.asked = False
        self._saved: dict = {}

    def begin(self) -> "_Hold":
        try:
            for sig in (signal.SIGINT, signal.SIGTERM):
                if signal.getsignal(sig) is not signal.SIG_IGN:  # told to ignore it (`nohup`, a script): still ignored
                    self._saved[sig] = signal.signal(sig, self._note)
        except ValueError:  # not the main thread
            pass
        return self

    def _note(self, signum, frame) -> None:
        if not self.asked and not json_mode():  # in Terminal, a big copy to another disk can take minutes more
            try:  # straight to the terminal: print() may be half way through a line of its own
                os.write(2, b"\nStopping after the file in hand...\n")
            except OSError:
                pass
        self.asked = True

    def end(self) -> None:
        for sig, handler in self._saved.items():
            signal.signal(sig, signal.SIG_DFL if handler is None else handler)  # None: set from C, not Python
        self._saved = {}

    def stop_if_asked(self) -> None:
        if self.asked:
            raise KeyboardInterrupt


_IMMUTABLE = getattr(stat, "UF_IMMUTABLE", 0) | getattr(stat, "SF_IMMUTABLE", 0)
_APPEND_ONLY = getattr(stat, "UF_APPEND", 0) | getattr(stat, "SF_APPEND", 0)


def _locked(st: os.stat_result) -> str | None:
    """Why macOS won't rename or delete this, nor a copy of it (a copy gets the same flags), or None."""
    flags = getattr(st, "st_flags", 0)
    if flags & _IMMUTABLE:
        return "locked in Finder (Get Info > Locked)"
    if flags & _APPEND_ONLY:
        return "marked append-only (chflags uappnd)"
    return None


def _one_file(a: Path, b: Path) -> bool:
    """Two names of one regular file (hard links): what a move cut off between its link and its
    unlink leaves behind. Neither name is followed if it is a link.

    Two spellings of ONE name (`A.txt` and `a.txt` in the same folder of a disk that ignores case)
    are not two names: taking one away would take the file."""
    try:
        sa, sb = os.lstat(a), os.lstat(b)
        if not stat.S_ISREG(sa.st_mode) or (sa.st_dev, sa.st_ino) != (sb.st_dev, sb.st_ino) or sa.st_nlink < 2:
            return False
        return norm_key(a.name) != norm_key(b.name) or not os.path.samefile(a.parent, b.parent)
    except OSError:
        return False


def _noclobber_rename(src: Path, dst: Path) -> None:
    """Same-filesystem move that can never overwrite dst."""
    try:
        os.link(src, dst)
    except FileExistsError:
        raise
    except OSError as e:
        if e.errno == errno.EXDEV:
            raise
        # no hard links here (exFAT, some SMB/FUSE): check, then rename
        if os.path.lexists(dst):
            raise FileExistsError(errno.EEXIST, "destination exists", str(dst)) from None
        os.rename(src, dst)
        return
    try:
        os.unlink(src)
    except OSError:  # only when the unlink itself failed: anything else may arrive after it worked
        if not os.path.lexists(src):  # it worked, whatever it said (a network disk can): the move is done
            return
        os.unlink(dst)  # our own hard link to src; drop it so the file isn't in two places
        raise


def _drop(partial: Path) -> None:
    """Remove a partial copy. Never follows a link, and never raises: the error that led here is the
    one to report. A copy of a locked file is locked too, and macOS deletes it only once unlocked."""
    try:
        if _locked(os.lstat(partial)):
            os.chflags(partial, 0, follow_symlinks=False)
        os.unlink(partial)
    except (OSError, AttributeError, NotImplementedError):
        pass


def _sync(path) -> None:
    """Push a file or folder all the way to the disk. On macOS fsync stops at the drive's own cache,
    which an unplugged drive loses; F_FULLFSYNC doesn't. A filesystem that can do neither is left be."""
    fd = os.open(path, os.O_RDONLY)
    try:
        try:
            fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
            return
        except (AttributeError, OSError):  # not macOS, or not on this filesystem
            pass
        try:
            os.fsync(fd)
        except OSError as e:
            if e.errno not in (errno.EINVAL, errno.ENOTSUP):
                raise
    finally:
        os.close(fd)


def move_file(src: Path, dst: Path, expected_hash: str | None, algo: str | None) -> str:
    try:
        _noclobber_rename(src, dst)
        return "rename"
    except OSError as e:
        if e.errno != errno.EXDEV:
            raise
    tmp = dst.with_name(dst.name + PARTIAL_SUFFIX)
    if os.path.lexists(tmp):  # left by a move that was cut off, or put there: never copied over or through
        _drop(tmp)
    # New and ours, or this move fails here: something under that name that couldn't be dropped (a
    # link, in a folder that won't let go of it) is not written through.
    os.close(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
    try:  # the copy itself is inside: a full disk or Ctrl-C mid-copy must not leave a partial behind
        shutil.copy2(src, tmp)
        macos.keep_metadata(src, tmp)  # Finder tags, "where from", creation date: copy2 drops them
        if expected_hash and algo and hash_file(str(tmp), algo) != expected_hash:
            raise RuntimeError("copy verification failed (hash mismatch); source left untouched")
        _sync(tmp)  # on the disk, not in a cache, before the only other copy is deleted
        _noclobber_rename(tmp, dst)
    except BaseException:
        _drop(tmp)
        raise
    try:
        try:
            _sync(dst.parent)  # its name too, where the disk can do that; the bytes are already safe
        except OSError:
            pass
        os.unlink(src)
    except OSError:  # only when the unlink itself failed: anything else may arrive after it worked
        if os.path.lexists(src):
            dst.unlink(missing_ok=True)  # our verified copy; the source is still intact
            raise
    return "copy+verify"


def move_dir(src: Path, dst: Path) -> str:
    """Rename a whole folder on the same disk; nothing inside it is opened or changed.

    Never replaces anything: an existing name is refused here, and rename(2) itself refuses to
    replace a folder that has anything in it (the only race left is an empty folder appearing).
    """
    if os.path.lexists(dst):
        raise FileExistsError(errno.EEXIST, "destination exists", str(dst))
    os.rename(src, dst)
    return "rename"


def _free(dst: Path, reserved: set[str], keep_ext: bool = True) -> Path:
    stem, ext = os.path.splitext(dst.name) if keep_ext else (dst.name, "")
    cand, n = dst, 1
    while os.path.lexists(cand) or norm_key(str(cand)) in reserved:
        n += 1
        cand = dst.with_name(f"{stem} ({n}){ext}")
    reserved.add(norm_key(str(cand)))
    return cand


def _safe_rel(p: str) -> bool:
    pp = PurePosixPath(p)
    return bool(p) and not pp.is_absolute() and ".." not in pp.parts and not p.startswith("~")


def _is_rel(p) -> bool:
    """A path dewey itself recorded relative to a folder: text, not absolute, never climbing out."""
    return isinstance(p, str) and bool(p) and not PurePosixPath(p).is_absolute() and ".." not in PurePosixPath(p).parts


def _same_folder(a: Path, b: Path) -> bool:
    try:
        return a == b or os.path.samefile(a, b)  # ~/downloads and ~/Downloads are one folder on a Mac
    except OSError:  # one of them isn't there any more
        return False


def _moved_with(path: Path, was: Path, now: Path) -> Path:
    """`path` as it is now that the folder once at `was` is at `now`. A path that was never inside
    that folder (a plan.dest on another disk) is where it always was."""
    if was == now:
        return path
    if path == was:
        return now
    try:
        return now / path.relative_to(was)
    except ValueError:
        return path


def _under(path: str, base: str) -> bool:
    return path == base or path.startswith(base.rstrip("/") + "/")


class Fence:
    """Keeps moves between a folder and its destination, whatever a plan, a journal or a link says."""

    def __init__(self, root: Path, dest_root: Path):
        self.root, self.dest_root = root, dest_root
        self._root, self._dest = os.path.realpath(root), os.path.realpath(dest_root)
        self.outside = not _under(self._dest, self._root)  # files leave the folder
        self._real: dict[str, str] = {}

    def _realdir(self, d: Path, fresh: bool) -> str:
        key = str(d)
        if fresh or key not in self._real:  # fresh: during a batch, folders appear as it goes
            self._real[key] = os.path.realpath(d)
        return self._real[key]

    def dest_problem(self, undoing: bool = False) -> str | None:
        """Why nothing may be filed into this destination at all.

        Undo only brings back what dewey itself put there (same hash, or the same folder), so it still
        reaches a hidden folder that a dewey before 0.2.2 was allowed to file into."""
        if not self.outside:
            return None
        why = (unsafe_root if undoing else unsafe_dest)(Path(self._dest))
        return f"{self.dest_root} is no place to file into: {why}" if why else None

    def problem(self, in_folder: str, in_dest: str, fresh: bool = False) -> str | None:
        """Why a move between these two relative paths (either direction) isn't allowed, or None."""
        if not _is_rel(in_folder):
            return "its path in this folder isn't a path inside it"
        if not _is_rel(in_dest):
            return "its path in the destination isn't a path inside it"
        if not _under(self._realdir((self.root / in_folder).parent, fresh), self._root):
            return "a link in this folder leads out of it on the way"
        there = self._realdir((self.dest_root / in_dest).parent, fresh)
        if not _under(there, self._dest):
            return "a link in the destination leads out of it on the way (to file somewhere else, set plan.dest)"
        if self.outside:
            if any(part.startswith(".") for part in PurePosixPath(in_dest).parts):
                return "its place in the destination is hidden, and outside this folder"
            why = unsafe_root(Path(there))
            if why:
                return f"its place in the destination is {there}: {why}"
        return None

    def made_here(self, d: Path) -> bool:
        """`d` is somewhere apply could have made a folder: undo may remove it if it is empty."""
        try:
            inside = d.relative_to(self.dest_root).as_posix()
        except ValueError:
            return False
        return inside != "." and self.problem("x", f"{inside}/x", fresh=True) is None


def _is_what_moved(rec: dict, st: os.stat_result, path: Path) -> bool:
    """`path`, outside the folder, is the very file or folder this journal entry says dewey put there.
    A file by its contents; a folder (moved by rename, which keeps both) by its inode and creation
    time. Nobody who wrote a journal by hand knows those of somebody else's folder."""
    if stat.S_ISREG(st.st_mode) and rec.get("algo") in ("sha256", "blake3") and isinstance(rec.get("hash"), str):
        return st.st_size == rec.get("size") and hash_file(str(path), rec["algo"]) == rec["hash"]
    if not isinstance(rec.get("inode"), int) or st.st_ino != rec["inode"]:
        return False
    return rec.get("born") is None or rec["born"] == getattr(st, "st_birthtime", None)


def plan_root(conn, plan) -> Path | None:
    """The folder a plan was made for, as it was called that day."""
    was = plan["root"]
    if not was:  # a plan from before 0.2.1: the root its scan recorded
        row = conn.execute("SELECT root FROM scans WHERE id=?", (plan["scan_id"],)).fetchone()
        was = row["root"] if row else None
    return Path(was) if was else None


def plan_dest(conn, plan, root: Path) -> Path:
    """Where a plan files things for the folder as it is now: inside `root` when it was inside the
    folder the plan was made for, wherever that folder has gone since."""
    was = plan_root(conn, plan)
    dest = Path(plan["dest_root"])
    return _moved_with(dest, was, root) if was else dest


def _label_for(dst: str, category: str, cats: dict) -> str | None:
    d = os.path.dirname(dst)
    if category in cats and cats[category]["path"] and norm_key(d).startswith(norm_key(cats[category]["path"])):
        return category
    for k, v in cats.items():
        if v["path"] and norm_key(d) == norm_key(v["path"]):
            return k
    return None


def _latest_plan(conn, plan_id: int | None):
    q = "SELECT * FROM plans WHERE id=?" if plan_id else "SELECT * FROM plans ORDER BY id DESC LIMIT 1"
    plan = conn.execute(q, (plan_id,) if plan_id else ()).fetchone()
    if not plan:
        raise DeweyExit("no plan found; run `dewey plan` first", NO_PLAN)
    return plan


def _homes(cfg: dict) -> dict:
    """[folders] kinds that have a home (`move = true` is a switch, not a kind)."""
    return {k: v for k, v in (cfg.get("folders") or {}).items() if isinstance(v, str)}


def read_plan_csv(csv_path: Path) -> tuple[bytes, list[str], list[dict]]:
    """(raw bytes, header, rows) of a plan CSV as the person last saved it."""
    try:
        data = csv_path.read_bytes()
    except FileNotFoundError:
        raise DeweyExit(f"{csv_path} is missing; run `dewey plan` again", NO_PLAN) from None
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as e:
        raise DeweyExit(f"{csv_path.name} isn't UTF-8 (in Excel, save as \"CSV UTF-8\"): {e}", BAD_EDIT) from None
    rd = csv.DictReader(io.StringIO(text, newline=""))
    rows = list(rd)
    return data, list(rd.fieldnames or []), rows


def edits_by_row(rows: list[dict]) -> dict[int, dict]:
    edits = {}
    for e in rows:
        try:
            edits[int(e["row"])] = e
        except (KeyError, ValueError, TypeError):
            continue
    return edits


@dataclass
class Resolution:
    """What apply will do with one plan row, given the CSV as it is now."""
    status: str        # from the CSV; "skip" when the line was deleted
    dst: str           # after a category change or "into this folder"
    category: str
    verdict: str       # move | stay (a leave-it-here category) | noop | refused
    why: str = ""
    hard: bool = False  # refused whatever the status says (src edited, unknown status)


def _typed(e: dict | None, r, key: str) -> str:
    """A cell of the CSV as the person left it: the plan's own value when they didn't change it.

    Spaces around what they typed don't count. The plan's value is kept exactly as it is, because a
    file can be named " notes.txt" or "report.txt ", and trimming that made dewey take the row for
    an edited one (and refuse it, or rename the file on its way)."""
    if e is None:
        return r[key]
    cell, planned = (e.get(key) or "").strip(), r[key] or ""
    return planned if cell == planned.strip() else cell


def resolve_row(r, e: dict | None, cats: dict, homes: dict, fence: Fence) -> Resolution:
    """One plan row (`plan_rows`) plus its CSV line (None = deleted). Shared by apply and `dewey rows`."""
    dest_root, root = fence.dest_root, fence.root
    status = (e.get("status") or "").strip().lower() if e else "skip"
    dst = _typed(e, r, "dst")
    category = _typed(e, r, "category")
    if _typed(e, r, "src") != r["src"]:
        return Resolution(status, dst, category, "refused", "src was edited in the CSV; edit dst instead", True)
    if status not in ("auto", "review", "skip"):
        return Resolution(status, dst, category, "refused", f"status {status!r} isn't auto/review/skip", True)
    name = os.path.basename(r["src"])
    if category != r["category"]:  # a correction: it decides where the row goes, or that it stays
        is_dir = r["action"] == "folder"
        if category not in cats and not (is_dir and category in homes):
            return Resolution(status, dst, category, "refused",
                              f"category {category!r} isn't a folder key in dewey.toml"
                              + (" or a [folders] kind" if is_dir else "") + "; nothing moved")
        home = (homes.get(category) if is_dir else None) or cats.get(category, {}).get("path", "")
        if not home:  # "other", "mixed": the person said leave it where it is
            return Resolution(status, r["src"], category, "stay", f"{category!r} means leave it where it is")
        if dst == r["dst"]:
            dst = f"{home.strip('/')}/{name}"
    # "Data/Exports/" or an existing folder means "into this folder", not "rename it to Exports".
    # Only for a dst the person typed: the planned dst never ends in "/" and must not be second-guessed.
    if dst != r["dst"] and (dst.endswith("/") or (dest_root / dst).is_dir()):
        dst = f"{dst.rstrip('/')}/{name}"
    if not _safe_rel(dst):
        return Resolution(status, dst, category, "refused",
                          f"dst {dst!r} must be a relative path inside the destination root")
    if norm_key(dst) == norm_key(r["src"]) and dest_root == root:
        return Resolution(status, dst, category, "noop")
    why = fence.problem(r["src"], dst)
    if why:
        return Resolution(status, dst, category, "refused", why)
    return Resolution(status, dst, category, "move")


def _review_dirs(root: Path, dest_root: Path, review: str, r) -> set[str]:
    """Every place inside the folder that is the review folder for this row, as `norm_key`s: the one
    the settings name now and the one the plan named (the settings may have changed since), in the
    folder and in a destination that is inside the folder."""
    names = {review, r["dst"].split("/Duplicates/")[0] if "/Duplicates/" in (r["dst"] or "") else ""}
    found = set()
    for name in filter(None, names):
        found.add(norm_key(name))
        inside = os.path.relpath(dest_root / name, root)
        if not inside.startswith(".."):
            found.add(norm_key(inside))
    return found


def _kept_copy(conn, root: Path, r, to_review: set, review_dirs: set[str]) -> bool:
    """A `duplicate` row may move only while another copy stays behind: one the catalog has under the
    same hash, that is still where the catalog says, with the contents it had, and that is neither in
    the review folder nor on its way there in this batch. The plan chose that copy when it was made;
    the person may have deleted or edited it since, and then this row's file is the only one left
    outside the folder the README says to empty."""
    if not r["hash"]:
        return False
    for f in conn.execute("SELECT id, rel_path, size, mtime_ns, hash_algo FROM files "
                          "WHERE hash=? AND kind='file' AND missing=0 AND id IS NOT ?", (r["hash"], r["file_id"])):
        if f["id"] in to_review or any(norm_key(f["rel_path"]).startswith(d + "/") for d in review_dirs):
            continue
        there = root / f["rel_path"]
        try:
            st = os.lstat(there)
            if stat.S_ISREG(st.st_mode) and st.st_size == f["size"] and (
                    st.st_mtime_ns == f["mtime_ns"] or hash_file(str(there), f["hash_algo"]) == r["hash"]):
                return True
        except (OSError, ValueError, TypeError, ImportError):  # gone, unreadable, or a hash this dewey can't repeat
            continue
    return False


def _selection_sha(pid: int, dest_root: Path, selected: list) -> str:
    """One fingerprint of what an apply would move: which rows, from where, to where. A dry run gives
    it out; `--expect-sha` on the real run then moves only if nothing changed in between (the CSV
    saved again from Numbers, a setting, a link in the folder)."""
    moves = [[r["row"], r["src"], dst] for r, _status, dst, _category in selected]
    return _sha256(json.dumps([pid, str(dest_root), moves]).encode())


def apply(conn: sqlite3.Connection, root: Path, cfg: dict, state_dir: Path, plan_id: int | None = None,
          csv_path: str | None = None, include_review: bool = False, dry_run: bool = False,
          prune_empty: bool = False, expect_sha: str | None = None) -> dict:
    plan = _latest_plan(conn, plan_id)
    pid = plan["id"]
    dest_root = plan_dest(conn, plan, root)
    csv_path = Path(csv_path) if csv_path else plan_files(state_dir, pid)[0]
    was = plan_root(conn, plan)
    if was and not _same_folder(was, root):
        say(f"note: plan {pid} was made when this folder was at {was}. It is applied here, in {root}.")
    fence = Fence(root, dest_root)
    if fence.dest_problem():
        raise DeweyExit(f"plan {pid}: {fence.dest_problem()}", UNSAFE_DEST)
    if fence.outside:
        say(f"note: plan {pid} files things into {dest_root}, outside this folder.")
    cats = cfg["categories"]
    homes = _homes(cfg)
    db_rows = {r["row"]: r for r in conn.execute("SELECT * FROM plan_rows WHERE plan_id=?", (pid,))}
    files = {r["id"]: r for r in conn.execute(
        "SELECT id, mtime_ns, hash_algo FROM files WHERE id IN (SELECT file_id FROM plan_rows WHERE plan_id=?)", (pid,))}
    _, _, csv_rows = read_plan_csv(csv_path)
    edits = edits_by_row(csv_rows)

    selected, refused, rejected = [], [], []
    for rowno in sorted(db_rows):
        r = db_rows[rowno]
        e = edits.get(rowno)
        res = resolve_row(r, e, cats, homes, fence)
        if res.hard:
            refused.append((r, res.why))
            continue
        if not (res.status == "auto" or (include_review and res.status == "review")):
            if e and res.status == "skip" and r["status"] in ("auto", "review"):
                rejected.append((r, None))
            continue
        if res.verdict == "refused":
            refused.append((r, res.why))
            continue
        if res.verdict == "stay":  # "other", "mixed": the person said leave it where it is
            if r["status"] in ("auto", "review"):
                rejected.append((r, res.category))
            continue
        if res.verdict == "noop":
            continue
        selected.append((r, res.status, res.dst, res.category))
    refused_items = [{"row": r["row"], "src": r["src"], "why": why} for r, why in refused]
    sha = _selection_sha(pid, dest_root, selected)
    if expect_sha:
        want = expect_sha.strip().lower()
        if len(want) < 12 or not sha.startswith(want):  # a dry run prints the first 12 characters
            raise DeweyExit(f"plan {pid} no longer moves what the dry run showed: its CSV, the settings or the "
                            "folder changed since. Nothing moved. Look at a new dry run, then apply again.", STALE)

    total = sum(r["size"] or 0 for r, *_ in selected)
    n_dirs = sum(r["action"] == "folder" for r, *_ in selected)
    what = f"{len(selected) - n_dirs:,} files" + (f" + {n_dirs:,} whole folder{'s' if n_dirs != 1 else ''}" if n_dirs else "")
    say(f"Plan {pid}: {what} to move ({human_bytes(total)})"
        f"{' including review rows' if include_review else ''}; {len(refused)} refused")
    for r, why in refused[:20]:
        say(f"  refused row {r['row']} {r['src']}: {why}")

    if dry_run:
        for r, status, dst, _ in selected[:40]:
            say(f"  [{status}] {r['src']}\n      -> {dst}   ({r['reason']})")
        if len(selected) > 40:
            say(f"  … {len(selected) - 40:,} more")
        say("Dry run: nothing moved.")
        if selected:
            say(f"  To move these only if nothing has changed since: add --expect-sha {sha[:12]}")
        return dict(plan_id=pid, dry_run=True, bytes=total, refused=refused_items,
                    dest_root=str(dest_root), dest_outside=fence.outside, selection_sha256=sha,
                    selected=[{"row": r["row"], "src": r["src"], "dst": dst, "status": status, "category": category,
                               "action": r["action"], "reason": r["reason"], "size": r["size"] or 0}
                              for r, status, dst, category in selected])
    if not selected:
        say("Nothing to do.")
        return dict(plan_id=pid, dry_run=False, batch=None, moved=[], skipped=[], failed=[], refused=refused_items,
                    counts={"moved": 0, "skipped": 0, "failed": 0, "bytes_moved": 0, "pruned_dirs": 0})

    batch = base = datetime.now().strftime("%Y%m%d-%H%M%S") + f"-p{pid}"
    mdir = state_dir / "moves"
    n = 1
    while (mdir / f"{batch}.jsonl").exists():  # two applies in one second must not share a journal
        n += 1
        batch = f"{base}-{n:03d}"
    j = Journal(mdir / f"{batch}.jsonl")
    started = now_iso()
    j.write({"op": "batch", "batch": batch, "plan_id": pid, "root": str(root), "dest_root": str(dest_root),
             "csv": str(csv_path), "include_review": include_review, "started": started})
    moved, skipped, failed = [], [], []
    reserved: set[str] = set()
    created_dirs: set[str] = set()
    review = str(cfg.get("plan", {}).get("review_dir") or "").strip("/")

    def set_aside(r, dst: str) -> bool:
        """A duplicate still going where the plan sent it, or into the review folder as it is named
        now. Not one the person re-filed somewhere of their own: that is an ordinary move."""
        if r["action"] != "duplicate":
            return False
        return (not review or norm_key(dst) == norm_key(r["dst"] or "")
                or norm_key(dst).startswith(norm_key(review) + "/"))

    to_review = {r["file_id"] for r, _status, dst, _category in selected if set_aside(r, dst)}
    prog = Progress("Moving", total=len(selected), total_bytes=total or None)
    hold = _Hold()
    try:
        hold.begin()  # from here to the end of the loop, Ctrl-C and Cancel wait for the file in hand
        for r, status, dst, category in selected:
            hold.stop_if_asked()
            src_abs = root / r["src"]
            size = r["size"] or 0
            frow = files.get(r["file_id"])
            algo = frow["hash_algo"] if frow else None
            try:
                st = os.lstat(src_abs)
            except FileNotFoundError:
                skipped.append({"row": r["row"], "src": r["src"], "why": "source no longer exists"})
                prog.update(1, size)
                continue
            except OSError as ex:
                skipped.append({"row": r["row"], "src": r["src"], "why": f"can't read source: {ex.strerror or ex}"})
                prog.update(1, size)
                continue
            is_dir = r["action"] == "folder"
            if is_dir != stat.S_ISDIR(st.st_mode) or not (is_dir or stat.S_ISREG(st.st_mode)):  # lstat: links are neither
                skipped.append({"row": r["row"], "src": r["src"],
                                "why": "no longer a folder" if is_dir else "no longer a regular file"})
                prog.update(1, size)
                continue
            if not is_dir and st.st_size != r["size"] or (frow and st.st_mtime_ns != frow["mtime_ns"]):
                try:
                    same = bool(algo) and hash_file(str(src_abs), algo) == r["hash"]
                except OSError:
                    same = False
                if not same:
                    skipped.append({"row": r["row"], "src": r["src"], "why": "contents changed since the scan; rescan"})
                    prog.update(1, size)
                    continue
            if _locked(st):  # macOS refuses to rename it, and a copy to another disk would be locked half way
                skipped.append({"row": r["row"], "src": r["src"], "why": f"{_locked(st)}; unlock it to move it"})
                prog.update(1, size)
                continue
            if set_aside(r, dst) and not _kept_copy(conn, root, r, to_review,
                                                    _review_dirs(root, dest_root, review, r)):
                skipped.append({"row": r["row"], "src": r["src"],
                                "why": "the copy this duplicates is gone or changed, so this one stays; rescan"})
                prog.update(1, size)
                continue
            # Already under both names: a batch that was cut off between its link and its unlink (a
            # kill, a power cut, Cancel in 0.2.1) and wasn't undone. This move takes the old name away.
            half_moved = not is_dir and _one_file(src_abs, dest_root / dst)
            dst_abs = dest_root / dst if half_moved else _free(dest_root / dst, reserved, keep_ext=not is_dir)
            if is_dir and norm_key(str(dst_abs)).startswith(norm_key(str(src_abs)) + "/"):
                skipped.append({"row": r["row"], "src": r["src"], "why": "dst is inside the folder itself"})
                prog.update(1, size)
                continue
            why = fence.problem(r["src"], os.path.relpath(dst_abs, dest_root), fresh=True)  # as the disk is now
            if why:
                skipped.append({"row": r["row"], "src": r["src"], "why": why})
                prog.update(1, size)
                continue
            rec = {"op": "move", "kind": "folder" if is_dir else "file", "row": r["row"], "file_id": r["file_id"], "hash": r["hash"], "algo": algo,
                   "size": size, "mtime_ns": st.st_mtime_ns, "inode": st.st_ino, "born": getattr(st, "st_birthtime", None),
                   "from": str(src_abs), "to": str(dst_abs),
                   "from_rel": r["src"], "to_rel": os.path.relpath(dst_abs, dest_root), "status": status,
                   "category": category, "decided_by": r["decided_by"], "confidence": r["confidence"],
                   "reason": r["reason"], "at": now_iso()}
            try:
                if is_dir:  # a folder is renamed, never copied: refuse before creating anything
                    a = dst_abs.parent
                    while not a.exists():
                        a = a.parent
                    if os.stat(a).st_dev != st.st_dev:
                        raise RuntimeError("whole folders only move within one disk; move it yourself, "
                                           "or set this row to skip")
                # record directories we create, so undo can remove them again. Inside the try: a plain
                # file sitting where a folder must go fails this one row instead of the whole batch.
                missing_dirs, d = [], dst_abs.parent
                while d != dest_root and not d.exists() and str(d) not in created_dirs:
                    missing_dirs.append(d)
                    d = d.parent
                for d in reversed(missing_dirs):
                    j.write({"op": "mkdir", "path": str(d)})
                dst_abs.parent.mkdir(parents=True, exist_ok=True)
                created_dirs.update(str(d) for d in missing_dirs)
                j.write(rec)  # intent first: the journal is never behind the disk
                if half_moved:
                    os.unlink(src_abs)
                    how = "rename"
                else:
                    how = move_dir(src_abs, dst_abs) if is_dir else move_file(src_abs, dst_abs, r["hash"], algo)
            except Exception as ex:  # noqa: BLE001
                j.write({"op": "failed", "row": r["row"], "error": f"{type(ex).__name__}: {ex}"})
                failed.append({"row": r["row"], "src": r["src"], "error": f"{type(ex).__name__}: {ex}"})
                prog.update(1, size)
                continue
            rec["method"] = how
            moved.append(rec)
            conn.execute("INSERT INTO moves (batch, plan_id, row, file_id, hash, src, dst, reason, decided_by, "
                         "confidence, category, moved_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                         (batch, pid, r["row"], r["file_id"], r["hash"], rec["from"], rec["to"], r["reason"],
                          r["decided_by"], r["confidence"], category, rec["at"]))
            if is_dir:
                _repoint_tree(conn, root, src_abs, dst_abs)
            else:
                _repoint(conn, r["file_id"], root, dst_abs)
            label = None if is_dir else _label_for(rec["to_rel"], category, cats)  # labels train the file decider
            from_model = (r["decided_by"] or "").startswith(DECIDER_PREFIXES)
            if label and (from_model or label != r["category"]):
                source = "accepted" if (label == r["category"] and dst == r["dst"]) else "corrected"
                conn.execute("INSERT INTO labels (file_id, hash, state, label, proposed, source, batch, created) "
                             "VALUES (?,?,?,?,?,?,?,?)",
                             (r["file_id"], r["hash"], r["state"], label, r["category"], source, batch, now_iso()))
            conn.commit()  # every move: a crash, Ctrl-C or closed terminal never loses what already moved
            prog.update(1, size)
    except BaseException as ex:
        conn.commit()
        j.close()
        prog.done()
        try:
            ex.batch = batch  # the app's "interrupted" event names the batch to undo
        except (AttributeError, TypeError):
            pass
        say(f"Stopped after {len(moved):,} of {len(selected):,} moves. `dewey undo '{root}'` puts them back "
            f"(batch {batch}).")
        raise
    finally:
        hold.end()
    prog.done()
    for r, label in rejected:  # label: the category the person chose instead (e.g. "other"), or None
        if (r["decided_by"] or "").startswith(DECIDER_PREFIXES):
            conn.execute("INSERT INTO labels (file_id, hash, state, label, proposed, source, batch, created) "
                         "VALUES (?,?,?,?,?,?,?,?)",
                         (r["file_id"], r["hash"], r["state"], label, r["category"],
                          "corrected" if label else "rejected", batch, now_iso()))

    pruned = _prune(root, [Path(m["from"]).parent for m in moved], j) if prune_empty else []
    j.write({"op": "end", "finished": now_iso(), "moved": len(moved), "skipped": len(skipped),
             "failed": len(failed), "pruned_dirs": len(pruned)})
    j.close()
    conn.commit()

    summary = {"batch": batch, "plan_id": pid, "root": str(root), "dest_root": str(dest_root),
               "started": started, "finished": now_iso(),
               "counts": {"moved": len(moved), "skipped": len(skipped), "failed": len(failed),
                          "bytes_moved": sum(m["size"] for m in moved), "pruned_dirs": len(pruned)},
               "moved": [{k: m[k] for k in ("from", "to", "kind", "reason", "category", "decided_by", "confidence",
                                            "status", "hash", "size", "method", "at")} for m in moved],
               "skipped": skipped, "failed": failed, "pruned_dirs": pruned,
               "undo": f"dewey undo '{root}' --batch {batch}"}
    out_json = mdir / f"{batch}.json"
    out_json.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    moved_dirs = sum(m["kind"] == "folder" for m in moved)
    say(f"Moved {len(moved) - moved_dirs:,} files{f' and {moved_dirs:,} whole folder' + ('s' if moved_dirs != 1 else '') if moved_dirs else ''} "
        f"({human_bytes(summary['counts']['bytes_moved'])}); "
        f"skipped {len(skipped)}, failed {len(failed)}{f', pruned {len(pruned)} empty folders' if pruned else ''}")
    for s in (skipped + failed)[:10]:
        say(f"  ! row {s['row']} {s['src']}: {s.get('why') or s.get('error')}")
    say(f"  log:  {mdir / (batch + '.jsonl')}\n  json: {out_json}\n  undo: dewey undo ROOT --batch {batch}")
    return {**summary, "dry_run": False, "refused": refused_items}


def _repoint(conn, file_id: int, root: Path, new_abs: Path) -> None:
    rel = os.path.relpath(new_abs, root)
    if rel.startswith(".."):
        conn.execute("UPDATE files SET missing=1 WHERE id=?", (file_id,))
        return
    conn.execute("DELETE FROM files WHERE rel_path=? AND id<>?", (rel, file_id))  # stale row at that path
    conn.execute("UPDATE files SET rel_path=?, name=?, missing=0 WHERE id=?", (rel, new_abs.name, file_id))


def _repoint_tree(conn, root: Path, old_abs: Path, new_abs: Path) -> None:
    """A whole folder moved: every catalog row inside it follows (the folder's own unit row too)."""
    old, new = os.path.relpath(old_abs, root), os.path.relpath(new_abs, root)
    under = "(rel_path = ? OR substr(rel_path, 1, ?) = ?)"  # not LIKE: names may hold % and _
    at = lambda p: (p, len(p) + 1, p + "/")
    if new.startswith(".."):  # moved out of the root: this catalog no longer covers it
        conn.execute(f"UPDATE files SET missing=1 WHERE {under}", at(old))
        return
    if old.startswith(".."):  # coming back from outside the root: the rows kept their old paths
        conn.execute(f"UPDATE files SET missing=0 WHERE {under}", at(new))
        return
    if not conn.execute(f"SELECT 1 FROM files WHERE {under} LIMIT 1", at(old)).fetchone():
        return  # nothing recorded at the old place (e.g. already repointed): leave the new place alone
    conn.execute(f"DELETE FROM files WHERE {under}", at(new))  # stale rows where the folder now is
    conn.execute(f"UPDATE files SET rel_path = ? || substr(rel_path, ?), "
                 f"name = CASE WHEN rel_path = ? THEN ? ELSE name END, missing = 0 WHERE {under}",
                 (new, len(old) + 1, old, new_abs.name, *at(old)))


def _remove_if_empty(d) -> bool:
    """rmdir, except a lone .DS_Store counts as empty: Finder writes one into every folder you open."""
    try:
        names = os.listdir(d)
        if any(n not in PRUNABLE for n in names):
            return False
        for n in names:
            os.unlink(os.path.join(d, n))
        os.rmdir(d)
        return True
    except OSError:  # gone already, not ours to touch, or something appeared meanwhile
        return False


def _prune(root: Path, dirs: list[Path], j: Journal) -> list[str]:
    """Remove folders the moves emptied (a lone .DS_Store counts as empty). Never the root."""
    pruned = []
    for d in sorted(set(dirs), key=lambda p: -len(p.parts)):
        while d != root and root in d.parents and _remove_if_empty(d):
            j.write({"op": "rmdir", "path": str(d)})
            pruned.append(str(d))
            d = d.parent
    return pruned


def latest_batch(conn, state_dir: Path) -> str | None:
    """Newest batch that still has something to undo.

    The journals on disk decide which batches exist: each move is journaled before it happens,
    so a batch killed before its first database commit still counts. The database only says
    which rows were already put back. Batch ids start with a timestamp, so names sort by time.
    """
    mdir = state_dir / "moves"
    if not mdir.is_dir():
        return None
    batches = [p.name[:-len(".jsonl")] for p in mdir.glob("*.jsonl") if not p.name.endswith(".undo.jsonl")]
    for batch in sorted(batches, reverse=True):  # ids, not file names: "-p1" < "-p1-002", but "-p1." > "-p1-"
        n, still_out = conn.execute("SELECT COUNT(*), COALESCE(SUM(undone_at IS NULL), 0) FROM moves "
                                    "WHERE batch=?", (batch,)).fetchone()
        if still_out or (n == 0 and not (mdir / f"{batch}.undo.jsonl").exists()):
            return batch
    return None


def _batch_places(head: dict, root: Path) -> tuple[Path, Path]:
    """(the folder when the batch ran, where the batch filed things as the folder is now)."""
    text = lambda k: head[k] if isinstance(head.get(k), str) and head[k] else None
    was_root = Path(text("root")) if text("root") else root
    return was_root, _moved_with(Path(text("dest_root")), was_root, root) if text("dest_root") else root


def batch_dest_outside(root: Path, state_dir: Path, batch: str) -> str | None:
    """Where a batch filed things, when that is outside the folder (the app says so before an undo)."""
    try:
        with open(state_dir / "moves" / f"{batch}.jsonl", encoding="utf-8") as fh:
            head = json.loads(fh.readline())
    except (OSError, ValueError):
        return None
    if not isinstance(head, dict) or head.get("op") != "batch":
        return None
    dest_root = _batch_places(head, root)[1]
    return str(dest_root) if Fence(root, dest_root).outside else None


def undo(conn: sqlite3.Connection, root: Path, state_dir: Path, batch: str | None = None) -> dict:
    batch = batch or latest_batch(conn, state_dir)
    if not batch:
        raise DeweyExit("nothing to undo", NOTHING_TO_UNDO)
    jpath = state_dir / "moves" / f"{batch}.jsonl"
    if not jpath.exists():
        raise DeweyExit(f"journal not found: {jpath}")
    recs = []
    with open(jpath, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    recs.append(json.loads(line))
                except json.JSONDecodeError:
                    pass  # a torn final line from a crash: ignore it
    moves = [r for r in recs if r.get("op") == "move"]
    # The journal names both ends relative to the folder and to where it filed things, so they are
    # found again in a folder that was renamed, copied or mounted somewhere else since.
    was_root, dest_root = _batch_places(next((r for r in recs if r.get("op") == "batch"), {}), root)
    if not _same_folder(was_root, root):
        say(f"note: batch {batch} moved things when this folder was at {was_root}. It is undone here, in {root}.")
    fence = Fence(root, dest_root)
    if fence.dest_problem(undoing=True):
        raise DeweyExit(f"batch {batch} says it filed things outside this folder, but "
                        f"{fence.dest_problem(undoing=True)}. Nothing was put back.", UNSAFE_DEST)
    if fence.outside:
        say(f"note: batch {batch} filed things into {dest_root}, outside this folder; they come back from there.")
    mkdirs = [d for d in (_moved_with(Path(r["path"]), was_root, root) for r in recs
                          if r.get("op") == "mkdir" and isinstance(r.get("path"), str))
              if fence.made_here(d)]  # apply only ever made folders inside the destination
    uj = Journal(state_dir / "moves" / f"{batch}.undo.jsonl")
    uj.write({"op": "undo", "batch": batch, "root": str(root), "dest_root": str(dest_root), "started": now_iso()})
    restored, skipped = 0, []
    prog = Progress("Undoing", total=len(moves), total_bytes=sum(m.get("size", 0) for m in moves) or None)
    hold = _Hold()
    try:
        hold.begin()  # Ctrl-C and Cancel wait for the file in hand, as they do in apply
        restored = _put_back(conn, root, dest_root, fence, batch, moves, uj, skipped, prog, hold)
    except BaseException:  # Ctrl-C, Cancel, a full disk: what already went back is on record
        conn.commit()
        uj.close()
        prog.done()
        say(f"Stopped before everything was back. `dewey undo '{root}' --batch {batch}` puts back the rest.")
        raise
    finally:
        hold.end()
    prog.done()
    removed = 0
    for d in sorted(mkdirs, key=lambda p: -len(p.parts)):
        if _remove_if_empty(d):  # left alone if something else lives there now
            removed += 1
    conn.execute("DELETE FROM labels WHERE batch=?", (batch,))
    uj.write({"op": "end", "restored": restored, "skipped": len(skipped), "dirs_removed": removed,
              "finished": now_iso()})
    uj.close()
    conn.commit()
    say(f"Undo {batch}: restored {restored:,}, skipped {len(skipped)}, removed {removed} folders it had created")
    for path, why in skipped[:10]:
        say(f"  ! {path}: {why}")
    return dict(batch=batch, restored=restored, skipped=len(skipped), dirs_removed=removed,
                skipped_items=[{"path": path, "why": why} for path, why in skipped])


def _why_it_stays(rec: dict, dst: Path, is_dir: bool, outside: bool) -> str | None:
    """Why what is at `dst` now isn't put back, or None when it is what dewey moved there, unchanged.

    A file that can't be read (no permission, a disk that gives errors) can't be told from a changed
    one, so it stays too. That is this one file's reason, not the end of the undo: the rest go back."""
    try:
        st = os.lstat(dst)
        if is_dir:  # the folder goes back as one piece, whatever is in it now: nothing inside is lost
            if not stat.S_ISDIR(st.st_mode):
                return "no longer a folder; left where it is"
            if outside and not _is_what_moved(rec, st, dst):
                return ("can't tell that this is the folder dewey moved"
                        + ("" if "inode" in rec else " (a batch from before 0.2.1)") + "; left where it is")
        elif not stat.S_ISREG(st.st_mode):
            return "no longer a regular file; left where it is"
        elif outside:  # from outside the folder, only the very file dewey moved comes back
            if not _is_what_moved(rec, st, dst):
                return "isn't the file dewey moved (or was modified since); left where it is"
        elif st.st_size != rec.get("size", 0) or (st.st_mtime_ns != rec.get("mtime_ns") and rec.get("algo")
                                                   and hash_file(str(dst), rec["algo"]) != rec["hash"]):
            return "file was modified after the move; left where it is"
        if _locked(st):
            return f"{_locked(st)}; unlock it and undo again"
    except OSError as ex:
        return f"can't be read ({ex.strerror or type(ex).__name__}); left where it is"
    return None


def _cut_off_copy(conn, batch: str, rec: dict, src: Path, dst: Path) -> bool:
    """A copy to another disk that was cut off (a kill, a power cut) once the copy had its name and
    before the original was removed: the journal has the move, the catalog never got it, and both
    files are, byte for byte, the one the journal names. Taking the copy away is all that is left of
    putting it back. After a move that finished, a file at the old place is somebody's own."""
    if rec.get("algo") not in ("sha256", "blake3") or not isinstance(rec.get("hash"), str):
        return False
    if conn.execute("SELECT 1 FROM moves WHERE batch=? AND row=?", (batch, rec.get("row"))).fetchone():
        return False
    try:
        for p in (src, dst):
            st = os.lstat(p)
            if not stat.S_ISREG(st.st_mode) or st.st_size != rec.get("size") \
                    or hash_file(str(p), rec["algo"]) != rec["hash"]:
                return False
    except (OSError, ImportError):
        return False
    return True


def _put_back(conn, root: Path, dest_root: Path, fence: Fence, batch: str, moves: list, uj: Journal,
              skipped: list, prog: Progress, hold: _Hold) -> int:
    """Undo's moves, newest first. Each one is committed as it lands, as apply's are: an undo that is
    stopped half way has put back exactly what History says it has."""
    restored = 0
    for rec in reversed(moves):
        hold.stop_if_asked()
        size = rec.get("size", 0)
        is_dir = rec.get("kind") == "folder"
        if not (_is_rel(rec.get("from_rel")) and _is_rel(rec.get("to_rel"))):
            skipped.append((str(rec.get("to") or rec.get("to_rel") or "?"), "the journal doesn't say where this was"))
            prog.update(1, size)
            continue
        src, dst = root / rec["from_rel"], dest_root / rec["to_rel"]
        why = fence.problem(rec["from_rel"], rec["to_rel"], fresh=True)
        if why:
            skipped.append((str(dst), why))
            prog.update(1, size)
            continue
        if not is_dir and os.path.lexists(dst.with_name(dst.name + PARTIAL_SUFFIX)):
            _drop(dst.with_name(dst.name + PARTIAL_SUFFIX))  # a copy to another disk that was cut off part way
        if not os.path.lexists(dst):
            if not os.path.lexists(src):
                skipped.append((str(dst), f"{'folder' if is_dir else 'file'} is at neither location"))
            else:  # never moved, or already put back by an undo that was interrupted: done either way
                if is_dir:
                    _repoint_tree(conn, root, dst, src)
                elif rec.get("file_id"):
                    _repoint(conn, rec["file_id"], root, src)
                conn.execute("UPDATE moves SET undone_at=? WHERE batch=? AND row=? AND undone_at IS NULL",
                             (now_iso(), batch, rec["row"]))
            prog.update(1, size)
            continue
        try:
            if os.path.lexists(src):
                # One file under both names: a move, or an undo, that was cut off between its link and
                # its unlink (a crash, a Force Quit, Cancel in 0.2.1). It is back already; only the
                # second name is left to take away. A copy to another disk that was cut off the same
                # way left two files instead.
                if is_dir or not (_one_file(src, dst) or _cut_off_copy(conn, batch, rec, src, dst)):
                    skipped.append((str(dst), "something now exists at the original path"))
                    prog.update(1, size)
                    continue
                os.unlink(dst)
            else:
                why = _why_it_stays(rec, dst, is_dir, fence.outside)
                if why:
                    skipped.append((str(dst), why))
                    prog.update(1, size)
                    continue
                try:  # a file sitting where its old folder was stops this one, not the whole undo
                    src.parent.mkdir(parents=True, exist_ok=True)
                except OSError as ex:
                    skipped.append((str(dst), f"the folder it was in can't be made again "
                                              f"({ex.strerror or type(ex).__name__}); left where it is"))
                    prog.update(1, size)
                    continue
                if is_dir:
                    move_dir(dst, src)
                else:
                    move_file(dst, src, rec.get("hash"), rec.get("algo"))
        except Exception as ex:  # noqa: BLE001
            skipped.append((str(dst), f"{type(ex).__name__}: {ex}"))
            prog.update(1, size)
            continue
        uj.write({"op": "restore", "row": rec["row"], "from": str(dst), "to": str(src), "at": now_iso()})
        if is_dir:
            _repoint_tree(conn, root, dst, src)
        elif rec.get("file_id"):
            _repoint(conn, rec["file_id"], root, src)
        conn.execute("UPDATE moves SET undone_at=? WHERE batch=? AND row=?", (now_iso(), batch, rec["row"]))
        conn.commit()
        restored += 1
        prog.update(1, size)
    return restored


def export_labels(conn: sqlite3.Connection, cfg: dict, out: Path, include_rejected: bool = False) -> int:
    q = cfg["decider"]["question"]
    options = {k: v["desc"] for k, v in cfg["categories"].items()}
    sql = "SELECT * FROM labels" + ("" if include_rejected else " WHERE source <> 'rejected'") + " ORDER BY id"
    n = 0
    with open(out, "w", encoding="utf-8") as fh:
        for r in conn.execute(sql):
            fh.write(json.dumps({"state": json.loads(r["state"] or "{}"), "question": q, "options": options,
                                 "label": r["label"], "proposed": r["proposed"], "source": r["source"],
                                 "hash": r["hash"], "batch": r["batch"]}, ensure_ascii=False) + "\n")
            n += 1
    return n


# --- the Mac app's view of a plan: read rows, write edits (the CSV stays the one source of truth) ----

EDITABLE = ("status", "category", "dst")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def plan_rows(conn: sqlite3.Connection, root: Path, cfg: dict, state_dir: Path, plan_id: int | None = None) -> dict:
    """Every row of a plan as apply would see it now: the plan's values, the CSV's edits, the verdict."""
    plan = _latest_plan(conn, plan_id)
    pid = plan["id"]
    dest_root = plan_dest(conn, plan, root)
    csv_path, report_path = plan_files(state_dir, pid)
    data, _, csv_rows = read_plan_csv(csv_path)
    edits = edits_by_row(csv_rows)
    cats, homes = cfg["categories"], _homes(cfg)
    fence = Fence(root, dest_root)
    rows = []
    for r in conn.execute("SELECT * FROM plan_rows WHERE plan_id=? ORDER BY row", (pid,)):
        e = edits.get(r["row"])
        res = resolve_row(r, e, cats, homes, fence)
        typed = (res.status, _typed(e, r, "dst"), _typed(e, r, "category"))
        rows.append({"row": r["row"], "src": r["src"], "action": r["action"], "size": r["size"] or 0,
                     "status": res.status, "dst": res.dst, "category": res.category,
                     "verdict": res.verdict, "why": res.why, "in_csv": e is not None,
                     "edited": typed != (r["status"], r["dst"], r["category"]),
                     "planned": {"status": r["status"], "dst": r["dst"], "category": r["category"]},
                     "confidence": r["confidence"], "decided_by": r["decided_by"], "reason": r["reason"],
                     "alternatives": r["alternatives"]})
    p = cfg["plan"]
    return {"plan_id": pid, "created": plan["created"], "decider": plan["decider"], "root": str(root),
            "dest_root": str(dest_root), "csv": str(csv_path),
            "report": str(report_path) if report_path.exists() else None,
            "csv_sha256": _sha256(data), "summary": json.loads(plan["summary"] or "{}"),
            "categories": [{"key": k, "path": v.get("path", ""), "desc": v.get("desc", "")} for k, v in cats.items()],
            "folder_kinds": [{"kind": k, "path": v} for k, v in homes.items()],
            "auto_confidence": p["auto_confidence"], "review_confidence": p["review_confidence"],
            "rows": rows}


def _csv_line(r) -> dict:
    """A plan row as `dewey plan` first wrote it into the CSV (planner.plan step 6)."""
    return {"row": r["row"], "status": r["status"], "action": r["action"], "src": r["src"], "dst": r["dst"],
            "category": r["category"], "confidence": f"{r['confidence'] or 0:.2f}", "decided_by": r["decided_by"],
            "reason": r["reason"], "alternatives": r["alternatives"]}


def _check_edits(edits, db_rows: dict, pid: int) -> list[dict]:
    if not isinstance(edits, list):
        raise DeweyExit("edits must be a JSON list of {row, status, category, dst}", BAD_EDIT)
    for ed in edits:
        if not isinstance(ed, dict):
            raise DeweyExit(f"each edit must be an object, got {ed!r}", BAD_EDIT)
        extra = set(ed) - {"row", *EDITABLE}
        if extra:
            raise DeweyExit(f"can't edit {', '.join(sorted(extra))}: only status, category and dst", BAD_EDIT)
        row = ed.get("row")
        if isinstance(row, bool) or not isinstance(row, int) or row not in db_rows:
            raise DeweyExit(f"row {row!r} isn't in plan {pid}", BAD_EDIT)
        for k in EDITABLE:
            if k in ed and not isinstance(ed[k], str):
                raise DeweyExit(f"row {row}: {k} must be a string", BAD_EDIT)
        if "status" in ed and ed["status"].strip().lower() not in ("auto", "review", "skip"):
            raise DeweyExit(f"row {row}: status {ed['status']!r} isn't auto/review/skip", BAD_EDIT)
    return edits


def edit_plan(conn: sqlite3.Connection, state_dir: Path, edits, plan_id: int | None = None,
              expect_sha: str | None = None) -> dict:
    """Write edits into plan-N.csv as a person would in Numbers. Every other line and column stays as it was.

    All or nothing: one bad edit, or a file that changed since `expect_sha` was read, leaves it untouched.
    """
    plan = _latest_plan(conn, plan_id)
    pid = plan["id"]
    csv_path = plan_files(state_dir, pid)[0]
    data, fields, csv_rows = read_plan_csv(csv_path)
    if expect_sha and expect_sha != _sha256(data):
        raise DeweyExit(f"{csv_path.name} changed since it was read (saved from Numbers?); reload it and try again",
                        STALE)
    db_rows = {r["row"]: r for r in conn.execute("SELECT * FROM plan_rows WHERE plan_id=?", (pid,))}
    edits = _check_edits(edits, db_rows, pid)
    fields += [k for k in CSV_FIELDS if k not in fields]  # a column deleted in Numbers comes back empty
    by_row = edits_by_row(csv_rows)
    changed = 0
    for ed in edits:
        line = by_row.get(ed["row"])
        readded = line is None
        if readded:  # a deleted line means skip: it comes back skipped unless this edit says otherwise
            line = by_row[ed["row"]] = {**_csv_line(db_rows[ed["row"]]), "status": "skip"}
            csv_rows.append(line)
        before = [line.get(k) for k in EDITABLE]
        for k in EDITABLE:
            if k in ed:
                line[k] = ed[k].strip().lower() if k == "status" else ed[k]
        changed += readded or before != [line.get(k) for k in EDITABLE]
    buf = io.StringIO(newline="")
    w = csv.DictWriter(buf, fieldnames=fields, extrasaction="ignore")
    w.writeheader()
    w.writerows(csv_rows)
    out = buf.getvalue().encode("utf-8-sig")  # BOM: Excel and Numbers then read it as UTF-8
    tmp = csv_path.with_name(csv_path.name + ".dewey-tmp")
    with open(tmp, "wb") as fh:  # atomic: Numbers, the app or a crash never sees half a file
        fh.write(out)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, csv_path)
    return {"plan_id": pid, "csv": str(csv_path), "csv_sha256": _sha256(out), "changed": changed}
