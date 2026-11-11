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

    def test_screen_cards_carry_the_mock_up_block(self):
        card = (ROOT / "skills/to-board/references/card-template.md").read_text()
        for want in ("## Mock-up\n- **Anchor:** docs/shape/mockup.html#screen-<name>",
                     "- **Classes:**", "- **Cut from mock-up:**", "```html",
                     "screen matches mock-up `#screen-<name>` (screenshot side by side)",
                     "never the\nmock-up's JavaScript", "## The mock-up block",
                     "write out the HTML it renders, not the JS"):
            self.assertIn(want, card)
        cut = self.section("Cut the cards")
        self.assertIn("**Mock-up block:**", cut)
        self.assertIn("never the mock-up's JS", cut)
        self.assertIn("`Cut from mock-up:`", cut)
        self.assertIn("`Cut from mock-up:`", self.section("Check before showing"))
        self.assertIn("Cut from mock-up: <screen>: <feature>", self.section("One review, for scope"))

    def test_coverage_lists_the_cuts(self):
        cov = self.section("Write `docs/shape/coverage.md`")
        self.assertIn("Cut from mock-up:\n- #13 · screen-pipeline:", cov)
        self.assertIn("`- none`", cov)
        lint = (ROOT / "skills/super-board/references/lint.md").read_text()
        self.assertIn("super-board-coverage.py cards", lint)
        self.assertIn("| 24 | Screen card", lint)


class NorthStarDayOne(unittest.TestCase):
    NS = (ROOT / "skills" / "north-star" / "SKILL.md").read_text()

    def test_grill_asks_day_one_per_must_as_part_of_the_bar(self):
        self.assertIn("- **Day-one test:** under each must", self.NS)
        self.assertIn("what will you ask or do with this on day one, and what's a good answer?", self.NS)
        self.assertIn("It is item 3 of the clarity bar (step 5).", self.NS)
        self.assertNotIn("costs no extra one", self.NS)

    def test_day_one_section_format_and_home(self):
        self.assertIn("## Day-one questions\n- M<n>: <what they'll ask or do on day one> → <a good answer>", self.NS)
        self.assertLess(self.NS.index("## Must have\n"), self.NS.index("## Day-one questions"))
        self.assertIn("never in the postcard", self.NS)

    def test_log_counts_day_one_per_must(self):
        self.assertIn('"day_one":{"M1":0}', self.NS)
        self.assertIn("`day_one` counts the day-one lines per must-have", self.NS)


class NorthStarClarityBar(unittest.TestCase):
    NS = (ROOT / "skills" / "north-star" / "SKILL.md").read_text()

    def drill(self):
        m = re.search(r"^### 5\. Drill to the clarity bar\n(.*?)(?=^### )", self.NS, re.M | re.S)
        self.assertIsNotNone(m)
        return m.group(1)

    def test_no_hard_question_cap(self):
        for cap in ("12 questions or fewer", "n/12", "12 or fewer", "12 is a ceiling"):
            self.assertNotIn(cap, self.NS)
        self.assertIn("About 12 questions is typical, not a cap", self.NS)
        self.assertIn("| Questions | about 12, not a cap | |", self.NS)

    def test_drill_step_sits_after_must_list_and_before_sparkle(self):
        names = [n for _, n in re.findall(r"^### (\d+)\. (.+)$", self.NS, re.M)]
        i = names.index("Drill to the clarity bar")
        self.assertEqual(names[i - 1], "Round 3: must, nice, never")
        self.assertEqual(names[i + 1], "Sparkle")

    def test_bar_has_four_items(self):
        d = self.drill()
        for item in ("(1) **who** uses it and what triggers it", "(2) what a **good result** looks like",
                     "(3) its **day-one** question, with an expected answer",
                     "(4) the one **edge case** that would change the design"):
            self.assertIn(item, d)

    def test_drill_judgement(self):
        d = self.drill()
        for want in ("Score each must-have 0 to 4 against the bar", "one question at a time",
                     "**Weakest first.**", "**A clear must-have gets one confirming question**",
                     "then stop drilling it", "with your guess, worded so \"yes\" accepts it",
                     "`Clear: M1, M3 · Drilling: M2 (2/4: no edge case) · Questions: 9`"):
            self.assertIn(want, d)

    def test_enough_ends_it_and_records_assumed(self):
        self.assertIn('- **"Enough" always ends it.**', self.NS)
        self.assertIn("`M<n>: assumed <missing items> (owner closed)`", self.NS)
        self.assertIn("- M<n>: assumed <missing items> (owner closed)\n```", self.NS)

    def test_log_records_questions_per_must_and_owner_closed(self):
        self.assertIn('"per_must":{"M1":0},"owner_closed":[]', self.NS)
        self.assertIn("`per_must` the questions asked about each", self.NS)
        self.assertIn("`owner_closed` the must-haves closed with \"enough\"", self.NS)


class DefineReview(unittest.TestCase):
    def sub(self):
        m = re.search(r"^#### Define review\n(.*?)(?=^#{2,4} )", TEXT, re.M | re.S)
        self.assertIsNotNone(m)
        return m.group(1)

    def test_sits_in_step_3_after_the_spec_review_before_cards(self):
        spec = TEXT.index("### 3. Spec review")
        self.assertLess(spec, TEXT.index("#### Define review"))
        self.assertLess(TEXT.index("#### Define review"), TEXT.index("### 4. "))
        self.assertIn("**in the same message as the spec review**", self.sub())

    def test_inputs_model_and_read_only(self):
        s = self.sub()
        for want in ("model fable", "read-only", "writes no file", "never the spec review's findings"):
            self.assertIn(want, s)
        for f in ("north-star.md", "mockup.html", "mockup-log.md", "spec.md"):
            self.assertIn(f"docs/shape/{f}", s)
        self.assertNotIn("later.md", s)

    def test_hunts_only_for_the_five_gaps(self):
        s = self.sub()
        for look in ("**vague must-haves:**", "the three documents disagree",
                     "mock-up screens or behaviour the spec doesn't support",
                     "spec rules that box the product in", "anything a builder or the AI would have to guess"):
            self.assertIn(look, s)

    def test_output_is_bounded_drill_down_questions(self):
        s = self.sub()
        self.assertIn("**at most 10 drill-down questions**", s)
        self.assertIn("`D<n> · <question> · suggested: <answer> · rests on:", s)
        self.assertIn("separate from the spec review's 8 findings", s)

    def test_vague_must_have_goes_back_to_north_star_before_cards(self):
        s = self.sub()
        self.assertIn("`M<n>: back to /north-star`", s)
        self.assertIn("**cut no cards** until the owner either re-grills", s)
        self.assertIn("the Define review's questions (step 3)", TEXT)
        self.assertIn("the spec review, the Define review and the blind review", TEXT)

    def test_help_describes_both_steps(self):
        html = (ROOT / "docs/help.html").read_text()
        self.assertNotIn("at most 12 questions", html)
        self.assertIn("drills each must-have to a <strong>clarity bar</strong>", html)
        self.assertIn("about 12 questions is typical, not a cap", html)
        self.assertIn('Say "enough" any time', html)
        self.assertIn("<li>Define review, alongside the spec review:", html)
        self.assertIn("up to 10 drill-down questions, each with a suggested answer", html)
        self.assertIn("no cards are cut until you do", html)


if __name__ == "__main__":
    unittest.main()
