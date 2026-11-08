// Run: node --test tests/github-read.test.cjs
// A fake `gh` prints FAKE_GH_OUT, so each case controls exactly what GitHub "returned".
const { test } = require('node:test')
const assert = require('node:assert')
const { spawnSync } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const HELPER = path.join(__dirname, "..", "scripts", "super-board-github-read.py")
const QUOTA = JSON.stringify({ resources: {
  graphql: { remaining: 4000, reset: 1 }, core: { remaining: 4000, reset: 1 } } })

function run(args, { out = '', err = '', code = 0, probe = 0, strict = false } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'github-read-test-'))
  const bin = path.join(dir, 'bin')
  fs.mkdirSync(bin)
  fs.writeFileSync(path.join(bin, 'gh'),
    '#!/bin/sh\nif [ "$1 $2" = "api repos/{owner}/{repo}" ]; then exit ${FAKE_PROBE_CODE:-0}; fi\nprintf "%s" "$FAKE_GH_OUT"\nprintf "%s" "$FAKE_GH_ERR" >&2\nexit ${FAKE_GH_CODE:-0}\n', { mode: 0o755 })
  const halt = path.join(dir, 'github-halt.json')
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, FAKE_GH_OUT: out, FAKE_GH_ERR: err, FAKE_GH_CODE: String(code), FAKE_PROBE_CODE: String(probe),
    SB_GITHUB_HALT_FILE: halt, SB_GITHUB_RETRY_DELAY: '0' }
  delete env.SB_GITHUB_READ_STRICT
  if (strict) env.SB_GITHUB_READ_STRICT = '1'
  const result = spawnSync('python3', [HELPER, ...args], { env, encoding: 'utf8' })
  return { code: result.status, stderr: result.stderr, halted: fs.existsSync(halt) }
}

test('a reshaped quota read fails that call only (64), with no run halt', () => {
  const r = run(['--kind', 'quota', '--', 'api', 'rate_limit', '--jq', '{graphql: .resources.graphql}'],
    { out: JSON.stringify({ graphql: { remaining: 1, reset: 1 } }) })
  assert.strictEqual(r.code, 64, r.stderr)
  assert.strictEqual(r.halted, false)
  assert.match(r.stderr, /the run continues/)
  assert.match(r.stderr, /--jq/)
})

test('reshaping with -q or --template is treated the same way', () => {
  for (const flag of [['-q', '.resources'], ['--template', '{{.}}'], ['--jq=.resources']]) {
    const r = run(['--kind', 'quota', '--', 'api', 'rate_limit', ...flag], { out: '{}' })
    assert.strictEqual(r.code, 64, `${flag}: ${r.stderr}`)
    assert.strictEqual(r.halted, false, String(flag))
  }
})

test('a raw quota read that passes its shape still succeeds', () => {
  const r = run(['--kind', 'quota', '--', 'api', 'rate_limit'], { out: QUOTA })
  assert.strictEqual(r.code, 0, r.stderr)
})

test('a raw read GitHub answers with the wrong shape fails that call only (64); STRICT callers still halt', () => {
  const r = run(['--kind', 'quota', '--', 'api', 'rate_limit'], { out: '{}' })
  assert.strictEqual(r.code, 64, r.stderr)
  assert.strictEqual(r.halted, false)
})

test('fixed-command scripts (STRICT) keep halting on a reshaped read', () => {
  const r = run(['--kind', 'quota', '--', 'api', 'rate_limit', '--jq', '.x'], { out: '{}', strict: true })
  assert.strictEqual(r.code, 79, r.stderr)
  assert.strictEqual(r.halted, true)
})

test('a --jq that produces the expected shape is still allowed', () => {
  const r = run(['--kind', 'body', '--', 'api', 'repos/{owner}/{repo}/pulls/1', '--jq', '{headRefOid: .head.sha, body}'],
    { out: JSON.stringify({ headRefOid: 'a'.repeat(40), body: '' }) })
  assert.strictEqual(r.code, 0, r.stderr)
})

test('agent-facing kinds keep their existing 64 on a wrong shape', () => {
  const r = run(['--kind', 'comments', '--', 'api', 'repos/{owner}/{repo}/issues/1/comments'], { out: '{}' })
  assert.strictEqual(r.code, 64, r.stderr)
  assert.strictEqual(r.halted, false)
})

test('a gh usage error (bad flag) fails that call only (64), with no run halt', () => {
  for (const err of ['unknown flag: --json\n\nUsage:  gh api <endpoint> [flags]',
                     'unknown shorthand flag: \'z\' in -z', 'accepts 1 arg(s), received 2']) {
    const r = run(['--kind', 'json', '--', 'api', 'repos/{owner}/{repo}/pulls/22', '--json', 'base,head'], { err, code: 1 })
    assert.strictEqual(r.code, 64, `${err}: ${r.stderr}`)
    assert.strictEqual(r.halted, false, err)
    assert.match(r.stderr, /the run continues/)
  }
})

test('an unknown --json field fails that call only (64)', () => {
  const r = run(['--kind', 'json', '--', 'pr', 'view', '22', '--json', 'state,merged'],
    { err: 'Unknown JSON field: "merged"\nAvailable fields:\n  mergedAt', code: 1 })
  assert.strictEqual(r.code, 64, r.stderr)
  assert.strictEqual(r.halted, false)
})

test('a malformed --jq filter fails that call only (64), with no run halt', () => {
  const r = run(['--kind', 'head', '--', 'pr', 'view', '38', '--json', 'headRefName,headRefOid', '--jq', '".headRefName + " " + .headRefOid"'],
    { err: 'failed to parse jq expression (line 1, column 19)\n    ".headRefName + " " + .headRefOid"', code: 1 })
  assert.strictEqual(r.code, 64, r.stderr)
  assert.strictEqual(r.halted, false)
})

test('any kind whose payload has the wrong shape fails that call only (64)', () => {
  const r = run(['--kind', 'approval', '--', 'pr', 'view', '50', '--json', 'body,headRefOid'],
    { out: '{"body":"x","headRefOid":"abc"}', code: 0 })
  assert.strictEqual(r.code, 64, r.stderr)
  assert.strictEqual(r.halted, false)
})

test('a usage error is not retried', () => {
  const r = run(['--kind', 'json', '--', 'api', 'x', '--json', 'a'], { err: 'unknown flag: --json', code: 1 })
  assert.doesNotMatch(r.stderr, /retry 2\/3/)
})

test('a real GitHub failure (5xx) still retries and halts (79)', () => {
  const r = run(['--kind', 'json', '--', 'api', 'x'], { err: 'HTTP 502: Bad Gateway', code: 1 })
  assert.strictEqual(r.code, 79, r.stderr)
  assert.strictEqual(r.halted, true)
})

test('a 404 on a wrong endpoint inside a readable repo fails that call only (64)', () => {
  const r = run(['--kind', 'json', '--', 'api', 'repos/{owner}/{repo}/pulls/22/comments/45'],
    { err: 'gh: Not Found (HTTP 404)', code: 1, probe: 0 })
  assert.strictEqual(r.code, 64, r.stderr)
  assert.strictEqual(r.halted, false)
  assert.match(r.stderr, /the run continues/)
})

test('a missing PR or issue number fails that call only (64)', () => {
  const r = run(['--kind', 'body', '--', 'pr', 'view', '9999', '--json', 'body,headRefOid'],
    { err: 'GraphQL: Could not resolve to a PullRequest with the number of 9999.', code: 1, probe: 0 })
  assert.strictEqual(r.code, 64, r.stderr)
  assert.strictEqual(r.halted, false)
})

test('a 404 when the repo itself is unreadable still halts (79)', () => {
  const r = run(['--kind', 'json', '--', 'api', 'repos/{owner}/{repo}/pulls/22'],
    { err: 'gh: Not Found (HTTP 404)', code: 1, probe: 1 })
  assert.strictEqual(r.code, 79, r.stderr)
  assert.strictEqual(r.halted, true)
})

test('a 401 still halts (79)', () => {
  const r = run(['--kind', 'json', '--', 'api', 'repos/{owner}/{repo}/pulls/22'],
    { err: 'gh: Requires authentication (HTTP 401)', code: 1, probe: 0 })
  assert.strictEqual(r.code, 79, r.stderr)
})
