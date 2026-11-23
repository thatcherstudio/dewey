"""DeweyExit: a SystemExit with a readable message (as before) plus a machine-readable kind.

Text mode prints the message exactly as a plain SystemExit would. In `--json` mode the kind goes
into the error event's `code`, so the Mac app can react to "nothing to undo" without parsing text.
"""
from __future__ import annotations

# The kinds the app may react to. Anything raised without one is "error".
NOT_A_FOLDER = "not_a_folder"
UNSAFE_ROOT = "unsafe_root"
UNSAFE_DEST = "unsafe_dest"
NO_CATALOG = "no_catalog"
NO_PLAN = "no_plan"
NOTHING_TO_UNDO = "nothing_to_undo"
CONFIG = "config"
DECIDER = "decider"
REMOTE_DECIDER = "remote_decider"  # the folder's own settings name a server elsewhere; not allowed yet
BAD_EDIT = "bad_edit"
STALE = "stale"
NO_ACCESS = "no_access"  # the system turned dewey away from a file or folder (privacy settings, permissions)


class DeweyExit(SystemExit):
    def __init__(self, message: str, kind: str = "error"):
        super().__init__(message)
        self.kind = kind
