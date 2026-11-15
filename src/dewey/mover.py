"""Apply a reviewed plan, keep a crash-safe journal, and undo it exactly.

Journal: ROOT/.dewey/moves/<batch>.jsonl, append-only, fsync'd per line, and each move
is written BEFORE it happens. If the process dies mid-run, the journal still names every
file that might have moved, and undo checks the disk rather than trusting the log.
At the end a pretty <batch>.json is written with what moved, where, and why.

Safety: never overwrites (hard-link + unlink, or check-then-rename where hard links aren't
supported), re-hashes a file if it changed since the scan, copies and verifies the hash
before deleting the source when crossing volumes, and never deletes anything else.
"""
from __future__ import annotations

import csv
import errno
import json
import os
import shutil
import sqlite3
import stat
from datetime import datetime
from pathlib import Path, PurePosixPath

from .catalog import hash_file, now_iso
from .planner import DECIDER_PREFIXES, norm_key
from .progress import Progress, human_bytes, say

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
    except BaseException:
        os.unlink(dst)  # our own hard link to src; drop it so the file isn't in two places
        raise


def move_file(src: Path, dst: Path, expected_hash: str | None, algo: str | None) -> str:
    try:
        _noclobber_rename(src, dst)
        return "rename"
    except OSError as e:
        if e.errno != errno.EXDEV:
            raise
    tmp = dst.with_name(dst.name + ".dewey-partial")
    try:  # the copy itself is inside: a full disk or Ctrl-C mid-copy must not leave a partial behind
        shutil.copy2(src, tmp)
        if expected_hash and algo and hash_file(str(tmp), algo) != expected_hash:
            raise RuntimeError("copy verification failed (hash mismatch); source left untouched")
        _noclobber_rename(tmp, dst)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    try:
        os.unlink(src)
    except BaseException:
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
        raise SystemExit("no plan found; run `dewey plan` first")
    return plan


def apply(conn: sqlite3.Connection, root: Path, cfg: dict, state_dir: Path, plan_id: int | None = None,
          csv_path: str | None = None, include_review: bool = False, dry_run: bool = False,
          prune_empty: bool = False) -> dict:
    plan = _latest_plan(conn, plan_id)
    pid = plan["id"]
    dest_root = Path(plan["dest_root"])
    csv_path = Path(csv_path or plan["csv_path"])
    cats = cfg["categories"]
    homes = {k: v for k, v in (cfg.get("folders") or {}).items() if isinstance(v, str)}
    db_rows = {r["row"]: r for r in conn.execute("SELECT * FROM plan_rows WHERE plan_id=?", (pid,))}
    files = {r["id"]: r for r in conn.execute(
        "SELECT id, mtime_ns, hash_algo FROM files WHERE id IN (SELECT file_id FROM plan_rows WHERE plan_id=?)", (pid,))}
    edits = {}
    with open(csv_path, newline="", encoding="utf-8-sig") as fh:
        for e in csv.DictReader(fh):
            try:
                edits[int(e["row"])] = e
            except (KeyError, ValueError, TypeError):
                continue

    selected, refused, rejected = [], [], []
    for rowno in sorted(db_rows):
        r = db_rows[rowno]
        e = edits.get(rowno)
        status = (e.get("status") or "").strip().lower() if e else "skip"
        dst = (e.get("dst") or "").strip() if e else r["dst"]
        category = (e.get("category") or "").strip() if e else r["category"]
        if e and e.get("src", "").strip() != r["src"]:
            refused.append((r, "src was edited in the CSV; edit dst instead"))
            continue
        if status not in ("auto", "review", "skip"):
            refused.append((r, f"status {status!r} isn't auto/review/skip"))
            continue
        if not (status == "auto" or (include_review and status == "review")):
            if e and status == "skip" and r["status"] in ("auto", "review"):
                rejected.append((r, None))
            continue
        name = os.path.basename(r["src"])
        if category != r["category"]:  # a correction: it decides where the row goes, or that it stays
            is_dir = r["action"] == "folder"
            if category not in cats and not (is_dir and category in homes):
                refused.append((r, f"category {category!r} isn't a folder key in dewey.toml"
                                   + (" or a [folders] kind" if is_dir else "") + "; nothing moved"))
                continue
            home = (homes.get(category) if is_dir else None) or cats.get(category, {}).get("path", "")
            if not home:  # "other", "mixed": the person said leave it where it is
                if r["status"] in ("auto", "review"):
                    rejected.append((r, category))
                continue
            if dst == r["dst"]:
                dst = f"{home.strip('/')}/{name}"
        # "Data/Exports/" or an existing folder means "into this folder", not "rename it to Exports".
        # Only for a dst the person typed: the planned dst never ends in "/" and must not be second-guessed.
        if dst != r["dst"] and (dst.endswith("/") or (dest_root / dst).is_dir()):
            dst = f"{dst.rstrip('/')}/{name}"
        if not _safe_rel(dst):
            refused.append((r, f"dst {dst!r} must be a relative path inside the destination root"))
            continue
        if norm_key(dst) == norm_key(r["src"]) and dest_root == root:
            continue
        selected.append((r, status, dst, category))

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
        return dict(moved=0, dry_run=True, selected=len(selected))
    if not selected:
        say("Nothing to do.")
        return dict(moved=0)

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
    prog = Progress("Moving", total=len(selected), total_bytes=total or None)
    try:
        for r, status, dst, category in selected:
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
            dst_abs = _free(dest_root / dst, reserved, keep_ext=not is_dir)
            if is_dir and norm_key(str(dst_abs)).startswith(norm_key(str(src_abs)) + "/"):
                skipped.append({"row": r["row"], "src": r["src"], "why": "dst is inside the folder itself"})
                prog.update(1, size)
                continue
            rec = {"op": "move", "kind": "folder" if is_dir else "file", "row": r["row"], "file_id": r["file_id"], "hash": r["hash"], "algo": algo,
                   "size": size, "mtime_ns": st.st_mtime_ns, "from": str(src_abs), "to": str(dst_abs),
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
    except BaseException:
        conn.commit()
        j.close()
        prog.done()
        say(f"Stopped after {len(moved):,} of {len(selected):,} moves. `dewey undo '{root}'` puts them back "
            f"(batch {batch}).")
        raise
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
               "moved": [{k: m[k] for k in ("from", "to", "reason", "category", "decided_by", "confidence",
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
    return summary


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


def undo(conn: sqlite3.Connection, root: Path, state_dir: Path, batch: str | None = None) -> dict:
    batch = batch or latest_batch(conn, state_dir)
    if not batch:
        raise SystemExit("nothing to undo")
    jpath = state_dir / "moves" / f"{batch}.jsonl"
    if not jpath.exists():
        raise SystemExit(f"journal not found: {jpath}")
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
    mkdirs = [r["path"] for r in recs if r.get("op") == "mkdir"]
    uj = Journal(state_dir / "moves" / f"{batch}.undo.jsonl")
    uj.write({"op": "undo", "batch": batch, "started": now_iso()})
    restored, skipped = 0, []
    prog = Progress("Undoing", total=len(moves), total_bytes=sum(m.get("size", 0) for m in moves) or None)
    for rec in reversed(moves):
        src, dst = Path(rec["from"]), Path(rec["to"])
        size = rec.get("size", 0)
        is_dir = rec.get("kind") == "folder"
        if not os.path.lexists(dst):
            if not os.path.lexists(src):
                skipped.append((rec, f"{'folder' if is_dir else 'file'} is at neither location"))
            else:  # never moved, or already put back by an undo that was interrupted: done either way
                if is_dir:
                    _repoint_tree(conn, root, dst, src)
                elif rec.get("file_id"):
                    _repoint(conn, rec["file_id"], root, src)
                conn.execute("UPDATE moves SET undone_at=? WHERE batch=? AND row=? AND undone_at IS NULL",
                             (now_iso(), batch, rec["row"]))
            prog.update(1, size)
            continue
        if os.path.lexists(src):
            skipped.append((rec, "something now exists at the original path"))
            prog.update(1, size)
            continue
        if is_dir:  # the folder goes back as one piece, whatever is in it now: nothing inside is lost
            if not stat.S_ISDIR(os.lstat(dst).st_mode):
                skipped.append((rec, "no longer a folder; left where it is"))
                prog.update(1, size)
                continue
            src.parent.mkdir(parents=True, exist_ok=True)
            try:
                move_dir(dst, src)
            except Exception as ex:  # noqa: BLE001
                skipped.append((rec, f"{type(ex).__name__}: {ex}"))
                prog.update(1, size)
                continue
            uj.write({"op": "restore", "row": rec["row"], "from": str(dst), "to": str(src), "at": now_iso()})
            _repoint_tree(conn, root, dst, src)
            conn.execute("UPDATE moves SET undone_at=? WHERE batch=? AND row=?", (now_iso(), batch, rec["row"]))
            conn.commit()
            restored += 1
            prog.update(1, size)
            continue
        st = os.lstat(dst)
        if st.st_size != size or (st.st_mtime_ns != rec.get("mtime_ns") and rec.get("algo")
                                  and hash_file(str(dst), rec["algo"]) != rec["hash"]):
            skipped.append((rec, "file was modified after the move; left where it is"))
            prog.update(1, size)
            continue
        src.parent.mkdir(parents=True, exist_ok=True)
        try:
            move_file(dst, src, rec.get("hash"), rec.get("algo"))
        except Exception as ex:  # noqa: BLE001
            skipped.append((rec, f"{type(ex).__name__}: {ex}"))
            prog.update(1, size)
            continue
        uj.write({"op": "restore", "row": rec["row"], "from": str(dst), "to": str(src), "at": now_iso()})
        if rec.get("file_id"):
            _repoint(conn, rec["file_id"], root, src)
        conn.execute("UPDATE moves SET undone_at=? WHERE batch=? AND row=?", (now_iso(), batch, rec["row"]))
        restored += 1
        prog.update(1, size)
    prog.done()
    removed = 0
    for d in sorted(mkdirs, key=lambda p: -len(Path(p).parts)):
        if _remove_if_empty(d):  # left alone if something else lives there now
            removed += 1
    conn.execute("DELETE FROM labels WHERE batch=?", (batch,))
    uj.write({"op": "end", "restored": restored, "skipped": len(skipped), "dirs_removed": removed,
              "finished": now_iso()})
    uj.close()
    conn.commit()
    say(f"Undo {batch}: restored {restored:,}, skipped {len(skipped)}, removed {removed} folders it had created")
    for rec, why in skipped[:10]:
        say(f"  ! {rec['to']}: {why}")
    return dict(batch=batch, restored=restored, skipped=len(skipped))


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
