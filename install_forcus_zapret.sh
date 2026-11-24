#!/usr/bin/env bash
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
cat > "$FZM_BOOTSTRAP_DIR/forcus_zapret.py" <<'FORCUS_ZAPRET_PY_392c4bd83def6991'
#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Forcus Zapret Manager: isolated local YouTube/Telegram profiles for systemd VPS."""
from __future__ import annotations

import argparse
import contextlib
import copy
import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import platform
import pwd
import re
import shlex
import shutil
import socket
import sqlite3
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import uuid

VERSION = '1.0.0'
OWNER = 'forcus-zapret'
ENGINE_VERSION = 'v1.0.7'
ENGINE_SHA256 = '547a5dce3f4820721a425680ea3f7f3971b7e9c772b8c795dd2d623148da0928'
PROFILES = ('youtube', 'telegram')
LABELS = {'youtube': 'YouTube', 'telegram': 'Telegram'}
USERS = {'youtube': 'fzm-yt', 'telegram': 'fzm-tg'}
YOUTUBE_DOMAINS = ['geosite:youtube', 'domain:googlevideo.com', 'domain:youtube.com',
                   'domain:youtube-nocookie.com', 'domain:ytimg.com',
                   'full:youtubei.googleapis.com', 'full:youtube.googleapis.com']
TELEGRAM_CIDRS = ['91.108.56.0/22', '91.108.4.0/22', '91.108.8.0/22', '91.108.16.0/22',
                 '91.108.12.0/22', '149.154.160.0/20', '91.105.192.0/23', '91.108.20.0/22',
                 '185.76.151.0/24', '2001:b28:f23d::/48', '2001:b28:f23f::/48',
                 '2001:67c:4e8::/48', '2001:b28:f23c::/48', '2a0a:f280::/32', '95.161.76.100/32']
TELEGRAM_DCS = [(1, '149.154.175.50'), (2, '149.154.167.51'), (3, '149.154.175.100'),
                (4, '149.154.167.91'), (5, '149.154.171.5')]
PACKAGES = ['ca-certificates', 'curl', 'python3', 'python3-cryptography', 'iproute2',
            'kmod', 'nftables', 'dante-server']
PRIVATE_TCP_DESTINATIONS = ['0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
                            '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16',
                            '224.0.0.0/4', '240.0.0.0/4', '::/96',
                            'fc00::/7', 'fe80::/10', 'ff00::/8']


class Error(RuntimeError):
    pass


def stamp():
    return dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:6]


def write_atomic(path, data, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise Error(f'Отказ записи через symlink: {path}')
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.fzm-', delete=False) as f:
        tmp = Path(f.name)
        try:
            os.fchmod(f.fileno(), mode)
            f.write(data.encode() if isinstance(data, str) else data)
            f.flush()
            os.fsync(f.fileno())
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
    try:
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def json_text(obj):
    return json.dumps(obj, ensure_ascii=False, indent=2) + '\n'


def valid_profile(name):
    if name not in PROFILES:
        raise Error('Профиль: youtube или telegram')
    return name


def validate_profile(p):
    valid_profile(p['name'])
    if type(p['port']) is not int or not 1024 <= p['port'] <= 65535:
        raise Error('SOCKS-порт: 1024–65535')
    if type(p['queue']) is not int or not 1 <= p['queue'] <= 65535:
        raise Error('NFQUEUE: 1–65535')
    if type(p['uid']) is not int or p['uid'] <= 0:
        raise Error('Нужен непривилегированный UID')
    if not re.fullmatch(r'[A-Za-z0-9_.:@-]{1,15}', p['interface']):
        raise Error('Некорректное имя сетевого интерфейса')
    if p['user'] != USERS[p['name']]:
        raise Error('Неверный пользователь профиля')
    if p.get('telegram_port_mode', 'off') not in ('auto', 'off', '5222'):
        raise Error('Telegram port mode: auto/off/5222')
    if type(p.get('redirect_5222', False)) is not bool:
        raise Error('redirect_5222 должен быть boolean')
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:[.-][A-Za-z0-9.-]+)?', p['engine_version']):
        raise Error('Неверная версия Zapret2')
    if not re.fullmatch(r'[a-f0-9]{64}', p['engine_sha256']):
        raise Error('Неверная SHA256')


def profile_names(scope):
    return list(PROFILES) if scope in ('both', 'all') else [valid_profile(scope)]


def units(name):
    valid_profile(name)
    return [f'forcus-zapret-{name}-socks.service', f'forcus-zapret-{name}-dpi.service']


def table_name(name):
    return 'fzm_' + valid_profile(name)


def render_dante(p):
    validate_profile(p)
    # These SOCKS profiles serve public services, not local administrative ports.
    # Limit to CONNECT: an UDP ASSOCIATE control request can legitimately name 0.0.0.0.
    blocks = ''.join(f'''socks block {{
 from: 127.0.0.1/32 to: {network}
 command: connect
 log: error
}}
''' for network in PRIVATE_TCP_DESTINATIONS)
    return f'''# Managed by {OWNER}; {p['name']}
logoutput: syslog
internal: 127.0.0.1 port = {p['port']}
external: {p['interface']}
user.privileged: root
user.unprivileged: {p['user']}
socksmethod: none
clientmethod: none
client pass {{
 from: 127.0.0.1/32 to: 0.0.0.0/0
 log: error
}}
{blocks}\
socks pass {{
 from: 127.0.0.1/32 to: 0.0.0.0/0
 command: connect udpassociate
 protocol: tcp udp
 log: error
}}
socks pass {{
 from: 127.0.0.1/32 to: ::/0
 command: connect udpassociate
 protocol: tcp udp
 log: error
}}
'''


def render_nft(p):
    validate_profile(p)
    uid, iface, queue = p['uid'], p['interface'], p['queue']
    mark = hex(0x0F200000 + queue)
    port = ' tcp dport 443' if p['name'] == 'youtube' else ''
    sport = ' tcp sport 443' if p['name'] == 'youtube' else ''
    out = [f'table inet {table_name(p["name"])} {{', f' comment "{OWNER}"',
           ' chain output {', '  type filter hook output priority mangle; policy accept;',
           f'  meta skuid {uid} oifname "{iface}" meta l4proto tcp{port} counter ct mark set {mark}',
           f'  meta skuid {uid} oifname "{iface}" meta mark & 0x40000000 == 0 meta l4proto tcp{port} ct original packets 1-12 counter queue flags bypass to {queue}']
    if p['name'] == 'telegram':
        out += [f'  meta skuid {uid} oifname "{iface}" meta l4proto udp counter ct mark set {mark}',
                f'  meta skuid {uid} oifname "{iface}" meta mark & 0x40000000 == 0 meta l4proto udp ct original packets 1-6 counter queue flags bypass to {queue}']
    out += [' }', ' chain input {', '  type filter hook prerouting priority mangle; policy accept;',
            f'  iifname "{iface}" ct mark {mark} meta mark & 0x40000000 == 0 meta l4proto tcp{sport} ct reply packets 1-12 counter queue flags bypass to {queue}']
    if p['name'] == 'telegram':
        out += [f'  iifname "{iface}" ct mark {mark} meta mark & 0x40000000 == 0 meta l4proto udp ct reply packets 1-6 counter queue flags bypass to {queue}']
    return '\n'.join(out + [' }', '}', ''])


def engine_dir(p):
    return '/opt/forcus-zapret/engines/' + p['engine_version'] + '-' + p['engine_sha256'][:12]


def nfq_args(p, engine=None):
    validate_profile(p)
    engine = engine or engine_dir(p)
    args = [engine + '/binaries/linux-x86_64/nfqws2', '--qnum=' + str(p['queue']), '--debug=0',
            '--lua-init=@lua/zapret-lib.lua', '--lua-init=@lua/zapret-antidpi.lua']
    tls = ['--payload=tls_client_hello', '--lua-desync=fake:blob=0x00000000:tcp_md5:repeats=1',
           '--lua-desync=fake:blob=fake_default_tls:tcp_md5:tls_mod=rnd,dupsid:repeats=1',
           '--lua-desync=multisplit:pos=2']
    if p['name'] == 'youtube':
        return args + ['--name=YouTube', '--filter-tcp=443', '--filter-l7=tls',
                       '--hostlist-domains=googlevideo.com,youtube.com,ytimg.com,youtubei.googleapis.com'] + tls
    return args + ['--name=Telegram-TLS', '--filter-tcp=*', '--filter-l7=tls'] + tls + [
        '--new=Telegram-MTProto', '--filter-tcp=*', '--filter-l7=mtproto,unknown',
        '--payload=mtproto_initial,unknown', '--out-range=-d8',
        '--lua-desync=fake:blob=0x00000000:tcp_md5:repeats=2:payload=all',
        '--lua-desync=multisplit:pos=2:payload=all',
        '--new=Telegram-UDP', '--filter-udp=*', '--payload=all', '--lua-desync=pass']


def render_units(p):
    name = p['name']
    socks, dpi = units(name)
    return {
        socks: f'''# Managed by {OWNER}
[Unit]
Description=Forcus {LABELS[name]} local SOCKS5
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/sbin/danted -f /etc/forcus-zapret/{name}.danted.conf -p /run/forcus-zapret-{name}.pid
Restart=on-failure
RestartSec=3
LimitNOFILE=16384
[Install]
WantedBy=multi-user.target
''',
        dpi: f'''# Managed by {OWNER}
[Unit]
Description=Forcus {LABELS[name]} Zapret2 processing
After=network-online.target {socks}
Wants=network-online.target {socks}
[Service]
Type=simple
WorkingDirectory={engine_dir(p)}
ExecStartPre=/usr/local/sbin/forcus-zapret ensure --profile {name}
ExecStart={' '.join(nfq_args(p))}
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
'''}


def xray_fragment(profiles, selections):
    outbounds, rules = [], []
    for name, tags in selections.items():
        valid_profile(name)
        if name not in profiles:
            raise Error('Сначала установи профиль ' + name)
        if not tags or len(tags) != len(set(tags)) or any(not re.fullmatch(r'[A-Za-z0-9_.:@+-]{1,128}', x) for x in tags):
            raise Error('Нужны уникальные inboundTag без пробелов и управляющих символов')
        p = profiles[name]
        tag = 'fzm-' + name
        outbounds.append({'tag': tag, 'protocol': 'socks', 'settings': {'servers': [{'address': '127.0.0.1', 'port': p['port']}]}})
        if name == 'youtube':
            rules += [dict(type='field', ruleTag='fzm-youtube-quic', inboundTag=tags, domain=YOUTUBE_DOMAINS,
                           network='udp', port='443', outboundTag='blocked'),
                      dict(type='field', ruleTag='fzm-youtube-tcp', inboundTag=tags, domain=YOUTUBE_DOMAINS,
                           network='tcp', outboundTag=tag)]
            continue
        selectors = [('domains', {'domain': ['geosite:telegram']}),
                     ('ip', {'ip': ['geoip:telegram'] + TELEGRAM_CIDRS})]
        bases = [dict(type='field', ruleTag='fzm-telegram-' + key, inboundTag=tags, network='tcp,udp', outboundTag=tag, **selector) for key, selector in selectors]
        if p.get('redirect_5222'):
            remap_tag = 'fzm-telegram-mtproto'
            outbounds.append({'tag': remap_tag, 'protocol': 'freedom', 'settings': {'redirect': ':5222'},
                              'streamSettings': {'sockopt': {'dialerProxy': tag}}})
            for r in bases:
                rules.append(dict(r, ruleTag=r['ruleTag']+'-tls', network='tcp', protocol=['tls', 'http']))
            for r in bases:
                rules.append(dict(r, ruleTag=r['ruleTag']+'-port', network='tcp', port='80,443', outboundTag=remap_tag))
        rules += bases
    return {'outbounds': outbounds, 'routing': {'rules': rules}}


def patch_xray(original, profiles, selections, insert_at=None):
    c = copy.deepcopy(original)
    if not isinstance(c.get('outbounds'), list) or not c['outbounds'] or not isinstance(c.get('routing', {}).get('rules'), list):
        raise Error('Нужен полный Xray JSON с outbounds и routing.rules')
    fragment = xray_fragment(profiles, selections)
    prefixes = tuple('fzm-' + name + '-' for name in selections)
    existing_tags = {o['tag'] for o in fragment['outbounds']}
    old_out = {o.get('tag'): o for o in c['outbounds']}
    for o in fragment['outbounds']:
        if o['tag'] in old_out and old_out[o['tag']] != o:
            raise Error('Конфликт outbound ' + o['tag'] + '; сначала отключи старую привязку')
    rules = [r for r in c['routing']['rules'] if not r.get('ruleTag', '').startswith(prefixes)]
    if insert_at is None:
        insert_at = 0
        # Keep leading API/private-address safety and the existing gstatic probe exception.
        for r in rules:
            if (r.get('outboundTag') == 'api' or r.get('ip') == ['geoip:private'] or
                    r.get('domain') == ['full:www.gstatic.com']):
                insert_at += 1
            else:
                break
    if not 0 <= insert_at <= len(rules):
        raise Error('Неверная позиция вставки правил')
    rules[insert_at:insert_at] = fragment['routing']['rules']
    c['routing']['rules'] = rules
    c['outbounds'] += [o for o in fragment['outbounds'] if o['tag'] not in old_out]
    if 'blocked' not in old_out:
        c['outbounds'].append({'tag': 'blocked', 'protocol': 'blackhole', 'settings': {}})
    return c


def detach_xray(original, names):
    c = copy.deepcopy(original)
    prefixes = tuple('fzm-' + valid_profile(n) + '-' for n in names)
    owned_tags = {'fzm-' + n for n in names}
    if 'telegram' in names:
        owned_tags.add('fzm-telegram-mtproto')
    c['routing']['rules'] = [r for r in c['routing']['rules'] if not r.get('ruleTag', '').startswith(prefixes)]
    for rule in c['routing']['rules']:
        if rule.get('outboundTag') in owned_tags:
            raise Error('Пользовательское правило использует наш outbound; сначала исправь его')
    for outbound in c['outbounds']:
        if outbound.get('tag') not in owned_tags and (
                outbound.get('proxySettings', {}).get('tag') in owned_tags or
                outbound.get('streamSettings', {}).get('sockopt', {}).get('dialerProxy') in owned_tags):
            raise Error('Другой outbound использует наш прокси; отключение остановлено')
    c['outbounds'] = [o for o in c['outbounds'] if o.get('tag') not in owned_tags]
    return c


class System:
    def __init__(self, root=Path('/')):
        self.root = Path(root)

    def path(self, path):
        return self.root / path.lstrip('/')

    def run(self, args, *, check=True, input=None, timeout=180, cwd=None, env=None):
        p = subprocess.run(list(map(str, args)), input=input, text=True, capture_output=True, timeout=timeout, cwd=cwd, env=env)
        if check and p.returncode:
            detail = (p.stderr + p.stdout)[-2000:].strip() or 'код завершения '+str(p.returncode)
            if Path(str(args[0])).name == 'danted':
                detail += '; подробная причина: journalctl -t danted -n 30 --no-pager'
            raise Error(str(args[0]) + ': ' + detail)
        return p

    def load(self):
        f = self.path('/etc/forcus-zapret/state.json')
        if not f.exists():
            return {'owner': OWNER, 'schema': 1, 'version': VERSION, 'profiles': {}, 'links': []}
        if f.is_symlink():
            raise Error('State не должен быть symlink')
        data = json.loads(f.read_text())
        if data.get('owner') != OWNER or data.get('schema') != 1:
            raise Error('Неизвестное состояние менеджера')
        for p in data['profiles'].values():
            validate_profile(p)
        return data

    def save(self, state):
        d = self.path('/etc/forcus-zapret'); d.mkdir(mode=0o700, parents=True, exist_ok=True)
        write_atomic(d/'state.json', json_text(state))

    @contextlib.contextmanager
    def lock(self):
        f = self.path('/run/lock/forcus-zapret.lock'); f.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(f, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Error('Другой процесс менеджера уже выполняет изменение')
            yield
        finally:
            os.close(fd)

    def preflight(self):
        if sys.version_info < (3, 10):
            raise Error('Нужен Python 3.10+')
        if os.geteuid() != 0:
            raise Error('Запусти от root: sudo bash install_forcus_zapret.sh')
        release = dict(line.split('=', 1) for line in self.path('/etc/os-release').read_text().splitlines() if '=' in line)
        if release.get('ID', '').strip('"') not in ('ubuntu', 'debian'):
            raise Error('Поддерживаются Ubuntu / Debian с systemd')
        if platform.machine() != 'x86_64':
            raise Error('Эта версия поддерживает только x86_64 / amd64')
        if not self.path('/run/systemd/system').is_dir():
            raise Error('Нужен работающий systemd; запускай на VPS-хосте')

    def dependencies(self):
        missing = [p for p in PACKAGES if self.run(['dpkg-query', '-W', '-f=${Status}', p], check=False).stdout.strip() != 'install ok installed']
        if missing:
            stock_dante_absent = not any(self.path(p).exists() for p in (
                '/etc/danted.conf', '/etc/systemd/system/danted.service',
                '/lib/systemd/system/danted.service', '/usr/lib/systemd/system/danted.service'))
            print('Установка зависимостей: ' + ', '.join(missing), flush=True)
            apt_env = dict(os.environ, DEBIAN_FRONTEND='noninteractive')
            apt_options = ['-o', 'Acquire::Retries=3', '-o', 'Acquire::http::Timeout=30',
                           '-o', 'Acquire::https::Timeout=30']
            self.run(['apt-get', *apt_options, '-o', 'APT::Update::Error-Mode=any', 'update'], timeout=600, env=apt_env)
            self.run(['apt-get', 'install', '-y', '--no-install-recommends',
                      *apt_options, '-o', 'Dpkg::Options::=--force-confold', *missing], timeout=900, env=apt_env)
            if 'dante-server' in missing and stock_dante_absent:
                # A newly installed stock unit has no configured external interface.
                # We manage dedicated units and never disable a preexisting Dante.
                self.run(['systemctl', 'disable', '--now', 'danted.service'])

    def backup(self, label):
        target = self.path('/var/backups/forcus-zapret') / (stamp() + '-' + label)
        target.mkdir(parents=True, mode=0o700)
        state_file = self.path('/etc/forcus-zapret/state.json')
        if state_file.exists():
            shutil.copy2(state_file, target/'state.json')
        nft_before = self.run(['nft', 'list', 'ruleset'], check=False).stdout
        if nft_before:
            write_atomic(target/'nft-before.txt', nft_before)
        return target

    def install_self(self):
        app = self.path('/opt/forcus-zapret'); marker = app/'.owner'
        if app.exists() and not marker.exists():
            raise Error('/opt/forcus-zapret занят чужой установкой')
        app.mkdir(parents=True, exist_ok=True, mode=0o755)
        app.chmod(0o755)
        write_atomic(marker, OWNER+'\n')
        source = Path(__file__).read_bytes()
        write_atomic(app/'forcus_zapret.py', source, 0o755)
        launcher = self.path('/usr/local/sbin/forcus-zapret')
        if launcher.exists() and OWNER not in launcher.read_text():
            raise Error('Команда forcus-zapret уже занята')
        write_atomic(launcher, '#!/bin/sh\n# '+OWNER+'\nexec /usr/bin/python3 /opt/forcus-zapret/forcus_zapret.py "$@"\n', 0o755)


def download(url, output, max_bytes=40*1024*1024):
    if not url.startswith('https://github.com/bol-van/zapret2/releases/download/'):
        raise Error('Разрешены только официальные release-архивы Zapret2')
    request = urllib.request.Request(url, headers={'User-Agent': 'Forcus-Zapret/'+VERSION})
    deadline = time.monotonic()+180
    with urllib.request.urlopen(request, timeout=45) as response, Path(output).open('wb') as f:
        if not response.geturl().startswith('https://'):
            raise Error('Отказ от перенаправления на HTTP')
        total = 0
        while chunk := response.read(1024*1024):
            if time.monotonic() > deadline:
                raise Error('Превышено время скачивания release-архива')
            total += len(chunk)
            if total > max_bytes:
                raise Error('Release-архив превышает лимит 40 MiB')
            f.write(chunk)


def unpack_engine(archive, target):
    allowed = ('binaries/linux-x86_64/', 'lua/', 'files/fake/')
    with tarfile.open(archive, 'r:gz') as tar:
        total = 0
        for member in tar:
            raw = PurePosixPath(member.name)
            if raw.is_absolute() or '..' in raw.parts:
                raise Error('Опасный путь в архиве')
            parts = raw.parts
            if len(parts) < 2:
                continue
            rel = '/'.join(parts[1:])
            if not any(rel.startswith(prefix) for prefix in allowed):
                continue
            if member.isdir():
                continue
            if not member.isfile():
                raise Error('Ссылки в исполняемых файлах архива не допускаются')
            total += member.size
            if total > 80*1024*1024 or member.size > 30*1024*1024:
                raise Error('Слишком большой распакованный архив')
            destination = Path(target)/rel
            write_atomic(destination, tar.extractfile(member).read(), 0o755 if rel.endswith('/nfqws2') else 0o644)
    for name in ('binaries/linux-x86_64/nfqws2', 'lua/zapret-lib.lua', 'lua/zapret-antidpi.lua'):
        if not (Path(target)/name).is_file():
            raise Error('Неполный официальный release-архив: ' + name)


def ensure_engine(system, version, sha256):
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:[.-][A-Za-z0-9.-]+)?', version) or not re.fullmatch('[a-f0-9]{64}', sha256):
        raise Error('Нужны версия vX.Y.Z и SHA256 release-архива')
    target = system.path('/opt/forcus-zapret/engines')/(version+'-'+sha256[:12])
    marker = target/'.archive-sha256'
    binary = target/'binaries/linux-x86_64/nfqws2'
    if marker.exists() and marker.read_text().strip() == sha256 and binary.is_file():
        system.run([binary, '--version'])
        return target
    if target.exists():
        raise Error('Неполная существующая копия движка; сохранена для диагностики: ' + str(target))
    cache = system.path('/var/cache/forcus-zapret'); cache.mkdir(parents=True, mode=0o700, exist_ok=True)
    archive = cache/(version+'-'+sha256[:12]+'.tar.gz')
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != sha256:
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as f:
            tmp = Path(f.name)
        try:
            download(f'https://github.com/bol-van/zapret2/releases/download/{version}/zapret2-{version}.tar.gz', tmp)
            if hashlib.sha256(tmp.read_bytes()).hexdigest() != sha256:
                raise Error('SHA256 архива не совпала; службы не изменены')
            tmp.replace(archive)
        finally:
            tmp.unlink(missing_ok=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.parent.chmod(0o755)
    temp = Path(tempfile.mkdtemp(prefix='.prepare-', dir=target.parent))
    try:
        unpack_engine(archive, temp)
        temp.chmod(0o755)
        for directory in temp.rglob('*'):
            if directory.is_dir():
                directory.chmod(0o755)
        system.run([temp/'binaries/linux-x86_64/nfqws2', '--version'])
        write_atomic(temp/'.archive-sha256', sha256+'\n')
        temp.rename(target)
    finally:
        if temp.exists():
            shutil.rmtree(temp)
    return target


def port_free(port):
    with socket.socket() as s:
        try:
            s.bind(('127.0.0.1', port))
            return True
        except OSError:
            return False


def choose_port(preferred, reserved=(), explicit=False):
    candidates = [preferred] if explicit else list(range(preferred, 65536)) + list(range(10808, preferred))
    for port in candidates:
        if 1024 <= port <= 65535 and port not in reserved and port_free(port):
            return port
    raise Error('Нет свободного SOCKS-порта' if not explicit else f'Порт {preferred} занят')


def queue_numbers(system):
    result = set()
    queue_file = system.path('/proc/net/netfilter/nfnetlink_queue')
    if queue_file.exists():
        for line in queue_file.read_text().splitlines():
            if line.split():
                result.add(int(line.split()[0]))
    text = system.run(['nft', 'list', 'ruleset'], check=False).stdout
    for start, end in re.findall(r'queue\s+(?:flags\s+[a-z,]+\s+)?(?:to\s+|num\s+)?(\d+)(?:-(\d+))?', text):
        result.update(range(int(start), int(end or start)+1))
    result.update(p['queue'] for p in system.load()['profiles'].values())
    return result


def tcp_open(ip, port, timeout=1.5):
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def port_policy(mode):
    if mode == 'off':
        return False, []
    observations = [{'ip': ip, 'tcp443': tcp_open(ip, 443), 'tcp5222': tcp_open(ip, 5222)}
                    for _, ip in TELEGRAM_DCS if ip in ('149.154.167.51', '149.154.167.91')]
    enabled = mode == '5222' or any(not o['tcp443'] and o['tcp5222'] for o in observations)
    return enabled, observations


def managed_table(system, name):
    r = system.run(['nft', 'list', 'table', 'inet', table_name(name)], check=False)
    if r.returncode:
        return False
    if f'comment "{OWNER}"' not in r.stdout:
        raise Error('Таблица ' + table_name(name) + ' не принадлежит менеджеру')
    return True


def ensure_profile(system, name):
    state = system.load()
    if name not in state['profiles']:
        raise Error('Профиль не установлен: ' + name)
    p = state['profiles'][name]
    uid = int(system.run(['id', '-u', p['user']]).stdout.strip())
    if uid != p['uid']:
        raise Error('UID пользователя изменился; восстановление таблицы остановлено')
    if not system.path('/proc/sys/net/netfilter/nf_conntrack_acct').exists():
        system.run(['modprobe', 'nf_conntrack'])
    system.run(['sysctl', '-q', '-w', 'net.netfilter.nf_conntrack_acct=1'])
    if not managed_table(system, name):
        system.run(['nft', '-f', system.path('/etc/forcus-zapret/'+name+'.nft')])


def install_profile(system, name, *, port=None, queue=None, interface=None, telegram_port_mode='auto'):
    valid_profile(name)
    state = system.load()
    if name in state['profiles']:
        p = state['profiles'][name]
        if (port is not None and port != p['port']) or (queue is not None and queue != p['queue']):
            raise Error('Уже установлен с другими портами/очередью; сначала удали привязку и профиль')
        print(LABELS[name]+': уже установлен; существующий профиль сохранён')
        return p
    interface = interface or json.loads(system.run(['ip', '-j', '-4', 'route', 'get', '1.1.1.1']).stdout)[0]['dev']
    system.run(['ip', 'link', 'show', 'dev', interface])
    port = choose_port(port or (10808 if name == 'youtube' else 10809),
                       [p['port'] for p in state['profiles'].values()], explicit=port is not None)
    used_queues = queue_numbers(system)
    if queue is not None and queue in used_queues:
        raise Error(f'Очередь {queue} занята; существующий обработчик сохранён')
    queue = queue or next((q for q in range(200, 65536) if q not in used_queues), None)
    if queue is None:
        raise Error('Нет свободной NFQUEUE')
    for file in [system.path('/etc/forcus-zapret/'+name+'.danted.conf'),
                 system.path('/etc/forcus-zapret/'+name+'.nft'),
                 *[system.path('/etc/systemd/system/'+u) for u in units(name)]]:
        if file.exists():
            raise Error('Чужой или незавершённый файл уже существует: ' + str(file))
    if system.run(['nft', 'list', 'table', 'inet', table_name(name)], check=False).returncode == 0:
        raise Error('Таблица '+table_name(name)+' уже существует')
    if system.run(['getent', 'passwd', USERS[name]], check=False).returncode == 0:
        raise Error('Пользователь '+USERS[name]+' уже существует вне этого профиля')
    fallback, observations = port_policy(telegram_port_mode) if name == 'telegram' else (False, [])
    backup = system.backup('install-'+name)
    created_files, created_user = [], False
    old_state = copy.deepcopy(state)
    try:
        system.run(['useradd', '--system', '--no-create-home', '--shell', '/usr/sbin/nologin', USERS[name]])
        created_user = True
        uid = int(system.run(['id', '-u', USERS[name]]).stdout.strip())
        p = dict(name=name, user=USERS[name], uid=uid, interface=interface, port=port, queue=queue,
                 engine_version=ENGINE_VERSION, engine_sha256=ENGINE_SHA256,
                 telegram_port_mode=telegram_port_mode, redirect_5222=fallback,
                 port_observations=observations, installed_at=stamp())
        validate_profile(p)
        engine = ensure_engine(system, p['engine_version'], p['engine_sha256'])
        system.run(nfq_args(p, str(engine))+['--dry-run'], cwd=str(engine))
        rendered = {system.path('/etc/forcus-zapret/'+name+'.danted.conf'): render_dante(p),
                    system.path('/etc/forcus-zapret/'+name+'.nft'): render_nft(p)}
        rendered.update({system.path('/etc/systemd/system/'+u): text for u, text in render_units(p).items()})
        for path, text in rendered.items():
            write_atomic(path, text)
            created_files.append(path)
        system.run(['danted', '-V', '-f', system.path('/etc/forcus-zapret/'+name+'.danted.conf')])
        system.run(['nft', '-c', '-f', system.path('/etc/forcus-zapret/'+name+'.nft')])
        system.run(['systemd-analyze', 'verify', *[system.path('/etc/systemd/system/'+u) for u in units(name)]])
        # The boot helper must be able to read the profile before starting the service.
        state['profiles'][name] = p
        system.save(state)
        system.run(['systemctl', 'daemon-reload'])
        system.run(['systemctl', 'enable', '--now', *units(name)])
        for _ in range(30):
            active = all(system.run(['systemctl', 'is-active', u], check=False).stdout.strip() == 'active' for u in units(name))
            if active and not port_free(port):
                break
            time.sleep(.2)
        else:
            raise Error('Службы не смогли открыть локальный SOCKS-порт')
        for unit in units(name):
            if system.run(['systemctl', 'is-enabled', unit], check=False).stdout.strip() != 'enabled':
                raise Error('Не удалось включить автозапуск '+unit)
        write_atomic(backup/'result.json', json_text({'installed': p}))
        print(f'{LABELS[name]} установлен: SOCKS5 127.0.0.1:{port}, NFQUEUE {queue}.')
        print('Это запуск служб; доступность сервиса проверяется отдельной командой check.')
        return p
    except BaseException:
        for u in reversed(units(name)):
            system.run(['systemctl', 'disable', '--now', u], check=False)
        try:
            if managed_table(system, name):
                system.run(['nft', 'delete', 'table', 'inet', table_name(name)], check=False)
        except Error:
            pass
        for f in created_files:
            f.unlink(missing_ok=True)
        if created_user:
            system.run(['userdel', USERS[name]], check=False)
        system.save(old_state)
        system.run(['systemctl', 'daemon-reload'], check=False)
        print('Установка '+name+' откачена. Копия: '+str(backup), file=sys.stderr)
        raise


def kernel_boot_files(system):
    for logical, text in {
        '/etc/modules-load.d/forcus-zapret.conf': '# '+OWNER+'\nnf_conntrack\n',
        '/etc/sysctl.d/91-forcus-zapret.conf': '# '+OWNER+'\nnet.netfilter.nf_conntrack_acct = 1\n',
    }.items():
        path = system.path(logical)
        if path.exists() and OWNER not in path.read_text():
            raise Error('Существующий файл не принадлежит менеджеру: '+str(path))
        write_atomic(path, text, 0o644)
    if not system.path('/proc/sys/net/netfilter/nf_conntrack_acct').exists():
        system.run(['modprobe', 'nf_conntrack'])
    system.run(['sysctl', '-p', system.path('/etc/sysctl.d/91-forcus-zapret.conf')])


def install(system, names, **options):
    for name in names:
        valid_profile(name)
    for key, low, high in [('port', 1024, 65535), ('queue', 1, 65535)]:
        value = options.get(key)
        if value is not None and (type(value) is not int or not low <= value <= high):
            raise Error(f'{key}: {low}–{high}')
    if options.get('telegram_port_mode', 'auto') not in ('auto', 'off', '5222'):
        raise Error('Telegram port mode: auto/off/5222')
    system.preflight()
    with system.lock():
        system.dependencies()
        system.install_self()
        kernel_boot_files(system)
        completed = []
        for name in names:
            try:
                install_profile(system, name, **options)
                completed.append(name)
            except BaseException:
                if completed:
                    print('Сохранены успешно установленные профили: '+', '.join(completed), file=sys.stderr)
                raise
    print('Меню: forcus-zapret\nПроверка: forcus-zapret check --profile all')


def status(system, names):
    state = system.load()
    for name in names:
        print('\n'+LABELS[name])
        if name not in state['profiles']:
            print('  Не установлен')
            continue
        p = state['profiles'][name]
        print(f'  SOCKS: 127.0.0.1:{p["port"]}; интерфейс {p["interface"]}; очередь {p["queue"]}')
        for unit in units(name):
            active = system.run(['systemctl', 'is-active', unit], check=False).stdout.strip() or 'unknown'
            enabled = system.run(['systemctl', 'is-enabled', unit], check=False).stdout.strip() or 'unknown'
            print('  '+unit+': '+active+'; '+enabled)
        print('  Zapret2: '+p['engine_version'])
        if name == 'telegram':
            print('  MTProto 80/443 → 5222: '+('включено' if p.get('redirect_5222') else 'выключено'))
        print('  Xray: '+('привязан' if any(name in link['selections'] for link in state['links']) else 'не привязан менеджером'))
        if any(name in link['selections'] and link.get('pending') for link in state['links']):
            print('  Xray: сохранена незавершённая операция; проверь/повтори apply перед удалением профиля')
        result = p.get('last_check')
        if not result:
            print('  Проверка: ещё не выполнялась')
        else:
            print('  Проверка: '+result.get('status', 'unknown')+'; '+result.get('checked_at', 'время неизвестно'))
            if result.get('proxy_ip'):
                print('  IP прокси: '+result['proxy_ip']+'; совпадает с VPS: '+str(result.get('same_egress')))
            if name == 'telegram' and 'successful_dcs' in result:
                print(f'  MTProto: {result["successful_dcs"]}/{len(result.get("mtproto", []))} контрольных DC; звонки отдельно не проверены')
            elif name == 'youtube':
                print('  HTTPS: '+result.get('http_status', 'unknown')+'; скорость видео отдельно не измерялась')


def service_action(system, names, action):
    system.preflight()
    with system.lock():
        state = system.load()
        for name in names:
            if name not in state['profiles']:
                raise Error('Не установлен: '+name)
            selected = units(name) if action != 'stop' else list(reversed(units(name)))
            system.run(['systemctl', action, *selected])
            print(name+': '+action)


def remove_profile(system, name):
    state = system.load()
    if name not in state['profiles']:
        print(name+': не установлен')
        return
    if any(name in link['selections'] for link in state['links']):
        raise Error('Сначала отключи привязку Xray: forcus-zapret xray detach --profile '+name)
    backup = system.backup('remove-'+name)
    p = state['profiles'][name]
    for logical in ['/etc/forcus-zapret/'+name+'.danted.conf', '/etc/forcus-zapret/'+name+'.nft',
                    *['/etc/systemd/system/'+u for u in units(name)]]:
        path = system.path(logical)
        if path.exists():
            if OWNER not in path.read_text():
                raise Error('Отказ удаления изменённого чужого файла: '+str(path))
            shutil.copy2(path, backup/path.name)
    # Verify table ownership before stopping anything.
    exists = managed_table(system, name)
    for u in reversed(units(name)):
        system.run(['systemctl', 'disable', '--now', u])
    if exists:
        system.run(['nft', 'delete', 'table', 'inet', table_name(name)])
    for logical in ['/etc/forcus-zapret/'+name+'.danted.conf', '/etc/forcus-zapret/'+name+'.nft',
                    *['/etc/systemd/system/'+u for u in units(name)]]:
        system.path(logical).unlink(missing_ok=True)
    state['profiles'].pop(name)
    system.save(state)
    system.run(['systemctl', 'daemon-reload'])
    if system.run(['pgrep', '-u', str(p['uid'])], check=False).returncode != 0:
        system.run(['userdel', p['user']], check=False)
    print(name+' удалён; резервная копия '+str(backup))


def export_backup(system, output=None):
    with system.lock():
        system.load()
        folder = system.backup('export')
        output = Path(output) if output else folder/'forcus-zapret-backup.tar.gz'
        if output.exists() or output.is_symlink():
            raise Error('Выходной файл уже существует')
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as f:
            temp = Path(f.name)
        try:
            with tarfile.open(temp, 'w:gz') as archive:
                for logical in ['/etc/forcus-zapret', '/etc/modules-load.d/forcus-zapret.conf',
                                '/etc/sysctl.d/91-forcus-zapret.conf', '/opt/forcus-zapret/forcus_zapret.py']:
                    path = system.path(logical)
                    if path.exists():
                        archive.add(path, arcname=logical.lstrip('/'))
                for path in system.path('/etc/systemd/system').glob('forcus-zapret-*.service'):
                    archive.add(path, arcname='etc/systemd/system/'+path.name)
                archive.add(folder/'state.json', arcname='state.json') if (folder/'state.json').exists() else None
                if (folder/'nft-before.txt').exists():
                    archive.add(folder/'nft-before.txt', arcname='nft-before.txt')
            temp.chmod(0o600)
            temp.replace(output)
        finally:
            temp.unlink(missing_ok=True)
        print('Копия собственных настроек: '+str(output))
        print('Шаблоны панели до/после привязок отдельно сохранены в /var/backups/forcus-zapret.')
        return output


def uninstall(system):
    system.preflight()
    with system.lock():
        state = system.load()
        if state['links']:
            raise Error('Сначала отключи Xray: forcus-zapret xray detach --profile all --yes')
        for name in list(state['profiles']):
            remove_profile(system, name)
        for logical in ['/etc/modules-load.d/forcus-zapret.conf', '/etc/sysctl.d/91-forcus-zapret.conf',
                        '/usr/local/sbin/forcus-zapret']:
            path = system.path(logical)
            if path.exists() and OWNER in path.read_text():
                path.unlink()
        app = system.path('/opt/forcus-zapret')
        if (app/'.owner').is_file() and (app/'.owner').read_text().strip() == OWNER:
            shutil.rmtree(app)
        config_dir = system.path('/etc/forcus-zapret')
        (config_dir/'state.json').unlink(missing_ok=True)
        if config_dir.exists() and not any(config_dir.iterdir()):
            config_dir.rmdir()
        cache = system.path('/var/cache/forcus-zapret')
        if cache.exists():
            for path in cache.glob('v*-*.tar.gz'):
                if path.is_file() and re.fullmatch(r'v[0-9A-Za-z.-]+-[a-f0-9]{12}\.tar\.gz', path.name):
                    path.unlink()
            if not any(cache.iterdir()):
                cache.rmdir()
        print('Менеджер удалён. Резервные копии в /var/backups/forcus-zapret сохранены; системные пакеты оставлены.')


class TemplateStore:
    """Compare-and-swap only the Xray template; never restore the whole user DB."""
    def __init__(self, system, spec):
        self.system, self.spec = system, dict(spec)
        if self.spec['backend'] not in ('postgres', 'sqlite', 'standalone'):
            raise Error('Неизвестное хранилище Xray')
        if self.spec['backend'] == 'postgres':
            for key in ('database', 'pg_user'):
                if not re.fullmatch('[A-Za-z0-9_-]+', self.spec[key]):
                    raise Error('Неверное имя PostgreSQL')

    def pg(self, query):
        return self.system.run(['runuser', '-u', self.spec['pg_user'], '--', 'psql', '-XAtq',
                                '-v', 'ON_ERROR_STOP=1', '-d', self.spec['database']], input=query).stdout.strip()

    def read(self):
        kind = self.spec['backend']
        if kind == 'postgres':
            result = self.pg("SELECT json_build_object('value',value)::text FROM settings WHERE key='xrayTemplateConfig';")
            if not result:
                raise Error('В PostgreSQL нет xrayTemplateConfig')
            return json.loads(result)['value']
        path = self.system.path(self.spec['config'])
        if path.is_symlink() or not path.is_file():
            raise Error('Нет обычного файла хранилища Xray: '+str(path))
        if kind == 'standalone':
            return path.read_text()
        with contextlib.closing(sqlite3.connect(path.as_uri()+'?mode=ro', uri=True)) as db:
            row = db.execute('SELECT value FROM settings WHERE key=?', ('xrayTemplateConfig',)).fetchone()
            if row is None:
                raise Error('В SQLite нет xrayTemplateConfig')
            return row[0]

    def compare_set(self, before, after):
        if self.spec['backend'] == 'postgres':
            quote = lambda s: "'"+s.replace("'", "''")+"'"
            result = self.pg("SET standard_conforming_strings=on; UPDATE settings SET value="+quote(after)+
                             " WHERE key='xrayTemplateConfig' AND value="+quote(before)+' RETURNING id;')
            if not result.isdecimal():
                raise Error('Шаблон параллельно изменён; запись остановлена')
        elif self.spec['backend'] == 'sqlite':
            with contextlib.closing(sqlite3.connect(self.system.path(self.spec['config']), timeout=10)) as db, db:
                db.execute('BEGIN IMMEDIATE')
                cur = db.execute('UPDATE settings SET value=? WHERE key=? AND value=?', (after, 'xrayTemplateConfig', before))
                if cur.rowcount != 1:
                    raise Error('Шаблон параллельно изменён; запись остановлена')
        else:
            path = self.system.path(self.spec['config'])
            if path.read_text() != before:
                raise Error('Конфиг параллельно изменён; запись остановлена')
            write_atomic(path, after)


def discover_store(system, backend='auto', config=None, database='xui', pg_user='postgres'):
    if backend == 'standalone':
        if not config:
            raise Error('Укажи --config для standalone Xray')
        if config == '/usr/local/x-ui/bin/config.json':
            raise Error('Это сгенерированный файл 3x-ui: используй postgres/sqlite, а не standalone')
        return TemplateStore(system, dict(backend=backend, config=config))
    if backend in ('auto', 'postgres'):
        store = TemplateStore(system, dict(backend='postgres', database=database, pg_user=pg_user))
        try:
            json.loads(store.read())
            return store
        except (Error, OSError, ValueError):
            if backend == 'postgres':
                raise
    for path in ([config] if config else ['/etc/x-ui/x-ui.db', '/usr/local/x-ui/db/x-ui.db']):
        if path and system.path(path).is_file():
            store = TemplateStore(system, dict(backend='sqlite', config=path))
            json.loads(store.read())
            return store
    raise Error('Не найдено хранилище 3x-ui. Укажи postgres/sqlite/standalone или используй xray prepare')


def validate_api(value):
    from urllib.parse import urlsplit
    try:
        address = urlsplit('//'+value)
        if address.hostname != 'localhost' and not ipaddress.ip_address(address.hostname).is_loopback:
            raise ValueError()
        if address.path or not 1 <= address.port <= 65535:
            raise ValueError()
    except (ValueError, TypeError):
        raise Error('API разрешено только на loopback, например 127.0.0.1:62789')
    return value


def resolve_binary(path=None):
    candidates = [path] if path else ['/usr/local/x-ui/bin/xray-linux-amd64', '/usr/local/bin/xray', '/usr/bin/xray']
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise Error('Не найден Xray; укажи --binary')


def apply_template(system, store, new, *, binary, api, runtime_path=None):
    """Validate, add outbounds, replace full routing, CAS persistent storage; rollback on errors."""
    validate_api(api)
    before_raw = store.read()
    before = json.loads(before_raw)
    if before == new:
        return None
    if any(before.get(key) != new.get(key) for key in set(before) | set(new) if key not in ('outbounds', 'routing')):
        raise Error('Горячее применение разрешено только для routing/outbounds')
    if {k:v for k,v in before['routing'].items() if k != 'rules'} != {k:v for k,v in new['routing'].items() if k != 'rules'}:
        raise Error('Изменение общих параметров routing не допускается')
    foreign_rules = lambda c: [r for r in c['routing']['rules'] if not r.get('ruleTag', '').startswith('fzm-')]
    if foreign_rules(before) != foreign_rules(new):
        raise Error('Чужие правила и их порядок должны сохраняться')
    desired_out = {o['tag']:o for o in new['outbounds']}
    for o in before['outbounds']:
        if not o['tag'].startswith('fzm-') and desired_out.get(o['tag']) != o:
            raise Error('Нельзя удалить или изменить чужой outbound: '+o['tag'])
    backup = system.backup('xray')
    write_atomic(backup/'template-before.json', before_raw)
    after_raw = json_text(new)
    write_atomic(backup/'template-after.json', after_raw)
    runtime_file = system.path(runtime_path) if runtime_path else None
    runtime_before = runtime_file.read_text() if runtime_file and runtime_file.exists() else None
    live_old = json.loads(runtime_before) if runtime_before else copy.deepcopy(before)
    live_new = copy.deepcopy(live_old)
    live_new['routing'], live_new['outbounds'] = copy.deepcopy(new['routing']), copy.deepcopy(new['outbounds'])
    write_atomic(backup/'runtime-before.json', json_text(live_old))
    candidate = backup/'runtime-candidate.json'
    write_atomic(candidate, json_text(live_new))
    cwd = str(Path(binary).parent)
    system.run([binary, 'run', '-test', '-c', candidate], cwd=cwd)
    system.run([binary, 'api', 'lsrules', '--server='+api], cwd=cwd)
    old_out = {o['tag']: o for o in before['outbounds']}
    for o in new['outbounds']:
        if o['tag'] in old_out and o != old_out[o['tag']]:
            raise Error('Изменение существующего outbound не допускается: '+o['tag'])
    additions = [o for o in new['outbounds'] if o['tag'] not in old_out]
    if any(not o['tag'].startswith('fzm-') and o['tag'] != 'blocked' for o in additions):
        raise Error('Попытка добавить чужой outbound')
    if runtime_before is not None and runtime_file.read_text() != runtime_before:
        raise Error('Runtime изменился во время проверки')
    added, persisted, routed = [], False, False
    def api_call(cmd, arg):
        return system.run([binary, 'api', cmd, '--server='+api, arg], cwd=cwd)
    try:
        for index, outbound in enumerate(additions):
            f = backup/('outbound-'+str(index)+'.json'); write_atomic(f, json_text({'outbounds': [outbound]}))
            api_call('ado', f)
            added.append(outbound['tag'])
        routed = True
        api_call('adrules', candidate)
        store.compare_set(before_raw, after_raw)
        persisted = True
        same_standalone = store.spec['backend'] == 'standalone' and runtime_path == store.spec.get('config')
        if runtime_before is not None and not same_standalone:
            if runtime_file.read_text() != runtime_before:
                raise Error('Runtime параллельно изменился; требуется откат')
            write_atomic(runtime_file, json_text(live_new))
    except BaseException as original_error:
        failures = []
        if persisted:
            try:
                store.compare_set(after_raw, before_raw)
            except Exception as e:
                failures.append('Не удалось вернуть постоянный шаблон: '+str(e))
        if routed:
            try:
                api_call('adrules', backup/'runtime-before.json')
            except Exception as e:
                failures.append('Не удалось вернуть правила API: '+str(e))
        for tag in reversed(added):
            try:
                api_call('rmo', tag)
            except Exception as e:
                failures.append('Не удалось удалить временный outbound '+tag+': '+str(e))
        if failures:
            raise Error('Применение не завершено. '+ '; '.join(failures)+'. Копия: '+str(backup)) from original_error
        raise
    # Remove unused owned handlers only after rules and permanent storage no longer reference them.
    removed = [tag for tag in old_out if tag.startswith('fzm-') and not any(o['tag'] == tag for o in new['outbounds'])]
    for tag in reversed(removed):
        api_call('rmo', tag)
    write_atomic(backup/'result.json', json_text({'applied': True, 'store': store.spec, 'api': api}))
    return backup


def xray_apply(system, selections, *, backend='auto', config=None, database='xui', pg_user='postgres',
               binary=None, api='127.0.0.1:62789', runtime='/usr/local/x-ui/bin/config.json', insert_at=None):
    system.preflight()
    with system.lock():
        state = system.load()
        for name in selections:
            if name not in state['profiles']:
                raise Error('Сначала установи профиль '+name)
            for unit in units(name):
                if system.run(['systemctl', 'is-active', unit], check=False).stdout.strip() != 'active':
                    raise Error('Сначала запусти службу '+unit)
        store = discover_store(system, backend, config, database, pg_user)
        before = json.loads(store.read())
        after = patch_xray(before, state['profiles'], selections, insert_at)
        binary = binary or resolve_binary()
        old_state = copy.deepcopy(state)
        spec = dict(store=store.spec, binary=binary, api=api, runtime=runtime, selections=dict(selections))
        existing = next((link for link in state['links'] if link['store'] == store.spec), None)
        if existing:
            existing['selections'].update(selections)
            existing.update({k: v for k, v in spec.items() if k != 'selections'})
        else:
            state['links'].append(spec)
        # Persist ownership intent before touching Xray: even disk failure after apply
        # must not make the still-referenced SOCKS profile look safe to delete.
        current_link = next(link for link in state['links'] if link['store'] == store.spec)
        current_link['pending'] = True
        system.save(state)
        try:
            backup = apply_template(system, store, after, binary=binary, api=api, runtime_path=runtime)
        except BaseException:
            if json.loads(store.read()) == before:
                system.save(old_state)
            raise
        current_link['pending'] = False
        system.save(state)
        print('Xray: сохранено и применено без перезапуска. Копия: '+str(backup or 'изменений нет'))


def xray_detach(system, names):
    system.preflight()
    with system.lock():
        state = system.load()
        for link in list(state['links']):
            selected = [name for name in names if name in link['selections']]
            if not selected:
                continue
            store = TemplateStore(system, link['store'])
            after = detach_xray(json.loads(store.read()), selected)
            apply_template(system, store, after, binary=link['binary'], api=link['api'], runtime_path=link['runtime'])
            for name in selected:
                link['selections'].pop(name)
            if not link['selections']:
                state['links'].remove(link)
            system.save(state)
        print('Привязки Xray отключены: '+', '.join(names))


def read_exact(sock, n):
    data = b''
    while len(data) < n:
        part = sock.recv(n-len(data))
        if not part:
            raise Error('Сервер закрыл соединение')
        data += part
    return data


def socks_connect(proxy_port, destination, destination_port, timeout=4):
    s = socket.create_connection(('127.0.0.1', proxy_port), timeout=timeout)
    try:
        s.sendall(b'\x05\x01\x00')
        if read_exact(s, 2) != b'\x05\x00':
            raise Error('SOCKS5 не принял локальное соединение')
        ip = ipaddress.ip_address(destination)
        s.sendall(b'\x05\x01\x00' + (b'\x01' if ip.version == 4 else b'\x04') + ip.packed + struct.pack('>H', destination_port))
        response = read_exact(s, 4)
        if response[:2] != b'\x05\x00':
            raise Error('SOCKS отказал в соединении: '+str(response[1]))
        size = {1: 4, 4: 16}.get(response[3])
        if size is None:
            size = read_exact(s, 1)[0]
        read_exact(s, size+2)
        return s
    except BaseException:
        s.close()
        raise


def mtproto_probe(proxy_port, ip, port=443):
    """Unauthenticated obfuscated abridged req_pq_multi, never logs into an account."""
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    start = time.monotonic()
    try:
        with socks_connect(proxy_port, ip, port) as s:
            nonce = os.urandom(16)
            body = struct.pack('<I', 0xbe7e8ef1)+nonce
            packet = b'\0'*8 + struct.pack('<Q', int(time.time()*2**32) & ~3) + struct.pack('<I', len(body)) + body
            while True:
                header = bytearray(os.urandom(64))
                if header[0] != 0xef and header[:4] not in (b'HEAD', b'POST', b'GET ', b'OPTI', b'\xee'*4, b'\xdd'*4, b'\x16\x03\x01\x02') and header[4:8] != b'\0'*4:
                    break
            header[56:60] = b'\xef'*4
            enc = Cipher(algorithms.AES(bytes(header[8:40])), modes.CTR(bytes(header[40:56]))).encryptor()
            rev = header[8:56][::-1]
            dec = Cipher(algorithms.AES(bytes(rev[:32])), modes.CTR(bytes(rev[32:48]))).decryptor()
            cipher_header = enc.update(bytes(header))
            s.sendall(bytes(header[:56])+cipher_header[56:64]+enc.update(bytes([len(packet)//4])+packet))
            def read(n): return dec.update(read_exact(s, n))
            length = read(1)[0]
            if length == 127:
                length = int.from_bytes(read(3), 'little')
            if not 0 < length <= 16384:
                raise Error('Неверная длина MTProto-ответа')
            response = read(length*4)
            if response[:8] != b'\0'*8 or response[20:24] != struct.pack('<I', 0x05162463) or response[24:40] != nonce:
                raise Error('Нет корректного resPQ с совпадающим nonce')
        return {'ip': ip, 'port': port, 'ok': True, 'seconds': round(time.monotonic()-start, 3)}
    except (OSError, Error) as e:
        return {'ip': ip, 'port': port, 'ok': False, 'error': str(e), 'seconds': round(time.monotonic()-start, 3)}


def check_profiles(system, names):
    state = system.load()
    for name in names:
        if name not in state['profiles']:
            raise Error('Не установлен: '+name)
        p = state['profiles'][name]
        print('\nПроверка '+LABELS[name]+' (SOCKS, не публичного VLESS-входа):', flush=True)
        result = {'checked_at': stamp(), 'kind': 'socks-connectivity'}
        if not all(system.run(['systemctl', 'is-active', u], check=False).stdout.strip() == 'active' for u in units(name)):
            result.update(status='failed', error='Службы не активны')
        else:
            direct = system.run(['curl', '-4', '-fsS', '--max-time', '10', 'https://api.ipify.org'], check=False, timeout=15)
            proxied = system.run(['curl', '-4', '-fsS', '--max-time', '10', '--socks5-hostname',
                                  '127.0.0.1:'+str(p['port']), 'https://api.ipify.org'], check=False, timeout=15)
            result['vps_ip'] = direct.stdout.strip() if not direct.returncode else 'unknown'
            result['proxy_ip'] = proxied.stdout.strip() if not proxied.returncode else 'unknown'
            result['same_egress'] = result['vps_ip'] == result['proxy_ip'] and result['vps_ip'] != 'unknown'
            if name == 'youtube':
                r = system.run(['curl', '-4', '-sS', '-L', '--max-time', '15', '--socks5-hostname',
                                '127.0.0.1:'+str(p['port']), '-o', '/dev/null', '-w', '%{http_code}', 'https://www.youtube.com/'],
                               check=False, timeout=20)
                result.update(status='reachable' if r.returncode == 0 and r.stdout.strip() == '200' else 'inconclusive',
                              http_status=r.stdout.strip(), video_speed='not-tested')
            else:
                rows = []
                for dc, ip in TELEGRAM_DCS:
                    row = mtproto_probe(p['port'], ip, 5222 if p.get('redirect_5222') else 443)
                    row['dc'] = dc; rows.append(row)
                    print(json.dumps(row, ensure_ascii=False), flush=True)
                count = sum(r['ok'] for r in rows)
                result.update(status='reachable' if count == len(rows) else 'partial' if count else 'failed',
                              mtproto=rows, successful_dcs=count, calls='not-tested')
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
        # Merge only observations under a short lock; do not overwrite simultaneous profile changes.
        with system.lock():
            latest = system.load()
            if name in latest['profiles'] and latest['profiles'][name]['installed_at'] == p['installed_at']:
                latest['profiles'][name]['last_check'] = result
                system.save(latest)


def upgrade_engine(system, version, sha256):
    system.preflight()
    with system.lock():
        state = system.load()
        if not state['profiles']:
            raise Error('Сначала установи профиль')
        new_engine = ensure_engine(system, version, sha256)
        candidates = {}
        for name, old in state['profiles'].items():
            p = dict(old, engine_version=version, engine_sha256=sha256)
            system.run(nfq_args(p, str(new_engine))+['--dry-run'], cwd=str(new_engine))
            candidates[name] = p
        backup = system.backup('engine-update')
        old_files, activity = {}, {}
        try:
            for name, p in candidates.items():
                dpi = units(name)[1]
                path = system.path('/etc/systemd/system/'+dpi)
                old_files[path] = path.read_bytes()
                activity[dpi] = system.run(['systemctl', 'is-active', dpi], check=False).stdout.strip() == 'active'
                write_atomic(path, render_units(p)[dpi])
            system.run(['systemd-analyze', 'verify', *old_files])
            system.run(['systemctl', 'daemon-reload'])
            for unit, active in activity.items():
                if active:
                    system.run(['systemctl', 'restart', unit])
                    if system.run(['systemctl', 'is-active', unit], check=False).stdout.strip() != 'active':
                        raise Error('Новый движок не запустил '+unit)
            state['profiles'].update(candidates)
            system.save(state)
        except BaseException:
            for path, data in old_files.items():
                write_atomic(path, data)
            system.run(['systemctl', 'daemon-reload'], check=False)
            for unit, active in activity.items():
                if active:
                    system.run(['systemctl', 'restart', unit], check=False)
            raise
        print('Движок обновлён после проверки всех профилей. Копия: '+str(backup))


def confirm(text, yes=False):
    if yes:
        return True
    if not sys.stdin.isatty():
        raise Error('Для неинтерактивного изменения добавь --yes')
    return input(text+' [y/N]: ').strip().lower() in ('y', 'yes', 'да', 'д', '1')


def parse_selections(args):
    result = {}
    for name in PROFILES:
        value = getattr(args, name+'_inbounds', None)
        if value:
            result[name] = [x.strip() for x in value.split(',') if x.strip()]
    if not result:
        raise Error('Укажи --youtube-inbounds и/или --telegram-inbounds; все входы автоматически не выбираются')
    return result


def menu_select_profiles(installed=False, system=None):
    print('1 — YouTube\n2 — Telegram\n3 — Оба профиля')
    answer = input('Выбор [3]: ').strip() or '3'
    if answer not in ('1', '2', '3'):
        raise Error('Выбери 1, 2 или 3')
    return ['youtube'] if answer == '1' else ['telegram'] if answer == '2' else list(PROFILES)


def wizard(system):
    names = menu_select_profiles()
    interface = input('Интерфейс [auto]: ').strip() or None
    advanced = input('Расширенные настройки портов/очередей? [y/N]: ').strip().lower() in ('y', 'да', '1')
    options = {}
    for name in names:
        options[name] = dict(interface=interface)
        if advanced:
            port = input(LABELS[name]+' SOCKS-порт [свободный автоматически]: ').strip()
            queue = input(LABELS[name]+' NFQUEUE [свободная автоматически]: ').strip()
            options[name].update(port=int(port) if port else None, queue=int(queue) if queue else None)
        if name == 'telegram':
            mode = input('MTProto порт: auto / off / 5222 [auto]: ').strip() or 'auto'
            if mode not in ('auto', 'off', '5222'):
                raise Error('Неверный режим порта')
            options[name]['telegram_port_mode'] = mode
    print('Установка: '+', '.join(LABELS[n] for n in names)+'. Выходной IP — IP этого VPS.')
    if not confirm('Скачать зависимости и установить выбранные профили?'):
        return
    for name in names:
        install(system, [name], **options[name])
    if confirm('Подключить выбранные профили к Xray / 3x-ui сейчас?'):
        wizard_xray(system, names)


def wizard_xray(system, names=None):
    names = names or menu_select_profiles()
    runtime = '/usr/local/x-ui/bin/config.json'
    if not system.path(runtime).exists():
        runtime = input('Путь к действующему runtime JSON Xray: ').strip()
    data = json.loads(system.path(runtime).read_text())
    inbound_tags = [i['tag'] for i in data.get('inbounds', []) if i.get('tag') and i.get('tag') != 'api']
    for index, tag in enumerate(inbound_tags, 1):
        print(str(index)+' — '+tag)
    selections = {}
    for name in names:
        suggested = ['in-10443-tcp', 'in-20443-tcp']
        if name == 'youtube':
            suggested += ['in-50443-tcp', 'in-60443-tcp']
        suggested = [t for t in suggested if t in inbound_tags]
        default = ','.join(str(inbound_tags.index(t)+1) for t in suggested)
        value = input(LABELS[name]+': номера входов через запятую'+(' ['+default+']' if default else '')+': ').strip() or default
        try:
            numbers = [int(n) for n in value.split(',')]
            if not numbers or any(n < 1 or n > len(inbound_tags) for n in numbers):
                raise ValueError()
            selections[name] = [inbound_tags[n-1] for n in numbers]
        except ValueError:
            raise Error('Выбери действующие номера инбаундов')
    print(json_text(selections))
    api = input('Локальное API Xray [127.0.0.1:62789]: ').strip() or '127.0.0.1:62789'
    if confirm('Сохранить эти привязки в шаблоне панели и применить без перезапуска?'):
        xray_apply(system, selections, api=api, runtime=runtime)


def menu(system):
    if not sys.stdin.isatty():
        raise Error('Для меню нужен терминал. CLI: --help; установка: install --profile both --yes')
    while True:
        print('\nFORCUS ZAPRET MANAGER '+VERSION)
        status(system, list(PROFILES))
        print('\n1 — Установить профили (Easy / Advanced)\n2 — Проверить соединения\n3 — Start / Stop / Restart\n4 — Журнал\n5 — Привязать Xray\n6 — Показать Xray JSON\n7 — Отключить привязку Xray\n8 — Удалить профиль\n9 — Обновить движок Zapret2\n10 — Резервная копия\n11 — Полностью удалить менеджер\n0 — Выход\nr — Обновить статусы')
        choice = input('Выбор: ').strip().lower()
        try:
            if choice == '0':
                return
            if choice in ('r', ''):
                continue
            if choice == '1':
                wizard(system); continue
            if choice == '9':
                version = input('Версия [v1.0.7]: ').strip() or ENGINE_VERSION
                sha = input('SHA256 официального release-архива [для v1.0.7 известна]: ').strip() or (ENGINE_SHA256 if version == ENGINE_VERSION else '')
                if confirm('Проверить новый движок и перезапустить только DPI-службы?'):
                    upgrade_engine(system, version, sha)
                continue
            if choice == '10':
                export_backup(system); continue
            if choice == '11':
                if confirm('Удалить менеджер и все его профили? Привязки Xray должны быть отключены заранее.'):
                    uninstall(system); return
                continue
            names = menu_select_profiles()
            if choice == '2':
                check_profiles(system, names)
            elif choice == '3':
                action = input('start / stop / restart: ').strip()
                if action not in ('start', 'stop', 'restart'):
                    raise Error('Неверное действие')
                if confirm(action+' для '+', '.join(names)+'?'):
                    service_action(system, names, action)
            elif choice == '4':
                for name in names:
                    print(system.run(['journalctl', '-u', units(name)[0], '-u', units(name)[1], '-n', '50', '--no-pager'], check=False).stdout)
            elif choice == '5':
                wizard_xray(system, names)
            elif choice == '6':
                selections = {name: [x.strip() for x in input(LABELS[name]+' inboundTag через запятую: ').split(',') if x.strip()] for name in names}
                print(json_text(xray_fragment(system.load()['profiles'], selections)))
            elif choice == '7':
                if confirm('Отключить только привязки выбранных профилей?'):
                    xray_detach(system, names)
            elif choice == '8':
                if confirm('Удалить выбранные профили? Привязки Xray должны быть отключены заранее.'):
                    system.preflight()
                    with system.lock():
                        for name in names:
                            remove_profile(system, name)
            else:
                print('Неизвестный пункт')
        except (Error, OSError, ValueError, subprocess.TimeoutExpired, sqlite3.Error, tarfile.TarError) as e:
            print('Ошибка: '+str(e), file=sys.stderr)


def argument_parser():
    p = argparse.ArgumentParser(description='Forcus Zapret Manager — YouTube / Telegram, local SOCKS5, systemd')
    p.add_argument('--version', action='version', version=VERSION)
    sub = p.add_subparsers(dest='command')
    sub.add_parser('menu')
    install_p = sub.add_parser('install')
    install_p.add_argument('--profile', choices=(*PROFILES, 'both'), default='both')
    install_p.add_argument('--port', type=int)
    install_p.add_argument('--queue', type=int)
    install_p.add_argument('--interface')
    install_p.add_argument('--telegram-port-mode', choices=('auto', 'off', '5222'), default='auto')
    install_p.add_argument('--yes', action='store_true')
    for command in ('status', 'check', 'start', 'stop', 'restart', 'remove', 'logs', 'ensure'):
        item = sub.add_parser(command)
        item.add_argument('--profile', choices=(*PROFILES, 'all'), default='all' if command != 'ensure' else 'youtube')
        if command in ('start', 'stop', 'restart', 'remove'):
            item.add_argument('--yes', action='store_true')
        if command == 'logs':
            item.add_argument('--lines', type=int, default=50)
    update = sub.add_parser('update-engine')
    update.add_argument('--engine-version', default=ENGINE_VERSION)
    update.add_argument('--sha256', default=ENGINE_SHA256)
    update.add_argument('--yes', action='store_true')
    backup = sub.add_parser('backup')
    backup.add_argument('--output')
    uninstall_p = sub.add_parser('uninstall')
    uninstall_p.add_argument('--yes', action='store_true')
    xray = sub.add_parser('xray').add_subparsers(dest='xray_command', required=True)
    for command in ('show', 'prepare', 'apply'):
        q = xray.add_parser(command)
        q.add_argument('--youtube-inbounds')
        q.add_argument('--telegram-inbounds')
        if command == 'prepare':
            q.add_argument('--input', required=True)
            q.add_argument('--output', required=True)
        if command in ('prepare', 'apply'):
            q.add_argument('--insert-at', type=int)
        if command == 'apply':
            q.add_argument('--backend', choices=('auto', 'postgres', 'sqlite', 'standalone'), default='auto')
            q.add_argument('--config')
            q.add_argument('--database', default='xui')
            q.add_argument('--pg-user', default='postgres')
            q.add_argument('--binary')
            q.add_argument('--api', default='127.0.0.1:62789')
            q.add_argument('--runtime', default='/usr/local/x-ui/bin/config.json')
            q.add_argument('--yes', action='store_true')
    detach = xray.add_parser('detach')
    detach.add_argument('--profile', choices=(*PROFILES, 'all'), default='all')
    detach.add_argument('--yes', action='store_true')
    return p


def main(argv=None):
    args = argument_parser().parse_args(argv)
    system = System()
    if args.command is None or args.command == 'menu':
        system.preflight(); menu(system); return 0
    if args.command == 'install':
        if args.profile == 'both' and (args.port is not None or args.queue is not None):
            raise Error('Для двух профилей используй автоматические порты/очереди или устанавливай их отдельно')
        if confirm('Установить '+args.profile+'?', args.yes):
            install(system, profile_names(args.profile), port=args.port, queue=args.queue, interface=args.interface, telegram_port_mode=args.telegram_port_mode)
    elif args.command == 'status':
        status(system, profile_names(args.profile))
    elif args.command == 'logs':
        if not 1 <= args.lines <= 5000:
            raise Error('--lines: 1–5000')
        for name in profile_names(args.profile):
            print(system.run(['journalctl', '-u', units(name)[0], '-u', units(name)[1], '-n', str(args.lines), '--no-pager'], check=False).stdout)
    elif args.command == 'check':
        system.preflight(); check_profiles(system, profile_names(args.profile))
    elif args.command in ('start', 'stop', 'restart'):
        if confirm(args.command+' '+args.profile+'?', args.yes):
            service_action(system, profile_names(args.profile), args.command)
    elif args.command == 'ensure':
        for name in profile_names(args.profile):
            ensure_profile(system, name)
    elif args.command == 'remove':
        if confirm('Удалить '+args.profile+'?', args.yes):
            system.preflight()
            with system.lock():
                for name in profile_names(args.profile):
                    remove_profile(system, name)
    elif args.command == 'update-engine':
        if confirm('Проверить и обновить движок?', args.yes):
            upgrade_engine(system, args.engine_version, args.sha256)
    elif args.command == 'backup':
        system.preflight(); export_backup(system, args.output)
    elif args.command == 'uninstall':
        if confirm('Полностью удалить менеджер и его профили?', args.yes):
            uninstall(system)
    elif args.command == 'xray':
        if args.xray_command == 'detach':
            if confirm('Отключить привязки Xray '+args.profile+'?', args.yes):
                xray_detach(system, profile_names(args.profile))
        else:
            selections = parse_selections(args)
            if args.xray_command == 'show':
                print(json_text(xray_fragment(system.load()['profiles'], selections)))
            elif args.xray_command == 'prepare':
                src, dst = Path(args.input), Path(args.output)
                if src.resolve() == dst.resolve() or dst.exists():
                    raise Error('Нужен отдельный новый выходной файл')
                desired = patch_xray(json.loads(src.read_text()), system.load()['profiles'], selections, args.insert_at)
                write_atomic(dst, json_text(desired))
                print('Подготовлен для проверки: '+str(dst))
            elif confirm('Применить Xray только к '+json.dumps(selections, ensure_ascii=False)+'?', args.yes):
                xray_apply(system, selections, backend=args.backend, config=args.config, database=args.database,
                           pg_user=args.pg_user, binary=args.binary, api=args.api, runtime=args.runtime, insert_at=args.insert_at)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nОтменено', file=sys.stderr)
        sys.exit(130)
    except (Error, OSError, ValueError, KeyError, subprocess.TimeoutExpired, sqlite3.Error, tarfile.TarError, ImportError) as exc:
        print('Ошибка: '+str(exc), file=sys.stderr)
        sys.exit(1)

FORCUS_ZAPRET_PY_392c4bd83def6991
/usr/bin/python3 "$FZM_BOOTSTRAP_DIR/forcus_zapret.py" "$@"
