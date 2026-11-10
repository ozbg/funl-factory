"""super-collect's findings doc (collect_handoff.py).

doc    — one findings doc, verified findings grouped, drops listed; dry-run writes nothing

Offline: a temp project.

    python3 tests/test_collect_handoff.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

KIT = Path(__file__).resolve().parents[1]
CLI = KIT / "skills/super-collect/scripts/collect_handoff.py"
SKILL = KIT / "skills/super-collect/SKILL.md"

FINDINGS = [
    {"title": "Checkout 500 on empty cart", "type": "bug", "source": "sentry", "group": "checkout",
     "fingerprint": "err|sentry|4411", "verdict": "file", "evidence": ["https://sentry.example/4411"],
     "note": "seen 42 times since 2026-10-01"},
    {"title": "Dead clicks on pricing", "type": "bug", "source": "posthog", "group": "pricing page",
     "fingerprint": "posthog|dead_click|1a2b", "verdict": "needs-triage", "evidence": ["replay 9f"], "note": ""},
    {"title": "Cart total rounds wrong", "type": "bug", "source": "prs", "group": "checkout",
     "fingerprint": "prs|cart|rounding", "verdict": "file", "evidence": ["PR #12", "PR #19"], "note": ""},
    {"title": "Old 404 on /legacy", "type": "bug", "source": "sentry",
     "fingerprint": "err|sentry|4490", "verdict": "drop-fixed", "evidence": ["PR #377"], "note": "resolved in web@1.4.0"},
    {"title": "Upload fails", "type": "bug", "source": "sentry",
     "fingerprint": "err|sentry|4502", "verdict": "duplicate", "evidence": ["#301"], "note": "card #301"},
]


class Handoff(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "project"
        self.root.mkdir()
        self.findings = Path(tmp.name) / "verified.json"
        self.findings.write_text(json.dumps(FINDINGS))

    def run_cli(self, *args, expected=0):
        p = subprocess.run([sys.executable, str(CLI), *args], cwd=self.root, text=True, capture_output=True)
        self.assertEqual(p.returncode, expected, p.stderr)
        return p

    # doc -----------------------------------------------------------------
    def test_doc_groups_verified_findings_and_lists_drops(self):
        p = self.run_cli("doc", "--findings", str(self.findings), "--since", "14d", "--date", "2026-10-27", "--yes")
        path = self.root / "docs/super-board/findings/collect-2026-10-27.md"
        self.assertEqual(p.stdout.strip(), "docs/super-board/findings/collect-2026-10-27.md")
        text = path.read_text()
        self.assertTrue(text.startswith("# Findings · 2026-10-27"))
        self.assertIn("## checkout", text)
        self.assertIn("## pricing page", text)
        self.assertLess(text.index("Checkout 500 on empty cart"), text.index("## pricing page"))
        self.assertIn("Cart total rounds wrong", text)
        self.assertIn("needs-triage", text)
        self.assertIn("err|sentry|4411", text)
        dropped = text[text.index("## Not in this doc"):]
        self.assertIn("Old 404 on /legacy", dropped)
        self.assertIn("drop-fixed", dropped)
        self.assertIn("duplicate", dropped)
        self.assertIn("filed straight into Backlog", text)

    def test_doc_dry_run_prints_and_writes_nothing(self):
        p = self.run_cli("doc", "--findings", str(self.findings), "--date", "2026-10-27")
        self.assertIn("## checkout", p.stdout)
        self.assertIn("would write docs/super-board/findings/collect-2026-10-27.md", p.stderr)
        self.assertFalse((self.root / "docs").exists())

    def test_doc_never_overwrites_an_earlier_run(self):
        self.run_cli("doc", "--findings", str(self.findings), "--date", "2026-10-27", "--yes")
        p = self.run_cli("doc", "--findings", str(self.findings), "--date", "2026-10-27", "--yes")
        self.assertEqual(p.stdout.strip(), "docs/super-board/findings/collect-2026-10-27-2.md")

    def test_doc_with_nothing_verified_is_refused(self):
        self.findings.write_text(json.dumps([f for f in FINDINGS if f["verdict"].startswith("drop")]))
        p = self.run_cli("doc", "--findings", str(self.findings), "--yes", expected=3)
        self.assertIn("nothing to hand off", p.stderr)

    # SKILL.md files straight into Backlog ----------------------------------
    def test_skill_files_straight_into_backlog(self):
        text = SKILL.read_text()
        for needle in ("collect_handoff.py", "docs/super-board/findings/collect-<YYYY-MM-DD>.md",
                       "super-collect-file.sh", "ticket-format.md"):
            self.assertIn(needle, text)
        for gone in ("/to-spec", "/to-tickets", "/implement-spec"):
            self.assertNotIn(gone, text)


if __name__ == "__main__":
    unittest.main()
