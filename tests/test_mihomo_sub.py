"""Isolated regressions; no downloads, Controller requests or service changes."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

import yaml


SCRIPT = Path(__file__).resolve().parents[1] / 'mihomo-sub.sh'


class MihomoSubTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = os.environ.copy()
        self.env.update({
            'MIHOMO_SUB_HOME': str(self.root / 'home'),
            'MIHOMO_SUB_CACHE': str(self.root / 'cache'),
            'MIHOMO_CONFIG_TARGET': str(self.root / 'runtime' / 'config.yaml'),
            'MIHOMO_DATA_DIR': str(self.root / 'runtime'),
            'MIHOMO_PROXY_PORT': '7897',
            'MIHOMO_CONTROLLER': '127.0.0.1:9090',
            'MIHOMO_CONTROLLER_SECRET': '',
            'MIHOMO_GH_PROXY_DEFAULT': 'https://example.invalid/',
            'SCRIPT': str(SCRIPT),
            'TEST_ROOT': str(self.root),
        })

    def shell(self, body, expected=0):
        result = subprocess.run(
            ['bash', '--noprofile', '--norc'],
            input='source "$SCRIPT"\n_mhm_init || exit 99\n' + body,
            text=True, capture_output=True, env=self.env,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_update_reports_failed_activation(self):
        self.shell('''
_mhm_active() { printf 'demo\\n'; }
_mhm_fetch() { return 0; }
_mhm_activate_cached() { return 1; }
_mhm_cmd_update demo
''', expected=1)

    def test_update_all_reports_failure_and_continues(self):
        self.shell('''
touch "$_SUB_DIR/a.url" "$_SUB_DIR/b.url"
_mhm_active() { printf 'a\\n'; }
_mhm_fetch() { printf '%s\\n' "$1" >> "$TEST_ROOT/fetched"; }
_mhm_activate_cached() { return 1; }
_mhm_cmd_update --all
''', expected=1)
        self.assertEqual((self.root / 'fetched').read_text(), 'a\nb\n')

    def test_update_inactive_subscription_succeeds(self):
        self.shell('''
_mhm_active() { printf 'active\\n'; }
_mhm_fetch() { return 0; }
_mhm_activate_cached() { exit 99; }
_mhm_cmd_update other
''')

    def test_service_detection(self):
        for output, status, expected in [
            ('', 1, 1), ('loaded', 1, 1), ('', 0, 1),
            ('not-found', 0, 1), ('error', 0, 1), ('loaded', 0, 0),
        ]:
            with self.subTest(output=output, status=status):
                self.shell(f'''
systemctl() {{ printf '%s' '{output}'; return {status}; }}
_mhm_service_exists
''', expected=expected)

    def test_nullglob_is_preserved(self):
        for enabled in (True, False):
            for populated in (True, False):
                with self.subTest(enabled=enabled, populated=populated):
                    self.shell(f'''
rm -f "$_SUB_DIR/demo.url"
{'touch "$_SUB_DIR/demo.url"' if populated else ':'}
shopt {'-s' if enabled else '-u'} nullglob
_mhm_cmd_ls >/dev/null || exit 90
[[ "$(shopt -p nullglob)" == 'shopt {'-s' if enabled else '-u'} nullglob' ]] || exit 91
_mhm_active() {{ printf 'other\\n'; }}
_mhm_fetch() {{ return 0; }}
_mhm_cmd_update --all >/dev/null 2>&1
rc=$?
[[ $rc == {0 if populated else 1} ]] || exit 92
[[ "$(shopt -p nullglob)" == 'shopt {'-s' if enabled else '-u'} nullglob' ]]
''')

    def test_target_permissions(self):
        self.shell('''
printf 'secret: private\\n' > "$TEST_ROOT/input.yaml"
_mhm_install_target "$TEST_ROOT/input.yaml" || exit 90
chmod 644 "$MIHOMO_CONFIG_TARGET"
_mhm_install_target "$TEST_ROOT/input.yaml"
''')
        target = self.root / 'runtime' / 'config.yaml'
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual(target.read_text(), 'secret: private\n')

    def test_yaml_overrides_and_escaping(self):
        original = '''---
defaults: &defaults
  mixed-port: 7890
  secret: old
<<: *defaults
"external-controller": 0.0.0.0:9090
'port': 8080
"socks-port": 1080
geo-update-interval: 24
geo-auto-update: true
"geox-url":
  mmdb: https://old.invalid/
secret: |
  subscription secret
proxies:
  - name: 香港节点
    type: socks5
    server: example.invalid
    port: 1080
proxy-groups:
  - name: 节点选择
    type: select
    proxies: [香港节点]
dns:
  enable: true
rules: [MATCH,节点选择]
'''
        (self.root / 'input.yaml').write_text(original)
        secret = 'quote" backslash\\ newline\ncolon: #hash'
        self.env['MIHOMO_CONTROLLER_SECRET'] = secret
        self.env['MIHOMO_GH_PROXY_DEFAULT'] = 'https://example.invalid/%22quoted%5Cpath'
        self.shell('_mhm_render_runtime_config "$TEST_ROOT/input.yaml" "$TEST_ROOT/output.yaml"\n')
        config = yaml.safe_load((self.root / 'output.yaml').read_text())
        self.assertEqual(config['mixed-port'], 7897)
        self.assertEqual(config['external-controller'], '127.0.0.1:9090')
        self.assertEqual(config['secret'], secret)
        self.assertIs(config['geo-auto-update'], False)
        for key in ('port', 'socks-port', 'geo-update-interval'):
            self.assertNotIn(key, config)
        self.assertTrue(config['geox-url']['mmdb'].startswith(self.env['MIHOMO_GH_PROXY_DEFAULT'] + '/'))
        before = yaml.safe_load(original)
        for key in ('proxies', 'proxy-groups', 'dns', 'rules'):
            self.assertEqual(config[key], before[key])

    def test_empty_local_secret_overrides_subscription_secret(self):
        (self.root / 'input.yaml').write_text('secret: subscription\n')
        self.shell('_mhm_render_runtime_config "$TEST_ROOT/input.yaml" "$TEST_ROOT/output.yaml"\n')
        self.assertEqual(yaml.safe_load((self.root / 'output.yaml').read_text())['secret'], '')

    def test_controller_reads_yaml_secret(self):
        target = self.root / 'runtime' / 'config.yaml'
        target.parent.mkdir()
        for secret in ('', 'quote" apostrophe\' backslash\\ colon: #hash'):
            with self.subTest(secret=secret):
                target.write_text(yaml.safe_dump({'secret': secret}))
                result = self.shell('_mhm_controller_secret\n')
                self.assertEqual(result.stdout, secret + '\n')

    def test_invalid_secret_aborts_api_request(self):
        target = self.root / 'runtime' / 'config.yaml'
        target.parent.mkdir()
        target.write_text('secret: [invalid]\n')
        self.shell('''
curl() { exit 99; }
_mhm_api GET /version ''
''', expected=1)

    def test_invalid_yaml_does_not_replace_runtime_config(self):
        for invalid in ('[invalid', '- list\n', '---\na: 1\n---\nb: 2\n',
                        '!!python/object/apply:os.system ["false"]\n'):
            with self.subTest(invalid=invalid):
                self.shell('''
mkdir -p "$MIHOMO_DATA_DIR"
printf 'secret: original\\n' > "$MIHOMO_CONFIG_TARGET"
''')
                cache = self.root / 'cache' / 'profiles' / 'demo.yaml'
                cache.write_text(invalid)
                self.shell('''
_mhm_ensure_geo() { return 0; }
_mhm_reload_runtime() { exit 99; }
_mhm_activate_cached demo
''', expected=1)
                self.assertEqual((self.root / 'runtime' / 'config.yaml').read_text(),
                                 'secret: original\n')

    def test_failed_reload_restores_old_config(self):
        self.shell('''
mkdir -p "$MIHOMO_DATA_DIR"
printf 'secret: original\\n' > "$MIHOMO_CONFIG_TARGET"
printf 'secret: new\\n' > "$_PROFILE_DIR/demo.yaml"
_mhm_ensure_geo() { return 0; }
_mhm_reload_runtime() { return 1; }
_mhm_activate_cached demo
''', expected=1)
        target = self.root / 'runtime' / 'config.yaml'
        self.assertEqual(target.read_text(), 'secret: original\n')
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertFalse((self.root / 'home' / 'active').exists())


    def test_subscription_commands_reject_path_traversal(self):
        victim_url = self.root / 'victim.url'
        victim_yaml = self.root / 'victim.yaml'
        victim_url.write_text('https://original.invalid/sub\n')
        victim_yaml.write_text('secret: original\n')
        commands = [
            'mhm add ../../victim https://new.invalid/sub',
            'mhm set-url ../../victim https://new.invalid/sub',
            'mhm update ../../victim', 'mhm use ../../victim',
            'mhm del ../../victim', 'mhm show ../../victim',
        ]
        for command in commands:
            with self.subTest(command=command):
                result = self.shell('''
curl() { exit 99; }
_mhm_ensure_geo() { exit 99; }
_mhm_reload_runtime() { exit 99; }
''' + command + '\n', expected=1)
                self.assertIn('名称', result.stderr)
                self.assertEqual(victim_url.read_text(), 'https://original.invalid/sub\n')
                self.assertEqual(victim_yaml.read_text(), 'secret: original\n')

    def test_saved_active_name_cannot_escape_subscription_directories(self):
        self.shell('''
printf '../../victim\n' > "$_ACTIVE_FILE"
curl() { exit 99; }
mhm update
''', expected=1)
        self.assertFalse((self.root / 'runtime/config.yaml').exists())

    def test_subscription_cannot_enable_additional_listeners(self):
        profile = {
            'allow-lan': True, 'bind-address': '*',
            'port': 8080, 'socks-port': 1080,
            'redir-port': 7892, 'tproxy-port': 7893,
            'listeners': [{'name': 'remote', 'type': 'mixed',
                           'listen': '0.0.0.0', 'port': 8888}],
            'external-controller': '0.0.0.0:9090',
            'external-controller-tls': '0.0.0.0:9443',
            'external-controller-unix': '/tmp/remote.sock',
            'external-controller-pipe': r'\\.\pipe\remote',
            'secret': 'subscription-secret',
            'proxies': [{'name': 'node', 'type': 'socks5',
                         'server': 'example.invalid', 'port': 1080}],
            'rules': ['MATCH,DIRECT'],
        }
        (self.root / 'input.yaml').write_text(yaml.safe_dump(profile))
        self.shell('_mhm_render_runtime_config "$TEST_ROOT/input.yaml" "$TEST_ROOT/output.yaml"\n')
        config = yaml.safe_load((self.root / 'output.yaml').read_text())
        self.assertIs(config['allow-lan'], False)
        self.assertEqual(config['bind-address'], '127.0.0.1')
        self.assertEqual(config['mixed-port'], 7897)
        self.assertEqual(config['external-controller'], '127.0.0.1:9090')
        self.assertEqual(config['secret'], '')
        for key in ('port', 'socks-port', 'redir-port', 'tproxy-port', 'listeners',
                    'external-controller-tls', 'external-controller-unix',
                    'external-controller-pipe'):
            self.assertNotIn(key, config)
        self.assertEqual(config['proxies'], profile['proxies'])
        self.assertEqual(config['rules'], profile['rules'])

    def test_invalid_install_record_does_not_replace_config(self):
        target = self.root / 'runtime/config.yaml'
        target.parent.mkdir()
        for record in ('{"scope":"system"}', '[1]', '{invalid'):
            with self.subTest(record=record):
                target.write_text('secret: original\n')
                target.chmod(0o640)
                self.env['TEST_INSTALL_RECORD'] = record
                self.shell('''
printf '%s' "$TEST_INSTALL_RECORD" > "$_INSTALL_FILE"
printf 'rules: ["MATCH,DIRECT"]\n' > "$_PROFILE_DIR/demo.yaml"
_mhm_ensure_geo() { return 0; }
_mhm_reload_runtime() { exit 99; }
_mhm_activate_cached demo
''', expected=1)
                self.assertEqual(target.read_text(), 'secret: original\n')
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
                self.assertEqual((self.root / 'home/install.json').read_text(), record)
                self.assertFalse((self.root / 'home/active').exists())

    def test_failed_install_record_commit_restores_config(self):
        for had_old in (True, False):
            with self.subTest(had_old=had_old):
                target = self.root / 'runtime/config.yaml'
                target.parent.mkdir(exist_ok=True)
                if had_old:
                    target.write_text('secret: original\n')
                    target.chmod(0o640)
                else:
                    target.unlink(missing_ok=True)
                record = self.root / 'home/install.json'
                record.parent.mkdir(exist_ok=True)
                record.write_text('{"scope":"user"}\n')
                self.shell('''
printf 'rules: ["MATCH,DIRECT"]\n' > "$_PROFILE_DIR/demo.yaml"
_mhm_ensure_geo() { return 0; }
_mhm_reload_runtime() { exit 99; }
mv() {
  [[ "${!#}" != "$_INSTALL_FILE" ]] || return 1
  command mv "$@"
}
_mhm_activate_cached demo
''', expected=1)
                if had_old:
                    self.assertEqual(target.read_text(), 'secret: original\n')
                    self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
                else:
                    self.assertFalse(target.exists())
                self.assertEqual(record.read_text(), '{"scope":"user"}\n')
                self.assertFalse((self.root / 'home/active').exists())
                self.assertFalse(list(target.parent.glob('config.yaml.tmp.*')))
                self.assertFalse(list(target.parent.glob('config.yaml.rollback.*')))
                self.assertFalse(list(record.parent.glob('install.json.tmp.*')))

    def test_partial_config_write_does_not_replace_old_config(self):
        target = self.root / 'runtime/config.yaml'
        target.parent.mkdir()
        target.write_text('secret: original\n')
        self.shell('''
printf '{"scope":"user"}\n' > "$_INSTALL_FILE"
printf 'secret: new\n' > "$TEST_ROOT/input.yaml"
install() { printf 'partial' > "${!#}"; return 1; }
_mhm_install_target "$TEST_ROOT/input.yaml"
''', expected=1)
        self.assertEqual(target.read_text(), 'secret: original\n')
        self.assertEqual((self.root / 'home/install.json').read_text(), '{"scope":"user"}\n')


if __name__ == '__main__':
    unittest.main()
