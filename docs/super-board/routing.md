# Which path do I take?

Pick the path by what you have. Every path ends in tickets on the super-board Backlog.

## 1. Plan: from what you have to tickets

| You have | Do this |
|---|---|
| An idea, or a north star | `/to-board` |
| Bugs and errors | `/super-collect` (triage files fixes to Ready, proposals straight into Backlog) |

- `/to-board` turns the north star into a one-page spec and Haiku-ready cards in Backlog.
- `/super-collect` finds problems (Sentry, PostHog, issues, PRs, code shape), checks each one, picks its track ([iteration](../../skills/super-board/references/iteration.md)) and files it in the ticket format.

## 2. Build

Run `/super-board lint`, move the good tickets to **Ready**, then `/super-board run`. Build → QA (with the security check) → Review → merge gate.

## 3. Deploy

super-deploy is planned. It is not built yet.
