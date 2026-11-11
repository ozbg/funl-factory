# Feedback card

Owners and users find problems by using the app. The feedback icon makes reporting one a single
click, and keeps the facts a fix needs: the screen, the state and the logs. `/to-board` cuts **one
feedback card in every app**, and `/super-collect feedback` reads what it saves
(`../../super-collect/SKILL.md` § feedback).

Apps run on different stacks, so the factory owns this spec, not a widget. The builder makes the
icon in the app's own stack, from this file.

## What the icon does

- **Always there.** A small fixed icon, bottom right, on every screen. It never covers a control:
  the app leaves room for it. Keyboard reachable, with the label `Send feedback`.
- **One panel.** Click it to open a panel with one text box (`What's wrong, or what do you want?`)
  and a `Mark up a screenshot` option. Markup draws freehand on a capture of the screen, in one
  colour. Submit, cancel, nothing else.
- **Captures on submit:**
  - the screenshot (with the markup, when there is any), taken before the panel opens, so the panel is not in it
  - the route or screen: the path, plus the mock-up screen name when the app knows it
  - the element the user marked or last clicked, as a stable selector (`[data-testid=save-note]`), when there is one
  - the app version or commit
  - a small **state snapshot** the app chooses: ids and counts, never whole records
    (`{"client_id": 42, "notes": 3, "filter": "open"}`)
  - the recent log lines: the last 50 client lines (console warnings and errors, failed requests)
    and the last 50 server lines for this session, when the app keeps them
- **Saves locally.** One item, `<data>/feedback/<id>.json`, plus `<id>.png` when there is a
  screenshot. `<data>` is the app's own data folder. `<id>` is `<UTC timestamp>-<slug of the
  text>`, for example `20261112T101500Z-save-does-nothing`.
- **Sends nothing.** No network call, no token, no third-party library that phones home. A web app
  posts the item to its own local server route, which writes the file; nothing else.
- **A tiny list.** One screen or panel lists the saved items, newest first: time, first line and
  status. Status is `filed #N` when `<data>/feedback/filed.json` names the item (collect writes
  it), else `new`.

## The item, `feedback/1`

```json
{
  "schema": "feedback/1",
  "id": "20261112T101500Z-save-does-nothing",
  "created_at": "2026-11-12T10:15:00Z",
  "text": "Save does nothing on a note",
  "route": "/clients/42?tab=notes",
  "screen": "screen-client",
  "element": "[data-testid=save-note]",
  "app": {"version": "1.4.0", "commit": "abc1234"},
  "state": {"client_id": 42, "notes": 3, "filter": "open"},
  "logs": {"client": ["warn POST /api/notes 500"], "server": ["error notes.save: null client"]},
  "screenshot": "20261112T101500Z-save-does-nothing.png",
  "marked_up": true
}
```

| Field | Rule |
|---|---|
| `schema` | always `feedback/1`. A breaking change bumps the number; collect skips a schema it doesn't know and says so |
| `id`, `created_at`, `text`, `route` | required. `created_at` is ISO 8601 UTC |
| `app` | required: `version`, `commit` or both |
| `screen`, `element` | optional strings; `null` or left out when unknown |
| `state` | optional object, flat, at most 20 keys: ids, counts, flags, filter values. No names, emails, phones, free text or whole records |
| `logs` | optional `{client: [..], server: [..]}`, strings, at most 50 each |
| `screenshot` | the PNG's file name in the same folder, or `null` |
| `marked_up` | `true` when the user drew on the screenshot |

The app never writes `status`: collect keeps that in `filed.json`.

## The card

One **amber** card, cut right after the foundation card and Blocked by it. It is a slice card
with no must-have of its own, so it adds no coverage row.

- **Title:** `✨ [feat] feedback: in-app feedback icon, saved locally`
- **Files:** the icon and panel, the local save (a server route for a web app), the list, and
  their tests, in the foundation's patterns.
- **Fix:** build the icon from `.claude/skills/to-board/references/feedback-card.md`. Name the
  data folder from spec.md.
- **Mock-up:** the screen anchor only if the mock-up shows the icon. No icon in the mock-up, no line.
- **Acceptance Criteria**, each with its test:
  - [ ] Clicking the icon and submitting text saves one `<data>/feedback/<id>.json` with the route, element, app version, state snapshot and recent logs
  - [ ] With markup on, a `<id>.png` is saved beside it, with the drawing in it, and the item names it
  - [ ] No outbound call: submitting makes no request to any host but the app's own server
  - [ ] The saved item validates against `feedback/1`: required fields present, `state` flat with at most 20 keys, logs at most 50 lines each
  - [ ] The list shows each item with `new`, or `filed #N` from `filed.json`
</content>
</invoke>
