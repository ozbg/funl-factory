#!/usr/bin/env bash
# super-board-scope.sh — the scope gate (factory #148). Code holds the goal's scope;
# the scope judge (references/scope-judge.md) makes the call; the owner rules past the cap.
#
# Workers find things. They never decide what a milestone carries. When a run starts,
# `freeze` records the goal milestone's cards in the config as `goal.scope`. After that the
# wave planner refuses any goal card that is not in the frozen list and not admitted, and
# the only way in is `admit`:
#
#   - with a judge verdict (`--verdict-file`): the verdict must be a `gate` with a citation
#     the north star backs (must-have, day-one question, invariant, or `harm:` naming a line
#     of `## Fit for purpose`). Admitted judge gates may grow the goal by at most 25% of
#     the frozen count, rounded up, at least 1. A gate for a frozen card's own failed AC
#     (`unfinished`) is unfinished scope and does not count. A verdict with `owner_call`
#     set is held for the owner.
#   - with `--owner "<words>"`: always accepted, recorded with the owner's words.
#
# Usage:
#   super-board-scope.sh freeze  --config <cfg> [--items <project-items.json>]
#   super-board-scope.sh admit <n> --config <cfg> --verdict-file <json> [--owner "<words>"]
#   super-board-scope.sh admit <n> --config <cfg> --owner "<words>"
#   super-board-scope.sh status  --config <cfg> [--json]
#   super-board-scope.sh pending --config <cfg> [--issues <issues.json>]
#   super-board-scope.sh profile --config <cfg>
#
# north-star.md, spec.md and zones.yaml are read under the config's `repo.path`.
# Without --items / --issues the board and the `scope:pending` issues are read live.
#
# Exits: 0 ok · 64 bad args · 65 refused by the gate (reason on stderr) ·
#        66 unreadable config, verdict or north star · 70 GitHub read failed
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export SB_SCOPE_HERE="$HERE"
exec python3 - "$@" <<'PY'
import json, math, os, re, subprocess, sys
from datetime import datetime, timezone

USAGE = ("usage: super-board-scope.sh freeze|admit <n>|status|pending|profile --config <cfg> "
         "[--items f] [--issues f] [--verdict-file f] [--owner \"<words>\"] [--json]")
VERDICTS = ("gate", "next", "drop")
KINDS = ("security", "privacy", "data-loss", "correctness", "ui", "copy", "performance", "test-debt", "factory")
PROFILE = ("Users", "Runs on", "Reach", "Holds", "Worst case", "Matters most", "Matters least",
           "Budget", "Scale", "Stage")
REASON_NOT_IN_SCOPE = "not in the frozen scope; the scope judge has not admitted it"


def die(msg, code):
    print(msg, file=sys.stderr)
    sys.exit(code)


def parse(argv):
    if not argv:
        die(USAGE, 64)
    a = {"cmd": argv[0], "n": None, "config": None, "items": None, "issues": None,
         "verdict": None, "owner": None, "json": False}
    rest = argv[1:]
    if a["cmd"] == "admit":
        if not rest or not re.fullmatch(r"\d+", rest[0]):
            die("admit takes an issue number: admit <n> --config <cfg> ...", 64)
        a["n"] = int(rest[0])
        rest = rest[1:]
    flags = {"--config": "config", "--items": "items", "--issues": "issues",
             "--verdict-file": "verdict", "--owner": "owner"}
    i = 0
    while i < len(rest):
        f = rest[i]
        if f == "--json":
            a["json"] = True
            i += 1
        elif f in flags and i + 1 < len(rest):
            a[flags[f]] = rest[i + 1]
            i += 2
        else:
            die("unknown arg: {}\n{}".format(f, USAGE), 64)
    if a["cmd"] not in ("freeze", "admit", "status", "pending", "profile"):
        die(USAGE, 64)
    if not a["config"]:
        die("--config is required", 64)
    return a


def read_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        die("cannot read {} {}: {}".format(what, path, e), 66)


def write_cfg(path, cfg):
    tmp = path + ".scope-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def now():
    return os.environ.get("SB_SCOPE_NOW") or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def repo_file(cfg, rel):
    return os.path.join((cfg.get("repo") or {}).get("path") or ".", rel)


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def section(text, title):
    """Lines under `## <title>` up to the next `## ` heading."""
    out, on = [], False
    for line in (text or "").splitlines():
        if line.startswith("## "):
            on = line[3:].strip().lower() == title.lower()
            continue
        if on:
            out.append(line)
    return out


def north_star(cfg):
    return read_text(repo_file(cfg, "docs/shape/north-star.md"))


def must_haves(ns):
    return [int(m.group(1)) for m in (re.match(r"^(\d+)\.", l) for l in section(ns, "Must have")) if m]


def day_one_count(ns):
    return sum(1 for l in section(ns, "Day-one questions") if re.match(r"^\s*-\s+\S", l))


def profile(ns):
    """{label: text} from `## Fit for purpose`; None when the block is absent."""
    if ns is None or not re.search(r"^## Fit for purpose[ \t]*$", ns, re.M):
        return None
    out = {}
    for l in section(ns, "Fit for purpose"):
        m = re.match(r"^\s*-\s+([^:]+):\s*(.*\S)\s*$", l)
        if m:
            out[m.group(1).strip()] = m.group(2)
    return out


def profile_missing(ns):
    p = profile(ns)
    if p is None:
        return list(PROFILE)
    return [k for k in PROFILE if not p.get(k)]


def invariant_known(cfg, ident):
    found = False
    for rel in ("docs/shape/spec.md", "docs/agents/zones.yaml"):
        t = read_text(repo_file(cfg, rel))
        if t and re.search(r"(?<![A-Za-z0-9])" + re.escape(ident) + r"(?![0-9])", t):
            found = True
    return found


def check_citation(cfg, ns, cite):
    """None when the gate citation is backed by the north star or spec, else the reason."""
    c = (cite or "").strip()
    if not c or c.lower() == "none":
        return "no citation: a gate needs a must-have, a day-one question, an invariant or a harm"
    m = re.fullmatch(r"must-have\s+(\d+)", c, re.I)
    if m:
        if ns is None:
            return "docs/shape/north-star.md missing, so no must-have can be cited"
        return None if int(m.group(1)) in must_haves(ns) else \
            "must-have {} is not under ## Must have in docs/shape/north-star.md".format(m.group(1))
    m = re.fullmatch(r"day-one\s+Q(\d+)", c, re.I)
    if m:
        n, total = int(m.group(1)), day_one_count(ns)
        return None if 1 <= n <= total else \
            "day-one Q{} is not in ## Day-one questions ({} listed)".format(n, total)
    m = re.fullmatch(r"(I\d+)", c)
    if m:
        return None if invariant_known(cfg, m.group(1)) else \
            "invariant {} is not in docs/shape/spec.md or docs/agents/zones.yaml".format(m.group(1))
    m = re.fullmatch(r"harm:\s*(.+)", c, re.I | re.S)
    if m:
        p = profile(ns)
        if p is None:
            return "harm: needs the north star's ## Fit for purpose block, and it has none"
        body = m.group(1).strip()
        for label in sorted(p, key=len, reverse=True):
            if body.lower().startswith(label.lower()):
                rest = body[len(label):].lstrip(" ,:;-—")
                if rest:
                    return None
                return "harm: {} names no event: say what happens to whom".format(label)
        return "harm: \"{}\" matches no line of ## Fit for purpose ({})".format(body, ", ".join(p))
    return "citation \"{}\" is not must-have <n>, day-one Q<n>, I<n> or harm: <profile line>: <what>".format(c)


def check_verdict(v, n):
    """None when the verdict object has the judge's schema, else the reason."""
    if not isinstance(v, dict):
        return "a verdict is one JSON object"
    if v.get("error"):
        return "the judge returned an error: {}".format(v["error"])
    if v.get("card") != n:
        return "the verdict is for card {}, not #{}".format(v.get("card"), n)
    if v.get("verdict") not in VERDICTS:
        return "verdict must be gate, next or drop"
    if v.get("kind") not in KINDS:
        return "kind must be one of " + ", ".join(KINDS)
    for k in ("citation", "reason", "cost_of_waiting"):
        if not isinstance(v.get(k), str) or not v[k].strip():
            return "{} must be a one-line string".format(k)
    for k in ("owner_call", "split"):
        if v.get(k) is not None and not isinstance(v[k], str):
            return "{} must be null or a string".format(k)
    if v.get("route") not in (None, "factory"):
        return "route must be null or \"factory\""
    u = v.get("unfinished")
    if u is not None and (not isinstance(u, int) or isinstance(u, bool)):
        return "unfinished must be null or a card number"
    return None


def scope_of(cfg):
    goal = cfg.get("goal") or {}
    s = goal.get("scope")
    return s if isinstance(s, dict) else None


def cap_of(s):
    return max(1, math.ceil(len(s.get("issues") or []) * 0.25))


def counted(s):
    return [a for a in s.get("admitted") or [] if a.get("by") == "judge" and a.get("unfinished") is None]


def in_scope(s, n):
    return n in (s.get("issues") or []) or any(a.get("number") == n for a in s.get("admitted") or [])


def gh_read(kind, args):
    here = os.environ["SB_SCOPE_HERE"]
    r = subprocess.run(["python3", os.path.join(here, "super-board-github-read.py"), "--kind", kind, "--"] + args,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        die("GitHub read failed (exit {})".format(r.returncode), 79 if r.returncode == 79 else 70)
    return json.loads(r.stdout)


# --- freeze ------------------------------------------------------------------------
def freeze(a, cfg):
    goal = (cfg.get("goal") or {}).get("milestone")
    if not goal:
        die("no goal.milestone in the config: confirm the goal first (run-workflow.md → goal check)", 64)
    s = scope_of(cfg)
    if s and s.get("milestone") == goal:
        print("frozen|{}|{} cards|since {}".format(goal, len(s.get("issues") or []), s.get("frozenAt")))
        return 0
    if a["items"]:
        items = read_json(a["items"], "items")
    else:
        proj = cfg.get("project") or {}
        r = subprocess.run([os.path.join(os.environ["SB_SCOPE_HERE"], "super-board-card.sh"),
                            "--owner", str(proj.get("owner")), "--number", str(proj.get("number")), "items"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(r.stderr)
            die("cannot read the board", 79 if r.returncode == 79 else 70)
        items = json.loads(r.stdout)
    cards = {}
    for it in items.get("items") or []:
        c = it.get("content") or {}
        ms = (it.get("milestone") or {}).get("title") or (c.get("milestone") or {}).get("title")
        if c.get("type") == "Issue" and ms == goal and it.get("status") != "Done":
            cards[c["number"]] = c.get("title") or ""
    nums = sorted(cards)
    cfg.setdefault("goal", {})["scope"] = {
        "milestone": goal, "frozenAt": now(), "issues": nums,
        "titles": {str(n): cards[n] for n in nums}, "admitted": []}
    write_cfg(a["config"], cfg)
    print("frozen|{}|{} cards|cap {}".format(goal, len(nums), cap_of(cfg["goal"]["scope"])))
    return 0


# --- admit -------------------------------------------------------------------------
def admit(a, cfg):
    n, s = a["n"], scope_of(cfg)
    if s is None:
        die("refused: no frozen scope in the config; run super-board-scope.sh freeze at run start", 65)
    if in_scope(s, n):
        print("in-scope|#{}".format(n))
        return 0
    owner = (a["owner"] or "").strip()
    if a["owner"] is not None and not owner:
        die("--owner needs the owner's own words", 64)
    if not a["verdict"] and not owner:
        die("admit needs --verdict-file <json> or --owner \"<words>\"", 64)
    v = None
    if a["verdict"]:
        raw = read_json(a["verdict"], "verdict file")
        if isinstance(raw, list):
            raw = next((x for x in raw if isinstance(x, dict) and x.get("card") == n), None) or \
                {"card": None}
        bad = check_verdict(raw, n)
        if bad:
            die("refused: #{}: {}".format(n, bad), 65)
        v = raw
    entry = {"number": n, "at": now()}
    if owner:
        entry.update({"by": "owner", "words": owner})
        if v:
            entry.update({"verdict": v["verdict"], "citation": v["citation"]})
    else:
        if v["verdict"] != "gate":
            die("refused: #{}: the judge said {}, not gate; only the owner admits it".format(n, v["verdict"]), 65)
        if v.get("route") == "factory":
            die("refused: #{}: factory work goes to funl-factory-master, never onto the goal".format(n), 65)
        ns = north_star(cfg)
        bad = check_citation(cfg, ns, v["citation"])
        if bad:
            die("refused: #{}: {}".format(n, bad), 65)
        if (v.get("owner_call") or "").strip():
            die("refused: #{}: owner call: {} (admit it with --owner \"<the owner's words>\")".format(
                n, v["owner_call"].strip()), 65)
        u = v.get("unfinished")
        if u is not None and u not in (s.get("issues") or []):
            die("refused: #{}: unfinished names #{}, which is not in the frozen scope".format(n, u), 65)
        if u is None and len(counted(s)) >= cap_of(s):
            die("refused: #{}: past the growth cap ({} of {} used): one needs-you item for the owner, "
                "admit or next (--owner \"<words>\")".format(n, len(counted(s)), cap_of(s)), 65)
        entry.update({"by": "judge", "verdict": "gate", "citation": v["citation"], "kind": v["kind"],
                      "reason": v["reason"]})
        if u is not None:
            entry["unfinished"] = u
    s.setdefault("admitted", []).append(entry)
    write_cfg(a["config"], cfg)
    print("admitted|#{}|{}|{}".format(n, entry["by"], entry.get("citation") or entry.get("words")))
    return 0


# --- status ------------------------------------------------------------------------
def status(a, cfg):
    s = scope_of(cfg)
    if s is None:
        out = {"frozen": None}
        print(json.dumps(out) if a["json"] else "scope: not frozen")
        return 0
    adm = s.get("admitted") or []
    out = {"milestone": s.get("milestone"), "frozenAt": s.get("frozenAt"), "frozen": len(s.get("issues") or []),
           "admitted": len(adm), "byJudge": sum(1 for x in adm if x.get("by") == "judge"),
           "byOwner": sum(1 for x in adm if x.get("by") == "owner"),
           "unfinished": sum(1 for x in adm if x.get("unfinished") is not None),
           "cap": cap_of(s), "capLeft": max(0, cap_of(s) - len(counted(s))),
           "cards": [{"number": x.get("number"), "by": x.get("by"),
                      "why": x.get("citation") if x.get("by") == "judge" else x.get("words")} for x in adm]}
    if a["json"]:
        print(json.dumps(out))
        return 0
    print("scope {} · frozen {} at {} · admitted {} (judge {}, owner {}) · cap {}, {} left".format(
        out["milestone"], out["frozen"], out["frozenAt"], out["admitted"], out["byJudge"], out["byOwner"],
        out["cap"], out["capLeft"]))
    for x in adm:
        why = x.get("citation") if x.get("by") == "judge" else '"{}"'.format(x.get("words"))
        tail = " · unfinished #{}, outside the cap".format(x["unfinished"]) if x.get("unfinished") is not None else ""
        print("  #{} · {} · {}{}".format(x.get("number"), x.get("by"), why, tail))
    return 0


# --- pending -----------------------------------------------------------------------
OPINION = re.compile(r"orchestrator|builder|reviewer|tester|\[(build|qa|review)\]", re.I)


def strip_body(body):
    """The card as the judge may see it: no Risk, Recommendation or Board summary
    section, no priority, no Decided line unless the owner signed it, no hidden comments."""
    body = re.sub(r"<!--.*?-->", "", body or "", flags=re.S)
    out, skip = [], False
    for line in body.splitlines():
        h = re.match(r"^#{1,3}\s+(.*\S)\s*$", line)
        if h:
            skip = h.group(1).lower() in ("risk", "recommendation", "board summary")
            if skip:
                continue
        if skip:
            continue
        if re.search(r"\bDecided\b", line, re.I) and (OPINION.search(line) or not re.search(r"\bowner\b", line, re.I)):
            continue
        if re.search(r"\bpriority\s*:", line, re.I):
            continue
        out.append(line)
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip() + "\n"


def pending(a, cfg):
    s = scope_of(cfg) or {}
    if a["issues"]:
        issues = read_json(a["issues"], "issues")
    else:
        repo = re.sub(r"^https?://github\.com/|\.git$", "", (cfg.get("repo") or {}).get("remote") or "")
        args = ["issue", "list", "--label", "scope:pending", "--state", "open", "--limit", "200",
                "--json", "number,title,body,labels"] + (["-R", repo] if repo else [])
        issues = gh_read("json", args)
    cards = []
    for i in issues:
        if s and in_scope(s, i.get("number")):
            continue
        labels = [(l.get("name") if isinstance(l, dict) else l) for l in i.get("labels") or []]
        cards.append({"number": i.get("number"), "title": i.get("title") or "",
                      "labels": [l for l in labels if l and not l.lower().startswith("priority")],
                      "body": strip_body(i.get("body"))})
    ns = north_star(cfg)
    print(json.dumps({"goal": (cfg.get("goal") or {}).get("milestone"),
                      "frozen": [{"number": n, "title": (s.get("titles") or {}).get(str(n), "")}
                                 for n in s.get("issues") or []],
                      "profile": not profile_missing(ns), "cards": sorted(cards, key=lambda c: c["number"])},
                     indent=1))
    return 0


# --- profile -----------------------------------------------------------------------
def profile_cmd(a, cfg):
    ns = north_star(cfg)
    if ns is None:
        die("no docs/shape/north-star.md", 66)
    miss = profile_missing(ns)
    if miss:
        if profile(ns) is None:
            print("north-star.md has no ## Fit for purpose block: the owner signs ten lines ({})".format(
                ", ".join(PROFILE)))
        else:
            print("## Fit for purpose is missing: {}".format(", ".join(miss)))
        return 1
    print("fit for purpose: ten lines")
    return 0


a = parse(sys.argv[1:])
cfg = read_json(a["config"], "config")
sys.exit({"freeze": freeze, "admit": admit, "status": status, "pending": pending, "profile": profile_cmd}[a["cmd"]](a, cfg))
PY
