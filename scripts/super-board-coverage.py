#!/usr/bin/env python3
"""super-board-coverage.py — check docs/shape/coverage.md against the north star and the board.

  super-board-coverage.py lint   --repo-path <app>
  super-board-coverage.py status --repo-path <app> --board-json <file|-> [--milestone M1] [--json]
                                 [--scorecard <file>]
  super-board-coverage.py cards  --repo-path <app> --issues-json <file|->
  super-board-coverage.py briefs --repo-path <app> --issues-json <file|->

coverage.md (written by /to-board):

    | Must-have | Cards |
    |---|---|
    | 1 | #12, #13 |
    | 2 | #14 |

    Demo: #20

    Cut from mock-up:
    - #13 · screen-pipeline: source filter (#14) · archived restore (later.md)

docs/shape/north-star.md lists the must-haves under `## Must have` as `1. ...`.
Board JSON is a list of {number, status}; a card is done when status is "Done".

lint: exit 1 if a must-have has no row or an empty Cards cell, or there is no
`Demo:` line. A row naming a must-have not in the north star is a warning. A
missing coverage.md is a warning and exit 0 (old apps are not failed). With a
docs/shape/mockup.html, a coverage.md with no `Cut from mock-up:` list is a
warning (old apps again).
cards: checks the mock-up block on every screen card (a card with a
`Mock-up:` line; the Demo card, titled `[test] demo:`, is skipped). Issues JSON
is a list of {number, title, body}. Exit 1 when a screen card lacks the
`## Mock-up` block, its anchor, the markup excerpt, the class list, the
`Cut from mock-up:` line or the match AC; when the anchor is not in mockup.html;
or when coverage.md's cut list leaves out a card that cuts something.
It also warns (exit unchanged) on a Demo card with no `Decided:` line saying
it runs its own app instance (own port, temp data, fake AI, fixed date).
briefs: the body-of-work gate (references/iteration.md). Issues JSON may carry
`labels` (names or {name}). A card labelled `body-of-work`, or with a `Brief:`
line in Context, fails (exit 1) when the line is missing, the brief file is not
in the repo, or it has no `Signed:` line with a real value (`no`, empty or a
`<placeholder>` is unsigned). A card still labelled `proposal` fails too: it is
waiting on the owner and belongs in Backlog.
status: prints done/total per must-have and one milestone line. Silent (no
output, exit 0) when coverage.md is missing. Read-only; stdlib only.
The milestone is done only when every card and the Demo card are Done AND the
agent walk passed (its latest `walk` row in the scorecard, default
docs/super-board/runs/scorecard.jsonl, with every exam at its pass mark) or the
owner accepted its findings (a later `walk-accept` row). `mockup_cuts` counts
the features in the `Cut from mock-up:` list (None with no list).

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
CUTS_RE = re.compile(r"^\s*Cut from mock-up:\s*(.*)$", re.IGNORECASE)
BULLET_RE = re.compile(r"^\s*[-*]\s+(.*\S)\s*$")
MOCKUP = Path("docs/shape/mockup.html")


def card_line(body: str, name: str) -> str | None:
    """Value of the last `Name:` line, bullet and bold allowed: `- **Mock-up:** x`."""
    rx = re.compile(r"^\s*(?:[-*]\s+)?(?:\*\*)?" + re.escape(name) + r":(?:\*\*)?[ \t]*(.*?)\s*$",
                    re.IGNORECASE | re.M)
    found = rx.findall(body or "")
    return found[-1] if found else None


def section(body: str, heading: str) -> str | None:
    """Text under the last `## <heading>`, up to the next `## `; fenced code is kept whole."""
    lines = (body or "").splitlines()
    start = None
    fence = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            fence = not fence
        if not fence and re.match(r"^##\s+" + re.escape(heading) + r"\s*$", line, re.IGNORECASE):
            start = i + 1
    if start is None:
        return None
    out, fence = [], False
    for line in lines[start:]:
        if line.lstrip().startswith("```"):
            fence = not fence
        if not fence and re.match(r"^##\s+", line):
            break
        out.append(line)
    return "\n".join(out)


def anchor_of(value: str | None) -> str | None:
    m = re.search(r"#(screen-[A-Za-z0-9_-]+)", value or "")
    return m.group(1) if m else None


def is_none(value: str) -> bool:
    return value.strip().strip("`*_.").lower() == "none"


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
    cuts = None
    in_cuts = False
    for line in (text or "").splitlines():
        m = CUTS_RE.match(line)
        if m:
            cuts, in_cuts = [], True
            if m.group(1).strip():
                cuts.append(m.group(1).strip())
            continue
        if in_cuts:
            b = BULLET_RE.match(line)
            if b:
                cuts.append(b.group(1))
            elif line.strip():
                in_cuts = False
    cut_cards = sorted({int(c) for item in (cuts or []) for c in CARD_RE.findall(item.split("·")[0].split(":")[0])})
    return {"rows": rows, "demo": demo, "cuts": cuts, "cut_cards": cut_cards}


def count_cuts(cuts: list[str] | None) -> int | None:
    """Features cut: the items after each bullet's `<screen>:`, split on `,` and `·`."""
    if cuts is None:
        return None
    n = 0
    for item in cuts:
        rest = item.split(":", 1)[1] if ":" in item else ""
        n += sum(1 for x in re.split(r"[,·]", rest) if x.strip() and not is_none(x))
    return n


SCORECARD = Path("docs/super-board/runs/scorecard.jsonl")


def walk_state(rows: list[dict], milestone: str | None) -> dict:
    """{state: not run | passed | failed | accepted, detail} from scorecard event rows."""
    walk, accepted, exams = None, False, {}
    for r in rows:
        if milestone and r.get("milestone") not in (None, milestone):
            continue
        ev = r.get("event")
        if ev == "walk":
            walk, accepted = r, False
        elif ev == "walk-accept" and walk is not None:
            accepted = True
        elif ev == "exam" and r.get("card") is not None:
            exams[r["card"]] = r
    if walk is None:
        return {"state": "not run", "detail": "walk not run"}
    failed_exams = [f"exam #{c} {r.get('score')}/{r.get('total')}" for c, r in sorted(exams.items())
                    if (r.get("score") or 0) < (r.get("pass_mark") or 0)]
    if walk.get("ok") and not failed_exams:
        return {"state": "passed", "detail": "agent walk passed"}
    bits = [f"screens {walk.get('passed')}/{walk.get('screens')}",
            f"questions {walk.get('answered')}/{walk.get('questions')}"] + failed_exams
    if accepted:
        return {"state": "accepted", "detail": "walk findings accepted (" + " · ".join(bits) + ")"}
    return {"state": "failed", "detail": "walk failed: " + " · ".join(bits)}


def read_rows(path: Path) -> list[dict]:
    out = []
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            try:
                out.append(json.loads(raw))
            except ValueError:
                continue
    except OSError:
        pass
    return out


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


def summarize(cov: dict, musts: list[int], done: set[int], milestone: str = "M1",
              walk: dict | None = None) -> dict:
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
    walk = walk or {"state": "not run", "detail": "walk not run"}
    built = bool(all_cards) and cards_done == len(all_cards) and demo_done
    complete = built and walk["state"] in ("passed", "accepted")
    if complete:
        line = f"{milestone} done: all cards, demo #{demo} Done · {walk['detail']}"
    elif built:
        line = f"{milestone}: {cards_done}/{len(all_cards)} cards done · demo #{demo} Done · {walk['detail']}"
    else:
        dtxt = f"demo #{demo} " if demo is not None else "no demo "
        state = "done" if demo_done else "not run"
        line = f"{milestone}: {cards_done}/{len(all_cards)} cards done · {dtxt}{state}"
    return {"milestone": milestone, "must_haves": per, "cards_done": cards_done,
            "cards_total": len(all_cards), "demo": demo, "demo_done": demo_done,
            "milestone_done": complete, "walk": walk["state"], "walk_detail": walk["detail"],
            "mockup_cuts": count_cuts(cov.get("cuts")), "line": line}


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
    cov = parse_coverage(ctext)
    errors, warnings = lint_problems(cov, parse_must_haves(ntext or ""))
    if cov["cuts"] is None and (root / MOCKUP).is_file():
        warnings.append("coverage.md has no `Cut from mock-up:` list; the owner can't see what the cards left out")
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
    sc = Path(args.scorecard) if args.scorecard else root / SCORECARD
    walk = walk_state(read_rows(sc), args.milestone)
    s = summarize(parse_coverage(ctext), musts, done, args.milestone, walk)
    if args.json:
        print(json.dumps(s))
        return 0
    for m in s["must_haves"]:
        extra = "  (no cards)" if m["total"] == 0 else ""
        print(f"must-have {m['must_have']}: {m['done']}/{m['total']} done{extra}")
    print(s["line"])
    return 0


def card_problems(card: dict, screens: set[str] | None, cov: dict | None) -> list[str]:
    """Mock-up block problems on one card; [] when fine or not a screen card."""
    body = card.get("body") or ""
    title = card.get("title") or ""
    ctx_line = card_line(section(body, "Context") or body, "Mock-up")
    if ctx_line is None or re.search(r"\[test\]\s*demo:", title, re.IGNORECASE):
        return []
    want = anchor_of(ctx_line)
    out: list[str] = []
    if want is None:
        out.append("Mock-up line names no `#screen-<name>` anchor")
    elif screens is not None and want not in screens:
        out.append(f"anchor #{want} is not in {MOCKUP}")
    block = section(body, "Mock-up")
    if block is None:
        return out + ["no `## Mock-up` block (anchor, markup excerpt, classes, cuts)"]
    got = anchor_of(card_line(block, "Anchor"))
    if got is None:
        out.append("mock-up block has no `Anchor:` line with `#screen-<name>`")
    elif want and got != want:
        out.append(f"mock-up block anchor #{got} differs from the Mock-up line #{want}")
    if not re.search(r"`[^`]+`|\.[A-Za-z]", card_line(block, "Classes") or ""):
        out.append("mock-up block has no class list (`Classes:` with the classes to use)")
    m = re.search(r"^\s*```(?:html)?\s*\n(.*?)^\s*```", block, re.M | re.S)
    if not m or "<" not in m.group(1):
        out.append("mock-up block has no markup excerpt (an ```html block)")
    cut = card_line(block, "Cut from mock-up")
    if not (cut or "").strip():
        out.append("mock-up block has no `Cut from mock-up:` line (list the cuts, or `none`)")
    elif cov is not None and cov["cuts"] is not None and not is_none(cut) \
            and card.get("number") is not None and int(card["number"]) not in cov["cut_cards"]:
        out.append("cuts features from the mock-up, but coverage.md's `Cut from mock-up:` list leaves it out")
    acs = section(body, "Acceptance Criteria") or ""
    target = want or got or "screen-"
    at = re.compile("#" + re.escape(target) + r"(?![A-Za-z0-9_-])")
    if not any("matches mock-up" in ln.lower() and at.search(ln)
               for ln in acs.splitlines() if re.match(r"^\s*[-*]\s+\[[ xX]\]", ln)):
        out.append(f"no AC `screen matches mock-up `#{target}` (screenshot side by side)`")
    return out


DEMO_TITLE_RE = re.compile(r"\[test\]\s*demo:", re.IGNORECASE)
OWN_INSTANCE_RE = re.compile(r"^\s*[-*]?\s*\**Decided:\**.*\bown app instance\b", re.IGNORECASE | re.M)


def demo_warning(card: dict) -> str | None:
    """The Demo card must run its own app instance, never the shared e2e server."""
    if not DEMO_TITLE_RE.search(card.get("title") or ""):
        return None
    if OWN_INSTANCE_RE.search(card.get("body") or ""):
        return None
    return ("Demo card has no `Decided:` line saying it runs its own app instance "
            "(own port, temp data folder, fake AI, fixed date; never the shared e2e server)")


def load_issues(src: str) -> list[dict]:
    raw = sys.stdin.read() if src == "-" else Path(src).read_text(encoding="utf-8")
    data = json.loads(raw)
    if not isinstance(data, list):
        raise ValueError("issues JSON must be a list")
    return [i for i in data if isinstance(i, dict)]


def cmd_cards(args) -> int:
    root = Path(args.repo_path)
    try:
        issues = load_issues(args.issues_json)
    except (OSError, ValueError) as e:
        print(f"cannot read issues json: {e}", file=sys.stderr)
        return 64
    mtext = read(root / MOCKUP)
    # Every `screen-<name>` token, not only literal ids: a vanilla-JS mock-up builds
    # `id="screen-${name}"` from a list of names.
    screens = set(re.findall(r"(?<![A-Za-z0-9_-])(screen-[A-Za-z0-9_-]*[A-Za-z0-9])", mtext)) if mtext is not None else None
    ctext = read(root / COVERAGE)
    cov = parse_coverage(ctext) if ctext is not None else None
    bad = 0
    checked = 0
    for card in issues:
        probs = card_problems(card, screens, cov)
        if card_line(section(card.get("body") or "", "Context") or card.get("body") or "", "Mock-up") is not None:
            checked += 1
        for p in probs:
            print(f"error: #{card.get('number')}: {p}")
        bad += bool(probs)
        w = demo_warning(card)
        if w:
            print(f"warning: #{card.get('number')}: {w}")
    if bad:
        print(f"{bad} screen card(s) fail the mock-up block check")
        return 1
    print(f"mock-up blocks ok ({checked} card(s) with a Mock-up line)")
    return 0


BODY_LABEL = "body-of-work"
SIGNED_RE = re.compile(r"^\s*Signed:[ \t]*(.*?)\s*$", re.IGNORECASE | re.M)


def label_names(card: dict) -> set[str]:
    out = set()
    for lab in card.get("labels") or []:
        name = lab.get("name") if isinstance(lab, dict) else lab
        if isinstance(name, str):
            out.add(name.strip().lower())
    return out


def signed(text: str) -> bool:
    m = SIGNED_RE.search(text or "")
    if not m:
        return False
    value = m.group(1).strip().strip("`*_")
    return bool(value) and value.lower() not in ("no", "not yet", "none") and not value.startswith("<")


def brief_problems(card: dict, root: Path) -> list[str]:
    """Body-of-work gate problems on one card; [] when fine or not a body of work."""
    body = card.get("body") or ""
    labels = label_names(card)
    out: list[str] = []
    if "proposal" in labels:
        out.append("still a `proposal`: it waits on the owner's accept, so it belongs in Backlog")
    line = card_line(section(body, "Context") or body, "Brief")
    if BODY_LABEL not in labels and line is None:
        return out
    m = re.search(r"(?<![\w/.-])((?:\./)?[\w./-]+\.md)\b", (line or "").replace("`", " "))
    if m is None:
        return out + ["body of work with no `Brief: docs/shape/briefs/<date>-<slug>.md` line in Context"]
    rel = m.group(1)
    path = (root / rel).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError:
        return out + [f"brief {rel} is outside the repo"]
    text = read(path)
    if text is None:
        return out + [f"brief {rel} not found"]
    if not signed(text):
        out.append(f"brief {rel} is not signed (no `Signed: <date> · <owner>` line)")
    return out


def cmd_briefs(args) -> int:
    root = Path(args.repo_path)
    try:
        issues = load_issues(args.issues_json)
    except (OSError, ValueError) as e:
        print(f"cannot read issues json: {e}", file=sys.stderr)
        return 64
    bad = 0
    for card in issues:
        probs = brief_problems(card, root)
        for p in probs:
            print(f"error: #{card.get('number')}: {p}")
        bad += bool(probs)
        w = demo_warning(card)
        if w:
            print(f"warning: #{card.get('number')}: {w}")
    if bad:
        print(f"{bad} card(s) fail the body-of-work gate")
        return 1
    print("briefs ok")
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
    b.add_argument("--scorecard", help=f"default <repo>/{SCORECARD}; the agent walk is read from it")
    b.set_defaults(fn=cmd_status)
    c = sub.add_parser("cards")
    c.add_argument("--repo-path", default=".")
    c.add_argument("--issues-json", required=True)
    c.set_defaults(fn=cmd_cards)
    d = sub.add_parser("briefs")
    d.add_argument("--repo-path", default=".")
    d.add_argument("--issues-json", required=True)
    d.set_defaults(fn=cmd_briefs)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
