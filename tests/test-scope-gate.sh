#!/usr/bin/env bash
# The scope gate (factory #148): super-board-scope.sh freeze / admit / status / pending /
# profile, the wave planner's refusal of an unadmitted goal card, and the collect filer's
# refusal of the goal milestone. Offline: board items and issues are fixtures, gh is a stub.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCOPE="$ROOT/scripts/super-board-scope.sh"
PLAN="$ROOT/scripts/super-board-wave-plan.sh"
FILE="$ROOT/skills/super-collect/scripts/super-collect-file.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export SB_GITHUB_HALT_FILE="$WORK/halt.json" SB_GITHUB_RETRY_DELAY=0 SB_SCOPE_NOW=2026-11-13T00:00:00Z

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "no: $3" "found it" ;; *) ok "$1" ;; esac; }

# --- an app: north star with the profile, spec with invariants ---------------------
APP="$WORK/app"; mkdir -p "$APP/docs/shape" "$APP/docs/agents"
cat > "$APP/docs/shape/north-star.md" <<'MD'
# funl: north star

Signed: 2026-11-01 · depth: product

## Fit for purpose
- Users: one, the owner, a solo founder.
- Runs on: the owner's Mac, started with `npm start`.
- Reach: 127.0.0.1 only (I6).
- Holds: the owner's charter, prospects and quotes. No payments, no health data.
- Worst case: a note is lost. A quote goes out with a wrong figure.
- Matters most: nothing lost; privacy by tier; money figures that are right.
- Matters least: uptime, pixel match with the mock-up.
- Budget: $300 a milestone.
- Scale: one user, hundreds of prospects.
- Stage: mvp.

## Must have
1. Charter. - why: x
4. Docs and price sheets. - why: y

## Day-one questions
- M1: who do I call first? → the ranked list
- M4: what did I quote Dr Tan? → $750 and the date

## Must never
- lose a note
MD
printf '# Spec\n\n## Invariants\n- I4: secure tier never sends contact details out.\n- I8: never bluff.\n' > "$APP/docs/shape/spec.md"
printf 'app_class: personal\n' > "$APP/docs/agents/zones.yaml"

CFG="$WORK/config.json"
cat > "$CFG" <<JSON
{"version":1,"project":{"owner":"acme","title":"Board","number":7},"repo":{"path":"$APP","remote":"https://github.com/acme/app.git"},
 "verify_commands":["git diff --check"],"ramp":{"stage":6},"goal":{"milestone":"M2"}}
JSON
cp "$CFG" "$WORK/config.fresh.json"

# Board: #20–#23 on M2 at the freeze (#23 Done, so not frozen); #30 on M3.
item() { printf '{"status":"%s","milestone":{"title":"%s"},"content":{"type":"Issue","number":%s,"title":"card %s","assignees":[]}}' "$1" "$2" "$3" "$3"; }
printf '{"items":[%s,%s,%s,%s,%s]}' "$(item Ready M2 20)" "$(item Backlog M2 21)" "$(item Ready M2 22)" \
  "$(item Done M2 23)" "$(item Ready M3 30)" > "$WORK/items.json"
DEPS="$WORK/deps.json"
jq -n '[20,21,22,24,25,30] | map({key: tostring, value: {runnable: true, parseable: true, acs: 2, mustHave: [1], files: ["src/\(.)/"]}}) | from_entries' > "$DEPS"

verdict() { # card verdict citation [extra jq]
  jq -n --argjson c "$1" --arg v "$2" --arg cite "$3" '{card: $c, verdict: $v, kind: "data-loss", citation: $cite,
    reason: "One click strips the price line.", cost_of_waiting: "The owner cannot trust Fix the doc.",
    owner_call: null, split: null, route: null, unfinished: null}' | jq "${4:-.}" > "$WORK/v-$1.json"
  echo "$WORK/v-$1.json"
}
admit() { "$SCOPE" admit "$@" --config "$CFG" 2>"$WORK/err"; }

echo "── freeze"
OUT=$("$SCOPE" freeze --config "$CFG" --items "$WORK/items.json")
is  "freeze records the goal's open cards" "frozen|M2|3 cards|cap 1" "$OUT"
is  "goal.scope.issues" "[20,21,22]" "$(jq -c '.goal.scope.issues' "$CFG")"
is  "frozenAt recorded" "2026-11-13T00:00:00Z" "$(jq -r '.goal.scope.frozenAt' "$CFG")"
OUT=$("$SCOPE" freeze --config "$CFG" --items "$WORK/items.json")
has "a second freeze keeps the first" "$OUT" "frozen|M2|3 cards|since"

echo "── the planner refuses a goal card added after the freeze"
printf '{"items":[%s,%s,%s]}' "$(item Ready M2 20)" "$(item Ready M2 24)" "$(item Ready M3 30)" > "$WORK/items2.json"
OUT=$("$PLAN" --config "$CFG" --items "$WORK/items2.json" --deps "$DEPS")
is  "frozen #20 runs" "[20]" "$(echo "$OUT" | jq -c '[.cards[].number]')"
is  "late #24 refused with the scope reason" "not in the frozen scope; the scope judge has not admitted it" \
    "$(echo "$OUT" | jq -r '.refused[] | select(.number == 24) | .reason')"
is  "off-goal #30 stays off-goal, not refused" "[30]" "$(echo "$OUT" | jq -c '[.offGoal[].number]')"

echo "── admit with a valid judge verdict"
is "admit without a frozen scope refuses" 65 "$("$SCOPE" admit 24 --config "$WORK/config.fresh.json" --verdict-file "$(verdict 24 gate 'must-have 4')" >/dev/null 2>&1; echo $?)"
OUT=$(admit 24 --verdict-file "$(verdict 24 gate 'must-have 4')")
is  "valid gate admitted" "admitted|#24|judge|must-have 4" "$OUT"
OUT=$("$PLAN" --config "$CFG" --items "$WORK/items2.json" --deps "$DEPS")
is  "admitted #24 now runs" "[20,24]" "$(echo "$OUT" | jq -c '[.cards[].number] | sort')"
is  "admitting twice is a no-op" "in-scope|#24" "$(admit 24 --verdict-file "$WORK/v-24.json")"

echo "── citations"
is  "no citation refused"          65 "$(admit 25 --verdict-file "$(verdict 25 gate none)" >/dev/null; echo $?)"
has "no citation names why"        "$(cat "$WORK/err")" "no citation"
is  "must-have not in the north star refused" 65 "$(admit 25 --verdict-file "$(verdict 25 gate 'must-have 9')" >/dev/null; echo $?)"
is  "day-one past the list refused" 65 "$(admit 25 --verdict-file "$(verdict 25 gate 'day-one Q3')" >/dev/null; echo $?)"
is  "unknown invariant refused"   65 "$(admit 25 --verdict-file "$(verdict 25 gate 'I9')" >/dev/null; echo $?)"
is  "harm on no profile line refused" 65 "$(admit 25 --verdict-file "$(verdict 25 gate 'harm: Brand, the logo is off')" >/dev/null; echo $?)"
has "harm refusal names the profile" "$(cat "$WORK/err")" "matches no line of ## Fit for purpose"
is  "harm with no event refused"   65 "$(admit 25 --verdict-file "$(verdict 25 gate 'harm: Worst case')" >/dev/null; echo $?)"
is  "a next verdict is not admitted" 65 "$(admit 25 --verdict-file "$(verdict 25 next none)" >/dev/null; echo $?)"
is  "a verdict for another card refused" 65 "$(admit 25 --verdict-file "$(verdict 26 gate 'must-have 4')" >/dev/null; echo $?)"
is  "a bad kind refused" 65 "$(admit 25 --verdict-file "$(verdict 25 gate 'must-have 4' '.kind = "vibes"')" >/dev/null; echo $?)"

echo "── the growth cap (3 frozen → cap 1, used by #24)"
is  "past the cap a judge gate is refused" 65 "$(admit 25 --verdict-file "$(verdict 25 gate 'harm: Worst case, wrong figure: two margins on one quote')" >/dev/null; echo $?)"
has "the refusal goes to the owner" "$(cat "$WORK/err")" "past the growth cap (1 of 1 used)"
OUT=$(admit 25 --verdict-file "$WORK/v-25.json" --owner "yes, build it")
is  "past the cap the owner admits" "admitted|#25|owner|harm: Worst case, wrong figure: two margins on one quote" "$OUT"
is  "the owner's words are recorded" "yes, build it" "$(jq -r '.goal.scope.admitted[] | select(.number == 25) | .words' "$CFG")"
is  "--owner alone is always accepted" "admitted|#26|owner|M2 needs it" "$(admit 26 --owner "M2 needs it")"
OUT=$(admit 27 --verdict-file "$(verdict 27 gate 'day-one Q2' '.unfinished = 20')")
is  "a frozen card's failed AC is outside the cap" "admitted|#27|judge|day-one Q2" "$OUT"
is  "unfinished must name a frozen card" 65 "$(admit 28 --verdict-file "$(verdict 28 gate 'I8' '.unfinished = 99')" >/dev/null; echo $?)"

echo "── owner_call holds the card for the owner"
is  "owner_call without --owner refused" 65 "$(admit 29 --verdict-file "$(verdict 29 gate 'I4' '.owner_call = "Loosen I4 for typed prices?"')" >/dev/null; echo $?)"
has "names the owner's question" "$(cat "$WORK/err")" "Loosen I4 for typed prices?"
is  "owner_call with --owner admitted" "admitted|#29|owner|I4" "$(admit 29 --verdict-file "$WORK/v-29.json" --owner "yes, typed prices only")"

echo "── status"
OUT=$("$SCOPE" status --config "$CFG")
has "frozen and admitted counts" "$OUT" "frozen 3 at 2026-11-13T00:00:00Z · admitted 5 (judge 2, owner 3) · cap 1, 0 left"
has "who admitted each" "$OUT" "#26 · owner · \"M2 needs it\""
has "unfinished shown outside the cap" "$OUT" "unfinished #20, outside the cap"

echo "── report: the scope-growth line"
REPORT="$ROOT/scripts/super-board-scorecard.py"
has "frozen N, admitted after M, by whom" "$(python3 "$REPORT" report --config "$CFG" --repo-path "$APP")" \
    "Scope: frozen 3 · admitted after 5 (judge 2, owner 3, 1 unfinished) · cap 1"
has "no freeze prints n/a" "$(python3 "$REPORT" report --config "$WORK/config.fresh.json" --repo-path "$APP")" "Scope: n/a"

echo "── pending strips the orchestrator's opinion"
cat > "$WORK/issues.json" <<'JSON'
[{"number":40,"title":"Fix the doc strips $750","labels":[{"name":"bug"},{"name":"priority:high"},{"name":"scope:pending"}],
  "body":"## Board summary\n**high** bug · owner `x`\n\n## Problem\nOne click strips the line.\n\n## Context\n- Decided (orchestrator): gate it\n- Decided (owner, 2026-11-12): keep labels\n- **Priority:** high\n\n## Recommendation\nShip it now.\n\n## Risk\n🟢 Low · seed data only\n\n## Acceptance Criteria\n- [ ] the line stays\n<!-- super-qa-meta priority: high -->"},
 {"number":24,"title":"already admitted","labels":[],"body":"x"}]
JSON
OUT=$("$SCOPE" pending --config "$CFG" --issues "$WORK/issues.json")
BODY=$(echo "$OUT" | jq -r '.cards[0].body')
is    "admitted cards are not pending" "[40]" "$(echo "$OUT" | jq -c '[.cards[].number]')"
is    "frozen titles for the judge" "card 20" "$(echo "$OUT" | jq -r '.frozen[0].title')"
is    "profile present" "true" "$(echo "$OUT" | jq -r '.profile')"
is    "priority label stripped" '["bug","scope:pending"]' "$(echo "$OUT" | jq -c '.cards[0].labels')"
has   "problem kept" "$BODY" "One click strips the line."
has   "owner's Decided kept" "$BODY" "Decided (owner, 2026-11-12)"
has   "ACs kept" "$BODY" "the line stays"
lacks "orchestrator Decided stripped" "$BODY" "orchestrator"
lacks "Risk stripped" "$BODY" "seed data only"
lacks "Recommendation stripped" "$BODY" "Ship it now"
lacks "Board summary stripped" "$BODY" "**high**"
lacks "priority line stripped" "$BODY" "Priority:"
lacks "hidden meta stripped" "$BODY" "super-qa-meta"

echo "── profile (lint)"
is "a full profile passes" 0 "$("$SCOPE" profile --config "$CFG" >/dev/null; echo $?)"
cp -R "$APP" "$WORK/app2"
python3 - "$WORK/app2/docs/shape/north-star.md" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"## Fit for purpose\n.*?\n\n", "", s, flags=re.S))
PY
jq --arg p "$WORK/app2" '.repo.path = $p | del(.goal.scope)' "$CFG" > "$WORK/config2.json"
is  "no profile fails lint" 1 "$("$SCOPE" profile --config "$WORK/config2.json" >/dev/null; echo $?)"
has "says what is missing" "$("$SCOPE" profile --config "$WORK/config2.json")" "no ## Fit for purpose block"
"$SCOPE" freeze --config "$WORK/config2.json" --items "$WORK/items.json" >/dev/null
is  "harm with no profile refused" 65 "$("$SCOPE" admit 24 --config "$WORK/config2.json" --verdict-file "$(verdict 24 gate 'harm: Worst case, a quote is wrong')" >/dev/null 2>&1; echo $?)"
is  "pending says no profile" "false" "$("$SCOPE" pending --config "$WORK/config2.json" --issues "$WORK/issues.json" | jq -r .profile)"

echo "── no goal.scope: today's behaviour"
OUT=$("$PLAN" --config "$WORK/config.fresh.json" --items "$WORK/items2.json" --deps "$DEPS")
is  "every goal card runs, nothing refused" "[20,24]|0" "$(echo "$OUT" | jq -r '"\([.cards[].number] | sort | tojson)|\(.refused | length)"')"
jq '.goal.scope.milestone = "M1"' "$CFG" > "$WORK/config-old.json"
OUT=$("$PLAN" --config "$WORK/config-old.json" --items "$WORK/items2.json" --deps "$DEPS")
is  "a scope frozen for another milestone is ignored" "0" "$(echo "$OUT" | jq -r '.refused | length')"

echo "── the collect filer"
cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 ${2:-}" in
  "api graphql") echo '[{"data":{"repository":{"issues":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}]' ;;
  "issue list") echo '[]' ;;
  "issue view") echo "https://github.com/acme/app/issues/55" ;;
  "issue create") echo "https://github.com/acme/app/issues/412" ;;
  "project item-list") echo '{"totalCount":0,"items":[]}' ;;
  "project list") echo '{"projects":[{"number":7,"title":"Board"}]}' ;;
  "project item-add") echo "PVTI_stub" ;;
  "project view") echo "PVT_stub" ;;
  "project field-list") echo '{"fields":[{"id":"F","name":"Status","options":[{"id":"o1","name":"Backlog"},{"id":"o2","name":"Ready"}]}]}' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/gh"
export PATH="$WORK:$PATH" GH_LOG="$WORK/gh.log" SB_COLLECT_STATE_DIR="$WORK/collect-state" SUPER_BOARD_BIN="$ROOT/scripts"
cat > "$WORK/feat.md" <<'MD'
## Problem
The quote screen shows two margins.
## Context
- **Where:** Quotes
## Fix
One margin line.
## Acceptance Criteria
- [ ] one margin line
## Risk
🟢 Low
MD
file() { : > "$GH_LOG"; "$FILE" --config "$1" --type feature --source walk --title "Two margins" --body-file "$WORK/feat.md" \
  --fingerprint "walk|screen-quotes|margins" "${@:2}" 2>"$WORK/err"; }
is  "goal milestone refused for a new card" 67 "$(file "$CFG" --milestone M2 --yes >/dev/null; echo $?)"
has "the refusal names scope:pending" "$(cat "$WORK/err")" "scope:pending"
lacks "nothing filed" "$(cat "$GH_LOG")" "issue create"
is  "adopting an unadmitted card onto the goal refused" 67 "$(: > "$GH_LOG"; "$FILE" --config "$CFG" --adopt 55 --type feature --milestone M2 --yes >/dev/null 2>&1; echo $?)"
OUT=$(: > "$GH_LOG"; "$FILE" --config "$CFG" --adopt 24 --type feature --milestone M2 --yes 2>/dev/null)
is  "an admitted card may go on the goal" "24" "$OUT"
has "and is put on it" "$(cat "$GH_LOG")" "--milestone M2"
OUT=$(file "$CFG" --yes)
is  "a walk finding files" "412" "$OUT"
has "to Backlog" "$(cat "$GH_LOG")" "o1"
lacks "never Ready" "$(cat "$GH_LOG")" "o2"
has "labelled scope:pending" "$(cat "$GH_LOG")" "--add-label scope:pending"
lacks "and never on the goal" "$(cat "$GH_LOG")" "--milestone"
OUT=$(file "$CFG" --milestone M3 --yes)
has "another milestone is allowed" "$(cat "$GH_LOG")" "--milestone M3"
OUT=$(file "$WORK/config.fresh.json" --milestone M2 --yes)
is  "no goal.scope: the goal milestone is set as asked" "412" "$OUT"
has "today's behaviour" "$(cat "$GH_LOG")" "--milestone M2"

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
