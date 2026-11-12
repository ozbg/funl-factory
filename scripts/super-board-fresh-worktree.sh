#!/usr/bin/env bash
# Brings a card worktree up to date with its base before the Builder starts (#99).
#
# A worktree cut before a dependency merged reads stale code: the Builder then
# blocks the card for something already on the base. This script fetches the base,
# checks each merged dependency's merge commit is in HEAD, and refreshes when not:
#   - branch not on the remote yet (no shared history) → rebase onto <remote>/<base>
#   - branch already pushed (a rebuild)                 → merge <remote>/<base> in
# It never force-pushes and never pushes at all.
#
# Usage: super-board-fresh-worktree.sh --base <branch> [--remote origin] [--dir <worktree>] [<sha>...]
#   <sha>: the merge commit of each `Blocked by` card's merged PR
#          (super-board-github-read.py --kind merge-state -- pr view <P> → mergeCommit.oid).
# Prints one line per sha: `present <sha>` or `not-merged <sha>`, plus `refreshed rebase|merge`.
# Exit: 0 every sha is in HEAD — a block naming these dependencies is refused
#       5 at least one sha is not on the base — a block may name only those
#       3 refresh needed but the worktree has uncommitted changes (nothing changed)
#       4 refresh hit a conflict (aborted, worktree as it was)
#       2 bad input or git fetch failed
set -uo pipefail

BASE="" REMOTE=origin DIR=. SHAS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) SHAS+=("$1"); shift ;;
  esac
done
[ -n "$BASE" ] || { echo "--base is required" >&2; exit 2; }
g() { git -C "$DIR" "$@"; }

g fetch -q "$REMOTE" "$BASE" || { echo "git fetch $REMOTE $BASE failed" >&2; exit 2; }
UPSTREAM="$REMOTE/$BASE"
g rev-parse -q --verify "refs/remotes/$UPSTREAM" >/dev/null \
  || g fetch -q "$REMOTE" "+refs/heads/$BASE:refs/remotes/$UPSTREAM" \
  || { echo "cannot resolve $UPSTREAM" >&2; exit 2; }

on_base=() missing=() stale=0
for sha in ${SHAS[@]+"${SHAS[@]}"}; do
  if g cat-file -e "$sha^{commit}" 2>/dev/null && g merge-base --is-ancestor "$sha" "$UPSTREAM"; then
    on_base+=("$sha")
    g merge-base --is-ancestor "$sha" HEAD || stale=1
  else
    missing+=("$sha")
  fi
done

if [ "$stale" = 1 ]; then
  if [ -n "$(g status --porcelain)" ]; then
    echo "worktree is behind $UPSTREAM but has uncommitted changes; commit or stash, then rerun" >&2
    exit 3
  fi
  branch=$(g symbolic-ref -q --short HEAD || true)
  if [ -n "$branch" ] && g ls-remote --exit-code -q --heads "$REMOTE" "$branch" >/dev/null 2>&1; then
    g merge -q --no-edit "$UPSTREAM" >/dev/null 2>&1 \
      || { g merge --abort 2>/dev/null; echo "merge of $UPSTREAM conflicts; aborted" >&2; exit 4; }
    echo "refreshed merge"
  else
    g rebase -q "$UPSTREAM" >/dev/null 2>&1 \
      || { g rebase --abort 2>/dev/null; echo "rebase onto $UPSTREAM conflicts; aborted" >&2; exit 4; }
    echo "refreshed rebase"
  fi
fi

for sha in ${on_base[@]+"${on_base[@]}"}; do echo "present $sha"; done
for sha in ${missing[@]+"${missing[@]}"}; do echo "not-merged $sha"; done
[ "${#missing[@]}" -eq 0 ] || exit 5
exit 0
