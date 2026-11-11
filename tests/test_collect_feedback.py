"""super-collect source `feedback` (collect_feedback.py), factory #103.

read    — new items only, unknown schema skipped, a missing folder is unavailable
redact  — emails, phones, state names, query values and tokens never reach the output
dedupe  — same route and element with overlapping words merge; a match with a filed item reuses its fingerprint
mark    — filed.json records the issue, so the item is never read as new again

Offline: fixtures in tests/fixtures/collect/feedback, copied to a temp folder.

    python3 tests/test_collect_feedback.py
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

KIT = Path(__file__).resolve().parents[1]
CLI = KIT / "skills/super-collect/scripts/collect_feedback.py"
FIXTURES = KIT / "tests/fixtures/collect/feedback"


class Feedback(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.dir = self.root / "data" / "feedback"
        shutil.copytree(FIXTURES, self.dir)

    def run_cli(self, *args, expected=0):
        p = subprocess.run([sys.executable, str(CLI), *args], cwd=self.root, text=True, capture_output=True)
        self.assertEqual(p.returncode, expected, p.stderr + p.stdout)
        return p

    def listed(self, *args):
        return json.loads(self.run_cli("list", "--dir", str(self.dir), *args).stdout)

    def by_route(self, out):
        return {c["route"]: c for c in out["candidates"]}

    def test_reads_new_items_and_skips_unknown_schema(self):
        out = self.listed()
        self.assertEqual(out["status"], "read")
        self.assertEqual(out["new"], 4)
        self.assertEqual(out["already_filed"], 1)
        self.assertEqual([s["file"] for s in out["skipped"]], ["old-schema.json"])
        self.assertIn("feedback/1", out["skipped"][0]["why"])
        for c in out["candidates"]:
            self.assertEqual(c["source"], "feedback")
            self.assertTrue(c["fingerprint"].startswith("feedback|"))
            self.assertNotRegex(c["fingerprint"], r"[\s\"\\]")

    def test_default_folder_comes_from_config(self):
        cfg = self.root / "cfg.json"
        cfg.write_text(json.dumps({"collect": {"feedback": {"dir": "data/feedback"}}}))
        out = json.loads(self.run_cli("list", "--config", str(cfg)).stdout)
        self.assertEqual(out["new"], 4)

    def test_since_narrows_by_created_at(self):
        out = self.listed("--since", "2026-11-12T00:00:00Z")
        self.assertEqual(out["new"], 1)

    def test_missing_folder_is_unavailable_not_empty(self):
        p = self.run_cli("list", "--dir", str(self.root / "nope"), expected=2)
        self.assertEqual(json.loads(p.stdout)["status"], "unavailable")

    def test_redacts_contact_details_names_queries_and_tokens(self):
        raw = self.run_cli("list", "--dir", str(self.dir)).stdout
        for leak in ("jo@example.com", "0412 345 678", "Harbour Freight", "harbour", "eyJhbGciOiJIUzI1NiJ9"):
            self.assertNotIn(leak, raw, leak)
        c = self.by_route(json.loads(raw))["/clients/N"]
        first = c["items"][0]
        self.assertEqual(first["text"], "Save does nothing on the [name] note. Call me on [phone] or [email]")
        self.assertEqual(first["route"], "/clients/42?tab=…&q=…")
        self.assertEqual(first["state"], {"client_id": 42, "client_name": "[redacted]", "notes": 3, "filter": "open"})
        self.assertIn("debug auth Bearer [token]", first["logs"]["client"])
        self.assertIn("error notes.save: null client for [name]", first["logs"]["server"])
        self.assertIn("2026-11-10 09:00:01", first["logs"]["client"][0], "a date is not a phone number")

    def test_screenshots_stay_local(self):
        out = self.listed()
        c = self.by_route(out)["/clients/N"]
        self.assertEqual(len(c["screenshots_local"]), 1)
        self.assertTrue(c["screenshots_local"][0].endswith(".png"))
        self.assertEqual(c["evidence"], ["2 feedback item(s) on /clients/N", "1 screenshot(s) kept local"])
        for item in c["items"]:
            self.assertNotIn("screenshot", item)

    def test_dedupes_on_route_element_and_similar_text(self):
        routes = self.by_route(self.listed())
        self.assertEqual(sorted(routes), ["/clients/N", "/pipeline", "/reports"])
        self.assertEqual(routes["/clients/N"]["count"], 2)
        self.assertEqual(routes["/pipeline"]["count"], 1)
        self.assertEqual(routes["/pipeline"]["element"], None)

    def test_a_repeat_of_a_filed_item_reuses_its_fingerprint(self):
        c = self.by_route(self.listed())["/reports"]
        self.assertEqual(c["seen_before"], "#88")
        self.assertEqual(c["fingerprint"], "feedback|/reports|1a2b3c4d5e6f|0a1b2c3d4e5f")

    def test_mark_records_the_issue_and_the_item_is_not_new_again(self):
        c = self.by_route(self.listed())["/clients/N"]
        self.run_cli("mark", "--dir", str(self.dir), "--ids", ",".join(c["ids"]), "--issue", "131",
                     "--fingerprint", c["fingerprint"])
        filed = json.loads((self.dir / "filed.json").read_text())
        for i in c["ids"]:
            self.assertEqual(filed[i]["issue"], 131)
            self.assertEqual(filed[i]["fingerprint"], c["fingerprint"])
        self.assertIn("20261112T080000Z-export-button", filed, "earlier entries are kept")
        again = self.listed()
        self.assertNotIn("/clients/N", self.by_route(again))
        self.assertEqual(again["already_filed"], 3)

    def test_refs_are_opaque_and_show_resolves_them_locally(self):
        c = self.by_route(self.listed())["/clients/N"]
        self.assertEqual(len(c["refs"]), 2)
        for r, i in zip(c["refs"], c["ids"]):
            self.assertRegex(r, r"^fb-[0-9a-f]{8}$")
            self.assertNotIn("save", r)
        out = json.loads(self.run_cli("show", c["refs"][0], "--dir", str(self.dir)).stdout)
        self.assertEqual(out["status"], "found")
        self.assertTrue(out["json"].endswith("20261110T090000Z-save-does-nothing.json"))
        self.assertTrue(out["png"].endswith("20261110T090000Z-save-does-nothing.png"))
        self.assertTrue(out["marked_up"])
        cfg = self.root / "cfg.json"
        cfg.write_text(json.dumps({"collect": {"feedback": {"dir": "data/feedback"}}}))
        out = json.loads(self.run_cli("show", c["refs"][1], "--config", str(cfg)).stdout)
        self.assertEqual(out["png"], None, "an item with no screenshot")

    def test_show_says_when_a_ref_is_not_here(self):
        p = self.run_cli("show", "fb-00000000", "--dir", str(self.dir), expected=3)
        self.assertEqual(json.loads(p.stdout)["status"], "not-here")
        self.run_cli("show", "fb-00000000", "--dir", str(self.root / "nope"), expected=3)
        self.run_cli("show", "save-does-nothing", "--dir", str(self.dir), expected=64)

    def test_mark_refuses_bad_input(self):
        self.run_cli("mark", "--dir", str(self.dir), "--ids", "no-such", "--issue", "1",
                     "--fingerprint", "feedback|/x|y|z", expected=64)
        self.run_cli("mark", "--dir", str(self.dir), "--ids", "20261111T130000Z-pipeline-headers", "--issue", "1",
                     "--fingerprint", "walk|x|y", expected=64)
        self.run_cli("mark", "--dir", str(self.dir), "--ids", "20261111T130000Z-pipeline-headers", "--issue", "x1",
                     "--fingerprint", "feedback|/x|y|z", expected=64)
        self.assertNotIn("20261111T130000Z-pipeline-headers", json.loads((self.dir / "filed.json").read_text()))

    def test_no_network_in_the_script(self):
        src = CLI.read_text()
        for mod in ("urllib", "http.client", "socket", "requests", "subprocess"):
            self.assertNotIn(f"import {mod}", src)


class FeedbackText(unittest.TestCase):
    SKILL = (KIT / "skills/super-collect/SKILL.md").read_text()
    WALK = (KIT / "skills/super-board/references/walk.md").read_text()

    def test_sources_row_and_section(self):
        self.assertIn("| `feedback` | `python3 .claude/skills/super-collect/scripts/collect_feedback.py list`", self.SKILL)
        self.assertNotIn("feedback (#103)", self.SKILL)
        sec = self.SKILL.split("### feedback — the in-app icon", 1)[1].split("### custom sources", 1)[0]
        for want in ("**Redacted first.**", "**Screenshots stay local.**", "never uploaded or embedded",
                     "**Repeats merge.**", "**Marked once filed.**", "collect_feedback.py mark --ids",
                     "A dry run marks nothing", "never go in a card"):
            self.assertIn(want, sec, want)
        self.assertIn("custom|walk|feedback", self.SKILL)
        self.assertIn('feedback) FP_PREFIX="feedback|"',
                      (KIT / "skills/super-collect/scripts/super-collect-file.sh").read_text())

    def test_cards_carry_the_ref_and_lanes_open_it(self):
        self.assertIn("`- **Feedback:** fb-b7d9560a, fb-22734fb7`", self.SKILL)
        lanes = KIT / "skills/super-board/references/lanes"
        build, qa = (lanes / "build.md").read_text(), (lanes / "qa.md").read_text()
        self.assertIn("`Feedback: fb-…` line", build)
        self.assertIn("collect_feedback.py show <ref>", build)
        self.assertIn("7c. **Feedback before.**", qa)
        self.assertIn("collect_feedback.py show <ref>", qa)
        self.assertIn('"before" in the before and after', qa)
        self.assertIn("never commit, embed or upload it", qa)

    def test_walk_findings_go_through_triage(self):
        findings = self.WALK.split("## Findings", 1)[1].split("## Record", 1)[0]
        self.assertIn("collect_handoff.py triage --findings <run folder>/triage.json", findings)
        self.assertIn("--track <track> --decision <decision>", findings)
        self.assertNotIn("File every ❌ to Backlog", self.WALK)
        self.assertLess(findings.index("collect_handoff.py triage"), findings.index("super-collect-file.sh"))


if __name__ == "__main__":
    unittest.main()
