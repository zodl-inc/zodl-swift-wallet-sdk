"""Required configuration stays process-local and private."""
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
NAMES = tuple('ZODL_OHTTP_' + suffix for suffix in (
    'GATEWAY_HOST_MAINNET', 'GATEWAY_HOST_TESTNET', 'RELAY_URL_MAINNET', 'RELAY_URL_TESTNET',
    'SIGNING_PUBKEY_MAINNET', 'SIGNING_PUBKEY_TESTNET', 'KEYS_DNS_NAME_MAINNET', 'KEYS_DNS_NAME_TESTNET'))
VALUES = dict(zip(NAMES, ('main.example.invalid', 'test.example.invalid', MAIN_URL, TEST_URL,
                          'a' * 64, 'b' * 64, '_main.example.invalid', '_test.example.invalid')))


class RelayEnvironmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('ohttp_env', RUNNER)
        cls.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.runner)

    def setUp(self):
        self.assertTrue(RUNNER.exists(), 'relay environment runner is missing')

    def resolve(self, values, shell_loader=lambda env: {}, github_loader=lambda env, names: {}):
        return self.runner.resolve_ohttp_environment(values, shell_loader=shell_loader, github_loader=github_loader)

    def test_fixed_eight_order_and_complete_inputs_never_load(self):
        def forbidden(*args):
            self.fail('complete input tried an external loader')
        self.assertEqual(self.runner.OHTTP_NAMES, NAMES)
        self.assertEqual(self.resolve(VALUES, forbidden, forbidden), VALUES)

    def test_inherited_values_win_including_empty(self):
        inherited = dict(VALUES, OTHER='preserved')
        inherited[MAINNET] = ''
        with self.assertRaisesRegex(ValueError, MAINNET):
            self.resolve(inherited, lambda env: VALUES)
        self.assertEqual(inherited[MAINNET], '')

    def test_each_missing_or_empty_name_is_required(self):
        for name in NAMES:
            for empty in (False, True):
                values = dict(VALUES, CI='1')
                if empty:
                    values[name] = ''
                else:
                    del values[name]
                with self.subTest(name=name, empty=empty), self.assertRaisesRegex(ValueError, name):
                    self.resolve(values)

    def test_missing_only_fetch_after_export_import(self):
        values = dict(VALUES)
        del values[NAMES[-1]]
        requests = []
        def github(env, names):
            requests.append(names)
            return {NAMES[-1]: VALUES[NAMES[-1]]}
        self.assertEqual(self.resolve(values, github_loader=github), VALUES)
        self.assertEqual(requests, [[NAMES[-1]]])
        self.assertEqual(self.resolve(values, shell_loader=lambda env: VALUES), VALUES)
        self.assertEqual(values[MAINNET], MAIN_URL)

    def test_controls_fail_with_name_only_diagnostics(self):
        for name in NAMES:
            for control in ('\0', '\n', '\x7f'):
                values = dict(VALUES)
                values[name] += control + 'private-input'
                with self.subTest(name=name, control=repr(control)), self.assertRaises(ValueError) as error:
                    self.resolve(values)
                self.assertIn(name, str(error.exception))
                self.assertNotIn('private-input', str(error.exception))

    def test_non_utf8_values_are_rejected_by_name(self):
        for name in NAMES:
            values = dict(VALUES)
            values[name] = 'private-input' + chr(0xd800)
            with self.subTest(name=name), self.assertRaises(ValueError) as error:
                self.resolve(values)
            self.assertIn(name, str(error.exception))
            self.assertNotIn('private-input', str(error.exception))

    def test_duplicate_gateway_rejected_ignoring_ascii_case(self):
        values = dict(VALUES)
        values[NAMES[1]] = values[NAMES[0]].upper()
        with self.assertRaisesRegex(ValueError, 'GATEWAY_HOST') as error:
            self.resolve(values)
        self.assertNotIn(values[NAMES[0]], str(error.exception))

    def test_hash_is_versioned_and_fixed_order_with_no_unrelated_entries(self):
        import hashlib
        payload = b'ZODL-OHTTP-CONFIG\x00v1\x00'
        for name in NAMES:
            for field in (name, VALUES[name]):
                encoded = field.encode('utf-8')
                payload += len(encoded).to_bytes(8, 'big') + encoded
        expected = hashlib.sha256(payload).hexdigest()
        self.assertEqual(self.runner.configuration_hash(VALUES), expected)
        self.assertEqual(self.runner.configuration_hash(dict(reversed(list(VALUES.items())), OTHER='ignored')), expected)
        for name in NAMES:
            changed = dict(VALUES)
            changed[name] += '/change' if 'RELAY_URL' in name else 'x'
            self.assertNotEqual(self.runner.configuration_hash(changed), expected)
        self.assertEqual(self.cli([], dict(VALUES, CI='1'), mode='--hash').stdout, expected + '\n')

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

    def test_ci_never_invokes_any_loader(self):
        def forbidden(*args):
            self.fail('CI tried an external loader')
        for key in ('CI', 'GITHUB_ACTIONS'):
            self.assertEqual(self.resolve(dict(VALUES, **{key: '1'}), forbidden, forbidden), dict(VALUES, **{key: '1'}))
            with self.assertRaises(ValueError):
                self.resolve({key: '1'}, forbidden, forbidden)
            self.assertEqual(self.runner.load_shell_exports({key: '1'}), {})
            self.assertEqual(self.runner.load_github_exports({key: '1'}, list(NAMES)), {})

    def shell_environment(self, directory):
        return {'PATH': '/usr/bin:/bin', 'ZDOTDIR': str(directory)}

    def test_shell_import_only_exports_and_discards_startup_chatter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.zshenv').write_text(f'print startup-secret\nprint stderr-secret >&2\nexport {MAINNET}="{MAIN_URL}"\n{TESTNET}="{TEST_URL}"\n')
            result = self.runner.load_shell_exports(self.shell_environment(root))
            self.assertEqual(result, {MAINNET: MAIN_URL})
            completed = self.cli([], dict(VALUES, **self.shell_environment(root)))
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

    def cli(self, arguments, env, mode='--required'):
        return subprocess.run([sys.executable, str(RUNNER), mode, *arguments], env=env,
                              text=True, capture_output=True, timeout=12)

    def test_child_environment_argv_status_and_metacharacters_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'executed'
            value = f'https://main.example.invalid/$(touch${{IFS}}{marker});literal'
            inherited = dict(VALUES, CI='1', OTHER='kept')
            inherited[MAINNET] = value
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
                                env=dict(VALUES, CI='1'),
                                text=True, capture_output=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '')

    def test_validation_is_silent_and_rejections_are_private(self):
        self.assertEqual(self.cli([], {'CI': '1'}).stdout, '')
        value = 'http://private.invalid/secret'
        env = dict(VALUES, CI='1')
        env[MAINNET] = value
        result = self.cli([], env)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(value, result.stdout + result.stderr)
        self.assertIn(MAINNET, result.stderr)

    def test_real_gh_boundary_structured_missing_only_and_private_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / 'gh'
            gh.write_text("#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nmode=os.environ.get('MODE','ok')\nif mode=='denied': print('secret value',file=sys.stderr); sys.exit(9)\nif mode=='malformed': print('not json'); sys.exit()\nname=sys.argv[3]\nprint(json.dumps({'name': name if mode!='wrong' else 'OTHER', 'value': 7 if mode=='type' else 'fetched-value'}))\n")
            gh.chmod(0o755)
            env = {'PATH': directory + os.pathsep + os.environ['PATH'], 'CALLS': str(root / 'calls'), 'GH_TOKEN': 'synthetic-token'}
            missing = [NAMES[-1]]
            self.assertEqual(self.runner.load_github_exports(env, missing), {NAMES[-1]: 'fetched-value'})
            calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
            self.assertEqual(calls, [['variable', 'get', NAMES[-1], '--repo', 'zodl-inc/zodl-swift-wallet-sdk-private', '--json', 'name,value']])
            for mode in ('denied', 'malformed', 'wrong', 'type'):
                with self.subTest(mode=mode), self.assertRaises(ValueError) as error:
                    self.runner.load_github_exports(dict(env, MODE=mode), missing)
                self.assertNotIn('secret value', str(error.exception))
                self.assertNotIn('synthetic-token', str(error.exception))
            with self.assertRaises(ValueError):
                self.runner.load_github_exports(env, ['GH_TOKEN'])

    def test_github_shared_deadline_and_os_errors_are_private(self):
        from unittest.mock import patch
        for failure in (subprocess.TimeoutExpired('gh secret', 1), PermissionError('token-secret')):
            with patch.object(self.runner.subprocess, 'run', side_effect=failure), self.assertRaises(ValueError) as error:
                self.runner.load_github_exports({}, list(NAMES))
            self.assertNotIn('secret', str(error.exception))

    def test_removed_optional_mode_is_rejected(self):
        self.assertNotEqual(self.cli([], dict(VALUES, CI='1'), mode='--optional').returncode, 0)


if __name__ == '__main__':
    unittest.main()
