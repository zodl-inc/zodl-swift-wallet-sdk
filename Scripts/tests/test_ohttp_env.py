"""Relay configuration stays process-local, private, and optional for SDK builds."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).resolve().parents[1] / 'lib/ohttp_env.py'
MAINNET = 'ZODL_OHTTP_RELAY_URL_MAINNET'
TESTNET = 'ZODL_OHTTP_RELAY_URL_TESTNET'
MAIN_URL = 'https://main.example.invalid/relay'
TEST_URL = 'https://test.example.invalid/relay'


class RelayEnvironmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not RUNNER.exists():
            return
        spec = importlib.util.spec_from_file_location('ohttp_env', RUNNER)
        cls.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.runner)

    def setUp(self):
        self.assertTrue(RUNNER.exists(), 'relay environment runner is missing')

    def resolve(self, values, required=False, shell_loader=lambda env: {}):
        return self.runner.resolve_relay_environment(values, required=required, shell_loader=shell_loader)

    def test_optional_absent_partial_and_empty_are_allowed(self):
        for values in ({}, {MAINNET: MAIN_URL}, {MAINNET: ''}, {MAINNET: '', TESTNET: ''}):
            self.assertEqual(self.resolve(values), values)

    def test_inherited_values_win_including_empty_and_full_environment_is_copied(self):
        inherited = {MAINNET: '', 'OTHER': 'preserved'}
        child = self.resolve(inherited, shell_loader=lambda env: {MAINNET: MAIN_URL, TESTNET: TEST_URL})
        self.assertEqual(child, {MAINNET: '', TESTNET: TEST_URL, 'OTHER': 'preserved'})
        self.assertEqual(inherited, {MAINNET: '', 'OTHER': 'preserved'})

    def test_required_missing_and_empty_are_rejected_by_name(self):
        for values in ({}, {MAINNET: ''}, {MAINNET: MAIN_URL}, {MAINNET: MAIN_URL, TESTNET: ''}):
            with self.assertRaisesRegex(ValueError, 'ZODL_OHTTP_RELAY_URL_'):
                self.resolve(values, required=True)
        self.assertEqual(self.resolve({MAINNET: MAIN_URL, TESTNET: TEST_URL}, required=True)[MAINNET], MAIN_URL)

    def test_invalid_urls_fail_without_values(self):
        for value in ('http://private.invalid/token', 'https://', 'https:///path', 'https://a b/path',
                      ' https://private.invalid', 'https://private.invalid/\nsecret', 'https://private.invalid/\x7f',
                      'https://private.invalid/\x80', 'https://private.invalid/\x9f', 'https://private.invalid/\u200b',
                      'https://private.invalid:bad', 'https://user:password@private.invalid', 'https://[broken', 'https://[::1]unexpected'):
            with self.subTest(value=value):
                with self.assertRaises(ValueError) as error:
                    self.runner.validate_relay_url(MAINNET, value, required=False)
                self.assertIn(MAINNET, str(error.exception))
                self.assertNotIn(value, str(error.exception))

    def test_ci_never_invokes_shell_loader(self):
        def forbidden(env):
            self.fail('CI tried shell startup')
        for key in ('CI', 'GITHUB_ACTIONS'):
            self.assertEqual(self.resolve({key: '1'}, shell_loader=forbidden), {key: '1'})
            self.assertEqual(self.runner.load_shell_exports({key: '1'}), {})

    def shell_environment(self, directory):
        return {'PATH': '/usr/bin:/bin', 'ZDOTDIR': str(directory)}

    def test_shell_import_only_exports_and_discards_startup_chatter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.zshenv').write_text(f'print startup-secret\nprint stderr-secret >&2\nexport {MAINNET}="{MAIN_URL}"\n{TESTNET}="{TEST_URL}"\n')
            result = self.runner.load_shell_exports(self.shell_environment(root))
            self.assertEqual(result, {MAINNET: MAIN_URL})
            completed = self.cli([], self.shell_environment(root))
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(completed.stdout, '')
            self.assertEqual(completed.stderr, '')

    def test_shell_failure_is_private_and_fatal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.zshenv').write_text('print startup-secret\nprint stderr-secret >&2\nexit 9\n')
            completed = self.cli([], self.shell_environment(root))
            self.assertNotEqual(completed.returncode, 0)
            self.assertNotIn('startup-secret', completed.stdout + completed.stderr)
            self.assertNotIn('stderr-secret', completed.stdout + completed.stderr)

    def test_shell_startup_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.zshenv').write_text('sleep 30\n')
            with self.assertRaisesRegex(ValueError, 'shell'):
                self.runner.load_shell_exports(self.shell_environment(root))

    def cli(self, arguments, env):
        return subprocess.run([sys.executable, str(RUNNER), '--optional', *arguments], env=env,
                              text=True, capture_output=True, timeout=12)

    def test_child_environment_argv_status_and_metacharacters_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'executed'
            value = f'https://main.example.invalid/$(touch${{IFS}}{marker});literal'
            inherited = {'CI': '1', MAINNET: value, TESTNET: TEST_URL, 'OTHER': 'kept'}
            code = 'import json,os,sys; print(json.dumps([dict(os.environ),sys.argv[1:]])); sys.exit(23)'
            result = self.cli(['--', sys.executable, '-c', code, 'a b', '$(literal)'], inherited)
            self.assertEqual(result.returncode, 23)
            child, argv = json.loads(result.stdout)
            self.assertEqual(child[MAINNET], value)
            self.assertEqual(child[TESTNET], TEST_URL)
            self.assertEqual(child['OTHER'], 'kept')
            self.assertEqual(argv, ['a b', '$(literal)'])
            self.assertFalse(marker.exists())

    def test_system_python_can_validate_in_an_xcode_build_phase(self):
        result = subprocess.run(['/usr/bin/python3', str(RUNNER), '--required'],
                                env={'CI': '1', MAINNET: MAIN_URL, TESTNET: TEST_URL},
                                text=True, capture_output=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '')

    def test_validation_is_silent_and_rejections_are_private(self):
        self.assertEqual(self.cli([], {'CI': '1'}).stdout, '')
        value = 'http://private.invalid/secret'
        result = self.cli([], {'CI': '1', MAINNET: value})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(value, result.stdout + result.stderr)
        self.assertIn(MAINNET, result.stderr)


if __name__ == '__main__':
    unittest.main()
