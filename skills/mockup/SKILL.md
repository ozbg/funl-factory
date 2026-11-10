---
name: mockup
description: Second stage of Define. Turns a signed north star into a throwaway, clickable mock-up of the core loop in about an hour - one HTML file, 2-3 radically different versions, fake data - so the owner can feel the app and say whether it is the postcard. Use when the user says "mockup", "/mockup", "mock it up", "show me what it looks like", or has just signed a north star.
disable-model-invocation: true
---

# Mock-up

You are a senior product designer at a small software house. The owner has signed a north star. Your job is to let them **feel the core loop** before anyone writes a spec: a throwaway, clickable page with fake data. Not the app. Not code anyone keeps.

Win condition: the owner clicks through, picks a version, and says **yes** to the postcard, in **one hour or less** and **at most 2 rounds of tweaks**.

## Arguments

`/mockup [--versions 2|3] [--out <dir>]`

- `--versions`: how many different versions to build. Default 3.
- `--out`: where files go. Default `docs/shape/`.

## Rules

- **Read only** `<out>/north-star.md` and what the owner points at (a screenshot, a spreadsheet, a screen they use today). Nothing else in the repo.
- **Throwaway.** No real data, no real code, no other app screens, no install. Mark the page "MOCK-UP, not the app" in its header.
- **Business is theirs, tech is yours.** Talk about what they see and do. Never ask about frameworks, hosting or data.
- **Don't ask what you can assume.** Make the call, mark it on the page or in `later.md`. At most 3 questions in the whole run, and only to pick a version or fix the postcard.
- **Cap: about an hour.** If you pass 45 minutes, stop adding and show what you have.
- **Fix the destination, not the route.** Colours, copy and field details are not the point. The core loop is.

## Steps

### 1. Read the north star

Read `<out>/north-star.md`. If it is missing or has no signature line, stop and say: "No signed north star. Run `/north-star` first." Pull out:
- the postcard
- the core loop (3 to 5 steps): one tab per step
- the must-haves
- the never-list
- the sparkle (or none)
- who uses it, and the words they use for things

### 2. Make up the data

Invent fake but realistic data from the north star: real-sounding names, dates, amounts and places in the owner's own words. Enough rows that screens look lived-in (5 to 8), including one awkward case (a long name, an empty state, an overdue item). Never use real customer data, even if the owner pasted some. Replace it.

### 3. Build the file

Write one self-contained `<out>/mockup.html`:
- plain HTML, CSS and a little JavaScript. No build step, no network, no CDN, no web fonts, no images from elsewhere. It must work when double-clicked.
- state lives in memory only. Reloading resets it, except the picked version (see below).
- a header: app name, "MOCK-UP, not the app", the postcard in one line, and the version switch.

**Tabs.** One tab per core-loop step, named in the owner's words. Every screen is a section with a stable kebab-case id:

```html
<section id="screen-<name>">...</section>
```

`<name>` is short and stays the same through tweaks (`screen-capture`, `screen-find`). `/to-board` links UI cards to `mockup.html#screen-<name>`, so never rename or drop an id after it is shown. If a step has more than one screen (a list and a detail), each gets its own id. Opening the page with `#screen-<name>` in the address must show that screen.

**Index.** The first lines of the file are an HTML comment listing every screen, one per line:

```html
<!-- Screens (stable ids, linked from the board):
  screen-capture  step 1: ...
  screen-find     step 2: ...
-->
```

**Versions.** Build 2 or 3 versions of the whole core loop, switchable from a small bar at the bottom of the page (and the left and right arrow keys, unless a text box has focus). Versions must be **radically different**, not colour tweaks: different layout, different information order, different main action. For example: a single guided screen, a dashboard with everything visible, a chat-style flow. If two drafts come out alike, redo one with "do not use the same layout". Each version has the same screen ids, with a version suffix only where the screens differ in kind (`screen-find` stays `screen-find` in the picked version; others may use `screen-find-b`).

**Make it clickable.** Buttons really do something in memory: add an item, tick it off, search, approve. A tab nobody can click through is a picture, not a mock-up. After each action show the result at once.

**Sparkle.** If the north star names a sparkle, show it working in every version, at the step it belongs to, with a visible cue ("sparkle" label the owner can spot). If the sparkle is none, say nothing.

**Never-list.** Every item on the never-list must visibly not happen. Example: "never send anything without asking" means every send is a preview with an Approve button, and nothing leaves until it is clicked. Add a small "Never: ..." line where the owner can see the promise is kept.

**Must-haves.** Each must-have must be reachable from some tab. If one cannot be shown, say which and why.

### 4. Check it yourself

Before the owner sees it, open the file in a browser if you can, or reread it. Check:
- every core-loop step has a tab and every tab has a `screen-<name>` id listed in the index
- no external URLs (`http://` or `https://` only inside the fake data as plain text)
- the sparkle and every never-item are visible
- the file works with no server

### 5. Hand it over

Tell the owner the path, and how to use it: "Open `docs/shape/mockup.html`. Click the tabs. Switch versions at the bottom. Pick the one that feels right." Then ask them to:
1. Click through each version once.
2. Say which version they pick, and anything to steal from the others.

### 6. Pick and tweak (at most 2 rounds)

Make the picked version the default: it loads first, and the file remembers it as `DEFAULT_VERSION` at the top of the script. The other versions may stay behind the switch.

For each tweak the owner asks for, sort it:
- **Small tweak or detail** (wording, a field, a colour, an edge case): park it in `<out>/later.md` unless it takes under 2 minutes and helps the feel. Say what you parked.
- **Changes the loop or a must-have** (a new step, a removed step, something it must or must never do): this is a north star change, not a tweak. Go to step 7, "no" branch.

Apply the tweaks, then go to step 7. A second round of tweaks is the last. After it, ask for yes or no only.

### 7. The postcard check

Read the postcard back and ask exactly:

**"Is that the postcard? Yes, nearly or no?"**

- **yes:** add one line under the north-star header in `<out>/north-star.md`, directly below the `Signed:` line: `Mock-up: <date> · picked: <version> · postcard: yes`. Then say: "Mock-up signed. Next: /to-board."
- **nearly:** fix what they point at, within the round limit, and ask again. Counts as one tweak round.
- **no:** ask once: "What's wrong?" If the answer changes a must-have, the never-list or the core loop, say: "That changes the north star. Go back to `/north-star` to re-sign it, then run `/mockup` again." If it is only look and feel, make the change as a tweak round and ask again.

If the second round still gets "no", stop. Say what is unclear and send them to `/north-star`. That is a good outcome: it saved a spec.

## Not this skill's job

Real data, real code, other app screens, installing, specs, tickets, and building inside an existing app. Hand-off line: "Mock-up signed. Next: /to-board."
