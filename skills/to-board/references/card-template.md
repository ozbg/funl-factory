# Card template

The board's ticket format ([ticket-format.md](../../super-board/references/ticket-format.md)),
filled in so a cheap model can build it without a design decision. Same sections, same card
lines; `/to-board` adds Mock-up, Pattern and Needs judgement, and a test hint on every AC.

## A slice card

```markdown
## Problem
<1–3 sentences from the user's side: what they can't do yet.>

## Context
- **Where:** <screen name>, `<route>`
  - a. <what the user does first>
  - b. <next step>
  - c. <what they see>
- **Who:** <who does it>
- **Scenario:** <the one core-loop step this card makes work>
- **Zone:** <green | amber | red, from super-board-zone.py>
- **Files:** <exact files, comma-separated, tests included, at most 5>
- **Fit for purpose:** <what good enough means; what it does not need>
- **Out of scope:** <the next card's job, or what later.md parks>
- **Must-have served:** <n>
- **Mock-up:** docs/shape/mockup.html#screen-<name>
- **Pattern:** <the file to copy, e.g. app/items/page.tsx from the foundation card>

## Fix
<What to change, in one line.> Reads/writes `<ContractName>` (spec.md § Contracts).
Write the tests first, see them fail, then run `<test command>` until green.

## Acceptance Criteria
- [ ] <checkable outcome> — test: <path>
- [ ] <checkable outcome> — test: <path>

## Risk
🟢 **Low** · <one line>

## Blocked by
- #<foundation> — <the pattern and contract it copies>
```

## The foundation card

Same sections. Differences:
- Title: `✨ [feat] foundation: skeleton, data model, first patterns`
- **Files:** every file it creates; it may pass 5 but stays under 600 source lines.
- No **Pattern:** line. It makes the patterns: one screen, one read, one write, one test.
- **Must-have served:** every must-have number.
- **Mock-up:** the first screen of the core loop, when there is a mock-up.
- ACs (test hints as usual):
  - the test command runs and passes
  - the test command also runs the formatter check, the linter (no empty catch, no unhandled promises, no unused code, no `any`), strict type checking and a high-severity dependency audit, and all pass
  - the data model in spec.md § Data model exists, with a migration if there is a database
  - seed data matches the mock-up's sample data
  - one screen renders seed data, as in the mock-up
  - each contract in spec.md § Contracts exists with its exact name and fields
- `## Blocked by` → `- None.`

## The Demo card

Same sections. Differences:
- Title: `🧪 [test] demo: core loop end to end`
- **Scenario:** the whole core loop from north-star.md, in one line.
- **Files:** the end-to-end test file only.
- **Pattern:** the foundation's test file.
- **Mock-up:** the first screen; Where lists every screen of the loop as lettered steps.
- **Must-have served:** every must-have number.
- ACs: one per core-loop step, each `— test: <the e2e file>`, each checked against its mock-up screen.
- `## Blocked by`: every other card, one bullet each.

## Needs judgement

Only when a card can't be made mechanical by deciding in spec.md or by splitting:

```markdown
- **Needs judgement:** yes — <the open question, in one line>
```

Absent means no. Never write `no`.

## Words that fail the mechanical test

`decide`, `choose`, `pick`, `whether`, `if needed`, `as appropriate`, `etc`, `and so on`,
`some`, `maybe`, `TBD`, `a suitable`, a folder in Files, a file the Fix names but Files doesn't.
