# super-board lanes — Builder

Read `common.md` (this folder) first: branch + PR model, PR template, review threads, commenting cadence, self-check.

## Builder pre-flight (before ANY card goes Ready → Building)

Two agents must never build the same thing, and nothing already on the base branch gets built
twice. So before a Builder starts, a **fresh, cheap sub-agent** (no code, no worktree) checks the
card. The wave's `Pre-flight` phase does it, one agent per batch of up to 5 Ready
cards, before `runLane('build')`.

```
[ ] bash .claude/bin/super-board-gh-guard.sh check 200
[ ] build the in-flight list: .claude/bin/super-board-card.sh --config <cfg> items (one call) → [{number,title,status}] for
    Building / QA / Review / Ready cards; save it to a temp file
[ ] bash .claude/bin/super-board-preflight.sh --repo <owner/name> --issues <N[,M…]> \
         --inflight <file> [--files <paths you expect to touch>]
[ ] judge each card: the script's verdict, then its `candidates` (near-misses) semantically
[ ] act on the outcome below, then return one verdict per card
```

The script asks four questions and the agent adds a fifth; the agent owns the judgement:

| # | Question | Mechanical signal (script) | Agent adds |
|---|---|---|---|
| 1 | Already done? | merged PR closes `#N`; merged PR / closed issue with the same `fingerprint:` or title | a merged PR that delivers the same behaviour under other words |
| 2 | Already in progress? | open PR on another branch closes `#N` or has the same title; a card in Building/QA/Review (or a lower-numbered Ready peer) with the same title | same feature, different words — not merely the same files |
| 3 | File overlap? | open PR touches files in the card's `**Files:**` list; a lower-numbered card in the same `--issues` batch lists the same files | the same overlap with a Ready peer in another batch. Only `**Files:**` lists count: `Pattern:` and `Mock-up:` paths are read-only references, never overlap (#95). `--files` passes a Files list, never a Pattern or Mock-up path |
| 4 | Unclear? | no `## Acceptance Criteria` bullets | AC that contradicts the current code (cite `file:line`) |
| 5 | Too big? | — | likely far over ~600 source lines (`card_max_lines`; tests, lockfiles, generated, snapshots, migration SQL excluded) or spans many areas (UI + API + DB + jobs …) — lint.md criterion 15 |

**Two Ready cards that overlap each other, neither with an open PR, go one at a time.** The
lower-numbered card proceeds; only the other is sequenced, with `blocked-by: #<lower>`, and the
wave-start sweep frees it once the lower one closes. Sequencing each against the other leaves
both with nothing to wait on and neither built — the same deadlock comes back every wave.

The agent may turn a `proceed` into a `hold` on evidence. It may turn a mechanical `hold` into
`proceed` only by naming why the match is a different feature. Its own branch's PR
(`issue-<N>-*`) is the card coming back, never its own duplicate.

**Outcomes — never drop a card silently:**

| Verdict | Action | Block template (`block-template.md`) |
|---|---|---|
| `proceed` | nothing; the Builder starts | — |
| `hold` — done | move card to Blocked | `👯` · names the merged PR / closed issue · Owner: <owner_name> (close as duplicate) · `blocked-by: -` |
| `hold` — in progress | move card to Blocked | `👯` · names the open PR / card · `blocked-by: <the issue that PR or card closes>` — the sweep returns it when that closes, and pre-flight then finds it done |
| `hold` — unclear | move card to Blocked | `❓` · the missing AC or the contradiction with `file:line` · `blocked-by: -` |
| `hold` — too big | move card to Blocked | `❓` · "too big — likely over <cap> source lines / spans <areas>" · suggests splitting with `/to-board` into vertical slices, each under the cap · `blocked-by: -` |
| `sequence` — `blockedBy` non-empty | move card to Blocked | `⏳` · the overlapping PR and files · `blocked-by: <blockedBy>` — the wave-start sweep frees it |
| `sequence` — `blockedBy` empty | proceed (card stays Ready, return column `Ready`), comment `⚠️ expected conflict with PR #<P> on <files> — the merge gate will rebase` | — |
| `halted` | script exit 79: required evidence unavailable; leave the card untouched, stop this run, resume explicitly after recovery | — |

A card the pre-flight agent returns no verdict for is treated as `skipped` (a verdict, not a
column), never built unchecked. `qa` cards are not pre-flighted: nothing is built.

## Builder (first pass)

1. Create worktree `.claude/worktrees/issue-<N>-build/` off `config.base_branch`.
2. Create branch `issue-<N>-<slug>` from `config.base_branch` — unless one already exists
   (the card came back from Building after a stopped run): then check it out, keep its
   commits and open PR, and continue from where it stopped.
2b. **Fresh base before building.** A worktree cut before a dependency merged reads stale code.
    For each `Blocked by` card that has merged, read its PR's merge commit
    (`super-board-github-read.py --kind merge-state -- pr view <P> --json state,headRefOid,mergeCommit`),
    then run `bash .claude/bin/super-board-fresh-worktree.sh --base <config.base_branch> <sha>…`
    in the worktree. It fetches the base and, when a sha is missing from HEAD, rebases an
    unpushed branch onto it or merges the base into a pushed one (never a force push).
    Exit 0: every dependency is in the worktree. Exit 5: the `not-merged` shas are not on the
    base. Exit 3 (uncommitted changes) or 4 (conflict): the worktree is untouched; commit or resolve by hand, then rerun.
    **A block that names a dependency is refused** when this script reports it `present`: the
    code is there, so build against it. Only a `not-merged` dependency can be `blocked-by:`.
3. Read issue body + ALL comments + PROJECT.md. A card with a `Feedback: fb-…` line in Context:
   run `python3 .claude/skills/super-collect/scripts/collect_feedback.py show <ref>` and look at
   the screenshot, its markup and the item before working. Never copy them into the repo or the PR.
3b. Touches a third-party API/SDK, an upgrade, or auth/billing? Read the current official docs
    for the installed version first (super-build → "Docs first").
3c. Get the tier: `python3 .claude/bin/super-board-zone.py --zones docs/agents/zones.yaml --files …` on the files the card touches (unplaced = amber).
    Green: one test per AC at the cheapest layer. Amber: every AC proven by a test. Red: plus
    the zone's invariants and edge cases, and one `code-review` self-pass — red only.
4. Implement the smallest safe change covering ACs. Name domain things exactly as `docs/shape/spec.md`
   names them (data model, contracts). If the card changes a contract or the data model, update
   `docs/shape/spec.md` in the same PR so the spec stays true for the cards after it. A `/to-board` card aims under ~200 source lines; `card_max_lines` (600) is the cap (tests don't
   count). File writes, DB writes and model calls stay in red paths: fix a lint failure by
   moving code, never by editing the lint config or `zones.yaml`. A `foundation` card runs alone.
   A PR over `merge_policy.auto_max_lines` → deeper review, the owner only if red. Far past
   `card_max_lines` mid-build → stop, push, propose the split (`/to-board`) in a PR comment, Blocked `❓`.
4b. **No partial merge.** Every AC is built, or split off (common.md → "No partial merge"): file a linked Backlog card with that AC, remove it here, note `AC<n> moved to #<N>`. Never leave one unticked for the gate to find.
5. Commit + push (always). Commits follow writing-standard.md § 1 (`✨ [feat] chat: stream replies` + short bullets).
6. Open draft PR linked to the issue with the PR description template (title in commit-subject format, every block filled).
7. Follow [PR author notes](pr-author-notes.md), then post the `[builder] [report]` PR comment (see "Commenting cadence").
8. Post a short status comment on the issue with the PR URL.
9. Clean up worktree. Keep branch + PR open.
10. Move card Building → QA.

## Builder (rebuild)

1. Worktree as above.
2. Read PR review threads on this branch's PR; filter `[builder]` prefix.
3. For each unresolved `[builder]` thread: read file:line + suggested fix, apply, resolve thread via graphql mutation.
4. Address any new failure feedback from Tester's latest `❌` comment.
   (A Reviewer bounce reaches you as those same `[builder]` threads, listed in the latest `<!-- super-review:report -->` comment. A finding the Reviewer re-opened as `not fixed` was resolved without a fix last time — fix the code, not just the thread.)
5. Commit + push to same branch.
6. Verify ALL `[builder]` threads are resolved. If not, return to step 3.
7. Refresh [PR author notes](pr-author-notes.md), rewrite `status`, `solution`, `history` blocks; post `[builder] [report]` PR + issue comments. Move Building → QA. Clean up worktree.

## Builder exit comments

Builder exit (PR):

```
[builder] [report] ✅ built · round 1
Did: added /api/stream and the client SSE consumer; no schema change, no new deps
✅ Done: AC1 stream opens `streaming.test.ts:12` · typecheck clean · `abc1234`
❌ Not done: AC2 TTFB under load — no load harness here
Next: qa
Local tests: npm test --run streaming
gh-quota-on-exit: graphql=4120/5000 rest=4870/5000
```

Builder exit (issue):

```
[builder] [report] ✅ built · PR #87 @ abc1234
Next: qa
```
