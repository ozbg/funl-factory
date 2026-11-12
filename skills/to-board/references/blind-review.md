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

One sub-agent per card, model haiku. It reads what a builder reads: the card, the full `docs/shape/spec.md` and the current contents of the files the card lists (those that exist). It may open `docs/shape/mockup.html`, where the card's Mock-up anchors point. Tell it: "Every card in this card's Blocked by is merged, and its files exist as described."

Start the readers in batches of at most 19, alongside the blind reviewer, so no more than 20 sub-agents run at once. Start the next batch as readers finish. A refused spawn is retried in the next batch, never dropped.

Prompt: "List every question you would need answered before building this card. Ask only where a wrong guess would fail an AC or break another card; a small choice you can state in the PR does not count. If none, answer exactly: none."

Any answer other than `none` fails the card. Count cards that answered `none` for the `Haiku read: n/N clear` figure.

## 3. One fix round

Fix every finding: decide it in spec.md, split the card, add a card or cut a card. Cutting or adding scope is the owner's call: list it as a flagged line in the review, never decide it silently. Re-run the Haiku read only on changed or new cards. Do not run a second round. Findings still open are shown under the table.

## Owner table lines

Above the table: `Verdict: builds the postcard: yes · Haiku read: 14/14 clear` (or `gaps`, and the real count). Below it, one line per open finding and per flagged scope change.
