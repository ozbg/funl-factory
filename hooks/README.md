# super-board guard hooks

Claude Code hook scripts. Python 3 standard library only (no jq, no node). Each reads the
hook JSON on stdin, prints a decision only when it blocks, and exits 0 on its own errors
so a broken guard never stops unrelated work (and a broken decider never approves anything). All of the below are on by default except the
protected-push guard (opt-in) and the dev-only skill-eval gate.

- `guard-worktree-path.py` — PreToolUse `Bash`: denies `git worktree add|move` whose target resolves outside `<repo>/.claude/worktrees/` (honours `cd X &&`, `git -C X`).
- `guard-secrets.py` — PreToolUse `Bash|Read|Grep`: denies reading or piping dotenv files, SSH keys, `.npmrc`, `credentials(.json)`, service-account JSON and `.pem`; `.env.example` stays readable. One plain call to `super-board-env-check.sh KEY…` is allowed: it prints present / empty / missing per key and never a value (no pipe, chain or redirect may ride along).
- `guard-key-literals.py` — PreToolUse `Edit|MultiEdit|Write|NotebookEdit|Bash`: denies writing a live-looking API key into a file; PostToolUse `Edit|MultiEdit|Write|NotebookEdit`: flags one already on disk. Reports line numbers, never the value.
- `guard-delete-outside.py` — PreToolUse `Bash`: denies `rm`, `rmdir`, `unlink`, `find … -delete` / `-exec rm` and `git clean` whose target resolves outside `$CLAUDE_PROJECT_DIR`, and always `/` or `~` itself (honours `cd X &&`, `git -C X`, `~`, `$HOME`). Inside `/tmp`, `/private/tmp`, `/var/folders` and `$TMPDIR` stays allowed. A path whose value is only known at run time (`$(…)`, a variable set earlier in the same command) is allowed.
- `permission-decider.py` — PreToolUse `Bash|Edit|MultiEdit|Write|NotebookEdit`: the one hook that **allows**, so a wave runs in Accept edits with no prompt (#131). It splits a command on `&&`, `||`, `;`, `|` and newlines (a leading `cd <dir in the project>` included) and allows it only when every segment is on its known-safe list: read-only tools on project paths, `sed -n` print-only scripts, `find` with no action, git reads anywhere in the project and git writes inside `.claude/worktrees/` (never a push to `main`, `master` or a configured base), the lanes' `gh` calls on the board's own repo, the project's test runners, `curl` to localhost, and `.claude/bin` / `.claude/hooks` scripts however invoked (`bash x`, `./x`, `x`, absolute path) but only the **main checkout's** copy. It denies: a direct merge in any spelling (`gh pr merge`, `gh api …/pulls/N/merge`, `mergePullRequest` / `enablePullRequestAutoMerge`, inside `bash -c` or an alias too; merges go through `super-board-merge-gate.sh` only); a worktree copy of a `.claude/bin` script (a builder could have edited it), naming the main copy to run instead; inline code from a lane (`python3 -c`, `python3 - <<EOF`, `node -e`), naming the allowed way; a lane's Edit/Write to `.claude/{bin,hooks,workflows}`, `.agents/{bin,hooks,workflows}` or `.claude/settings*.json` in any checkout. Anything else prints nothing, so Claude Code's own rules and mode decide as before. Another hook's deny, and settings deny/ask rules, still win over its allow. The snippet also adds `permissions.deny` lines for a direct merge, so the gate holds even if a hook is off.
- `cleanup-wt.py` — SessionStart (`--auto`): when a base branch tip moved since the last session, removes worktrees and local branches already merged into it. The merge gate also runs it with `--post-merge` after every merge. Never deletes unmerged work (a dirty worktree on a merged branch is wip-committed and its branch kept), never touches bases or the worktree it runs in, and writes a recovery TSV to `<git-common-dir>/cleanup-wt/<timestamp>.tsv` before acting. Restore with `git branch <name> <sha>`. A manual dry run (`python3 .claude/hooks/cleanup-wt.py`, then `--apply`) still works.

## Enable

`install.sh` does this for you: it copies the scripts to `.claude/hooks/` in the target
project and merges the block below (kept in `settings-snippet.json`) into
`.claude/settings.json`, backing the file up first and never adding a command twice.
`./install.sh --no-hooks` skips both (and with it the merge gate's post-merge cleanup, which needs `cleanup-wt.py`). By hand, copy the scripts and merge this:

```json
{
  "permissions": {
    "deny": [
      "Bash(gh pr merge *)",
      "Bash(gh api *pulls/*/merge*)",
      "Bash(gh api graphql *mergePullRequest*)",
      "Bash(gh api graphql *enablePullRequestAutoMerge*)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-worktree-path.py"
          },
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-delete-outside.py"
          }
        ]
      },
      {
        "matcher": "Bash|Read|Grep",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-secrets.py"
          }
        ]
      },
      {
        "matcher": "Edit|MultiEdit|Write|NotebookEdit|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-key-literals.py"
          }
        ]
      },
      {
        "matcher": "Bash|Edit|MultiEdit|Write|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/permission-decider.py"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|MultiEdit|Write|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-key-literals.py"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "cd \"$CLAUDE_PROJECT_DIR\" && python3 .claude/hooks/cleanup-wt.py --auto --fetch 2>/dev/null || true"
          }
        ]
      }
    ]
  }
}
```

## Opt-in: block pushes to the base branch

`guard-protected-push.py` — PreToolUse `Bash`: denies a `git push` that would update or delete
`main`, `master`, any `base_branch` in `.claude/super-board/configs/*.json`, or a name in
`SB_PROTECTED_BRANCHES` (comma-separated). That covers force pushes (`-f`, `--force`,
`--force-with-lease`, `+ref`), explicit refspecs (`feat:main`, `HEAD:refs/heads/main`), `--delete`,
`--all` / `--mirror`, and a bare `git push` while the base is checked out. Force pushes to feature
branches stay allowed: the rebase pass needs them. `SB_ALLOW_PROTECTED_PUSH=1` turns it off for a
session.

It is installed but not wired by default: a brand-new repo often pushes its first commits straight
to `main`. `super-board onboard` asks once ("Block direct/force pushes to main? Recommended for
existing apps; skip for brand-new repos"), and `./install.sh --protect-main` wires it. After a
`--no-hooks` install, onboard does not wire a script that is not there; it names
`./install.sh --no-hooks --protect-main <dir>`, which installs this one guard alone. Either way the
entry is `settings-protect-main.json`:

```
{ "matcher": "Bash", "hooks": [ { "type": "command",
  "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-protected-push.py" } ] }
```

## For repos that author skills: `dev/gate-skill-evals.py`

A Stop hook for this pack and for EricOS, **never installed into a target project** (`install.sh`
copies `hooks/*.py` only). When a skill changed this session — uncommitted, untracked, or committed
but not pushed — and no `claude plugin eval` result is newer than the change, it blocks the stop and
names the command to run. A changed `SKILL.md` always counts; a changed reference, script or the
plugin's `workflows/<skill>*.js` counts only when the skill has an eval case. Cases are found per
skill (`<skill>/evals/`) or per plugin (`evals/<case>/case.yaml` whose `tags` or `name` has the
skill); results are the newest file under the matching `evals/results/`. A changed `SKILL.md` with
no case only warns. A running `plugin eval`, `stop_hook_active`, `SKILL_EVAL_GATE=off` and globs in
`.claude/eval-gate-ignore` all stand it down.

Why Stop and not pre-commit: the point is to make the agent run the eval while it still has the
context to read the result. A pre-commit gate fires later, in whoever commits (a human, `git-sync`,
another agent), and cannot run a paid eval itself, so it gets bypassed with `--no-verify`. The Stop
hook still covers commits made during the session, via the unpushed-commits check.

Wired in this pack's `.claude/settings.json`. For EricOS, add to its `.claude/settings.json`:

```
"Stop": [ { "hooks": [ { "type": "command", "timeout": 30,
  "command": "python3 \"$CLAUDE_PROJECT_DIR\"/_skills/vendor/super-board/hooks/dev/gate-skill-evals.py" } ] } ]
```

Adapted from `gate-skill-evals.sh` in Eric Tech's ai-builder-starter-kit.

Tests: `tests/test-guard-hooks.sh` (all guards and the eval gate), `tests/test_decider.py` (the decider and a simulated 3-card wave), `tests/test-cleanup-wt.sh`.

## Credit

- `cleanup-wt.py` — ported from the `cleanup-wt` skill in Eric Tech's BookKeepingApp (Node), generalised.
- `guard-worktree-path.py` — ported from `.claude/hooks/guard-worktree-path.js` in Eric
  Tech's BookKeepingApp.
- `guard-secrets.py`, `guard-key-literals.py` — ported from `.agents/hooks/` in Eric
  Tech's [ai-builder-starter-kit](https://github.com/EricTechPro/ai-builder-starter-kit)
  (same author as this pack; the kit has no top-level licence file, and this pack is MIT).
