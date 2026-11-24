#!/usr/bin/env python3
"""Run as root INSIDE a disposable systemd container. Never run on a real VPS."""
from pathlib import Path
import copy
import contextlib
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys

assert Path('/run/systemd/container').exists() or os.environ.get('container') == 'docker', 'Disposable container only'
ROOT = Path('/var/lib/fzm-ci'); ROOT.mkdir(parents=True,exist_ok=True)
REPORT = []

def run(args, expect=0):
    p = subprocess.run(args, capture_output=True, text=True, timeout=150)
    REPORT.append({'command': list(map(str,args)), 'returncode': p.returncode, 'stdout': p.stdout[-5000:], 'stderr': p.stderr[-2000:]})
    (ROOT/'report.json').write_text(json.dumps(REPORT, ensure_ascii=False, indent=2))
    assert p.returncode == expect, (args, p.stdout[-2500:], p.stderr[-1500:])
    print('PASS', ' '.join(map(str,args[:5])), flush=True)
    return p.stdout

def cli(*args, expect=0):return run(['forcus-zapret', *args], expect)

cli('status','--profile','all')
cli('check','--profile','all')
cli('backup','--output',str(ROOT/'backup.tar.gz'))
state=json.loads(Path('/etc/forcus-zapret/state.json').read_text())
assert set(state['profiles']) == {'youtube','telegram'}
assert len({p['queue'] for p in state['profiles'].values()})==2
assert len({p['port'] for p in state['profiles'].values()})==2
for p in state['profiles'].values():
    assert p['last_check']['same_egress']
    assert run(['systemctl','is-enabled',f'forcus-zapret-{p["name"]}-dpi.service']).strip()=='enabled'

binary=Path('/opt/test-xray/xray')
if not binary.exists():
    print('Xray fixture binary missing; cannot run live Xray integration',file=sys.stderr)
    sys.exit(2)
base={'log':{'loglevel':'warning'},'api':{'tag':'api','services':['HandlerService','RoutingService']},
      'inbounds':[{'tag':'api','listen':'127.0.0.1','port':62789,'protocol':'tunnel','settings':{'address':'127.0.0.1'}},
                  *[{'tag':tag,'listen':'127.0.0.1','port':port,'protocol':'socks','settings':{'auth':'noauth','udp':True},'sniffing':{'enabled':True,'destOverride':['http','tls','quic']}}
                    for tag,port in [('fixture-ru',12080),('fixture-ru-yt',12081),('fixture-foreign',12082)]]],
      'outbounds':[{'tag':'direct','protocol':'freedom','settings':{}},{'tag':'blocked','protocol':'blackhole','settings':{}}],
      'routing':{'domainStrategy':'AsIs','rules':[{'type':'field','inboundTag':['api'],'outboundTag':'api'},
                 {'type':'field','inboundTag':['fixture-foreign'],'outboundTag':'direct'}]}}
runtime=ROOT/'xray.json';runtime.write_text(json.dumps(base))
Path('/etc/systemd/system/fzm-ci-xray.service').write_text(f'''[Unit]
Description=Disposable Xray test fixture
[Service]
WorkingDirectory={binary.parent}
ExecStart={binary} run -c {runtime}
[Install]
WantedBy=multi-user.target
''')
run(['systemctl','daemon-reload']);run(['systemctl','enable','--now','fzm-ci-xray.service'])
pid=run(['systemctl','show','-p','MainPID','--value','fzm-ci-xray.service']).strip()
db=ROOT/'panel.db'
with contextlib.closing(sqlite3.connect(db)) as c, c:
    c.execute('CREATE TABLE settings(id INTEGER PRIMARY KEY,key TEXT UNIQUE,value TEXT)')
    c.execute('INSERT INTO settings(key,value) VALUES(?,?)',('xrayTemplateConfig',json.dumps(base)))
    c.execute('INSERT INTO settings(key,value) VALUES(?,?)',('unrelated','keep-me'))

common=['--binary',str(binary),'--runtime',str(runtime),'--api','127.0.0.1:62789']
scope=['--youtube-inbounds','fixture-ru,fixture-ru-yt','--telegram-inbounds','fixture-ru,fixture-ru-yt']
cli('xray','apply','--backend','sqlite','--config',str(db),*common,*scope,'--yes')
assert pid==run(['systemctl','show','-p','MainPID','--value','fzm-ci-xray.service']).strip()
one=json.loads(runtime.read_text())
for rule in one['routing']['rules']:
    if rule.get('ruleTag','').startswith('fzm-'):assert rule['inboundTag']==['fixture-ru','fixture-ru-yt']
assert [r for r in one['routing']['rules'] if not r.get('ruleTag','').startswith('fzm-')]==base['routing']['rules']
with contextlib.closing(sqlite3.connect(db)) as c:
    assert c.execute('SELECT value FROM settings WHERE key="unrelated"').fetchone()[0]=='keep-me'
    assert json.loads(c.execute('SELECT value FROM settings WHERE key="xrayTemplateConfig"').fetchone()[0])==one
cli('xray','apply','--backend','sqlite','--config',str(db),*common,*scope,'--yes')
assert json.loads(runtime.read_text())==one
cli('remove','--profile','youtube','--yes',expect=1)
cli('xray','detach','--profile','youtube','--yes')
left=json.loads(runtime.read_text())
assert any(o['tag']=='fzm-telegram' for o in left['outbounds'])
assert not any(o['tag']=='fzm-youtube' for o in left['outbounds'])
cli('xray','detach','--profile','telegram','--yes')
assert json.loads(runtime.read_text())==base

# A standalone persistent config is also the runtime file: CAS must not mistake
# its own successful write for a concurrent update.
cli('xray','apply','--backend','standalone','--config',str(runtime),*common,*scope,'--yes')
assert pid==run(['systemctl','show','-p','MainPID','--value','fzm-ci-xray.service']).strip()
cli('xray','detach','--profile','all','--yes')
assert json.loads(runtime.read_text())==base

# Optional PostgreSQL fixture, installed separately by the CI harness.
if Path('/usr/bin/psql').exists():
    run(['runuser','-u','postgres','--','createdb','fzm_ci'])
    def sql(query):
        p=subprocess.run(['runuser','-u','postgres','--','psql','-XAtq','-v','ON_ERROR_STOP=1','-d','fzm_ci'],input=query,capture_output=True,text=True)
        assert p.returncode==0,p.stderr
        return p.stdout
    sql('CREATE TABLE settings(id serial PRIMARY KEY,key text UNIQUE,value text);')
    quote=lambda t:"'"+t.replace("'","''")+"'"
    sql('INSERT INTO settings(key,value) VALUES(\'xrayTemplateConfig\','+quote(json.dumps(base))+'),(\'unrelated\',\'keep-me\');')
    cli('xray','apply','--backend','postgres','--database','fzm_ci',*common,*scope,'--yes')
    assert pid==run(['systemctl','show','-p','MainPID','--value','fzm-ci-xray.service']).strip()
    assert sql("SELECT value FROM settings WHERE key='unrelated';").strip()=='keep-me'
    cli('xray','detach','--profile','all','--yes')
    assert json.loads(runtime.read_text())==base
    spec=importlib.util.spec_from_file_location('manager','/opt/forcus-zapret/forcus_zapret.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    store=module.TemplateStore(module.System(),{'backend':'postgres','database':'fzm_ci','pg_user':'postgres'})
    before=store.read();special="Quote ' backslash \\ newline\nРусский текст"
    store.compare_set(before,special);assert store.read()==special
    store.compare_set(special,before)

cli('stop','--profile','youtube','--yes')
assert run(['systemctl','is-active','forcus-zapret-telegram-dpi.service']).strip()=='active'
cli('start','--profile','youtube','--yes')
cli('update-engine','--yes')
(ROOT/'smoke-ok').write_text('Live SQLite, standalone, profile lifecycle and available PostgreSQL tests passed\n')
print('All live integration checks passed. Keep container for reboot and uninstall tests.',flush=True)
