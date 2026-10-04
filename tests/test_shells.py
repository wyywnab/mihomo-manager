"""Shell integration: proxy changes must remain in the calling shell."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'mihomo-sub.sh'


class ShellTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith('MIHOMO_') or key.endswith('_proxy') or key in (
                'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'BASH_ENV', 'ZDOTDIR',
                'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'ZSH_VERSION', 'BASH_VERSION',
            ):
                del self.env[key]
        self.env.update(HOME=str(self.home), SCRIPT=str(SCRIPT))

    def run_shell(self, shell, body, expected=0):
        args = ['bash', '--noprofile', '--norc'] if shell == 'bash' else ['zsh', '-f']
        result = subprocess.run(args, input='source "$SCRIPT" || exit $?\n' + body,
                                text=True, capture_output=True, env=self.env, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_bash_export_serialization_preserves_quotes_without_execution(self):
        self.env['MIHOMO_PROXY_HOST'] = "host'quoted $(touch " + str(self.home / 'executed') + ')'
        result = self.run_shell('bash', '''
eval "$(mhm --system proxy env)" || exit $?
printf '%s\\n%s\\n' "$http_proxy" "$all_proxy"
''')
        self.assertEqual(result.stdout.splitlines(), [
            'http://' + self.env['MIHOMO_PROXY_HOST'] + ':7898',
            'socks5h://' + self.env['MIHOMO_PROXY_HOST'] + ':7898',
        ])
        self.assertFalse((self.home / 'executed').exists())

    @unittest.skipUnless(shutil.which('zsh'), 'zsh is not installed')
    def test_zsh_source_and_command_forwarding_preserve_unexported_settings(self):
        result = self.run_shell('zsh', '''
MIHOMO_GH_PROXY_DEFAULT=''
mhm gh-proxy reset || exit $?
[[ "$(mhm gh-proxy)" == '(direct / no GitHub proxy)' ]] || exit 91
mhm help || exit $?
''')
        self.assertIn('mhm', result.stdout)
        self.assertEqual((self.home / '.config/mihomo-sub/gh-proxy').read_text(), '\n')

    @unittest.skipUnless(shutil.which('zsh'), 'zsh is not installed')
    def test_zsh_proxy_changes_current_shell_and_preserves_default_scope(self):
        result = self.run_shell('zsh', '''
mhm --system proxy on || exit $?
[[ "$http_proxy" == http://127.0.0.1:7898 ]] || exit 91
[[ "$ALL_PROXY" == socks5h://127.0.0.1:7898 ]] || exit 92
mhm proxy on || exit $?
[[ "$http_proxy" == http://127.0.0.1:7897 ]] || exit 93
mhm env off || exit $?
[[ -z ${http_proxy+x}${HTTPS_PROXY+x}${ALL_PROXY+x} ]] || exit 94
''')
        self.assertIn('已关闭代理', result.stdout)
        self.assertFalse((self.home / '.config').exists())

    @unittest.skipUnless(shutil.which('zsh'), 'zsh is not installed')
    def test_zsh_custom_values_are_quoted_and_forwarded(self):
        self.env['MIHOMO_PROXY_HOST'] = "host'quoted $(touch " + str(self.home / 'executed') + ')'
        result = self.run_shell('zsh', '''
MIHOMO_PROXY_PORT=12345
mhm proxy on || exit $?
printf 'RESULT=%s\\n' "$http_proxy"
''')
        self.assertIn('RESULT=http://' + self.env['MIHOMO_PROXY_HOST'] + ':12345', result.stdout)
        self.assertFalse((self.home / 'executed').exists())


if __name__ == '__main__':
    unittest.main()
