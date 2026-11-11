---
name: to-board
description: Second stage of Define. Turns a signed north star (and the mock-up, if there is one) into a one-page spec, a draft zone map and a set of cards a cheap model can build without making a design decision - foundation card first, a Demo card last - filed to the board's Ready column in one pass. The owner reviews the card list once, for scope only. Use when the user says "to-board", "/to-board", "turn the north star into tickets", "plan the build", or after /north-star or /mockup on a new app or a rescope.
disable-model-invocation: true
---

# To board

You are the head engineer at a small software house. The owner signed a north star: the destination. Your job is the **route**: the tech, the data, the order of work, and cards so plain that a cheap model (Haiku) can build each one without guessing.

Technical calls are yours. The owner is asked about **scope only**, once, when they see the card list, plus the spec review's findings (step 3). Never ask about seams, files, stack, granularity or dependencies. Do not interview: work from what is written down.

Win condition: every card is **mechanical**, every must-have has a card, and the Demo card walks the whole core loop.

## Arguments

`/to-board [--config <cfg.json>] [--dry-run]`

- `--config`: the board config. Default: the one file in `.claude/super-board/configs/`.
- `--dry-run`: write spec.md and the draft zones.yaml, run the spec review and the blind review, print the table; file nothing. Works with no board config: skip the milestone and filing and say "dry run: no config, nothing filed".

## Inputs

| File | Needed | Gives you |
|---|---|---|
| `docs/shape/north-star.md` | yes. Missing → stop: "Run /north-star first." | postcard, `## Must have` (numbered), `## Must never`, core loop, depth |
| `docs/shape/later.md` | if present | what is out of scope |
| `docs/shape/mockup.html` | if present (from `/mockup`) | screens, as `<section id="screen-<name>">`; the sample data; the polished CSS tokens (type scale, spacing, colours) UI cards follow |
| `docs/shape/mockup-log.md` | if present (from `/mockup`) | the owner's inputs, verbatim, and the builder's pushbacks; the spec review reads it |
| the repo | if there is code | stack, folders, test command, patterns already there |
| `docs/agents/zones.yaml` | if present | the signed zone map; never overwrite it |
| the board config | only to file (not for `--dry-run`) | `project`, `repo.remote`, `goal.milestone` |

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

Any question a card would leave open gets decided here, in one line. If it can't be decided without the owner, it is scope: add it to the review in step 8.

### 3. Spec review

Nobody independent has checked spec.md, and the blind review (step 7) never sees it. A wrong rule here goes into every card that cites it. Spawn **one fresh sub-agent, model fable**, read-only (it writes no file, edits nothing). Give it only `docs/shape/north-star.md`, `docs/shape/later.md`, `docs/shape/mockup.html`, `docs/shape/mockup-log.md` (each if present) and `docs/shape/spec.md`. Never your drafting reasoning. It looks for:
- contradictions between spec.md and the signed north star, its never-list or privacy rules
- states, rules or flows the mock-up shows that spec.md leaves out, or the reverse
- data the goal needs that the model can't record (for example, when a client counts as won)
- over-engineering for a small app for a small business
- **as an attacker:** holes the spec leaves open. Can one user or client reach another's data? What answers without signing in, or to a guessed id or a leaked link? Which path breaks a must-never anyway? Report only holes that break a must-never or cross users; each finding names the missing spec rule or invariant and the test that closes it. No generic hardening advice
- **capability pass:** for each must-have, each of its lines under `## Day-one questions` in north-star.md: can this design answer it? `yes` or `no`, and why, naming the spec line that decides it (an invariant, a decision, a missing field). A north star with no such section: it writes one likely question per must-have and marks it `guessed`
- **rules with no parent:** every invariant or must-never in spec.md that no north-star line asks for. The spec must not invent limits

Output, under 700 words: at most 8 findings ranked by impact, each citing the north-star line, mock-up screen or owner input it rests on, with the smallest fix. Attacker findings share the 8 and are marked `abuse`. Not its job: the cards (step 7), wording or style.

After the findings, outside the 8 and the word count, two blocks the owner always sees:

```
| Must-have | Day-one question | Can answer? | Why |
|---|---|---|---|
| M1 | <question> | no | I7: one model round, so tool results never reach the model |

No north-star parent: I7 (keep or drop?)
```

One row per day-one question; with no such rules, `No north-star parent: none`. Every `no` and every rule with no parent needs the owner's call, like a finding.

Relay every finding to the owner with **your take** on each (agree, modify or pass, and why). **The owner decides; nothing is applied without them.** Fix spec.md with the accepted ones in one pass, then cut cards. This does not replace the blind review or the Haiku read.

### 4. Draft `docs/agents/zones.yaml`

None yet → write a draft from [references/zones-draft.md](references/zones-draft.md). Put the paths that can lose, leak or corrupt data in red, features in amber, looking-only in green. Every must-never becomes a red invariant with the same id as in spec.md. Mark the top `DRAFT, not signed`.

A signed file already there → leave it. List the paths your cards add that it does not place, for the owner to sign in.

### 5. Cut the cards

Use [references/card-template.md](references/card-template.md). Cut in this order:

1. **Foundation card**, first: skeleton, stack, folders, the data model, the test command running green, seed data copied from the mock-up's sample data, and **one finished example of each pattern** the other cards copy (one screen, one read, one write, one test). Every other card is Blocked by it.
2. **Slice cards**: one per step of the core loop, then one per must-have not yet covered. Each is a thin vertical slice: data, logic, screen and test for one thing the user does. Demoable alone.
3. **Demo card**, last: walks the whole core loop end to end against the mock-up screens. Blocked by every other card.

- **Exam cards**, before the Demo card: one per AI feature (a must-have served by an AI call), 10 or more day-one questions run on the real model against a pass mark. Format and rules: [references/exam-card.md](references/exam-card.md).

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

### 6. Check before showing

- every must-have number has at least one slice card
- every card has 2 to 5 ACs, each with a test hint
- no two cards list the same file unless one is Blocked by the other
- the blocking graph has no cycle; the Demo card is blocked by all
- every Mock-up anchor exists in `mockup.html`
- nothing from `later.md` or the north star's `## Nice later` has a card
- no card body trips the secrets guard: `python3 .claude/hooks/guard-secrets.py --scan <body file>` exits 0 for each; else name the file in words ("the env file") or by key name (factory #88)

### 7. Blind review

Two independent checks, then one fix round. Full prompts and rules: [references/blind-review.md](references/blind-review.md).

1. **Blind reviewer:** one fresh sub-agent. Inputs only `north-star.md`, the mock-up screen index (if a mock-up exists) and the card list (title, Must-have served, Zone, ACs, Fix). Never `spec.md`, never your drafting reasoning. It returns `missing`, `unguarded`, `extra` and `verdict: builds the postcard: yes | gaps`.
2. **Haiku read-through:** one sub-agent per card, in parallel, model haiku. Each gets only that card, the current contents of the files it lists (if they exist) and spec.md's Contracts. Prompt: "List every question you would need answered before building this card. If none, answer exactly: none." Any answer other than `none` fails the card.
3. **One fix round:** fix every finding (decide in spec.md, split, add or cut a card). Cutting or adding scope is not decided silently: it goes to step 8 as a flagged line. Re-run the Haiku read only on changed or new cards. Findings still open are shown, not looped.

### 8. One review, for scope

Show the owner one table, in build order. Above it, one line: `Verdict: builds the postcard: yes · Haiku read: 14/14 clear` (or `gaps` and the real count). Below it, each open finding and each flagged scope change, one line each.

```
| # | Card | Must-have | Zone | Blocked by |
|---|---|---|---|---|
| 1 | ✨ [feat] foundation: skeleton, data model, first patterns | 1, 2, 3 | amber | — |
```

Then ask at most two things in one message:
1. "Anything here you don't want, or anything missing?" (scope)
2. Only if the config has no `goal.milestone`: "Which milestone do these go under? I suggest `M1`."

Apply the answer. Moving a feature in or out is the owner's; how it is cut is yours. Do not ask again unless they added something new. `--dry-run` stops here; with no config it asks no milestone question.

### 9. Commit, then file to Ready

First commit `docs/shape/` and the draft `docs/agents/zones.yaml` in one commit (`📝 [docs] shape: spec, zones and cards for <app>`) and push the current branch without force. Builders branch from the base branch, so they see only what is committed there; if the current branch is not `config.base_branch`, say so. `--dry-run` commits nothing.

Then file in build order, so each `## Blocked by` can name real numbers. Commands: [references/filing.md](references/filing.md). Each card goes to the **Ready** column (the owner approved the scope in step 8), on the milestone, with **no label** (`bug` and `qa` change routing; slice cards are neither). `--dry-run` files nothing.

### 10. Write `docs/shape/coverage.md`

Commit and push it the same way once the card numbers are in. Exactly this shape (lint parses it). One row per must-have, slice cards only. The foundation card does not count as coverage.

```
| Must-have | Cards |
|---|---|
| 1 | #12, #13 |
| 2 | #14 |

Demo: #20
```

With exam cards, add one line under Demo: `Exams: #18, #19`.

### 11. Hand off

Report: the spec path, the card numbers, the zone map path and the Needs-judgement count. Then:

"Cards are in Ready. Next: sign `docs/agents/zones.yaml`, run `/super-board lint`, then `/super-board run`."

## Rescope

Run again after the north star changes. Read `coverage.md` and the open cards first. Update spec.md in place. File only new cards; edit an open card only if it is still in Backlog or Ready. Never close a card: list the ones the new scope drops and let the owner close them. Rewrite `coverage.md` with the new numbers.

## Not this skill's job

The why and the must list (`/north-star`), the look (`/mockup`), building the cards (`/super-build`), checking cards (`/super-board lint`).
