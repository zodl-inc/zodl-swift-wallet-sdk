"""Exercise SDK-owned native entrypoints without compiling or downloading Rust."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MAINNET = 'ZODL_OHTTP_RELAY_URL_MAINNET'
TESTNET = 'ZODL_OHTTP_RELAY_URL_TESTNET'
MAIN_URL = 'https://main.example.invalid/relay'
TEST_URL = 'https://test.example.invalid/relay'


class NativeRelayEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for path in ('Makefile', 'Scripts/init-local-ffi.sh', 'Scripts/rebuild-local-ffi.sh', 'Scripts/version-macos-framework.sh',
                     'BuildSupport/Makefile', 'BuildSupport/module.modulemap', 'BuildSupport/platform-Info.plist',
                     'BuildSupport/LocalPackages-Package.swift'):
            dest = self.root / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, dest)
        if (ROOT / 'Scripts/lib/ohttp_env.py').exists():
            (self.root / 'Scripts/lib').mkdir()
            shutil.copy2(ROOT / 'Scripts/lib/ohttp_env.py', self.root / 'Scripts/lib/ohttp_env.py')
        tools = self.root / 'bin'
        tools.mkdir()
        cargo = tools / 'cargo'
        cargo.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
with open(os.environ['CAPTURE'], 'a') as output:
    output.write(json.dumps([sys.argv[1:], {key: os.environ.get(key) for key in ('ZODL_OHTTP_RELAY_URL_MAINNET','ZODL_OHTTP_RELAY_URL_TESTNET')}])+'\\n')
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
        (startup / '.zshenv').write_text(f'export {MAINNET}="{MAIN_URL}"\nexport {TESTNET}="{TEST_URL}"\n')
        self.env = {key: value for key, value in os.environ.items()
                    if key not in (MAINNET, TESTNET, 'CI', 'GITHUB_ACTIONS', 'CARGO_HOME', 'RUSTUP_HOME')}
        self.env.update(PATH=str(tools) + os.pathsep + self.env['PATH'], ZDOTDIR=str(startup),
                        CAPTURE=str(self.root / 'cargo.jsonl'), FIXTURE_ROOT=str(self.root))

    def run_native(self, command):
        result = subprocess.run(command, cwd=self.root, env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.root / 'cargo.jsonl').read_text().splitlines()]
        self.assertTrue(calls)
        for argv, values in calls:
            self.assertEqual(values, {MAINNET: MAIN_URL, TESTNET: TEST_URL})
            self.assertNotIn(MAIN_URL, argv)
            self.assertNotIn(TEST_URL, argv)
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


if __name__ == '__main__':
    unittest.main()
