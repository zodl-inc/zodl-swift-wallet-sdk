"""Run the local FFI scripts against disposable source and external-tool fixtures."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SLICES = {'ios-arm64': ('ios', None), 'ios-arm64-simulator': ('ios', 'simulator'), 'macos-arm64': ('macos', None)}
TRIPLES = {'ios-sim': 'aarch64-apple-ios-sim', 'ios-device': 'aarch64-apple-ios', 'macos': 'aarch64-apple-darwin'}


def bundle(root, identifiers=SLICES, arch='arm64'):
    libraries = []
    for identifier in identifiers:
        platform, variant = SLICES[identifier]
        framework = root / identifier / 'libzcashlc.framework'
        (framework / 'Headers').mkdir(parents=True)
        (framework / 'Modules').mkdir()
        (framework / 'Headers/zcashlc.h').write_text('void fixture(void);')
        (framework / 'Modules/module.modulemap').write_text('module libzcashlc {}')
        (framework / 'libzcashlc').write_text(arch)
        (framework / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'libzcashlc'}))
        item = dict(LibraryIdentifier=identifier, LibraryPath='libzcashlc.framework', SupportedArchitectures=['arm64'], SupportedPlatform=platform)
        if variant:
            item['SupportedPlatformVariant'] = variant
        libraries.append(item)
    (root / 'Info.plist').write_bytes(plistlib.dumps(dict(AvailableLibraries=libraries, CFBundlePackageType='XFWK', XCFrameworkFormatVersion='1.0')))


class LocalFFITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'sdk'
        shutil.copytree(ROOT / 'Scripts', self.repo / 'Scripts', ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copytree(ROOT / 'BuildSupport', self.repo / 'BuildSupport', ignore=shutil.ignore_patterns('products'))
        self.tools = self.base / 'tools'
        self.tools.mkdir()
        self.home = self.base / 'home'
        self.home.mkdir()
        self.log = self.base / 'calls'
        # The native entry points take no OHTTP inputs: run them without any.
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('ZODL_OHTTP_')}
        self.env.update(HOME=str(self.home), PATH=str(self.tools) + os.pathsep + os.environ['PATH'], CALLS=str(self.log))
        self.env.pop('CARGO_TARGET_DIR', None)
        self.tool('python3', '#!/bin/sh\nexec ' + sys.executable + ' "$@"\n')
        self.tool('uname', '#!/bin/sh\necho x86_64\n')
        self.tool('lipo', '#!/bin/sh\n[ "$1" = -archs ] || exit 8\ncat "$2"\n')
        self.tool('rustup', '#!/bin/sh\necho "rustup $*" >> "$CALLS"\nif [ "$2" = list ]; then printf "%s\\n" aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; fi\n')
        self.tool('cargo', '''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as log: log.write('cargo ' + ' '.join(args) + '\\n')
if os.environ.get('FAIL_BUILD'): sys.exit(7)
triple = args[args.index('--target') + 1]
p = pathlib.Path('target') / triple / 'release/libzcashlc.a'
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(os.environ.get('BUILD_ARCH', 'arm64'))
h = pathlib.Path('target/Headers/zcashlc.h')
h.parent.mkdir(exist_ok=True)
h.write_text('void rebuilt(void);')
''')
        self.tool('make', '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
assert sys.argv[1] == 'xcframework'
assert sys.argv[2].startswith('FFI_CARGO_FEATURES=')
with open(os.environ['CALLS'], 'a') as log: log.write('make ' + ' '.join(sys.argv[1:]) + '\\n')
shutil.copytree(os.environ['MAKE_PRODUCT'], pathlib.Path('products/libzcashlc.xcframework'))
''')
        self.tool('gh', '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
with open(os.environ['CALLS'], 'a') as log: log.write('gh ' + ' '.join(sys.argv[1:]) + '\\n')
dest = pathlib.Path(sys.argv[sys.argv.index('--dir') + 1])
shutil.copyfile(os.environ['ARCHIVE'], dest / 'libzcashlc.xcframework.zip')
''')
        product = self.base / 'make-product'
        bundle(product)
        self.env['MAKE_PRODUCT'] = str(product)
        self.install = self.repo / 'LocalPackages/libzcashlc.xcframework'
        self.wrapper = self.repo / 'LocalPackages/Package.swift'

    def tool(self, name, body):
        path = self.tools / name
        path.write_text(body)
        path.chmod(0o755)

    def run_script(self, script, *args):
        return subprocess.run(['bash', str(self.repo / 'Scripts' / script), *args], env=self.env, text=True, capture_output=True)

    def require_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def seed(self):
        bundle(self.install)
        self.wrapper.write_text('previous wrapper')

    def snapshot(self):
        return {str(p.relative_to(self.repo / 'LocalPackages')): (os.readlink(p) if p.is_symlink() else p.read_bytes()) for p in (self.repo / 'LocalPackages').rglob('*') if p.is_symlink() or p.is_file()}

    def assert_preserved_failure(self, result, before):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)

    def archive(self, mutate=None, extra=None):
        product = self.base / 'archive-source/libzcashlc.xcframework'
        bundle(product)
        if mutate:
            mutate(product)
        archive = self.base / 'asset.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            for p in product.rglob('*'):
                if p.is_file():
                    output.write(p, str(p.relative_to(product.parent)))
            if extra:
                info, content = extra
                output.writestr(info, content)
        self.env['ARCHIVE'] = str(archive)
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.repo / 'Package.swift').write_text('url: "https://github.com/example/sdk/releases/download/2.0.0/libzcashlc.xcframework.zip",\nchecksum: "' + checksum + '"\n')
        return archive

    def test_init_default_and_each_arm_selector_install_exact_canonical_subset(self):
        cases = [((), set(SLICES)), (('--arm-all',), set(SLICES)), (('--arm-macos',), {'macos-arm64'}), (('--arm-ios',), {'ios-arm64', 'ios-arm64-simulator'}), (('--arm-simulator',), {'ios-arm64-simulator'})]
        for args, expected in cases:
            with self.subTest(args=args):
                shutil.rmtree(self.repo / 'LocalPackages', ignore_errors=True)
                self.seed()
                (self.install / 'macos-arm64').rename(self.install / 'macos-arm64_x86_64')
                self.log.unlink(missing_ok=True)
                self.require_ok(self.run_script('init-local-ffi.sh', *args))
                self.assertEqual({p.name for p in self.install.iterdir()}, expected | {'Info.plist'})
                self.assertEqual(self.wrapper.read_bytes(), (self.repo / 'BuildSupport/LocalPackages-Package.swift').read_bytes())
                expected_triples = {'ios-arm64': 'aarch64-apple-ios', 'ios-arm64-simulator': 'aarch64-apple-ios-sim', 'macos-arm64': 'aarch64-apple-darwin'}
                if args:
                    cargo_calls = {line for line in self.log.read_text().splitlines() if line.startswith('cargo ')}
                    self.assertEqual(cargo_calls, {'cargo build --locked --target ' + expected_triples[identifier] + ' --release' for identifier in expected})
                self.require_ok(subprocess.run([sys.executable, str(self.repo / 'Scripts/lib/ffi_layout.py'), 'validate', str(self.install), '--allow-versioned-macos'], env=self.env, text=True, capture_output=True))
                if 'macos-arm64' in expected:
                    self.assertTrue((self.install / 'macos-arm64/libzcashlc.framework/Versions/Current').is_symlink())

    def test_rebuild_each_platform_always_requests_arm_preserves_others_and_gpu(self):
        for target, triple in TRIPLES.items():
            with self.subTest(target=target):
                shutil.rmtree(self.repo / 'LocalPackages', ignore_errors=True)
                self.seed()
                before = self.snapshot()
                self.log.unlink(missing_ok=True)
                self.require_ok(self.run_script('rebuild-local-ffi.sh', target, '--gpu'))
                calls = self.log.read_text()
                self.assertIn('cargo build --locked --target ' + triple + ' --release --features gpu', calls)
                self.assertNotIn('x86_64', calls)
                rebuilt = {'ios-sim': 'ios-arm64-simulator', 'ios-device': 'ios-arm64', 'macos': 'macos-arm64'}[target]
                after = self.snapshot()
                for path, contents in before.items():
                    if not path.startswith('libzcashlc.xcframework/' + rebuilt + '/'):
                        self.assertEqual(after[path], contents)
                self.assertEqual(set(p.name for p in self.install.iterdir()), set(SLICES) | {'Info.plist'})

    def test_trace_feature_survives_full_subset_and_gpu_rebuilds(self):
        for args in (('--trace',), ('--arm-macos', '--trace')):
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                self.require_ok(self.run_script('init-local-ffi.sh', *args))
                calls = self.log.read_text()
                if len(args) == 1:
                    self.assertIn('make xcframework FFI_CARGO_FEATURES=ohttp-trace', calls)
                else:
                    self.assertIn('cargo build --locked --target aarch64-apple-darwin --release --features ohttp-trace', calls)
        self.log.unlink()
        self.require_ok(self.run_script('rebuild-local-ffi.sh', 'macos', '--gpu', '--trace'))
        self.assertIn('--features gpu,ohttp-trace', self.log.read_text())

    def test_universal_rejected_before_external_build_or_download(self):
        self.seed()
        before = self.snapshot()
        for script in ('init-local-ffi.sh', 'rebuild-local-ffi.sh'):
            self.assert_preserved_failure(self.run_script(script, '--universal'), before)
        self.assertFalse(self.log.exists())

    def test_rebuild_rejects_old_unknown_and_intel_installations_before_build(self):
        for kind in ('old', 'unknown', 'intel'):
            with self.subTest(kind=kind):
                shutil.rmtree(self.repo / 'LocalPackages', ignore_errors=True)
                self.seed()
                if kind == 'old':
                    (self.install / 'macos-arm64').rename(self.install / 'macos-arm64_x86_64')
                elif kind == 'unknown':
                    (self.install / 'unknown').mkdir()
                else:
                    (self.install / 'ios-arm64/libzcashlc.framework/libzcashlc').write_text('x86_64')
                before = self.snapshot()
                result = self.run_script('rebuild-local-ffi.sh', 'macos')
                self.assert_preserved_failure(result, before)
                self.assertIn('init-local-ffi.sh', result.stdout + result.stderr)
                self.assertFalse(self.log.exists())

    def test_failed_and_fat_source_builds_preserve_previous_installation(self):
        self.seed()
        before = self.snapshot()
        for variable, value in [('FAIL_BUILD', '1'), ('BUILD_ARCH', 'arm64 x86_64')]:
            self.env[variable] = value
            for script, args in [('init-local-ffi.sh', ('--arm-all',)), ('rebuild-local-ffi.sh', ('macos',))]:
                self.assert_preserved_failure(self.run_script(script, *args), before)
            del self.env[variable]

    def test_invalid_full_make_product_preserves_installation(self):
        self.seed()
        (Path(self.env['MAKE_PRODUCT']) / 'ios-arm64/libzcashlc.framework/libzcashlc').write_text('arm64 x86_64')
        self.assert_preserved_failure(self.run_script('init-local-ffi.sh'), self.snapshot())

    def test_rebuild_adds_missing_platform_without_removing_existing_slice(self):
        self.require_ok(self.run_script('init-local-ffi.sh', '--arm-simulator'))
        original = (self.install / 'ios-arm64-simulator/libzcashlc.framework/libzcashlc').read_bytes()
        self.require_ok(self.run_script('rebuild-local-ffi.sh', 'macos'))
        self.assertEqual(set(p.name for p in self.install.iterdir()), {'ios-arm64-simulator', 'macos-arm64', 'Info.plist'})
        self.assertEqual((self.install / 'ios-arm64-simulator/libzcashlc.framework/libzcashlc').read_bytes(), original)

    def test_failed_wrapper_install_rolls_back_framework_and_wrapper(self):
        self.seed()
        before = self.snapshot()
        self.tool('mv', '''#!/bin/sh
case "$1" in
    LocalPackages/.ffi-stage.*/Package.swift) exit 9 ;;
esac
exec /bin/mv "$@"
''')
        self.assert_preserved_failure(self.run_script('init-local-ffi.sh', '--arm-all'), before)

    def test_cached_canonical_full_product_installs_and_versions_macos(self):
        self.seed()
        self.archive()
        self.require_ok(self.run_script('init-local-ffi.sh', '--cached'))
        self.assertEqual(set(p.name for p in self.install.iterdir()), set(SLICES) | {'Info.plist'})
        self.assertTrue((self.install / 'macos-arm64/libzcashlc.framework/Versions/A/Resources/Info.plist').is_file())

    def test_cached_checksum_mismatch_preserves_installation(self):
        self.seed()
        archive = self.archive()
        with archive.open('ab') as output:
            output.write(b'changed')
        self.assert_preserved_failure(self.run_script('init-local-ffi.sh', '--cached'), self.snapshot())

    def test_cached_intel_mislabeled_and_missing_payload_preserve_installation(self):
        self.seed()
        mutations = [lambda p: (p / 'ios-arm64/libzcashlc.framework/libzcashlc').write_text('x86_64'), lambda p: (p / 'macos-arm64').rename(p / 'macos-arm64_x86_64'), lambda p: (p / 'ios-arm64/libzcashlc.framework/Headers/zcashlc.h').unlink()]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                shutil.rmtree(self.base / 'archive-source', ignore_errors=True)
                self.archive(mutate)
                self.assert_preserved_failure(self.run_script('init-local-ffi.sh', '--cached'), self.snapshot())

    def test_cached_unsafe_paths_links_and_corrupt_archive_do_not_escape_staging(self):
        self.seed()
        outside = self.base / 'escaped'
        link = zipfile.ZipInfo('libzcashlc.xcframework/escape')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        for extra in [('../../escaped', 'escape'), (str(outside), 'escape'), (link, str(outside)), ('libzcashlc.xcframework/../escape', 'escape')]:
            with self.subTest(extra=extra):
                shutil.rmtree(self.base / 'archive-source', ignore_errors=True)
                self.archive(extra=extra)
                self.assert_preserved_failure(self.run_script('init-local-ffi.sh', '--cached'), self.snapshot())
                self.assertFalse(outside.exists())
        shutil.rmtree(self.base / 'archive-source')
        archive = self.archive()
        archive.write_bytes(b'not a zip')
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        manifest = self.repo / 'Package.swift'
        manifest.write_text(manifest.read_text().split('checksum:')[0] + 'checksum: "' + checksum + '"\n')
        self.assert_preserved_failure(self.run_script('init-local-ffi.sh', '--cached'), self.snapshot())


if __name__ == '__main__':
    unittest.main()
