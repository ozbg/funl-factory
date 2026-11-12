#!/usr/bin/env bash
# Tests scripts/super-board-fresh-worktree.sh on a throwaway repo with a bare origin (#99).
# Pins: a worktree cut before a dependency merged is refreshed (rebase when unpushed,
# merge when pushed), a dependency on the base exits 0 so a block naming it is refused,
# an unmerged dependency exits 5, and a dirty or conflicting worktree is left as it was.
set -euo pipefail
cd "$(dirname "$0")"
FW="$(pwd)/../scripts/super-board-fresh-worktree.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare -b trunk "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
R="$T/repo"
g() { git -C "$R" "$@"; }
commit() { echo "$2" > "$1/$3"; git -C "$1" add "$3"; git -C "$1" commit -qm "$3 $2"; }

g switch -q -c trunk 2>/dev/null || true
commit "$R" 1 base.txt; g push -q origin trunk

# Card worktrees cut from the old base, before dependency #24 merged.
g worktree add -q -b issue-26-new "$R/.claude/worktrees/issue-26-build" origin/trunk
g worktree add -q -b issue-27-pushed "$R/.claude/worktrees/issue-27-build" origin/trunk
g worktree add -q -b issue-28-dirty "$R/.claude/worktrees/issue-28-build" origin/trunk
g worktree add -q -b issue-29-clash "$R/.claude/worktrees/issue-29-build" origin/trunk
W26="$R/.claude/worktrees/issue-26-build" W27="$R/.claude/worktrees/issue-27-build"
W28="$R/.claude/worktrees/issue-28-build" W29="$R/.claude/worktrees/issue-29-build"
commit "$W26" 1 card26.txt
commit "$W27" 1 card27.txt; git -C "$W27" push -q origin issue-27-pushed
echo scratch > "$W28/notes.txt"
commit "$W29" mine accept.txt

# #24 merges on the base after the worktrees were cut.
g switch -q -c dep24 trunk; commit "$R" 1 accept.txt; g switch -q trunk
g merge -q --no-ff --no-edit dep24; g push -q origin trunk
DEP=$(g rev-parse trunk)
g reset -q --hard HEAD~1            # local trunk stays stale too: only the fetch knows
g switch -q -c later dep24
commit "$R" 1 later.txt; LATER=$(g rev-parse HEAD); g switch -q trunk

# AC1: unpushed branch is rebased, so #24's accept step is now in the worktree.
out=$(bash "$FW" --base trunk --dir "$W26" "$DEP") || fail "stale unpushed worktree exited $?: $out"
grep -qx "refreshed rebase" <<<"$out" || fail "unpushed branch not rebased: $out"
grep -qx "present $DEP" <<<"$out" || fail "dependency not reported present: $out"
[ -f "$W26/accept.txt" ] && [ -f "$W26/card26.txt" ] || fail "rebase lost base or card work"
[ "$(git -C "$W26" rev-list --merges HEAD ^"$DEP" | wc -l | tr -d ' ')" = 0 ] || fail "rebase made a merge"

# AC1: pushed branch is merged, never rebased (shared history stays).
before=$(git -C "$W27" rev-parse HEAD)
out=$(bash "$FW" --base trunk --dir "$W27" "$DEP") || fail "stale pushed worktree exited $?: $out"
grep -qx "refreshed merge" <<<"$out" || fail "pushed branch not merged: $out"
git -C "$W27" merge-base --is-ancestor "$before" HEAD || fail "pushed branch history rewritten"
[ -f "$W27/accept.txt" ] || fail "merge did not bring the dependency"

# AC2: already fresh, dependency on base → exit 0, no refresh: the block is refused.
out=$(bash "$FW" --base trunk --dir "$W26" "$DEP") || fail "fresh worktree exited $?"
grep -q refreshed <<<"$out" && fail "fresh worktree refreshed again: $out"
grep -qx "present $DEP" <<<"$out" || fail "fresh dependency not present: $out"

# A dependency not on the base → exit 5 and named: that block may stand.
set +e; out=$(bash "$FW" --base trunk --dir "$W26" "$DEP" "$LATER"); rc=$?; set -e
[ "$rc" = 5 ] || fail "unmerged dependency exited $rc, want 5"
grep -qx "not-merged $LATER" <<<"$out" || fail "unmerged dependency not named: $out"
set +e; bash "$FW" --base trunk --dir "$W26" deadbeef >/dev/null; rc=$?; set -e
[ "$rc" = 5 ] || fail "unknown sha exited $rc, want 5"

# Dirty worktree is left alone.
set +e; bash "$FW" --base trunk --dir "$W28" "$DEP" 2>/dev/null; rc=$?; set -e
[ "$rc" = 3 ] || fail "dirty worktree exited $rc, want 3"
[ ! -f "$W28/accept.txt" ] && [ -f "$W28/notes.txt" ] || fail "dirty worktree changed"

# Conflict aborts and leaves the worktree as it was.
before=$(git -C "$W29" rev-parse HEAD)
set +e; bash "$FW" --base trunk --dir "$W29" "$DEP" 2>/dev/null; rc=$?; set -e
[ "$rc" = 4 ] || fail "conflict exited $rc, want 4"
[ "$(git -C "$W29" rev-parse HEAD)" = "$before" ] && [ -z "$(git -C "$W29" status --porcelain)" ] \
  || fail "conflict left the worktree changed"

# Bad input.
set +e; bash "$FW" --dir "$W26" 2>/dev/null; rc=$?; set -e
[ "$rc" = 2 ] || fail "missing --base exited $rc, want 2"
echo "PASS: fresh-worktree"
