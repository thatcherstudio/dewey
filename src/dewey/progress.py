"""Throttled progress line with count, rate, throughput and ETA.

TTY: redraws one line in place (~4x/sec).  Non-TTY (piped/logged): prints a
fresh line every few seconds so long runs are never silent in a log either.
"""
from __future__ import annotations

import shutil
import sys
import time


def human_bytes(n: float) -> str:
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def human_duration(s: float | None) -> str:
    if s is None or s != s or s in (float("inf"), float("-inf")) or s < 0:
        return "--:--"
    s = int(s)
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


class Progress:
    def __init__(self, label: str, total: int | None = None, unit: str = "files",
                 total_bytes: int | None = None, stream=None, interval: float | None = None):
        self.label = label
        self.total = total
        self.unit = unit
        self.total_bytes = total_bytes
        self.stream = stream or sys.stderr
        self.tty = hasattr(self.stream, "isatty") and self.stream.isatty()
        self.interval = interval if interval is not None else (0.25 if self.tty else 5.0)
        self.n = 0
        self.bytes = 0
        self.extra = ""
        self.start = time.monotonic()
        self._last = 0.0
        self._drawn = False

    def update(self, n: int = 1, nbytes: int = 0, extra: str | None = None) -> None:
        self.n += n
        self.bytes += nbytes
        if extra is not None:
            self.extra = extra
        now = time.monotonic()
        if now - self._last >= self.interval:
            self._last = now
            self._render(now)

    def _line(self, now: float, final: bool) -> str:
        el = max(now - self.start, 1e-9)
        rate = self.n / el
        parts = [f"{self.label}:"]
        if self.total:
            pct = 100.0 * self.n / self.total
            parts.append(f"{self.n:,}/{self.total:,} {self.unit} ({pct:5.1f}%)")
        else:
            parts.append(f"{self.n:,} {self.unit}")
        parts.append(f"{rate:,.1f} {self.unit}/s")
        if self.bytes:
            parts.append(f"{human_bytes(self.bytes / el)}/s")
        parts.append(f"elapsed {human_duration(el)}")
        if not final and el >= 1.5:  # early rates are dominated by startup; don't print a silly ETA
            eta = None
            if self.total_bytes and self.bytes:
                eta = (self.total_bytes - self.bytes) / (self.bytes / el)
            elif self.total and self.n:
                eta = (self.total - self.n) / rate
            if eta is not None:
                parts.append(f"ETA {human_duration(eta)}")
        if self.extra:
            parts.append(self.extra)
        return "  ".join(parts)

    def _render(self, now: float, final: bool = False) -> None:
        line = self._line(now, final)
        if self.tty:
            width = shutil.get_terminal_size((120, 20)).columns - 1
            self.stream.write("\r\x1b[K" + line[:width])
        else:
            self.stream.write(line + "\n")
        self.stream.flush()
        self._drawn = True

    def done(self, message: str | None = None) -> None:
        self._render(time.monotonic(), final=True)
        if self.tty:
            self.stream.write("\n")
        if message:
            self.stream.write(message + "\n")
        self.stream.flush()


def say(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()
