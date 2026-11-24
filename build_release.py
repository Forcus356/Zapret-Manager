#!/usr/bin/env python3
"""Build a source ZIP and standalone installer without caches, credentials or raw CI logs."""
from pathlib import Path
import hashlib
import re
import shutil
import subprocess
import sys
import zipfile

root=Path(__file__).parent
subprocess.run([sys.executable,str(root/'build_installer.py')],check=True)
version=re.search(r"^VERSION = '([^']+)'",(root/'forcus_zapret.py').read_text(),re.M)[1]
dist=root/'dist';dist.mkdir(exist_ok=True)
files=[root/name for name in ['forcus_zapret.py','install_forcus_zapret.sh','build_installer.py','build_release.py',
    'README.md','README.ru_RU.md','LICENSE','SECURITY.md','SECURITY.ru_RU.md',
    'THIRD_PARTY_NOTICES.md','CHANGELOG.md','TESTING.md','.gitignore']]
files+=sorted((root/'tests').glob('*.py'))+[root/'tests/Dockerfile.systemd',root/'tests/README.md']
files+=sorted(p for p in (root/'docs').rglob('*') if p.is_file())
files+=sorted((root/'.github/workflows').glob('*.yml'))
assert all(p.is_file() for p in files)
manifest=''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(root))+'\n' for p in files)
archive=dist/('Forcus-Zapret-Manager-v'+version+'.zip')
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
    for p in files:z.write(p,arcname='Forcus-Zapret-Manager/'+str(p.relative_to(root)))
    z.writestr('Forcus-Zapret-Manager/SHA256SUMS',manifest)
with zipfile.ZipFile(archive) as z:assert z.testzip() is None
shutil.copy2(root/'install_forcus_zapret.sh',dist/'install_forcus_zapret.sh')
(dist/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n'
    for p in [archive,dist/'install_forcus_zapret.sh']))
print(archive)
