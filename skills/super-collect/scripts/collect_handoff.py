"""super-collect's findings doc. Stdlib only.

    collect_handoff.py doc --findings v.json [--since 14d] [--date YYYY-MM-DD] [--out P] [--yes]

doc    Writes ONE findings doc from the verifier's results: `file` and `needs-triage`
       findings grouped by `group` (else by source), everything else listed under
       "Not in this doc". Default path docs/super-board/findings/collect-<date>.md;
       an existing file is never overwritten (-2, -3, …). Without --yes it prints the
       doc and writes nothing. Every finding is then filed straight into Backlog
       (super-collect-file.sh) in the ticket format.

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


def render(findings, since, date):
    kept = [f for f in findings if f.get("verdict") in KEEP]
    other = [f for f in findings if f.get("verdict") not in KEEP]
    groups = {}
    for f in kept:
        groups.setdefault(f.get("group") or f.get("source") or "other", []).append(f)
    lines = [f"# Findings · {date}", "",
             f"super-collect found these problems{' since ' + since if since else ''}. A fresh verifier checked each one.",
             f"{len(kept)} findings in {len(groups)} groups. Next: each one is filed straight into Backlog in the ticket format.", ""]
    for name, items in groups.items():
        lines += [f"## {name}", ""]
        for f in items:
            tag = " `needs-triage`" if f.get("verdict") == "needs-triage" else ""
            lines.append(f"- **{f.get('title', '(untitled)')}** · {f.get('type', 'bug')} · {f.get('source', '?')}{tag}")
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
    args = p.parse_args(argv)
    return {"doc": doc}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
