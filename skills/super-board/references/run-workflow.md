# super-board run — workflow backend contract

The only backend: the orchestrator stays in-session and drains the board in
waves of the `super-board-wave` workflow. Preconditions, label routing, halt
gates, the wave-start sweep and done conditions come from `run.md`; lane
lifecycles, branch/PR model, comment cadence and Block templates come from
`lanes/` (`build.md`, `qa.md`, `review.md`, `common.md`).

## Required GitHub evidence and a paused run

Required reads use `.claude/bin/super-board-github-read.py --kind <shape> -- <gh args>`.
Three total attempts means the first attempt plus two retries of that same read;
unrelated successful calls do not reset its failures. Invalid GraphQL queries,
authentication, and permission errors stop immediately. Do not retry mutations.
A payload that misses an agent-facing `--kind` shape (`READ_SHAPES` in
`workflows/super-board-wave.js`), or any read the caller reshaped with `--jq`,
`-q` or `--template` that then misses its shape (e.g. `--kind quota` over a
trimmed `rate_limit`), exits 64 for that call only, printing the valid form; it
never halts the run. A bad `gh` flag, an unknown `--json` field or a 404 inside a
readable repo is the same: that call fails, the run continues. Fixed-command
scripts set `SB_GITHUB_READ_STRICT=1`.

Exit **79**, a workflow result with `halted: true`, or a failed `--check` ends this
run. Check the helper's `--check` before claims, board/comment writes, each new
lane/wave, and all migration/merge steps. The marker is shared through the main
checkout's `.claude/super-board/github-halt.json`, including linked worktrees (a
submodule keeps it in its own git dir: `<git-common-dir>/super-board/`).
Cancel active workflow agents using local workflow controls; do not launch more
lanes. Already-running agents stop at their next checkpoint; this is not an
instantaneous process-wide kill. Preserve worktrees, claims, card statuses, and
approval evidence. Do not move cards to Done/Blocked or release claims using an
unavailable GitHub API. Report the local saved reason and what remains in flight.

After fixing access or the invalid query, explicitly resume with the helper's
`--resume`. It rechecks the failed read before clearing the marker and archives
the original reason. Failed recovery leaves the pause intact. When the caller's
query was corrected or PR metadata changed, supply its current read explicitly:
`--resume --kind <same-shape> [--meta <fresh-meta.json>] -- <corrected gh read args>`.
The replacement must pass the same evidence validator; the broken saved query
is retained in the archived record. This is a read-only recovery check. An uncertain write
has no automatic recovery probe: inspect the remote outcome first, then archive
the halt record explicitly; never rerun a migration/write as a health check. Then follow normal
run preflight/reconcile, inspect preserved worktrees, and start a fresh wave.
Do not schedule automatic retries of the stopped run.

## Orchestrator delegation contract (NON-NEGOTIABLE, adapted)

The interactive session that runs this backend is the orchestrator. It:
- polls the board, claims assignees, launches workflow waves, reconciles
  results, posts notifications, and reports to the user between waves;
- does NOT do product work, patch lane skills mid-run, or hold per-card
  build context. Workflow lane agents do all product work.

## Preconditions (before the first wave)

**Goal check first, every run (factory #40).** The goal is a GitHub milestone named in the
config's `goal.milestone`. Before anything else:
1. Read the open milestones (`gh api repos/<owner>/<repo>/milestones`): title, description
   (its "Done when: …" line), and open and closed issue counts.
2. Show the owner the current goal in two lines (`🎯 <title> · <closed>/<total>` and its
   done-when line), then ask with AskUserQuestion: keep it, reword it, or switch to another
   open milestone. With no goal set, propose one from the open milestones or the plan, and
   ask. Don't start a wave without a goal the owner has confirmed this session.
3. Save the answer to `goal.milestone`. A reworded goal is saved to the milestone's
   title or description on GitHub first.
4. Ready cards that are free but not on the goal show up in the planner's `offGoal` list.
   Tell the owner how many there are in one line, and never run them. A card belongs to
   the goal only when its milestone says so: move a card onto the goal only when the
   owner asks, never because it's runnable.

Run the same preconditions as `run.md` §Preconditions, minus PID checks:
1. Config exists and validates against `config-schema.json`. Run
   `python3 .claude/bin/super-board-verification-ready.py --config <config>`; exit 9
   stops before dispatch until the owning project's verification commands are configured.
   Preserve work; repair setup and restart explicitly, never bounce to Build.
2. Production-merge guard: refuse `base_branch: main` + `human_approves_merge:
   false` when deploy markers exist (same rule as run.md → Preconditions).
3. Worktree check: if legacy `.worktrees/issue-*` exists, halt for inspection/move
   as described in run.md. Scan only board worktrees under `.claude/worktrees/`;
   when their named branch is gone use `git worktree remove` without force. Preserve
   detached, dirty, locked, unregistered, and unrelated folders.
4. `node --check` passes on a wrapped copy of
   `.claude/workflows/super-board-wave.js` (catches a broken script before
   burning tokens):
   `{ echo '(async function(){'; sed 's/^export const meta/const meta/' .claude/workflows/super-board-wave.js; echo '})'; } | node --check --input-type=module`
5. Wave marker: atomically create `.claude/super-board/inflight/workflow-wave.lock`
   (mkdir -p the directory) containing the config slug and start time:
   `(set -C; printf 'SLUG=%s\nSTARTED=%s\n' <slug> "$(date -u +%FT%TZ)" > <lock>)`.
   Before replacing an existing marker, check `/workflows`. Only if no
   super-board-wave is running is the marker stale from a crashed run — replace it.
   Remove the lock when the run ends or stops.
6. Crash-recovery sweep: with no wave running, strip `bot_identity` from any
   Review/QA/Ready/Building card that still carries it
   (`gh issue edit <n> --remove-assignee <bot_identity>`). A crashed
   orchestrator releases nothing — leaked assignees make the planner skip
   those cards forever and the board silently stops draining.
7. Database reach: for every env in `migrations.allowed_envs` with a command, run its read-only
   `migrations.checks[env]` (e.g. `supabase migration list --db-url …`). A failure halts the run
   with the check's error — a broken URL caught here costs nothing; caught at merge time it
   strands a wave of reviewed PRs. An env with a command and no check: say so once, then go on.
   The URL resolves from the project's `.env`, never the session (config-schema → `migrations`).

## The wave loop

Repeat until a done condition, a halt or a stop:

1. **Rate guard** — `sb_gh_guard_check 200` (super-board-gh-guard.sh; `gh api rate_limit` misreports GraphQL); if GraphQL remaining < 200, wait for
   reset (same thresholds as run.md). A failing `gh` call outranks the reading:
   right after a reset the REST reading has shown 4999 while calls still failed.
   With GraphQL dry, the orchestrator's own writes go over REST, a separate
   quota: `gh api repos/<o>/<r>/issues/<n>/comments -f body=…` for a comment,
   `gh api -X DELETE repos/<o>/<r>/issues/<n>/assignees -f 'assignees[]=<bot>'`
   to release a claim. Board moves have no REST route; they wait for the reset.
   **Usage guard** — `bash .claude/bin/super-board-usage.sh check --config <config-path>`
   (Claude 5-hour and weekly plan usage; threshold `usage_pause_pct`, default 95):
   - exit 0 → launch.
   - exit 10 otherwise (pause) → launch nothing new. A wave already running finishes —
     stopping it mid-lane loses work. Then release claims as usual, post the
     resume note (one line to the user and the run manifest:
     `⏸ paused at <window> <used>% — resets <local time>; remaining: <N> cards; resume: /super-board run <slug>`),
     remove the wave lock, and wait for the reset. If a wake tool is available
     (`ScheduleWakeup`, or a `/loop` re-entry), schedule
     `min(3600, resets_at - now + 60)` seconds and chain until the reset; on
     wake re-run the check — trust the reading, not the clock — and continue
     only on exit 0. No wake tool → stop with the note; the user resumes.
   - exit 3 (unknown) → launch, and say once per run why the guard is blind
     (its `reason`). Do not halt a run on a missing signal.

   The signal is the `rate_limits` block Claude Code pipes to the status line —
   the only scriptable source of plan usage (`/usage` is interactive; `ccusage`
   reports tokens and cost, not % of plan). It reaches the script only if the
   user's status-line command records it; add one line after it reads stdin:
   `printf '%s' "$input" | bash <repo>/.claude/bin/super-board-usage.sh record`.
   Pro/Max only (API-key sessions have no `rate_limits`); it refreshes on this
   session's own turns. Claude Code's built-in pause at 100% remains the
   backstop — the guard exists so a wave does not start that the limit would
   cut off mid-lane.
2. **Plan the wave** —
   `bash .claude/bin/super-board-wave-plan.sh --config <config-path>` →
   Exit 9 is a verification-readiness halt: preserve work and claims, repair the
   owning project's `verify_commands`, then restart explicitly. No GitHub recovery probe,
   rebase, Build bounce, or automatic retry.
   **Skill readiness before any wave writes.** Hydrate every selected issue body
   read-only with `.claude/bin/super-board-github-read.py --kind issue -- issue
   view <N> --json number,title,body`. Keep number, status, labels and literal body
   in a JSON array file. Run `python3 .claude/bin/super-board-skills-ready.py
   --root <repo-root> --host claude --cards <cards.json>` before sweep/resume/refresh/flag/stranded actions or Claim.
   Exit 10 names missing helpers: halt, preserve all state, repair the exact
   visible skill files and restart explicitly. Exit 64 means invalid input.
   GitHub hydration failure follows the existing exit-79 read policy.
   Empty selection checks no unused helpers.
   Pass hydrated bodies into the wave. Workers recheck their lane before writes
   and activate conditional helpers only after `--require <exact-name>` passes.
   Untyped Ready cards conservatively check bug and feature chains before
   classification. Existing docs/ux/tests/refactor rows keep their chain; check
   any proposed new label chain before writing that label.

   The planner returns `cards`, `sweep`, `resume`, `refreshApproval`, `flag` and `stranded`. **Act on
   `sweep`, `resume`, `refreshApproval`, `flag` and `stranded` BEFORE launching** (run.md → "The wave-start
   sweep"): move every swept card to `Ready` with a comment naming what cleared
   it, move every `resume` card (verified human approval of the current pinned
   request) to `Review`; `needs-you:done` is display-only. Move `refreshApproval`
   cards to `Review` solely to review the changed head and post a fresh human request;
   clear their stale `needs-you:done` display labels. They have no approval to merge.
   Comment on flagged cards asking for their
   `## Blocked by` line to be fixed, and return every stranded Building card to
   `Ready` (below). Swept, resumed, approval-refresh and stranded cards are NOT in this pass's
   `cards`; they join the next wave.

   **Refused cards.** The planner also returns `refused` (`{number, reason}`) and
   `deferred` (`reason: "overlap"`). Before launching, move each refused card to
   `Backlog` with one comment naming the missing field from its `reason`; never
   dispatch it. Deferred cards stay in Ready and join a later wave.

   **Stranded Building cards.** A card in Building with no assignee between
   waves has no live worker — a stopped or crashed wave left it mid-build. For
   each: find its branch (`git ls-remote --heads origin 'issue-<N>-*'`) and any
   leftover `.claude/worktrees/issue-<N>-build/`. If its HEAD is detached, keep it:
   its commits may have no other ref. Otherwise remove it with `git worktree remove`
   without force. On detached HEAD or removal failure (dirty, locked, or unregistered),
   keep the folder and Building status, report the recovery path, and do not
   redispatch that card until its work is preserved. Otherwise keep the branch and PR,
   move the card to `Ready`, and comment:
   `[orchestrator] [report] ↩️ back to Ready · stranded in Building` / `Did: found no live
   worker` / `✅ Done: card moved to Ready · branch <name> kept` / `Next: builder`
   (writing-standard.md § 4). The next Builder continues on the branch.
   **Builder pre-flight.** No card goes Ready → Building unchecked. The wave's first phase
   (`Pre-flight` in `super-board-wave.js`, before `runLane('build')`) runs one cheap sub-agent per
   batch of up to 5 Ready cards: already merged? already in progress (open PR or another card)?
   same files as an open PR? unclear? It runs `super-board-preflight.sh`, posts the Block template
   and moves held/sequenced cards to Blocked itself (lanes/build.md → "Builder pre-flight"). The summary
   reports those as `preflight:blocked`; `preflight:failed` means pre-flight was blind and the card
   stays in Ready for the next wave. Sequenced cards carry a `blocked-by:` line, so this same sweep
   frees them when the overlapping PR's issue closes.
   Wave width is the ramp stage (`ramp.stage`, 1–3; a foundation goal runs 1),
   counted after the planner drops overlapping cards and cards the ticket gate
   refuses, in flight first (Review → QA → Ready), and never above `max_workers`
   when that is set. `max_workers` is the GitHub-limit valve: step 5 lowers it
   after a wave that hit the hourly limit. Health (step 5) steps `ramp.stage` down
   on a breach; raising it is the owner's call. After a `pause-new` health action,
   drop the planner's Ready cards from this wave; in-flight cards still run.
   If `cards` is empty and
   Building/QA/Review counts are 0 → done. If empty but cards sit in Blocked
   only → report and stop. **Goal reached:** when the goal milestone has no open
   issues, stop, report `🎯 <title> reached`, and ask the owner for the next goal
   (the goal check above). Off-goal cards never keep a run going. This is unfinished work, not a completed-run calibration trigger.
3. **Claim** — for each card, `gh issue edit <n> --add-assignee <bot_identity>`,
   then VERIFY: re-read assignees (`gh issue view <n> --json assignees`) and
   proceed only if the list is exactly `[<bot_identity>]`. Adding an assignee
   does NOT fail when someone else already claimed (issues accept up to 10
   assignees), so the add alone is not a mutex — on any other assignee set,
   remove own assignee and skip the card (race lost). Skipped when
   bot_identity is unset — accepted single-orchestrator risk: without it
   there is no cross-session claim at all, so never run two orchestrators
   (or /loop re-entries) against the same board without bot_identity.
4. **Launch** — Workflow tool with
   `scriptPath: .claude/workflows/super-board-wave.js` and
   `args: { configPath, cards, humanApprovesMerge, tier, laneModels }` (`cards` hydrated after the planner: each
   carries `lane` and `labels`, and a `qa` card skips the Builder). Runs in the background; the
   orchestrator stays responsive. `humanApprovesMerge` comes from the config. Review lanes run in
   parallel: the merge mutex sits in `super-board-merge-gate.sh`, not in the workflow.
   `tier` is the run's model ladder: `'low'` when the user invoked
   `super-board run --low` (haiku/sonnet/opus by card complexity), `'high'`
   for `run --high` (opus for every card), omitted/`'medium'`
   otherwise (sonnet/opus/session — the default). A `model_tier` key in the
   config sets the default; an explicit flag wins over config.
   `laneModels` is the config's `lane_models`, passed as is (omit it when unset). It sets
   the model per lane (classify, preflight, build, qa, review) over the tier; a lane it
   leaves out keeps the tier's choice. A bad value fails the wave before any agent runs.
   `laneModelsByTier` is the config's `lane_models_by_tier` (omit when unset): per zone tier,
   then per lane, for example the strongest model on red build and review.
   `laneModelsJudgement` is the config's `lane_models_judgement` (omit when unset): per lane, for
   cards the planner flags `judgement: true` (`**Needs judgement:** yes`); wins over the tier map.
   Each lane's history entry records `modelRule`: `judgement`, `tier` or `default`.
5. **Reconcile** (when the run completes) — read the returned `cards`
   summary. If `halted: true`, any card is `halted`, or the GitHub helper's `--check`
   fails, preserve claims and stop. For verification-readiness (exit 9), repair
   `verify_commands` and restart explicitly; do not invoke GitHub evidence recovery.
   For a GitHub read halt, follow "Required GitHub evidence" above. Otherwise,
   for EVERY card in the wave, release the assignee
   (`gh issue edit <n> --remove-assignee <bot_identity>`, idempotent).
   Append one line per card to the run manifest
   `docs/super-board/runs/<date>-<slug>.md`:
   `| #N | <lanesRun> | <finalStatus> | <column> | <detail> |`.
   Then the scorecard: save the returned `cards` to a temp file and run
   `python3 .claude/bin/super-board-scorecard.py record --results <file> --logs <the wave's transcript folder> --scorecard docs/super-board/runs/scorecard.jsonl --wave <date>-<N>`.
   The transcript folder is the one the Workflow result names; agent logs inside it
   give tokens and minutes per card. `cardsWithoutLogs` above 0 means the logs were not
   found: say so once in the report, the rest of the row still counts.
   Pass `--milestone <goal.milestone>` to `record`. Each card's `citation` and
   `round_capped` and the result's `uncited-bounce` events are read when present.
   **Health** — right after `record`, run
   `python3 .claude/bin/super-board-scorecard.py health --config <config-path> --wave <date>-<N> --goal-done <closed> --goal-total <total>`
   (the goal milestone's issue counts). Four metrics act: a card round-capped this wave,
   rolling rounds per merged card above 2, budget burn (80% of `goal.budget_usd`
   in API-equivalent dollars with under 60% of the goal merged), and over 2
   failed/halted lane exits today. A breach has already written `ramp.stage` one
   lower (floor 1). Act on `action`:
   - `continue` → plan the next wave as usual.
   - `pause-new` → the next wave takes no new Ready cards; in-flight cards finish.
   - `stop-ask` → post ONE `needs-you` item (below) asking the owner about the
     budget, and launch nothing new until they answer.
   Health never halts the run. A `warnings` entry (the wave wrote no rows) goes in
   the report once. The report-only numbers (cited bounces, tokens per merge, days
   since the last accepted demo) never act. Record an accepted demo with
   `super-board-scorecard.py demo --accepted`.
   **Digest** — then run
   `python3 .claude/bin/super-board-scorecard.py digest --config <config-path> --plan <the wave's plan.json> --wave <date>-<N> --goal-done <closed> --goal-total <total>`.
   It prints goal, merges, health, budget and asks only when there was a merge, a
   breach or an ask (every wave when `digest` is `every-wave`). Non-empty output is
   sent as is with the PushNotification tool.
   **Owner asks.** Every question for the owner is a `needs-you` item: a comment
   on the card's PR (on the issue when there is no PR) with the `needs-you` label,
   never only a chat line. The wave-start sweep never sends a `needs-you` card back
   to a builder (#38); it waits for the owner's answer.
   Then the GitHub-limit step-down: save the returned `cards` to a temp file and run
   `bash .claude/bin/super-board-throttle.sh --config <config-path> --results <file>`.
   `hit: true` (GraphQL at 0, or a lane failed on the limit) has already written
   `max_workers` one lower into the config — unlimited → 3 → 2 → 1, floor 1 — so the
   next wave and the next run start narrower. Raising it again is the owner's call.
6. **Report** — one short block to the user per wave, in the session. Outcome
   first, one line per card that needs a human, then what happens next:

   The goal line comes first:
   ```
   🎯 M1 · Ben can test funl · 3/5 done · next: #78, #65 · 2 off-goal waiting
   Wave 3 · 5 cards → 2 merged · 1 bounced · 1 blocked · 1 failed · usage 5h 62%
     🛡 #15 Blocked 🔐 missing STRIPE_TEST_KEY — owner: Eric
     ❌ #18 failed: build lane returned no result — retried next wave
   Next: wave 4 (3 cards)   |   ⏸ paused until 14:05   |   ✅ board drained
   ```
   Add the scorecard as the block's last line(s):
   `python3 .claude/bin/super-board-scorecard.py summary --scorecard docs/super-board/runs/scorecard.jsonl`
   prints one line per build model (🟢 working · 🟡 watch · 🔴 not working). Review's
   `score.cause` says why a card needed fixes: mostly `build` → the builder model is
   short for those cards, so ask the owner before moving it up; mostly `ticket` →
   sharpen tickets first, keep the model.
   A throttle hit adds one line: `🐢 GitHub hourly limit hit — max_workers 3 → 2 (config saved)`.
   Merged and bounced cards are counts, not lines — they need nobody. Every
   `human-gate`/`blocked` card gets its line and its owner: that is the
   human's queue. Never report a card as done that is not on the base branch.
7. **Health gates** — the health action (step 5) replaces the old zero-progress
   and block-rate gates: it pauses new cards or asks the owner, never halts. The
   run stops only on a GitHub halt, a readiness halt, the usage guard, a done
   condition, or the user saying stop. The stop note is four lines: `🛑 halted — <gate>` · the evidence (counts, the cards
   that kept bouncing) · what is left in flight or claimed · `Resume:
   /super-board run <slug> [--low|--high]` (retain the run's choice) and who must act first.
8. Loop to 1. For unattended cadence, the user may wrap this loop in /loop;
   the orchestrator must still act on the health action and stop when told.

After normal completion, confirm all selected waves and lane tasks have ended,
finish final reconciliation, and release only the `workflow-wave.lock` created
by this host for this run (match its saved slug/start identity). Never remove
a marker owned by another or uncertain run; preserve it and skip calibration.
The read-only adapter never removes markers. Then run the optional adapter in [`calibration.md`](calibration.md).
This is a separate post-run task, after all lane workers and pending selected work
are accounted for. Do not calibrate per wave, on a halt/partial delivery, or from
Done counts or process exit alone. When enabled and eligible, delegate the installed
skill automatically using the helper's scoped brief; check its actual diff before
accepting automatic edits. An unavailable skill/host or an ineligible receipt is
reported as skipped and does not change the completed product work.

## Stop / resume

- Stop: `x` on the run in `/workflows` (or TaskStop), then release assignees
  for in-flight cards and post "stopped mid-flight" comments (same protocol
  as `references/stop.md`). Remove `.claude/super-board/inflight/workflow-wave.lock`.
- Resume: just run again — board state is the only state. A workflow stopped
  mid-wave can also be resumed in-session via `resumeFromRunId` (completed
  lane agents return cached results).
- Cards stranded in `Building` (wave stopped after the Builder moved
  Ready → Building) come back by themselves: the next run's crash-recovery
  sweep releases their claim and the planner reports them in `stranded`
  (wave loop step 2). No manual drag.

## Mid-run permission prompts

The run allowlist, headless-run rules and merge lines live in `onboard.md` →
"Mid-run permission prompts"; onboard writes them into `.claude/settings.json`.

## Skill-readiness reconciliation

Exit 10 from a skill check or lane result with detail `skills-readiness:` is a
readiness halt. Stop new dispatch, stop only this runner's active workers,
and preserve claims, inflight records, worktrees, card state and approval
evidence. Repair the exact host-visible skills and restart explicitly. Do not
release claims, bounce a card or enter a retry loop on this halt. Existing
preselection crash recovery remains the discovery step; once missing skills
are known, recovery and wave writes stop.
