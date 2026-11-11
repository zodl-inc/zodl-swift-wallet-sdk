"""Exercise the layout CLI and real Make packaging with external tool doubles."""
import itertools
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'Scripts/lib/ffi_layout.py'
sys.path.insert(0, str(ROOT / 'Scripts/lib'))
from ffi_layout import MACOS_LINKS  # noqa: E402

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
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('ZODL_OHTTP_')}
        self.env.update(PATH=str(self.tools) + os.pathsep + os.environ['PATH'])

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

    def test_versioned_macos_is_accepted_without_opt_in(self):
        self.fixture(('macos-arm64',))
        self.version_macos()
        result = self.cli('validate', self.product)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_require_versioned_macos_rejects_shallow_macos_only(self):
        self.fixture()
        flags = ('--require-full', '--require-versioned-macos')
        self.assertNotEqual(self.cli('validate', self.product, *flags).returncode, 0)
        self.version_macos()
        result = self.cli('validate', self.product, *flags)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_require_versioned_macos_does_not_require_a_macos_slice(self):
        self.fixture(('ios-arm64',))
        result = self.cli('validate', self.product, '--require-versioned-macos')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_versioned_macos_with_root_plist_or_extra_entries_is_rejected(self):
        self.fixture(('macos-arm64',))
        framework = self.version_macos()
        plist = framework / 'Info.plist'
        plist.write_bytes(plistlib.dumps({'CFBundleExecutable': 'libzcashlc'}))
        self.assertNotEqual(self.cli('validate', self.product).returncode, 0)
        plist.unlink()
        extra = framework / 'extra'
        extra.write_text('x')
        self.assertNotEqual(self.cli('validate', self.product).returncode, 0)
        extra.unlink()
        evil = framework / 'Versions/A/evil'
        evil.symlink_to('A')
        self.assertNotEqual(self.cli('validate', self.product).returncode, 0)
        evil.unlink()
        resource_plist = framework / 'Versions/A/Resources/Info.plist'
        content = resource_plist.read_bytes()
        resource_plist.unlink()
        self.assertNotEqual(self.cli('validate', self.product).returncode, 0)
        resource_plist.write_bytes(content)
        self.assertEqual(self.cli('validate', self.product).returncode, 0)

    def test_versioned_macos_with_bad_link_targets_is_rejected(self):
        self.fixture(('macos-arm64',))
        framework = self.version_macos()
        for target in ('../../../../outside', str(framework / 'Versions/A/Headers'), 'Versions/Current/libzcashlc'):
            path = framework / 'Headers'
            path.unlink()
            path.symlink_to(target)
            self.assertNotEqual(self.cli('validate', self.product).returncode, 0)

    def test_ios_links_and_symlinked_slice_are_rejected(self):
        self.fixture()
        path = self.product / 'ios-arm64/libzcashlc.framework/Headers/zcashlc.h'
        outside = self.base / 'header'
        path.rename(outside)
        path.symlink_to(outside)
        self.assertNotEqual(self.cli('validate', self.product).returncode, 0)

    def zip_with(self, members):
        archive = self.base / 'hostile.zip'
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
            for name, content, is_link in members:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = ((stat.S_IFLNK if is_link else stat.S_IFREG) | 0o755) << 16
                output.writestr(info, content)
        return archive

    def extract_cli(self, archive):
        destination = self.base / 'out'
        shutil.rmtree(destination, ignore_errors=True)
        destination.mkdir()
        return self.cli('extract', archive, destination), destination

    def test_extract_rejects_disallowed_links_before_writing_anything(self):
        macos = 'libzcashlc.xcframework/macos-arm64/libzcashlc.framework/'
        regular = ('libzcashlc.xcframework/Info.plist', 'plist', False)
        cases = {
            'wrong target': (macos + 'Headers', 'Versions/A/Headers'),
            'escaping target': (macos + 'Headers', '../../../../escaped'),
            'link in ios slice': ('libzcashlc.xcframework/ios-arm64/libzcashlc.framework/Headers', 'Versions/Current/Headers'),
            'extra link name': (macos + 'Versions/A/evil', 'A'),
            'oversized link under a disallowed name': ('libzcashlc.xcframework/ios-arm64/x', '\0' * 400_000),
        }
        for label, (name, target) in cases.items():
            with self.subTest(label):
                result, destination = self.extract_cli(self.zip_with([regular, (name, target, True)]))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('unexpected link member', result.stderr)
                self.assertEqual(list(destination.iterdir()), [])

    def test_extract_reads_a_link_target_with_a_bound_close_to_its_expected_length(self):
        name = 'libzcashlc.xcframework/macos-arm64/libzcashlc.framework/Headers'
        expected = MACOS_LINKS['Headers']
        archive = self.base / 'bomb.zip'
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o755) << 16
            # A few MB of deflated zeros behind a header that declares the real target length.
            output.writestr(info, b'\0' * (4 * 1024 ** 2))
            output.getinfo(name).file_size = len(expected)
        reads = []
        real = zipfile.ZipExtFile.read
        def recording(extfile, size=-1):
            reads.append(size)
            return real(extfile, size)
        destination = self.base / 'out'
        destination.mkdir()
        sys.path.insert(0, str(ROOT / 'Scripts/lib'))
        import ffi_layout
        with mock.patch.object(zipfile.ZipExtFile, 'read', recording), self.assertRaises(ffi_layout.LayoutError):
            ffi_layout.extract(archive, destination)
        self.assertTrue(reads)
        self.assertTrue(all(0 <= size <= len(expected) + 1 for size in reads), reads)
        self.assertEqual(list(destination.iterdir()), [])

    def test_extract_reports_a_corrupt_compressed_link_as_a_layout_error(self):
        name = 'libzcashlc.xcframework/macos-arm64/libzcashlc.framework/Headers'
        archive = self.base / 'corrupt.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o755) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(info, MACOS_LINKS['Headers'])
        data = bytearray(archive.read_bytes())
        start = data.index(name.encode()) + len(name)
        data[start:start + 6] = b'\xff' * 6
        archive.write_bytes(data)
        result, destination = self.extract_cli(archive)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertIn('ffi-layout:', result.stderr)
        self.assertEqual(list(destination.iterdir()), [])

    def test_extract_rejects_members_nested_under_a_link_before_writing_anything(self):
        macos = 'libzcashlc.xcframework/macos-arm64/libzcashlc.framework/'
        links = [(macos + name, target, True) for name, target in MACOS_LINKS.items()]
        # APFS is case-insensitive, so a case variant of a link path is just as much a parent.
        for nested in (macos + 'Headers/x.h', macos + 'headers/x.h', macos + 'Versions/Current/x'):
            with self.subTest(nested):
                regular = ('libzcashlc.xcframework/Info.plist', 'plist', False)
                result, destination = self.extract_cli(self.zip_with([regular, (nested, 'data', False)] + links))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('member nested under a link', result.stderr)
                self.assertEqual(list(destination.iterdir()), [])

    def test_extract_creates_exactly_the_five_macos_links(self):
        macos = 'libzcashlc.xcframework/macos-arm64/libzcashlc.framework/'
        members = [(macos + 'Versions/A/libzcashlc', 'binary', False)]
        members += [(macos + name, target, True) for name, target in MACOS_LINKS.items()]
        result, destination = self.extract_cli(self.zip_with(members))
        self.assertEqual(result.returncode, 0, result.stderr)
        framework = destination / 'libzcashlc.xcframework/macos-arm64/libzcashlc.framework'
        for name, target in MACOS_LINKS.items():
            self.assertTrue((framework / name).is_symlink(), name)
            self.assertEqual(os.readlink(framework / name), target)


def walk_without_following_links(root):
    for directory, names, files in os.walk(root, followlinks=False):
        for name in names + files:
            yield Path(directory) / name


class MakePackagingTests(unittest.TestCase):
    setUp = LayoutTests.setUp
    walk = staticmethod(walk_without_following_links)

    def assert_versioned_macos(self, product, version):
        framework = product / 'macos-arm64/libzcashlc.framework'
        self.assertEqual({p.name for p in framework.iterdir()},
                         {'Versions', 'libzcashlc', 'Headers', 'Modules', 'Resources'})
        for link, target in MACOS_LINKS.items():
            self.assertTrue((framework / link).is_symlink(), link)
            self.assertEqual(os.readlink(framework / link), target)
        self.assertEqual((framework / 'Versions/A/libzcashlc').read_text(), 'arm64')
        self.assertFalse((framework / 'Info.plist').exists())
        info = plistlib.loads((framework / 'Versions/A/Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], version)

    def test_real_packaging_excludes_stale_intel_inputs_and_replaces_old_product(self):
        source = self.base / 'source'
        support = source / 'BuildSupport'
        shutil.copytree(ROOT / 'BuildSupport', support, ignore=shutil.ignore_patterns('products'))
        (source / 'Scripts/lib').mkdir(parents=True)
        if HELPER.exists():
            shutil.copy(HELPER, source / 'Scripts/lib/ffi_layout.py')
        versioner = source / 'Scripts/version-macos-framework.sh'
        shutil.copy(ROOT / 'Scripts/version-macos-framework.sh', versioner)
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
        platform = plistlib.loads((support / 'platform-Info.plist').read_bytes())
        self.assert_versioned_macos(product, platform['CFBundleShortVersionString'])
        for identifier in ('ios-arm64', 'ios-arm64-simulator'):
            framework = product / identifier / 'libzcashlc.framework'
            self.assertTrue((framework / 'Info.plist').is_file())
            self.assertEqual([p for p in self.walk(framework) if p.is_symlink()], [])
        shutil.copy(ROOT / 'Makefile', source / 'Makefile')
        result = subprocess.run(['make', '-C', str(source), 'ffi-macos'], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(set(p.name for p in product.iterdir()), {'macos-arm64', 'Info.plist'})
        info = plistlib.loads((product / 'Info.plist').read_bytes())
        self.assertEqual([i['LibraryIdentifier'] for i in info['AvailableLibraries']], ['macos-arm64'])
        self.assert_versioned_macos(product, platform['CFBundleShortVersionString'])

    def test_release_packaging_refuses_a_shallow_macos_slice(self):
        source = self.base / 'source'
        support = source / 'BuildSupport'
        shutil.copytree(ROOT / 'BuildSupport', support, ignore=shutil.ignore_patterns('products'))
        (source / 'Scripts/lib').mkdir(parents=True)
        shutil.copy(HELPER, source / 'Scripts/lib/ffi_layout.py')
        # A versioner that succeeds without converting anything must not yield a release.
        versioner = source / 'Scripts/version-macos-framework.sh'
        versioner.write_text('#!/bin/sh\nexit 0\n')
        versioner.chmod(0o755)
        (source / 'Cargo.toml').write_text('fixture')
        (source / 'rust').mkdir()
        (source / 'target/Headers').mkdir(parents=True)
        (source / 'target/Headers/zcashlc.h').write_text('void fixture(void);')
        for arch in ('aarch64-apple-darwin', 'aarch64-apple-ios', 'aarch64-apple-ios-sim'):
            archive = source / 'target' / arch / 'release/libzcashlc.a'
            archive.parent.mkdir(parents=True)
            archive.write_text('arm64')
        (self.tools / 'cargo').write_text('#!/bin/sh\nexit 0\n')
        (self.tools / 'cargo').chmod(0o755)
        (self.tools / 'lipo').write_text('''#!/usr/bin/env python3
import pathlib, sys
args = sys.argv[1:]
if args[0] == '-archs':
    print(pathlib.Path(args[1]).read_text())
else:
    output = args.index('-output')
    pathlib.Path(args[output + 1]).write_text(pathlib.Path(args[1]).read_text())
''')
        result = subprocess.run(['make', '-C', str(support), 'xcframework'], env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('macOS framework must be versioned', result.stderr)


class VersionerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo'
        (self.repo / 'Scripts').mkdir(parents=True)
        (self.repo / 'BuildSupport').mkdir()
        shutil.copy(ROOT / 'Scripts/version-macos-framework.sh', self.repo / 'Scripts')
        self.platform = self.repo / 'BuildSupport/platform-Info.plist'
        self.platform.write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'libzcashlc', 'CFBundleExecutable': 'libzcashlc',
            'CFBundleShortVersionString': '9.8.7', 'CFBundleVersion': '42'}))
        self.framework = self.base_framework()

    def base_framework(self):
        framework = Path(self.temp.name) / 'libzcashlc.framework'
        (framework / 'Headers').mkdir(parents=True)
        (framework / 'Modules').mkdir()
        (framework / 'libzcashlc').write_text('arm64')
        (framework / 'Headers/zcashlc.h').write_text('void fixture(void);')
        (framework / 'Modules/module.modulemap').write_text('module libzcashlc {}')
        (framework / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'libzcashlc'}))
        return framework

    def run_versioner(self):
        return subprocess.run(['../Scripts/version-macos-framework.sh', str(self.framework)],
                              cwd=self.repo / 'BuildSupport', text=True, capture_output=True)

    def test_versions_come_from_the_plist_beside_the_script_from_any_directory(self):
        result = self.run_versioner()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        info = plistlib.loads((self.framework / 'Versions/A/Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], '9.8.7')
        self.assertEqual(info['CFBundleVersion'], '42')
        self.assertFalse((self.framework / 'Info.plist').exists())

    def test_missing_platform_plist_fails_before_touching_the_framework(self):
        self.platform.unlink()
        before = self.snapshot()
        result = self.run_versioner()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_platform_plist_without_a_version_key_fails_before_touching_the_framework(self):
        self.platform.write_bytes(plistlib.dumps({'CFBundleVersion': '42'}))
        before = self.snapshot()
        result = self.run_versioner()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)

    def snapshot(self):
        return {str(p.relative_to(self.framework)): (os.readlink(p) if p.is_symlink() else
                                                    None if p.is_dir() else p.read_bytes())
                for p in walk_without_following_links(self.framework)}


class ConfigureLocalFFITests(unittest.TestCase):
    fixture = LayoutTests.fixture
    save = LayoutTests.save

    def setUp(self):
        LayoutTests.setUp(self)
        self.repo = self.base / 'sdk'
        (self.repo / 'Scripts/lib').mkdir(parents=True)
        (self.repo / 'BuildSupport/products').mkdir(parents=True)
        shutil.copy(ROOT / 'Makefile', self.repo / 'Makefile')
        shutil.copy(HELPER, self.repo / 'Scripts/lib/ffi_layout.py')
        shutil.copy(ROOT / 'Scripts/version-macos-framework.sh', self.repo / 'Scripts/version-macos-framework.sh')
        shutil.copy(ROOT / 'BuildSupport/platform-Info.plist', self.repo / 'BuildSupport/platform-Info.plist')
        self.product = self.repo / 'BuildSupport/products/libzcashlc.xcframework'
        self.product.mkdir()
        self.source_wrapper = self.repo / 'BuildSupport/LocalPackages-Package.swift'
        self.source_wrapper.write_text('new wrapper')
        self.local = self.repo / 'LocalPackages'
        self.install = self.local / 'libzcashlc.xcframework'
        self.install.mkdir(parents=True)
        (self.install / 'previous-framework').write_text('previous framework')
        (self.local / 'Package.swift').write_text('previous wrapper')

    def configure(self, python=None):
        return subprocess.run(['make', '-C', str(self.repo), 'configure-local-ffi',
                               'PYTHON=' + str(python or sys.executable)],
                              env=self.env, text=True, capture_output=True)

    def snapshot(self):
        return {str(p.relative_to(self.local)): (os.readlink(p) if p.is_symlink() else p.read_bytes())
                for p in self.local.rglob('*') if p.is_file() or p.is_symlink()}

    def assert_preserved_failure(self, before, python=None):
        result = self.configure(python)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)
        return result

    def test_missing_invalid_old_and_fat_products_preserve_both_installed_paths(self):
        for damage in ('missing-product', 'missing-manifest', 'malformed-manifest',
                       'old-slice', 'fat-binary', 'missing-payload'):
            with self.subTest(damage=damage):
                shutil.rmtree(self.product, ignore_errors=True)
                self.product.mkdir()
                self.fixture()
                if damage == 'missing-product':
                    shutil.rmtree(self.product)
                elif damage == 'missing-manifest':
                    (self.product / 'Info.plist').unlink()
                elif damage == 'malformed-manifest':
                    (self.product / 'Info.plist').write_bytes(b'bad plist')
                elif damage == 'old-slice':
                    (self.product / 'macos-arm64').rename(self.product / 'macos-arm64_x86_64')
                elif damage == 'fat-binary':
                    (self.product / 'macos-arm64/libzcashlc.framework/libzcashlc').write_text('arm64 x86_64')
                else:
                    (self.product / 'ios-arm64/libzcashlc.framework/Headers/zcashlc.h').unlink()
                self.assert_preserved_failure(self.snapshot())

    def test_missing_wrapper_preserves_both_installed_paths(self):
        self.fixture()
        self.source_wrapper.unlink()
        self.assert_preserved_failure(self.snapshot())

    def test_full_and_macos_only_products_replace_previous_installation_without_rebuild(self):
        for identifiers in (tuple(SLICES), ('macos-arm64',)):
            with self.subTest(identifiers=identifiers):
                shutil.rmtree(self.product)
                self.product.mkdir()
                self.fixture(identifiers)
                result = self.configure()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual({p.name for p in self.install.iterdir()}, set(identifiers) | {'Info.plist'})
                self.assertEqual((self.local / 'Package.swift').read_text(), 'new wrapper')
                self.assertEqual((self.install / 'macos-arm64/libzcashlc.framework/libzcashlc').read_text(), 'arm64')

    def test_versioned_product_installs_with_identical_payload(self):
        self.fixture()
        framework = LayoutTests.version_macos(self)
        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        installed = self.install / 'macos-arm64/libzcashlc.framework'
        for link, target in MACOS_LINKS.items():
            self.assertEqual(os.readlink(installed / link), target)
        self.assertEqual((installed / 'Versions/A/libzcashlc').read_bytes(),
                         (framework / 'Versions/A/libzcashlc').read_bytes())

    def test_versioning_failure_preserves_both_installed_paths(self):
        self.fixture()
        versioner = self.repo / 'Scripts/version-macos-framework.sh'
        for script in ('#!/bin/sh\nexit 9\n', '#!/bin/sh\nrm "$1/Headers/zcashlc.h"\n'):
            with self.subTest(script=script):
                versioner.write_text(script)
                self.assert_preserved_failure(self.snapshot())
                self.assertTrue((self.product / 'macos-arm64/libzcashlc.framework/Headers/zcashlc.h').is_file())

    def test_staged_copy_and_replacement_failures_restore_both_installed_paths(self):
        self.fixture()
        python = self.tools / 'failure-python'
        python.write_text('#!' + sys.executable + '\n' + r'''
import os, pathlib, runpy, shutil, sys
failure = os.environ['INSTALL_FAILURE']
copytree, copy2, replace = shutil.copytree, shutil.copy2, os.replace

def fail_copytree(source, destination, *args, **kwargs):
    if failure == 'framework-copy':
        pathlib.Path(destination).mkdir()
        (pathlib.Path(destination) / 'partial').write_text('partial')
        raise OSError('injected framework copy failure')
    return copytree(source, destination, *args, **kwargs)

def fail_copy2(source, destination, *args, **kwargs):
    if failure == 'wrapper-copy' and pathlib.Path(source).name == 'LocalPackages-Package.swift':
        pathlib.Path(destination).write_text('partial wrapper')
        raise OSError('injected wrapper copy failure')
    return copy2(source, destination, *args, **kwargs)

def fail_replace(source, destination, *args, **kwargs):
    source, destination = pathlib.Path(source), pathlib.Path(destination)
    kind = 'framework' if source.name.endswith('.xcframework') else 'wrapper'
    action = 'backup' if source.parent.name == 'LocalPackages' else 'replace'
    if failure == kind + '-' + action:
        globals()['failure'] = ''
        raise OSError('injected ' + kind + ' ' + action + ' failure')
    return replace(source, destination, *args, **kwargs)

shutil.copytree, shutil.copy2, os.replace = fail_copytree, fail_copy2, fail_replace
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
''')
        python.chmod(0o755)
        for failure in ('framework-copy', 'wrapper-copy', 'framework-backup',
                        'wrapper-backup', 'framework-replace', 'wrapper-replace'):
            with self.subTest(failure=failure):
                self.env['INSTALL_FAILURE'] = failure
                result = self.assert_preserved_failure(self.snapshot(), python)
                self.assertIn('injected ' + failure.replace('-', ' ') + ' failure', result.stderr)


if __name__ == '__main__':
    unittest.main()
