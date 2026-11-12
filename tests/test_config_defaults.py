"""Offline text checks for config defaults and the onboard/run text that writes them
(factory #83, #89, #91, #92, #93)."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REFS = ROOT / "skills" / "super-board" / "references"
ONBOARD = (REFS / "onboard.md").read_text()
RUN_WF = (REFS / "run-workflow.md").read_text()
SCHEMA_TEXT = (REFS / "config-schema.json").read_text()


def schema():
    body = "\n".join(l for l in SCHEMA_TEXT.splitlines() if not l.lstrip().startswith("//"))
    return json.loads(body)


def onboard_config_write():
    """Step 8's config-write bullet, from the config file line to the active pointer line."""
    m = re.search(r"\.claude/super-board/configs/<slug>\.json \(committed\)(.*?)\.claude/super-board/active ←",
                  ONBOARD, re.S)
    assert m, "onboard step 8 config write not found"
    return re.sub(r"\s+", " ", re.sub(r"[│├└─]", " ", m.group(1)))


class MidDefineChecks(unittest.TestCase):  # #83
    def test_onboard_saves_empty_checks_for_a_new_app_mid_define(self):
        text = re.sub(r"\s+", " ", re.sub(r"[│├└─]", " ", ONBOARD))
        self.assertIn("A new app mid-Define (`docs/shape/north-star.md` exists, no app manifest", text)
        self.assertIn("stage `verify_commands: []`", text)
        self.assertIn("Checks are set at /to-board, once the spec picks the stack.", text)
        self.assertIn("never report it as a failure", text)
        self.assertIn("A new app mid-Define expects exit 9 here: no failure", text)

    def test_to_board_sets_verify_commands_from_the_stack_before_the_first_run(self):
        skill = (ROOT / "skills" / "to-board" / "SKILL.md").read_text()
        line = next(l for l in skill.splitlines() if l.startswith("1. **Foundation card**"))
        self.assertIn("real check commands for the stack spec.md picked", line)
        self.assertIn("before the first `/super-board run` the orchestrator sets `verify_commands`", line)


class OwnerName(unittest.TestCase):  # #89
    PROMPTS = [p for p in (ROOT / "skills").rglob("*.md")] + [REFS / "config-schema.json"]

    def test_no_lane_prompt_or_template_hard_codes_a_person(self):
        hits = []
        for p in self.PROMPTS:
            for i, line in enumerate(p.read_text().splitlines(), 1):
                if re.search(r"\bEric\b(?! Tech)", line):
                    hits.append(f"{p.relative_to(ROOT)}:{i}")
        self.assertEqual(hits, [])

    def test_templates_name_the_configured_owner(self):
        self.assertIn("Owner: <owner_name | repo admin>", (REFS / "block-template.md").read_text())
        self.assertIn("Owner: <owner_name> (close as duplicate)", (REFS / "lanes" / "build.md").read_text())
        self.assertIn("Next: <builder | qa | reviewer | owner | none>", (REFS / "lanes" / "common.md").read_text())

    def test_onboard_writes_owner_name(self):
        self.assertIn("owner_name", schema()["notifications"])
        self.assertIn("Stage `notifications.owner_name` too: the repo owner's GitHub name", ONBOARD)
        self.assertIn('bot_identity, owner_name}', onboard_config_write())


class CardSize(unittest.TestCase):  # #91
    def test_card_size_gates_cite_card_max_lines(self):
        lint = next(l for l in (REFS / "lint.md").read_text().splitlines() if l.startswith("| 15 |"))
        build = next(l for l in (REFS / "lanes" / "build.md").read_text().splitlines() if l.startswith("| 5 | Too big?"))
        size = next(l for l in (REFS / "ticket-format.md").read_text().splitlines() if l.startswith("| Size |"))
        for row in (lint, build):
            self.assertIn("`card_max_lines`", row)
            self.assertNotIn("auto_max_lines", row)
        self.assertIn("(`card_max_lines`)", size)
        self.assertIn("only decides who merges", size)
        crit = (REFS / "lint.md").read_text().split("## Criterion 15", 1)[1].split("\n## ", 1)[0]
        self.assertIn("(`card_max_lines`, default 600", crit)

    def test_schema_documents_both_keys_each_with_one_job(self):
        cfg = schema()
        self.assertEqual(cfg["card_max_lines"], 600)
        self.assertIn("auto_max_lines", cfg["merge_policy"])
        self.assertIn("// Card size (one job: how big a card may be).", SCHEMA_TEXT)
        self.assertIn("It never\n  // decides who merges", SCHEMA_TEXT)
        self.assertIn("// One job: who merges a PR, by size. Never the card-size yardstick", SCHEMA_TEXT)


class WaveWidth(unittest.TestCase):  # #92
    def test_docs_name_the_ceiling_of_six(self):
        self.assertIn("`ramp.stage`, 1–6", RUN_WF)
        self.assertIn("stage: 1 to 6", SCHEMA_TEXT)
        self.assertIn("Above 6 the planner exits 65", SCHEMA_TEXT)


class OnboardDefaults(unittest.TestCase):  # #93
    def test_fresh_onboard_writes_the_owner_approved_defaults(self):
        write = onboard_config_write()
        self.assertIn('`ramp: {"stage": 3}`', write)
        self.assertIn('`lane_models: {"review": "sonnet"}`', write)
        self.assertIn('"red": {"build": "sonnet", "qa": "sonnet", "review": "session"}', write)
        self.assertIn("`card_max_lines: 600`", write)
        self.assertIn("auto_max_lines 5000 source lines", ONBOARD)
        self.assertNotIn("auto_max_lines 600", ONBOARD)
        cfg = schema()
        self.assertEqual(cfg["merge_policy"]["auto_max_lines"], 5000)
        self.assertEqual(cfg["lane_models"]["review"], "sonnet")
        self.assertEqual(cfg["lane_models_by_tier"]["red"]["review"], "session")
        self.assertEqual(cfg["ramp"]["stage"], 3)

    def test_existing_config_values_are_kept_on_rerun(self):
        write = onboard_config_write()
        self.assertIn("Each default here (merge cap, card cap, ramp, models, targets) is", write)
        self.assertIn("for a new config only: a value already set is kept on re-run.", write)

    def test_run_preconditions_name_accept_edits_and_the_auto_warning(self):
        pre = RUN_WF.split("Run the same preconditions", 1)[1].split("## The wave loop", 1)[0]
        self.assertIn("lanes are designed for **Accept edits**", pre)
        self.assertIn('"Switch this session to Accept edits; Auto can refuse\n   allow-listed lane commands like the merge gate."', pre)


if __name__ == "__main__":
    unittest.main()
