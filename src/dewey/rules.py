"""Tier 1: deterministic rules from config. Cheap, explainable, and they keep the
decision model's queue short (it only sees files no rule could place)."""
from __future__ import annotations

import re
import string
from dataclasses import dataclass
from datetime import datetime

from .errors import CONFIG, DeweyExit

PLACEHOLDERS = ("review", "year", "month", "camera")  # what `fill` puts into a rule's target and reason


def template_problem(text: str) -> str | None:
    """Why a rule's target or reason can't be filled in, or None when it can.

    Checked when the config loads: `Zips/{year` used to pass, then stop the plan half way with an
    internal error, and `{yaer}` quietly became nothing, filing into the wrong folder."""
    hint = "the placeholders are {review} {year} {month} {camera}; write {{ and }} for a real brace"
    try:
        fields = [(name, spec) for _, name, spec, _ in string.Formatter().parse(text) if name is not None]
    except ValueError as e:  # a brace that is never closed, a lone }
        return f"{e} ({hint})"
    for name, spec in fields:
        if name not in PLACEHOLDERS or "{" in (spec or ""):
            return f"{{{name}{':' + spec if spec else ''}}} isn't something dewey fills in ({hint})"
    try:
        text.format_map(dict.fromkeys(PLACEHOLDERS, "2025"))
    except (ValueError, LookupError, AttributeError, TypeError) as e:  # {year:d}, {year!x}
        return f"{e} ({hint})"
    return None


@dataclass
class Rule:
    name: str
    target: str
    reason: str
    ext: frozenset | None
    name_re: re.Pattern | None
    path_re: re.Pattern | None
    min_size: int | None
    max_size: int | None
    has_camera: bool | None

    def matches(self, f) -> bool:
        if self.ext is not None and f["ext"] not in self.ext:
            return False
        if self.name_re is not None and not self.name_re.search(f["name"]):
            return False
        if self.path_re is not None and not self.path_re.search(f["rel_path"]):
            return False
        if self.min_size is not None and (f["size"] or 0) < self.min_size:
            return False
        if self.max_size is not None and (f["size"] or 0) > self.max_size:
            return False
        if self.has_camera is not None and bool(f["camera"]) != self.has_camera:
            return False
        return True


def compile_rules(cfg: dict) -> list[Rule]:
    out = []
    for r in cfg.get("rules", []):
        for key in ("target", "reason"):
            why = template_problem(r[key]) if key in r else None
            if why:
                raise DeweyExit(f"config: rule {r.get('name')!r}: {key} {r[key]!r} can't be filled in: {why}", CONFIG)
        try:
            out.append(Rule(
                name=r["name"], target=r["target"], reason=r.get("reason", r["name"]),
                ext=frozenset(e.lower() if e.startswith(".") else "." + e.lower() for e in r["ext"]) if "ext" in r else None,
                name_re=re.compile(r["name_regex"]) if "name_regex" in r else None,
                path_re=re.compile(r["path_regex"]) if "path_regex" in r else None,
                min_size=r.get("min_size"), max_size=r.get("max_size"),
                has_camera=r.get("has_camera"),
            ))
        except re.error as e:
            raise DeweyExit(f"config: bad regex in rule {r.get('name')}: {e}", CONFIG)
    return out


_NAME_DATE = re.compile(r"(?<!\d)((?:19|20)\d{2})[-_.](0[1-9]|1[0-2])[-_.](0[1-9]|[12]\d|3[01])(?!\d)")


def file_date(f) -> datetime:
    """Best guess at when the thing happened: EXIF, then a date in the name, then mtime.
    (Copies and downloads reset mtime, so 'Screenshot 2025-03-04 …' should say 2025.)"""
    if f["photo_date"]:
        try:
            return datetime.fromisoformat(f["photo_date"])
        except ValueError:
            pass
    m = _NAME_DATE.search(f["name"])
    if m:
        try:
            return datetime(int(m[1]), int(m[2]), int(m[3]))
        except ValueError:
            pass
    return datetime.fromtimestamp((f["mtime_ns"] or 0) / 1e9)


def fill(template: str, f, review_dir: str) -> str:
    d = file_date(f)
    return template.format_map(dict(review=review_dir, year=f"{d.year:04d}", month=f"{d.month:02d}",
                                    camera=f["camera"] or "")).strip("/")


def first_match(rules: list[Rule], f) -> Rule | None:
    for r in rules:
        if r.matches(f):
            return r
    return None
