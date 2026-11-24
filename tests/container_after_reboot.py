#!/usr/bin/env python3
"""Verify reboot persistence and uninstall in a disposable container only."""
from pathlib import Path
import json
import os
import subprocess
import time

assert Path('/run/systemd/container').exists() or os.environ.get('container') == 'docker'
root=Path('/var/lib/fzm-ci');before=json.loads((root/'reboot-before.json').read_text())
log=[]
def run(args,expected=0):
    p=subprocess.run(args,capture_output=True,text=True,timeout=90)
    log.append({'command':args,'returncode':p.returncode,'stdout':p.stdout[-2000:],'stderr':p.stderr[-1500:]})
    (root/'after-reboot-report.json').write_text(json.dumps(log,ensure_ascii=False,indent=2))
    assert p.returncode==expected,(args,p.stdout[-1500:],p.stderr[-1500:])
    print('PASS',' '.join(args[:5]),flush=True)
    return p.stdout
services=['forcus-zapret-'+name+'-'+part+'.service' for name in ['youtube','telegram'] for part in ['socks','dpi']]+['fzm-ci-xray.service','postgresql@16-main.service']
for _ in range(60):
    if all(subprocess.run(['systemctl','is-active',u],capture_output=True,text=True).stdout.strip()=='active' for u in services):break
    time.sleep(.25)
else:raise RuntimeError('Not all fixture/profile services returned after restart')
for service in services:run(['systemctl','is-active',service])
for name in ['youtube','telegram']:
    run(['nft','list','table','inet','fzm_'+name])
assert run(['sysctl','-n','net.netfilter.nf_conntrack_acct']).strip()=='1'
state=json.loads(Path('/etc/forcus-zapret/state.json').read_text())
queue_ids={int(line.split()[0]) for line in Path('/proc/net/netfilter/nfnetlink_queue').read_text().splitlines()}
assert {p['queue'] for p in state['profiles'].values()} <= queue_ids
assert state['links'] and not state['links'][0].get('pending')
assert any(o['tag']=='fzm-telegram-mtproto' for o in json.loads((root/'xray.json').read_text())['outbounds'])
run(['/opt/test-xray/xray','api','lsrules','--server=127.0.0.1:62789'])
run(['forcus-zapret','xray','detach','--profile','all','--yes'])
run(['forcus-zapret','remove','--profile','youtube','--yes'])
run(['systemctl','is-active','forcus-zapret-telegram-dpi.service'])
run(['nft','list','table','inet','fzm_telegram'])
assert not Path('/etc/systemd/system/forcus-zapret-youtube-dpi.service').exists()
run(['forcus-zapret','uninstall','--yes'])
assert not Path('/usr/local/sbin/forcus-zapret').exists()
assert not Path('/opt/forcus-zapret').exists()
assert not Path('/etc/forcus-zapret/state.json').exists()
for name in ['youtube','telegram']:run(['nft','list','table','inet','fzm_'+name],expected=1)
run(['systemctl','is-active','fzm-ci-xray.service'])
run(['systemctl','is-active','postgresql@16-main.service'])
assert Path('/usr/sbin/danted').exists() and Path('/usr/sbin/nft').exists()
assert any(Path('/var/backups/forcus-zapret').iterdir())
(root/'final-ok.json').write_text(json.dumps({'reboot_persistence':True,'nfqueue_recreated':True,
    'xray_bindings_persisted':True,'one_profile_removal_preserved_other':True,
    'uninstall_preserved_xray_postgres_packages_backups':True},indent=2))
print('All reboot and uninstall checks passed',flush=True)
