"""Installer regressions using temporary homes and simulated HTTP responses."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'install.sh'
MOCKS = r'''
uname() {
  if [[ "$1" == -s ]]; then printf 'Linux\n'; else printf '%s\n' "${TEST_ARCH:-x86_64}"; fi
}
curl() {
  local arg dest='' next=0 url="${!#}" raw
  printf '%s\n' "$url" >> "$TEST_ROOT/downloads"
  [[ "${TEST_DOWNLOAD_FAIL:-0}" != 1 ]] || return 22
  for arg in "$@"; do
    if (( next )); then dest="$arg"; next=0; fi
    if [[ "$arg" == --output ]]; then next=1; fi
  done
  raw="${url#https://proxy.invalid/}"
  raw="${raw#https://gh-proxy.org/}"
  case "$raw" in
    https://raw.githubusercontent.com/*/install.sh)
      cat "$TEST_INSTALLER" ;;
    https://raw.githubusercontent.com/*/mihomo-sub.sh)
      cp "$TEST_SCRIPT" "$dest"
      printf '200\n\n' ;;
    https://github.com/mikefarah/yq/releases/latest/download/yq_linux_*)
      if [[ "${TEST_REDIRECT_YQ:-0}" == 1 ]]; then
        printf '302\nhttps://github.com/mikefarah/yq/releases/download/v4.45.1/%s\n' "${raw##*/}"
      else
        cp "$TEST_ROOT/yq-asset" "$dest"
        printf '200\n\n'
      fi ;;
    https://github.com/mikefarah/yq/releases/download/*/yq_linux_*)
      cp "$TEST_ROOT/yq-asset" "$dest"
      printf '200\n\n' ;;
    *) printf 'Unexpected download: %s\n' "$url" >&2; return 99 ;;
  esac
}
python3() { printf 'Installer must not use Python\n' >&2; return 99; }
sudo() { printf 'Installer must not use sudo\n' >&2; return 99; }
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith('MIHOMO_') or key in ('BASH_ENV', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'ZDOTDIR'):
                del self.env[key]
        mocks = self.root / 'mocks.sh'
        mocks.write_text(MOCKS)
        self.env.update({
            'HOME': str(self.home), 'BASH_ENV': str(mocks),
            'TEST_ROOT': str(self.root), 'TEST_SCRIPT': str(ROOT / 'mihomo-sub.sh'),
            'TEST_INSTALLER': str(INSTALLER),
            'MIHOMO_GH_PROXY_DEFAULT': 'https://proxy.invalid/',
        })
        (self.root / 'yq-asset').write_text('#!/bin/sh\nprintf "yq version v4.45.1\\n"\n')

    @property
    def target(self):
        return self.home / '.local/share/mihomo-sub.sh'

    @property
    def yq(self):
        return self.home / '.local/bin/yq'

    @property
    def bashrc(self):
        return self.home / '.bashrc'

    def run_install(self, *args, stdin=False, expected=0):
        command = ['bash', '-s', '--', *args] if stdin else ['bash', str(INSTALLER), *args]
        result = subprocess.run(command, input=INSTALLER.read_text() if stdin else None,
                                text=True, capture_output=True, env=self.env, timeout=20)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_defaults_install_both_and_only_print_bashrc_hint(self):
        self.bashrc.write_text('# original bashrc\n')
        result = self.run_install()
        self.assertEqual(self.target.read_bytes(), (ROOT / 'mihomo-sub.sh').read_bytes())
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(self.yq.stat().st_mode), 0o755)
        self.assertEqual(self.bashrc.read_text(), '# original bashrc\n')
        self.assertIn('请把下面内容加入', result.stdout)
        self.assertIn(str(self.target), result.stdout)
        self.assertIn(str(self.yq), result.stdout)

    def test_skip_yq_needs_no_download(self):
        self.run_install('--no-yq')
        self.assertTrue(self.target.exists())
        self.assertFalse(self.yq.exists())
        self.assertFalse((self.root / 'downloads').exists())
        self.assertFalse(self.bashrc.exists())

    def test_zsh_default_only_prints_zshrc_hint(self):
        zshrc = self.home / '.zshrc'
        zshrc.write_text('setopt AUTO_CD\n')
        result = self.run_install('--shell', 'zsh', '--no-yq')
        self.assertIn(str(zshrc), result.stdout)
        self.assertEqual(zshrc.read_text(), 'setopt AUTO_CD\n')
        self.assertFalse(self.bashrc.exists())

    def test_zsh_auto_rc_preserves_existing_zsh_configuration(self):
        zshrc = self.home / '.zshrc'
        original = 'setopt AUTO_CD\narr=(one two)\nprint -r -- ${arr[1]}\n'
        zshrc.write_text(original)
        self.run_install('--shell', 'zsh', '--add-rc', '--no-yq')
        self.run_install('--shell', 'zsh', '--add-rc', '--no-yq')
        self.assertIn(original, zshrc.read_text())
        self.assertEqual(zshrc.read_text().count('# >>> mihomo-manager >>>'), 1)
        self.assertEqual(Path(str(zshrc) + '.before-mhm-installer').read_text(), original)
        self.assertFalse(self.bashrc.exists())

    def test_zsh_default_respects_zdotdir(self):
        self.env['ZDOTDIR'] = str(self.home / 'zsh configs')
        self.run_install('--shell', 'zsh', '--add-rc', '--no-yq')
        self.assertTrue((Path(self.env['ZDOTDIR']) / '.zshrc').exists())
        self.assertFalse((self.home / '.zshrc').exists())

    def test_explicit_rc_overrides_zsh_default(self):
        rc = self.home / 'custom rc'
        self.run_install('--rc-file', str(rc), '--shell', 'zsh', '--add-rc', '--no-yq')
        self.assertIn('source', rc.read_text())
        self.assertFalse((self.home / '.zshrc').exists())

    def test_auto_bashrc_is_idempotent_and_backs_up_original(self):
        original = '# user config\nexport TEST_ORIGINAL=1\n'
        self.bashrc.write_text(original)
        self.bashrc.chmod(0o640)
        self.run_install('--add-bashrc')
        self.run_install('--add-bashrc')
        content = self.bashrc.read_text()
        self.assertEqual(content.count('# >>> mihomo-manager >>>'), 1)
        self.assertEqual(content.count('# <<< mihomo-manager <<<'), 1)
        self.assertIn(original, content)
        self.assertEqual((self.home / '.bashrc.before-mhm-installer').read_text(), original)
        self.assertEqual(stat.S_IMODE(self.bashrc.stat().st_mode), 0o640)
        self.assertEqual(len((self.root / 'downloads').read_text().splitlines()), 1)
        result = subprocess.run(['bash', '-c', 'source "$HOME/.bashrc"; declare -F mhm; printf "%s" "$MIHOMO_YQ_BIN"'],
                                capture_output=True, text=True, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('mhm', result.stdout)
        self.assertIn(str(self.yq), result.stdout)

    def test_custom_paths_with_quotes_spaces_and_dollars(self):
        target = self.home / 'share "quoted" $literal' / 'mhm script.sh'
        yq = self.home / 'bin "quoted" $literal' / 'yq'
        bashrc = self.home / 'custom bashrc'
        self.run_install('--path', str(target), '--yq-path', str(yq), '--bashrc', str(bashrc), '--add-bashrc')
        env = self.env.copy()
        env['TEST_BASHRC'] = str(bashrc)
        result = subprocess.run(['bash', '-c', 'source "$TEST_BASHRC"; declare -F mhm; printf "%s" "$MIHOMO_YQ_BIN"'],
                                capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(yq), result.stdout)
        self.assertTrue(target.exists())

    def test_stdin_install_downloads_main_script_from_default_repo(self):
        self.run_install('--no-yq', '--add-bashrc', stdin=True)
        calls = (self.root / 'downloads').read_text()
        self.assertIn('https://proxy.invalid/https://raw.githubusercontent.com/wyywnab/mihomo-manager/main/mihomo-sub.sh', calls)
        self.assertTrue(self.target.exists())
        self.assertTrue(self.bashrc.exists())

    def test_readme_remote_commands_apply_proxy_choice_to_all_downloads(self):
        commands = [line for line in (ROOT / 'README.md').read_text().splitlines()
                    if line.startswith('bash -o pipefail -c ')]
        self.assertEqual(len(commands), 2)
        for index, command in enumerate(commands):
            with self.subTest(proxy=index == 0):
                root = self.root / f'bootstrap-{index}'
                home = root / 'home'
                home.mkdir(parents=True)
                (root / 'yq-asset').write_bytes((self.root / 'yq-asset').read_bytes())
                env = self.env.copy()
                env.update(HOME=str(home), TEST_ROOT=str(root))
                rc = home / 'custom zshrc'
                result = subprocess.run(
                    ['bash', '--noprofile', '--norc'],
                    input=command + ' --shell zsh --add-rc --rc-file "$HOME/custom zshrc"\n',
                    text=True, capture_output=True, env=env, timeout=20,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = (root / 'downloads').read_text().splitlines()
                self.assertEqual(len(calls), 3)  # installer, manager, native yq
                prefix = 'https://gh-proxy.org/' if index == 0 else ''
                self.assertEqual(calls[0], prefix + 'https://raw.githubusercontent.com/wyywnab/mihomo-manager/main/install.sh')
                self.assertEqual(calls[1], prefix + 'https://raw.githubusercontent.com/wyywnab/mihomo-manager/main/mihomo-sub.sh')
                self.assertEqual(calls[2], prefix + 'https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64')
                self.assertTrue((home / '.local/share/mihomo-sub.sh').exists())
                self.assertTrue((home / '.local/bin/yq').exists())
                self.assertTrue(rc.exists())
                self.assertFalse((home / '.bashrc').exists())
                self.assertIn('export MIHOMO_GH_PROXY_DEFAULT=' + (prefix[:-1] if prefix else "''"), rc.read_text())

    def test_repo_and_ref_override_local_checkout(self):
        self.run_install('--no-yq', '--repo', 'example/fork', '--ref', 'develop')
        self.assertIn('https://raw.githubusercontent.com/example/fork/develop/mihomo-sub.sh',
                      (self.root / 'downloads').read_text())

    def test_readme_commands_report_bootstrap_download_failure(self):
        self.env['TEST_DOWNLOAD_FAIL'] = '1'
        commands = [line for line in (ROOT / 'README.md').read_text().splitlines()
                    if line.startswith('bash -o pipefail -c ')]
        for command in commands:
            with self.subTest(command=command):
                result = subprocess.run(['bash', '--noprofile', '--norc'], input=command,
                                        text=True, capture_output=True, env=self.env, timeout=20)
                self.assertEqual(result.returncode, 22, result.stdout + result.stderr)
                self.assertFalse(self.target.exists())
                self.assertFalse(self.yq.exists())

    def test_empty_proxy_downloads_directly(self):
        self.run_install('--gh-proxy', '', stdin=True)
        calls = (self.root / 'downloads').read_text().splitlines()
        self.assertTrue(all(url.startswith(('https://github.com/', 'https://raw.githubusercontent.com/')) for url in calls))
        self.assertNotIn('https://proxy.invalid/', '\n'.join(calls))

    def test_saved_empty_proxy_is_used_if_environment_is_unset(self):
        del self.env['MIHOMO_GH_PROXY_DEFAULT']
        setting = self.home / '.config/mihomo-sub/gh-proxy'
        setting.parent.mkdir(parents=True)
        setting.write_text('\n')
        self.run_install()
        self.assertTrue((self.root / 'downloads').read_text().startswith('https://github.com/'))

    def test_github_redirect_gets_prefix_at_each_hop(self):
        self.env['TEST_REDIRECT_YQ'] = '1'
        self.run_install()
        calls = (self.root / 'downloads').read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(url.startswith('https://proxy.invalid/https://github.com/') for url in calls))
        self.assertIn('/releases/download/v4.45.1/', calls[1])

    def test_arm64_yq_asset(self):
        self.env['TEST_ARCH'] = 'aarch64'
        self.run_install()
        self.assertIn('yq_linux_arm64', (self.root / 'downloads').read_text())

    def test_download_failure_does_not_replace_installed_script(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_text('# old installation\n')
        self.env['TEST_DOWNLOAD_FAIL'] = '1'
        self.run_install(expected=1)
        self.assertEqual(self.target.read_text(), '# old installation\n')
        self.assertFalse(self.bashrc.exists())

    def test_wrong_yq_version_is_rejected_before_installing_main(self):
        (self.root / 'yq-asset').write_text('#!/bin/sh\nprintf "yq version 3.1.0\\n"\n')
        self.run_install(expected=1)
        self.assertFalse(self.target.exists())
        self.assertFalse(self.yq.exists())

    def test_malformed_bashrc_markers_preserve_original(self):
        original = '# original\n# >>> mihomo-manager >>>\nexport KEEP=1\n'
        self.bashrc.write_text(original)
        self.run_install('--no-yq', '--add-bashrc', expected=1)
        self.assertEqual(self.bashrc.read_text(), original)

    def test_symlinked_bashrc_remains_a_symlink(self):
        actual = self.home / 'dotfiles/bashrc'
        actual.parent.mkdir()
        actual.write_text('# linked bashrc\n')
        self.bashrc.symlink_to(actual)
        self.run_install('--no-yq', '--add-bashrc')
        self.assertTrue(self.bashrc.is_symlink())
        self.assertIn('# >>> mihomo-manager >>>', actual.read_text())

    def test_invalid_arguments_do_not_install(self):
        for arguments in [('--path',), ('--unknown',), ('--gh-proxy', 'invalid'),
                          ('--repo', 'invalid'), ('--yq-version', 'v3.1.0'), ('--shell', 'fish')]:
            with self.subTest(arguments=arguments):
                self.run_install(*arguments, expected=1)
                self.assertFalse(self.target.exists())


    def test_requested_yq_version_replaces_a_different_installed_version(self):
        self.yq.parent.mkdir(parents=True)
        self.yq.write_text('#!/bin/sh\nprintf "yq version v4.45.1\\n"\n')
        self.yq.chmod(0o755)
        (self.root / 'yq-asset').write_text('#!/bin/sh\nprintf "yq version v4.40.1\\n"\n')
        self.run_install('--yq-version', 'v4.40.1')
        self.assertIn('v4.40.1', self.yq.read_text())
        self.assertIn('/releases/download/v4.40.1/yq_linux_amd64',
                      (self.root / 'downloads').read_text())

    def test_requested_yq_version_reuses_the_matching_installed_version(self):
        self.yq.parent.mkdir(parents=True)
        self.yq.write_text('#!/bin/sh\nprintf "yq version v4.45.1\\n"\n')
        self.yq.chmod(0o755)
        self.run_install('--yq-version', 'v4.45.1')
        self.assertFalse((self.root / 'downloads').exists())

    def test_downloaded_yq_must_match_the_requested_version(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_text('# old installation\n')
        self.yq.parent.mkdir(parents=True)
        self.yq.write_text('#!/bin/sh\nprintf "yq version v4.45.1\\n"\n')
        self.yq.chmod(0o755)
        self.run_install('--yq-version', 'v4.40.1', expected=1)
        self.assertEqual(self.target.read_text(), '# old installation\n')
        self.assertIn('v4.45.1', self.yq.read_text())

    def test_explicit_ref_overrides_the_local_checkout(self):
        for use_environment in (False, True):
            with self.subTest(use_environment=use_environment):
                if use_environment:
                    self.env['MIHOMO_INSTALL_REF'] = 'release/test'
                    self.run_install('--no-yq')
                else:
                    self.run_install('--no-yq', '--ref', 'release/test')
                self.assertIn('/wyywnab/mihomo-manager/release/test/mihomo-sub.sh',
                              (self.root / 'downloads').read_text())
                (self.root / 'downloads').unlink()

    def test_failed_explicit_ref_download_preserves_installed_script(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_text('# old installation\n')
        self.env['TEST_DOWNLOAD_FAIL'] = '1'
        self.run_install('--no-yq', '--ref', 'missing-branch', expected=1)
        self.assertEqual(self.target.read_text(), '# old installation\n')


if __name__ == '__main__':
    unittest.main()
