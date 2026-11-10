# super-board lanes — Tester

Read `common.md` (this folder) first: branch + PR model, PR template, review threads, commenting cadence, self-check.

## `qa` cards

**`qa` cards.** The Tester moves the card Ready → QA itself, creates `issue-<N>-<slug>` from the
base branch, and tests what is already there against the ACs. Tests it writes are committed to
that branch; a PR opens only when there is something to merge (tests, evidence). A failure it
cannot fix with tests alone is filed as a `bug` card (`super-qa-file-bug.sh`) and named in the
handoff — the `qa` card still moves on to Review with the findings. The Reviewer reviews the QA
report and any test diff.

A live site with no repo is not a board. `/super-qa <url>` tests it on its own.

## Tester (first pass — repo-backed)

1. Pull latest of base; checkout `issue-<N>-<slug>` into worktree `.claude/worktrees/issue-<N>-qa/`.
   A `qa` card has no branch yet: move it Ready → QA, then create the branch from the base.
2. `target.url` set → health-check it first. Unhealthy → Block.
3. Read issue + PR + Builder's handoff comment.
4. Build issue-scoped test plan: one observable test per AC.
4a. Existing project verifier → follow `../../super-qa/references/project-verifier.md`
for affected feature selection, actual host readiness and new run-owned proof.
Record uncovered/stale optional coverage alongside ordinary issue AC checks.
4b. **Test-gap check** (super-qa → "Test-gap check (after build)"): map every AC to unit / component / e2e tests, hunt edge cases, write the High gaps red-first. A High gap that needs app code changed → Fail (step 7) with the gap list. Medium/Low go in the handoff under `Test gaps (not written)`.
4c. **Security pass** (super-qa → "Security pass (every PR)"): run `pr-security-review` on the PR's diff against its base. Each kept finding is a failing check → Fail (step 7) with a `[builder]` thread on its file:line. Skill missing → Block.
5. Run the tests. Capture evidence to `docs/super-board/runs/issue-<N>-qa-v<N>/`. For UI/visual ACs, capture screenshots at the standard viewports (1920×1080 desktop, 1024×768 tablet, 375×667 mobile). Commit the screenshots to the issue branch BEFORE writing the comment (the markdown image URLs depend on the files being present on the branch).
6. **Pass** → commit test files + screenshots to same branch + push → tick the `ac` block with proof lines, write `visual` for UI, append a `history` row, rewrite `status` → `[qa] [report] ✅` PR comment with results + evidence path **+ inline screenshot embeds** (see "Screenshot embed format" below) → issue comment with the SAME inline screenshot embeds → move card QA → Review. Clean up worktree.
7. **Fail** → leave failing ACs unchecked with the reason, append a `history` row, rewrite `status` → `[qa] [report] ❌` PR comment with per-AC expected/actual + repro file:line + evidence path + "what fixed should look like" **+ inline screenshot embeds of the broken state** → issue comment with the same inline screenshots (showing what's wrong) → increment rebuild counter → move card QA → Ready (label `loop:rebuild-N`). Clean up worktree.

### Screenshot embed format (mandatory on every QA exit — added 2026-05-22)

Inline screenshots in the GitHub comment using raw-URL markdown so they render directly on the issue/PR page without anyone having to clone the repo:

```markdown
| Viewport | Screenshot |
|---|---|
| Desktop 1920×1080 | ![desktop](https://github.com/<OWNER>/<REPO>/raw/<SHA>/docs/super-board/runs/issue-<N>-qa-v<V>/desktop.png) |
| Tablet 1024×768  | ![tablet](https://github.com/<OWNER>/<REPO>/raw/<SHA>/docs/super-board/runs/issue-<N>-qa-v<V>/tablet.png) |
| Mobile 375×667   | ![mobile](https://github.com/<OWNER>/<REPO>/raw/<SHA>/docs/super-board/runs/issue-<N>-qa-v<V>/mobile.png) |
```

Substitution rules:
- `<OWNER>/<REPO>` — read from `git remote get-url origin` (parse owner/name).
- `<SHA>` — the commit that added the screenshots (`git rev-parse HEAD` right after committing them), never a branch name: the branch is deleted on merge and a branch URL breaks. Push before you post.
- `<N>` and `<V>` — issue number + QA version (`v1`, `v2`, ...).
- File names — keep them stable and descriptive (`desktop.png`, `tablet.png`, `mobile.png`, or `before-fix-desktop.png` / `after-fix-desktop.png` for rebuild-pass cases).

For non-visual ACs (API tests, migration SQL, etc.), skip the screenshot block but keep the evidence-path line. Tests output (logs, REPORT.md) still goes in the evidence folder.

If a screenshot file is >5MB, downscale to ≤1920px wide before committing; GitHub's image rendering chokes on huge images.

## Tester (rebuild — when Reviewer bounced for `[qa]` thread fixes)

1. Worktree as above.
2. Read PR review threads; filter `[qa]` prefix.
3. For each unresolved `[qa]` thread: apply fix to test files, resolve thread.
4. Re-run full test suite for the ticket.
5. Save evidence to `runs/issue-<N>-qa-v<N+1>/`.
6. Commit + push. Verify ALL `[qa]` threads are resolved.
7. Update `ac`, `history`, `status`; post `[qa] [report]` PR + issue comments. Move QA → Review. Clean up worktree.

## Tester exit comments

Tester fail (issue and PR — screenshots mandatory for any UI-touching AC):

```
[qa] [report] ❌ failing · v1
Did: ran AC1–AC2 on desktop + mobile against `abc1234`
✅ Done: AC2 CLS 0.04
❌ Not done: AC1 TTFB 1240 ms (want < 800) — fixed looks like first byte under 800 ms
Next: builder
Local tests: npx playwright test e2e/streaming

| Viewport | Screenshot |
|---|---|
| Desktop 1920×1080 | ![desktop](https://github.com/<OWNER>/<REPO>/raw/<SHA>/docs/super-board/runs/issue-42-qa-v1/desktop.png) |
| Mobile 375×667 | ![mobile](https://github.com/<OWNER>/<REPO>/raw/<SHA>/docs/super-board/runs/issue-42-qa-v1/mobile.png) |
```

A pass uses the same table with screenshots of the **working** UI per AC.
