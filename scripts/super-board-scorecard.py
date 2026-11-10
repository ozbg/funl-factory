#!/usr/bin/env python3
"""Scorecard and health for the factory (factory #25, v2 T9).

record  — after each wave, append one JSON line per card to the board's scorecard,
          with tokens (split), API-equivalent dollars and minutes from the agent logs.
summary — one line per build model across every recorded wave.
health  — four acting metrics; a breach steps ramp.stage down one and pauses or asks.
          Never halts. Prints {breaches, action, ...} and appends a health event row.
demo    — record that the owner accepted a demo (an event row).
digest  — short plain-text owner digest; prints only on a merge, breach or ask
          (every wave when the config's `digest` is "every-wave").

  super-board-scorecard.py record --results <wave-cards.json> --logs <dir> \
      --scorecard docs/super-board/runs/scorecard.jsonl [--wave <label>] [--milestone <title>]
  super-board-scorecard.py summary --scorecard docs/super-board/runs/scorecard.jsonl
  super-board-scorecard.py health --config <cfg> [--wave <label>] [--goal-done N --goal-total N]
  super-board-scorecard.py demo --accepted
  super-board-scorecard.py digest --config <cfg> --plan <plan.json> [--wave <label>]

--results is the wave's `cards` array (or the whole {cards, halted} result).
--logs is the folder holding the wave's agent-*.jsonl logs (searched recursively).
An agent already counted in an earlier row is never counted twice.
"""
import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_SC = "docs/super-board/runs/scorecard.jsonl"

# List prices, $ per million tokens: input, output, cache write, cache read.
# API-EQUIVALENT dollars only: on a Claude plan this is not real spend, it is a
# yardstick for goal.budget_usd. Update here when list prices change.
PRICES = {
    "opus": (4.00, 20.00, 5.00, 0.20),
    "sonnet": (2.00, 10.00, 2.50, 0.20),
    "haiku": (0.10, 0.50, 0.125, 0.01),
}
# A model we cannot name is priced as opus, so the budget errs on the safe side.
UNKNOWN_FAMILY = "opus"


def family(model):
    m = str(model or "").lower()
    return next((f for f in PRICES if f in m), UNKNOWN_FAMILY)


def usd(split, model):
    p = PRICES[family(model)]
    return (split["input"] * p[0] + split["output"] * p[1]
            + split["cacheWrite"] * p[2] + split["cacheRead"] * p[3]) / 1e6


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

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
    """One agent log → {id, lane, card, tokens, cache_read, split, usd, minutes} or None."""
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
    model = None
    if meta.exists():
        try:
            model = json.loads(meta.read_text()).get("model")
        except ValueError:
            pass
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
    split = {"input": 0, "output": 0, "cacheWrite": 0, "cacheRead": 0}
    seen = set()
    stamps = []
    for o in lines:
        t = _ts(o.get("timestamp")) if o.get("timestamp") else None
        if t:
            stamps.append(t)
        msg = o.get("message") or {}
        model = model or msg.get("model")
        u = msg.get("usage")
        # Streaming can log one API response on several lines; count it once.
        key = o.get("requestId") or msg.get("id")
        if not u or (key and key in seen):
            continue
        if key:
            seen.add(key)
        split["input"] += int(u.get("input_tokens", 0))
        split["output"] += int(u.get("output_tokens", 0))
        split["cacheWrite"] += int(u.get("cache_creation_input_tokens", 0))
        split["cacheRead"] += int(u.get("cache_read_input_tokens", 0))
    minutes = round((max(stamps) - min(stamps)).total_seconds() / 60, 1) if len(stamps) > 1 else 0.0
    # `tokens` keeps its old meaning (no cache reads); the split carries all four.
    tokens = split["input"] + split["cacheWrite"] + split["output"]
    return {"id": path.stem, "lane": lane, "card": card, "tokens": tokens, "cache_read": split["cacheRead"],
            "split": split, "usd": usd(split, model), "minutes": minutes}


def load_all(path):
    rows = []
    if path.exists():
        for raw in path.read_text().splitlines():
            if raw.strip():
                rows.append(json.loads(raw))
    return rows


def load_rows(path):
    """Card rows only; event rows (health, demo) are skipped."""
    return [r for r in load_all(path) if "event" not in r]


def append(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")


def record(a):
    res = json.loads(Path(a.results).read_text())
    cards = res.get("cards", []) if isinstance(res, dict) else res
    events = res.get("events", []) if isinstance(res, dict) else []
    uncited = {e.get("number") for e in events if isinstance(e, dict) and e.get("type") == "uncited-bounce"}
    at = now_iso()
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
        split = {k: sum(g["split"][k] for g in mine) for k in ("input", "output", "cacheWrite", "cacheRead")}
        citation = c.get("citation") or a.citation
        out.append({
            "wave": a.wave,
            "at": at,
            "milestone": c.get("milestone") or a.milestone,
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
            "tokenSplit": split,
            "usd": round(sum(g["usd"] for g in mine), 4),
            "citation": None if (c.get("number") in uncited or c.get("uncitedBounce")) else citation,
            "uncited": c.get("number") in uncited or bool(c.get("uncitedBounce")),
            "roundCapped": bool(c.get("roundCapped") or c.get("round_capped") or a.round_capped),
            "minutes": round(sum(g["minutes"] for g in mine), 1),
            "agents": [g["id"] for g in mine],
        })
    append(sc, out)
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
        model = next((r["buildModel"] for r in rs if r.get("buildModel")), None) or "not built in these waves"
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


# ── health (v2 T9) ──────────────────────────────────────────────────────────
# Only these four act. Limits are first guesses; the owner tunes them with data.
ROUNDS_LIMIT = 2          # rolling rounds per merged card, above this breaches
ROLLING = 10              # merged cards in the rolling window
BURN_PCT = 80             # budget used at or above this ...
MERGED_PCT = 60           # ... with under this share of the goal merged breaches
FAILURES_LIMIT = 2        # failed/halted lane exits today, above this breaches
REPORT_AFTER = 10         # report-only metrics count once this many cards merged


def _lane_exits(r):
    exits = [t.split(":", 1)[1] for t in (r.get("lanesRun") or "").split(" → ") if ":" in t]
    return exits or [r.get("finalStatus")]


def _merged_cards(rows):
    """Card numbers in the order they reached Done (first time)."""
    out = []
    for r in rows:
        if r.get("column") == "Done" and r["card"] not in out:
            out.append(r["card"])
    return out


def compute_health(all_rows, cfg, wave=None, goal_done=None, goal_total=None, today=None):
    rows = [r for r in all_rows if "event" not in r]
    goal = cfg.get("goal") or {}
    milestone = goal.get("milestone")
    budget = goal.get("budget_usd")
    wave = wave if wave is not None else (rows[-1].get("wave") if rows else None)
    today = today or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    on_goal = [r for r in rows if not milestone or r.get("milestone") in (None, milestone)]
    this_wave = [r for r in rows if r.get("wave") == wave]
    merged = _merged_cards(rows)
    warnings = []
    if wave is not None and not this_wave:
        warnings.append("wave {} wrote no scorecard rows".format(wave))

    # Goal progress: the milestone's own counts when given, else what the scorecard saw.
    if goal_total is None:
        seen = {r["card"] for r in on_goal}
        goal_total, goal_done = len(seen), len(set(_merged_cards(on_goal)))
    goal_done = goal_done or 0
    spent = round(sum(r.get("usd") or 0 for r in on_goal), 2)

    by_card = {}
    for r in rows:
        by_card.setdefault(r["card"], []).append(r)
    window = merged[-ROLLING:]
    rounds = [max([(r.get("score") or {}).get("round", 1) for r in by_card[c]] or [1]) for c in window]
    rpm = round(sum(rounds) / len(rounds), 2) if rounds else 0
    capped = sorted({r["card"] for r in this_wave if r.get("roundCapped")})
    failures = sum(1 for r in rows if str(r.get("at", "")).startswith(today)
                   for x in _lane_exits(r) if x in ("failed", "halted"))
    burn = round(100 * spent / budget) if budget else 0
    done_pct = round(100 * goal_done / goal_total) if goal_total else 0

    breaches = []
    if capped:
        breaches.append({"metric": "round-capped", "detail": "cards hit the round cap: " + ", ".join("#%s" % c for c in capped)})
    if rpm > ROUNDS_LIMIT:
        breaches.append({"metric": "rounds-per-merge", "detail": "{} rounds per merged card (last {}) > {}".format(rpm, len(window), ROUNDS_LIMIT)})
    if budget and burn >= BURN_PCT and done_pct < MERGED_PCT:
        breaches.append({"metric": "budget-burn", "detail": "${} of ${} ({}%) with {}/{} merged ({}%)".format(
            spent, budget, burn, goal_done, goal_total, done_pct)})
    if failures > FAILURES_LIMIT:
        breaches.append({"metric": "factory-failures", "detail": "{} failed/halted lane exits today > {}".format(failures, FAILURES_LIMIT)})
    # Budget asks the owner; any other breach only pauses new cards. Never halts.
    if any(b["metric"] == "budget-burn" for b in breaches):
        action = "stop-ask"
    elif breaches:
        action = "pause-new"
    else:
        action = "continue"

    # Report-only: shown, never acted on, and only meaningful after REPORT_AFTER merges.
    bounced = [r for r in rows if "bounced" in (r.get("lanesRun") or "")]
    cited = [r for r in bounced if r.get("citation") and not r.get("uncited")]
    merged_rows = [r for c in merged for r in by_card[c]]
    tok = sum(sum((r.get("tokenSplit") or {}).values()) or r.get("tokens", 0) for r in merged_rows)
    demos = [r for r in all_rows if r.get("event") == "demo" and r.get("accepted")]
    days = None
    if demos:
        last = datetime.fromisoformat(demos[-1]["at"].replace("Z", "+00:00"))
        days = (datetime.fromisoformat(today + "T00:00:00+00:00") - last.replace(hour=0, minute=0, second=0)).days
    return {
        "action": action,
        "breaches": breaches,
        "wave": wave,
        "metrics": {"roundCapped": capped, "roundsPerMerge": rpm, "budgetBurnPct": burn,
                    "goalMergedPct": done_pct, "failuresToday": failures},
        "budget": {"usd": spent, "budget_usd": budget},
        "goal": {"milestone": milestone, "done": goal_done, "total": goal_total},
        "report": {"ready": len(merged) >= REPORT_AFTER, "merges": len(merged),
                   "citedBouncePct": round(100 * len(cited) / len(bounced)) if bounced else None,
                   "tokensPerMerge": round(tok / len(merged)) if merged else None,
                   "daysSinceDemo": days},
        "warnings": warnings,
    }


def _read_cfg(path):
    return json.loads(Path(path).read_text())


def health(a):
    cfg = _read_cfg(a.config)
    sc = Path(a.scorecard)
    h = compute_health(load_all(sc), cfg, a.wave, a.goal_done, a.goal_total)
    if h["breaches"]:
        # Step the ramp down one (floor 1). Never up: that is the owner's call.
        stage = int((cfg.get("ramp") or {}).get("stage", 1))
        to = max(1, stage - 1)
        if to != stage:
            cfg.setdefault("ramp", {})["stage"] = to
            Path(a.config).write_text(json.dumps(cfg, indent=2) + "\n")
        h["ramp"] = {"from": stage, "to": to}
    append(sc, [{"event": "health", "at": now_iso(), "wave": h["wave"], "action": h["action"],
                 "breaches": [b["metric"] for b in h["breaches"]]}])
    print(json.dumps(h, sort_keys=True))


def demo(a):
    if not a.accepted:
        print("demo: pass --accepted to record an accepted demo", file=sys.stderr)
        return 64
    append(Path(a.scorecard), [{"event": "demo", "accepted": True, "at": now_iso(), "note": a.note or ""}])
    print(json.dumps({"recorded": "demo"}))


def digest(a):
    cfg = _read_cfg(a.config)
    plan = json.loads(Path(a.plan).read_text()) if a.plan else {}
    all_rows = load_all(Path(a.scorecard))
    h = compute_health(all_rows, cfg, a.wave, a.goal_done, a.goal_total)
    # The action health already took this wave wins over a recomputation.
    last = next((r for r in reversed(all_rows) if r.get("event") == "health" and r.get("wave") == h["wave"]), None)
    action = last["action"] if last else h["action"]
    wave_rows = [r for r in all_rows if "event" not in r and r.get("wave") == h["wave"]]
    merges = sorted({r["card"] for r in wave_rows if r.get("column") == "Done"})
    asks = ["#{} {}".format(r["card"], r.get("detail") or r.get("finalStatus"))
            for r in wave_rows if r.get("finalStatus") in ("human-gate", "blocked") or r.get("column") == "Blocked"]
    asks += [str(x) for x in plan.get("asks", [])]
    if action == "stop-ask":
        asks.append("budget: keep going, raise goal.budget_usd, or stop?")
    if not (merges or h["breaches"] or asks) and cfg.get("digest") != "every-wave":
        return
    g, b, m = h["goal"], h["budget"], h["metrics"]
    lines = ["🎯 {} · {}/{} done".format(g["milestone"] or "no goal", g["done"], g["total"]),
             "Merged this wave: " + (", ".join("#%s" % c for c in merges) or "none"),
             "Health: " + action,
             "  round-capped     {}".format(", ".join("#%s" % c for c in m["roundCapped"]) or "none"),
             "  rounds/merge     {} (limit {})".format(m["roundsPerMerge"], ROUNDS_LIMIT),
             "  budget burn      {}% with {}% merged".format(m["budgetBurnPct"], m["goalMergedPct"]),
             "  failures today   {} (limit {})".format(m["failuresToday"], FAILURES_LIMIT)]
    r = h["report"]
    if r["ready"]:
        lines.append("  report only: cited bounces {}% · {}k tokens/merge · {} days since demo".format(
            r["citedBouncePct"], round((r["tokensPerMerge"] or 0) / 1000), r["daysSinceDemo"]))
    lines.append("Budget: ${} of {} (API-equivalent)".format(
        b["usd"], "$%s" % b["budget_usd"] if b["budget_usd"] else "no budget"))
    lines.append("Asks: " + ("; ".join(asks) if asks else "none"))
    for w in h["warnings"]:
        lines.append("⚠ " + w)
    print("\n".join(lines))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    r.add_argument("--results", required=True)
    r.add_argument("--logs")
    r.add_argument("--scorecard", required=True)
    r.add_argument("--wave", default="")
    r.add_argument("--milestone")
    r.add_argument("--citation", help="default citation for a card whose result has none")
    r.add_argument("--round-capped", action="store_true", help="mark every card round-capped")
    s = sub.add_parser("summary")
    s.add_argument("--scorecard", required=True)
    for name in ("health", "digest"):
        x = sub.add_parser(name)
        x.add_argument("--config", required=True)
        x.add_argument("--scorecard", default=DEFAULT_SC)
        x.add_argument("--wave")
        x.add_argument("--goal-done", type=int, help="closed issues on the goal milestone")
        x.add_argument("--goal-total", type=int, help="all issues on the goal milestone")
        if name == "digest":
            x.add_argument("--plan")
    d = sub.add_parser("demo")
    d.add_argument("--accepted", action="store_true")
    d.add_argument("--note")
    d.add_argument("--scorecard", default=DEFAULT_SC)
    a = p.parse_args()
    return {"record": record, "summary": summary, "health": health, "demo": demo, "digest": digest}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
