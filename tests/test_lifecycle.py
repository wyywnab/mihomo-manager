"""Exercise user/system lifecycle with fake downloads and systemd."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

import yaml


SCRIPT = Path(__file__).resolve().parents[1] / 'mihomo-sub.sh'
MOCKS = r'''
uname() {
  if [[ "$1" == -s ]]; then printf 'Linux\n'; else printf '%s\n' "${TEST_ARCH:-x86_64}"; fi
}
wget() {
  printf '%s\n' "$*" >> "$TEST_ROOT/downloads"
  local arg dest next=0 url="${!#}"
  for arg in "$@"; do
    if (( next )); then dest="$arg"; next=0; fi
    [[ "$arg" != -O ]] || next=1
  done
  case "$url" in
    https://proxy.invalid/https://api.github.com/repos/MetaCubeX/mihomo/releases/*|https://api.github.com/repos/MetaCubeX/mihomo/releases/*)
      cp "$TEST_ROOT/release.json" "$dest" ;;
    https://proxy.invalid/https://github.com/MetaCubeX/mihomo/releases/download/*|https://github.com/MetaCubeX/mihomo/releases/download/*)
      [[ "${FAIL_ASSET:-0}" != 1 ]] || return 1
      cp "$TEST_ROOT/asset.gz" "$dest" ;;
    https://proxy.invalid/https://raw.githubusercontent.com/*|https://raw.githubusercontent.com/*)
      printf 'rules: ["MATCH,DIRECT"]\n' > "$dest" ;;
    *) printf 'Unproxied/unexpected download: %s\n' "$url" >&2; return 99 ;;
  esac
}
systemctl() {
  printf '%s\n' "$*" >> "$TEST_ROOT/systemctl"
  local scope="$1"
  shift
  case "$1" in
    show-environment) return 0 ;;
    show)
      if [[ -f "$_UNIT_FILE" ]]; then printf 'loaded\n'; else printf 'not-found\n'; fi ;;
    is-active) printf 'inactive\n'; return 3 ;;
    is-enabled) printf 'enabled\n' ;;
    disable) [[ "${FAIL_DISABLE:-0}" != 1 ]] ;;
    *) return 0 ;;
  esac
}
curl() {
  printf 'curl %s\n' "${!#}" >> "$TEST_ROOT/downloads"
  local arg dest next=0 url="${!#}"
  for arg in "$@"; do
    if (( next )); then dest="$arg"; next=0; fi
    [[ "$arg" != --output ]] || next=1
  done
  case "$url" in
    https://subscription.invalid/start)
      printf '302\nhttps://raw.githubusercontent.com/example/repo/main/config.yaml\n' ;;
    https://proxy.invalid/https://raw.githubusercontent.com/*)
      printf 'rules: ["MATCH,DIRECT"]\n' > "$dest"
      printf '200\n\n' ;;
    *) printf 'Unproxied/unexpected curl: %s\n' "$url" >&2; return 99 ;;
  esac
}
journalctl() { printf '%s\n' "$*" >> "$TEST_ROOT/journalctl"; }
sudo() { printf '%s\n' "$*" >> "$TEST_ROOT/sudo"; }
'''


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = os.environ.copy()
        # Avoid host overrides, especially if the test runner has sourced mhm.
        for key in list(self.env):
            if key.startswith('MIHOMO_'):
                del self.env[key]
        self.env.update({
            'HOME': str(self.root / 'user'),
            'XDG_CONFIG_HOME': str(self.root / 'user' / '.config'),
            'XDG_CACHE_HOME': str(self.root / 'user' / '.cache'),
            'MIHOMO_SCOPE': 'user',
            'MIHOMO_SUB_HOME': str(self.root / 'state'),
            'MIHOMO_SUB_CACHE': str(self.root / 'cache'),
            'MIHOMO_CONFIG_TARGET': str(self.root / 'data' / 'config.yaml'),
            'MIHOMO_DATA_DIR': str(self.root / 'data'),
            'MIHOMO_BIN': str(self.root / 'bin' / 'mihomo'),
            'MIHOMO_UNIT_DIR': str(self.root / 'units'),
            'MIHOMO_GH_PROXY_DEFAULT': 'https://proxy.invalid/',
            'SCRIPT': str(SCRIPT),
            'TEST_ROOT': str(self.root),
        })
        self.write_release()

    def write_release(self, arch='amd64-v1', payload=None, digest=None):
        payload = payload or b'#!/bin/sh\nprintf "Mihomo v1.2.3 test\\n"\n'
        archive = gzip.compress(payload)
        (self.root / 'asset.gz').write_bytes(archive)
        name = f'mihomo-linux-{arch}-v1.2.3.gz'
        release = {'tag_name': 'v1.2.3', 'assets': [{
            'name': name,
            'browser_download_url': 'https://github.com/MetaCubeX/mihomo/releases/download/v1.2.3/' + name,
            'digest': digest or 'sha256:' + hashlib.sha256(archive).hexdigest(),
        }]}
        (self.root / 'release.json').write_text(json.dumps(release))

    def shell(self, body, expected=0):
        result = subprocess.run(
            ['bash', '--noprofile', '--norc'],
            input='source "$SCRIPT"\n' + MOCKS + body,
            capture_output=True, text=True, env=self.env, timeout=20,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def install_and_register(self):
        self.shell('mhm install || exit $?\nmhm register\n')

    def test_complete_user_lifecycle_and_cleanup(self):
        result = self.shell('''
mhm --user install || exit $?
mhm --user register || exit $?
mhm --user start || exit $?
mhm --user status || exit $?
mhm --user logs || exit $?
mhm --user stop || exit $?
mhm --user uninstall
''')
        self.assertIn('scope:      user', result.stdout)
        for path in ('bin/mihomo', 'units/mihomo.service', 'state', 'cache', 'data'):
            self.assertFalse((self.root / path).exists(), path)
        calls = (self.root / 'systemctl').read_text()
        self.assertIn('--user enable mihomo.service', calls)
        self.assertIn('--user disable --now mihomo.service', calls)
        self.assertNotIn('--system', calls)
        self.assertEqual((self.root / 'journalctl').read_text(), '--user -u mihomo.service -n 50 --no-pager\n')
        for line in (self.root / 'downloads').read_text().splitlines():
            self.assertIn('--max-redirect=0', line)
            self.assertIn('https://proxy.invalid/https://', line)

    def test_registration_unit_paths_and_permissions(self):
        self.install_and_register()
        unit = (self.root / 'units' / 'mihomo.service').read_text()
        self.assertIn('WantedBy=default.target', unit)
        self.assertIn(f'ExecStart="{self.root}/bin/mihomo" -d "{self.root}/data" -f "{self.root}/data/config.yaml"', unit)
        for path, mode in [('bin/mihomo', 0o755), ('units/mihomo.service', 0o644),
                           ('data/config.yaml', 0o600), ('state/install.json', 0o600)]:
            self.assertEqual(stat.S_IMODE((self.root / path).stat().st_mode), mode)

    def test_scope_defaults_and_shell_are_isolated(self):
        for key in ('MIHOMO_SUB_HOME', 'MIHOMO_SUB_CACHE', 'MIHOMO_CONFIG_TARGET',
                    'MIHOMO_DATA_DIR', 'MIHOMO_BIN', 'MIHOMO_UNIT_DIR'):
            del self.env[key]
        result = self.shell('''
source "$SCRIPT"
mhm --system status || exit $?
mhm --user status || exit $?
[[ "$MIHOMO_SCOPE" == user ]] || exit 91
[[ "$MIHOMO_BIN" == "$HOME/.local/bin/mihomo" ]] || exit 92
[[ ! -e "$HOME/.config" ]] || exit 93
''')
        self.assertIn('/usr/local/bin/mihomo', result.stdout)
        self.assertIn(str(self.root / 'user' / '.local/bin/mihomo'), result.stdout)
        calls = (self.root / 'systemctl').read_text()
        self.assertIn('--system show ', calls)
        self.assertIn('--user show ', calls)

    def test_system_scope_mutations(self):
        # Simulate root routing; writes still use only temporary test paths.
        self.shell('_mhm_is_root() { return 0; }\nmhm --system install || exit $?\nmhm --system register || exit $?\nmhm --system restart\n')
        self.assertIn('WantedBy=multi-user.target', (self.root / 'units/mihomo.service').read_text())
        calls = (self.root / 'systemctl').read_text()
        self.assertIn('--system enable mihomo.service', calls)
        self.assertIn('--system restart mihomo.service', calls)
        self.assertNotIn('--user', calls)

    def test_system_scope_escalation_preserves_paths_and_proxy(self):
        self.shell('_mhm_is_root() { return 1; }\nmhm --system install v1.2.3\n')
        call = (self.root / 'sudo').read_text()
        self.assertIn('MIHOMO_SCOPE=system', call)
        self.assertIn('MIHOMO_GH_PROXY_DEFAULT=https://proxy.invalid/', call)
        self.assertIn(f'MIHOMO_BIN={self.root}/bin/mihomo', call)
        self.assertIn('--system install v1.2.3', call)
        self.assertFalse((self.root / 'bin/mihomo').exists())

    def test_latest_and_tagged_release_are_proxied(self):
        self.shell('mhm install 1.2.3\n')
        calls = (self.root / 'downloads').read_text()
        self.assertIn('https://proxy.invalid/https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/v1.2.3', calls)

    def test_arm64_asset(self):
        self.env['TEST_ARCH'] = 'aarch64'
        self.write_release(arch='arm64')
        self.shell('mhm install\n')
        self.assertIn('mihomo-linux-arm64-v1.2.3.gz', (self.root / 'downloads').read_text())

    def test_download_failure_preserves_installed_binary(self):
        self.shell('mhm install\n')
        before = (self.root / 'bin/mihomo').read_bytes()
        self.shell('FAIL_ASSET=1\nmhm install\n', expected=1)
        self.assertEqual((self.root / 'bin/mihomo').read_bytes(), before)

    def test_checksum_mismatch_does_not_install(self):
        self.write_release(digest='sha256:' + '0' * 64)
        self.shell('mhm install\n', expected=1)
        self.assertFalse((self.root / 'bin/mihomo').exists())

    def test_unrunnable_binary_does_not_install(self):
        self.write_release(payload=b'not an executable\n')
        self.shell('mhm install\n', expected=1)
        self.assertFalse((self.root / 'bin/mihomo').exists())

    def test_empty_prefix_allows_direct_download(self):
        self.env['MIHOMO_GH_PROXY_DEFAULT'] = ''
        # A persisted legacy "off" setting must not fall back to the default.
        (self.root / 'state').mkdir()
        (self.root / 'state/gh-proxy').write_text('')
        self.shell('mhm install\n')
        calls = (self.root / 'downloads').read_text()
        self.assertNotIn('https://proxy.invalid/', calls)
        self.assertIn('--max-redirect=10', calls)
        self.assertIn('https://api.github.com/repos/MetaCubeX/mihomo/releases/latest', calls)
        self.assertTrue((self.root / 'bin/mihomo').exists())

    def test_proxy_can_be_disabled(self):
        self.shell('mhm gh-proxy off\n')
        self.assertEqual((self.root / 'state/gh-proxy').read_text(), '\n')

    def test_empty_default_is_not_replaced(self):
        self.env['MIHOMO_GH_PROXY_DEFAULT'] = ''
        result = self.shell('_mhm_geo_mmdb_url\n')
        self.assertEqual(result.stdout.strip(), 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb')

    def test_explicit_empty_prefix_and_reset(self):
        self.shell('mhm gh-proxy set "" || exit $?\nmhm install\n')
        self.assertNotIn('https://proxy.invalid/', (self.root / 'downloads').read_text())
        self.shell('mhm gh-proxy reset\n')
        self.assertEqual((self.root / 'state/gh-proxy').read_text(), 'https://proxy.invalid/\n')

    def test_lifecycle_without_python_or_yaml_reader(self):
        self.env['MIHOMO_PYTHON_FALLBACK'] = '0'
        self.env['MIHOMO_YQ_BIN'] = 'nonexistent-yq'
        self.shell('''
python3() { printf 'Unexpected Python call\n' >&2; exit 99; }
mhm install || exit $?
mhm register || exit $?
_mhm_controller_secret || exit $?
mhm status || exit $?
mhm uninstall
''')
        self.assertFalse((self.root / 'bin/mihomo').exists())
        self.assertFalse((self.root / 'data').exists())

    def test_json_config_works_without_python(self):
        self.env['MIHOMO_PYTHON_FALLBACK'] = '0'
        self.env['MIHOMO_YQ_BIN'] = 'nonexistent-yq'
        self.env['MIHOMO_GH_PROXY_DEFAULT'] = ''
        (self.root / 'input.yaml').write_text(json.dumps({
            'rule-providers': {'remote': {'url': 'https://raw.githubusercontent.com/example/repo/main/rules.yaml'}},
        }))
        self.shell('''
python3() { exit 99; }
_mhm_render_runtime_config "$TEST_ROOT/input.yaml" "$TEST_ROOT/rendered.yaml"
''')
        config = json.loads((self.root / 'rendered.yaml').read_text())
        self.assertEqual(config['rule-providers']['remote']['url'], 'https://raw.githubusercontent.com/example/repo/main/rules.yaml')
        self.assertTrue(config['geox-url']['mmdb'].startswith('https://github.com/'))

    def test_yaml_without_reader_fails_before_replacing_config(self):
        self.env['MIHOMO_PYTHON_FALLBACK'] = '0'
        self.env['MIHOMO_YQ_BIN'] = 'nonexistent-yq'
        (self.root / 'input.yaml').write_text('rules: ["MATCH,DIRECT"]\n')
        self.shell('''
python3() { exit 99; }
_mhm_render_runtime_config "$TEST_ROOT/input.yaml" "$TEST_ROOT/rendered.yaml"
''', expected=1)

    def test_native_yaml_reader_takes_priority_without_python(self):
        self.env['MIHOMO_YQ_BIN'] = 'yq'
        self.env['MIHOMO_PYTHON_FALLBACK'] = '0'
        (self.root / 'input.yaml').write_text('rules: ["MATCH,DIRECT"]\n')
        # Stub the external converter boundary; real YAML parsing is exercised
        # by the compatibility-reader tests on hosts without native yq.
        self.shell('''
python3() { exit 99; }
yq() {
  case "$1" in
    --version) printf 'yq version v4.45.1\n' ;;
    --help) printf -- '--yaml-fix-merge-anchor-to-spec\n' ;;
    eval) printf '{"rules":["MATCH,DIRECT"]}\n' ;;
    *) return 99 ;;
  esac
}
_mhm_render_runtime_config "$TEST_ROOT/input.yaml" "$TEST_ROOT/rendered.yaml"
''')
        self.assertEqual(json.loads((self.root / 'rendered.yaml').read_text())['rules'], ['MATCH,DIRECT'])

    def test_yaml_converter_failure_does_not_accept_partial_output(self):
        self.env['MIHOMO_YQ_BIN'] = 'yq'
        (self.root / 'input.yaml').write_text('rules: ["MATCH,DIRECT"]\n')
        self.shell('''
python3() { exit 99; }
yq() {
  case "$1" in
    --version) printf 'yq version v4.45.1\n' ;;
    --help) return 0 ;;
    eval) printf '{"rules":[]}\n'; return 1 ;;
  esac
}
_mhm_render_runtime_config "$TEST_ROOT/input.yaml" "$TEST_ROOT/rendered.yaml"
''', expected=1)
        self.assertFalse((self.root / 'rendered.yaml').exists())

    def test_nodes_without_python(self):
        group = '节点选择 / %?中文'
        node = '香港 "引号" \\节点'
        proxies = {'proxies': {
            'GLOBAL': {'type': 'Selector', 'all': ['DIRECT'], 'now': 'DIRECT'},
            group: {'type': 'Selector', 'all': ['DIRECT', node], 'now': 'DIRECT'},
        }}
        (self.root / 'proxies.json').write_text(json.dumps(proxies))
        self.shell('''
python3() { exit 99; }
_mhm_api_proxies() { cat "$TEST_ROOT/proxies.json"; }
_mhm_api() {
  printf '%s' "$2" > "$TEST_ROOT/api-path"
  printf '%s' "$3" > "$TEST_ROOT/api-body"
}
mhm node ls || exit $?
mhm node use 2 || exit $?
mhm node groups || exit $?
mhm node group 1 || exit $?
mhm node current
''')
        from urllib.parse import quote
        self.assertEqual((self.root / 'api-path').read_text(), '/proxies/' + quote(group, safe=''))
        self.assertEqual(json.loads((self.root / 'api-body').read_text()), {'name': node})
        self.assertEqual((self.root / 'state/node-group').read_text(), 'GLOBAL\n')

    def test_invalid_node_index_does_not_call_api(self):
        (self.root / 'proxies.json').write_text(json.dumps({'proxies': {
            '选择': {'type': 'Selector', 'all': ['DIRECT'], 'now': 'DIRECT'},
        }}))
        self.shell('''
python3() { exit 99; }
_mhm_api_proxies() { cat "$TEST_ROOT/proxies.json"; }
_mhm_api() { exit 99; }
mhm node use 0
''', expected=1)

    def test_reload_body_without_python(self):
        self.shell('''
python3() { exit 99; }
_mhm_api() { printf '%s' "$3" > "$TEST_ROOT/api-body"; }
_mhm_wait_ready() { return 0; }
_mhm_reload_runtime
''')
        self.assertEqual(json.loads((self.root / 'api-body').read_text()),
                         {'path': str(self.root / 'data/config.yaml')})

    def test_github_subscription_and_provider_urls_are_proxied(self):
        self.shell('mhm add demo https://raw.githubusercontent.com/example/repo/main/config.yaml\n')
        self.assertIn('https://proxy.invalid/https://raw.githubusercontent.com/',
                      (self.root / 'downloads').read_text())
        profile = self.root / 'profile.yaml'
        profile.write_text('''rule-providers:
  remote:
    url: https://raw.githubusercontent.com/example/rules/main/rules.yaml
proxy-providers:
  remote:
    url: https://github.com/example/repo/releases/download/latest/config.yaml
external-ui-url: https://github.com/example/ui/releases/download/latest/ui.zip
''')
        self.shell('_mhm_render_runtime_config "$TEST_ROOT/profile.yaml" "$TEST_ROOT/rendered.yaml"\n')
        config = yaml.safe_load((self.root / 'rendered.yaml').read_text())
        for key in ('rule-providers', 'proxy-providers'):
            self.assertTrue(config[key]['remote']['url'].startswith('https://proxy.invalid/https://'))
        self.assertTrue(config['external-ui-url'].startswith('https://proxy.invalid/https://'))

    def test_redirect_to_github_is_prefixed_before_request(self):
        self.shell('mhm add demo https://subscription.invalid/start\n')
        calls = (self.root / 'downloads').read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0].endswith('https://subscription.invalid/start'))
        self.assertTrue(calls[1].endswith('https://proxy.invalid/https://raw.githubusercontent.com/example/repo/main/config.yaml'))
        self.assertTrue((self.root / 'cache/profiles/demo.yaml').exists())

    def test_full_validation_uses_proxied_config(self):
        binary = self.root / 'bin/mihomo'
        binary.parent.mkdir()
        binary.write_text('''#!/usr/bin/env python3
import json, os, sys, yaml
from pathlib import Path
config = yaml.safe_load(Path(sys.argv[sys.argv.index('-f') + 1]).read_text())
Path(os.environ['TEST_ROOT'], 'validated.json').write_text(json.dumps(config))
''')
        binary.chmod(0o700)
        profile = self.root / 'profile.yaml'
        profile.write_text('''rule-providers:
  remote:
    url: https://raw.githubusercontent.com/example/repo/main/rules.yaml
''')
        self.env['MIHOMO_VALIDATE'] = '1'
        self.shell('_mhm_validate_profile "$TEST_ROOT/profile.yaml"\n')
        config = json.loads((self.root / 'validated.json').read_text())
        self.assertTrue(config['rule-providers']['remote']['url'].startswith('https://proxy.invalid/https://'))

    def test_url_like_secret_is_preserved(self):
        self.env['MIHOMO_CONTROLLER_SECRET'] = 'https://github.com/secret/value'
        (self.root / 'profile.yaml').write_text('rules: ["MATCH,DIRECT"]\n')
        self.shell('_mhm_render_runtime_config "$TEST_ROOT/profile.yaml" "$TEST_ROOT/rendered.yaml"\n')
        config = yaml.safe_load((self.root / 'rendered.yaml').read_text())
        self.assertEqual(config['secret'], self.env['MIHOMO_CONTROLLER_SECRET'])

    def test_uninstall_keeps_data_on_request(self):
        self.install_and_register()
        self.shell('mhm uninstall --keep-data\n')
        self.assertTrue((self.root / 'data/config.yaml').exists())
        self.assertTrue((self.root / 'state').exists())
        self.assertFalse((self.root / 'bin/mihomo').exists())
        self.assertFalse((self.root / 'units/mihomo.service').exists())

    def test_uninstall_refuses_foreign_or_modified_artifacts(self):
        self.install_and_register()
        binary = self.root / 'bin/mihomo'
        binary.write_text('external change\n')
        self.shell('mhm uninstall\n', expected=1)
        self.assertTrue(binary.exists())
        self.assertTrue((self.root / 'units/mihomo.service').exists())
        self.assertNotIn('disable --now', (self.root / 'systemctl').read_text())

    def test_install_refuses_external_binary(self):
        binary = self.root / 'bin/mihomo'
        binary.parent.mkdir()
        binary.write_text('external installation\n')
        self.shell('mhm install\n', expected=1)
        self.assertEqual(binary.read_text(), 'external installation\n')
        self.assertFalse((self.root / 'downloads').exists())

    def test_failed_stop_prevents_uninstall(self):
        self.install_and_register()
        self.shell('FAIL_DISABLE=1\nmhm uninstall\n', expected=1)
        self.assertTrue((self.root / 'bin/mihomo').exists())
        self.assertTrue((self.root / 'units/mihomo.service').exists())

    def test_existing_config_is_restored_and_unrelated_data_kept(self):
        data = self.root / 'data'
        data.mkdir()
        (data / 'config.yaml').write_text('secret: original\n')
        (data / 'unrelated').write_text('keep\n')
        self.install_and_register()
        self.shell('''
printf 'rules: ["MATCH,DIRECT"]\n' > "$_PROFILE_DIR/demo.yaml"
_mhm_ensure_geo() { return 0; }
_mhm_reload_runtime() { return 0; }
_mhm_activate_cached demo || exit $?
mhm uninstall
''')
        self.assertEqual((data / 'config.yaml').read_text(), 'secret: original\n')
        self.assertEqual((data / 'unrelated').read_text(), 'keep\n')
        self.assertFalse((data / 'config.yaml.before-mihomo-sub').exists())

    def test_status_does_not_create_directories(self):
        self.shell('mhm status\n')
        self.assertFalse((self.root / 'state').exists())
        self.assertFalse((self.root / 'cache').exists())


    def test_keep_data_retains_only_data_artifact_records(self):
        self.install_and_register()
        original = json.loads((self.root / 'state/install.json').read_text())
        self.shell('mhm uninstall --keep-data\n')
        retained = json.loads((self.root / 'state/install.json').read_text())
        self.assertEqual(retained['scope'], 'user')
        self.assertEqual(retained['config'], original['config'])
        self.assertNotIn('binary', retained)
        self.assertNotIn('unit', retained)

    def test_full_uninstall_after_keep_data_cleans_generated_config(self):
        data = self.root / 'data'
        data.mkdir()
        (data / 'unrelated').write_text('keep\n')
        self.install_and_register()
        self.shell('mhm uninstall --keep-data\n')
        self.install_and_register()
        self.shell('mhm uninstall\n')
        self.assertFalse((data / 'config.yaml').exists())
        self.assertEqual((data / 'unrelated').read_text(), 'keep\n')
        self.assertFalse((self.root / 'state').exists())

    def test_keep_data_cycle_preserves_external_config_changes(self):
        data = self.root / 'data'
        data.mkdir()
        self.install_and_register()
        self.shell('mhm uninstall --keep-data\n')
        (data / 'config.yaml').write_text('secret: external-change\n')
        self.install_and_register()
        self.shell('mhm uninstall\n')
        self.assertEqual((data / 'config.yaml').read_text(), 'secret: external-change\n')


if __name__ == '__main__':
    unittest.main()
