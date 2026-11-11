#!/usr/bin/env python3
"""The run allowlist covers every .claude/bin script that pre-flight and the lanes call (#38).

Onboard writes the base list from onboard.md -> "Mid-run permission prompts", so a
script missing there stalls a fresh install on a prompt (and a headless run never starts).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / "skills/super-board/references"
ALLOWLIST = REF / "onboard.md"
CALLERS = [
    REF / "run-workflow.md",
    ROOT / "workflows/super-board-wave.js",
    ROOT / "skills/super-build/SKILL.md",
    ROOT / "skills/super-qa/SKILL.md",
    ROOT / "skills/super-review/SKILL.md",
    *sorted((REF / "lanes").glob("*.md")),
]
# The merge gate is offered with the merge lines (onboard -> Permissions), listed below the base.
REF = re.compile(r"(?:(bash|python3|source) )?\.claude/bin/([A-Za-z0-9_-]+\.(?:sh|py))")
RULE = re.compile(r'"(Bash\([^"]*\))"')

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


text = ALLOWLIST.read_text()
section = text.split("## Mid-run permission prompts", 1)[1].split("\n## ", 1)[0]
base = section.split("plus your project's test runners", 1)[0]
rules = set(RULE.findall(section))  # base list + merge lines
base_rules = set(RULE.findall(base))


def covered(script, form, pool):
    forms = [form] if form else ["bash", "python3", "source", None]
    for f in forms:
        target = f".claude/bin/{script}" if f is None else f"{f} .claude/bin/{script}"
        if f"Bash({target}:*)" in pool:
            return True
    return False


for path in CALLERS:
    for form, script in set(REF.findall(path.read_text())):
        pool = rules if script == "super-board-merge-gate.sh" else base_rules
        check(covered(script, form or None, pool),
              f"{path.relative_to(ROOT)} calls {(form + ' ') if form else ''}.claude/bin/{script}"
              " but the run allowlist has no rule for it")

for rule in ("Bash(python3 .claude/bin/super-board-github-read.py:*)",
             "Bash(.claude/bin/super-board-github-read.py:*)"):
    check(rule in base_rules, f"base allowlist misses {rule}")

# Read-only commands and the guard's one-call form are in the base list; test runners come
# from the project itself (#94).
for rule in ("Bash(bash .claude/bin/super-board-gh-guard.sh:*)", "Bash(git status:*)",
             "Bash(git diff:*)", "Bash(git log:*)", "Bash(git rev-parse:*)", "Bash(git merge-base:*)",
             "Bash(gh pr list:*)", "Bash(gh issue list:*)", "Bash(ls:*)", "Bash(cat:*)",
             "Bash(grep:*)", "Bash(jq:*)"):
    check(rule in base_rules, f"base allowlist misses {rule}")
for rule in ("Bash(find:*)", "Bash(sed:*)", "Bash(node:*)", "Bash(bash .claude/bin/:*)"):
    check(rule not in rules, f"allowlist must not pre-approve {rule}")
check(text.count("super-board-settings.py runner-rules .") >= 2,
      "onboard must add the project's test runners from super-board-settings.py runner-rules (base list and step 6)")

# Lanes' one route to resolve threads, edit comments, and create the deep-review label (#8).
for rule in ("Bash(gh api:*)", "Bash(gh api graphql:*)", "Bash(gh label create:*)"):
    check(rule in base_rules, f"base allowlist misses {rule}")

# A gh or board command behind `cd … &&` or in a loop matches no rule (#37).
SHAPE = re.compile(r"\bcd [^`\n]*?&&\s*(?:gh |(?:bash |python3 )?\.claude/bin/)|\bfor \w+ in [^`\n]*?;\s*do\s+gh ")
for path in CALLERS:
    for m in SHAPE.finditer(path.read_text()):
        failures.append(f"{path.relative_to(ROOT)}: `{m.group(0)}` puts a gh or board command behind cd or a loop")
# Lane commands are one literal call each: no shell variables for paths or values, no
# chaining, no `echo $?` (#94). Every Bash call is a fresh shell, and a chain matches no rule.
LANE_DOCS = [p for p in CALLERS if p.suffix == ".md"] + [
    ROOT / "skills/super-board/references/github-cheatsheet.md",
    ROOT / "skills/super-board/references/rate-limit-etiquette.md",
    ROOT / "skills/to-board/references/filing.md",
    ROOT / "skills/super-collect/SKILL.md",
]
# A command, or an env-prefixed command (`NAME=x cmd …`). A bare `NAME=1` names a setting.
CMD_START = re.compile(r"(?:python3|bash|sh|source|gh|git|npm|npx|pnpm|yarn|mkdir|node|\.claude/bin/)\b|[A-Z][A-Z0-9_]*=\S*\s+\S")
CHAIN = re.compile(r"&&|\|\||;\s*\S|\$\?|\$\(|\$\{?[A-Z][A-Z0-9_]*\b|^[A-Z][A-Z0-9_]*=")


def command_spans(text):
    """Commands a lane might copy: lines of fenced blocks, and inline code spans."""
    fenced = False
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if "No shell variables" in line:  # the rule itself names the forbidden forms
            continue
        if fenced:
            yield n, line.split("  #")[0].strip()
        else:
            for span in re.findall(r"`([^`]+)`", line):
                yield n, span.strip()


for path in LANE_DOCS:
    for n, span in command_spans(path.read_text()):
        if CMD_START.match(span) and CHAIN.search(span):
            failures.append(f"{path.relative_to(ROOT)}:{n}: `{span}` chains commands or uses a shell variable")

wave = (ROOT / "workflows/super-board-wave.js").read_text()
WAVE_BAD = re.compile(r'\$PWD\b|\$\(|&&\s*(?:python3|bash|gh|git|\.claude/)|;\s*echo|echo \$\?|\b[A-Z]{1,4}=\.claude/bin'
                      r"|sb_gh_guard_check|source \.claude/bin")
for n, line in enumerate(wave.splitlines(), 1):
    if line.lstrip().startswith("`Command shape:"):
        continue
    for m in WAVE_BAD.finditer(line):
        failures.append(f"workflows/super-board-wave.js:{n}: `{m.group(0)}` in a lane prompt is not one plain call")
check("one literal call" in wave and "python3 .claude/bin/super-board-github-read.py --check" in wave,
      "lane prompts must state the command shape with a literal example")
check("bash .claude/bin/super-board-gh-guard.sh check 200" in wave,
      "lane prompts must give the guard as one plain call")

common = (ROOT / "skills/super-board/references/lanes/common.md").read_text()
check("**One literal call per Bash call.**" in common, "lanes/common.md must give the one-call rule")

# Card text never travels inside a command: the secrets guard scans the whole command (#88).
for bad in ("--cards -", "<<'CARDS'", "<<CARDS"):
    check(bad not in wave, f"workflows/super-board-wave.js passes cards inline ({bad}); write a file and pass --cards <file>")
check("--cards <that file>" in wave and "Write tool" in wave,
      "the skills check must write the cards to a file and pass its path")
check("**Card text never goes inside a command**" in common, "lanes/common.md must say card text never goes inside a command")
lint = (ROOT / "skills/super-board/references/lint.md").read_text()
check("| 23 | Body names a file the secrets guard blocks" in lint and "guard-secrets.py --scan" in lint,
      "lint must flag a card body the secrets guard would block")
check("guard-secrets.py --scan" in (ROOT / "skills/to-board/SKILL.md").read_text(),
      "/to-board must scan card bodies before filing")
check("Bash(git -C:*)" in base_rules, "base allowlist misses Bash(git -C:*), how lanes run git")
check("resolveReviewThread" in common and "gh api -X PATCH" in common,
      "lanes/common.md must give the one route to resolve threads and edit comments")

check(re.search(r'claude -p "/super-board run"', section) is not None,
      "onboard.md must say whether claude -p \"/super-board run\" is supported")
check(".claude/super-board/" in section and ".claude/worktrees/" in section,
      "onboard.md must say how a headless run writes .claude/super-board/ and .claude/worktrees/")

if failures:
    for f in failures:
        print(f"FAIL: {f}", file=sys.stderr)
    sys.exit(1)
print("PASS: test_run_allowlist.py")
