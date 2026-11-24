#!/usr/bin/env python3
"""Extra live branch checks; disposable container only, after container_smoke.py."""
from pathlib import Path
import importlib.util
import json
import os
import subprocess

assert Path('/run/systemd/container').exists() or os.environ.get('container') == 'docker'
root=Path('/var/lib/fzm-ci');assert (root/'smoke-ok').exists()
def run(args,expected=0):
    p=subprocess.run(args,capture_output=True,text=True,timeout=120)
    assert p.returncode==expected,(args,p.stdout[-1500:],p.stderr[-1500:])
    print('PASS',' '.join(map(str,args[:5])),flush=True)
    return p.stdout
state_file=Path('/etc/forcus-zapret/state.json')
state=json.loads(state_file.read_text())
state['profiles']['telegram']['redirect_5222']=True
state['profiles']['telegram']['telegram_port_mode']='5222'
state_file.write_text(json.dumps(state))
pid=run(['systemctl','show','-p','MainPID','--value','fzm-ci-xray.service']).strip()
run(['forcus-zapret','xray','apply','--backend','postgres','--database','fzm_ci',
     '--binary','/opt/test-xray/xray','--runtime',str(root/'xray.json'),
     '--youtube-inbounds','fixture-ru,fixture-ru-yt','--telegram-inbounds','fixture-ru,fixture-ru-yt','--yes'])
assert pid==run(['systemctl','show','-p','MainPID','--value','fzm-ci-xray.service']).strip()
spec=importlib.util.spec_from_file_location('manager','/opt/forcus-zapret/forcus_zapret.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
checks=[]
for port in [12080,12081]:
    result=module.mtproto_probe(port,'149.154.167.51',443)
    assert result['ok'],result
    checks.append(dict(result,proxy_port=port))
print('PASS real MTProto 443 -> Xray -> local SOCKS -> NFQUEUE -> Telegram:5222 for both inbounds',flush=True)
run(['forcus-zapret','stop','--profile','youtube','--yes'])
run(['forcus-zapret','update-engine','--yes'])
run(['systemctl','is-active','forcus-zapret-youtube-dpi.service'],expected=3)
run(['systemctl','is-active','forcus-zapret-telegram-dpi.service'])
run(['forcus-zapret','start','--profile','youtube','--yes'])
(root/'reboot-before.json').write_text(json.dumps({'xray_pid':pid,'mtproto_fallback_checks':checks,
    'stopped_profile_preserved_by_update':True,'profiles':json.loads(state_file.read_text())['profiles']},indent=2))
print('Ready for docker restart; both profile services and Xray bindings enabled',flush=True)
