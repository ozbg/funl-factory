#!/usr/bin/env bash
# Tests per-lane models (args.laneModels from config `lane_models`) and the
# Review scorecard in workflows/super-board-wave.js (factory #25). No gh calls:
# the script body runs under node with agent/pipeline/log stubbed.
set -euo pipefail
cd "$(dirname "$0")"

node - ../workflows/super-board-wave.js <<'JS'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
const run = (args, complexity = 'high', review = {}) => {
  const models = {}
  const prompts = {}
  const agent = async (prompt, opts) => {
    models[opts.label] = opts.model
    prompts[opts.label] = prompt
    const l = opts.label
    if (l.startsWith('preflight')) return { verdicts: args.cards.map((c) => ({ number: c.number, verdict: 'proceed', detail: 'clean' })) }
    if (l.startsWith('classify')) return { kind: 'feature', complexity }
    if (l.startsWith('review')) return { status: 'advanced', column: 'Done', detail: 'merged', ...review }
    return { status: 'advanced', column: 'next', detail: 'ok' }
  }
  const pipeline = async (items, ...stages) => Promise.all(items.map(async (it) => {
    let v = it
    for (const [i, st] of stages.entries()) v = i === 0 ? await st(it) : await st(v, it)
    return v
  }))
  return new AsyncFunction('args', 'agent', 'pipeline', 'log', src)(args, agent, pipeline, () => {})
    .then((out) => ({ out, models, prompts }))
}
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1) }
const eq = (a, b, m) => a === b || fail(`${m}: expected ${b}, got ${a}`)
const base = { configPath: 'c.json' }
const ready = (n) => ({ number: n, status: 'Ready', title: 't' })

;(async () => {
  // 1 — owner's setup: Haiku build and QA, Review on the session model, on a hard card.
  const haiku = { classify: 'haiku', preflight: 'haiku', build: 'haiku', qa: 'haiku', review: 'session' }
  const a = await run({ ...base, laneModels: haiku, cards: [ready(7)] }, 'high')
  eq(a.models['preflight:#7'], 'haiku', 'preflight model')
  eq(a.models['classify:#7'], 'haiku', 'classify model')
  eq(a.models['build:#7'], 'haiku', 'build model on a high card')
  eq(a.models['qa:#7'], 'haiku', 'qa model on a high card')
  eq(a.models['review:#7'], undefined, 'review "session" passes no model')
  const s = a.out.cards[0]
  eq(s.buildModel, 'haiku', 'summary buildModel')
  eq(s.qaModel, 'haiku', 'summary qaModel')
  eq(s.reviewModel, 'session', 'summary reviewModel')
  eq(s.complexity, 'high', 'summary complexity')

  // 2 — a card entering past Ready (never classified) still gets its lane model.
  const b = await run({ ...base, laneModels: haiku, cards: [{ number: 8, status: 'QA', title: 't' }] })
  eq(b.models['qa:#8'], 'haiku', 'qa model for a card entering at QA')
  eq(b.models['review:#8'], undefined, 'review model for a card entering at QA')

  // 3 — a complexity map picks by the card's class; past Ready uses the medium cell.
  const map = { qa: { low: 'haiku', medium: 'haiku', high: 'sonnet' } }
  eq((await run({ ...base, laneModels: map, cards: [ready(9)] }, 'high')).models['qa:#9'], 'sonnet', 'map high')
  eq((await run({ ...base, laneModels: map, cards: [ready(9)] }, 'low')).models['qa:#9'], 'haiku', 'map low')
  eq((await run({ ...base, laneModels: map, cards: [{ number: 9, status: 'QA', title: 't' }] })).models['qa:#9'], 'haiku', 'map past Ready → medium')
  // A lane the map leaves out keeps the tier: medium ladder, high card → session.
  eq((await run({ ...base, laneModels: map, cards: [ready(9)] }, 'high')).models['build:#9'], undefined, 'unset lane keeps tier')

  // 4 — no laneModels: today's choices exactly (medium tier).
  const d = await run({ ...base, cards: [ready(10)] }, 'low')
  eq(d.models['preflight:#10'], 'sonnet', 'default preflight')
  eq(d.models['classify:#10'], 'haiku', 'default classify')
  eq(d.models['build:#10'], 'sonnet', 'default build on a low card')
  eq(d.models['qa:#10'], 'sonnet', 'default qa on a low card')
  eq(d.models['review:#10'], undefined, 'default review')
  const lo = await run({ ...base, tier: 'low', cards: [ready(10)] }, 'medium')
  eq(lo.models['build:#10'], 'sonnet', '--low medium card')
  eq(lo.models['preflight:#10'], 'haiku', '--low preflight')

  // 5 — a bad setting fails the wave before any agent runs.
  for (const bad of [{ builder: 'haiku' }, { qa: '' }, { qa: { huge: 'opus' } }, { qa: {} }, ['haiku']]) {
    let threw = false
    await run({ ...base, laneModels: bad, cards: [ready(11)] }).catch(() => { threw = true })
    threw || fail(`laneModels ${JSON.stringify(bad)} must throw`)
  }

  // 6 — Review is asked for the score; build/QA are not. The score reaches the summary.
  const score = { verdict: 'fixes', acsProven: 3, acsTotal: 4, blockers: 0, round: 2, cause: 'ticket' }
  const f = await run({ ...base, laneModels: haiku, cards: [ready(12)] }, 'low', { score })
  ;/Also return score/.test(f.prompts['review:#12']) || fail('review prompt must ask for score')
  ;['build:#12', 'qa:#12'].forEach((l) => /Also return score/.test(f.prompts[l]) && fail(`${l} must not be asked for score`))
  eq(JSON.stringify(f.out.cards[0].score), JSON.stringify(score), 'summary score')
  // A review with no score reports null, never a made-up one.
  eq((await run({ ...base, cards: [ready(13)] })).out.cards[0].score, null, 'missing score → null')
})().catch((e) => fail(e.stack))
JS
echo "PASS: test-wave-lane-models.sh (6 scenarios)"
