"""super-collect's findings doc (collect_handoff.py).

doc    — one findings doc, verified findings grouped, drops listed; dry-run writes nothing
triage — track and fix-or-propose rules, the routing rule, the fix cap
digest — the open proposals, one recommendation each

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

    # triage ----------------------------------------------------------------
    FIX = {"title": "Stage header wrong", "verdict": "file", "track": "tweak", "decision": "fix",
           "breaks": "baseline #screen-pipeline", "screens": ["pipeline"], "touches": [], "zone": "green"}

    def triage(self, findings, *args, expected=0):
        self.findings.write_text(json.dumps(findings))
        p = self.run_cli("triage", "--findings", str(self.findings), *args, expected=expected)
        return json.loads(p.stdout) if expected == 0 else p

    def test_triage_fixes_only_what_meets_every_rule(self):
        cases = [
            (dict(self.FIX), "fix", "tweak"),
            (dict(self.FIX, verdict="needs-triage"), "propose", "tweak"),
            (dict(self.FIX, breaks=""), "propose", "tweak"),
            (dict(self.FIX, zone="red"), "propose", "tweak"),
            (dict(self.FIX, zone=None), "propose", "tweak"),
            (dict(self.FIX, track="bug", decision="propose", recommendation="Fix it next run."), "propose", "bug"),
        ]
        out = self.triage([c for c, _, _ in cases], "--max-fix", "9")
        for f, (_, decision, track) in zip(out, cases):
            self.assertEqual((f["decision"], f["track"]), (decision, track), f["why"])
        self.assertEqual(out[0]["column"], "Ready")
        self.assertEqual(out[0]["labels"], ["tweak"])
        self.assertEqual(out[1]["column"], "Backlog")
        self.assertEqual(out[1]["labels"], ["tweak", "proposal"])
        self.assertTrue(all(f["recommendation"] for f in out[1:]))

    def test_what_it_touches_picks_the_track_not_its_label(self):
        out = self.triage([dict(self.FIX, track="bug", touches=["data-model"]),
                           dict(self.FIX, screens=["pipeline", "today"]),
                           dict(self.FIX, touches=["rule"]),
                           dict(self.FIX, touches=["contract"]),
                           dict(self.FIX, track=None)])
        self.assertEqual([f["track"] for f in out], ["body"] * 5)
        self.assertEqual({f["decision"] for f in out}, {"propose"})
        self.assertEqual(out[0]["labels"], ["body-of-work", "proposal"])
        self.assertIn("whatever its label", out[0]["why"])

    def test_fix_cap_sends_overflow_to_backlog_as_a_proposal(self):
        out = self.triage([dict(self.FIX, title=f"t{i}") for i in range(7)])
        self.assertEqual([f["decision"] for f in out], ["fix"] * 5 + ["propose"] * 2)
        self.assertIn("cap of 5", out[5]["why"])
        self.assertIn("held back by the run cap", out[6]["recommendation"])
        out = self.triage([dict(self.FIX, title=f"t{i}") for i in range(3)], "--max-fix", "1")
        self.assertEqual([f["decision"] for f in out], ["fix", "propose", "propose"])
        cfg = Path(self.findings.parent) / "cfg.json"
        cfg.write_text(json.dumps({"collect": {"triage": {"max_fix_cards": 2}}}))
        out = self.triage([dict(self.FIX, title=f"t{i}") for i in range(3)], "--config", str(cfg))
        self.assertEqual([f["decision"] for f in out], ["fix", "fix", "propose"])

    def test_triage_leaves_drops_alone_and_refuses_a_bare_proposal(self):
        out = self.triage([dict(FINDINGS[3])])
        self.assertNotIn("decision", out[0])
        p = self.triage([dict(self.FIX, decision="propose")], expected=64)
        self.assertIn("needs a recommendation", p.stderr)

    def test_doc_shows_the_triage(self):
        triaged = self.triage([dict(self.FIX), dict(self.FIX, title="Rethink", touches=["rule"])])
        self.findings.write_text(json.dumps(triaged))
        p = self.run_cli("doc", "--findings", str(self.findings), "--date", "2026-11-12")
        self.assertIn("tweak · fix → Ready", p.stdout)
        self.assertIn("body · propose → Backlog", p.stdout)
        self.assertIn("Recommendation: Accept to grill it", p.stdout)

    # digest ----------------------------------------------------------------
    def test_digest_lists_open_proposals_with_a_recommendation(self):
        issues = Path(self.findings.parent) / "issues.json"
        issues.write_text(json.dumps([
            {"number": 41, "title": "Agent sees all data", "labels": [{"name": "proposal"}, {"name": "body-of-work"}],
             "body": "## Problem\nx\n\n## Recommendation\n- Accept: grill it, it reverses I4.\n"},
            {"number": 42, "title": "Copy on empty state", "labels": ["proposal", "tweak"], "body": "## Problem\nx"},
            {"number": 43, "title": "Not a proposal", "labels": [{"name": "bug"}], "body": ""},
        ]))
        p = self.run_cli("digest", "--issues-json", str(issues))
        self.assertIn("## Proposals · 2 open", p.stdout)
        self.assertIn("| #41 | body | Agent sees all data | Accept: grill it, it reverses I4. |", p.stdout)
        self.assertIn("| #42 | tweak |", p.stdout)
        self.assertIn("no recommendation", p.stdout)
        self.assertNotIn("#43", p.stdout)
        self.assertIn("reject #N <reason>", p.stdout)

    # SKILL.md files straight into Backlog ----------------------------------
    def test_skill_files_straight_into_backlog(self):
        text = SKILL.read_text()
        for needle in ("collect_handoff.py", "docs/super-board/findings/collect-<YYYY-MM-DD>.md",
                       "super-collect-file.sh", "ticket-format.md"):
            self.assertIn(needle, text)
        for gone in ("/to-spec", "/to-tickets", "/implement-spec"):
            self.assertNotIn(gone, text)


class IterationProtocol(unittest.TestCase):
    """The three tracks are written down, triage follows them, and lint holds the gate (#102)."""
    REFS = KIT / "skills/super-board/references"

    def test_iteration_md_defines_tracks_routing_path_brief_and_lessons(self):
        text = (self.REFS / "iteration.md").read_text()
        for needle in ("| **bug** |", "| **tweak** |", "| **body of work** |",
                       "What it touches picks the track, not its label",
                       "docs/shape/briefs/<YYYY-MM-DD>-<slug>.md", "Signed: <date> · <owner>",
                       "## Lessons log", "docs/super-board/lessons.md",
                       "collect.triage.max_fix_cards", "`proposal`", "`body-of-work`"):
            self.assertIn(needle, text)
        steps = [f"- {c}. **" for c in "abcdefghij"]
        positions = [text.index(st) for st in steps]
        self.assertEqual(positions, sorted(positions))
        for word in ("Grill", "Exam", "Brief", "Fable review", "Owner signs", "Spec update",
                     "Cards", "Run", "Walk", "Report"):
            self.assertIn(f". **{word}.**", text)
        for section in ("## What", "## Why", "## Rules it changes", "## Screens", "## Out of scope",
                        "## Exam", "## Review"):
            self.assertIn(section, text)

    def test_collect_triages_and_digests(self):
        text = SKILL.read_text()
        for needle in ("## Triage", "collect_handoff.py triage", "## Proposals digest",
                       "collect_handoff.py digest", "--accept <n>", "--reject <n> --reason",
                       "--track bug|tweak|body --decision fix|propose", "| `feedback` | `python3 .claude/skills/super-collect/scripts/collect_feedback.py list`",
                       "Never accept or reject for the owner", "iteration.md"):
            self.assertIn(needle, text)
        self.assertNotIn("never moves a card to `Ready`", text)

    def test_lint_holds_the_brief_gate(self):
        lint = (self.REFS / "lint.md").read_text()
        self.assertIn("| 25 | Body of work without a signed brief", lint)
        self.assertIn("super-board-coverage.py briefs", lint)
        self.assertIn("passes all 25 criteria", lint)
        rescope = (KIT / "skills/to-board/SKILL.md").read_text()
        self.assertIn("- **Brief:** docs/shape/briefs/<date>-<slug>.md", rescope)

    def test_agents_md_block_points_at_the_protocol(self):
        block = (self.REFS / "agents-md-block.md").read_text()
        self.assertIn("references/iteration.md", block)


if __name__ == "__main__":
    unittest.main()
