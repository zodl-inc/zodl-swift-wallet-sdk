#!/usr/bin/env python3
"""Create and validate the ARM64 libzcashlc XCFramework layout."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from xml.parsers.expat import ExpatError

SLICES = {
    "ios-arm64": ("ios", None),
    "ios-arm64-simulator": ("ios", "simulator"),
    "macos-arm64": ("macos", None),
}


class LayoutError(ValueError):
    """The bundle cannot be used as an ARM64 local or release product."""


def manifest(identifiers):
    """Describe exactly one nonempty canonical subset, in the requested order."""
    if not identifiers or len(set(identifiers)) != len(identifiers) or any(i not in SLICES for i in identifiers):
        raise LayoutError("expected unique canonical ARM64 slice identifiers")
    libraries = []
    for identifier in identifiers:
        platform, variant = SLICES[identifier]
        item = dict(LibraryIdentifier=identifier, LibraryPath="libzcashlc.framework",
                    SupportedArchitectures=["arm64"], SupportedPlatform=platform)
        if variant:
            item["SupportedPlatformVariant"] = variant
        libraries.append(item)
    return dict(AvailableLibraries=libraries, CFBundlePackageType="XFWK", XCFrameworkFormatVersion="1.0")


def read_plist(path):
    try:
        value = plistlib.loads(path.read_bytes())
        if not isinstance(value, dict):
            raise ValueError("expected dictionary")
        return value
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        raise LayoutError("missing or malformed plist: " + str(path)) from error


def validate_framework(framework, allow_versioned):
    """Allow only the local macOS links emitted by version-macos-framework.sh."""
    if framework.is_symlink() or not framework.is_dir():
        raise LayoutError("framework must be a real directory")
    versioned = (framework / "Versions").exists()
    links = {}
    if versioned:
        if not allow_versioned:
            raise LayoutError("versioned macOS framework requires explicit opt-in")
        links = {"Versions/Current": "A"}
        links.update({name: "Versions/Current/" + name for name in ("libzcashlc", "Headers", "Modules", "Resources")})
        for name, target in links.items():
            path = framework / name
            if not path.is_symlink() or os.readlink(path) != target:
                raise LayoutError("unexpected versioned macOS link: " + name)
    for path in framework.rglob("*"):
        if path.is_symlink():
            relative = str(path.relative_to(framework))
            if relative not in links or os.readlink(path) != links[relative]:
                raise LayoutError("unsafe framework symlink")
            try:
                path.resolve(strict=True).relative_to(framework.resolve())
            except (OSError, ValueError, RuntimeError) as error:
                raise LayoutError("framework link escapes or has no target") from error
    plist_path = "Resources/Info.plist" if versioned else "Info.plist"
    for name in ("libzcashlc", "Headers/zcashlc.h", "Modules/module.modulemap", plist_path):
        path = framework / name
        if not path.is_file() or path.stat().st_size == 0:
            raise LayoutError("missing or empty required framework file: " + name)
    read_plist(framework / plist_path)
    try:
        result = subprocess.run(["lipo", "-archs", str(framework / "libzcashlc")],
                                capture_output=True, text=True, check=False)
    except OSError as error:
        raise LayoutError("could not execute lipo") from error
    if result.returncode or result.stdout.split() != ["arm64"]:
        raise LayoutError("actual binary architectures must be exactly arm64")


def validate(root, require_full=False, allow_versioned_macos=False):
    """Verify metadata, physical slice inventory, required files and binary archs."""
    if root.is_symlink() or not root.is_dir():
        raise LayoutError("XCFramework must be a real directory")
    info_path = root / "Info.plist"
    if info_path.is_symlink():
        raise LayoutError("manifest must be a real file")
    info = read_plist(info_path)
    libraries = info.get("AvailableLibraries")
    if info.get("CFBundlePackageType") != "XFWK" or info.get("XCFrameworkFormatVersion") != "1.0" or not isinstance(libraries, list) or not libraries:
        raise LayoutError("invalid or empty XCFramework manifest")
    identifiers = []
    for item in libraries:
        if not isinstance(item, dict) or not isinstance(item.get("LibraryIdentifier"), str):
            raise LayoutError("malformed slice declaration")
        identifier = item["LibraryIdentifier"]
        if identifier not in SLICES or identifier in identifiers:
            raise LayoutError("unexpected or duplicate slice declaration")
        identifiers.append(identifier)
        expected = manifest([identifier])["AvailableLibraries"][0]
        if any(item.get(key) != value for key, value in expected.items()) or item.get("SupportedPlatformVariant") != SLICES[identifier][1]:
            raise LayoutError("slice metadata does not match canonical ARM64 layout")
    if require_full and set(identifiers) != set(SLICES):
        raise LayoutError("full product requires all three ARM64 slices")
    if {p.name for p in root.iterdir() if p.is_dir() or p.is_symlink()} != set(identifiers):
        raise LayoutError("undeclared or missing slice directories")
    for identifier in identifiers:
        directory = root / identifier
        if directory.is_symlink() or {p.name for p in directory.iterdir()} != {"libzcashlc.framework"}:
            raise LayoutError("unexpected slice contents")
        validate_framework(directory / "libzcashlc.framework", allow_versioned_macos and identifier == "macos-arm64")
    return identifiers


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    operations = parser.add_subparsers(dest="operation", required=True)
    create = operations.add_parser("manifest")
    create.add_argument("output", type=Path)
    create.add_argument("identifiers", nargs="*")
    check = operations.add_parser("validate")
    check.add_argument("root", type=Path)
    check.add_argument("--require-full", action="store_true")
    check.add_argument("--allow-versioned-macos", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.operation == "manifest":
            args.output.write_bytes(plistlib.dumps(manifest(args.identifiers)))
        else:
            validate(args.root, args.require_full, args.allow_versioned_macos)
    except (LayoutError, OSError, RuntimeError) as error:
        print("ffi-layout: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
