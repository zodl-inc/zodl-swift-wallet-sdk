"""Exercise SDK-owned native entrypoints without compiling or downloading Rust."""
import hashlib
import json
import os
import plistlib
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
MAINNET = 'ZODL_OHTTP_RELAY_URL_MAINNET'
TESTNET = 'ZODL_OHTTP_RELAY_URL_TESTNET'
NAMES = tuple('ZODL_OHTTP_' + suffix for suffix in ('GATEWAY_HOST_MAINNET', 'GATEWAY_HOST_TESTNET', 'RELAY_URL_MAINNET', 'RELAY_URL_TESTNET', 'SIGNING_PUBKEY_MAINNET', 'SIGNING_PUBKEY_TESTNET', 'KEYS_DNS_NAME_MAINNET', 'KEYS_DNS_NAME_TESTNET'))
COMPILER_ENVIRONMENT_NAMES = (
    'CARGO', 'RUSTC', 'CARGO_BUILD_RUSTC', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER',
    'CARGO_BUILD_RUSTC_WRAPPER', 'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER',
    'RUSTUP_TOOLCHAIN', 'RUSTUP_AUTO_INSTALL',
)
MAIN_URL = 'https://main.example.invalid/relay'
TEST_URL = 'https://test.example.invalid/relay'
VALUES = dict(zip(NAMES, ('main.example.invalid', 'test.example.invalid', MAIN_URL, TEST_URL, 'a'*64, 'b'*64, 'main.example.invalid', 'test.example.invalid')))


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
with (root/'compiler-environment.jsonl').open('a') as output:
    names = ('CARGO', 'RUSTC', 'CARGO_BUILD_RUSTC', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER',
             'CARGO_BUILD_RUSTC_WRAPPER', 'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER',
             'RUSTUP_TOOLCHAIN', 'RUSTUP_AUTO_INSTALL')
    output.write(json.dumps({name: os.environ[name] for name in names if name in os.environ})+'\\n')
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
        (startup / '.zshenv').write_text('touch "$FIXTURE_ROOT/zsh-called"\n')
        (startup / '.zshrc').write_text('touch "$FIXTURE_ROOT/zsh-called"\n')
        # Real CI compiler selection belongs to the parent build, not this fake repository.
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('ZODL_OHTTP_') and key not in COMPILER_ENVIRONMENT_NAMES
                    and key not in ('CI', 'GITHUB_ACTIONS', 'CARGO_HOME', 'RUSTUP_HOME', 'OHTTP_ENV_RESOLVED')}
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
        result = subprocess.run(command, cwd=cwd or self.root, env=dict(self.env, **VALUES, ZODL_OHTTP_REQUIRE='0'), text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.root / 'cargo.jsonl').read_text().splitlines()]
        self.assertTrue(calls)
        for argv, values in calls:
            self.assertEqual(values, dict(VALUES, ZODL_OHTTP_REQUIRE='1'))
            self.assertNotIn(MAIN_URL, argv)
            self.assertNotIn(TEST_URL, argv)
        self.assertFalse((self.root / 'gh.jsonl').exists(), 'GitHub configuration lookup executed')
        self.assertFalse((self.root / 'zsh-called').exists(), 'zsh startup executed')
        return calls

    def test_malformed_hosts_stop_native_entrypoints_before_cargo(self):
        marker = self.root / 'cargo.jsonl'
        for command in (['bash', 'Scripts/init-local-ffi.sh', '--arm-macos'], ['make', 'ffi-ci']):
            for name in (NAMES[0], NAMES[1], NAMES[6], NAMES[7], MAINNET, TESTNET):
                invalid = ('HTTPS://private-canary.invalid/relay', 'hTtPs://private-canary.invalid/relay',
                           'https://@private-canary.invalid/relay', 'https://:443/relay', 'https://[]/relay') if name in (MAINNET, TESTNET) else (
                               'https://private-canary.invalid/path', '_private-canary.invalid')
                for value in invalid:
                    with self.subTest(command=command, name=name, value=value):
                        marker.unlink(missing_ok=True)
                        environment = dict(self.env, **VALUES, CI='1')
                        environment[name] = value
                        result = subprocess.run(command, cwd=self.root, env=environment, text=True,
                                                capture_output=True, timeout=30)
                        self.assertFalse(marker.exists(), 'Cargo started before malformed host rejection')
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(name, result.stderr)
                        self.assertNotIn(value, result.stdout + result.stderr)

    def test_invalid_configuration_preserves_products_and_prevents_native_or_cache_reuse(self):
        product = self.root / 'BuildSupport/products/macos/keep'
        invalid = []
        for first, second in zip(NAMES[::2], NAMES[1::2]):
            for case_only in (False, True):
                value = VALUES[first]
                duplicate = (value[:8] + value[8:].upper() if 'RELAY_URL' in first else value.upper()) if case_only else value
                invalid.append(dict(VALUES, **{second: duplicate}))
        invalid.append(dict(VALUES, **{NAMES[4]: 'g' * 64}))
        for values in invalid:
            for command in (['make', 'ffi-ci'], ['bash', 'Scripts/init-local-ffi.sh', '--arm-macos']):
                with self.subTest(command=command, values=list(values)):
                    product.parent.mkdir(parents=True, exist_ok=True)
                    product.write_text('existing product')
                    result = subprocess.run(command, cwd=self.root, env=dict(self.env, **values),
                                            capture_output=True, text=True, timeout=30)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(product.read_text(), 'existing product')
                    self.assertFalse((self.root / 'cargo.jsonl').exists())
                    self.assertNotIn(MAIN_URL, result.stdout + result.stderr)

    def test_ci_compiler_overrides_cannot_escape_fixture_tools(self):
        marker = self.root / 'escaped-compiler'
        sentinel = self.root / 'ci-compiler'
        sentinel.write_text(
            '#!/usr/bin/env python3\n'
            'from pathlib import Path\n'
            f'Path({str(marker)!r}).write_text("unexpected compiler invocation")\n'
            'raise SystemExit(97)\n'
        )
        sentinel.chmod(0o755)
        overrides = {
            'CARGO': str(sentinel), 'RUSTC': str(sentinel), 'CARGO_BUILD_RUSTC': str(sentinel),
            'RUSTC_WRAPPER': str(sentinel), 'RUSTC_WORKSPACE_WRAPPER': str(sentinel),
            'CARGO_BUILD_RUSTC_WRAPPER': str(sentinel), 'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER': str(sentinel),
            'RUSTUP_TOOLCHAIN': 'ci-selected-toolchain', 'RUSTUP_AUTO_INSTALL': '0',
        }
        with mock.patch.dict(os.environ, dict(overrides, CI='1', GITHUB_ACTIONS='true', OHTTP_ENV_RESOLVED='1')):
            fixture = NativeRelayEnvironmentTests(methodName='test_root_native_cargo_commands_receive_local_exports')
            fixture.setUp()
            self.addCleanup(fixture.doCleanups)
            fixture.run_native(['make', 'build-rust'])
            self.assertEqual(
                [json.loads(line) for line in (fixture.root / 'compiler-environment.jsonl').read_text().splitlines()],
                [{}],
            )
            self.assertFalse(marker.exists(), 'Inherited compiler selection bypassed the fixture tool boundary')
            for name, value in overrides.items():
                self.assertEqual(os.environ[name], value, name)

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

    def test_release_product_stays_shallow_and_archives_like_release(self):
        self.run_native(['make', 'ffi-all'])
        (self.root / 'Cargo.toml').write_text('[package]\nname = "libzcashlc"\nversion = "5.0.0"\n')
        (self.root / 'Cargo.lock').write_text('version = 3\n\n[[package]]\nname = "libzcashlc"\nversion = "5.0.0"\n')
        shims = self.root / 'record-shims'
        shims.mkdir()
        lipo = shims / 'lipo'
        lipo.write_text('''#!/usr/bin/env python3
import sys
print('arm64' if '/ios-arm64/' in sys.argv[-1] else 'arm64 x86_64')
''')
        lipo.chmod(0o755)
        sys.path.insert(0, str(ROOT / 'Scripts/ci'))
        self.addCleanup(sys.path.remove, str(ROOT / 'Scripts/ci'))
        import sdk_build_record
        products = self.root / 'BuildSupport/products'
        product = products / 'libzcashlc.xcframework'
        with mock.patch.dict(os.environ, {'PATH': str(shims) + os.pathsep + os.environ['PATH']}):
            slices = sdk_build_record.verify_slices(product, sdk_build_record.component_versions(self.root), self.root)
        self.assertEqual(len(slices), 3)
        subprocess.run(['zip', '-qr', 'libzcashlc.xcframework.zip', 'libzcashlc.xcframework'], cwd=products, check=True)
        expected = {str(path.relative_to(products)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in product.rglob('*') if path.is_file()}
        with zipfile.ZipFile(products / 'libzcashlc.xcframework.zip') as bundle:
            archived = {item.filename: hashlib.sha256(bundle.read(item)).hexdigest()
                        for item in bundle.infolist() if not item.is_dir()}
        self.assertEqual(archived, expected)

    def assert_local_copy_versioned_and_product_shallow(self):
        product = self.root / 'BuildSupport/products/libzcashlc.xcframework'
        self.assertEqual([path for path in product.rglob('*') if path.is_symlink()], [])
        shallow = product / 'macos-arm64_x86_64/libzcashlc.framework'
        self.assertTrue((shallow / 'Info.plist').is_file())
        self.assertFalse((shallow / 'Versions').exists())
        local = self.root / 'LocalPackages/libzcashlc.xcframework'
        macos = local / 'macos-arm64_x86_64/libzcashlc.framework'
        self.assertTrue((macos / 'Versions/A/Resources/Info.plist').is_file())
        self.assertFalse((macos / 'Versions/A/Versions').exists())
        self.assertEqual(os.readlink(macos / 'Versions/Current'), 'A')
        for name in ('libzcashlc', 'Headers', 'Modules', 'Resources'):
            self.assertEqual(os.readlink(macos / name), f'Versions/Current/{name}')
        self.assertFalse((macos / 'Info.plist').exists())
        metadata = plistlib.loads((macos / 'Resources/Info.plist').read_bytes())
        self.assertEqual(metadata['CFBundlePackageType'], 'FMWK')
        self.assertEqual(metadata['CFBundleSupportedPlatforms'], ['MacOSX'])
        minimum = re.search(r'^MACOSX_DEPLOYMENT_TARGET = (.+)$',
                            (self.root / 'BuildSupport/Makefile').read_text(), re.MULTILINE).group(1)
        self.assertEqual(metadata['LSMinimumSystemVersion'], minimum)
        version = plistlib.loads((self.root / 'BuildSupport/platform-Info.plist').read_bytes())['CFBundleVersion']
        self.assertEqual(metadata['CFBundleVersion'], version)
        for identifier in ('ios-arm64', 'ios-arm64_x86_64-simulator'):
            ios = local / identifier / 'libzcashlc.framework'
            original = product / identifier / 'libzcashlc.framework'
            self.assertEqual({path.name for path in ios.iterdir()},
                             {'libzcashlc', 'Headers', 'Modules', 'Info.plist'})
            for relative in ('libzcashlc', 'Headers/zcashlc.h', 'Modules/module.modulemap', 'Info.plist'):
                self.assertEqual((ios / relative).read_bytes(), (original / relative).read_bytes())

    def configure_local_ffi(self):
        result = subprocess.run(['make', 'configure-local-ffi'], cwd=self.root, env=dict(self.env, **VALUES),
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_configure_local_ffi_versions_only_the_local_macos_copy(self):
        self.run_native(['make', 'ffi-all'])
        for _ in range(2):
            self.configure_local_ffi()
            self.assert_local_copy_versioned_and_product_shallow()

    def test_configure_local_ffi_without_macos_slice(self):
        self.run_native(['make', 'ffi-all'])
        shutil.rmtree(self.root / 'BuildSupport/products/libzcashlc.xcframework/macos-arm64_x86_64')
        self.configure_local_ffi()
        self.assertFalse((self.root / 'LocalPackages/libzcashlc.xcframework/macos-arm64_x86_64').exists())

    def test_missing_configuration_is_rejected_before_cleanup_even_with_recursion_marker(self):
        product = self.root / 'BuildSupport/products/macos/keep'
        commands = (['make', 'ffi-ci'], ['make', '-C', 'BuildSupport', 'release'],
                    ['bash', 'Scripts/init-local-ffi.sh', '--arm-macos'])
        for command in commands:
            for context in ({}, {'CI': '1'}, {'GITHUB_ACTIONS': 'true'}, {'OHTTP_ENV_RESOLVED': '1'}):
                for name in NAMES:
                    with self.subTest(command=command, context=context, name=name):
                        for filename in ('cargo.jsonl', 'gh.jsonl', 'zsh-called'):
                            (self.root / filename).unlink(missing_ok=True)
                        (self.root / 'values.json').write_text(json.dumps(VALUES))
                        product.parent.mkdir(parents=True, exist_ok=True)
                        product.write_text('keep')
                        release_record = product.parent.parent / 'release.env'
                        release_record.write_text('keep')
                        environment = dict(self.env, **VALUES, **context)
                        del environment[name]
                        result = subprocess.run(command, cwd=self.root, env=environment, capture_output=True, timeout=30)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertTrue(product.exists(), 'existing native product removed before validation')
                        self.assertEqual(release_record.read_text(), 'keep')
                        self.assertFalse((self.root / 'cargo.jsonl').exists())
                        self.assertFalse((self.root / 'gh.jsonl').exists())
                        self.assertFalse((self.root / 'zsh-called').exists())

    def test_release_recursion_marker_cannot_bypass_validation_before_cleanup(self):
        (self.root / 'Cargo.toml').write_text('[package]\nversion = "7.0.0"\n')
        subprocess.run(['git', 'init', '-q'], cwd=self.root, check=True)
        product = self.root / 'BuildSupport/products/macos/keep'
        for name in NAMES:
            with self.subTest(name=name):
                product.parent.mkdir(parents=True, exist_ok=True)
                product.write_text('keep')
                environment = dict(self.env, **VALUES, OHTTP_ENV_RESOLVED='1')
                del environment[name]
                result = subprocess.run(['bash', 'Scripts/prepare-release.sh', 'artifacts', '7.0.0'],
                                        cwd=self.root, env=environment, capture_output=True, timeout=30)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(product.exists(), 'release cleanup preceded configuration validation')
                self.assertFalse((self.root / 'cargo.jsonl').exists())

    def test_cached_initializer_needs_no_configuration(self):
        archive = self.root / 'fixture.zip'
        with zipfile.ZipFile(archive, 'w') as bundle:
            bundle.writestr('libzcashlc.xcframework/Info.plist', 'cached binary')
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.root / 'Package.swift').write_text(
            'https://github.com/example/sdk/releases/download/1/libzcashlc.xcframework.zip\n'
            f'checksum: "{checksum}"\n')
        gh = self.root / 'bin/gh'
        gh.write_text(
            '#!/usr/bin/env python3\nimport os, pathlib, shutil, sys\n'
            'assert sys.argv[1:4] == ["release", "download", "1"]\n'
            'root=pathlib.Path(os.environ["FIXTURE_ROOT"])\n'
            'shutil.copyfile(root/"fixture.zip", root/"LocalPackages/libzcashlc.xcframework.zip")\n')
        result = subprocess.run(['bash', 'Scripts/init-local-ffi.sh', '--cached'], cwd=self.root,
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'LocalPackages/libzcashlc.xcframework/Info.plist').read_text(), 'cached binary')
        self.assertTrue((self.root / 'LocalPackages/Package.swift').exists())
        self.assertFalse((self.root / 'cargo.jsonl').exists())
        self.assertFalse((self.root / 'gh.jsonl').exists())
        self.assertFalse((self.root / 'zsh-called').exists())

    def test_source_aggregate_builds_and_checks_share_one_environment(self):
        for target in ('build-all', 'build-all-release', 'check-all', 'check'):
            with self.subTest(target=target):
                (self.root / 'cargo.jsonl').unlink(missing_ok=True)
                (self.root / 'swift.jsonl').unlink(missing_ok=True)
                (self.root / 'suite.jsonl').unlink(missing_ok=True)
                self.run_native(['make', target])
                swift_calls = [json.loads(line) for line in (self.root / 'swift.jsonl').read_text().splitlines()]
                self.assertTrue(swift_calls)
                self.assertTrue(all(values == dict(VALUES, ZODL_OHTTP_REQUIRE='1') for values in swift_calls))
                if target in ('check-all', 'check'):
                    self.assertEqual([json.loads(line) for line in (self.root / 'suite.jsonl').read_text().splitlines()], [dict(VALUES, ZODL_OHTTP_REQUIRE='1')])

    def test_relative_script_paths_work_from_another_directory(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.root / 'LocalPackages/libzcashlc.xcframework').mkdir(parents=True)
        for command in (['bash', '../Scripts/init-local-ffi.sh', '--arm-macos'],
                        ['bash', '../Scripts/rebuild-local-ffi.sh', 'macos']):
            (self.root / 'cargo.jsonl').unlink(missing_ok=True)
            self.run_native(command, cwd=outside)

    def test_source_make_dry_runs_never_resolve_or_fetch(self):
        for command in (['make', '-n', 'ffi-ci'], ['make', '-n', '-C', 'BuildSupport', 'xcframework'],
                        ['make', '-n', '-C', 'BuildSupport', 'release']):
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
        self.assertEqual(swift_calls, [dict(VALUES, ZODL_OHTTP_REQUIRE='1')] * 2)
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
