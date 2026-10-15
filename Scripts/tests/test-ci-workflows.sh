# Offline, text-only checks on how CI builds and caches the FFI (the root
# Makefile's ffi-ci target and the workflows that call it), on whether the
# FFI build's deployment targets agree with Package.swift, and on Cargo.toml
# keeping a release build's proc macros loadable. Like
# test-workflow.sh, these never run cargo, gh or a workflow. `make -n` prints
# the commands a target would run; GNU make still descends into `$(MAKE)`
# lines under -n, but only to print their commands too.
# A recipe line that joins another command to `$(MAKE)` would run that command
# for real here, which is why ffi-ci keeps its rm on a line of its own.

# The dry run of `make <target>`, saved to a scratch file whose path is printed.
_dry_run() {
    local out; out="$SCRATCH/dry-run-$1.txt"
    make -C "$REPO_ROOT" -n "$1" > "$out" 2>/dev/null
    printf '%s\n' "$out"
}

test_ffi_ci_builds_only_the_arm64_macos_slice() {
    local f; f="$(_dry_run ffi-ci)"
    assert_eq "1" "$(grep -c 'cargo build' "$f")" "make ffi-ci runs exactly one cargo build"
    assert_file_contains "$f" "target aarch64-apple-darwin" "make ffi-ci builds aarch64-apple-darwin"
    assert_file_lacks "$f" "target x86_64-apple-darwin" "make ffi-ci builds no x86_64 slice"
}

test_ffi_ci_turns_fat_lto_off() {
    assert_file_contains "$(_dry_run ffi-ci)" "CARGO_PROFILE_RELEASE_LTO=false" \
        "make ffi-ci overrides the release profile's lto"
}

# lipo bundles every static library it finds under products/macos, so a stale
# x86_64 one left by an earlier `make ffi-macos` would ride along unless the
# directory is gone before the build starts.
test_ffi_ci_clears_the_macos_products_before_building() {
    local f rm_line make_line
    f="$(_dry_run ffi-ci)"
    rm_line="$(grep -n 'rm -rf BuildSupport/products/macos$' "$f" | head -1 | cut -d: -f1)"
    make_line="$(grep -n 'ffi-macos MACOS_ARCHS=aarch64-apple-darwin' "$f" | head -1 | cut -d: -f1)"
    assert_succeeds "make ffi-ci removes BuildSupport/products/macos" test -n "$rm_line"
    assert_succeeds "make ffi-ci delegates to ffi-macos with arm64 only" test -n "$make_line"
    assert_succeeds "the removal comes before the build" test "${rm_line:-0}" -lt "${make_line:-0}"
}

test_ffi_macos_still_builds_both_macos_architectures_with_lto() {
    local f; f="$(_dry_run ffi-macos)"
    assert_file_contains "$f" "target x86_64-apple-darwin" "make ffi-macos still builds x86_64"
    assert_file_contains "$f" "target aarch64-apple-darwin" "make ffi-macos still builds arm64"
    assert_file_lacks "$f" "CARGO_PROFILE_RELEASE_LTO" "make ffi-macos keeps the release profile's lto"
}

# Package.swift's platforms, printed as "iOS <major> macOS <major>" (for example
# "iOS 16 macOS 14") whatever the layout or order of the platforms array.
# Comment lines are ignored.
_package_platforms() {
    local manifest ios macos
    manifest="$(grep -v '^[[:space:]]*//' "$REPO_ROOT/Package.swift")"
    ios="$(printf '%s\n' "$manifest" | grep -oE '\.iOS\(\.v[0-9]+\)' | tr -dc '0-9\n' | paste -sd' ' -)"
    macos="$(printf '%s\n' "$manifest" | grep -oE '\.macOS\(\.v[0-9]+\)' | tr -dc '0-9\n' | paste -sd' ' -)"
    printf 'iOS %s macOS %s\n' "$ios" "$macos"
}

test_ffi_builds_pass_the_deployment_targets() {
    local f; f="$(_dry_run ffi-ci)"
    assert_file_contains "$f" "MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build" \
        "make ffi-ci passes both deployment targets to cargo"
    f="$(_dry_run ffi-all)"
    local builds; builds="$(grep -c 'cargo build' "$f")"
    assert_succeeds "make ffi-all runs cargo at least once" test "$builds" -gt 0
    assert_eq "$builds" \
        "$(grep -c 'MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build' "$f")" \
        "every cargo build in make ffi-all carries both deployment targets"
}

test_deployment_targets_agree_with_package_swift() {
    assert_eq "iOS 16 macOS 14" "$(_package_platforms)" "Package.swift declares iOS 16 and macOS 14"
    local s
    for s in Scripts/init-local-ffi.sh Scripts/rebuild-local-ffi.sh; do
        assert_file_contains "$REPO_ROOT/$s" "export MACOSX_DEPLOYMENT_TARGET=14.0" "$s exports the macOS target"
        assert_file_contains "$REPO_ROOT/$s" "export IPHONEOS_DEPLOYMENT_TARGET=16.0" "$s exports the iOS target"
    done
    assert_file_contains "$REPO_ROOT/BuildSupport/Makefile" "MACOSX_DEPLOYMENT_TARGET = 14.0" \
        "BuildSupport/Makefile's macOS target"
    assert_file_contains "$REPO_ROOT/BuildSupport/Makefile" "IPHONEOS_DEPLOYMENT_TARGET = 16.0" \
        "BuildSupport/Makefile's iOS target"
    assert_eq "<string>14.0</string>" \
        "$(grep -A1 '<key>LSMinimumSystemVersion</key>' "$REPO_ROOT/Scripts/version-macos-framework.sh" | tail -1 | tr -d '[:space:]')" \
        "the macOS framework's Info.plist names macOS 14 as its minimum"
}

# The settings of Cargo.toml's [$1] table, one per line, without comments or
# blank lines.
_cargo_table() {
    awk -v h="[$1]" '
        /^\[/ { in_t = ($0 == h); next }
        in_t && !/^[[:space:]]*(#|$)/ { print }
    ' "$REPO_ROOT/Cargo.toml"
}

# A release build's build scripts and proc macros would otherwise be stripped
# by rustc's bundled rust-objcopy, whose output macOS 27's dyld can refuse to
# load, so the FFI build stops at the first proc macro (see Cargo.toml).
test_release_builds_leave_host_artifacts_unstripped() {
    assert_eq "strip = false" \
        "$(_cargo_table profile.release.build-override | grep -E '^strip[[:space:]]*=')" \
        "Cargo.toml's [profile.release.build-override] sets strip = false"
}

_swift_workflow() { printf '%s\n' "$REPO_ROOT/.github/workflows/swift.yml"; }

# The paths-ignore entries under trigger $1 (pull_request or push) of file $2.
_paths_ignore_of() {
    awk -v t="  $1:" '
        $0 == t { in_t = 1; next }
        in_t && /^  [a-z_]+:/ { in_t = 0 }
        in_t && /^    paths-ignore:/ { in_l = 1; next }
        in_l && /^      - / { print; next }
        in_l { in_l = 0 }
    ' "$2"
}

test_swift_workflow_also_runs_on_pushes_to_main() {
    local f; f="$SCRATCH/swift-on.txt"
    awk '/^on:/ { f = 1; next } f && /^[a-z]/ { exit } f' "$(_swift_workflow)" > "$f"
    assert_file_contains "$f" "  push:" "swift.yml also triggers on push"
    assert_file_contains "$f" "    branches: [main]" "only on pushes to main"
}

test_swift_workflow_push_and_pull_request_ignore_the_same_paths() {
    local pr push
    pr="$(_paths_ignore_of pull_request "$(_swift_workflow)")"
    push="$(_paths_ignore_of push "$(_swift_workflow)")"
    assert_succeeds "pull_request has a paths-ignore list" test -n "$pr"
    assert_eq "$pr" "$push" "push ignores exactly the paths pull_request ignores"
}

# The whole list item of the step named $1, whichever key comes first.
_step_block() {
    awk -v n="name: $1" '
        /^    - / { if (hit) { printf "%s", item; done = 1; exit } item = "" }
        { item = item $0 "\n" }
        index($0, n) { hit = 1 }
        END { if (hit && !done) printf "%s", item }
    ' "$(_swift_workflow)"
}

# The `if:` line of the step named $1, including a `- if:` written before its `name:`.
_step_condition() {
    _step_block "$1" | grep -E '^ *(- )?if:'
}

test_swift_workflow_runs_the_rust_tests_on_every_run() {
    assert_file_contains "$(_swift_workflow)" "name: Run Rust unit tests" "swift.yml has the Rust test step"
    assert_eq "" "$(_step_condition "Run Rust unit tests")" \
        "the Rust test step has no condition: fork pull requests run it too"
}

test_swift_workflow_builds_the_ffi_with_ffi_ci() {
    assert_file_contains "$(_swift_workflow)" "run: make ffi-ci" "swift.yml builds the FFI with make ffi-ci"
    assert_file_lacks "$(_swift_workflow)" "run: make ffi-macos" "swift.yml no longer builds the universal slice"
}

test_swift_workflow_installs_only_the_arm64_macos_rust_target() {
    assert_file_contains "$(_swift_workflow)" "targets: aarch64-apple-darwin" "swift.yml installs aarch64-apple-darwin"
    assert_file_lacks "$(_swift_workflow)" "x86_64-apple-darwin" "swift.yml installs no x86_64 target"
}

test_swift_workflow_cache_keys_name_the_ci_build() {
    assert_file_contains "$(_swift_workflow)" "key: ffi-xcframework-macos-arm64-nolto-" "the XCFramework key names the ffi-ci build"
    assert_file_contains "$(_swift_workflow)" "cargo-v2-" "the cargo key is bumped to v2"
    assert_file_lacks "$(_swift_workflow)" "cargo-v1-" "no v1 cargo key remains"
}

test_swift_workflow_hashes_the_root_makefile() {
    assert_file_contains "$(_swift_workflow)" "find rust Cargo.toml Cargo.lock BuildSupport Makefile -type f" \
        "the FFI source hash covers the root Makefile, where ffi-ci lives"
}

test_swift_workflow_interpolates_nothing_into_run_scripts() {
    assert_eq "" "$(_run_script_interpolations "$(_swift_workflow)")" "no \${{ }} in swift.yml reaches a run: script"
}

_codeql_workflow() { printf '%s\n' "$REPO_ROOT/.github/workflows/codeql.yml"; }
_build_ffi_workflow() { printf '%s\n' "$REPO_ROOT/.github/workflows/build-ffi.yml"; }

test_no_workflow_selects_xcode_16() {
    assert_eq "" "$(grep -rl 'Xcode_16' "$REPO_ROOT/.github/workflows")" "no workflow selects Xcode 16"
}

test_swift_workflow_runs_on_xcode_27() {
    assert_file_contains "$(_swift_workflow)" "runs-on: xcode-27" "swift.yml builds on the xcode-27 image"
    assert_file_contains "$(_swift_workflow)" "/Applications/Xcode_27.0.app" "swift.yml selects Xcode 27.0"
}

test_build_ffi_workflow_runs_on_xcode_27() {
    assert_file_contains "$(_build_ffi_workflow)" "runs-on: xcode-27" "build-ffi.yml builds on the xcode-27 image"
    assert_file_contains "$(_build_ffi_workflow)" "/Applications/Xcode_27.0.app" "build-ffi.yml selects Xcode 27.0"
}

# Xcode 27 ships Swift 6.4, which CodeQL's Swift extractor cannot analyze yet.
test_codeql_swift_job_uses_xcode_26_6() {
    assert_file_contains "$(_codeql_workflow)" "runner: macos-26" "CodeQL's Swift job runs on macos-26"
    assert_file_contains "$(_codeql_workflow)" "/Applications/Xcode_26.6.app" "CodeQL's Swift job selects Xcode 26.6"
}

test_codeql_swift_job_builds_with_ffi_ci() {
    assert_file_contains "$(_codeql_workflow)" "run: make ffi-ci" "CodeQL's Swift job builds with make ffi-ci"
    assert_file_lacks "$(_codeql_workflow)" "run: make ffi-macos" "CodeQL no longer builds the universal slice"
    assert_file_contains "$(_codeql_workflow)" "key: codeql-ffi-xcframework-macos-arm64-nolto-" \
        "CodeQL's XCFramework key names the ffi-ci build"
    assert_file_contains "$(_codeql_workflow)" 'codeql-${{ runner.os }}-cargo-v2-${{ steps.toolchain.outputs.cachekey }}-' \
        "CodeQL's cargo key carries the rustc version"
    assert_file_contains "$(_codeql_workflow)" "find rust Cargo.toml Cargo.lock BuildSupport Makefile -type f" \
        "CodeQL's FFI hash covers the root Makefile"
    assert_file_contains "$(_codeql_workflow)" "id: toolchain" "CodeQL's Setup Rust step has an id"
    assert_file_lacks "$(_codeql_workflow)" "x86_64-apple-darwin" "CodeQL installs no x86_64 target"
}

test_no_workflow_calls_slipstream_a_private_cargo_clone() {
    assert_eq "" "$(grep -rl 'PRIVATE zodl-inc/slipstream' "$REPO_ROOT/.github/workflows")" \
        "no cache comment still describes slipstream as a private git dependency"
}

# Every local action or reusable workflow (`uses: ./<path>`) that the workflow
# or action file $1 calls, one `./<path>` per line. The value may be quoted;
# commented-out lines are ignored.
_local_action_refs() {
    awk '
        /^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["\047]?\.\// {
            ref = $0
            sub(/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["\047]?/, "", ref)
            sub(/["\047[:space:]#].*$/, "", ref)
            print ref
        }
    ' "$1"
}

# A branch that fetches private repositories brings its authorization action
# back with it; what must never happen is a workflow or action calling a local
# action, or a local reusable workflow, that is not there.
test_every_local_action_a_workflow_uses_exists() {
    local f ref missing=""
    for f in "$REPO_ROOT"/.github/workflows/*.yml \
             "$REPO_ROOT"/.github/actions/*/action.yml \
             "$REPO_ROOT"/.github/actions/*/action.yaml; do
        [ -e "$f" ] || continue
        while IFS= read -r ref; do
            # A reusable workflow is the referenced file itself; an action is a
            # directory holding action.yml or action.yaml.
            if [ ! -f "$REPO_ROOT/$ref" ] && [ ! -f "$REPO_ROOT/$ref/action.yml" ] \
                && [ ! -f "$REPO_ROOT/$ref/action.yaml" ]; then
                missing="$missing $ref"
            fi
        done < <(_local_action_refs "$f")
    done
    assert_eq "" "${missing# }" "every local action a workflow or action uses exists"
}

# The toolchain floats on stable. After a Rust release, a cache restored by an
# exact key hit would hold artifacts the new compiler cannot reuse, and nothing
# would ever save the rebuilt ones, so the key has to name the rustc version.
test_swift_workflow_cargo_key_includes_the_toolchain() {
    assert_file_contains "$(_swift_workflow)" "id: toolchain" "the build job's Rust setup step has an id"
    assert_file_contains "$(_swift_workflow)" 'cargo-v2-${{ steps.toolchain.outputs.cachekey }}-' \
        "the cargo cache key carries the rustc version"
}
