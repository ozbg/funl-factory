#!/usr/bin/env bash
# Stubbed Codex only: model precedence and ladders, review consent, bounded permissions,
# structured failures and wave routing/concurrency/halt/stop. No network.
# Every case runs twice: through the super-board-codex-lane.sh shim and through
# super-board-lane.sh --backend codex, with the same stubbed codex.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${SB_LANE_ENTRY:-}" ]; then
  for entry in shim backend; do SB_LANE_ENTRY=$entry bash "$0" || { echo "FAIL: entry $entry" >&2; exit 1; }; done
  # The backend seam: a missing, unknown or not-yet-built backend exits 64 and names the valid ones.
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  for args in "" "--backend gemini" "--backend claude" "--backend=gemini" "--backend"; do
    RC=0; bash "$KIT/scripts/super-board-lane.sh" $args --config x --card '{}' --lane build >/dev/null 2>"$T/err" || RC=$?
    [ "$RC" -eq 64 ] && grep -q 'valid backends: codex' "$T/err" || { echo "FAIL: '$args' must exit 64 naming the valid backends (rc=$RC)" >&2; cat "$T/err" >&2; exit 1; }
  done
  grep -q '^exec .*super-board-lane.sh" --backend codex "\$@"$' "$KIT/scripts/super-board-codex-lane.sh" || { echo 'FAIL: codex-lane must be a one-line shim' >&2; exit 1; }
  echo 'PASS: test-codex-lane.sh (shim + --backend codex; backend refusal)'
  exit 0
fi
case "$SB_LANE_ENTRY" in
  shim) LAUNCHER=("$KIT/scripts/super-board-codex-lane.sh") ;;
  *) LAUNCHER=("$KIT/scripts/super-board-lane.sh" --backend codex) ;;
esac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo"
git init -q "$T/repo"
python3 "$KIT/tests/fixtures/install_worker_skills.py" "$T/repo"
export SUPER_BOARD_SKILLS_HOME="$T/home"; mkdir -p "$SUPER_BOARD_SKILLS_HOME"
cat > "$T/bin/gh" <<'PYGH'
#!/usr/bin/env python3
import json,sys
args=sys.argv[1:]
if args[:2]==['issue','view']:
    print(json.dumps({'labels':[]} if args[args.index('--json')+1] == 'labels' else {'number':int(args[2]),'title':'fixture','body':''}))
else:
    sys.exit('unexpected gh fixture call: '+str(args))
PYGH
chmod +x "$T/bin/gh"
export SB_CODEX_TEST_LOG="$T/calls.jsonl"
export PATH="$T/bin:$PATH"
cp "$KIT/tests/fixtures/fake_codex.py" "$T/bin/codex"
chmod +x "$T/bin/codex"
cd "$T/repo"
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
CARD='{"number":1,"status":"Ready","title":"example"}'
lane() { bash "${LAUNCHER[@]}" --config "$T/config.json" --card "$CARD" --lane "$@" 2>"$T/stderr"; }
wave() { bash "$KIT/scripts/super-board-codex-wave.sh" --config "$T/config.json" --cards "$CARDS" "$@" 2>"$T/stderr"; }
fail() { echo "FAIL: $*" >&2; cat "$T/stderr" >&2; exit 1; }
last_model() { tail -1 "$SB_CODEX_TEST_LOG" | jq -r '.args | if index("-m") then .[index("-m")+1] else "default" end'; }

RC=0; lane review >"$T/out" || RC=$?
[ "$RC" -eq 78 ] && [ ! -e "$SB_CODEX_TEST_LOG" ] || fail 'fallback review must refuse before Codex'
lane review --codex >"$T/out"
jq -e '.status == "advanced" and .column == "Done"' "$T/out" >/dev/null || fail 'explicit review allowed'
grep -q -- '--expect-head' "$SB_CODEX_TEST_LOG" || fail 'review must pin reviewed head to merge gate'
grep -q 'Never run bare gh pr merge' "$SB_CODEX_TEST_LOG" || fail 'review must keep merge protocol'
[ "$(last_model)" = default ] || fail 'no model uses Codex default'
lane build --codex=flag-model >"$T/out"
[ "$(last_model)" = flag-model ] || fail 'flag model must reach -m'
echo '{"codex":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane qa --codex >"$T/out"
[ "$(last_model)" = config-model ] || fail 'config model must reach -m'
lane qa --codex=flag-model >"$T/out"
[ "$(last_model)" = flag-model ] || fail 'flag must beat config'
RC=0; lane qa >"$T/out" || RC=$?
[ "$RC" -eq 78 ] || fail 'fallback without usage_fallback "codex" must refuse'
echo '{"codex":{"model":"config-model"},"usage_fallback":"codex","verify_commands":["git diff --check"]}' > "$T/config.json"
lane qa >"$T/out"
[ "$(last_model)" = config-model ] || fail 'build/qa fallback uses config model'
RC=0; lane review >"$T/out" || RC=$?
[ "$RC" -eq 78 ] || fail 'config model cannot authorize fallback review'
RC=0; lane build --codex= >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'empty explicit model must refuse'

# Ladders: run tier x card grade -> model; an ungraded card takes the medium cell.
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
while read -r TIER GRADE WANT; do
  lane build --codex --tier "$TIER" ${GRADE:+--complexity "$GRADE"} >"$T/out"
  [ "$(last_model)" = "$WANT" ] || fail "ladder $TIER/$GRADE must pick $WANT, got $(last_model)"
done <<'CELLS'
medium low gpt-6.1-sol
medium medium gpt-6.1-sol
medium high gpt-6-astra
low low gpt-6-luna
low medium gpt-6.1-sol
low high gpt-6.1-sol
high low gpt-6-astra
high medium gpt-6-astra
high high gpt-6-astra
CELLS
lane qa --codex --tier medium >"$T/out"
[ "$(last_model)" = gpt-6.1-sol ] || fail 'ungraded default card takes the medium cell'
lane qa --codex --tier low >"$T/out"
[ "$(last_model)" = gpt-6.1-sol ] || fail 'ungraded --low card takes the medium cell'
lane build --codex=flag-model --tier high --complexity high >"$T/out"
[ "$(last_model)" = flag-model ] || fail 'explicit --codex=<model> beats the ladder'
echo '{"codex":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --codex --tier low --complexity low >"$T/out"
[ "$(last_model)" = config-model ] || fail 'codex.model beats the ladder'
echo '{"codex":{"model":""},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --codex --tier high --complexity low >"$T/out"
[ "$(last_model)" = gpt-6-astra ] || fail 'empty codex.model leaves the ladder in charge'
RC=0; lane build --codex --tier extreme >"$T/out" || RC=$?
[ "$RC" -ne 0 ] || fail 'unknown tier must refuse'

# Per-lane models: codex.models.<lane> beats codex.model; a lane without an entry keeps codex.model.
echo '{"codex":{"model":"config-model","models":{"build":"build-model","qa":"qa-model"}},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --codex >"$T/out"; [ "$(last_model)" = build-model ] || fail 'codex.models.build must reach -m'
lane qa --codex >"$T/out";    [ "$(last_model)" = qa-model ] || fail 'codex.models.qa must reach -m'
lane review --codex >"$T/out"; [ "$(last_model)" = config-model ] || fail 'a lane with no codex.models entry keeps codex.model'
lane build --codex=flag-model >"$T/out"; [ "$(last_model)" = flag-model ] || fail '--codex=<model> beats codex.models'
echo '{"codex":{"models":"build-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
RC=0; lane build --codex >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'codex.models must be an object'
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"

# The lane env makes caches writable, shares one browser path and keeps colour out of evidence logs.
lane build --codex >"$T/out"
tail -1 "$SB_CODEX_TEST_LOG" | jq -e '.env.NO_COLOR == "1" and .env.FORCE_COLOR == "0" and (.env.npm_config_cache | test("super-board-codex/npm-cache$")) and (.env.npm_config_store_dir | test("pnpm-store$")) and (.env.PLAYWRIGHT_BROWSERS_PATH | test("ms-playwright$"))' >/dev/null || fail 'lane env must set caches, browser path and NO_COLOR'
tail -1 "$SB_CODEX_TEST_LOG" | jq -e '.prompt | contains("github-cheatsheet.md") and contains("JSON object alone") and contains("scratch-<card>")' >/dev/null || fail 'lane prompt must carry the cheat sheet, JSON-only and scratch checkout rules'

# private_home denies every sibling along the path from $HOME to the repo; off by default.
tail -1 "$SB_CODEX_TEST_LOG" | jq -e '[.args[] | select(startswith("permissions.super-board-lane.filesystem="))][0] | contains("\"none\"") | not' >/dev/null || fail 'home denials are opt-in'
HOMEDIR=$(cd "$(mktemp -d)" && pwd -P); export HOMEDIR; mkdir -p "$HOMEDIR/Documents/work/repo" "$HOMEDIR/Documents/other" "$HOMEDIR/secrets"
(cd "$HOMEDIR/Documents/work/repo" && git init -q && python3 "$KIT/tests/fixtures/install_worker_skills.py" . && \
  echo '{"codex":{"private_home":true},"verify_commands":["git diff --check"]}' > "$T/private.json" && \
  HOME="$HOMEDIR" bash "${LAUNCHER[@]}" --config "$T/private.json" --card "$CARD" --lane build --codex >"$T/out" 2>"$T/stderr")
tail -1 "$SB_CODEX_TEST_LOG" | jq -e '[.args[] | select(startswith("permissions.super-board-lane.filesystem="))][0] | contains("secrets") and contains("Documents/other") and contains("none")' >/dev/null || fail 'private_home must deny home siblings'
tail -1 "$SB_CODEX_TEST_LOG" | jq -e '[.args[] | select(startswith("permissions.super-board-lane.filesystem="))][0] | (contains("Documents/work/repo\"=\"write")) and (contains("\"" + env.HOMEDIR + "\"=") | not)' >/dev/null || fail 'private_home keeps the repo writable and never denies a parent folder itself'
rm -rf "$HOMEDIR"

# A lane that ends in prose is resumed in the same session and then counts as advanced.
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_PROSE_FIRST=1 lane build --codex >"$T/out"
jq -e '.status == "advanced" and .detail == "finished after resume"' "$T/out" >/dev/null || fail 'prose-only lane must be resumed to a valid result'
jq -s -e '[.[].lane] == ["build", "resume"] and .[1].session == "sess-1234" and (.[1].prompt | contains("only the JSON result object"))' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'resume must reuse the session id with the finish prompt'
# No session id and invalid output: fail with the final message kept, not a bare error.
: > "$SB_CODEX_TEST_LOG"
RC=0; SB_CODEX_TEST_INVALID=1 lane build --codex >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed" and (.detail | contains("final message: not json") and contains("saved:"))' "$T/out" >/dev/null || fail 'invalid final message must be reported and kept'
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"

# Wave: the luna router grades Ready cards only when nothing pins a model.
echo '{"max_workers":1,"verify_commands":["git diff --check"]}' > "$T/config.json"
CARDS='[{"number":1,"status":"Ready","title":"easy"},{"number":2,"status":"Review"}]'
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_GRADE=low wave --codex --tier low >"$T/out"
python3 - "$SB_CODEX_TEST_LOG" <<'PY'
import json, pathlib, sys
calls = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
model = lambda call: call['args'][call['args'].index('-m') + 1] if '-m' in call['args'] else 'default'
grades = [call for call in calls if call['lane'] == 'grade']
assert [call['number'] for call in grades] == [1], grades
assert model(grades[0]) == 'gpt-6-luna'
card1 = [model(call) for call in calls if call['number'] == 1 and call['lane'] != 'grade']
assert card1 == ['gpt-6-luna'] * 3, card1          # --low x low on build, qa and review
card2 = [model(call) for call in calls if call['number'] == 2]
assert card2 == ['gpt-6.1-sol'], card2              # ungraded Review card: --low medium cell
PY
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_GRADE=high wave --codex >"$T/out"
jq -s -e '[.[] | select(.number == 1 and .lane != "grade") | .args | .[index("-m")+1]] | all(. == "gpt-6-astra")' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'default ladder sends a hard card to astra'
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_GRADE_EXIT=1 wave --codex --tier high >"$T/out"
jq -s -e '[.[] | select(.number == 1 and .lane != "grade") | .args | .[index("-m")+1]] | all(. == "gpt-6-astra")' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'a failed grade falls back to the medium cell'
: > "$SB_CODEX_TEST_LOG"
wave --codex=pinned-model >"$T/out"
jq -s -e 'all(.lane != "grade") and all(.args | .[index("-m")+1] == "pinned-model")' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'a pinned model skips the router and wins every lane'
: > "$SB_CODEX_TEST_LOG"
RC=0; SB_CODEX_TEST_GRADE_EXIT=79 wave --codex >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.halted and .cards[0].finalStatus == "halted"' "$T/out" >/dev/null || fail 'router halt stops the wave'
jq -s -e 'all(.lane == "grade")' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'router halt launches no lane'
rm -f "$T/stderr"

# A .git pointer to a superproject-shaped external git dir, without a commit.
mkdir -p "$T/super/.git/modules"
git init -q --separate-git-dir="$T/super/.git/modules/kit" "$T/submodule"
python3 "$KIT/tests/fixtures/install_worker_skills.py" "$T/submodule"
cd "$T/submodule"
lane review --codex >"$T/out"
python3 - "$SB_CODEX_TEST_LOG" "$T/submodule" "$T/super/.git/modules/kit" <<'PY'
import json, pathlib, sys
call = json.loads(pathlib.Path(sys.argv[1]).read_text().splitlines()[-1])
args = call['args']
configs = [args[i+1] for i, arg in enumerate(args) if arg == '-c']
assert 'approval_policy="never"' in configs
assert 'default_permissions="super-board-lane"' in configs
assert not any('.extends=' in entry for entry in configs)
assert 'permissions.super-board-lane.network.enabled=true' in configs
grants = next(entry.split('=', 1)[1] for entry in configs if entry.startswith('permissions.super-board-lane.filesystem='))
filesystem = json.loads(grants.replace('=', ':'))
for path in sys.argv[2:]:
    assert filesystem[str(pathlib.Path(path).resolve())] == 'write'
assert filesystem[':root'] == 'read'
assert '--dangerously-bypass-approvals-and-sandbox' not in args
PY
cd "$T/repo"
SB_CODEX_TEST_INVALID=1 RC=0
export SB_CODEX_TEST_INVALID
lane build --codex >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail 'invalid result fails'
unset SB_CODEX_TEST_INVALID
RC=0; SB_CODEX_TEST_EXIT=2 lane build --codex >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail 'nonzero exec never trusts success JSON'

# The whole result is checked against the lane schema, not only status/column/detail.
while IFS= read -r BAD; do
  RC=0; SB_CODEX_TEST_RESULT="$BAD" lane build --codex >"$T/out" || RC=$?
  [ "$RC" -eq 1 ] && jq -e '.status == "failed" and .column == "Ready"' "$T/out" >/dev/null || fail "malformed result must fail: $BAD"
done <<'BAD'
{"status":"advanced","column":"QA","detail":"d","prUrl":7,"branch":null,"priorFindings":null,"score":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":null,"extra":1}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":{"fixed":1,"noLongerApplies":0},"score":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":{"fixed":1,"notFixed":true,"noLongerApplies":0},"score":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"priorFindings":null,"score":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":["b"],"priorFindings":null,"score":null}
{"status":"done","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":null,"score":null}
["status","advanced"]
BAD
while IFS= read -r GOOD; do
  SB_CODEX_TEST_RESULT="$GOOD" lane build --codex >"$T/out" || fail "valid result must exit 0: $GOOD"
  [ "$(cat "$T/out")" = "$(jq -c . <<<"$GOOD" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))')" ] || fail "valid result must print unchanged: $GOOD"
done <<'GOOD'
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":null,"score":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":"https://github.com/o/r/pull/2","branch":"sb/1","priorFindings":{"fixed":2,"notFixed":0,"noLongerApplies":1},"score":null}
GOOD

CARDS='[{"number":1,"status":"Ready"},{"number":2,"status":"Ready","labels":["qa"]},{"number":3,"status":"QA"},{"number":4,"status":"Review"}]'
echo '{"max_workers":1,"codex":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
: > "$SB_CODEX_TEST_LOG"
wave --codex=wave-model --output "$T/wave.json" > "$T/out"
cmp "$T/out" "$T/wave.json" || fail 'file and stdout wave result differ'
jq -e '.halted == false and (.cards | length) == 4 and .cards[0].lanesRun == "build:advanced → qa:advanced → review:advanced" and .cards[1].lanesRun == "qa:advanced → review:advanced" and .cards[2].lastLane == "review" and .cards[3].column == "Done"' "$T/out" >/dev/null || fail 'wave routing/summary'
[ "$(last_model)" = wave-model ] || fail 'wave propagates explicit model'
jq -e '.cards[0].buildModel == "wave-model" and .cards[0].qaModel == "wave-model" and .cards[3].reviewModel == "wave-model" and .cards[3].buildModel == null' "$T/out" >/dev/null || fail 'summary names the pinned --codex model per lane that ran'
jq -s -e 'all(.active == 1)' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'max_workers=1 must serialize cards'
[ ! -e .claude/super-board/codex-wave.pid ] && [ -z "$(ls -A .claude/super-board/inflight)" ] || fail 'completed wave leaves no PID/worker locks'
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_STATUS=bounced wave --codex >"$T/out"
jq -e '.cards[0].lanesRun == "build:bounced"' "$T/out" >/dev/null || fail 'non-advanced ends card chain'
jq -e '.cards[0].buildModel == "codex" and .cards[0].qaModel == null' "$T/out" >/dev/null || fail 'no pinned model reports codex, and only for lanes that ran'
: > "$SB_CODEX_TEST_LOG"
RC=0; SB_CODEX_TEST_STATUS=halted wave --codex >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && [ "$(wc -l < "$SB_CODEX_TEST_LOG" | tr -d ' ')" -eq 1 ] || fail 'halt stops all new lane dispatch'
jq -e '.halted and (.cards | length) == 4' "$T/out" >/dev/null || fail 'halt summary preserves all cards'

# Rolling dispatch: no --cards; the planner is asked again after every finished card, the cap is
# max_workers, each finished card is one line in --events, and the run ends when the board is idle.
mkdir -p "$T/rolling"; cp "$KIT"/scripts/* "$T/rolling/"
cat > "$T/rolling/super-board-wave-plan.sh" <<'PLAN'
#!/usr/bin/env bash
# Stub planner: cards 1 and 2 are runnable until their review lane has started.
jq -n --slurpfile log "$SB_CODEX_TEST_LOG" '{cards: [range(1;3) | select(. as $n | ([$log[] | select(.number == $n and .lane == "review")] | length) == 0) | {number: ., status: "Review", title: "rolling", lane: "review", labels: []}]}'
PLAN
chmod +x "$T/rolling/super-board-wave-plan.sh"
cp "$T/config.json" "$T/config.saved"
echo '{"max_workers":1,"verify_commands":["git diff --check"]}' > "$T/config.json"
: > "$SB_CODEX_TEST_LOG"; rm -f "$T/events.jsonl"
SB_ROLLING_POLL=0.2 bash "$T/rolling/super-board-codex-wave.sh" --config "$T/config.json" --rolling --events "$T/events.jsonl" --codex >"$T/out" 2>"$T/stderr" || fail 'rolling run must end 0 when the board is idle'
jq -e '.halted == false and ([.cards[].number] | sort) == [1, 2] and all(.cards[]; .finalStatus == "advanced")' "$T/out" >/dev/null || fail 'rolling run must finish both planned cards'
jq -s -e 'all(.active == 1)' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'rolling honours max_workers=1'
[ "$(wc -l < "$T/events.jsonl" | tr -d ' ')" -eq 2 ] && jq -s -e 'all(.finalStatus == "advanced" and has("at"))' "$T/events.jsonl" >/dev/null || fail 'rolling writes one event per finished card'
RC=0; bash "$KIT/scripts/super-board-codex-wave.sh" --config "$T/config.json" --codex >/dev/null 2>&1 || RC=$?
[ "$RC" -ne 0 ] || fail 'without --rolling, --cards stays required'
# A card that did not advance waits out --cooldown before it is picked again.
: > "$SB_CODEX_TEST_LOG"; rm -f "$T/events.jsonl"
SB_CODEX_TEST_STATUS=bounced SB_ROLLING_POLL=0.2 bash "$T/rolling/super-board-codex-wave.sh" --config "$T/config.json" --rolling --events "$T/events.jsonl" --cooldown 0 --codex >"$T/out" 2>"$T/stderr" &
ROLL=$!; for _ in {1..40}; do [ -f "$T/events.jsonl" ] && [ "$(wc -l < "$T/events.jsonl")" -ge 2 ] && break; sleep 0.25; done
kill "$ROLL" 2>/dev/null || true; wait "$ROLL" 2>/dev/null || true
[ "$(jq -s 'length' "$T/events.jsonl")" -ge 2 ] || fail 'a bounced card is picked again once its cooldown ends'
rm -f .claude/super-board/codex-wave.pid; rm -rf .claude/super-board/inflight; mkdir -p .claude/super-board/inflight
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
cp "$T/config.saved" "$T/config.json"

# A readiness halt returned by a running lane stops dispatch and preserves its owned lock.
: > "$SB_CODEX_TEST_LOG"
RC=0; SB_CODEX_TEST_EXIT=9 wave --codex >"$T/out" || RC=$?
[ "$RC" -eq 9 ] && [ "$(wc -l < "$SB_CODEX_TEST_LOG" | tr -d ' ')" -eq 1 ] || fail 'readiness halt stops new Codex dispatch'
jq -e '.halted and .cards[0].finalStatus == "halted" and (.cards[0].detail | contains("verification-readiness"))' "$T/out" >/dev/null || fail 'readiness is a setup halt, not failed/rebase'
[ -f .claude/super-board/inflight/1 ] || fail 'readiness halt preserves its lane lock for recovery'
[ ! -e .claude/super-board/codex-wave.pid ] || fail 'ended wave releases only its PID marker'
rm .claude/super-board/inflight/1  # fixture recovery before unrelated concurrency tests

# A normal Codex completion can also report gate exit 9 in its structured result.
: > "$SB_CODEX_TEST_LOG"
RC=0; SB_CODEX_TEST_STATUS=halted SB_CODEX_TEST_DETAIL='verification-readiness: checks missing' wave --codex >"$T/out" || RC=$?
[ "$RC" -eq 9 ] && [ "$(wc -l < "$SB_CODEX_TEST_LOG" | tr -d ' ')" -eq 1 ] || fail 'structured readiness halt preserves code 9'
[ -f .claude/super-board/inflight/1 ] || fail 'structured readiness halt preserves lane state'
rm .claude/super-board/inflight/1

# Two card chains run together, but a cap of 1 above was serial.
echo '{"max_workers":2,"verify_commands":["git diff --check"]}' > "$T/config.json"
CARDS='[{"number":1,"status":"Review"},{"number":2,"status":"Review"}]'
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_DELAY=1 wave --codex >"$T/out"
python3 - "$SB_CODEX_TEST_LOG" <<'PY'
import json, pathlib, sys
calls = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert len(calls) == 2 and max(call['active'] for call in calls) == 2
PY

# If the numeric lock cannot be written, startup fails as a card result and
# reaps the already-created launcher rather than losing the whole wave summary.
mkdir .claude/super-board/inflight/1
CARDS='[{"number":1,"status":"Review"}]'
wave --codex >"$T/out"
jq -e '.cards[0].finalStatus == "failed" and (.cards[0].detail | contains("could not start"))' "$T/out" >/dev/null || fail 'startup failure needs structured result'
rmdir .claude/super-board/inflight/1

# TERM reaps the Codex process group and its descendants before lock cleanup.
CARDS='[{"number":1,"status":"Review"}]'
SB_CODEX_TEST_SLEEP=1 SB_CODEX_TEST_PID="$T/descendant.pid" wave --codex >"$T/out" &
JOB=$!
for _ in {1..100}; do [ -s "$T/descendant.pid" ] && break; sleep 0.05; done
[ -s "$T/descendant.pid" ] || fail 'stub did not start'
WAVE_PID=$(cat .claude/super-board/codex-wave.pid)
kill -TERM "$WAVE_PID"
RC=0; wait "$JOB" || RC=$?
[ "$RC" -eq 79 ] || fail 'interrupted wave must halt'
DESCENDANT=$(cat "$T/descendant.pid")
! kill -0 "$DESCENDANT" 2>/dev/null || fail 'descendant survived wave cancellation'
[ ! -e .claude/super-board/codex-wave.pid ] && [ -z "$(ls -A .claude/super-board/inflight)" ] || fail 'interrupted wave leaves no live locks'
echo "PASS: test-codex-lane.sh [$SB_LANE_ENTRY] (model/ladders/router/review/sandbox/results/wave/halt/cancellation)"
