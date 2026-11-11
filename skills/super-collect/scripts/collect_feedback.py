#!/usr/bin/env python3
"""super-collect source `feedback`: the items an app's feedback icon saved on this machine
(spec: .claude/skills/to-board/references/feedback-card.md, schema `feedback/1`).

    collect_feedback.py list [--dir D] [--config C] [--since 14d]
    collect_feedback.py mark --ids ID[,ID…] --issue N --fingerprint FP [--dir D] [--config C]

list  Reads every new item in the folder (`--dir`, else the config's collect.feedback.dir,
      else `data/feedback`), redacts it, groups repeats and prints candidates shaped like
      every other source's. New = not named in `<dir>/filed.json`. `--since` narrows by
      `created_at`; without it every new item is read.
      Redaction, before anything leaves the machine: emails, phone numbers, the string
      values of name-like state keys (and those names wherever they appear), query-string
      values in the route, and token-like strings in logs. Screenshots are never uploaded:
      the candidate names the local PNG path only.
      Dedupe: items on the same route (ids collapsed) and element whose words overlap
      (Jaccard >= 0.5) are one candidate. A candidate that matches an item already filed
      reuses that item's fingerprint, so the filer adds "Seen again" to the open issue.
      Fingerprint `feedback|<route>|<element>|<text hash>` (collect_common.fingerprint).
mark  Records the filed issue for each id in `<dir>/filed.json` (the app's list reads it),
      so an item is never filed twice.

Output: one JSON object. Exit 0 ok · 2 folder missing or unreadable · 64 usage.
No network. Stdlib only.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collect_common as cc  # noqa: E402

SCHEMA = "feedback/1"
DEFAULT_DIR = "data/feedback"
SIDECAR = "filed.json"
REQUIRED = ("id", "created_at", "text", "route")
SIMILAR = 0.5
MAX_LOG = 50

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
PHONE = re.compile(r"(?<![\w])\+?\(?\d[\d\s().-]{7,}\d(?![\w])")
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
TOKEN = re.compile(r"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}|\b(sk|pk|ghp|gho|xox[abp])[-_][A-Za-z0-9_-]{8,}")
NAME_KEY = re.compile(r"(?i)(^|_)(name|first|last|full|contact|email|phone|mobile|address|user|owner|customer|client)($|_)")
ID_KEY = re.compile(r"(?i)(^|_)(id|ids|count|n)$")
STOP = {"the", "a", "an", "is", "it", "on", "in", "of", "to", "and", "or", "i", "my", "this", "that",
        "does", "do", "not", "no", "when", "with", "for", "be", "was", "at", "n", "me", "are", "than",
        "name", "email", "phone", "token", "redacted"}  # the last five are redaction marks


def folder(args):
    if args.dir:
        return args.dir
    cfg, _ = cc.active_config(args.config)
    return (cc.collect_block(cfg, "feedback") or {}).get("dir") or DEFAULT_DIR


def read_sidecar(d):
    p = os.path.join(d, SIDECAR)
    if not os.path.exists(p):
        return {}
    with open(p) as f:
        data = json.load(f)
    return data if isinstance(data, dict) else {}


def write_sidecar(d, data):
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".filed-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, os.path.join(d, SIDECAR))


def names_in(state):
    """String values of name-like keys: they are redacted everywhere they appear."""
    found = []
    for k, v in (state or {}).items():
        if isinstance(v, str) and len(v.strip()) > 1 and NAME_KEY.search(k) and not ID_KEY.search(k):
            found.append(v.strip())
    return sorted(set(found), key=len, reverse=True)


def scrub(text, names):
    text = str(text or "")
    for n in names:
        text = re.sub(r"\b" + re.escape(n) + r"\b", "[name]", text, flags=re.I)
    text = EMAIL.sub("[email]", text)
    text = TOKEN.sub(lambda m: (m.group(1) or "") + "[token]", text)
    return PHONE.sub(phone, text)


def phone(m):
    s = m.group(0)
    if sum(c.isdigit() for c in s) < 9 or DATE.search(s):
        return s
    return "[phone]"


def scrub_route(route, names):
    path, _, query = str(route or "").partition("?")
    path = scrub(path, names)
    if not query:
        return path
    keys = [q.split("=", 1)[0] for q in query.split("&") if q]
    return path + "?" + "&".join(f"{k}=…" for k in keys)


def scrub_state(state, names):
    out = {}
    for k, v in (state or {}).items():
        if NAME_KEY.search(k) and not ID_KEY.search(k) and isinstance(v, str):
            out[k] = "[redacted]"
        elif isinstance(v, (int, float, bool)) or v is None:
            out[k] = v
        else:
            out[k] = scrub(json.dumps(v) if not isinstance(v, str) else v, names)
    return out


def redact(item):
    names = names_in(item.get("state"))
    logs = item.get("logs") or {}
    return {
        "id": item["id"],
        "created_at": item["created_at"],
        "text": scrub(item["text"], names),
        "route": scrub_route(item["route"], names),
        "screen": item.get("screen") or None,
        "element": scrub(item.get("element"), names) or None,
        "app": {k: (item.get("app") or {}).get(k) for k in ("version", "commit") if (item.get("app") or {}).get(k)},
        "state": scrub_state(item.get("state"), names),
        "logs": {side: [scrub(l, names) for l in (logs.get(side) or [])[-MAX_LOG:]] for side in ("client", "server")},
        "marked_up": bool(item.get("marked_up")),
    }


def route_key(route):
    path = str(route or "").split("?", 1)[0].split("#", 1)[0] or "/"
    return re.sub(r"/(\d+|[0-9a-f]{8,}|[0-9a-f-]{36})(?=/|$)", "/N", path.lower())


def words(text):
    return {w for w in re.findall(r"[a-z]+", cc.normalize(text)) if w not in STOP}


def similar(a, b):
    if not a or not b:
        return a == b
    return len(a & b) / len(a | b) >= SIMILAR


def load(d, since):
    items, skipped = [], []
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json") or name == SIDECAR or name.startswith("."):
            continue
        try:
            with open(os.path.join(d, name)) as f:
                item = json.load(f)
        except (OSError, ValueError) as e:
            skipped.append({"file": name, "why": f"unreadable: {e.__class__.__name__}"})
            continue
        if not isinstance(item, dict) or item.get("schema") != SCHEMA:
            skipped.append({"file": name, "why": f"schema {item.get('schema') if isinstance(item, dict) else '?'!r} is not {SCHEMA}"})
            continue
        missing = [k for k in REQUIRED if not str(item.get(k) or "").strip()]
        if not ((item.get("app") or {}).get("version") or (item.get("app") or {}).get("commit")):
            missing.append("app.version or app.commit")
        if missing:
            skipped.append({"file": name, "why": "missing " + ", ".join(missing)})
            continue
        if since:
            try:
                at = cc.since(item["created_at"])
            except ValueError:
                skipped.append({"file": name, "why": "created_at is not ISO 8601"})
                continue
            if at < since:
                continue
        shot = os.path.basename(str(item.get("screenshot") or ""))
        item["_shot"] = os.path.join(d, shot) if shot and os.path.isfile(os.path.join(d, shot)) else None
        items.append(item)
    return items, skipped


def cmd_list(args):
    d = folder(args)
    if not os.path.isdir(d):
        print(json.dumps({"status": "unavailable", "error": f"no feedback folder at {d}"}))
        return 2
    try:
        filed = read_sidecar(d)
    except (OSError, ValueError) as e:
        print(json.dumps({"status": "unavailable", "error": f"{SIDECAR} unreadable: {e.__class__.__name__}"}))
        return 2
    since = cc.since(args.since) if args.since else None
    items, skipped = load(d, since)
    new = [i for i in items if i["id"] not in filed]
    groups = []
    for item in new:
        clean = redact(item)
        key = (route_key(clean["route"]), clean["element"] or "screen", words(clean["text"]))
        g = next((g for g in groups if g["key"][:2] == key[:2] and similar(g["key"][2], key[2])), None)
        if g is None:
            groups.append({"key": key, "items": [clean], "shots": []})
            g = groups[-1]
        else:
            g["items"].append(clean)
        if item["_shot"]:
            g["shots"].append(item["_shot"])
    candidates = []
    for g in groups:
        route, element, ws = g["key"]
        first = g["items"][0]
        fp = cc.fingerprint("feedback", route, element, " ".join(sorted(ws)) or first["text"])
        seen = next((r for r in filed.values() if r.get("route") == route and r.get("element") == element
                     and similar(set(r.get("words") or []), ws) and r.get("fingerprint")), None)
        if seen:
            fp = seen["fingerprint"]
        candidates.append({
            "title": first["text"].splitlines()[0][:80],
            "type": "bug",
            "source": "feedback",
            "fingerprint": fp,
            "seen_before": f"#{seen['issue']}" if seen else None,
            "route": route,
            "screen": first["screen"],
            "element": None if element == "screen" else element,
            "count": len(g["items"]),
            "ids": [i["id"] for i in g["items"]],
            "words": sorted(ws),
            "items": g["items"],
            "screenshots_local": g["shots"],
            "evidence": [f"{len(g['items'])} feedback item(s) on {route}"]
            + ([f"{len(g['shots'])} screenshot(s) kept local"] if g["shots"] else []),
        })
    status = "read" if candidates else "empty"
    print(json.dumps({"status": status, "dir": d, "new": len(new), "already_filed": len(items) - len(new),
                      "skipped": skipped, "candidates": candidates}, indent=2))
    return 0


def cmd_mark(args):
    d = folder(args)
    if not os.path.isdir(d):
        print(json.dumps({"status": "unavailable", "error": f"no feedback folder at {d}"}))
        return 2
    if not re.fullmatch(r"\d+", args.issue or ""):
        print("collect-feedback: --issue takes an issue number", file=sys.stderr)
        return 64
    if not args.fingerprint.startswith("feedback|"):
        print("collect-feedback: --fingerprint must start feedback|", file=sys.stderr)
        return 64
    ids = [i.strip() for i in args.ids.split(",") if i.strip()]
    items, _ = load(d, None)
    by_id = {i["id"]: i for i in items}
    unknown = [i for i in ids if i not in by_id]
    if not ids or unknown:
        print("collect-feedback: no such item: " + (", ".join(unknown) or "(none given)"), file=sys.stderr)
        return 64
    filed = read_sidecar(d)
    now = dt.datetime.now(cc.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    for i in ids:
        clean = redact(by_id[i])
        filed[i] = {"issue": int(args.issue), "fingerprint": args.fingerprint, "filed_at": now,
                    "route": route_key(clean["route"]), "element": clean["element"] or "screen",
                    "words": sorted(words(clean["text"]))}
    write_sidecar(d, filed)
    print(json.dumps({"status": "marked", "issue": int(args.issue), "ids": ids}))
    return 0


class Parser(argparse.ArgumentParser):
    def error(self, message):
        print("collect-feedback: " + message, file=sys.stderr)
        sys.exit(64)


def main(argv=None):
    p = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=Parser)
    for name in ("list", "mark"):
        s = sub.add_parser(name)
        s.add_argument("--dir")
        s.add_argument("--config")
        if name == "list":
            s.add_argument("--since")
        else:
            s.add_argument("--ids", required=True)
            s.add_argument("--issue", required=True)
            s.add_argument("--fingerprint", required=True)
    args = p.parse_args(argv)
    return {"list": cmd_list, "mark": cmd_mark}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
