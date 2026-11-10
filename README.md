<div align="center">

<img src="docs/assets/logo.svg" width="88" height="88" alt="super-board kanban logo">

<h1>super-board</h1>

<p><strong>Add tasks, walk away, get merged PRs with proof.</strong></p>

<p>Stop babysitting coding agents: cards you drop in Ready come back as tested, reviewed PRs.</p>

<p>8 skills (4 you type, 4 the board runs) · 9 commands · 6 guard hooks</p>

<p>
<img alt="Version" src="https://img.shields.io/badge/version-3.3.0-1f883d?style=flat-square">
<img alt="Host" src="https://img.shields.io/badge/Claude%20Code-skills-d97757?style=flat-square">
<img alt="License" src="https://img.shields.io/badge/license-MIT-0969da?style=flat-square">
</p>

<p><a href="https://erictechpro.github.io/super-board/"><strong>🌐 Live site: erictechpro.github.io/super-board</strong></a></p>

<p>⭐ Star this repo if it helps · <a href="https://www.skool.com/erictech">Join the builders using this → weekly live calls, setup help</a> · <a href="https://youtu.be/aggJvNZxfKA">▶ Watch the walkthrough</a></p>

<p><a href="#install">Install</a> · <a href="#quick-start">Quick start</a> · <a href="#how-it-works">How it works</a> · <a href="#skills">Skills</a> · <a href="#commands">Commands</a> · <a href="#guards--hooks">Guards</a></p>

</div>

<p align="center"><a href="https://erictechpro.github.io/super-board/skill-map/"><img src="docs/assets/skill-map.png" alt="The super-board skill map: open the interactive version" width="100%"></a></p>
<p align="center"><sub>The skill map. Click it for the live version: zoom, pan, open any node.</sub></p>

## Install

Before you start:

- [ ] Claude Code, and `gh` with board access: `gh auth refresh -s project,read:project,repo`
- [ ] Dynamic workflows on in `/config` ([backends](docs/super-board/README.md#backends))
- [ ] `verify_commands` set in your config, so the merge gate can prove the build ([setup notes](docs/super-board/README.md#setup-notes))

In your project folder:

```bash
curl -fsSL https://raw.githubusercontent.com/ozbg/funl-factory/main/get.sh | bash
```

Or as a Claude Code plugin:

```
/plugin marketplace add ozbg/funl-factory
/plugin install super-board@super-board
```

> [!NOTE]
> The plugin ships the skills only. Run `/super-board:super-board onboard` and its 🔍 Checks step adds the guard hooks, scripts and workflows. Needs Claude Code, `gh`, `jq`, bash 3.2+ and Python 3.9+; the installer checks.

### What lands in your app

Exactly 26 skills: the 8 pack skills and the 18 helpers in the tables under [Skills](#skills),
all listed in [`skills/families.json`](skills/families.json). Re-running the installer prunes
retired skills (Cloudflare's `security-audit`, `implement`, `grill-me`, `visual`, the setup
skills and the rest in the manifest's `retired` list), but only super-board's own copies and
skills your `skills-lock.json` says came from `mattpocock/skills` or Cloudflare. Each is backed
up first to `.claude/super-board/backup/<timestamp>/`. Skills you added from anywhere else stay.
`--no-helper-skills` skips the helper download; `/super-board onboard` adds them later.

[`pr-security-review`](skills/pr-security-review/README.md) runs inside the QA lane on red cards,
and on amber cards on a boundary path; each finding fails QA and goes back to Build. It is from Anthropic's
[claude-code-security-review](https://github.com/anthropics/claude-code-security-review).
Claude Code's built-in `/security-review` is left as it is.

Running from Codex or OpenCode? See [supported hosts](docs/hosts.md) for tested versions, sign-in and gaps.

Optional post-run learning can delegate an already installed `calibrate` skill after
verified selected work completes. It applies only to explicitly permitted existing
canonical skill files; the package bundles no private skill. See
[post-run calibration](skills/super-board/references/calibration.md).

## Quick start

### 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/ozbg/funl-factory/main/get.sh | bash
```

### 2. Onboard

```
/super-board onboard
```

Checks · GitHub · Board · Branch · AGENTS.md · Policies · Bug sources · Review. <kbd>Enter</kbd> takes the recommended answer.

### 3. Run

```
/super-board run my-app
```

Add cards to `Ready`. The board drains on its own.

## How it works

**Which path?** Clear idea, foggy idea or bugs: [the routing rule](docs/super-board/routing.md) says what to run, and when 1–5 tickets go to `/implement-spec` instead of the board.

<p align="center"><a href="https://youtu.be/aggJvNZxfKA"><img src="https://i.ytimg.com/vi/aggJvNZxfKA/maxresdefault.jpg" alt="Watch I Built a Self-Improving Software Factory by Eric Tech on YouTube" width="100%"></a></p>
<p align="center"><a href="https://youtu.be/aggJvNZxfKA"><strong>▶ Watch on YouTube: I Built a Self-Improving Software Factory</strong></a></p>

## Skills

**8 skills (4 you type, 4 the board runs).** Uses [Matt Pocock skills](https://github.com/mattpocock/skills), ponytail, impeccable, humanizer, [Anthropic's security review](https://github.com/anthropics/claude-code-security-review).

<!-- skills:start -->
**You type — 4 skills**

| Skill | What it does |
|---|---|
| [`/super-board`](skills/super-board/README.md) | Orchestrator: plans waves, runs Build → QA → Review, merges when green. |
| [`/super-collect`](skills/super-collect/README.md) | Finds problems, verifies them, writes a findings doc for /to-spec and /to-tickets. |
| [`/git-sync`](skills/git-sync/README.md) | Commit per logical change, merge-pull, push without force, report. |
| [`/north-star`](skills/north-star/SKILL.md) | One short interview that fixes an app's why, must-haves and destination. |

**The board runs — 4 skills**

| Skill | What it does |
|---|---|
| [`/super-build`](skills/super-build/README.md) | Builder lane: worktree, smallest safe change, tests, draft PR. |
| [`/super-qa`](skills/super-qa/README.md) | Tester lane: evidence, test-gap check, screenshots, or bounce to Build. |
| [`/super-review`](skills/super-review/README.md) | Reviewer lane: own hypotheses, remembers prior findings, merge gate. |
| [`/pr-security-review`](skills/pr-security-review/README.md) | Security pass on red and boundary amber cards; super-qa runs it, findings fail QA. |

**Kept here, not installed into apps — 3 skills**

| Skill | What it does |
|---|---|
| [`/mockup`](skills/mockup/SKILL.md) | One-hour clickable mock-up of the core loop; installing it is #60. |
| [`/ui-refine-loop`](skills/ui-refine-loop/README.md) | Critique → refine loop that polishes one page or component. |
| [`/visual`](skills/visual/README.md) | One HTML page: branch recap, plan, or codebase map with diagrams. |
| [`/to-board`](skills/to-board/SKILL.md) | North star to one-page spec and Haiku-ready cards in Backlog. |

**Helpers installed beside the pack — 18 skills**

| Skill | What it does |
|---|---|
| `/tdd` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Build lane: every change goes red, green, refactor. |
| `/diagnosing-bugs` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Build lane on bug cards: reproduce and pin the cause first. |
| `/code-review` ([mattpocock/skills](https://github.com/mattpocock/skills)) | QA and Review lanes: standards and spec review of a diff. |
| `/codebase-design` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Review lane and refactors: deep-module design vocabulary. |
| `/domain-modeling` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Build lane when a card touches domain terms, glossary or ADRs. |
| `/verification-before-completion` ([obra/superpowers](https://github.com/obra/superpowers)) | Every lane: run the checks before claiming done. |
| `/prototype` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Throwaway prototype that settles a design question before a ticket. |
| `/to-spec` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Turns a findings doc or idea into a spec; super-collect hands off here. |
| `/to-tickets` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Splits a spec into board tickets with acceptance criteria. |
| `/grilling` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Stress-tests a plan with hard questions before it becomes tickets. |
| `/research` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Primary-source research written up as a Markdown file in the repo. |
| `/triage` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Sorts incoming issues into actionable, duplicate or won't-fix. |
| `/improve-codebase-architecture` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Finds refactor candidates; feeds /super-collect architecture. |
| `/handoff` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Writes a handoff note so the next session picks up cleanly. |
| `/claude-handoff` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Hands the current task to a fresh Claude session. |
| `/to-questionnaire` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Turns open questions into a questionnaire the owner answers. |
| `/wizard` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Interactive bash wizard for steps only the owner can do. |
| `/retro` ([mattpocock/skills](https://github.com/mattpocock/skills)) | Run retro: what worked, what broke, what to change next. |
<!-- skills:end -->

Each name links to that skill's README. Adding a skill? Write its `SKILL.md` and `README.md`, add a line to `skills/families.json`, and this table updates itself.

## Commands

```
/super-board onboard          # 8-step setup, resumes
/super-board lint             # vague ACs?
/super-board status           # read-only snapshot
/super-board run <slug>       # drain the board
/super-board stop             # stop workers
/super-collect [source]       # find problems → findings doc → /to-spec
/ui-refine-loop <route>       # polish one page
/visual [recap|plan|path]     # one HTML page
/git-sync                     # commit, pull, push
```

Flags: `run --low|--high` · `super-collect --since 30d`

## Guards & hooks

Run automatically once installed. Python stdlib, JSON in, JSON out.

| | |
| --- | --- |
| [guard-worktree-path](hooks/guard-worktree-path.py) | Blocks `git worktree add` outside `.claude/worktrees/` |
| [guard-secrets](hooks/guard-secrets.py) | Blocks reading or piping dotenv files, SSH keys and credential files; key names via `super-board-env-check.sh` |
| [guard-key-literals](hooks/guard-key-literals.py) | Blocks a live-looking API key written into a file; flags one already there |
| [guard-delete-outside](hooks/guard-delete-outside.py) | Blocks `rm`, `find -delete` and `git clean` aimed outside the project, `~` or `/` |
| [guard-protected-push](hooks/guard-protected-push.py) | Opt-in (`onboard` asks, or `install.sh --protect-main`): blocks direct and force pushes to main/master/base |
| [README sync](scripts/super-board-readme-sync.py) | Regenerates the skill table; pre-commit and PostToolUse hooks keep it fresh |
| [cleanup-wt](hooks/cleanup-wt.py) | Removes merged worktrees and branches after each merge and at session start, with a recovery file |
| [merge gate](scripts/super-board-merge-gate.sh) | Merges only after the current base plus your non-empty project `verify_commands` pass (missing checks halt setup), pinned to the reviewed commit; applies `merge_policy` and runs allowed DB migrations |

## Models

A cheap router grades each card easy, medium or hard first; the run flag picks the model for each grade.

| Command | Router | Easy card | Medium card | Hard card |
| --- | --- | --- | --- | --- |
| `/super-board run` | Haiku 4.5 | Sonnet 5.5 | Opus 5.5 | session model |
| `/super-board run --low` | Haiku 4.5 | Haiku 4.5 | Sonnet 5.5 | Opus 5.5 |
| `/super-board run --high` | Sonnet 5.5 | Opus 5.5 | Opus 5.5 | Opus 5.5 |

## Writing standard

Commits, tickets, PR bodies and comments all follow [one writing standard](https://erictechpro.github.io/super-board/writing-standard/), in the pack and in every project it is installed into.

<details>
<summary><strong>Upgrading from 2.x</strong></summary>

1. Re-run the install line.
2. Run `/super-board onboard`; step 1 upgrades for you and keeps a backup.
3. Try `board-migrate --dry-run` on a copy of your board first.

[Full notes](RELEASE-NOTES.md#upgrading-from-2x)

</details>

## Credits

`funl-factory` is the owner's copy of the pack; `super-board` stays the engine and skill name. It is the `ozbg/funl-factory` fork of Eric Tech's original [EricTechPro/super-board](https://github.com/EricTechPro/super-board), forked at v3.3.0 and kept under the same MIT license; all credit for the pack goes to Eric. MIT © Eric Tech ([LICENSE](LICENSE)). Built on [obra/superpowers](https://github.com/obra/superpowers), [mattpocock/skills](https://github.com/mattpocock/skills), [BuilderIO/skills](https://github.com/BuilderIO/skills) and [tt-a1i/archify](https://github.com/tt-a1i/archify). `pr-security-review` is ported from [anthropics/claude-code-security-review](https://github.com/anthropics/claude-code-security-review) (MIT © 2025 Anthropic, [notice](skills/pr-security-review/LICENSE)).

---

<p align="center">
<a href="https://erictechpro.github.io/super-board/">Live site</a> ·
<a href="https://erictechpro.github.io/super-board/skill-map/">Skill map</a> ·
<a href="https://erictechpro.github.io/super-board/writing-standard/">Writing standard</a> ·
<a href="https://erictechpro.github.io/super-board/onboarding/">Setup simulator</a> ·
<a href="https://erictechpro.github.io/super-board/impeccable/">Impeccable map</a> ·
<a href="https://erictechpro.github.io/super-board/pstack/">pstack map</a> ·
<a href="https://erictechpro.github.io/super-board/security-audit/">Security audit map</a> ·
<a href="RELEASE-NOTES.md">Release notes</a> ·
<a href="RELEASING.md">Release checks</a> ·
<a href="https://youtu.be/nX_bGyIOFM4">YouTube walkthrough</a>
</p>
<p align="center"><sub>Made by Eric Tech</sub></p>

### Worker skill availability

Setup and dispatch resolve real, nonempty `SKILL.md` files for the actual
Claude or Codex host. Missing required skills halt before claims or workers;
lockfiles and arbitrary plugin caches do not count. The shared registry in
`scripts/super-board-skills-ready.py` owns lane dependencies, overrides and the
two declared ponytail fallbacks. The QA lane requires the bundled
`pr-security-review`. Every required skill is a pack or helper skill in
`skills/families.json`, or has a fallback. Setup's full helper union may be red while a
selected card is runnable. Read-only checks never install; explicit onboard
repair rechecks files after installation.

The CLI accepts `--home <fixture-home>` and `--catalog <active-skills.json>`.
Launchers accept the same inventory through `SUPER_BOARD_SKILLS_HOME` and
`SUPER_BOARD_SKILLS_CATALOG`; neither changes the actual host. Catalog shape:
`{"host":"codex","skills":[{"name":"vendor:skill","path":"/exact/SKILL.md",
"enabled":true,"scope":"project","project_root":"/exact/project"}]}`.
User entries use `scope:"user"`. Restart explicitly after repairing missing
skills; readiness certifies availability, not their content or external tools.
