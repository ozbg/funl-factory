#!/usr/bin/env bash
# Dispatch an explicitly selected Codex wave; stdout/--output matches the
# Claude workflow's {cards:[summary...], halted} reconciliation contract.
# Usage: --config f --cards '<JSON array>' --codex[=model] [--tier low|medium|high] [--output f]
#        --config f --rolling --codex[=model] [--events f] [--cooldown 300]   (no --cards)
# --rolling keeps planning: each newly runnable card starts as soon as a slot is free, until the
# board is idle. max_workers is re-read every loop, so it can be lowered mid-run. No new card
# starts below 10 GB free disk, and the run ends by removing clean scratch checkouts in temp folders.
# Unless one model is pinned (--codex=<model> or codex.model), a cheap router
# (ROUTER_MODEL) grades each Ready card low/medium/high; the lane launcher maps
# tier x grade to a model through its Codex.LADDERS table.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import importlib.util
import shutil
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description='Dispatch one explicitly opted-in Codex wave.')
parser.add_argument('--config', required=True)
parser.add_argument('--cards', help='planner card array JSON or JSON file (omit with --rolling)')
parser.add_argument('--rolling', action='store_true',
                    help='keep planning: start each newly runnable card as soon as a slot is free, until the board is idle')
parser.add_argument('--events', help='rolling: append one JSON line per finished card to this file')
parser.add_argument('--cooldown', type=int, default=300,
                    help='rolling: seconds before a card that did not advance may be picked again (default 300)')
parser.add_argument('--output')
parser.add_argument('--tier', default='medium', choices=['low', 'medium', 'high'])
raw = sys.argv[2:]
codex = [arg for arg in raw if arg == '--codex' or arg.startswith('--codex=')]
if len(codex) != 1 or (codex[0].startswith('--codex=') and not codex[0].partition('=')[2].strip()):
    parser.error('exactly one explicit --codex[=<non-empty-model>] is required')
args = parser.parse_args([arg for arg in raw if arg not in codex])
output_path = Path(args.output).resolve() if args.output else None
launcher = Path(sys.argv[1]).resolve().with_name('super-board-lane.sh')
try:
    config_path = Path(args.config).resolve()
    config = json.loads(config_path.read_text())
    if args.rolling:
        cards = []
    elif not args.cards:
        raise ValueError('--cards is required unless --rolling')
    else:
        cards = json.loads(args.cards if args.cards.lstrip().startswith('[') else Path(args.cards).read_text())
    if not isinstance(config, dict) or not isinstance(cards, list):
        raise ValueError('config must be an object; cards must be an array')
    numbers = set()
    for card in cards:
        if (not isinstance(card, dict) or type(card.get('number')) is not int or card['number'] < 1
                or card.get('status') not in ['Ready', 'QA', 'Review']):
            raise ValueError('each card needs a positive number and Ready/QA/Review status')
        if card['number'] in numbers:
            raise ValueError('duplicate card number')
        numbers.add(card['number'])
        if card.get('lane') not in [None, 'build', 'qa', 'review']:
            raise ValueError('invalid card lane')
        if card['status'] == 'Ready' and card.get('lane') == 'review':
            raise ValueError('a Ready card must enter build or qa')
    workers = config.get('max_workers', 0)
    if type(workers) is not int or workers < 0:
        raise ValueError('max_workers must be a non-negative integer')
    workers = workers or max(1, min(16, (os.cpu_count() or 2) - 2))
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()).resolve()
    configured = (config.get('codex') or {}).get('model')
    pinned = codex[0].startswith('--codex=') or (isinstance(configured, str) and configured.strip())
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    parser.error(str(error))
# Summary keys the workflow adds for the scorecard (factory #25); empty on halt paths.
NO_SCORE = dict(complexity=None, buildModel=None, qaModel=None, reviewModel=None, score=None)
readiness = launcher.with_name('super-board-verification-ready.py')
if subprocess.run([sys.executable, str(readiness), '--config', str(config_path)]).returncode:
    result = json.dumps({'cards': [dict(number=c['number'], finalStatus='halted', lastLane='none',
                                       column=c['status'], detail='verification-readiness: repair verify_commands and restart explicitly',
                                       prUrl=None, priorFindings=None, lanesRun='none:halted', **NO_SCORE) for c in cards], 'halted': True})
    if output_path:
        output_path.write_text(result + '\n')
    print(result)
    sys.exit(9)
os.chdir(root)
resolver_path = launcher.with_name('super-board-skills-ready.py')
try:
    spec = importlib.util.spec_from_file_location('skills_ready', resolver_path)
    resolver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(resolver)
    resolver.hydrate(cards, root)
    skills = resolver.report(root, 'codex', cards, home=os.environ.get('SUPER_BOARD_SKILLS_HOME'),
                             catalog=os.environ.get('SUPER_BOARD_SKILLS_CATALOG'))
except SystemExit as error:
    code, detail = error.code, 'required GitHub reads halted while hydrating skills; preserve claims and worktrees'
except (OSError, ValueError, TypeError, KeyError) as error:
    code, detail = 64, 'skills-readiness: ' + str(error)
else:
    code = 0 if skills['ready'] else 10
    detail = 'skills-readiness: missing ' + ', '.join(dict.fromkeys(e['name'] for e in skills['entries'] if e['status'] == 'missing'))
if code:
    result = json.dumps(dict(cards=[dict(number=c['number'], finalStatus='halted', lastLane='none', column=c['status'],
                                       detail=detail, prUrl=None, priorFindings=None, lanesRun='none:halted', **NO_SCORE) for c in cards], halted=True))
    if output_path:
        output_path.write_text(result + '\n')
    print(result)
    sys.exit(code)
readiness_halted = threading.Event()
skills_halted = threading.Event()
halted = threading.Event()
mutex = threading.RLock()
active = set()
inflight = root / '.claude/super-board/inflight'
marker = root / '.claude/super-board/codex-wave.pid'
inflight.mkdir(parents=True, exist_ok=True)
owner = str(os.getpid())

def cancel(signum, frame):
    halted.set()
    with mutex:
        processes = list(active)
        for process in processes:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    # Process groups include the launcher, Codex, and shell descendants. Kill
    # lingering descendants too, even when their launcher already exited.
    time.sleep(2)
    for process in processes:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

signal.signal(signal.SIGTERM, cancel)
signal.signal(signal.SIGINT, cancel)
try:
    with marker.open('x') as stream:
        stream.write(owner + '\n')
except FileExistsError:
    parser.error('Codex wave PID marker exists; reconcile the previous wave before starting another')

# The router only grades scope; it writes nothing. A Codex-only run grades with
# the cheapest Codex model rather than waking Claude.
ROUTER_MODEL = 'gpt-6-luna'
GRADE_SCHEMA = {'type': 'object', 'additionalProperties': False, 'required': ['complexity'],
                'properties': {'complexity': {'type': 'string', 'enum': ['low', 'medium', 'high']}}}

def grade(card):
    """Return (complexity or None, halted). A failed grade falls back to the medium cell."""
    if pinned or card['status'] != 'Ready':
        return card.get('complexity') if card.get('complexity') in ['low', 'medium', 'high'] else None, False
    if card.get('complexity') in ['low', 'medium', 'high']:
        return card['complexity'], False
    prompt = (f"Read GitHub issue #{card['number']} (\"{card.get('title', '')}\") - body and all comments - with "
              f".claude/bin/super-board-github-read.py --kind issue -- issue view {card['number']} --json number,title,body and "
              f"--kind comments -- api repos/{{owner}}/{{repo}}/issues/{card['number']}/comments --paginate --slurp. "
              'Grade complexity (low|medium|high) by the scope of change required. Read only: change no file, '
              'label, comment or board state. Exit 79 from the read helper means stop and return nothing.\n')
    with tempfile.TemporaryDirectory(prefix='super-board-codex-grade-') as temporary:
        schema_path, output = Path(temporary) / 'schema.json', Path(temporary) / 'grade.json'
        schema_path.write_text(json.dumps(GRADE_SCHEMA))
        command = ['codex', 'exec', '-m', ROUTER_MODEL, '-C', str(root), '-c', 'approval_policy="never"',
                   '-c', 'default_permissions="super-board-grade"',
                   '-c', 'permissions.super-board-grade.filesystem={":root"="read", ":slash_tmp"="write", ":tmpdir"="write"}',
                   '-c', 'permissions.super-board-grade.network.enabled=true',
                   '--output-schema', str(schema_path), '--output-last-message', str(output), '-']
        with mutex:
            if halted.is_set():
                return None, True
            try:
                process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                           text=True, start_new_session=True)
            except OSError:
                return None, False
            active.add(process)
        try:
            process.communicate(prompt)
        finally:
            with mutex:
                active.discard(process)
        if process.returncode == 79:
            return None, True
        try:
            value = json.loads(output.read_text()).get('complexity')
        except (OSError, ValueError, AttributeError):
            return None, False
        return (value if value in ['low', 'medium', 'high'] else None), False

def run_card(card):
    complexity, stop = grade(card)
    if stop:
        halted.set()
        return dict(number=card['number'], finalStatus='halted', lastLane='none', column=card['status'],
                    detail='run halted while grading; preserve claims and worktrees', prUrl=None,
                    priorFindings=None, lanesRun='none:halted', **NO_SCORE)
    labels = [str(label).lower() for label in card.get('labels', [])]
    first = card.get('lane') or ('qa' if 'qa' in labels else 'build')
    entry = 'review' if card['status'] == 'Review' else 'qa' if card['status'] == 'QA' else first
    lanes = ['build', 'qa', 'review'][['build', 'qa', 'review'].index(entry):]
    history = []
    current = dict(card)
    for lane in lanes:
        with mutex:
            if halted.is_set():
                history.append(dict(lane='none', status='halted', column=current['status'], detail='run halted; preserve claims and worktrees'))
                break
            boundary = resolver.report(root, 'codex', [current], lane=lane,
                                       home=os.environ.get('SUPER_BOARD_SKILLS_HOME'), catalog=os.environ.get('SUPER_BOARD_SKILLS_CATALOG'))
            if not boundary['ready']:
                skills_halted.set()
                halted.set()
                history.append(dict(lane=lane, status='halted', column=current['status'],
                                    detail='skills-readiness: missing ' + ', '.join(e['name'] for e in boundary['entries'] if e['status'] == 'missing')))
                break
            process = None
            lock = inflight / str(card['number'])
            try:
                process = subprocess.Popen(['bash', str(launcher), '--backend', 'codex', '--config', str(config_path),
                                            '--card', json.dumps(current), '--lane', lane, codex[0],
                                            '--tier', args.tier] + (['--complexity', complexity] if complexity else []),
                                           stdout=subprocess.PIPE, text=True, start_new_session=True)
                active.add(process)
                lock.write_text(f'PID={process.pid}\nLANE={lane}\nSTARTED={time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
            except OSError as error:
                if process is not None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                    active.discard(process)
                history.append(dict(lane=lane, status='failed', column=current['status'],
                                    detail=f'could not start {lane} lane: {error}'))
                break
        preserve_lock = False
        try:
            stdout, _ = process.communicate()
            if process.returncode in (9, 10):
                preserve_lock = True
                (readiness_halted if process.returncode == 9 else skills_halted).set()
            try:
                result = json.loads(stdout)
                if (not isinstance(result, dict) or result.get('status') not in
                    ['advanced', 'bounced', 'blocked', 'human-gate', 'failed', 'halted']
                    or not all(isinstance(result.get(key), str) for key in ['column', 'detail'])):
                    raise ValueError('invalid lane result')
                if process.returncode and result['status'] not in ('halted', 'failed'):
                    raise ValueError(f'lane exited {process.returncode}')
            except (ValueError, TypeError):
                result = dict(status='halted' if process.returncode in (9, 10, 79) or halted.is_set() else 'failed',
                              column=current['status'], detail=f'{lane} lane returned no valid result (exit {process.returncode})')
            with mutex:
                if result['status'] == 'halted':
                    halted.set()
                active.discard(process)
            history.append(dict(lane=lane, **result))
            if result['status'] != 'advanced':
                break
            expected = {'build': 'QA', 'qa': 'Review', 'review': 'Done'}[lane]
            if result['column'] != expected:
                history[-1].update(status='failed', detail=f'{lane} claimed advanced without reaching {expected}')
                break
            current['status'] = result['column']
            current.pop('lane', None)
        finally:
            try:
                if not preserve_lock and lock.read_text().startswith(f'PID={process.pid}\n'):
                    lock.unlink()
            except FileNotFoundError:
                pass
    last = history[-1]
    # Codex picks its own -m per lane; lane_models applies to Claude waves only.
    ran = lambda lane: 'codex' if any(h['lane'] == lane for h in history) else None
    return dict(number=card['number'], finalStatus=last['status'], lastLane=last['lane'],
                column=last['column'], detail=last['detail'], prUrl=last.get('prUrl'),
                priorFindings=last.get('priorFindings'),
                lanesRun=' → '.join(f"{item['lane']}:{item['status']}" for item in history),
                complexity=complexity, buildModel=ran('build'), qaModel=ran('qa'), reviewModel=ran('review'),
                score=next((h.get('score') for h in reversed(history) if h['lane'] == 'review' and h.get('score')), None))

bin_dir = Path(sys.argv[1]).resolve().parent
bot = ((config.get('notifications') or {}).get('bot_identity') or '').strip()
events_path = Path(args.events).resolve() if args.events else None

def plan():
    """Runnable cards from the board, or [] when the planner or the guard fails."""
    subprocess.run(['bash', str(bin_dir / 'super-board-gh-guard.sh'), 'check', '200'], capture_output=True)
    out = subprocess.run(['bash', str(bin_dir / 'super-board-wave-plan.sh'), '--config', str(config_path)],
                         capture_output=True, text=True)
    try:
        planned = json.loads(out.stdout).get('cards', []) if out.returncode == 0 else []
    except ValueError:
        planned = []
    planned = [card for card in planned if isinstance(card, dict) and type(card.get('number')) is int]
    # Cards from the planner have no body yet; the lane's skills-readiness check needs it.
    try:
        resolver.hydrate(planned, root)
    except (SystemExit, OSError, ValueError, TypeError, KeyError):
        return []
    return planned

def claim(number):
    if bot:
        subprocess.run(['gh', 'issue', 'edit', str(number), '--add-assignee', bot], capture_output=True)

def emit(summary):
    if events_path:
        with events_path.open('a') as stream:
            stream.write(json.dumps(dict(at=time.strftime('%Y-%m-%dT%H:%M:%S%z'), **summary)) + '\n')

MIN_FREE_GB = 10

def cap():
    """max_workers, re-read every loop so the orchestrator can lower it mid-run (never above the start value)."""
    try:
        value = json.loads(config_path.read_text()).get('max_workers', workers)
        return max(1, min(workers, int(value))) if int(value) > 0 else workers
    except (OSError, ValueError, TypeError):
        return workers

def free_gb():
    return shutil.disk_usage(root).free / 1e9

def sweep_scratch():
    """Remove clean scratch checkouts lanes left in temp folders; report dirty ones."""
    listing = subprocess.run(['git', 'worktree', 'list', '--porcelain'], capture_output=True, text=True).stdout
    temp_roots = [str(Path(p).resolve()) for p in ['/tmp', '/private/tmp', os.environ.get('TMPDIR') or '/tmp']]
    kept = []
    for line in listing.splitlines():
        if not line.startswith('worktree '):
            continue
        path = line.split(' ', 1)[1]
        if Path(path).resolve() == Path(root).resolve():
            continue  # never the checkout the run itself works in, even when that sits in a temp folder
        if not any(str(Path(path).resolve()).startswith(t) for t in temp_roots):
            continue
        dirty = subprocess.run(['git', '-C', path, 'status', '--porcelain'], capture_output=True, text=True).stdout.strip()
        if dirty:
            kept.append(path)
        else:
            subprocess.run(['git', 'worktree', 'remove', '--force', path], capture_output=True)
    subprocess.run(['git', 'worktree', 'prune'], capture_output=True)
    return kept

def roll(pool):
    """Waves wait for their slowest card; rolling starts each runnable card as soon as a
    slot frees. A card that did not advance waits `cooldown` seconds before it is picked
    again, so the orchestrator can rule on it first. Ends when nothing runs and nothing
    is runnable, or when the run halts."""
    summaries, running, cooled, replan = [], {}, {}, True
    while True:
        for number, future in list(running.items()):
            if future.done():
                summary = future.result()
                summaries.append(summary)
                emit(summary)
                del running[number]
                replan = True
                if summary['finalStatus'] != 'advanced':
                    cooled[number] = time.time() + max(0, args.cooldown)
        if halted.is_set():
            if not running:
                return summaries
        elif len(running) < cap() and free_gb() < MIN_FREE_GB:
            # A full disk fails lanes mid-write; stop starting cards until space returns.
            if not getattr(roll, 'warned', False):
                emit(dict(number=0, finalStatus='paused', lastLane='none', column='-',
                          detail=f'disk low: {free_gb():.1f} GB free (< {MIN_FREE_GB}); not starting new cards'))
                roll.warned = True
        elif len(running) < cap() and (replan or any(t <= time.time() for t in cooled.values())):
            roll.warned = False
            replan = False
            for card in plan():
                number = card['number']
                if len(running) >= cap():
                    break
                if number in running or cooled.get(number, 0) > time.time():
                    continue
                cooled.pop(number, None)
                claim(number)
                running[number] = pool.submit(run_card, card)
            if not running and not any(t > time.time() for t in cooled.values()):
                return summaries
        time.sleep(float(os.environ.get('SB_ROLLING_POLL', '15')))

try:
    with ThreadPoolExecutor(max_workers=workers) as pool:
        summaries = roll(pool) if args.rolling else list(pool.map(run_card, cards))
    result = json.dumps(dict(cards=summaries, halted=halted.is_set()))
    if output_path:
        output = output_path
        temporary = output.with_name(output.name + f'.{owner}.tmp')
        temporary.write_text(result + '\n')
        temporary.replace(output)
    print(result)
finally:
    if marker.exists() and marker.read_text().strip() == owner:
        marker.unlink()
    try:
        left = sweep_scratch()
        if left:
            print('[codex-wave] dirty scratch checkouts kept: ' + ', '.join(left), file=sys.stderr)
    except Exception as error:  # cleanup must never change the exit code
        print(f'[codex-wave] scratch sweep failed: {error}', file=sys.stderr)
sys.exit(10 if skills_halted.is_set() else 9 if readiness_halted.is_set() else 79 if halted.is_set() else 0)
PY
