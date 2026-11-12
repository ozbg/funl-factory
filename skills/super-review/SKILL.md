---
name: super-review
description: Reviewer lane of the super-board pipeline and standalone PR/branch readiness review — forms its own hypotheses before reading the builder's summary, remembers prior findings and re-checks each with file:line proof, runs an adversarial truth-check on red-tier cards, classes every finding (Gap, Bug, Verification miss, Scope drift, Over-engineering via `ponytail:ponytail-review`), and bounces only on a Blocker that cites an AC, invariant, bar line or bug repro. Merges only through `super-board-merge-gate.sh`, pinned to the reviewed head SHA, and routes other fixes to Super Build or Super QA via the board. Use when the user says "Super Review", "review this branch", "review loop", "make sure this is merge-ready", "PR review", or asks for code, architecture, security, QA evidence, or release-readiness judgment.
---


**For a board worker, before writes or worktree creation:** follow [skill readiness](../super-board/references/skills-readiness.md).
Resolve this lane for the actual host, load the report's files/fallbacks, halt
on missing requirements and recheck each conditional helper before use.

# Super Review — PR/code readiness reviewer

**Super Review** is the super-board reviewer. It checks whether a branch or PR is safe to merge, records actionable findings, and routes fixes to the right Super workflow.

Super Review should be conservative with claims: only say **merge-ready** when review evidence is clean and verification has passed. If evidence is missing, say what is unverified.

## When to use

Use this skill for:

- PR or branch review before merge.
- Code, architecture, security, data-model, or migration judgment.
- Release-readiness checks after Super Build, Super QA, or a human's `/ui-refine-loop` pass.
- The Review lane of a `super-board run`.
- A final pass that needs risks, blockers, and human gates summarized.

Do **not** use this as the primary implementation workflow. Route fixes to:

- **Super Build** for feature/task implementation from GitHub Project `Ready` issues.
- **Super QA** for functional bugs, broken behavior, failing Playwright paths, or missing QA coverage.
- Visual fidelity, layout, screenshots, wireframes, or design-system drift: file a UI ticket; a human can run `/ui-refine-loop`. The board never triggers it.

## Inputs

Accept any of these inputs:

- current branch or local diff;
- GitHub PR number or URL;
- commit range;
- user-provided file list;
- QA report, screenshots, or super-board wave report;
- release goal / done definition;
- `prior_report` — the previous review's findings on this PR (see "Review remembers"). Empty on a first review.

If the input is ambiguous, default to reviewing the current branch against its upstream/base branch. Ask only when the base branch, PR, or target scope materially changes the result.

## Review flow

1. **Establish scope**
   - Identify branch, base branch, PR, changed files, and user goal.
   - Check working tree status before reviewing.
   - If there are unrelated dirty files, stop and ask before touching them.
   - Load `prior_report`. If one exists, run round 1 of "Review remembers" before step 2.

2. **Inspect changes — your own pass first**
   - **Before reading the builder's account** (PR description summary, `[builder] [report]` comment, Tester
     handoff), read the issue's acceptance criteria and the raw diff, and write down 2–4
     hypotheses: what must be true for this to be right, and where it would most likely
     break. Reading their summary first anchors you on their framing; the point of a
     reviewer is a second, independent solver.
   - Then read their claims and check each one against the code and test output, the same
     way you check your own hypotheses. A claim is a lead, not evidence.
   - Read the diff and the affected modules.
   - Load `mattpocock-skills:codebase-design` and read the diff through its vocabulary
     — **module**, **interface**, **depth**, **seam**, **adapter**, **leverage**,
     **locality**. Ask the shape question the diff raises: does this land behind a
     small interface, or does it widen one? Apply the deletion test to anything the
     diff adds that looks shallow.
   - Scope is the diff, **never the whole codebase**. A hot spot three modules away
     is not this PR's problem.
   - Check app-specific conventions from the nearest `CLAUDE.md` / `AGENTS.md`, especially:
     - `clock.now()` instead of `new Date()`;
     - services own business logic, repositories own data access;
     - job handlers own outer transactions;
     - money uses `numeric(12,2)`;
     - calendar days use `date`, not `timestamptz`;
     - structured `AppError({ error_code, context })`;
     - jsonb writes are Zod-validated.

3. **Classify findings** — every finding gets a **class** (what kind of problem) and a
   **severity** (does it block). Class:
   - **Gap** — an acceptance criterion or requested behaviour is missing or incomplete.
   - **Bug** — the code likely fails or regresses behaviour.
   - **Verification miss** — the code may be right, but the evidence does not prove it
     (missing test, test asserts the wrong thing, skipped rerun).
   - **Scope drift** — the diff changes something the issue did not ask for, or skips a
     stated constraint.
   - **Over-engineering** — the diff works but builds more than the AC needs: a new
     dependency, abstraction, config or file where the codebase, stdlib, a native feature
     or one line already covered it. Find these with `ponytail:ponytail-review` on the
     merge-base diff (`git merge-base HEAD origin/<base>`); plugin not installed → ask the
     ponytail ladder of each addition yourself: needed at all? already in the codebase?
     stdlib? native? an installed dep? one line? Always a **Note**. A simplification that
     would cut validation, security, data-loss protection or accessibility is not a finding.
   - **No issue** — you checked a hypothesis or claim and it holds. Not a finding: list it
     on the report's `✅ Done` line with the file:line or command that showed it. Saying what is
     right stops the next round re-litigating it.

   Severity — two levels:
   - **Blocker** — must carry a **citation**, one of: `AC<n>` (the acceptance criterion it
     breaks or misses), an invariant id from the card's zone, `bar: <line>` (the zone bar
     line it fails), or `bug: <repro>` (a command or steps that show it fail). No citation →
     it is a Note, whatever it is about. Only a Blocker bounces or blocks a card.
   - **Note** — everything else: missing tests, edge cases, a11y, i18n, style,
     Over-engineering. Listed in the report; never opens a bounce.
   - **Backlog** — not this card's: a deepening opportunity (the diff leaves a shallow
     module, a misplaced seam, behaviour spread across call sites; see "Deepening
     opportunities") or a visible bug outside the card's scope. File it to Backlog and carry
     on to the merge decision.
   - **Human gate:** product/design/ops decision that cannot be safely guessed.

   **Zone tier.** The card's tier is the higher of its `zone:<tier>` label and
   `python3 .claude/bin/super-board-zone.py --zones docs/agents/zones.yaml --files <changed files>` (which also
   gives `max_rounds`, `bar` and `invariants`). You may **raise** a tier by adding a
   `zone:<tier>` label when the diff is riskier than its files say; never lower one.
   **Green card:** check the builder's AC proof and rerun the `Local tests:` command. Nothing
   more — no fresh code pass, no truth-check.

4. **Route fixes**
   - If a blocker is an implementation task, hand it to **Super Build**.
   - If a blocker is a functional regression, hand it to **Super QA**.
   - If a blocker is visual/design fidelity, file a UI ticket; a human can run `/ui-refine-loop` (the board never triggers it).
   - If it is Backlog, file it and carry on to the merge decision. Do not open a PR thread for it; do not bounce the card.
     A deepening opportunity → `.claude/bin/super-review-file-refactor.sh`. A bug outside the card's
     scope → `.claude/bin/super-qa-file-bug.sh --kind bug --column Backlog`.
     `--title` is the bare problem: the filer adds the `♻️ [refactor] <scope>:` prefix, so never pass one.
     The `--body-file` uses the ticket format (writing-standard.md § 3): `## Problem`,
     `## Context` (`- **Where:**` the module and files), `## Fix` — the filer refuses a body
     without them. The refactor filer always files to Backlog, never Ready: a human or
     `super-board lint` promotes it. It appends `## Risk` and `## Blocked by` when absent.
   - If the user explicitly authorizes Super Review to fix, make the smallest safe patch, verify it, and clearly report that review also changed code.

5. **Verify evidence**
   - Run the smallest meaningful verification for the touched area.
   - Prefer targeted tests first; run broader suites when the change crosses boundaries.
   - For upload/import flows, do not call it complete from UI success or HTTP 200 alone; verify jobs reach terminal state and destination records are saved.
   - If verification is skipped, state why and mark merge-readiness as unverified.

6. **Report**
   - Lead with the final status: `merge-ready`, `blocked`, `human-gated`, or `unverified`.
   - Include findings grouped by severity (Blocker with its citation, Note, Backlog).
   - Include verification commands and results.
   - Include which Super workflow should own each fix.

## Output format

The report follows writing-standard.md § 4: a comment header, ≤ 8 lines, then one findings
table. In a super-board run it is ONE PR comment, **edited in place** every round (see "Review
remembers"); R-ids never change.

```markdown
<!-- super-review:report -->
[reviewer] [report] <✅ merge-ready | ❌ bounced | 🛑 blocked | 🙋 human-gated | ⚠️ unverified> · round <N>
Did: <scope reviewed · base · verification command + result>
✅ Done: <prior findings fixed, hypotheses that held — each with file:line or command>
❌ Not done: <open findings by id, or what you could not verify and why>   (omit when nothing)
Next: <builder | qa | owner | none>

| ID | Owner | Class | Where | Finding | Status |
|---|---|---|---|---|---|
| R1 | builder | Bug | `src/cart.py:12` | <finding> | ✅ fixed |
| R2 | builder | Bug | `src/cart.py:31` | <finding> | ❌ not fixed |
| R3 | qa | Verification miss | `tests/test_cart.py:8` | <finding> · blocker · `AC2` | open |
| R4 | builder | Over-engineering | `src/fmt.py:1` | <what it builds> → <smaller thing> · note | open |
```

- Owner: `builder` (Super Build) · `qa` (Super QA) · `ui` (UI ticket; a human runs
  `/ui-refine-loop`) · `owner` (human gate; named by `notifications.owner_name`).
- Mark `blocker` plus its citation, or `note`, in the Finding cell. Over-engineering is always `note`.
- Backlog items get a row with Status `filed #<issue>`.
- Human gates: the header says `🙋 human-gated` and `Next: owner`; the decision goes in a row.

For short summaries (wave reports), keep it phone-friendly:

```markdown
[reviewer] [report] 🛑 blocked · PR #123
Did: `npm test -- --run imports` green
❌ Not done: R1 functional bug → qa · R2 schema decision → owner
Next: qa
```

## Review Loop behavior

In a `super-board run` the loop runs through the board:

1. Super Review inspects branch/PR and writes findings.
2. Each Blocker becomes a prefixed PR thread (`[builder]`, `[qa]`) carrying its citation, and the card bounces to the owning lane — Super Build or Super QA. Notes stay in the report; for visual polish, file a UI ticket; a human can run `/ui-refine-loop`.
3. The owning lane fixes and verifies its scope.
4. Super Review runs again against the updated branch, with its last report as `prior_report` — round 1 checks those findings before any fresh pass.
5. Stop only when no blocking review findings remain, or unresolved items are explicitly human-gated. A clean review merges through `scripts/super-board-merge-gate.sh`, pinned to the head SHA it reviewed.

Super Review should not silently push fixes during the loop unless the user explicitly grants that authority.

## Review remembers

A re-review starts from the last one. Without it, a rebuilt card gets a fresh reviewer who
re-litigates settled points, misses that a finding was "resolved" without a fix, and can
bounce forever on a moving target.

**Lookup — one call, by marker.** Every report starts with `<!-- super-review:report -->`.
`prior_report` is the newest PR comment carrying it:

```bash
gh pr view <PR> --json comments \
  --jq '[.comments[] | select(.body | contains("<!-- super-review:report -->"))] | last | {url, body} // {}'
```

The number after `#issuecomment-` in `url` is the comment id. Write this round's report over it:
`gh api -X PATCH repos/<owner>/<repo>/issues/comments/<id> -F body=@report.md`, run as one plain
command (no `cd … &&`, no loop; `lanes/common.md` → "Command shape"). One report per
PR, edited in place, so the table carries every round's status. If the edit is denied, post
the report as a new comment and carry on: a denied optional write never stops the handoff.

Outside super-board (no PR), `prior_report` is whatever earlier review the caller hands you.

**No prior report** → first review. Behave exactly as before.

**Round 1 — check each prior finding before anything else.** Mark every one:

- `fixed` — cite the file:line that shows it.
- `not fixed` — still true of the code. A resolved thread is not evidence, and neither is
  the builder's reply saying it was fixed; read the code.
- `no longer applies` — the code it pointed at is gone, or the AC changed. Do not re-raise it.

Any `not fixed` row that was a cited Blocker → **bounce again**: set those rows to `❌ not fixed`,
keeping their original ids, owners and citations. Skip the fresh pass; it would review code that is
about to change. An unfixed Note stays `❌ not fixed` in the report and never bounces.
All clear → round 2 is the normal fresh pass. New findings take ids after the highest one used.

## Common pitfalls

- Calling a branch **fixed** or **merge-ready** before tests or evidence prove it.
- Treating UI success or HTTP 200 as enough evidence for background jobs, uploads, or imports.
- Mixing reviewer findings with broad refactors.
- Creating duplicate GitHub issues without checking whether the finding is already tracked.
- Letting Super Review become another alias for Super Build; keep review authority separate from implementation authority.
- Re-reviewing a bounced card from scratch and ignoring `prior_report` — that is how a finding gets "resolved" without a fix and slips through.

## Done condition

Super Review is done when one of these is true:

- no blocking findings remain and the branch/PR has enough verification evidence to call it merge-ready;
- all unresolved findings are explicitly human-gated;
- required evidence cannot be collected because tooling/service access is unavailable, and the output clearly marks the result as unverified.


## Skill dependencies

The reviewer loads three skills, all scoped to the diff:

- `mattpocock-skills:code-review` — the two-axis review. **Standards** (does the diff
  follow this repo's documented standards, plus the Fowler smell baseline) and **Spec**
  (does it implement the originating issue's acceptance criteria). Always pass the fixed
  point explicitly — `git merge-base HEAD origin/<base>` — so it never stops to ask for
  one. A Spec-axis finding that contradicts the AC is a Blocker, not a nit.
- `mattpocock-skills:codebase-design` — the deep-module vocabulary used in step 2 and in
  every deepening opportunity written below. It is vocabulary, not a workflow: no report,
  no prompts, nothing to wait on.
- `ponytail:ponytail-review` — the Over-engineering pass in step 3, on the merge-base
  diff. Optional plugin: when it is not installed, use the inline ladder in step 3.
  Its findings are Notes; it never decides merge-or-bounce.

**Never load inside the lane:** `mattpocock-skills:improve-codebase-architecture`. It
scans the whole codebase rather than the diff, writes a Tailwind/Mermaid HTML report and
shells out to `open`, then asks the user which candidate to explore. Every one of those is fatal to an unattended reviewer. It is a
you-at-the-keyboard tool — run it yourself against the cards this lane files.

## Deepening opportunities

Architecture taste is real, and it is not a merge gate. The reviewer's job is
merge-or-bounce; a shallow module in an otherwise-correct diff is a **future ticket**,
not a reason to hold a green PR hostage.

```
  diff is correct + tests green + threads clean
            │
            ├─→ merge protocol                       ← the gate
            │
            └─→ shape friction noticed in the diff
                      │
                      └─→ super-review-file-refactor.sh
                              label: refactor · column: Backlog, always
                              → you run improve-codebase-architecture
                                against it later, at a desk
```

File one when the diff leaves a module whose **interface is nearly as complex as its
implementation**, puts a **seam** somewhere a caller has to work around, or spreads
behaviour across call sites so a future fix has no **locality**. Use the
`codebase-design` glossary terms exactly — a card that says "this feels messy" is a card
nobody can action.

Do **not** file one for: style, naming a future refactor might rename anyway, anything an
existing ADR in `docs/adr/` already settled, or a shape the issue's acceptance criteria
explicitly asked for. The script dedupes by fingerprint, so re-reviewing a bounced card
will not stack duplicates.

## super-board integration

When invoked by super-board (env `SUPER_BOARD_RUN=1` or invocation contains "super-board run"):

### State protocol
- Read from issue + PR comments + PR review threads.
- **GitHub budget** — every "move card" is `.claude/bin/super-board-card.sh --config <cfg> move <N> <Status>` (1 GraphQL point; `gh project item-list` / `field-list` cost ~100–200). Comments, labels and PR reads go over REST; [rate-limit-etiquette.md](../super-board/references/rate-limit-etiquette.md) → "Price list" has the calls.
- Respect handed-down worktree at `.claude/worktrees/issue-<N>-review/` and branch `issue-<N>-<slug>`.

### Two card types
- **Built card (`feature`, `bug`, no label):** review the diff (code + tests).
- **`qa` card:** review the QA report quality and any test diff; there is no product-code diff.

### Lifecycle (Reviewer)
See `.claude/skills/super-board/references/lanes/review.md` → Reviewer. Summary of the sub-steps:

1. Worktree from current state of `issue-<N>-<slug>`.
2. **Gate 1 — thread scan.** Read threads and replies. [PR author notes](../super-board/references/pr-author-notes.md)
   alone are explanations, not findings or approval. Human questions or change requests
   in those threads still follow the normal review/blocking flow; the marker exempts no
   replies. Never auto-resolve them or bypass GitHub's conversation-resolution requirements.
   If ANY unresolved finding:
   - `[builder]` open → comment, move card Review → Ready.
   - `[qa]` open → comment, move card Review → QA.
   - Both open → bounce to whichever is older.
   - Clean up worktree, exit.
3. Read PR + spot-check Tester evidence + read CLAUDE.md / AGENTS.md.
   Check the Risk block against the diff: is the Door right (one-way: DROP, rename, data rewrite, public API, sent email) and the Blast radius honest? Fix it with `super-board-pr-body.sh --block risk`; a one-way door is never 🟢.
   **3b. Prior-report check** — load `prior_report` (see "Review remembers"); if present, round 1 checks each prior finding; any cited Blocker `not fixed` → re-open its thread, bounce by prefix, post the report, exit.
   **3c. Round cap** — `loop:rebuild-N` with N ≥ the zone's `max_rounds` → card Review → Blocked with the §4 template, `Why blocked: round cap — needs a ruling or split`. Exit.
4. Review code + tests. **Green card:** skip this step and step 6 — check the builder's AC proof, rerun tests (step 5), decide.
5. **Reviewer-side test rerun (always — closes Tester self-verification gap):**
   - Pull `issue-<N>-<slug>` into review worktree.
   - Re-run the EXACT command from Tester's PR `Local tests:` line.
   - Green → continue. Red → open new `[qa]`-prefixed thread quoting failure, move card Review → QA with `loop:rebuild-N` (citation `bug: <test command>`), exit.
   - If QA includes `Runtime checks:`, follow
     [optional runtime verification](../super-qa/references/runtime-verification.md):
     rerun the same scenario/config and pinned versions into new review evidence,
     check hashes/revisions and performance AC budgets. Never infer a speed win
     from exit 0 or an inconclusive result. Runtime checks supplement local tests.
6. **Adversarial mode** (per `config.truth_gate` — `off` / `red` / `always`, default `red`): see section below.
7. Decide per finding. Only a Blocker with a citation counts — yours, `ponytail:ponytail-review`'s
   or a truth-check sub-agent's. Everything else is a Note: report row, no thread, no bounce.
   - **Backlog** → file it (step 4 of the review flow), then keep going. Never bounces a card.
   - **No Blockers + threads clean + truth ≥ threshold (when it ran) + tests green** → run the **merge protocol** (below). Never move a card to Done any other way.
   - **Code-side Blocker** → new `[builder]`-prefixed thread naming the citation, move card Review → Ready (`loop:rebuild-N`).
   - **Test-side Blocker** → new `[qa]`-prefixed thread naming the citation, move card Review → QA (`loop:rebuild-N`).
   - **Human gate (destructive schema, contract, money, auth, live-DB migration)** → full §4 Block template, move card Review → Blocked. A *clean* PR that merely touches money, auth or schema is not a finding: run the merge protocol, and the gate's `merge_policy` hands it to a human (exit 7 → 🙋 Blocked).
   - **Structured result:** every `bounced` exit carries `citation: "<value>"` — the Blocker's citation, or `"none"` (Gate 1 thread bounce).
8. Write the Reviewer report (marker `<!-- super-review:report -->`, ids on every finding) — edit the existing report comment in place, post a new one only on the first review. It is the next re-review's `prior_report`.
9. Clean up worktree.

### Merge protocol — Done means merged

Builder opens PRs as **drafts**, and GitHub never auto-merges a draft. Skipping the
`gh pr ready` step is why a six-hour run landed zero commits on `main` while producing
two complete builds. In order, no shortcuts:

1. `gh pr ready <PR>` — idempotent, safe on an already-ready PR.
2. Merge through the gate, pinned to the head you reviewed (`merge_policy.default: "human"`
   keeps a person on every merge — the gate returns exit 7 below):
   record `gh pr view <PR> --json headRefOid` when review passes, then
   `super-board-merge-gate.sh --config <cfg> --pr <PR> --expect-head <sha> --subject "<PR title>"
   --body-file <msg.md>` (it merges with `--match-head-commit`; the message is the PR title plus the
   commit bullets and `Closes #N` — writing-standard.md § 1). Exit 6 = the head moved after review → your evidence is void;
   leave the card in **Review** with a `[reviewer]` comment naming both shas.
   The gate owns the merge decision (config `merge_policy`, `migrations`):
   - **Exit 9 — verification-readiness.** Halt the run; preserve card, approval, claims, and worktree. Configure `verify_commands` with the owning project's real checks and restart explicitly. No bounce to Build, rebase retry, approval request, or bare merge.
   - **Exit 7 — a human merges.** `merge_policy` matched (money / auth / schema label,
     path or added-line keyword; a red-tier diff over `auto_max_lines`, default 600 source
     lines — "big PR — please review"; `default: "human"`). `schema` means destructive only (DROP / TRUNCATE / RENAME);
     an additive migration follows `migrations.allowed_envs`, and a live DB is always human.
     Card → **Blocked** with the 🙋 template: `Why blocked` quotes the gate's
     `human-gate:` lines; `To unblock` = review PR #<P> and merge it yourself, OR comment
     `done` to approve (the next wave re-runs the gate, which merges). Label `needs-you`.
   - **Exit 10 — deep review.** A non-red PR over `auto_max_lines` (600 source lines) gets a
     deeper review, not the owner. Stdout has a `deep-review: <why>` line. Re-run the whole
     review on the strongest model the host offers (Opus; on a smaller model, spawn it as
     one sub-agent on Opus): the code pass with no green-card skip, the test rerun, and the
     truth-check whatever the tier or `truth_gate`. Post it as the Reviewer report (`Did:`
     names the deep review). Clean → `gh pr edit <PR> --add-label deep-reviewed` (missing
     label → `gh label create deep-reviewed --color 0E8A16` once), then re-run the gate with
     the same `--expect-head`. The label counts only when added after the head commit. A
     cited Blocker or a truth score below threshold → bounce or block as usual; no label.
     No human unless the tier is red (then the gate exits 7).
   - **Exit 11 — draft.** The Reviewer marks it ready (`gh pr ready <PR>`) and re-runs the
     gate. Never Blocked, never a halt.
   - **Exit 12 — a GitHub read came back empty or malformed.** Leave the card in Review;
     the next wave re-runs the gate. Never Blocked, never a halt.
   - **Exit 8 — 🙋 needs you.** Migrations for a database outside
     `migrations.allowed_envs`, an allowed migrate command that failed, or a declared
     human-only step. Card → **Blocked** with the 🙋 template
     (`block-template.md` → "🙋 Needs you"), the gate's `needs-you:` commands copied
     verbatim into `To unblock`, label `needs-you`, `blocked-by: -`. After the human
     comments `done` after the current pinned request, the next wave verifies their
     permission and the head, then moves it to Review. Re-run the gate; labels do not
     authorize it. For exits 7 and 8, copy `approval-request:` into the canonical
     issue block and link it from the PR (no duplicate request); see block-template.md.
   - The rule in one line: the robot migrates the databases it was allowed to test its
     work; live databases, money, auth and destructive schema changes wait for a person.
3. **Confirm the merge landed** — never trust the merge command's exit code:
   **Exit 79 — required GitHub evidence unavailable:** stop the current run. Leave
   the card, approval, claims, and worktree intact. Report the local halt reason;
   do not classify missing data as safe, bounce it to Build, or post a new approval
   request. Explicit recovery is in run-workflow.md → Required GitHub evidence.

   `gh pr view <PR> --json state,mergeCommit` must report `MERGED` plus a commit sha,
   and that sha must be an ancestor of the base branch
   (`git merge-base --is-ancestor <sha> origin/<base>`).
4. Only then: close the issue, move card Review → **Done**, post the ✅ comment citing
   the merge commit sha.
5. Merge refused (failing checks, conflicts, branch protection) → card Review →
   **Blocked** with the §4 Block template naming the blocker. Never leave it in Review;
   a card left in Review gets re-picked and re-reviewed indefinitely.

**Invariant:** a card in `Done` has its code on the base branch. The run loop's
landed-work halt gate reads `Done` as its definition of progress, so a card marked Done
without a confirmed merge makes a runaway look like a healthy run.

### Prefix discipline
- Every new review thread Reviewer writes MUST start with its owner lane — `[builder]`, `[qa]`, or `[reviewer]` — then a label: `[blocker]`, `[issue]`, `[suggestion]`, `[nit]`, `[question]`, `[praise]` (writing-standard.md § 4). Older PRs may carry `[QA]` / `[review]`; read them as `[qa]` / `[reviewer]`.
- Unprefixed **top-level** human PR comments → treat as 🧑 Block reason. Move card Review → Blocked with the full §4 template.
- Inline human review-thread replies → context only, no Block.

### `super-truth` is folded into super-review
The standalone `super-truth` skill is removed (spec §10 item 8.9). The adversarial pattern is now built in — see next section.

## Adversarial mode (folded from super-truth)

Activated per `config.truth_gate`:
- `off` — never adversarial.
- `red` (default) — only cards whose zone tier is red.
- `always` — every card.
- `non-trivial` (deprecated) — diff ≥10 lines OR labels in `{security, migration, payments, auth}`.

When activated, spawn 2 sub-agents in parallel:
- **Code-grounder.** Verify cited file:line still exists and matches claims.
- **Historian.** `git blame` the changed lines; check for ADRs / prior incidents.

**Use this brief verbatim.** Fill the `<…>` slots; do not reword, add or drop lines. A
reviewer that wrote its own brief once told the sub-agents over-engineering was blocking,
and a correct PR was held for it.

```
You are the <Code-grounder | Historian> in an adversarial truth-check of PR #<P>.
Job: <Code-grounder: verify every file:line the PR cites still exists and does what the PR
claims. | Historian: git blame the changed lines; look for ADRs, prior incidents, reverted
attempts.>
Read the issue ACs and the diff first and form your own hypotheses. Only then read the
builder's summary below, as claims to check, not as the frame.
ACs: <paste>
Diff: <merge-base diff or path to it>
Builder's summary (claims): <paste>
Budget: at most 50 gh calls; prefer local git. Over budget: confidence "insufficient_data".
Class every finding: Gap / Bug / Verification miss / Scope drift / Over-engineering / No issue.
Severity: Blocker / Should fix / Nit.
Over-engineering is ALWAYS Should fix and NEVER Blocker on its own. It does not lower your
confidence score.
Confidence 0-100 = how sure you are the PR's claims are true and the code does what the ACs
ask. Design taste and over-building do not count against it.
Return: findings (class, severity, file:line, one line each) and confidence.
```

**After collecting, the Reviewer applies the severity rule itself:** a sub-agent finding is a
Blocker only with a citation; everything else is a Note. The merge decision is the Reviewer's,
not the sub-agents'.

**Aggregation rule: take the MINIMUM of the two scores.** Rationale: one strong skeptic should be enough to block.

Compare aggregate to `config.truth_threshold` (default `70`):
- **Below threshold** → Reviewer MUST NOT approve. Open `[reviewer]`-prefixed PR thread quoting the lowest-confidence sub-agent finding. Write the full §4 Block template comment. Move card Review → Blocked with reason 🛡 truth-check failed (confidence X/100). The bot's "Why I cannot decide" line names the specific sub-agent finding it could not confirm.
- **Above threshold** → continue to approval decision.

### Block/Skip exits use the §4 mandatory template
Same rule as super-build/super-qa.
