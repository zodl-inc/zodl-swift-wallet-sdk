#!/usr/bin/env python3
"""Validate installed stable Rust before CI restores or builds native artifacts."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib
from typing import Mapping

_NUMBER = r'(?:0|[1-9][0-9]*)'
_RELEASE = re.compile(rf'{_NUMBER}\.{_NUMBER}\.{_NUMBER}')
_MINIMUM = re.compile(rf'{_NUMBER}\.{_NUMBER}(?:\.{_NUMBER})?')
_TOOLCHAIN = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,199}')
_HOST = re.compile(r'[a-z0-9_]+(?:-[a-z0-9_]+){2,4}')
_COMMIT = re.compile(r'[0-9a-f]{40}')
_WRAPPERS = ('RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'CARGO_BUILD_RUSTC_WRAPPER',
             'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER')
_EXPORTED = ('RUSTUP_TOOLCHAIN', 'RUSTUP_AUTO_INSTALL', 'RUSTC', 'CARGO', 'CARGO_BUILD_RUSTC',
             *_WRAPPERS, 'CARGO_INCREMENTAL', 'CARGO_TERM_COLOR')
_SECRETS = frozenset({'GH_TOKEN', 'AUTHORITY_GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN',
                      'GITHUB_ENTERPRISE_TOKEN', 'ZODL_SOURCE_APP', 'ZODL_ASC', 'ZODL_PARTNER_KEYS',
                      'ZODL_IOS_SIGNING', 'ZODL_MAC_DMG_SIGNING', 'ZODL_SPARKLE_KEY',
                      'ZODL_PUBLISH_APP', 'ZODL_SLACK_BOT', 'ZODL_SPARKLE_PRIVATE_KEY'})
_ERRORS = {
    'minimum': 'The SDK root Cargo.toml must declare a numeric package.rust-version.',
    'probe': 'The installed stable Rust toolchain could not be verified.',
    'unstable': 'The installed stable compiler must report a numeric stable release.',
    'too_old': 'The installed stable compiler is older than the SDK Rust minimum.',
    'override': 'An explicit RUSTC or RUSTUP_TOOLCHAIN override conflicts with stable Rust.',
}


class RustToolchainError(ValueError):
    """A safe diagnostic that never embeds raw process output or overrides."""

    def __init__(self, reason: str):
        self.reason = reason
        super().__init__(_ERRORS[reason])


@dataclass(frozen=True)
class RustSelection:
    release: str
    commit: str
    host: str
    rustc: str
    cargo: str
    cachekey: str
    env: dict[str, str]


def _version(value: str) -> tuple[int, int, int]:
    parts = tuple(int(part) for part in value.split('.'))
    return parts if len(parts) == 3 else (*parts, 0)


def _minimum(root: Path) -> tuple[int, int, int]:
    try:
        with (root / 'Cargo.toml').open(encoding='utf-8') as stream:
            manifest = stream.read(256 * 1024 + 1)
        if len(manifest) > 256 * 1024:
            raise ValueError('oversized')
        package = tomllib.loads(manifest).get('package')
        value = package.get('rust-version') if isinstance(package, dict) else None
        if not isinstance(value, str) or not _MINIMUM.fullmatch(value):
            raise ValueError('minimum')
        return _version(value)
    except (OSError, UnicodeError, ValueError, TypeError, OverflowError):
        raise RustToolchainError('minimum') from None


def _base_environment(environ: Mapping[str, str]) -> dict[str, str]:
    env = {name: value for name, value in environ.items()
           if name not in _SECRETS and not name.startswith(('GITHUB_APP_', 'AWS_'))}
    env['RUSTUP_AUTO_INSTALL'] = '0'
    return env


def _bound_environment(environ, toolchain, rustc, cargo):
    env = _base_environment(environ)
    env.update(RUSTUP_TOOLCHAIN=toolchain, RUSTC=rustc, CARGO=cargo, CARGO_BUILD_RUSTC=rustc,
               CARGO_INCREMENTAL='0', CARGO_TERM_COLOR='always')
    env.update({name: '' for name in _WRAPPERS})
    env['PATH'] = str(Path(rustc).parent) + (':' + env['PATH'] if env.get('PATH') else '')
    return env


def _probe(command, root, runner, environ):
    try:
        result = runner(command, cwd=root, env=dict(environ), capture_output=True, text=True, timeout=10)
        if (result.returncode or not isinstance(result.stdout, str) or not isinstance(result.stderr, str)
                or len(result.stdout) > 16 * 1024 or len(result.stderr) > 16 * 1024):
            raise ValueError('probe')
        return result.stdout
    except (OSError, ValueError, subprocess.SubprocessError):
        raise RustToolchainError('probe') from None


def _tool_path(output, name):
    value = output.removesuffix('\n')
    path = Path(value)
    if (not path.is_absolute() or path.name != name or '..' in path.parts
            or any(not char.isprintable() for char in value)):
        raise RustToolchainError('probe')
    return value


def _tool_paths(root, toolchain, runner, env):
    paths = [_tool_path(_probe(['rustup', 'which', '--toolchain', toolchain, name], root, runner, env), name)
             for name in ('rustc', 'cargo')]
    if Path(paths[0]).parent != Path(paths[1]).parent:
        raise RustToolchainError('probe')
    return paths


def _compiler(output, minimum):
    lines = output.splitlines()
    if not lines:
        raise RustToolchainError('probe')
    fields = {}
    for line in lines[1:]:
        key, separator, value = line.partition(': ')
        if not separator or not value or key in fields:
            raise RustToolchainError('probe')
        fields[key] = value
    release = fields.get('release', '')
    if not _RELEASE.fullmatch(release):
        raise RustToolchainError('unstable')
    commit, host = fields.get('commit-hash', ''), fields.get('host', '')
    header = re.fullmatch(rf'rustc {re.escape(release)} \(([0-9a-f]{{7,40}}) [0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}\)', lines[0])
    if (fields.get('binary') != 'rustc' or not _COMMIT.fullmatch(commit) or commit == '0' * 40
            or not _HOST.fullmatch(host) or not header or not commit.startswith(header[1])):
        raise RustToolchainError('probe')
    if _version(release) < minimum:
        raise RustToolchainError('too_old')
    return release, commit, host


def _explicit_compiler(value, root, environ):
    if not value or any(not char.isprintable() or char.isspace() for char in value):
        raise RustToolchainError('override')
    path = Path(value)
    command = str(root / path) if not path.is_absolute() and '/' in value else value
    # Child probes run from the SDK; resolve relative PATH entries there too.
    search_path = ':'.join(str(root / entry) if not Path(entry).is_absolute() else entry
                           for entry in environ.get('PATH', '').split(':'))
    resolved = shutil.which(command, path=search_path)
    if resolved is None:
        raise RustToolchainError('override')
    return resolved


def _check_overrides(root, selected, toolchain, runner, environ):
    explicit = environ.get('RUSTUP_TOOLCHAIN')
    if explicit and explicit not in (toolchain, 'stable'):
        try:
            if not _TOOLCHAIN.fullmatch(explicit):
                raise RustToolchainError('override')
            env = _base_environment(environ)
            env['RUSTUP_TOOLCHAIN'] = explicit
            rustc, cargo = _tool_paths(root, explicit, runner, env)
            env = _bound_environment(env, explicit, rustc, cargo)
            identity = _compiler(_probe([rustc, '-vV'], root, runner, env), (0, 0, 0))
            if identity != (selected.release, selected.commit, selected.host):
                raise RustToolchainError('override')
        except RustToolchainError:
            raise RustToolchainError('override') from None
    if 'RUSTC' in environ and environ['RUSTC'] != selected.rustc:
        try:
            rustc = _explicit_compiler(environ['RUSTC'], root, environ)
            identity = _compiler(_probe([rustc, '-vV'], root, runner, selected.env), (0, 0, 0))
            if identity != (selected.release, selected.commit, selected.host):
                raise RustToolchainError('override')
        except RustToolchainError:
            raise RustToolchainError('override') from None


def validate(root: Path, *, runner, environ: Mapping[str, str]) -> RustSelection:
    """Bind already-installed stable tools without changing defaults or installing."""
    root = root.resolve()
    minimum = _minimum(root)
    env = _base_environment(environ)
    env['RUSTUP_TOOLCHAIN'] = 'stable'
    active = _probe(['rustup', 'show', 'active-toolchain'], root, runner, env).strip()
    toolchain = active.partition(' ')[0]
    if not _TOOLCHAIN.fullmatch(toolchain) or '\n' in active or '\r' in active:
        raise RustToolchainError('probe')
    env['RUSTUP_TOOLCHAIN'] = toolchain
    rustc, cargo = _tool_paths(root, toolchain, runner, env)
    bound = _bound_environment(env, toolchain, rustc, cargo)
    output = _probe([rustc, '-vV'], root, runner, bound)
    release, commit, host = _compiler(output, minimum)
    if toolchain not in ('stable', f'stable-{host}'):
        raise RustToolchainError('probe')
    cargo_output = _probe([cargo, '--version'], root, runner, bound)
    if not re.fullmatch(rf'cargo {_RELEASE.pattern} \([0-9a-f]{{7,40}} [0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}\)\n?', cargo_output):
        raise RustToolchainError('probe')
    selected = RustSelection(release, commit, host, rustc, cargo,
                             hashlib.sha256(output.encode('utf-8')).hexdigest(), bound)
    _check_overrides(root, selected, toolchain, runner, environ)
    return selected


def main(argv=None, *, runner=subprocess.run, environ=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--github-env', type=Path)
    parser.add_argument('--github-output', type=Path)
    parser.add_argument('--github-path', type=Path)
    args = parser.parse_args(argv)
    try:
        selected = validate(args.root, runner=runner, environ=os.environ if environ is None else environ)
        # Persist only validated single-line values, after every check succeeds.
        exports = '\n'.join(name + '=' + selected.env[name] for name in _EXPORTED) + '\n'
        outputs = '\n'.join(name + '=' + getattr(selected, name)
                            for name in ('release', 'commit', 'host', 'rustc', 'cargo', 'cachekey')) + '\n'
        for path, content in ((args.github_env, exports), (args.github_output, outputs),
                              (args.github_path, str(Path(selected.rustc).parent) + '\n')):
            if path is not None:
                with path.open('a', encoding='utf-8') as stream:
                    stream.write(content)
        print(f'Validated Rust {selected.release} ({selected.host}, {selected.commit})')
        return 0
    except (RustToolchainError, OSError) as error:
        diagnostic = str(error) if isinstance(error, RustToolchainError) else 'Could not persist validated Rust settings.'
        print('Rust validation failed: ' + diagnostic, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
