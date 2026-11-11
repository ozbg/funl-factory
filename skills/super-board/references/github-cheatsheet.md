# GitHub cheat sheet — copy these, do not improvise

Every GitHub call a lane makes is on this page. Copy the command, change only `<N>`,
`<branch>`, `<file>` or `<cfg>`. A command not on this page is a mistake.

Each row is **one plain call**: run it exactly as written, one Bash call per row. No shell
variables for paths, no `&&`, `;` or `echo $?`. An allow rule matches one plain command, and
anything else prompts the owner (`lanes/common.md` → "Command shape"). The exit code is in
the tool result. Required reads go through `.claude/bin/super-board-github-read.py`.

## Before any write

| Need | Command |
|---|---|
| Quota | `bash .claude/bin/super-board-gh-guard.sh check 200` |
| Run still live? | `python3 .claude/bin/super-board-github-read.py --check` (exit 79 = stop) |

## Reads (required evidence)

| Need | Command |
|---|---|
| Issue title + body | `python3 .claude/bin/super-board-github-read.py --kind issue -- issue view <N> --json number,title,body` |
| Issue comments | `python3 .claude/bin/super-board-github-read.py --kind comments -- api repos/{owner}/{repo}/issues/<N>/comments --paginate --slurp` |
| Issue state | `python3 .claude/bin/super-board-github-read.py --kind state -- issue view <N> --json state --jq .state` |
| Open PRs (overlap, duplicate) | `python3 .claude/bin/super-board-github-read.py --kind prs-open -- pr list --state open --limit 100 --json number,title,body,url,headRefName,files` |
| Merged PRs | `python3 .claude/bin/super-board-github-read.py --kind prs-merged -- pr list --state merged --limit 50 --json number,title,body,url` |
| Closed issues | `python3 .claude/bin/super-board-github-read.py --kind issues-closed -- issue list --state closed --limit 50 --json number,title,body,stateReason` |
| My PR for a branch | `python3 .claude/bin/super-board-github-read.py --kind json -- pr list --head <branch> --state all --json number,url,state,isDraft` |
| PR branch + head SHA | `python3 .claude/bin/super-board-github-read.py --kind head -- pr view <N> --json headRefName,headRefOid --jq '"\(.headRefName) \(.headRefOid)"'` |
| PR body + head SHA | `python3 .claude/bin/super-board-github-read.py --kind body -- pr view <N> --json body,headRefOid` |
| PR size, files, labels | `python3 .claude/bin/super-board-github-read.py --kind metadata -- pr view <N> --json files,labels,body,additions,deletions,changedFiles > <file>` |
| PR diff (needs the metadata file) | `python3 .claude/bin/super-board-github-read.py --kind diff --meta <file> -- pr diff <N>` |
| PR merged? | `python3 .claude/bin/super-board-github-read.py --kind merge-state -- pr view <N> --json state,headRefOid,mergeCommit` |
| PR inline review comments | `python3 .claude/bin/super-board-github-read.py --kind json -- api repos/{owner}/{repo}/pulls/<N>/comments --paginate --slurp` |
| One inline review comment by id | `python3 .claude/bin/super-board-github-read.py --kind json -- api repos/{owner}/{repo}/pulls/comments/<id>` — no PR number in the path |
| One issue/PR conversation comment by id | `python3 .claude/bin/super-board-github-read.py --kind json -- api repos/{owner}/{repo}/issues/comments/<id>` — no issue number in the path |
| PR base + head branch | `python3 .claude/bin/super-board-github-read.py --kind json -- pr view <N> --json baseRefName,headRefName,headRefOid` |
| Anything else, `issue`/`pr` | `python3 .claude/bin/super-board-github-read.py --kind json -- issue view <N> --json <fields>` (or `pr view`, `pr list`, `issue list`) — no `--jq` |
| Anything else, `gh api` | `python3 .claude/bin/super-board-github-read.py --kind json -- api repos/{owner}/{repo}/<path>` — `gh api` has NO `--json` flag; it already returns full JSON |

## Board

| Need | Command |
|---|---|
| Card column | `bash .claude/bin/super-board-card.sh --config <cfg> status <N>` |
| Move card | `bash .claude/bin/super-board-card.sh --config <cfg> move <N> <Column>` |
| Whole board | `bash .claude/bin/super-board-card.sh --config <cfg> items` |

## Not required evidence (plain `gh`)

| Need | Command |
|---|---|
| CI checks | `gh pr checks <N> --json name,state,bucket` — exit 8 = still running; "no checks reported" = none, not a failure |

## Writes (plain `gh`, run once, never retry)

| Need | Command |
|---|---|
| Comment | `gh issue comment <N> --body-file <file>` |
| Open draft PR | `gh pr create --draft --base <base_branch> --head <branch> --title "<title>" --body-file <file>` |
| PR body blocks | `bash .claude/bin/super-board-pr-body.sh ...` (see writing-standard.md) |
| Mark PR ready | `gh pr ready <N>` |
| Labels | `gh issue edit <N> --add-label <name>` |
| Remove a label | `gh issue edit <N> --remove-label <name>` |
| Claim a card | `gh issue edit <N> --add-assignee <bot-login>` (`notifications.bot_identity` in the config) |
| Release a claim | `gh issue edit <N> --remove-assignee <bot-login>` |
| Merge | `.claude/bin/super-board-merge-gate.sh` only |
| List unresolved review threads | `gh api graphql -f query='query{repository(owner:"<owner>",name:"<repo>"){pullRequest(number:<N>){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{databaseId body}}}}}}}' --jq '.data.repository.pullRequest.reviewThreads.nodes[]\|select(.isResolved==false)\|"\(.id)\t\(.comments.nodes[0].body\|split("\n")[0])"'` |
| Reply to a review thread | `gh api graphql -f query='mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){comment{id}}}' -f t=<thread id> -f b="<one line: what fixed it, with the commit>"` |
| Resolve a review thread (only after the fix is pushed) | `gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' -f t=<thread id>` |

## Exit codes

- **64** — your command was wrong (bad flag, missing field, reshaped output). Find the row above, copy it exactly, run it once more.
- **79** — the run is paused. Stop all GitHub calls. Return `status=halted`.

## Never

- NEVER run `--resume`, and NEVER touch `.claude/super-board/github-halt*.json`. Only the orchestrator or the owner unpauses a run.
- NEVER add `--jq`, `-q` or `--template` to a read, except the two rows above that show one.
- NEVER drop fields from a `--json` list above. Each `--kind` checks for every field shown.
- NEVER call `gh api rate_limit`, `gh api graphql`, `gh project ...` or `curl api.github.com` yourself.
- NEVER invent a `--kind`. When unsure, use `--kind json` with full JSON output.
