#!/usr/bin/env python3
"""Scorecard for lane models (factory #25): is a cheap builder landing good work?

record  — after each wave, append one JSON line per card to the board's scorecard,
          with tokens and minutes read from the wave's agent logs.
summary — one line per build model across every recorded wave.

  super-board-scorecard.py record --results <wave-cards.json> --logs <dir> \
      --scorecard docs/super-board/runs/scorecard.jsonl [--wave <label>]
  super-board-scorecard.py summary --scorecard docs/super-board/runs/scorecard.jsonl

--results is the wave's `cards` array (or the whole {cards, halted} result).
--logs is the folder holding the wave's agent-*.jsonl logs (searched recursively).
An agent already counted in an earlier row is never counted twice.
"""
import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

LANES = ("classify", "build", "qa", "review")
LABEL = re.compile(r"^(classify|build|qa|review):#(\d+)\b")
# Fallback when a log carries no label: the lane prompt's first line.
PROMPT = [
    (re.compile(r"Run super-build on issue #(\d+)\b"), "build"),
    (re.compile(r"Run super-qa on issue #(\d+)\b"), "qa"),
    (re.compile(r"Run super-review on issue #(\d+)\b"), "review"),
    (re.compile(r"Read GitHub issue #(\d+) .*Classify it"), "classify"),
]


def _ts(s):
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None


def _first_prompt(lines):
    for o in lines:
        m = o.get("message") or {}
        if o.get("type") == "user" or m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, list):
                c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            if isinstance(c, str) and c.strip():
                return c
    return ""


def read_agent(path):
    """One agent log → {id, lane, card, tokens, cache_read, minutes} or None."""
    lines = []
    for raw in path.read_text(errors="replace").splitlines():
        try:
            lines.append(json.loads(raw))
        except ValueError:
            continue
    label = ""
    meta = path.with_name(path.name[: -len(".jsonl")] + ".meta.json")
    if meta.exists():
        try:
            m = json.loads(meta.read_text())
            label = m.get("label") or m.get("description") or ""
        except ValueError:
            pass
    lane = card = None
    hit = LABEL.match(label)
    if hit:
        lane, card = hit.group(1), int(hit.group(2))
    else:
        text = _first_prompt(lines)
        for rx, ln in PROMPT:
            h = rx.search(text)
            if h:
                lane, card = ln, int(h.group(1))
                break
    if lane is None:
        return None
    tokens = cache_read = 0
    seen = set()
    stamps = []
    for o in lines:
        t = _ts(o.get("timestamp")) if o.get("timestamp") else None
        if t:
            stamps.append(t)
        msg = o.get("message") or {}
        u = msg.get("usage")
        # Streaming can log one API response on several lines; count it once.
        key = o.get("requestId") or msg.get("id")
        if not u or (key and key in seen):
            continue
        if key:
            seen.add(key)
        tokens += int(u.get("input_tokens", 0)) + int(u.get("cache_creation_input_tokens", 0)) + int(u.get("output_tokens", 0))
        cache_read += int(u.get("cache_read_input_tokens", 0))
    minutes = round((max(stamps) - min(stamps)).total_seconds() / 60, 1) if len(stamps) > 1 else 0.0
    return {"id": path.stem, "lane": lane, "card": card, "tokens": tokens, "cache_read": cache_read, "minutes": minutes}


def load_rows(path):
    rows = []
    if path.exists():
        for raw in path.read_text().splitlines():
            if raw.strip():
                rows.append(json.loads(raw))
    return rows


def record(a):
    res = json.loads(Path(a.results).read_text())
    cards = res.get("cards", []) if isinstance(res, dict) else res
    sc = Path(a.scorecard)
    counted = {i for r in load_rows(sc) for i in r.get("agents", [])}
    agents = []
    if a.logs:
        for p in sorted(Path(a.logs).rglob("*.jsonl")):
            if p.name.endswith(".meta.jsonl") or p.name == "journal.jsonl":
                continue
            ag = read_agent(p)
            if ag and ag["id"] not in counted:
                agents.append(ag)
    out = []
    for c in cards:
        mine = [g for g in agents if g["card"] == c.get("number")]
        out.append({
            "wave": a.wave,
            "card": c.get("number"),
            "complexity": c.get("complexity"),
            "buildModel": c.get("buildModel"),
            "qaModel": c.get("qaModel"),
            "reviewModel": c.get("reviewModel"),
            "lanesRun": c.get("lanesRun"),
            "finalStatus": c.get("finalStatus"),
            "column": c.get("column"),
            "score": c.get("score"),
            "tokens": sum(g["tokens"] for g in mine),
            "cacheRead": sum(g["cache_read"] for g in mine),
            "minutes": round(sum(g["minutes"] for g in mine), 1),
            "agents": [g["id"] for g in mine],
        })
    sc.parent.mkdir(parents=True, exist_ok=True)
    with sc.open("a") as f:
        for r in out:
            f.write(json.dumps(r, sort_keys=True) + "\n")
    unmatched = sum(1 for r in out if not r["agents"])
    print(json.dumps({"recorded": len(out), "agentsMatched": sum(len(r["agents"]) for r in out), "cardsWithoutLogs": unmatched}))


def light(first_pass, rework):
    # First guess at the cut-offs; the owner tunes them once there is data.
    if first_pass >= 70 and rework <= 10:
        return "🟢"
    if first_pass < 50 or rework > 25:
        return "🔴"
    return "🟡"


def summary(a):
    rows = load_rows(Path(a.scorecard))
    if not rows:
        print("no scorecard rows yet")
        return
    by_card = {}
    for r in rows:
        by_card.setdefault(r["card"], []).append(r)
    groups = {}
    for card, rs in by_card.items():
        model = next((r["buildModel"] for r in rs if r.get("buildModel")), None) or "unbuilt (qa cards)"
        groups.setdefault(model, []).append(rs)
    for model in sorted(groups):
        cards = groups[model]
        merged = [rs for rs in cards if any(r.get("column") == "Done" for r in rs)]
        scores = [r["score"] for rs in cards for r in rs if r.get("score")]
        first = [rs for rs in merged if not any("bounced" in (r.get("lanesRun") or "") for r in rs)]
        rounds = [max([r["score"].get("round", 1) for r in rs if r.get("score")] or [1]) for rs in merged]
        rework = [s for s in scores if s.get("verdict") == "rework"]
        causes = {}
        for s in scores:
            if s.get("verdict") in ("fixes", "rework") and s.get("cause") in ("build", "ticket"):
                causes[s["cause"]] = causes.get(s["cause"], 0) + 1
        n = len(merged)
        fp = round(100 * len(first) / n) if n else 0
        rw = round(100 * len(rework) / len(scores)) if scores else 0
        tok = sum(r.get("tokens", 0) for rs in merged for r in rs)
        mins = sum(r.get("minutes", 0) for rs in merged for r in rs)
        cause = " · cause build {} / ticket {}".format(causes.get("build", 0), causes.get("ticket", 0)) if causes else ""
        print("{} build {} · {} merged · first pass {}% · avg rounds {} · rework {}%{} · {}k tokens/card · {} min/card".format(
            light(fp, rw) if n else "⚪", model, n, fp,
            round(sum(rounds) / n, 1) if n else 0, rw, cause,
            round(tok / n / 1000) if n else 0, round(mins / n) if n else 0))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    r.add_argument("--results", required=True)
    r.add_argument("--logs")
    r.add_argument("--scorecard", required=True)
    r.add_argument("--wave", default="")
    s = sub.add_parser("summary")
    s.add_argument("--scorecard", required=True)
    a = p.parse_args()
    {"record": record, "summary": summary}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
