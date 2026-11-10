export const meta = {
  name: 'super-board-wave',
  description: 'Drain one super-board wave: classify, then build → qa → review per card (lifecycles per lanes/*.md)',
  whenToUse: 'Launched by the super-board run-workflow backend with args from super-board-wave-plan.sh. Not for direct ad-hoc use.',
  phases: [
    { title: 'Pre-flight', detail: 'per Ready card: already done? in progress? file overlap? unclear? (lanes/build.md → Builder pre-flight)' },
    { title: 'Classify', detail: 'haiku router: kind (feature | bug | qa) + complexity per Ready card; skipped when the ticket has a Zone: line' },
    { title: 'Build', detail: 'Builder lifecycle (lanes/build.md): worktree, branch, draft PR' },
    { title: 'QA', detail: 'Tester lifecycle (lanes/qa.md): zone checks, cited fails, evidence; green cards skip it' },
    { title: 'Review', detail: 'Reviewer lifecycle (lanes/review.md): gates, rerun tests, merge' },
    { title: 'Enforce', detail: 'uncited bounce → pass with a note; bounce past the zone round cap → Blocked' },
  ],
}

// args = {
//   configPath: '.claude/super-board/configs/<slug>.json',
//   cards: [{ number, status, title, lane, labels, body }],  // super-board-wave-plan.sh, hydrated
//     lane: 'build' | 'qa' | 'review' — a Ready card labelled `qa` has lane 'qa'
//     and skips the Builder; every other Ready card is built first (v3.0.0).
//     body (optional): a `Zone:` line in it skips the classify agent.
//   tier: 'low' | 'medium' | 'high' (optional, default 'medium'),  // run model ladder
//   laneModels: config `lane_models` (optional) — per-lane model, over the tier:
//     { classify, preflight, build, qa, review }, each a model name, 'session'
//     (inherit the session model), or { low, medium, high } by card complexity.
//   laneModelsByTier: config `lane_models_by_tier` (optional) — per zone tier,
//     over laneModels: { green, amber, red }, each { build, qa, review } → a model
//     name or 'session'. Absent = today's choices. E.g. { red: { build: 'session' } }.
// }
// The harness can deliver `args` as a JSON-encoded string (the tool param is
// untyped) — normalize before validating.
const input = (() => {
  if (typeof args !== 'string') return args
  try { return JSON.parse(args) } catch { return args }
})()
if (!input || !Array.isArray(input.cards) || !input.configPath) {
  throw new Error('super-board-wave needs args {configPath, cards:[{number,status,title,lane}]}')
}
// `variant` was removed in v3.0.0; the planner refuses a "qa-only" config, so a
// wave launched with one is a stale caller. Refuse rather than guess.
if (input.variant && input.variant !== 'full') {
  throw new Error(`super-board-wave: variant "${input.variant}" was removed in v3.0.0 — labels route cards; run /super-board onboard to upgrade`)
}
// Lane for a card entering at Ready: the planner's `lane`, else its labels.
const labelsOf = (card) => (card.labels || []).map((l) => String(l).toLowerCase())
const readyLane = (card) => card.lane || (labelsOf(card).includes('qa') ? 'qa' : 'build')
if (input.tier && !['low', 'medium', 'high'].includes(input.tier)) {
  throw new Error(`super-board-wave: unknown tier "${input.tier}" — use low | medium | high`)
}

// Per-lane models (config `lane_models`, factory #25). Validated up front so a
// typo fails the wave before any agent runs, never mid-card.
const LANE_KEYS = ['classify', 'preflight', 'build', 'qa', 'review']
const LEVELS = ['low', 'medium', 'high']
const laneModels = input.laneModels || {}
if (typeof laneModels !== 'object' || Array.isArray(laneModels)) {
  throw new Error('super-board-wave: laneModels must be an object keyed by lane')
}
for (const [k, v] of Object.entries(laneModels)) {
  if (!LANE_KEYS.includes(k)) throw new Error(`super-board-wave: unknown lane "${k}" in laneModels — use ${LANE_KEYS.join(' | ')}`)
  const ok = (m) => typeof m === 'string' && m.length > 0
  const okMap = v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length > 0 &&
    Object.keys(v).every((l) => LEVELS.includes(l)) && Object.values(v).every(ok)
  if (!ok(v) && !okMap) throw new Error(`super-board-wave: laneModels.${k} must be a model name, "session", or {low,medium,high}`)
}
// The model for a lane: its lane_models setting when there is one, else the
// tier's choice (`fallback`). 'session' → undefined, so agent() inherits the
// session model. A complexity map with no class (a card that entered past
// Ready, never classified) uses its medium cell.
const TIERS = ['green', 'amber', 'red']
const byTier = input.laneModelsByTier || {}
if (typeof byTier !== 'object' || Array.isArray(byTier)) {
  throw new Error('super-board-wave: laneModelsByTier must be an object keyed by tier')
}
for (const [t, lanes] of Object.entries(byTier)) {
  if (!TIERS.includes(t)) throw new Error(`super-board-wave: unknown tier "${t}" in laneModelsByTier — use ${TIERS.join(' | ')}`)
  if (!lanes || typeof lanes !== 'object' || Array.isArray(lanes)) throw new Error(`super-board-wave: laneModelsByTier.${t} must be an object keyed by lane`)
  for (const [k, m] of Object.entries(lanes)) {
    if (!['build', 'qa', 'review'].includes(k)) throw new Error(`super-board-wave: unknown lane "${k}" in laneModelsByTier.${t} — use build | qa | review`)
    if (typeof m !== 'string' || !m) throw new Error(`super-board-wave: laneModelsByTier.${t}.${k} must be a model name or "session"`)
  }
}
const pick = (lane, cls, fallback, tier) => {
  const t = tier && byTier[tier] && byTier[tier][lane]
  if (t) return t === 'session' ? undefined : t
  const v = laneModels[lane]
  if (v === undefined) return fallback
  const m = typeof v === 'string' ? v : v[(cls && cls.complexity) || 'medium']
  if (m === undefined) return fallback
  return m === 'session' ? undefined : m
}

let halted = false
// Valid form per --kind, from validate() in scripts/super-board-github-read.py (#32).
const READ_SHAPES = [
  `Every GitHub command, ready to copy: .claude/skills/super-board/references/github-cheatsheet.md. Never run the helper's --resume.`,
  `Read shapes (helper: .claude/bin/super-board-github-read.py --kind <kind> -- <gh args>):`,
  `- issue title+body: --kind issue -- issue view <N> --json number,title,body`,
  `- issue comments: --kind comments -- api repos/{owner}/{repo}/issues/<N>/comments --paginate --slurp (zero comments = [[]])`,
  `- other JSON, incl. maybe-empty lists: --kind json -- <gh args> (no --jq that prints a plain string)`,
  `- PR branch+head: --kind head -- pr view <N> --json headRefName,headRefOid --jq '"\\(.headRefName) \\(.headRefOid)"'`,
  `- PR body+head: --kind body -- pr view <N> --json body,headRefOid`,
  `- PR metadata: --kind metadata -- pr view <N> --json files,labels,body,additions,deletions,changedFiles`,
  `- issue state: --kind state -- issue view <N> --json state --jq .state`,
  `- quota: use the guard's sb_gh_guard_check; never pass --jq to --kind quota`,
  `A read whose output misses its shape (incl. any you reshaped with --jq/-q/--template) exits 64 for that call only and prints the valid form: fix the read, do not halt.`,
].join('\n')
const READ_FAILURE = READ_SHAPES + '\n' + `Verification-readiness exit 9 means missing/unusable config.verify_commands: preserve card/worktree/approval/claims, report status=halted (preflight verdict=halted), stop dispatch, repair project configuration before explicit restart; no Build bounce or automatic retries. ` + `Required GitHub reads use .claude/bin/super-board-github-read.py: three total attempts, exit 79 means run halted. Check --check before any GitHub write, migration, or merge. On exit 79 preserve worktree/card/approval/claims, make no more GitHub calls, and report status=halted (preflight verdict=halted). Never retry a mutation. Config: ${input.configPath}.`

const CLASSIFY_SCHEMA = {
  type: 'object',
  properties: {
    kind: { type: 'string', enum: ['feature', 'bug', 'qa'] },
    status: { type: 'string', enum: ['ok', 'halted'] },
    complexity: { type: 'string', enum: ['low', 'medium', 'high'] },
  },
  required: ['kind', 'complexity'],
}

const STAGE_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['advanced', 'bounced', 'blocked', 'human-gate', 'failed', 'halted'] },
    column: { type: 'string' },
    detail: { type: 'string' },
    prUrl: { type: 'string' },
    branch: { type: 'string' },
    // QA and Review: what a bounce cites — AC<n>, I<n>, `bar: <line>` or
    // `bug: <repro or test command>`. A pass returns "none". A bounce without a
    // valid citation is rejected by this script (see enforce below).
    citation: { type: 'string' },
    // Every lane that ran the zone script: its tier and max_rounds.
    tier: { type: 'string', enum: ['green', 'amber', 'red'] },
    maxRounds: { type: 'integer' },
    // Review lane only, on a re-review: how round 1 graded the prior report.
    priorFindings: {
      type: 'object',
      properties: {
        fixed: { type: 'integer' },
        notFixed: { type: 'integer' },
        noLongerApplies: { type: 'integer' },
      },
    },
    // Review lane only: the scorecard (factory #25). Optional, so a missing
    // score never fails the lane.
    score: {
      type: 'object',
      properties: {
        verdict: { type: 'string', enum: ['clean', 'fixes', 'rework'] },
        acsProven: { type: 'integer' },
        acsTotal: { type: 'integer' },
        blockers: { type: 'integer' },
        round: { type: 'integer' },
        cause: { type: 'string', enum: ['build', 'ticket', 'none'] },
      },
    },
  },
  required: ['status', 'column', 'detail'],
}

const LANE = {
  build:  { skill: 'super-build',  section: 'Builder',  phase: 'Build' },
  qa:     { skill: 'super-qa',     section: 'Tester',   phase: 'QA' },
  review: { skill: 'super-review', section: 'Reviewer', phase: 'Review' },
}

// The merge-race guard used to live here, as a promise chain around the whole
// Review lane. It is gone on purpose (2026-08-20).
//
// It guarded the right thing in the wrong place. Squash-merges into one base
// branch do race — but serialising the entire lane also serialised reading the
// diff, rerunning the suite and the truth-check, none of which touch the base.
// On a wide wave that made Review the throughput ceiling for work that could
// have run in parallel. It was also invisible to the `claude-p` backend and to a
// second orchestrator on another machine, because a JS promise cannot be seen
// from another process.
//
// The mutex now sits at the merge step itself, in super-board-merge-gate.sh, as
// an atomic mkdir lock the Reviewer takes for the seconds it needs — and the
// freshness check runs INSIDE that lock, so nothing can move the base between
// the proof and the merge. See lanes/review.md → Merge protocol step 5.

// Review remembers: a card back in Review after a bounce is graded against the
// last Reviewer report first (lanes/review.md → Reviewer step 3b). The lookup is one gh
// call by marker, so the lane does it — this script never sees PR comments.
const REVIEW_MEMORY = [
  `Before reviewing, load prior_report: the newest PR comment containing "<!-- super-review:report -->" (lanes/review.md → Reviewer step 3b).`,
  `None → first review, behave as usual. Found → round 1 marks each prior finding fixed / not fixed / no longer applies;`,
  `any cited Blocker not fixed → bounce again listing them; an unfixed Note never bounces. Edit that report comment in place (keep R-ids), never post a second one. Report the counts as priorFindings.`,
  // Independent pass (lanes/review.md → Reviewer step 3): hypotheses before the builder's account.
  `Read the issue ACs and the diff before the builder's PR summary; form your own hypotheses, then check their claims.`,
  `Class every finding Gap / Bug / Verification miss / Scope drift / Over-engineering, and list what you verified correct.`,
  // v2 severity (lanes/review.md step 4): two levels, and only a cited Blocker bounces.
  `Severity is Blocker or Note. A Blocker cites AC<n>, I<n>, bar: <line> or bug: <repro>; no citation → Note. Re-bounce only cited Blockers.`,
  // Simplest-solution pass (super-review step 3): a Note, never a bounce.
  `Run ponytail:ponytail-review on the merge-base diff (inline ladder if the plugin is absent); over-engineering is always a Note.`,
  // Truth-check brief is fixed (super-review → Adversarial mode); a hand-written one once made over-building blocking.
  `Truth-check sub-agents get the fixed brief from super-review → "Adversarial mode", verbatim. After collecting, any uncited or over-engineering finding is a Note; it never decides merge or bounce.`,
  // Merge policy + migrations live in the gate (lanes/review.md → Merge protocol step 5).
  `Merge only via super-board-merge-gate.sh. Exit 7 = merge_policy says a human merges (money/auth/schema, or a big red PR): Blocked with the 🙋 template quoting its human-gate lines; To unblock = merge it yourself, or comment done to approve. Exit 10 = deep review needed: run it (lanes/review.md), add deep-reviewed, re-run the gate. Exit 13 = acceptance checklist not met (unticked AC, or proof not a file at the head): bounce to Build citing each AC the gate printed; never Blocked. Exit 11 (draft) or 12 (bad read) = leave the card in Review and retry next wave; never Blocked, never a halt.`,
  `Exit 8 = 🙋 needs you (migration for a DB the robot may not touch, failed migrate, declared human step): Blocked with the 🙋 template, exact commands from its needs-you lines, label needs-you.`,
  // Scorecard (factory #25): a by-product of the review above, never extra work.
  `Also return score, from what you already checked: verdict (clean = merge as is · fixes = notes only · rework = any blocker),`,
  `acsProven/acsTotal (ACs a test or probe proved / ACs on the issue), blockers (count), round (1 = first review of this PR, +1 per prior report),`,
  `cause (none when clean; else build = the code missed a clear AC · ticket = the AC was missing, vague or wrong).`,
]

// GitHub budget (rate-limit-etiquette.md → "Price list"). Measured 2026-10-04: a
// 3-card wave spent ~2,850 of 5,000 GraphQL points/hr, nearly all of it lanes
// finding a card with `gh project item-list` (~203 points on a 131-card board)
// and its Status options with `gh project field-list` (101) before each move.
const BOARD_IO = () =>
  `Board moves and reads: .claude/bin/super-board-card.sh --config ${input.configPath} move <issue> <Status> ` +
  `(1 GraphQL point) · status <issue> · items. Comments, labels, PR reads: REST per .claude/skills/super-board/references/rate-limit-etiquette.md → "Price list". Read GitHub once per decision, never in a sleep loop.`

// The orchestrator resolves every remaining chain before claims. The runtime has
// no subprocess API; each worker repeats the deterministic CLI before its writes.
const SKILLS_CHECK = (cards, lane) => [
  `First operation, before worktree creation, classification, comments, labels or moves: run python3 .claude/bin/super-board-skills-ready.py --root "$PWD" --host claude --cards - --hydrate${lane ? ' --lane ' + lane : ''},`,
  `with this JSON array as stdin (data, never interpolate a body into shell code): ${JSON.stringify(cards)}.`,
  `Exit 10 means status=halted (preflight verdict=halted), detail beginning "skills-readiness:"; preserve all existing claims/worktrees/approval evidence. Exit 64 means invalid input: halt and repair it. Exit 79 uses the read halt policy.`,
  `Load the exact resolved_path files. Only declared fallback IDs are allowed. Before using a conditional/custom helper repeat this CLI with --require <exact-name>.`,
].join('\n')

// skills-ready derives a card's entry lane from its status and refuses a `lane`
// that disagrees (exit 64). A card the wave moved on (built → QA, green → Review)
// keeps the planner's stale `lane`, so recompute it from where the card is now.
const entryLane = (card) => card.status === 'Review' ? 'review'
  : card.status === 'QA' ? 'qa'
  : labelsOf(card).includes('qa') ? 'qa' : 'build'
const atEntry = (card) => ({ ...card, lane: entryLane(card) })

// A valid bounce citation (lanes/qa.md step 8, lanes/review.md step 4).
const CITATION = /^(AC\d+|I\d+|bar: .+|bug: .+)$/

const BOUNCE_RULES = [
  `A bounce MUST return citation: AC<n> | I<n> | bar: <line> | bug: <repro steps or test command> (a red test rerun is bug: <command>).`,
  `No citation → it is a Note, not a bounce: pass the card with the note. This workflow rejects an uncited bounce and moves the card on.`,
  `A pass returns citation "none". Return tier and maxRounds from super-board-zone.py when you ran it.`,
]

const lanePrompt = (lane, card, { greenEntry = false } = {}) => [
  SKILLS_CHECK([atEntry(card)], lane),
  READ_FAILURE,
  `Run ${LANE[lane].skill} on issue #${card.number} ("${card.title}") for a super-board workflow wave.`,
  `Read .claude/skills/super-board/references/lanes/${lane}.md → "${LANE[lane].section}" lifecycle and follow it EXACTLY:`,
  `create your own worktree under .claude/worktrees/, work on the issue branch, post the required PR/issue comments,`,
  `move the project card yourself, clean up the worktree on exit. Config: ${input.configPath}.`,
  BOARD_IO(),
  `Commits, PR title, PR body blocks, comments: .claude/skills/super-board/references/writing-standard.md. Rewrite only your own PR body blocks, with .claude/bin/super-board-pr-body.sh.`,
  ...(lane === 'review' ? REVIEW_MEMORY : []),
  ...(lane === 'qa' || lane === 'review' ? BOUNCE_RULES : []),
  ...(lane === 'build' && !labelsOf(card).includes('qa')
    ? [`Return tier and maxRounds from your zone step (3c). Green tier, and no zone:amber or zone:red label → no QA lane: move the card Building → Review, not QA, and return column Review.`]
    : []),
  ...(greenEntry
    ? [`Green card: it skips QA and comes straight from Building. If the board still shows it in Building or QA, move it to Review first; there is no Tester report — check the builder's AC proof, rerun its tests, and tick each AC whose test passed with its proof line before the gate (lanes/review.md step 4).`]
    : []),
  ...(lane === 'qa' && card.status === 'Ready'
    ? [`This card is labelled qa: it skips Building. Move it Ready → QA yourself, create the issue branch from the base branch, and test what is already there (lanes/qa.md → "qa cards").`]
    : []),
  ``,
  `Report your exit via structured output:`,
  `- status=advanced  → card moved forward (Building→QA, QA→Review, Review→Done/merged)`,
  `- status=bounced   → card moved backward (QA fail → Ready, Reviewer bounce → Ready/QA); cited, see above`,
  `- status=blocked or human-gate → you wrote the Block template and moved the card to Blocked`,
  `- status=halted    → required service evidence or verification configuration is unavailable; leave card state unchanged and stop the run`,
  `- status=failed    → you could not complete the lifecycle (say why in detail)`,
  `column = the column the card is in when you exit. detail = one line. Include prUrl/branch when they exist.`,
].join('\n')

// Run-tier model ladders. Card complexity indexes into the active ladder;
// undefined = inherit the session model (the strongest available — e.g.
// Fable/Opus). Cards entering past Ready (cls null, never classified)
// always inherit the session model.
//   low    (run --low):  haiku / sonnet / opus
//   medium (default):    sonnet / opus / session
//   high   (run --high): opus for every card
const LADDERS = {
  low: { low: 'haiku', medium: 'sonnet', high: 'opus' },
  medium: { low: 'sonnet', medium: 'opus', high: undefined },
  high: { low: 'opus', medium: 'opus', high: 'opus' },
}
const ladder = LADDERS[input.tier || 'medium']
const tierFor = (cls) => (cls ? ladder[cls.complexity] : undefined)
const modelFor = (lane, cls, zone) => pick(lane, cls, tierFor(cls), zone)
// The classify router writes no code — haiku is fine except on --high runs.
const classifyModel = pick('classify', null, (input.tier || 'medium') === 'high' ? 'sonnet' : 'haiku')

const runLane = async (lane, card, model, history, opts) => {
  if (halted) {
    const result = { status: 'halted', column: card.status, detail: 'run halted; preserve work and repair the reported readiness or evidence problem' }
    history.push({ lane, ...result })
    return result
  }
  const r = await agent(lanePrompt(lane, card, opts), {
    label: `${lane}:#${card.number}`,
    phase: LANE[lane].phase,
    schema: STAGE_SCHEMA,
    ...(model ? { model } : {}),
  })
  const result = r || { status: 'failed', column: 'unknown', detail: `${lane} agent returned no result` }
  if (result.status === 'halted') halted = true
  history.push({ lane, model: model || 'session', ...result })
  return result
}

// Zone tier (v2). This script has no subprocess, so the lanes run
// super-board-zone.py on the PR's files and report `tier`. A `zone:<tier>` label
// and the ticket's `Zone:` line can raise it, never lower it. Unknown → amber,
// the zone script's own default.
const RANK = { green: 0, amber: 1, red: 2 }
const DEFAULT_ROUNDS = { green: 1, amber: 2, red: 3 }
const ZONE_COMPLEXITY = { green: 'low', amber: 'medium', red: 'high' }
const ZONE_LINE = /^[ \t]*[-*]?[ \t]*\**Zone\**:\**[ \t]*\**(green|amber|red)\b/im
const highest = (...ts) => ts.filter((t) => TIERS.includes(t)).reduce((a, b) => (a && RANK[a] >= RANK[b] ? a : b), null)
const zoneOfBody = (card) => {
  const m = typeof card.body === 'string' && card.body.match(ZONE_LINE)
  return m ? m[1].toLowerCase() : null
}
const zoneOfLabels = (card) => highest(...labelsOf(card).map((l) => (l.match(/^zone:(green|amber|red)$/) || [])[1]))
// N in `loop:rebuild-N` when the wave started: rebuilds so far (none = 0).
const rebuildsOf = (card) => Math.max(0, ...labelsOf(card).map((l) => +((l.match(/^loop:rebuild-(\d+)$/) || [])[1] || 0)))

// Enforcement: one cheap agent that makes the board match the rule below. It
// writes no code; it moves a card, fixes a label and leaves one comment.
const ENFORCE_MODEL = 'haiku'
const enforce = async (card, lines, history, mark) => {
  if (halted) {
    history.push({ lane: 'enforce', status: 'halted', column: card.status, detail: 'run halted before enforcement', ...mark })
    return { status: 'halted' }
  }
  const r = await agent([READ_FAILURE, ...lines, BOARD_IO(),
    `Comments: .claude/skills/super-board/references/writing-standard.md. Write no code. Report status, column, detail via structured output.`].join('\n'), {
    label: `enforce:#${card.number}`,
    phase: 'Enforce',
    model: ENFORCE_MODEL,
    schema: STAGE_SCHEMA,
  })
  const out = r || { status: 'failed', column: 'unknown', detail: 'enforce agent returned no result' }
  if (out.status === 'halted') halted = true
  history.push({ lane: 'enforce', model: ENFORCE_MODEL, ...out, ...mark })
  return out
}

// A QA or Review bounce, checked here rather than trusted (v2):
//   - no valid citation → rejected: the stage counts as a pass with a note, the
//     card goes to Review, never back to Building. Logged as `uncited-bounce`.
//   - cited, and N + 1 ≥ the zone's max_rounds (this round was the last one) →
//     Blocked, "round cap: needs a ruling or split". Green 1, amber 2, red 3 rounds.
// Returns true when the chain may go on to the Review lane.
const judgeBounce = async (lane, card, r, history) => {
  const n = rebuildsOf(card)
  const before = n ? `loop:rebuild-${n}` : 'no loop:rebuild label'
  const citation = String(r.citation || '').trim()
  if (!CITATION.test(citation)) {
    log(`uncited-bounce: #${card.number} ${lane} (citation "${citation}") — ${r.detail}`)
    const e = await enforce(card, [
      `Issue #${card.number} ("${card.title}"): the ${lane} lane bounced it with no valid citation ("${citation}"): ${r.detail}.`,
      `An uncited bounce is a Note, not a fail (lanes/qa.md step 8, lanes/review.md step 4). Undo it:`,
      `1. Move the card to Review. 2. Put the loop label back to what it was before this bounce (${before}).`,
      `3. Post one PR comment and one issue comment: "[${lane}] [note] uncited-bounce — <the finding>; no citation, so a Note: the card moves on." The next review never re-bounces it.`,
      `Return status=advanced, column=Review, citation "none".`,
    ], history, { uncitedBounce: true })
    return lane === 'qa' && e.status === 'advanced'
  }
  const tier = highest(r.tier, zoneOfLabels(card), zoneOfBody(card)) || 'amber'
  const max = r.tier === tier && Number.isInteger(r.maxRounds) && r.maxRounds > 0 ? r.maxRounds : DEFAULT_ROUNDS[tier]
  if (n + 1 >= max) {
    log(`round-cap: #${card.number} ${tier} max_rounds ${max}, rebuilds ${n} — ${citation}`)
    await enforce(card, [
      `Issue #${card.number} ("${card.title}"): the ${lane} lane bounced it (${citation}: ${r.detail}).`,
      `It is a ${tier} card with max_rounds ${max} and ${n} rebuild(s) so far, so that bounce would start a round past the cap.`,
      `Move the card to Blocked with the block template (.claude/skills/super-board/references/block-template.md): reason 🛡,`,
      `Why blocked: "round cap: needs a ruling or split — ${citation}", To unblock: a ruling on the finding or a split into smaller cards, last line "blocked-by: -".`,
      `Keep the loop:rebuild label. Return status=blocked, column=Blocked, detail "round cap: needs a ruling or split".`,
    ], history, { roundCapped: true, citation })
  }
  return false
}

// Builder pre-flight (lanes/build.md → "Builder pre-flight"). Before ANY Ready card
// reaches runLane('build'), a fresh cheap agent asks: already merged? already
// being built (open PR or another card)? same files as an open PR? unclear?
// One agent per batch of PREFLIGHT_BATCH cards, so the three gh list calls in
// super-board-preflight.sh are paid once per batch, not once per card.
// Outcomes: proceed · hold (agent wrote the Block template, card → Blocked) ·
// sequence (card → Blocked with `blocked-by:` the overlapping PR's issue, so the
// wave-start sweep frees it; or proceed with a conflict note when that PR closes
// no issue) · skipped (pre-flight blind — card stays Ready for the next wave).
// A card the agent did not answer for is skipped, never built unchecked.
const PREFLIGHT_SCHEMA = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          number: { type: 'integer' },
          verdict: { type: 'string', enum: ['proceed', 'hold', 'sequence', 'skipped', 'halted'] },
          column: { type: 'string' },
          blockedBy: { type: 'array', items: { type: 'integer' } },
          detail: { type: 'string' },
        },
        required: ['number', 'verdict', 'detail'],
      },
    },
  },
  required: ['verdicts'],
}
const PREFLIGHT_BATCH = 5
const preflightModel = pick('preflight', null, (input.tier || 'medium') === 'low' ? 'haiku' : 'sonnet')
const preflightPrompt = (batch) => [
  SKILLS_CHECK(batch),
  READ_FAILURE,
  `Builder pre-flight for issues ${batch.map((c) => `#${c.number} ("${c.title}")`).join(', ')}. Config: ${input.configPath}.`,
  `Read .claude/skills/super-board/references/lanes/build.md → "Builder pre-flight" and follow it EXACTLY. You write no code.`,
  `Other cards in this wave: ${JSON.stringify(input.cards.map(({ number, status, title }) => ({ number, status, title })))}`,
  `Run .claude/bin/super-board-preflight.sh once for the whole batch, then judge its candidates semantically.`,
  `hold / sequence-behind → post the Block template (block-template.md) and move the card to Blocked yourself.`,
  `Two Ready cards overlapping each other with no open PR: the lower-numbered one proceeds; sequence only the other, blockedBy [the lower]. Never both.`,
  `A sequence with nothing to wait on (empty blockedBy) leaves the card in Ready: return column Ready and it builds.`,
  BOARD_IO(),
  `Return one verdict per issue: proceed | hold | sequence | skipped (pre-flight blind). Never drop a card silently.`,
].join('\n')

// Only cards the Builder will take are pre-flighted; `qa` cards skip Building.
const ready = input.cards.filter((c) => c.status === 'Ready' && readyLane(c) === 'build')
const verdicts = new Map()
const batches = []
for (let i = 0; i < ready.length; i += PREFLIGHT_BATCH) batches.push(ready.slice(i, i + PREFLIGHT_BATCH))
await Promise.all(batches.map(async (batch) => {
  const r = await agent(preflightPrompt(batch), {
    label: `preflight:${batch.map((c) => '#' + c.number).join(',')}`,
    phase: 'Pre-flight',
    model: preflightModel,
    schema: PREFLIGHT_SCHEMA,
  })
  for (const v of (r && r.verdicts) || []) {
    verdicts.set(v.number, v)
    if (v.verdict === 'halted') halted = true
  }
}))
// sequence with nothing to wait on = proceed with a conflict note (the agent posted it).
// No column and an empty blockedBy is the same case: nothing to wait on never parks a
// card (2026-10-03: #180/#181 each "sequenced" behind the other, neither built).
const preflightGo = (card) => {
  const v = verdicts.get(card.number)
  if (!v) return false
  if (v.verdict === 'proceed') return true
  return v.verdict === 'sequence' && (v.column === 'Ready' ||
    (!v.column && Array.isArray(v.blockedBy) && v.blockedBy.length === 0))
}
const preflightExit = (card) => {
  const v = verdicts.get(card.number) ||
    { verdict: 'skipped', detail: 'pre-flight returned no verdict — not built unchecked; retried next wave' }
  return {
    lane: 'preflight',
    status: v.verdict === 'halted' ? 'halted' : v.verdict === 'skipped' ? 'failed' : 'blocked',
    column: v.column || (['skipped', 'halted'].includes(v.verdict) ? 'Ready' : 'Blocked'),
    detail: `${v.verdict}: ${v.detail}`,
  }
}

const results = await pipeline(
  input.cards,
  // Stage 1: classify cards entering at Ready (router for model tiering)
  async (card) => {
    if (halted) return { card, cls: null }
    if (card.status !== 'Ready') return { card, cls: null }
    const labels = labelsOf(card)
    const typed = ['qa', 'bug', 'feature'].find((l) => labels.includes(l))
    // A ticket that names its zone needs no router (~25k tokens a card): the
    // zone is the complexity, the label the kind (no label = built, a feature).
    const zone = zoneOfBody(card)
    if (zone) return { card, cls: { kind: typed || 'feature', complexity: ZONE_COMPLEXITY[zone], zone } }
    const cls = await agent(
      SKILLS_CHECK([card]) + '\n' + READ_FAILURE + '\n' + `Read GitHub issue #${card.number} ("${card.title}") — body (--kind issue) and all comments (--kind comments) — with the read shapes above. ` +
      `Classify it: kind (feature|bug|qa) and complexity (low|medium|high) judged by the scope of change required. ` +
      (typed
        ? `Its label says "${typed}": return kind "${typed}" — the label routes the card, you never override it.`
        : `It has no type label, so it is built (no label = Building). Return feature or bug — never qa, ` +
          `which only a person sets. Existing docs/ux/tests/refactor/tech-debt rows keep their label chain: classify complexity without adding feature/bug. For a truly untyped card, re-run skills-ready against a copy of this card with the proposed label before any label write, then add that label: gh issue edit ${card.number} --add-label <kind>.`),
      { label: `classify:#${card.number}`, phase: 'Classify', model: classifyModel, schema: CLASSIFY_SCHEMA }
    )
    if (cls && cls.status === 'halted') halted = true
    return { card, cls }
  },
  // Stage 2: lane chain — entry point depends on the card's current column.
  // A non-'advanced' exit ends the chain; the next wave re-selects the card
  // from wherever it landed (the board is the loop state, not this script).
  async (prev, card) => {
    const history = []
    const cls = prev && prev.cls
    // Every exit carries the classified complexity (#33).
    // Known before Build: the zone:<tier> label or the ticket's Zone: line.
    let zone = highest(zoneOfLabels(card), zoneOfBody(card))
    const done = () => ({ number: card.number, complexity: (cls && cls.complexity) || null, zone, history })
    if (halted) {
      history.push({ lane: 'none', status: 'halted', column: card.status, detail: 'run halted; preserve current work and resume explicitly' })
      return done()
    }
    let at = card.status
    let greenEntry = false
    // Each lane sees the card where it is now, not where the wave found it (#32):
    // a card that just built is in QA, never a qa-labelled Ready card.
    const now = () => ({ ...card, status: at })

    if (at === 'Ready' && readyLane(card) === 'build') {
      if (!preflightGo(card)) {
        history.push(preflightExit(card))
        return done()
      }
      const b = await runLane('build', now(), modelFor('build', cls, zone), history)
      if (b.status !== 'advanced') return done()
      zone = highest(zone, b.tier)
      // Green skips QA (lanes/qa.md step 4): Build → Review. Only on the
      // builder's own zone-script tier, never on the ticket's word alone.
      greenEntry = b.tier === 'green' && zone === 'green'
      at = greenEntry ? 'Review' : 'QA'
    }
    // A `qa`-labelled card skips Building: Ready → QA, Tester first
    // (run.md "Lanes and label routing").
    // A qa card keeps status Ready for its Tester prompt (the skip-Building instruction).
    const qaEntry = at === 'Ready' && readyLane(card) === 'qa'
    if (qaEntry) at = 'QA'
    if (at === 'QA') {
      const q = await runLane('qa', qaEntry ? card : now(), modelFor('qa', cls, zone), history)
      if (q.status === 'bounced') {
        if (!(await judgeBounce('qa', card, q, history))) return done()
      } else if (q.status !== 'advanced') return done()
      zone = highest(zone, q.tier)
      at = 'Review'
    }
    if (at === 'Review') {
      // Reviewer on the session model unless lane_models.review says otherwise.
      // No lane-level serialisation: the merge gate holds the mutex for the
      // merge alone (see the note above).
      const r = await runLane('review', now(), pick('review', cls, undefined, zone), history, { greenEntry })
      if (r.status === 'bounced') await judgeBounce('review', card, r, history)
      zone = highest(zone, r.tier)
    }
    return done()
  }
)

const summary = results.filter(Boolean).map((r) => {
  const last = r.history[r.history.length - 1] ||
    { lane: 'none', status: 'failed', column: 'unknown', detail: 'no lane ran' }
  const modelOf = (lane) => (r.history.find((h) => h.lane === lane) || {}).model || null
  const review = [...r.history].reverse().find((h) => h.lane === 'review')
  // The last QA/Review verdict's citation: a valid one, "none" for a pass, else null.
  const cited = [...r.history].reverse().find((h) => (h.lane === 'qa' || h.lane === 'review') && h.citation)
  const citation = cited && (cited.citation === 'none' || CITATION.test(cited.citation.trim())) ? cited.citation.trim() : null
  return {
    number: r.number,
    complexity: r.complexity || null,
    tier: r.zone || null,
    citation,
    uncitedBounce: r.history.some((h) => h.uncitedBounce),
    roundCapped: r.history.some((h) => h.roundCapped || (h.status === 'blocked' && /round cap/i.test(h.detail || ''))),
    buildModel: modelOf('build'),
    qaModel: modelOf('qa'),
    reviewModel: modelOf('review'),
    score: (review && review.score) || null,
    finalStatus: last.status,
    lastLane: last.lane,
    column: last.column,
    detail: last.detail,
    prUrl: last.prUrl || null,
    priorFindings: last.priorFindings || null,
    lanesRun: r.history.map((h) => `${h.lane}:${h.status}`).join(' → ') || 'none',
  }
})
log(`wave complete: ${summary.length} cards — ` +
    summary.map((s) => `#${s.number}=${s.finalStatus}@${s.column}`).join(', '))
return { cards: summary, halted }
