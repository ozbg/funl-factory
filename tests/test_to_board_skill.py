"""Offline text checks for skills/to-board (blind review step)."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKILL = ROOT / "skills" / "to-board" / "SKILL.md"
REF = ROOT / "skills" / "to-board" / "references" / "blind-review.md"
TEXT = SKILL.read_text()
REF_TEXT = REF.read_text()


class ToBoardSkill(unittest.TestCase):
    def test_blind_review_step_sits_after_check_and_before_owner_review(self):
        steps = re.findall(r"^### (\d+)\. (.+)$", TEXT, re.M)
        names = [n for _, n in steps]
        self.assertEqual([int(i) for i, _ in steps], list(range(1, len(steps) + 1)))
        self.assertEqual(names.index("Blind review"), names.index("Check before showing") + 1)
        self.assertEqual(names[names.index("Blind review") + 1], "One review, for scope")

    def test_cross_references_follow_the_renumbering(self):
        self.assertIn("step 7", TEXT)
        self.assertNotIn("step 6", TEXT)
        self.assertNotIn("step 6", (ROOT / "skills/to-board/references/filing.md").read_text())

    def test_reviewer_inputs_and_never_spec(self):
        for t in (TEXT, REF_TEXT):
            self.assertIn("north-star.md", t)
            self.assertIn("mock-up screen index", t)
            self.assertIn("Never `spec.md`", t) if t is TEXT else self.assertIn("Never give it `spec.md`", t)
            for out in ("missing", "unguarded", "extra", "verdict: builds the postcard: yes | gaps"):
                self.assertIn(out, t)

    def test_haiku_read_rule(self):
        for t in (TEXT, REF_TEXT):
            self.assertIn("one sub-agent per card", t.lower())
            self.assertIn("model haiku", t)
            self.assertIn("List every question you would need answered before building this card. If none, answer exactly: none.", t)
            self.assertIn("Any answer other than `none` fails the card", t)

    def test_one_fix_round(self):
        self.assertIn("One fix round", TEXT)
        self.assertIn("only on changed or new cards", TEXT)
        self.assertIn("not looped", TEXT)
        self.assertIn("flagged line", TEXT)

    def test_owner_table_verdict_line(self):
        self.assertIn("Verdict: builds the postcard: yes · Haiku read: 14/14 clear", TEXT)
        self.assertIn("open finding", TEXT)

    def test_dry_run_without_config(self):
        self.assertIn("dry run: no config, nothing filed", TEXT)
        self.assertIn("only to file", TEXT)
        self.assertIn("draft zones.yaml", TEXT)

    def test_line_limit(self):
        self.assertLessEqual(len(TEXT.splitlines()), 200)

    def test_commits_before_filing(self):
        self.assertIn("### 8. Commit, then file to Ready", TEXT)
        self.assertIn("push the current branch without force", TEXT)
        self.assertIn("`--dry-run` commits nothing", TEXT)

    def test_checked_standards(self):
        root = Path(__file__).resolve().parent.parent
        card = (root / "skills/to-board/references/card-template.md").read_text()
        self.assertIn("no empty catch, no unhandled promises, no unused code, no `any`", card)
        self.assertIn("high-severity dependency audit", card)
        zones = (root / "skills/to-board/references/zones-draft.md").read_text()
        self.assertIn("Inputs are validated where they enter", zones)
        build = (root / "skills/super-board/references/lanes/build.md").read_text()
        self.assertIn("exactly as `docs/shape/spec.md`", build)

    def test_spec_stays_true(self):
        root = Path(__file__).resolve().parent.parent
        build = (root / "skills/super-board/references/lanes/build.md").read_text()
        self.assertIn("update\n   `docs/shape/spec.md` in the same PR", build)
        review = (root / "skills/super-board/references/lanes/review.md").read_text()
        self.assertIn("`bar: spec.md matches the code`", review)


if __name__ == "__main__":
    unittest.main()
