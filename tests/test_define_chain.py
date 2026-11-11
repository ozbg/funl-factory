"""Offline text checks for the Define chain: mockup review and polish, hand-offs, secrets rule."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOCKUP = (ROOT / "skills/mockup/SKILL.md").read_text()


def section(text, name):
    m = re.search(r"^### \d+\. " + re.escape(name) + r"\n(.*?)(?=^#{2,3} )", text, re.M | re.S)
    assert m, name
    return m.group(1)


class Mockup(unittest.TestCase):
    def test_step_order(self):
        steps = re.findall(r"^### (\d+)\. (.+)$", MOCKUP, re.M)
        self.assertEqual([int(i) for i, _ in steps], list(range(1, len(steps) + 1)))
        names = [n for _, n in steps]
        tweak = next(i for i, n in enumerate(names) if n.startswith("Pick and tweak"))
        self.assertEqual(names[tweak + 1:tweak + 4], ["Outside review", "Design polish", "The postcard check"])

    def test_outside_review(self):
        s = section(MOCKUP, "Outside review")
        for want in ("model fable", "read-only", "writes no file", "north-star.md", "later.md",
                     "mockup-log.md", "mockup.html", "verdict:", "at most 8 core issues",
                     "smallest fix", "cut/park list", "at most 3 things that must stay",
                     "under 700 words", "**your take** on each",
                     "The owner decides; nothing is applied without them."):
            self.assertIn(want, s)

    def test_feedback_log(self):
        self.assertIn("`<out>/mockup-log.md`", MOCKUP)
        self.assertIn("- owner (round <n>):", MOCKUP)
        self.assertIn("- builder:", MOCKUP)

    def test_design_polish(self):
        s = section(MOCKUP, "Design polish")
        for want in ("`frontend-design`", "Keep every `screen-<name>` id", "every button",
                     "every behaviour", "before and after screenshots", "1280px", "390px",
                     "owner picks what stays"):
            self.assertIn(want, s)

    def test_hand_off_depends_on_board_config(self):
        self.assertIn('No board config in `.claude/super-board/configs/` → "Mock-up signed. Next: /super-board onboard"', MOCKUP)
        self.assertIn('A config exists → "Mock-up signed. Next: /to-board --dry-run"', MOCKUP)
        self.assertNotIn("Next: /to-board.", MOCKUP)

    def test_line_limit(self):
        self.assertLessEqual(len(MOCKUP.splitlines()), 150)


class Chain(unittest.TestCase):
    def test_north_star_hands_to_mockup(self):
        ns = (ROOT / "skills/north-star/SKILL.md").read_text()
        self.assertIn('"North star signed. Next: /mockup"', ns)
        self.assertLessEqual(len(ns.splitlines()), 150)

    def test_onboard_checks_plugin_and_names_dry_run(self):
        ob = (ROOT / "skills/super-board/references/onboard.md").read_text()
        self.assertIn("frontend-design@claude-plugins-official", ob)
        self.assertIn("enabledPlugins", ob)
        self.assertIn("Next: /to-board --dry-run", ob)

    def test_help_shows_chain_in_order(self):
        html = (ROOT / "docs/help.html").read_text()
        chain = re.search(r'<ol class="chain">(.*?)</ol>', html, re.S).group(1)
        order = ["/north-star", "/mockup", "outside review", "design polish", "postcard check",
                 "/super-board onboard", "/to-board --dry-run", "spec review", "blind review",
                 "scope review", "/to-board</span>: files", "zones.yaml", "/super-board lint",
                 "/super-board run", "report"]
        pos = [chain.find(w) for w in order]
        self.assertNotIn(-1, pos, dict(zip(order, pos)))
        self.assertEqual(pos, sorted(pos))


class Secrets(unittest.TestCase):
    def test_standalone_crawl_uses_env_check(self):
        crawl = (ROOT / "skills/super-qa/references/standalone-crawl.md").read_text()
        self.assertIn(".claude/bin/super-board-env-check.sh", crawl)
        self.assertNotIn("read in order: `.env", crawl)

    def test_no_skill_tells_an_agent_to_read_a_secrets_file(self):
        bad = re.compile(r"\b(read|open|cat|grep|source|pull)\b[^.\n]{0,40}`\.env(\.[a-z.]+)?`", re.I)
        never = re.compile(r"\bnever\b", re.I)
        hits = []
        for f in (ROOT / "skills").rglob("*.md"):
            for n, line in enumerate(f.read_text().splitlines(), 1):
                if bad.search(line) and not never.search(line):
                    hits.append(f"{f.relative_to(ROOT)}:{n}")
        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()
