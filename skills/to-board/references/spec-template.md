# spec.md template

One page. If it runs past about 80 lines, something in it belongs on a card or in `later.md`.

```markdown
# <App name>: spec

> <the postcard, copied from north-star.md>

From: docs/shape/north-star.md (signed <date>) · mock-up: docs/shape/mockup.html | none · written: <date>

## Must have
1. <must, same number and words as the north star>
2. <must>

## Invariants
Each must-never, as a rule a test can prove. Same ids in docs/agents/zones.yaml.
- I1: <rule, e.g. "A failed save leaves the record exactly as it was.">
- I2: <rule>

## Volumes
- Users: <n> · records: <n per month> · busiest moment: <what, how many>
- <assumed> marks anything the north star didn't say.

## Decisions
One-way calls, one line each, with the reason.
- Stack: <framework, language, database, host> - <why>
- Data: <where it lives, backups> - <why>
- Auth: <none | who signs in, how> - <why>
- Tests: `<test command>` · end to end: `<e2e command>` - seam: <the one seam>
- <any question a card would otherwise leave open>: <the answer>

## Data model
| Entity | Fields | Written by |
|---|---|---|
| <Entity> | id, <field>: <type>, … | <the one module or route that writes it> |

## Contracts
The shapes where two cards meet. Cards name these, never re-invent them.
- `<ContractName>`: `<path>` · `{ field: type, … }` · made by card <foundation | slice name> · used by <slice names>
```

Rules:
- No user stories, no screen list, no edge-case catalogue. The cards and the mock-up hold those.
- Decisions are yours. Mark a decision `assumed` when the north star didn't fix it and it is cheap to change later.
- A contract is a type, a route or a table: the exact name and fields. Write it once here; the foundation card makes it real.
