#!/usr/bin/env bash
# Red-card truth-check in workflows/super-board-wave.js (factory #87). The
# Reviewer lane has no sub-agent tool, so the workflow runs the Code-grounder
# and Historian itself, before Review, and hands the score to the Reviewer.
# A red card whose check did not run is Blocked and never reaches the Reviewer
# (so never the merge gate). No gh calls: agent stubbed.
set -euo pipefail
cd "$(dirname "$0")"

node - ../workflows/super-board-wave.js <<'JS'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1) }
const eq = (a, b, m) => JSON.stringify(a) === JSON.stringify(b) || fail(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`)

// replies: label → result (or null for "no result"). Unlisted truth agents pass at 90.
const run = async (args, replies = {}) => {
  const prompts = {}
  const order = []
  const logs = []
  const agent = async (prompt, opts) => {
    const l = opts.label
    prompts[l] = prompt
    order.push(l)
    if (l.startsWith('preflight')) return { verdicts: args.cards.map((c) => ({ number: c.number, verdict: 'proceed', detail: 'clean' })) }
    if (l.startsWith('classify')) return { kind: 'feature', complexity: 'medium' }
    if (l in replies) return replies[l]
    if (l.startsWith('truth-')) return { status: 'ok', confidence: 90, findings: [], detail: 'claims hold' }
    if (l.startsWith('enforce')) return { status: 'blocked', column: 'Blocked', detail: 'truth-check did not run', citation: 'bar: truth-check before merge' }
    return { status: 'advanced', column: l.startsWith('review') ? 'Done' : 'next', detail: 'ok', citation: 'none', prUrl: 'https://github.com/a/b/pull/40' }
  }
  const pipeline = async (items, ...stages) => Promise.all(items.map(async (it) => {
    let v = it
    for (const [i, st] of stages.entries()) v = i === 0 ? await st(it) : await st(v, it)
    return v
  }))
  const out = await new AsyncFunction('args', 'agent', 'pipeline', 'log', src)(
    { configPath: 'c.json', ...args }, agent, pipeline, (m) => logs.push(m))
  return { out, prompts, order, logs, card: out.cards[0] }
}
const card = (n, over = {}) => ({ number: n, status: 'Review', lane: 'review', title: 't', labels: ['feature'], body: '', ...over })
const red = { labels: ['feature', 'zone:red'] }

;(async () => {
  // 1 — a red card's truth-check runs before Review; the score (minimum) and findings reach the review prompt.
  const finding = { class: 'Bug', severity: 'Blocker', where: 'src/a.ts:3', finding: 'no auth check', citation: 'I2' }
  const a = await run({ cards: [card(1, red)] }, {
    'truth-historian:#1': { status: 'ok', confidence: 72, findings: [finding], detail: 'one doubt' },
  })
  a.prompts['truth-code-grounder:#1'] || fail('Code-grounder must run on a red card')
  a.prompts['truth-historian:#1'] || fail('Historian must run on a red card')
  ;/Adversarial mode/.test(a.prompts['truth-historian:#1']) || fail('truth agents use the fixed brief from super-review')
  ;/Read only/.test(a.prompts['truth-historian:#1']) || fail('truth agents are read-only')
  a.order.indexOf('truth-historian:#1') < a.order.indexOf('review:#1') || fail('truth-check runs before Review')
  const rp = a.prompts['review:#1']
  ;/Score: 72\/100/.test(rp) || fail('review prompt must carry the minimum score')
  ;/Do not spawn truth-check sub-agents/.test(rp) || fail('review must not try to spawn sub-agents')
  rp.includes('no auth check') || fail('review prompt must carry the findings')
  ;/"truth 72\/100" on the Did line/.test(rp) || fail('review report must carry the truth result')
  eq(a.card.truthCheck, { ran: true, score: 72 }, 'summary truthCheck')
  eq(a.card.column, 'Done', 'checked red card goes on to merge')

  // 1b — red from the builder's zone script: Build → QA → truth → Review, PR url handed over.
  const b = await run({ cards: [card(2, { status: 'Ready', lane: 'build' })] }, {
    'build:#2': { status: 'advanced', column: 'QA', detail: 'built', tier: 'red', prUrl: 'https://github.com/a/b/pull/41' },
    'qa:#2': { status: 'advanced', column: 'Review', detail: 'passed', citation: 'none' },
  })
  eq(b.order.filter((l) => !/^(preflight|classify)/.test(l)),
    ['build:#2', 'qa:#2', 'truth-code-grounder:#2', 'truth-historian:#2', 'review:#2'], 'lane order')
  b.prompts['truth-code-grounder:#2'].includes('pull/41') || fail('truth agents get the PR url')

  // 2 — the check did not run (failed, no verdict, no result, bad score): Blocked, the Reviewer never starts.
  for (const bad of [
    { status: 'failed', detail: 'diff unreadable' },
    { status: 'ok', confidence: 0, insufficientData: true, detail: 'over budget' },
    null,
    { status: 'ok', detail: 'no score' },
  ]) {
    const c = await run({ cards: [card(3, red)] }, { 'truth-code-grounder:#3': bad })
    c.prompts['review:#3'] && fail(`no review (and no merge) when the truth-check did not run: ${JSON.stringify(bad)}`)
    const ep = c.prompts['enforce:#3'] || fail('a missing truth-check must be enforced')
    ;/Move the card to Blocked/.test(ep) || fail('missing truth-check blocks the card')
    ;/truth-check did not run/.test(ep) || fail('block reason names the missing check')
    ;/bar: truth-check before merge/.test(ep) || fail('the blocker cites the check')
    c.logs.some((l) => l.startsWith('truth-check-missing: #3')) || fail('missing truth-check must be logged')
    eq(c.card.truthCheck, { ran: false, score: null }, 'summary truthCheck when missing')
    eq(c.card.column, 'Blocked', 'card is Blocked')
  }

  // 3 — amber card: no truth agents; the Reviewer is told not to merge if its own zone step finds red.
  const d = await run({ cards: [card(4)] })
  Object.keys(d.prompts).some((l) => l.startsWith('truth-')) && fail('amber card must not run the truth-check')
  ;/If your zone step \(3c\) finds tier red, do not merge/.test(d.prompts['review:#4']) || fail('review must hold a red card with no truth-check')
  eq(d.card.truthCheck, null, 'no truth-check needed')
  // ...and if it merges one anyway, the wave log says so.
  const e = await run({ cards: [card(5)] }, { 'review:#5': { status: 'advanced', column: 'Done', detail: 'merged', tier: 'red', citation: 'none' } })
  e.logs.some((l) => l.startsWith('truth-check-skipped: #5')) || fail('red merge with no truth-check must be logged')

  // 4 — truthGate: off never runs it (and says nothing); always runs it on an amber card.
  const f = await run({ truthGate: 'off', cards: [card(6, red)] })
  Object.keys(f.prompts).some((l) => l.startsWith('truth-')) && fail('truthGate off: no truth-check')
  ;/^Truth-check: /m.test(f.prompts['review:#6']) && fail('truthGate off: review prompt has no truth lines')
  const g = await run({ truthGate: 'always', cards: [card(7)] })
  g.prompts['truth-historian:#7'] || fail('truthGate always: amber card is checked')
  let threw = false
  try { await run({ truthGate: 'sometimes', cards: [card(8)] }) } catch (err) { threw = /unknown truthGate/.test(err.message) }
  threw || fail('an unknown truthGate fails the wave up front')

  // 5 — a halted truth agent stops the card: no review, no enforcement.
  const h = await run({ cards: [card(9, red)] }, { 'truth-code-grounder:#9': { status: 'halted', detail: 'exit 79' } })
  h.prompts['review:#9'] && fail('halted truth-check: no review')
  h.prompts['enforce:#9'] && fail('halted truth-check: no enforcement')
  eq(h.out.halted, true, 'run halted')
})().catch((e) => fail(e.stack))
JS
echo "PASS: test-wave-truth-check.sh (red check before Review, missing check blocks, truthGate)"
