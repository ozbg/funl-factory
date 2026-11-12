#!/usr/bin/env bash
# super-board-wave-plan.sh — compute the next workflow-backend wave from board state.
# Read-only: no gh writes, no locks. The orchestrator owns every mutation; this
# script only says what the next wave should contain and what should be swept.
#
# WAVE SHAPE (changed 2026-08-20 — see "why" below)
#
# A wave is no longer a fixed number of slots. It is:
#
#   every Ready card whose `## Blocked by` list is fully closed,
#   plus every card already in flight in QA or Review,
#   minus anything already claimed by an assignee.
#
# The graph filters first; the ramp then caps (v2, below). Up to 9 unrelated
# cards once ran at once on the same files, so width is no longer unlimited.
#
# `max_workers` is kept as a safety valve under the ramp cap. Absent or 0 means
# the ramp alone decides. Set it only to deliberately throttle a machine.
#
# THE BLOCKED SWEEP. `Blocked` used to be terminal: a card parked naming the
# issue it waited on, that issue later closed, and nothing ever read the note
# back. Cards sat until a human noticed — five of them did, on the board above.
# This script now reports, in `sweep`, every Blocked card whose blockers have all
# closed. The orchestrator moves them to Ready before launching, so they join the
# very next wave.
#
# FAIL SAFE ON AN UNREADABLE DEPENDENCY LINE. A card whose `## Blocked by`
# section cannot be parsed confidently is never treated as free. It is reported
# in `flag` so the orchestrator can comment on it, and it is left where it is.
# Guessing "runnable" is how a card gets built against a base branch that does
# not have what it needs. See super-board-deps.sh for what "unreadable" means and
# the three shapes that produce it.
#
# STRANDED BUILDING CARDS. No lane selects from Building: a Builder moves its card
# Ready → Building and on to QA in one lifecycle. A wave stopped (or crashed) in
# between leaves the card in Building, and nothing ever picks it up again. The
# planner runs only between waves, after the crash-recovery sweep has stripped
# leaked claims, so a Building card with no assignee has no live worker. It is
# reported in `stranded`; the orchestrator checks its branch and worktree and
# moves it back to Ready, keeping the branch.
#
# LABEL ROUTING (v3.0.0). One board shape for every project; a card's label picks
# its lane. Three labels: `qa`, `bug`, `feature`. A Ready card labelled `qa` skips
# the Builder and goes straight to the Tester (lane "qa"); every other Ready card,
# labelled or not, is built first (lane "build"). Each picked card carries `lane`
# and its `labels`. The old per-board `variant` is gone: a config still saying
# "qa-only" is refused (exit 65) until `super-board onboard` upgrades it, because
# reading it as "full" would start building on a board meant only for testing.
#
# GATE, RAMP, OVERLAP (v2). Free, on-goal Ready cards are admitted only with
# ACs and, unless labelled bug or qa, a `Must-have served:` number listed under
# `## Must have` in <repo.path>/docs/shape/north-star.md. The rest go to `refused`
# with a one-line reason; the orchestrator moves them to Backlog. The wave is
# capped at min(max_workers, ramp.stage); goal.foundation forces 1. In-flight
# cards go first; a Ready card whose `Files:` prefixes overlap a picked card is
# `deferred`. A card with no `Files:` line is `refused` ("no `Files:` line"): unknown
# files would overlap everything and defer it every wave. A Ready card whose AC
# `— test: <path>` the runner never runs, or whose open blocker is not on the
# board, goes to `flag` (left in Ready, not built) with the reason.
#
# Usage:
#   super-board-wave-plan.sh --config <config.json> [--items <project-items.json>]
#                            [--deps <deps.json>]
# Without --items, fetches live board state via super-board-card.sh items — the
# item-list shape for ~1 GraphQL point per 100 cards, where `gh project item-list`
# spends 101 per 100 (fieldValues x four nested connections).
# Without --deps, derives the graph via super-board-deps.sh. Pass --deps in tests
# to keep the script offline.
#
# Stdout:
#   { "cards": [ {"number":10,"status":"Review","title":"…","lane":"review","labels":[]} ],
#     "sweep": [ {"number":37,"title":"…","clearedBy":[32]} ],
#     "resume": [ {"number":51,"title":"…"} ],
#     "refreshApproval": [ {"number":52,"title":"…","why":"PR head changed after review"} ],
#     "refused": [ {"number":23,"reason":"no Acceptance Criteria checkboxes"} ],
#     "deferred": [ {"number":24,"title":"…","reason":"overlap"} ],
#     "flag":  [ {"number":82,"title":"…","why":"…"} ],
#     "stranded": [ {"number":44,"title":"…"} ] }
set -euo pipefail

CONFIG=""; ITEMS_FILE=""; DEPS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --items)  ITEMS_FILE="$2"; shift 2 ;;
    --deps)   DEPS_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[ -n "$CONFIG" ] && [ -e "$CONFIG" ] || { echo "config not found: ${CONFIG:-<unset>}" >&2; exit 66; }

# Read the config ONCE — $CONFIG may be a process substitution (test mode),
# which is a FIFO and cannot be read twice.
CONFIG_JSON=$(cat "$CONFIG")
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
printf '%s\n' "$CONFIG_JSON" | python3 "$HERE/super-board-verification-ready.py" --config -
export SB_REPO_PATH=$(echo "$CONFIG_JSON" | jq -r '.repo.path // "."')
python3 "$HERE/super-board-github-read.py" --check
VARIANT=$(echo "$CONFIG_JSON" | jq -r '.variant // ""')
# 0 or absent = unlimited. A wave is sized by the dependency graph, not a knob.
MAX_WORKERS=$(echo "$CONFIG_JSON" | jq -r '.max_workers // 0')
# The run's goal (factory #40): a milestone title. Set, only its Ready cards run;
# in-flight cards always finish. Empty = no goal filter (old behaviour).
GOAL=$(echo "$CONFIG_JSON" | jq -r '.goal.milestone // ""')
# Ramp: lanes never exceed ramp.stage (1–6, the owner's call); a foundation goal runs one at a time.
STAGE=$(echo "$CONFIG_JSON" | jq -r 'if .goal.foundation == true then 1 else (.ramp.stage // 1) end')
case "$STAGE" in 1|2|3|4|5|6) ;; *) echo "invalid ramp.stage in config: ${STAGE} (1 to 6)" >&2; exit 65 ;; esac
CAP=$STAGE
[ "$MAX_WORKERS" -gt 0 ] && [ "$MAX_WORKERS" -lt "$CAP" ] && CAP=$MAX_WORKERS
# Must-have numbers from the north star; null when the file is missing.
NORTH_STAR="$SB_REPO_PATH/docs/shape/north-star.md"
if [ -f "$NORTH_STAR" ]; then
  MUST=$(awk '/^## /{m = ($0 ~ /^## Must have[ \t]*$/)} m && /^[0-9]+\./{sub(/\..*/, ""); print}' "$NORTH_STAR" | jq -s -c .)
else
  MUST=null
fi
OWNER=$(echo "$CONFIG_JSON" | jq -r '.project.owner')
NUMBER=$(echo "$CONFIG_JSON" | jq -r '.project.number')

if [ -n "$ITEMS_FILE" ]; then
  ITEMS=$(cat "$ITEMS_FILE")
else
  ITEMS=$("$HERE/super-board-card.sh" --owner "$OWNER" --number "$NUMBER" items)
fi

# `variant` was removed in v3.0.0 (labels route cards now). Absent or "full" is
# fine. Anything else — "qa-only", or a typo — is refused loudly rather than
# guessed: a guess either builds on a test-only board or strands the QA column.
case "$VARIANT" in
  ""|full) COLUMNS='["Review","QA","Ready"]' ;;
  qa-only) echo "config still says variant \"qa-only\" — removed in v3.0.0. Run /super-board onboard: it upgrades the config and labels those cards qa." >&2; exit 65 ;;
  *) echo "invalid variant in config: ${VARIANT} (variant was removed in v3.0.0 — delete the key)" >&2; exit 65 ;;
esac

# The dependency graph. Only Ready and Blocked cards are gated by it — a card in
# QA or Review already passed its own preflight and is mid-flight.
if [ -n "$DEPS_FILE" ]; then
  DEPS=$(cat "$DEPS_FILE")
else
  REPO=$(echo "$CONFIG_JSON" | jq -r '.repo.remote // ""' \
           | sed -E 's#^https?://github\.com/##; s#\.git$##')
  [ -n "$REPO" ] || { echo "config.repo.remote is required to derive dependencies" >&2; exit 66; }
  HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # A graph we cannot fetch is not a graph of zero blockers. Fail rather than
  # plan a wave that treats every card as free.
  DEPS=$("$HERE/super-board-deps.sh" --repo "$REPO" --limit 300) || {
    rc=$?; echo "could not derive the dependency graph for ${REPO}" >&2; exit "$rc"; }
fi

# AC test paths the project's runner would never run. For each Ready card's
# `— test: <path>` ACs (deps `acTests`): a path on the base branch is fine; a path
# that is not there yet is fine when it sits inside the runner's literal include
# globs (a builder may create it, so a NEW test file in an include glob is never
# flagged); a path outside every glob is flagged. Globs come from a literal
# `include` (vitest), `testMatch` (jest) or `testDir`/`testMatch` (playwright) in
# the config at the repo root. No runner config, or one not readable as literals
# (spread, variable, regex), means the check is skipped: never guess.
BASE_BRANCH=$(echo "$CONFIG_JSON" | jq -r '.base_branch // "main"')
TEST_PAIRS=$(jq -n -c --argjson items "$ITEMS" --argjson deps "$DEPS" \
  '[ $items.items[] | select(.status == "Ready" and .content.type == "Issue")
     | .content.number as $n | { n: $n, t: ($deps[($n | tostring)].acTests // []) }
     | select(.t | length > 0) ]')
test_flags() { python3 - <<'PYEOF'
import json, os, re, subprocess, sys

repo, base = os.environ.get("SB_REPO_PATH", "."), os.environ["SB_BASE"]
pairs = json.loads(os.environ["SB_PAIRS"])
JS = ["ts", "mts", "cts", "js", "mjs", "cjs"]

def norm(p):
    return re.sub(r"^(\./)+", "", p)

def read(name):
    try:
        with open(os.path.join(repo, name), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None

def config(prefix, exts):
    for e in exts:
        src = read("%s.%s" % (prefix, e))
        if src is not None:
            return "%s.%s" % (prefix, e), src
    return None, None

def strip_block(src, key):
    # Drop key: { ... } so coverage.include is not read as test.include.
    while True:
        m = re.search(r"\b%s\s*:\s*\{" % key, src)
        if not m:
            return src
        i, depth = m.end(), 1
        while i < len(src) and depth:
            depth += {"{": 1, "}": -1}.get(src[i], 0)
            i += 1
        src = src[:m.start()] + src[i:]

def literal(src, key):
    # [] of strings after key:; None when the key is absent, False when not plain literals.
    m = re.search(r"\b%s\s*:\s*(\[[^\]]*\]|['\"\x60][^'\"\x60]*['\"\x60])" % key, src)
    if not m:
        return None if not re.search(r"\b%s\s*:" % key, src) else False
    body = m.group(1).strip()
    parts = body[1:-1].split(",") if body.startswith("[") else [body]
    out = []
    for p in parts:
        if not p.strip():
            continue
        s = re.match(r"""^\s*(['"\x60])([^'"\x60$]*)\1\s*$""", p)
        if not s:
            return False
        out.append(s.group(2))
    return out

globs, used, unreadable = [], [], False

name, src = config("vitest.config", JS)
if src is not None:
    v = literal(strip_block(src, "coverage"), "include")
    if v is None:
        v = ["**/*.{test,spec}.?(c|m)[jt]s?(x)"]  # vitest's documented default
    if v is False:
        unreadable = True
    else:
        globs += v; used.append(name)

name, src = config("jest.config", JS)
if src is not None:
    v = literal(src, "testMatch")
    if not v:  # absent (default too broad to judge), regex or non-literal
        unreadable = True
    else:
        globs += v; used.append(name)

name, src = config("playwright.config", JS)
if src is not None:
    d, m = literal(src, "testDir"), literal(src, "testMatch")
    if not d or len(d) != 1 or m is False:
        unreadable = True
    else:
        d = norm(d[0].strip()).rstrip("/")
        for p in (m or ["**/*.@(spec|test).?(c|m)[jt]s?(x)"]):
            p = norm(p)
            p = p if "/" in p else "**/" + p
            globs.append((d + "/" if d else "") + p)
        used.append(name)

if unreadable or not globs:
    print("{}"); sys.exit(0)  # unknown runner config: skip, never guess

def to_regex(g):
    out, i, stack = "", 0, []
    while i < len(g):
        c = g[i]
        if g.startswith("**/", i):
            out += "(?:.*/)?"; i += 3; continue
        if g.startswith("**", i):
            out += ".*"; i += 2; continue
        if g[i:i + 2] in ("?(", "@(", "*("):
            stack.append("?" if c == "?" else ("*" if c == "*" else "")); out += "(?:"; i += 2; continue
        if c in "{(":
            stack.append(""); out += "(?:"
        elif c in "})":
            out += ")" + (stack.pop() if stack else "")
        elif c in ",|":
            out += "|"
        elif c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        elif c == "[":
            k = g.find("]", i)
            if k < 0:
                out += r"\["
            else:
                out += g[i:k + 1]; i = k + 1; continue
        else:
            out += re.escape(c)
        i += 1
    return re.compile("^" + out + "$")

regs = [to_regex(g) for g in globs]

def on_base(path):
    for ref in ("origin/" + base, base):
        if subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", ref + "^{commit}"],
                          capture_output=True).returncode == 0:
            return subprocess.run(["git", "-C", repo, "cat-file", "-e", ref + ":" + path],
                                  capture_output=True).returncode == 0
    return os.path.exists(os.path.join(repo, path))  # no git ref: the working tree

flags = {}
for p in pairs:
    bad = [t for t in (norm(x) for x in p["t"])
           if not on_base(t) and not any(r.match(t) for r in regs)]
    if bad:
        flags[str(p["n"])] = ("AC cites " + ", ".join("\x60%s\x60" % t for t in bad) + ", not on " + base
                              + " and outside the test include globs (" + ", ".join(globs) + ") of "
                              + ", ".join(used) + ", so the runner never runs it")
print(json.dumps(flags))
PYEOF
}
TESTFLAGS=$(SB_BASE="$BASE_BRANCH" SB_PAIRS="$TEST_PAIRS" test_flags)

# Open `## Blocked by` issues that are not on the project board: nothing will ever
# move them, so a card waiting on one waits forever. Reported in `flag`.
BOARD_NUMBERS=$(echo "$ITEMS" | jq -c '[ .items[] | select(.content.type == "Issue") | .content.number ]')

# Review extras used to be gated behind human_approves_merge, because concurrent
# auto-merges into one base branch race. That guard now lives where the race
# actually is — the merge step takes a lock inside the wave workflow and the
# freshness gate re-verifies under it — so reviews may run in parallel here.
echo "$ITEMS" | jq --argjson cols "$COLUMNS" --argjson cap "$CAP" --argjson deps "$DEPS" --arg goal "$GOAL" \
                  --argjson must "$MUST" --argjson tf "$TESTFLAGS" --argjson board "$BOARD_NUMBERS" '
  def dep($n): $deps[($n | tostring)];
  # One-line reason a Ready card is refused, or "" when admitted.
  def refusal:
    dep(.number) as $d
    | ( if ($d.acs // 0) == 0 then "no Acceptance Criteria checkboxes" else empty end ),
      # No `Files:` line (or an empty one): the card cannot be placed against the
      # others, and unknown files overlap everything, so it would be deferred
      # forever as a look-alike file clash. Refused like a missing must-have.
      ( if (($d.files // []) | length) == 0 then "no `Files:` line" else empty end ),
      ( if (.labels | index("bug") or index("qa")) then empty
        elif $must == null then "docs/shape/north-star.md missing, so no must-have can be served"
        elif ($d.mustHave // []) == [] then "no `Must-have served:` line"
        elif ([ $d.mustHave[] | select(. as $n | $must | index($n) | not) ] | length) > 0
          then "`Must-have served:` names \([ $d.mustHave[] | select(. as $n | $must | index($n) | not) ] | map(tostring) | join(", ")), not in docs/shape/north-star.md"
        else empty end );
  def files_of($n): (dep($n).files // []);
  # Prefix overlap; a card with no `Files:` overlaps everything.
  def overlaps($a; $b): ($a == [] or $b == []) or
    any($a[]; . as $x | any($b[]; . as $y | ($x | startswith($y)) or ($y | startswith($x))));
  # gh project item-list puts label names on the item (`labels`); some shapes put
  # them on the content, as strings or {name}. Lower-cased, names only.
  def labels_of: [ ((.labels // []) + (.content.labels // []))[]
                   | (if type == "object" then .name else . end) | ascii_downcase ] | unique;
  def lane_of($status; $labels):
    if $status == "Review" then "review"
    elif $status == "QA" then "qa"
    elif ($labels | index("qa")) then "qa"
    else "build" end;
  # Unknown to the graph (closed, or beyond the fetch limit) is not "free".
  def free($n): (dep($n) | if . == null then false else .runnable end);
  # On the goal milestone of this run, or no goal set.
  def on_goal: $goal == "" or .milestone == $goal;

  [ .items[]
    | select(.content.type == "Issue")
    | select((.content.assignees // []) | length == 0)
    | labels_of as $l
    | { number: .content.number, status: .status, title: .content.title,
        lane: lane_of(.status; $l), labels: $l,
        milestone: (.milestone.title // .content.milestone.title // null) } ] as $all

  # In flight: already past preflight, so the graph does not gate them. Iterated
  # in $cols order (Review, then QA) rather than board order, so a throttled wave
  # spends its slots on the work closest to Done.
  | [ $cols[] as $c | $all[] | select(.status == $c and $c != "Ready") ] as $flight

  # Ready: only the ones the graph says are actually free, then the gate.
  | [ $all[] | select(.status == "Ready") | select(free(.number)) | select(on_goal)
      | . + { reason: ([ refusal ] | join("; ")) } ] as $gated
  # A card flagged for an AC test the runner never runs stays in Ready, unbuilt.
  | [ $gated[] | select(.reason == "") | select($tf[(.number | tostring)] == null) | del(.reason) ] as $ready
  # Free but not on the goal: reported so the report can say what is waiting, never run.
  | [ $all[] | select(.status == "Ready") | select(free(.number)) | select(on_goal | not)
      | { number, title, milestone } ] as $offgoal

  # Downstream-first, so work already begun finishes before new work starts.
  # Ready cards then pick greedily: one that overlaps a picked card is deferred.
  | reduce $ready[] as $c ({ picked: $flight[:$cap], deferred: [] };
      if (.picked | length) >= $cap then .
      elif any(.picked[]; overlaps(files_of(.number); files_of($c.number)))
        then .deferred += [ { number: $c.number, title: $c.title, reason: "overlap" } ]
      else .picked += [ $c ] end) as $pick
  | { cards: ($pick.picked | map(del(.milestone) | . + { judgement: (dep(.number).judgement // false) })),
      refused: [ $gated[] | select(.reason != "") | { number, reason } ],
      deferred: $pick.deferred,
      offGoal: $offgoal,

      # Blocked cards whose blockers have all closed. The orchestrator moves
      # these to Ready before launching, so they join this very wave.
      sweep: [ $all[]
               | select(.status == "Blocked")
               | select(free(.number))
               | { number, title,
                   clearedBy: (dep(.number) | .blockers) } ],

      # Verified current-head human approval from the dependency helper. The
      # Reviewer independently rechecks it; labels are only UI state.
      resume: [ $all[]
                | select(.status == "Blocked")
                | select(dep(.number) != null and (dep(.number).needsYouDone // false))
                | { number, title } ],

      # Changed code while Blocked needs a new review/request, never approval.
      refreshApproval: [ $all[]
                         | select(.status == "Blocked")
                         | select(dep(.number).approvalRefresh // false)
                         | { number, title, why: dep(.number).approvalWhy } ],

      # Cards the graph could not read. Left where they are, reported so the
      # orchestrator can ask for the line to be fixed.
      # Also flagged, one entry per card with the reasons joined: a Ready card whose
      # AC cites a test path the runner never runs, and a Ready/Blocked card waiting
      # on an open issue that is not on the project board.
      flag:  ( [ $all[]
               | select(.status as $s | ["Ready","Blocked"] | index($s))
               | . as $c | dep(.number) as $d
               | { number, title,
                   why: ( [ ( if $d != null and ($d.parseable | not) then $d.why else empty end ),
                            ( if .status == "Ready" and $tf[(.number | tostring)] != null
                              then $tf[(.number | tostring)] else empty end ),
                            ( [ ($d.openBlockers // [])[] | select(. as $b | $board | index($b) | not) ] as $off
                              | if ($off | length) > 0
                                then "waits on open \($off | map("#\(.)") | join(", ")), not on the project board, so nothing will ever move it"
                                else empty end ) ] | join("; ") ) }
               | select(.why != "") ] ),

      # Building with no claim between waves = no live worker. Back to Ready.
      stranded: [ $all[] | select(.status == "Building") | { number, title } ] }'
