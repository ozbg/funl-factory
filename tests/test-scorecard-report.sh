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
echo "$out" | grep -q '^AI exams: n/a' || fail "no exams: $out"
echo "$out" | grep -q 'n/a exams at pass mark: n/a vs all' || fail "exam target n/a: $out"

# AI exams: the latest run per card counts; one under its pass mark fails the target
$PY exam --card 4 --score 6 --total 10 --pass-mark 8 --model claude-sonnet-4-5 --milestone M1 --scorecard "$SC" >/dev/null
$PY exam --card 4 --score 9 --total 10 --pass-mark 8 --model claude-sonnet-4-5 --milestone M1 --scorecard "$SC" >/dev/null
$PY exam --card 5 --score 10 --total 12 --pass-mark 10 --model claude-sonnet-4-5 --scorecard "$SC" >/dev/null
out=$($PY report --config "$CFG" --repo-path "$APP")
echo "$out" | grep -q '^AI exams: #4 9/10 (pass 8) claude-sonnet-4-5 · #5 10/12 (pass 10) claude-sonnet-4-5' || fail "exams line: $out"
echo "$out" | grep -q '✅ exams at pass mark: 2/2 vs all' || fail "exam target pass: $out"
$PY exam --card 5 --score 7 --total 12 --pass-mark 10 --model claude-sonnet-4-5 --scorecard "$SC" >/dev/null
out=$($PY report --config "$CFG" --repo-path "$APP")
echo "$out" | grep -q '❌ exams at pass mark: 1/2 vs all' || fail "exam target fail: $out"
echo "$out" | grep -q 'fix the spec, not the prompt' || fail "exam next step: $out"
if $PY exam --card 4 --score 9 --total 10 --pass-mark 8 --model fake-model --scorecard "$SC" 2>/dev/null; then fail "fake model accepted"; fi

# Product targets (factory #108): screens match, agent walk, mock-up cuts
echo "$out" | grep -q '^Done: .* · milestone not done: walk not run' || fail "milestone gate without walk: $out"
echo "$out" | grep -q 'n/a screens match: n/a vs ≥ 100%' || fail "screens n/a: $out"
echo "$out" | grep -q 'n/a walk pass: n/a vs ≥ 100%' || fail "walk n/a: $out"
echo "$out" | grep -q 'ℹ mock-up cuts: n/a (no target)' || fail "cuts n/a: $out"
echo "$out" | grep -q 'run the agent walk' || fail "walk next step: $out"
printf '\nCut from mock-up:\n- #1 · screen-today: snooze, bulk edit · archive (later.md)\n' >> "$APP/docs/shape/coverage.md"
$PY screen --card 1 --screen screen-today --failed --milestone M1 --scorecard "$SC" >/dev/null
$PY screen --card 1 --screen screen-today --passed --milestone M1 --scorecard "$SC" >/dev/null
$PY screen --card 2 --screen screen-pipeline --failed --milestone M1 --scorecard "$SC" >/dev/null
SHOTS="$APP/docs/super-board/runs/2026-11-12-walk"; mkdir -p "$SHOTS"
touch "$SHOTS/screen-today.png" "$SHOTS/screen-pipeline.png"
printf -- '- screen-pipeline: stage headers off the mock-up\n' > "$SHOTS/findings.md"
$PY walk --screens 2 --passed 1 --questions 3 --answered 3 --shots "$SHOTS" --findings "$SHOTS/findings.md" --milestone M1 --scorecard "$SC" >/dev/null
out=$($PY report --config "$CFG" --repo-path "$APP")
echo "$out" | grep -q '❌ screens match: 1/2 (50%) vs ≥ 100%' || fail "screens fail: $out"
echo "$out" | grep -q '❌ walk pass: 80% · screens 1/2 · questions 3/3 vs ≥ 100%' || fail "walk fail: $out"
echo "$out" | grep -q 'ℹ mock-up cuts: 3 (no target)' || fail "cuts count: $out"
echo "$out" | grep -q "milestone not done: walk failed: screens 1/2 · questions 3/3 · exam #5 7/12" || fail "gate on failed walk: $out"
$PY walk --accepted --note "stage headers move to M2" --milestone M1 --scorecard "$SC" >/dev/null
out=$($PY report --config "$CFG" --repo-path "$APP")
echo "$out" | grep -q '^Done: .* · milestone done' || fail "accepted findings close the milestone: $out"
echo "$out" | grep -q 'walk pass: 80% · screens 1/2 · questions 3/3 · findings accepted' || fail "accepted walk line: $out"

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
assert d["targets_met"]["exam_pass"] is False and len(d["exams"]) == 2, d
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
