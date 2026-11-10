#!/usr/bin/env bash
# Tests super-board-merge-gate.sh — the merge mutex and the freshness gate.
# Scenarios 1-7 stop at or before the first `gh pr view`. Scenarios 8-13 run past
# it against a local bare `origin` and a `gh` stub on PATH, to pin the head guard.
#
# The gate exists because `mergeable: CLEAN` was trusted twice on 2026-08-20 and
# was wrong both times: the text did not conflict, but a shared interface had
# grown on the base since the branch was tested, so the merge would have turned
# the base branch red. These tests pin the two properties that prevent it — one
# merge at a time, and the proof happens under the lock.
set -euo pipefail
cd "$(dirname "$0")"
GATE="../scripts/super-board-merge-gate.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

setup() {  # $1 = verify_commands JSON array
  TMP=$(mktemp -d)
  export SB_GITHUB_HALT_FILE="$TMP/halt.json" SB_GITHUB_RETRY_DELAY=0
  mkdir -p "$TMP/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/gh"
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
  mkdir -p "$TMP/.claude/super-board/inflight"
  printf '{"base_branch":"staging","repo":{"path":"%s","remote":"https://github.com/x/y.git"},"verify_commands":%s}' \
    "$TMP" "${1:-[\"git diff --check\"]}" > "$TMP/c.json"
  LOCK="$TMP/.claude/super-board/inflight/merge.lock"
}
teardown() { rm -rf "$TMP"; }

# 1 — a held, fresh lock makes a second caller wait and then give up with 4.
#     Exit 4 is distinct on purpose: "someone else is merging" is not the same
#     answer as "this branch is broken", and the caller routes them differently.
setup
mkdir -p "$LOCK"; date +%s > "$LOCK/at"
RC=0; "$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 --stale-after 9999 >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 4 ] || fail "a contended fresh lock should exit 4, got $RC"
[ -d "$LOCK" ] || fail "the loser must not delete the winner's lock"
teardown

# 2 — a lock older than --stale-after is reaped. A process that died holding it
#     would otherwise wedge every future merge on the board.
setup
mkdir -p "$LOCK"; echo $(( $(date +%s) - 99999 )) > "$LOCK/at"
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 --stale-after 60 2>&1 || true)
echo "$OUT" | grep -q "reaping a lock abandoned" || fail "an abandoned lock should be reaped, got: $OUT"
teardown

# 3 — THE REGRESSION THIS FILE EXISTS FOR. --lock-timeout and --stale-after must
#     be independent. A caller willing to wait 20 minutes must NOT thereby decide
#     that a 20-minute-old lock is dead: that reaps the very merge it is queued
#     behind. With them collapsed into one number (the first implementation), a
#     lock aged just past the wait window was stolen.
setup
mkdir -p "$LOCK"; echo $(( $(date +%s) - 30 )) > "$LOCK/at"
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 --stale-after 9999 2>&1 || true)
echo "$OUT" | grep -q "reaping" && fail "a 30s-old lock must survive a 6s waiter with stale-after 9999"
echo "$OUT" | grep -q "could not take the merge lock" || fail "the waiter should time out politely, got: $OUT"
teardown

# 4 — the default stale-after has an absolute floor, not just a multiple of the
#     wait. An impatient caller must not be able to reap by being impatient: with
#     only a 3x multiple, `--lock-timeout 6` outlived its own 18s threshold inside
#     the polling loop and stole a live lock.
setup
mkdir -p "$LOCK"; echo $(( $(date +%s) - 60 )) > "$LOCK/at"
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 2>&1 || true)
echo "$OUT" | grep -q "reaping" && fail "a 60s-old lock must survive an impatient waiter (floor is 1800s)"
echo "$OUT" | grep -q "could not take the merge lock" || fail "the impatient waiter should time out, got: $OUT"
teardown

# 5 — missing verification is a setup halt, not permission to merge.
for commands in '[]' '["", " ", "\t\n"]' '["\u0000"]' '["git\u0000 diff --check"]'; do
  setup "$commands"
  RC=0; OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 2>&1) || RC=$?
  [ "$RC" -eq 9 ] || fail "unusable verification must exit 9, got $RC: $OUT"
  echo "$OUT" | grep -q 'verification-readiness' || fail "must name the setup problem"
  echo "$OUT" | grep -q 'verify_commands' || fail "must name the setting to repair"
  [ ! -d "$LOCK" ] || fail "readiness failure must not acquire the merge lock"
  [ ! -f "$TMP/halt.json" ] || fail "readiness failure must not attempt GitHub reads"
  teardown
done
setup
jq 'del(.verify_commands)' "$TMP/c.json" > "$TMP/missing.json"
RC=0; "$GATE" --config "$TMP/missing.json" --pr 1 >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 9 ] || fail "missing verification must exit 9, got $RC"
teardown

# 6 — the lock is released on every exit path, including the failures above.
#     A gate that strands its own lock wedges the board it was written to protect.
setup
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 2>&1 || true)
[ ! -d "$LOCK" ] || fail "the lock must be released on exit, even when the run fails"
teardown

# 7 — usage errors are distinct from operational ones, so a caller never reads a
#     typo as "the branch is broken".
setup
RC=0; "$GATE" --config "$TMP/c.json" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 64 ] || fail "a missing --pr should exit 64, got $RC"
RC=0; "$GATE" --config /nope/nope.json --pr 1 >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 66 ] || fail "a missing config should exit 66, got $RC"
teardown

# ── Head guard (8-11). A real git origin with a `staging` base and a `feat`
#    branch; `gh` is a stub that reports feat's head and logs every call.
#    STUB_OID       — headRefOid `gh pr view` reports
#    STUB_OID_AFTER — headRefOid reported once a merge has been attempted
#    STUB_MERGE_RC  — exit code of `gh pr merge`
head_setup() {
  setup '["git diff --check"]'
  ORIGIN="$TMP/origin.git"; git init -q --bare "$ORIGIN"
  git -C "$TMP" init -q -b staging 2>/dev/null || { git -C "$TMP" init -q; git -C "$TMP" checkout -q -b staging; }
  git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$TMP" remote add origin "$ORIGIN"; git -C "$TMP" push -q origin staging
  git -C "$TMP" checkout -q -b feat
  echo proof > "$TMP/proof.txt"; git -C "$TMP" add proof.txt
  git -C "$TMP" -c user.email=t@t -c user.name=t commit -q -m feat
  git -C "$TMP" push -q origin feat; git -C "$TMP" checkout -q staging
  SHA=$(git -C "$TMP" rev-parse feat)
  mkdir -p "$TMP/bin"; export GH_LOG="$TMP/gh.log"; : > "$GH_LOG"
  cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")
    case "$*" in *state,mergeCommit*)
      [ "${STUB_STATE_FAIL:-0}" = 0 ] || { grep -q '^pr merge' "$GH_LOG" && exit 1; }
      state="${STUB_STATE:-OPEN}"; oid="$STUB_OID"; draft="${STUB_DRAFT:-0}"
      if grep -q '^pr merge' "$GH_LOG"; then state="${STUB_STATE_AFTER:-OPEN}"; oid="${STUB_OID_AFTER:-$STUB_OID}"; draft="${STUB_DRAFT_AFTER:-$draft}"; fi
      jq -n --arg state "$state" --arg head "$oid" --arg draft "$draft" '{state:$state,headRefOid:$head,isDraft:($draft=="1"),mergeCommit:(if $state=="MERGED" then {oid:$head} else null end)}'; exit 0 ;;
    esac
    case "$*" in *labels*)
      if [ -n "${STUB_META_AFTER:-}" ] && [ -f "$STUB_VERIFIED" ]; then printf '%s\n' "$STUB_META_AFTER"; exit 0; fi
      { if [ -n "${STUB_META:-}" ]; then printf '%s\n' "$STUB_META"; else echo '{"files":[],"labels":[],"body":"","additions":0,"deletions":0,"changedFiles":0}'; fi; } \
        | jq -c --arg raw "${STUB_RAW_BODY:-}" 'if $raw != "" or ((.body // "") | contains("sb:ac")) then . else .body = ((.body // "") + "\n<!-- sb:ac -->\n- [x] done\\\n  ↳ `proof.txt:1`\n<!-- /sb:ac -->") end'
      exit 0 ;; esac
    if [ -n "${STUB_HEAD+x}" ]; then printf '%s' "$STUB_HEAD"; exit 0; fi
    oid="$STUB_OID"; grep -q '^pr merge' "$GH_LOG" && oid="${STUB_OID_AFTER:-$STUB_OID}"
    echo "feat $oid" ;;
  "pr merge") exit "${STUB_MERGE_RC:-0}" ;;
  "pr diff")
    [ "${STUB_DIFF_FAIL:-0}" = 0 ] || exit 1
    if [ -n "${STUB_DIFF:-}" ]; then printf '%b' "$STUB_DIFF"; exit 0; fi
    python3 - <<'DIFF'
import json, os
m = json.loads(os.environ.get('STUB_META') or '{"files":[],"additions":0,"deletions":0}')
for i, f in enumerate(m.get('files', [])):
    p = f['path']; print(f'diff --git a/{p} b/{p}\n--- a/{p}\n+++ b/{p}')
    added = m.get('additions', 0) if i == 0 else 0
    removed = m.get('deletions', 0) if i == 0 else 0
    if added or removed:
        print(f'@@ -1,{removed} +1,{added} @@')
        print(''.join('-old\n' for _ in range(removed)) + ''.join('+new\n' for _ in range(added)), end='')
DIFF
    ;;
  "api graphql")
    jq -n --arg head "$STUB_OID" '[{data:{repository:{defaultBranchRef:{name:"main"},pullRequest:{headRefOid:$head,state:"OPEN",baseRefName:"main",body:"",closingIssuesReferences:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{number:42,repository:{nameWithOwner:"x/y"}}]}}}}}]' ;;
  "api --paginate")
    [ "${STUB_APPROVAL:-0}" = 1 ] || { echo '[[]]'; exit 0; }
    case "$*" in
      */issues/42/comments*) cat "$STUB_COMMENTS" ;;
      */issues/1/comments*) echo '[[]]' ;;
      *) exit 1 ;;
    esac ;;
  "api repos/x/y/collaborators/owner/permission")
    [ "${STUB_PERMISSION_FAIL:-0}" = 0 ] || exit 1
    echo '{"permission":"admin"}' ;;
  "api repos/"*)
    # The paginated file list the gate reads instead of `pr view --json files` (which stops at 100).
    case "$*" in */issues/*/events*) printf '%s' "${STUB_EVENTS:-[[]]}"; exit 0 ;; esac
    case "$*" in */pulls/*/files*) ;; *) exit 1 ;; esac
    # A file list too big for an environment variable comes from a file.
    if [ -n "${STUB_FILES_PAGES:-}" ]; then cat "$STUB_FILES_PAGES"; exit 0; fi
    meta="${STUB_META:-{\"files\":[]}}"
    if [ -n "${STUB_META_AFTER:-}" ] && [ -f "$STUB_VERIFIED" ]; then meta="$STUB_META_AFTER"; fi
    printf '%s' "$meta" | jq -c --argjson size "${STUB_PAGE_SIZE:-100}" \
      '. as $m | [.files | to_entries | map(.value as $f | {filename: $f.path, additions: ($f.additions // (if .key == 0 then $m.additions else 0 end)), deletions: ($f.deletions // (if .key == 0 then $m.deletions else 0 end))}) | . as $f | range(0; ([length, 1] | max); $size) | $f[.:(. + $size)]]'
    exit 0 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$TMP/bin/gh"
}
gate() { SB_GITHUB_RETRY_DELAY=0 SB_GITHUB_HALT_FILE="$TMP/halt.json" PATH="$TMP/bin:$PATH" "$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 "$@"; }

# 8 — head moved after review: the reviewed sha no longer matches the PR head.
#     Exit 6, and no merge is attempted on evidence gathered for another commit.
head_setup
RC=0; STUB_OID="$SHA" gate --expect-head deadbeef >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 6 ] || fail "a moved head should exit 6, got $RC"
grep -q '^pr merge' "$GH_LOG" && fail "no merge may be attempted when the head moved"
teardown

# 9 — head unchanged: merge pins the reviewed commit with --match-head-commit.
head_setup
RC=0; STUB_OID="$SHA" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "a matching head should merge (exit 0), got $RC"
grep -q -- "--match-head-commit $SHA" "$GH_LOG" || fail "merge must pass --match-head-commit $SHA, got: $(cat "$GH_LOG")"
teardown

# 9b — the squash message: --subject and --body-file reach `gh pr merge` (writing standard).
head_setup
printf -- '- 413 shows the size message\nCloses #1\n' > "$TMP/msg.md"
RC=0; STUB_OID="$SHA" gate --expect-head "$SHA" --subject "🐛 [fix] receipts: show a size error" --body-file "$TMP/msg.md" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "a merge with a subject should exit 0, got $RC"
grep -q -- "--subject 🐛 \[fix\] receipts: show a size error" "$GH_LOG" || fail "merge must pass --subject, got: $(cat "$GH_LOG")"
grep -q -- "--body-file $TMP/msg.md" "$GH_LOG" || fail "merge must pass --body-file, got: $(cat "$GH_LOG")"
RC=0; STUB_OID="$SHA" gate --expect-head "$SHA" --body-file /nope.md >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 66 ] || fail "an unreadable --body-file should exit 66, got $RC"
teardown

# 10 — a push lands during verification: GitHub refuses the pinned merge and the
#      head has moved, so this is void evidence (6), not branch protection (3).
head_setup
RC=0; STUB_OID="$SHA" STUB_OID_AFTER=cafef00dcafef00dcafef00dcafef00dcafef00d STUB_MERGE_RC=1 gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 6 ] || fail "a head that moved mid-gate should exit 6, got $RC"
teardown

# 11 — same refusal with the head unchanged is still GitHub saying no (3).
head_setup
RC=0; STUB_OID="$SHA" STUB_MERGE_RC=1 gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 79 ] || fail "unconfirmed merge must pause for reconciliation, got $RC"
teardown

# A lost merge response is reconciled, never blindly repeated.
head_setup
RC=0; STUB_OID="$SHA" STUB_STATE_AFTER=MERGED STUB_MERGE_RC=1 gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "GitHub-confirmed lost merge response must report merged"
[ "$(grep -c '^pr merge' "$GH_LOG")" -eq 1 ] || fail "merge mutation must only run once"
teardown
head_setup
RC=0; STUB_OID="$SHA" STUB_STATE_FAIL=1 STUB_MERGE_RC=1 gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 79 ] || fail "unreadable merge outcome must halt"
[ "$(grep -c '^pr merge' "$GH_LOG")" -eq 1 ] || fail "unknown merge outcome must not replay mutation"
teardown

# 12 — post-merge cleanup: when the cleanup-wt hook is installed the gate runs it with
#      --post-merge --base <base> after a merge, and its failure never fails the
#      merge that already happened.
head_setup
mkdir -p "$TMP/.claude/hooks"
printf 'import sys\nopen("%s/cleanup.args","w").write(" ".join(sys.argv[1:]))\nsys.exit(1)\n' "$TMP" \
  > "$TMP/.claude/hooks/cleanup-wt.py"
RC=0; STUB_OID="$SHA" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "a failing cleanup must not fail the merge, got $RC"
grep -q -- "--post-merge --base staging" "$TMP/cleanup.args" 2>/dev/null \
  || fail "cleanup-wt should run with --post-merge --base staging, got: $(cat "$TMP/cleanup.args" 2>/dev/null)"
teardown

# 13 — a refused merge never cleans up. (Scenario 9 is the no-cleanup-wt path.)
head_setup
mkdir -p "$TMP/.claude/hooks"
printf 'open("%s/cleanup.ran","w")\n' "$TMP" > "$TMP/.claude/hooks/cleanup-wt.py"
RC=0; STUB_OID="$SHA" STUB_MERGE_RC=1 gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 79 ] || fail "an unconfirmed merge should halt, got $RC"
[ ! -f "$TMP/cleanup.ran" ] || fail "cleanup must not run when the merge was refused"
teardown

# 13c — a draft PR is a retry (11), never a halt; so is a malformed head read (12).
head_setup
RC=0; STUB_DRAFT=1 STUB_OID="$SHA" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 11 ] || fail "a draft PR should exit 11, got $RC"
[ ! -f "$TMP/halt.json" ] || fail "a draft PR must never write a halt file"
grep -q '^pr merge' "$GH_LOG" && fail "no merge may be attempted on a draft"
RC=0; STUB_DRAFT_AFTER=1 STUB_MERGE_RC=1 STUB_OID="$SHA" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 11 ] || fail "GitHub refusing a draft at merge should exit 11, got $RC"
[ ! -f "$TMP/halt.json" ] || fail "a refused draft merge must never write a halt file"
for h in "" "feat" "feat not-a-sha" "{}"; do
  RC=0; STUB_HEAD="$h" STUB_OID="$SHA" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
  [ "$RC" -eq 12 ] || fail "a malformed head read ('$h') should exit 12, got $RC"
  [ ! -f "$TMP/halt.json" ] || fail "a malformed head read ('$h') must never write a halt file"
done
teardown

# ── Merge policy and migrations (14-25). Same origin and stub; STUB_META is the
#    `gh pr view --json labels,files,…` answer, STUB_DIFF the `gh pr diff` text.
cfgset() { jq "$1" "$TMP/c.json" > "$TMP/c2.json" && mv "$TMP/c2.json" "$TMP/c.json"; }
meta() {  # $1 labels csv, $2 files csv, $3 body, $4 size
  jq -cn --arg l "$1" --arg f "$2" --arg b "${3:-}" --argjson n "${4:-1}" \
    '{labels: ($l | split(",") | map(select(. != "") | {name: .})),
      files:  ($f | split(",") | map(select(. != "") | {path: .})),
      additions: $n, deletions: 0, body: $b} | .changedFiles = (.files | length)'
}

# Required policy evidence: an unavailable diff must halt before migrations or merge.
head_setup
cfgset ".migrations = {allowed_envs: [\"staging\"], target_env: \"staging\", commands: {staging: \"touch $TMP/ran\"}}"
RC=0; SB_GITHUB_RETRY_DELAY=0 STUB_DIFF_FAIL=1 STUB_OID="$SHA" STUB_META="$(meta "" supabase/migrations/1.sql)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 79 ] || fail "failed required diff must halt run (79), got $RC"
[ ! -f "$TMP/ran" ] || fail "no migration may run without policy evidence"
grep -q '^pr merge' "$GH_LOG" && fail "no merge may run without policy evidence"
[ "$(grep -c '^pr diff' "$GH_LOG")" -eq 3 ] || fail "exactly three failed read attempts"
teardown

# 13b — a big PR: the file list comes from the paginated REST endpoint (`pr view --json files`
#       stops at 100), pages are joined, and the count must match changedFiles. A PR with ANSI
#       codes in its diff is read with --allow-escape-sequences.
head_setup
BIGFILES=$(jq -cn '[range(0;130) | {path: "src/f\(.).ts", additions: 1, deletions: 0}]')
RC=0; STUB_PAGE_SIZE=100 STUB_OID="$SHA" STUB_META="$(jq -cn --argjson f "$BIGFILES" '{labels: [], body: "", additions: 130, deletions: 0, files: $f, changedFiles: 130}')" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "a 130-file PR read over two pages should merge, got $RC"
grep -q 'pr diff 1 .*--allow-escape-sequences' "$GH_LOG" || fail "the gate must read diffs with --allow-escape-sequences"
grep -q 'pulls/1/files?per_page=100 --paginate --slurp' "$GH_LOG" || fail "the gate must read the file list from the paginated REST endpoint"
teardown
head_setup
RC=0; STUB_OID="$SHA" STUB_META="$(jq -cn --argjson f "$BIGFILES" '{labels: [], body: "", additions: 130, deletions: 0, files: $f, changedFiles: 150}')" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 79 ] || fail "a file list shorter than changedFiles must halt (79), got $RC"

# 21b — a file list bigger than the OS argument limit (#68: 188 files with patches crashed jq
#       with "Argument list too long", exit 70). The gate reads it from files and gets past it.
head_setup
N=6000
jq -cn --argjson n "$N" '[[range(0; $n) | {filename: ("src/a/really/long/path/to/a/module/number-\(.)/that/keeps/going/index.ts"), additions: 1, deletions: 0, patch: ("@@ -0,0 +1 @@\n+" + ("x" * 200))}]]' > "$TMP/bigpages.json"
[ "$(wc -c < "$TMP/bigpages.json")" -gt 1100000 ] || fail "the big file list fixture should pass the argument limit"
RC=0; STUB_FILES_PAGES="$TMP/bigpages.json" STUB_OID="$SHA" STUB_META="$(jq -cn --argjson n "$N" '{labels: [], body: "", additions: $n, deletions: 0, changedFiles: $n}')" gate --expect-head "$SHA" > "$TMP/big.out" 2>&1 || RC=$?
grep -q "Argument list too long" "$TMP/big.out" && fail "a big file list must not hit the argument limit"
# Past the file read: no exit 70, and not read_meta's own "file list incomplete" halt. (The stub's
# fake diff names no files, so the later diff read stops; that step is covered by scenario 21.)
[ "$RC" -ne 70 ] || fail "a big file list must not crash the file read (70): $(tail -3 "$TMP/big.out")"
grep -q "PR #1 file list incomplete" "$TMP/big.out" && fail "a big file list must be read whole: $(tail -3 "$TMP/big.out")"
grep -q '^pr merge' "$GH_LOG" && fail "no merge may run on an incomplete file list"
teardown

# 14 — a money label: a human merges. Exit 7, the category is named, no merge.
head_setup
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta money src/x.ts)" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 7 ] || fail "a money label should exit 7, got $RC"
echo "$OUT" | grep -q "^human-gate: money — label money" || fail "exit 7 must name the category, got: $OUT"
grep -q '^pr merge' "$GH_LOG" && fail "no merge may be attempted on a human-gated PR"
teardown

# 15 — an auth path, by glob; merge_policy.default human; a diff over auto_max_lines.
head_setup
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" src/auth/session.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "a path under **/auth/** should exit 7, got $RC"
cfgset '.merge_policy = {default: "human"}'
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "merge_policy.default human should exit 7, got $RC"
# A big PR gets a deeper review, never the owner — unless its tier is red.
cfgset '.merge_policy = {default: "auto", auto_max_lines: 100}'
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts "" 400)" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 10 ] || fail "a big amber PR without deep-reviewed must exit 10, got $RC: $OUT"
echo "$OUT" | grep -q "^deep-review: big PR — deeper review: 400 changed lines" || fail "exit 10 must say why, got: $OUT"
grep -q '^pr merge' "$GH_LOG" && fail "a big PR must not merge before its deep review"
# The label counts only when added after the head commit.
OLD='[[{"event":"labeled","label":{"name":"deep-reviewed"},"created_at":"2001-01-01T00:00:00Z"}]]'
NEW='[[{"event":"labeled","label":{"name":"deep-reviewed"},"created_at":"2099-01-01T00:00:00Z"}]]'
RC=0; STUB_EVENTS="$OLD" STUB_OID="$SHA" STUB_META="$(meta deep-reviewed src/x.ts "" 400)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 10 ] || fail "a deep-reviewed label older than the head must exit 10, got $RC"
RC=0; STUB_EVENTS="$NEW" STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts "" 400)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 10 ] || fail "a removed deep-reviewed label must exit 10, got $RC"
grep -q '^pr merge' "$GH_LOG" && fail "no merge without a current deep review"
RC=0; STUB_EVENTS="$NEW" STUB_OID="$SHA" STUB_META="$(meta deep-reviewed src/x.ts "" 400)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "a big PR labelled deep-reviewed after its head should merge, got $RC"
printf 'zones:\n  red:\n    paths: ["src/**"]\n' > "$TMP/zones.yaml"
cfgset ".zones = \"$TMP/zones.yaml\""
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts "" 400)" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 7 ] || fail "a big red PR should exit 7, got $RC"
echo "$OUT" | grep -q "human-gate: size — big PR — please review" || fail "the red size gate must say big PR, got: $OUT"
teardown

# 15b — merge-policy size outcomes: the cap defaults to 600 source lines; over it
#       → "deep-review" (no human) unless red; tests do not count; 0 = no cap;
#       tier comes from the zones file (none → amber, unreadable → red).
T15=$(mktemp -d)
policy() {  # $1 config json, $2 meta json → policy stdout
  echo "$1" > "$T15/c.json"; echo "$2" > "$T15/m.json"
  python3 ../scripts/super-board-merge-policy.py --config "$T15/c.json" --meta "$T15/m.json" --diff /dev/null
}
sz() { jq -cn --argjson s "$1" --argjson t "${2:-0}" '{labels: [], body: "", files: [
  {path: "src/app.ts", additions: $s, deletions: 0},
  {path: "src/app.test.ts", additions: $t, deletions: 0}]}'; }
policy '{}' "$(sz 600)" | jq -e '.outcome == "auto" and .tier == "amber" and .human == []' >/dev/null \
  || fail "600 source lines is at the default cap and should be auto"
policy '{}' "$(sz 500 600)" | jq -e '.outcome == "auto" and .deep_review == null' >/dev/null \
  || fail "500 source + 600 test lines must not count the tests"
OUT=$(policy '{}' "$(sz 601)")
echo "$OUT" | jq -e '.outcome == "deep-review" and .human == [] and (.deep_review | test("601 changed lines > auto_max_lines 600"))' >/dev/null \
  || fail "601 source lines should be deep-review with no human, got: $OUT"
policy '{"merge_policy":{"auto_max_lines":0}}' "$(sz 5000)" | jq -e '.outcome == "auto"' >/dev/null \
  || fail "auto_max_lines 0 should turn the size cap off"
printf 'zones:\n  red:\n    paths: ["src/app.ts"]\n' > "$T15/z.yaml"
OUT=$(policy "{\"zones\":\"$T15/z.yaml\"}" "$(sz 601)")
echo "$OUT" | jq -e '.tier == "red" and .outcome == "human" and .human[0].category == "size"' >/dev/null \
  || fail "a big red PR should go to a human, got: $OUT"
policy "{\"zones\":\"$T15/z.yaml\"}" "$(sz 10)" | jq -e '.tier == "red" and .outcome == "auto"' >/dev/null \
  || fail "a small red PR is not gated for size"
printf 'zones:\n  red:\n    paths: [a\n' > "$T15/bad.yaml"
policy "{\"zones\":\"$T15/bad.yaml\"}" "$(sz 601)" | jq -e '.tier == "red" and .outcome == "human"' >/dev/null \
  || fail "an unreadable zones file must fail safe to red"
policy '{}' "$(jq -cn '{labels: [{name: "money"}], body: "", files: [{path: "src/a.ts", additions: 9000, deletions: 0}]}')" \
  | jq -e '.outcome == "human" and ([.human[].category] == ["money"])' >/dev/null \
  || fail "money stays human; a big amber PR adds no size entry"
rm -rf "$T15"

# 15d — a non-Claude host (config `host` only) merges by hand unless
#       merge_policy.default is "auto"; claude, no host and an explicit auto merge.
head_setup
for h in codex opencode; do
  cfgset ".host = \"$h\" | del(.merge_policy)"
  RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts)" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
  [ "$RC" -eq 7 ] || fail "host $h with no merge_policy.default should exit 7, got $RC"
  echo "$OUT" | grep -q "^human-gate: default — host $h: auto-merge not turned on" || fail "host $h gate must say why, got: $OUT"
done
grep -q '^pr merge' "$GH_LOG" && fail "no merge may run on a non-Claude host without auto"
cfgset '.host = "codex" | .merge_policy = {default: "auto"}'
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "host codex with merge_policy.default auto should merge, got $RC"
teardown
T15=$(mktemp -d); printf '%s' "$(meta "" src/x.ts)" > "$T15/m.json"
for c in '{"host":"claude"}' '{}' '{"host":"claude","merge_policy":{}}' '{"host":"opencode","merge_policy":{"default":"auto"}}'; do
  echo "$c" > "$T15/c.json"
  python3 ../scripts/super-board-merge-policy.py --config "$T15/c.json" --meta "$T15/m.json" --diff /dev/null \
    | jq -e '.human == []' >/dev/null || fail "config $c should leave a small clean PR ungated"
done
for c in '{"host":"codex"}' '{"host":"opencode","merge_policy":{"auto_max_lines":0}}'; do
  echo "$c" > "$T15/c.json"
  python3 ../scripts/super-board-merge-policy.py --config "$T15/c.json" --meta "$T15/m.json" --diff /dev/null \
    | jq -e '.human | length == 1 and .[0].category == "default"' >/dev/null \
    || fail "config $c should add one default human entry"
done
rm -rf "$T15"

# 15c — lockfiles, snapshots and generated files do not count toward the cap;
#       migration SQL is left out and reported separately; size_exclude is
#       configurable ([] counts everything).
head_setup
BIG=$(jq -cn '{labels: [], body: "", additions: 2300, deletions: 0, files: [
  {path: "src/x.ts", additions: 300, deletions: 0},
  {path: "package-lock.json", additions: 900, deletions: 0},
  {path: "src/__snapshots__/x.test.ts.snap", additions: 500, deletions: 0},
  {path: "src/api/__generated__/types.ts", additions: 400, deletions: 0},
  {path: "db/migrations/001_add.sql", additions: 200, deletions: 0}], changedFiles: 5}')
cfgset '.migrations = {allowed_envs: ["test"], target_env: "test", commands: {test: "true"}}'
RC=0; STUB_OID="$SHA" STUB_META="$BIG" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "300 counted lines (rest excluded) should merge, got $RC"
echo "$BIG" > "$TMP/big.json"
cfgset '.merge_policy = {auto_max_lines: 250}'
OUT=$(python3 ../scripts/super-board-merge-policy.py --config "$TMP/c.json" --meta "$TMP/big.json" --diff /dev/null)
echo "$OUT" | jq -e '.outcome == "deep-review" and (.deep_review | contains("300 changed lines > auto_max_lines 250 (+200 migration lines counted separately)"))' >/dev/null \
  || fail "size check should count 300 and report migration lines separately, got: $OUT"
cfgset '.merge_policy = {size_exclude: []}'
python3 ../scripts/super-board-merge-policy.py --config "$TMP/c.json" --meta "$TMP/big.json" --diff /dev/null \
  | jq -e '.outcome == "deep-review" and (.deep_review | test("^big PR — deeper review: 2100 "))' >/dev/null \
  || fail "size_exclude [] should count the lockfile"
teardown

# 16 — a destructive keyword counts in an ADDED line only. Deleting a DROP TABLE
#      is not adding one.
head_setup
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" db/x.sql)" STUB_DIFF='diff --git a/src/x.ts b/src/x.ts\n--- a/src/x.ts\n+++ b/src/x.ts\n@@ -0,0 +1 @@\n+DROP TABLE users;\n' gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "an added DROP TABLE should exit 7 (schema), got $RC"
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" db/x.sql | jq ' .additions=0 | .deletions=1')" STUB_DIFF='diff --git a/db/x.sql b/db/x.sql\n--- a/db/x.sql\n+++ b/db/x.sql\n@@ -1 +0,0 @@\n-DROP TABLE users;\n' gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "a removed DROP TABLE must not gate, got $RC"
for p in src/db.test.ts tests/schema.py e2e/fixtures/seed.ts test/fixtures/x.txt; do
  RC=0; STUB_OID="$SHA" STUB_META="$(meta "" "$p")" STUB_DIFF="diff --git a/$p b/$p\n--- a/$p\n+++ b/$p\n@@ -0,0 +1 @@\n+expect(sql).not.toContain('DROP TABLE users');\n" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
  [ "$RC" -eq 0 ] || fail "a DROP TABLE in a test or fixture ($p) must not gate, got $RC"
done
for p in tests/migrations/001.sql supabase/migrations/002_drop.sql; do
  RC=0; STUB_OID="$SHA" STUB_META="$(meta "" "$p")" STUB_DIFF="diff --git a/$p b/$p\n--- a/$p\n+++ b/$p\n@@ -0,0 +1 @@\n+DROP TABLE users;\n" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
  [ "$RC" -eq 7 ] || fail "a DROP TABLE in SQL or a migration ($p) must still gate, got $RC"
done
teardown

# 16b — a stale UI label cannot approve a policy gate.
head_setup
RC=0; STUB_OID="$SHA" STUB_META="$(meta money,needs-you:done src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "a needs-you:done label alone must not authorize a policy bypass, got $RC"
teardown

# 16c — a trusted done confirms the request emitted for the exact current head.
# The request exists before the human comment; processing never binds old done
# to whatever head happens to exist now.
head_setup
export STUB_APPROVAL=1 STUB_COMMENTS="$TMP/comments.json"
echo '[[]]' > "$STUB_COMMENTS"
OUT=$(STUB_OID="$SHA" STUB_META="$(meta money src/x.ts)" gate --expect-head "$SHA" 2>/dev/null || true)
REQUEST=$(echo "$OUT" | sed -n 's/^approval-request: //p')
[ -n "$REQUEST" ] || fail "a hold must emit a pinned request"
make_approval() {
  jq -n --argjson request "$REQUEST" '[[
    {id:1,body:("Reason tag: 🙋 needs you\napproval-request: " + ($request|tojson)),created_at:"2026-10-03T00:00:01Z",updated_at:"2026-10-03T00:00:01Z",user:{login:"owner",type:"User"}},
    {id:2,body:"done",created_at:"2026-10-03T00:00:02Z",updated_at:"2026-10-03T00:00:02Z",user:{login:"owner",type:"User"}}
  ]]' > "$STUB_COMMENTS"
}
make_approval
RC=0; STUB_OID="$SHA" STUB_META="$(meta money src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "current trusted approval must merge, got $RC"
: > "$GH_LOG"
# A later code version cannot reuse the same human's done.
REQUEST=$(echo "$REQUEST" | jq '.head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"')
make_approval
RC=0; STUB_OID="$SHA" STUB_META="$(meta money,needs-you:done src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "old-head approval must hold, got $RC"
grep -q '^pr merge' "$GH_LOG" && fail "old approval must never reach merge"
# Neither unreadable authority nor a newer human block can authorize.
REQUEST=$(echo "$REQUEST" | jq --arg head "$SHA" '.head=$head')
make_approval
RC=0; STUB_PERMISSION_FAIL=1 STUB_OID="$SHA" STUB_META="$(meta money src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 79 ] || fail "unreadable authority must halt, got $RC"
rm -f "$SB_GITHUB_HALT_FILE"  # next test starts a separate recovered run
jq '.[0] += [{id:3,body:"Reason tag: 🙋 new decision",created_at:"2026-10-03T00:00:03Z",updated_at:"2026-10-03T00:00:03Z",user:{login:"owner",type:"User"}}]' "$STUB_COMMENTS" > "$TMP/new.json"
mv "$TMP/new.json" "$STUB_COMMENTS"
RC=0; STUB_OID="$SHA" STUB_META="$(meta money,needs-you:done src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "new human block must revoke prior approval, got $RC"
# Verify takes time: a same-head body edit adds a new human step during it.
make_approval
export STUB_VERIFIED="$TMP/verified"
jq --arg cmd "touch $STUB_VERIFIED" '.verify_commands=[$cmd]' "$TMP/c.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/c.json"
RC=0; STUB_META_AFTER="$(meta money src/x.ts 'needs-you: run a new command')" STUB_OID="$SHA" STUB_META="$(meta money src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "changed human steps during verify must revoke approval, got $RC"
grep -q '^pr merge' "$GH_LOG" && fail "stale approval after verification must not merge"
unset STUB_APPROVAL STUB_COMMENTS STUB_VERIFIED
teardown

# 16d — head-bound approval also covers a declared human-only command; label
# changes cannot grant it, and a later human request during verification revokes it.
head_setup
export STUB_APPROVAL=1 STUB_COMMENTS="$TMP/comments.json"
echo '[[]]' > "$STUB_COMMENTS"
OUT=$(STUB_OID="$SHA" STUB_META="$(meta '' src/x.ts 'needs-you: confirm live setting')" gate --expect-head "$SHA" 2>/dev/null || true)
REQUEST=$(echo "$OUT" | sed -n 's/^approval-request: //p')
make_approval
RC=0; STUB_OID="$SHA" STUB_META="$(meta '' src/x.ts 'needs-you: confirm live setting')" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "trusted confirmation of current human step must merge, got $RC"
: > "$GH_LOG"
cat > "$TMP/new-block.py" <<'NEWBLOCK'
import json, os
p=os.environ["STUB_COMMENTS"]
x=json.load(open(p))
x[0].append({"id":3,"body":"Reason tag: 🙋 a new human decision","created_at":"2026-10-03T00:00:03Z","updated_at":"2026-10-03T00:00:03Z","user":{"login":"owner","type":"User"}})
with open(p,"w") as f: json.dump(x,f)
NEWBLOCK
jq --arg cmd "python3 $TMP/new-block.py" '.verify_commands=[$cmd]' "$TMP/c.json" > "$TMP/new.json"
mv "$TMP/new.json" "$TMP/c.json"
RC=0; STUB_OID="$SHA" STUB_META="$(meta '' src/x.ts 'needs-you: confirm live setting')" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 8 ] || fail "a newer human request during verification must hold, got $RC"
grep -q '^pr merge' "$GH_LOG" && fail "revoked human approval must not reach merge"
unset STUB_APPROVAL STUB_COMMENTS
teardown

# 17 — custom categories replace the defaults: with always_human = {} a money
#      label merges.
head_setup
cfgset '.merge_policy = {always_human: {}}'
RC=0; STUB_OID="$SHA" STUB_META="$(meta money src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "always_human {} should let a money label merge, got $RC"
teardown

# 18 — a migration whose target env is allowed: the gate runs the configured
#      command for each allowed env, then merges.
head_setup
cfgset ".migrations = {allowed_envs: [\"test\",\"staging\"], target_env: \"staging\",
        commands: {test: \"touch $TMP/ran-test\", staging: \"touch $TMP/ran-staging\"}}"
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" supabase/migrations/001_add.sql)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "an allowed migration should merge, got $RC"
[ -f "$TMP/ran-test" ] && [ -f "$TMP/ran-staging" ] || fail "both allowed migrate commands should have run"
teardown

# 19 — the target env is NOT allowed (live): 🙋 exit 8 with the exact command,
#      no merge. The allowed env still ran, so the human has one step left.
head_setup
cfgset ".migrations = {allowed_envs: [\"staging\"], target_env: \"live\",
        commands: {staging: \"touch $TMP/ran-staging\", live: \"npm run db:migrate:live\"}}"
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" prisma/migrations/2026/migration.sql)" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 8 ] || fail "a migration for a disallowed env should exit 8, got $RC"
echo "$OUT" | grep -q "^needs-you: npm run db:migrate:live" || fail "exit 8 must print the exact command, got: $OUT"
[ -f "$TMP/ran-staging" ] || fail "the allowed env should still migrate"
grep -q '^pr merge' "$GH_LOG" && fail "no merge while a human step is open"
teardown

# 20 — a UI label cannot confirm that human-only steps ran.
head_setup
cfgset ".migrations = {allowed_envs: [\"staging\"], target_env: \"live\",
        commands: {staging: \"true\", live: \"npm run db:migrate:live\"}}"
RC=0; STUB_OID="$SHA" STUB_META="$(meta needs-you:done prisma/migrations/2026/migration.sql)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 8 ] || fail "a needs-you:done label alone must not confirm human steps, got $RC"
teardown

# 21 — an allowed migrate command that FAILS is a needs-you, and needs-you:done
#      does not excuse a command that is failing right now.
head_setup
cfgset '.migrations = {allowed_envs: ["staging"], target_env: "staging", commands: {staging: "exit 3"}}'
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta needs-you:done drizzle/0001.sql)" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 8 ] || fail "a failing migrate command should exit 8, got $RC"
echo "$OUT" | grep -q "staging: failed in the merge gate" || fail "the failure must be named, got: $OUT"
teardown

# 22 — a human-only step declared in the PR body, on a PR with no migrations.
head_setup
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts 'Notes
needs-you: `npm run backfill -- --env live`')" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 8 ] || fail "a needs-you: line in the body should exit 8, got $RC"
echo "$OUT" | grep -q "^needs-you: npm run backfill -- --env live" || fail "the declared step must be printed, got: $OUT"
teardown

# 22b — the status block carries needs-you inside its alert (writing-standard.md § 2).
head_setup
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts '<!-- sb:status -->
> [!WARNING]
> 🛑 Blocked · needs you · Closes #7 · head `3f9c2a1`
> needs-you: `npm run backfill -- --env live`
<!-- /sb:status -->

<!-- sb:problem -->
## Problem
<!-- /sb:problem -->')" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 8 ] || fail "a needs-you line in the status alert should exit 8, got $RC"
echo "$OUT" | grep -q "^needs-you: npm run backfill -- --env live" || fail "the status-block step must be printed, got: $OUT"
teardown

# 23 — metadata the gate cannot read fails safe to a human (7), never to merge.
head_setup
RC=0; STUB_OID="$SHA" STUB_META='not json' gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 79 ] || fail "unreadable PR metadata should halt (79), got $RC"
teardown

# 24 — dry run: migrations are reported, never executed.
head_setup
cfgset ".migrations = {allowed_envs: [\"staging\"], target_env: \"staging\", commands: {staging: \"touch $TMP/ran\"}}"
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" supabase/migrations/1.sql)" gate --expect-head "$SHA" --dry-run 2>&1) || RC=$?
[ "$RC" -eq 0 ] || fail "a dry run should exit 0, got $RC"
[ ! -f "$TMP/ran" ] || fail "a dry run must not run a migrate command"
echo "$OUT" | grep -q "would migrate staging" || fail "a dry run should say what it would migrate, got: $OUT"
teardown

# 25 — the glob dialect: **/ spans zero or more directories; * stays in one segment.
P="../scripts/super-board-merge-policy.py"
pol() { printf '%s' "$1" > "$T25/m.json"; python3 "$P" --config "$T25/c.json" --meta "$T25/m.json" --diff /dev/null; }
T25=$(mktemp -d); echo '{"base_branch":"staging","migrations":{"globs":["**/migrations/*.sql"]}}' > "$T25/c.json"
pol "$(meta "" migrations/1.sql)"          | jq -e '.migrations == ["migrations/1.sql"]' >/dev/null || fail "**/ should match zero directories"
pol "$(meta "" a/b/migrations/1.sql)"      | jq -e '.migrations | length == 1' >/dev/null || fail "**/ should match nested directories"
pol "$(meta "" migrations/old/1.sql)"      | jq -e '.migrations | length == 0' >/dev/null || fail "* must not cross a /"
rm -rf "$T25"

# Dry-run also reports missing verification before querying or merging a PR.
head_setup
jq '.verify_commands = ["", " "]' "$TMP/c.json" > "$TMP/invalid.json"
RC=0; STUB_OID="$SHA" "$GATE" --config "$TMP/invalid.json" --pr 1 --dry-run >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 9 ] || fail "dry-run must expose missing verification as setup, got $RC"
[ ! -s "$GH_LOG" ] || fail "unready setup must not call GitHub"
teardown

# A real configured command still runs; a failed project check blocks the merge.
head_setup
jq '.verify_commands = ["", " ", "git rev-parse --verify nonexistent-ref"]' "$TMP/c.json" > "$TMP/failing.json"
RC=0; STUB_OID="$SHA" "$GATE" --config "$TMP/failing.json" --pr 1 --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ] || fail "failed configured project check must exit 2, got $RC"
grep -q '^pr merge' "$GH_LOG" && fail "failed check must not merge"
teardown

# 26 — acceptance checklist (exit 13): unticked, missing proof file, no block, non-path proof
#      are refused with the AC named; every AC ticked and proven merges.
ac_meta() { meta "" "src/a.ts" "$1"; }
ac_run() { RC=0; OUT=$(STUB_RAW_BODY=1 STUB_OID="$SHA" STUB_META="$(ac_meta "$1")" gate --expect-head "$SHA" 2>&1) || RC=$?; }
head_setup
ac_run $'<!-- sb:ac -->\n- [x] one\\\n  ↳ `proof.txt:1`\n- [ ] two\\\n  ↳ not verified yet\n<!-- /sb:ac -->'
[ "$RC" -eq 13 ] || fail "an unticked AC must exit 13, got $RC: $OUT"
echo "$OUT" | grep -q '^AC2: unticked$' || fail "should name AC2, got: $OUT"
echo "$OUT" | grep -q '^AC1' && fail "a proven AC must not be listed"
grep -q '^pr merge' "$GH_LOG" && fail "an unticked AC must not merge"
[ ! -d "$LOCK" ] || fail "the lock must be released on exit 13"
ac_run $'<!-- sb:ac -->\n- [x] one\\\n  ↳ `tests/x.test.ts:3`\n<!-- /sb:ac -->'
[ "$RC" -eq 13 ] || fail "a missing proof file must exit 13, got $RC"
echo "$OUT" | grep -q "^AC1: proof tests/x.test.ts not in $SHA\$" || fail "should name the missing file, got: $OUT"
ac_run $'<!-- sb:ac -->\n- [x] one\\\n  ↳ manual: screenshot\n<!-- /sb:ac -->'
[ "$RC" -eq 13 ] || fail "a non-path proof must exit 13, got $RC"
ac_run "no checklist here"
[ "$RC" -eq 13 ] || fail "no ac block must exit 13, got $RC"
echo "$OUT" | grep -q 'no acceptance checklist' || fail "should say no acceptance checklist, got: $OUT"
grep -q '^pr merge' "$GH_LOG" && fail "a refused checklist must not merge"
RC=0; STUB_RAW_BODY=1 STUB_OID="$SHA" STUB_META="$(ac_meta "no checklist")" gate --expect-head "$SHA" --dry-run >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 13 ] || fail "--dry-run must check the checklist too, got $RC"
ac_run $'<!-- sb:ac -->\n- [x] one\\\n  ↳ `proof.txt:1` · passes\n- [X] two\\\n  ↳ `proof.txt`\n<!-- /sb:ac -->'
[ "$RC" -eq 0 ] || fail "every AC ticked and proven should merge, got $RC: $OUT"
grep -q '^pr merge' "$GH_LOG" || fail "a proven checklist must merge"
teardown

echo "PASS: test-merge-gate.sh (merge, policy and approval scenarios)"
