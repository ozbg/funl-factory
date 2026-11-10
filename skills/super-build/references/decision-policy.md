# Decision policy for super-board workers

Workers run unattended. When the issue forces a judgment call it does not settle,
the worker walks the **decision ladder**, records the choice in the commit, and
never blocks on the user. `grilling`, `shape` and `clarify` need a human, so they
live in `super-board lint`, never in a worker. Wanting one is a human gate (below).

## Skill map

Tier comes from `super-board-zone.py --zones <config zones> --files <paths the card touches>`.
An unplaced file counts as amber. The card's tier is the highest of its files.

| Tier | Test depth | Extra |
| --- | --- | --- |
| green | one test per AC at the cheapest layer; no edge-case sweep | — |
| amber | every AC proven by a test | — |
| red | every AC, plus the zone's `invariants` and listed edge cases | `code-review` self-pass on your diff (merge-base as fixed point) |

Always: `mattpocock-skills:tdd` (skip for docs-only), `ponytail:ponytail` before code,
`verification-before-completion` before the final commit. `bug` cards add
`mattpocock-skills:diagnosing-bugs` first. An explicit `Skills:` line in the issue
replaces the label pick. `vitest` / `playwright-best-practices` follow the layer.

Test gates: walk down and stop at the first layer that reproduces (call the module →
unit; real collaborators → integration; browser → e2e; live third party → not a test,
file a mock gap). A test counts only if it goes **red for the right reason** on the
unfixed code and **survives a refactor** that keeps behaviour.

## Simplest solution first

Fallback when `ponytail:ponytail` is not installed:

1. Stop at the first rung that holds: not needed at all → already in the codebase →
   stdlib → platform → installed dependency → one line → only then minimum code.
2. No dependency, abstraction, config or file the AC does not need.
3. Bug fix = root cause: one guard in the shared function beats one per caller.
4. Never cut validation, security, data-loss protection or accessibility to shrink a diff.

## Verify before done

Fallback when `verification-before-completion` is not installed:

1. Run the check that proves the claim, fresh, in this worktree: the new test, then the
   full suite and `verify_commands`. Never reuse earlier output.
2. Read the output, not just the exit code. Tick an AC only when a run shows it.
3. Report what you ran and what it printed. Never write "should work".

## Testing strategy

Fallback when `testing-strategy` is not installed: the zone table above sets depth;
test where the defect lives; skip framework behaviour, generated code and pass-through glue.

## The decision ladder

Stop at the first rung that answers the question.

```
  1  acceptance criteria    the issue body says which behaviour is correct
  2  repo precedent         an existing pattern in this codebase already does this
  3  smallest blast radius  least irreversible, fewest files, revertable in one commit
  4  human gate             the fork is not yours to make → stop
```

A rung-3 fork that adds an ownership boundary, a public interface or architecture
expensive to reverse follows [design preflight](../../super-board/references/design-preflight.md).

## Recording the decision

A rung-3 choice goes in the commit under a `--- decision ---` trailer, after the bullets.
Rungs 1 and 2 need none.

```
🐛 [fix] orders: use the idempotency key from the request header

- duplicate POST returns the first order (orders.test.ts:41)
Closes #123

--- decision ---
question: reuse the request header key, or mint a server-side key per order?
chose: request header — the client already retries with a stable key
rung: 3 (blast radius — no schema change, revertable in one commit)
```

## Hard human gates

Print `HUMAN GATE TRIPPED: <reason>`, label `human-gated`, keep the worktree, stop, when:

- **Money:** billing, payments, pricing — unless the issue explicitly authorises it.
- **Auth:** auth, secrets, permissions, data across a trust boundary — unless authorised.
- **Destructive schema:** DROP / TRUNCATE / RENAME, or any destructive DB change.
- **Live DB:** a migration on the live database, or a production deploy.
- The issue is unclear about what "fixed" means, or the fix breaks a public contract.

Salvageable work blocked by a gate → `WIP-PARTIAL`, not a halt.
