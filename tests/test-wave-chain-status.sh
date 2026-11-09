#!/usr/bin/env bash
# Each lane sees the card where it is now, and every summary row keeps its
# classified complexity (factory #32, #33). No gh calls: agent/pipeline stubbed.
set -euo pipefail
cd "$(dirname "$0")"

node - ../workflows/super-board-wave.js <<'JS'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
const run = (cards, reply) => {
  const prompts = {}
  const agent = async (prompt, opts) => { prompts[opts.label] = prompt; return reply(opts.label) }
  const pipeline = async (items, ...stages) => Promise.all(items.map(async (it) => {
    let v = it
    for (const [i, st] of stages.entries()) v = i === 0 ? await st(it) : await st(v, it)
    return v
  }))
  return new AsyncFunction('args', 'agent', 'pipeline', 'log', src)({ configPath: 'c.json', cards }, agent, pipeline, () => {})
    .then((out) => ({ out, prompts }))
}
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1) }
const QA_CARD = /This card is labelled qa: it skips Building/
const base = (cx, over = {}) => (label) => {
  if (label.startsWith('preflight')) return { verdicts: [7, 8, 9, 10].map((n) => ({ number: n, verdict: n === 9 ? 'hold' : 'proceed', column: n === 9 ? 'Blocked' : undefined, detail: 'x' })) }
  if (label.startsWith('classify')) return { kind: 'feature', complexity: cx }
  if (over[label]) return over[label]
  return { status: 'advanced', column: label.startsWith('review') ? 'Done' : 'next', detail: 'ok' }
}

;(async () => {
  // #32 — a built card's QA prompt never carries the qa-card instruction.
  const a = await run([{ number: 7, status: 'Ready', title: 't', labels: ['feature'] }], base('medium'))
  QA_CARD.test(a.prompts['qa:#7']) && fail('QA after Build must not say the card is labelled qa')
  // A qa-labelled Ready card still gets it.
  const b = await run([{ number: 8, status: 'Ready', title: 't', labels: ['qa'] }], base('low'))
  QA_CARD.test(b.prompts['qa:#8']) || fail('a qa-labelled Ready card must get the qa-card instruction')

  // #33 — complexity survives every early exit.
  const c = await run([
    { number: 7, status: 'Ready', title: 't', labels: ['feature'] },   // fails QA
    { number: 9, status: 'Ready', title: 't', labels: ['feature'] },   // held by pre-flight
    { number: 10, status: 'Ready', title: 't', labels: ['bug'] },      // bounced in Build
    { number: 11, status: 'Review', title: 't', labels: ['bug'] },     // entered past Ready
  ], base('high', {
    'qa:#7': { status: 'bounced', column: 'Ready', detail: 'qa fail' },
    'build:#10': { status: 'bounced', column: 'Ready', detail: 'build fail' },
  }))
  const by = Object.fromEntries(c.out.cards.map((s) => [s.number, s]))
  ;[7, 9, 10].forEach((n) => by[n].complexity === 'high' || fail(`#${n} lost its complexity: ${by[n].complexity}`))
  by[11].complexity === null || fail('a card entering past Ready reports null complexity')
})().catch((e) => fail(e.stack))
JS
echo "PASS: test-wave-chain-status.sh (QA prompt per column; complexity on every exit)"
