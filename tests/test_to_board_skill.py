"""Offline text checks for skills/to-board (spec review and blind review steps)."""
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
        self.assertIn("step 8 as a flagged line", TEXT)
        self.assertIn("approved the scope in step 8", TEXT)
        self.assertNotIn("in step 7.", TEXT)
        filing = (ROOT / "skills/to-board/references/filing.md").read_text()
        self.assertIn("SKILL step 8", filing)
        self.assertNotIn("step 7", filing)

    def section(self, name):
        m = re.search(r"^### \d+\. " + re.escape(name) + r"\n(.*?)(?=^### )", TEXT, re.M | re.S)
        self.assertIsNotNone(m, name)
        return m.group(1)

    def test_spec_review_sits_after_spec_and_before_blind_review(self):
        names = [n for _, n in re.findall(r"^### (\d+)\. (.+)$", TEXT, re.M)]
        self.assertEqual(names.index("Spec review"), names.index("Write `docs/shape/spec.md`") + 1)
        self.assertLess(names.index("Spec review"), names.index("Cut the cards"))
        self.assertLess(names.index("Spec review"), names.index("Blind review"))

    def test_spec_review_inputs_model_read_only_and_output(self):
        s = self.section("Spec review")
        self.assertIn("model fable", s)
        self.assertIn("read-only", s)
        self.assertIn("writes no file", s)
        for f in ("north-star.md", "later.md", "mockup.html", "mockup-log.md", "spec.md"):
            self.assertIn(f"docs/shape/{f}", s)
        self.assertIn("Never your drafting reasoning", s)
        self.assertIn("at most 8 findings ranked by impact", s)
        self.assertIn("smallest fix", s)
        self.assertIn("under 700 words", s)
        for look in ("never-list or privacy rules", "mock-up shows that spec.md leaves out",
                     "data the goal needs", "over-engineering"):
            self.assertIn(look, s)

    def test_spec_review_reads_as_an_attacker(self):
        s = self.section("Spec review")
        self.assertIn("model fable", s)
        self.assertIn("**as an attacker:**", s)
        for want in ("reach another's data", "without signing in", "guessed id", "leaked link",
                     "break a must-never or cross users", "missing spec rule or invariant",
                     "the test that closes it", "No generic hardening advice",
                     "Attacker findings share the 8 and are marked `abuse`"):
            self.assertIn(want, s)

    def test_spec_review_owner_decides(self):
        s = self.section("Spec review")
        self.assertIn("**your take** on each", s)
        self.assertIn("The owner decides; nothing is applied without them.", s)
        self.assertIn("does not replace the blind review or the Haiku read", s)
        # The blind reviewer still never sees spec.md.
        self.assertIn("Never `spec.md`", self.section("Blind review"))

    def test_spec_review_capability_pass_and_rules_with_no_parent(self):
        s = self.section("Spec review")
        for want in ("**capability pass:**", "`## Day-one questions`", "can this design answer it?",
                     "`yes` or `no`, and why", "marks it `guessed`",
                     "**rules with no parent:**", "every invariant or must-never in spec.md",
                     "| Must-have | Day-one question | Can answer? | Why |",
                     "No north-star parent:", "(keep or drop?)",
                     "outside the 8 and the word count", "needs the owner's call"):
            self.assertIn(want, s)

    def test_mockup_log_is_an_input(self):
        self.assertIn("| `docs/shape/mockup-log.md` | if present (from `/mockup`) |", TEXT)

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
        self.assertIn("### 9. Commit, then file to Ready", TEXT)
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


class NorthStarDayOne(unittest.TestCase):
    NS = (ROOT / "skills" / "north-star" / "SKILL.md").read_text()

    def test_grill_asks_day_one_per_must_without_extra_questions(self):
        self.assertIn("- **Day-one test:** under each must", self.NS)
        self.assertIn("what will you ask or do with this on day one, and what's a good answer?", self.NS)
        self.assertIn("costs no extra one", self.NS)
        self.assertIn("**12 questions or fewer**", self.NS)

    def test_day_one_section_format_and_home(self):
        self.assertIn("## Day-one questions\n- M<n>: <what they'll ask or do on day one> → <a good answer>", self.NS)
        self.assertLess(self.NS.index("## Must have\n"), self.NS.index("## Day-one questions"))
        self.assertIn("never in the postcard", self.NS)

    def test_log_counts_day_one_per_must(self):
        self.assertIn('"day_one":{"M1":0}', self.NS)
        self.assertIn("`day_one` counts the day-one lines per must-have", self.NS)


if __name__ == "__main__":
    unittest.main()
