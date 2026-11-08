#!/usr/bin/env bash
# One headless board lane on a non-Claude worker host, chosen by --backend.
# Usage: --backend codex --config f --card '<JSON>' --lane build|qa|review
#        [--<backend>[=model]] [--tier low|medium|high] [--complexity low|medium|high]
# --<backend> (e.g. --codex) is the run owner's explicit opt-in; without it,
# usage fallback may build/test but must never own a review or merge, and the
# board config must say "usage_fallback": "<backend>" (exit 78 otherwise).
# Model: --<backend>=<model>, else <backend>.model, else the backend's LADDERS[tier][complexity]
# when --tier is given (an ungraded card takes the medium cell), else the host's default.
# A missing, unknown or not-yet-built backend exits 64 and names the valid ones.
# Shared here: input checks, readiness/GitHub gates, lane prompt, result schema and
# validation, signal handling. Per host: one class in BACKENDS below.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

def fail(message, code=64):
    print(message, file=sys.stderr)
    sys.exit(code)


class Codex:
    """`codex exec` with a bounded permission profile; the answer lands in --output-last-message."""
    name, label = 'codex', 'Codex'
    # Codex run ladders, the one copy: run tier x card complexity -> model.
    # Mirrors the Claude LADDERS in workflows/super-board-wave.js. gpt-6.1-sol
    # ties gpt-6-astra on DeepSWE v1.1 (75.2% vs 74.1-74.8%) at a fifth of the
    # price, so it carries the default; Astra takes hard cards and --high.
    LADDERS = {
        'low': {'low': 'gpt-6-luna', 'medium': 'gpt-6.1-sol', 'high': 'gpt-6.1-sol'},
        'medium': {'low': 'gpt-6.1-sol', 'medium': 'gpt-6.1-sol', 'high': 'gpt-6-astra'},
        'high': {'low': 'gpt-6-astra', 'medium': 'gpt-6-astra', 'high': 'gpt-6-astra'},
    }
    capture_stdout = False  # Codex logs go to our stderr; the answer is a file

    def command(self, run):
        """(argv, stdin text) for one lane run; run holds root, git_dir, common_dir, model, prompt, schema_path, output."""
        # A custom profile deliberately does NOT extend :workspace, which protects
        # .git as read-only. Explicit git/common-dir grants also cover submodules.
        # https://learn.chatgpt.com/docs/permissions → File access limited to workspace
        filesystem = {':root': 'read', ':slash_tmp': 'write', ':tmpdir': 'write'}
        if run.get('private_home'):
            filesystem.update(self.private_home_denials(run['root']))
        filesystem.update({str(run['root']): 'write', str(run['git_dir']): 'write', str(run['common_dir']): 'write'})
        grants = '{' + ', '.join(json.dumps(key) + '=' + json.dumps(value) for key, value in filesystem.items()) + '}'
        command = ['codex', 'exec', '-C', str(run['root']), '-c', 'approval_policy="never"',
                   '-c', 'default_permissions="super-board-lane"',
                   '-c', 'permissions.super-board-lane.filesystem=' + grants,
                   '-c', 'permissions.super-board-lane.network.enabled=true',
                   '--output-schema', str(run['schema_path']), '--output-last-message', str(run['output']), '-']
        if run['model'] and run['model'].strip():
            command[2:2] = ['-m', run['model']]
        return command, run['prompt']

    @staticmethod
    def private_home_denials(root):
        """codex.private_home: lanes run on a third-party model, so hide the owner's home folder.

        Denying $HOME itself breaks path traversal, so deny every sibling along the path from
        $HOME down to the repo instead (all of home, all of Documents, every other repo). Only the
        repo and the config the tools need are allowed back. Deny before allow."""
        home, repo = Path.home().resolve(), Path(root).resolve()
        grants = {}
        if home in repo.parents:
            chain = [home] + [parent for parent in reversed(repo.parents) if home in parent.parents] + [repo]
            for parent, keep in zip(chain, chain[1:]):
                for entry in parent.iterdir():
                    if entry != keep:
                        grants[str(entry)] = 'none'
        for allowed in [home / '.config' / 'gh', home / '.config' / 'git', home / '.gitconfig']:
            if allowed.exists():
                grants[str(allowed)] = 'read'
        return grants

    def env(self, run):
        """Environment for the lane: the sandbox makes $HOME read-only, so point caches at the temp dir."""
        cache_root = Path(os.environ.get('TMPDIR') or tempfile.gettempdir()) / 'super-board-codex'
        env = dict(os.environ)
        env.setdefault('npm_config_cache', str(cache_root / 'npm-cache'))
        env.setdefault('npm_config_store_dir', str(cache_root / 'pnpm-store'))
        # One browser download per machine, not one per lane.
        env.setdefault('PLAYWRIGHT_BROWSERS_PATH', str(cache_root / 'ms-playwright'))
        # Evidence logs get committed; keep ANSI colour codes out of them.
        env['NO_COLOR'] = '1'
        env['FORCE_COLOR'] = '0'
        # The keychain sits in the (possibly blocked) home folder, so hand gh the token it already uses.
        if not env.get('GH_TOKEN'):
            token = subprocess.run(['gh', 'auth', 'token'], capture_output=True, text=True)
            if token.returncode == 0 and token.stdout.strip():
                env['GH_TOKEN'] = token.stdout.strip()
        return env

    @staticmethod
    def session_id(line):
        found = re.match(r'session id:\s*(\S+)', line.strip())
        return found.group(1) if found else None

    def resume_command(self, run, command, session):
        """argv that resumes `session` with the same sandbox and schema (the model's context is kept)."""
        resume = ['codex', 'exec', 'resume'] + command[command.index('-c'):command.index('--output-schema')]
        resume += ['--output-schema', str(run['schema_path']), '-o', str(run['output']), session, '-']
        if run['model'] and run['model'].strip():
            resume[3:3] = ['-m', run['model']]
        return resume

    def final_message(self, run, stdout):
        """The host's last message, which must be the lane result JSON."""
        return run['output'].read_text()


# One entry per worker host. A new host is one more class with the same members:
# name, label, LADDERS (or None), capture_stdout (True hands stdout to final_message),
# command(run) and final_message(run, stdout). Everything else in this file is shared.
BACKENDS = {backend.name: backend for backend in [Codex()]}

raw = sys.argv[2:]
choice = None
for index, arg in enumerate(raw):
    if arg == '--backend' or arg.startswith('--backend='):
        choice = arg.partition('=')[2] if '=' in arg else (raw[index + 1] if index + 1 < len(raw) else '')
        del raw[index:index + (1 if '=' in arg else 2)]
        break
if choice not in BACKENDS:
    fail(('missing --backend' if choice is None else f'unknown or not-yet-built backend {choice!r}')
         + '; valid backends: ' + ', '.join(BACKENDS))
backend = BACKENDS[choice]
flag = '--' + backend.name

parser = argparse.ArgumentParser(description=f'Run one {backend.label} board lane (no Claude sub-agents).')
parser.add_argument('--config', required=True)
parser.add_argument('--card', required=True, help='card JSON or a JSON file')
parser.add_argument('--lane', required=True, choices=['build', 'qa', 'review'])
parser.add_argument('--tier', choices=['low', 'medium', 'high'], help='run ladder (--low / default / --high)')
parser.add_argument('--complexity', choices=['low', 'medium', 'high'], help="router's grade for this card")
explicit = False
model = None
rest = []
for arg in raw:
    if arg == flag:
        explicit = True
    elif arg.startswith(flag + '='):
        explicit = True
        model = arg.partition('=')[2]
        if not model.strip():
            fail(f'{flag}=<model> requires a non-empty model')
    else:
        rest.append(arg)
args = parser.parse_args(rest)
script_path = Path(sys.argv[1]).resolve()
if args.lane == 'review' and not explicit:
    fail(f'{backend.label} review refused: run must be started with explicit {flag}; usage fallback cannot review.', 78)
try:
    config_path = Path(args.config).resolve()
    config = json.loads(config_path.read_text())
    card = json.loads(args.card if args.card.lstrip().startswith('{') else Path(args.card).read_text())
    if not isinstance(config, dict) or not isinstance(card, dict):
        raise ValueError('config/card must be objects')
    if type(card.get('number')) is not int or card['number'] < 1 or not isinstance(card.get('status'), str):
        raise ValueError('card needs a positive issue number and status')
    configured = config.get(backend.name, {}).get('model') if config.get(backend.name) else None
    # <backend>.models pins a model per lane ({"build": ..., "qa": ..., "review": ...}); it wins over <backend>.model.
    per_lane = (config.get(backend.name) or {}).get('models') or {}
    if not isinstance(per_lane, dict):
        raise ValueError(f'{backend.name}.models must be an object of lane -> model')
    if isinstance(per_lane.get(args.lane), str) and per_lane[args.lane].strip():
        configured = per_lane[args.lane]
    if configured is not None and not isinstance(configured, str):
        raise ValueError(f'{backend.name}.model must be a string')
    model = model if model is not None else (configured if configured and configured.strip() else None)
    if model is None and args.tier and backend.LADDERS:
        model = backend.LADDERS[args.tier][args.complexity or 'medium']
except (OSError, ValueError, AttributeError) as error:
    fail(f'Invalid {backend.label} lane input: {error}')
# Without --<backend> this is the usage fallback, and that is opt-in per board.
if not explicit and config.get('usage_fallback', 'none') != backend.name:
    fail(f'{backend.label} fallback refused: usage_fallback is not "{backend.name}" in {config_path}; pass {flag} for an explicit {backend.label} run.', 78)

column = card['status']
def result(status, detail):
    print(json.dumps({'status': status, 'column': column, 'detail': detail}))

readiness = script_path.with_name('super-board-verification-ready.py')
def require_verification_ready():
    if subprocess.run([sys.executable, str(readiness), '--config', str(config_path)]).returncode:
        result('halted', 'verification-readiness: repair verify_commands; preserve claims, worktrees and card state, then restart explicitly')
        sys.exit(9)
require_verification_ready()

def git_path(option):
    return Path(subprocess.check_output(['git', 'rev-parse', option], text=True).strip()).resolve()

try:
    root = git_path('--show-toplevel')
    git_dir = git_path('--git-dir')
    common_dir = git_path('--git-common-dir')
except subprocess.CalledProcessError:
    fail(f'{backend.label} lane must start inside the target git repository')
os.chdir(root)
helper = script_path.with_name('super-board-github-read.py')
if not helper.exists() or subprocess.run([sys.executable, str(helper), '--check']).returncode:
    result('halted', 'required GitHub reads halted or helper missing; preserve claims and worktrees')
    sys.exit(79)

resolver_path = script_path.with_name('super-board-skills-ready.py')
try:
    spec = importlib.util.spec_from_file_location('skills_ready', resolver_path)
    resolver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(resolver)
    resolver.hydrate([card], root)
    skills = resolver.report(root, backend.name, [card], lane=args.lane,
                             home=os.environ.get('SUPER_BOARD_SKILLS_HOME'), catalog=os.environ.get('SUPER_BOARD_SKILLS_CATALOG'))
except SystemExit as error:
    result('halted', 'required GitHub reads halted while hydrating skills; preserve claims and worktrees')
    sys.exit(error.code)
except (OSError, ValueError, TypeError, KeyError) as error:
    result('halted', 'skills-readiness: ' + str(error))
    sys.exit(64)
if not skills['ready']:
    result('halted', 'skills-readiness: missing ' + ', '.join(dict.fromkeys(e['name'] for e in skills['entries'] if e['status'] == 'missing')))
    sys.exit(10)

skill = {'build': 'super-build', 'qa': 'super-qa', 'review': 'super-review'}[args.lane]
section = {'build': 'Builder', 'qa': 'Tester', 'review': 'Reviewer'}[args.lane]
prompt = f'''Run {skill} for issue #{card['number']} as a {backend.label} lane worker.
First operation: recheck .claude/bin/super-board-skills-ready.py --root {root} --host {backend.name} --cards - --lane {args.lane} with the Card JSON below as a one-element stdin array, before worktree creation, classification or lifecycle writes. Exit 10 means status=halted, detail=skills-readiness:, preserve all state. Load resolved_path files and only declared fallback IDs from the report. Before activating any conditional helper, repeat with --require <exact-name>.
Resolved skill report: {json.dumps(skills)}
Config: {config_path}
Card: {json.dumps(card)}
If docs/super-board/PROJECT.md or docs/agents/coding-standards.md exist, read them first; builders follow the standards and reviewers report a broken rule as a Standards finding. Never read anything outside this repository, and test with made-up fixture data only. Read .claude/skills/{skill}/SKILL.md and .claude/skills/super-board/references/run.md → {section} lifecycle; follow all its board, branch, worktree, comments, test and merge requirements.
GitHub: before your first GitHub call read .claude/skills/super-board/references/github-cheatsheet.md and copy its commands exactly; a GitHub command not on it is a mistake. Never run the read helper's --resume or touch .claude/super-board/github-halt*.json: only the owner unpauses a run. You report findings; scope rulings, AC changes and size-cap changes belong to the orchestrator.
Sandbox: your home folder is read-only. npm_config_cache and npm_config_store_dir already point at writable $TMPDIR folders; never override them. Scratch files go in $TMPDIR, never inside the worktree. Commit and push your work before every exit.
Follow-up tickets: pass --title as a plain subject; the filing script adds the emoji and [type] prefix itself.
Source .claude/bin/super-board-gh-guard.sh and use its quota checks (sb_gh_guard_check); never call the read helper with --kind quota or --jq on rate_limit yourself. Required GitHub reads go through .claude/bin/super-board-github-read.py; a read that misses its --kind shape exits 64 for that call only and prints the valid form, so fix the read. A --kind diff read needs --meta <file> from a --kind metadata read first. Check --check before new writes, migrations and merges; exit 79 means status=halted, no more GitHub calls, preserve claims/worktree/card/approval. Never retry a mutation.
Use .claude/bin/super-board-card.sh for board reads/moves and .claude/bin/super-board-pr-body.sh for owned PR blocks; follow writing-standard.md and pr-author-notes.md.
Use your own worktree under .claude/worktrees/; never edit the main checkout. Any extra checkout (for example a base-branch comparison) also goes under .claude/worktrees/scratch-<card>-<name> and is removed with git worktree remove before you exit; never create worktrees in /tmp or $TMPDIR. Clean up on ordinary exit, preserve work on halt/interruption.
{backend.label} adaptation: do not launch Claude or other sub-agents. Perform preflight, classification, independent review and truth-check duties inline. This changes the execution host, never the evidence requirements, confidence threshold or merge policy.
Return JSON: status=advanced|bounced|blocked|human-gate|failed|halted; column=current board column; detail=one line; prUrl/branch when known, otherwise null; priorFindings=review counts or null. A non-advanced exit ends this card's lane chain. On merge-gate exit 9, return status=halted with detail starting exactly "verification-readiness:"; preserve work and never bounce/retry.
Your final message is that JSON object alone: no prose before or after it, no code fence. A summary in prose makes the lane count as failed even when the work succeeded; put any notes in a GitHub comment instead.
'''
if args.lane == 'build':
    prompt += '''Before creating any worktree or changing code, perform run.md's Builder pre-flight inline: call super-board-preflight.sh, judge its candidates semantically, and act on proceed/hold/sequence/skipped. Blind preflight leaves Ready and returns failed. Your own issue branch PR is not a duplicate. Read the issue and all comments; preserve qa/bug/feature labels. Existing docs/ux/tests/refactor/tech-debt rows keep their label chain: classify complexity without adding feature/bug. If truly untyped, classify feature or bug, re-run skills-ready on the proposed labelled card before adding that label, never qa. Then follow the Builder lifecycle.
'''
elif args.lane == 'qa' and card['status'] == 'Ready':
    prompt += 'This qa-labelled Ready card skips Building: move Ready → QA and create the issue branch from the base; test the existing product per run.md qa cards.\n'
elif args.lane == 'review':
    prompt += f'''The owner explicitly chose run {flag}: you may review and own the merge. First load the latest <!-- super-review:report -->; grade prior R-ids fixed/not fixed/no longer applies, bounce any not fixed and edit the same report in place. Form hypotheses from the issue AC and diff before reading the Builder narrative.
Rerun the Tester's tests. When truth_gate triggers, apply super-review's fixed Adversarial mode brief inline in two distinct passes (code-grounder and historian); collect evidence and aggregate confidence against truth_threshold. Over-engineering is Should fix, never Blocker alone and never lowers confidence. Missing evidence fails closed.
Merge ONLY through the unchanged .claude/bin/super-board-merge-gate.sh, pinning the exact head you reviewed at review pass using --expect-head "$HEAD" --config <config> --pr <N> --subject <title> --body-file <msg.md>. Never run bare gh pr merge or bypass the gate. Follow run.md Merge protocol and route every gate exit exactly: 2/5 rebase pass, 3 Blocked, 4 stay Review, 6 fresh review, 7/8 human gate with pinned approval-request; 9 verification-readiness means halt and preserve card/worktree/approval/claims until config repair and explicit restart, never a Build bounce or rebase retry. Respect human_approves_merge and merge_policy. Confirm MERGED <sha>, fetch base and prove merge-base --is-ancestor <sha> origin/<base> before closing issue or moving Done.
'''

counts = {key: {'type': 'integer'} for key in ['fixed', 'notFixed', 'noLongerApplies']}
properties = {
    'status': {'type': 'string', 'enum': ['advanced', 'bounced', 'blocked', 'human-gate', 'failed', 'halted']},
    'column': {'type': 'string'}, 'detail': {'type': 'string'},
    'prUrl': {'type': ['string', 'null']}, 'branch': {'type': ['string', 'null']},
    'priorFindings': {'anyOf': [{'type': 'null'}, {'type': 'object', 'properties': counts,
                      'required': list(counts), 'additionalProperties': False}]},
}
schema = {'type': 'object', 'properties': properties, 'required': list(properties), 'additionalProperties': False}
JSON_TYPES = {'object': dict, 'array': list, 'string': str, 'null': type(None)}
def conforms(value, rule):
    # The subset of JSON Schema the lane schema uses: type, enum, anyOf, properties/required/additionalProperties.
    if 'anyOf' in rule:
        return any(conforms(value, option) for option in rule['anyOf'])
    kinds = rule['type'] if isinstance(rule['type'], list) else [rule['type']]
    if not any(type(value) is int if kind == 'integer' else isinstance(value, JSON_TYPES[kind]) for kind in kinds):
        return False
    if 'enum' in rule and value not in rule['enum']:
        return False
    if isinstance(value, dict):
        if set(value) - set(rule['properties']) or not set(rule['required']) <= set(value):
            return False
        return all(conforms(value[key], rule['properties'][key]) for key in value)
    return True
child = None
def interrupted(signum, frame):
    if child is not None:
        child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    result('halted', 'lane interrupted; preserve claims and worktrees')
    sys.exit(128 + signum)
signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
with tempfile.TemporaryDirectory(prefix=f'super-board-{backend.name}-') as temporary:
    run = dict(root=root, git_dir=git_dir, common_dir=common_dir, model=model, prompt=prompt,
               private_home=bool((config.get(backend.name) or {}).get('private_home')),
               schema_path=Path(temporary) / 'schema.json', output=Path(temporary) / 'result.json')
    run['schema_path'].write_text(json.dumps(schema))
    command, stdin = backend.command(run)
    env = backend.env(run) if hasattr(backend, 'env') else dict(os.environ)

    def launch(argv, text):
        """Run the host once. Return (exit code, stdout when captured, session id when the host reports one)."""
        global child
        child = subprocess.Popen(argv, stdin=subprocess.PIPE if text is not None else subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT if not backend.capture_stdout else None,
                                 text=True, env=env, cwd=str(root))
        if text is not None:
            child.stdin.write(text)
            child.stdin.close()
        session, seen = None, []
        for line in child.stdout:
            if backend.capture_stdout:
                seen.append(line)
            else:
                sys.stderr.write(line)  # the host's log goes to the wave log; the answer is a file
            if session is None and hasattr(backend, 'session_id'):
                session = backend.session_id(line)
        child.wait()
        return child.returncode, ''.join(seen), session

    try:
        # Some models end their turn with a sentence of narration instead of the JSON result.
        # Resume the same session, which keeps its context, and ask it to finish; give up after two resumes.
        resume_prompt = ('You stopped before finishing this lane. Do not redo finished steps. Complete every '
                         'remaining step of the lifecycle (board move, comments, cleanup), then reply with '
                         'only the JSON result object: no prose, no code fence.')
        code, stdout, session = launch(command, stdin)
        for attempt in range(3):
            require_verification_ready()
            if code:
                result('halted' if code in (9, 10, 79) else 'failed',
                       'verification-readiness: repair verify_commands and restart explicitly; preserve work'
                       if code == 9 else 'skills-readiness: required skills became unavailable; preserve work' if code == 10 else f"{' '.join(command[:2])} exited {code}")
                sys.exit(code if code in (9, 10, 79) else 1)
            try:
                parsed = json.loads(backend.final_message(run, stdout))
                if not conforms(parsed, schema):
                    raise ValueError('lane result does not match the lane schema')
                break
            except (OSError, ValueError):
                if attempt == 2 or session is None or not hasattr(backend, 'resume_command'):
                    raise
                sys.stderr.write(f'[lane] final message was not the JSON result; resuming session {session} ({attempt + 1}/2)\n')
                code, stdout, _ = launch(backend.resume_command(run, command, session), resume_prompt)
        print(json.dumps(parsed))
        sys.exit(10 if parsed['status'] == 'halted' and parsed['detail'].startswith('skills-readiness:')
                 else 9 if parsed['status'] == 'halted' and parsed['detail'].startswith('verification-readiness:')
                 else 79 if parsed['status'] == 'halted' else 0)
    except (OSError, ValueError) as error:
        # Keep the raw final message: a lane that did the work but answered in prose is worth reading.
        try:
            raw = run['output'].read_text(errors='replace') if run['output'].exists() else ''
        except OSError:
            raw = ''
        keep = Path(os.environ.get('TMPDIR') or tempfile.gettempdir()) / f'super-board-{backend.name}' / 'failed-lanes' / f"{card['number']}-{args.lane}-{int(time.time())}.txt"
        try:
            keep.parent.mkdir(parents=True, exist_ok=True)
            keep.write_text(raw)
        except OSError:
            keep = None
        snippet = ' '.join(raw.split())[:160] or 'empty final message'
        result('failed', f'{backend.label} returned no valid lane result: {error}; final message: {snippet}; saved: {keep}')
        sys.exit(1)
PY
