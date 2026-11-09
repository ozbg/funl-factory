"""Offline tests for scripts/super-board-scorecard.py (factory #25)."""
import json
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


if __name__ == "__main__":
    unittest.main()
