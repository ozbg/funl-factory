# Screen match: the app beside its baseline

Every screen card gets this check, whatever its zone. A screen card is one with a `**Mock-up:**`
line or a `## Mock-up` block. Its match AC reads
``screen matches mock-up `#screen-<name>` (screenshot side by side) — test: QA screenshot``.

QA proves that AC with a screenshot pair and a list of differences. Review looks at the pair
before passing the card.

## The baseline

- **Until the first build ships, the baseline is the mock-up.** The AC names the anchor:
  ``matches mock-up `#screen-<name>` ``. QA captures that section of `docs/shape/mockup.html`.
- **After the first build ships, the mock-up is frozen** and the app's own screenshots are the
  baseline. Cards written from then on name the file:
  ``screen matches baseline `docs/shape/baseline/screen-<name>.png` ``. QA uses that file as it
  is on the base branch.

| File | What it is | Written by |
|---|---|---|
| `docs/shape/baseline/screen-<name>.png` | the app screen, desktop | QA, on the card's branch, each round. It becomes the baseline when the card merges |
| `docs/shape/baseline/screen-<name>-phone.png` | the app screen, phone | the same, when the mock-up has a phone view |
| `docs/shape/baseline/mockup/screen-<name>.png` · `-phone.png` | the mock-up anchor | QA, once. Already on the base branch → reuse it |

These are the only QA images that are committed. Everything else stays in the local evidence
folder. A rebase conflict on one of these files keeps the branch's copy.

## Capture

Same size on both sides. Desktop is 1280×800, always. Add phone (390×844) when the mock-up has a
phone view for that screen: a phone frame or toggle, or narrow-width `@media` rules that change it.

The helper is `scripts/runtime_browser.mjs --shot`. `SB_RUNTIME_PROJECT` is the app root with
Playwright installed; nothing is installed for you.

```bash
node .claude/skills/super-qa/scripts/runtime_browser.mjs --shot --screen screen-<name> --viewport desktop --url "file://<worktree>/docs/shape/mockup.html#screen-<name>" --out <worktree>/docs/shape/baseline/mockup/screen-<name>.png
```
```bash
node .claude/skills/super-qa/scripts/runtime_browser.mjs --shot --viewport desktop --url "<app URL of the screen>" --out <worktree>/docs/shape/baseline/screen-<name>.png
```

Run the app on its seed or demo data, the closest to the mock-up's sample data. Add
`--full-page` to both sides for a screen taller than the viewport. The helper prints one JSON
line: `opened` says how it reached the screen, and `classes` lists every class inside it.

### Opening `#screen-<name>` in the mock-up

The mock-up is often one vanilla-JS file that builds its screens in script and switches them by
URL hash or by tabs. The helper:

- a. loads `mockup.html#screen-<name>` and waits for the page to settle
- b. passes if an element with id `screen-<name>` is visible
- c. otherwise clicks the first visible control that targets it: a link ending `#screen-<name>`,
  `data-screen`, `data-tab`, `aria-controls`, or a tab named after the screen, then checks again

The mock-up switches screens some other way: read its script, then pass that control as
`--click "<selector>"`. The helper still fails with `could not open #screen-<name>` (exit 2):
this is never a pass. Leave the match AC unticked with that error and move the card to Blocked
(❓, `To unblock: say how to open #screen-<name> in the mock-up`). The builder can't fix the
mock-up, so a bounce would only burn a round.

The mock-up's own chrome is not the screen. Its tab bar, version switch and owner notes are
never differences.

## List the differences

Look at the pair. Compare the app's `classes` with the card's `Classes:` line. Write one row
for each visible difference. Kinds: layout, component, class, type, colour, spacing, copy,
missing control, extra control. Different sample names and numbers are not a difference; a
different number of rows, columns or controls is.

Judge each row against the card:

- `✅ cut: <quote>` when the card's `Cut from mock-up:` line lists it
- `✅ accepted: <comment link>` when a note on the card accepts it
- `❌ AC<n>` for anything else. It fails the match AC, citing the difference

No difference at all → one row reading `none`. A pass with no list is not a pass.

## Commit and embed

1. In the card worktree, `git add docs/shape/baseline/`, commit `💄 [ui] screen-<name>: QA
   screenshots v<V>`, and push. `<sha>` is that commit.
2. Pin each image to the commit that holds it. Mock-up shots and the new app shots use `<sha>`.
   A baseline PNG from after the first build uses `<base-sha>`, because this branch overwrites it.
3. Embed the pair below the QA comment's AC table, on the issue and the PR, and write the same
   table into the PR's `visual` block. Raw URLs pinned to a sha, never links (writing-standard.md).

```
| | Baseline: mock-up `#screen-pipeline` | App `3f9c2a1` |
|---|---|---|
| Desktop | <img src="https://github.com/<o>/<r>/raw/3f9c2a1/docs/shape/baseline/mockup/screen-pipeline.png" width="480"> | <img src="https://github.com/<o>/<r>/raw/3f9c2a1/docs/shape/baseline/screen-pipeline.png" width="480"> |
| Phone | <img src="https://github.com/<o>/<r>/raw/3f9c2a1/docs/shape/baseline/mockup/screen-pipeline-phone.png" width="220"> | <img src="https://github.com/<o>/<r>/raw/3f9c2a1/docs/shape/baseline/screen-pipeline-phone.png" width="220"> |

| # | Difference | Kind | Verdict |
|---|---|---|---|
| D1 | no source filter above the list | missing control | ✅ cut: source filter (#14) |
| D2 | stage headers 14 px, mock-up 12 px capitals | type | ❌ AC3 |
```

The match AC's proof line is the app shot: `docs/shape/baseline/screen-<name>.png`. It is a
file at the head, so the merge gate accepts it.
