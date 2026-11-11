# super-board run — orchestrator contract

**Scope:** the orchestrator's shared rules: preconditions, label routing, halt gates, the wave-start sweep, done conditions. The wave loop is in `run-workflow.md`. Lane agents do not read this file: each loads its own lane file in `lanes/` (`build.md`, `qa.md`, `review.md`) plus `lanes/common.md`.

## Required GitHub reads can pause a run

Use `.claude/bin/super-board-github-read.py` for required API evidence. It retries
one failed read at most twice (three total attempts); invalid queries or missing
authority halt immediately. Exit **79** means stop dispatch and pause the current
run. Never substitute an empty board, OPEN issue, full quota, or empty diff.
Check the helper's `--check` before each write, migration, or merge. Preserve
worktrees, claims, card/approval state, and the shared local halt record. Report
the reason locally when GitHub cannot accept a comment. Do not blindly retry a
mutation: a lost response may conceal a successful write. Confirm its remote
outcome once service is available before resuming. Recovery and workflow
checkpoint limitations: [run-workflow.md](run-workflow.md#required-github-evidence-and-a-paused-run).

## Orchestrator delegation contract (NON-NEGOTIABLE)

**Super-board is an autonomous trader. The interactive Claude session that invokes `super-board run` is an orchestrator, NOT a worker.** Its only jobs are:

1. Verify preconditions (see table below).
2. Run the wave loop in `run-workflow.md`.
3. Report one short block per wave back to the user.

The orchestrator MUST NOT:

- Build, test, review, or fix issues itself. All product work is delegated to workflow lane agents.
- Patch the dispatcher script or skill files unless the user explicitly asked for that change. Drift fixes belong in a follow-up issue, not a side-edit during a run dispatch.
- Wait for workers to finish. Workers run in their own contexts and write evidence back to the issue + PR. The orchestrator's output to the user is the dispatch confirmation, not the run result.
- Hold context for multi-card progress. Workers own the state machine via the GitHub Project board + assignee mutex + inflight lock files.

If a problem surfaces during the run (bug in the dispatcher, missing skill, stuck card), the orchestrator should: (a) capture the symptom, (b) tell the user what they observed, (c) wait for explicit approval before touching anything. **Do not silently expand the task into "fix the dispatcher while you're at it" — that's the orchestrator becoming a worker.**

When the user asks for diagnostics or a fix, prefer dispatching a focused named subagent over doing the work in the orchestrator session, so the orchestrator's context stays small and the work stays inspectable in its own log.

## Intro shown when run starts

```
🤖 super-board run
─────────────────────────────────────────────────────────
Purpose: the autonomous loop. Drains your GitHub Project board.

Progress: ✅ onboard  →  ✅ lint  →  🤖 run (you are here)
─────────────────────────────────────────────────────────
```

## Optional post-run learning

The installed-skill adapter is described in [`calibration.md`](calibration.md).
It runs after verified selected work finishes, never within a product lane.
A supervising host may prepare the bounded receipt and delegate the external
skill after normal final reconciliation.

## Preconditions (verified before any worker dispatches)

| Check | Action on fail |
|---|---|
| Usable verification commands | Run `python3 .claude/bin/super-board-verification-ready.py --config <config>`. Exit 9 halts setup before dispatch: configure the owning project's checks, then restart explicitly. |
| Active config exists | Halt: "Run `super-board onboard` first." |
| Project + required columns exist | Halt: "Project / columns missing. Run `super-board onboard` to repair." |
| `gh auth` valid with required scopes | Halt: "Re-auth: `gh auth refresh -s project,read:project,repo`." |
| `pre-flight.md` all items `[✓]` | Halt: "Pre-flight incomplete — fix these: [list]." |
| No issues missing ACs in active columns | Halt: "N issues need clarification. Run `super-board lint`." |
| Clean git working tree on base branch | Halt: "Working tree dirty. Stash or commit before running." |
| Legacy worktrees | If `.worktrees/issue-*` exists, halt before dispatch. Stop its worker, inspect/preserve edits, then `git worktree move` it to the matching `.claude/worktrees/` path. Never delete it as part of an upgrade. |
| Stale worktree scan | Scan only `.claude/worktrees/issue-<N>` and `issue-<N>-build/qa/review`. If its named branch is gone, use `git worktree remove` without force. Keep detached, dirty, locked, unregistered, or unrelated folders; log failures for inspection. A missing board label alone is not permission to delete work. |
| Production-merge guard | If `base_branch == "main"` AND `human_approves_merge == false` AND `merge_policy.default != "human"` AND `merge_policy.allow_auto_on_production != true` AND production-detection signals fire (see onboard → base branch), halt with: `🛡 Refusing to start: would auto-merge to production main. Set merge_policy.default: "human", switch base_branch to staging, or re-run super-board onboard to opt in explicitly.` |
| Database reach | Run every `migrations.checks[env]` for an env in `allowed_envs` (read-only, e.g. `supabase migration list --db-url …`). On failure halt with its error: "Migrate URL for <env> does not connect — fix it before a wave builds work the gate cannot land." |
| GraphQL rate-limit guard | Before each wave, `bash .claude/bin/super-board-gh-guard.sh check 200` (one plain call — it reads GraphQL's own `rateLimit`, because `gh api rate_limit` misreports the GraphQL bucket). If GraphQL remaining < 200, sleep until reset. Prevents the run from dying mid-loop when the user has burned quota in another tool. |

## Lanes and label routing

One board shape (v3.0.0): Backlog · Ready · Building · QA · Review · Blocked · Done. A card's
label picks its path — three labels, no per-board variant:

| Label | Path | Why |
|---|---|---|
| `feature` | Ready → Building → QA → Review → Done | new behaviour: build, test, review |
| `bug` | Ready → Building → QA → Review → Done | a fix: same lanes |
| `qa` | Ready → QA → Review → Done | test what already exists; skips Building |
| none | as `feature` | the classifier adds `feature` or `bug`; it never adds `qa` |

`super-board-wave-plan.sh` puts `lane` (`build` / `qa` / `review`) and `labels` on every picked
card; `super-board-wave.js` sends a `qa` card from Ready straight to the Tester.

**Green skips QA.** When the Builder's zone step reports `green` (and no `zone:amber`/`zone:red`
label), the Builder moves the card Building → Review and the wave runs the Reviewer next, with
no Tester. A `qa` card still goes to QA, and so does a screen card (a Mock-up line or block),
for the screen match. A ticket with a `Zone:` line skips the classify
agent: green, amber, red mean low, medium, high complexity.

```
Builder:   Ready → Building → QA
           worker   = super-build skill
           worktree = .claude/worktrees/issue-<N>-build/
           branch   = issue-<N>-<slug>  (created here, persists across lanes)

Tester:    QA → Review            (a `qa` card: Ready → QA → Review)
           worker   = super-qa skill (issue-scoped mode)
           worktree = .claude/worktrees/issue-<N>-qa/
           branch   = same issue-<N>-<slug>  (a `qa` card: the Tester creates it)

Reviewer:  Review → Done
           worker   = super-review skill
           worktree = .claude/worktrees/issue-<N>-review/
           branch   = same issue-<N>-<slug>  (squash-merged on approval)
```

**`qa` cards** (Tester detail: `lanes/qa.md`). The Tester moves the card Ready → QA itself, creates `issue-<N>-<slug>` from the
base branch, and tests what is already there against the ACs. Tests it writes are committed to
that branch; a PR opens only when there is something to merge (tests, evidence). A failure it
cannot fix with tests alone is filed as a `bug` card (`super-qa-file-bug.sh`) and named in the
handoff — the `qa` card still moves on to Review with the findings. The Reviewer reviews the QA
report and any test diff.

A live site with no repo is not a board. `/super-qa <url>` tests it on its own.

## Halt gates

| Gate | Action |
|---|---|
| Round cap: a cited QA or Review bounce when the card has `loop:rebuild-N` and N + 1 ≥ the zone's `max_rounds` (green 1, amber 2, red 3 rounds in all; tier = the higher of `super-board-zone.py` on the PR's files and any `zone:<tier>` label) | The wave moves the card to Blocked with the §4 template (reason 🛡), `round cap: needs a ruling or split`, never back to Building; continue run |
| A QA or Review bounce with no citation (`AC<n>`, `I<n>`, `bar: …`, `bug: …`) | The wave rejects it: logged `uncited-bounce`, the finding is a Note and the card moves on to Review |
| No card progresses for 3 consecutive waves | Halt, dump state |
| Auth expires mid-run | Halt, ping user with refresh instruction |
| Pre-flight check fails on re-validation | Halt with the specific missing item |
| Merge conflict, or a stale branch the merge gate rejects | Move card to **`Ready`** with the `loop:rebase` label — NOT Blocked. See `lanes/review.md` → "The rebase pass" |
| User-defined time/budget window reached | Graceful halt: finish in-flight workers, no new dispatches |
| Destructive action would be required (prod deploy, db drop, secret rotation) | Halt, never proceed; move card to Blocked with reason 🛡 |
| Block-rate alert: Blocked count > `config.block_rate_alert_pct` of initial Ready | Post the breakdown in the run report, continue run |

### The wave-start sweep

Before planning any wave, `super-board-wave-plan.sh` reports five lists the orchestrator must act on
**before** launching:

- **`sweep`** — `Blocked` cards whose blockers have all closed. Move each to `Ready` and comment
  naming what cleared it (`clearedBy` carries the numbers). They then join this very wave.
- **`stranded`** — `Building` cards with no claim. Nothing selects from Building,
  so a wave stopped mid-build leaves them there forever. Remove any leftover build worktree, keep
  the branch, move the card to `Ready`, and comment naming the branch.
- **`resume`** — 🙋 `Blocked` cards whose newest pinned request has a later `done`
  from a human with verified write, maintain or admin permission, for the current
  PR head. Move each to **Review**; `needs-you:done` may be kept as a display label
  only. Do not create or copy approval evidence. The Reviewer re-runs the gate,
  which independently checks the request, current policy/steps and head, verifies
  the build, and runs allowed migrations. New code or a newer request needs fresh
  human approval; a label or old bare comment cannot bypass that hold.
- **`refreshApproval`** — a PR head changed while its card was still `Blocked`.
  Move it to **Review** and remove stale `needs-you:done` display labels. The Reviewer
  reviews the new code and lets the gate produce a new pinned request, then returns
  it to **Blocked** for a fresh human reply. This is not an approved resume.
- **`flag`** — cards whose `## Blocked by` section could not be parsed. Leave them where they are
  and comment asking for the line to be fixed, quoting the `why`. Never guess: a card treated as
  free on an unreadable line gets built against a base that does not have what it needs.

**Why the sweep exists.** `Blocked` used to be terminal. A card parked naming the issue it waited
for, that issue later merged, and nothing ever read the note back — the run's own done-condition
("only Blocked/Done cards remain") meant a closing blocker could not wake anything. Five
cards sat that way on a real board until a human opened it and noticed.

## Done conditions

The loop exits cleanly when:
- All active-pipeline columns are empty; OR
- Only Blocked/Done cards remain (Backlog is not part of a run); OR
- A halt gate fires.

## Run manifest

```
docs/super-board/runs/<YYYY-MM-DD>-<slug>.md
```

Records: config used, columns, target, per-card history (claim → completion → next column with evidence links), halt gates, final counts, per-lane wall-clock, resume command.

## Notification cadence

- **Start** — project, initial column counts, link to live status: `super-board status`.
- **Per card completion** — `✅ Tester → #41 passed all checks → Review`.
- **Per Block** — short headline + reason tag (`⛔ #19 blocked → 🔐 missing OPENAI_API_KEY`) + link to the full §4 template comment on the issue.
- **Every 10 dispatches** — brief column-count snapshot.
- **Block-rate alert** — when Blocked count exceeds `config.block_rate_alert_pct` of initial Ready: ping with breakdown ("11/30 Ready cards blocked: 🔐×6, 💳×3, ❓×2 — see project board"). One-shot per run (does not re-fire).
- **Final** — end column counts, total moved to Done, blockers (with reason-tag breakdown), total wall-clock.
