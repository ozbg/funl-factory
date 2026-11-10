#!/usr/bin/env python3
"""Real setup boundaries with fake external tools. No host or GitHub writes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

KIT = Path(os.environ.get('SB_TEST_PACK', Path(__file__).resolve().parents[1]))
MANIFEST = json.loads((KIT / 'skills/families.json').read_text())
NAMES = [n for f in MANIFEST.values() if f.get('install') == 'pack' for n in f['skills']] + [
         'tdd','codebase-design','code-review','diagnosing-bugs','verification-before-completion','testing-strategy']

class Dispatch(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root, self.home, self.bin = [self.base / name for name in ['repo','home','bin']]
        for path in [self.root,self.home,self.bin]: path.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        SUPER_BOARD_SKILLS_HOME=str(self.home), SB_GITHUB_RETRY_DELAY='0',
                        SB_GITHUB_HALT_FILE=str(self.base / 'halt.json'), CALL_LOG=str(self.base / 'calls.jsonl'))
        subprocess.run(['git','init','-q',str(self.root)], check=True)
        self.config = self.base / 'config.json'
        self.config.write_text('{"max_workers":1,"verify_commands":["git diff --check"]}')
        self.tool('gh', '''import json,os,sys
args=sys.argv[1:]
with open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps({'tool':'gh','args':args})+'\\n')
if args[:2]==['issue','view']:
    fields=args[args.index('--json')+1] if '--json' in args else ''
    if fields=='state': print('OPEN')
    elif fields=='labels': print('{"labels":[]}')
    else: print(json.dumps({'number':int(args[2]),'title':'fixture','body':os.environ.get('ISSUE_BODY','')}))
else: sys.exit('unexpected GitHub mutation/read: '+str(args))
''')
        self.tool('claude', "import json,os\nwith open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps({'tool':'claude'})+'\\n')\n")
        self.tool('npx', "import json,os,sys\nwith open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps({'tool':'npx','args':sys.argv[1:]})+'\\n')\n")
        self.state = self.root / '.claude/super-board'
        (self.state / 'inflight').mkdir(parents=True)
        (self.state / 'inflight/99').write_text('PID=99999\nLANE=review\n')
        (self.state / 'approval.json').write_text('{"human":"existing"}')
        (self.root / '.claude/worktrees/preserved').mkdir(parents=True)
        (self.root / '.claude/worktrees/preserved/user.txt').write_text('existing work')

    def tool(self,name,source):
        compile(source, name, 'exec')
        path=self.bin/name;path.write_text('#!/usr/bin/env python3\n'+source);path.chmod(0o755)

    def full(self,host='codex'):
        for name in NAMES:
            for surface in ['.agents/skills'] if host=='codex' else ['.claude/skills']:
                path=self.root/surface/name/'SKILL.md';path.parent.mkdir(parents=True,exist_ok=True);path.write_text('fixture skill instructions')

    def calls(self):
        path=self.base/'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_setup_fix_reports_missing_even_after_successful_installer(self):
        (self.root/'skills-lock.json').write_text('{"mattpocock/skills":true}')
        for command,extra in [('check',[]),('fix',['--no-helpers']),('fix',[])]:
            result=subprocess.run([sys.executable,str(KIT/'scripts/super-board-setup.py'),command,'--root',str(self.root),'--pack',str(KIT),'--home',str(self.home),*extra],env=self.env,text=True,capture_output=True)
            self.assertEqual(result.returncode,1,result.stderr)
            output=json.loads(result.stdout)
            self.assertFalse(output['helper_skills']);self.assertFalse(output['green'])
            self.assertTrue(any(e['status']=='missing' for e in output['helper_readiness']['entries']))
            self.assertNotIn("Matt Pocock's coding skills added",output.get('fixed',[]))
        npx=[c['args'] for c in self.calls() if c['tool']=='npx']
        # One `fix` without --no-helpers: each helper source once, every helper named.
        self.assertEqual(len(npx),2,npx)
        self.assertIn('mattpocock/skills',npx[0]); self.assertNotIn('*',npx[0])
        self.assertEqual(npx[1][npx[1].index('add'):],['add','obra/superpowers','--skill','verification-before-completion','-a','claude-code','-y'])
        named={a for c in npx for a in c[c.index('add'):]}
        self.assertTrue(set(MANIFEST['helpers']['skills']) <= named)
        self.assertFalse(named & {'security-audit','cloudflare/security-audit-skill'})

    def test_setup_no_longer_installs_security_audit(self):
        self.full('claude')
        for command,extra in [('check',[]),('fix',[])]:
            result=subprocess.run([sys.executable,str(KIT/'scripts/super-board-setup.py'),command,'--root',str(self.root),'--pack',str(KIT),'--home',str(self.home),*extra],env=self.env,text=True,capture_output=True)
            output=json.loads(result.stdout)
            self.assertNotIn('security_audit',output,result.stdout)
            self.assertNotIn('security-audit',[e['name'] for e in output['helper_readiness']['entries']])
        self.assertFalse(any('security-audit' in ' '.join(c['args']) for c in self.calls() if c['tool']=='npx'))

if __name__=='__main__':unittest.main()
