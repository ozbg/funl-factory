# The agent walk — milestone end

Every card can pass and the app can still miss. The walk is the check a user would make: an agent
uses the real running app, every screen, with the app's real AI settings, before the milestone
closes.

## When it runs

The orchestrator runs it, once per run, when all of these hold (`run-workflow.md` → wave loop
step 2):

- `super-board-coverage.py status --json --milestone <goal.milestone>` says every listed card
  and the Demo card are Done (`demo_done` and `cards_done == cards_total`)
- its `walk` is `not run` or `failed`
- no card on the goal is left in Ready, Building, QA or Review

A failed walk's findings go through triage, like every collect finding: a clear fix goes to Ready,
the rest to Backlog as proposals. When the fixes on the goal merge, the next run walks again.

## Who walks

One Agent task, model **Sonnet** (never Haiku: judging whether an app is useful and looks right
needs more). It loads this file and `../../super-qa/references/screen-match.md`. It works in its
own worktree, `.claude/worktrees/walk-<date>/`, cut from the latest base branch. It never edits app
code, and never moves a card.

## Inputs

| Input | From |
|---|---|
| Screens | every `#screen-<name>` anchor in `docs/shape/mockup.html` (the same tokens `super-board-coverage.py cards` reads), minus screens coverage.md's `Cut from mock-up:` list cuts whole |
| Baseline per screen | `docs/shape/baseline/screen-<name>.png` on the base branch, else the mock-up anchor (screen-match.md → "The baseline") |
| What a user does there | the must-haves in `docs/shape/north-star.md` whose cards build that screen (coverage.md rows), and the core loop |
| Day-one questions | every `- M<n>: <question> → <good answer>` line under `## Day-one questions` in north-star.md |
| Exams | every exam card in coverage.md's `Exams:` line, with its command and pass mark from its `## Exam` section |

No mock-up: the screens are the app's routes from spec.md, and every screen is judged on the
rubric alone.

## Setup

- a. Start the app the way QA does, on its seed or demo data, with the real AI settings the app
  is configured for. Never the fake or mock model.
- b. Check key names only: `bash .claude/bin/super-board-env-check.sh`. Never read `.env`.
- c. No key for the real model: stop. The walk is not run; the orchestrator posts one `needs-you`
  item (`blocked-by: model key`).
- d. Make the run folder `docs/super-board/runs/<date>-walk/` in the main checkout.

## The rubric

**Each screen.** Pass only when every line holds; a fail names the line.

- a. **Opens.** It loads with no console error and no blank or broken state.
- b. **Looks right.** Screenshot it at 1280×800 (`runtime_browser.mjs --shot`, as screen-match.md
  → "Capture"), save `<run folder>/screen-<name>.png`, and compare it with its baseline. List the
  differences the same way. A difference not under `Cut from mock-up:` and not accepted on a card
  fails.
- c. **Does the job.** Try each thing its must-haves say a user does there, through the UI: click,
  type, submit. The result must be what the must-have's good result says.
- d. **States.** Empty, loading and error states exist where the screen has data.
- e. **Reads well.** Copy is plain, errors say what happened in one line, no placeholder text.

**Each day-one question.** Ask it, or do it, through the real UI, never a direct API call. It
passes when the answer or result holds the good answer's facts and would satisfy the owner. Save
the screen after the answer as `<run folder>/q<n>.png`.

**Each exam card.** Run its exam command on the real model and record it with
`super-board-scorecard.py exam` (lanes/qa.md → "Exam cards"). The model key is missing, or the
command can't run: read its latest recorded score instead, and say so. A score under its pass
mark is a finding.

## Findings

Write `<run folder>/findings.md`: one table row per screen, question and exam.

```
| # | What | Result | Reason | Shot | Card |
|---|---|---|---|---|---|
| S1 | screen-pipeline | ❌ | b: stage headers 14 px, mock-up 12 px capitals | screen-pipeline.png | #61 |
| S2 | screen-today | ✅ | | screen-today.png | |
| Q1 | M2: who do I call first today? | ❌ | listed prospects, not ranked by follow-up date | q1.png | #62 |
| E1 | exam #18 | ✅ | 9/10, pass mark 8, claude-sonnet-4-5 | | |
```

Every ❌ goes through collect's triage, then the collect filer, as one card. The walk saw it
fail, so its verdict is `file`.

- a. Write one finding per ❌ into `<run folder>/triage.json`, with the triage fields
  (`../../super-collect/SKILL.md` § Triage): `track`, `decision`, `breaks` (the rubric line plus
  the mock-up anchor, must-have or day-one question it breaks), `screens`, `touches`, `zone`,
  `recommendation`.
- b. Run the rules in code:
  `python3 .claude/skills/super-collect/scripts/collect_handoff.py triage --findings <run folder>/triage.json --config <cfg>`.
- c. File each with its final `track` and `decision`. A fix lands in Ready, a proposal in Backlog:

```bash
.claude/skills/super-collect/scripts/super-collect-file.sh --config <cfg> --type bug \
  --source walk --title "<one line>" --body-file <md> \
  --fingerprint "walk|screen-<name>|<key>" --track <track> --decision <decision> --yes
```

- d. Put each fix card on the goal, so the next walk waits for it:
  `gh issue edit <n> --milestone <goal.milestone>`.

- `--type bug` when a must-have, an AC or the mock-up says it should work; `--type feature` when
  nothing on the board covers it.
- The body is the ticket format (writing-standard.md § 3), plus the lines its decision needs
  (`Breaks:` and `Failing test:` for a bug fix, `## Before and after` for a tweak,
  `## Recommendation` for a proposal). Context names the screen or question,
  the rubric line, the must-have, and embeds the shot as a path in the run folder. A bug adds the
  Evidence table.
- Fingerprint `walk|screen-<name>|<key>` for a screen, `walk|M<n>|<key>` for a question, so a
  second walk finds the same card and adds "Seen again" instead of a copy.
- Put the card number in the findings row.

## Record

```bash
python3 .claude/bin/super-board-scorecard.py walk --screens <n> --passed <n> \
  --questions <n> --answered <n> --shots docs/super-board/runs/<date>-walk/ \
  --findings docs/super-board/runs/<date>-walk/findings.md --model <id> --milestone <goal.milestone>
```

The command refuses a run folder with fewer screenshots than screens, and a failure with no
findings file. The walk passes when every screen and question passes and every exam is at its
pass mark. The agent returns one line: `walk: screens <p>/<n> · questions <a>/<q> · exams <e>/<x> ·
<k> findings filed`.

## After the walk

- **Passed.** `super-board status` and `report` show the milestone done. The orchestrator commits
  the run folder with the run manifest and reports `🎯 <title> reached`.
- **Failed.** The milestone stays not done. The orchestrator commits the run folder and posts one
  `needs-you` item on the Demo card: the findings table, with each card's triage decision, and two
  choices. Build them (the fixes are in Ready already; accept the proposals onto the goal, and the
  next run builds them, then walks again), or accept them as they are.
- **Accepted.** On the owner's word only, never the agent's:
  `super-board-scorecard.py walk --accepted --note "<the owner's reason>" --milestone <goal.milestone>`.
  The finding cards stay in Backlog for later.
