# Blind review

Run after "Check before showing", before the owner sees the table. Cost: a few cents.

## 1. Blind reviewer

One fresh sub-agent, fresh context, like the north-star blind test. Give it ONLY:

- `docs/shape/north-star.md`
- the mock-up screen index (`grep -o 'id="screen-[a-z0-9-]*"' docs/shape/mockup.html`), if a mock-up exists
- the card list: for each card the title, Must-have served, Zone, ACs and Fix

Never give it `spec.md` or your drafting reasoning. It must judge the cards alone.

Prompt: "You have the north star and a list of build cards. Could a team that builds exactly these cards ship the postcard? Return four things. `missing`: every must-have or core-loop step with no card. `unguarded`: every must-never with no invariant or no test AC. `extra`: every card that traces to no must-have. `verdict: builds the postcard: yes | gaps`."

## 2. Haiku read-through

One sub-agent per card, all in parallel, model haiku. Give each ONLY the card, the current contents of the files it lists (those that exist) and spec.md's Contracts section.

Prompt: "List every question you would need answered before building this card. If none, answer exactly: none."

Any answer other than `none` fails the card. Count cards that answered `none` for the `Haiku read: n/N clear` figure.

## 3. One fix round

Fix every finding: decide it in spec.md, split the card, add a card or cut a card. Cutting or adding scope is the owner's call: list it as a flagged line in the review, never decide it silently. Re-run the Haiku read only on changed or new cards. Do not run a second round. Findings still open are shown under the table.

## Owner table lines

Above the table: `Verdict: builds the postcard: yes · Haiku read: 14/14 clear` (or `gaps`, and the real count). Below it, one line per open finding and per flagged scope change.
