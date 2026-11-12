#!/usr/bin/env python3
"""super-board-settings.py — merge into .claude/settings.json without losing anything.

    super-board-settings.py hooks <settings.json> <snippet.json> [...] [--dry-run]
    super-board-settings.py allow <settings.json> <rule> [<rule> ...]  [--dry-run]
    super-board-settings.py runner-rules <project-dir>
    super-board-settings.py risky <settings.json>
    super-board-settings.py remove <settings.json> <rule> [<rule> ...] [--dry-run]

`hooks` adds each hook command from the snippets once per event + matcher
(install.sh and onboard's protect-main step), and each `permissions.deny` rule a
snippet carries (the direct-merge deny lines, #131). `allow` adds permission rules to
`permissions.allow` once each (onboard's Permissions step, after the user
approved the printed diff). Both keep every existing key, back the file up
(`settings.json.bak-<ts>`) before writing, write atomically, and leave an
invalid settings.json untouched. `--dry-run` prints what would be added
(`+ <line>`) and writes nothing. `runner-rules` prints, one per line, the allow
rules for the project's own test runners, read from its files (package.json and
its lockfile, pyproject/pytest config, Makefile, go.mod, Cargo.toml), so lane
test commands run without a prompt (#94). It writes nothing. `risky` prints, one
per line, the allow rules that let a lane run any code or merge around the gate
(`node:*`, `python3 -c`, `bash:*`, `gh pr merge`, a wildcard over `.claude/bin/` …);
onboard shows them and `remove` drops the ones the owner approves (#131).

Exit: 0 ok (including "already present"), 2 settings.json invalid, 64 usage.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import time


def load(path: str):
    if not os.path.exists(path):
        return {}
    try:
        data = json.load(open(path))
    except ValueError as e:
        print(f"    ✗ {path} is not valid JSON ({e}); left untouched — merge by hand", file=sys.stderr)
        sys.exit(2)
    if not isinstance(data, dict):
        print(f"    ✗ {path} is not a JSON object; left untouched", file=sys.stderr)
        sys.exit(2)
    return data


def save(path: str, data: dict) -> None:
    if os.path.exists(path):
        backup = f"{path}.bak-{time.strftime('%Y%m%d%H%M%S')}"
        shutil.copy2(path, backup)
        print(f"    ✓ backup: {backup}")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def merge_hooks(settings: dict, snippets: list[dict]) -> list[str]:
    hooks = settings.setdefault("hooks", {})
    added = []
    for event, entries in [kv for s in snippets for kv in s["hooks"].items()]:
        current = hooks.setdefault(event, [])
        for entry in entries:
            matcher = entry.get("matcher")
            target = next((e for e in current if e.get("matcher") == matcher), None)
            if target is None:
                target = {"matcher": matcher} if matcher is not None else {}
                target["hooks"] = []
                current.append(target)
            have = {h.get("command") for e in current if e.get("matcher") == matcher
                    for h in e.get("hooks", [])}
            for h in entry["hooks"]:
                if h["command"] not in have:
                    target.setdefault("hooks", []).append(h)
                    have.add(h["command"])
                    added.append(f"{event} {matcher or '*'}: {h['command']}")
    return added


def merge_deny(settings: dict, snippets: list[dict]) -> list[str]:
    deny = None
    added = []
    for rule in [r for s in snippets for r in (s.get("permissions") or {}).get("deny", [])]:
        deny = settings.setdefault("permissions", {}).setdefault("deny", [])
        if rule not in deny:
            deny.append(rule)
            added.append(f"deny: {rule}")
    return added


# Allow rules that hand a lane arbitrary code or a merge that skips the gate. The
# permission decider allows the safe forms of these commands without them.
RISKY = [
    re.compile(r"^Bash$"), re.compile(r"^Bash\(\*\)$"),
    re.compile(r"^Bash\((node|python3?|bash|sh|zsh|eval|env|xargs|npx|deno|bun|ruby|perl)( \*|:\*)\)$"),
    re.compile(r"^Bash\((python3?|node) (-c|-e|-)\b.*\)$"),
    re.compile(r"^Bash\(gh pr merge\b.*\)$"),
    re.compile(r"^Bash\(gh api\b.*merge.*\)$"),
    re.compile(r"^Bash\((bash |python3 |sh )?\.claude/bin/(:\*| \*|\*)\)$"),
    re.compile(r"^Bash\((sed|find|awk)(:\*| \*)\)$"),
]


def risky(settings: dict) -> list[str]:
    allow = (settings.get("permissions") or {}).get("allow") or []
    return [r for r in allow if isinstance(r, str) and any(p.match(r) for p in RISKY)]


def merge_allow(settings: dict, rules: list[str]) -> list[str]:
    allow = settings.setdefault("permissions", {}).setdefault("allow", [])
    added = []
    for r in rules:
        if r not in allow:
            allow.append(r)
            added.append(r)
    return added


# package.json dependency -> the npx rule its lanes run.
NPX_TOOLS = [("@playwright/test", "playwright"), ("playwright", "playwright"), ("vitest", "vitest"),
             ("jest", "jest"), ("typescript", "tsc"), ("eslint", "eslint"),
             ("prettier", "prettier"), ("vite", "vite")]
# lockfile -> package manager and the subcommands a lane runs.
MANAGERS = [("pnpm-lock.yaml", "pnpm", ["install", "test", "run", "exec", "-C"]),
            ("yarn.lock", "yarn", ["install", "test", "run"]),
            ("bun.lockb", "bun", ["install", "test", "run"]),
            ("bun.lock", "bun", ["install", "test", "run"])]
NPM = ("npm", ["ci", "install", "test", "run", "audit", "--prefix"])


def runner_rules(root: str) -> list[str]:
    def has(name):
        return os.path.exists(os.path.join(root, name))

    def read(name):
        try:
            return open(os.path.join(root, name)).read()
        except OSError:
            return ""

    rules: list[str] = []
    if has("package.json"):
        try:
            pkg = json.loads(read("package.json"))
        except ValueError:
            pkg = {}
        mgr, subs = next(((m, s) for lock, m, s in MANAGERS if has(lock)), NPM)
        rules += [f"Bash({mgr} {s}:*)" for s in subs]
        deps = {**(pkg.get("dependencies") or {}), **(pkg.get("devDependencies") or {})}
        for dep, tool in NPX_TOOLS:
            rule = f"Bash(npx {tool}:*)"
            if dep in deps and rule not in rules:
                rules.append(rule)
    if has("pytest.ini") or "[tool.pytest" in read("pyproject.toml") or "[tool:pytest]" in read("setup.cfg") \
            or (has("tests") and (has("pyproject.toml") or has("requirements.txt"))):
        rules += ["Bash(python3 -m pytest:*)", "Bash(pytest:*)"]
    if any(line.startswith("test:") for line in read("Makefile").splitlines()):
        rules.append("Bash(make test:*)")
    if has("go.mod"):
        rules.append("Bash(go test:*)")
    if has("Cargo.toml"):
        rules.append("Bash(cargo test:*)")
    return rules


def main(argv: list[str]) -> int:
    dry = "--dry-run" in argv
    args = [a for a in argv if a != "--dry-run"]
    if len(args) == 2 and args[0] == "runner-rules":
        for r in runner_rules(args[1]):
            print(r)
        return 0
    if len(args) == 2 and args[0] == "risky":
        for r in risky(load(args[1])):
            print(r)
        return 0
    if len(args) < 3 or args[0] not in ("hooks", "allow", "remove"):
        print(__doc__, file=sys.stderr)
        return 64
    verb, path, rest = args[0], args[1], args[2:]
    settings = load(path)
    if verb == "hooks":
        snippets = [json.load(open(p)) for p in rest]
        added = merge_hooks(settings, snippets) + merge_deny(settings, snippets)
        noun = "hook command(s) / deny rule(s)"
    elif verb == "remove":
        allow = (settings.get("permissions") or {}).get("allow") or []
        added = [f"- {r}" for r in rest if r in allow]
        if added:
            settings["permissions"]["allow"] = [r for r in allow if r not in rest]
        noun = "permission rule(s) removed:"
    else:
        added = merge_allow(settings, rest)
        noun = "permission rule(s)"
    if not added:
        print("    ✓ already present — nothing to change")
        return 0
    if dry:
        for a in added:
            print(a if a.startswith("- ") else f"+ {a}")
        return 0
    save(path, settings)
    print(f"    ✓ {len(added)} {noun}" + ("" if verb == "remove" else " added"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
