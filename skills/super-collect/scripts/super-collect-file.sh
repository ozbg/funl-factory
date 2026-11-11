#!/usr/bin/env bash
# super-collect-file.sh — file one collected item onto the super-board project,
# into the holding column only. Dry-run unless --yes.
#
# This is a router, not a third filer. Bugs, features and recurring-problem fixes go
# through super-qa-file-bug.sh; refactors through super-review-file-refactor.sh.
# What it adds on top of them:
#   1. a repo-wide fingerprint dedupe (theirs only see their own source label),
#   2. holding-column resolution BEFORE dispatch — both filers fall back toward
#      Ready when the requested column is missing, and super-collect puts a card in
#      Ready only as a triage fix (`--decision fix`). No holding column → refuse (exit 65).
#   3. `--adopt N` for a user-filed issue that is not on the board yet: place the
#      existing issue instead of filing a copy of it.
#   4. one fingerprint shape per source, so the same problem keys the same way on
#      every run: sentry `err|sentry|<issue-id>`, posthog `posthog|<signal>|<key>`
#      (tracking gaps: `gap|<workflow>`),
#      github `github|<issue#>`, prs `prs|<boundary>|<cause>`,
#      architecture `arch|<module>|<problem>`, walk `walk|<screen-name or M<n>>|<key>`,
#      feedback `feedback|<route>|<element>|<text hash>`.
#   5. triage (super-board references/iteration.md): `--track bug|tweak|body` labels the
#      track; `--decision fix` files to Ready and needs a `Breaks:` line plus a
#      `Failing test:` line (bug) or a `## Before and after` section (tweak);
#      `--decision propose` files to Backlog with the `proposal` label and needs a
#      `## Recommendation` section. The fix cap is applied before this, by
#      `collect_handoff.py triage`. A closed issue whose body carries the
#      rejection marker is never filed again (`rejected|#N`).
#   6. the owner's answer to the proposals digest: `--accept N` (bug or tweak → Ready,
#      body of work stays in Backlog for the grill) and `--reject N --reason "<why>"`
#      (comment, marker in the body, label `rejected`, closed as not planned).
#
# Usage:
#   super-collect-file.sh --config <cfg.json> --type bug|feature|refactor|fix \
#     --source sentry|posthog|github|prs|architecture|custom|walk|feedback --title "<one line>" --body-file <md> \
#     --fingerprint "<stable key>" [--priority high|medium|low] [--area <a>] \
#     [--label <l>]... [--track bug|tweak|body --decision fix|propose] [--yes]
#   super-collect-file.sh --config <cfg.json> --adopt <issue#> --type bug|feature|refactor [--yes]
#   super-collect-file.sh --config <cfg.json> --accept <issue#> [--yes]
#   super-collect-file.sh --config <cfg.json> --reject <issue#> --reason "<why>" [--yes]
#
# Stdout: dry-run → one `would-file|duplicate|recurrence|rejected|would-adopt|would-accept|would-reject` plan line;
#         --yes   → the issue number (new, existing on a dedupe hit, adopted, accepted or rejected).
# Exits:  0 ok · 64 bad args · 65 no holding column · 66 unreadable/weak body
#         70 gh failure · 71 filed but not placed (number still on stdout)
#         79 repository paused (existing issue number still on stdout after discovery)
set -uo pipefail

ORIGINAL_ARGS=("$@")
CONFIG=""; TYPE=""; SOURCE=""; TITLE=""; BODY_FILE=""; FP=""
PRIORITY="medium"; AREA=""; ADOPT=""; YES=0; EXTRA_LABELS=()
TRACK=""; DECISION=""; ACCEPT=""; REJECT=""; REASON=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config)      CONFIG="$2"; shift 2 ;;
    --type)        TYPE="$2"; shift 2 ;;
    --source)      SOURCE="$2"; shift 2 ;;
    --title)       TITLE="$2"; shift 2 ;;
    --body-file)   BODY_FILE="$2"; shift 2 ;;
    --fingerprint) FP="$2"; shift 2 ;;
    --priority)    PRIORITY="$2"; shift 2 ;;
    --area)        AREA="$2"; shift 2 ;;
    --adopt)       ADOPT="$2"; shift 2 ;;
    --label)       EXTRA_LABELS+=("$2"); shift 2 ;;
    --track)       TRACK="$2"; shift 2 ;;
    --decision)    DECISION="$2"; shift 2 ;;
    --accept)      ACCEPT="$2"; shift 2 ;;
    --reject)      REJECT="$2"; shift 2 ;;
    --reason)      REASON="$2"; shift 2 ;;
    --yes)         YES=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

die() { echo "$1" >&2; exit "$2"; }

[ -n "$CONFIG" ] && [ -r "$CONFIG" ] || die "config not found: ${CONFIG:-<unset>}" 66
ANSWER="${ACCEPT:-$REJECT}"
if [ -n "$ACCEPT" ] && [ -n "$REJECT" ]; then die "--accept and --reject are one answer each" 64; fi
if [ -n "$ANSWER" ]; then
  case "$ANSWER" in *[!0-9]*) die "--accept/--reject take an issue number (got: $ANSWER)" 64 ;; esac
  [ -z "$REJECT" ] || [ -n "$(printf '%s' "$REASON" | tr -d '[:space:]')" ] || die "--reject needs --reason \"<why>\"" 64
  TYPE=answer
fi
case "$TYPE" in bug|feature|refactor|fix|answer) ;; *) die "--type must be bug|feature|refactor|fix (got: ${TYPE:-<unset>})" 64 ;; esac
case "$TRACK" in ""|bug|tweak|body) ;; *) die "--track must be bug|tweak|body (got: $TRACK)" 64 ;; esac
case "$DECISION" in ""|fix|propose) ;; *) die "--decision must be fix|propose (got: $DECISION)" 64 ;; esac
if [ -n "$DECISION" ] && [ -z "$TRACK" ]; then die "--decision needs --track" 64; fi
if [ -n "$TRACK" ] && [ -z "$DECISION" ]; then die "--track needs --decision fix|propose" 64; fi
if [ "$DECISION" = fix ] && [ "$TRACK" = body ]; then die "a body of work is never a fix: --decision propose (iteration.md)" 64; fi
case "$TRACK" in bug) TRACK_LABEL=bug ;; tweak) TRACK_LABEL=tweak ;; body) TRACK_LABEL=body-of-work ;; *) TRACK_LABEL="" ;; esac
[ -z "$TRACK_LABEL" ] || EXTRA_LABELS+=("$TRACK_LABEL")
[ "$DECISION" != propose ] || EXTRA_LABELS+=("proposal")
case "$PRIORITY" in high|medium|low) ;; *) die "--priority must be high|medium|low (got: $PRIORITY)" 64 ;; esac

if [ -n "$ANSWER" ]; then
  :
elif [ -z "$ADOPT" ]; then
  case "$SOURCE" in
    sentry) FP_PREFIX="err|sentry|" ;; posthog) FP_PREFIX="posthog|" ;; github) FP_PREFIX="github|" ;;
    prs) FP_PREFIX="prs|" ;; architecture) FP_PREFIX="arch|" ;;
    custom) FP_PREFIX="custom|" ;;   # onboard's "➕ Add another source": custom|<name>|<key>
    walk) FP_PREFIX="walk|" ;;       # the milestone-end agent walk: walk|<screen-or-M<n>>|<key>
    feedback) FP_PREFIX="feedback|" ;;  # the in-app feedback icon: feedback|<route>|<element>|<text>
    *) die "--source must be sentry|posthog|github|prs|architecture|custom|walk|feedback (got: ${SOURCE:-<unset>})" 64 ;;
  esac
  [ -n "$TITLE" ] || die "--title is required" 64
  [ -n "$FP" ]    || die "--fingerprint is required (dedupe key)" 64
  case "$FP" in *[[:space:]]*) die "--fingerprint must be one token without whitespace" 64;; esac
  case "$FP" in *'"'*|*'\\'*) die "--fingerprint may not contain quotes or backslashes" 64 ;; esac
  case "$SOURCE|$FP" in "posthog|gap|"?*) FP_PREFIX="gap|" ;; esac
  case "$FP" in "$FP_PREFIX"?*) ;; *) die "--fingerprint for source ${SOURCE} must start with '${FP_PREFIX}' (got: $FP)" 64 ;; esac
  [ -n "$BODY_FILE" ] && [ -r "$BODY_FILE" ] || die "--body-file missing or unreadable: ${BODY_FILE:-<unset>}" 66
else
  case "$ADOPT" in *[!0-9]*|"") die "--adopt takes an issue number (got: $ADOPT)" 64 ;; esac
  [ "$TYPE" != "fix" ] || die "--adopt takes bug|feature|refactor" 64
fi

OWNER=$(jq -r '.project.owner // empty' "$CONFIG")
NUMBER=$(jq -r '.project.number // empty' "$CONFIG")
PTITLE=$(jq -r '.project.title // empty' "$CONFIG")
REMOTE=$(jq -r '.repo.remote // empty' "$CONFIG")
[ -n "$OWNER" ] && [ -n "$NUMBER" ] || die "config lacks project.owner / project.number" 66
REPO_FLAG=()
[ -z "$REMOTE" ] || REPO_FLAG=(-R "$(echo "$REMOTE" | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')")

BIN="${SUPER_BOARD_BIN:-}"
if [ -z "$BIN" ]; then
  # Installed: .claude/skills/super-collect/scripts → .claude/bin. Pack: skills/… → scripts/.
  ROOT3=$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)
  for d in ".claude/bin" "$ROOT3/bin" "$ROOT3/scripts"; do
    [ -x "$d/super-qa-file-bug.sh" ] && { BIN="$d"; break; }
  done
fi
[ -n "$BIN" ] || die "cannot find super-qa-file-bug.sh — set SUPER_BOARD_BIN or run install.sh" 70

# Router-owned duplicate/adopt writes share the same halt as the child filers.
GITHUB_READ="$BIN/super-board-github-read.py"
python3 "$GITHUB_READ" --check || exit $?
REPO_NAME="${REPO_FLAG[1]:-}"
if [ -z "$REPO_NAME" ]; then
  REPO_NAME=$(python3 "$GITHUB_READ" --kind scalar -- repo view --json nameWithOwner --jq .nameWithOwner) || exit $?
fi
case "$REPO_NAME" in */*) ;; *) die "cannot resolve owner/name for collector" 70;; esac
STATE="$BIN/super-board-collect-state.py"
LOCK_KEY=$(printf '%s' "$REPO_NAME" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().lower().encode()).hexdigest())')
if [ "${SB_COLLECT_LOCK_HELD:-}" != "$LOCK_KEY" ]; then
  exec python3 "$STATE" --repo "$REPO_NAME" --lock -- "$0" "${ORIGINAL_ARGS[@]}"
fi
STATE_FP="${FP:-adopt|$ADOPT}"
[ -z "$ACCEPT" ] || STATE_FP="accept|$ACCEPT"
[ -z "$REJECT" ] || STATE_FP="reject|$REJECT"
state() { python3 "$STATE" --repo "$REPO_NAME" --action "$1" --fingerprint "$STATE_FP" --digest "${DIGEST:-}" --issue "${2:-}"; }
DIGEST=""
if [ -n "$BODY_FILE" ]; then
  DIGEST=$(python3 -c 'import hashlib,sys; print(hashlib.sha256((sys.argv[1]+"\0").encode()+open(sys.argv[2],"rb").read()).hexdigest())' "$SOURCE" "$BODY_FILE") || exit 70
fi

# --- body sections ----------------------------------------------------------
# The ticket format is writing-standard.md § 3. super-qa-file-bug.sh enforces the
# full bug shape (lettered steps, the 12-row Evidence table). Features and
# recurring-problem fixes are not repro-shaped, so they get their own minimum here
# and the QA filer's repro check is bypassed for them. Refactors: the review filer.
need_sections() {
  local missing="" s
  for s in "$@"; do
    grep -qiE "^#{1,3}[[:space:]]+${s}[[:space:]]*$" "$BODY_FILE" || missing="${missing}${missing:+, }${s}"
  done
  [ -z "$missing" ] || die "body is missing required section(s): ${missing} (writing-standard.md § 3)" 66
}
need_checklist() {
  awk '/^#+[[:space:]]+/ { h = tolower($0); on = (h ~ /^#+[[:space:]]+acceptance criteria[[:space:]]*$/); next }
       on && /^[[:space:]]*- \[[ xX]\] / { found = 1 } END { exit !found }' "$BODY_FILE" \
    || die "Acceptance Criteria needs a checklist: one '- [ ] <checkable outcome>' per line" 66
}
need_line() { # $1 = the card line, e.g. Breaks
  grep -qiE "^[[:space:]]*(- )?(\*\*)?${1}:(\*\*)?[[:space:]]*[^[:space:]]" "$BODY_FILE" \
    || die "a triage ${DECISION} needs a '${1}:' line in Context (iteration.md)" 66
}
if [ -z "$ADOPT" ] && [ -z "$ANSWER" ]; then
  case "$DECISION|$TRACK" in
    fix\|bug)   need_line "Breaks"; need_line "Failing test" ;;
    fix\|tweak) need_line "Breaks"; need_sections "Before and after" ;;
    propose\|*) need_sections "Recommendation" ;;
  esac
  case "$TYPE" in
    bug) "$BIN/super-qa-file-bug.sh" --title "$TITLE" --body-file "$BODY_FILE" --check-body || exit $? ;;
    feature)  need_sections "Problem" "Context" "Fix" "Acceptance Criteria" "Risk"; need_checklist ;;
    fix)      need_sections "Problem" "Context" "Evidence" "Fix" "Acceptance Criteria" "Risk"; need_checklist ;;
    refactor) need_sections "Problem" "Context" "Fix" ;;
  esac
fi

# --- holding column ---------------------------------------------------------
FIELDS=$(python3 "$GITHUB_READ" --kind fields -- project field-list "$NUMBER" --owner "$OWNER" --format json) || exit $?
HOLD=""
for c in Backlog Todo "To do" Triage Inbox; do
  hit=$(echo "$FIELDS" | jq -r --arg c "$c" '.fields[] | select(.name=="Status") | .options[]? | select(.name==$c) | .name' | head -1)
  if [ -n "$hit" ]; then HOLD="$hit"; break; fi
done
[ -n "$HOLD" ] || die "project ${OWNER}/${NUMBER} has no holding column (Backlog, Todo, To do, Triage, Inbox) — refusing: the filers would fall back to Ready" 65
READY=$(echo "$FIELDS" | jq -r '.fields[] | select(.name=="Status") | .options[]? | select(.name=="Ready") | .name' | head -1)
COLUMN="$HOLD"
if [ "$DECISION" = fix ]; then
  [ -n "$READY" ] || die "project ${OWNER}/${NUMBER} has no Ready column for a triage fix" 65
  COLUMN="$READY"
fi

place() { # $1 = issue url, $2 = column (default the holding column)
  local item_id project_id field_id option_id col="${2:-$HOLD}"
  python3 "$GITHUB_READ" --check || return $?
  item_id=$(gh project item-add "$NUMBER" --owner "$OWNER" --url "$1" --format json --jq '.id') || return 1
  python3 "$GITHUB_READ" --check || return $?
  project_id=$(gh project view "$NUMBER" --owner "$OWNER" --format json --jq '.id') || return 1
  field_id=$(echo "$FIELDS" | jq -r '.fields[] | select(.name=="Status") | .id')
  option_id=$(echo "$FIELDS" | jq -r --arg c "$col" '.fields[] | select(.name=="Status") | .options[] | select(.name==$c) | .id')
  python3 "$GITHUB_READ" --check || return $?
  gh project item-edit --id "$item_id" --project-id "$project_id" \
    --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null
}

tag() { # $1 = issue number, rest = labels; best-effort
  local n="$1"; shift
  for l in "$@"; do
    python3 "$GITHUB_READ" --check || return $?
    gh label create "$l" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --color 5319E7 --force >/dev/null 2>&1 || true
  done
  for l in "$@"; do
    python3 "$GITHUB_READ" --check || return $?
    gh issue edit "$n" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --add-label "$l" >/dev/null 2>&1 || echo "warn: could not label #${n} ${l}" >&2
  done
  return 0
}

# --- the owner's answer to a proposal ---------------------------------------
if [ -n "$ANSWER" ]; then
  ISSUE=$(python3 "$GITHUB_READ" --kind issue -- issue view "$ANSWER" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --json number,title,body,labels,url) || exit $?
  LABELS=$(printf '%s' "$ISSUE" | jq -r '[.labels[]?.name] | join(",")') || exit 70
  case ",$LABELS," in *,proposal,*) ;; *) die "#${ANSWER} is not an open proposal (no 'proposal' label)" 64 ;; esac
  case ",$LABELS," in *,body-of-work,*) ATRACK=body ;; *,tweak,*) ATRACK=tweak ;; *,bug,*) ATRACK=bug ;; *) ATRACK=body ;; esac
  if [ -n "$REJECT" ]; then
    if [ "$YES" -ne 1 ]; then echo "would-reject|#${REJECT}|${REASON}"; exit 0; fi
    SAFE_REASON=$(printf '%s' "$REASON" | tr '\n' ' ' | sed 's/--*>*/-/g')
    BODY_TMP=$(mktemp); trap 'rm -f "$BODY_TMP"' EXIT
    { printf '%s' "$ISSUE" | jq -r '.body'; echo; echo "<!-- super-collect-rejected: ${SAFE_REASON} -->"; } > "$BODY_TMP"
    state begin "$REJECT" || exit $?
    tag "$REJECT" rejected || { RC=$?; echo "$REJECT"; exit "$RC"; }
    for step in body comment unlabel close; do
      python3 "$GITHUB_READ" --check || { RC=$?; echo "$REJECT"; exit "$RC"; }
      case "$step" in
        body)    gh issue edit "$REJECT" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --body-file "$BODY_TMP" >/dev/null 2>&1 ;;
        comment) gh issue comment "$REJECT" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --body "Rejected by the owner: ${REASON}" >/dev/null 2>&1 ;;
        unlabel) gh issue edit "$REJECT" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --remove-label proposal >/dev/null 2>&1 ;;
        close)   gh issue close "$REJECT" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --reason "not planned" >/dev/null 2>&1 ;;
      esac || { python3 "$GITHUB_READ" --halt "Reject of #${REJECT} stopped at ${step}; reconcile before retrying"; echo "$REJECT"; exit 79; }
    done
    state success "$REJECT" || exit $?
    echo "$REJECT"; exit 0
  fi
  TARGET="$HOLD"
  if [ "$ATRACK" != body ]; then
    [ -n "$READY" ] || die "project ${OWNER}/${NUMBER} has no Ready column" 65
    TARGET="$READY"
  fi
  if [ "$YES" -ne 1 ]; then echo "would-accept|#${ACCEPT}|${ATRACK}|${TARGET}"; exit 0; fi
  state begin "$ACCEPT" || exit $?
  python3 "$GITHUB_READ" --check || { RC=$?; echo "$ACCEPT"; exit "$RC"; }
  NEXT="moves to ${TARGET}"
  [ "$ATRACK" != body ] || NEXT="stays in ${TARGET}; next, grill it (iteration.md, step a)"
  gh issue comment "$ACCEPT" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --body "Accepted by the owner: ${NEXT}." >/dev/null 2>&1 \
    && python3 "$GITHUB_READ" --check \
    && gh issue edit "$ACCEPT" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --remove-label proposal >/dev/null 2>&1 \
    || { python3 "$GITHUB_READ" --halt "Accept of #${ACCEPT} incomplete; reconcile before retrying"; echo "$ACCEPT"; exit 79; }
  if [ "$ATRACK" != body ]; then
    place "$(printf '%s' "$ISSUE" | jq -r '.url')" "$TARGET" || { RC=$?; echo "$ACCEPT"; [ "$RC" -eq 79 ] && exit 79; echo "warn: #${ACCEPT} not placed in '${TARGET}'" >&2; exit 71; }
  fi
  state success "$ACCEPT" || exit $?
  [ "$ATRACK" != body ] || echo "next: #${ACCEPT} is a body of work: grill it with /north-star (iteration.md, step a)" >&2
  echo "$ACCEPT"; exit 0
fi

# --- adopt ------------------------------------------------------------------
if [ -n "$ADOPT" ]; then
  if [ "$YES" -ne 1 ]; then echo "would-adopt|#${ADOPT}|${TYPE}|${HOLD}"; exit 0; fi
  URL=$(python3 "$GITHUB_READ" --kind scalar -- issue view "$ADOPT" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --json url --jq .url) || exit $?
  BOARD=$(python3 "$GITHUB_READ" --kind items -- project item-list "$NUMBER" --owner "$OWNER" --format json --limit 500) || exit $?
  # A matching issue number without its repository URL cannot prove whether
  # this is already our card. Preserve potentially live work until reconciled.
  AMBIGUOUS=$(printf '%s' "$BOARD" | jq -r --argjson n "$ADOPT" '[.items[] | select(.content.type == "Issue" and .content.number == $n and ((.content.url // "") == ""))] | length') || exit 70
  if [ "$AMBIGUOUS" != 0 ]; then
    python3 "$GITHUB_READ" --halt "Board identity is incomplete for issue #${ADOPT}; reconcile before adoption"
    exit 79
  fi
  # Never reset a card already on the board to Backlog, especially live work.
  ON_BOARD=$(printf '%s' "$BOARD" | jq -r --arg u "$URL" '[.items[] | select(.content.url == $u)] | length') || exit 70
  if [ "$ON_BOARD" != 0 ]; then echo "$ADOPT"; exit 0; fi
  state begin "$ADOPT" || exit $?
  tag "$ADOPT" "$TYPE" "source:collect" ${EXTRA_LABELS[@]+"${EXTRA_LABELS[@]}"} || { RC=$?; echo "$ADOPT"; exit "$RC"; }
  place "$URL" || { RC=$?; echo "$ADOPT"; [ "$RC" -eq 79 ] && exit 79; echo "warn: #${ADOPT} not placed in '${HOLD}'" >&2; exit 71; }
  state success "$ADOPT" || exit $?
  echo "$ADOPT"; exit 0
fi

# --- dedupe -----------------------------------------------------------------
# Repo-wide, any label, any state. An open hit is a duplicate; a closed-only hit
# is a recurrence — file again, but name the issue that claimed the fix.
# Exact match on a whitespace-delimited token: `err|sentry|441` must not hit `err|sentry|4411`.
ISSUES_JSON=$(python3 "$GITHUB_READ" --issue-history "$REPO_NAME") || exit $?
HITS=$(printf '%s' "$ISSUES_JSON" | jq -r --arg fp "$FP" '[.[] | select(any(.body | splits("\\s+"); . == $fp))] | sort_by(.state != "OPEN") | map("\(.number) \(.state) \(if (.body | contains("<!-- super-collect-rejected:")) then "rejected" else "-" end)") | .[]') || exit 70

OPEN_HIT=$(echo "$HITS" | awk '$2=="OPEN"{print $1; exit}')
CLOSED_HIT=$(echo "$HITS" | awk '$2!="OPEN" && $1!=""{print $1; exit}')
REJECTED_HIT=$(echo "$HITS" | awk '$2!="OPEN" && $3=="rejected"{print $1; exit}')

# The owner rejected this item once: never file it again. The reason is on that issue.
if [ -z "$OPEN_HIT" ] && [ -n "$REJECTED_HIT" ]; then
  if [ "$YES" -ne 1 ]; then echo "rejected|#${REJECTED_HIT}|${TYPE}|${TITLE}"; exit 0; fi
  echo "$REJECTED_HIT"; exit 0
fi

if [ -n "$OPEN_HIT" ]; then
  if [ "$YES" -ne 1 ]; then echo "duplicate|#${OPEN_HIT}|${TYPE}|${TITLE}"; exit 0; fi
  python3 "$GITHUB_READ" --check || { RC=$?; echo "$OPEN_HIT"; exit "$RC"; }
  SEEN=$(state seen "$OPEN_HIT") || exit $?
  if [ "$SEEN" = unchanged ]; then echo "$OPEN_HIT"; exit 0; fi
  state begin "$OPEN_HIT" || exit $?
  gh issue comment "$OPEN_HIT" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --body "Seen again by super-collect (${SOURCE}).

$(cat "$BODY_FILE")" >/dev/null 2>&1 || { python3 "$GITHUB_READ" --halt "Collector comment outcome unknown for #${OPEN_HIT}; reconcile before retrying"; echo "$OPEN_HIT"; exit 79; }
  state success "$OPEN_HIT" || exit $?
  echo "$OPEN_HIT"; exit 0
fi

if [ "$YES" -ne 1 ]; then
  # A bug's full shape is the QA filer's check; run it now so the plan never says
  # would-file for a body --yes would refuse with 66.
  if [ "$TYPE" = bug ]; then "$BIN/super-qa-file-bug.sh" --title "$TITLE" --body-file "$BODY_FILE" --check-body || exit $?; fi
  if [ -n "$CLOSED_HIT" ]; then echo "recurrence|#${CLOSED_HIT}|${TYPE}|${TITLE}|${COLUMN}"
  else echo "would-file|${TYPE}|${TITLE}|${COLUMN}"; fi
  exit 0
fi

state begin || exit $?

# --- compose + dispatch -----------------------------------------------------
BODY_TMP=$(mktemp)
trap 'rm -f "$BODY_TMP"' EXIT
{
  cat "$BODY_FILE"
  if [ -n "$CLOSED_HIT" ]; then
    echo; echo "> Recurrence: this fingerprint was last filed as #${CLOSED_HIT}, which is closed."
  fi
  echo; echo "<!-- super-collect-fingerprint: ${FP} -->"
  echo "<!-- super-collect-source: ${SOURCE} -->"
} > "$BODY_TMP"

ERR=$(mktemp)
case "$TYPE" in
  refactor)
    OUT=$("$BIN/super-review-file-refactor.sh" --config "$CONFIG" --title "$TITLE" \
      --body-file "$BODY_TMP" --fingerprint "$FP" --column "$COLUMN" ${AREA:+--area "$AREA"} 2>"$ERR"); RC=$? ;;
  *)
    case "$TYPE" in bug) KIND=bug; WEAK=0 ;; feature) KIND=feature; WEAK=1 ;; fix) KIND=tech-debt; WEAK=1 ;; esac
    OUT=$(SUPER_QA_PROJECT_OWNER="$OWNER" SUPER_QA_PROJECT_TITLE="$PTITLE" \
      SUPER_QA_TARGET_OPTION_NAME="$COLUMN" SUPER_QA_ALLOW_WEAK_BODY="$WEAK" SUPER_QA_REPO="$REPO_NAME" \
      "$BIN/super-qa-file-bug.sh" --title "$TITLE" --body-file "$BODY_TMP" --kind "$KIND" \
      --priority "$PRIORITY" --fingerprint "$FP" ${AREA:+--area "$AREA"} 2>"$ERR"); RC=$? ;;
esac
cat "$ERR" >&2; rm -f "$ERR"
N=$(echo "$OUT" | tail -1)
# A child may have created the issue before a required placement read failed.
# Preserve its identity without tagging or making further writes after the halt.
if [ "$RC" -eq 79 ]; then [ -z "$N" ] || echo "$N"; exit 79; fi
if [ "$RC" -eq 64 ] || [ "$RC" -eq 66 ]; then state known-failure || true; fi
case "$N" in ''|*[!0-9]*) die "filer failed (exit ${RC})" "$([ "$RC" -ne 0 ] && echo "$RC" || echo 70)" ;; esac
if [ "$RC" -ne 0 ]; then
  python3 "$GITHUB_READ" --halt "Collector filing/placement incomplete for #${N}; reconcile before retrying"
  echo "$N"; exit 79
fi
tag "$N" "source:collect" "collect:${SOURCE}" ${EXTRA_LABELS[@]+"${EXTRA_LABELS[@]}"} || { RC=$?; echo "$N"; exit "$RC"; }
if [ "$RC" -eq 0 ]; then state success "$N" || exit $?; fi
echo "$N"
exit "$RC"
