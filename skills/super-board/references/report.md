# `super-board report` — one page per milestone

Read-only, except `--log`, which appends one line to the app's factory log. Run it at the end of a
milestone and on demand. It adds no new measurements: every number is already recorded.

```bash
python3 .claude/bin/super-board-scorecard.py report --config <config> [--repo-path <app>] [--log] [--compare] [--json]
```

Print the stdout as is. Do not rewrite it.

## Where the numbers come from

| Line | Source |
|---|---|
| Define | last line of `docs/shape/north-star-log.jsonl` (minutes, questions, blind match); the `Mock-up:` line under `Signed:` in `docs/shape/north-star.md` |
| Build | scorecard records (`docs/super-board/runs/scorecard.jsonl`): days from first card started to last merged, merged/total, first pass, rework, rounds per merge, k tokens and minutes per card. Merged/total comes from `--board-json` when given. A review that only re-checks an approved, unchanged head (after a human gate) is not a round. Models by rule counts `modelRules` on records; `n/a` when absent |
| Cost | API-equivalent USD from the records, against `goal.budget_usd` |
| Done | `super-board-coverage.py status --json`: done/total per must-have, demo state, and whether the milestone is done (cards, demo and the agent walk; `walk.md`). Board state is the Done cards in the scorecard, or `--board-json <file>` (`[{number, status}]`) |
| AI exams | `exam` rows in the scorecard, written by QA (`super-board-scorecard.py exam --card N --score S --total T --pass-mark P --model <id>`). The latest run per card counts: score, pass mark, model |
| Screens match | `screen` rows in the scorecard, written by QA's screen match (`lanes/qa.md` step 7b: `super-board-scorecard.py screen --card N --screen screen-<name> --passed\|--failed`). The latest per card counts, out of the screen cards QA recorded |
| Walk pass | the latest `walk` row, written by the agent walk (`walk.md`): screens and day-one questions passed, out of those walked and asked. A later `walk-accept` row adds `findings accepted` |
| Mock-up cuts | the features in coverage.md's `Cut from mock-up:` list, counted by `super-board-coverage.py status` |

Any input that is missing prints `n/a` on its line. Nothing crashes.

When the owner or orchestrator merges a card outside the lane, record it so the count stays right:
`super-board-scorecard.py merged --card N --sha <merge sha> --by owner|orchestrator`.

## Targets

Config `targets` over these defaults (onboard writes them):

| Key | Default | Pass when |
|---|---|---|
| `days_per_app` | 2 | days ≤ target |
| `first_pass_pct` | 70 | first pass ≥ target |
| `rework_pct` | 10 | rework ≤ target |
| `rounds_per_merge` | 1.5 | rounds ≤ target |
| `demo_first_try` | true | demo card passed on round 1 |
| `exam_pass` | true | every exam card's latest score is at or above its pass mark |
| `screens_match` | 100 | percent of screen cards whose latest screen match passed ≥ target |
| `walk_pass` | 100 | the walk's pass rate (screens plus questions) ≥ target |

Each prints ✅ or ❌ with its value against the target. A target with no data prints `n/a`.
`mock-up cuts` prints its count with `ℹ` and no target: a cut is a choice, not a miss.

`walk_pass` grades the walk. The milestone gate is stricter: the Done line says `milestone done`
only when the walk passed every screen, question and exam, or the owner accepted its findings.

## Next

One to three plain lines from breached targets, for example `sharpen tickets: most bounces cite ticket`
when the records' cause data says tickets, else a generic line. A missed `walk_pass` says to work the
walk's findings; a Done demo with no walk says to run it; a missed `screens_match` says to give each
screen card its mock-up block and fail QA on every unlisted difference.

## Retro

When the milestone closes, the orchestrator fills the retro from this report: [`retro.md`](retro.md).
Its Product quality section carries screens match, exam scores, walk findings and the defects the
owner finds after.

## `--log` and `--compare`

`--log` appends exactly one JSON line to `<repo>/docs/super-board/factory-log.jsonl`:
`{date, app, milestone, days, merged, total, first_pass_pct, rework_pct, rounds_per_merge, usd,
budget_usd, demo_passed, postcard, targets_met, exams, screens_match_pct, walk_pass_pct, mockup_cuts}`.
Unknown values are `null`.

`--compare` prints that file as a table, one row per line, so app 2 sits beside app 1.
