"""Offline tests for scripts/super-board-zone.py (v2 zone resolver)."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "super-board-zone.py"
ZONES = ROOT / "tests" / "fixtures" / "zones" / "zones.yaml"  # copy of a real app zone map


def run(zones, *files, stdin=None):
    args = [sys.executable, str(SCRIPT), "--zones", str(zones)]
    args += ["--files-from", "-"] if stdin is not None else ["--files", *files]
    return subprocess.run(args, capture_output=True, text=True, input=stdin)


def resolve(*files, zones=ZONES):
    r = run(zones, *files)
    if r.returncode:
        raise AssertionError(r.stderr)
    return json.loads(r.stdout)


class Zone(unittest.TestCase):
    def test_highest_zone_wins(self):
        out = resolve("core/src/vault-write.ts", "web/src/components/X.tsx")
        self.assertEqual(out["tier"], "red")
        self.assertEqual(out["max_rounds"], 3)
        self.assertEqual(out["per_file"], {"core/src/vault-write.ts": "red", "web/src/components/X.tsx": "green"})
        self.assertIn("security-pass", out["checks"])
        self.assertEqual(out["invariants"][0]["id"], "I1")
        self.assertEqual(len(out["invariants"]), 11)
        self.assertEqual(out["owner_gate"], ["destructive-schema", "live-database"])
        self.assertTrue(out["bar"].startswith("The hard core."))
        self.assertIn("Two edits to the same note within the same second", out["accepted_limits"])

    def test_red_file_inside_amber_glob(self):
        out = resolve("core/src/agent-tools/guardrails.ts")
        self.assertEqual(out["tier"], "red")
        self.assertEqual(resolve("core/src/agent-tools/other.ts")["tier"], "amber")

    def test_green_only(self):
        out = resolve("web/src/components/X.tsx", "docs/a/b/c.md")
        self.assertEqual((out["tier"], out["max_rounds"], out["invariants"]), ("green", 1, []))
        self.assertEqual(out["bar"], "Looks right, works on the happy path, no console errors.")

    def test_unlisted_is_amber(self):
        out = resolve("web/src/components/X.tsx", "somewhere/new.ts")
        self.assertEqual(out["tier"], "amber")
        self.assertEqual(out["per_file"]["somewhere/new.ts"], "amber")
        self.assertEqual(out["max_rounds"], 2)

    def test_double_star_crosses_directories(self):
        self.assertEqual(resolve("core/drizzle/a/b/0001.sql")["tier"], "red")
        self.assertEqual(resolve("web/src/app/page.tsx")["tier"], "green")
        self.assertEqual(resolve("web/src/app/x/y/page.tsx")["tier"], "green")
        # single * stays inside one directory
        self.assertEqual(resolve("web/src/lib/palette-x/y.ts")["tier"], "amber")

    def test_files_from_stdin(self):
        r = run(ZONES, stdin="./core/src/git.ts\n\nweb/src/components/A.tsx\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["per_file"]["core/src/git.ts"], "red")

    def test_no_zones_file(self):
        out = resolve("core/src/vault-write.ts", zones=ZONES.parent / "missing.yaml")
        self.assertEqual((out["tier"], out["max_rounds"], out["zones_file"]), ("amber", 2, False))

    def test_boundary(self):
        tmp = Path(tempfile.mkdtemp()) / "zones.yaml"
        tmp.write_text(ZONES.read_text() + "\nboundary: [web/src/app/api/**, mcp/**]\n")
        self.assertTrue(resolve("mcp/src/server.ts", zones=tmp)["boundary"])
        self.assertFalse(resolve("core/src/crm.ts", zones=tmp)["boundary"])
        self.assertFalse(resolve("mcp/src/server.ts")["boundary"])  # no boundary key

    def test_parse_error(self):
        tmp = Path(tempfile.mkdtemp()) / "zones.yaml"
        tmp.write_text("zones:\n  red:\n    paths: [a, b\n")
        r = run(tmp, "a")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)
        tmp.write_text("zones:\n  red:\n    this is not yaml\n")
        self.assertEqual(run(tmp, "a").returncode, 2)


if __name__ == "__main__":
    unittest.main()
