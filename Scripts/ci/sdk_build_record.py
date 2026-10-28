#!/usr/bin/env python3
"""Verify the native release command's source and record its completed build."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile
from xml.parsers.expat import ExpatError

WORKFLOW_PATH = ".github/workflows/build-ffi.yml"
TARGETS = ("clean-ffi", "ffi-all", "configure-local-ffi", "build", "test-offline")
SLICES = {
    "ios-arm64": ("ios", None, {"arm64"}),
    "ios-arm64_x86_64-simulator": ("ios", "simulator", {"arm64", "x86_64"}),
    "macos-arm64_x86_64": ("macos", None, {"arm64", "x86_64"}),
}
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")


class BuildError(ValueError):
    """A request or build cannot produce verified release evidence."""


def run(args: list[str], cwd: Path, *, capture: bool = True) -> str:
    """Native build output streams to the job log; identity output is captured."""
    try:
        result = subprocess.run(args, cwd=cwd, text=True, check=False,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None)
    except OSError as error:
        raise BuildError("could not execute " + args[0]) from error
    if result.returncode:
        # Captured Git output can include credential-bearing URLs, so never echo it.
        raise BuildError("command failed: " + args[0] + " " + args[1] + " (exit " + str(result.returncode) + ")")
    return result.stdout.strip() if capture else ""


def canonical_version(value: str) -> str:
    match = SEMVER.fullmatch(value) if isinstance(value, str) else None
    if not match or (match[4] and any(part.isdigit() and len(part) > 1 and part[0] == "0" for part in match[4].split("."))):
        raise BuildError("invalid canonical SDK semantic version")
    return value


def requested_version(value: str) -> str:
    if isinstance(value, str) and "+" in value:
        raise BuildError("unsupported build metadata in requested SDK release version")
    return canonical_version(value)


def read_plist(path: Path) -> dict:
    try:
        value = plistlib.loads(path.read_bytes())
        if not isinstance(value, dict):
            raise ValueError("expected dictionary")
        return value
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        raise BuildError("missing or malformed plist: " + path.name) from error


def table_value(text: str, table: str, key: str) -> str:
    matches = list(re.finditer(r"(?m)^\[" + re.escape(table) + r"\]\s*$", text))
    if len(matches) != 1:
        raise BuildError("ambiguous Cargo table")
    start = matches[0].end()
    end = re.search(r"(?m)^\[", text[start:])
    block = text[start:start + end.start()] if end else text[start:]
    values = re.findall(r'(?m)^' + key + r'\s*=\s*"([^"\n]+)"\s*(?:#.*)?$', block)
    if len(values) != 1:
        raise BuildError("missing or ambiguous Cargo field")
    return values[0]


def component_versions(source: Path) -> dict:
    try:
        cargo = (source / "Cargo.toml").read_text()
        if table_value(cargo, "package", "name") != "libzcashlc":
            raise BuildError("unexpected Cargo package identity")
        cargo_version = canonical_version(table_value(cargo, "package", "version"))
        lock = (source / "Cargo.lock").read_text()
        roots = []
        for block in re.findall(r"(?ms)^\[\[package\]\]\s*\n(?:(?!^\[).)*", lock):
            names = re.findall(r'(?m)^name\s*=\s*"([^"\n]+)"\s*$', block)
            if "libzcashlc" in names:
                versions = re.findall(r'(?m)^version\s*=\s*"([^"\n]+)"\s*$', block)
                if names != ["libzcashlc"] or len(versions) != 1 or re.search(r"(?m)^(source|checksum)\s*=", block):
                    raise BuildError("ambiguous Cargo.lock root package")
                roots.append(versions[0])
        if roots != [cargo_version]:
            raise BuildError("Cargo.lock root version differs from Cargo package")
        plist = read_plist(source / "BuildSupport/platform-Info.plist")
        if plist.get("CFBundleIdentifier") != "libzcashlc" or plist.get("CFBundleExecutable") != "libzcashlc":
            raise BuildError("unexpected platform plist identity")
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            if not isinstance(plist.get(key), str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", plist[key]):
                raise BuildError("invalid platform plist version")
        return {"cargo": cargo_version, "lock": roots[0], "plist_short": plist["CFBundleShortVersionString"], "plist_build": plist["CFBundleVersion"]}
    except OSError as error:
        raise BuildError("missing native component metadata") from error


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_slices(product: Path, versions: dict, source: Path) -> list[dict]:
    if product.is_symlink() or not product.is_dir() or any(path.is_symlink() for path in product.rglob("*")):
        raise BuildError("native product must be a real tree without symlinks")
    info = read_plist(product / "Info.plist")
    libraries = info.get("AvailableLibraries")
    if info.get("XCFrameworkFormatVersion") != "1.0" or info.get("CFBundlePackageType") != "XFWK" or not isinstance(libraries, list) or len(libraries) != 3:
        raise BuildError("invalid full XCFramework manifest")
    verified = []
    seen = set()
    for item in libraries:
        if not isinstance(item, dict):
            raise BuildError("invalid XCFramework slice")
        identifier = item.get("LibraryIdentifier")
        if not isinstance(identifier, str) or identifier not in SLICES or identifier in seen:
            raise BuildError("unexpected or duplicate XCFramework slice")
        seen.add(identifier)
        platform, variant, architectures = SLICES[identifier]
        actual_arches = item.get("SupportedArchitectures")
        if item.get("SupportedPlatform") != platform or item.get("SupportedPlatformVariant") != variant or item.get("LibraryPath") != "libzcashlc.framework" or not isinstance(actual_arches, list) or not all(isinstance(arch, str) for arch in actual_arches) or set(actual_arches) != architectures or len(actual_arches) != len(architectures):
            raise BuildError("invalid XCFramework slice metadata")
        framework = product / identifier / "libzcashlc.framework"
        for name in ("libzcashlc", "Headers/zcashlc.h", "Modules/module.modulemap", "Info.plist"):
            path = framework / name
            if not path.is_file() or path.stat().st_size == 0:
                raise BuildError("missing/nonempty framework binary, headers or modules")
        actual = run(["lipo", "-archs", str(framework / "libzcashlc")], source).split()
        if set(actual) != architectures or len(actual) != len(architectures):
            raise BuildError("actual binary architectures do not match full slice")
        module = (framework / "Modules/module.modulemap").read_text()
        if not re.search(r"\bmodule\s+libzcashlc\b", module) or "zcashlc.h" not in module:
            raise BuildError("invalid libzcashlc module map")
        plist = read_plist(framework / "Info.plist")
        if plist.get("CFBundleIdentifier") != "libzcashlc" or plist.get("CFBundleExecutable") != "libzcashlc" or plist.get("CFBundleShortVersionString") != versions["plist_short"] or plist.get("CFBundleVersion") != versions["plist_build"]:
            raise BuildError("framework plist differs from immutable source metadata")
        verified.append({"identifier": identifier, "platform": platform, "variant": variant,
                         "architectures": sorted(actual), "binary_sha256": sha256(framework / "libzcashlc")})
    return verified


def capture_source(root: Path, expected: str | None) -> dict:
    """Capture one clean immutable checkout before native compilation starts."""
    if Path(run(["git", "rev-parse", "--show-toplevel"], root)).resolve() != root.resolve():
        raise BuildError("source must be the repository root")
    commit = run(["git", "rev-parse", "HEAD"], root)
    tree = run(["git", "rev-parse", "HEAD^{tree}"], root)
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(r"[0-9a-f]{40}", tree):
        raise BuildError("invalid source commit/tree")
    if expected is not None and (not re.fullmatch(r"[0-9a-f]{40}", expected) or expected != commit):
        raise BuildError("source commit differs from expected source")
    identity = {"source_commit": commit, "source_tree": tree}
    check_source(root, identity)
    return identity


def check_source(root: Path, identity: dict) -> None:
    """Refuse source changes before a later stage or remote write."""
    if (run(["git", "rev-parse", "HEAD"], root) != identity["source_commit"] or
            run(["git", "rev-parse", "HEAD^{tree}"], root) != identity["source_tree"]):
        raise BuildError("source commit/tree changed during native build")
    if run(["git", "status", "--porcelain", "--untracked-files=normal"], root):
        raise BuildError("source checkout must be clean")


def execution_identity(repository: str, source_commit: str) -> dict:
    request = os.environ.get("ZODL_SDK_REQUEST_ID") or None
    if request is not None and not re.fullmatch(r"[0-9a-f]{32}", request):
        raise BuildError("invalid request ID")
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return {"backend": "local", "request_id": request, "workflow": None}
    if os.environ.get("GITHUB_REPOSITORY") != repository or os.environ.get("GITHUB_SHA") != source_commit:
        raise BuildError("Actions repository/source differs from native checkout")
    ref = os.environ.get("GITHUB_WORKFLOW_REF", "")
    prefix = repository + "/" + WORKFLOW_PATH + "@"
    selected = ref[len(prefix):] if ref.startswith(prefix) else ""
    if not selected.startswith(("refs/heads/", "refs/tags/")) or subprocess.run(
            ["git", "check-ref-format", selected], capture_output=True).returncode:
        raise BuildError("invalid Actions workflow reference")
    sha = os.environ.get("GITHUB_WORKFLOW_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise BuildError("invalid Actions workflow SHA")
    workflow = {"path": WORKFLOW_PATH, "ref": ref, "sha": sha}
    for field, variable in (("run_id", "GITHUB_RUN_ID"), ("run_attempt", "GITHUB_RUN_ATTEMPT")):
        value = os.environ.get(variable, "")
        if not re.fullmatch(r"[1-9][0-9]*", value):
            raise BuildError("invalid Actions run identity")
        workflow[field] = int(value)
    return {"backend": "github-actions", "request_id": request, "workflow": workflow}


def finish_record(root: Path, archive: Path, context: dict, destination: Path) -> dict:
    """Bind the existing ZIP bytes to verified slices and successful native stages."""
    check_source(root, context)
    if context["commands"] != [["make", target] for target in TARGETS]:
        raise BuildError("native build/test stages are incomplete")
    versions = component_versions(root)
    if versions != context["component_versions"]:
        raise BuildError("native component versions changed")
    product = root / "BuildSupport/products/libzcashlc.xcframework"
    slices = verify_slices(product, versions, root)
    if archive.name != "libzcashlc.xcframework.zip" or archive.is_symlink() or not archive.is_file():
        raise BuildError("missing native release archive")
    expected = {str(path.relative_to(product.parent)): path for path in product.rglob("*") if path.is_file()}
    with zipfile.ZipFile(archive) as bundle:
        files = [item for item in bundle.infolist() if not item.is_dir()]
        if len(files) != len(expected) or {item.filename for item in files} != set(expected):
            raise BuildError("archive contents differ from verified native product")
        for item in files:
            if hashlib.sha256(bundle.read(item)).hexdigest() != sha256(expected[item.filename]):
                raise BuildError("archive bytes differ from verified native product")
    toolchains = {
        "swift": run(["make", "--no-print-directory", "print-swift-version"], root),
        "cargo": run(["cargo", "+stable", "--version", "--verbose"], root),
        "rustc": run(["rustc", "+stable", "--version", "--verbose"], root),
        "xcode": run(["xcodebuild", "-version", "-skipMacroValidation", "-derivedDataPath", str(root / "DerivedData")], root),
    }
    if not all(toolchains.values()):
        raise BuildError("missing compiler identity")
    proof = {key: context[key] for key in ("repository", "version", "source_commit", "source_tree", "component_versions", "commands", "execution")}
    proof.update(schema_version=1, kind="zodl-sdk-native-build", slices=slices, toolchains=toolchains,
                 artifact={"name": archive.name, "size": archive.stat().st_size, "sha256": sha256(archive)})
    check_source(root, context)
    temporary = destination.with_suffix(".tmp")
    temporary.write_text(json.dumps(proof, indent=2, sort_keys=True) + "\n")
    temporary.replace(destination)
    return proof


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("begin", "check", "finish"))
    parser.add_argument("context", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--command", choices=TARGETS)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args(argv)
    root = Path.cwd()
    try:
        if args.version is not None:
            requested_version(args.version)
        if args.operation == "begin":
            version = requested_version(args.version)
            identity = capture_source(root, os.environ.get("ZODL_SDK_EXPECTED_SOURCE") or None)
            repository = os.environ.get("GH_REPO", "")
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
                raise BuildError("invalid native build repository")
            versions = component_versions(root)
            if versions["cargo"] != version or versions["plist_short"] != re.split(r"[-+]", version, maxsplit=1)[0]:
                raise BuildError("source component version differs from requested release")
            context = dict(identity, repository=repository, version=version, component_versions=versions,
                           commands=[], execution=execution_identity(repository, identity["source_commit"]))
        else:
            context = json.loads(args.context.read_text())
            requested_version(context["version"])
            check_source(root, context)
            if args.operation == "finish":
                if args.archive is None or args.destination is None:
                    raise BuildError("finish requires archive and destination")
                finish_record(root, args.archive, context, args.destination)
                return 0
            if args.command:
                position = len(context["commands"])
                if position >= len(TARGETS) or args.command != TARGETS[position]:
                    raise BuildError("native stages ran out of order")
                product = root / "BuildSupport/products/libzcashlc.xcframework"
                if args.command == "clean-ffi" and (product.exists() or product.is_symlink()):
                    raise BuildError("stale native product survived clean-ffi")
                context["commands"].append(["make", args.command])
        args.context.write_text(json.dumps(context) + "\n")
        return 0
    except (BuildError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print("SDK native build record failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
