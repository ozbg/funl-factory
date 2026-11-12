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
# cards and demo Done, no agent walk yet: not done (factory #108)
out=$(echo "$B2" | $PY status --repo-path "$T/full" --board-json -)
echo "$out" | grep -qF 'M1: 3/3 cards done · demo #20 Done · walk not run' || fail "walk pending line: $out"
SC="$T/full/docs/super-board/runs/scorecard.jsonl"; mkdir -p "$(dirname "$SC")"
echo '{"event":"walk","milestone":"M1","screens":4,"passed":3,"questions":5,"answered":5,"ok":false}' > "$SC"
out=$(echo "$B2" | $PY status --repo-path "$T/full" --board-json -)
echo "$out" | grep -qF 'M1: 3/3 cards done · demo #20 Done · walk failed: screens 3/4 · questions 5/5' || fail "walk failed line: $out"
echo '{"event":"walk-accept","milestone":"M1","note":"later"}' >> "$SC"
out=$(echo "$B2" | $PY status --repo-path "$T/full" --board-json -)
echo "$out" | grep -qF 'M1 done: all cards, demo #20 Done · walk findings accepted' || fail "accepted line: $out"
# a walk that passes, with an exam under its pass mark, still fails; a walk for another milestone doesn't count
echo '{"event":"walk","milestone":"M1","screens":4,"passed":4,"questions":5,"answered":5,"ok":true}' >> "$SC"
echo '{"event":"exam","milestone":"M1","card":18,"score":6,"total":10,"pass_mark":8}' >> "$SC"
out=$(echo "$B2" | $PY status --repo-path "$T/full" --board-json -)
echo "$out" | grep -qF 'walk failed: screens 4/4 · questions 5/5 · exam #18 6/10' || fail "exam gate: $out"
echo '{"event":"exam","milestone":"M1","card":18,"score":9,"total":10,"pass_mark":8}' >> "$SC"
out=$(echo "$B2" | $PY status --repo-path "$T/full" --board-json -)
echo "$out" | grep -qF 'M1 done: all cards, demo #20 Done · agent walk passed' || fail "done line: $out"
out=$(echo "$B2" | $PY status --repo-path "$T/full" --board-json - --milestone M2)
echo "$out" | grep -qF 'M2: 3/3 cards done · demo #20 Done · walk not run' || fail "other milestone: $out"
echo "$B2" | $PY status --repo-path "$T/full" --board-json - --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["milestone_done"] and d["walk"]=="passed" and d["mockup_cuts"] is None, d' || fail "walk json"
rm "$SC"
# cards done but demo not: not done
B3='[{"number":12,"status":"Done"},{"number":13,"status":"Done"},{"number":14,"status":"Done"},{"number":20,"status":"QA"}]'
out=$(echo "$B3" | $PY status --repo-path "$T/full" --board-json -)
echo "$out" | grep -qF 'M1: 3/3 cards done · demo #20 not run' || fail "demo pending line: $out"

# --- Cut from mock-up list in coverage.md (factory #104)
app cuts "$FULL"$'\n\nCut from mock-up:\n- #13 · screen-pipeline: source filter (#14) · archived restore (later.md)\n- #12 · screen-today: snooze'
printf '<section id="screen-pipeline"></section><section id="screen-today"></section>\n' > "$T/cuts/docs/shape/mockup.html"
out=$($PY lint --repo-path "$T/cuts") || fail "coverage with a cut list should pass lint: $out"
echo "$out" | grep -q 'Cut from mock-up' && fail "a present cut list must not warn: $out"
python3 - "$T/cuts" <<'PY' || fail "cut list parse"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cov", "scripts/super-board-coverage.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c = m.parse_coverage(open(sys.argv[1] + "/docs/shape/coverage.md").read())
assert c["cut_cards"] == [12, 13], c["cut_cards"]
assert len(c["cuts"]) == 2, c["cuts"]
assert m.count_cuts(c["cuts"]) == 3, m.count_cuts(c["cuts"])
assert m.count_cuts(["none"]) == 0 and m.count_cuts(None) is None
PY
# mock-up present, no cut list: warning only (old apps are not failed)
app nocuts "$FULL"
printf '<section id="screen-pipeline"></section>\n' > "$T/nocuts/docs/shape/mockup.html"
out=$($PY lint --repo-path "$T/nocuts") || fail "no cut list must still exit 0"
echo "$out" | grep -q 'warning: coverage.md has no `Cut from mock-up:` list' || fail "no cut list should warn: $out"
# no mock-up, no cut list: silent
out=$($PY lint --repo-path "$T/full")
echo "$out" | grep -q 'Cut from mock-up' && fail "no mock-up must not warn about cuts: $out"

# --- cards: every screen card carries its mock-up block (factory #104)
GOOD=$(cat <<'MD'
## Context
- **Where:** Prospects, `#/prospects`
- **Mock-up:** docs/shape/mockup.html#screen-pipeline

## Mock-up
- **Anchor:** docs/shape/mockup.html#screen-pipeline
- **Classes:** `table`, `pill`, `button.link`
- **Cut from mock-up:** source filter (#14)

```html
<table class="table"><tr><td><button class="link">Physio</button></td></tr></table>
```

## Acceptance Criteria
- [ ] typing "physio" leaves one row — test: tests/e2e/p.spec.ts
- [ ] screen matches mock-up `#screen-pipeline` (screenshot side by side) — test: QA screenshot

## Blocked by
- None.
MD
)
cards() { # cards <app> <json>: run the cards check, echo output, return its exit
  printf '%s' "$2" > "$T/issues.json"
  $PY cards --repo-path "$T/$1" --issues-json "$T/issues.json"
}
J() { python3 -c 'import json,sys; print(json.dumps([{"number":int(a.split("=",1)[0]),"title":"✨ [feat] t","body":a.split("=",1)[1]} for a in sys.argv[1:]]))' "$@"; }
out=$(cards cuts "$(J "13=$GOOD")") || fail "a full mock-up block should pass: $out"
echo "$out" | grep -q '1 card' || fail "cards summary: $out"

# a card with no Mock-up line is not a screen card
out=$(cards cuts "$(J $'40=## Context\n- **Files:** a.ts\n\n## Acceptance Criteria\n- [ ] x — test: a')") || fail "non-screen card must pass: $out"

# the Demo card is skipped by its title
DEMO=$(python3 -c 'import json; print(json.dumps([{"number":20,"title":"🧪 [test] demo: core loop end to end","body":"## Context\n- **Mock-up:** docs/shape/mockup.html#screen-today\n"}]))')
out=$(cards cuts "$DEMO") || fail "demo card must be skipped: $out"
# the Demo card without its own-instance line warns, never fails (factory #100, criterion 26)
echo "$out" | grep -qF 'warning: #20: Demo card has no `Decided:` line' || fail "demo without own instance should warn: $out"
DEMO_OK=$(python3 -c 'import json; print(json.dumps([{"number":20,"title":"🧪 [test] demo: core loop end to end","body":"## Context\n- **Mock-up:** docs/shape/mockup.html#screen-today\n- **Decided:** the demo runs its own app instance: its own port, a fresh temp data folder, the fake AI and a fixed date.\n"}]))')
out=$(cards cuts "$DEMO_OK") || fail "demo with own instance must pass: $out"
echo "$out" | grep -q 'warning' && fail "demo with own instance must not warn: $out"
# a non-demo card never gets the demo warning
out=$(cards cuts "$(J "13=$GOOD")")
echo "$out" | grep -q 'Decided' && fail "non-demo card must not get the demo warning: $out"
# the template carries the line, so a fresh Demo card passes
grep -q '^- \*\*Decided:\*\* the demo runs its own app instance' skills/to-board/references/card-template.md || fail "demo template lacks the own-instance line"

# each missing piece fails, with its own message
expect_fail() { # expect_fail <label> <message> <body>
  if out=$(cards cuts "$(J "13=$3")"); then fail "$1 should fail"; fi
  echo "$out" | grep -qF "$2" || fail "$1 message: $out"
}
expect_fail "no block" 'no `## Mock-up` block' $'## Context\n- **Mock-up:** docs/shape/mockup.html#screen-pipeline\n\n## Acceptance Criteria\n- [ ] x — test: a'
expect_fail "no anchor" 'no `Anchor:` line' "$(printf '%s' "$GOOD" | grep -v 'Anchor:')"
expect_fail "wrong anchor" 'differs from the Mock-up line' "${GOOD/\*\*Anchor:\*\* docs\/shape\/mockup.html#screen-pipeline/**Anchor:** docs/shape/mockup.html#screen-today}"
expect_fail "no classes" 'no class list' "$(printf '%s' "$GOOD" | grep -v 'Classes:')"
expect_fail "no excerpt" 'no markup excerpt' "$(printf '%s' "$GOOD" | grep -v -e '```' -e '<table')"
expect_fail "no cut line" 'no `Cut from mock-up:` line' "$(printf '%s' "$GOOD" | grep -v 'Cut from mock-up:')"
expect_fail "no match AC" 'no AC `screen matches mock-up `#screen-pipeline`' "$(printf '%s' "$GOOD" | grep -v 'matches mock-up')"
expect_fail "anchor not in mock-up" 'is not in docs/shape/mockup.html' "${GOOD//screen-pipeline/screen-ghost}"

# a vanilla-JS mock-up builds its ids from names: the token anywhere counts
printf '<script>for (const n of ["screen-lead"]) html += `<section id="${n}">`;</script>\n' >> "$T/cuts/docs/shape/mockup.html"
out=$(cards cuts "$(J "13=${GOOD//screen-pipeline/screen-lead}")") || fail "a JS-built screen id should count: $out"

# a cut not listed in coverage.md fails; `none` needs no coverage row
if out=$(cards cuts "$(J "15=$GOOD")"); then fail "unlisted cut should fail"; fi
echo "$out" | grep -q 'coverage.md' || fail "unlisted cut message: $out"
out=$(cards cuts "$(J "15=${GOOD/source filter (#14)/none}")") || fail "cut none needs no coverage row: $out"
# bad json is a usage error
printf 'nope' > "$T/bad.json"
set +e; $PY cards --repo-path "$T/cuts" --issues-json "$T/bad.json" 2>/dev/null; rc=$?; set -e
[ "$rc" = 64 ] || fail "bad issues json should exit 64, got $rc"

# briefs: the body-of-work gate (references/iteration.md, lint criterion 25)
B="$T/briefs"; mkdir -p "$B/docs/shape/briefs"
printf '# Brief: super brain\n\nSigned: 2026-11-12 · owner\n\n## What\nx\n' > "$B/docs/shape/briefs/2026-11-12-brain.md"
printf '# Brief: draft\n\nSigned: no\n' > "$B/docs/shape/briefs/2026-11-13-draft.md"
printf '# Brief: nosign\n\n## What\nx\n' > "$B/docs/shape/briefs/2026-11-14-nosign.md"
BJ() { python3 -c 'import json,sys; print(json.dumps([{"number":int(n),"title":"t","labels":l.split(",") if l else [],"body":b} for n,l,b in (a.split("=",2) for a in sys.argv[1:])]))' "$@" > "$T/b.json"; }
briefs() { $PY briefs --repo-path "$B" --issues-json "$T/b.json"; }
CTX=$'## Context\n- **Brief:** docs/shape/briefs/2026-11-12-brain.md\n\n## Fix\nx'
BJ "21=body-of-work=$CTX" "22==## Context\n- **Where:** x" "23=bug=no brief needed"
out=$(briefs) || fail "a signed brief, and cards that are not a body of work, pass: $out"
BJ "24=body-of-work=## Context\n- **Where:** x"
if out=$(briefs); then fail "body-of-work label with no Brief line should fail"; fi
echo "$out" | grep -qF '#24: body of work with no `Brief:' || fail "no-brief message: $out"
BJ "25==${CTX//brain/ghost}"
if out=$(briefs); then fail "a Brief line naming a missing file should fail"; fi
echo "$out" | grep -q 'not found' || fail "missing brief message: $out"
BJ "26=body-of-work=${CTX//2026-11-12-brain/2026-11-13-draft}" "27=body-of-work=${CTX//2026-11-12-brain/2026-11-14-nosign}"
if out=$(briefs); then fail "an unsigned brief should fail"; fi
echo "$out" | grep -q '#26: brief .* is not signed' && echo "$out" | grep -q '#27: brief .* is not signed' || fail "unsigned message: $out"
BJ "28=proposal,tweak=## Context\n- **Where:** x"
if out=$(briefs); then fail "a proposal in an active column should fail"; fi
echo "$out" | grep -q 'still a `proposal`' || fail "proposal message: $out"
BJ "29=body-of-work=${CTX//docs\/shape\/briefs\/2026-11-12-brain.md/..\/..\/etc\/x.md}"
if out=$(briefs); then fail "a brief outside the repo should fail"; fi

echo "PASS: test-coverage"
