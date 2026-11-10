# super-board lanes — shared lane contract

Every lane (Builder, Tester, Reviewer) reads this file with its own lane file: `build.md`, `qa.md` or `review.md` in this folder. The orchestrator's material (preconditions, routing, halt gates, sweep) is in `../run.md`.

## Branch + PR model — one branch, one PR per issue

Format: **`issue-<N>-<kebab-title>`** (no lane prefix).

Example: `issue-42-add-chat-streaming`.

There is **exactly one branch per issue** and **exactly one PR per issue**. All three lanes work on the same branch in their own worktrees:

- Builder creates the branch off `config.base_branch`, writes code, commits + pushes, opens a **draft PR**.
- Tester checks out the same branch in a fresh worktree, adds tests, commits to the same branch, pushes.
- Reviewer is the **only lane that merges**. On approval: squash-merges PR into `base_branch`, deletes the branch.
- If `config.merge_policy` says a human merges (`default: "human"`, or a money / auth / schema / size hit), the merge gate exits 7 and the Reviewer parks the card in Blocked for a human click instead.

## PR description template

Format: `writing-standard.md` § 2. Title = the commit subject format
(`✨ [feat] chat: stream replies`). The body is marker blocks; each lane rewrites only its own
with `.claude/bin/super-board-pr-body.sh --pr <P> --block <name> --expect-head <sha>
(--body-file | --append-file) <md>`. The script refuses (exit 6) when the PR head moved since you
read it — re-read, then redo the edit. Builder opens the PR with every block filled
(`super-board-pr-body.sh --skeleton` prints the empty markers).

| Block | Builder | Tester | Reviewer |
|---|---|---|---|
| `status` (alert card) | writes | rewrites on exit | rewrites on exit |
| `problem` (lettered steps under Where, screenshot embedded) | writes from the ticket's Context | — | — |
| `solution` (plain bullets, `Docs:` bullets last) | writes, updates on rebuild | — | — |
| `ac` (checklist + one proof line each) | writes all unchecked | ticks with proof, or leaves unchecked with the reason | unticks one it disproved |
| `history` (Lane · Done · Time · Details) | appends a row | appends a row | appends a row |
| `visual` (Before \| After, UI only) | — | writes | — |
| `risk` (🟢/🟡/🔴 + one line, Door, Blast radius) | writes | — | adjusts |
| `redcheck` (only when merged with a failing check) | — | — | writes |

```markdown
<!-- sb:status -->
> [!NOTE]
> ⏳ In QA · round 1 · ✅ 0/2 AC · Closes #<N> · head `<sha>`
<!-- /sb:status -->

<!-- sb:problem -->
## Problem
- **Where:** <page>, `<route>`
  - a. <step>
  - b. <step>
- **Who:** <who sees it>
- **What happened:** <one line>

![<page> · desktop](https://github.com/<OWNER>/<REPO>/raw/<sha>/<path>.png)
<!-- /sb:problem -->

<!-- sb:solution -->
## Solution
- <one change per bullet>
- Docs: <url> — <the one fact it settled>   (or: Docs: none needed — no third-party surface)
<!-- /sb:solution -->

<!-- sb:ac -->
## Acceptance criteria
- [ ] <AC1 text>\
  ↳ not verified yet: QA has not run
- [ ] <AC2 text>\
  ↳ not verified yet: QA has not run
<!-- /sb:ac -->

<!-- sb:history -->
<details><summary>Iteration history</summary>

| Lane | Done | Time | Details |
|---|---|---|---|
| 🔨 builder | ✅ | <super-board-pr-body.sh --time> | draft · `<sha>` |

</details>
<!-- /sb:history -->

<!-- sb:risk -->
## Risk
🟢 **Low** · <one line: what could break and what limits it>
- **Door:** <two-way | one-way> · <how to undo, or why it cannot be undone>
- **Blast radius:** <short label> · <who breaks if this is wrong>
<!-- /sb:risk -->
```

History rows by lane: `🔨 builder` · `🔍 qa` (`❌ v1` / `✅ v2`, details = evidence folder) ·
`🧐 reviewer` (`❌ bounced` / `✅ merged`, details = finding ids or `squash <sha>`). Time comes
from `super-board-pr-body.sh --time --config <cfg>` (config `timezone`).

Status card lines: `> [!NOTE]` + `🔨 Building` / `⏳ In QA` / `⏳ In review · round N` ·
`> [!TIP]` + `✅ Merged · <sha>` · `> [!WARNING]` + `🛑 Blocked · <reason>`. Each names the AC
count and the head commit, so evidence is never read against a different one.

No "Not verified" and no "Next" section: an unchecked AC with its one-line reason says what is
not proven. Merged with a failing check (the 💳 CI-budget bypass) → the Reviewer writes the
`redcheck` block first:
`> [!WARNING]` / `> 🔴 Merged with a failing check: <check> · <why it was safe>`, and names the
check in `risk` too.

## PR review-comment threads — prefix + resolution protocol

Reviewer findings use **line-level review comments** (resolvable threads). Each finding MUST start with the lane that owns the fix — `[builder]`, `[qa]` or `[reviewer]` — then a label (`[blocker]`, `[issue]`, `[suggestion]`, `[nit]`, `[question]`, `[praise]`; writing-standard.md § 4). Read `[QA]` and `[review]` on older PRs as `[qa]` and `[reviewer]`. [PR author notes](pr-author-notes.md) have their own format; read all replies before treating a thread as explanation only.

Examples:

```
src/api/stream.ts:54   [builder] [blocker] uses `new Date()` — replace with `clock.now()`.
e2e/streaming/ttfb.spec.ts:18   [qa] [issue] spec asserts status only — add a TTFB assertion.
```

**Resolution rules (each lane only scans the current branch's PR):**

| Lane exiting | Must resolve | Refusal action |
|---|---|---|
| Builder (Building → QA) | All `[builder]` threads on this PR | Stay in Building, fix, then exit |
| Tester (QA → Review) | All `[qa]` threads on this PR | Stay in QA, fix, then exit |
| Reviewer (approving merge) | All findings and human requests; any conversations GitHub requires resolved | Bounce: `[builder]` open → Ready; `[qa]` open → QA; unresolved human decision → Blocked |

Threads are resolved via `gh api graphql` `resolveReviewThread` mutation when the fix is committed.

## Commenting cadence (issue + PR, every lane)

Every lane writes BOTH on every exit, in the comment format of writing-standard.md § 4:

```
[<role>] [<label>] <status-emoji> <status> · <context>
Did: <one line>
✅ Done: <what passed or landed, with sha / file:line / command>
❌ Not done: <what failed or was skipped, and why>   (omit when nothing)
Next: <builder | qa | reviewer | Eric | none>
```

- Role = who writes it: `builder` · `qa` · `reviewer` · `collect` · `orchestrator`. Label for a
  lane exit is `report`; `blocker` for a Block comment.
- ≤ 8 lines. Evidence before prose. An unchecked thing is never implied to pass.
- NEVER list changed files — the PR shows them. No restating the issue, no adjectives.
- Machine lines go last and do not count: `Local tests:` (Tester and Builder, the exact command
  the Reviewer reruns), `gh-quota-on-exit:`, `blocked-by:`.
- Run the prose through `humanizer` when installed (else the plain-words rules in
  writing-standard.md).
- The **issue comment** is the same header plus the PR link; the PR comment carries the detail.

Block exits use the same header (`[<role>] [blocker] 🛑 blocked`) and the fields of
`block-template.md`. A card dropped on purpose (out of scope, won't do) is closed as not planned
and moved to Done with a `[<role>] [report] 🤷 dropped · <reason>` comment — there is no Skipped
column.

## Root-cause hash (used by the rebuild-cap gate)

To detect "same root cause" without depending on a model classifier, each lane writes a deterministic hash to its failure handoff comment:

```
root-cause-hash: <sha256 first 12 hex chars>
```

The hash inputs (joined with `|`):

1. Lane (`build` / `qa` / `review`).
2. Error class — first matched: `test_assertion`, `test_runtime`, `build_fail`, `lint_fail`, `merge_conflict`, `network`, `auth`, `quota`, `other`.
3. First 3 unique `file:line` frames from the captured stack trace / test output (sorted, normalized — strip absolute paths to repo-relative).

Two consecutive failures on the same card with **identical hash** AND **same lane** count as the same root cause. Hits `rebuild_cap` → Blocked.

Different hash on the same card resets the counter — the bot recognizes that progress has been made even if the card hasn't reached Review yet.

## Worker rate-limit etiquette (read before any burst of gh calls)

Workers share the orchestrator's gh-auth token bucket. Every worker MUST follow `rate-limit-etiquette.md` (in this directory):

- Move and read cards with `.claude/bin/super-board-card.sh --config <cfg> move <issue> <Status>` / `status <issue>` — 1 GraphQL point. Every "move card X → Y" in the lane lifecycles means this call. Comments, labels and PR reads go over REST (`rate-limit-etiquette.md` → "Price list").

- Source `scripts/super-board-gh-guard.sh` at worker start.
- Call `sb_gh_guard_check 200` before any burst of gh calls (thread reads, sub-agent spawn, exit verification).
- Adversarial sub-agents are capped at 50 gh calls each — prefer `git blame` (local) over `gh api graphql`.
- Final PR handoff comment MUST include `gh-quota-on-exit: graphql=<n>/5000 rest=<n>/5000` (use `sb_gh_guard_summary`).
- On 403 / secondary-rate-limit: sleep 60s, re-check at threshold 500, then resume.

## Worker self-check (mandatory on exit, every lane)

Before releasing the claim assignee and exiting, every worker MUST verify:

- [ ] Issue comment AND PR comment both written (per "Commenting cadence" above).
- [ ] Card column move's mutation returned success. **Trust the exit code of `super-board-card.sh move`** — a re-read of the board was the per-worker quota tax (`rate-limit-etiquette.md` §3). If the mutation returned non-zero, preserve its unknown outcome, leave the assignee in place, and pause the run locally. Reconcile the remote card state before any repeat; never blindly retry a write or depend on a successful halt comment.
- [ ] Claim assignee released (`gh issue edit --remove-assignee <bot_identity>`) and the descriptive `loop:in-*` label removed.
- [ ] On failure handoff: `root-cause-hash:` line is present in the PR handoff comment (per "Root-cause hash" above).
- [ ] On Block/Skip exit: the full template from `block-template.md` is populated on BOTH the issue and the PR (if a PR exists); the reason emoji is one of the nine in the vocabulary table (🔐 💳 🔑 ❓ 🛡 🧑 🤷 📦 🎨).
- [ ] `gh-quota-on-exit:` line appended to PR handoff comment.

A worker that cannot satisfy this checklist must NOT release its claim. It either fixes the gap and re-checks, or — if the gap itself is structural (e.g., GitHub API refusing to move the card) — it leaves the assignee in place and writes a halt comment so the run's no-progress halt gate can fire deterministically.
