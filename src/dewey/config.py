"""Configuration: one TOML file, defaults embedded here as the single source of truth.

`dewey init ROOT` writes DEFAULT_TOML to ROOT/.dewey/dewey.toml for editing.
User values override defaults key-by-key; [[rules]] and [categories] replace
the defaults wholesale when present (merging rule lists is more confusing than useful).

The Mac app reads settings with `read_settings` and saves them with `write_settings`, which writes
only what differs from the defaults (through `dumps`, a small TOML writer: tomllib only reads).
"""
from __future__ import annotations

import copy
import hashlib
import math
import os
import re
import shutil
import tempfile
import tomllib
from pathlib import Path

from .errors import CONFIG, STALE, DeweyExit
from .folders import LABELS as FOLDER_LABELS

STATE_DIRNAME = ".dewey"

DEFAULT_TOML = r'''
# dewey configuration ------------------------------------------------------
# Anything you delete falls back to the built-in default.
# If you define [[rules]] or [categories] here, yours REPLACE the defaults.

[scan]
hash = "sha256"          # "sha256" (stdlib) or "blake3" (pip install blake3; several times faster)
workers = 4              # parallel hashing/extraction threads
hash_cloud_files = false # iCloud "Optimize Mac Storage" placeholders: reading them downloads them.
                         # false = catalog them but don't read, hash or move them.
snippet_chars = 400      # text preview sent to the decider. Laya's context is 512 tokens and the
                         # folder descriptions share it, so keep this short.
skip_dirs = [".git", ".hg", ".svn", "node_modules", ".venv", "venv", "__pycache__", ".Trash",
             ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
             ".DocumentRevisions-V100", ".cache"]
ignore_files = [".DS_Store", "Icon\r", ".localized", "desktop.ini", "Thumbs.db", ".com.apple.timemachine.donotpresent"]
# Directories ending in these are macOS packages/bundles: cataloged as ONE unit, never opened or split.
# Any folder holding Contents/Info.plist or Contents/PkgInfo is treated as a bundle too, listed or not.
bundle_suffixes = [".app", ".photoslibrary", ".photolibrary", ".migratedphotolibrary", ".aplibrary",
                   ".fcpbundle", ".fcpxmld", ".logicx", ".band", ".xcodeproj", ".xcworkspace",
                   ".xcarchive", ".playground", ".dSYM", ".bundle", ".framework", ".plugin", ".kext",
                   ".appex", ".prefPane", ".qlgenerator", ".mdimporter", ".saver", ".workflow", ".scptd",
                   ".lrdata", ".lrcat-data", ".lrlibrary", ".rtfd", ".textbundle", ".pages", ".numbers",
                   ".key", ".graffle", ".dtBase2", ".sparsebundle", ".musiclibrary", ".tvlibrary",
                   ".imovielibrary", ".scriv", ".pkg", ".mpkg", ".pvm", ".vmwarevm", ".utm"]
# A folder containing any of these is a project: cataloged as one unit and left in place.
# Not just repos: a GitHub "Download ZIP" has no .git, so build files count too.
project_markers = [".git", ".hg", ".svn", "package.json", "pyproject.toml", "setup.py", "Cargo.toml",
                   "go.mod", "Gemfile", "pom.xml", "build.gradle", "composer.json", "CMakeLists.txt",
                   "Makefile"]

[plan]
dest = ""                 # "" = reorganize inside the scanned folder; or an absolute path elsewhere
review_dir = "_Review"    # duplicates / junk / empties land here. Nothing is ever deleted.
keep_duplicate = "oldest" # which copy stays put: "oldest" | "newest" | "shortest_path"
auto_confidence = 0.85    # decider answers at/above this -> status "auto"
review_confidence = 0.50  # between this and auto -> "review"; below -> left in place, listed as unsure
max_depth = 0             # 0 = only loose files in the top folder move; every subfolder stays whole
                          # (nothing is pulled out of it, not even duplicates). N = files up to N
                          # folders deep may move. -1 = file everything individually (splits folders).

[folders]
# Folders that stay whole get a kind in the report (from what's inside them), and ONE review row
# that moves the whole folder, contents untouched, on the same disk. Approve it in the CSV like any
# review row, or change its category to another kind or folder key. move = false: label only.
move = true
# kind = where a folder of that kind goes ("" = label it, leave it where it is)
code = "Code"            # project markers, Xcode projects, .github, mostly source, GitHub "-main" ZIPs
cad = "3D & CAD"         # .scad/.step/.f3d sources, or mostly .stl/.3mf
design = "Design"        # design sources (.fig/.psd/.sketch), or images with specs/README (handoffs)
images = "Images"        # icon sets, folders of downloaded pictures
photos = "Photos"        # mostly camera photos (EXIF)
documents = "Documents"  # mostly PDFs, Office files, text
video = "Videos"
audio = "Audio"
mixed = ""               # no clear kind: labelled, left where it is

[decider]
backend = "systemone"     # "systemone": Laya or any Jev-compatible server (POST /v1/systemone)
                          # "chat": any OpenAI-compatible server (mlx_lm.server, oMLX, Ollama, LM Studio)
                          # "none": rules only
url = "http://127.0.0.1:8000"
model = "english"         # laya-serve checkpoint name; for chat e.g. "mlx-community/Qwen3-4B-Instruct-2507-4bit"
question = "Which folder should this file be filed in?"
timeout = 30
workers = 4               # concurrent requests to the decider
trust_chat_confidence = false   # chat LLMs self-report confidence (uncalibrated). When false, chat
                                # answers are capped just below auto_confidence so a human reviews them.

# Rules run first, top to bottom, first match wins. Anything no rule claims goes to the decider.
# Match keys (all optional; every key given must match):
#   ext = [".pdf"], name_regex = "...", path_regex = "...", min_size / max_size (bytes), has_camera = true
# target/reason placeholders: {review} {year} {month} {camera}
#   {year}/{month} come from photo EXIF when available, else the file's modified date.

[[rules]]
name = "empty"
max_size = 0
target = "{review}/Empty"
reason = "Zero-byte file"

[[rules]]
name = "partial-download"
ext = [".crdownload", ".part", ".partial", ".download", ".tmp", ".temp"]
target = "{review}/Junk"
reason = "Incomplete download or temp file"

[[rules]]
name = "office-lockfile"
name_regex = '^(~\$|\.~lock\.)'
target = "{review}/Junk"
reason = "Office lock/owner file left behind"

[[rules]]
name = "screenshot"
name_regex = '^(Screenshot|Screen Shot|Screen Recording|CleanShot) '
target = "Screenshots/{year}"
reason = "macOS screenshot naming"

[[rules]]
name = "camera-photo"
has_camera = true
target = "Photos/{year}"
reason = "EXIF says it came from a camera ({camera})"

[[rules]]
name = "phone-raw-photo"
ext = [".heic", ".heif", ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".orf", ".rw2"]
target = "Photos/{year}"
reason = "Phone/camera photo format"

[[rules]]
name = "video"
ext = [".mov", ".mp4", ".m4v", ".avi", ".mkv", ".mts", ".webm"]
target = "Videos/{year}"
reason = "Video file"

[[rules]]
name = "audio"
ext = [".mp3", ".m4a", ".wav", ".aiff", ".aif", ".flac", ".ogg", ".opus", ".aac"]
target = "Audio"
reason = "Audio file"

[[rules]]
name = "installer"
ext = [".dmg", ".pkg", ".mpkg", ".exe", ".msi", ".iso", ".appimage", ".deb", ".rpm", ".apk", ".ipsw"]
target = "Installers"
reason = "Installer / disk image (usually re-downloadable)"

[[rules]]
name = "3d-cad"
ext = [".stl", ".3mf", ".step", ".stp", ".obj", ".f3d", ".f3z", ".gcode", ".bgcode", ".scad", ".iges", ".igs", ".skp", ".dxf"]
target = "3D & CAD"
reason = "3D model / CAD / slicer file"

[[rules]]
name = "fonts"
ext = [".ttf", ".otf", ".woff", ".woff2"]
target = "Fonts"
reason = "Font file"

[[rules]]
name = "archives"
ext = [".zip", ".tar", ".gz", ".tgz", ".7z", ".rar", ".bz2", ".xz", ".zst"]
target = "Archives"
reason = "Compressed archive"

# The decider picks exactly ONE of these for each file no rule claimed.
# Keys are the answers it gives (keep them stable once you start collecting labels).
# Descriptions are what the model reads: short and concrete beats long and clever.
# path = "" means "leave it where it is".

[categories.finance]
path = "Documents/Finance"
desc = "bank or card statements, invoices, receipts, bills, tax forms, pay stubs, budgets"

[categories.medical]
path = "Documents/Medical"
desc = "medical records, health insurance, prescriptions, lab results, EOBs"

[categories.home]
path = "Documents/Home"
desc = "mortgage, deed, home insurance, utilities, warranties, contractor quotes, property tax"

[categories.vehicles]
path = "Documents/Vehicles"
desc = "vehicle registration, title, service records, auto insurance"

[categories.manuals]
path = "Documents/Manuals"
desc = "product manuals, user guides, datasheets, spec sheets, install instructions"

[categories.work]
path = "Documents/Work"
desc = "job documents: reports, policies, meeting notes, proposals, presentations"

[categories.personal]
path = "Documents/Personal"
desc = "letters, certificates, school records, resumes, legal papers"

[categories.reference]
path = "Documents/Reference"
desc = "articles, papers, ebooks, how-to guides saved for reading"

[categories.data]
path = "Data"
desc = "raw data: CSV/JSON/XML exports, databases, logs, datasets"

[categories.code]
path = "Code"
desc = "source code, scripts, config files, notebooks"

[categories.images]
path = "Images"
desc = "graphics, logos, icons, diagrams, downloaded pictures (not personal photos)"

[categories.design]
path = "Design"
desc = "design source files and mockups: SVG, PSD, layouts"

[categories.notes]
path = "Notes"
desc = "personal notes, drafts, to-do lists, brainstorms"

[categories.other]
path = ""
desc = "none of the above / not sure"
'''

DEFAULTS: dict = tomllib.loads(DEFAULT_TOML)
REPLACE_WHOLESALE = {"rules", "categories"}


def _merge(base: dict, over: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in over.items():
        if k in REPLACE_WHOLESALE:
            out[k] = copy.deepcopy(v)
        elif isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def state_dir_for(root: Path, override: str | None = None) -> Path:
    return Path(override).expanduser().resolve() if override else root / STATE_DIRNAME


def find_config(state_dir: Path, explicit: str | None) -> Path | None:
    if explicit:
        p = Path(explicit).expanduser()
        if not p.is_file():
            raise DeweyExit(f"config not found: {p}", CONFIG)
        return p
    for p in (state_dir / "dewey.toml",
              Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "dewey" / "dewey.toml"):
        if p.is_file():
            return p
    return None


def load(state_dir: Path, explicit: str | None = None) -> tuple[dict, Path | None]:
    path = find_config(state_dir, explicit)
    if path is None:
        return copy.deepcopy(DEFAULTS), None
    cfg = _merge(DEFAULTS, _parse(path.read_bytes().decode("utf-8", errors="replace"), path))
    check_types(cfg)
    validate(cfg)
    return cfg, path


def _parse(text: str, path: Path) -> dict:
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:  # a typo in dewey.toml: say where, not a traceback
        raise DeweyExit(f"config: {path} isn't valid TOML: {e}", CONFIG) from None


# in the order the default file writes them: name, what it matches, where it goes
RULE_TYPES = {"name": str, "ext": list, "name_regex": str, "path_regex": str, "min_size": int, "max_size": int,
              "has_camera": bool, "target": str, "reason": str}


def _type_ok(value, like) -> bool:
    """`value` may stand where `like` is: bool is not a number, an int may be a float, lists hold strings."""
    if isinstance(like, bool) or like is bool:
        return isinstance(value, bool)
    if isinstance(like, float) or like is float:
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if isinstance(like, int) or like is int:
        return isinstance(value, int) and not isinstance(value, bool)
    if isinstance(like, list) or like is list:
        return isinstance(value, list) and all(isinstance(x, str) for x in value)
    return isinstance(value, type(like) if not isinstance(like, type) else like)


def _type_name(like) -> str:
    t = like if isinstance(like, type) else type(like)
    return {bool: "true or false", int: "a whole number", float: "a number", str: "text",
            list: "a list of text"}.get(t, t.__name__)


def check_types(cfg: dict) -> None:
    """Every known setting has the type of its default (a typo like workers = "4" says so here,
    instead of failing halfway through a scan). Settings dewey doesn't know are left alone."""
    for sec in ("scan", "plan", "folders", "decider"):
        if not isinstance(cfg.get(sec), dict):
            raise DeweyExit(f"config: [{sec}] must be a table", CONFIG)
        for k, v in cfg[sec].items():
            like = DEFAULTS[sec].get(k, str if sec == "folders" else None)
            if like is not None and not _type_ok(v, like):
                raise DeweyExit(f"config: {sec}.{k} must be {_type_name(like)}, not {v!r}", CONFIG)
    rules = cfg.get("rules", [])
    if not isinstance(rules, list) or not all(isinstance(r, dict) for r in rules):
        raise DeweyExit("config: rules must be a list of [[rules]] tables", CONFIG)
    for r in rules:
        for k, like in RULE_TYPES.items():
            if k in r and not _type_ok(r[k], like):
                raise DeweyExit(f"config: rule {r.get('name', '?')!r}: {k} must be {_type_name(like)}, "
                                f"not {r[k]!r}", CONFIG)
    cats = cfg.get("categories", {})
    if not isinstance(cats, dict) or not all(isinstance(c, dict) for c in cats.values()):
        raise DeweyExit("config: categories must be [categories.KEY] tables", CONFIG)
    for key, c in cats.items():
        for k in ("path", "desc"):
            if k in c and not isinstance(c[k], str):
                raise DeweyExit(f"config: categories.{key}.{k} must be text, not {c[k]!r}", CONFIG)


def validate(cfg: dict) -> None:
    cats = cfg.get("categories") or {}
    if cfg["decider"]["backend"] != "none" and len(cats) < 2:
        raise DeweyExit("config: [categories] needs at least 2 entries for the decider", CONFIG)
    if len(cats) > 255:
        raise DeweyExit("config: decision models cap a choice at 255 options; split into two stages", CONFIG)
    for key, c in cats.items():
        if "path" not in c or "desc" not in c:
            raise DeweyExit(f"config: categories.{key} needs both path and desc", CONFIG)
    for r in cfg.get("rules", []):
        if "name" not in r or "target" not in r:
            raise DeweyExit(f"config: every [[rules]] entry needs name and target: {r}", CONFIG)
    p = cfg["plan"]
    if not (0 <= p["review_confidence"] <= p["auto_confidence"] <= 1):
        raise DeweyExit("config: need 0 <= review_confidence <= auto_confidence <= 1", CONFIG)
    if p["keep_duplicate"] not in ("oldest", "newest", "shortest_path"):
        raise DeweyExit("config: plan.keep_duplicate must be oldest | newest | shortest_path", CONFIG)
    if "" in cats:
        raise DeweyExit("config: a category needs a name (categories has an empty key)", CONFIG)
    if cfg["decider"]["backend"] not in ("systemone", "chat", "none"):
        raise DeweyExit("config: decider.backend must be systemone | chat | none", CONFIG)
    if cfg["scan"]["hash"] not in ("sha256", "blake3"):
        raise DeweyExit("config: scan.hash must be sha256 | blake3", CONFIG)
    for sec, k, low in (("scan", "workers", 1), ("decider", "workers", 1), ("scan", "snippet_chars", 0),
                        ("plan", "max_depth", -1)):
        if cfg[sec][k] < low:
            raise DeweyExit(f"config: {sec}.{k} must be {low} or more", CONFIG)
    if cfg["decider"]["timeout"] <= 0:
        raise DeweyExit("config: decider.timeout must be more than 0 seconds", CONFIG)


# --- writing TOML -----------------------------------------------------------------------------

_BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")
_ESCAPES = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r"}


def _toml_str(s: str) -> str:
    """A TOML basic string. Not json.dumps: JSON leaves DEL (0x7f) raw and writes emoji as surrogate
    pairs (\\ud83d\\ude00), and TOML allows neither."""
    out = []
    for ch in s:
        o = ord(ch)
        if ch in _ESCAPES:
            out.append(_ESCAPES[ch])
        elif o < 0x20 or o == 0x7F:
            out.append(f"\\u{o:04X}")
        elif 0xD800 <= o <= 0xDFFF:
            raise ValueError(f"not valid text (a lone surrogate): {s!r}")
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def _toml_key(k) -> str:
    if not isinstance(k, str):
        raise TypeError(f"TOML keys are text, not {k!r}")
    return k if _BARE_KEY.fullmatch(k) else _toml_str(k)


def _toml_value(v) -> str:
    if isinstance(v, bool):  # before int: True is an int too
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if math.isnan(v):
            return "nan"
        if math.isinf(v):
            return "inf" if v > 0 else "-inf"
        return repr(v)  # always has a "." or an exponent: 1.0, 1e-05
    if isinstance(v, str):
        return _toml_str(v)
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(_toml_value(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{_toml_key(k)} = {_toml_value(x)}" for k, x in v.items()) + "}"
    raise TypeError(f"TOML can't hold {v!r}")  # None included: TOML has no null


def _table_list(v) -> bool:
    return isinstance(v, list) and len(v) > 0 and all(isinstance(x, dict) for x in v)


def dumps(doc: dict) -> str:
    """TOML text for `doc`: plain values first, then [tables], then [[lists of tables]]."""
    lines: list[str] = []
    _dump_table(lines, (), doc, "table")
    return "\n".join(lines).strip("\n") + "\n" if lines else ""


def _dump_table(lines: list, path: tuple, table: dict, kind: str) -> None:
    plain = [(k, v) for k, v in table.items() if not isinstance(v, dict) and not _table_list(v)]
    tables = [(k, v) for k, v in table.items() if isinstance(v, dict)]
    lists = [(k, v) for k, v in table.items() if _table_list(v)]
    name = ".".join(_toml_key(k) for k in path)
    if kind == "list":
        lines += ["", f"[[{name}]]"]
    elif path and (plain or not (tables or lists)):  # a table holding only tables needs no header
        lines += ["", f"[{name}]"]
    lines += [f"{_toml_key(k)} = {_toml_value(v)}" for k, v in plain]
    for k, v in tables:
        _dump_table(lines, path + (k,), v, "table")
    for k, v in lists:
        for item in v:
            _dump_table(lines, path + (k,), item, "list")


# --- settings for the Mac app -----------------------------------------------------------------

SETTINGS_HEADER = """\
# dewey settings for this folder, saved by the Dewey app.
# Only settings that differ from dewey's built-in defaults are here; everything else uses the
# default, so improvements to the defaults still reach this folder. The app rewrites this file when
# it saves (comments added here aren't kept); the previous version is kept as dewey.toml.bak.
# `dewey init --force ROOT` replaces it with the full default file, every setting explained.
"""


def settings_path(state_dir: Path, explicit: str | None = None) -> Path:
    """The file the app's settings are saved to: the folder's own dewey.toml."""
    return Path(explicit).expanduser() if explicit else state_dir / "dewey.toml"


def to_app(cfg: dict) -> dict:
    """The settings as the app edits them: categories and folder kinds are ordered lists (JSON
    objects lose their order in Swift, and the decider reads the categories in order)."""
    out = {k: copy.deepcopy(v) for k, v in cfg.items() if k not in ("folders", "categories")}
    f = cfg.get("folders", {})
    out["folders"] = {"move": f.get("move", True),
                      "kinds": [{"kind": k, "path": v, "label": FOLDER_LABELS.get(k, k)}
                                for k, v in f.items() if k != "move" and isinstance(v, str)]}
    out["categories"] = [{"key": k, "path": c.get("path", ""), "desc": c.get("desc", "")}
                         for k, c in cfg.get("categories", {}).items()]
    return out


def from_app(data) -> dict:
    """The app's settings (any subset of the sections `to_app` gives) as config, ready to merge."""
    def bad(msg):
        return DeweyExit(f"settings: {msg}", CONFIG)

    if not isinstance(data, dict):
        raise bad("expected a JSON object")
    out: dict = {}
    for sec, v in data.items():
        if sec in ("scan", "plan", "decider"):
            if not isinstance(v, dict):
                raise bad(f"{sec} must be an object")
            out[sec] = {}
            for k, x in v.items():
                if k not in DEFAULTS[sec]:
                    raise bad(f"unknown setting {sec}.{k}")
                if isinstance(DEFAULTS[sec][k], float) and isinstance(x, int) and not isinstance(x, bool):
                    x = float(x)  # 1 from JSON: write 1.0
                out[sec][k] = x
        elif sec == "folders":
            if not isinstance(v, dict):
                raise bad("folders must be an object")
            f = {}
            for k, x in v.items():
                if k == "move":
                    f["move"] = x
                elif k == "kinds":
                    for item in x if isinstance(x, list) else [None]:
                        if not isinstance(item, dict) or item.get("kind") not in DEFAULTS["folders"]:
                            raise bad(f"unknown folder kind {item!r}")
                        f[item["kind"]] = item.get("path", "")
                else:
                    raise bad(f"unknown setting folders.{k}")
            out["folders"] = f
        elif sec == "rules":
            if not isinstance(v, list) or not all(isinstance(r, dict) for r in v):
                raise bad("rules must be a list of objects")
            for r in v:
                extra = set(r) - set(RULE_TYPES)
                if extra:
                    raise bad(f"unknown rule setting {', '.join(sorted(extra))}")
            # in the order a person would write them (the app sends keys sorted)
            out["rules"] = [{k: r[k] for k in RULE_TYPES if r.get(k) is not None} for r in v]
        elif sec == "categories":
            if not isinstance(v, list) or not all(isinstance(c, dict) for c in v):
                raise bad("categories must be a list of {key, path, desc}")
            cats: dict = {}
            for c in v:
                key = c.get("key")
                if not isinstance(key, str) or not key.strip():
                    raise bad("every folder for the decider needs a name")
                if key in cats:
                    raise bad(f"two folders for the decider are called {key!r}")
                cats[key] = {"path": c.get("path", ""), "desc": c.get("desc", "")}
            out["categories"] = cats
        else:
            raise bad(f"unknown section {sec}")
    return out


def changed_settings(cfg: dict) -> dict:
    """Only what differs from the defaults (category order counts: the decider reads them in order)."""
    def same(a, b):  # == but 1 isn't 1.0 or True
        if isinstance(a, dict) and isinstance(b, dict):
            return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
        if isinstance(a, list) and isinstance(b, list):
            return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
        return type(a) is type(b) and a == b

    out = {}
    for sec, v in cfg.items():
        d = DEFAULTS.get(sec)
        if sec == "categories":
            if not (isinstance(v, dict) and list(v) == list(d) and same(v, d)):
                out[sec] = v
        elif sec not in REPLACE_WHOLESALE and isinstance(v, dict) and isinstance(d, dict):
            diff = {k: x for k, x in v.items() if k not in d or not same(x, d[k])}
            if diff:
                out[sec] = diff
        elif not same(v, d):
            out[sec] = v
    return out


def _current(state_dir: Path, explicit: str | None) -> tuple[Path, Path | None, bytes | None]:
    """(where settings are saved, the file they're read from now, its bytes)."""
    target = settings_path(state_dir, explicit)
    source = target if target.is_file() else (None if explicit else find_config(state_dir, None))
    return target, source, source.read_bytes() if source else None


def _checked(text: str, path: Path) -> dict:
    from .rules import compile_rules  # a bad regex is a config error too

    cfg = _merge(DEFAULTS, _parse(text, path))
    check_types(cfg)
    validate(cfg)
    compile_rules(cfg)
    return cfg


def _sha(path: Path) -> str | None:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def read_settings(state_dir: Path, explicit: str | None = None) -> dict:
    """The folder's settings, merged with the defaults. A file dewey can't use comes back with
    valid=false, the error and its text, so the app can show it instead of failing."""
    target, source, data = _current(state_dir, explicit)
    out = {"path": str(target), "exists": target.is_file(), "source": str(source) if source else None,
           "sha256": _sha(target), "valid": True, "error": None, "raw": None,
           "config": to_app(DEFAULTS), "defaults": to_app(DEFAULTS)}
    if source is not None:
        raw = data.decode("utf-8", errors="replace")
        try:
            out["config"] = to_app(_checked(raw, source))
        except DeweyExit as e:
            out.update(valid=False, error=str(e.code), raw=raw, config=None)
    return out


def write_settings(state_dir: Path, explicit: str | None, data, *, reset: bool = False,
                   expect_sha: str | None = None) -> dict:
    """Save the app's settings (any subset of sections) over the current ones, or over the defaults
    with reset. Checked like a file dewey reads, written atomically, the old file kept as .bak."""
    target, source, current = _current(state_dir, explicit)
    if target.is_symlink():  # a dotfiles link: write where it points, keep the link
        target = target.resolve()
    if expect_sha is not None and (_sha(target) or "none") != expect_sha:
        raise DeweyExit(f"{target} changed since the settings were read; showing the new version", STALE)
    base = DEFAULTS
    if not reset and source is not None:
        try:
            base = _checked(current.decode("utf-8", errors="replace"), source)
        except DeweyExit as e:
            raise DeweyExit(f"{e.code}\nFix the file, or start over from the defaults "
                            "(the old file is kept as dewey.toml.bak).", CONFIG) from None
    cfg = _merge(base, from_app(data))
    check_types(cfg)
    validate(cfg)
    from .rules import compile_rules
    compile_rules(cfg)
    try:
        body = dumps(changed_settings(cfg))
    except (TypeError, ValueError) as e:
        raise DeweyExit(f"settings: {e}", CONFIG) from None
    text = SETTINGS_HEADER + ("\n" + body if body else "")
    if to_app(_checked(text, target)) != to_app(cfg):  # the writer must give back exactly what it was given
        raise RuntimeError("the TOML writer didn't round-trip these settings; nothing was written")

    target.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    if target.exists():
        backup = target.with_name(target.name + ".bak")
        shutil.copy2(target, backup)
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, target)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return {**read_settings(state_dir, explicit), "backup": str(backup) if backup else None,
            "changed": list(changed_settings(cfg))}
