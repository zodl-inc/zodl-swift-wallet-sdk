"""Stable CI compiler selection, including real CLI/Actions-file boundaries."""
import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'Scripts/ci/rust_toolchain.py'
COMMIT = 'a' * 40
HOST = 'aarch64-apple-darwin'


def verbose(release='1.100.0', commit=COMMIT, host=HOST):
    return (f'rustc {release} ({commit[:9]} 2026-10-28)\nbinary: rustc\n'
            f'commit-hash: {commit}\ncommit-date: 2026-10-28\nhost: {host}\n'
            f'release: {release}\nLLVM version: 22.1.0\n')


class ToolchainTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(HELPER.is_file(), 'CI Rust validation helper is missing')
        spec = importlib.util.spec_from_file_location('ci_rust_toolchain', HELPER)
        self.module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.module
        spec.loader.exec_module(self.module)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.bin = self.root / 'toolchains/stable/bin'
        self.bin.mkdir(parents=True)
        self.rustc = str(self.bin / 'rustc')
        self.cargo = str(self.bin / 'cargo')
        for path in (self.rustc, self.cargo):
            Path(path).write_text('fixture')
            Path(path).chmod(0o755)
        self.manifest('1.99')
        self.env = {'PATH': '/usr/bin', 'KEEP_ME': 'preserved'}
        self.output = verbose()
        self.cargo_output = 'cargo 1.100.0 (bbbbbbbbb 2026-10-28)\n'
        self.paths = {'rustc': self.rustc, 'cargo': self.cargo}
        self.other_output = self.output
        self.calls = []
        self.fail_tool = None

    def manifest(self, minimum):
        (self.root / 'Cargo.toml').write_text('[package]\nname="fixture"\n' + minimum if minimum.startswith('rust-version') else '[package]\nname="fixture"\nrust-version="' + minimum + '"\n')

    def runner(self, command, **kwargs):
        self.calls.append((command, kwargs))
        self.assertEqual(kwargs['cwd'], self.root)
        self.assertEqual(kwargs['env']['RUSTUP_AUTO_INSTALL'], '0')
        self.assertNotIn('install', command, 'validation must never install implicitly or explicitly')
        if self.fail_tool and self.fail_tool in command:
            return subprocess.CompletedProcess(command, 1, '', 'secret diagnostic')
        if command == ['rustup', 'show', 'active-toolchain']:
            self.assertEqual(kwargs['env']['RUSTUP_TOOLCHAIN'], 'stable')
            output = f'stable-{HOST} (environment override by RUSTUP_TOOLCHAIN)\n'
        elif command[:3] == ['rustup', 'which', '--toolchain']:
            output = self.paths[command[-1]] + '\n'
        elif command == [self.rustc, '-vV']:
            output = self.output
        elif command == [self.cargo, '--version']:
            output = self.cargo_output
        elif command[-1] == '-vV':
            output = self.other_output
        else:
            self.fail('unexpected tool invocation: ' + repr(command))
        return subprocess.CompletedProcess(command, 0, output, '')

    def validate(self):
        return self.module.validate(self.root, runner=self.runner, environ=self.env)

    def rejects(self):
        with self.assertRaises(self.module.RustToolchainError):
            self.validate()

    def test_numeric_minimum_and_equal_release_are_accepted(self):
        for minimum, release in [('1.99', '1.99.0'), ('1.99.1', '1.99.1'), ('1.99', '1.100.0')]:
            with self.subTest(minimum=minimum, release=release):
                self.manifest(minimum)
                self.output = verbose(release)
                self.assertEqual(self.validate().release, release)

    def test_older_compiler_is_rejected(self):
        self.manifest('1.100')
        self.output = verbose('1.99.0')
        self.rejects()

    def test_minimum_must_be_an_explicit_numeric_string(self):
        for value in ['rust-version.workspace=true', 'rust-version=99', 'rust-version="1"',
                      'rust-version="1.99.0-beta.1"', 'rust-version="01.99"',
                      'rust-version="1.99.0.1"', '# rust-version missing', 'rust-version="^1.99"']:
            with self.subTest(value=value):
                self.manifest(value if value.startswith('rust-version') else 'rust-version=""')
                self.rejects()
        (self.root / 'Cargo.toml').write_text('not valid = [')
        self.rejects()
        (self.root / 'Cargo.toml').unlink()
        self.rejects()

    def test_prerelease_compilers_are_rejected(self):
        for release in ['1.100.0-beta.1', '1.100.0-nightly', '1.100.0-dev', '1.100', 'invalid']:
            with self.subTest(release=release):
                self.output = verbose(release)
                self.rejects()

    def test_compiler_identity_is_validated(self):
        for output in [verbose(commit='0' * 40), verbose(commit='bad'), verbose(host='bad host'),
                       verbose().replace('rustc 1.100.0', 'rustc 1.99.0'),
                       verbose() + 'release: 1.100.0\n', 'rustc 1.100.0\n']:
            with self.subTest(output=output):
                self.output = output
                self.rejects()

    def test_tool_paths_are_absolute_single_line_and_colocated(self):
        for name, path in [('rustc', 'bin/rustc'), ('rustc', '/tmp/rustc\nEVIL=x'),
                           ('cargo', '/different/bin/cargo'), ('cargo', '/tmp/not-cargo')]:
            with self.subTest(path=path):
                self.paths = {'rustc': self.rustc, 'cargo': self.cargo, name: path}
                self.rejects()

    def test_missing_or_unusable_tools_are_fatal(self):
        for tool in ['rustup', self.rustc, self.cargo]:
            with self.subTest(tool=tool):
                self.fail_tool = tool
                self.rejects()

    def test_malformed_cargo_version_is_rejected(self):
        self.cargo_output = 'not a cargo executable\n'
        self.rejects()

    def test_same_toolchain_override_is_rebound_to_stable(self):
        for override in ['stable', f'stable-{HOST}', '1.100.0']:
            with self.subTest(override=override):
                self.env['RUSTUP_TOOLCHAIN'] = override
                self.assertEqual(self.validate().env['RUSTUP_TOOLCHAIN'], f'stable-{HOST}')

    def test_different_explicit_toolchain_identity_is_rejected(self):
        self.env['RUSTUP_TOOLCHAIN'] = '1.99.0'
        self.other_output = verbose('1.99.0')
        # An alias may resolve to the same path, so supply a distinct installed compiler.
        original = self.runner
        def runner(command, **kwargs):
            if command[:3] == ['rustup', 'which', '--toolchain'] and command[3] == '1.99.0':
                return subprocess.CompletedProcess(command, 0, str(self.root / 'old/bin' / command[-1]) + '\n', '')
            return original(command, **kwargs)
        with self.assertRaises(self.module.RustToolchainError):
            self.module.validate(self.root, runner=runner, environ=self.env)

    def test_explicit_compilers_accept_paths_names_and_sdk_relative_paths(self):
        alias = self.root / 'tools/custom-compiler'
        alias.parent.mkdir()
        alias.write_text('fixture')
        alias.chmod(0o755)
        for override in [str(alias), './tools/custom-compiler', 'custom-compiler']:
            with self.subTest(override=override):
                self.env.update(RUSTC=override, PATH='tools:/usr/bin')
                selected = self.validate()
                self.assertEqual(selected.env['RUSTC'], self.rustc)
                self.assertEqual(selected.env['CARGO'], self.cargo)

    def test_explicit_compiler_identity_requires_commit_and_host(self):
        alias = self.root / 'custom'
        alias.write_text('fixture')
        alias.chmod(0o755)
        self.env['RUSTC'] = str(alias)
        for output in [verbose('1.99.0'), verbose(commit='b' * 40), verbose(host='x86_64-apple-darwin')]:
            with self.subTest(output=output):
                self.other_output = output
                self.rejects()

    def test_invalid_overrides_do_not_leak_into_diagnostics(self):
        for name in ['RUSTC', 'RUSTUP_TOOLCHAIN']:
            for value in ['', 'private-secret\nEVIL=1', 'missing compiler']:
                with self.subTest(name=name, value=value):
                    self.env = {'PATH': '/usr/bin', name: value}
                    # Empty RUSTUP_TOOLCHAIN has no explicit selection semantics.
                    if name == 'RUSTUP_TOOLCHAIN' and not value:
                        continue
                    with self.assertRaises(self.module.RustToolchainError) as error:
                        self.validate()
                    if value:
                        self.assertNotIn(value, str(error.exception))

    def test_selection_binds_tools_clears_wrappers_and_preserves_caller_environment(self):
        self.env.update(RUSTC_WRAPPER='wrapper', RUSTC_WORKSPACE_WRAPPER='wrapper',
                        CARGO_BUILD_RUSTC='wrong', CARGO_BUILD_RUSTC_WRAPPER='wrapper',
                        CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER='wrapper', GH_TOKEN='secret',
                        GITHUB_TOKEN='secret', AWS_SECRET_ACCESS_KEY='secret')
        original = dict(self.env)
        selected = self.validate()
        self.assertEqual(self.env, original)
        self.assertEqual(selected.env['RUSTC'], self.rustc)
        self.assertEqual(selected.env['CARGO_BUILD_RUSTC'], self.rustc)
        self.assertEqual(selected.env['CARGO'], self.cargo)
        self.assertEqual(selected.env['KEEP_ME'], 'preserved')
        self.assertEqual(selected.env['PATH'], str(self.bin) + ':/usr/bin')
        for name in ['RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'CARGO_BUILD_RUSTC_WRAPPER', 'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER']:
            self.assertEqual(selected.env[name], '')
        for _, kwargs in self.calls:
            self.assertNotIn('GH_TOKEN', kwargs['env'])
            self.assertNotIn('GITHUB_TOKEN', kwargs['env'])
            self.assertNotIn('AWS_SECRET_ACCESS_KEY', kwargs['env'])

    def test_cache_key_hashes_complete_verbose_output(self):
        first = self.validate()
        self.assertEqual(first.cachekey, hashlib.sha256(self.output.encode()).hexdigest())
        self.assertEqual((first.commit, first.host), (COMMIT, HOST))
        self.output = self.output.replace('LLVM version: 22.1.0', 'LLVM version: 23.1.0')
        self.assertNotEqual(first.cachekey, self.validate().cachekey)

    def test_cli_failure_leaves_actions_files_untouched(self):
        (self.root / 'Cargo.toml').write_text('[package]\nname="fixture"\n')
        files = [self.root / name for name in ['env', 'output', 'path']]
        for path in files:
            path.write_text('sentinel\n')
        result = subprocess.run([sys.executable, str(HELPER), '--root', str(self.root),
                                 '--github-env', str(files[0]), '--github-output', str(files[1]),
                                 '--github-path', str(files[2])], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([path.read_text() for path in files], ['sentinel\n'] * 3)

    def test_cli_exports_only_validated_values(self):
        files = [self.root / name for name in ['env', 'output', 'path']]
        for path in files:
            path.write_text('sentinel\n')
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            result = self.module.main(['--root', str(self.root), '--github-env', str(files[0]),
                                       '--github-output', str(files[1]), '--github-path', str(files[2])],
                                      runner=self.runner, environ=self.env)
        self.assertEqual(result, 0)
        environment = dict(line.split('=', 1) for line in files[0].read_text().splitlines()[1:])
        output = dict(line.split('=', 1) for line in files[1].read_text().splitlines()[1:])
        self.assertEqual(environment['RUSTC'], self.rustc)
        self.assertEqual(environment['CARGO'], self.cargo)
        self.assertEqual(environment['RUSTUP_AUTO_INSTALL'], '0')
        self.assertEqual(environment['RUSTUP_TOOLCHAIN'], f'stable-{HOST}')
        self.assertEqual(environment['CARGO_BUILD_RUSTC'], self.rustc)
        self.assertEqual(environment['RUSTC_WRAPPER'], '')
        self.assertNotIn('KEEP_ME', environment)
        self.assertEqual(output['cachekey'], hashlib.sha256(self.output.encode()).hexdigest())
        self.assertEqual(output['release'], '1.100.0')
        self.assertEqual(files[2].read_text(), 'sentinel\n' + str(self.bin) + '\n')


if __name__ == '__main__':
    unittest.main()
