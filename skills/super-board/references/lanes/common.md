# super-board lanes — shared lane contract

Every lane (Builder, Tester, Reviewer) reads this file with its own lane file: `build.md`, `qa.md` or `review.md` in this folder. The orchestrator's material (preconditions, routing, halt gates, sweep) is in `../run.md`.

## Branch + PR model — one branch, one PR per issue

Format: **`issue-<N>-<kebab-title>`** (no lane prefix).

Example: `issue-42-add-chat-streaming`.

There is **exactly one branch per issue** and **exactly one PR per issue**. All three lanes work on the same branch in their own worktrees:

- Builder creates the branch off `config.base_branch`, writes code, commits + pushes, opens a **draft PR**.
- Tester checks out the same branch in a fresh worktree, adds tests, commits to the same branch, pushes.
- Reviewer is the **only lane that merges**. On approval: squash-merges PR into `base_branch`, deletes the branch.
- If `config.merge_policy` says a human merges (`default: "human"`, or a money / auth / schema hit, or a red-tier PR over the size cap), the merge gate exits 7 and the Reviewer parks the card in Blocked for a human click instead. A non-red PR over the cap gets a deep review instead (exit 10, no human; `review.md` → "Deep review").

## Command shape — every lane, every command

A permission rule matches one plain command. Anything else misses the allowlist and goes to
the permission checker, which denies GitHub writes and strands the card (#37), and in Accept
edits mode prompts the owner on every call (#94).

- **One literal call per Bash call.** Copy commands as written, with literal paths
  (`python3 .claude/bin/super-board-github-read.py --check`). No shell variables for paths
  or values (`R=…`, `SP=…`, `$R`, `"$(…)"`), no `&&`, `;`, `|` or `echo $?`. Every Bash call is
  a fresh shell, so a variable or a sourced function is gone by the next call anyway. The
  exit code is in the tool result; read it there. A value you need later (a sha, a path),
  read it with its own call and paste the literal into the next one.
- **Card text never goes inside a command** (no heredoc, no `--cards -`, no `echo '<json>' |`).
  The secrets guard scans the whole command, so a body that only names the env file halts the
  wave (#88). Write the JSON or body to a file with the Write tool and pass the path
  (`--cards <file>`, `--body-file <file>`).

- **Scripts exactly as written.** Call a `.claude/bin` script the way the docs spell it
  (`bash .claude/bin/super-board-preflight.sh …`, `python3 .claude/bin/super-board-config.py …`),
  from the main checkout: never a worktree's copy, which the permission decider denies.
  When your shell sits in a worktree, use the main checkout's absolute path
  (`bash <main>/.claude/bin/<script> …`), never a `cd` into the worktree first.
- **Read files with the Read tool**: lane docs, skills, configs, code. Not `cat`, `sed -n` or
  `grep` to pull a section out; Read the file and find the section.
- **Config values come from one helper**: `python3 .claude/bin/super-board-config.py get
  <key> --config <cfg>` (`base_branch`, `repo`, `merge_policy.default`, `verify_commands`).
  Never `python3 -c`, `python3 - <<EOF` or `node -e`: inline code is denied for lanes.
- **Change files with the Edit and Write tools**, never a Python or `sed -i` script. Never
  edit `.claude/bin`, `.claude/hooks`, `.claude/workflows` or `.claude/settings*.json` in any
  checkout (denied): a fix there goes on the `❌ Not done:` line for the owner.
- **Merge only through the gate** (`review.md` → "Merge protocol"). `gh pr merge`, a REST
  `pulls/<N>/merge` call and the merge GraphQL mutations are denied in every spelling.
- `gh`, `.claude/bin/…` and board commands run as one plain command: no `cd … &&` in front,
  no shell loop, no `;` or `&&` chain. Name the repo with `-R <owner>/<repo>` (or
  `--repo`, or `--config` for board scripts), never by changing directory. Ten threads to
  reply to → ten commands.
- `git` runs as `git -C <absolute worktree> …`. Before every commit and push, check
  `git -C <worktree> rev-parse --show-toplevel` and `git -C <worktree> branch --show-current`
  name your worktree and branch: lanes can share a shell's working directory (#23).
- Tests and builds run from the worktree: as the lane's own cwd when it was started there,
  else pinned with the runner's own flag (`pnpm -C <worktree> …`, `npm --prefix <worktree> …`,
  `npx playwright test --config <worktree>/playwright.config.ts`). `cd <worktree> && …` only
  when the runner has no such flag: it is a local command, never a GitHub one, and it prompts.
- Verify runs in the **foreground** and you wait for it: never `run_in_background`, `&` or
  `nohup`. A lane that hands back while verify runs hands back nothing.
- Cap test workers at 2 per lane, or parallel lanes overload the machine and timing tests
  flake (#5): vitest or jest `--maxWorkers=2`, Playwright `--workers=2`, pytest-xdist `-n 2`.
  Write the capped command into `Local tests:` so the Reviewer reruns the same thing.
- A denied **optional** write (a thread reply, a thread resolve, a comment edit) never stops
  the handoff. Post a new comment instead, or name the skipped write on the `❌ Not done:`
  line, and finish the exit. Only a denied **required** write (card move, handoff comment)
  stops the lane: return `failed` with the planned writes in `detail` for the orchestrator.

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
| `ac` (checklist + one proof line each) | writes all unchecked | ticks with proof, or leaves unchecked with the reason | unticks one it disproved · on a green card (no QA) ticks each it confirmed, with proof |
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

**No partial merge.** The gate (exit 13) refuses a PR whose `ac` block has an unticked AC, or a
ticked one whose proof line does not cite `path` or `path:line` of a file at the head (a test or
file, never "manual"). An AC that cannot be met is built, or split: the builder files a Backlog
card holding that AC (`super-qa-file-bug.sh --column Backlog --kind feature --label scope:pending`, body links `#<this>`),
deletes the AC from this card's checklist and writes one line `AC<n> moved to #<N>` in `solution`.

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

### Thread and comment writes — the one allowed route

The lane that fixed a finding resolves its thread once the fix is pushed. One command per
thread, each a single plain `gh api` call (allowlist `Bash(gh api graphql:*)` and `Bash(gh api:*)`):

```
# list thread ids (read)
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{body}}}}}}}' -F o=<owner> -F r=<repo> -F n=<PR>
# resolve one thread
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<thread-id>
# reply in a thread
gh api repos/<owner>/<repo>/pulls/<PR>/comments/<comment-id>/replies -f body='<text>'
# edit your own comment in place
gh api -X PATCH repos/<owner>/<repo>/issues/comments/<comment-id> -F body=@<file>
```

A denied resolve or edit is an optional write (see "Command shape"): say so on the
`❌ Not done:` line and finish the handoff.

## Commenting cadence (issue + PR, every lane)

Every lane writes BOTH on every exit, in the comment format of writing-standard.md § 4:

```
[<role>] [<label>] <status-emoji> <status> · <context>
Did: <one line>
✅ Done: <what passed or landed, with sha / file:line / command>
❌ Not done: <what failed or was skipped, and why>   (omit when nothing)
Next: <builder | qa | reviewer | owner | none>
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

## Round cap

On a bounce, the card carries `loop:rebuild-N`. If N + 1 ≥ the zone's `max_rounds`
(`super-board-zone.py` on the changed files), the card goes to **Blocked** with the §4
template, `Why blocked: round cap — needs a ruling or split`, instead of bouncing again.

## Root-cause hash

Each lane writes a deterministic hash to its failure handoff comment, so a reader can see when two failures share a cause:

```
root-cause-hash: <sha256 first 12 hex chars>
```

The hash inputs (joined with `|`):

1. Lane (`build` / `qa` / `review`).
2. Error class — first matched: `test_assertion`, `test_runtime`, `build_fail`, `lint_fail`, `merge_conflict`, `network`, `auth`, `quota`, `other`.
3. First 3 unique `file:line` frames from the captured stack trace / test output (sorted, normalized — strip absolute paths to repo-relative).

The hash is evidence only; the round cap above decides when a card stops bouncing.

## Worker rate-limit etiquette (read before any burst of gh calls)

Workers share the orchestrator's gh-auth token bucket. Every worker MUST follow `rate-limit-etiquette.md` (in this directory):

- Move and read cards with `.claude/bin/super-board-card.sh --config <cfg> move <issue> <Status>` / `status <issue>` — 1 GraphQL point. Every "move card X → Y" in the lane lifecycles means this call. Comments, labels and PR reads go over REST (`rate-limit-etiquette.md` → "Price list").

- Call `bash .claude/bin/super-board-gh-guard.sh check 200` before any burst of gh calls (thread reads, sub-agent spawn, exit verification). One plain call; never `source` it from a lane.
- Adversarial sub-agents are capped at 50 gh calls each — prefer `git blame` (local) over `gh api graphql`.
- Final PR handoff comment MUST include `gh-quota-on-exit: graphql=<n>/5000 rest=<n>/5000` (use `bash .claude/bin/super-board-gh-guard.sh summary`).
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
