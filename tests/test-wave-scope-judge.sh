#!/usr/bin/env bash
# The scope judge step in workflows/super-board-wave.js (factory #148). A read-only
# Sonnet agent judges each scope:pending card and the workflow returns its verdicts
# for the orchestrator to `admit`. No gh calls: agent stubbed.
set -euo pipefail
cd "$(dirname "$0")"

node - ../workflows/super-board-wave.js <<'JS'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1) }
const eq = (a, b, m) => JSON.stringify(a) === JSON.stringify(b) || fail(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`)

const run = async (args, judge) => {
  const calls = []
  const logs = []
  const agent = async (prompt, opts) => {
    calls.push({ prompt, opts })
    if (opts.label.startsWith('scope-judge')) return judge(prompt, opts)
    return { status: 'advanced', column: 'Done', detail: 'ok', citation: 'none' }
  }
  const pipeline = async (items, ...stages) => Promise.all(items.map(async (it) => {
    let v = it
    for (const [i, st] of stages.entries()) v = i === 0 ? await st(it) : await st(v, it)
    return v
  }))
  const out = await new AsyncFunction('args', 'agent', 'pipeline', 'log', src)(
    { configPath: 'c.json', cards: [], ...args }, agent, pipeline, (m) => logs.push(m))
  return { out, calls, logs }
}
const pend = (cards, over = {}) => ({ goal: 'M2', frozen: [{ number: 10, title: 'Quotes' }], profile: true, cards, ...over })
const card = (n) => ({ number: n, title: `card ${n}`, labels: ['bug'], body: '## Problem\nx\n' })
const v = (card, verdict, citation, over = {}) => ({ card, verdict, kind: 'data-loss', citation, reason: 'r', cost_of_waiting: 'c', owner_call: null, split: null, route: null, ...over })

;(async () => {
  // 1 — no scope:pending cards: no judge, the result has no scope block (today's shape).
  const a = await run({})
  a.calls.some((c) => c.opts.label.startsWith('scope-judge')) && fail('no pending cards → no judge')
  eq(Object.keys(a.out), ['cards', 'halted'], 'result shape without pending cards')

  // 2 — the judge runs on Sonnet, read-only, sees only the stripped cards, and each verdict is recorded.
  const b = await run({ scopePending: pend([card(191), card(176), card(172)]) }, () => ({
    verdicts: [v(191, 'gate', 'must-have 4'), v(176, 'next', 'none'), v(172, 'drop', 'taste')],
  }))
  const j = b.calls.filter((c) => c.opts.label.startsWith('scope-judge'))
  eq(j.length, 1, 'one batched judge call')
  eq(j[0].opts.model, 'sonnet', 'judge model')
  eq(j[0].opts.phase, 'Scope judge', 'judge phase')
  ;/scope-judge\.md/.test(j[0].prompt) || fail('judge reads references/scope-judge.md')
  ;/Read only/.test(j[0].prompt) || fail('judge is read-only')
  ;/Never read a card on GitHub/.test(j[0].prompt) || fail('judge never sees the card thread')
  ;/Never count against the growth cap/.test(j[0].prompt) || fail('code counts the cap, never the judge')
  eq(b.out.scope.verdicts.map((x) => [x.card, x.verdict]), [[191, 'gate'], [176, 'next'], [172, 'drop']], 'verdicts recorded')
  eq(b.out.scope.gates, [191], 'gates for admit')
  eq(b.out.scope.drops, [172], 'drops for the owner digest')
  eq(b.out.scope.ran, true, 'judge ran')
  b.logs.some((l) => l.startsWith('scope-verdict: #191 gate')) || fail('each verdict is logged')

  // 3 — a gate with no citation is read as next; an owner call is never a plain gate; a stray card is ignored.
  const c = await run({ scopePending: pend([card(1), card(2)]) }, () => ({
    verdicts: [v(1, 'gate', 'none'), v(2, 'gate', 'I4', { owner_call: 'loosen I4?' }), v(99, 'gate', 'must-have 1')],
  }))
  eq(c.out.scope.verdicts.map((x) => [x.card, x.verdict]), [[1, 'next'], [2, 'gate']], 'uncited gate → next; stray card dropped')
  eq(c.out.scope.gates, [], 'an owner-call gate is not admitted by the judge')
  eq(c.out.scope.ownerCalls, [2], 'owner calls listed')

  // 4 — batches of six; a card with no verdict is reported missing.
  const many = Array.from({ length: 8 }, (_, i) => card(i + 1))
  const d = await run({ scopePending: pend(many) }, (prompt) => ({
    verdicts: many.filter((x) => prompt.includes(`"number":${x.number},`) && x.number !== 8).map((x) => v(x.number, 'next', 'none')),
  }))
  eq(d.calls.filter((x) => x.opts.label.startsWith('scope-judge')).length, 2, 'two batches for eight cards')
  eq(d.out.scope.missing, [8], 'missing verdicts named')

  // 5 — no fit-for-purpose profile: the judge never runs.
  const e = await run({ scopePending: pend([card(5)], { profile: false }) }, () => fail('judge ran without a profile'))
  eq(e.out.scope.ran, false, 'not run without a profile')
  eq(e.out.scope.missing, [5], 'card still pending')

  // 6 — the judge refuses (its own profile check): not ran, error kept.
  const f = await run({ scopePending: pend([card(6)]) }, () => ({ error: 'no fit-for-purpose profile', verdicts: [] }))
  eq(f.out.scope.ran, false, 'judge error → not ran')
  ;/fit-for-purpose/.test(f.out.scope.detail) || fail('error kept in detail')

  console.log('PASS: test-wave-scope-judge.sh (6 scenarios)')
})().catch((e) => fail(e.stack || String(e)))
JS
