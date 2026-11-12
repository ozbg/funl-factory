#!/usr/bin/env python3
"""PreToolUse decider: lane commands run without a prompt; the gates stay shut.

A permission rule matches the literal command text, so a lane that writes
`.claude/bin/x` instead of `bash .claude/bin/x`, an absolute path, `cd <worktree> &&`,
or a regex `sed -n` through the `.claude/skills` symlink gets a prompt nobody is there
to answer overnight. This hook reads the command instead of its spelling:

- allow   every segment of the command (split on && || ; | and newlines, with any
          leading `cd <dir inside the project>`) is on the known-safe list below, and
          every `.claude/bin` / `.claude/hooks` script resolves to the MAIN checkout.
- deny    a direct merge (`gh pr merge`, `gh api …/pulls/N/merge`, the merge GraphQL
          mutations) anywhere in the command: merges go through
          super-board-merge-gate.sh only. A `.claude/bin` script run from a worktree
          copy (a builder could have edited it). A subagent's Edit/Write to
          `.claude/bin`, `.claude/hooks`, `.claude/workflows`, `.agents/{bin,hooks,
          workflows}` or `.claude/settings*.json`, in any checkout.
- nothing anything else: Claude Code's own rules and mode decide, as before.

A hook's allow does not beat a deny from another hook (deny > ask > allow) or a
deny/ask rule in settings, so guard-secrets, guard-protected-push and the other
guards still apply. Python 3 stdlib only; its own errors print nothing.
"""
import glob
import json
import os
import re
import sys

DENY_EDIT_DIRS = (".claude/bin", ".claude/hooks", ".claude/workflows",
                  ".agents/bin", ".agents/hooks", ".agents/workflows")
SAFE_ENV = re.compile(r"^(CI|NODE_ENV|FORCE_COLOR|NO_COLOR|TZ|LANG|LC_[A-Z]+|DEBUG|PORT|"
                      r"PWDEBUG|PLAYWRIGHT_[A-Z_]+|VITEST_[A-Z_]+|GH_PAGER|PAGER|SB_[A-Z_]+)$")
WRAPPERS = {"time", "nohup"}
TMP_ROOTS = ("/tmp", "/private/tmp", "/var/folders", "/private/var/folders")
MERGE_TEXT = re.compile(r"\bgh\b[^\n]*?\bpr\s+merge\b|pulls/[^/\s'\"]+/merge\b|"
                        r"\b(mergePullRequest|enablePullRequestAutoMerge|mergeBranch)\b")
SEARCH_ONLY = {"grep", "egrep", "fgrep", "rg"}
SECRET = re.compile(r"(^|/)\.env(\.(?!example\b)[\w.-]+)?$|(^|/)\.npmrc$|(^|/)id_(rsa|ed25519|ecdsa)|\.pem$")

READ_TOOLS = {"ls", "cat", "head", "tail", "wc", "stat", "file", "basename", "dirname",
              "realpath", "pwd", "diff", "uniq", "cut", "tr", "nl", "tac", "comm", "column"}
PATTERN_FIRST = {"grep", "egrep", "fgrep", "rg", "jq"}
NO_PATH_TOOLS = {"echo", "printf", "true", "false", "test", "[", "date", "sleep", "which"}
NPX_TOOLS = {"playwright", "vitest", "jest", "tsc", "eslint", "prettier", "vite"}
GIT_READ = {"status", "diff", "log", "show", "rev-parse", "merge-base", "ls-files", "ls-remote",
            "blame", "rev-list", "cat-file", "describe", "show-ref", "grep", "shortlog",
            "for-each-ref", "name-rev", "fetch"}
GIT_WRITE = {"add", "commit", "pull", "checkout", "switch", "restore", "merge", "rebase",
             "cherry-pick", "mv", "rm"}
GH_ALLOW = {
    "pr": {"view", "diff", "checks", "comment", "create", "ready", "edit", "list", "status"},
    "issue": {"view", "list", "edit", "comment", "create", "close"},
    "project": {"item-edit", "item-list", "item-add", "view", "field-list", "list"},
    "label": {"create", "list"},
    "auth": {"status"},
    "run": {"list", "view"},
    "repo": {"view"},
}
SAFE_MUTATIONS = {"resolveReviewThread", "unresolveReviewThread", "addComment", "updateIssueComment",
                  "addPullRequestReviewThreadReply", "addPullRequestReviewComment",
                  "updateProjectV2ItemFieldValue", "addProjectV2ItemById", "addLabelsToLabelable",
                  "removeLabelsFromLabelable", "markPullRequestReadyForReview", "minimizeComment"}
REST_WRITE = re.compile(r"^/?repos/[^/]+/[^/]+/(issues/\d+/comments|issues/comments/\d+|"
                        r"pulls/\d+/comments(/\d+/replies)?|pulls/comments/\d+|pulls/\d+/reviews|"
                        r"issues/\d+/labels|labels)$")


class Unsafe(Exception):
    """The command uses a shape the decider does not judge (falls through)."""


# ---------------------------------------------------------------- parsing
def split(command):
    """[[words], ...] per simple command. Raises Unsafe on substitutions, expansions,
    heredocs, subshells, background jobs and redirects to anything but /dev/null or an fd."""
    segs, words, cur, has, i, n = [], [], "", False, 0, len(command)

    def end_word():
        nonlocal cur, has
        if has:
            words.append(cur)
        cur, has = "", False

    def end_seg():
        nonlocal words
        end_word()
        if words:
            segs.append(words)
        words = []

    while i < n:
        c = command[i]
        if c == "'":
            j = command.find("'", i + 1)
            if j < 0:
                raise Unsafe("unterminated quote")
            cur += command[i + 1:j]
            has, i = True, j + 1
            continue
        if c == '"':
            i += 1
            while i < n and command[i] != '"':
                ch = command[i]
                if ch in "$`":
                    raise Unsafe("expansion in double quotes")
                if ch == "\\" and i + 1 < n:
                    i += 1
                    ch = command[i]
                cur += ch
                i += 1
            if i >= n:
                raise Unsafe("unterminated quote")
            has, i = True, i + 1
            continue
        if c == "\\":
            if i + 1 < n and command[i + 1] == "\n":
                i += 2
                continue
            if i + 1 < n:
                cur += command[i + 1]
                has, i = True, i + 2
                continue
            raise Unsafe("trailing backslash")
        if c in "$`(){}*?[":
            if c == "[" and not has and command[i:i + 2] == "[ ":
                cur, has, i = "[", True, i + 1
                continue
            raise Unsafe("expansion, glob or grouping")
        if c in "<>" or (c == "&" and command[i:i + 2] == "&>"):
            if c == "<":
                raise Unsafe("input redirect or heredoc")
            fd = cur if has and cur.isdigit() else None
            if fd is not None:
                cur, has = "", False
            else:
                end_word()
            op = command[i:i + 2]
            i += 2 if op in (">>", ">&", "&>") else 1
            while i < n and command[i] in " \t":
                i += 1
            j = i
            while j < n and command[j] not in " \t\n;|&<>":
                j += 1
            target = command[i:j]
            if not (target == "/dev/null" or (op == ">&" and target.isdigit())):
                raise Unsafe("redirect to a file")
            i = j
            continue
        if c in " \t":
            end_word()
            i += 1
            continue
        if c == "\n" or c == ";":
            end_seg()
            i += 1
            continue
        if c == "|":
            end_seg()
            i += 2 if command[i:i + 2] in ("||", "|&") else 1
            continue
        if c == "&":
            if command[i:i + 2] == "&&":
                end_seg()
                i += 2
                continue
            raise Unsafe("background job")
        if c == "#" and not has:
            j = command.find("\n", i)
            i = n if j < 0 else j  # a comment runs to the end of its line only
            continue
        cur += c
        has = True
        i += 1
    end_seg()
    if command.rstrip().endswith(("&&", "||", "|")):
        raise Unsafe("dangling operator")
    return segs


# ---------------------------------------------------------------- context
def main_root(cwd):
    base = os.environ.get("CLAUDE_PROJECT_DIR") or cwd
    marker = os.sep + os.path.join(".claude", "worktrees") + os.sep
    at = base.find(marker)
    return os.path.realpath(base if at < 0 else base[:at])


def inside(path, root):
    p = os.path.realpath(path)
    return p == root or p.startswith(root + os.sep)


class Ctx:
    def __init__(self, cwd, root, agent=False):
        self.cwd, self.root, self.agent = cwd, root, agent
        self.repos, self.protected = set(), {"main", "master"}
        for f in glob.glob(os.path.join(root, ".claude", "super-board", "configs", "*.json")):
            try:
                c = json.load(open(f))
            except (OSError, ValueError):
                continue
            if isinstance(c.get("repo"), str):
                self.repos.add(c["repo"].lower())
            if isinstance(c.get("base_branch"), str):
                self.protected.add(c["base_branch"])
        self.protected |= {b for b in os.environ.get("SB_PROTECTED_BRANCHES", "").split(",") if b}

    def path(self, p):
        return os.path.normpath(os.path.join(self.cwd, os.path.expanduser(p)))

    def contained(self, p):
        r = os.path.realpath(self.path(p))
        tmp = [os.path.realpath(os.environ.get("TMPDIR", "/tmp"))] + list(TMP_ROOTS)
        return inside(r, self.root) or r == "/dev/null" or any(inside(r, t) for t in tmp)


# ---------------------------------------------------------------- judges
ALLOW, DENY, SKIP = "allow", "deny", None


def strip_prefix(words):
    while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
        if not SAFE_ENV.match(words[0].split("=", 1)[0]):
            return None
        words = words[1:]
    while words and words[0] in WRAPPERS:
        words = words[1:]
    if words and words[0] == "timeout" and len(words) > 2 and re.match(r"^\d+[smh]?$", words[1]):
        words = words[2:]
    return words


def script_target(words):
    """(path, rest) when the segment runs a .claude/bin or .claude/hooks script, else None."""
    prog = words[0]
    if prog in ("bash", "sh", "python3", "python", "source", ".") and len(words) > 1:
        if words[1].startswith("-"):
            return None
        cand = words[1]
    else:
        cand = prog
    if re.search(r"(^|/)\.claude/(bin|hooks)/[^/]+$", cand):
        return cand
    return None


def judge_script(cand, ctx):
    full = ctx.path(cand)
    kind = os.path.basename(os.path.dirname(full))
    want = os.path.join(ctx.root, ".claude", kind)
    if os.path.realpath(os.path.dirname(full)) != os.path.realpath(want):
        return DENY, ("Blocked: %s is not the main checkout's copy (%s). A worktree copy could "
                      "have been edited by a builder. Run it from the main checkout, as written in "
                      "the lane docs: `bash .claude/bin/%s …` with no `cd` in front, or by its "
                      "absolute path `bash %s …` when your shell sits in a worktree."
                      % (full, want, os.path.basename(full), os.path.join(want, os.path.basename(full))))
    if not os.path.isfile(full):
        return SKIP, None
    return ALLOW, None


def paths_ok(args, ctx, skip_first=False):
    seen_pattern = not skip_first
    for a in args:
        if a == "--":
            continue
        if a.startswith("-"):
            if "=" in a and ("/" in a.split("=", 1)[1]):
                if not ctx.contained(a.split("=", 1)[1]):
                    return False
            continue
        if not seen_pattern:
            seen_pattern = True
            continue
        if SECRET.search(a):
            return False
        if ("/" in a or a.startswith("~") or a in (".", "..")) and not ctx.contained(a):
            return False
    return True


SED_ADDR = r"(\d+|\$|/[^/\n]*/)"
SED_CMD = re.compile(r"^%s(,%s)?p$|^\d+q$" % (SED_ADDR, SED_ADDR))


def judge_sed(args, ctx):
    script, files, quiet = None, [], False
    it = iter(args)
    for a in it:
        if a in ("-n", "--quiet", "--silent"):
            quiet = True
        elif a in ("-E", "-r"):
            continue
        elif a == "-e":
            if script is not None:
                return SKIP
            script = next(it, None)
        elif a.startswith("-"):
            return SKIP  # -i, -f, -s, … are not judged here
        elif script is None:
            script = a
        else:
            files.append(a)
    if not quiet or script is None:
        return SKIP
    parts = [p.strip() for p in script.split(";") if p.strip()]
    if not parts or not all(SED_CMD.match(p) for p in parts):
        return SKIP
    if not paths_ok(files, ctx):
        return SKIP
    linked = [f for f in files if os.path.realpath(ctx.path(f)) != os.path.abspath(ctx.path(f))]
    if "/" in script and linked:
        # Claude Code treats a regex-address sed on a path through a symlink (.claude/skills →
        # .agents/skills) as a possible write there and prompts, whatever a hook says.
        return DENY if ctx.agent else SKIP
    return ALLOW


def judge_find(args, ctx):
    bad = {"-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf",
           "-fls", "-files0-from"}
    if any(a in bad for a in args):
        return SKIP
    roots = []
    for a in args:
        if a.startswith("-") or a in ("!", "(", ")"):
            break
        roots.append(a)
    return ALLOW if paths_ok(roots, ctx) else SKIP


def judge_git(args, ctx):
    gitdir = ctx.cwd
    while args and args[0].startswith("-"):
        if args[0] == "-C" and len(args) > 1:
            gitdir = ctx.path(args[1])
            args = args[2:]
        elif args[0] == "--no-pager":
            args = args[1:]
        else:
            return SKIP  # -c, --git-dir, --exec-path … can run arbitrary code
    if not args or not inside(gitdir, ctx.root):
        return SKIP
    sub, rest = args[0], args[1:]
    if sub in GIT_READ:
        return ALLOW
    # Writes happen in a lane's own worktree, never in the main checkout the run lives in.
    in_wt = inside(gitdir, os.path.join(ctx.root, ".claude", "worktrees"))
    if sub in GIT_WRITE:
        return ALLOW if in_wt else SKIP
    if sub == "branch":
        return SKIP if any(a in ("-d", "-D", "--delete", "-m", "-M", "-f", "--force", "-c", "-C")
                           for a in rest) else ALLOW
    if sub == "config":
        return ALLOW if rest and rest[0] in ("--get", "--get-all", "--list", "-l") else SKIP
    if sub == "reset":
        return SKIP if "--hard" in rest or not in_wt else ALLOW
    if sub == "worktree":
        return ALLOW if rest and rest[0] in ("list", "add", "prune") else SKIP
    if sub == "push":
        return judge_push(rest, ctx) if in_wt else SKIP
    return SKIP


def judge_push(rest, ctx):
    pos = []
    for a in rest:
        if a in ("--all", "--mirror", "--delete", "-d", "--tags", "--prune"):
            return SKIP
        if a.startswith("-"):
            continue
        pos.append(a)
    if len(pos) < 2:
        return SKIP  # bare `git push` pushes whatever is checked out
    for ref in pos[1:]:
        dst = ref.lstrip("+").split(":")[-1]
        dst = re.sub(r"^refs/heads/", "", dst)
        if not dst or dst == "HEAD" or dst in ctx.protected:
            return SKIP
    return ALLOW


def gh_positionals(args):
    pos, it = [], iter(args)
    for a in it:
        if a in ("-R", "--repo"):
            next(it, None)
        elif a.startswith("-"):
            continue
        else:
            pos.append(a)
    return pos


def gh_repo_ok(args, ctx):
    for k, a in enumerate(args):
        val = None
        if a in ("-R", "--repo") and k + 1 < len(args):
            val = args[k + 1]
        elif a.startswith("--repo="):
            val = a.split("=", 1)[1]
        if val is not None and ctx.repos and val.lower() not in ctx.repos:
            return False
    return True


def judge_gh_api(args, ctx):
    method, fields, endpoint, query = "GET", False, None, ""
    it = iter(args)
    for a in it:
        if a in ("-X", "--method"):
            method = (next(it, "") or "").upper()
        elif a.startswith("--method="):
            method = a.split("=", 1)[1].upper()
        elif a in ("-f", "-F", "--field", "--raw-field"):
            fields = True
            v = next(it, "") or ""
            if v.startswith("query="):
                query = v[6:]
            elif "=@" in v:
                return SKIP  # body from a file: not judged here
        elif a in ("--input",):
            return SKIP
        elif a in ("-H", "--header", "--jq", "-q", "-t", "--template", "--cache", "--hostname"):
            next(it, None)
        elif a.startswith("-"):
            continue
        elif endpoint is None:
            endpoint = a
    if endpoint is None:
        return SKIP
    if endpoint == "graphql":
        if not re.search(r"\bmutation\b", query):
            return ALLOW
        names = set(re.findall(r"\b([a-z][A-Za-z0-9]*)\s*\(", query)) - {"mutation", "query"}
        return ALLOW if names and names <= SAFE_MUTATIONS else SKIP
    if not fields and method == "GET":
        return ALLOW
    if method in ("GET", "POST", "PATCH") and REST_WRITE.match(endpoint.split("?")[0]):
        return ALLOW
    return SKIP


def judge_gh(args, ctx):
    pos = gh_positionals(args)
    if not pos:
        return SKIP, None
    if pos[:2] == ["pr", "merge"]:
        return DENY, MERGE_REASON
    if pos[0] == "api":
        rest = args[args.index("api") + 1:]
        if any(re.search(r"pulls/[^/]+/merge\b", a) for a in rest):
            return DENY, MERGE_REASON
        return judge_gh_api(rest, ctx), None
    if not gh_repo_ok(args, ctx):
        return SKIP, None
    for k, a in enumerate(args):  # a file gh uploads must be this project's
        if a in ("--body-file", "-F") and (k + 1 >= len(args) or args[k + 1] == "-"
                                           or not ctx.contained(args[k + 1])):
            return SKIP, None
        if a.startswith("--body-file=") and not ctx.contained(a.split("=", 1)[1]):
            return SKIP, None
    if len(pos) >= 2 and pos[1] in GH_ALLOW.get(pos[0], ()):
        return ALLOW, None
    return SKIP, None


def judge_runner(prog, args, ctx):
    def dir_ok(flag_vals):
        return all(inside(ctx.path(v), ctx.root) for v in flag_vals)

    if prog == "npx":
        a = [x for x in args if x not in ("--no-install", "--yes", "-y")]
        return ALLOW if a and a[0] in NPX_TOOLS else SKIP
    if prog in ("npm", "pnpm", "yarn", "bun"):
        dirs, rest, it = [], [], iter(args)
        for a in it:
            if a in ("--prefix", "-C", "--dir", "--cwd"):
                dirs.append(next(it, "") or "")
            elif a.startswith(("--prefix=", "--dir=", "--cwd=")):
                dirs.append(a.split("=", 1)[1])
            else:
                rest.append(a)
        if not dir_ok(dirs) or not rest:
            return SKIP
        sub, tail = rest[0], rest[1:]
        if sub in ("test", "t", "run", "run-script", "audit"):
            return ALLOW
        if sub in ("ci", "install", "i") and not [t for t in tail if not t.startswith("-")]:
            return ALLOW  # no package names: install only what the lockfile names
        if sub == "exec" and tail and tail[0] in NPX_TOOLS:
            return ALLOW
        return SKIP
    if prog == "node":
        return ALLOW if args[:1] == ["--check"] and paths_ok(args[1:], ctx) else SKIP
    if prog == "pytest":
        return ALLOW
    if prog in ("python3", "python") and args[:2] == ["-m", "pytest"]:
        return ALLOW
    if prog == "make" and args[:1] == ["test"]:
        return ALLOW
    if prog in ("go", "cargo") and args[:1] == ["test"]:
        return ALLOW
    return SKIP


SED_LINK_REASON = ("Blocked for lanes: `sed` with a /regex/ address on a file reached through a "
                   "symlink (.claude/skills → .agents/skills) asks for a person every time. Read the "
                   "file with the Read tool and find the section there.")
LOCAL_URL = re.compile(r"^(https?://)?(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(/\S*)?$")
CURL_SAFE_FLAGS = {"-s", "-S", "-sS", "-f", "-fsS", "-sf", "-L", "-I", "-i", "-v", "--silent",
                   "--show-error", "--fail", "--head", "--include", "-k"}


def judge_curl(args):
    """A QA smoke check against the app's own dev server: localhost only, nothing written or sent."""
    it, urls = iter(args), []
    for a in it:
        if a in CURL_SAFE_FLAGS:
            continue
        if a in ("-w", "--write-out", "-m", "--max-time", "--connect-timeout", "--retry"):
            next(it, None)
            continue
        if a.startswith("-"):
            return SKIP  # -o, -d, -T, -K, -X … are not judged here
        urls.append(a)
    return ALLOW if urls and all(LOCAL_URL.match(u) for u in urls) else SKIP


def judge_segment(words, ctx):
    """(decision, reason). Updates ctx.cwd for `cd`."""
    words = strip_prefix(words)
    if not words:
        return SKIP, None
    prog, args = words[0], words[1:]
    if prog == "cd":
        if len(args) != 1 or not inside(ctx.path(args[0]), ctx.root):
            return SKIP, None
        ctx.cwd = ctx.path(args[0])
        return ALLOW, None
    cand = script_target(words)
    if cand:
        return judge_script(cand, ctx)
    if any(SECRET.search(a) for a in args):
        return SKIP, None
    if prog == "git":
        return judge_git(args, ctx), None
    if prog == "gh":
        return judge_gh(args, ctx)
    if prog in NO_PATH_TOOLS:
        return ALLOW, None
    if not inside(ctx.cwd, ctx.root):
        return SKIP, None  # relative paths would land outside the project
    if prog == "sed":
        d = judge_sed(args, ctx)
        return d, (SED_LINK_REASON if d == DENY else None)
    if prog == "find":
        return judge_find(args, ctx), None
    if prog in READ_TOOLS:
        return (ALLOW if paths_ok(args, ctx) else SKIP), None
    if prog in PATTERN_FIRST:
        explicit = any(a in ("-e", "-f", "--regexp", "--file") for a in args)
        return (ALLOW if paths_ok(args, ctx, skip_first=not explicit) else SKIP), None
    if prog == "sort":
        return (SKIP if any(a.startswith(("-o", "--output")) for a in args)
                else ALLOW if paths_ok(args, ctx) else SKIP), None
    if prog == "mkdir":
        return (ALLOW if paths_ok(args, ctx) else SKIP), None
    if prog == "curl":
        return judge_curl(args), None
    return judge_runner(prog, args, ctx), None


MERGE_REASON = ("Blocked: merges go through the merge gate only — "
                "`bash .claude/bin/super-board-merge-gate.sh --config <cfg> --pr <N> --expect-head <sha> …` "
                "(lanes/review.md → \"Merge protocol\"). A direct `gh pr merge`, a REST "
                "`pulls/<N>/merge` call or a merge GraphQL mutation skips merge_policy and migrations.")


INLINE_CODE = re.compile(r"(^|[;&|(]\s*|\n\s*)(python3?|node)\s+(-c\b|-e\b|-\s*(<<|$|\|))")
INLINE_REASON = ("Blocked for lanes: inline code (`python3 -c`, `python3 - <<EOF`, `node -e`) can do "
                 "anything, so it would wait for a person. Read a config value with "
                 "`python3 .claude/bin/super-board-config.py get <key> --config <cfg>`, read files with "
                 "the Read tool, change files with the Edit/Write tools.")


def decide_bash(command, cwd, root, agent=False):
    try:
        segs = split(command)
    except Unsafe:
        segs = None
    if MERGE_TEXT.search(command):
        if segs is None or not all(s and s[0] in SEARCH_ONLY for s in segs):
            return DENY, MERGE_REASON
    if agent and INLINE_CODE.search(command):
        return DENY, INLINE_REASON
    if segs is None or not segs:
        return SKIP, None
    ctx = Ctx(cwd, root, agent)
    verdict = ALLOW
    for words in segs:
        d, reason = judge_segment(words, ctx)
        if d == DENY:
            return DENY, reason
        if d is SKIP:
            verdict = SKIP
    return verdict, ("every segment is on super-board's known-safe list" if verdict else None)


def decide_edit(tool_input, root):
    p = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not isinstance(p, str) or not p:
        return SKIP, None
    for cand in {os.path.normpath(p), os.path.realpath(p)}:
        parts = cand.replace(os.sep, "/")
        hit = any(("/" + d + "/") in parts for d in DENY_EDIT_DIRS) or \
            re.search(r"/\.claude/settings(\.local)?\.json$", parts)
        if hit:
            return DENY, ("Blocked: %s is factory machinery (scripts, hooks, workflows, settings). "
                          "A lane never edits it, in any checkout. If it needs a change, say so in "
                          "your handoff (❌ Not done) and the owner changes it." % p)
    return SKIP, None


def decide(payload):
    tool = payload.get("tool_name")
    ti = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    root = main_root(cwd)
    if tool == "Bash":
        cmd = ti.get("command")
        return decide_bash(cmd, cwd, root, bool(payload.get("agent_id"))) if isinstance(cmd, str) \
            else (SKIP, None)
    if tool in ("Edit", "MultiEdit", "Write", "NotebookEdit") and payload.get("agent_id"):
        return decide_edit(ti, root)
    return SKIP, None


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        decision, reason = decide(payload)
        if decision:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                     "permissionDecision": decision,
                                                     "permissionDecisionReason": reason or ""}}))
    except Exception:
        pass  # a broken decider must never block or approve anything


if __name__ == "__main__":
    main()
