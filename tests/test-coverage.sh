#!/usr/bin/env bash
# super-board-coverage.py: lint and status over fixture apps.
set -euo pipefail
cd "$(dirname "$0")/.."
PY="python3 scripts/super-board-coverage.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

app() { # app <name> <coverage body or ->
  mkdir -p "$T/$1/docs/shape"
  printf '# North star\n\n## Must have\n\n1. First\n2. Second\n\n## Out of scope\n\n3. Not a must-have\n' > "$T/$1/docs/shape/north-star.md"
  [ "$2" = "-" ] || printf '%s\n' "$2" > "$T/$1/docs/shape/coverage.md"
}
FULL=$'| Must-have | Cards |\n|---|---|\n| 1 | #12, #13 |\n| 2 | #14 |\n\nDemo: #20'

# full coverage
app full "$FULL"
$PY lint --repo-path "$T/full" >/dev/null || fail "full coverage should pass lint"

# a must-have with no row, and one with an empty Cards cell
app norow $'| Must-have | Cards |\n|---|---|\n| 1 | #12 |\n\nDemo: #20'
out=$($PY lint --repo-path "$T/norow" || true)
$PY lint --repo-path "$T/norow" >/dev/null && fail "no row should fail lint"
echo "$out" | grep -q 'must-have 2 has no row' || fail "no-row message: $out"
app empty $'| Must-have | Cards |\n|---|---|\n| 1 | #12 |\n| 2 |  |\n\nDemo: #20'
$PY lint --repo-path "$T/empty" >/dev/null && fail "empty Cards cell should fail lint"

# missing Demo
app nodemo $'| Must-have | Cards |\n|---|---|\n| 1 | #12 |\n| 2 | #14 |'
out=$($PY lint --repo-path "$T/nodemo" || true)
$PY lint --repo-path "$T/nodemo" >/dev/null && fail "missing Demo should fail lint"
echo "$out" | grep -q 'Demo' || fail "demo message: $out"

# missing coverage.md: warning, exit 0
app none -
out=$($PY lint --repo-path "$T/none") || fail "missing coverage.md must exit 0"
echo "$out" | grep -qi 'warning' || fail "missing coverage.md should warn: $out"
[ -z "$($PY status --repo-path "$T/none" --board-json <(echo '[]'))" ] || fail "status must be silent without coverage.md"

# row for a number not in the north star: warning only
app extra $'| Must-have | Cards |\n|---|---|\n| 1 | #12 |\n| 2 | #14 |\n| 9 | #15 |\n\nDemo: #20'
out=$($PY lint --repo-path "$T/extra") || fail "unknown row is a warning, not a failure"
echo "$out" | grep -q 'row 9' || fail "unknown row warning: $out"

# status: not done
B1='[{"number":12,"status":"Done"},{"number":13,"status":"Done"},{"number":14,"status":"Building"},{"number":20,"status":"Ready"}]'
out=$(echo "$B1" | $PY status --repo-path "$T/full" --board-json -)
echo "$out" | grep -q '^must-have 1: 2/2 done' || fail "must-have 1 line: $out"
echo "$out" | grep -q '^must-have 2: 0/1 done' || fail "must-have 2 line: $out"
echo "$out" | grep -qF 'M1: 2/3 cards done · demo #20 not run' || fail "milestone line: $out"
echo "$B1" | $PY status --repo-path "$T/full" --board-json - --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d["milestone_done"] and d["cards_total"]==3' || fail "json output"

# status: all done
B2='[{"number":12,"status":"Done"},{"number":13,"status":"Done"},{"number":14,"status":"Done"},{"number":20,"status":"Done"}]'
out=$(echo "$B2" | $PY status --repo-path "$T/full" --board-json -)
echo "$out" | grep -qF 'M1 done: all cards and demo #20 Done' || fail "done line: $out"
# cards done but demo not: not done
B3='[{"number":12,"status":"Done"},{"number":13,"status":"Done"},{"number":14,"status":"Done"},{"number":20,"status":"QA"}]'
out=$(echo "$B3" | $PY status --repo-path "$T/full" --board-json -)
echo "$out" | grep -qF 'M1: 3/3 cards done · demo #20 not run' || fail "demo pending line: $out"

echo "PASS: test-coverage"
