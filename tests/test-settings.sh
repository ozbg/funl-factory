#!/usr/bin/env bash
# Tests super-board-settings.py allow — onboard's Permissions step: print the diff,
# write only after approval, keep every existing key, add each rule once.
set -euo pipefail
cd "$(dirname "$0")"
S="$PWD/../scripts/super-board-settings.py"
fail() { echo "FAIL: $1" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
F="$T/.claude/settings.json"; mkdir -p "$T/.claude"
echo '{"permissions":{"allow":["Bash(ls:*)"]},"model":"x"}' > "$F"

# 1 — --dry-run prints the diff and writes nothing.
OUT=$(python3 "$S" allow "$F" 'Bash(gh pr merge:*)' 'Bash(ls:*)' --dry-run)
[ "$OUT" = "+ Bash(gh pr merge:*)" ] || fail "dry run should list only the new rule, got: $OUT"
jq -e '.permissions.allow == ["Bash(ls:*)"]' "$F" >/dev/null || fail "dry run wrote the file"

# 2 — a real run adds once, keeps other keys, backs up; a second run is a no-op.
python3 "$S" allow "$F" 'Bash(gh pr merge:*)' >/dev/null
jq -e '.permissions.allow == ["Bash(ls:*)","Bash(gh pr merge:*)"] and .model == "x"' "$F" >/dev/null || fail "merge lost or duplicated: $(cat "$F")"
ls "$T/.claude" | grep -q '^settings.json.bak-' || fail "no backup before writing"
python3 "$S" allow "$F" 'Bash(gh pr merge:*)' | grep -q "already present" || fail "second run should change nothing"

# 3 — invalid JSON is left exactly as it was (exit 2); no file → created.
printf '{ nope' > "$F"; RC=0; python3 "$S" allow "$F" 'X' >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ] && [ "$(cat "$F")" = "{ nope" ] || fail "invalid settings must be untouched (rc $RC)"
python3 "$S" allow "$T/new/settings.json" 'X' >/dev/null && jq -e '.permissions.allow == ["X"]' "$T/new/settings.json" >/dev/null || fail "a missing file should be created"

# 4 — runner-rules prints the project's own test-runner rules, one per line (#94).
P="$T/proj"; mkdir -p "$P"
echo '{"devDependencies":{"@playwright/test":"1","vitest":"1","typescript":"5"}}' > "$P/package.json"
OUT=$(python3 "$S" runner-rules "$P")
for r in 'Bash(npm ci:*)' 'Bash(npm test:*)' 'Bash(npm run:*)' 'Bash(npx playwright:*)' 'Bash(npx vitest:*)' 'Bash(npx tsc:*)'; do
  printf '%s\n' "$OUT" | grep -qxF "$r" || fail "runner-rules missed $r, got: $OUT"
done
printf '%s\n' "$OUT" | grep -q 'jest\|pnpm' && fail "runner-rules added a runner the project does not use: $OUT"
touch "$P/pnpm-lock.yaml"; printf 'test:\n\tgo test\n' > "$P/Makefile"
OUT=$(python3 "$S" runner-rules "$P")
printf '%s\n' "$OUT" | grep -qxF 'Bash(pnpm test:*)' || fail "pnpm lockfile should pick pnpm, got: $OUT"
printf '%s\n' "$OUT" | grep -qxF 'Bash(npm test:*)' && fail "pnpm project should not get npm rules"
printf '%s\n' "$OUT" | grep -qxF 'Bash(make test:*)' || fail "Makefile test target missed"
[ -z "$(python3 "$S" runner-rules "$T/new")" ] || fail "a folder with no runner should print nothing"

echo "PASS: test-settings.sh (4 scenarios)"
