#!/usr/bin/env python3
"""super-board-coverage.py — check docs/shape/coverage.md against the north star and the board.

  super-board-coverage.py lint   --repo-path <app>
  super-board-coverage.py status --repo-path <app> --board-json <file|-> [--milestone M1] [--json]

coverage.md (written by /to-board):

    | Must-have | Cards |
    |---|---|
    | 1 | #12, #13 |
    | 2 | #14 |

    Demo: #20

docs/shape/north-star.md lists the must-haves under `## Must have` as `1. ...`.
Board JSON is a list of {number, status}; a card is done when status is "Done".

lint: exit 1 if a must-have has no row or an empty Cards cell, or there is no
`Demo:` line. A row naming a must-have not in the north star is a warning. A
missing coverage.md is a warning and exit 0 (old apps are not failed).
status: prints done/total per must-have and one milestone line. Silent (no
output, exit 0) when coverage.md is missing. Read-only; stdlib only.

Exit codes: 0 ok · 1 lint failure · 64 bad usage / unreadable board JSON
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

COVERAGE = Path("docs/shape/coverage.md")
NORTH_STAR = Path("docs/shape/north-star.md")

ROW_RE = re.compile(r"^\s*\|\s*(\d+)\s*\|(.*)\|\s*$")
DEMO_RE = re.compile(r"^\s*Demo:\s*(.*)$", re.IGNORECASE)
CARD_RE = re.compile(r"#(\d+)")
MUST_RE = re.compile(r"^\s*(\d+)[.)]\s+\S")


def parse_coverage(text: str) -> dict:
    """Return {rows: {n: [card numbers]}, demo: int | None}."""
    rows: dict[int, list[int]] = {}
    demo = None
    for line in (text or "").splitlines():
        m = ROW_RE.match(line)
        if m:
            n = int(m.group(1))
            rows.setdefault(n, [])
            for c in CARD_RE.findall(m.group(2)):
                if int(c) not in rows[n]:
                    rows[n].append(int(c))
            continue
        m = DEMO_RE.match(line)
        if m:
            c = CARD_RE.search(m.group(1))
            if c:
                demo = int(c.group(1))
    return {"rows": rows, "demo": demo}


def parse_must_haves(text: str) -> list[int]:
    """Numbers of the numbered items under `## Must have`."""
    out: list[int] = []
    inside = False
    for line in (text or "").splitlines():
        if re.match(r"^##\s+", line):
            inside = bool(re.match(r"^##\s+must[\s-]*have\b", line, re.IGNORECASE))
            continue
        if inside:
            m = MUST_RE.match(line)
            if m:
                out.append(int(m.group(1)))
    return out


def lint_problems(cov: dict, musts: list[int]) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    for n in musts:
        if n not in cov["rows"]:
            errors.append(f"must-have {n} has no row in coverage.md")
        elif not cov["rows"][n]:
            errors.append(f"must-have {n} has no cards")
    for n in sorted(cov["rows"]):
        if n not in musts:
            warnings.append(f"coverage.md row {n} is not a must-have in the north star")
    if cov["demo"] is None:
        errors.append("coverage.md has no `Demo: #N` line")
    return errors, warnings


def summarize(cov: dict, musts: list[int], done: set[int], milestone: str = "M1") -> dict:
    nums = sorted(set(musts) | set(cov["rows"]))
    per = []
    all_cards: list[int] = []
    for n in nums:
        cards = cov["rows"].get(n, [])
        all_cards += [c for c in cards if c not in all_cards]
        per.append({"must_have": n, "cards": cards,
                    "done": sum(1 for c in cards if c in done), "total": len(cards)})
    demo = cov["demo"]
    demo_done = demo is not None and demo in done
    cards_done = sum(1 for c in all_cards if c in done)
    complete = bool(all_cards) and cards_done == len(all_cards) and demo_done
    if complete:
        line = f"{milestone} done: all cards and demo #{demo} Done"
    else:
        dtxt = f"demo #{demo} " if demo is not None else "no demo "
        state = "done" if demo_done else "not run"
        line = f"{milestone}: {cards_done}/{len(all_cards)} cards done · {dtxt}{state}"
    return {"milestone": milestone, "must_haves": per, "cards_done": cards_done,
            "cards_total": len(all_cards), "demo": demo, "demo_done": demo_done,
            "milestone_done": complete, "line": line}


def read(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def cmd_lint(args) -> int:
    root = Path(args.repo_path)
    ctext = read(root / COVERAGE)
    if ctext is None:
        print(f"warning: {COVERAGE} not found; coverage not checked")
        return 0
    ntext = read(root / NORTH_STAR)
    if ntext is None:
        print(f"warning: {NORTH_STAR} not found; checking the Demo line only")
    errors, warnings = lint_problems(parse_coverage(ctext), parse_must_haves(ntext or ""))
    for w in warnings:
        print(f"warning: {w}")
    for e in errors:
        print(f"error: {e}")
    if errors:
        return 1
    print("coverage ok")
    return 0


def load_board(src: str) -> set[int]:
    raw = sys.stdin.read() if src == "-" else Path(src).read_text(encoding="utf-8")
    data = json.loads(raw)
    return {int(i["number"]) for i in data if str(i.get("status", "")).lower() == "done"}


def cmd_status(args) -> int:
    root = Path(args.repo_path)
    ctext = read(root / COVERAGE)
    if ctext is None:
        return 0
    try:
        done = load_board(args.board_json)
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"cannot read board json: {e}", file=sys.stderr)
        return 64
    musts = parse_must_haves(read(root / NORTH_STAR) or "")
    s = summarize(parse_coverage(ctext), musts, done, args.milestone)
    if args.json:
        print(json.dumps(s))
        return 0
    for m in s["must_haves"]:
        extra = "  (no cards)" if m["total"] == 0 else ""
        print(f"must-have {m['must_have']}: {m['done']}/{m['total']} done{extra}")
    print(s["line"])
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("lint")
    a.add_argument("--repo-path", default=".")
    a.set_defaults(fn=cmd_lint)
    b = sub.add_parser("status")
    b.add_argument("--repo-path", default=".")
    b.add_argument("--board-json", required=True)
    b.add_argument("--milestone", default="M1")
    b.add_argument("--json", action="store_true")
    b.set_defaults(fn=cmd_status)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
