"""Offline tests for scripts/super-board-scorecard.py (factory #25, v2 T9 health)."""
import json
from datetime import datetime, timezone
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "super-board-scorecard.py"


def run(*args):
    r = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)
    if r.returncode:
        raise AssertionError(r.stderr)
    return r.stdout


def usage(i, o, req, ts):
    return {"type": "assistant", "requestId": req, "timestamp": ts,
            "message": {"role": "assistant", "usage": {"input_tokens": i, "cache_creation_input_tokens": 0,
                                                       "cache_read_input_tokens": 500, "output_tokens": o}}}


class Scorecard(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.logs = self.tmp / "logs"
        self.logs.mkdir()
        self.sc = self.tmp / "scorecard.jsonl"

    def agent(self, name, lines, meta=None):
        (self.logs / f"{name}.jsonl").write_text("\n".join(json.dumps(l) for l in lines) + "\n")
        if meta is not None:
            (self.logs / f"{name}.meta.json").write_text(json.dumps(meta))

    def results(self, cards):
        p = self.tmp / "results.json"
        p.write_text(json.dumps({"cards": cards, "halted": False}))
        return str(p)

    def test_record_reads_tokens_and_minutes_once(self):
        # Build agent, labelled in its meta; one response logged twice (streaming).
        self.agent("agent-b", [
            {"type": "user", "timestamp": "2026-11-09T10:00:00Z", "message": {"role": "user", "content": "x"}},
            usage(100, 900, "r1", "2026-11-09T10:01:00Z"),
            usage(100, 900, "r1", "2026-11-09T10:01:00Z"),
            usage(50, 450, "r2", "2026-11-09T10:12:00Z"),
        ], {"description": "build:#7", "model": "haiku"})
        # Review agent with no meta: found by its prompt.
        self.agent("agent-r", [
            {"type": "user", "timestamp": "2026-11-09T10:20:00Z",
             "message": {"role": "user", "content": "Run super-review on issue #7 (\"t\") for a super-board workflow wave."}},
            usage(10, 90, "r3", "2026-11-09T10:26:00Z"),
        ])
        # Another card's agent and an unrelated log are ignored.
        self.agent("agent-x", [usage(1, 1, "r4", "2026-11-09T10:00:00Z")], {"description": "build:#8"})
        self.agent("agent-y", [usage(1, 1, "r5", "2026-11-09T10:00:00Z")], {"description": "Explore repo"})
        card = {"number": 7, "complexity": "low", "buildModel": "haiku", "qaModel": "haiku", "reviewModel": "session",
                "lanesRun": "build:advanced → qa:advanced → review:advanced", "finalStatus": "advanced", "column": "Done",
                "score": {"verdict": "clean", "acsProven": 3, "acsTotal": 3, "blockers": 0, "round": 1, "cause": "none"}}
        res = self.results([card])
        out = json.loads(run("record", "--results", res, "--logs", str(self.logs), "--scorecard", str(self.sc), "--wave", "1"))
        self.assertEqual(out, {"recorded": 1, "agentsMatched": 2, "cardsWithoutLogs": 0})
        row = json.loads(self.sc.read_text().splitlines()[0])
        self.assertEqual(row["tokens"], 1000 + 500 + 100)
        self.assertEqual(row["minutes"], 12.0 + 6.0)
        self.assertEqual(row["cacheRead"], 1500)
        self.assertEqual(sorted(row["agents"]), ["agent-b", "agent-r"])
        # Recording again (logs folder keeps old agents) counts nothing twice.
        run("record", "--results", res, "--logs", str(self.logs), "--scorecard", str(self.sc), "--wave", "2")
        self.assertEqual(json.loads(self.sc.read_text().splitlines()[1])["tokens"], 0)

    def test_summary_line_per_build_model(self):
        rows = [
            # #1 haiku: merged first time, clean.
            {"card": 1, "buildModel": "haiku", "lanesRun": "build:advanced → qa:advanced → review:advanced", "column": "Done",
             "score": {"verdict": "clean", "round": 1, "cause": "none"}, "tokens": 40000, "minutes": 10},
            # #2 haiku: review sent it back (ticket unclear), merged on round 2.
            {"card": 2, "buildModel": "haiku", "lanesRun": "build:advanced → qa:advanced → review:bounced", "column": "Ready",
             "score": {"verdict": "rework", "round": 1, "cause": "ticket"}, "tokens": 30000, "minutes": 8},
            {"card": 2, "buildModel": "haiku", "lanesRun": "build:advanced → qa:advanced → review:advanced", "column": "Done",
             "score": {"verdict": "clean", "round": 2, "cause": "none"}, "tokens": 20000, "minutes": 6},
            # #3 sonnet: merged first time with should-fix notes from the build.
            {"card": 3, "buildModel": "sonnet", "lanesRun": "build:advanced → qa:advanced → review:advanced", "column": "Done",
             "score": {"verdict": "fixes", "round": 1, "cause": "build"}, "tokens": 90000, "minutes": 20},
        ]
        self.sc.write_text("".join(json.dumps(r) + "\n" for r in rows))
        out = run("summary", "--scorecard", str(self.sc)).splitlines()
        self.assertEqual(len(out), 2)
        haiku = next(l for l in out if "build haiku" in l)
        self.assertIn("2 merged", haiku)
        self.assertIn("first pass 50%", haiku)
        self.assertIn("avg rounds 1.5", haiku)
        self.assertIn("rework 33%", haiku)
        self.assertIn("cause build 0 / ticket 1", haiku)
        self.assertIn("45k tokens/card", haiku)
        self.assertIn("12 min/card", haiku)
        self.assertTrue(haiku.startswith("🔴"))  # rework 33% > 25%
        sonnet = next(l for l in out if "build sonnet" in l)
        self.assertTrue(sonnet.startswith("🟢"))
        self.assertIn("first pass 100%", sonnet)

    def test_summary_empty(self):
        self.assertIn("no scorecard rows", run("summary", "--scorecard", str(self.sc)))

    # ── v2 T9: split tokens, dollars, health, demo, digest ──

    def test_record_splits_tokens_prices_and_keeps_new_fields(self):
        self.agent("agent-b", [
            {"type": "assistant", "requestId": "r1", "timestamp": "2026-11-09T10:00:00Z",
             "message": {"role": "assistant", "model": "claude-haiku-5-5", "usage": {
                 "input_tokens": 1_000_000, "output_tokens": 1_000_000,
                 "cache_creation_input_tokens": 1_000_000, "cache_read_input_tokens": 1_000_000}}},
        ], {"description": "build:#7"})
        res = self.tmp / "res.json"
        res.write_text(json.dumps({"cards": [
            {"number": 7, "lanesRun": "build:advanced → qa:advanced → review:bounced", "column": "Ready",
             "citation": "AC2 · src/a.ts:12", "round_capped": True},
            {"number": 8, "lanesRun": "build:advanced → qa:bounced", "column": "Ready", "citation": "x"},
        ], "events": [{"type": "uncited-bounce", "number": 8}]}))
        run("record", "--results", str(res), "--logs", str(self.logs), "--scorecard", str(self.sc),
            "--wave", "w1", "--milestone", "M1")
        r7, r8 = [json.loads(l) for l in self.sc.read_text().splitlines()]
        self.assertEqual(r7["tokenSplit"], {"input": 1_000_000, "output": 1_000_000,
                                            "cacheWrite": 1_000_000, "cacheRead": 1_000_000})
        self.assertAlmostEqual(r7["usd"], 0.10 + 0.50 + 0.125 + 0.01)  # haiku list price
        self.assertEqual(r7["milestone"], "M1")
        self.assertEqual(r7["citation"], "AC2 · src/a.ts:12")
        self.assertTrue(r7["roundCapped"])
        self.assertTrue(r7["at"].endswith("Z"))
        self.assertIsNone(r8["citation"])
        self.assertTrue(r8["uncited"])
        self.assertFalse(r8["roundCapped"])

    def cfg(self, stage=3, budget=100, digest="merge-breach-ask"):
        p = self.tmp / "cfg.json"
        p.write_text(json.dumps({"goal": {"milestone": "M1", "budget_usd": budget}, "ramp": {"stage": stage},
                                 "digest": digest}))
        return p

    def rows(self, *rows):
        today = datetime.now(timezone.utc).strftime("%Y-%m-%dT10:00:00Z")
        self.sc.write_text("".join(json.dumps({"at": today, "milestone": "M1", **r}) + "\n" for r in rows))

    def health(self, cfg, *extra):
        return json.loads(run("health", "--config", str(cfg), "--scorecard", str(self.sc), *extra))

    def test_budget_burn_with_few_merges_asks_and_steps_ramp_down(self):
        cfg = self.cfg(stage=3, budget=100)
        self.rows({"wave": "w1", "card": 1, "column": "Done", "lanesRun": "review:advanced", "usd": 50},
                  {"wave": "w2", "card": 2, "column": "QA", "lanesRun": "build:advanced", "usd": 35})
        h = self.health(cfg, "--goal-done", "1", "--goal-total", "5")
        self.assertEqual(h["action"], "stop-ask")
        self.assertEqual([b["metric"] for b in h["breaches"]], ["budget-burn"])
        self.assertEqual(h["ramp"], {"from": 3, "to": 2})
        self.assertEqual(json.loads(cfg.read_text())["ramp"]["stage"], 2)
        self.assertEqual(h["budget"], {"usd": 85, "budget_usd": 100})
        self.assertEqual(sorted(h), ["action", "breaches", "budget", "goal", "metrics", "ramp", "report", "warnings", "wave"])
        ev = json.loads(self.sc.read_text().splitlines()[-1])
        self.assertEqual((ev["event"], ev["action"], ev["wave"]), ("health", "stop-ask", "w2"))
        # Same burn with 60% merged is fine.
        self.assertEqual(self.health(cfg, "--goal-done", "3", "--goal-total", "5")["action"], "continue")

    def test_breach_pauses_new_and_ramp_floors_at_one(self):
        cfg = self.cfg(stage=1, budget=None)
        self.rows({"wave": "w1", "card": 1, "column": "Review", "lanesRun": "build:advanced", "roundCapped": True})
        h = self.health(cfg)
        self.assertEqual(h["action"], "pause-new")
        self.assertEqual(h["metrics"]["roundCapped"], [1])
        self.assertEqual(h["ramp"], {"from": 1, "to": 1})
        self.assertEqual(json.loads(cfg.read_text())["ramp"]["stage"], 1)

    def test_clean_wave_continues_and_never_steps_up(self):
        cfg = self.cfg(stage=2)
        self.rows({"wave": "w1", "card": 1, "column": "Done", "lanesRun": "review:advanced",
                   "score": {"round": 1}, "usd": 1})
        h = self.health(cfg)
        self.assertEqual((h["action"], h["breaches"]), ("continue", []))
        self.assertNotIn("ramp", h)
        self.assertEqual(json.loads(cfg.read_text())["ramp"]["stage"], 2)

    def test_rounds_per_merge_and_failures_today(self):
        cfg = self.cfg(stage=3, budget=None)
        self.rows({"wave": "w1", "card": 1, "column": "Done", "score": {"round": 3}, "lanesRun": "review:advanced"},
                  {"wave": "w1", "card": 2, "column": "Done", "score": {"round": 2}, "lanesRun": "review:advanced"},
                  {"wave": "w1", "card": 6, "column": "Done", "score": {"round": 3}, "lanesRun": "review:advanced"},
                  {"wave": "w2", "card": 3, "column": "Ready", "lanesRun": "build:failed"},
                  {"wave": "w2", "card": 4, "column": "Ready", "lanesRun": "build:advanced → qa:failed"},
                  {"wave": "w2", "card": 5, "column": "QA", "lanesRun": "none", "finalStatus": "halted"})
        h = self.health(cfg)
        self.assertEqual(h["metrics"]["roundsPerMerge"], 2.67)
        self.assertEqual(h["metrics"]["failuresToday"], 3)
        self.assertEqual(sorted(b["metric"] for b in h["breaches"]), ["factory-failures", "rounds-per-merge"])
        self.assertEqual(h["action"], "pause-new")

    def test_approval_only_review_after_a_human_gate_is_not_a_round(self):
        # funl #1: round 1 bounced, round 2 clean but human-gated, round 3 only re-checked it to merge.
        cfg = self.cfg(stage=2, budget=None)
        self.rows({"wave": "w1", "card": 1, "column": "Ready", "lanesRun": "review:bounced",
                   "score": {"verdict": "rework", "blockers": 1, "round": 1}},
                  {"wave": "w2", "card": 1, "column": "Blocked", "lanesRun": "review:blocked",
                   "score": {"verdict": "clean", "blockers": 0, "round": 2}},
                  {"wave": "w3", "card": 1, "column": "Done", "lanesRun": "review:advanced",
                   "score": {"verdict": "clean", "blockers": 0, "round": 3}})
        h = self.health(cfg)
        self.assertEqual(h["metrics"]["roundsPerMerge"], 2)
        self.assertEqual(h["action"], "continue")

    def test_rounds_per_merge_never_acts_under_three_merges(self):
        cfg = self.cfg(stage=2, budget=None)
        self.rows({"wave": "w1", "card": 1, "column": "Done", "score": {"verdict": "clean", "round": 4}},
                  {"wave": "w1", "card": 2, "column": "Done", "score": {"verdict": "clean", "round": 3}})
        h = self.health(cfg)
        self.assertEqual(h["metrics"]["roundsPerMerge"], 3.5)
        self.assertEqual((h["action"], h["breaches"]), ("continue", []))

    def test_merged_outside_the_lane_counts_as_merged(self):
        self.rows({"wave": "w1", "card": 2, "column": "Review", "lanesRun": "review:blocked", "milestone": "M2"})
        out = json.loads(run("merged", "--card", "2", "--sha", "abc123", "--by", "owner", "--scorecard", str(self.sc)))
        self.assertEqual(out, {"recorded": "merged", "card": 2, "by": "owner"})
        row = json.loads(self.sc.read_text().splitlines()[-1])
        self.assertEqual((row["column"], row["mergedBy"], row["sha"], row["milestone"]), ("Done", "owner", "abc123", "M2"))
        h = self.health(self.cfg(stage=1, budget=None))
        self.assertEqual(h["report"]["merges"], 1)

    def test_warns_when_wave_wrote_no_rows_and_reports_after_ten_merges(self):
        cfg = self.cfg(stage=1, budget=None)
        self.rows(*[{"wave": "w1", "card": n, "column": "Done", "lanesRun": "review:advanced",
                     "tokenSplit": {"input": 1000, "output": 0, "cacheWrite": 0, "cacheRead": 0}} for n in range(10)],
                  {"wave": "w1", "card": 20, "column": "Ready", "lanesRun": "review:bounced", "citation": "AC1"},
                  {"wave": "w1", "card": 21, "column": "Ready", "lanesRun": "review:bounced"})
        out = run("demo", "--accepted", "--scorecard", str(self.sc))
        self.assertIn("demo", out)
        h = self.health(cfg, "--wave", "w9")
        self.assertEqual(h["warnings"], ["wave w9 wrote no scorecard rows"])
        self.assertEqual(h["report"], {"ready": True, "merges": 10, "citedBouncePct": 50,
                                       "tokensPerMerge": 1000, "daysSinceDemo": 0})
        self.assertEqual(h["action"], "continue")  # report-only metrics never act

    def test_digest_shows_goal_merges_health_budget(self):
        cfg = self.cfg(stage=2, budget=100)
        self.rows({"wave": "w1", "card": 7, "column": "Done", "lanesRun": "review:advanced", "usd": 12.5},
                  {"wave": "w1", "card": 9, "column": "Blocked", "finalStatus": "blocked", "lanesRun": "build:blocked"})
        plan = self.tmp / "plan.json"
        plan.write_text(json.dumps({"cards": []}))
        out = run("digest", "--config", str(cfg), "--plan", str(plan), "--scorecard", str(self.sc),
                  "--goal-done", "3", "--goal-total", "5")
        self.assertIn("🎯 M1 · 3/5 done", out)
        self.assertIn("Merged this wave: #7", out)
        self.assertIn("Health: continue", out)
        self.assertIn("rounds/merge", out)
        self.assertIn("Budget: $12.5 of $100", out)
        self.assertIn("Asks: #9", out)

    def test_digest_quiet_without_merge_breach_or_ask_unless_every_wave(self):
        self.rows({"wave": "w1", "card": 7, "column": "QA", "lanesRun": "build:advanced", "usd": 1})
        plan = self.tmp / "plan.json"
        plan.write_text("{}")
        args = ("--plan", str(plan), "--scorecard", str(self.sc))
        self.assertEqual(run("digest", "--config", str(self.cfg()), *args), "")
        self.assertIn("Health: continue", run("digest", "--config", str(self.cfg(digest="every-wave")), *args))

    def test_digest_budget_breach_is_an_ask(self):
        cfg = self.cfg(stage=2, budget=10)
        self.rows({"wave": "w1", "card": 7, "column": "QA", "lanesRun": "build:advanced", "usd": 9})
        self.health(cfg)
        plan = self.tmp / "plan.json"
        plan.write_text("{}")
        out = run("digest", "--config", str(cfg), "--plan", str(plan), "--scorecard", str(self.sc))
        self.assertIn("Health: stop-ask", out)
        self.assertIn("budget-burn", run("health", "--config", str(cfg), "--scorecard", str(self.sc)))
        self.assertIn("Asks: budget", out)

    # ── factory #106: AI exam scores ──
    def test_exam_records_an_event_row_skipped_by_card_reads(self):
        out = json.loads(run("exam", "--card", "12", "--score", "7", "--total", "10", "--pass-mark", "8",
                             "--model", "claude-sonnet-4-5", "--milestone", "M1", "--scorecard", str(self.sc)))
        self.assertEqual(out, {"recorded": "exam", "card": 12, "passed": False})
        row = json.loads(self.sc.read_text())
        self.assertEqual({k: row[k] for k in ("event", "card", "score", "total", "pass_mark", "model", "milestone")},
                         {"event": "exam", "card": 12, "score": 7, "total": 10, "pass_mark": 8,
                          "model": "claude-sonnet-4-5", "milestone": "M1"})
        self.assertIn("no scorecard rows yet", run("summary", "--scorecard", str(self.sc)))

    def test_exam_refuses_the_fake_model_and_bad_numbers(self):
        for args in (["--model", "fake"], ["--model", "mock-llm"], ["--model", "claude-sonnet-4-5", "--score", "11"],
                     ["--model", "claude-sonnet-4-5", "--pass-mark", "0"]):
            base = {"--card": "1", "--score": "9", "--total": "10", "--pass-mark": "8"}
            for i in range(0, len(args), 2):
                base[args[i]] = args[i + 1]
            flat = [x for kv in base.items() for x in kv]
            r = subprocess.run([sys.executable, str(SCRIPT), "exam", *flat, "--scorecard", str(self.sc)],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 64, args)
        self.assertFalse(self.sc.exists())

    # ── factory #108: screen match and the agent walk ──
    def _rc(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args, "--scorecard", str(self.sc)],
                              capture_output=True, text=True).returncode

    def test_screen_records_one_verdict(self):
        out = json.loads(run("screen", "--card", "13", "--screen", "screen-pipeline", "--failed",
                             "--milestone", "M1", "--scorecard", str(self.sc)))
        self.assertEqual(out, {"recorded": "screen", "card": 13, "passed": False})
        row = json.loads(self.sc.read_text())
        self.assertEqual((row["event"], row["screen"], row["passed"]), ("screen", "screen-pipeline", False))
        self.assertEqual(self._rc("screen", "--card", "1", "--screen", "screen-a"), 64)  # neither flag
        self.assertEqual(self._rc("screen", "--card", "1", "--screen", "pipeline", "--passed"), 64)
        self.assertIn("no scorecard rows yet", run("summary", "--scorecard", str(self.sc)))

    def test_walk_needs_a_screenshot_per_screen(self):
        shots = self.tmp / "2026-11-12-walk"
        shots.mkdir()
        (shots / "screen-today.png").write_bytes(b"png")
        args = ["walk", "--screens", "2", "--passed", "2", "--questions", "3", "--answered", "3",
                "--shots", str(shots)]
        self.assertEqual(self._rc(*args), 64)
        (shots / "screen-pipeline.png").write_bytes(b"png")
        out = json.loads(run(*args, "--model", "claude-sonnet-4-5", "--scorecard", str(self.sc)))
        self.assertEqual(out, {"recorded": "walk", "passed": True})
        row = json.loads(self.sc.read_text())
        self.assertEqual((row["event"], row["ok"], row["screens"], row["answered"]), ("walk", True, 2, 3))

    def test_walk_failure_needs_findings_and_acceptance_needs_a_note(self):
        shots = self.tmp / "walk"
        shots.mkdir()
        (shots / "a.png").write_bytes(b"png")
        base = ["walk", "--screens", "1", "--passed", "0", "--questions", "2", "--answered", "2", "--shots", str(shots)]
        self.assertEqual(self._rc(*base), 64)
        findings = self.tmp / "findings.md"
        findings.write_text("- screen-today: no snooze\n")
        self.assertEqual(self._rc(*base, "--findings", str(findings)), 0)
        self.assertEqual(self._rc("walk", "--screens", "1", "--passed", "2", "--questions", "0", "--answered", "0",
                                  "--shots", str(shots)), 64)
        self.assertEqual(self._rc("walk", "--accepted"), 64)
        self.assertEqual(self._rc("walk", "--accepted", "--note", "snooze is M2"), 0)
        events = [json.loads(x)["event"] for x in self.sc.read_text().splitlines()]
        self.assertEqual(events, ["walk", "walk-accept"])


if __name__ == "__main__":
    unittest.main()
