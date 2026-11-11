"""super-collect's triage, findings doc and proposals digest. Stdlib only.

    collect_handoff.py triage --findings v.json [--max-fix N | --config cfg.json]
    collect_handoff.py doc    --findings v.json [--since 14d] [--date YYYY-MM-DD] [--out P] [--yes]
    collect_handoff.py digest --issues-json open-proposals.json

triage Applies the track and fix-or-propose rules (super-board references/iteration.md) to
       the verified findings and prints them back as JSON with the final `track`,
       `decision`, `column` and `why`. Input per finding, from the triage agent:
       `track` bug|tweak|body, `decision` fix|propose, `breaks` (the spec line, rule or
       baseline screen it breaks), `screens` [names], `touches` [rule|data-model|contract],
       `zone` green|amber|red, `recommendation`. What it touches picks the track: a rule,
       the data model, a contract or more than one screen makes it a body of work. A fix
       needs verdict `file`, track bug or tweak, a `breaks` citation, at most one screen,
       nothing touched and zone green or amber; anything else, or unsure, is proposed.
       Fixes past the cap (--max-fix, else the config's collect.triage.max_fix_cards,
       else 5) become proposals recommending the fix. A proposal from the agent with no
       recommendation is refused (exit 64).

doc    Writes ONE findings doc from the verifier's results: `file` and `needs-triage`
       findings grouped by `group` (else by source), everything else listed under
       "Not in this doc". Default path docs/super-board/findings/collect-<date>.md;
       an existing file is never overwritten (-2, -3, …). Without --yes it prints the
       doc and writes nothing. Every finding is then filed straight into Backlog
       (super-collect-file.sh) in the ticket format.
digest Prints the proposals digest from `gh issue list --label proposal --state open
       --json number,title,body,labels,url`: one row each with its track and the first
       line of its `## Recommendation`, for the owner to accept or reject.

Exits: 0 ok · 3 nothing verified · 64 bad args
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

KEEP = ("file", "needs-triage")
DOC_DIR = "docs/super-board/findings"
TRACKS = ("bug", "tweak", "body")
TRACK_LABEL = {"bug": "bug", "tweak": "tweak", "body": "body-of-work"}
WIDE = ("rule", "data-model", "contract")
DEFAULT_MAX_FIX = 5


def route(f):
    """Final (track, decision, why) for one kept finding."""
    touches = [t for t in (f.get("touches") or []) if t in WIDE]
    screens = f.get("screens") or []
    track = f.get("track") if f.get("track") in TRACKS else None
    if touches or len(screens) > 1:
        wide = ", ".join(touches + ([f"{len(screens)} screens"] if len(screens) > 1 else []))
        return "body", "propose", f"touches {wide}: a body of work, whatever its label"
    if track is None:
        return "body", "propose", "no track given: unsure, so proposed"
    if track == "body":
        return track, "propose", "a body of work is always proposed"
    if f.get("decision") != "fix":
        return track, "propose", "triage proposed it"
    if f.get("verdict") != "file":
        return track, "propose", "the verifier was unsure (needs-triage)"
    if not str(f.get("breaks") or "").strip():
        return track, "propose", "cites no spec line, rule or baseline screen it breaks"
    if f.get("zone") not in ("green", "amber"):
        return track, "propose", f"zone {f.get('zone') or 'unknown'}: only green or amber is fixed alone"
    return track, "fix", f"breaks {f['breaks']}"


def max_fix(args):
    if args.max_fix is not None:
        return args.max_fix
    if args.config:
        cfg = json.loads(Path(args.config).read_text())
        n = ((cfg.get("collect") or {}).get("triage") or {}).get("max_fix_cards")
        if isinstance(n, int) and n >= 0:
            return n
    return DEFAULT_MAX_FIX


def triage(args):
    findings = json.loads(Path(args.findings).read_text())
    if not isinstance(findings, list):
        print("collect-handoff: --findings must be a JSON array", file=sys.stderr)
        return 64
    cap, fixes, missing = max_fix(args), 0, []
    for f in findings:
        if f.get("verdict") not in KEEP:
            continue
        asked = f.get("decision")
        track, decision, why = route(f)
        if decision == "fix":
            fixes += 1
            if fixes > cap:
                decision, why = "propose", f"over the cap of {cap} fix cards a run"
                f["recommendation"] = f"Accept: a {track} fix, held back by the run cap."
        if decision == "propose" and not str(f.get("recommendation") or "").strip():
            if asked == "propose":
                missing.append(f.get("title") or f.get("fingerprint") or "?")
            elif track == "body":
                f["recommendation"] = "Accept to grill it as a body of work (iteration.md), or reject."
            else:
                f["recommendation"] = f"Accept as a {track} fix once it names what it breaks ({why}), or reject."
        f.update(track=track, decision=decision, why=why,
                 column="Ready" if decision == "fix" else "Backlog",
                 labels=[TRACK_LABEL[track]] + (["proposal"] if decision == "propose" else []))
    if missing:
        print("collect-handoff: a proposal needs a recommendation: " + "; ".join(missing), file=sys.stderr)
        return 64
    print(json.dumps(findings, indent=2))
    kept = [f for f in findings if f.get("verdict") in KEEP]
    print(f"collect-handoff: {sum(f['decision'] == 'fix' for f in kept)} fix (cap {cap}) · "
          f"{sum(f['decision'] == 'propose' for f in kept)} propose", file=sys.stderr)
    return 0


def recommendation(body):
    lines, inside = (body or "").splitlines(), False
    for line in lines:
        if line.startswith("## "):
            inside = line[3:].strip().lower() == "recommendation"
            continue
        if inside and line.strip():
            return line.strip().lstrip("-* ").strip()
    return "(no recommendation: ask triage for one before deciding)"


def digest(args):
    issues = json.loads(Path(args.issues_json).read_text())
    if not isinstance(issues, list):
        print("collect-handoff: --issues-json must be a JSON array", file=sys.stderr)
        return 64
    rows = []
    for i in issues:
        names = {(l.get("name") if isinstance(l, dict) else l) for l in i.get("labels") or []}
        if "proposal" not in names:
            continue
        track = next((t for t, l in TRACK_LABEL.items() if l in names), "?")
        title = str(i.get("title") or "").replace("|", "/")
        rec = recommendation(i.get("body")).replace("|", "/")
        rows.append(f"| #{i.get('number')} | {track} | {title} | {rec} |")
    if not rows:
        print("## Proposals · none open")
        return 0
    print("\n".join([f"## Proposals · {len(rows)} open", "",
                     "| # | Track | Proposal | Recommendation |", "|---|---|---|---|", *rows, "",
                     "Answer each one: `accept #N`, or `reject #N <reason>`."]))
    return 0


def render(findings, since, date):
    kept = [f for f in findings if f.get("verdict") in KEEP]
    other = [f for f in findings if f.get("verdict") not in KEEP]
    groups = {}
    for f in kept:
        groups.setdefault(f.get("group") or f.get("source") or "other", []).append(f)
    lines = [f"# Findings · {date}", "",
             f"super-collect found these problems{' since ' + since if since else ''}. A fresh verifier checked each one.",
             f"{len(kept)} findings in {len(groups)} groups. Next: fixes are filed to Ready (capped), and everything else is filed straight into Backlog, in the ticket format.", ""]
    for name, items in groups.items():
        lines += [f"## {name}", ""]
        for f in items:
            tag = " `needs-triage`" if f.get("verdict") == "needs-triage" else ""
            if f.get("decision"):
                tag += f" · {f.get('track')} · {f['decision']} → {f.get('column')}"
            lines.append(f"- **{f.get('title', '(untitled)')}** · {f.get('type', 'bug')} · {f.get('source', '?')}{tag}")
            if f.get("why"):
                lines.append(f"  - Triage: {f['why']}")
            if f.get("decision") == "propose" and f.get("recommendation"):
                lines.append(f"  - Recommendation: {f['recommendation']}")
            if f.get("note"):
                lines.append(f"  - {f['note']}")
            if f.get("evidence"):
                lines.append("  - Evidence: " + ", ".join(str(e) for e in f["evidence"]))
            if f.get("fingerprint"):
                lines.append(f"  - Fingerprint: `{f['fingerprint']}`")
        lines.append("")
    if other:
        lines += ["## Not in this doc", ""]
        for f in other:
            why = f" — {f['note']}" if f.get("note") else ""
            lines.append(f"- {f.get('title', '(untitled)')} · {f.get('verdict', '?')}{why}")
        lines.append("")
    return "\n".join(lines), len(kept)


def doc(args):
    findings = json.loads(Path(args.findings).read_text())
    if not isinstance(findings, list):
        print("collect-handoff: --findings must be a JSON array", file=sys.stderr)
        return 64
    date = args.date or dt.date.today().isoformat()
    text, kept = render(findings, args.since, date)
    if not kept:
        print("collect-handoff: nothing to hand off — no finding has verdict file or needs-triage", file=sys.stderr)
        return 3
    out = Path(args.out) if args.out else Path(DOC_DIR) / f"collect-{date}.md"
    n = 2
    base = out
    while out.exists():
        out = base.with_name(f"{base.stem}-{n}{base.suffix}")
        n += 1
    if not args.yes:
        sys.stdout.write(text)
        print(f"collect-handoff: dry run — would write {out}", file=sys.stderr)
        return 0
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(out)
    return 0


class Parser(argparse.ArgumentParser):
    def error(self, message):
        print("collect-handoff: " + message, file=sys.stderr)
        sys.exit(64)


def main(argv=None):
    p = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=Parser)
    d = sub.add_parser("doc")
    d.add_argument("--findings", required=True)
    d.add_argument("--since", default="")
    d.add_argument("--date")
    d.add_argument("--out")
    d.add_argument("--yes", action="store_true")
    t = sub.add_parser("triage")
    t.add_argument("--findings", required=True)
    t.add_argument("--max-fix", type=int)
    t.add_argument("--config")
    g = sub.add_parser("digest")
    g.add_argument("--issues-json", required=True)
    args = p.parse_args(argv)
    return {"doc": doc, "triage": triage, "digest": digest}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
