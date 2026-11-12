#!/usr/bin/env bash
# Tests get.sh, the one-line installer, offline: the pack is served as a local
# file:// tarball (SUPER_BOARD_TARBALL), and npx is a stub on PATH that logs its
# arguments instead of reaching the network. Each case installs into a fresh
# temp target and checks what landed.
set -euo pipefail
cd "$(dirname "$0")/.."
PACK="$PWD"
GET="$PACK/get.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A tarball shaped like GitHub's: one top-level folder holding the pack.
mkdir -p "$WORK/src/super-board-test"
tar -cf - --exclude ./.git --exclude ./evals --exclude ./docs . | tar -xf - -C "$WORK/src/super-board-test"
tar -czf "$WORK/pack.tgz" -C "$WORK/src" super-board-test
export SUPER_BOARD_TARBALL="file://$WORK/pack.tgz"

# Stubs: npx records its argv and, like `npx skills add`, drops a SKILL.md into
# .claude/skills for every --skill it names; gh and jq exist so no warnings fire.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/npx" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$NPX_LOG"
want=0
for a in "$@"; do
  if [ "$want" -eq 1 ]; then mkdir -p ".claude/skills/$a"; echo "fixture $a" > ".claude/skills/$a/SKILL.md"; want=0; fi
  [ "$a" = "--skill" ] && want=1
done
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/gh"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/jq"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
export NPX_LOG="$WORK/npx.log"
export HOME="$WORK/home"; mkdir -p "$HOME"   # keep the real ~/.claude/skills out of the "already present" check

bash -n "$GET" || fail "get.sh has a syntax error"

M="$PACK/skills/families.json"
WANT=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join(sorted([n for f in d.values() if f.get("install") == "pack" for n in f["skills"]] + list(d["helpers"]["skills"]))))' "$M")
HELPERS=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["helpers"]["skills"]))' "$M")
MATT_HELPERS=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["helpers"]["sources"]["mattpocock/skills"]))' "$M")

# 1 — default install into --target: the 10 pack skills land, hooks wired, and the
#     7 helpers are fetched by name (never --skill '*'). Exactly 17 skills result.
T="$WORK/t1"; mkdir -p "$T"; : > "$NPX_LOG"
out=$(bash "$GET" --target "$T" 2>&1) || fail "default install exited non-zero: $out"
for s in super-board super-build super-qa super-review super-collect git-sync pr-security-review north-star; do
  [ -f "$T/.claude/skills/$s/SKILL.md" ] || fail "skill $s not installed"
done
[ -x "$T/.claude/bin/super-board-wave-plan.sh" ] || fail "dispatcher script not installed"
[ -f "$T/.claude/workflows/super-board-wave.js" ] || fail "workflow not installed"
[ -f "$T/.claude/settings.json" ] || fail "hooks were not merged into settings.json"
grep -q 'add mattpocock/skills --skill tdd' "$NPX_LOG" || fail "helper skills step not called by name (npx log: $(cat "$NPX_LOG"))"
grep -q 'add obra/superpowers --skill verification-before-completion -a claude-code -y' "$NPX_LOG" || fail "verification-before-completion not fetched: $(cat "$NPX_LOG")"
for h in $HELPERS; do grep -q -- "--skill $h " "$NPX_LOG" || fail "helper $h not named: $(cat "$NPX_LOG")"; done
! grep -q "'\*'\|--skill \*\|security-audit" "$NPX_LOG" || fail "get.sh must name helpers, never '*' or security-audit: $(cat "$NPX_LOG")"
[ "$(ls "$T/.claude/skills" | sort)" = "$WANT" ] || fail "fresh install should end with exactly 17 skills: $(diff <(echo "$WANT") <(ls "$T/.claude/skills" | sort))"
echo "$out" | grep -q '/super-board onboard' || fail "summary is missing the next step"
n=$(printf '%s\n' "$out" | grep -c '/super-board onboard' || true)
[ "$n" -eq 1 ] || fail "the next step should be printed once, got $n times: $out"

# 2 — flags pass through to install.sh, positional target works from piped stdin.
T="$WORK/t2"; mkdir -p "$T"; : > "$NPX_LOG"
bash -s -- --protect-main --no-helper-skills "$T" < "$GET" >/dev/null 2>&1 || fail "piped install with --protect-main failed"
grep -q 'guard-protected-push' "$T/.claude/settings.json" || fail "--protect-main was not passed through to install.sh"
[ ! -s "$NPX_LOG" ] || fail "--no-helper-skills still called npx"

# 3 — --no-hooks passes through: no settings.json, no hooks dir.
T="$WORK/t3"; mkdir -p "$T"
bash "$GET" --no-hooks --no-helper-skills --target "$T" >/dev/null 2>&1 || fail "--no-hooks install failed"
[ ! -e "$T/.claude/settings.json" ] || fail "--no-hooks still wrote settings.json"
[ -f "$T/.claude/skills/super-board/SKILL.md" ] || fail "--no-hooks install skipped the skills"

# 4 — a lock that lists mattpocock/skills is not enough: helpers missing on disk are
#     fetched again. All 18 on disk: npx is not called.
T="$WORK/t4"; mkdir -p "$T"; : > "$NPX_LOG"
printf '{"skills":{"tdd":{"source":"mattpocock/skills"}}}\n' > "$T/skills-lock.json"
bash "$GET" --target "$T" >/dev/null 2>&1 || fail "install with a lock but no helpers failed"
grep -q 'add mattpocock/skills' "$NPX_LOG" || fail "a lock entry alone must not count as installed"
: > "$NPX_LOG"
out=$(bash "$GET" --target "$T" 2>&1) || fail "install with helpers present failed"
[ ! -s "$NPX_LOG" ] || fail "all 18 helpers present, but npx was called: $(cat "$NPX_LOG")"
echo "$out" | grep -q '^🧠 helper skills: already installed$' || fail "summary should say helper skills are already installed"

# 4b — Matt Pocock's helpers on disk, verification-before-completion missing: only its source is fetched.
T="$WORK/t4b"; mkdir -p "$T"; : > "$NPX_LOG"
for h in $MATT_HELPERS; do mkdir -p "$T/.claude/skills/$h"; echo x > "$T/.claude/skills/$h/SKILL.md"; done
bash "$GET" --target "$T" >/dev/null 2>&1 || fail "install with only Matt's helpers failed"
! grep -q 'mattpocock/skills' "$NPX_LOG" || fail "mattpocock/skills helpers present, but npx fetched them"
grep -q 'obra/superpowers --skill verification-before-completion' "$NPX_LOG" || fail "missing verification-before-completion was not fetched"

# 4c — upgrade over an app with 49 skills (old pack + Matt's whole set + security-audit,
#      as a lock says): ends with exactly the 17, pruned ones backed up.
T="$WORK/t4c"; mkdir -p "$T/.claude/skills"; : > "$NPX_LOG"
OLD="to-spec to-tickets ask-matt chief-of-staff git-guardrails-claude-code grill-me grill-with-docs implement implement-spec loop-me migrate-to-shoehorn pr scaffold-exercises setup-matt-pocock-skills setup-pre-commit setup-ts-deep-modules teach wait-what wayfinder writing-beats writing-for-agents writing-fragments writing-shape prototype grilling research retro wizard triage to-questionnaire handoff claude-handoff"
for s in $OLD $MATT_HELPERS security-audit verification-before-completion ui-refine-loop visual super-board super-build super-qa super-review super-collect git-sync pr-security-review; do
  mkdir -p "$T/.claude/skills/$s"; echo x > "$T/.claude/skills/$s/SKILL.md"
done
python3 - "$T/skills-lock.json" $OLD $MATT_HELPERS <<'PY'
import json, sys
s = {n: {"source": "mattpocock/skills"} for n in sys.argv[2:]}
s["security-audit"] = {"source": "cloudflare/security-audit-skill"}
json.dump({"version": 1, "skills": s}, open(sys.argv[1], "w"))
PY
[ "$(ls "$T/.claude/skills" | wc -l | tr -d ' ')" -eq 49 ] || fail "4c fixture should start with 49 skills"
bash "$GET" --target "$T" >/dev/null 2>&1 || fail "upgrade over 49 skills failed"
[ "$(ls "$T/.claude/skills" | sort)" = "$WANT" ] || fail "upgrade should end with exactly 17 skills: $(diff <(echo "$WANT") <(ls "$T/.claude/skills" | sort))"
ls "$T"/.claude/super-board/backup/*/.claude/skills/wayfinder/SKILL.md >/dev/null 2>&1 || fail "pruned skills must be backed up"
[ ! -s "$NPX_LOG" ] || fail "all helpers were present; npx should not run: $(cat "$NPX_LOG")"

# 5 — a target that isn't a directory is refused, and nothing is written.
: > "$WORK/a-file"
if bash "$GET" --target "$WORK/a-file" >/dev/null 2>&1; then fail "a file as target was accepted"; fi
if bash "$GET" --target "$WORK/missing" >/dev/null 2>&1; then fail "a missing target was accepted"; fi
[ ! -e "$WORK/missing" ] || fail "a refused target was created"

# 6 — an unknown flag reaches install.sh, which rejects it; get.sh fails.
T="$WORK/t6"; mkdir -p "$T"
if bash "$GET" --bogus --no-helper-skills --target "$T" >/dev/null 2>&1; then fail "unknown flag was swallowed"; fi

# 7 — a bad tarball URL fails cleanly and leaves no temp folder behind.
T="$WORK/t7"; mkdir -p "$T"
mkdir -p "$WORK/tmp7"
if TMPDIR="$WORK/tmp7" SUPER_BOARD_TARBALL="file://$WORK/nope.tgz" bash "$GET" --no-helper-skills --target "$T" >/dev/null 2>&1; then
  fail "missing tarball was accepted"
fi
[ -z "$(ls -A "$WORK/tmp7")" ] || fail "temp folder was left behind after a failed download"

# 8 — grouped output, in the spec's order: header · checks · download · installing ·
#     helper skills · 🎉 · 👉. One line per group of files, no per-file list.
T="$WORK/t8"; mkdir -p "$T"; printf '# Rules\n- pnpm\n' > "$T/CLAUDE.md"; : > "$NPX_LOG"
out=$(bash "$GET" --target "$T" 2>&1) || fail "grouped-output install failed: $out"
order=$(printf '%s\n' "$out" | grep -oE '^(🧩|🔍|📦|🔧|🧠|🔒|🎉|👉)' | tr -d '\n')
[ "$order" = "🧩🔍📦🔧🧠🎉👉" ] || fail "groups out of order ($order): $out"
printf '%s\n' "$out" | grep -q '^   ✓ curl · tar · python3 · gh · jq · node$' || fail "checks line wrong: $out"
printf '%s\n' "$out" | grep -q '^   🛡️  7 guard hooks → .claude/settings.json (new file)$' || fail "guard line wrong: $out"
printf '%s\n' "$out" | grep -q '^   ! CLAUDE.md holds its own rules — onboard offers a merge$' || fail "CLAUDE.md hint missing: $out"
printf '%s\n' "$out" | grep -q '^🧠 helper skills: installed$' || fail "helper line wrong: $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -le 13 ] || fail "output should stay ≤ 13 lines: $out"

# 9 — Node missing: the checks line marks it ✗ and helper skills wait for 🔍 Checks.
T="$WORK/t9"; mkdir -p "$T"
# /usr/bin can contain node on Linux. Keep only the tools this install uses.
NOBIN="$WORK/bin-nonode"; mkdir -p "$NOBIN"
for t in bash id curl tar gzip python3 mktemp mkdir rm dirname tr cp ln chmod grep basename sed gh jq; do
  ln -s "$(command -v "$t")" "$NOBIN/$t"
done
out=$(PATH="$NOBIN" bash "$GET" --target "$T" 2>&1) || fail "install without node failed: $out"
printf '%s\n' "$out" | grep -q '✗ node' || fail "missing node should be marked ✗: $out"
printf '%s\n' "$out" | grep -q '^🧠 helper skills: skipped — 🔍 Checks will fix this$' || fail "helper line should defer to Checks: $out"
printf '%s\n' "$out" | grep -q 'security-audit' && fail "get.sh no longer mentions security-audit: $out"

echo "PASS: test-get.sh (11 cases)"
