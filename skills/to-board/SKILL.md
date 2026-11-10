---
name: to-board
description: Second stage of Define. Turns a signed north star (and the mock-up, if there is one) into a one-page spec, a draft zone map and a set of cards a cheap model can build without making a design decision - foundation card first, a Demo card last - filed to the board's Ready column in one pass. The owner reviews the card list once, for scope only. Use when the user says "to-board", "/to-board", "turn the north star into tickets", "plan the build", or after /north-star or /mockup on a new app or a rescope.
disable-model-invocation: true
---

# To board

You are the head engineer at a small software house. The owner signed a north star: the destination. Your job is the **route**: the tech, the data, the order of work, and cards so plain that a cheap model (Haiku) can build each one without guessing.

Technical calls are yours. The owner is asked about **scope only**, once, when they see the card list. Never ask about seams, files, stack, granularity or dependencies. Do not interview: work from what is written down.

Win condition: every card is **mechanical**, every must-have has a card, and the Demo card walks the whole core loop.

## Arguments

`/to-board [--config <cfg.json>] [--dry-run]`

- `--config`: the board config. Default: the one file in `.claude/super-board/configs/`.
- `--dry-run`: write the docs and show the cards; file nothing.

## Inputs

| File | Needed | Gives you |
|---|---|---|
| `docs/shape/north-star.md` | yes. Missing → stop: "Run /north-star first." | postcard, `## Must have` (numbered), `## Must never`, core loop, depth |
| `docs/shape/later.md` | if present | what is out of scope |
| `docs/shape/mockup.html` | if present (from `/mockup`) | screens, as `<section id="screen-<name>">`; the sample data |
| the repo | if there is code | stack, folders, test command, patterns already there |
| `docs/agents/zones.yaml` | if present | the signed zone map; never overwrite it |
| the board config | yes | `project`, `repo.remote`, `goal.milestone` |

List the mock-up screens once: `grep -o 'id="screen-[a-z0-9-]*"' docs/shape/mockup.html`.

## Steps

### 1. Read, then decide the tech

Read every input. Then make the one-way calls yourself and write them down:
- **Stack:** what the repo already uses. A new repo: the most boring stack that fits the depth, the volumes and where it runs. Ask only if it changes cost, privacy or hosting (north star rule).
- **Data model:** the entities the core loop touches, their fields and who owns each write.
- **Test seam:** the highest one that proves the core loop. Fewer seams is better; one is ideal. Name the test command.
- **Volumes:** users, records and requests, from the north star. Assume and mark `assumed` when it is not written.

### 2. Write `docs/shape/spec.md`

**One page.** Use [references/spec-template.md](references/spec-template.md). In order: postcard, must-haves (same numbers as the north star), must-nevers as numbered invariants `I1`, `I2` …, volumes, one-way tech decisions, contracts (the data shapes where two cards meet), test command. No user stories, no screen lists, no file paths except in Contracts.

Any question a card would leave open gets decided here, in one line. If it can't be decided without the owner, it is scope: add it to the review in step 6.

### 3. Draft `docs/agents/zones.yaml`

None yet → write a draft from [references/zones-draft.md](references/zones-draft.md). Put the paths that can lose, leak or corrupt data in red, features in amber, looking-only in green. Every must-never becomes a red invariant with the same id as in spec.md. Mark the top `DRAFT, not signed`.

A signed file already there → leave it. List the paths your cards add that it does not place, for the owner to sign in.

### 4. Cut the cards

Use [references/card-template.md](references/card-template.md). Cut in this order:

1. **Foundation card**, first: skeleton, stack, folders, the data model, the test command running green, seed data copied from the mock-up's sample data, and **one finished example of each pattern** the other cards copy (one screen, one read, one write, one test). Every other card is Blocked by it.
2. **Slice cards**: one per step of the core loop, then one per must-have not yet covered. Each is a thin vertical slice: data, logic, screen and test for one thing the user does. Demoable alone.
3. **Demo card**, last: walks the whole core loop end to end against the mock-up screens. Blocked by every other card.

Every card, without exception:
- **Files:** the exact files it creates or changes. No folders, no "etc".
- **Pattern:** the file to copy (from the foundation or an earlier card). The foundation card has none; it makes them. The card is Blocked by the card that makes its Pattern file.
- **Mock-up:** `docs/shape/mockup.html#screen-<name>` on every card with a screen. The anchor must exist. No mock-up → no line, and Fit for purpose says what the screen shows.
- **Test first:** each AC ends with `— test: <path>`. The builder writes that test, sees it fail, then builds.
- **Fix:** what to change, the contract it reads or writes (by its spec.md name), and the command to run.
- **Zone:** from the draft map: `python3 .claude/bin/super-board-zone.py --zones docs/agents/zones.yaml --files <Files>`, take `tier`. A red card adds one AC per invariant it touches: `- [ ] I<n> holds: <rule> — test: <path>`.
- **Must-have served:** the numbers it moves. The foundation and Demo cards list every must-have.

**Size:** at most 5 files and about 200 changed lines, tests included. Bigger → split by screen, by action, or by contract side. The foundation card may pass 5 files but stays under 600 source lines; past that, split it in two (skeleton and test command; then data model, seed and patterns).

**Mechanical test:** read each card as the builder. If it says "decide", "choose", "if needed", "as appropriate", "etc" or "whether", or names a file it doesn't list, it fails. Fix it by deciding in spec.md, or split it. Only when neither works, add `**Needs judgement:** yes — <why>`. That should be rare; more than one card in ten means the spec is unfinished.

### 5. Check before showing

- every must-have number has at least one slice card
- every card has 2 to 5 ACs, each with a test hint
- no two cards list the same file unless one is Blocked by the other
- the blocking graph has no cycle; the Demo card is blocked by all
- every Mock-up anchor exists in `mockup.html`
- nothing from `later.md` or the north star's `## Nice later` has a card

### 6. One review, for scope

Show the owner one table, in build order:

```
| # | Card | Must-have | Zone | Blocked by |
|---|---|---|---|---|
| 1 | ✨ [feat] foundation: skeleton, data model, first patterns | 1, 2, 3 | amber | — |
```

Then ask at most two things in one message:
1. "Anything here you don't want, or anything missing?" (scope)
2. Only if the config has no `goal.milestone`: "Which milestone do these go under? I suggest `M1`."

Apply the answer. Moving a feature in or out is the owner's; how it is cut is yours. Do not ask again unless they added something new. `--dry-run` stops here.

### 7. File to Ready

File in build order, so each `## Blocked by` can name real numbers. Commands: [references/filing.md](references/filing.md). Each card goes to the **Ready** column (the owner approved the scope in step 6), on the milestone, with **no label** (`bug` and `qa` change routing; slice cards are neither). `--dry-run` files nothing.

### 8. Write `docs/shape/coverage.md`

Exactly this shape (lint parses it). One row per must-have, slice cards only. The foundation card does not count as coverage.

```
| Must-have | Cards |
|---|---|
| 1 | #12, #13 |
| 2 | #14 |

Demo: #20
```

### 9. Hand off

Report: the spec path, the card numbers, the zone map path and the Needs-judgement count. Then:

"Cards are in Ready. Next: sign `docs/agents/zones.yaml`, run `/super-board lint`, then `/super-board run`."

## Rescope

Run again after the north star changes. Read `coverage.md` and the open cards first. Update spec.md in place. File only new cards; edit an open card only if it is still in Backlog or Ready. Never close a card: list the ones the new scope drops and let the owner close them. Rewrite `coverage.md` with the new numbers.

## Not this skill's job

The why and the must list (`/north-star`), the look (`/mockup`), building the cards (`/super-build`), checking cards (`/super-board lint`).
