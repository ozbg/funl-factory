# super-board lanes — Reviewer

Read `common.md` (this folder) first: branch + PR model, PR template, review threads, commenting cadence, self-check.

## Reviewer

1. Worktree `.claude/worktrees/issue-<N>-review/` from current state of `issue-<N>-<slug>`.
2. **Gate 1** — scan PR threads and their replies. [PR author notes](pr-author-notes.md)
   alone are explanations, not findings. Human questions or change requests in those
   threads still follow the normal review/blocking flow; the marker exempts no replies.
   Never auto-resolve them or bypass GitHub's conversation-resolution requirements.
   If ANY unresolved finding:
   - `[builder]` open → comment, move card Review → Ready.
   - `[qa]` open → comment, move card Review → QA.
   - Both open → bounce to whichever is older; the other gets picked up later.
   - Clean up worktree, exit.
3. Read the issue ACs and the raw diff (code + test files) FIRST and write 2–4 hypotheses of your own — what must hold, where it would break. Only then read the PR description, the `[builder] [report]` comment and Tester's handoff, and check each claim like a hypothesis. Spot-check Tester's evidence (one screenshot at least), read CLAUDE.md / AGENTS.md.
3b. **Prior-report check (review remembers — added 2.5.0).** Load the last Reviewer report on this PR as `prior_report`. One call:
   ```
   gh pr view <PR> --json comments \
     --jq '[.comments[] | select(.body | contains("<!-- super-review:report -->"))] | last | {url, body} // {}'
   ```
   - Empty → first review of this card. Skip to step 4; behave exactly as before.
   - Non-empty → the card was bounced and rebuilt. **Round 1** walks every finding in `prior_report` and marks each one `fixed` / `not fixed` / `no longer applies` (code it pointed at is gone or the AC changed), citing the file:line that proves it. A resolved thread is not proof — check the code.
   - Any cited Blocker `not fixed` → bounce again now: re-open one thread per unfixed Blocker with its original prefix and citation (`[builder]` → Ready, `[qa]` → QA, both → `[builder]` first), `loop:rebuild-N`, and update the Reviewer report: those rows go to `❌ not fixed`. Skip the fresh pass; it would review code that is about to change.
   - An unfixed Note never bounces; its row stays `❌ not fixed`.
   - Otherwise → continue to step 4 for a fresh pass. Do not re-raise a prior finding marked `no longer applies`.
3c. **Zone + round cap.** Tier = the higher of the card's `zone:<tier>` label and `python3 .claude/bin/super-board-zone.py --zones docs/agents/zones.yaml --files <changed files>` (also gives `max_rounds`, `bar`, `invariants`). You may raise a tier with a `zone:<tier>` label, never lower one. `loop:rebuild-N` with N ≥ `max_rounds` → Blocked with the §4 template, `Why blocked: round cap — needs a ruling or split`. Exit.
4. Review the code (logic, conventions) and the tests. **Green card:** skip this — check the builder's AC proof, rerun tests (step 5), go to step 7.
   Severity is two levels. **Blocker** must cite `AC<n>`, an invariant id, `bar: <line>` or `bug: <repro>`; no citation → **Note**. Over-engineering is always a Note; so are missing tests, edge cases, a11y and i18n unless they cite. Deepening opportunities and visible bugs outside the card's scope → file to Backlog (super-review → "Route fixes").
5. **Reviewer-side test rerun** (always — closes the Tester self-verification gap):
   - Pull `issue-<N>-<slug>` into the review worktree.
   - Re-run the test command Tester used (recorded in Tester's PR handoff comment as `Local tests:` line).
   - Tests green → continue to step 6.
   - Tests red → open new `[qa]`-prefixed PR thread quoting the failure output, move card Review → QA with `loop:rebuild-N` (citation `bug: <test command>`), exit. Tester wrote a broken suite; QA owns the fix.
6. **Adversarial mode** (per `truth_gate`, default `red`: red-tier cards only; `off` never; `always` every card): when triggered, spawn 2 sub-agents in parallel:
   - **Code-grounder** — verify cited file:line still exists and matches claims.
   - **Historian** — `git blame` the changed lines, check for ADRs / prior incidents.
   - **Budget cap (added 2026-05-22): each sub-agent ≤50 gh calls.** Prefer local `git blame` / `git log` over `gh api graphql`. If a sub-agent needs >50 calls to reach confidence, it returns `confidence: "insufficient_data"` and the Reviewer flags the card as 🛡 truth-check inconclusive instead of burning the shared quota. See `rate-limit-etiquette.md`.
   - **Brief:** use the fixed sub-agent brief in super-review → "Adversarial mode" verbatim. Never write your own. A sub-agent finding is a Blocker only with a citation.
   - Aggregate into a confidence score (0-100). Compare against `config.truth_threshold` (default 70).
   - **Below threshold** — Reviewer MUST NOT approve. Open a `[reviewer]`-prefixed PR thread quoting the lowest-confidence sub-agent finding, write the full Block template comment (see §4 Block/Skip), move card Review → Blocked with reason tag 🛡 truth-check failed (confidence X/100). The card stays Blocked until human review; the bot's "Why I cannot decide" line names the specific sub-agent finding it could not confirm.
   - **Above threshold** — continue to step 7.
   - **No Reproducer needed** — Tester's tests were re-run in step 5.
7. Decide. Only cited Blockers count; Notes go in the report with no thread.
   - **No Blockers + threads clean + truth ≥ threshold (when it ran) + tests green** → run the **merge protocol** below. Do not move the card to Done any other way.
   - **Code-side Blocker** → open new `[builder]`-prefixed PR thread naming the citation, move card Review → Ready (label `loop:rebuild-N`).
   - **Test-side Blocker** → open new `[qa]`-prefixed PR thread naming the citation, move card Review → QA (label `loop:rebuild-N`).
   - Every bounce puts `citation: "<value>"` (or `"none"` for a Gate 1 bounce) in the structured result.
   - **CI-budget block (💳, added 2026-05-22)** — if remote CI jobs `failed_to_start` due to `Actions budget` AND `config.auto_merge_on_ci_budget_block` is true AND local-evidence is strong (truth ≥ threshold, Tester suite green on rerun in step 5, all `[builder]`/`[qa]` threads clean) → **squash-merge anyway** on local evidence; do NOT move to Blocked. Write the PR's `redcheck` block (`> [!WARNING]` · `🔴 Merged with a failing check: <check> · CI budget block`) and a `[reviewer] [report] ✅ merged · CI-budget bypass` comment on the PR and the issue citing: (a) the failed CI run ID, (b) the Tester pass-count, (c) the truth-gate score. Reason: CI failure-to-start ≠ test failure; with strong local evidence, parking the card wastes pipeline time. This bypass is ONLY for `💳` — never for `🛡` truth-fail, `🔐` missing creds, or `🧑` human-only decisions.
   - **Human gate (destructive schema, API contract, money, auth, live-DB migration)** → write the full Block template (see §4), move card Review → Blocked. A clean PR that only *touches* money, auth or schema is not a blocker — run the merge protocol; the gate's `merge_policy` routes it to a human (exit 7 → 🙋 Blocked).
8. Write the **Reviewer report** on every exit from step 3b on — bounce, block, human gate, merge (a Gate 1 thread bounce reviews nothing and writes none). It is ONE comment per PR, **edited in place** each round: find it by the marker (step 3b's lookup, plus `.url` — the number after `#issuecomment-` is its id) and `gh api -X PATCH repos/<owner>/<repo>/issues/comments/<id> -F body=@<file>`; post a new comment only when none exists. It is what step 3b reads next time, so the first line is the stable marker and every finding keeps its id (writing-standard.md § 4):

   ```
   <!-- super-review:report -->
   [reviewer] [report] ❌ bounced · round 2
   Did: checked R1–R2 against the code; fresh pass skipped (R2 open)
   ✅ Done: R1 fixed `src/api/stream.ts:54`
   ❌ Not done: R2 not fixed `e2e/streaming/ttfb.spec.ts:18`
   Next: builder

   | ID | Owner | Class | Where | Finding | Status |
   |---|---|---|---|---|---|
   | R1 | builder | Bug | `src/api/stream.ts:54` | <one line> | ✅ fixed |
   | R2 | qa | Verification miss | `e2e/streaming/ttfb.spec.ts:18` | <one line> | ❌ not fixed |
   | R3 | builder | Over-engineering | `src/api/retry.ts:1` | <what it builds → smaller thing> · note | open |
   ```
   Blocker rows carry their citation in the Finding cell (`· blocker · AC2`). Status words in the header: `merge-ready` · `bounced` · `blocked` · `human-gated` · `merged`. Keep every row across rounds; update its Status (`open` · `✅ fixed` · `❌ not fixed` · `no longer applies`). New findings take the next free id. Every finding names its class — Gap / Bug / Verification miss / Scope drift / Over-engineering (super-review → "Classify findings"); a checked hypothesis that held is not a finding, it goes on the `✅ Done` line.
9. Clean up worktree.

## Merge protocol (Reviewer only — added 2026-08-06, issue #9)

Builder opens every PR as a **draft**, and GitHub will not merge a draft: `gh pr merge --auto`
on a draft queues forever and never fires. A run that skipped this step produced two
substantial builds and landed **zero commits on `main` in six hours**. The Reviewer must
walk these steps in order, and the card **must not reach Done until the merge is confirmed
on the base branch**.

```
1. Mark ready      gh pr ready <PR>                     # idempotent; no-op if already ready
2. Merge through the gate (step 5), pinned to the reviewed head — never a bare
   `gh pr merge`. The gate applies `merge_policy` (who merges; `default: "human"`
   keeps a person on every merge) and `migrations` (which databases the robot may
   migrate) itself; the Reviewer does not second-guess either, it routes the exit code.
3. Confirm the merge LANDED, do not trust the exit code:
     gh pr view <PR> --json state,mergeCommit -q '.state + " " + (.mergeCommit.oid // "none")'
     Expect: MERGED <sha>.  Then verify the sha is reachable from the base branch:
     git fetch origin <base> && git merge-base --is-ancestor <sha> origin/<base>
4. Only after step 3 passes: close the issue, move card Review → Done, rewrite `status` (`> [!TIP]` ✅ Merged) and append the `history` row, post the `[reviewer] [report] ✅ merged` comment
   citing the merge commit sha.
5. Merge through the gate, never with a bare `gh pr merge`. Record the head you
   reviewed when review passes, and hand it to the gate:
     HEAD=$(gh pr view <N> --json headRefOid -q .headRefOid)   # at the moment review passes
     bash .claude/bin/super-board-merge-gate.sh --config <config> --pr <N> --expect-head "$HEAD" \
       --subject "<PR title>" --body-file <msg.md>
   <msg.md> = the PR's commit bullets, deduplicated, plus `Closes #<issue>` (writing-standard.md § 1).
   The gate takes the merge mutex, checks the PR head is still $HEAD, merges the CURRENT
   base into a scratch worktree at $HEAD, runs `config.verify_commands`, and only then
   squash-merges with `--match-head-commit $HEAD`. After a merge it runs `cleanup-wt --post-merge`
   when the `.claude/hooks/cleanup-wt.py` hook is installed (local only; a cleanup failure never changes the exit). Route by exit code:
     9 → verification-readiness: halt the run and preserve card, approval, claims, and worktree. Repair `config.verify_commands` with the project's real checks, then restart explicitly. Never bounce to Build, retry a rebase, or bypass the gate.
     0 → merged; continue to step 4
     2 → the branch no longer builds against the base → **rebase pass** (see below)
     3 → GitHub refused after a green verify (branch protection, required check)
          → Blocked with the §4 template; this one really is a human's
     4 → another card holds the merge lock → leave the card in Review, next wave retries
     5 → the base does not merge in cleanly → **rebase pass** (see below)
     6 → the PR head is not the commit you reviewed (a push after review, or during
          verify). Your evidence is void: leave the card in Review with a `[reviewer]`
          comment naming both shas; the next wave reviews the new head
     7 → merge_policy: a human merges this one. Stdout carries one
          `human-gate: <money|auth|schema|size|default|policy> — <evidence>` line per
          hit. Card Review → **Blocked** with the 🙋 template: `Why blocked` names the
          category and evidence; `To unblock` = "[ ] review PR #<P> and merge it
          yourself" OR "[ ] comment `done` to approve — the next wave merges it";
          label `needs-you`, `blocked-by: -`. A human merge moves the card to Done the
          usual way; a `done` brings it back through `resume`, and the gate clears the
          policy hold only with a verified trusted approval of the current request.
     8 → 🙋 needs you. Stdout carries one `needs-you: <command>` line per human step
          (migration for an env outside `migrations.allowed_envs`, an allowed migrate
          command that failed, a `needs-you:` line in the PR body,
          `migrations.human_steps`). Card Review → **Blocked** with the 🙋 template
          (block-template.md → "🙋 Needs you"), the commands copied verbatim into
          `To unblock`, label `needs-you` on issue and PR, `blocked-by: -`. When the
          human comments `done` after the current pinned request, the wave planner
          verifies their permission and the head before resuming Review. For exits
          7 and 8, copy the gate's `approval-request:` line into the canonical issue
          block; link it from the PR without duplicating the request.
   → do NOT leave a card in Review on exit 2, 3, 5, 7 or 8. A card left in Review is
     re-picked next wave and re-reviewed forever, which is the re-dispatch waste
     tracked in issue #10. Exits 4 and 6 are the exceptions: 4 simply queued, and
     6 needs a fresh review of a commit nobody has reviewed yet.
```

**Ordering invariant.** `Done` means "merged" — or closed as not planned on purpose, with a 🤷
comment (there is no Skipped column). If step 3 cannot be satisfied, the card goes to Blocked,
never Done. Anything that reads the board — status, halt gate, the
landed-work progress signal — depends on Done meaning the code is on the base branch.

## The rebase pass

A merge conflict is not a human decision. It is a build task, and it belongs in the lane that is
allowed to push.

**Why this changed.** On 2026-08-20 a PR reached Review with 264 tests green and a 94/100 truth
gate, and could not merge: eleven hunks across five files, every one of them two tickets adding
members to the same interface on purpose. The Reviewer refused — correctly, because **the Reviewer
never pushes to the branch it is judging** — and moved the card to `Blocked`. Two further cards
were waiting on that one and parked behind it. The resolution, when a human finally did it, was
"keep both sides" in twelve of the thirteen hunks and one block of setup code moved into a
function. Three cards lost a wave to a mechanical edit.

**The rule.** On merge-gate exit 2 or 5:

```
[ ] label the issue `loop:rebase`
[ ] move the card Review → Ready  (NOT Blocked)
[ ] comment on the PR: which files conflicted, or which verify command failed, and its output
```

The Builder picks it up as an ordinary pass, routes `mattpocock-skills:resolving-merge-conflicts`,
and pushes. Its finish line is a **green verification**, not an empty `git diff --diff-filter=U`:
when a shared interface grows on both sides, the files git merged cleanly are where most of the
work is. In the run above, thirteen conflict hunks were followed by ten further files that merged
without a marker and still failed to typecheck.

`Blocked` is still correct when the rebase itself cannot be done: the two sides genuinely disagree
about behaviour, or resolving requires a product decision. That is a `❓` or `🧑` block with the
usual template — and, per §4, a `blocked-by:` line.

## Reviewer exit comments

Reviewer merge (issue):

```
[reviewer] [report] ✅ merged · `ef67890` on staging
Did: path Build → QA ❌ v1 → Build → QA ✅ v2 → Review ✅ · truth 95/100
Next: none
```
