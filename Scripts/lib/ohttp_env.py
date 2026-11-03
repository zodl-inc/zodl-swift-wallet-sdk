#!/usr/bin/env python3
"""Resolve relay build inputs without logging values or rewriting source files."""
from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import tempfile
import unicodedata
from urllib.parse import urlsplit

RELAY_NAMES = ('ZODL_OHTTP_RELAY_URL_MAINNET', 'ZODL_OHTTP_RELAY_URL_TESTNET')


def validate_relay_url(name: str, value: str | None, *, required: bool) -> None:
    if value is None or value == '':
        if required:
            raise ValueError(f'{name} is required')
        return
    try:
        if any(character.isspace() or unicodedata.category(character) in ('Cc', 'Cf') for character in value):
            raise ValueError()
        parsed = urlsplit(value)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username is not None or parsed.password is not None:
            raise ValueError()
        # Older system Python accepts junk after a bracketed IPv6 host.
        if parsed.netloc.startswith('['):
            suffix = parsed.netloc[parsed.netloc.index(']') + 1:]
            if suffix and not suffix.startswith(':'):
                raise ValueError()
        # Accessing port also rejects malformed and out-of-range ports.
        parsed.port
        host = parsed.hostname
        if any(character in host for character in '\\%'):
            raise ValueError()
        if ':' not in host:
            labels = host.rstrip('.').encode('idna').decode('ascii').split('.')
            if any(not label or len(label) > 63 or label.startswith('-') or label.endswith('-') or
                   any(not (character.isalnum() or character == '-') for character in label) for label in labels):
                raise ValueError()
    except (ValueError, UnicodeError):
        raise ValueError(f'{name} must be a valid HTTPS URL') from None


def _is_ci(environ: dict[str, str]) -> bool:
    return 'CI' in environ or 'GITHUB_ACTIONS' in environ


def load_shell_exports(environ: dict[str, str]) -> dict[str, str]:
    if _is_ci(environ):
        return {}
    # A separate inherited descriptor keeps startup chatter out of the protocol.
    # Only exported parameters are accepted, and no environment value is shell code.
    with tempfile.TemporaryFile() as result:
        descriptor = result.fileno()
        script = '\n'.join(
            f'if [[ $parameters[{name}] == *export* ]]; then print -rn -- {name}$\'\\0\'"${{{name}}}"$\'\\0\' >&{descriptor}; fi'
            for name in RELAY_NAMES
        )
        try:
            process = subprocess.Popen(['/bin/zsh', '-l', '-i', '-c', script], env=environ,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, pass_fds=(descriptor,), start_new_session=True)
            try:
                status = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise ValueError('Local shell relay import timed out') from None
        except OSError:
            raise ValueError('Local shell relay import failed') from None
        if status:
            raise ValueError('Local shell relay import failed')
        result.seek(0)
        data = result.read(65537)
    if len(data) > 65536:
        raise ValueError('Local shell relay import exceeded its limit')
    try:
        fields = data.decode('utf-8').split('\0')
        if fields.pop() != '' or len(fields) % 2:
            raise ValueError()
        exports = dict(zip(fields[::2], fields[1::2]))
        if any(name not in RELAY_NAMES for name in exports):
            raise ValueError()
        return exports
    except (ValueError, UnicodeError):
        raise ValueError('Local shell relay import returned invalid data') from None


def resolve_relay_environment(environ: dict[str, str], *, required: bool, shell_loader=None) -> dict[str, str]:
    child = dict(environ)
    if not _is_ci(environ) and any(name not in child for name in RELAY_NAMES):
        exports = (shell_loader or load_shell_exports)(dict(environ))
        for name in RELAY_NAMES:
            if name not in child and name in exports:
                child[name] = exports[name]
    for name in RELAY_NAMES:
        validate_relay_url(name, child.get(name), required=required)
    return child


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--optional', action='store_true')
    mode.add_argument('--required', action='store_true')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command[:1] == ['--']:
        command = command[1:]
    try:
        child = resolve_relay_environment(dict(os.environ), required=arguments.required)
        if command:
            os.execvpe(command[0], command, child)
        return 0
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except OSError:
        print('Unable to execute child command', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
