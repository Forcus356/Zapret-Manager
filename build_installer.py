#!/usr/bin/env python3
"""Build the readable standalone Bash installer from the Python source."""
from pathlib import Path
import hashlib

root = Path(__file__).parent
source = (root/'forcus_zapret.py').read_text()
delimiter = 'FORCUS_ZAPRET_PY_' + hashlib.sha256(source.encode()).hexdigest()[:16]
assert delimiter not in source
shell = '''#!/usr/bin/env bash
# Forcus Zapret Manager: self-contained installer and menu.
# GPL-3.0-or-later. Source: forcus_zapret.py in the same release.
set -Eeuo pipefail
umask 077
if [[ ! -x /usr/bin/python3 ]]; then
    [[ $EUID -eq 0 ]] || { echo 'Нужен root для установки Python 3' >&2; exit 1; }
    . /etc/os-release
    [[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || { echo 'Ubuntu/Debian only' >&2; exit 1; }
    apt-get update
    apt-get install -y --no-install-recommends python3 ca-certificates
fi
/usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || {
    echo 'Нужен Python 3.10+ (Ubuntu 22.04+/Debian 12+). Системный Python автоматически не заменяется.' >&2
    exit 1
}
FZM_BOOTSTRAP_DIR="$(mktemp -d /tmp/forcus-zapret.XXXXXXXX)"
trap 'rm -rf -- "$FZM_BOOTSTRAP_DIR"' EXIT
cat > "$FZM_BOOTSTRAP_DIR/forcus_zapret.py" <<'DELIMITER'
SOURCE
DELIMITER
/usr/bin/python3 "$FZM_BOOTSTRAP_DIR/forcus_zapret.py" "$@"
'''.replace('DELIMITER', delimiter).replace('SOURCE\n', source+'\n')
target = root/'install_forcus_zapret.sh'
target.write_text(shell)
target.chmod(0o755)
print(target)
