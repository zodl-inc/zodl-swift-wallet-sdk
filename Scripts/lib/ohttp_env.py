#!/usr/bin/env python3
"""Resolve required native OHTTP build inputs without logging values or rewriting source files."""
from __future__ import annotations

import argparse
import hashlib
import os
import sys
import unicodedata
from urllib.parse import urlsplit

OHTTP_NAMES = tuple('ZODL_OHTTP_' + suffix for suffix in (
    'GATEWAY_HOST_MAINNET', 'GATEWAY_HOST_TESTNET', 'RELAY_URL_MAINNET', 'RELAY_URL_TESTNET',
    'SIGNING_PUBKEY_MAINNET', 'SIGNING_PUBKEY_TESTNET', 'KEYS_DNS_NAME_MAINNET', 'KEYS_DNS_NAME_TESTNET'))

RELAY_NAMES = ('ZODL_OHTTP_RELAY_URL_MAINNET', 'ZODL_OHTTP_RELAY_URL_TESTNET')
HOST_NAMES = OHTTP_NAMES[:2] + OHTTP_NAMES[6:]


def validate_relay_url(name: str, value: str | None, *, required: bool) -> None:
    if value is None or value == '':
        if required:
            raise ValueError(f'{name} is required')
        return
    try:
        if any(character.isspace() or unicodedata.category(character) in ('Cc', 'Cf') for character in value):
            raise ValueError()
        parsed = urlsplit(value)
        if not value.startswith('https://') or parsed.scheme != 'https' or not parsed.hostname or parsed.username is not None or parsed.password is not None:
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


def validate_configuration(environ: dict[str, str]) -> None:
    for name in OHTTP_NAMES:
        if not isinstance(environ.get(name), str) or not environ[name]:
            raise ValueError(f'{name} is required')
        try:
            environ[name].encode('utf-8')
        except UnicodeError:
            raise ValueError(f'{name} contains invalid data') from None
        if any(unicodedata.category(character) == 'Cc' for character in environ[name]):
            raise ValueError(f'{name} contains invalid data')
        if name in HOST_NAMES:
            value = environ[name]
            # Match the core build script's bare ASCII DNS host grammar before Cargo starts.
            if not (len(value) <= 253 and all(
                    0 < len(label) <= 63 and not label.startswith('-') and not label.endswith('-')
                    and all(character.isascii() and (character.isalnum() or character == '-') for character in label)
                    for label in value.split('.'))):
                raise ValueError(f'{name} must be a bare DNS host name (no scheme, port, path or trailing dot)')
    # Match Rust's eq_ignore_ascii_case rather than Unicode case folding.
    ascii_lower = str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')
    if environ[OHTTP_NAMES[0]].translate(ascii_lower) == environ[OHTTP_NAMES[1]].translate(ascii_lower):
        raise ValueError('ZODL_OHTTP_GATEWAY_HOST_MAINNET and ZODL_OHTTP_GATEWAY_HOST_TESTNET must differ')
    for name in RELAY_NAMES:
        validate_relay_url(name, environ[name], required=True)


def resolve_ohttp_environment(environ: dict[str, str]) -> dict[str, str]:
    child = dict(environ)
    validate_configuration(child)
    return child


def configuration_hash(environ: dict[str, str]) -> str:
    validate_configuration(environ)
    digest = hashlib.sha256(b'ZODL-OHTTP-CONFIG\x00v1\x00')
    for name in OHTTP_NAMES:
        for field in (name, environ[name]):
            encoded = field.encode('utf-8')
            digest.update(len(encoded).to_bytes(8, 'big'))
            digest.update(encoded)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--hash', action='store_true', help='Print the validated configuration digest')
    mode.add_argument('--required', action='store_true')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command[:1] == ['--']:
        command = command[1:]
    try:
        child = resolve_ohttp_environment(dict(os.environ))
        if arguments.hash:
            if command:
                raise ValueError('--hash does not accept a command')
            print(configuration_hash(child))
            return 0
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
