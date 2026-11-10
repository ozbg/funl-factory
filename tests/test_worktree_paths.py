#!/usr/bin/env python3
"""Worker prompt -> guard -> Git -> cleanup contract. No live workers or GitHub."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

PACK = Path(__file__).resolve().parents[1]


class WorktreePaths(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve() / "repo"
        self.root.mkdir()
        self.env = dict(os.environ, GIT_AUTHOR_NAME="test", GIT_AUTHOR_EMAIL="test@example.com",
                        GIT_COMMITTER_NAME="test", GIT_COMMITTER_EMAIL="test@example.com",
                        CLEANUP_WT_GH="/nonexistent")
        self.run_cmd("git", "init", "-q", "-b", "main")
        (self.root / ".gitignore").write_text(".claude/worktrees/\n.worktrees/\n.planning/\n")
        self.run_cmd("git", "add", ".gitignore")
        self.run_cmd("git", "commit", "-qm", "fixture")
        # The recovery lookup uses ls-remote; keep it on this local fixture.
        self.run_cmd("git", "remote", "add", "origin", str(self.root))

    def run_cmd(self, *cmd, cwd=None, input=None, check=True):
        return subprocess.run(cmd, cwd=cwd or self.root, env=self.env, input=input,
                              text=True, capture_output=True, check=check)

    def test_generated_lane_paths_pass_guard_and_are_cleaned(self):
        # Execute the workflow with a stub agent and inspect its real lane prompts.
        js = r"""
const fs = require('fs')
const src = fs.readFileSync(process.argv[1], 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor, prompts = {}
const agent = async (prompt, opts) => {
  if (opts.label.startsWith('preflight')) return { verdicts: [{ number: 7, verdict: 'proceed' }] }
  if (opts.label.startsWith('classify')) return { kind: 'feature', complexity: 'low' }
  prompts[opts.label] = prompt
  return { status: 'advanced', column: 'next' }
}
const pipeline = async (items, ...stages) => Promise.all(items.map(async item => {
  let value = item
  for (const stage of stages) value = await stage(value, item)
  return value
}))
new AsyncFunction('args','agent','pipeline','log',src)(
  {configPath:'fixture.json',cards:[{number:7,status:'Ready',title:'fixture'}]},
  agent,pipeline,()=>{}).then(()=>console.log(JSON.stringify(prompts)))
"""
        prompts = json.loads(self.run_cmd("node", "-e", js,
                                          str(PACK / "workflows/super-board-wave.js")).stdout)
        for lane in ("build", "qa", "review"):
            with self.subTest(lane=lane):
                match = re.search(r"create your own worktree under ([^, ]+)", prompts[lane + ":#7"])
                self.assertIsNotNone(match, "lane must prescribe its worktree location")
                path = match[1].rstrip("/") + "/issue-7-" + lane
                command = "git worktree add -b issue-7-" + lane + " " + shlex.quote(path) + " main"
                payload = json.dumps({"tool_name": "Bash", "cwd": str(self.root),
                                      "tool_input": {"command": command}})
                verdict = self.run_cmd("python3", str(PACK / "hooks/guard-worktree-path.py"),
                                       input=payload).stdout
                self.assertEqual(verdict, "", "the installed guard must allow the lane's command")
                self.run_cmd(*shlex.split(command))
                for meta in (self.root / ".git/worktrees").iterdir():
                    for name in ("gitdir", "commondir"):
                        os.utime(meta / name, (1577836800, 1577836800))
                self.run_cmd("python3", str(PACK / "hooks/cleanup-wt.py"), "--post-merge",
                             "--no-fetch", "--base", "main", input="")
                self.assertFalse((self.root / path).exists(), "cleanup must see the lane's worktree")


if __name__ == "__main__":
    unittest.main()
