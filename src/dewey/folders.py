"""Tell what kind of folder a whole folder is, from what's inside it.

Folders that stay whole (plan.max_depth) are never split. This only labels them and picks a
home for the folder as one piece; the planner turns that into a single review row.
Signals are file names and extensions from the catalog, nothing is opened.
"""
from __future__ import annotations

import os
import re
from collections import Counter

LABELS = {
    "code": "code project",
    "cad": "3D-print / CAD project",
    "design": "design files",
    "images": "image set",
    "photos": "photo set",
    "documents": "documents",
    "video": "videos",
    "audio": "audio",
    "mixed": "mixed (no clear kind)",
    "filing": "a dewey filing folder",
}

CODE_EXT = {".py", ".swift", ".js", ".mjs", ".ts", ".tsx", ".jsx", ".go", ".rs", ".c", ".h", ".cc", ".cpp",
            ".hpp", ".m", ".mm", ".java", ".kt", ".kts", ".rb", ".php", ".sh", ".zsh", ".bash", ".lua", ".pl",
            ".cs", ".scala", ".r", ".ipynb", ".sql", ".vue", ".svelte", ".html", ".htm", ".css", ".scss",
            ".toml", ".yml", ".yaml", ".gradle", ".tmpl", ".plist", ".xcconfig", ".entitlements", ".rules"}
CAD_SOURCE = {".scad", ".step", ".stp", ".f3d", ".f3z", ".skp", ".iges", ".igs", ".dxf", ".fcstd", ".blend"}
CAD_ANY = CAD_SOURCE | {".stl", ".3mf", ".obj", ".gcode", ".bgcode"}
DESIGN_SOURCE = {".fig", ".sketch", ".psd", ".ai", ".xd", ".afdesign", ".afphoto", ".indd", ".graffle"}
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".ico", ".icns", ".tif", ".tiff", ".bmp",
             ".heic", ".heif", ".avif"}
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".avi", ".mkv", ".mts", ".webm"}
AUDIO_EXT = {".mp3", ".m4a", ".wav", ".aiff", ".aif", ".flac", ".ogg", ".opus", ".aac"}
DOC_EXT = {".pdf", ".doc", ".docx", ".pages", ".txt", ".md", ".rtf", ".odt", ".xls", ".xlsx", ".numbers",
           ".ppt", ".pptx", ".key", ".csv", ".epub"}
BUILD_FILES = {"install.sh", "build.sh", "setup.sh", "makefile", "justfile", "package.swift", "dockerfile",
               "requirements.txt", "podfile", "cartfile", "claude.md", "agents.md"}
GITHUB_ZIP = re.compile(r"-(main|master|develop|trunk)$", re.I)


def classify(name: str, files: list, units: list, own_marker: str | None = None,
             git_files: list | None = None) -> tuple[str, str]:
    """-> (kind, why). files: catalog rows inside the folder; units: bundles/projects inside it.

    own_marker: the project marker when the folder itself is a project unit.
    git_files: .github / .gitignore found at the top of the folder (hidden, so not in `files`).
    """
    rel = lambda f: f["rel_path"].casefold()
    exts = Counter(f["ext"] for f in files)
    shown = {os.path.basename(f["rel_path"]).casefold(): os.path.basename(f["rel_path"]) for f in files}
    names = set(shown)
    n = max(1, len(files))
    share = lambda group: sum(c for e, c in exts.items() if e in group) / n
    has_readme = any(x.startswith("readme") for x in names)
    readme = ", README" if has_readme else ""
    top = lambda group: ", ".join(f"{c} {e}" for e, c in exts.most_common() if e in group)[:60]

    if own_marker:
        return "code", f"project marker {own_marker}"
    inner = [u for u in units if u["kind"] == "project"]
    xcode = [u for u in units if u["name"].lower().endswith((".xcodeproj", ".xcworkspace"))]
    if inner:
        return "code", f"project inside ({inner[0]['name']})"
    if xcode:
        return "code", f"Xcode project ({xcode[0]['name']}){readme}"
    if git_files or any("/.github/" in rel(f) or "/.gitignore" in rel(f) for f in files):
        return "code", f".github / .gitignore, {top(CODE_EXT) or 'source files'}"
    cad_src = [e for e in exts if e in CAD_SOURCE]
    if cad_src or (share(CAD_ANY) >= 0.25 and exts.keys() & CAD_ANY):
        return "cad", f"{top(CAD_ANY)}{readme}"
    if exts.keys() & DESIGN_SOURCE:
        return "design", f"design sources ({top(DESIGN_SOURCE)})"
    if share(CODE_EXT) >= 0.4 or (names & BUILD_FILES and has_readme):
        build = sorted(shown[b] for b in names & BUILD_FILES)
        return "code", f"{top(CODE_EXT) or 'source files'}{', ' + build[0] if build else ''}{readme}"
    if share(IMAGE_EXT) >= 0.6:
        if sum(1 for f in files if f["camera"]) >= 0.5 * n:
            return "photos", f"{sum(1 for f in files if f['camera'])} camera photos (EXIF)"
        if has_readme or exts.keys() & {".json", ".html", ".csv"}:
            return "design", f"{top(IMAGE_EXT)} with specs{readme}"
        return "images", top(IMAGE_EXT) + (", favicon set" if "favicon.ico" in names else "")
    if share(VIDEO_EXT) >= 0.5:
        return "video", top(VIDEO_EXT)
    if share(AUDIO_EXT) >= 0.5:
        return "audio", top(AUDIO_EXT)
    if GITHUB_ZIP.search(name):
        return "code", f"GitHub download (\"{GITHUB_ZIP.search(name).group(0)}\" name){readme}"
    if share(DOC_EXT) >= 0.6:
        return "documents", top(DOC_EXT)
    return "mixed", ", ".join(f"{c} {e or '(no ext)'}" for e, c in exts.most_common(4))
