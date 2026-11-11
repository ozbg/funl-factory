# super-board lanes — Tester

Read `common.md` (this folder) first: branch + PR model, PR template, review threads, commenting cadence, self-check.
The rules behind each step are in `../../super-qa/SKILL.md` (zone checks, citations, round cap, evidence).

## `qa` cards

**`qa` cards.** The Tester moves the card Ready → QA itself, creates `issue-<N>-<slug>` from the
base branch, and tests what is already there against the ACs. Tests it writes are committed to
that branch; a PR opens only when there are tests to merge. A failure it cannot fix with tests
alone is filed as a Backlog card (`super-qa-file-bug.sh --column Backlog`) and named in the
handoff. The `qa` card still moves on to Review with the findings.

A live site with no repo is not a board. `/super-qa <url>` tests it on its own.

## Tester (first pass — repo-backed)

1. Pull latest of base; checkout `issue-<N>-<slug>` into worktree `.claude/worktrees/issue-<N>-qa/`.
   A `qa` card has no branch yet: move it Ready → QA, then create the branch from the base.
2. `target.url` set → health-check it first. Unhealthy → Block.
3. Read issue + PR + Builder's handoff comment.
4. **Zone.** Run `python3 .claude/bin/super-board-zone.py` on the diff's files (super-qa → "Zone first").
   Green → move QA → Review with `Did: green zone — no QA lane`, `citation: "none"`. Stop.
   A green screen card is the exception: run step 7b only, then pass or fail as steps 9–10.
5. **Checks** (super-qa → "Checks by zone"). Amber: AC ledger, the zone's bar, the ticket's own
   edge cases. Red: those, plus a test per touched invariant and one mutation per guarded line.
   Accepted limits are never checked. Existing project verifier → affected features only.
6. **Security pass** on red, or amber with `boundary: true` (super-qa → "Security pass").
7. Run the tests. Evidence goes to `.claude/super-board/evidence/<issue>/v<V>/` in the main
   checkout, gitignored. Never commit it, never embed images. The one exception is step 7b.
   An AC that cannot be proven by a test or file is a fail: the merge gate refuses unticked or path-less proof (common.md → "No partial merge").
7b. **Screen match** on every screen card (a `**Mock-up:**` line or a `## Mock-up` block), every
   zone: follow `../../super-qa/references/screen-match.md`. Capture the app and its baseline at
   the same size, list every visible difference, commit the pair under `docs/shape/baseline/`
   and embed it. A difference not under `Cut from mock-up:` and not accepted by a note on the
   card fails the match AC, citing it. A mock-up screen that won't open is never a pass.
8. **Sort findings.** A fail cites `AC<n>`, `I<n>`, `bar: <line>` or `bug: <repro steps>`.
   Anything else is a note. Out-of-scope privacy, data-loss or visible bug → Backlog card via
   `super-qa-file-bug.sh --column Backlog`; it does not fail this card.
9. **Pass** → commit and push test files only (and the 7b pair) → tick the `ac` block with proof
   lines, write `visual` as text for UI (a screen card: the 7b pair), append a `history` row,
   rewrite `status` → `[qa] [report] ✅` PR comment with the AC table (text) and any 7b pair →
   issue comment → move QA → Review. Result
   `citation: "none"`. Clean up worktree.
10. **Fail** → read `loop:rebuild-N` (none = 0). N + 1 ≥ the zone's `max_rounds` (this was the last allowed round) → Blocked with the
    block template, reason 🛡, line `ruling or split: <what keeps failing>`. Otherwise leave the
    failing ACs unchecked with the reason, append a `history` row, rewrite `status` →
    `[qa] [report] ❌` PR comment with the AC table, expected/actual per cited fail and any 7b pair → issue
    comment → label `loop:rebuild-<N+1>` → move QA → Ready. Result `citation: "<first cited>"`.
    Clean up worktree.

## Tester (rebuild — when Reviewer bounced for `[qa]` thread fixes)

1. Worktree as above.
2. Read PR review threads; filter `[qa]` prefix.
3. For each unresolved `[qa]` thread: apply fix to test files, resolve thread.
4. Re-run the ticket's tests. Evidence to `.claude/super-board/evidence/<issue>/v<V+1>/`.
5. Commit + push test files. Verify ALL `[qa]` threads are resolved.
6. Update `ac`, `history`, `status`; post `[qa] [report]` PR + issue comments. Move QA → Review. Clean up worktree.

## Tester exit comments

Tester fail (issue and PR):

```
[qa] [report] ❌ failing · v1
Did: amber · ran AC1–AC2 against `abc1234` · pr-security-review: skipped (amber)
✅ Done: AC2 `tests/streaming.test.ts:42`
❌ Not done: AC1 TTFB 1240 ms (want < 800) — fixed looks like first byte under 800 ms
Next: builder
Local tests: npx playwright test e2e/streaming

| AC | Result | Proof |
|---|---|---|
| AC1 | ❌ | want TTFB < 800 ms, got 1240 ms |
| AC2 | ✅ | `tests/streaming.test.ts:42` |
```

A pass uses the same table. Notes (uncited gaps) go on one `Notes:` line, never on `❌ Not done`.
