# /super-qa

The Tester: proves a card's acceptance criteria with tests and evidence, or sends it back to Build with a precise failure.

## What It Does

- **Checks by zone** (`docs/agents/zones.yaml`). Green skips QA. Amber maps each AC to a test and checks the zone's bar and the ticket's own edge cases. Red adds a test per touched invariant and one mutation per guarded line. Accepted limits are never checked.
- **No citation, no bounce.** A fail cites an AC, an invariant, a bar line or a reproducible bug. Anything else is a note. After `max_rounds` fails the card goes to Blocked for a ruling or a split.
- **Keeps evidence local**: screenshots, logs and HARs go to `.claude/super-board/evidence/<issue>/`, gitignored. The PR gets an AC table as text and 0 evidence lines.
- **Runs `pr-security-review`** on red cards and amber cards on a boundary. For a whole-repo audit it points you at `security-audit`.
- **Files what it finds** off-ticket as `source:qa` Backlog cards instead of failing the card for them.

## When To Use It

- Inside a super-board run (the QA lane). This is the normal path.
- Standalone, as `/super-qa`, to bug-bash an app: a browser crawl from `docs/super-qa/queue.md` that grows a Playwright suite and files fix-ready issues.

## Standalone flags

| Command | Does |
|---|---|
| `/super-qa` | 10 iterations |
| `/super-qa 5` | 5 iterations |
| `/super-qa --resume` | Continue from the last iteration |
| `/super-qa --continue-on-error` | Don't halt on one failed iteration |

## Install

Part of the super-board pack: `./install.sh /path/to/project`. Run it against staging, not production. Lane details: `skills/super-board/references/lanes/qa.md` → Tester.
