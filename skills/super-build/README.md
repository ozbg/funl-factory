# /super-build

The Builder: turns a `Ready` card into a branch, the smallest safe change, tests and a draft PR.

## What It Does

- **Works in its own git worktree** on `issue-<N>-<slug>`, and picks up an existing branch if a stopped run left one.
- **Tests by zone tier** (`super-board-zone.py`): green gets one test per AC, amber proves every AC, red adds the zone's invariants and edge cases plus a `code-review` self-pass. An unplaced file is amber.
- **Slices of 200–600 source lines.** Tests don't count toward the size cap; a big PR gets a deeper review, the owner only if red.
- **Simplest solution first**: runs `ponytail:ponytail` before the first line of code, or an inline ladder when the plugin is absent. Validation, security, data-loss protection and accessibility are never cut.
- **Reads official docs first** when a card touches a third-party API or SDK, an upgrade, or auth/billing, and lists them as `Docs:` bullets in the PR's Solution block.
- **On a rebuild** it fixes every `[builder]` review thread and the Tester's latest failure, and fixes the code, not just the thread.
- **Never merges.** Merging belongs to the Reviewer and the merge gate.

## When To Use It

- Inside a super-board run (the Building lane). This is the normal path.
- Standalone, as `/super-build` on one card you name. The headless `claude -p` dispatcher is gone; drain a board with `/super-board run`.

## Install

Part of the super-board pack: `./install.sh /path/to/project`. Lane details: `skills/super-board/references/lanes/build.md` → Builder.
