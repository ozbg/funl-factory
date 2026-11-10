#!/usr/bin/env python3
"""Resolve a card's zone tier from the app's docs/agents/zones.yaml.

super-board-zone.py --zones <path> [--files f1 f2 ... | --files-from -]

Prints JSON: tier, max_rounds, checks, bar, invariants, accepted_limits, boundary,
owner_gate, per_file. Tier = highest zone of any file; an unlisted file is amber.
No zones file: amber, max_rounds 2, "zones_file": false. Exit 2 on a parse error.
Stdlib only: a small parser for the zones.yaml shape (mappings, lists, `>` folded
scalars, inline [a, b] lists, comments). Not a general YAML parser.
"""
import argparse
import json
import re
import sys
from pathlib import Path

RANK = {"green": 0, "amber": 1, "red": 2}
DEFAULT_ROUNDS = {"green": 1, "amber": 2, "red": 3}


class ZoneError(Exception):
    pass


def scalar(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        return s[1:-1]
    if s.startswith("["):
        if not s.endswith("]"):
            raise ZoneError(f"unclosed inline list: {s}")
        return [scalar(x) for x in s[1:-1].split(",") if x.strip()]
    return int(s) if re.fullmatch(r"-?\d+", s) else s


def parse(text):
    rows = []  # [indent, content, lineno]
    for n, raw in enumerate(text.splitlines(), 1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise ZoneError(f"line {n}: tab indent")
        line = re.sub(r"(^|\s)#.*$", "", raw).rstrip()
        if line.strip():
            rows.append([len(line) - len(line.lstrip()), line.strip(), n])
    value, i = block(rows, 0, rows[0][0] if rows else 0)
    if i != len(rows):
        raise ZoneError(f"line {rows[i][2]}: unexpected indent")
    return value if value is not None else {}


def block(rows, i, indent):
    if i >= len(rows):
        return None, i
    if rows[i][1].startswith("- ") or rows[i][1] == "-":
        out = []
        while i < len(rows) and rows[i][0] == indent and rows[i][1].startswith("-"):
            item = rows[i][1][1:].strip()
            if re.match(r"^[\w-]+:(\s|$)", item):  # "- id: I1" starts a mapping item
                rows[i] = [indent + 2, item, rows[i][2]]
                v, i = block(rows, i, indent + 2)
            else:
                v, i = scalar(item), i + 1
            out.append(v)
        return out, i
    out = {}
    while i < len(rows) and rows[i][0] == indent:
        ind, text, n = rows[i]
        m = re.match(r"^([\w-]+):(?:\s+(.*))?$", text)
        if not m:
            raise ZoneError(f"line {n}: expected 'key: value'")
        key, val = m.group(1), (m.group(2) or "").strip()
        i += 1
        if val in (">", ">-", "|"):
            parts = []
            while i < len(rows) and rows[i][0] > ind:
                parts.append(rows[i][1])
                i += 1
            out[key] = " ".join(parts)
        elif val:
            out[key] = scalar(val)
        elif i < len(rows) and rows[i][0] > ind:
            out[key], i = block(rows, i, rows[i][0])
        else:
            out[key] = None
    if i < len(rows) and rows[i][0] > indent:
        raise ZoneError(f"line {rows[i][2]}: unexpected indent")
    return out, i


def glob_re(pat):
    tok = {"**/": "(?:.*/)?", "**": ".*", "*": "[^/]*", "?": "[^/]"}
    parts = re.findall(r"\*\*/|\*\*|\*|\?|[^*?]+", pat)
    return re.compile("".join(tok.get(t) or re.escape(t) for t in parts) + r"\Z")


def matches(path, pats):
    return any(glob_re(str(p)).match(path) for p in pats or [])


def resolve(doc, files):
    zones = doc.get("zones")
    if not isinstance(zones, dict):
        raise ZoneError("missing 'zones:' mapping")
    per_file = {}
    for f in files:
        hits = [z for z in RANK if matches(f, (zones.get(z) or {}).get("paths"))]
        per_file[f] = max(hits, key=RANK.get) if hits else "amber"
    tier = max(per_file.values(), key=RANK.get) if per_file else "amber"
    z = zones.get(tier) or {}
    return {
        "tier": tier,
        "max_rounds": z.get("max_rounds", DEFAULT_ROUNDS[tier]),
        "checks": z.get("checks") or [],
        "bar": z.get("bar") or z.get("purpose") or "",
        "invariants": z.get("invariants") or [],
        "accepted_limits": doc.get("accepted_limits") or [],
        "boundary": any(matches(f, doc.get("boundary")) for f in files),
        "owner_gate": z.get("owner_gate") or [],
        "per_file": per_file,
        "zones_file": True,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--zones", required=True)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--files", nargs="*", default=[])
    g.add_argument("--files-from")
    a = ap.parse_args()
    files = a.files
    if a.files_from:
        src = sys.stdin if a.files_from == "-" else open(a.files_from)
        files = [l.strip() for l in src if l.strip()]
    files = [f[2:] if f.startswith("./") else f for f in files]
    path = Path(a.zones)
    if not path.is_file():
        print(json.dumps({**resolve({"zones": {}}, files), "zones_file": False}))
        return 0
    try:
        doc = parse(path.read_text())
        if not isinstance(doc, dict):
            raise ZoneError("top level is not a mapping")
        print(json.dumps(resolve(doc, files)))
    except ZoneError as e:
        print(f"super-board-zone: {path}: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
