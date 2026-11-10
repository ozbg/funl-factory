"""Configuration readiness at the real preflight interfaces; no network or apps."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/super-board-verification-ready.py"


class VerificationReadiness(unittest.TestCase):
    def test_unusable_configuration_stops_before_dispatch(self):
        for commands in (None, [], ["", " \t\n"], ["\x00"], ["make\x00 check"], "npm test", [None], [123]):
            with self.subTest(commands=commands), tempfile.TemporaryDirectory() as tmp:
                path = pathlib.Path(tmp) / "config.json"
                config = {"worker_backend": "claude-p", "verify_commands": commands}
                path.write_text(json.dumps(config))
                result = subprocess.run(["python3", str(CHECK), "--config", str(path)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 9)
                self.assertIn("verify_commands", result.stderr)
                self.assertIn("verification-readiness", result.stderr)
                # Planner must reject before it reads the supplied (nonexistent) items.
                result = subprocess.run(["bash", str(ROOT / "scripts/super-board-wave-plan.sh"),
                                         "--config", str(path), "--items", str(path.parent / "absent")],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 9, result.stderr)

    def test_configured_project_commands_are_accepted_without_running_them(self):
        result = subprocess.run(["python3", str(CHECK), "--config", "-"],
                                input=json.dumps({"verify_commands": ["", " \t", "make check"]}),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_setup_reports_configuration_error_without_inventing_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            cfg = root / ".claude/super-board/configs/app.json"
            cfg.parent.mkdir(parents=True)
            cfg.write_text(json.dumps({"verify_commands": [" "]}))
            command = ["python3", str(ROOT / "scripts/super-board-setup.py"),
                       "check", "--root", str(root), "--pack", str(ROOT)]
            result = subprocess.run(command, capture_output=True, text=True)
            report = json.loads(result.stdout)
            self.assertFalse(report["green"])
            self.assertIn("verify_commands", report["verification"][str(cfg.relative_to(root))])
            text = subprocess.run(command + ["--text"], capture_output=True, text=True)
            self.assertIn("verification-readiness", text.stdout)
            self.assertEqual(json.loads(cfg.read_text())["verify_commands"], [" "])


if __name__ == "__main__":
    unittest.main()
