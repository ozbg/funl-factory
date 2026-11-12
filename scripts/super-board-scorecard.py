#!/usr/bin/env python3
"""Scorecard and health for the factory (factory #25, v2 T9).

record  — after each wave, append one JSON line per card to the board's scorecard,
          with tokens (split), API-equivalent dollars and minutes from the agent logs.
summary — one line per build model across every recorded wave.
health  — four acting metrics; a breach steps ramp.stage down one and pauses or asks.
          Never halts. Prints {breaches, action, ...} and appends a health event row.
demo    — record that the owner accepted a demo (an event row).
exam    — record one AI exam score on the real model (an event row; the latest per card counts).
screen  — record one QA screen match, passed or failed (an event row; the latest per card counts).
walk    — record the milestone-end agent walk (screens and day-one questions passed), or
          --accepted when the owner accepts its findings. Needs a screenshot per screen.
merged  — record a merge made outside the lane (owner or orchestrator), so report and
          health count the card as merged.
digest  — short plain-text owner digest; prints only on a merge, breach or ask
          (every wave when the config's `digest` is "every-wave").

  super-board-scorecard.py record --results <wave-cards.json> --logs <dir> \
      --scorecard docs/super-board/runs/scorecard.jsonl [--wave <label>] [--milestone <title>]
  super-board-scorecard.py summary --scorecard docs/super-board/runs/scorecard.jsonl
  super-board-scorecard.py health --config <cfg> [--wave <label>] [--goal-done N --goal-total N]
  super-board-scorecard.py demo --accepted
  super-board-scorecard.py merged --card N --sha <merge sha> --by owner|orchestrator [--milestone M1]
  super-board-scorecard.py exam --card N --score 9 --total 10 --pass-mark 8 --model <model id> [--milestone M1]
  super-board-scorecard.py screen --card N --screen screen-<name> --passed|--failed [--milestone M1]
  super-board-scorecard.py walk --screens N --passed N --questions N --answered N \
      --shots docs/super-board/runs/<date>-walk/ [--findings <file>] [--model <id>] [--milestone M1]
  super-board-scorecard.py walk --accepted --note "<why>" [--milestone M1]
  super-board-scorecard.py digest --config <cfg> --plan <plan.json> [--wave <label>]
  super-board-scorecard.py report --config <cfg> [--repo-path <app>] [--log] [--compare] [--json]
                                  [--board-json <file>]

report  — one page per milestone against targets (config `targets`, else defaults);
          --log appends one line to <repo>/docs/super-board/factory-log.jsonl, --compare
          prints that log as a table. A missing input prints n/a, never a crash.

--results is the wave's `cards` array (or the whole {cards, halted} result).
--logs is the folder holding the wave's agent-*.jsonl logs (searched recursively).
An agent already counted in an earlier row is never counted twice.
"""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
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


def card_rounds(rs):
    """Review rounds that found rework on one card's rows.

    A review after a pass (verdict clean or fixes, no blockers) only re-checks an
    approved, unchanged head, for example after a human gate. It is not a round.
    """
    scored = [r["score"] for r in rs if r.get("score")]
    top = max([s.get("round", 1) for s in scored] or [1])
    approvals = sum(1 for prev, cur in zip(scored, scored[1:])
                    if prev.get("verdict") != "rework" and not prev.get("blockers")
                    and cur.get("round", 1) > prev.get("round", 1))
    return max(1, top - approvals)


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
        rounds = [card_rounds(rs) for rs in merged]
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
ROUNDS_MIN_MERGES = 3     # rounds per merge only acts once this many cards merged
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
    rounds = [card_rounds(by_card[c]) for c in window]
    rpm = round(sum(rounds) / len(rounds), 2) if rounds else 0
    capped = sorted({r["card"] for r in this_wave if r.get("roundCapped")})
    failures = sum(1 for r in rows if str(r.get("at", "")).startswith(today)
                   for x in _lane_exits(r) if x in ("failed", "halted"))
    burn = round(100 * spent / budget) if budget else 0
    done_pct = round(100 * goal_done / goal_total) if goal_total else 0

    breaches = []
    if capped:
        breaches.append({"metric": "round-capped", "detail": "cards hit the round cap: " + ", ".join("#%s" % c for c in capped)})
    if rpm > ROUNDS_LIMIT and len(window) >= ROUNDS_MIN_MERGES:
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


def merged(a):
    """A merge made outside the lane: the card's rows still say Review, so add a Done row."""
    sc = Path(a.scorecard)
    mine = [r for r in load_rows(sc) if r.get("card") == a.card]
    milestone = a.milestone or next((r.get("milestone") for r in reversed(mine) if r.get("milestone")), None)
    append(sc, [{"card": a.card, "column": "Done", "finalStatus": "merged", "lanesRun": "merged:" + a.by,
                 "mergedBy": a.by, "sha": a.sha, "milestone": milestone, "wave": a.wave or "outside-lane",
                 "at": now_iso(), "tokens": 0, "usd": 0, "minutes": 0, "agents": []}])
    print(json.dumps({"recorded": "merged", "card": a.card, "by": a.by}))


def demo(a):
    if not a.accepted:
        print("demo: pass --accepted to record an accepted demo", file=sys.stderr)
        return 64
    append(Path(a.scorecard), [{"event": "demo", "accepted": True, "at": now_iso(), "note": a.note or ""}])
    print(json.dumps({"recorded": "demo"}))


FAKE_MODEL = re.compile(r"\b(fake|mock|stub|dummy)\b", re.I)


def exam(a):
    if FAKE_MODEL.search(a.model or "") or not (a.model or "").strip():
        print("exam: needs the real model, got {!r}".format(a.model), file=sys.stderr)
        return 64
    if a.total < 1 or not (0 <= a.score <= a.total) or not (0 < a.pass_mark <= a.total):
        print("exam: want 0 <= score <= total and 0 < pass mark <= total", file=sys.stderr)
        return 64
    row = {"event": "exam", "card": a.card, "score": a.score, "total": a.total, "pass_mark": a.pass_mark,
           "model": a.model, "at": now_iso()}
    if a.milestone:
        row["milestone"] = a.milestone
    append(Path(a.scorecard), [row])
    print(json.dumps({"recorded": "exam", "card": a.card, "passed": a.score >= a.pass_mark}))


def screen(a):
    if a.passed == a.failed:
        print("screen: pass exactly one of --passed or --failed", file=sys.stderr)
        return 64
    if not re.match(r"^screen-[A-Za-z0-9_-]+$", a.screen or ""):
        print("screen: --screen must be screen-<name>, got {!r}".format(a.screen), file=sys.stderr)
        return 64
    row = {"event": "screen", "card": a.card, "screen": a.screen, "passed": bool(a.passed), "at": now_iso()}
    if a.milestone:
        row["milestone"] = a.milestone
    append(Path(a.scorecard), [row])
    print(json.dumps({"recorded": "screen", "card": a.card, "passed": bool(a.passed)}))


def walk(a):
    if a.accepted:
        if not (a.note or "").strip():
            print("walk: --accepted needs --note saying why the owner accepts the findings", file=sys.stderr)
            return 64
        row = {"event": "walk-accept", "at": now_iso(), "note": a.note}
        if a.milestone:
            row["milestone"] = a.milestone
        append(Path(a.scorecard), [row])
        print(json.dumps({"recorded": "walk-accept"}))
        return 0
    n = {k: getattr(a, k) for k in ("screens", "passed", "questions", "answered")}
    if any(v is None for v in n.values()):
        print("walk: needs --screens, --passed, --questions and --answered", file=sys.stderr)
        return 64
    if n["screens"] < 1 or not (0 <= n["passed"] <= n["screens"]) or not (0 <= n["answered"] <= n["questions"]):
        print("walk: want screens >= 1, 0 <= passed <= screens, 0 <= answered <= questions", file=sys.stderr)
        return 64
    shots = Path(a.shots) if a.shots else None
    pngs = sorted(shots.glob("*.png")) if shots and shots.is_dir() else []
    if len(pngs) < n["screens"]:
        print("walk: {} has {} screenshots for {} screens; save one per screen first".format(
            a.shots, len(pngs), n["screens"]), file=sys.stderr)
        return 64
    ok = n["passed"] == n["screens"] and n["answered"] == n["questions"]
    if not ok and not (a.findings and Path(a.findings).is_file()):
        print("walk: a failed screen or question needs --findings <file> listing each one", file=sys.stderr)
        return 64
    row = dict(n, event="walk", at=now_iso(), shots=str(a.shots), findings=a.findings, model=a.model, ok=ok)
    if a.milestone:
        row["milestone"] = a.milestone
    append(Path(a.scorecard), [row])
    print(json.dumps({"recorded": "walk", "passed": ok}))


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


# ── report (factory #63) ────────────────────────────────────────────────────
LOG_PATH = "docs/super-board/factory-log.jsonl"
DEFAULT_TARGETS = {"days_per_app": 2, "first_pass_pct": 70, "rework_pct": 10,
                   "rounds_per_merge": 1.5, "demo_first_try": True, "exam_pass": True,
                   "screens_match": 100, "walk_pass": 100}
NA = "n/a"


def _jsonl(path):
    out = []
    try:
        for raw in Path(path).read_text().splitlines():
            try:
                out.append(json.loads(raw))
            except ValueError:
                continue
    except OSError:
        pass
    return out


def _read_text(path):
    try:
        return Path(path).read_text()
    except OSError:
        return None


def _num(v, suffix=""):
    return NA if v is None else "{}{}".format(v, suffix)


def _coverage(repo, rows, board_json, milestone=None, scorecard=None):
    """Coverage summary dict from super-board-coverage.py, or None when it can't run."""
    script = Path(__file__).resolve().with_name("super-board-coverage.py")
    if not script.exists():
        script = Path(repo) / ".claude" / "bin" / "super-board-coverage.py"
    if not script.exists() or not (Path(repo) / "docs/shape/coverage.md").exists():
        return None
    tmp = None
    try:
        if not board_json:
            done = {r["card"] for r in rows if r.get("column") == "Done"}
            tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
            json.dump([{"number": n, "status": "Done"} for n in sorted(done)], tmp)
            tmp.close()
            board_json = tmp.name
        cmd = [sys.executable, str(script), "status", "--repo-path", str(repo), "--board-json", str(board_json), "--json"]
        if milestone:
            cmd += ["--milestone", milestone]
        if scorecard:
            cmd += ["--scorecard", str(scorecard)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None
    except (OSError, ValueError):
        return None
    finally:
        if tmp:
            Path(tmp.name).unlink(missing_ok=True)


def _board_counts(board_json, milestone=None):
    """(done, total) from a [{number, status[, milestone]}] board file, or (None, None)."""
    if not board_json:
        return None, None
    try:
        items = json.loads(Path(board_json).read_text())
        items = [i for i in items if not milestone or i.get("milestone") in (None, milestone)]
        done = sum(1 for i in items if str(i.get("status", "")).lower() == "done")
        return done, len(items)
    except (OSError, ValueError, TypeError, AttributeError):
        return None, None


def compute_report(cfg, rows, repo, goal_done=None, goal_total=None, board_json=None, today=None, scorecard=None):
    goal = cfg.get("goal") or {}
    milestone = goal.get("milestone")
    budget = goal.get("budget_usd")
    targets = dict(DEFAULT_TARGETS)
    targets.update(cfg.get("targets") or {})
    exams, screens = {}, {}
    walk_row, walk_accepted = None, False
    for r in rows:
        if milestone and r.get("milestone") not in (None, milestone):
            continue
        ev = r.get("event")
        if ev == "exam" and r.get("card") is not None:
            exams[r["card"]] = r  # the latest run per card counts
        elif ev == "screen" and r.get("card") is not None:
            screens[r["card"]] = bool(r.get("passed"))  # the latest match per card counts
        elif ev == "walk":
            walk_row, walk_accepted = r, False  # the latest walk counts
        elif ev == "walk-accept" and walk_row is not None:
            walk_accepted = True
    exams = [{"card": c, "score": r.get("score"), "total": r.get("total"), "pass_mark": r.get("pass_mark"),
              "model": r.get("model"), "passed": (r.get("score") or 0) >= (r.get("pass_mark") or 0)}
             for c, r in sorted(exams.items())]
    rows = [r for r in rows if "event" not in r and r.get("card") is not None
            and (not milestone or r.get("milestone") in (None, milestone))]
    sm = {"passed": sum(screens.values()), "total": len(screens),
          "pct": round(100 * sum(screens.values()) / len(screens)) if screens else None}
    walk = None
    if walk_row:
        asked = walk_row.get("screens", 0) + walk_row.get("questions", 0)
        good = walk_row.get("passed", 0) + walk_row.get("answered", 0)
        walk = {k: walk_row.get(k) for k in ("screens", "passed", "questions", "answered", "findings", "shots")}
        walk.update(pct=round(100 * good / asked) if asked else None, accepted=walk_accepted)
    by_card = {}
    for r in rows:
        by_card.setdefault(r["card"], []).append(r)
    merged = _merged_cards(rows)
    n = len(merged)
    board_done, board_total = _board_counts(board_json, milestone)
    if goal_total is None:
        goal_total = board_total
    if goal_done is None:
        goal_done = board_done
    total = goal_total if goal_total is not None else (len(by_card) or None)
    done = goal_done if goal_done is not None else (n if rows else None)
    merged_rows = [r for c in merged for r in by_card[c]]
    scores = [r["score"] for r in rows if r.get("score")]

    # Define: north-star log (latest line) and the Mock-up line.
    ns = _jsonl(Path(repo) / "docs/shape/north-star-log.jsonl")
    last = ns[-1] if ns else {}
    ntext = _read_text(Path(repo) / "docs/shape/north-star.md")
    mockup, postcard = None, None
    if ntext is not None:
        m = re.search(r"^Mock-up:\s*(.*)$", ntext, re.M)
        mockup = bool(m)
        postcard = bool(m and re.search(r"postcard:\s*yes", m.group(1), re.I))
    define = {"minutes": last.get("minutes"), "questions": last.get("questions"),
              "blind_match": last.get("blind_match"), "mockup_signed": mockup}

    # Build
    days = None
    starts = []
    for r in rows:
        t = _ts(r.get("at"))
        if t:
            starts.append((t - timedelta(minutes=r.get("minutes") or 0), t, r))
    ends = [t for _, t, r in starts if r.get("column") == "Done"]
    if starts and ends:
        days = round((max(ends) - min(s for s, _, _ in starts)).total_seconds() / 86400, 1)
    fp = rw = rpm = tok = mins = None
    if n:
        first = [c for c in merged if not any("bounced" in (r.get("lanesRun") or "") for r in by_card[c])]
        fp = round(100 * len(first) / n)
        rounds = [card_rounds(by_card[c]) for c in merged]
        rpm = round(sum(rounds) / n, 2)
        tok = round(sum(r.get("tokens", 0) for r in merged_rows) / n / 1000)
        mins = round(sum(r.get("minutes", 0) for r in merged_rows) / n)
    if scores:
        rw = round(100 * sum(1 for s in scores if s.get("verdict") == "rework") / len(scores))
    causes = {}
    for s in scores:
        if s.get("verdict") in ("fixes", "rework") and s.get("cause") in ("build", "ticket"):
            causes[s["cause"]] = causes.get(s["cause"], 0) + 1
    rules = {}
    for r in merged_rows:
        mr = r.get("modelRules")
        if isinstance(mr, dict):
            for k, v in mr.items():
                rules[k] = rules.get(k, 0) + (v if isinstance(v, int) else 1)
        elif isinstance(mr, str):
            rules[mr] = rules.get(mr, 0) + 1
        elif isinstance(mr, list):
            for k in mr:
                rules[str(k)] = rules.get(str(k), 0) + 1

    spent = round(sum(r.get("usd") or 0 for r in rows), 2) if rows else None

    # Done: coverage and demo
    cov = _coverage(repo, rows, board_json, milestone, scorecard)
    demo_done = cov.get("demo_done") if cov else None
    demo_first = None
    if cov is not None:
        dc = by_card.get(cov.get("demo"), [])
        late = any((r.get("score") or {}).get("round", 1) > 1 for r in dc)
        demo_first = bool(demo_done and not late)

    checks = [("days_per_app", "days", days, lambda v, t: v <= t, "≤"),
              ("first_pass_pct", "first pass", fp, lambda v, t: v >= t, "≥"),
              ("rework_pct", "rework", rw, lambda v, t: v <= t, "≤"),
              ("rounds_per_merge", "rounds per merge", rpm, lambda v, t: v <= t, "≤")]
    met = {}
    for key, _, val, ok, _ in checks:
        met[key] = None if val is None else bool(ok(val, targets[key]))
    met["demo_first_try"] = None if demo_first is None else (demo_first or not targets["demo_first_try"])
    met["exam_pass"] = None if not exams else (all(e["passed"] for e in exams) or not targets["exam_pass"])
    met["screens_match"] = None if sm["pct"] is None else sm["pct"] >= targets["screens_match"]
    met["walk_pass"] = None if not walk or walk["pct"] is None else walk["pct"] >= targets["walk_pass"]
    return {"milestone": milestone, "targets": targets, "targets_met": met, "define": define,
            "build": {"days": days, "merged": done, "total": total, "first_pass_pct": fp, "rework_pct": rw,
                      "rounds_per_merge": rpm, "k_tokens_per_card": tok, "min_per_card": mins,
                      "model_rules": rules or None, "causes": causes},
            "cost": {"usd": spent, "budget_usd": budget},
            "done": {"coverage": cov, "demo_passed": demo_done, "demo_first_try": demo_first},
            "exams": exams, "screens_match": sm, "walk": walk,
            "mockup_cuts": cov.get("mockup_cuts") if cov else None,
            "postcard": postcard, "_checks": checks}


def render_report(app, rep):
    d, b, c, dn, t, met = rep["define"], rep["build"], rep["cost"], rep["done"], rep["targets"], rep["targets_met"]
    mark = lambda k: NA if met[k] is None else ("✅" if met[k] else "❌")
    yn = lambda v: NA if v is None else ("yes" if v else "no")
    out = ["{} {}".format(app, rep["milestone"] or "")]
    out.append("Define: north star {} min · {} questions · blind match {} · mock-up signed {}".format(
        _num(d["minutes"]), _num(d["questions"]), _num(d["blind_match"], "/5"), yn(d["mockup_signed"])))
    rules = ", ".join("{} ×{}".format(k, v) for k, v in sorted(b["model_rules"].items())) if b["model_rules"] else NA
    out.append("Build: {} days · {}/{} merged · first pass {} · rework {} · {} rounds per merge · {}k tokens/card · {} min/card · models by rule {}".format(
        _num(b["days"]), _num(b["merged"]), _num(b["total"]), _num(b["first_pass_pct"], "%"), _num(b["rework_pct"], "%"),
        _num(b["rounds_per_merge"]), _num(b["k_tokens_per_card"]), _num(b["min_per_card"]), rules))
    out.append("Cost: {} of {} (API-equivalent)".format(
        NA if c["usd"] is None else "${}".format(c["usd"]), NA if c["budget_usd"] is None else "${}".format(c["budget_usd"])))
    cov = dn["coverage"]
    if cov:
        per = " · ".join("must-have {} {}/{}".format(m["must_have"], m["done"], m["total"]) for m in cov["must_haves"])
        out.append("Done: {} · demo {} · milestone {}".format(
            per or NA, "passed" if dn["demo_passed"] else "not passed",
            "done" if cov.get("milestone_done") else "not done: " + (
                cov.get("walk_detail") if dn["demo_passed"] and cov.get("cards_done") == cov.get("cards_total")
                else "cards still open")))
    else:
        out.append("Done: {} · demo {}".format(NA, NA))
    ex = rep["exams"]
    out.append("AI exams: {}".format(" · ".join("#{} {}/{} (pass {}) {}".format(
        e["card"], e["score"], e["total"], e["pass_mark"], e["model"]) for e in ex) if ex else NA))
    for key, label, val, _, op in rep["_checks"]:
        unit = "%" if key.endswith("pct") else ""
        out.append("{} {}: {} vs {} {}{}".format(mark(key), label, _num(val, unit if val is not None else ""), op, t[key], unit))
    out.append("{} demo first try: {} vs {}".format(mark("demo_first_try"), yn(dn["demo_first_try"]), yn(t["demo_first_try"])))
    out.append("{} exams at pass mark: {} vs {}".format(mark("exam_pass"), "{}/{}".format(
        sum(1 for e in ex if e["passed"]), len(ex)) if ex else NA, "all" if t["exam_pass"] else "any"))
    sm, w = rep["screens_match"], rep["walk"]
    out.append("{} screens match: {} vs ≥ {}%".format(mark("screens_match"), "{}/{} ({}%)".format(
        sm["passed"], sm["total"], sm["pct"]) if sm["total"] else NA, t["screens_match"]))
    wtxt = NA
    if w:
        wtxt = "{}% · screens {}/{} · questions {}/{}{}".format(
            _num(w["pct"]), w["passed"], w["screens"], w["answered"], w["questions"],
            " · findings accepted" if w["accepted"] else "")
    out.append("{} walk pass: {} vs ≥ {}%".format(mark("walk_pass"), wtxt, t["walk_pass"]))
    out.append("ℹ mock-up cuts: {} (no target)".format(_num(rep["mockup_cuts"])))
    out.append("Next:")
    nxt = _next_steps(rep)
    out.extend("  " + x for x in nxt)
    return "\n".join(out)


def _next_steps(rep):
    met, b, c = rep["targets_met"], rep["build"], rep["cost"]
    ca = b.get("causes") or {}
    steps = []
    if met["first_pass_pct"] is False:
        steps.append("sharpen tickets: most bounces cite ticket" if ca.get("ticket", 0) > ca.get("build", 0)
                     else "tighten build: most bounces cite build, add tests or a smaller card size"
                     if ca else "sharpen tickets: read the bounced cards and fix what they share")
    if met["rework_pct"] is False:
        steps.append("shrink cards: rework means the card was too big or unclear")
    if met["rounds_per_merge"] is False:
        steps.append("write tighter AC: extra rounds mean the check was not clear up front")
    if met["demo_first_try"] is False:
        steps.append("run the demo card earlier and check it against the postcard")
    if met["exam_pass"] is False:
        steps.append("fix the spec, not the prompt: a failed exam means thin context or a rule that cripples the AI")
    if met["walk_pass"] is False:
        steps.append("work the walk's findings: each is a Backlog card; the milestone isn't done until they pass or you accept them")
    elif rep.get("walk") is None and rep["done"]["demo_passed"]:
        steps.append("run the agent walk: the demo is Done, and the milestone isn't done until the walk passes")
    if met["screens_match"] is False:
        steps.append("match the mock-up: give each screen card its mock-up block, and fail QA on every unlisted difference")
    if met["days_per_app"] is False:
        steps.append("cut the must-haves or split the milestone: the app ran over its days")
    if c["usd"] is not None and c["budget_usd"] and c["usd"] > c["budget_usd"]:
        steps.append("over budget: cheaper models on low-complexity cards")
    return steps[:3] or ["all targets met or n/a: keep going"]


def _log_line(app, rep, today):
    b, c = rep["build"], rep["cost"]
    return {"date": today, "app": app, "milestone": rep["milestone"], "days": b["days"], "merged": b["merged"],
            "total": b["total"], "first_pass_pct": b["first_pass_pct"], "rework_pct": b["rework_pct"],
            "rounds_per_merge": b["rounds_per_merge"], "usd": c["usd"], "budget_usd": c["budget_usd"],
            "demo_passed": rep["done"]["demo_passed"], "postcard": rep["postcard"], "targets_met": rep["targets_met"],
            "exams": [{k: e[k] for k in ("card", "score", "total", "pass_mark")} for e in rep["exams"]] or None,
            "screens_match_pct": rep["screens_match"]["pct"],
            "walk_pass_pct": rep["walk"]["pct"] if rep["walk"] else None, "mockup_cuts": rep["mockup_cuts"]}


def compare(repo):
    entries = _jsonl(Path(repo) / LOG_PATH)
    if not entries:
        print("{}: no factory log yet".format(NA))
        return
    head = ["date", "app", "milestone", "days", "merged", "first pass", "rework", "rounds", "usd", "demo", "postcard", "targets"]
    table = [head]
    for e in entries:
        met = [v for v in (e.get("targets_met") or {}).values() if v is not None]
        tm = "{}/{}".format(sum(1 for v in met if v), len(met)) if met else NA
        yn = lambda v: NA if v is None else ("yes" if v else "no")
        spend = NA if e.get("usd") is None else "${}{}".format(e["usd"], "/${}".format(e["budget_usd"]) if e.get("budget_usd") else "")
        table.append([str(x) for x in (e.get("date") or NA, e.get("app") or NA, e.get("milestone") or NA, _num(e.get("days")),
                      "{}/{}".format(_num(e.get("merged")), _num(e.get("total"))), _num(e.get("first_pass_pct"), "%"),
                      _num(e.get("rework_pct"), "%"), _num(e.get("rounds_per_merge")), spend,
                      yn(e.get("demo_passed")), yn(e.get("postcard")), tm)])
    w = [max(len(r[i]) for r in table) for i in range(len(head))]
    for r in table:
        print("  ".join(x.ljust(w[i]) for i, x in enumerate(r)).rstrip())


def report(a):
    repo = Path(a.repo_path).resolve()
    if a.compare:
        compare(repo)
        return 0
    if not a.config:
        print("report: --config is required", file=sys.stderr)
        return 64
    try:
        cfg = _read_cfg(a.config)
    except (OSError, ValueError) as e:
        print("report: cannot read config: {}".format(e), file=sys.stderr)
        return 64
    sc = Path(a.scorecard) if a.scorecard else repo / DEFAULT_SC
    try:
        rows = load_all(sc)
    except ValueError:
        rows = []
    rep = compute_report(cfg, rows, repo, a.goal_done, a.goal_total, a.board_json, scorecard=sc)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    if a.log:
        line = _log_line(repo.name, rep, today)
        path = repo / LOG_PATH
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as f:
            f.write(json.dumps(line, sort_keys=True) + "\n")
    if a.json:
        out = {k: v for k, v in rep.items() if not k.startswith("_")}
        out["app"] = repo.name
        print(json.dumps(out, sort_keys=True))
    else:
        print(render_report(repo.name, rep))
    return 0


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
    x = sub.add_parser("report")
    x.add_argument("--config")
    x.add_argument("--repo-path", default=".")
    x.add_argument("--scorecard", help="default <repo>/" + DEFAULT_SC)
    x.add_argument("--board-json", help="[{number,status}]: merged count and coverage; default: Done cards in the scorecard")
    x.add_argument("--goal-done", type=int)
    x.add_argument("--goal-total", type=int)
    x.add_argument("--log", action="store_true", help="append one line to " + LOG_PATH)
    x.add_argument("--compare", action="store_true", help="print the factory log as a table")
    x.add_argument("--json", action="store_true")
    m = sub.add_parser("merged")
    m.add_argument("--card", type=int, required=True)
    m.add_argument("--sha", required=True, help="the merge commit sha")
    m.add_argument("--by", required=True, choices=["owner", "orchestrator"])
    m.add_argument("--milestone", help="default: the card's last recorded milestone")
    m.add_argument("--wave", help="default: outside-lane")
    m.add_argument("--scorecard", default=DEFAULT_SC)
    d = sub.add_parser("demo")
    d.add_argument("--accepted", action="store_true")
    d.add_argument("--note")
    d.add_argument("--scorecard", default=DEFAULT_SC)
    e = sub.add_parser("exam")
    e.add_argument("--card", type=int, required=True)
    e.add_argument("--score", type=int, required=True, help="questions passed")
    e.add_argument("--total", type=int, required=True, help="questions asked")
    e.add_argument("--pass-mark", type=int, required=True, help="questions needed to pass, from the card")
    e.add_argument("--model", required=True, help="the real model id the exam ran on")
    e.add_argument("--milestone")
    e.add_argument("--scorecard", default=DEFAULT_SC)
    sc = sub.add_parser("screen")
    sc.add_argument("--card", type=int, required=True)
    sc.add_argument("--screen", required=True, help="the mock-up anchor, screen-<name>")
    sc.add_argument("--passed", action="store_true")
    sc.add_argument("--failed", action="store_true")
    sc.add_argument("--milestone")
    sc.add_argument("--scorecard", default=DEFAULT_SC)
    w = sub.add_parser("walk")
    w.add_argument("--screens", type=int, help="screens walked")
    w.add_argument("--passed", type=int, help="screens that passed")
    w.add_argument("--questions", type=int, help="day-one questions asked")
    w.add_argument("--answered", type=int, help="day-one questions answered well")
    w.add_argument("--shots", help="the run folder holding one screenshot per screen")
    w.add_argument("--findings", help="the walk's findings file; required when anything failed")
    w.add_argument("--model", help="the model the walk ran on")
    w.add_argument("--accepted", action="store_true", help="the owner accepts the latest walk's findings")
    w.add_argument("--note")
    w.add_argument("--milestone")
    w.add_argument("--scorecard", default=DEFAULT_SC)
    a = p.parse_args()
    return {"record": record, "summary": summary, "health": health, "demo": demo, "merged": merged, "digest": digest, "report": report,
            "exam": exam, "screen": screen, "walk": walk}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
