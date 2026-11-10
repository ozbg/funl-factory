#!/usr/bin/env bash
# super-board-scorecard.py report: targets, log, compare and n/a handling over fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
PY="python3 scripts/super-board-scorecard.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

APP="$T/charter-hub"
mkdir -p "$APP/docs/shape" "$APP/docs/super-board/runs"
printf '# North star\n\n## Must have\n\n1. First\n2. Second\n' > "$APP/docs/shape/north-star.md"
printf 'Signed: 2026-11-01 · depth: product · questions: 9 · minutes: 17\nMock-up: 2026-11-02 · picked: B · postcard: yes\n' >> "$APP/docs/shape/north-star.md"
printf '{"date":"2026-11-01","questions":9,"minutes":17,"blind_match":4}\n' > "$APP/docs/shape/north-star-log.jsonl"
printf '| Must-have | Cards |\n|---|---|\n| 1 | #1, #2 |\n| 2 | #3 |\n\nDemo: #3\n' > "$APP/docs/shape/coverage.md"
SC="$APP/docs/super-board/runs/scorecard.jsonl"
cat > "$SC" <<'J'
{"card":1,"milestone":"M1","at":"2026-11-01T10:00:00Z","minutes":60,"tokens":40000,"usd":10,"column":"Building","lanesRun":"build:advanced","modelRules":{"low-haiku":1}}
{"card":1,"milestone":"M1","at":"2026-11-02T10:00:00Z","minutes":30,"tokens":20000,"usd":5,"column":"Done","lanesRun":"build:advanced → qa:advanced → review:advanced","score":{"verdict":"clean","round":1,"cause":"none"},"modelRules":{"low-haiku":1}}
{"card":2,"milestone":"M1","at":"2026-11-02T12:00:00Z","minutes":60,"tokens":60000,"usd":12,"column":"Done","lanesRun":"build:advanced → review:bounced → build:advanced → review:advanced","score":{"verdict":"fixes","round":2,"cause":"ticket"}}
{"card":3,"milestone":"M1","at":"2026-11-03T00:00:00Z","minutes":30,"tokens":30000,"usd":4,"column":"Done","lanesRun":"build:advanced → review:advanced","score":{"verdict":"clean","round":1,"cause":"none"}}
J
CFG="$T/cfg.json"
echo '{"goal":{"milestone":"M1","budget_usd":60}}' > "$CFG"

out=$($PY report --config "$CFG" --repo-path "$APP")
echo "$out" | grep -q '^charter-hub M1' || fail "header: $out"
echo "$out" | grep -q '^Define: north star 17 min · 9 questions · blind match 4/5 · mock-up signed yes' || fail "define: $out"
echo "$out" | grep -q '^Build: 1.6 days · 3/3 merged · first pass 67% · rework 0% · 1.33 rounds per merge' || fail "build: $out"
echo "$out" | grep -q 'models by rule low-haiku ×2' || fail "rules: $out"
echo "$out" | grep -q '^Cost: \$31 of \$60' || fail "cost: $out"
echo "$out" | grep -q '^Done: must-have 1 2/2 · must-have 2 1/1 · demo passed' || fail "done: $out"
echo "$out" | grep -q '❌ first pass: 67% vs ≥ 70%' || fail "default first pass target: $out"
echo "$out" | grep -q '✅ rework: 0% vs ≤ 10%' || fail "rework target: $out"
echo "$out" | grep -q '✅ rounds per merge: 1.33 vs ≤ 1.5' || fail "rounds target: $out"
echo "$out" | grep -q '✅ demo first try: yes vs yes' || fail "demo target: $out"
echo "$out" | grep -q 'sharpen tickets: most bounces cite ticket' || fail "next: $out"

# config targets override defaults
echo '{"goal":{"milestone":"M1","budget_usd":60},"targets":{"first_pass_pct":60,"days_per_app":1}}' > "$T/cfg2.json"
out=$($PY report --config "$T/cfg2.json" --repo-path "$APP")
echo "$out" | grep -q '✅ first pass: 67% vs ≥ 60%' || fail "override first pass: $out"
echo "$out" | grep -q '❌ days: 1.6 vs ≤ 1' || fail "override days: $out"

# --log appends exactly one valid line; --compare prints one row per line
LOG="$APP/docs/super-board/factory-log.jsonl"
$PY report --config "$CFG" --repo-path "$APP" --log >/dev/null
[ "$(wc -l < "$LOG")" -eq 1 ] || fail "log should have one line"
python3 - "$LOG" <<'P' || fail "log line shape"
import json, sys
d = json.loads(open(sys.argv[1]).read())
for k in "date app milestone days merged total first_pass_pct rework_pct rounds_per_merge usd budget_usd demo_passed postcard targets_met".split():
    assert k in d, k
assert d["app"] == "charter-hub" and d["postcard"] is True and d["targets_met"]["first_pass_pct"] is False
P
$PY report --config "$T/cfg2.json" --repo-path "$APP" --log >/dev/null
[ "$(wc -l < "$LOG")" -eq 2 ] || fail "log should have two lines"
cmp=$($PY report --compare --repo-path "$APP")
[ "$(echo "$cmp" | wc -l)" -eq 3 ] || fail "compare: header plus one row per line: $cmp"
echo "$cmp" | grep -q 'charter-hub' || fail "compare row: $cmp"
out=$($PY report --compare --repo-path "$T/none")
echo "$out" | grep -q 'n/a' || fail "compare with no log: $out"

# --json prints valid JSON
$PY report --config "$CFG" --repo-path "$APP" --json | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "json"

# missing coverage.md and north-star log: n/a, no crash
rm "$APP/docs/shape/coverage.md" "$APP/docs/shape/north-star-log.jsonl"
out=$($PY report --config "$CFG" --repo-path "$APP") || fail "crashed without coverage/log"
echo "$out" | grep -q '^Define: north star n/a min · n/a questions · blind match n/a' || fail "define n/a: $out"
echo "$out" | grep -q '^Done: n/a · demo n/a' || fail "done n/a: $out"
echo "$out" | grep -q 'n/a demo first try' || echo "$out" | grep -q 'demo first try: n/a' || fail "demo target n/a: $out"

# no scorecard at all: still no crash
out=$($PY report --config "$CFG" --repo-path "$T/empty") || fail "crashed on empty repo"
echo "$out" | grep -q '^Build: n/a days' || fail "empty build: $out"
echo "PASS: test-scorecard-report.sh"
