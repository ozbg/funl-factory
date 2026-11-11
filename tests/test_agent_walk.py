"""Offline text checks for the milestone-end agent walk and the product targets (factory #108)."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REFS = ROOT / "skills" / "super-board" / "references"


def read(*parts):
    return ROOT.joinpath(*parts).read_text()


class AgentWalk(unittest.TestCase):
    def setUp(self):
        self.walk = (REFS / "walk.md").read_text()

    def test_walk_uses_sonnet_the_real_app_and_the_day_one_questions(self):
        self.assertIn("model **Sonnet**", self.walk)
        self.assertIn("## Day-one questions", self.walk)
        self.assertIn("Never the fake or mock model", self.walk)
        self.assertIn("screen-match.md", self.walk)
        self.assertIn("runtime_browser.mjs --shot", self.walk)
        self.assertIn("Never read `.env`", self.walk)

    def test_walk_rubric_covers_screens_questions_and_exams(self):
        rubric = self.walk.split("## The rubric", 1)[1].split("## Findings", 1)[0]
        for line in ("**Opens.**", "**Looks right.**", "**Does the job.**", "**States.**", "**Reads well.**",
                     "**Each day-one question.**", "**Each exam card.**"):
            self.assertIn(line, rubric)
        self.assertIn("super-board-scorecard.py exam", rubric)

    def test_walk_saves_a_shot_per_screen_and_records_with_the_scorecard(self):
        self.assertIn("docs/super-board/runs/<date>-walk/", self.walk)
        self.assertIn("<run folder>/screen-<name>.png", self.walk)
        self.assertRegex(self.walk, r"super-board-scorecard\.py walk --screens <n> --passed <n> \\\n\s+--questions <n> --answered <n> --shots")

    def test_failures_file_to_backlog_through_the_collect_filer(self):
        self.assertIn("super-collect-file.sh --config <cfg> --type bug", self.walk)
        self.assertIn("--source walk", self.walk)
        self.assertIn('walk|screen-<name>|<key>', self.walk)
        filer = read("skills", "super-collect", "scripts", "super-collect-file.sh")
        self.assertIn('walk) FP_PREFIX="walk|"', filer)
        self.assertIn("|walk", read("skills", "super-collect", "SKILL.md"))

    def test_only_the_owner_accepts_findings(self):
        self.assertIn("On the owner's word only, never the agent's", self.walk)
        self.assertIn("walk --accepted --note", self.walk)

    def test_run_loop_runs_the_walk_before_the_goal_is_reached(self):
        wf = (REFS / "run-workflow.md").read_text()
        walk_at, goal_at = wf.index("**Agent walk:**"), wf.index("**Goal reached:**")
        self.assertLess(walk_at, goal_at)
        self.assertIn("[`walk.md`](walk.md)", wf)
        self.assertIn("`milestone_done`", wf[goal_at:goal_at + 400])
        self.assertIn("[`retro.md`](retro.md)", wf)
        self.assertIn("walk.md", (REFS / "run.md").read_text().split("## Done conditions", 1)[1])
        self.assertIn("references/walk.md", read("skills", "super-board", "SKILL.md"))
        self.assertIn("agent walk passed", (REFS / "status.md").read_text())

    def test_qa_records_the_screen_match(self):
        qa = (REFS / "lanes" / "qa.md").read_text()
        step = qa.split("7b. **Screen match**", 1)[1].split("\n8. ", 1)[0]
        self.assertIn("super-board-scorecard.py screen --card <N> --screen screen-<name> --passed|--failed", step)
        self.assertIn("super-board-scorecard.py screen", read("skills", "super-qa", "references", "screen-match.md"))


class ProductTargets(unittest.TestCase):
    def test_new_targets_have_defaults_everywhere(self):
        for text in ((REFS / "config-schema.json").read_text(), (REFS / "onboard.md").read_text(),
                     (REFS / "report.md").read_text()):
            self.assertIn("screens_match", text)
            self.assertIn("walk_pass", text)
        self.assertRegex((REFS / "config-schema.json").read_text(), r'"screens_match": 100, "walk_pass": 100')
        report = (REFS / "report.md").read_text()
        self.assertIn("mock-up cuts", report)
        self.assertIn("[`retro.md`](retro.md)", report)

    def test_retro_template_has_a_product_quality_section(self):
        retro = (REFS / "retro.md").read_text()
        section = retro.split("## Product quality", 1)[1].split("## What worked", 1)[0]
        for row in ("Screens match the mock-up", "AI exams", "Agent walk", "Walk findings", "Owner-found defects"):
            self.assertIn(row, section)

    def test_help_guide_matches_the_walk(self):
        html = read("docs", "help.html")
        self.assertIn("The milestone isn't done until the walk passes or you accept its findings.", html)
        self.assertIn("docs/super-board/runs/&lt;date&gt;-walk/", html)
        self.assertTrue(re.search(r"Agent walk passes</td><td>every screen and day-one question", html))


if __name__ == "__main__":
    unittest.main()
