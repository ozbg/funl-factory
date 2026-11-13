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

The walk finds things. It never decides what the milestone carries. Every finding files to
Backlog with the `scope:pending` label, and the scope judge ([`scope-judge.md`](scope-judge.md))
decides each one: `gate`, `next` or `drop`. Only an admitted gate joins the goal
(`super-board-scope.sh admit`). When those merge, the next run walks again.

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

**Each screen.** Every line is checked, and a miss names its line. Only a and c gate the
milestone; a miss on b, d or e is a finding, and the screen still passes.

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

**What gates the milestone.** Only these fail the walk:

- a day-one question whose answer lacks a fact its good answer names
- rubric a or c on a screen: it doesn't open, or it can't do its job
- an exam below its pass mark

Looks, states and "reads well" (b, d, e) never fail the walk. They file as `scope:pending` like
every other finding, and the judge usually says `next`. The one exception is the judge's: a
safety signal that is wrong on most answers is broken, and it gates (scope-judge.md, #181).

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

Every ❌ files as one card, to Backlog, with the `scope:pending` label. The walk never puts a
card on the goal, and never into Ready: the collect filer refuses `--milestone <goal>` for a card
the scope judge has not admitted (exit 67).

```bash
.claude/skills/super-collect/scripts/super-collect-file.sh --config <cfg> --type bug \
  --source walk --title "<one line>" --body-file <md> \
  --fingerprint "walk|screen-<name>|<key>" --yes
```

`--source walk` adds `scope:pending` itself. Write in Context which rubric line or day-one question
it breaks, and whether it gates the walk. The judge reads that line, not your verdict.

- `--type bug` when a must-have, an AC or the mock-up says it should work; `--type feature` when
  nothing on the board covers it.
- The body is the ticket format (writing-standard.md § 3), with a `Breaks:` line naming the
  rubric line, day-one question or exam. Context names the screen or question,
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
- **Failed.** The milestone stays not done. The orchestrator commits the run folder. The next wave's
  scope judge decides each finding, and the admitted gates are built; then the run walks again.
- **Two failed walks on one goal.** The findings still open go to the owner as one `needs-you`
  item on the Demo card: the findings table, with each card's judge verdict, and two choices.
  Build them (the owner admits them with their own words), or accept them as they are. No third
  walk starts until the owner answers.
- **Accepted.** On the owner's word only, never the agent's:
  `super-board-scorecard.py walk --accepted --note "<the owner's reason>" --milestone <goal.milestone>`.
  The finding cards stay in Backlog for later.
