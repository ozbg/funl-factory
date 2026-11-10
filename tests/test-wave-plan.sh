#!/usr/bin/env bash
# Tests super-board-wave-plan.sh against fixtures. No gh calls, no network —
# the dependency graph is injected with --deps.
#
# The contract these tests pin down changed on 2026-08-20. A wave used to be
# "one card per column, then fill to max_workers". It is now "every Ready card
# the dependency graph says is free, plus everything already in flight", with
# max_workers demoted to an optional throttle. Several scenarios below exist
# because the old contract shipped a board where five cards sat in Blocked long
# after their blockers had closed.
set -euo pipefail
cd "$(dirname "$0")"
PLAN="../scripts/super-board-wave-plan.sh"
CFG=fixtures/wave-config.json
ITEMS=fixtures/wave-items.json

fail() { echo "FAIL: $1" >&2; exit 1; }
TMPDIR_GOAL=$(mktemp -d); trap 'rm -rf "$TMPDIR_GOAL"' EXIT
plan() { "$PLAN" --config "$1" --items "$ITEMS" --deps "$DEPS"; }

# The v2 gate needs a north star and well-formed cards: every card in the shared
# fixture gets 2 ACs, must-have 1 and its own files, so the older scenarios
# below keep testing what they always tested.
REPO="$TMPDIR_GOAL/repo"; mkdir -p "$REPO/docs/shape"
printf '# North star\n\n## Must have\n1. **Charter, front and centre.** x\n2. **Second.** y\n\n## Later\n9. not a must-have\n' > "$REPO/docs/shape/north-star.md"
DEPS="$TMPDIR_GOAL/deps.json"
jq 'with_entries(if (.value | type) == "object" then .value += {acs: 2, mustHave: [1], files: ["src/\(.key)/"]} else . end)' fixtures/wave-deps.json > "$DEPS"

# Ramp stage 3 and no max_workers, so the scenarios below see the full
# graph-filtered wave unless they test the cap itself.
NOCAP=$(jq --arg r "$REPO" 'del(.max_workers) | .ramp.stage = 3 | .repo.path = $r' "$CFG")
OUT=$(plan <(echo "$NOCAP"))

# 1 — width follows the graph, not a knob. Free Ready cards are #12 alone:
#     #11 is assigned, #14 waits on open #12, #15 is unreadable, the draft is not
#     an issue. In flight: Review #10 and QA #13. Total 3.
echo "$OUT" | jq -e '.cards | length == 3' >/dev/null || fail "expected 3 cards, got: $OUT"
echo "$OUT" | jq -e '[.cards[].number] | sort == [10,12,13]' >/dev/null || fail "wrong cards: $OUT"

# 2 — downstream-first: in-flight cards lead, so work already begun finishes
#     before new work starts.
echo "$OUT" | jq -e '[.cards[].status] | index("Ready") > index("Review")' >/dev/null \
  || fail "in-flight cards must precede Ready cards: $OUT"

# 3 — a Ready card with an OPEN blocker is not dispatched. This is the whole
#     point: #14 would previously have been picked as backlog fill, hit its own
#     preflight, and parked in Blocked.
echo "$OUT" | jq -e '[.cards[].number] | index(14) == null' >/dev/null \
  || fail "#14 waits on open #12 and must not be dispatched: $OUT"

# 4 — an unreadable dependency line is fail-safe: never dispatched, always flagged.
echo "$OUT" | jq -e '[.cards[].number] | index(15) == null' >/dev/null \
  || fail "#15 has an unreadable Blocked-by line and must not be dispatched"
echo "$OUT" | jq -e '[.flag[].number] == [15]' >/dev/null \
  || fail "#15 must be flagged so a human can fix the line, got: $(echo "$OUT" | jq -c .flag)"
echo "$OUT" | jq -e '.flag[0].why | test("None")' >/dev/null \
  || fail "the flag must carry the reason, not just the number"

# 5 — the sweep: a Blocked card whose blockers have all closed comes back.
#     #16 waits on #9, which is closed. #17 waits on #12, which is open.
echo "$OUT" | jq -e '[.sweep[].number] == [16]' >/dev/null \
  || fail "expected only #16 swept, got: $(echo "$OUT" | jq -c .sweep)"
echo "$OUT" | jq -e '.sweep[0].clearedBy == [9]' >/dev/null \
  || fail "the sweep must name what cleared the card, for the comment it will post"

# 6 — a swept card is NOT also dispatched in the same plan. The orchestrator moves
#     it to Ready first; dispatching it straight from Blocked would skip that move
#     and leave the board lying about where the card is.
echo "$OUT" | jq -e '[.cards[].number] | index(16) == null' >/dev/null \
  || fail "#16 must be swept, not dispatched from Blocked"

# 7 — max_workers still throttles when set. It is a safety valve now, not the
#     wave-sizing mechanism.
OUT7=$(plan <(echo "$NOCAP" | jq '.max_workers = 1'))
echo "$OUT7" | jq -e '(.cards | length) == 1 and .cards[0].number == 10' >/dev/null \
  || fail "max_workers=1 should keep only the leading in-flight card, got: $OUT7"

# 8 — the throttle does not suppress the sweep. A capped wave still frees cards,
#     because sweeping is a board correction and costs no worker.
echo "$OUT7" | jq -e '[.sweep[].number] == [16]' >/dev/null \
  || fail "a capped wave must still sweep, got: $(echo "$OUT7" | jq -c .sweep)"

# 9 — assignee is the cross-machine mutex and still wins over everything.
echo "$OUT" | jq -e '[.cards[].number] | index(11) == null' >/dev/null \
  || fail "#11 is assigned and must never be dispatched"

# 10 — reviews are no longer gated behind human_approves_merge. The merge race is
#      guarded where it happens (the merge lock plus the freshness gate inside the
#      wave workflow), so a second Review card is free to run here.
OUT10=$("$PLAN" --config <(echo "$NOCAP") --items fixtures/wave-items-review-heavy.json --deps "$DEPS")
echo "$OUT10" | jq -e '[.cards[] | select(.status == "Review")] | length >= 2' >/dev/null \
  || fail "reviews should run in parallel now, got: $OUT10"

# 11 — variant was removed in v3.0.0. A config still saying "qa-only" is refused
#      (exit 65) until onboard upgrades it: reading it as a build board would start
#      building on a board meant only for testing.
RC=0; "$PLAN" --config <(echo "$NOCAP" | jq '.variant = "qa-only"') --items "$ITEMS" --deps "$DEPS" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 65 ] || fail "a legacy qa-only config should exit 65, got $RC"

# 12 — an invalid variant fails loudly (exit 65); an absent one is the normal case.
RC=0; "$PLAN" --config <(echo "$NOCAP" | jq '.variant = "fulll"') --items "$ITEMS" --deps "$DEPS" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 65 ] || fail "invalid variant should exit 65, got $RC"
"$PLAN" --config <(echo "$NOCAP" | jq 'del(.variant)') --items "$ITEMS" --deps "$DEPS" >/dev/null \
  || fail "a config with no variant must plan normally"

# 13 — empty board → empty everything (run-workflow.md's done condition depends
#      on this shape).
OUT13=$("$PLAN" --config <(echo "$NOCAP") --items <(echo '{"items":[]}') --deps "$DEPS")
echo "$OUT13" | jq -e '.cards == [] and .sweep == [] and .flag == [] and .stranded == []' >/dev/null \
  || fail "empty board should yield empty cards/sweep/flag/stranded, got: $OUT13"

# 14 — a card the graph has never heard of is not treated as free. An issue beyond
#      the fetch limit, or closed out from under the board, must not be dispatched
#      on the strength of a missing entry.
OUT14=$("$PLAN" --config <(echo "$NOCAP") --items "$ITEMS" --deps <(echo '{}'))
echo "$OUT14" | jq -e '[.cards[] | select(.status == "Ready")] | length == 0' >/dev/null \
  || fail "an empty graph must yield no Ready picks, got: $OUT14"

# 15 — a graph that cannot be derived is a hard failure, not an empty graph.
#      Without --deps and without config.repo.remote there is nothing to derive from.
RC=0; "$PLAN" --config <(echo "$NOCAP" | jq 'del(.repo)') --items "$ITEMS" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 66 ] || fail "a missing repo remote should exit 66, got $RC"

# 16 — a Building card with no claim is stranded: a stopped wave left it there and
#      no lane selects from Building. A claimed one (#19) has a live worker.
echo "$OUT" | jq -e '[.stranded[].number] == [18]' >/dev/null \
  || fail "expected only #18 stranded, got: $(echo "$OUT" | jq -c .stranded)"
echo "$OUT" | jq -e '[.cards[].number] | index(18) == null' >/dev/null \
  || fail "#18 must be moved to Ready first, not dispatched from Building"

# 17 — label routing. A Ready card labelled `qa` skips the Builder (lane qa); `bug`,
#      `feature` and no label are built first (lane build). QA/Review cards keep their
#      column's lane. Labels come from the item (`labels`) or the content, any case.
LBL_ITEMS=$(jq -n '{items: [
  {status:"Ready", labels:["QA"], content:{type:"Issue", number:12, title:"qa card", assignees:[]}},
  {status:"Ready", labels:["bug"], content:{type:"Issue", number:10, title:"bug card", assignees:[]}},
  {status:"Ready", content:{type:"Issue", number:13, title:"no label", assignees:[], labels:[{name:"feature"}]}},
  {status:"Ready", content:{type:"Issue", number:9, title:"bare", assignees:[]}},
  {status:"QA", labels:["qa"], content:{type:"Issue", number:11, title:"in qa", assignees:[]}}]}')
LBL_DEPS=$(jq -n '[9,10,11,12,13] | map({(tostring): {runnable:true, parseable:true, blockers:[], acs:1, mustHave:[1], files:["f\(.)/"]}}) | add')
OUT17=$("$PLAN" --config <(echo "$NOCAP" | jq '.ramp.stage = 3') --items <(echo "$LBL_ITEMS" | jq '.items |= map(select(.content.number | IN(9, 13) | not))') --deps <(echo "$LBL_DEPS"))
OUT17B=$("$PLAN" --config <(echo "$NOCAP") --items <(echo "$LBL_ITEMS" | jq '.items |= map(select(.content.number | IN(9, 13)))') --deps <(echo "$LBL_DEPS"))
lane() { printf '%s\n%s' "$OUT17" "$OUT17B" | jq -s '{cards: [.[].cards[]]}' | jq -r --argjson n "$1" '.cards[] | select(.number == $n) | .lane'; }
[ "$(lane 12)" = qa ]    || fail "a qa-labelled Ready card must skip Building (lane qa), got: $OUT17"
[ "$(lane 10)" = build ] || fail "a bug card is built first, got $(lane 10)"
[ "$(lane 13)" = build ] || fail "a feature card (label on content) is built first, got $(lane 13)"
[ "$(lane 9)" = build ]  || fail "no label = Building, got $(lane 9)"
[ "$(lane 11)" = qa ]    || fail "a QA-column card keeps lane qa, got $(lane 11)"
echo "$OUT17" | jq -e '.cards[] | select(.number == 12) | .labels == ["qa"]' >/dev/null \
  || fail "labels must be passed through lower-cased, got: $OUT17"

# 18 — resume: a 🙋 Blocked card whose human step is done (#20) is reported for
#      the move back to Review; one still waiting (#21) is not. Neither is swept
#      to Ready or dispatched from Blocked.
echo "$OUT" | jq -e '[.resume[].number] == [20]' >/dev/null \
  || fail "expected only #20 resumed, got: $(echo "$OUT" | jq -c .resume)"
echo "$OUT" | jq -e '[.sweep[].number, .cards[].number] | (index(20) == null and index(21) == null)' >/dev/null \
  || fail "🙋 cards must not be swept to Ready or dispatched"

# 19 — a moved head while Blocked goes to request refresh, never approved resume.
OUT19=$("$PLAN" --config <(echo "$NOCAP") --items "$ITEMS" --deps <(jq '.["21"].approvalRefresh=true | .["21"].approvalWhy="PR head changed"' "$DEPS"))
echo "$OUT19" | jq -e '[.refreshApproval[].number] == [21]' >/dev/null || fail "stale approval must get a fresh request"
echo "$OUT19" | jq -e '[.resume[].number, .cards[].number, .sweep[].number] | index(21) == null' >/dev/null || fail "refresh is not permission to merge or build"


# Goal — config goal.milestone runs only that milestone's Ready cards (factory #40).
# In-flight cards always finish; free Ready cards off the goal are reported, never run.
GOAL=$(echo "$NOCAP" | jq '.goal = {milestone: "M1 · test"}')
jq '(.items[] | select(.content.number == 12)) += {milestone: {title: "M2 · later"}}' "$ITEMS" > "$TMPDIR_GOAL/items-off.json"
OUT=$("$PLAN" --config <(echo "$GOAL") --items "$TMPDIR_GOAL/items-off.json" --deps "$DEPS")
echo "$OUT" | jq -e '[.cards[].number] | sort == [10,13]' >/dev/null || fail "off-goal Ready #12 must not run, in-flight must: $OUT"
echo "$OUT" | jq -e '[.offGoal[].number] == [12]' >/dev/null || fail "#12 must be reported offGoal: $(echo "$OUT" | jq -c .offGoal)"
jq '(.items[] | select(.content.number == 12)) += {milestone: {title: "M1 · test"}}' "$ITEMS" > "$TMPDIR_GOAL/items-on.json"
OUT=$("$PLAN" --config <(echo "$GOAL") --items "$TMPDIR_GOAL/items-on.json" --deps "$DEPS")
echo "$OUT" | jq -e '([.cards[].number] | sort) == [10,12,13] and (.offGoal | length) == 0' >/dev/null || fail "on-goal #12 must run: $OUT"
OUT=$("$PLAN" --config <(echo "$GOAL") --items "$ITEMS" --deps "$DEPS")
echo "$OUT" | jq -e '[.offGoal[].number] == [12]' >/dev/null || fail "a Ready card with no milestone is off-goal: $OUT"
# No goal: unchanged, and offGoal is empty.
echo "$(plan <(echo "$NOCAP"))" | jq -e '(.offGoal // []) | length == 0' >/dev/null || fail "no goal must report no offGoal"

# 20 — the gate (v2). A free Ready card with no ACs, no must-have, or a must-have
#      the north star does not list is refused with a one-line reason naming the
#      field, and never dispatched. bug/qa cards skip the must-have check only.
G_ITEMS=$(jq -n '{items: [range(30;37) as $n | {status:"Ready", content:{type:"Issue", number:$n, title:"c\($n)", assignees:[]}}]
                  | (.[5].labels = ["bug"]) | (.[6].labels = ["bug"])}')
G_DEPS=$(jq -n '{"30":{acs:0,mustHave:[1]}, "31":{acs:2}, "32":{acs:2,mustHave:[1,9]},
                 "33":{acs:2,mustHave:[2]}, "34":{acs:2,mustHave:[]}, "35":{acs:1}, "36":{acs:0}}
                | map_values(. + {runnable:true, parseable:true, blockers:[], files:["g/"]}) | with_entries(.value.files = ["g\(.key)/"])')
OUT20=$("$PLAN" --config <(echo "$NOCAP") --items <(echo "$G_ITEMS") --deps <(echo "$G_DEPS"))
why() { echo "$OUT20" | jq -r --argjson n "$1" '.refused[] | select(.number == $n) | .reason'; }
echo "$OUT20" | jq -e '([.cards[].number] | sort) == [33,35] and ([.refused[].number] | sort) == [30,31,32,34,36]' >/dev/null \
  || fail "gate: only #33 (must-have 2) and #35 (bug, no must-have) admitted, got: $OUT20"
why 30 | grep -q "Acceptance Criteria" || fail "#30 reason must name the ACs: $(why 30)"
why 31 | grep -q "Must-have served"    || fail "#31 reason must name Must-have served: $(why 31)"
why 32 | grep -q "names 9"             || fail "#32 reason must name the unknown must-have: $(why 32)"
why 36 | grep -q "Acceptance Criteria" || fail "a bug card still needs ACs: $(why 36)"
[ "$(echo "$OUT20" | jq '[.refused[].reason | select(test("\n"))] | length')" = 0 ] || fail "reasons must be one line"
OUT20B=$("$PLAN" --config <(echo "$NOCAP" | jq --arg r "$TMPDIR_GOAL" '.repo.path = $r') --items <(echo "$G_ITEMS") --deps <(echo "$G_DEPS"))
echo "$OUT20B" | jq -e '[.cards[].number] == [35] and (.refused | all(.number == 35 | not))
                         and ([.refused[] | select(.number == 33) | .reason | test("north-star.md missing")] == [true])' >/dev/null \
  || fail "no north star: every non-bug card refused naming the file, got: $OUT20B"

# 21 — overlap. Two cards sharing a path prefix never land in one wave; a card
#      with no Files: line overlaps everything; in-flight cards pick first.
O_ITEMS=$(jq -n '{items: [{status:"Review", content:{type:"Issue", number:40, title:"r", assignees:[]}}]
                  + [range(41;45) as $n | {status:"Ready", content:{type:"Issue", number:$n, title:"c\($n)", assignees:[]}}]}')
O_DEPS=$(jq -n '{"40":{files:["src/api/"]}, "41":{files:["src/api/users.ts"]}, "42":{files:["docs/a.md"]},
                 "43":{files:["docs/"]}, "44":{}}
                | map_values(. + {runnable:true, parseable:true, blockers:[], acs:1, mustHave:[1]})')
OUT21=$("$PLAN" --config <(echo "$NOCAP") --items <(echo "$O_ITEMS") --deps <(echo "$O_DEPS"))
echo "$OUT21" | jq -e '[.cards[].number] == [40,42] and ([.deferred[] | [.number, .reason]] == [[41,"overlap"],[43,"overlap"],[44,"overlap"]])' >/dev/null \
  || fail "overlap: expected cards [40,42], deferred 41 43 44, got: $OUT21"

# 22 — ramp. Lanes never exceed ramp.stage or max_workers, whichever is lower;
#      goal.foundation forces 1; no ramp key means stage 1; a bad stage exits 65.
R_ITEMS=$(jq -n '{items: [range(50;55) as $n | {status:"Ready", content:{type:"Issue", number:$n, title:"c\($n)", assignees:[]}}]}')
R_DEPS=$(jq -n '[range(50;55)] | map({(tostring): {runnable:true, parseable:true, blockers:[], acs:1, mustHave:[1], files:["r\(.)/"]}}) | add')
width() { "$PLAN" --config <(echo "$NOCAP" | jq "$1") --items <(echo "$R_ITEMS") --deps <(echo "$R_DEPS") | jq '.cards | length'; }
[ "$(width '.ramp.stage = 2')" = 2 ] || fail "stage 2 must cap at 2"
[ "$(width '.ramp.stage = 3')" = 3 ] || fail "stage 3 must cap at 3"
[ "$(width '.ramp.stage = 3 | .max_workers = 2')" = 2 ] || fail "max_workers below the stage must win"
[ "$(width '.ramp.stage = 3 | .goal.foundation = true')" = 1 ] || fail "foundation must force 1"
[ "$(width 'del(.ramp)')" = 1 ] || fail "no ramp key must mean stage 1"
RC=0; "$PLAN" --config <(echo "$NOCAP" | jq '.ramp.stage = 4') --items <(echo "$R_ITEMS") --deps <(echo "$R_DEPS") >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 65 ] || fail "ramp.stage 4 should exit 65, got $RC"

echo "PASS: test-wave-plan.sh (22 scenarios)"
