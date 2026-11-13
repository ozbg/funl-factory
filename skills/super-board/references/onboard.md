# super-board onboard — verb reference

Config schema and field notes: `config-schema.json`. Loaded by `SKILL.md` for `super-board onboard`.

**Where it runs:** the current Claude Code session, in the user's folder. Not headless.
Invoked as `/super-board onboard` (get.sh / install.sh) or `/super-board:super-board onboard`
(plugin install — skill names carry the plugin prefix).

## Host-visible skill checks

Checks use `.claude/bin/super-board-skills-ready.py --profile setup --host
<claude|codex>` and show `helper_readiness`: exact files, declared fallbacks,
optional skips and missing names. Setup checks the unconditional union; a
selected card may need fewer helpers. Node or `skills-lock.json` never proves
readiness. `check` and dispatch install nothing. Explicit `fix` retains helper
installation, then re-resolves actual files; an installer exit of zero alone is
not success. `--no-helpers` suppresses that repair attempt, not missing evidence.
The helpers are the 18 in `skills/families.json` → `helpers`, fetched by name per source
(never `--skill '*'`). Cloudflare's `security-audit` is retired: install.sh prunes it. A config
still naming a retired backend (`claude-p`, `codex`, `--codex`) gets a one-line fix in
`legacy_backend`, never a red check. The bundled `pr-security-review` is a pack
skill: install.sh ships it and the QA lane requires it.
A host plugin inventory may be supplied with `--catalog <active-skills.json>`;
only enabled entries applying to this project count.

## Design rules

| Rule | How |
|---|---|
| Wizard | 8 numbered steps. Each opens with the agenda strip and `N of 8 · <emoji> <Name> — <one short why>`, then one `AskUserQuestion` |
| Minimal text | what it found in one line, then the question. Details go in an option's description or one dim line under it — never a paragraph |
| Recommended first | every question puts its recommended option FIRST, labelled `(Recommended)`, so Enter takes it |
| One tool | ask with `AskUserQuestion` (≤ 4 questions per call, ≤ 4 options per question; the built-in "Other" box is the free-text option). NEVER free-text a choice that has options |
| Fix, don't ask | a must-have (skills, scripts, workflows, guard hooks, settings entries, old folders, config keys, labels, columns) is fixed with NO question and listed under "Fixed for you". Only system tools and sign-ins are asked — through Claude Code's own permission prompt on the exact command |
| Save as you go | every answer is written to `.claude/super-board/onboard-answers.json` the moment it is given |
| Write once | files in the repo (config, settings.json allow lines, AGENTS.md, CLAUDE.md, docs) change only at step 8, after "Write everything". GitHub-side actions the user just picked (create or extend the board, create `staging`) run in their own step |
| Secrets | NEVER read, grep, cat or source a dotenv file. Key names only, via `.claude/bin/super-board-env-check.sh` |

**Scripts.** `SB=.claude/bin` after an install. Plugin install before step 1 has run: the plugin's
own copy, `PACK=$(dirname "$(find ~/.claude/plugins -path '*super-board*' -name install.sh -not -path
'*/node_modules/*' 2>/dev/null | head -1)")`, `SB=$PACK/scripts`. `$PACK` empty → `🛑 Can't find the
super-board plugin files. Run the one-line installer (get.sh) or ./install.sh <this-dir> from a
checkout, then re-run onboard.`

| Script | Used in |
|---|---|
| `python3 $SB/super-board-setup.py check / fix --text` | 1 Checks |
| `python3 $SB/super-board-setup.py board-rank / board-migrate / names` | 1 (upgrade), 3 Board |
| `python3 $SB/super-board-setup.py branch` | 4 Branch |
| `python3 $SB/super-board-agents-md.py …` | 5 AGENTS.md |
| `python3 $SB/super-board-settings.py allow … --dry-run` · `risky` · `remove … --dry-run` | 6 Policies |
| `python3 .claude/skills/super-collect/scripts/collect_custom.py classify / ping / add` | 7 Bug sources |

---

## Screens

**Start** (after the skill loads; nothing asked yet):

```
⏺ super-board setup — 8 steps. Enter takes the recommended answer.
  1 🔍 Checks       install or update what the board needs
  2 🔑 GitHub       sign in so I can manage boards
  3 🗂️ Board        pick or create your project board
  4 🌿 Branch       choose where finished work merges
  5 📜 AGENTS.md    move your rules into one file
  6 🛡️ Policies     what the robot may do alone
  7 📥 Bug sources  where to find problems to fix
  8 ✅ Review       check every answer, then save once
  Stop any time; re-run continues. Live site only? /super-qa <url>.
```

**Agenda strip** — first line of every step, done steps ticked, the current one bold:

```
✓ 1 Checks · ✓ 2 GitHub · 3 Board · 4 Branch · 5 AGENTS.md · 6 Policies · 7 Bug sources · 8 Review
⏺ 3 of 8 · 🗂️ Board — the robot takes tickets from here.
```

| # | Header line |
|---|---|
| 1 | `1 of 8 · 🔍 Checks — install or update what the board needs.` |
| 2 | `2 of 8 · 🔑 GitHub — sign in so I can manage boards.` |
| 3 | `3 of 8 · 🗂️ Board — the robot takes tickets from here.` |
| 4 | `4 of 8 · 🌿 Branch — where finished work merges.` |
| 5 | `5 of 8 · 📜 AGENTS.md — Claude reads AGENTS.md; CLAUDE.md becomes "@AGENTS.md".` |
| 6 | `6 of 8 · 🛡️ Policies — what the robot may do alone.` |
| 7 | `7 of 8 · 📥 Bug sources — where to find problems to fix.` |
| 8 | `8 of 8 · ✅ Review — nothing is written until you say so.` |

**Resume** — an answers file with `last_step` and no finished config. Saved answers first, then
the question:

```
⏺ Bash(cat .claude/super-board/onboard-answers.json)
  ⎿  saved 2 Oct, 18:40 · stopped at Policies & permissions
⏺ 💾 Found your answers from last time:
  ✓ GitHub: erictech        ✓ board: Ledgerly Roadmap
  ✓ base: staging           ✓ AGENTS.md: merged
  → stopped at 🛡️ Policies & permissions
```

AskUserQuestion "Continue where you left off?" [Continue at <step> (Recommended) / Edit an earlier
answer — pick which on the next screen / Start over — saved answers are renamed .bak]. Step 1
Checks always runs again first, silently unless it fixes something.

**Re-run on a finished setup** (config exists, nothing interrupted): show the current values in
the step-8 table, then "Onboard found an existing setup. What now?" [Keep all — check and repair
(Recommended) / Edit an earlier answer / Start over]. Keep all = step 1, the board repair of step 3
(`board-migrate`, no question), the step-7 pings, the self-check. A CLAUDE.md that is no longer the
`@AGENTS.md` pointer → step 5 is offered even under Keep all.

---

## The answers file

`.claude/super-board/onboard-answers.json` (gitignored — step 8 adds it):

```json
{ "version": 2, "updated": "<iso>", "last_step": "policies",
  "answers": { "github": {"login": "erictech", "remote": "github.com/erictech/my-app"},
               "board": {"owner": "erictech", "number": 4, "title": "Ledgerly Roadmap", "reused": true},
               "base_branch": "staging", "agents": "merged",
               "policies": {"merge_default": "auto", "protect_main": true, "allowed_envs": ["test", "staging"]},
               "permissions": "add", "collect": ["sentry", "github", "prs", "architecture", "linear"],
               "custom": [{"name": "linear", "kind": "mcp", "target": "linear"}] } }
```

Write it atomically (temp file + rename) after every answer. A halt never loses work.

---

## Step by step

```
0. SILENT DETECT (no questions, nothing printed but the start screen)
   ├─ answers file, .claude/super-board/configs/*.json → resume / re-run screens
   ├─ instruction files: python3 $SB/super-board-agents-md.py detect
   ├─ manifests + README (board names), branches + deploy signals ($SB/super-board-setup.py branch)
   ├─ migration dirs (supabase/migrations, prisma/migrations, drizzle, **/migrations/*.sql,
   │    db/migrate, alembic/versions) and migrate scripts in the manifest (db:migrate, …)
   ├─ collect signals: Sentry (@sentry/* / sentry-sdk in manifests, Sentry.init(, .sentryclirc),
   │    PostHog (posthog-js / posthog-node / posthog, posthog.init(, NEXT_PUBLIC_POSTHOG_* names);
   │    key names: bash $SB/super-board-env-check.sh SENTRY_AUTH_TOKEN POSTHOG_PERSONAL_API_KEY
   ├─ verification commands: preserve valid `verify_commands`; otherwise inspect the owning
   │    project's documented checks and stage those commands. Unresolved checks are a setup
   │    halt. Never save placeholders or invent a universal runner.
   │    A new app mid-Define (`docs/shape/north-star.md` exists, no app manifest such as
   │    package.json, pyproject.toml, go.mod or Cargo.toml) has no code and no checks yet:
   │    stage `verify_commands: []`, say in one line "Checks are set at /to-board, once the
   │    spec picks the stack.", and never report it as a failure (DONE, self-check).
   ├─ project verifier: detect `.agents/skills/verify-*/SKILL.md` and feature maps.
   │    For creation or upkeep read `../../super-qa/references/project-verifier.md`;
   │    stage real project checks only when source names accepted features. Optional
   │    verifier gaps never replace or block the required verification commands.
   └─ machine time zone for config `timezone`: $TZ, else readlink /etc/localtime | sed
      's#.*zoneinfo/##', else timedatectl show -p Timezone --value, else "UTC". Shown at step 8.

1. 🔍 CHECKS — nothing asked except system tools and sign-ins
   ├─ python3 $SB/super-board-setup.py fix --host <actual-worker-host> --text
   │    Fixes with NO question, backed up first to .claude/super-board/backup/<ts>/:
   │    skills, .claude/bin scripts, workflows, guard hooks + settings.json entries (runs the
   │    pack's install.sh), removes old skill folders (super-refine, cleanup-wt, arch-loop),
   │    migrates every config to the v3 keys, git init, and the 18 helper skills (Node present).
   │    install.sh also prunes retired skills (backed up first) and keeps the owner's own.
   ├─ Print its list exactly, one ✓ per line:
   │      ⏺ Fixed for you:
   │        ✓ super-board skills and scripts installed
   │        ✓ board engine (workflow) installed
   │        ✓ 6 safety guards switched on
   │        ✓ settings.json entries added (backup kept)
   │        ✓ git repo found
   ├─ Each `needs` item (a system tool): one line, then run its `command` with Bash — Claude
   │    Code's permission prompt IS the question. No AskUserQuestion.
   │      Needs your machine: Node.js isn't installed. It's needed for the helper installer; actual coding
   │      skills (tests, code review, debugging) the board uses.
   │      → Bash(brew install node && npx -y skills@latest add mattpocock/skills --skill tdd … && npx -y skills@latest add obra/superpowers --skill verification-before-completion …)
   │    The command is per OS (brew / apt / dnf / winget) and comes from the script.
   │    Declined: node → report exact missing skills and keep readiness red; existing resolved
   │    helpers still count, but missing required helpers halt dispatch;
   │    git or gh → halt: "Without <tool> the board can't <why>. Your answers are saved — run
   │    the command, then re-run onboard."
   ├─ Re-check (`check --text`) after every install; move on only when it says all green.
   ├─ Design plugin (Claude host only; `/mockup` step 8 runs it). On if EITHER holds:
   │    a `frontend-design` skill is in this session's available skills (any namespace, e.g.
   │    `<plugin-id>:frontend-design`, which is how claude.ai account plugins show), OR
   │    `enabledPlugins` has a `frontend-design@…` key set to true in `~/.claude/settings.json`
   │    or `.claude/settings.json`. Neither → no question, one line:
   │      Needs your machine: frontend-design plugin is off; /mockup's design polish needs it.
   │      → enable "frontend-design" in claude.ai plugins (desktop app), or
   │        /plugin install frontend-design@claude-plugins-official; then start a NEW session
   │        (plugins load at session start).
   │    It never blocks onboard; a missing plugin stops only /mockup step 8.
   ├─ Workflow runtime: syntax-check the installed workflow (same command run-workflow.md uses):
   │      { echo '(async function(){'; sed 's/^export const meta/const meta/' \
   │        .claude/workflows/super-board-wave.js; echo '})'; } | node --check --input-type=module
   │    Fails → fix re-copies it; still failing → 🛑 (error table). Remind once: dynamic
   │    workflows must be ON in /config.
   └─ OLDER SUPER-BOARD (the result says `upgraded: true`): same rule, no question. Header
      `1 of 8 · 🔍 Checks — found super-board v<from>; upgrading to v<pack>.` and the list:
          ⏺ Upgraded for you (backup: .claude/super-board/backup/<ts>/)
            ✓ skills updated; added super-collect, git-sync, north-star, pr-security-review
            ✓ removed old folders: super-refine, cleanup-wt, arch-loop
            ✓ scripts, board engine and safety guards updated
            ✓ config moved to the new keys (merge rule, migrations, sources)
            ✓ labels mapped: build→feature · bug-fix→bug · qa-only→qa (14)
            ✓ Skipped column: 4 cards moved to Done, column removed
            ✓ re-checked: all green
          Your CLAUDE.md still has its own rules — step 5 offers to move them.
      The two board lines come from `python3 $SB/super-board-setup.py board-migrate --config
      <config>` — run it here when `gh auth status` already has the project scope, else in
      step 3 (it then prints them there). It adds missing columns, creates qa · bug · feature,
      maps old labels, labels every card `qa` on a board that was "qa-only", moves Skipped
      cards to Done, removes Skipped and restores any status the change cleared. Keep the board
      idle during this operation. The helper saves every card/status and label conversion plan
      in `.claude/super-board/migrations/` before writing to GitHub. A failed upgrade is not a
      completed setup: keep the recovery file and re-run the same command from the same project
      root (or with the same `--root`). It resumes the saved plan and verifies remote results;
      it never takes a new snapshot over a partially upgraded board. No extra setup question.

2. 🔑 GITHUB
   ├─ Bash(gh auth status). Signed in with project scopes → `✓ GitHub connected.`; continue below.
   ├─ Not signed in → one line, then Bash(gh auth login) — the permission prompt asks.
   ├─ Missing scopes → "This opens a browser to approve board access — needed to move cards and
   │    create the board for you." then Bash(gh auth refresh -s project,read:project,repo)
   ├─ Bash(git remote get-url origin). No remote → AskUserQuestion "This project isn't on GitHub
   │    yet. Create a repo?" [Create a private repo (Recommended) / Use an existing repo /
   │    Not now — the robot can't open pull requests]. Create → gh repo create <login>/<folder>
   │    --private --source . --remote origin
   ├─ Second account (AskUserQuestion, header "Robot account"); explain in four short lines:
   │      The robot's gh issue, gh pr and gh project GraphQL calls share your 5,000 points/hr.
   │      Finfluencer (2026-10-03/04): 3 cards cost ~2,850 (~950/card); 14 used all 5,000 in ~40 min.
   │      Board moves then failed; nearly every wave left the board idle for up to an hour.
   │      Your browsing and tools share that budget. A bot gets its own 5,000 points/hr.
   │    "Want a second GitHub account for the robot? It gives the board its own hourly budget,
   │    so it can run more cards before pausing. Takes about 10 minutes."
   │      • Yes, set it up now (Recommended)
   │      • Not now — stay on my account; waves pause when the hourly limit runs out
   │    Save the choice with the GitHub answers. Yes → follow references/second-account.md;
   │    keep the owner active through step 3, then finish bot access before step 4. Keep the
   │    repo/project owner unchanged. Already on a verified bot → keep it; don't create another.
   └─ bot_identity: new board with a machine account → bot username; existing board → keep its
      configured claim identity. Otherwise `super-board-bot[bot]` when a GitHub App is installed
      on the repo, else the login. Stage `notifications.bot_identity` for step 8; see second-account.md.
      Stage `notifications.owner_name` too: the repo owner's GitHub name
      (`gh api users/<owner> --jq '.name // .login'`); an existing value is kept.

3. 🗂️ BOARD — one question: which board
   ├─ One checklist line, one labels line, no question about either:
   │      Columns: ✓ Backlog ✓ Ready ✓ Building ✓ QA ✓ Review ✓ Blocked ✓ Done
   │      Labels: feature · bug · qa (qa skips Building; no label = feature)
   ├─ python3 $SB/super-board-setup.py board-rank --owner <owner>   (boards ranked by matching
   │    columns; `recommend` = the best with ≥ 4 of 7)
   │  python3 $SB/super-board-setup.py names                         (two names from
   │    package.json / README / folder)
   ├─ AskUserQuestion "Which board?" (header "Board"):
   │    • Use <title> (#<n>) — <m> of 7 columns match, I'll add <missing> (Recommended)
   │        description: its URL (github.com/users/<owner>/projects/<n>)
   │    • Create a new board named "<names[0]>"       (Recommended when nothing is recommended)
   │    • Create a new board named "<names[1]>"
   │    "Other" = Type a name.
   ├─ Reuse → board-migrate --owner <o> --number <n> --repo <owner/repo>: adds the missing
   │    columns, the three labels, keeps every card. Prints `<title> ready`.
   └─ New → gh project create --owner <o> --title "<name>", link it to the repo, then
      board-migrate --prune-empty on it (the seven columns replace GitHub's default Todo /
      In Progress; labels). Prints its URL.
   There is no "Needs you" column and no Skipped column: a card waiting on a person goes to
   Blocked with 🙋 (block-template.md); a card dropped on purpose is closed and moved to Done.
   Second account chosen in step 2 → finish references/second-account.md now; verify bot access.

4. 🌿 BRANCH
   ├─ python3 $SB/super-board-setup.py branch → one line:
   │      Found: main (deploys to production via Vercel), no staging.
   ├─ AskUserQuestion "Where should finished work merge?" (header "Branch"):
   │    no staging:   • Create staging from main (Recommended) — "nothing goes live until you
   │                    move it to main" (or "keeps main clean" with no deploy signal)
   │                  • main — every merge goes live (or just "main" with no deploy signal)
   │    staging found: • staging (Recommended) — already exists · • main — every merge goes live
   ├─ Create staging → Bash(git push origin main:staging) right away (the pick is the OK).
   └─ main kept with a deploy signal → step 6 defaults to "you merge everything", target_env "live".

5. 📜 AGENTS.md — one line, one question; one short question per conflict
   ├─ detect says CLAUDE.md is already the pointer → `✓ Already done — CLAUDE.md is "@AGENTS.md".`
   ├─ No instruction files → "Create AGENTS.md for your project rules?" [Yes (Recommended) —
   │    CLAUDE.md becomes "@AGENTS.md" / Skip]
   ├─ Otherwise N = rule units in CLAUDE.md (`units --file CLAUDE.md`):
   │    AskUserQuestion "Move your N CLAUDE.md rules into AGENTS.md?" (header "AGENTS.md")
   │      • Yes, move them (Recommended) — backup first, diff before saving
   │      • Only add the super-board section
   │      • Skip
   ├─ Yes → draft the merge into onboard-staged/ by the rules below. Each conflict = its own
   │    AskUserQuestion, header "Conflict k of n", question "<Subject>: which rule wins?",
   │    options quoting BOTH lines verbatim with file:line, the more specific one Recommended.
   │    Then one tool line: Bash(super-board-agents-md.py coverage && check) ⎿ 31/31 rules kept ·
   │    118 lines. Written at step 8.
   ├─ Only the section → stage `block --create`; a CLAUDE.md alone gets `@AGENTS.md` prepended.
   └─ Writing standard, always, no question: stage docs/agents/issue-tracker.md with a
      `## Ticket format` section from references/ticket-format.md (create, or replace only that
      section). The block's "Writing (super-board)" table links it and writing-standard.md.

6. 🛡️ POLICIES — ONE AskUserQuestion call, two questions; details folded
   Q1 header "Rules", "Use the safe defaults?"
      • Yes (Recommended) — description: "robot merges normal changes · money/logins/DB wait for
        you · no pushes to main · migrate test + staging only"
        (production base kept: "you merge everything (main goes live) · no pushes to main ·
        migrate test + staging")
      • Review each
   Q2 header "Permissions", "Let it run its commands without asking each time?"
      • Yes, add <N> lines to settings.json (Recommended)
      • No, ask me each time
   Folded details = ONE dim line under each, never a table:
      merge_policy.default auto · always_human: money, auth, schema · push guard on (main, master,
      <base>) · migrations.allowed_envs: test, staging
      + Bash(gh project:*) + Bash(gh issue:*) + Bash(gh pr:*) + … (the --dry-run output, joined)
   Wide lines already in settings.json (`super-board-settings.py risky .claude/settings.json`
   prints them: `node:*`, `python3 -c`, `gh pr merge`, a wildcard over `.claude/bin/` …) → Q2's
   Yes description adds "and remove <K> lines that let the robot run any code or merge around
   the gate", listed in the dim line with a `-`; Yes runs `remove` with them at step 8. The
   permission decider (hooks/README.md) allows the safe forms of those commands without them.
   Self-migrating app — migration dirs exist and the manifest has no migrate script — ONE
   question, even on safe defaults, header "Migrations": "Does the app apply its own
   migrations (on startup, or its deploy does)?" [Yes, it migrates itself (Recommended when
   the app opens a local database such as SQLite) / No, the robot runs a command].
   Yes → `migrations.commands[env] = "-"` for every env in allowed_envs and target_env, no
   `checks`: the gate then has nothing to run and raises no false 🙋 for a migration PR.
   Review each → ONE more AskUserQuestion call, up to three questions:
    a. "Merge" — "Who merges a change that passes review?" [Robot merges normal changes
       (Recommended) / I merge everything]; production base: the order flips, and robot-merges
       sets merge_policy.allow_auto_on_production: true (run.md's guard needs it).
       → merge_policy.default "auto" | "human"; auto_max_lines 5000 source lines (tests,
         lockfiles, generated, snapshots, migration SQL not counted; over it → a deeper
         review, not you, unless the tier is red); always_human = schema defaults (money,
         auth, destructive schema). A matching PR parks in Blocked with 🙋. Card size is
         separate: `card_max_lines` 600, the yardstick for lint and the Builder pre-flight.
    b. "Push guard" — "Block pushing straight to main?" [Yes (Recommended for a repo with
       commits) / No]. Skipped when settings.json already wires guard-protected-push.py. Script
       missing (--no-hooks install) → record the answer and say: "Run ./install.sh --no-hooks
       --protect-main <this-dir> — it installs only this guard."
    c. "Databases" (multiSelect, only when migration dirs exist) — "Which databases may the robot
       migrate?" [test (Recommended) / staging (Recommended) / live] → migrations.allowed_envs;
       target_env "live" on a production base, else "staging"; commands from the manifest's
       migrate scripts (ask only for a missing one). A command needing a DB URL resolves it
       from the project's `.env` by absolute path, never from the session, since a lane agent's
       shell loads nothing (config-schema → `migrations.commands`). Write a matching read-only
       `migrations.checks[env]` (e.g. `supabase migration list --db-url …`) and run it now; a
       failure is fixed here, not discovered at the first merge. For Supabase the URL is the
       Session pooler string (port 5432) with special characters in the password URL-encoded,
       and a just-reset password takes ~20 s to reach the pooler — retry once before calling it wrong.
   Permission lines: the base list in "Mid-run permission prompts" below, plus the
   merge line when merge_policy.default is "auto" ("Bash(bash .claude/bin/super-board-merge-gate.sh:*)";
   never a `gh pr merge` line: the gate merges inside its own script, and a direct merge is
   denied), one "Bash(<migrate command>)" per allowed env that is not "-", "Bash(bash
   .claude/bin/super-board-env-check.sh:*)" and the test-runner lines that
   `python3 $SB/super-board-settings.py runner-rules .` prints (npm/pnpm/yarn/bun scripts,
   npx playwright, vitest, jest, tsc, eslint, prettier, vite; pytest; make test; go and cargo
   test; one per line, from the project's own files). N counts what is NOT already in
   settings.json: `super-board-settings.py allow .claude/settings.json <rules…> --dry-run`.

7. 📥 BUG SOURCES — tick sources; "Add another source" is the free-text box
   ├─ AskUserQuestion multiSelect "Where should I look for problems?" (header "Bug sources"):
   │    Sentry — app errors (Recommended when detected) · PostHog — rage clicks, errors, slow pages
   │    (Recommended when detected) · GitHub issues — bugs filed but not on the board · Past PRs —
   │    review comments that keep repeating · Architecture — tangled or duplicated code.
   │    Undetected Sentry / PostHog are left out. More than 4 options → split into two questions
   │    in the same call ("Error sources", "Code sources") — the tool takes 4 per question.
   │    "Other" = ➕ Add another source (link, app, API URL, MCP or command).
   ├─ Feedback is not asked: every app gets the feedback icon (/to-board cuts its card), so
   │    `feedback` always joins collect.sources, with collect.feedback.dir = the app's data
   │    folder + `/feedback` (default `data/feedback`). No key, no ping.
   ├─ Built-ins: ask only what detection missed (Sentry org/project/host, PostHog host/project_id).
   │    Missing key → the exact .env line to add (name only) + scopes: Sentry `event:read
   │    project:read`; PostHog personal key `query:read error_tracking:read`. PostHog failure
   │    events: grep capture() calls for *_failed / *_error, propose them, user confirms.
   ├─ ➕ typed text → C=.claude/skills/super-collect/scripts/collect_custom.py
   │    python3 $C classify "<text>" → kind mcp | http | cli (an app name resolves to one)
   │    python3 $C ping --kind <k> --target <t> [--auth-env <E>] --name <n>   (read-only)
   │      mcp → status "agent": call that server's read/list tool yourself, limit 1, read-only;
   │            pipe its JSON into `$C normalize --name <n>` to count what it returned.
   │    ✅ → `$C add … --config <staged config>` (collect.custom[] + collect.sources).
   │    ❌ → say why in one line (401 → the token name to add to .env); never saved; re-test by
   │         typing it again.
   ├─ Ping each built-in, read-only, before step 8:
   │      python3 .claude/skills/super-collect/scripts/collect_sentry.py  --config <staged> ping
   │      python3 .claude/skills/super-collect/scripts/collect_posthog.py --config <staged> ping
   │      gh api graphql -f query='{viewer{login}}'          (github, prs)
   └─ One result block, one line per source; a failure leaves that source out, never halts:
          ✅ linear — can read issues (12 open bugs); saved in this project's config
          ✅ sentry · github · prs · architecture
          ❌ posthog — key missing: add POSTHOG_PERSONAL_API_KEY to .env (left out)

8. ✅ REVIEW — compact table, then write once
   ├─ Two columns, no borders:
   │      Board    Ledgerly Roadmap #4 (+QA)    Branch   staging (new)
   │      Rules    safe defaults                Perms    7 lines
   │      AGENTS   rules moved, CLAUDE.md→@     Sources  sentry, github, prs, arch, linear
   ├─ Existing or staged project verifier: list skill/map/runner paths and state
   │    `starter, not run` or the actual selected-feature proof. Preserve human-owned
   │    critical paths and flows; missing source leaves this optional helper absent.
   ├─ AskUserQuestion "Write everything?" (header "Save") [Write everything (Recommended) /
   │    Change one thing → pick the step, walk only it, back here / Cancel — nothing written].
   ├─ Write, in order (each atomic; stop and report on the first failure — answers are kept):
   │    ├─ .claude/super-board/configs/<slug>.json (committed): description, project, target
   │    │    {type: repo | repo+url}, repo, base_branch, timezone, columns (the seven), labels,
   │    │    paths, merge_policy, migrations, collect (incl. custom), notifications {channel:
   │    │    "session", bot_identity, owner_name}, worker_backend "workflow", host (always: `bash $SB/super-board-host.sh`;
   │    │    on exit 65 ask claude/codex/opencode), verify_commands (non-blank project checks, or
   │    │    `[]` for a new app mid-Define), `card_max_lines: 600`, wave width `ramp: {"stage": 3}`,
   │    │    model defaults `lane_models: {"review": "sonnet"}`,
   │    │    `lane_models_by_tier: {"red": {"build": "sonnet", "qa": "sonnet", "review": "session"}}` and
   │    │    `lane_models_judgement: {"build": "sonnet", "qa": "sonnet"}`, and report targets
    │    `targets: {"days_per_app": 2, "first_pass_pct": 70, "rework_pct": 10,
    │    "rounds_per_merge": 1.5, "demo_first_try": true, "exam_pass": true, "screens_match": 100,
    │    "walk_pass": 100}`. Each default here (merge cap, card cap, ramp, models, targets) is
    │    for a new config only: a value already set is kept on re-run. No `variant`.
   │    ├─ .claude/super-board/active ← <slug>
   │    ├─ .gitignore += .claude/super-board/active, onboard-answers.json, onboard-staged/,
   │    │    backup/, inflight/, migrations/, upgrade.json (all under .claude/super-board/)
   │    ├─ settings.json: super-board-settings.py allow … ; remove <approved risky lines> ; protect main →
   │    │    super-board-settings.py hooks .claude/settings.json <pack>/hooks/settings-protect-main.json
   │    ├─ AGENTS.md / CLAUDE.md: super-board-agents-md.py backup, then write --src <staged>
   │    │    --dest AGENTS.md, pointer --tail <staged tail> --force, block, check
   │    ├─ staged project verifier skill/map/scenarios/runner, if source-backed; then
   │    │    inspect the saved map and resolve the local skill for the actual host.
   │    └─ docs/agents/issue-tracker.md; docs/super-board/PROJECT.md (a sub-agent drafts it from
   │       manifests + README + tree, no question; listed in the table as "PROJECT.md drafted")
   ├─ GitHub-side gates (own step, after the files): AskUserQuestion header "GitHub gates",
   │    "Make GitHub itself refuse pushes to <base> and main?" [Yes (Recommended) / Not now].
   │    Yes → the ruleset command in "GitHub-side gates" below, once per branch, run by the
   │    owner's own session (the robot's token cannot change rulesets). Then print the
   │    token guidance from the same section as one dim line. Never applied without the yes.
   └─ Delete onboard-staged/; keep the answers file (re-runs use it).

FIT FOR PURPOSE — an app with `docs/shape/north-star.md` whose
      `bash $SB/super-board-scope.sh profile --config <saved config>` exits 1 has no
      `## Fit for purpose` block, and the scope judge won't judge without it (factory #148).
      Draft the ten lines (north-star SKILL.md → step 8) from the north star, spec.md and
      zones.yaml, show them, and ask the owner once (AskUserQuestion): sign as is, or fix a
      line. Write the block under `## North star` only after their yes. Never write it unsigned.
      A new app mid-Define gets it from /north-star instead.

DONE — run `python3 $SB/super-board-verification-ready.py --config <saved config>`;
      exit 9 reports setup incomplete (repair checks before run; do not reinstall/rebase).
      A new app mid-Define expects exit 9 here: no failure, just the one-line note that
      checks are set at /to-board.
      Then self-check, then the ONE place that names the next command:
      ⏺ Bash(self-check)  ⎿  all good
      ⏺ 🎉 Onboard complete.
        📋 Board: github.com/users/<owner>/projects/<n> (<title>)
        🧹 Next: /super-board lint — checks every ticket has clear success criteria.
        🤖 Then: /super-board run.
      A new app mid-Define (`docs/shape/north-star.md` exists, `docs/shape/coverage.md` does
      not) gets the next Define step instead of the two lines above:
        🧭 Next: /to-board --dry-run — spec and card table, nothing filed.
```

---

## Mid-run permission prompts

Lane agents inherit the session allowlist and run in acceptEdits. Two things keep a
wave from stalling on prompts: these lines in `.claude/settings.json` →
`permissions.allow`, and the permission decider hook (`.claude/hooks/permission-decider.py`,
wired by install.sh), which allows the shapes a rule cannot match. Add:

    "Bash(gh issue view:*)", "Bash(gh issue edit:*)", "Bash(gh issue comment:*)",
    "Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh pr checks:*)", "Bash(gh pr comment:*)",
    "Bash(gh pr create:*)", "Bash(gh pr ready:*)", "Bash(gh project item-edit:*)",
    "Bash(gh project item-list:*)", "Bash(gh api:*)", "Bash(git worktree:*)",
    "Bash(.claude/bin/super-board-card.sh:*)",
    "Bash(git checkout:*)", "Bash(git add:*)", "Bash(git commit:*)",
    "Bash(git push:*)", "Bash(git pull:*)", "Bash(git fetch:*)", "Bash(git blame:*)",
    "Bash(mkdir:*)", "Bash(pgrep:*)", "Bash(node --check:*)",
    "Bash(bash .claude/bin/super-board-wave-plan.sh:*)",
    "Bash(bash .claude/bin/super-board-preflight.sh:*)",
    "Bash(bash .claude/bin/super-board-fresh-worktree.sh:*)",
    "Bash(python3 .claude/bin/super-board-github-read.py:*)",
    "Bash(.claude/bin/super-board-github-read.py:*)",
    "Bash(python3 .claude/bin/super-board-verification-ready.py:*)",
    "Bash(python3 .claude/bin/super-board-skills-ready.py:*)",
    "Bash(bash .claude/bin/super-board-usage.sh:*)",
    "Bash(bash .claude/bin/super-board-throttle.sh:*)",
    "Bash(bash .claude/bin/super-board-scope.sh:*)",
    "Bash(python3 .claude/bin/super-board-scorecard.py:*)",
    "Bash(python3 .claude/bin/super-board-zone.py:*)",
    "Bash(python3 .claude/bin/super-board-coverage.py:*)",
    "Bash(python3 .claude/bin/super-board-config.py:*)",
    "Bash(.claude/bin/super-qa-file-bug.sh:*)", "Bash(.claude/bin/super-review-file-refactor.sh:*)",
    "Bash(bash .claude/bin/super-board-host.sh:*)",
    "Bash(bash .claude/bin/super-board-pr-body.sh:*)", "Bash(gh pr edit:*)",
    "Bash(bash .claude/bin/super-board-stop.sh:*)",
    "Bash(gh api graphql:*)", "Bash(gh label create:*)",
    "Bash(source .claude/bin/super-board-gh-guard.sh:*)",
    "Bash(bash .claude/bin/super-board-gh-guard.sh:*)",
    "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
    "Bash(git -C:*)", "Bash(python3 .claude/hooks/guard-secrets.py --scan:*)",
    "Bash(git rev-parse:*)", "Bash(git merge-base:*)", "Bash(git ls-files:*)",
    "Bash(git ls-remote:*)", "Bash(git config --get:*)", "Bash(git branch --show-current:*)",
    "Bash(gh pr list:*)", "Bash(gh issue list:*)", "Bash(gh project view:*)",
    "Bash(gh project field-list:*)", "Bash(gh auth status:*)",
    "Bash(ls:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)",
    "Bash(grep:*)", "Bash(jq:*)", "Bash(sleep:*)",
    plus your project's test runners, from `python3 .claude/bin/super-board-settings.py runner-rules .`
    (e.g. "Bash(npm test:*)", "Bash(npm run:*)", "Bash(npx playwright:*)", "Bash(npx vitest:*)").

The read-only lines are safe to pre-approve because the guard-secrets hook still denies any
of them that touches a secrets file. `git -C` is how lanes run git in their worktree
(`lanes/common.md`); `git push` is already allowed, and guard-protected-push still blocks pushes
to protected branches.

Not in the list on purpose, because a rule cannot limit them: `find` (`-delete`, `-exec`),
`sed` (`-i`, `w`), `node`, `python3 -c` and wildcards over `.claude/bin/` (they would also
run a worktree copy a builder edited). The decider allows their safe forms instead:
`sed -n` print-only scripts, `find` with no action, and a `.claude/bin` script however it is
spelled (`bash x`, `./x`, `x`, an absolute path) when it resolves to the main checkout's copy.
It denies the worktree copy, a lane's inline code (`python3 -c`, `python3 - <<EOF`, `node -e`,
with the allowed way in the reason), and every direct merge.

A rule matches one plain command only. A lane command behind `cd … &&`, in a
shell loop or chained with `;` misses every rule; the decider allows it only when every
segment is known-safe, else it goes to the permission checker, which denies GitHub writes
(`lanes/common.md` → "Command shape").

**Why allow-listed commands still prompted (#131).** Reproduced headless with funl's
allowlist: a rule matches the command text, so `.claude/bin/super-board-preflight.sh` (no
`bash`), `bash /abs/path/.claude/bin/…` and `python3 -c` miss `Bash(bash .claude/bin/…:*)`
and `Bash(python3 .claude/bin/:*)`; a regex `sed -n '/A/,/^## /p'` on a file reached
through the `.claude/skills` → `.agents/skills` symlink is checked as a possible write
through a symlink and prompts despite `Bash(sed -n:*)`. A PreToolUse hook's `allow` is
honoured inside subagents (the hook input carries `agent_id` and `permission_mode`).

**Sandbox** (`sandbox.enabled` with `autoAllowBashIfSandboxed`) would approve every command
inside an OS sandbox instead of judging each one. Worth a later trial on a throwaway app:
it limits writes to the project and network to an allowlist, but lanes need `gh`, the
package registry and the dev server, so the network list has to be right first.
`"Bash(gh api graphql:*)"` is the lanes' one route to resolve a review thread, and
`"Bash(gh api:*)"` covers editing their own comment (`lanes/common.md` → "Thread and
comment writes"). `"Bash(gh label create:*)"` lets the Reviewer create the
`deep-reviewed` label once.

`tests/test_run_allowlist.py` fails when pre-flight or a lane calls a `.claude/bin`
script this list does not cover, or a lane file puts a `gh` or board command
behind `cd … &&`. The read helper is listed in both forms: scripts call
`python3 .claude/bin/super-board-github-read.py`, lane prompts call it directly.

**Headless runs (`claude -p "/super-board run"`).** Supported only where Claude Code may
write the project's `.claude/` folder without a prompt. `.claude/` is a protected path:
the wave lock under `.claude/super-board/` (inflight lock, halt and PID files) is prompted
in `default` and `acceptEdits`, denied in `dontAsk`, and no `permissions.allow` rule
(e.g. `Edit(.claude/**)`) pre-approves it. Claude's own git worktrees under
`.claude/worktrees/` are exempt, so lane worktrees need only `Bash(git worktree:*)`.
Pick one:
- Interactive (recommended): start `/super-board run` in a terminal session and answer
  the first `.claude/` write prompt with "allow Claude to edit files in this project's
  .claude folder for this session".
- Headless: `claude -p "/super-board run" --permission-mode bypassPermissions`, only in
  an isolated container or VM. `--permission-mode acceptEdits` stops at the wave lock.

Merging is NOT in the base list. On a board whose `merge_policy.default` is
`"auto"`, `super-board onboard` offers the merge line as a diff to approve
up front (onboard → Permissions), so the first overnight run does not stall:

    "Bash(bash .claude/bin/super-board-merge-gate.sh:*)",
    plus one line per configured migrate command in `migrations.commands`
    for the envs in `migrations.allowed_envs` (none for a `"-"`).

`gh pr merge` is never allow-listed: the gate runs it inside its own script, which no
permission rule sees. A direct merge is denied three ways: the decider hook, the
`permissions.deny` lines install.sh merges from `hooks/settings-snippet.json`
(`gh pr merge *`, `gh api *pulls/*/merge*`, the two merge GraphQL mutations), and the
GitHub ruleset below.

Without them every Reviewer merge pauses for one interactive approval, so the
backend is **attended-only**. With them, the gate still enforces
`merge_policy` (money / auth / destructive schema / a red-tier PR over `auto_max_lines` → human, exit 7;
a non-red PR over it → deep review, exit 10, no human) and `migrations`
(live DB → 🙋 needs you, exit 8), so the allowlist removes the prompt, not
the policy. Pair auto-merge with a non-production `base_branch`.

> **Read this before starting an overnight wave (issue #9).** The two settings
> interact, and the failure is silent. A board configured
> `"human_approves_merge": false` and `merge_policy.default: "auto"`, processing
> otherwise ungated PRs **without** the merge gate allowed, will build,
> test and review cards all night and land **nothing** —
> each Reviewer stalls on an approval prompt nobody is there to click, and the
> card returns to Review to be re-reviewed on the next wave.
>
> Pick one deliberately:
>
> | Intent | Configuration | Allowlist the merge gate | Reviewer's terminal state |
> | --- | --- | --- | --- |
> | Attended — approve each merge command | `human_approves_merge: false`, `merge_policy.default: "auto"` | no | pauses on a tool permission prompt |
> | Unattended auto-merge | `human_approves_merge: false`, `merge_policy.default: "auto"` | **yes** | card → Done after confirmed merge; configured human gates → 🙋 Blocked |
> | Every PR requires human approval through the gate | `human_approves_merge: false`, `merge_policy.default: "human"` | needed only if the agent will merge after approval | gate exits 7 → 🙋 Blocked until a human merges or approves the pinned request |
> | Legacy human-only switch | `human_approves_merge: true` | no | Reviewer stops before the gate; card stays in Review |
>
> Gate-based rows also need the merge-gate command allowed. A tool permission prompt
> is separate from the gate's human-approval request; allowing a command does not
> bypass `merge_policy`.
>
> Row 2 is the only combination that lands code with nobody watching, and it
> requires a non-production `base_branch` — the production-merge
> guard refuses to start otherwise. Whichever row you pick, the Reviewer still
> owes the full merge protocol in `lanes/review.md` → "Merge protocol": mark the draft PR
> ready, merge, **verify the merge commit is an ancestor of the base branch**,
> and only then move the card to Done. A merge-blocked PR goes to Blocked, not
> back to Review.

## GitHub-side gates

The hooks stop a lane on this machine. GitHub stops everything else, including a lane that
found a way round a hook. Onboard asks once, after writing the files (step 8 → "GitHub gates"),
and the owner's own session runs it; the robot never changes a ruleset.

**Ruleset, once per branch** (`<base>`, and `main` when it is not the base):

    gh api -X POST repos/<owner>/<repo>/rulesets --input <file>

with `<file>` written by the Write tool:

    {"name": "super-board: <branch>", "target": "branch", "enforcement": "active",
     "conditions": {"ref_name": {"include": ["refs/heads/<branch>"], "exclude": []}},
     "rules": [{"type": "deletion"}, {"type": "non_fast_forward"},
               {"type": "pull_request", "parameters": {"required_approving_review_count": 0,
                "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false,
                "require_last_push_approval": false, "required_review_thread_resolution": false}}]}

No direct push, no force push, no delete, every change through a PR. Zero required
approvals: the gate merges the robot's own PR, and GitHub never lets an account approve
its own. No bypass list, so the owner merges through a PR too. A ruleset needs a public
repo or a paid plan for a private one; GitHub's error says so, and onboard prints that line
and moves on (the hooks still hold).

**Token** — the robot's `gh` should reach this one repo and its board, nothing else:
- A second account (references/second-account.md) sees only what it is invited to: invite it to
  this repo as a collaborator with Write, and to the board.
- On the owner's own account, a fine-grained personal access token: Repository access →
  Only select repositories → this repo. Permissions: Contents, Pull requests, Issues read and
  write; Metadata, Actions, Commit statuses read. **Administration: no access**, so the
  robot can't lift the ruleset. Projects: read and write for the board's owner where GitHub
  offers it; where it doesn't (some user-owned boards), a classic token with `repo` and
  `project` is the fallback, and the ruleset is what still holds. The owner installs it with
  `gh auth login --with-token` typed at their own prompt; an agent never types a token.

## AGENTS.md source of truth

Goal: one instruction file every agent reads (AGENTS.md); CLAUDE.md is the single line
`@AGENTS.md` plus any Claude-only rules below it. Use the import, not a symlink and not a
deletion: older Claude Code versions, `CLAUDE.local.md` and some settings only load CLAUDE.md,
and a committed symlink breaks on Windows.

**Deterministic — always via the script** (`.claude/bin/super-board-agents-md.py`):

| Need | Command |
|---|---|
| What exists, pointer or not | `detect` |
| Back up every instruction file first | `backup` → `.claude/super-board/backup/<ts>/` |
| Rule units to map | `units --file AGENTS.md --file CLAUDE.md [--file …]` |
| Lossless gate | `coverage --units mapped.json --target <staged AGENTS.md> --target <staged CLAUDE.md>` |
| Size + markers | `check --file <staged AGENTS.md>` (≤ 200 lines, one marker pair) |
| Write | `write --src <staged> --dest AGENTS.md` (atomic) |
| CLAUDE.md pointer | `pointer --tail <claude-only.md> --force` (only after backup + approval) |
| super-board section | `block` (`--create` when AGENTS.md is new) |

**Semantic — the agent, by these rules:**

1. **Split** every source (AGENTS.md, CLAUDE.md, `@imports` expanded, CLAUDE.local.md,
   .claude/CLAUDE.md) into rule units with `units`.
2. **Classify each unit**:
   - Duplicate (same directive in both) → keep ONE, the more specific wording.
   - Tool-agnostic CLAUDE-only rule → move into the matching AGENTS.md section.
   - Claude-specific (hooks, slash commands, subagents, model choice, Claude tool names) →
     stays in CLAUDE.md below `@AGENTS.md`.
   - Conflict (same subject, different directive — npm vs pnpm) → NEVER auto-resolve. One
     AskUserQuestion per conflict, quoting BOTH lines verbatim, with file:line.
   - Stale (names a path or script that no longer exists) → ask keep or drop.
3. **Every unit maps to a line.** Write `mapped.json` (the `units` output plus `maps_to`: the
   exact target line, or `dropped`: the user's reason) and run `coverage`. Exit 1 → fix before
   showing anything. A unit is gone only when the user dropped it on purpose.
4. **Format** — wording only, meaning unchanged:
   - Sections in order: overview (1 line) · Commands · Where things live · Conventions ·
     Boundaries (Always / Ask first / Never) · super-board block · Commits and PRs.
   - Structured tables wherever rules share a shape; caveman-terse cells (no articles, no
     filler, no "please").
   - Negations explicit and loud: `NEVER`, `DON'T`, `ALWAYS` in caps. NEVER soften a
     prohibition into a suggestion.
   - ≤ 200 lines. Overflow → `docs/agents/<topic>.md` with a one-line pointer in AGENTS.md
     (a pointer, not an `@import` — imports do not cut context cost).
5. **Show** the diff of AGENTS.md and CLAUDE.md folded under the coverage line; the step-8
   "Write everything" is the approval. Nothing is written before step 8.

**The super-board section** sits between `<!-- super-board:begin vX.Y.Z … -->` and
`<!-- super-board:end -->`, rendered from `references/agents-md-block.md`. Re-install and
re-onboard rewrite ONLY that block; text outside the markers is never touched.

---

## Error recovery during onboard

The user never sees a raw stack trace — they get a diagnosis and the exact next command. Every
halt says what was tried, what failed, the exact fix, and "re-run `/super-board onboard` — your
answers are kept and it resumes at <step>".

| Step | Failure | What the user sees |
|---|---|---|
| 1 | Pack files not found (plugin) | `🛑 Can't find the super-board plugin files. Run the one-line installer (get.sh) or ./install.sh <this-dir> from a checkout, then re-run onboard.` |
| 1 | A tool install declined (git, gh) | `Without <tool> the board can't <why>. Your answers are saved — run <command>, then re-run onboard.` |
| 1 | Node declined, or `npx skills add` fails | `⚠️ Required worker skills remain unavailable: <exact names>. Install for <host> and restart.` Setup stays red; dispatch halts before claims. |
| 1 | Workflow still fails `node --check` after the re-copy | `🛑 .claude/workflows/super-board-wave.js is corrupt. Re-run ./install.sh <this-dir> — don't hand-edit it.` |
| 1 | settings.json invalid JSON | `✋ .claude/settings.json is not valid JSON; I left it untouched. Fix it, then re-run — only the settings entries repeat.` |
| 2 | Scope refused in the browser | `🔑 GitHub asked for project,read:project,repo and you said no. Without them I can't read or move cards. Re-run: gh auth refresh -s project,read:project,repo.` |
| 2 | Repo create refused | `📦 GitHub refused to create the repo (org admin required, or the free-repo quota). Pick an existing repo, or create one in the web UI, then re-run.` |
| 3 | Org project denied | `🔑 You can't create projects under <org>. Ask an org admin, or use your account: gh project create --owner @me.` |
| 3 | Board read-only | `🔑 That board is read-only for your account. Get write access, or pick another.` |
| 3 | board-migrate exits 2 | Show its `error` and recovery-file path. Some changes may already be applied. Keep the board stopped and the recovery file; fix the access/read/write failure, then re-run the same command from the same project root. A concurrent-edit conflict needs review of the saved original/desired state; never delete the record to bypass it. |
| 4 | `git push origin main:staging` rejected | `🌿 Couldn't create staging (<reason>). Create it on GitHub, or pick main.` |
| 5 | `coverage` exits 1 | Not an error: fix the mapping, re-run `coverage`, then show the result. |
| 5 | Two managed blocks / dangling marker | `✋ AGENTS.md has <n> super-board markers. Leave one begin/end pair (or none) and re-run.` |
| 7 | A ping fails | One ❌ line with the reason and what to add; the source is left out; onboard continues. |
| 8 | File not writable | `🛑 Can't write <path> — check permissions.` Answers kept; re-run resumes at Review. |

---

### Upgrade recovery limits

The recovery file is durable before any GitHub write, records verified progress, and is retained
on failure. Full cursor pagination covers boards beyond 500 cards; missing/partial pages block
writes. A lost mutation response is checked against GitHub before an operation can repeat.
Completed records retain the latest snapshot until a later, fully snapshotted migration replaces
them. The local OS lock releases automatically on a crash; run upgrades from one project root.

New nonempty task statuses and edits after a verified restore are preserved. Changed options,
labels, or conflicting unfinished restores halt for review. Deleted cards are never recreated.
GitHub cannot atomically compare a read with a field rewrite: edits made in that narrow interval,
or an intentional clear before the first post-rewrite observation, cannot always be distinguished
from the rewrite clearing a status. **Keep workers and people from editing this board during its
upgrade.** This is resumable recovery, not a promise of an atomic rollback. Do not hand-edit or
remove a pending recovery record; use its saved state to reconcile a conflict before retrying.

## Worker self-check (mandatory before the 🎉 screen)

1. **Config validates** — `.claude/super-board/configs/<slug>.json` parses, has every required
   field from `config-schema.json` (incl. `notifications.bot_identity`, `notifications.owner_name`, `merge_policy`,
   `migrations`), has no `variant`, and `columns` is the seven.
2. **Active pointer** — `.claude/super-board/active` holds exactly the slug + `\n`.
3. **Board columns and labels** — `gh project field-list <n> --owner <o>` returns Backlog, Ready,
   Building, QA, Review, Blocked, Done (no Skipped); `gh label list` has qa, bug, feature.
4. **Setup green** — `python3 .claude/bin/super-board-setup.py check` exits 0 (or only `needs`
   the user declined, or only the `verify_commands` line on a new app mid-Define).
5. **Workflow runtime** — the step-1 `node --check` passes.

When step 5 wrote files: `super-board-agents-md.py check --file AGENTS.md` passes and `detect`
reports CLAUDE.md as a pointer (unless "Only add the super-board section"). Any check fails →
no 🎉: name the failed check and say "re-run `/super-board onboard` — it resumes there".

## Project-owned verification checks

Use [project-checks.md](project-checks.md) to connect existing lint, layout, import
and test commands through `verify_commands`. Examples are app-owned; onboarding
does not impose an architecture or install a universal linter.
