"""What a release has to agree with itself about: one version number, and pinned packages that
cover everything pyproject.toml asks for.

    python -m unittest discover -s tests -v
"""
from __future__ import annotations

import re
import sys
import tomllib
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))
import dewey  # noqa: E402


def numbers(version: str) -> tuple[int, ...]:
    return tuple(int(n) for n in re.findall(r"\d+", version))


def key(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()  # Pillow, pillow_heif and pillow-heif as PyPI compares them


class Release(unittest.TestCase):
    def setUp(self):
        self.project = tomllib.loads((REPO / "pyproject.toml").read_text(encoding="utf-8"))["project"]

    def test_the_version_is_written_the_same_in_both_places(self):
        # pyproject.toml is what pip and the app's Info.plist get (scripts/build-app.sh reads it);
        # dewey/__init__.py is what `dewey --version` says and what the app shows as its dewey.
        self.assertEqual(self.project["version"], dewey.__version__,
                         "bump pyproject.toml and src/dewey/__init__.py together")

    def test_every_optional_package_is_pinned_with_checksums_at_a_version_that_fits(self):
        # constraints.txt (`make pins`) is what the app bundles and what CI installs.
        text = (REPO / "constraints.txt").read_text(encoding="utf-8")
        pins = {}
        for block in re.split(r"\n(?=\S)", text):  # a requirement and its indented --hash lines
            m = re.match(r"([A-Za-z0-9_.-]+)==([^\s;\\]+)", block)
            if m:
                self.assertIn("--hash=sha256:", block, f"{m[1]} has no checksum: run `make pins`")
                pins[key(m[1])] = m[2]
        wanted = [r for reqs in self.project["optional-dependencies"].values() for r in reqs]
        self.assertTrue(wanted)
        for req in wanted:
            m = re.fullmatch(r"([A-Za-z0-9_.-]+)>=([0-9.]+)", req)
            self.assertIsNotNone(m, f"{req!r}: this test reads only NAME>=VERSION")
            self.assertIn(key(m[1]), pins, f"{m[1]} isn't in constraints.txt: run `make pins`")
            self.assertGreaterEqual(numbers(pins[key(m[1])]), numbers(m[2]),
                                    f"constraints.txt pins {m[1]} below {req}: run `make pins`")


if __name__ == "__main__":
    unittest.main()
