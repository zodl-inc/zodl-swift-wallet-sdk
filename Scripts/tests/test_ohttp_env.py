"""Required configuration stays process-local and private."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

RUNNER = Path(__file__).resolve().parents[1] / 'lib/ohttp_env.py'
MAINNET = 'ZODL_OHTTP_RELAY_URL_MAINNET'
TESTNET = 'ZODL_OHTTP_RELAY_URL_TESTNET'
MAIN_URL = 'https://main.example.invalid/relay'
TEST_URL = 'https://test.example.invalid/relay'
NAMES = tuple('ZODL_OHTTP_' + suffix for suffix in (
    'GATEWAY_HOST_MAINNET', 'GATEWAY_HOST_TESTNET', 'RELAY_URL_MAINNET', 'RELAY_URL_TESTNET',
    'SIGNING_PUBKEY_MAINNET', 'SIGNING_PUBKEY_TESTNET', 'KEYS_DNS_NAME_MAINNET', 'KEYS_DNS_NAME_TESTNET'))
VALUES = dict(zip(NAMES, ('main.example.invalid', 'test.example.invalid', MAIN_URL, TEST_URL,
                          'a' * 64, 'b' * 64, 'main.example.invalid', 'test.example.invalid')))


class RelayEnvironmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('ohttp_env', RUNNER)
        cls.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.runner)

    def setUp(self):
        self.assertTrue(RUNNER.exists(), 'relay environment runner is missing')

    def resolve(self, values):
        return self.runner.resolve_ohttp_environment(values)

    def test_fixed_eight_order_and_complete_inputs_are_copied_without_subprocesses(self):
        inherited = dict(VALUES, OTHER='preserved')
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('shell started')), \
                patch.object(subprocess, 'run', side_effect=AssertionError('GitHub started')):
            resolved = self.resolve(inherited)
        self.assertEqual(self.runner.OHTTP_NAMES, NAMES)
        self.assertEqual(resolved, inherited)
        self.assertIsNot(resolved, inherited)
        resolved['OTHER'] = 'changed'
        self.assertEqual(inherited['OTHER'], 'preserved')

    def test_each_missing_or_empty_name_fails_without_external_acquisition(self):
        for context in ({}, {'CI': '1'}, {'GITHUB_ACTIONS': 'true'}, {'OHTTP_ENV_RESOLVED': '1'}):
            for name in NAMES:
                for empty in (False, True):
                    values = dict(VALUES, **context)
                    if empty:
                        values[name] = ''
                    else:
                        del values[name]
                    with self.subTest(context=context, name=name, empty=empty), \
                            patch.object(subprocess, 'Popen', side_effect=AssertionError('shell started')), \
                            patch.object(subprocess, 'run', side_effect=AssertionError('GitHub started')), \
                            self.assertRaisesRegex(ValueError, name):
                        self.resolve(values)

    def test_shared_relay_key_and_dns_values_are_accepted_unchanged(self):
        values = dict(VALUES)
        for first, second in ((NAMES[2], NAMES[3]), (NAMES[4], NAMES[5]), (NAMES[6], NAMES[7])):
            values[second] = values[first]
        self.assertEqual(self.resolve(values), values)

    def test_missing_inputs_never_execute_filling_zshrc_or_gh_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / 'external-call'
            exports = ''.join(f'export {name}={value}\n' for name, value in VALUES.items())
            (root / '.zshrc').write_text(f'touch {marker}\n' + exports)
            gh = root / 'gh'
            gh.write_text(
                '#!/usr/bin/env python3\nimport json, pathlib, sys\n'
                f'pathlib.Path({str(marker)!r}).touch()\n'
                'print(json.dumps({"name":sys.argv[3],"value":"test.example.invalid"}))\n'
            )
            gh.chmod(0o755)
            env = dict(VALUES, PATH=directory + os.pathsep + os.environ['PATH'], ZDOTDIR=directory)
            del env[NAMES[-1]]
            result = self.cli([], env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(NAMES[-1], result.stderr)
            self.assertFalse(marker.exists(), 'configuration acquisition executed')

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

    def test_bare_host_grammar_rejects_invalid_inputs_without_values(self):
        invalid = ('https://private-canary.invalid/path', 'private-canary.invalid:443',
                   'private-canary.invalid/path', 'private-canary.invalid?query', 'private-canary.invalid#fragment',
                   '.private-canary.invalid', 'private-canary.invalid.', 'private-canary..invalid',
                   '-private-canary.invalid', 'private-canary-.invalid', '_private-canary.invalid',
                   'private canary.invalid', 'private\\canary.invalid', 'prívate-canary.invalid',
                   'private-canary.\u200b.invalid', 'a' * 64 + '.invalid',
                   '.'.join(('a' * 63,) * 3 + ('b' * 62,)))
        for name in (NAMES[0], NAMES[1], NAMES[6], NAMES[7]):
            for value in invalid:
                with self.subTest(name=name, value=value):
                    with self.assertRaises(ValueError) as caught:
                        self.resolve(dict(VALUES, CI='1', **{name: value}))
                    self.assertIn(name, str(caught.exception))
                    self.assertIn('bare DNS host name', str(caught.exception))
                    self.assertNotIn(value, str(caught.exception))

    def test_bare_host_grammar_preserves_valid_boundary_values(self):
        valid = ('a', '0', '127.0.0.1', 'A-1.example.INVALID', 'xn--bcher-kva.invalid',
                 'a' * 63 + '.invalid', '.'.join(('a' * 63,) * 3 + ('b' * 61,)))
        for name in (NAMES[0], NAMES[1], NAMES[6], NAMES[7]):
            for value in valid:
                with self.subTest(name=name, value=value):
                    environment = dict(VALUES, CI='1', **{name: value})
                    self.assertEqual(environment, self.resolve(environment))

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
        expected = 'a2bddd883cc977a28d0a01647b082acb5a15c3add9773f9e3330e0d5f9f17241'
        self.assertEqual(hashlib.sha256(payload).hexdigest(), expected)
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

    def test_relay_requires_literal_lowercase_scheme_without_disclosing_values(self):
        for name in (MAINNET, TESTNET):
            for value in ('HTTPS://private-canary.invalid/relay', 'hTtPs://private-canary.invalid/relay',
                          'https://@private-canary.invalid/relay', 'https://:443/relay', 'https://[]/relay'):
                with self.subTest(name=name, value=value):
                    with self.assertRaises(ValueError) as caught:
                        self.resolve(dict(VALUES, CI='1', **{name: value}))
                    self.assertIn(name, str(caught.exception))
                    self.assertNotIn(value, str(caught.exception))

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

    def test_removed_optional_mode_is_rejected(self):
        self.assertNotEqual(self.cli([], dict(VALUES, CI='1'), mode='--optional').returncode, 0)


if __name__ == '__main__':
    unittest.main()
