"""Cheap content signals for the decider: a short text preview and photo EXIF.

Everything here is best-effort and stdlib-first. Optional extras improve it:
  pypdf        -> PDF text      (pip install pypdf)
  Pillow       -> EXIF date/camera for JPEG/PNG/TIFF
  pillow-heif  -> EXIF for HEIC

These files come from anywhere (a Downloads folder), so every reader takes a bounded bite: the
first 16 KB of text, 200 KB of each Office part, two pages of a PDF no bigger than PDF_MAX_BYTES.
pypdf is the one parser here that has had hangs and memory blow-ups on crafted files; pyproject.toml
asks for a version with those fixed and with its own limits on what a stream may unpack to.
"""
from __future__ import annotations

import html
import logging
import os
import re
import zipfile
from datetime import datetime

TEXT_EXTS = {
    ".txt", ".md", ".markdown", ".rst", ".csv", ".tsv", ".json", ".jsonl", ".xml", ".yaml", ".yml",
    ".toml", ".ini", ".cfg", ".conf", ".log", ".py", ".js", ".ts", ".tsx", ".jsx", ".sh", ".zsh",
    ".bash", ".ps1", ".sql", ".html", ".htm", ".css", ".swift", ".go", ".rs", ".java", ".c", ".h",
    ".cpp", ".hpp", ".rb", ".php", ".r", ".ipynb", ".tex", ".srt", ".vtt", ".eml", ".ics", ".vcf",
    ".rtf", ".svg", ".gpx", ".kml", ".properties",
}  # not .env: it holds passwords and keys, and the preview is stored and sent to the decider
OOXML = {".docx": ["word/document.xml"],
         ".pptx": None,  # slides discovered dynamically
         ".xlsx": ["xl/sharedStrings.xml"]}
EXIF_EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".heic", ".heif", ".webp"}
PDF_MAX_BYTES = 64 * 1024 * 1024  # pypdf reads the whole file into memory, in every scan worker at once

_ws = re.compile(r"\s+")
_tags = re.compile(r"<[^>]+>")
_rtf = re.compile(r"\\[a-zA-Z]+-?\d* ?|[{}]")

try:  # optional
    import pypdf  # type: ignore
    logging.getLogger("pypdf").setLevel(logging.ERROR)
except Exception:  # pragma: no cover
    pypdf = None

try:  # optional
    from PIL import Image  # type: ignore
    try:
        import pillow_heif  # type: ignore
        pillow_heif.register_heif_opener()
    except Exception:
        pass
except Exception:  # pragma: no cover
    Image = None


def capabilities() -> dict[str, bool]:
    try:
        import blake3  # noqa: F401
        b3 = True
    except Exception:
        b3 = False
    try:
        import pillow_heif  # noqa: F401
        heif = True
    except Exception:
        heif = False
    return {"pypdf (PDF text)": pypdf is not None, "Pillow (EXIF)": Image is not None,
            "pillow-heif (HEIC EXIF)": heif, "blake3 (fast hash)": b3}


def _clean(s: str, limit: int) -> str:
    return _ws.sub(" ", s).strip()[:limit]


def _read_text(path: str, ext: str, limit: int) -> str | None:
    with open(path, "rb") as fh:
        raw = fh.read(16384)
    if b"\x00" in raw[:4096]:
        return None
    text = raw.decode("utf-8", errors="replace")
    if ext == ".rtf":
        text = _rtf.sub(" ", text)
    elif ext in (".html", ".htm", ".xml", ".svg"):
        text = html.unescape(_tags.sub(" ", text))
    return _clean(text, limit) or None


def _read_ooxml(path: str, ext: str, limit: int) -> str | None:
    with zipfile.ZipFile(path) as z:
        names = OOXML[ext]
        if names is None:  # pptx
            names = sorted((n for n in z.namelist() if re.match(r"ppt/slides/slide\d+\.xml$", n)),
                           key=lambda n: int(re.findall(r"\d+", n)[-1]))[:3]
        chunks = []
        for n in names:
            try:
                with z.open(n) as fh:
                    chunks.append(fh.read(200_000).decode("utf-8", errors="replace"))
            except KeyError:
                continue
    text = html.unescape(_tags.sub(" ", " ".join(chunks)))
    return _clean(text, limit) or None


def _read_pdf(path: str, limit: int) -> str | None:
    if pypdf is None:
        return None
    if os.path.getsize(path) > PDF_MAX_BYTES:
        return "(large PDF; not opened for a preview)"
    reader = pypdf.PdfReader(path)
    if reader.is_encrypted:
        try:
            reader.decrypt("")
        except Exception:
            return "(encrypted PDF)"
    parts = []
    meta = reader.metadata
    if meta and meta.title:
        parts.append(f"Title: {meta.title}.")
    for page in reader.pages[:2]:
        parts.append(page.extract_text() or "")
        if sum(len(p) for p in parts) > limit:
            break
    text = _clean(" ".join(parts), limit)
    return text or "(PDF with no text layer; probably a scan)"


def snippet(path: str, ext: str, limit: int) -> str | None:
    try:
        if ext in TEXT_EXTS:
            return _read_text(path, ext, limit)
        if ext in OOXML:
            return _read_ooxml(path, ext, limit)
        if ext == ".pdf":
            return _read_pdf(path, limit)
    except Exception:
        return None
    return None


def photo_info(path: str, ext: str) -> tuple[str | None, str | None]:
    """(iso_date, camera) from EXIF, or (None, None)."""
    if Image is None or ext not in EXIF_EXTS:
        return None, None
    try:
        with Image.open(path) as img:
            exif = img.getexif()
            if not exif:
                return None, None
            make = str(exif.get(271) or "").strip()
            model = str(exif.get(272) or "").strip()
            sub = exif.get_ifd(0x8769)
            raw = sub.get(36867) or exif.get(306)
    except Exception:
        return None, None
    if make and model and not model.lower().startswith(make.lower()):
        camera = f"{make} {model}"
    else:
        camera = model or make or None
    date = None
    if raw:
        try:
            date = datetime.strptime(str(raw).strip()[:19], "%Y:%m:%d %H:%M:%S").date().isoformat()
        except ValueError:
            date = None
    return date, camera
