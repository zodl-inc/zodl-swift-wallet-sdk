"""Exercise the layout CLI and real Make packaging with external tool doubles."""
import itertools
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'Scripts/lib/ffi_layout.py'
SLICES = {'ios-arm64': ('ios', None), 'ios-arm64-simulator': ('ios', 'simulator'), 'macos-arm64': ('macos', None)}


class LayoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.product = self.base / 'libzcashlc.xcframework'
        self.product.mkdir()
        self.tools = self.base / 'tools'
        self.tools.mkdir()
        lipo = self.tools / 'lipo'
        lipo.write_text('#!/bin/sh\n[ "$1" = -archs ] || exit 7\ncat "$2"\n')
        lipo.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ['PATH'])

    def cli(self, *args):
        return subprocess.run([sys.executable, str(HELPER), *map(str, args)], env=self.env, text=True, capture_output=True)

    def fixture(self, identifiers=None):
        libraries = []
        for identifier in identifiers or SLICES:
            platform, variant = SLICES[identifier]
            framework = self.product / identifier / 'libzcashlc.framework'
            (framework / 'Headers').mkdir(parents=True)
            (framework / 'Modules').mkdir()
            (framework / 'libzcashlc').write_text('arm64')
            (framework / 'Headers/zcashlc.h').write_text('void fixture(void);')
            (framework / 'Modules/module.modulemap').write_text('module libzcashlc { header "zcashlc.h" }')
            (framework / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'libzcashlc'}))
            item = dict(LibraryIdentifier=identifier, LibraryPath='libzcashlc.framework', SupportedArchitectures=['arm64'], SupportedPlatform=platform)
            if variant:
                item['SupportedPlatformVariant'] = variant
            libraries.append(item)
        self.info = dict(AvailableLibraries=libraries, CFBundlePackageType='XFWK', XCFrameworkFormatVersion='1.0')
        self.save()

    def save(self):
        (self.product / 'Info.plist').write_bytes(plistlib.dumps(self.info))

    def test_accepts_each_nonempty_canonical_subset_and_full_contract(self):
        for count in (1, 2, 3):
            for identifiers in itertools.combinations(SLICES, count):
                with self.subTest(identifiers=identifiers):
                    shutil.rmtree(self.product)
                    self.product.mkdir()
                    self.fixture(identifiers)
                    result = self.cli('validate', self.product)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    full = self.cli('validate', self.product, '--require-full')
                    self.assertEqual(full.returncode == 0, count == 3, full.stderr)

    def test_manifest_declares_exactly_requested_slices(self):
        for identifiers in [('macos-arm64',), tuple(SLICES)]:
            result = self.cli('manifest', self.product / 'Info.plist', *identifiers)
            self.assertEqual(result.returncode, 0, result.stderr)
            info = plistlib.loads((self.product / 'Info.plist').read_bytes())
            self.assertEqual([i['LibraryIdentifier'] for i in info['AvailableLibraries']], list(identifiers))
            self.assertTrue(all(i['SupportedArchitectures'] == ['arm64'] for i in info['AvailableLibraries']))

    def test_manifest_refuses_empty_duplicate_and_unknown_identifiers(self):
        path = self.product / 'Info.plist'
        path.write_bytes(b'preserve')
        for ids in [(), ('macos-arm64', 'macos-arm64'), ('macos-arm64_x86_64',)]:
            self.assertNotEqual(self.cli('manifest', path, *ids).returncode, 0)
            self.assertEqual(path.read_bytes(), b'preserve')

    def test_metadata_mismatch_duplicate_and_malformed_declarations_fail(self):
        self.fixture()
        original = plistlib.dumps(self.info)
        mutations = [lambda: self.info['AvailableLibraries'][0].update(SupportedPlatform='macos'),
                     lambda: self.info['AvailableLibraries'][0].update(SupportedPlatformVariant='simulator'),
                     lambda: self.info['AvailableLibraries'][0].update(SupportedArchitectures=['arm64', 'arm64']),
                     lambda: self.info['AvailableLibraries'][0].update(LibraryPath='../libzcashlc.framework'),
                     lambda: self.info['AvailableLibraries'].append(self.info['AvailableLibraries'][0]),
                     lambda: self.info.update(AvailableLibraries=[]),
                     lambda: self.info.update(AvailableLibraries=['invalid'])]
        for mutation in mutations:
            self.info = plistlib.loads(original)
            mutation()
            self.save()
            self.assertNotEqual(self.cli('validate', self.product).returncode, 0)
        (self.product / 'Info.plist').write_bytes(b'malformed')
        self.assertNotEqual(self.cli('validate', self.product).returncode, 0)

    def test_actual_fat_intel_and_duplicate_architectures_fail(self):
        self.fixture()
        binary = self.product / 'macos-arm64/libzcashlc.framework/libzcashlc'
        for archs in ('arm64 x86_64', 'x86_64', 'arm64 arm64', ''):
            binary.write_text(archs)
            self.assertNotEqual(self.cli('validate', self.product).returncode, 0)

    def test_undeclared_old_named_slice_even_hidden_is_rejected(self):
        self.fixture()
        for name in ('macos-arm64_x86_64', '.ios-arm64_x86_64-simulator'):
            extra = self.product / name
            extra.mkdir()
            self.assertNotEqual(self.cli('validate', self.product).returncode, 0)
            extra.rmdir()

    def test_missing_required_files_fail(self):
        self.fixture()
        framework = self.product / 'ios-arm64/libzcashlc.framework'
        for relative in ('libzcashlc', 'Headers/zcashlc.h', 'Modules/module.modulemap', 'Info.plist'):
            path = framework / relative
            content = path.read_bytes()
            path.unlink()
            self.assertNotEqual(self.cli('validate', self.product).returncode, 0)
            path.write_bytes(content)

    def version_macos(self):
        framework = self.product / 'macos-arm64/libzcashlc.framework'
        version = framework / 'Versions/A'
        version.mkdir(parents=True)
        for name in ('libzcashlc', 'Headers', 'Modules'):
            (framework / name).rename(version / name)
            (framework / name).symlink_to('Versions/Current/' + name)
        (version / 'Resources').mkdir()
        (framework / 'Info.plist').rename(version / 'Resources/Info.plist')
        (framework / 'Resources').symlink_to('Versions/Current/Resources')
        (framework / 'Versions/Current').symlink_to('A')
        return framework

    def test_versioned_macos_requires_opt_in_and_stays_local(self):
        self.fixture(('macos-arm64',))
        framework = self.version_macos()
        self.assertNotEqual(self.cli('validate', self.product).returncode, 0)
        result = self.cli('validate', self.product, '--allow-versioned-macos')
        self.assertEqual(result.returncode, 0, result.stderr)
        for target in ('../../../../outside', str(framework / 'Versions/A/Headers'), 'Versions/Current/libzcashlc'):
            path = framework / 'Headers'
            path.unlink()
            path.symlink_to(target)
            self.assertNotEqual(self.cli('validate', self.product, '--allow-versioned-macos').returncode, 0)

    def test_ios_links_and_symlinked_slice_are_rejected_with_opt_in(self):
        self.fixture()
        path = self.product / 'ios-arm64/libzcashlc.framework/Headers/zcashlc.h'
        outside = self.base / 'header'
        path.rename(outside)
        path.symlink_to(outside)
        self.assertNotEqual(self.cli('validate', self.product, '--allow-versioned-macos').returncode, 0)


class MakePackagingTests(unittest.TestCase):
    setUp = LayoutTests.setUp
    def test_real_packaging_excludes_stale_intel_inputs_and_replaces_old_product(self):
        source = self.base / 'source'
        support = source / 'BuildSupport'
        shutil.copytree(ROOT / 'BuildSupport', support, ignore=shutil.ignore_patterns('products'))
        (source / 'Scripts/lib').mkdir(parents=True)
        if HELPER.exists():
            shutil.copy(HELPER, source / 'Scripts/lib/ffi_layout.py')
        (source / 'Cargo.toml').write_text('fixture')
        (source / 'rust').mkdir()
        (source / 'target/Headers').mkdir(parents=True)
        (source / 'target/Headers/zcashlc.h').write_text('void fixture(void);')
        for platform, arch in [('macos', 'aarch64-apple-darwin'), ('ios-device', 'aarch64-apple-ios'), ('ios-simulator', 'aarch64-apple-ios-sim'), ('macos', 'x86_64-apple-darwin'), ('ios-simulator', 'x86_64-apple-ios')]:
            archive = source / 'target' / arch / 'release/libzcashlc.a'
            archive.parent.mkdir(parents=True)
            archive.write_text('x86_64' if arch.startswith('x86_64') else 'arm64')
            stale = support / 'products' / platform / 'static-libraries/x86_64-old/libzcashlc.a'
            stale.parent.mkdir(parents=True, exist_ok=True)
            stale.write_text('x86_64')
        old = support / 'products/libzcashlc.xcframework/macos-arm64_x86_64'
        old.mkdir(parents=True)
        (self.tools / 'cargo').write_text('#!/bin/sh\nexit 0\n')
        (self.tools / 'cargo').chmod(0o755)
        (self.tools / 'lipo').write_text('''#!/usr/bin/env python3
import pathlib, sys
args = sys.argv[1:]
if args[0] == '-archs':
    print(pathlib.Path(args[1]).read_text())
else:
    assert args[0] == '-create'
    output = args.index('-output')
    pathlib.Path(args[output + 1]).write_text(' '.join(pathlib.Path(p).read_text() for p in args[1:output]))
''')
        result = subprocess.run(['make', '-C', str(support), 'xcframework'], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        product = support / 'products/libzcashlc.xcframework'
        self.assertEqual(set(p.name for p in product.iterdir()), set(SLICES) | {'Info.plist'})
        for identifier in SLICES:
            self.assertEqual((product / identifier / 'libzcashlc.framework/libzcashlc').read_text(), 'arm64')
        shutil.copy(ROOT / 'Makefile', source / 'Makefile')
        result = subprocess.run(['make', '-C', str(source), 'ffi-macos'], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(set(p.name for p in product.iterdir()), {'macos-arm64', 'Info.plist'})
        info = plistlib.loads((product / 'Info.plist').read_bytes())
        self.assertEqual([i['LibraryIdentifier'] for i in info['AvailableLibraries']], ['macos-arm64'])


if __name__ == '__main__':
    unittest.main()
