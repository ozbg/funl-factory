# zones.yaml draft

The draft `docs/agents/zones.yaml` that `/to-board` writes when the app has none. The owner
signs it; until then it says `DRAFT, not signed` on top. `super-board-zone.py` reads this
shape (mappings, lists, `>` folded text, inline `[a, b]` lists, comments). A file not
listed counts as amber.

```yaml
# <app> zone map — DRAFT, not signed
#
# Which parts of the app are dangerous, what must always hold there, and how hard each
# card is checked. Card tier = the highest zone of any file it touches.
# Sign it: comment `signed zones` on the zone-map issue, then remove the DRAFT line.

app_class: <personal-tool | small-team | customer-facing>
stage: mvp

zones:

  red:
    purpose: >
      What can lose data, leak it, take money or let the wrong person in. Kept small.
    paths:
      - <the one write path, the schema and migrations, auth, payments, anything that sends>
    invariants:   # the must-nevers, same ids as docs/shape/spec.md § Invariants
      - id: I1
        rule: <rule>
      - id: I2
        rule: <rule>
    checks: [typecheck, tests, invariant-suite, scenario-run, security-pass, adversarial-review]
    max_rounds: 3
    owner_gate: [destructive-schema, live-database]

  amber:
    purpose: >
      Features. They change data only through the red write path.
    paths:
      - <routes, actions, feature modules>
    bar: >
      The card's scenario works in the real app. Errors say what happened in one line.
      Empty, error and loading states exist.
    checks: [typecheck, tests, invariant-suite, scenario-run, review]
    max_rounds: 2

  green:
    purpose: >
      Looking, not changing. Screens, read-only views, copy.
    paths:
      - <components, pages, docs/**>
    bar: Looks right, works on the happy path, no console errors.
    checks: [typecheck, tests, invariant-suite, review-light]
    max_rounds: 1

accepted_limits:
  - <things nobody bounces a card for, from the volumes and later.md>
```

Rules:
- Every must-never in the north star is a red invariant. Nothing else is.
- Paths are the exact files and globs the cards list. A card's Files line must resolve to one zone.
- Keep red small: only what the invariants guard. Most cards should land in amber or green.
