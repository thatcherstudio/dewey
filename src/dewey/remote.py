"""Whether a decision model on another machine may be used for a folder.

A folder's own dewey.toml can arrive with the folder (a zip, a shared drive). If it names a server
that isn't this Mac, every file name and text preview, and DEWEY_API_KEY with them, would go to
whoever wrote that file. So a url that only the folder's own settings name is used after the person
says yes (`--allow-remote`, or the app's question), once per folder and server. The yes is kept
outside the folder, in ~/.config/dewey/remote.json, where a folder can't write it for them.

A url typed on the command line (`--url`), or set in a config file that isn't in the folder, is the
person's own and needs no asking.
"""
from __future__ import annotations

import json
import os
import urllib.parse
from pathlib import Path


def store_path() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "dewey" / "remote.json"


def origin(url: str) -> str:
    """scheme://host:port, the part of a url that says who gets the request."""
    u = urllib.parse.urlsplit(str(url))
    try:
        port = u.port
    except ValueError:
        port = None
    return f"{u.scheme.lower()}://{(u.hostname or '').lower()}" + (f":{port}" if port else "")


def arrives_with(root: Path, cfg_path: Path) -> bool:
    """The config file is inside the folder, so it came (or could have come) with it."""
    folder, cfg = os.path.realpath(root), os.path.realpath(cfg_path)
    return cfg.startswith(folder.rstrip("/") + "/")


def _read() -> dict:
    try:
        data = json.loads(store_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def allowed(root: Path, url: str) -> bool:
    servers = _read().get(os.path.realpath(root))
    return isinstance(servers, list) and origin(url) in servers


def allow(root: Path, url: str) -> None:
    data, key = _read(), os.path.realpath(root)
    servers = [s for s in data.get(key, []) if isinstance(s, str)] if isinstance(data.get(key), list) else []
    if origin(url) not in servers:
        servers.append(origin(url))
    data[key] = servers
    path = store_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)
