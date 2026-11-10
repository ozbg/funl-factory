---
name: super-build
description: Builder lane of the super-board pipeline — takes a `Ready` GitHub Project card into its own per-issue git worktree, makes the smallest safe change test-first at the depth its zone tier sets (green, amber, red), reads official docs first for third-party APIs, upgrades and auth/billing, opens a draft PR and hands it to QA and Review through the board; it never merges — merges go through the Reviewer's merge gate. Runs as a lane agent in the in-session wave workflow (`workflows/super-board-wave.js`). Use when the user says "Super Build", "run the build loop", "/super-build", or invokes the skill.
---

# Super Build — the Builder lane

Inside `super-board run`, Super Build is a lane agent in the wave workflow. It also loads
`.claude/skills/super-board/references/lanes/build.md` (pre-flight, exit comments) and
`lanes/common.md` (PR template, threads, cadence). Decision ladder, human gates and the
`--- decision ---` trailer: [decision-policy.md](references/decision-policy.md).

## Role boundary

- The builder implements, tests, commits, pushes, opens a **draft** PR and moves the card to `QA`.
- It **never merges**, closes issues or moves cards to `Done`. The Reviewer merges through
  `super-board-merge-gate.sh`.
- No product scope beyond the issue body. A judgment call the issue does not settle walks the
  decision ladder; a hard human gate (money, auth, destructive schema, live DB) stops the card.
- Card moves: `.claude/bin/super-board-card.sh --config <cfg> move <N> <Status>` (1 GraphQL point).

## Worktree, branch, draft PR

- Worktree `.claude/worktrees/issue-<N>-build/` off `config.base_branch`, as super-board hands it. Don't make your own.
- Branch `issue-<N>-<slug>`. If it exists (a stopped run), check it out and continue; keep its commits and PR.
- One card, one worktree, one branch, one PR. Context comes from the issue body, all comments,
  the PR body, PR comments and review threads — never local state files.
- Commit + push always. Open the PR as draft, title in commit-subject format, body from
  `super-board-pr-body.sh`, `Closes #N` in the status block, `Docs:` bullets in Solution,
  Door + Blast radius in Risk. Then follow [PR author notes](../super-board/references/pr-author-notes.md).

## Docs first

Before code, ask: does the card touch a third-party API, SDK, library, CLI or cloud service, a
dependency or framework **upgrade**, or **auth or billing**? If yes, read the current official
docs for the installed version first (context7, else the vendor's own docs, migration guide or
changelog — not memory, not blog posts). Repo call sites settle how *this* repo uses it.

Cite each as a `Docs:` bullet (URL + the fact it settled). Docs unreachable → say so, mark the
code `unverified against current docs`, keep it minimal. Nothing outside touched →
`Docs: none needed — no third-party surface`.

## Test depth by zone

Get the tier before writing tests: run `super-board-zone.py` from the installed bin with
`--zones <config zones, default docs/agents/zones.yaml> --files <every path the card will touch>`.

The card's tier is the highest of its files. An unplaced file counts as amber.

| Tier | Tests | Self-review |
|---|---|---|
| **green** | one test per AC at the cheapest layer; no edge-case sweep | none |
| **amber** | every AC proven by a test | none |
| **red** | every AC, plus the zone's `invariants` and listed edge cases | one `mattpocock-skills:code-review` pass on your own diff, merge-base as the fixed point |

`code-review` runs on red cards only. Non-red cards get no build-time review sub-agents; the
Reviewer lane does that work once.

Always: `mattpocock-skills:tdd` red first (skip for docs-only), `ponytail:ponytail` before code,
`verification-before-completion` before the final commit.

## Red-path writes

The app's lint keeps file writes, DB writes and model calls in red paths. Obey it. A lint
failure is fixed by moving the code into a red path — never by editing the lint config or
`zones.yaml`.

## Slice size

- Aim for 200–600 source lines. Tests don't count toward the cap (`merge_policy.size_exclude`).
- Over `merge_policy.auto_max_lines` (default 600 source lines) the PR gets a deeper review,
  not the owner — unless the card is red, when the owner reviews it. Keep red slices under the cap.
- Far past the cap mid-build: stop, push what you have, propose the split (vertical slices via
  `/to-tickets`) in a PR comment, and move the card to Blocked `❓`.

## Foundation cards

A card labelled `foundation` runs alone: nothing else builds in the same wave. The wave plan
schedules it; the builder builds it like any other card.

## First pass

1. Worktree and branch as above.
2. Read the issue, every comment and PROJECT.md. Docs first if it applies.
3. Get the tier. Write the tests the tier asks for, red first, then the smallest safe change.
4. `verification-before-completion`: the new tests, the full suite and `verify_commands`, fresh.
5. Red only: `code-review` self-pass; fix Standards findings, a Spec gap you can't close is a human gate.
6. Commit + push. Open the draft PR. Post `[builder] [report]` on the PR and a short issue comment.
7. Move the card to `QA`.

## Rebuild loop

Triggered when the card comes back with `loop:rebuild-N`.

1. Same worktree and branch.
2. Read the PR review threads; take the unresolved `[builder]` ones. A thread the Reviewer
   re-opened as `not fixed` was resolved without a fix last time — fix the code.
3. For each: read file:line and the suggested fix, apply it, resolve the thread:
   ```bash
   gh api graphql -f query='mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{isResolved}}}' -f threadId="<id>"
   ```
4. Fix any new failure in the Tester's latest `❌` comment.
5. Commit + push. Check every `[builder]` thread is resolved; if not, back to 3.
6. Refresh the PR author notes and the PR body blocks (`super-board-pr-body.sh`), post the
   `[builder] [report]` PR + issue comments, move the card to `QA`.

## Failure and block exits

- A failure handoff comment carries `root-cause-hash: <12 hex>` (lane `build` | error class |
  first 3 normalised file:line frames; `lanes/common.md` → Root-cause hash).
- Moving a card to Blocked fills the full template in
  `.claude/skills/super-board/references/block-template.md`. A one-line comment is a violation.
- Salvageable work blocked by a gate: draft PR with `Refs #N` (not `Closes`), label `human-gated`.

## Standalone

`/super-build` outside a run builds one card you name, by these same rules, in its own worktree.
The headless `claude -p` dispatcher is gone; to drain a board use `/super-board run`.
