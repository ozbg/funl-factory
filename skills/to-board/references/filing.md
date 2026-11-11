# Filing the cards

The same tools the board's lanes use ([github-cheatsheet.md](../../super-board/references/github-cheatsheet.md)).
Run from the app's repo root. `<cfg>` is the board config; `<owner>`, `<number>` are its
`project.owner` and `project.number`; `<repo>` is `repo.remote` as `owner/name`.

Run each command as one plain call, exactly as written: no shell variables, no `&&` or `;`.

## Once, before the first card

| Need | Command |
|---|---|
| Quota | `bash .claude/bin/super-board-gh-guard.sh check 200` |
| Run still live? | `python3 .claude/bin/super-board-github-read.py --check` (exit 79 = stop) |
| Milestone exists? | `python3 .claude/bin/super-board-github-read.py --kind json -- api repos/<repo>/milestones --paginate` and look for the title |
| Make the milestone (only if missing, only with the title the owner gave or the config holds) | `gh api repos/<repo>/milestones -f title="<milestone>"` |

## Each card, in build order

Write the body to a temp file, then:

| Step | Command |
|---|---|
| a. Create the issue (no `--label`) | `gh issue create --repo <repo> --title "<title>" --body-file <file> --milestone "<milestone>"` → prints the issue URL |
| b. Put it on the board | `gh project item-add <number> --owner <owner> --url <issue URL> --format json --jq .id` |
| c. Move it to Ready | `bash .claude/bin/super-board-card.sh --config <cfg> move <N> Ready` |

Run each write once. Never retry a create: a failed or unclear `gh issue create` means
check with `python3 .claude/bin/super-board-github-read.py --kind json -- issue list --repo <repo> --search "<title> in:title" --json number,title`
before trying again. Keep a list of title → number as you go; later cards' `## Blocked by`
use those numbers.

A board with no Ready column: stop and tell the owner. File only after the owner's scope review (SKILL step 8).

## After the last card

Check that every card parses the way the planner will read it:

```bash
bash .claude/bin/super-board-deps.sh --repo <repo> --issues <N,M,…>
```

Each new card must show `parseable: true`, `acs` between 2 and 5, a `mustHave` list, a
`files` list and `blockers` matching its `## Blocked by`. Fix any that don't with `gh issue edit <N> --body-file <file>`.

## Re-running

Search before you create: a card whose exact title is already open is not filed again.
Edit it instead, only while it is in Backlog or Ready.
