"""Turn the catalog into a reviewable plan: plan-N.csv (editable) + report-N.md (readable).

Order of precedence for each file:
  1. exact duplicate (same hash)  -> _Review/Duplicates/<hash>/   (one copy stays put)
  2. first matching rule          -> rule target                   (confidence 1.0)
  3. decision model               -> category path, tiered by confidence
Nothing is moved here. `dewey apply` reads the CSV after you've had a look.
"""
from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import sqlite3
import unicodedata
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

from . import decide as dmod
from . import folders as fkind
from .catalog import UNIT_KINDS, check_safe_root, left_alone, now_iso, unsafe_dest
from .errors import DECIDER, NO_CATALOG, UNSAFE_DEST, DeweyExit
from .progress import Progress, human_bytes, say
from .rules import compile_rules, file_date, fill, first_match

CSV_FIELDS = ["row", "status", "action", "src", "dst", "category", "confidence",
              "decided_by", "reason", "alternatives"]
DECIDER_PREFIXES = ("systemone:", "chat:")
AVOID_KEEP = re.compile(r"(^|/)(Downloads|Desktop|tmp|temp|Temp|Inbox)(/|$)")


def norm_key(p: str) -> str:
    """APFS/HFS+ are case-insensitive and normalization-insensitive by default."""
    return unicodedata.normalize("NFC", p).casefold()


def _inside(rel: str, folder: str) -> bool:
    """`rel` is somewhere inside `folder` (both relative to the same place), as the disk compares names."""
    return norm_key(rel).startswith(norm_key(folder) + "/")


def plan_files(state_dir: Path, plan_id: int) -> tuple[Path, Path]:
    """A plan's CSV and report: fixed names in the state folder, so a folder that was renamed, copied
    or mounted somewhere else still finds its own. (`plans.csv_path` is where they were that day.)"""
    return state_dir / f"plan-{plan_id}.csv", state_dir / f"report-{plan_id}.md"


def build_state(f) -> dict:
    st = {"file_name": f["name"],
          "folder": os.path.dirname(f["rel_path"]) or "(top level)",
          "extension": f["ext"] or "(none)",
          "size": human_bytes(f["size"] or 0),
          "modified": file_date(f).date().isoformat()}
    if f["snippet"]:
        st["text_preview"] = f["snippet"]
    return st


def pick_keeper(fs: list, mode: str, review_dir: str):
    def tier(f):
        rel = f["rel_path"]
        return (rel.startswith(review_dir + "/"), bool(AVOID_KEEP.search(rel)))
    if mode == "newest":
        key = lambda f: (tier(f), -(f["mtime_ns"] or 0), f["rel_path"])
    elif mode == "shortest_path":
        key = lambda f: (tier(f), len(f["rel_path"]), f["rel_path"])
    else:  # oldest: birth time separates the original from later copies (copies keep mtime)
        key = lambda f: (tier(f), f["birth_ns"] or f["mtime_ns"] or 0, f["rel_path"])
    return min(fs, key=key)


def _cache_key(decider, question: str, options: dict, state: dict) -> str:
    blob = json.dumps([decider.name, question, options, state], sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(blob.encode()).hexdigest()


def decide_all(conn: sqlite3.Connection, decider, items: list, cfg: dict, options: dict):
    """items: [(file_row, state)] -> [(file_row, state, Decision | None, error | None)]"""
    q = cfg["decider"]["question"]
    out, todo = [], []
    for f, st in items:
        key = _cache_key(decider, q, options, st)
        c = conn.execute("SELECT * FROM decision_cache WHERE key=?", (key,)).fetchone()
        if c:
            out.append((f, st, dmod.Decision(c["choice"], c["confidence"], json.loads(c["probabilities"] or "{}"),
                                             c["decided_by"], c["note"] or ""), None))
        else:
            todo.append((f, st, key))
    if out:
        say(f"Reusing {len(out):,} cached decisions")
    if not todo:
        return out
    # One real request before the queue goes out, so a server that is down fails here, at once and
    # in its own words. Only now that something needs deciding: a plan whose files were all decided
    # before asks the model nothing, and 0.2.1 still failed it when the model wasn't running.
    ok, msg = dmod.probe(decider, cfg)
    say(("Decider ok: " if ok else "Decider FAILED: ") + msg)
    if not ok:
        raise DeweyExit("Start the decision model server (see README), fix [decider] in dewey.toml, "
                        "or rerun with --backend none for rules only.", DECIDER)
    prog = Progress("Deciding", total=len(todo))
    errors_in_a_row = 0
    # Not `with ThreadPoolExecutor` (it waits for the whole queue on Ctrl-C). On any exit, queued
    # requests are dropped and every answer so far stays in the cache, so a rerun picks up from here.
    pool = ThreadPoolExecutor(max_workers=max(1, int(cfg["decider"]["workers"])))
    try:
        futs = {pool.submit(decider.choose, st, q, options): (f, st, key) for f, st, key in todo}
        for i, fut in enumerate(as_completed(futs), 1):
            f, st, key = futs[fut]
            try:
                dec = fut.result()
                errors_in_a_row = 0
                conn.execute("INSERT OR REPLACE INTO decision_cache VALUES (?,?,?,?,?,?,?)",
                             (key, dec.choice, dec.confidence, json.dumps(dec.probabilities),
                              dec.decided_by, dec.note, now_iso()))
                out.append((f, st, dec, None))
            except dmod.DecisionError as e:
                errors_in_a_row += 1
                out.append((f, st, None, str(e)))
                if errors_in_a_row >= 25:
                    raise DeweyExit(f"decider failed 25 times in a row; last error: {e}", DECIDER)
            prog.update(1)
            if i % 100 == 0:
                conn.commit()
    except BaseException:
        pool.shutdown(wait=False, cancel_futures=True)
        conn.commit()
        raise
    pool.shutdown()
    conn.commit()
    prog.done()
    return out


def _alts(probs: dict, exclude: str, n: int = 2) -> str:
    ranked = sorted(((p, k) for k, p in probs.items() if k != exclude), reverse=True)[:n]
    return "; ".join(f"{k} {p:.2f}" for p, k in ranked if p > 0)


def plan(conn: sqlite3.Connection, root: Path, cfg: dict, decider, state_dir: Path) -> dict:
    p = cfg["plan"]
    review = p["review_dir"].strip("/")
    dest_root = Path(p["dest"]).expanduser().resolve() if p["dest"] else root
    check_safe_root(root)
    if dest_root != root and root not in dest_root.parents:  # filing outside the folder
        why = unsafe_dest(dest_root)
        if why:
            raise DeweyExit(f"plan.dest: {dest_root} is no place to file into: {why}", UNSAFE_DEST)
        say(f"note: this plan files things into {dest_root}, outside this folder.")
    # A destination that is a folder inside this one (`dest = ".../Downloads/Sorted"`) is scanned with
    # the rest, and what is in it is filed already, as it would be in a destination anywhere else.
    # 0.2.1 planned those files again on every run: each one "moved" onto itself, so it was renamed
    # "a (2).zip", and the destination was offered as a whole folder to move into itself.
    dest_in = os.path.relpath(dest_root, root) if dest_root != root and root in dest_root.parents else ""
    filed = lambda f: bool(dest_in) and _inside(f["rel_path"], dest_in)
    review_at = f"{dest_in}/{review}" if dest_in else review  # the review folder, as a path in this folder
    in_review = lambda f: _inside(f["rel_path"], review_at)
    scan = conn.execute("SELECT * FROM scans WHERE finished IS NOT NULL ORDER BY id DESC LIMIT 1").fetchone()
    if not scan:
        raise DeweyExit("no completed scan yet; run `dewey scan` first", NO_CATALOG)
    algo = (conn.execute("SELECT hash_algo FROM files WHERE hash_algo IS NOT NULL LIMIT 1").fetchone() or ["hash"])[0]
    hidden_too = bool(cfg["scan"].get("include_hidden", False))
    files = [f for f in conn.execute("SELECT * FROM files WHERE missing=0")  # a scan from before 0.2.1 kept these
             if not left_alone(f["rel_path"], hidden_too)]
    regular = [f for f in files if f["kind"] == "file" and f["hash"]]
    unreadable = [f for f in files if f["kind"] == "file" and not f["hash"]]
    units = [f for f in files if f["kind"] in UNIT_KINDS]
    symlinks = [f for f in files if f["kind"] == "symlink"]
    cloud = [f for f in files if f["kind"] == "cloud"]
    cats = cfg["categories"]

    rows: list[dict] = []
    counts = Counter()

    def add(f, target_dir, action, status, category, decided_by, confidence, reason, alts="", state=None):
        cur_dir = os.path.dirname(f["rel_path"])
        if target_dir and dest_root == root and (norm_key(cur_dir) == norm_key(target_dir)
                                                 or norm_key(cur_dir).startswith(norm_key(target_dir) + "/")):
            counts["already_filed"] += 1
            return
        rows.append(dict(file=f, target_dir=target_dir, action=action, status=status, category=category,
                         decided_by=decided_by, confidence=round(float(confidence), 4), reason=reason,
                         alternatives=alts, state=state or build_state(f)))

    max_depth = int(p["max_depth"])

    def too_deep(f) -> bool:  # inside a folder that stays whole
        return max_depth >= 0 and f["rel_path"].count("/") > max_depth

    whole = defaultdict(list)  # folder left whole -> catalog rows inside it
    for f in regular:
        if too_deep(f) and not in_review(f):
            whole["/".join(f["rel_path"].split("/")[:max_depth + 1])].append(f)

    # 1. duplicates ------------------------------------------------------------
    groups = defaultdict(list)
    for f in regular:
        if f["size"]:
            groups[f["hash"]].append(f)
    dup_ids, dup_groups = set(), []
    for h, fs in groups.items():
        if len(fs) < 2:
            continue
        # A copy inside a folder that stays whole, or one that is filed already, can't move, so it
        # is the one kept (unless it's already in the review area); only copies that may move go to review.
        stays = lambda f: too_deep(f) or filed(f)
        pinned = [f for f in fs if stays(f) and not in_review(f)]
        keeper = pick_keeper(pinned or fs, p["keep_duplicate"], review_at)
        others = [f for f in fs if f["id"] != keeper["id"] and not stays(f)]
        if not others:
            continue
        dup_groups.append((keeper, others))
        for f in others:
            dup_ids.add(f["id"])
            add(f, f"{review}/Duplicates/{h[:10]}", "duplicate", "auto", "duplicate", "hash", 1.0,
                f"Exact duplicate of {keeper['rel_path']} ({algo} match)")

    # 2. rules -----------------------------------------------------------------
    rules = compile_rules(cfg)
    queue = []
    for f in regular:
        if f["id"] in dup_ids:
            continue
        if in_review(f):
            counts["in_review_area"] += 1
            continue
        if filed(f):
            counts["already_filed"] += 1
            continue
        if too_deep(f):
            counts["below_max_depth"] += 1
            continue
        r = first_match(rules, f)
        if r:
            add(f, fill(r.target, f, review), "move", "auto", f"rule:{r.name}", f"rule:{r.name}", 1.0,
                fill(r.reason, f, review))
        else:
            queue.append((f, build_state(f)))

    # 3. decision model ----------------------------------------------------------
    options = {k: v["desc"] for k, v in cats.items()}
    auto_c, rev_c = float(p["auto_confidence"]), float(p["review_confidence"])
    if decider.kind == "none":
        counts["no_rule_matched"] = len(queue)
        results = []
    else:
        results = decide_all(conn, decider, queue, cfg, options)
    for f, st, dec, err in results:
        if err:
            counts["decider_error"] += 1
            add(f, "", "move", "skip", "", "error", 0.0, f"decider error: {err[:120]}", state=st)
            continue
        choice, conf = dec.choice, dec.confidence
        path = cats.get(choice, {}).get("path", "")
        note = f" [{dec.note}]" if dec.note else ""
        if not path:  # "other"/leave-in-place: offer the best real folder, but don't move it
            real = {k: v for k, v in dec.probabilities.items() if cats.get(k, {}).get("path")}
            if real:
                best = max(real, key=real.get)
                add(f, cats[best]["path"], "move", "skip", best, dec.decided_by, real[best],
                    f"Model picked '{choice}' ({conf:.2f}); best real folder shown{note}",
                    _alts(dec.probabilities, best), st)
            else:
                counts["model_other"] += 1
            continue
        status = "auto" if conf >= auto_c else "review" if conf >= rev_c else "skip"
        label = cats[choice]["desc"].split(",")[0]
        add(f, path, "move", status, choice, dec.decided_by, conf,
            f"Model: {choice} ({label}) at {conf:.2f}{note}", _alts(dec.probabilities, choice), st)

    # 4. folders left whole: label each, offer ONE review row that moves it as a unit ----------
    folder_info = _plan_folders(cfg, root, review, max_depth, whole, units, add, rows, dest_in)

    # 5. destination names: no collisions on a case-insensitive filesystem ------
    taken: set[str] = set()
    rows.sort(key=lambda r: ({"auto": 0, "review": 1, "skip": 2}[r["status"]],
                             r["action"] != "duplicate", r["target_dir"], r["file"]["rel_path"]))
    for r in rows:
        if not r["target_dir"]:  # nowhere to go (e.g. decider error): dst = src, a no-op
            r["dst"] = r["file"]["rel_path"]
            continue
        name = r["file"]["name"]
        stem, ext = (name, "") if r["action"] == "folder" else os.path.splitext(name)
        n, cand = 1, name
        while True:
            rel = f"{r['target_dir']}/{cand}"
            if norm_key(rel) not in taken and not os.path.lexists(dest_root / rel):
                break
            n += 1
            cand = f"{stem} ({n}){ext}"
        taken.add(norm_key(rel))
        r["dst"] = rel
        if cand != name:
            r["reason"] += f"; renamed to avoid a name clash"

    # 6. persist ------------------------------------------------------------------
    cur = conn.execute("INSERT INTO plans (created, scan_id, dest_root, decider, root) VALUES (?,?,?,?,?)",
                       (now_iso(), scan["id"], str(dest_root), decider.name, str(root)))
    plan_id = cur.lastrowid
    for i, r in enumerate(rows, 1):
        r["row"] = i
        f = r["file"]
        conn.execute("INSERT INTO plan_rows VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                     (plan_id, i, f["id"], f["hash"], f["size"], f["rel_path"], r["dst"], r["action"],
                      r["status"], r["category"], r["decided_by"], r["confidence"], r["reason"],
                      r["alternatives"], json.dumps(r["state"], ensure_ascii=False)))
    csv_path, report_path = plan_files(state_dir, plan_id)
    with open(csv_path, "w", newline="", encoding="utf-8-sig") as fh:  # BOM: Excel then reads it as UTF-8
        w = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
        w.writeheader()
        for r in rows:
            w.writerow({"row": r["row"], "status": r["status"], "action": r["action"],
                        "src": r["file"]["rel_path"], "dst": r["dst"], "category": r["category"],
                        "confidence": f"{r['confidence']:.2f}", "decided_by": r["decided_by"],
                        "reason": r["reason"], "alternatives": r["alternatives"]})
    ctx = dict(plan_id=plan_id, root=root, dest_root=dest_root, scan=scan, decider=decider.name,
               rows=rows, dup_groups=dup_groups, units=units, symlinks=symlinks, unreadable=unreadable, cloud=cloud,
               counts=counts, n_files=len(regular), review=review, whole=whole, max_depth=max_depth,
               folders=folder_info)
    report_path.write_text(render_report(ctx), encoding="utf-8")
    summary = summarize(rows)
    conn.execute("UPDATE plans SET csv_path=?, report_path=?, summary=? WHERE id=?",
                 (str(csv_path), str(report_path), json.dumps(summary), plan_id))
    conn.commit()
    nf = summary["folder"]["n"]
    folders_note = f" · {nf:,} whole folder{'s' if nf != 1 else ''} to review" if nf else ""
    say(f"Plan {plan_id}: {summary['auto']['n']:,} auto · {summary['review']['n']:,} review · "
        f"{summary['skip']['n']:,} unsure (left in place){folders_note}. "
        f"Includes {summary['duplicate']['n']:,} exact duplicates -> {review}/Duplicates "
        f"({human_bytes(summary['duplicate']['bytes'])} reclaimable)")
    say(f"  report: {report_path}\n  plan:   {csv_path}")
    return dict(plan_id=plan_id, csv=str(csv_path), report=str(report_path), summary=summary)


def _plan_folders(cfg: dict, root: Path, review: str, max_depth: int, whole: dict, units: list,
                  add, rows: list, dest_in: str = "") -> list[dict]:
    """Label every folder left whole; add one review row per folder that has a home for its kind.

    `dest_in`: the destination, when it is a folder inside this one. It is where dewey files things,
    so neither it, nor a folder in it, nor a folder that holds it is offered as a folder to move."""
    if max_depth < 0:
        return []
    fcfg = cfg.get("folders") or {}
    homes = {k: v.strip("/") for k, v in fcfg.items() if k in fkind.LABELS and isinstance(v, str)}
    may_move = bool(fcfg.get("move", True))
    first = lambda p: p.replace("{review}", review).strip("/").split("/")[0]
    # folders dewey files things into (Code, Images, _Review, ...) are the filing cabinet, not mess
    filing = {norm_key(first(p)) for p in [review, *(c["path"] for c in cfg["categories"].values()),
                                           *(r["target"] for r in cfg.get("rules", [])), *homes.values()]
              if p and "{" not in first(p)}
    cands = {prefix: (members, None, None) for prefix, members in whole.items()}
    for u in units:  # a project folder at the top is one catalog unit; its insides were never walked
        if u["kind"] == "project" and u["rel_path"].count("/") == max_depth and u["rel_path"] not in cands:
            marker = next((m for m in cfg["scan"]["project_markers"] if os.path.lexists(root / u["rel_path"] / m)),
                          "project marker")
            cands[u["rel_path"]] = ([], u, marker)
    info = []
    for prefix in sorted(cands, key=str.casefold):
        members, unit, marker = cands[prefix]
        name = os.path.basename(prefix)
        size = unit["size"] if unit else sum(f["size"] or 0 for f in members)
        n_files = None if unit else len(members)
        is_dest = dest_in and (norm_key(prefix) == norm_key(dest_in) or _inside(prefix, dest_in)
                               or _inside(dest_in, prefix))
        if norm_key(prefix.split("/")[0]) in filing or is_dest:
            info.append(dict(path=prefix, kind="filing", why="dewey files things here", n=n_files, bytes=size, row=None))
            continue
        inner = [u for u in units if u["rel_path"].startswith(prefix + "/")]
        # hidden files aren't in the catalog, so the two that say "code" are looked for on disk
        git = [m for m in (".github", ".gitignore") if os.path.lexists(root / prefix / m)]
        kind, why = fkind.classify(name, members, inner, marker, git_files=git)
        home = homes.get(kind, "") if may_move else ""
        row = None
        if home:
            f = {"id": unit["id"] if unit else None, "rel_path": prefix, "name": name, "size": size, "hash": None}
            before = len(rows)
            add(f, home, "folder", "review", kind, "folder-kind", 1.0,
                f"Whole folder ({fkind.LABELS[kind]}): {why}. Contents move with it, untouched.",
                state={"folder": prefix, "kind": kind, "why": why, "files": n_files})
            row = rows[-1] if len(rows) > before else None
        info.append(dict(path=prefix, kind=kind, why=why, n=n_files, bytes=size, row=row))
    return info


def summarize(rows: list[dict]) -> dict:
    s = {k: {"n": 0, "bytes": 0} for k in ("auto", "review", "skip", "duplicate", "folder")}
    for r in rows:
        size = r["file"]["size"] or 0
        if r["action"] == "folder":  # counted on their own: one row is a whole folder, not a file
            s["folder"]["n"] += 1
            s["folder"]["bytes"] += size
            continue
        s[r["status"]]["n"] += 1
        s[r["status"]]["bytes"] += size
        if r["action"] == "duplicate":
            s["duplicate"]["n"] += 1
            s["duplicate"]["bytes"] += size
    return s


# ---------------------------------------------------------------- report ----

def _tree(rows: list[dict], max_children: int = 30) -> list[str]:
    node = lambda: {"n": 0, "bytes": 0, "kids": {}}
    top = node()
    for r in rows:
        if r["status"] == "skip" or not r["target_dir"]:
            continue
        cur = top
        for part in r["target_dir"].split("/"):
            cur = cur["kids"].setdefault(part, node())
            cur["n"] += 1
            cur["bytes"] += r["file"]["size"] or 0
    lines: list[str] = []

    def walk(d: dict, prefix: str):
        items = sorted(d["kids"].items(), key=lambda kv: (-kv[1]["n"], kv[0]))
        shown = items[:max_children]
        for i, (name, sub) in enumerate(shown):
            last = i == len(shown) - 1 and len(items) <= max_children
            branch = "└── " if last else "├── "
            label = f"{prefix}{branch}{name}/"
            noun = "file " if sub["n"] == 1 else "files"
            lines.append(f"{label:<52} {sub['n']:>6,} {noun} {human_bytes(sub['bytes']):>10}")
            walk(sub, prefix + ("    " if last else "│   "))
        if len(items) > max_children:
            lines.append(f"{prefix}└── … {len(items) - max_children} more folders")

    walk(top, "")
    return lines


def _md(s: str) -> str:
    return str(s).replace("|", "\\|").replace("\n", " ")


def render_report(c: dict) -> str:
    review = c["review"]
    s = summarize(c["rows"])
    rows = [r for r in c["rows"] if r["action"] != "folder"]  # whole folders get their own table
    by_status = defaultdict(list)
    for r in rows:
        by_status[r["status"]].append(r)
    unit_bytes = sum(u["size"] or 0 for u in c["units"])
    out = [f"# dewey plan {c['plan_id']}: `{c['root']}`", "",
           f"Generated {datetime.now():%Y-%m-%d %H:%M} from scan {c['scan']['id']} "
           f"({c['scan']['files']:,} files, {human_bytes(c['scan']['bytes'] or 0)}). Decider: `{c['decider']}`."]
    if c["dest_root"] != c["root"]:
        out.append(f"Destination root: `{c['dest_root']}`")
    out += ["", "Nothing has moved yet. Edit the CSV, then `dewey apply`.", "", "## Summary", "",
            "| | Files | Size |", "|---|---:|---:|",
            f"| Will move (auto) | {s['auto']['n']:,} | {human_bytes(s['auto']['bytes'])} |",
            f"| Needs your OK (review) | {s['review']['n']:,} | {human_bytes(s['review']['bytes'])} |",
            f"| Unsure, left in place unless you flip it | {s['skip']['n']:,} | {human_bytes(s['skip']['bytes'])} |",
            f"| …of the above, exact duplicates → `{review}/Duplicates` | {s['duplicate']['n']:,} | "
            f"{human_bytes(s['duplicate']['bytes'])} reclaimable |",
            f"| Already where they belong | {c['counts']['already_filed']:,} | |",
            f"| Bundles & projects kept whole, not touched | {len(c['units']):,} | {human_bytes(unit_bytes)} |",
            f"| Symlinks (cataloged, never moved) | {len(c['symlinks']):,} | |",
            f"| Unreadable | {len(c['unreadable']):,} | |"]
    if c["cloud"]:
        out.append(f"| iCloud placeholders, not downloaded (skipped) | {len(c['cloud']):,} | "
                   f"{human_bytes(sum(f['size'] or 0 for f in c['cloud']))} |")
    if c["folders"]:
        nf = len(c["folders"])
        wf = sum(len(m) for m in c["whole"].values())
        out.append(f"| Inside {nf:,} folder{'s' if nf != 1 else ''} kept whole (never split) | {wf:,} | "
                   f"{human_bytes(sum(f['bytes'] or 0 for f in c['folders']))} |")
    if s["folder"]["n"]:
        out.append(f"| …of those, whole folders you can move as one piece (review rows) | "
                   f"{s['folder']['n']:,} folders | {human_bytes(s['folder']['bytes'])} |")
    if c["counts"]["model_other"]:
        out.append(f"| Model said none of the folders fit | {c['counts']['model_other']:,} | |")
    if c["counts"]["no_rule_matched"]:
        out.append(f"| No rule matched (rules-only mode, left in place) | {c['counts']['no_rule_matched']:,} | |")
    if c["counts"]["decider_error"]:
        out.append(f"| Decider errors (listed as skip) | {c['counts']['decider_error']:,} | |")

    tree = _tree(rows)
    if tree:
        out += ["", "## Where things would go (auto + review)", "", "```text", f"{c['dest_root'].name}/", *tree, "```"]
        tops = Counter()
        for r in rows:
            if r["status"] != "skip" and r["target_dir"]:
                tops[r["target_dir"].split("/")[0]] += 1
        out += ["", "```mermaid", "pie showData title Files by destination",
                *[f'    "{_md(k)}" : {v}' for k, v in tops.most_common(12)], "```"]

    how = Counter()
    conf_sum = defaultdict(float)
    for r in rows:
        k = "duplicate (hash)" if r["action"] == "duplicate" else \
            r["decided_by"] if r["decided_by"].startswith("rule:") else \
            "decision model" if r["decided_by"].startswith(DECIDER_PREFIXES) else r["decided_by"]
        how[k] += 1
        conf_sum[k] += r["confidence"]
    if how:
        out += ["", "## How each decision was made", "", "| Source | Files | Avg confidence |", "|---|---:|---:|"]
        out += [f"| {_md(k)} | {v:,} | {conf_sum[k] / v:.2f} |" for k, v in how.most_common()]

    if c["dup_groups"]:
        top = sorted(c["dup_groups"], key=lambda g: -(g[0]["size"] or 0) * len(g[1]))[:15]
        out += ["", f"## Biggest duplicate groups ({len(c['dup_groups']):,} group{'s' if len(c['dup_groups']) != 1 else ''} total)", "",
                "| Copies | Size each | Kept | Moved to review |", "|---:|---:|---|---|"]
        for keeper, others in top:
            moved = ", ".join(f"`{_md(o['rel_path'])}`" for o in others[:3]) + (" …" if len(others) > 3 else "")
            out.append(f"| {len(others) + 1} | {human_bytes(keeper['size'])} | `{_md(keeper['rel_path'])}` | {moved} |")

    def table(title: str, items: list[dict], limit: int = 40):
        if not items:
            return
        items = sorted(items, key=lambda r: r["confidence"])
        out.extend(["", f"## {title} ({len(items):,})", "",
                    "| Row | File | Proposed | Conf | Runner-up |", "|---:|---|---|---:|---|"])
        for r in items[:limit]:
            out.append(f"| {r['row']} | `{_md(r['file']['rel_path'])}` | `{_md(r['target_dir'] or '(stay)')}` | "
                       f"{r['confidence']:.2f} | {_md(r['alternatives'])} |")
        if len(items) > limit:
            out.append(f"\n…{len(items) - limit:,} more in the CSV.")

    table("Needs your OK (status = review)", by_status["review"])
    table("Unsure: left in place unless you change status to auto", by_status["skip"])

    if c["folders"]:
        deep = "loose files in the top folder" if c["max_depth"] == 0 else f"files up to {c['max_depth']} folders deep"
        out += ["", f"## Folders kept whole ({len(c['folders']):,})", "",
                f"Only {deep} are planned (`plan.max_depth = {c['max_depth']}`), so nothing inside these "
                "folders is ever split. A folder with a suggested home has ONE `review` row that moves the "
                "whole folder, contents untouched: set its `status` to `auto` to accept, change its "
                "`category` to another kind or folder key to send it elsewhere, or leave it as `review`.",
                "", "| Folder | Looks like | Because | Files | Size | Suggested move |", "|---|---|---|---:|---:|---|"]
        for f in c["folders"][:80]:
            r = f["row"]
            move = f"row {r['row']}: `{_md(r['dst'])}/`" if r else "stays where it is"
            out.append(f"| `{_md(f['path'])}/` | {fkind.LABELS[f['kind']]} | {_md(f['why'])} | "
                       f"{'' if f['n'] is None else format(f['n'], ',')} | {human_bytes(f['bytes'] or 0)} | {move} |")
        if len(c["folders"]) > 80:
            out.append(f"\n…{len(c['folders']) - 80:,} more.")
    if c["units"]:
        out += ["", "## Kept whole (bundles and projects)", "", "| Kind | Path | Size |", "|---|---|---:|"]
        for u in sorted(c["units"], key=lambda u: -(u["size"] or 0))[:40]:
            out.append(f"| {u['kind']} | `{_md(u['rel_path'])}` | {human_bytes(u['size'] or 0)} |")
    if c["unreadable"]:
        out += ["", "## Unreadable (skipped)", ""]
        out += [f"- `{_md(u['rel_path'])}`: {_md(u['error'] or '')}" for u in c["unreadable"][:40]]

    out += ["", "## Next", "",
            f"1. Open `plan-{c['plan_id']}.csv`. Set `status` to `auto`, `review` or `skip`; "
            "edit `dst` or `category` (a category key from dewey.toml) to correct a row. Deleting a row = skip.",
            "2. `dewey apply ROOT --dry-run` to preview, then `dewey apply ROOT` (auto rows) or "
            "`dewey apply ROOT --include-review`.",
            "3. `dewey undo ROOT` reverses the last batch exactly.", ""]
    return "\n".join(out)
