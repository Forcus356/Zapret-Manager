import copy
import contextlib
import io
import json
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import forcus_zapret as m


def profile(name='youtube', port=10808, queue=200, redirect=False):
    return dict(name=name, port=port, queue=queue, uid=995 if name=='youtube' else 994,
                user=m.USERS[name], interface='ens3', engine_version=m.ENGINE_VERSION,
                engine_sha256=m.ENGINE_SHA256, redirect_5222=redirect,
                telegram_port_mode='auto', installed_at='fixture')


def config():
    return {'inbounds': [{'tag': 'api'}],
            'outbounds': [{'tag': 'direct', 'protocol': 'freedom'}, {'tag': 'blocked', 'protocol': 'blackhole'}],
            'routing': {'domainStrategy': 'AsIs', 'rules': [
                {'type': 'field', 'inboundTag': ['api'], 'outboundTag': 'api'},
                {'type': 'field', 'domain': ['full:www.gstatic.com'], 'outboundTag': 'direct'},
                {'type': 'field', 'inboundTag': ['foreign'], 'outboundTag': 'direct'}]}}


class FakeSystem(m.System):
    def __init__(self, root):
        super().__init__(root)
        self.commands, self.tables, self.users, self.active = [], {}, {}, set()
        self.fail_enable = None
        self.fail_route = False
        self.hook = None

    def preflight(self): pass
    def dependencies(self): pass
    def install_self(self): pass

    def run(self, args, *, check=True, **kwargs):
        a = list(map(str, args)); self.commands.append(a)
        if self.hook:
            self.hook(a)
        rc, out = 0, ''
        if a[:2] == ['nft', 'list']:
            if a[2] == 'table':
                name = a[-1]
                rc, out = (0, self.tables[name]) if name in self.tables else (1, '')
            else:
                out = '\n'.join(self.tables.values())
        elif a[:2] == ['nft', '-f']:
            name = Path(a[2]).stem
            self.tables['fzm_'+name] = Path(a[2]).read_text()
        elif a[:3] == ['nft', 'delete', 'table']:
            self.tables.pop(a[-1], None)
        elif a[:2] == ['getent', 'passwd']:
            rc = 0 if a[2] in self.users else 2
        elif a[0] == 'useradd': self.users[a[-1]] = 1000+len(self.users)
        elif a[:2] == ['id', '-u']: out = str(self.users[a[2]])
        elif a[0] == 'userdel': self.users.pop(a[1], None)
        elif a[:3] == ['ip', '-j', '-4']: out = '[{"dev":"ens3"}]'
        elif a[:2] == ['systemctl', 'enable']:
            for u in a[3:]:
                if u.endswith('-dpi.service'):
                    name = u.removeprefix('forcus-zapret-').removesuffix('-dpi.service')
                    m.ensure_profile(self, name)
                if self.fail_enable and self.fail_enable in u:
                    rc = 1; break
                self.active.add(u)
        elif a[:2] == ['systemctl', 'disable']:
            self.active.difference_update(a[3:])
        elif a[:2] == ['systemctl', 'is-active']:
            rc, out = (0, 'active') if a[2] in self.active else (3, 'inactive')
        elif a[:2] == ['systemctl', 'is-enabled']: out = 'enabled'
        elif a[0] == 'pgrep': rc = 1
        elif 'api' in a and 'adrules' in a and self.fail_route:
            self.fail_route = False; rc = 1
        result = subprocess.CompletedProcess(a, rc, out, 'injected failure' if rc else '')
        if rc and check:
            raise m.Error('injected failure: '+' '.join(a))
        return result


class TempCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.system = FakeSystem(self.root)
    def tearDown(self): self.tmp.cleanup()


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.profiles = {'youtube': profile(), 'telegram': profile('telegram',10809,201,True)}

    def test_only_requested_inbounds_and_no_foreign_mutation(self):
        old = config(); saved=copy.deepcopy(old)
        result=m.patch_xray(old,self.profiles,{'telegram':['ru','ru-yt']})
        self.assertEqual(old,saved)
        self.assertEqual(result['inbounds'],old['inbounds'])
        self.assertEqual([r for r in result['routing']['rules'] if not r.get('ruleTag','').startswith('fzm-')],old['routing']['rules'])
        for r in result['routing']['rules']:
            if r.get('ruleTag','').startswith('fzm-'):self.assertEqual(r['inboundTag'],['ru','ru-yt'])
        self.assertEqual(result['outbounds'][:2],old['outbounds'])

    def test_reapply_idempotent(self):
        selection={'youtube':['ru'],'telegram':['ru','ru-yt']}
        one=m.patch_xray(config(),self.profiles,selection)
        self.assertEqual(m.patch_xray(one,self.profiles,selection),one)

    def test_detach_one_retains_other_profile_and_custom_rules(self):
        c=m.patch_xray(config(),self.profiles,{'youtube':['ru'],'telegram':['ru']})
        one=m.detach_xray(c,['youtube'])
        self.assertTrue(any(o['tag']=='fzm-telegram' for o in one['outbounds']))
        self.assertFalse(any(o['tag']=='fzm-youtube' for o in one['outbounds']))
        self.assertEqual(m.detach_xray(one,['telegram']),config())

    def test_telegram_tls_before_port_remapping(self):
        rules=m.xray_fragment(self.profiles,{'telegram':['ru']})['routing']['rules']
        self.assertEqual(len(rules),6)
        self.assertTrue(all(r.get('protocol')==['tls','http'] for r in rules[:2]))
        self.assertTrue(all(r.get('port')=='80,443' for r in rules[2:4]))
        self.assertTrue(all(r.get('network')=='tcp,udp' for r in rules[4:]))

    def test_telegram_off_never_rewrites_ports(self):
        self.profiles['telegram']['redirect_5222']=False
        f=m.xray_fragment(self.profiles,{'telegram':['ru']})
        self.assertEqual(len(f['outbounds']),1)
        self.assertEqual(len(f['routing']['rules']),2)

    def test_domain_and_ip_are_separate_or_alternatives(self):
        f=m.xray_fragment(self.profiles,{'telegram':['ru']})
        self.assertTrue(all(not ('domain'in r and 'ip'in r) for r in f['routing']['rules']))

    def test_detach_refuses_custom_reference(self):
        c=m.patch_xray(config(),self.profiles,{'youtube':['ru']})
        c['routing']['rules'].append({'outboundTag':'fzm-youtube'})
        with self.assertRaises(m.Error):m.detach_xray(c,['youtube'])

    def test_detach_refuses_outbound_chain_reference(self):
        c=m.patch_xray(config(),self.profiles,{'youtube':['ru']})
        c['outbounds'].append({'tag':'custom','streamSettings':{'sockopt':{'dialerProxy':'fzm-youtube'}}})
        with self.assertRaises(m.Error):m.detach_xray(c,['youtube'])

    def test_outbound_conflict_refused(self):
        c=config();c['outbounds'].append({'tag':'fzm-youtube','protocol':'socks','settings':{'servers':[]}})
        with self.assertRaises(m.Error):m.patch_xray(c,self.profiles,{'youtube':['ru']})

    def test_no_implicit_scope(self):
        for tags in ([],['ru','ru'],['ru\nmalicious']):
            with self.subTest(tags=tags),self.assertRaises(m.Error):m.xray_fragment(self.profiles,{'telegram':tags})

    def test_api_rule_survives_at_first_position(self):
        c=m.patch_xray(config(),self.profiles,{'youtube':['ru']})
        self.assertEqual(c['routing']['rules'][:2],config()['routing']['rules'][:2])


class RenderTests(unittest.TestCase):
    def test_queues_and_tables_are_independent(self):
        a,b=profile(),profile('telegram',10809,201)
        self.assertIn('to 200',m.render_nft(a));self.assertNotIn('to 201',m.render_nft(a))
        self.assertIn('to 201',m.render_nft(b));self.assertNotIn('to 200',m.render_nft(b))
        self.assertNotEqual(m.table_name(a['name']),m.table_name(b['name']))

    def test_ipv6_and_no_public_socks(self):
        s=m.render_dante(profile())
        self.assertIn('internal: 127.0.0.1 port',s)
        self.assertIn('to: ::/0',s)
        self.assertIn('meta l4proto tcp',m.render_nft(profile()))
        self.assertNotIn('ip protocol tcp',m.render_nft(profile()))

    def test_known_and_unknown_mtproto_supported(self):
        args=m.nfq_args(profile('telegram',10809,201))
        self.assertIn('--filter-l7=mtproto,unknown',args)
        self.assertIn('--lua-desync=multisplit:pos=2:payload=all',args)
        self.assertIn('--lua-desync=pass',args)

    def test_invalid_profile_input_cannot_inject_config(self):
        for key,value in [('interface','eth0\nExecStart=bad'),('uid',0),('port',0),('queue',65536),('name','../etc')]:
            p=profile();p[key]=value
            with self.subTest(key=key),self.assertRaises(m.Error):m.render_nft(p)

    def test_units_use_own_dante_not_global(self):
        for text in m.render_units(profile()).values():
            self.assertNotIn('Restart=x-ui',text)
            self.assertNotIn('/etc/danted.conf',text)
        self.assertIn('/etc/forcus-zapret/youtube.danted.conf',next(iter(m.render_units(profile()).values())))

    def test_private_tcp_blocks_precede_public_pass_without_blocking_udp_associate(self):
        text=m.render_dante(profile())
        self.assertLess(text.index('socks block'),text.index('socks pass'))
        self.assertIn('to: 127.0.0.0/8',text)
        self.assertIn('to: 169.254.0.0/16',text)
        for block in text.split('socks block')[1:]:
            rule=block.split('}',1)[0]
            self.assertIn('command: connect',rule)
            self.assertNotIn('udpassociate',rule)


class StorageTests(TempCase):
    def sqlite_store(self):
        p=self.root/'panel.db'
        with contextlib.closing(sqlite3.connect(p)) as db, db:
            db.execute('CREATE TABLE settings(id INTEGER PRIMARY KEY,key TEXT UNIQUE,value TEXT)')
            db.execute('INSERT INTO settings(key,value) VALUES(?,?)',('xrayTemplateConfig',m.json_text(config())))
            db.execute('INSERT INTO settings(key,value) VALUES(?,?)',('unrelated','preserved'))
        return m.TemplateStore(self.system,{'backend':'sqlite','config':'/panel.db'})

    def test_sqlite_compare_set_and_unrelated_row(self):
        s=self.sqlite_store();before=s.read();s.compare_set(before,'new')
        self.assertEqual(s.read(),'new')
        with contextlib.closing(sqlite3.connect(self.root/'panel.db')) as db:self.assertEqual(db.execute('SELECT value FROM settings WHERE key="unrelated"').fetchone()[0],'preserved')

    def test_sqlite_concurrent_edit_not_overwritten(self):
        s=self.sqlite_store();before=s.read();s.compare_set(before,'other-admin')
        with self.assertRaises(m.Error):s.compare_set(before,'ours')
        self.assertEqual(s.read(),'other-admin')

    def test_standalone_cas_and_symlink_refusal(self):
        p=self.root/'config.json';p.write_text('before')
        s=m.TemplateStore(self.system,{'backend':'standalone','config':'/config.json'})
        s.compare_set('before','after')
        with self.assertRaises(m.Error):s.compare_set('before','wrong')
        self.assertEqual(p.read_text(),'after')
        (self.root/'link').symlink_to(p)
        with self.assertRaises(m.Error):m.TemplateStore(self.system,{'backend':'standalone','config':'/link'}).read()

    def test_generated_panel_file_not_standalone(self):
        with self.assertRaises(m.Error):m.discover_store(self.system,'standalone','/usr/local/x-ui/bin/config.json')

    def test_api_is_only_loopback(self):
        for value in ['5.1.2.3:62789','127.0.0.1:0','127.0.0.1:8080/path','example.org:80']:
            with self.subTest(value=value),self.assertRaises(m.Error):m.validate_api(value)
        for value in ['127.0.0.1:62789','localhost:62789','[::1]:62789']:self.assertEqual(m.validate_api(value),value)

    def test_storage_failure_restores_native_routes_and_outbounds(self):
        store=self.sqlite_store();before=store.read()
        desired=m.patch_xray(json.loads(before),{'youtube':profile()},{'youtube':['ru']})
        with patch.object(store,'compare_set',side_effect=m.Error('concurrent edit')):
            with self.assertRaises(m.Error):m.apply_template(self.system,store,desired,binary='/usr/bin/fake-xray',api='127.0.0.1:62789')
        routes=[a for a in self.system.commands if 'adrules'in a]
        self.assertEqual(len(routes),2)
        self.assertIn('runtime-before.json',routes[-1][-1])
        self.assertTrue(any('rmo'in a and a[-1]=='fzm-youtube' for a in self.system.commands))
        self.assertEqual(store.read(),before)

    def test_failed_routing_request_still_triggers_rollback(self):
        store=self.sqlite_store();before=store.read();self.system.fail_route=True
        desired=m.patch_xray(json.loads(before),{'youtube':profile()},{'youtube':['ru']})
        with self.assertRaises(m.Error):m.apply_template(self.system,store,desired,binary='/usr/bin/fake-xray',api='127.0.0.1:62789')
        self.assertEqual(len([a for a in self.system.commands if 'adrules'in a]),2)
        self.assertEqual(store.read(),before)

    def test_validation_failure_does_not_change_live_or_database(self):
        s=self.sqlite_store();before=s.read()
        def hook(a):
            if '-test'in a:raise m.Error('bad geosite')
        self.system.hook=hook
        desired=m.patch_xray(config(),{'youtube':profile()},{'youtube':['ru']})
        with self.assertRaises(m.Error):m.apply_template(self.system,s,desired,binary='/usr/bin/fake',api='127.0.0.1:62789')
        self.assertEqual(s.read(),before)
        self.assertFalse(any('ado'in a or 'adrules'in a for a in self.system.commands))

    def test_standalone_runtime_same_file_applies(self):
        p=self.root/'xray.json';p.write_text(m.json_text(config()))
        s=m.TemplateStore(self.system,{'backend':'standalone','config':'/xray.json'})
        desired=m.patch_xray(config(),{'youtube':profile()},{'youtube':['ru']})
        m.apply_template(self.system,s,desired,binary='/usr/bin/fake',api='127.0.0.1:62789',runtime_path='/xray.json')
        self.assertEqual(json.loads(p.read_text()),desired)

    def test_concurrent_runtime_edit_is_preserved(self):
        s=self.sqlite_store();before=s.read()
        runtime=self.root/'runtime.json';runtime.write_text(m.json_text(config()))
        other=dict(config(),note='another admin changed the runtime')
        def hook(a):
            if 'lsrules'in a:runtime.write_text(m.json_text(other))
        self.system.hook=hook
        desired=m.patch_xray(config(),{'youtube':profile()},{'youtube':['ru']})
        with self.assertRaises(m.Error):m.apply_template(self.system,s,desired,binary='/usr/bin/fake',api='127.0.0.1:62789',runtime_path='/runtime.json')
        self.assertEqual(json.loads(runtime.read_text()),other)
        self.assertEqual(s.read(),before)
        self.assertFalse(any('ado'in a or 'adrules'in a for a in self.system.commands))

    def test_apply_refuses_foreign_rule_outbound_and_global_routing_edits(self):
        store=self.sqlite_store();before=store.read()
        desired=m.patch_xray(config(),{'youtube':profile()},{'youtube':['ru']})
        for kind in ['outbound','rule','domain-strategy']:
            c=copy.deepcopy(desired)
            if kind=='outbound':c['outbounds']=[o for o in c['outbounds'] if o['tag']!='direct']
            elif kind=='rule':c['routing']['rules']=c['routing']['rules'][1:]
            else:c['routing']['domainStrategy']='IPOnDemand'
            with self.subTest(kind=kind),self.assertRaises(m.Error):m.apply_template(self.system,store,c,binary='/usr/bin/fake',api='127.0.0.1:62789')
            self.assertEqual(store.read(),before)
        self.assertFalse(any('ado'in a or 'adrules'in a for a in self.system.commands))


class InstallationTests(TempCase):
    def install(self,names):
        engine=self.root/'engine';engine.mkdir(exist_ok=True)
        with patch.object(m,'ensure_engine',return_value=engine),patch.object(m,'choose_port',side_effect=[10808,10809]),patch.object(m,'port_free',return_value=False),patch.object(m,'port_policy',return_value=(False,[])),patch.object(m.time,'sleep'):
            m.install(self.system,names)

    def test_two_profiles_independent_and_idempotent(self):
        self.install(list(m.PROFILES))
        self.assertEqual(set(self.system.load()['profiles']),set(m.PROFILES))
        self.assertEqual(len(self.system.tables),2)
        before=copy.deepcopy(self.system.load())
        self.install(list(m.PROFILES))
        self.assertEqual(self.system.load(),before)

    def test_second_profile_failure_preserves_first(self):
        self.system.fail_enable='telegram-dpi'
        with self.assertRaises(m.Error):self.install(list(m.PROFILES))
        self.assertEqual(set(self.system.load()['profiles']),{'youtube'})
        self.assertIn('fzm_youtube',self.system.tables)
        self.assertNotIn('fzm_telegram',self.system.tables)
        self.assertIn('fzm-yt',self.system.users)
        self.assertNotIn('fzm-tg',self.system.users)
        self.assertTrue(self.system.path('/etc/systemd/system/'+m.units('youtube')[1]).exists())

    def test_existing_user_refused(self):
        self.system.users['fzm-yt']=1234
        with self.assertRaises(m.Error):self.install(['youtube'])
        self.assertEqual(self.system.users['fzm-yt'],1234)
        self.assertFalse(any(a[0]=='userdel' for a in self.system.commands))

    def test_foreign_nft_table_not_deleted(self):
        self.system.tables['fzm_youtube']='table inet fzm_youtube { comment "other" }'
        with self.assertRaises(m.Error):self.install(['youtube'])
        self.assertIn('fzm_youtube',self.system.tables)
        self.assertFalse(any(a[:3]==['nft','delete','table'] for a in self.system.commands))

    def test_remove_bound_profile_refused(self):
        self.install(['youtube'])
        state=self.system.load();state['links']=[{'selections':{'youtube':['ru']}}];self.system.save(state)
        with self.assertRaises(m.Error):m.remove_profile(self.system,'youtube')
        self.assertIn('fzm_youtube',self.system.tables)

    def test_remove_one_keeps_other_services_and_table(self):
        self.install(list(m.PROFILES));m.remove_profile(self.system,'youtube')
        self.assertEqual(set(self.system.load()['profiles']),{'telegram'})
        self.assertIn('fzm_telegram',self.system.tables)
        self.assertTrue(all(u in self.system.active for u in m.units('telegram')))

    def test_busy_queue_refused_without_stopping_foreign_handler(self):
        self.system.tables['foreign']='table inet foreign { queue flags bypass to 200 }'
        with patch.object(m,'choose_port',return_value=10808),self.assertRaises(m.Error):m.install_profile(self.system,'youtube',queue=200)
        self.assertFalse(any(a[:2]==['systemctl','disable'] for a in self.system.commands))

    def test_explicit_invalid_ports_rejected_before_dependencies(self):
        for key,value in [('port',80),('queue',0),('queue',65536)]:
            with self.subTest(key=key,value=value),self.assertRaises(m.Error):m.install(self.system,['youtube'],**{key:value})
        self.assertEqual(self.system.commands,[])

    def test_whole_uninstall_refuses_bound_profiles(self):
        self.install(['youtube'])
        state=self.system.load();state['links']=[{'selections':{'youtube':['ru']}}];self.system.save(state)
        before=len(self.system.commands)
        with self.assertRaises(m.Error):m.uninstall(self.system)
        self.assertFalse(any(a[:2]==['systemctl','disable'] for a in self.system.commands[before:]))
        self.assertIn('youtube',self.system.load()['profiles'])

    def test_uninstall_retains_backup_and_foreign_kernel_file(self):
        self.install(list(m.PROFILES))
        foreign=self.system.path('/etc/sysctl.d/91-forcus-zapret.conf');foreign.write_text('# foreign administrator\n')
        m.uninstall(self.system)
        self.assertTrue(foreign.exists())
        self.assertTrue(any(self.system.path('/var/backups/forcus-zapret').iterdir()))
        self.assertFalse(self.system.tables)

    def test_queue_ranges_are_reserved(self):
        self.system.tables['foreign']='table inet x { queue flags bypass to 200-205; queue to 300; }'
        self.assertTrue(set(range(200,206)).issubset(m.queue_numbers(self.system)))
        self.assertIn(300,m.queue_numbers(self.system))

    def test_existing_stock_dante_is_not_disabled_by_dependencies(self):
        path=self.system.path('/etc/danted.conf');path.parent.mkdir(parents=True);path.write_text('existing admin configuration')
        m.System.dependencies(self.system)
        self.assertFalse(any(a[:3]==['systemctl','disable','--now'] for a in self.system.commands))
        self.assertEqual(path.read_text(),'existing admin configuration')

    def test_only_new_stock_dante_is_disabled(self):
        m.System.dependencies(self.system)
        self.assertIn(['systemctl','disable','--now','danted.service'],self.system.commands)

    def test_pending_link_survives_post_apply_state_write_failure(self):
        self.install(['youtube'])
        database=self.root/'panel.db'
        with contextlib.closing(sqlite3.connect(database)) as db, db:
            db.execute('CREATE TABLE settings(id INTEGER PRIMARY KEY,key TEXT,value TEXT)')
            db.execute('INSERT INTO settings VALUES(1,?,?)',('xrayTemplateConfig',m.json_text(config())))
        store=m.TemplateStore(self.system,{'backend':'sqlite','config':'/panel.db'})
        original_save=self.system.save;count=0
        def fail_second(state):
            nonlocal count
            count+=1
            if count==2:raise OSError('simulated disk error')
            original_save(state)
        with patch.object(m,'discover_store',return_value=store),patch.object(self.system,'save',side_effect=fail_second):
            with self.assertRaises(OSError):m.xray_apply(self.system,{'youtube':['ru']},binary='/usr/bin/fake',runtime=None)
        self.assertTrue(self.system.load()['links'][0]['pending'])
        with self.assertRaises(m.Error):m.remove_profile(self.system,'youtube')
        # A retry completes the saved operation without duplicate outbounds/rules.
        with patch.object(m,'discover_store',return_value=store):m.xray_apply(self.system,{'youtube':['ru']},binary='/usr/bin/fake',runtime=None)
        self.assertFalse(self.system.load()['links'][0]['pending'])


class ArchiveTests(TempCase):
    def archive(self,members):
        path=self.root/'archive.tar.gz'
        with tarfile.open(path,'w:gz') as t:
            for name,content,kind in members:
                entry=tarfile.TarInfo(name);entry.type=kind;entry.size=len(content) if kind==tarfile.REGTYPE else 0
                if kind==tarfile.SYMTYPE:entry.linkname='/etc/passwd'
                t.addfile(entry,io.BytesIO(content) if entry.size else None)
        return path

    def test_path_traversal_and_links_rejected(self):
        for name,kind in [('../escape',tarfile.REGTYPE),('/root/escape',tarfile.REGTYPE),('root/lua/zapret-lib.lua',tarfile.SYMTYPE)]:
            with self.subTest(name=name):
                a=self.archive([(name,b'bad',kind)])
                with self.assertRaises(m.Error):m.unpack_engine(a,self.root/'out')
        self.assertFalse((self.root.parent/'escape').exists())

    def test_only_necessary_regular_files_extracted(self):
        names=['binaries/linux-x86_64/nfqws2','lua/zapret-lib.lua','lua/zapret-antidpi.lua','docs/readme.md']
        a=self.archive([('root/'+n,b'fixture',tarfile.REGTYPE) for n in names])
        m.unpack_engine(a,self.root/'out')
        self.assertFalse((self.root/'out/docs').exists())
        self.assertTrue((self.root/'out/lua/zapret-lib.lua').is_file())

    def test_bad_checksum_never_extracts_or_stops_service(self):
        def bad_download(url,path):Path(path).write_bytes(b'wrong archive')
        with patch.object(m,'download',side_effect=bad_download):
            with self.assertRaises(m.Error):m.ensure_engine(self.system,m.ENGINE_VERSION,m.ENGINE_SHA256)
        self.assertFalse(any('systemctl'in a for a in self.system.commands))
        self.assertFalse(self.system.path('/opt/forcus-zapret/engines').exists())


if __name__=='__main__':unittest.main()
