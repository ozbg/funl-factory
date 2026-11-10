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
| Build | scorecard records (`docs/super-board/runs/scorecard.jsonl`): days from first card started to last merged, merged/total, first pass, rework, rounds per merge, k tokens and minutes per card. Models by rule counts `modelRules` on records; `n/a` when absent |
| Cost | API-equivalent USD from the records, against `goal.budget_usd` |
| Done | `super-board-coverage.py status --json`: done/total per must-have, demo state. Board state is the Done cards in the scorecard, or `--board-json <file>` (`[{number, status}]`) |

Any input that is missing prints `n/a` on its line. Nothing crashes.

## Targets

Config `targets` over these defaults (onboard writes them):

| Key | Default | Pass when |
|---|---|---|
| `days_per_app` | 2 | days ≤ target |
| `first_pass_pct` | 70 | first pass ≥ target |
| `rework_pct` | 10 | rework ≤ target |
| `rounds_per_merge` | 1.5 | rounds ≤ target |
| `demo_first_try` | true | demo card passed on round 1 |

Each prints ✅ or ❌ with its value against the target. A target with no data prints `n/a`.

## Next

One to three plain lines from breached targets, for example `sharpen tickets: most bounces cite ticket`
when the records' cause data says tickets, else a generic line.

## `--log` and `--compare`

`--log` appends exactly one JSON line to `<repo>/docs/super-board/factory-log.jsonl`:
`{date, app, milestone, days, merged, total, first_pass_pct, rework_pct, rounds_per_merge, usd,
budget_usd, demo_passed, postcard, targets_met}`. Unknown values are `null`.

`--compare` prints that file as a table, one row per line, so app 2 sits beside app 1.
