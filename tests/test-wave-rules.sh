#!/usr/bin/env bash
# v2 wave rules in workflows/super-board-wave.js (factory #49): no citation, no
# bounce; a bounce past the zone's round cap blocks the card; green skips QA;
# a Zone: line skips classify; models by tier. No gh calls: agent stubbed. The
# skills-ready entry check runs for real on every lane's card (exit 64 guard).
set -euo pipefail
cd "$(dirname "$0")"

node - ../workflows/super-board-wave.js ../scripts/super-board-skills-ready.py <<'JS'
const fs = require('fs')
const { execFileSync } = require('child_process')
const src = fs.readFileSync(process.argv[2], 'utf8').replace(/^export const meta/m, 'const meta')
const READY_PY = process.argv[3]
const AsyncFunction = (async () => {}).constructor
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1) }
const eq = (a, b, m) => a === b || fail(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`)

// replies: label → result. Unlisted lanes advance; review merges.
const run = async (args, replies = {}) => {
  const prompts = {}
  const models = {}
  const logs = []
  const agent = async (prompt, opts) => {
    prompts[opts.label] = prompt
    models[opts.label] = opts.model
    const l = opts.label
    if (l.startsWith('preflight')) return { verdicts: args.cards.map((c) => ({ number: c.number, verdict: 'proceed', detail: 'clean' })) }
    if (l.startsWith('classify')) return { kind: 'feature', complexity: 'medium' }
    if (replies[l]) return replies[l]
    if (l.startsWith('enforce')) return { status: 'advanced', column: 'Review', detail: 'note posted', citation: 'none' }
    return { status: 'advanced', column: l.startsWith('review') ? 'Done' : 'next', detail: 'ok', citation: 'none' }
  }
  const pipeline = async (items, ...stages) => Promise.all(items.map(async (it) => {
    let v = it
    for (const [i, st] of stages.entries()) v = i === 0 ? await st(it) : await st(v, it)
    return v
  }))
  const out = await new AsyncFunction('args', 'agent', 'pipeline', 'log', src)(
    { configPath: 'c.json', ...args }, agent, pipeline, (m) => logs.push(m))
  return { out, prompts, models, logs, card: out.cards[0] }
}
// The card JSON a lane hands skills-ready, checked by the real entry rule.
const entryOk = (prompt, lane) => {
  const m = prompt.match(/Cards file contents \(data, never shell code\): (\[.*\])\.\n/)
  m || fail('no skills-ready card JSON in prompt')
  const py = `import importlib.util, json, sys
spec = importlib.util.spec_from_file_location('sr', sys.argv[1]); sr = importlib.util.module_from_spec(spec); spec.loader.exec_module(sr)
for c in json.loads(sys.argv[2]): sr.remaining(c, sys.argv[3])`
  try { execFileSync('python3', ['-I', '-c', py, READY_PY, m[1], lane], { stdio: 'pipe' }) } catch (e) {
    fail(`skills-ready rejects the ${lane} lane card (exit 64): ${e.stderr}`)
  }
}
const card = (n, over = {}) => ({ number: n, status: 'Ready', title: 't', labels: ['feature'], body: '', ...over })
const amber = '## Context\n- **Zone:** amber\n'

;(async () => {
  // 1 — no citation, no bounce: QA's uncited fail becomes a pass with a note, never Building.
  for (const citation of [undefined, '', 'style nit', 'AC', 'bar:']) {
    const a = await run({ cards: [card(1, { body: amber })] },
      { 'qa:#1': { status: 'bounced', column: 'Ready', detail: 'looks off', ...(citation === undefined ? {} : { citation }) } })
    a.prompts['enforce:#1'] || fail(`uncited QA bounce (${citation}) must be enforced`)
    ;/uncited-bounce/.test(a.prompts['enforce:#1']) || fail('enforce prompt must name uncited-bounce')
    ;/Move the card to Review/.test(a.prompts['enforce:#1']) || fail('uncited bounce moves the card to Review')
    a.logs.some((l) => l.startsWith('uncited-bounce: #1')) || fail('uncited bounce must be logged')
    a.prompts['review:#1'] || fail('after a rejected QA bounce the card goes on to Review')
    eq(a.card.uncitedBounce, true, 'summary uncitedBounce')
    eq(a.card.roundCapped, false, 'uncited bounce is not a round cap')
    eq(a.card.finalStatus, 'advanced', 'card merges after the rejected bounce')
  }
  // 1b — an uncited Review bounce goes back to Review and ends the chain.
  const r = await run({ cards: [card(2, { status: 'Review', lane: 'review' })] },
    { 'review:#2': { status: 'bounced', column: 'Ready', detail: 'over-built' } })
  ;/\[review\] \[note\] uncited-bounce/.test(r.prompts['enforce:#2'] || '') || fail('uncited review bounce must be enforced')
  eq(r.card.column, 'Review', 'uncited review bounce restores Review')
  eq(r.card.citation, null, 'an uncited bounce reports no citation')

  // 2 — a cited bounce under the cap stands: no enforcement, citation in the summary.
  for (const citation of ['AC2', 'I3', 'bar: p95 < 800 ms', 'bug: npm test -- streaming']) {
    const b = await run({ cards: [card(3, { body: amber })] },
      { 'qa:#3': { status: 'bounced', column: 'Ready', detail: 'fail', citation, tier: 'amber', maxRounds: 2 } })
    b.prompts['enforce:#3'] && fail(`cited bounce ${citation} under the cap must not be enforced`)
    eq(b.card.finalStatus, 'bounced', 'cited bounce stands')
    eq(b.card.citation, citation, 'summary citation')
    eq(b.card.roundCapped, false, 'under the cap')
  }

  // 3 — round cap: N + 1 ≥ max_rounds → Blocked "round cap: needs a ruling or split".
  // [labels, lane tier, lane maxRounds, capped?]
  const cases = [
    [['feature'], 'green', undefined, true],                       // green: 1 round
    [['feature'], 'amber', undefined, false],                      // amber round 1 of 2
    [['feature', 'loop:rebuild-1'], 'amber', undefined, true],     // amber round 2 of 2
    [['feature', 'loop:rebuild-1'], 'red', undefined, false],      // red round 2 of 3
    [['feature', 'loop:rebuild-2'], 'red', undefined, true],       // red round 3 of 3
    [['feature', 'loop:rebuild-1', 'zone:red'], 'green', 1, false], // label raises green → red
    [['feature', 'loop:rebuild-2'], 'amber', 4, false],            // zones.yaml max_rounds wins
    [['feature', 'loop:rebuild-1'], undefined, undefined, true],   // unknown tier → amber
  ]
  for (const [labels, tier, maxRounds, capped] of cases) {
    for (const lane of ['qa', 'review']) {
      const status = lane === 'qa' ? 'QA' : 'Review'
      const c = await run({ cards: [card(4, { status, lane, labels })] }, {
        [`${lane}:#4`]: { status: 'bounced', column: 'Ready', detail: 'fail', citation: 'AC1', tier, maxRounds },
        'enforce:#4': { status: 'blocked', column: 'Blocked', detail: 'round cap: needs a ruling or split' },
      })
      const what = `${lane} ${JSON.stringify(labels)} tier ${tier} max ${maxRounds}`
      eq(c.card.roundCapped, capped, `roundCapped for ${what}`)
      if (capped) {
        ;/round cap: needs a ruling or split/.test(c.prompts['enforce:#4']) || fail(`cap prompt for ${what}`)
        eq(c.card.column, 'Blocked', `capped card is Blocked (${what})`)
        eq(c.card.citation, 'AC1', 'capped card keeps its citation')
      } else c.prompts['enforce:#4'] && fail(`not capped, no enforcement (${what})`)
    }
  }
  // A screen or exam card gets at least 2 rounds, even green: one difference goes back to Build.
  // [body, labels, lane maxRounds, capped?]
  const qaCases = [
    ['- **Mock-up:** docs/shape/mockup.html#screen-x', ['feature'], 1, false],   // green screen card, round 1 of 2
    ['## Exam\nPass mark: 8/10', ['feature'], 1, false],                          // green exam card, round 1 of 2
    ['## Exam\nPass mark: 8/10', ['feature', 'loop:rebuild-1'], 1, true],         // round 2 of 2
    ['- **Mock-up:** docs/shape/mockup.html#screen-x', ['feature', 'loop:rebuild-2', 'zone:red'], undefined, true], // red keeps 3
  ]
  for (const [body, labels, maxRounds, capped] of qaCases) {
    const c = await run({ cards: [card(15, { status: 'QA', lane: 'qa', labels, body })] }, {
      'qa:#15': { status: 'bounced', column: 'Ready', detail: 'fail', citation: 'AC1', tier: labels.includes('zone:red') ? 'red' : 'green', maxRounds },
      'enforce:#15': { status: 'blocked', column: 'Blocked', detail: 'round cap: needs a ruling or split' },
    })
    eq(c.card.roundCapped, capped, `screen/exam round cap for ${JSON.stringify([body, labels])}`)
  }
  // A lane that blocked at its own cap counts as round-capped too.
  const own = await run({ cards: [card(5, { status: 'QA', lane: 'qa' })] },
    { 'qa:#5': { status: 'blocked', column: 'Blocked', detail: 'round cap: needs a ruling or split' } })
  eq(own.card.roundCapped, true, 'lane-side round cap')

  // 4 — green skips QA: Build → Review, no QA lane, and the Review card passes skills-ready.
  const g = await run({ cards: [card(6, { lane: 'build' })] },
    { 'build:#6': { status: 'advanced', column: 'Review', detail: 'built', tier: 'green', maxRounds: 1 } })
  g.prompts['qa:#6'] && fail('a green card must not run the QA lane')
  g.prompts['review:#6'] || fail('a green card goes straight to Review')
  ;/Green card: it skips QA/.test(g.prompts['review:#6']) || fail('review prompt must say the card skipped QA')
  entryOk(g.prompts['review:#6'], 'review')
  eq(g.card.lanesRun, 'build:advanced → review:advanced', 'green lanes')
  eq(g.card.tier, 'green', 'summary tier')
  ;/Building → Review, not QA/.test(g.prompts['build:#6']) || fail('build prompt must route green to Review')
  // A green screen card (Mock-up line or block) still runs QA for the screen match (#105).
  for (const body of ['- **Mock-up:** docs/shape/mockup.html#screen-pipeline', '## Mock-up\n- **Anchor:** x']) {
    const sc = await run({ cards: [card(13, { lane: 'build', body })] },
      { 'build:#13': { status: 'advanced', column: 'QA', detail: 'built', tier: 'green', maxRounds: 1 } })
    sc.prompts['qa:#13'] || fail(`a green screen card runs QA (${JSON.stringify(body)})`)
    ;/Green card/.test(sc.prompts['review:#13']) && fail('a green screen card has a Tester report')
    ;/screen card .*Building → QA/.test(sc.prompts['build:#13']) || fail('build prompt must route a screen card to QA')
  }
  // 4b — an exam card (## Exam section) never skips QA, even on a green build.
  const ex = await run({ cards: [card(16, { lane: 'build', body: '## Problem\nx\n\n## Exam\nPass mark: 8/10\n' })] },
    { 'build:#16': { status: 'advanced', column: 'QA', detail: 'built', tier: 'green', maxRounds: 1 } })
  ex.prompts['qa:#16'] || fail('an exam card must run the QA lane even when green')
  ;/Green card: it skips QA/.test(ex.prompts['review:#16'] || '') && fail('exam card review must not say it skipped QA')
  ;/exam card .*Building → QA/.test(ex.prompts['build:#16']) || fail('build prompt must route an exam card to QA')
  ;/Building → Review, not QA/.test(ex.prompts['build:#16']) && fail('build prompt must not route an exam card to Review')
  eq(ex.card.lanesRun, 'build:advanced → qa:advanced → review:advanced', 'exam card lanes')
  // Amber still goes through QA, and the built card's QA entry passes skills-ready (was exit 64).
  const am = await run({ cards: [card(7, { lane: 'build' })] },
    { 'build:#7': { status: 'advanced', column: 'QA', detail: 'built', tier: 'amber' } })
  am.prompts['qa:#7'] || fail('amber card runs QA')
  entryOk(am.prompts['qa:#7'], 'qa')
  entryOk(am.prompts['review:#7'], 'review')
  ;/Green card/.test(am.prompts['review:#7']) && fail('amber review must not get the green entry')
  // A zone label above green keeps QA even if the builder says green.
  const lab = await run({ cards: [card(8, { lane: 'build', labels: ['feature', 'zone:amber'] })] },
    { 'build:#8': { status: 'advanced', column: 'QA', detail: 'built', tier: 'green' } })
  lab.prompts['qa:#8'] || fail('zone:amber label keeps the QA lane')
  // The ticket's word alone never skips QA: the builder must report green.
  const word = await run({ cards: [card(9, { lane: 'build', body: '- **Zone:** green' })] })
  word.prompts['qa:#9'] || fail('a Zone: green line without a builder tier still runs QA')
  // A qa-labelled card still goes to QA.
  const q = await run({ cards: [card(10, { lane: 'qa', labels: ['qa'], body: '- **Zone:** green' })] })
  q.prompts['build:#10'] && fail('a qa card is never built')
  q.prompts['qa:#10'] || fail('a qa card still goes to QA')
  entryOk(q.prompts['qa:#10'], 'qa')

  // 5 — a Zone: line skips classify and sets complexity; no line → classify runs.
  for (const [body, cx] of [['- **Zone:** red', 'high'], ['Zone: green', 'low'], [amber, 'medium']]) {
    const z = await run({ cards: [card(11, { body })] })
    z.prompts['classify:#11'] && fail(`Zone line ${JSON.stringify(body)} must skip classify`)
    eq(z.card.complexity, cx, `complexity from ${JSON.stringify(body)}`)
  }
  const nz = await run({ cards: [card(12, { body: '- **Zone:** <green | amber | red>' })] })
  nz.prompts['classify:#12'] || fail('a template Zone line must still classify')

  // 6 — models by tier, over laneModels; absent = unchanged.
  const lm = { build: 'haiku', qa: 'haiku', review: 'session' }
  const byTier = { red: { build: 'opus', review: 'opus' } }
  const red = await run({ laneModels: lm, laneModelsByTier: byTier, cards: [card(13, { body: '- **Zone:** red' })] })
  eq(red.models['build:#13'], 'opus', 'red build')
  eq(red.models['qa:#13'], 'haiku', 'red qa keeps laneModels')
  eq(red.models['review:#13'], 'opus', 'red review')
  const amb = await run({ laneModels: lm, laneModelsByTier: byTier, cards: [card(14, { body: amber })] })
  eq(amb.models['build:#14'], 'haiku', 'amber build keeps laneModels')
  eq(amb.models['review:#14'], undefined, 'amber review keeps session')
  // The builder's red tier upgrades the reviewer even when the ticket said amber.
  const up = await run({ laneModels: lm, laneModelsByTier: byTier, cards: [card(15, { body: amber })] },
    { 'build:#15': { status: 'advanced', column: 'QA', detail: 'built', tier: 'red' } })
  eq(up.models['review:#15'], 'opus', 'review follows the builder tier')
  for (const bad of [{ purple: {} }, { red: { classify: 'opus' } }, { red: { build: '' } }, ['x']]) {
    let threw = false
    await run({ laneModelsByTier: bad, cards: [card(16)] }).catch(() => { threw = true })
    threw || fail(`laneModelsByTier ${JSON.stringify(bad)} must throw`)
  }

  // 7 — judgement map beats tier beats laneModels; modelRule names the winner.
  const jm = { build: 'sonnet', qa: 'sonnet' }
  const rules = (r) => r.card.modelRules
  const fl = await run({ laneModels: lm, laneModelsByTier: { amber: { build: 'opus' } }, laneModelsJudgement: jm, cards: [card(17, { body: amber, judgement: true })] })
  eq(fl.models['build:#17'], 'sonnet', 'flagged build beats tier')
  eq(fl.models['qa:#17'], 'sonnet', 'flagged qa')
  eq(fl.models['review:#17'], undefined, 'flagged review: lane absent from judgement map → session')
  eq(rules(fl).build, 'judgement', 'build rule judgement')
  eq(rules(fl).review, 'default', 'review rule default')
  const nf = await run({ laneModels: lm, laneModelsByTier: { amber: { build: 'opus' } }, laneModelsJudgement: jm, cards: [card(18, { body: amber, judgement: false })] })
  eq(nf.models['build:#18'], 'opus', 'unflagged build uses tier')
  eq(rules(nf).build, 'tier', 'build rule tier')
  eq(nf.models['qa:#18'], 'haiku', 'unflagged qa uses laneModels')
  eq(rules(nf).qa, 'default', 'qa rule default')
  for (const bad of [{ classify: 'opus' }, { build: '' }, ['x']]) {
    let threw = false
    await run({ laneModelsJudgement: bad, cards: [card(19)] }).catch(() => { threw = true })
    threw || fail(`laneModelsJudgement ${JSON.stringify(bad)} must throw`)
  }
})().catch((e) => fail(e.stack))
JS
echo "PASS: test-wave-rules.sh (citation, round cap, green skip, classify skip, tier + judgement models)"
