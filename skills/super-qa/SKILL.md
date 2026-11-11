---
name: super-qa
description: >-
  Super QA — the Tester lane of super-board and a standalone bug-bash. On a board card it checks
  by zone: amber maps each AC to a test and checks the zone's bar and the ticket's own edge cases;
  red adds invariant tests and one mutation per guarded line; green skips QA. A fail must cite an
  AC, an invariant, a bar line or a reproducible bug. Evidence stays local; the PR gets an AC
  table as text, and every screen card gets its screenshot beside the mock-up. Standalone, it
  crawls routes from `docs/super-qa/queue.md` with Playwright, records screenshots/logs/HARs
  and files product-readable issues. Use when the user says
  "run super-qa", "QA review", "bug bash", "verify and fix", or invokes `/super-qa`.
---


**For a board worker, before writes or worktree creation:** follow [skill readiness](../super-board/references/skills-readiness.md).
Resolve this lane for the actual host, load the report's files/fallbacks, halt
on missing requirements and recheck each conditional helper before use.

# super-qa — the Tester

Two modes:

- **Board lane** (env `SUPER_BOARD_RUN=1`, or the prompt says "super-board run"): this file plus
  `../super-board/references/lanes/qa.md`. Checks scale with the card's zone.
- **Standalone** (`/super-qa`, `/super-qa N`, `/super-qa <url>`): the BFS route crawler. Load
  [references/standalone-crawl.md](references/standalone-crawl.md) and follow it. A board lane
  never loads it.

## Zone first

Scope is the PR's diff against its base. Resolve its zone:

```bash
git -C <worktree> merge-base HEAD origin/<base>                     # → <base-sha>
git -C <worktree> diff --name-only <base-sha>...HEAD                # → <files>
python3 .claude/bin/super-board-zone.py --zones <config.zones> --files <files>
```
Three plain calls; paste each result into the next (`lanes/common.md` → "Command shape").

The JSON gives `tier`, `max_rounds`, `bar`, `invariants`, `accepted_limits`, `boundary`. No
zones file → every card is amber, and `max_rounds` comes from config `max_rounds.<tier>`. A `qa`
card with no diff is amber.

## Checks by zone

**Green — no QA lane.** The Builder proves the ACs and the Reviewer checks them. A later ticket
makes the workflow skip QA for green; until then a green card that reaches QA moves straight to
Review with `Did: green zone — no QA lane` and `citation: "none"`. A green screen card gets the
screen match (below) first.

**Amber:**

1. **Ledger.** Every AC → the asserting test `file:line`, or `n/a: <reason>`. A test that runs
   the code but asserts nothing about the AC does not count. An AC with no test: write one,
   red first, at the layer the defect would live (unit or integration before e2e).
2. **Bar.** Check each line of the zone's `bar` against the card's change.
3. **Ticket edge cases.** Only the edge cases the ticket itself names. No generic list.

**Red:** the amber checks, plus:

4. **Invariants.** A green test for each invariant the diff can touch (`I<n>` → test `file:line`).
   No test → write it.
5. **Mutations.** For each red line a test guards, break that line once, see the test go red,
   restore it, see green. The mutation never reaches a commit. One per guarded line.

**Accepted limits** in the zones file are never checked, never noted, never filed.

**Screen cards, every zone.** A card with a `**Mock-up:**` line or a `## Mock-up` block gets the
screen match: the app and its baseline (the mock-up anchor until the first build ships, then the
frozen app screenshot) captured at the same size, every visible difference listed and judged
against the card. A difference not under `Cut from mock-up:` and not accepted by a note on the
card fails the match AC. Follow [references/screen-match.md](references/screen-match.md).

## No citation, no bounce

A fail must cite one of:

- `AC<n>` — an acceptance criterion with no passing proof
- `I<n>` — an invariant with no green test, or a red line whose mutation survived
- `bar: <line>` — a zone bar line the change misses
- `bug: <repro steps>` — a visible defect you can reproduce in this card's change

Anything else is a note in the handoff, never a fail. An amber card with a gap in a Unicode case
the ticket did not name gets a note. A privacy, data-loss or visible-bug finding outside the
card's scope is filed as a Backlog card and does not fail this card:

```bash
super-qa-file-bug.sh --title "<one line>" --body-file <md> --column Backlog
```

The structured result carries `citation: "<value>"` (the first cited fail) or `citation: "none"`
on a pass. Start `detail` with the same `citation: <value>` so the wave summary shows it.

## Security pass

Run it on red cards, and on amber cards when the zone script says `boundary: true`. Skip it on
the rest and say `pr-security-review: skipped (<tier>)` on the `Did:` line.

1. Load `pr-security-review` and follow it on the PR's diff against its base branch
   (`gh pr view <PR> --json baseRefName`). It runs in this lane, not in a sub-agent.
2. A kept finding inside the card's scope is a fail citing `bug: <category> — <file:line>`, with
   a `[builder]` PR thread on that line. Outside the scope → Backlog card, as above.
3. A finding you can show is wrong goes on the `✅ Done` line with the proof.
4. Skill missing on a card that needs it → Block (`🔐`, needs install). Never pass it unchecked.

For a whole-repo audit, mention `security-audit` (standalone); never run it from the lane.

## Round cap

On a fail, read the card's `loop:rebuild-N` label (none = 0). N at or above the zone's
`max_rounds` → move the card to Blocked with the block template, reason 🛡, and the line
`ruling or split: <what keeps failing>`. Below it → the normal fail exit.

## Evidence

Evidence stays out of the repo. Write it under the main checkout, not the card worktree (that is
removed on exit):

```bash
git -C <worktree> rev-parse --path-format=absolute --git-common-dir   # → <main>/.git; <ev> = <main>/.claude/super-board/evidence
mkdir -p <ev>/<issue>/v<V>
```
Then, if `<ev>/.gitignore` is missing, write it (one line: `*`) with the Write tool.

Screenshots, logs, HARs and test output go there. Never `git add` them, never embed images in a
comment. The one exception is a screen card's screenshot pair: it is committed under
`docs/shape/baseline/` and embedded, pinned to a sha (screen-match.md). The PR comment carries
the AC table as text:

```markdown
| AC | Result | Proof |
|---|---|---|
| AC1 | ✅ | `tests/streaming.test.ts:42` |
| AC2 | ❌ | want TTFB < 800 ms, got 1240 ms |
```

Evidence adds 0 lines to the PR. Only tests the Tester writes, and a screen card's pair, are committed.

## Lifecycle (board lane)

The steps are in `../super-board/references/lanes/qa.md` → "Tester". Card types:

- **Built card (`feature`, `bug`, no label):** worktree `.claude/worktrees/issue-<N>-qa/` at the
  Builder's branch tip.
- **`qa` card:** move it Ready → QA yourself, create `issue-<N>-<slug>` from the base branch,
  test what is already there (lanes/qa.md → "qa cards").
- **A live URL with no repo** is not a board card: `/super-qa <url>` runs standalone.

GitHub budget: every card move is `.claude/bin/super-board-card.sh --config <cfg> move <N> <Status>`.
Comments, labels and PR reads go over REST
([rate-limit-etiquette.md](../super-board/references/rate-limit-etiquette.md) → "Price list").
State lives in issue + PR comments and review threads. After pushing tests, refresh
[PR author notes](../super-board/references/pr-author-notes.md) before the handoff.

### Pass handoff names the test command

Every pass comment ends with a `Local tests:` line holding the EXACT command the Reviewer reruns:

```
Local tests:  npm test --run streaming
```

### Failure → `root-cause-hash:` line required

Hash lane = `qa`, inputs per `lanes/common.md` → "Root-cause hash".

### Block exits use the §4 template

Same as super-build: `block-template.md`, on the issue and the PR.

## Optional checks

- **Project feature verifier.** An existing `.agents/skills/verify-<app>/` map → follow
  [project-verifier.md](references/project-verifier.md) for affected features only. A map
  inspection proves no test pass.
- **Runtime performance and memory.** Only when the issue asks or `runtime_verification.config`
  is set → [runtime-verification.md](references/runtime-verification.md). Report under
  `Runtime checks:`. A noisy result cannot prove a performance AC.

## Skill dependencies (board lane)

- `mattpocock-skills:tdd` — red first for every test the lane writes
- `verification-before-completion` — no pass without fresh output
- `pr-security-review` — red cards and boundary amber cards only
- `vitest` / `playwright-best-practices` — mechanics for the layer the test lives at
