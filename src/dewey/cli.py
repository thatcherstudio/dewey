"""dewey: catalog a folder, recommend an organization, move with a journal, undo exactly.

  dewey init   ROOT          write ROOT/.dewey/dewey.toml (rules, folders, decider settings)
  dewey doctor ROOT          check config, optional extras and the decision model
  dewey scan   ROOT          walk + hash + extract into ROOT/.dewey/catalog.db (incremental)
  dewey plan   ROOT          duplicates, rules, decision model -> plan-N.csv + report-N.md
  dewey run    ROOT          scan, then plan
  dewey apply  ROOT          move the auto rows of the latest plan (--include-review, --dry-run)
  dewey undo   ROOT          reverse the latest batch (or --batch ID)
  dewey status ROOT          what's in the catalog, plans, batches, labels
  dewey export-labels ROOT   your accepted/corrected decisions as JSONL, for fine-tuning

For the Mac app (every command also takes --json: one JSON event per line on stdout):
  dewey rows   ROOT          the plan's rows with your CSV edits applied, as apply will see them
  dewey edit   ROOT          save edits (a JSON list on stdin) into the plan CSV
  dewey app-info             version and app protocol
"""
from __future__ import annotations

import argparse
import json
import signal
import sys
import traceback
from contextlib import closing
from pathlib import Path

from . import __version__, catalog, config, decide, extract, mover, planner, progress
from .errors import BAD_EDIT, NO_CATALOG, NOT_A_FOLDER, DeweyExit
from .progress import emit, human_bytes, say

PROTOCOL = 1  # bump when an event or result shape changes in a way the app must know about


def _ctx(args):
    root = Path(args.root).expanduser().resolve()
    if not root.is_dir():
        raise DeweyExit(f"not a folder: {root}", NOT_A_FOLDER)
    state = config.state_dir_for(root, args.state)
    cfg, cfg_path = config.load(state, args.config)
    if getattr(args, "dest", None):
        cfg["plan"]["dest"] = args.dest
    for k in ("url", "model"):
        if getattr(args, k, None):
            cfg["decider"][k] = getattr(args, k)
    return root, state, cfg, cfg_path


def _need_catalog(state: Path, root_arg: str) -> None:
    if not (state / "catalog.db").exists():
        raise DeweyExit(f"no catalog yet at {state}; run `dewey scan {root_arg}`", NO_CATALOG)


def cmd_init(args):
    root, state, cfg, cfg_path = _ctx(args)
    state.mkdir(parents=True, exist_ok=True)
    target = state / "dewey.toml"
    if target.exists() and not args.force:
        say(f"{target} already exists (use --force to overwrite)")
        return {"config": str(target), "created": False}
    target.write_text(config.DEFAULT_TOML.lstrip(), encoding="utf-8")
    say(f"Wrote {target}\nEdit the [categories] to match how you file things, then `dewey doctor {args.root}`.")
    return {"config": str(target), "created": True}


def cmd_doctor(args):
    root, state, cfg, cfg_path = _ctx(args)
    say(f"dewey {__version__}  python {sys.version.split()[0]}")
    say(f"root:   {root}\nstate:  {state}\nconfig: {cfg_path or '(built-in defaults; run `dewey init` to customize)'}")
    say(f"rules: {len(cfg.get('rules', []))}   folders for the decider: {len(cfg['categories'])}")
    extras = extract.capabilities()
    for name, ok in extras.items():
        say(f"  {'ok ' if ok else '-- '} {name}")
    d = decide.make(cfg, args.backend)
    ok, msg = decide.probe(d, cfg)
    say(("decider ok: " if ok else "decider FAILED: ") + msg)
    result = {"version": __version__, "python": sys.version.split()[0], "root": str(root), "state": str(state),
              "config": str(cfg_path) if cfg_path else None, "rules": len(cfg.get("rules", [])),
              "categories": len(cfg["categories"]), "extras": [{"name": n, "ok": o} for n, o in extras.items()],
              "decider": {"backend": d.kind, "name": d.name, "url": cfg["decider"]["url"],
                          "model": cfg["decider"]["model"], "ok": ok, "message": msg},
              "ok": ok}
    if not ok:
        say("  Laya:   pip install 'laya[serve]' && laya-serve   (Jev-compatible, POST /v1/systemone)\n"
            "  LLM:    mlx_lm.server --model mlx-community/Qwen3-4B-Instruct-2507-4bit --port 8080\n"
            "          then: --backend chat --url http://127.0.0.1:8080 --model mlx-community/Qwen3-4B-Instruct-2507-4bit")
        if not progress.json_mode():  # the app reads "ok": false from the result instead
            raise SystemExit(1)
    return result


def cmd_scan(args):
    root, state, cfg, _ = _ctx(args)
    with closing(catalog.open_db(state)) as conn:
        return catalog.scan(conn, root, cfg, state)


def cmd_plan(args):
    root, state, cfg, _ = _ctx(args)
    with closing(catalog.open_db(state)) as conn:
        d = decide.make(cfg, args.backend)
        return planner.plan(conn, root, cfg, d, state)


def cmd_run(args):
    return {"scan": cmd_scan(args), "plan": cmd_plan(args)}


def cmd_apply(args):
    root, state, cfg, _ = _ctx(args)
    with closing(catalog.open_db(state)) as conn:
        return mover.apply(conn, root, cfg, state, plan_id=args.plan, csv_path=args.csv,
                           include_review=args.include_review, dry_run=args.dry_run, prune_empty=args.prune_empty)


def cmd_undo(args):
    root, state, cfg, _ = _ctx(args)
    with closing(catalog.open_db(state)) as conn:
        return mover.undo(conn, root, state, args.batch)


def cmd_export_labels(args):
    root, state, cfg, _ = _ctx(args)
    with closing(catalog.open_db(state)) as conn:
        out = Path(args.output) if args.output else state / "labels.jsonl"
        n = mover.export_labels(conn, cfg, out, args.include_rejected)
        say(f"Wrote {n:,} labeled decisions to {out}")
        return {"count": n, "path": str(out)}


def cmd_rows(args):
    root, state, cfg, _ = _ctx(args)
    _need_catalog(state, args.root)
    with closing(catalog.open_db(state)) as conn:
        res = mover.plan_rows(conn, root, cfg, args.plan)
    say(f"Plan {res['plan_id']}: {len(res['rows']):,} rows, "
        f"{sum(r['edited'] for r in res['rows']):,} edited since the plan was made")
    return res


def cmd_edit(args):
    root, state, cfg, _ = _ctx(args)
    _need_catalog(state, args.root)
    try:
        edits = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        raise DeweyExit(f"edits on stdin aren't valid JSON: {e}", BAD_EDIT) from None
    with closing(catalog.open_db(state)) as conn:
        res = mover.edit_plan(conn, edits, args.plan, args.expect_sha)
    say(f"Saved {res['changed']:,} changed rows to {res['csv']}")
    return res


def cmd_app_info(args):
    info = {"version": __version__, "protocol": PROTOCOL, "python": sys.version.split()[0],
            "executable": sys.executable}
    say(f"dewey {__version__} (app protocol {PROTOCOL}, python {info['python']})")
    return info


def status_data(conn, root: Path, state: Path) -> dict:
    s = conn.execute("SELECT * FROM scans WHERE finished IS NOT NULL ORDER BY id DESC LIMIT 1").fetchone()
    kinds = [{"kind": r["kind"], "n": r["n"], "bytes": r["b"] or 0} for r in conn.execute(
        "SELECT kind, COUNT(*) n, SUM(size) b FROM files WHERE missing=0 GROUP BY kind")]
    d = conn.execute("""SELECT COUNT(*) groups, SUM(extra) copies, SUM(extra*size) wasted FROM
                        (SELECT hash, size, COUNT(*)-1 extra FROM files WHERE kind='file' AND missing=0
                         AND hash IS NOT NULL AND size>0 GROUP BY hash HAVING COUNT(*)>1)""").fetchone()
    top = [{"ext": r["ext"], "n": r["n"], "bytes": r["b"] or 0} for r in conn.execute(
        "SELECT ext, COUNT(*) n, SUM(size) b FROM files WHERE kind='file' AND missing=0 "
        "GROUP BY ext ORDER BY b DESC LIMIT 8")]
    plans = [{"id": p["id"], "created": p["created"], "decider": p["decider"], "csv": p["csv_path"],
              "report": p["report_path"], "summary": json.loads(p["summary"] or "{}")}
             for p in conn.execute("SELECT * FROM plans ORDER BY id DESC LIMIT 20")]
    batches = [{"batch": b["batch"], "moves": b["n"], "undone": b["u"] or 0, "plan_id": b["plan_id"],
                "moved_at": b["moved_at"]}
               for b in conn.execute("SELECT batch, COUNT(*) n, SUM(undone_at IS NOT NULL) u, MIN(plan_id) plan_id, "
                                     "MIN(moved_at) moved_at FROM moves GROUP BY batch ORDER BY MAX(id) DESC LIMIT 20")]
    labels = [{"source": r["source"], "n": r["n"]}
              for r in conn.execute("SELECT source, COUNT(*) n FROM labels GROUP BY source")]
    errors = [{"path": e["rel_path"], "error": e["error"]} for e in conn.execute(
        "SELECT rel_path, error FROM scan_errors WHERE scan_id=? LIMIT 20", (s["id"] if s else -1,))]
    return {"catalog": True, "root": str(root), "state": str(state), "scan": dict(s) if s else None,
            "kinds": kinds, "duplicates": {"groups": d["groups"] or 0, "copies": d["copies"] or 0,
                                           "wasted": d["wasted"] or 0},
            "top_types": top, "plans": plans, "batches": batches, "undoable": mover.latest_batch(conn, state),
            "labels": labels, "errors": errors}


def cmd_status(args):
    root, state, cfg, _ = _ctx(args)
    if not (state / "catalog.db").exists():
        if progress.json_mode():  # a folder dewey hasn't scanned yet is a normal state for the app
            return {"catalog": False, "root": str(root), "state": str(state)}
        _need_catalog(state, args.root)
    with closing(catalog.open_db(state)) as conn:
        st = status_data(conn, root, state)
    s = st["scan"]
    if s:
        say(f"Last scan #{s['id']} finished {s['finished']}: {s['files']:,} files, {human_bytes(s['bytes'] or 0)}, "
            f"{s['units']} units, {s['errors']} errors")
    for r in st["kinds"]:
        say(f"  {r['kind']:<8} {r['n']:>8,}  {human_bytes(r['bytes']):>10}")
    d = st["duplicates"]
    if d["groups"]:
        say(f"  duplicates: {d['groups']:,} groups, {d['copies']:,} extra copies, {human_bytes(d['wasted'])} reclaimable")
    if st["top_types"]:
        say("  biggest types: " + ", ".join(f"{r['ext'] or '(none)'} {human_bytes(r['bytes'])}" for r in st["top_types"]))
    for p in st["plans"][:5]:
        sm = p["summary"]
        parts = ", ".join(f"{sm[k]['n']:,} {k}" for k in ("auto", "review", "skip", "duplicate", "folder") if k in sm)
        say(f"Plan {p['id']} ({p['created']}, {p['decider']}): {parts}")
    for b in st["batches"][:5]:
        undone = f", {b['undone']} undone" if b["undone"] else ""
        say(f"Batch {b['batch']}: {b['moves']:,} moves{undone}")
    if st["labels"]:
        say("Labels for fine-tuning: " + ", ".join(f"{r['source']} {r['n']:,}" for r in st["labels"]))
    for e in st["errors"]:
        say(f"  ! {e['path']}: {e['error']}")
    return st


class _Parser(argparse.ArgumentParser):
    """In --json mode a usage error is an error event too (subparsers inherit this class)."""

    def error(self, message):
        if progress.json_mode():
            emit("error", code="usage", message=f"{self.prog}: error: {message}")
            raise SystemExit(2)
        super().error(message)


def _parser() -> argparse.ArgumentParser:
    ap = _Parser(prog="dewey", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=f"dewey {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add(name, fn, help_, root=True):
        p = sub.add_parser(name, help=help_)
        if root:
            p.add_argument("root", help="folder to work on")
            p.add_argument("--state", help="state folder (default ROOT/.dewey)")
            p.add_argument("--config", help="config file (default ROOT/.dewey/dewey.toml)")
        p.add_argument("--json", action="store_true", help="one JSON event per line on stdout (for the Mac app)")
        p.set_defaults(fn=fn)
        return p

    p = add("init", cmd_init, "write an editable config"); p.add_argument("--force", action="store_true")
    for name, fn, h in (("doctor", cmd_doctor, "check setup"), ("plan", cmd_plan, "build a plan"),
                        ("run", cmd_run, "scan then plan")):
        p = add(name, fn, h)
        p.add_argument("--backend", choices=["systemone", "chat", "none"], help="override [decider] backend")
        p.add_argument("--url", help="override [decider] url")
        p.add_argument("--model", help="override [decider] model")
        if name != "doctor":
            p.add_argument("--dest", help="organize into this folder instead of inside ROOT")
    add("scan", cmd_scan, "catalog + hash")
    p = add("apply", cmd_apply, "move files per the latest plan")
    p.add_argument("--plan", type=int, help="plan id (default: latest)")
    p.add_argument("--csv", help="edited plan CSV (default: the plan's own plan-N.csv)")
    p.add_argument("--include-review", action="store_true", help="also move rows with status=review")
    p.add_argument("--dry-run", action="store_true", help="show what would move")
    p.add_argument("--prune-empty", action="store_true", help="remove folders left empty (a lone .DS_Store counts as empty)")
    p = add("undo", cmd_undo, "reverse a batch"); p.add_argument("--batch", help="batch id (default: latest)")
    add("status", cmd_status, "summarize the catalog")
    p = add("export-labels", cmd_export_labels, "export decisions for fine-tuning")
    p.add_argument("-o", "--output"); p.add_argument("--include-rejected", action="store_true")
    p = add("rows", cmd_rows, "plan rows with your CSV edits applied (for the Mac app)")
    p.add_argument("--plan", type=int, help="plan id (default: latest)")
    p = add("edit", cmd_edit, "save edits (JSON list on stdin) into the plan CSV (for the Mac app)")
    p.add_argument("--plan", type=int, help="plan id (default: latest)")
    p.add_argument("--expect-sha", help="refuse if the CSV's sha256 isn't this (it changed since it was read)")
    add("app-info", cmd_app_info, "version and app protocol (for the Mac app)", root=False)
    return ap


def _catch_signals() -> dict:
    """--json: the app cancels with SIGINT and quits with SIGTERM; both stop the way Ctrl-C does.

    Set explicitly: a child started with SIGINT ignored would otherwise never see it."""
    def stop(signum, frame):
        raise KeyboardInterrupt
    try:
        return {signal.SIGINT: signal.signal(signal.SIGINT, signal.default_int_handler),
                signal.SIGTERM: signal.signal(signal.SIGTERM, stop)}
    except ValueError:  # not the main thread: leave signals alone
        return {}


def main(argv=None):
    if sys.version_info < (3, 11):
        raise SystemExit("dewey needs Python 3.11+ (uses tomllib and hashlib.file_digest)")
    argv = list(sys.argv[1:] if argv is None else argv)
    as_json = "--json" in argv  # known before parsing, so a usage error is an event too
    progress.set_json(as_json)
    saved = _catch_signals() if as_json else {}
    try:
        args = _parser().parse_args(argv)
        try:
            data = args.fn(args)
        except KeyboardInterrupt as e:
            if as_json:
                emit("interrupted", batch=getattr(e, "batch", None),
                     message="Finished work is saved; if files were moving, undo puts back the ones that moved.")
            else:
                say("\ninterrupted. Finished work is saved; if files were moving, `dewey undo ROOT` puts back the ones that moved.")
            raise SystemExit(130)
        if as_json:
            emit("result", data=data if data is not None else {})
    except SystemExit as e:
        if as_json and not (e.code is None or isinstance(e.code, int)):
            emit("error", code=getattr(e, "kind", "error"), message=str(e.code))
            raise SystemExit(1) from None
        raise
    except Exception as e:  # noqa: BLE001 - in --json mode the app gets an event, the traceback goes to stderr
        if not as_json:
            raise
        traceback.print_exc()
        emit("error", code="internal", message=f"{type(e).__name__}: {e}")
        raise SystemExit(1) from None
    finally:
        for sig, handler in saved.items():
            signal.signal(sig, handler)
        progress.set_json(False)


if __name__ == "__main__":
    main()
