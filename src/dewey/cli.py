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
"""
from __future__ import annotations

import argparse
import json
import sys
from contextlib import closing
from pathlib import Path

from . import __version__, catalog, config, decide, extract, mover, planner
from .progress import human_bytes, say


def _ctx(args):
    root = Path(args.root).expanduser().resolve()
    if not root.is_dir():
        raise SystemExit(f"not a folder: {root}")
    state = config.state_dir_for(root, args.state)
    cfg, cfg_path = config.load(state, args.config)
    if getattr(args, "dest", None):
        cfg["plan"]["dest"] = args.dest
    for k in ("url", "model"):
        if getattr(args, k, None):
            cfg["decider"][k] = getattr(args, k)
    return root, state, cfg, cfg_path


def cmd_init(args):
    root, state, cfg, cfg_path = _ctx(args)
    state.mkdir(parents=True, exist_ok=True)
    target = state / "dewey.toml"
    if target.exists() and not args.force:
        say(f"{target} already exists (use --force to overwrite)")
        return
    target.write_text(config.DEFAULT_TOML.lstrip(), encoding="utf-8")
    say(f"Wrote {target}\nEdit the [categories] to match how you file things, then `dewey doctor {args.root}`.")


def cmd_doctor(args):
    root, state, cfg, cfg_path = _ctx(args)
    say(f"dewey {__version__}  python {sys.version.split()[0]}")
    say(f"root:   {root}\nstate:  {state}\nconfig: {cfg_path or '(built-in defaults; run `dewey init` to customize)'}")
    say(f"rules: {len(cfg.get('rules', []))}   folders for the decider: {len(cfg['categories'])}")
    for name, ok in extract.capabilities().items():
        say(f"  {'ok ' if ok else '-- '} {name}")
    d = decide.make(cfg, args.backend)
    ok, msg = decide.probe(d, cfg)
    say(("decider ok: " if ok else "decider FAILED: ") + msg)
    if not ok:
        say("  Laya:   pip install 'laya[serve]' && laya-serve   (Jev-compatible, POST /v1/systemone)\n"
            "  LLM:    mlx_lm.server --model mlx-community/Qwen3-4B-Instruct-2507-4bit --port 8080\n"
            "          then: --backend chat --url http://127.0.0.1:8080 --model mlx-community/Qwen3-4B-Instruct-2507-4bit")
        raise SystemExit(1)


def cmd_scan(args):
    root, state, cfg, _ = _ctx(args)
    with closing(catalog.open_db(state)) as conn:
        catalog.scan(conn, root, cfg, state)


def cmd_plan(args):
    root, state, cfg, _ = _ctx(args)
    with closing(catalog.open_db(state)) as conn:
        d = decide.make(cfg, args.backend)
        planner.plan(conn, root, cfg, d, state)


def cmd_run(args):
    cmd_scan(args)
    cmd_plan(args)


def cmd_apply(args):
    root, state, cfg, _ = _ctx(args)
    with closing(catalog.open_db(state)) as conn:
        mover.apply(conn, root, cfg, state, plan_id=args.plan, csv_path=args.csv,
                    include_review=args.include_review, dry_run=args.dry_run, prune_empty=args.prune_empty)


def cmd_undo(args):
    root, state, cfg, _ = _ctx(args)
    with closing(catalog.open_db(state)) as conn:
        mover.undo(conn, root, state, args.batch)


def cmd_export_labels(args):
    root, state, cfg, _ = _ctx(args)
    with closing(catalog.open_db(state)) as conn:
        out = Path(args.output) if args.output else state / "labels.jsonl"
        n = mover.export_labels(conn, cfg, out, args.include_rejected)
        say(f"Wrote {n:,} labeled decisions to {out}")


def cmd_status(args):
    root, state, cfg, _ = _ctx(args)
    if not (state / "catalog.db").exists():
        raise SystemExit(f"no catalog yet at {state}; run `dewey scan {args.root}`")
    with closing(catalog.open_db(state)) as conn:
        s = conn.execute("SELECT * FROM scans WHERE finished IS NOT NULL ORDER BY id DESC LIMIT 1").fetchone()
        if s:
            say(f"Last scan #{s['id']} finished {s['finished']}: {s['files']:,} files, {human_bytes(s['bytes'] or 0)}, "
                f"{s['units']} units, {s['errors']} errors")
        for r in conn.execute("SELECT kind, COUNT(*) n, SUM(size) b FROM files WHERE missing=0 GROUP BY kind"):
            say(f"  {r['kind']:<8} {r['n']:>8,}  {human_bytes(r['b'] or 0):>10}")
        d = conn.execute("""SELECT COUNT(*) groups, SUM(extra) copies, SUM(extra*size) wasted FROM
                            (SELECT hash, size, COUNT(*)-1 extra FROM files WHERE kind='file' AND missing=0
                             AND hash IS NOT NULL AND size>0 GROUP BY hash HAVING COUNT(*)>1)""").fetchone()
        if d["groups"]:
            say(f"  duplicates: {d['groups']:,} groups, {d['copies']:,} extra copies, {human_bytes(d['wasted'] or 0)} reclaimable")
        top = conn.execute("SELECT ext, COUNT(*) n, SUM(size) b FROM files WHERE kind='file' AND missing=0 "
                           "GROUP BY ext ORDER BY b DESC LIMIT 8").fetchall()
        if top:
            say("  biggest types: " + ", ".join(f"{r['ext'] or '(none)'} {human_bytes(r['b'] or 0)}" for r in top))
        for p in conn.execute("SELECT id, created, decider, summary FROM plans ORDER BY id DESC LIMIT 5"):
            sm = json.loads(p["summary"] or "{}")
            parts = ", ".join(f"{sm[k]['n']:,} {k}" for k in ("auto", "review", "skip", "duplicate", "folder") if k in sm)
            say(f"Plan {p['id']} ({p['created']}, {p['decider']}): {parts}")
        for b in conn.execute("SELECT batch, COUNT(*) n, SUM(undone_at IS NOT NULL) u FROM moves GROUP BY batch "
                              "ORDER BY MAX(id) DESC LIMIT 5"):
            say(f"Batch {b['batch']}: {b['n']:,} moves{f', {b[2]} undone' if b[2] else ''}")
        lab = conn.execute("SELECT source, COUNT(*) n FROM labels GROUP BY source").fetchall()
        if lab:
            say("Labels for fine-tuning: " + ", ".join(f"{r['source']} {r['n']:,}" for r in lab))
        errs = conn.execute("SELECT rel_path, error FROM scan_errors WHERE scan_id=? LIMIT 20",
                            (s["id"] if s else -1,)).fetchall()
        for e in errs:
            say(f"  ! {e['rel_path']}: {e['error']}")


def main(argv=None):
    if sys.version_info < (3, 11):
        raise SystemExit("dewey needs Python 3.11+ (uses tomllib and hashlib.file_digest)")
    ap = argparse.ArgumentParser(prog="dewey", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=f"dewey {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add(name, fn, help_):
        p = sub.add_parser(name, help=help_)
        p.add_argument("root", help="folder to work on")
        p.add_argument("--state", help="state folder (default ROOT/.dewey)")
        p.add_argument("--config", help="config file (default ROOT/.dewey/dewey.toml)")
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

    args = ap.parse_args(argv)
    try:
        args.fn(args)
    except KeyboardInterrupt:
        say("\ninterrupted. Finished work is saved; if files were moving, `dewey undo ROOT` puts back the ones that moved.")
        raise SystemExit(130)


if __name__ == "__main__":
    main()
