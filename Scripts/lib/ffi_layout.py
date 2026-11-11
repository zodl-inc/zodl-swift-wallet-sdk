#!/usr/bin/env python3
"""Create and validate the ARM64 libzcashlc XCFramework layout."""
from __future__ import annotations

import argparse
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
import zlib
from xml.parsers.expat import ExpatError

SLICES = {
    "ios-arm64": ("ios", None),
    "ios-arm64-simulator": ("ios", "simulator"),
    "macos-arm64": ("macos", None),
}

# The only links a versioned macOS framework may contain, relative to the
# framework root. Everything else must be a real file or directory.
MACOS_LINKS = {
    "Versions/Current": "A",
    "libzcashlc": "Versions/Current/libzcashlc",
    "Headers": "Versions/Current/Headers",
    "Modules": "Versions/Current/Modules",
    "Resources": "Versions/Current/Resources",
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


def validate_framework(framework, allow_versioned, require_versioned=False):
    """Allow only the macOS links emitted by version-macos-framework.sh."""
    if framework.is_symlink() or not framework.is_dir():
        raise LayoutError("framework must be a real directory")
    versioned = (framework / "Versions").exists()
    links = {}
    if versioned:
        if not allow_versioned:
            raise LayoutError("only the macOS slice may be a versioned framework")
        links = MACOS_LINKS
        # A stray root plist or extra entry would make the bundle ambiguous to
        # codesign and to Xcode's validation, so the top level is exact.
        if {p.name for p in framework.iterdir()} != {"Versions", "libzcashlc", "Headers", "Modules", "Resources"}:
            raise LayoutError("unexpected top-level entries in versioned macOS framework")
        if (framework / "Versions/A").is_symlink() or not (framework / "Versions/A").is_dir():
            raise LayoutError("Versions/A must be a real directory")
        for name, target in links.items():
            path = framework / name
            if not path.is_symlink() or os.readlink(path) != target:
                raise LayoutError("unexpected versioned macOS link: " + name)
    elif require_versioned:
        raise LayoutError("macOS framework must be versioned")
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


def validate(root, require_full=False, require_versioned_macos=False):
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
        is_macos = identifier == "macos-arm64"
        validate_framework(directory / "libzcashlc.framework", is_macos, require_versioned_macos and is_macos)
    return identifiers


def install(root, wrapper, destination):
    """Stage a validated subset and replace both local paths with rollback."""
    validate(root)
    destination.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".ffi-install-", dir=str(destination)))
    backups = []
    installed = []
    cleanup = True
    try:
        staged_framework = stage / root.name
        staged_wrapper = stage / "Package.swift"
        shutil.copytree(root, staged_framework, symlinks=True)
        shutil.copy2(wrapper, staged_wrapper)
        validate(staged_framework)
        # Release products arrive with a versioned macOS framework, while a
        # product built before the Makefile versioned it is still shallow. The
        # versioner is idempotent and converts only the shallow case. Convert
        # only the staged local copy, so a failed conversion leaves the
        # installed framework untouched.
        macos = staged_framework / "macos-arm64/libzcashlc.framework"
        if macos.is_dir():
            versioner = Path(__file__).resolve().parents[1] / "version-macos-framework.sh"
            result = subprocess.run(["bash", str(versioner), str(macos)], check=False)
            if result.returncode:
                raise LayoutError("could not version the staged macOS framework")
        validate(staged_framework)
        replacements = [(staged_framework, destination / root.name),
                        (staged_wrapper, destination / "Package.swift")]
        try:
            for _, target in replacements:
                if target.exists() or target.is_symlink():
                    backup = stage / ("previous-" + target.name)
                    os.replace(target, backup)
                    backups.append((backup, target))
            for source, target in replacements:
                os.replace(source, target)
                installed.append(target)
        except BaseException:
            # Keep backups available for recovery if the filesystem also refuses rollback.
            cleanup = False
            for target in reversed(installed):
                if target.is_dir() and not target.is_symlink():
                    shutil.rmtree(target)
                else:
                    target.unlink()
            for backup, target in reversed(backups):
                os.replace(backup, target)
            cleanup = True
            raise
    finally:
        if cleanup:
            shutil.rmtree(stage)


def extract(archive, destination):
    """Unpack a release zip, admitting only the known macOS framework links."""
    root = "libzcashlc.xcframework"
    macos = PurePosixPath(root, "macos-arm64", "libzcashlc.framework")
    allowed_links = {macos / name: target for name, target in MACOS_LINKS.items()}
    try:
        source = zipfile.ZipFile(archive)
    except (OSError, zipfile.BadZipFile) as error:
        raise LayoutError("cannot read archive: " + str(archive)) from error
    with source:
        seen = set()
        regular = []
        links = []
        # Check every member before writing anything, so a rejected archive
        # leaves no partial extraction behind.
        for item in source.infolist():
            path = PurePosixPath(item.filename)
            kind = stat.S_IFMT(item.external_attr >> 16)
            if (path.is_absolute() or "\\" in item.filename or ".." in path.parts
                    or not path.parts or path.parts[0] != root or path in seen
                    or kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK)):
                raise LayoutError("unsafe or duplicate archive member: " + item.filename)
            seen.add(path)
            if kind == stat.S_IFLNK:
                # Check the name and declared size before decompressing, so a
                # hostile link member cannot make us inflate arbitrary data.
                expected = allowed_links.get(path)
                if expected is None or item.file_size != len(expected.encode("utf-8")):
                    raise LayoutError("unexpected link member: " + item.filename)
                try:
                    target = source.read(item).decode("utf-8")
                except (UnicodeDecodeError, zipfile.BadZipFile, OSError) as error:
                    raise LayoutError("unreadable link member: " + item.filename) from error
                if target != expected:
                    raise LayoutError("unexpected link member: " + item.filename)
                links.append((path, target))
            else:
                regular.append(item)
        # A shallow archive has plain directories where a versioned one has
        # links, so only the links this archive really contains claim a path.
        # Compare without case, because APFS ignores it.
        claimed = [tuple(part.lower() for part in path.parts) for path, _ in links]
        for path in seen:
            lowered = tuple(part.lower() for part in path.parts)
            if any(lowered[:len(parent)] == parent and len(lowered) > len(parent) for parent in claimed):
                raise LayoutError("unexpected member nested under a link: " + path.as_posix())
        # Links are created only after every regular member is written, so a
        # link can never redirect a later write out of the destination.
        try:
            for item in regular:
                source.extract(item, destination)
            for path, target in links:
                os.symlink(target, Path(destination, *path.parts))
        except (zipfile.BadZipFile, zlib.error) as error:
            raise LayoutError("corrupt archive member") from error


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    operations = parser.add_subparsers(dest="operation", required=True)
    create = operations.add_parser("manifest")
    create.add_argument("output", type=Path)
    create.add_argument("identifiers", nargs="*")
    check = operations.add_parser("validate")
    check.add_argument("root", type=Path)
    check.add_argument("--require-full", action="store_true")
    check.add_argument("--require-versioned-macos", action="store_true")
    local = operations.add_parser("install")
    local.add_argument("root", type=Path)
    local.add_argument("wrapper", type=Path)
    local.add_argument("destination", type=Path)
    unpack = operations.add_parser("extract")
    unpack.add_argument("archive", type=Path)
    unpack.add_argument("destination", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.operation == "manifest":
            args.output.write_bytes(plistlib.dumps(manifest(args.identifiers)))
        elif args.operation == "extract":
            extract(args.archive, args.destination)
        elif args.operation == "install":
            install(args.root, args.wrapper, args.destination)
        else:
            validate(args.root, args.require_full, args.require_versioned_macos)
    except (LayoutError, OSError, RuntimeError) as error:
        print("ffi-layout: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
