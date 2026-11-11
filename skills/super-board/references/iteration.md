# Iteration — the three tracks after v1

Once the first milestone ships, every change takes one of three tracks. `/super-collect`'s
triage step picks the track and decides fix or propose (`../../super-collect/SKILL.md` §
Triage). The owner's guide says the same in `docs/help.html#iterate`.

## The tracks

| Track | What it is | What it goes through | Owner |
|---|---|---|---|
| **bug** | The app differs from the spec, a rule (`I1`…) or the baseline screen | Triage reproduces it and writes a card with a test that fails now. Build, QA, review, like any card. | Nothing: the spec already decided what's right |
| **tweak** | One screen's look, copy or behaviour, with no contract or data-model change | A card with before and after. QA's proof is the new screen beside the baseline; the baseline updates on merge. | Only when it changes how the product behaves |
| **body of work** | Touches a rule, the data model or more than one screen, or is new | The path below, steps a to j | Accept the proposal; sign the brief |

**Routing rule.** What it touches picks the track, not its label. Anything that touches a rule,
the data model, a contract (the data shapes where cards meet) or more than one screen is a body
of work, even when it arrives called a bug or a tweak. Triage enforces this in code
(`collect_handoff.py triage`).

## Fix or propose

Triage **fixes** an item on its own only when all of these hold:

- it cites the spec line, rule or baseline screen it breaks (a `Breaks:` line in Context)
- it touches one screen at most
- it changes no contract and no data model
- it is not red zone
- the verifier said `file`, not `needs-triage`

A fix is a bug or tweak card filed to **Ready**. A bug carries a `Failing test:` line naming the
test that fails now. A tweak carries a `## Before and after` section. Fix cards are capped per run
(`collect.triage.max_fix_cards`, default 5). Overflow goes to Backlog as a proposal recommending
the fix, so a noisy week can't take over the board.

Everything else is **proposed**, and so is anything triage is unsure of. A proposal goes to
Backlog with the `proposal` label and a `## Recommendation` section. The proposals digest lists
every open one for the owner:

- **accept:** a bug or tweak moves to Ready. A body of work stays in Backlog and starts step a.
- **reject:** the issue closes as not planned. The reason goes in a comment and in the body, so
  collect never files the same item again.

Labels, all of them: `bug` · `tweak` · `body-of-work` for the track, `proposal` while it waits on
the owner, `rejected` once closed.

## A body of work, step by step

- a. **Grill.** `/north-star` in rescope mode, on the change only. It drills each changed
  must-have to the clarity bar, asks the day-one questions and runs its Fable clarity review.
- b. **Exam.** Write the day-one questions with expected answers. They become the exam card and
  the walk's script.
- c. **Brief.** Write `docs/shape/briefs/<YYYY-MM-DD>-<slug>.md` (shape below).
- d. **Fable review.** A fresh Fable agent reads only the brief, the north star and the spec. It
  returns at most 6 findings: a rule the brief breaks without saying, a screen it forgets, a
  question a builder would have to guess. The factory gives its take; the owner decides.
- e. **Owner signs.** The owner reads the brief and says yes. Write the `Signed:` line. If the
  postcard moved, the owner re-signs `north-star.md` too.
- f. **Spec update.** `/to-board` rescope updates `docs/shape/spec.md` from the brief: new or
  changed rules, data model, contracts.
- g. **Cards.** `/to-board` cuts only the new cards. Each carries the `body-of-work` label and a
  `Brief:` line in Context. Then `/super-board lint`.
- h. **Run.** `/super-board run`.
- i. **Walk.** The agent walk (`walk.md`) on the real app, with the exam on the real model.
- j. **Report.** `/super-board report`, and the retro.

**The gate.** A body-of-work card can't sit in Ready without a signed brief. Lint criterion 25
(`super-board-coverage.py briefs`) fails any active card labelled `body-of-work`, or with a
`Brief:` line, whose brief is missing, not found, or has no `Signed:` line.

## The brief

`docs/shape/briefs/<YYYY-MM-DD>-<slug>.md`, one page:

```markdown
# Brief: <the change, in a few words>

Signed: <date> · <owner>

## What
<two or three sentences: what changes for the user>

## Why
<the pain, and the items that raised it: #N, walk findings, feedback>

## Rules it changes
- <I3: old → new, or "adds I7: …", or "none">
- Data model: <tables or fields added or changed, or "none">

## Screens
- <#screen-name: what changes>

## Out of scope
- <what this leaves alone>

## Exam
- <a day-one question> → <the expected answer>

## Review
- <each Fable finding: taken, or not and why>
```

Until the owner signs, the line reads `Signed: no`. Lint reads `no`, an empty value or a
`<placeholder>` as unsigned.

## Lessons log

Every gap found along the way (a step that let a problem through, or made the owner repeat
themselves) gets one line in the app's `docs/super-board/lessons.md`:

```
- <date> · <the gap> · <factory ticket #N> · <the default that changed, or "pending">
```

The fix goes on the factory repo as a ticket, never on the app's board. Once it ships, the
default changes for every app and the line gets its last field. The retro's Factory changes
section reads from this log.
