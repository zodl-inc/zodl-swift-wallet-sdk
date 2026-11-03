"""Exercise SDK-owned native entrypoints without compiling or downloading Rust."""
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MAINNET = 'ZODL_OHTTP_RELAY_URL_MAINNET'
TESTNET = 'ZODL_OHTTP_RELAY_URL_TESTNET'
NAMES = tuple('ZODL_OHTTP_' + suffix for suffix in ('GATEWAY_HOST_MAINNET', 'GATEWAY_HOST_TESTNET', 'RELAY_URL_MAINNET', 'RELAY_URL_TESTNET', 'SIGNING_PUBKEY_MAINNET', 'SIGNING_PUBKEY_TESTNET', 'KEYS_DNS_NAME_MAINNET', 'KEYS_DNS_NAME_TESTNET'))
MAIN_URL = 'https://main.example.invalid/relay'
TEST_URL = 'https://test.example.invalid/relay'
VALUES = dict(zip(NAMES, ('main.example.invalid', 'test.example.invalid', MAIN_URL, TEST_URL, 'a'*64, 'b'*64, '_main.example.invalid', '_test.example.invalid')))


class NativeRelayEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for path in ('Makefile', 'Scripts/init-local-ffi.sh', 'Scripts/rebuild-local-ffi.sh', 'Scripts/version-macos-framework.sh',
                     'BuildSupport/Makefile', 'BuildSupport/Info.plist', 'BuildSupport/module.modulemap', 'BuildSupport/platform-Info.plist',
                     'BuildSupport/LocalPackages-Package.swift', 'Scripts/prepare-release.sh', 'Scripts/lib/release-lib.sh'):
            dest = self.root / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, dest)
        if (ROOT / 'Scripts/lib/ohttp_env.py').exists():
            (self.root / 'Scripts/lib').mkdir(exist_ok=True)
            shutil.copy2(ROOT / 'Scripts/lib/ohttp_env.py', self.root / 'Scripts/lib/ohttp_env.py')
        tools = self.root / 'bin'
        tools.mkdir()
        cargo = tools / 'cargo'
        cargo.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
with open(os.environ['CAPTURE'], 'a') as output:
    output.write(json.dumps([sys.argv[1:], {key: os.environ.get(key) for key in os.environ if key.startswith('ZODL_OHTTP_')}])+'\\n')
args=sys.argv[1:]
root=pathlib.Path(os.environ['FIXTURE_ROOT'])
for index, arg in enumerate(args):
    if arg == '--target':
        lib=root/'target'/args[index+1]/'release/libzcashlc.a'
        lib.parent.mkdir(parents=True, exist_ok=True)
        lib.write_text('library')
(root/'target/Headers').mkdir(parents=True, exist_ok=True)
(root/'target/Headers/zcashlc.h').write_text('header')
''')
        rustup = tools / 'rustup'
        rustup.write_text('#!/bin/sh\nif [ "$1 $2" = "target list" ]; then printf "%s\\n" aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; fi\n')
        lipo = tools / 'lipo'
        lipo.write_text('''#!/usr/bin/env python3
import pathlib,sys
if '-output' in sys.argv:
    pathlib.Path(sys.argv[sys.argv.index('-output')+1]).write_text('library')
else:
    print('arm64')
''')
        for script in (cargo, rustup, lipo):
            script.chmod(0o755)
        startup = self.root / 'shell'
        startup.mkdir()
        (startup / '.zshenv').write_text('')
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('ZODL_OHTTP_') and key not in ('CI', 'GITHUB_ACTIONS', 'CARGO_HOME', 'RUSTUP_HOME')}
        gh = tools / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
if sys.argv[1:3] == ['auth','status']: sys.exit(0)
if sys.argv[1:3] == ['release','view']: sys.exit(1)
if sys.argv[1:3] == ['release','create']: sys.exit(0)
name=sys.argv[3]
root=pathlib.Path(os.environ['FIXTURE_ROOT'])
with (root/'gh.jsonl').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
values=json.loads((root/'values.json').read_text())
print(json.dumps({'name':name,'value':values[name]}))
values[name] += 'changed'
(root/'values.json').write_text(json.dumps(values))
''')
        gh.chmod(0o755)
        swift = tools / 'swift'
        swift.write_text('''#!/usr/bin/env python3
import json,os,pathlib
with (pathlib.Path(os.environ['FIXTURE_ROOT'])/'swift.jsonl').open('a') as f:
    f.write(json.dumps({k:v for k,v in os.environ.items() if k.startswith('ZODL_OHTTP_')})+'\\n')
''')
        swift.chmod(0o755)
        suite = self.root / 'Scripts/tests/run-tests.sh'
        suite.parent.mkdir(parents=True)
        suite.write_text(swift.read_text().replace('swift.jsonl', 'suite.jsonl'))
        suite.chmod(0o755)
        self.env.update(PATH=str(tools) + os.pathsep + self.env['PATH'], ZDOTDIR=str(startup),
                        CAPTURE=str(self.root / 'cargo.jsonl'), FIXTURE_ROOT=str(self.root))

    def run_native(self, command, cwd=None):
        (self.root / 'values.json').write_text(json.dumps(VALUES))
        (self.root / 'gh.jsonl').unlink(missing_ok=True)
        result = subprocess.run(command, cwd=cwd or self.root, env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.root / 'cargo.jsonl').read_text().splitlines()]
        self.assertTrue(calls)
        for argv, values in calls:
            self.assertEqual(values, VALUES)
            self.assertNotIn(MAIN_URL, argv)
            self.assertNotIn(TEST_URL, argv)
        lookups = [json.loads(line) for line in (self.root / 'gh.jsonl').read_text().splitlines()]
        self.assertEqual([call[2] for call in lookups], list(NAMES))
        self.assertTrue(all(call[3:] == ['--repo', 'zodl-inc/zodl-swift-wallet-sdk-private', '--json', 'name,value'] for call in lookups))
        return calls

    def test_init_arm_subsets_receive_local_exports(self):
        for flag, targets in (('--arm-macos', ['aarch64-apple-darwin']),
                              ('--arm-simulator', ['aarch64-apple-ios-sim']),
                              ('--arm-ios', ['aarch64-apple-ios-sim', 'aarch64-apple-ios']),
                              ('--arm-all', ['aarch64-apple-ios-sim', 'aarch64-apple-ios', 'aarch64-apple-darwin'])):
            with self.subTest(flag=flag):
                capture = self.root / 'cargo.jsonl'
                capture.unlink(missing_ok=True)
                calls = self.run_native(['bash', 'Scripts/init-local-ffi.sh', flag])
                self.assertEqual([argv[argv.index('--target')+1] for argv, _ in calls], targets)

    def test_rebuild_single_and_universal_slices_receive_local_exports(self):
        (self.root / 'LocalPackages/libzcashlc.xcframework').mkdir(parents=True)
        for target, flag, count in (('ios-device', '', 1), ('ios-sim', '', 1), ('macos', '', 1),
                                    ('ios-sim', '--universal', 2), ('macos', '--universal', 2)):
            with self.subTest(target=target, flag=flag):
                (self.root / 'cargo.jsonl').unlink(missing_ok=True)
                command = ['bash', 'Scripts/rebuild-local-ffi.sh', target]
                self.assertEqual(len(self.run_native(command + ([flag] if flag else []))), count)

    def test_root_native_cargo_commands_receive_local_exports(self):
        for target, argv in (('build-rust', ['build']), ('build-rust-release', ['build', '--release']),
                             ('test-rust', ['test', '--locked'])):
            with self.subTest(target=target):
                (self.root / 'cargo.jsonl').unlink(missing_ok=True)
                calls = self.run_native(['make', target])
                self.assertEqual(calls[0][0], argv)

    def test_buildsupport_native_cargo_targets_receive_local_exports(self):
        for target, count in (('cargo-all', 5), ('cargo-macos', 2), ('cargo-ios-device', 1), ('cargo-ios-simulator', 2)):
            with self.subTest(target=target):
                (self.root / 'cargo.jsonl').unlink(missing_ok=True)
                calls = self.run_native(['make', '-C', 'BuildSupport', target])
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][0].count('--target'), count)

    def test_full_packaging_and_ci_entrypoints_resolve_once(self):
        for command in (['bash', 'Scripts/init-local-ffi.sh'], ['make', 'ffi-ci'], ['make', 'ffi-all'],
                        ['make', 'ffi-macos'], ['make', '-C', 'BuildSupport', 'xcframework']):
            with self.subTest(command=command):
                (self.root / 'cargo.jsonl').unlink(missing_ok=True)
                self.run_native(command)

    def test_invalid_configuration_is_rejected_before_cleanup(self):
        product = self.root / 'BuildSupport/products/macos/keep'
        product.parent.mkdir(parents=True)
        product.write_text('keep')
        env = dict(self.env, CI='1')
        result = subprocess.run(['make', 'ffi-ci'], cwd=self.root, env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(product.exists())
        self.assertFalse((self.root / 'cargo.jsonl').exists())

    def test_cached_initializer_never_imports_or_fetches_config(self):
        # Stop at the ordinary precompiled release download boundary.
        (self.root / 'Package.swift').write_text('https://github.com/example/sdk/releases/download/1/libzcashlc.xcframework.zip\nchecksum: "' + 'a'*64 + '"\n')
        gh = self.root / 'bin/gh'
        gh.write_text('#!/bin/sh\nprintf "%s\\n" "$*" > "$FIXTURE_ROOT/cached-gh"\nexit 42\n')
        result = subprocess.run(['bash', 'Scripts/init-local-ffi.sh', '--cached'], cwd=self.root, env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('release download', (self.root / 'cached-gh').read_text())
        self.assertFalse((self.root / 'cargo.jsonl').exists())

    def test_source_aggregate_builds_and_checks_share_one_environment(self):
        for target in ('build-all', 'build-all-release', 'check-all', 'check'):
            with self.subTest(target=target):
                (self.root / 'cargo.jsonl').unlink(missing_ok=True)
                (self.root / 'swift.jsonl').unlink(missing_ok=True)
                (self.root / 'suite.jsonl').unlink(missing_ok=True)
                self.run_native(['make', target])
                swift_calls = [json.loads(line) for line in (self.root / 'swift.jsonl').read_text().splitlines()]
                self.assertTrue(swift_calls)
                self.assertTrue(all(values == VALUES for values in swift_calls))
                if target in ('check-all', 'check'):
                    self.assertEqual([json.loads(line) for line in (self.root / 'suite.jsonl').read_text().splitlines()], [VALUES])

    def test_relative_script_paths_work_from_another_directory(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.root / 'LocalPackages/libzcashlc.xcframework').mkdir(parents=True)
        for command in (['bash', '../Scripts/init-local-ffi.sh', '--arm-macos'],
                        ['bash', '../Scripts/rebuild-local-ffi.sh', 'macos']):
            (self.root / 'cargo.jsonl').unlink(missing_ok=True)
            self.run_native(command, cwd=outside)

    def test_source_make_dry_runs_never_resolve_or_fetch(self):
        for command in (['make', '-n', 'ffi-ci'], ['make', '-n', '-C', 'BuildSupport', 'xcframework']):
            result = subprocess.run(command, cwd=self.root, env=dict(self.env, CI='1'), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('cargo build', result.stdout)
            self.assertFalse((self.root / 'gh.jsonl').exists())
            self.assertFalse((self.root / 'cargo.jsonl').exists())

    def test_manual_release_build_and_verification_share_one_resolution(self):
        subprocess.run(['git', 'init', '-q'], cwd=self.root, check=True)
        (self.root / 'Cargo.toml').write_text('[package]\nversion = "7.0.0"\n')
        self.run_native(['bash', 'Scripts/prepare-release.sh', 'artifacts', '7.0.0'])
        swift_calls = [json.loads(line) for line in (self.root / 'swift.jsonl').read_text().splitlines()]
        self.assertEqual(swift_calls, [VALUES, VALUES])
        self.assertTrue((self.root / 'BuildSupport/products/release.env').exists())

    def test_offline_test_helper_requires_a_complete_resolved_environment(self):
        result = subprocess.run(['make', 'test-offline'], cwd=self.root, env=dict(self.env, CI='1'), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'swift.jsonl').exists())

    def test_workspace_build_phase_passes_configuration_to_every_platform(self):
        project = ROOT / 'BuildSupport/FFIBuilder.xcodeproj/project.pbxproj'
        match = re.search(r'shellScript = ("(?:\\.|[^"\\])*");', project.read_text())
        self.assertIsNotNone(match)
        script = json.loads(match.group(1))
        (self.root / 'LocalPackages/libzcashlc.xcframework').mkdir(parents=True)
        for platform, target in (('macosx', 'aarch64-apple-darwin'), ('iphonesimulator', 'aarch64-apple-ios-sim'), ('iphoneos', 'aarch64-apple-ios')):
            with self.subTest(platform=platform):
                self.env.update(SRCROOT=str(self.root / 'BuildSupport'), PLATFORM_NAME=platform)
                (self.root / 'cargo.jsonl').unlink(missing_ok=True)
                calls = self.run_native(['bash', '-c', script])
                self.assertEqual(calls[0][0][calls[0][0].index('--target') + 1], target)


if __name__ == '__main__':
    unittest.main()
