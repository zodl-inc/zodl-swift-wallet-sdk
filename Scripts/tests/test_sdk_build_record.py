"""Native artifacts-command integration with real Git and external process doubles."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ["clean-ffi", "ffi-all", "configure-local-ffi", "build", "test-offline"]
NATIVE_DOUBLE = '''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path.cwd()
if name == "make":
    with open(os.environ["NATIVE_LOG"], "a") as log:
        log.write(json.dumps({"cwd": str(root), "argv": sys.argv}) + "\\n")
    target = sys.argv[-1]
    if os.environ.get("FAIL_TARGET") == target:
        print("native step failed", file=sys.stderr)
        sys.exit(9)
    product = root / "BuildSupport/products/libzcashlc.xcframework"
    if target == "clean-ffi":
        if not os.environ.get("KEEP_STALE"):
            shutil.rmtree(product, ignore_errors=True)
    if target == "configure-local-ffi":
        (root / "LocalPackages").mkdir(exist_ok=True)
    if os.environ.get("MUTATE_STAGE") == target:
        (root / "Cargo.toml").write_text("mutated source")
    if target == "test-offline" and os.environ.get("FAIL_RECORD_WRITE"):
        (root / "BuildSupport/products/sdk-build-record.json").mkdir()
    if target == "ffi-all":
        slices = {
            "ios-arm64": ("ios", None, ["arm64"]),
            "ios-arm64_x86_64-simulator": ("ios", "simulator", ["arm64", "x86_64"]),
            "macos-arm64_x86_64": ("macos", None, ["arm64", "x86_64"]),
        }
        libraries = []
        for identifier, (platform, variant, arches) in slices.items():
            if os.environ.get("MISSING_SLICE") == identifier:
                continue
            framework = product / identifier / "libzcashlc.framework"
            (framework / "Headers").mkdir(parents=True)
            (framework / "Modules").mkdir()
            (framework / "libzcashlc").write_text(" ".join(arches))
            (framework / "Headers/zcashlc.h").write_text("void fixture(void);\\n")
            (framework / "Modules/module.modulemap").write_text('module libzcashlc { header "zcashlc.h" }\\n')
            shutil.copyfile(root / "BuildSupport/platform-Info.plist", framework / "Info.plist")
            libraries.append(dict(LibraryIdentifier=identifier, LibraryPath="libzcashlc.framework",
                                  SupportedPlatform=platform, SupportedArchitectures=arches))
            if variant:
                libraries[-1]["SupportedPlatformVariant"] = variant
        (product / "Info.plist").write_bytes(plistlib.dumps(dict(
            XCFrameworkFormatVersion="1.0", CFBundlePackageType="XFWK", AvailableLibraries=libraries)))
        if os.environ.get("SYMLINK_PRODUCT"):
            (product / "extra").symlink_to(root / "Cargo.toml")
        broken = os.environ.get("BROKEN_PRODUCT")
        framework = product / "ios-arm64/libzcashlc.framework"
        if broken == "header":
            (framework / "Headers/zcashlc.h").write_text("")
        if broken == "module":
            (framework / "Modules/module.modulemap").write_text("module wrong {}")
        if broken == "plist":
            (framework / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "999"}))
        if os.environ.get("WRONG_ARCH"):
            (product / "ios-arm64/libzcashlc.framework/libzcashlc").write_text("x86_64")
        if os.environ.get("MUTATE_SOURCE") == target:
            (root / "Cargo.toml").write_text("changed by build")
        if os.environ.get("CHANGE_COMMIT"):
            subprocess = __import__("subprocess")
            subprocess.run(["git", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "changed"], check=True)
    if os.environ.get("NATIVE_REAL_MAKE") and target in ("build", "test-offline", "print-swift-version"):
        os.execv("/usr/bin/make", ["/usr/bin/make", *sys.argv[1:]])
    if target == "print-swift-version":
        print("swift fixture compiler identity\\ncomplete compiler/build details")
elif name == "lipo":
    print(pathlib.Path(sys.argv[-1]).read_text())
else:
    print(name + " fixture compiler identity\\ncomplete compiler/build details")
'''
GH_DOUBLE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
if args[:2] == ["auth", "status"]:
    sys.exit(0)
if args[:2] == ["release", "view"]:
    if not os.environ.get("RELEASE_EXISTS"):
        sys.exit(1)
    if "--json" in args:
        print("false" if os.environ.get("PUBLISHED") else "true")
    sys.exit(0)
if args[:2] == ["release", "upload"]:
    if os.environ.get("FAIL_RECORD_UPLOAD") and any("sdk-build-record.json" in a for a in args):
        sys.exit(9)
    sys.exit(0)
if args[:2] in (["release", "create"], ["release", "edit"]):
    if os.environ.get("FAIL_UPLOAD"):
        sys.exit(9)
    sys.exit(0)
sys.exit(10)
'''

class NativeRecordTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.log = self.root / "make.jsonl"
        self.ghlog = self.root / "gh.jsonl"
        for tool in ("make", "lipo", "swift", "cargo", "rustc", "xcodebuild", "gh"):
            path = self.tools / tool
            path.write_text(GH_DOUBLE if tool == "gh" else NATIVE_DOUBLE)
            path.chmod(0o755)
        for relative in ("Makefile", "Scripts/prepare-release.sh", "Scripts/release.sh", "Scripts/lib/release-lib.sh", "Scripts/ci/sdk_build_record.py"):
            source = ROOT / relative
            if source.exists():
                target = self.source / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(source, target)
        (self.source / "BuildSupport").mkdir()
        (self.source / "Cargo.toml").write_text('[package]\nname = "libzcashlc"\nversion = "5.0.0"\n')
        (self.source / "Cargo.lock").write_text('version = 3\n\n[[package]]\nname = "libzcashlc"\nversion = "5.0.0"\n')
        (self.source / "BuildSupport/platform-Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "libzcashlc", "CFBundleExecutable": "libzcashlc",
            "CFBundleShortVersionString": "5.0.0", "CFBundleVersion": "42"}))
        (self.source / ".gitignore").write_text("BuildSupport/products/\nLocalPackages/\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Tests")
        self.git("config", "user.email", "tests@example.invalid")
        self.commit()
        self.head = self.git("rev-parse", "HEAD")
        self.tree = self.git("rev-parse", "HEAD^{tree}")
        self.products = self.source / "BuildSupport/products"

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.source, text=True).strip()

    def commit(self):
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "fixture")

    def artifacts(self, *flags, record=True, expected_source=None, **env):
        environment = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "ZODL_SDK_")) and k not in ("GH_REPO", "SWIFT", "MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
        environment.update(PATH=str(self.tools) + os.pathsep + environment["PATH"], NATIVE_LOG=str(self.log), GH_LOG=str(self.ghlog))
        if record:
            environment["ZODL_SDK_BUILD_RECORD"] = "1"
        if expected_source:
            environment["ZODL_SDK_EXPECTED_SOURCE"] = expected_source
        environment.update(env)
        return subprocess.run(["bash", "Scripts/prepare-release.sh", "artifacts", *flags, "5.0.0"], cwd=self.source, env=environment, text=True, capture_output=True)

    def make_calls(self):
        return [args for args in self.all_make_calls() if args != ["--no-print-directory", "print-swift-version"]]

    def all_make_calls(self):
        return [json.loads(line)["argv"][1:] for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def swift_fixtures(self):
        self.swiftlog = self.root / "swift.jsonl"
        for name in ("swift", "environment-swift", "assignment-swift"):
            compiler = self.tools / name
            compiler.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
with open(os.environ["SWIFT_LOG"], "a") as log:
    log.write(json.dumps([pathlib.Path(sys.argv[0]).name, *sys.argv[1:]]) + "\\n")
if sys.argv[1:] == ["--version"]:
    mode = os.environ.get("SWIFT_IDENTITY_MODE") if pathlib.Path(sys.argv[0]).name == "environment-swift" else None
    if mode == "failure":
        print("identity unavailable", file=sys.stderr)
        sys.exit(7)
    if mode != "empty":
        print(pathlib.Path(sys.argv[0]).name + " compiler version\\ncomplete compiler/build details")
''')
            compiler.chmod(0o755)
        return dict(NATIVE_REAL_MAKE="1", SWIFT_LOG=str(self.swiftlog))

    def swift_calls(self):
        return [json.loads(line) for line in self.swiftlog.read_text().splitlines()]

    def gh_calls(self):
        return [json.loads(line) for line in self.ghlog.read_text().splitlines()] if self.ghlog.exists() else []

    def record(self):
        path = self.products / "sdk-build-record.json"
        self.assertTrue(path.is_file(), "native build must produce sdk-build-record.json")
        return json.loads(path.read_text())

    def assert_no_release_write(self):
        self.assertFalse(any(c[:2] in (["release", "create"], ["release", "upload"], ["release", "edit"]) for c in self.gh_calls()))

    def policy_environment(self):
        environment = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "ZODL_SDK_")) and k != "GH_REPO"}
        environment.update(PATH=str(self.tools) + os.pathsep + environment["PATH"], NATIVE_LOG=str(self.log), GH_LOG=str(self.ghlog), GH_REPO="owner/sdk")
        real_git = shutil.which("git")
        sentinel = self.tools / "git"
        sentinel.write_text("#!/bin/bash\nif [ \"$*\" = \"rev-parse --show-toplevel\" ]; then exec " + real_git + " \"$@\"; fi\nprintf '%s\\n' \"$*\" >> \"$GH_LOG\"\nexit 91\n")
        sentinel.chmod(0o755)
        return environment

    def source_snapshot(self):
        return {str(p.relative_to(self.source)): p.read_bytes() for p in self.source.rglob("*") if p.is_file()}

    def test_metadata_requests_stop_before_operational_preflight(self):
        environment = self.policy_environment()
        self.products.mkdir(parents=True)
        (self.products / "sdk-build-record.json").write_bytes(b"existing evidence\n")
        (self.products / "release.env").write_bytes(b"existing completion\n")
        before = self.source_snapshot()
        commands = [
            ["Scripts/prepare-release.sh", "start", "--issue", "1", "upstream"],
            ["Scripts/prepare-release.sh", "build", "--artifacts", "local", "upstream"],
            ["Scripts/prepare-release.sh", "build", "--artifacts", "ci", "upstream"],
            ["Scripts/prepare-release.sh", "artifacts"],
            ["Scripts/release.sh", "upstream"],
        ]
        for version in ("5.0.0+build.1", "5.0.0-rc.1+build.1"):
            for command in commands:
                for dry in ([], ["--dry-run"]):
                    for evidence in ("0", "1"):
                        with self.subTest(version=version, command=command, dry=dry, evidence=evidence):
                            # release.sh requires options before the positionals.
                            argv = ["bash", command[0], *dry, *command[1:], version] if command[0].endswith("/release.sh") else ["bash", *command, *dry, version]
                            result = subprocess.run(argv, cwd=self.source, env=dict(environment, ZODL_SDK_BUILD_RECORD=evidence), text=True, capture_output=True)
                            self.assertNotEqual(result.returncode, 0)
                            self.assertIn("unsupported build metadata", result.stderr.lower())
                            self.assertEqual(self.make_calls(), [])
                            self.assertEqual(self.gh_calls(), [])
                            self.assertEqual(self.source_snapshot(), before)

    def test_record_explicit_metadata_request_precedes_context_reads(self):
        environment = self.policy_environment()
        for operation in ("begin", "check", "finish"):
            with self.subTest(operation=operation):
                result = subprocess.run(["python3", "Scripts/ci/sdk_build_record.py", operation, str(self.root / "missing.json"), "--version", "5.0.0+build.1"], cwd=self.source, env=environment, text=True, capture_output=True)
                self.assertIn("unsupported build metadata", result.stderr.lower())
                self.assertEqual(self.gh_calls(), [])

    def test_record_metadata_requests_preserve_context_and_evidence(self):
        environment = self.policy_environment()
        context = self.root / "context.json"
        destination = self.root / "record.json"
        for version in ("5.0.0+build.1", "5.0.0-rc.1+build.1"):
            for operation in ("begin", "check", "finish"):
                for existing in (False, True):
                    with self.subTest(version=version, operation=operation, existing=existing):
                        context.unlink(missing_ok=True)
                        if existing or operation != "begin":
                            context.write_text(json.dumps(dict(version=version)) + "\n")
                        destination.write_bytes(b"immutable existing evidence\n")
                        before = context.read_bytes() if context.exists() else None
                        result = subprocess.run(["python3", "Scripts/ci/sdk_build_record.py", operation, str(context), "--version", version, "--archive", str(self.root / "missing.zip"), "--destination", str(destination)], cwd=self.source, env=environment, text=True, capture_output=True)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("unsupported build metadata", result.stderr.lower())
                        self.assertEqual(context.read_bytes() if context.exists() else None, before)
                        self.assertEqual(destination.read_bytes(), b"immutable existing evidence\n")
                        self.assertEqual(self.gh_calls(), [])
                        if operation != "begin":
                            # Resume must validate the saved version even without --version.
                            resumed = subprocess.run(["python3", "Scripts/ci/sdk_build_record.py", operation, str(context)], cwd=self.source, env=environment, text=True, capture_output=True)
                            self.assertIn("unsupported build metadata", resumed.stderr.lower())
                            self.assertEqual(context.read_bytes(), before)

    def test_expected_source_mismatch_stops_before_native_make(self):
        result = self.artifacts(expected_source="f" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])
        self.assert_no_release_write()

    def test_native_record_binds_actual_archive_and_source(self):
        result = self.artifacts(expected_source=self.head, ZODL_SDK_REQUEST_ID="c" * 32)
        self.assertEqual(result.returncode, 0, result.stderr)
        proof = self.record()
        self.assertEqual(proof["source_commit"], self.head)
        self.assertEqual(proof["source_tree"], self.tree)
        self.assertEqual(proof["kind"], "zodl-sdk-native-build")
        self.assertEqual(proof["schema_version"], 1)
        archive = self.products / "libzcashlc.xcframework.zip"
        self.assertEqual(proof["artifact"], dict(name=archive.name, size=archive.stat().st_size, sha256=hashlib.sha256(archive.read_bytes()).hexdigest()))
        self.assertEqual(self.make_calls(), [[target] for target in TARGETS])
        self.assertEqual(proof["commands"], [["make", target] for target in TARGETS])
        self.assertEqual(proof["component_versions"], dict(cargo="5.0.0", lock="5.0.0", plist_short="5.0.0", plist_build="42"))
        self.assertEqual(len(proof["slices"]), 3)
        self.assertEqual(proof["execution"], dict(backend="local", request_id="c"*32, workflow=None))
        self.assertTrue(all(proof["toolchains"].values()))
        self.assertFalse((self.source / "LocalPackages").exists())
        self.assertTrue(any(c[:2] == ["release", "upload"] and any("sdk-build-record.json" in a for a in c) for c in self.gh_calls()))
        self.assertTrue((self.products / "release.env").is_file())

    def test_make_swift_identity_target_is_quiet_and_read_only(self):
        environment = {key: value for key, value in os.environ.items() if key not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
        environment.update(self.swift_fixtures(), SWIFT=str(self.tools / "environment-swift"))
        before = self.source_snapshot()
        result = subprocess.run(["/usr/bin/make", "--no-print-directory", "print-swift-version"],
                                cwd=self.source, env=environment, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "environment-swift compiler version\ncomplete compiler/build details\n")
        self.assertEqual(self.source_snapshot(), before)
        self.assertEqual(self.swift_calls(), [["environment-swift", "--version"]])

    def assert_selected_swift(self, selected, **environment):
        result = self.artifacts(**self.swift_fixtures(), **environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.swift_calls()[:2], [[selected, "build"], [selected, "test", "--filter", "OfflineTests"]])
        self.assertEqual(self.record()["toolchains"]["swift"], selected + " compiler version\ncomplete compiler/build details")
        self.assertEqual(self.swift_calls(), [[selected, "build"], [selected, "test", "--filter", "OfflineTests"], [selected, "--version"]])
        self.assertEqual(self.make_calls(), [[target] for target in TARGETS])
        self.assertEqual(self.all_make_calls(), [[target] for target in TARGETS] + [["--no-print-directory", "print-swift-version"]])
        self.assertEqual(self.record()["commands"], [["make", target] for target in TARGETS])

    def test_record_uses_default_make_swift(self):
        self.assert_selected_swift("swift")

    def test_record_uses_environment_selected_make_swift(self):
        self.assert_selected_swift("environment-swift", SWIFT=str(self.tools / "environment-swift"))

    def test_record_uses_make_assignment_over_conflicting_environment_swift(self):
        self.assert_selected_swift("assignment-swift", SWIFT=str(self.tools / "environment-swift"),
                                   MAKEFLAGS="SWIFT=" + str(self.tools / "assignment-swift"))

    def test_bad_make_swift_identity_stops_before_create_or_draft_overwrite(self):
        environment = self.swift_fixtures()
        for mode in ("failure", "empty"):
            for existing in (False, True):
                with self.subTest(mode=mode, existing=existing):
                    self.log.unlink(missing_ok=True)
                    self.ghlog.unlink(missing_ok=True)
                    self.swiftlog.unlink(missing_ok=True)
                    flags = ["--force-overwrite-existing-release"] if existing else []
                    result = self.artifacts(*flags, **environment, SWIFT=str(self.tools / "environment-swift"),
                                            SWIFT_IDENTITY_MODE=mode, RELEASE_EXISTS="1" if existing else "")
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("command failed: make" if mode == "failure" else "missing compiler identity", result.stderr)
                    self.assertEqual(self.make_calls(), [[target] for target in TARGETS])
                    self.assertEqual(self.swift_calls(), [["environment-swift", "build"], ["environment-swift", "test", "--filter", "OfflineTests"], ["environment-swift", "--version"]])
                    self.assertTrue((self.products / "libzcashlc.xcframework.zip").is_file())
                    self.assertFalse((self.products / "sdk-build-record.json").exists())
                    self.assertFalse((self.products / "release.env").exists())
                    self.assert_no_release_write()

    def test_record_disabled_keeps_native_make_build_without_identity_query(self):
        result = self.artifacts(record=False, **self.swift_fixtures(),
                                SWIFT=str(self.tools / "environment-swift"), SWIFT_IDENTITY_MODE="failure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.swift_calls(), [["environment-swift", "build"], ["environment-swift", "test", "--filter", "OfflineTests"]])
        self.assertEqual(self.all_make_calls(), [[target] for target in TARGETS])
        self.assertFalse((self.products / "sdk-build-record.json").exists())
        self.assertTrue((self.products / "release.env").is_file())

    def test_mutation_after_every_native_stage_stops_before_upload(self):
        for stage in TARGETS:
            with self.subTest(stage=stage):
                result = self.artifacts(MUTATE_STAGE=stage)
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_release_write()
                self.git("checkout", "--", "Cargo.toml")
                self.log.unlink(missing_ok=True)

    def test_commit_movement_stops_before_upload(self):
        result = self.artifacts(CHANGE_COMMIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_incomplete_slice_is_rejected(self):
        result = self.artifacts(MISSING_SLICE="ios-arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_binary_architecture_is_verified(self):
        result = self.artifacts(WRONG_ARCH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_symlink_product_is_rejected(self):
        result = self.artifacts(SYMLINK_PRODUCT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_component_version_mismatch_stops_before_make(self):
        (self.source / "Cargo.lock").write_text('[[package]]\nname = "libzcashlc"\nversion = "4.0.0"\n')
        self.commit()
        result = self.artifacts()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])

    def test_proof_refuses_verification_bypass(self):
        for flag in ("--skip-verify", "--dry-run"):
            with self.subTest(flag=flag):
                result = self.artifacts(flag)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.make_calls(), [])

    def test_failed_record_upload_does_not_write_completion(self):
        result = self.artifacts(FAIL_RECORD_UPLOAD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.products / "release.env").exists())

    def test_failed_archive_upload_does_not_write_completion(self):
        result = self.artifacts(FAIL_UPLOAD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.products / "release.env").exists())

    def test_failed_native_stage_does_not_upload(self):
        result = self.artifacts(FAIL_TARGET="test-offline")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_actions_identity_and_private_storage(self):
        repo = "owner/sdk-private"
        result = self.artifacts(GITHUB_ACTIONS="true", GITHUB_REPOSITORY=repo, GITHUB_SHA=self.head,
            GITHUB_WORKFLOW_REF=repo+"/.github/workflows/build-ffi.yml@refs/heads/candidate/5.0.0",
            GITHUB_WORKFLOW_SHA=self.head, GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        proof = self.record()
        self.assertEqual(proof["repository"], repo)
        self.assertEqual(proof["execution"]["workflow"], dict(path=".github/workflows/build-ffi.yml", ref=repo+"/.github/workflows/build-ffi.yml@refs/heads/candidate/5.0.0", sha=self.head, run_id=123, run_attempt=2))
        self.assertEqual(proof["execution"]["backend"], "github-actions")

    def test_actions_checkout_must_match_dispatch_sha(self):
        result = self.artifacts(GITHUB_ACTIONS="true", GITHUB_REPOSITORY="owner/sdk", GITHUB_SHA="f"*40)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])

    def test_invalid_request_identity_stops_before_make(self):
        result = self.artifacts(ZODL_SDK_REQUEST_ID="not-hex")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])

    def test_existing_local_packages_is_retained(self):
        (self.source / "LocalPackages").mkdir()
        result = self.artifacts()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.source / "LocalPackages").exists())

    def test_legacy_skip_verify_and_default_repository(self):
        result = self.artifacts("--skip-verify", record=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.make_calls(), [["clean-ffi"], ["ffi-all"]])
        self.assertFalse((self.products / "sdk-build-record.json").exists())
        self.assertTrue(any("zodl-inc/zodl-swift-wallet-sdk" in c for c in self.gh_calls()))

    def test_fork_storage_remains_supported(self):
        result = self.artifacts(GH_REPO="developer/sdk")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.record()["repository"], "developer/sdk")

    def test_published_release_cannot_be_overwritten(self):
        result = self.artifacts("--force-overwrite-existing-release", RELEASE_EXISTS="1", PUBLISHED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])
        self.assert_no_release_write()

    def test_manual_force_retains_draft_replacement(self):
        result = self.artifacts("--force-overwrite-existing-release", RELEASE_EXISTS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(c[:2] == ["release", "upload"] and "--clobber" in c for c in self.gh_calls()))

    def test_dirty_source_stops_before_make(self):
        (self.source / "Cargo.toml").write_text("dirty")
        result = self.artifacts()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [])
        self.assert_no_release_write()

    def test_stale_product_must_not_survive_clean(self):
        (self.products / "libzcashlc.xcframework").mkdir(parents=True)
        result = self.artifacts(KEEP_STALE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.make_calls(), [["clean-ffi"]])
        self.assert_no_release_write()

    def test_failed_record_write_stops_before_upload(self):
        result = self.artifacts(FAIL_RECORD_WRITE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.products / "release.env").exists())
        self.assert_no_release_write()

    def test_broken_framework_files_stop_before_upload(self):
        for broken in ("header", "module", "plist"):
            with self.subTest(broken=broken):
                result = self.artifacts(BROKEN_PRODUCT=broken)
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_release_write()

    def test_archive_must_match_verified_product(self):
        zip_tool = self.tools / "zip"
        zip_tool.write_text("#!/usr/bin/env python3\nimport subprocess, sys, zipfile\nsubprocess.run(['/usr/bin/zip', *sys.argv[1:]], check=True)\nwith zipfile.ZipFile(sys.argv[2], 'a') as bundle:\n    bundle.writestr('unexpected.txt', 'unrelated bytes')\n")
        zip_tool.chmod(0o755)
        result = self.artifacts()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_release_write()

    def test_duplicate_producer_removed(self):
        for path in (".github/workflows/sdk-release-build.yml", "Scripts/ci/build-sdk-release.py", "Scripts/ci/sdk_release_build.py"):
            self.assertFalse((ROOT / path).exists(), path)

class RequestVersionTests(unittest.TestCase):
    def test_request_policy_preserves_historical_parsing_and_prereleases(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("request_record", ROOT / "Scripts/ci/sdk_build_record.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for version in ("5.0.0+build.1", "5.0.0-rc.1+build.1"):
            self.assertEqual(module.canonical_version(version), version)
            with self.assertRaisesRegex(module.BuildError, "unsupported build metadata"):
                module.requested_version(version)
        for version in ("5.0.0", "5.0.0-rc.1", "5.0.0-alpha", "5.0.0-alpha.7"):
            self.assertEqual(module.requested_version(version), version)


class WorkflowRefTests(unittest.TestCase):
    def test_actions_refs_follow_git_rules_including_build_metadata(self):
        import importlib.util
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('native_ref_record', ROOT / 'Scripts/ci/sdk_build_record.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        repository = 'zodl-inc/zodl-swift-wallet-sdk-private'
        prefix = repository + '/.github/workflows/build-ffi.yml@'
        environment = dict(GITHUB_ACTIONS='true', GITHUB_REPOSITORY=repository, GITHUB_SHA='a' * 40,
                           GITHUB_WORKFLOW_SHA='a' * 40, GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='1',
                           ZODL_SDK_REQUEST_ID='c' * 32)
        for ref in ('refs/heads/candidate/6.1.0+build.1', 'refs/tags/6.1.0+build.1',
                    'refs/heads/valid-@-é'):
            with self.subTest(ref=ref), patch.dict(os.environ, dict(environment, GITHUB_WORKFLOW_REF=prefix + ref)):
                self.assertEqual(module.execution_identity(repository, 'a' * 40)['workflow']['ref'], prefix + ref)
        for ref in ('--help', 'refs/pull/12/head', 'refs/heads/a..b', 'refs/tags/x.lock',
                    'refs/heads/a b', 'refs/tags/x\ny', 'refs/heads/.hidden', 'refs/tags/x@{1}', 'refs/heads/a//b'):
            with self.subTest(ref=ref), patch.dict(os.environ, dict(environment, GITHUB_WORKFLOW_REF=prefix + ref)):
                with self.assertRaises(module.BuildError):
                    module.execution_identity(repository, 'a' * 40)


if __name__ == "__main__":
    unittest.main()
