# shellcheck shell=bash disable=SC2016
# Literal shell/GitHub expressions are fixtures, evaluated by their consumers.
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
    OHTTP_ENV_RESOLVED=1 make -C "$REPO_ROOT" -n "$1" > "$out" 2>/dev/null
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
    assert_file_contains "$f" "MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=16.0 python3 ../Scripts/lib/ohttp_env.py --required -- cargo build" \
        "make ffi-ci passes both deployment targets to cargo"
    f="$(_dry_run ffi-all)"
    local builds; builds="$(grep -c 'cargo build' "$f")"
    assert_succeeds "make ffi-all runs cargo at least once" test "$builds" -gt 0
    assert_eq "$builds" \
        "$(grep -c 'MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=16.0 python3 ../Scripts/lib/ohttp_env.py --required -- cargo build' "$f")" \
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
    assert_file_contains "$(_swift_workflow)" "target aarch64-apple-darwin" "swift.yml installs aarch64-apple-darwin"
    assert_file_lacks "$(_swift_workflow)" "x86_64-apple-darwin" "swift.yml installs no x86_64 target"
}

test_swift_workflow_cache_keys_name_the_ci_build() {
    assert_file_contains "$(_swift_workflow)" "key: ffi-xcframework-macos-arm64-nolto-" "the XCFramework key names the ffi-ci build"
    assert_file_contains "$(_swift_workflow)" "cargo-ci-macos-arm64-nolto-v4-" "the cargo key isolates the CI build variant"
    assert_file_lacks "$(_swift_workflow)" "cargo-v1-" "no v1 cargo key remains"
}

test_swift_workflow_hashes_the_root_makefile() {
    assert_file_contains "$(_swift_workflow)" 'Scripts/ci/ffi-input-hash.sh' \
        "the FFI source hash uses committed build inputs"
}

test_swift_workflow_interpolates_nothing_into_run_scripts() {
    assert_eq "" "$(_run_script_interpolations "$(_swift_workflow)")" "no \${{ }} in swift.yml reaches a run: script"
}

_codeql_workflow() { printf '%s\n' "$REPO_ROOT/.github/workflows/codeql.yml"; }
_build_ffi_workflow() { printf '%s\n' "$REPO_ROOT/.github/workflows/build-ffi.yml"; }

test_no_workflow_selects_xcode_16() {
    assert_eq "" "$(grep -rl 'Xcode_16' "$REPO_ROOT/.github/workflows")" "no workflow selects Xcode 16"
}

# These workflows use the image-selected Xcode and isolate compiled caches by
# its complete version/build output, as well as the runner architecture.
_assert_default_xcode_cache_identity() {
    local workflow="$1"
    assert_file_lacks "$workflow" "xcode-select" "the image chooses Xcode"
    assert_file_lacks "$workflow" "/Applications/Xcode_" "no version-numbered Xcode path is pinned"
    assert_file_contains "$workflow" "id: xcode-cache-key" "the Xcode identity has a step output"
    assert_file_contains "$workflow" 'xcodebuild -version -skipMacroValidation -derivedDataPath "${RUNNER_TEMP}/DerivedData"' \
        "the default Xcode reports its version with isolated build data"
    assert_file_contains "$workflow" 'shasum -a 256 "$xcode_version_file"' "the hash uses the complete captured output"
    local keys="$SCRATCH/compiled-cache-keys.txt"
    awk '
        /^[[:space:]]*key:/ { print }
        /^[[:space:]]*restore-keys:/ {
            match($0, /[^[:space:]]/)
            restore_indent = RSTART
            in_restore = 1
            next
        }
        in_restore && /[^[:space:]]/ {
            match($0, /[^[:space:]]/)
            if (RSTART > restore_indent) { print; next }
            in_restore = 0
        }
    ' "$workflow" | grep -E 'cargo-|ffi-xcframework-' > "$keys"
    assert_succeeds "compiled cache keys exist" test -s "$keys"
    while IFS= read -r key; do
        printf '%s\n' "$key" > "$SCRATCH/cache-key.txt"
        assert_file_contains "$SCRATCH/cache-key.txt" '${{ runner.arch }}' "every compiled cache key or restore prefix includes architecture"
        assert_file_contains "$SCRATCH/cache-key.txt" '${{ steps.xcode-cache-key.outputs.hash }}' "every compiled cache key or restore prefix includes Xcode identity"
    done < "$keys"
}

test_swift_workflow_runs_on_xcode_27() {
    assert_file_contains "$(_swift_workflow)" "runs-on: xcode-27" "swift.yml builds on the xcode-27 image"
    _assert_default_xcode_cache_identity "$(_swift_workflow)"
}

test_build_ffi_workflow_runs_on_xcode_27() {
    assert_file_contains "$(_build_ffi_workflow)" "runs-on: xcode-27" "build-ffi.yml builds on the xcode-27 image"
    _assert_default_xcode_cache_identity "$(_build_ffi_workflow)"
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
    assert_file_contains "$(_codeql_workflow)" 'codeql-${{ runner.os }}-cargo-v4-${{ steps.toolchain.outputs.cachekey }}-' \
        "CodeQL's cargo key carries the rustc version"
    assert_file_contains "$(_codeql_workflow)" "Scripts/ci/ffi-input-hash.sh" \
        "CodeQL's FFI hash covers committed native build inputs including the runner"
    assert_file_contains "$(_codeql_workflow)" "id: toolchain" "CodeQL's Setup Rust step has an id"
    assert_file_contains "$(_codeql_workflow)" 'Scripts/ci/rust_toolchain.py' "CodeQL validates the compiler and exports its identity"
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
    assert_file_contains "$(_swift_workflow)" 'Scripts/ci/rust_toolchain.py' "the validator exports the cachekey output"
    assert_file_contains "$(_swift_workflow)" 'cargo-ci-macos-arm64-nolto-v4-${{ steps.toolchain.outputs.cachekey }}-' \
        "the cargo cache key carries the rustc identity and build variant"
}

# Compile identity must be available before any compiled product can be restored.
test_ci_cache_rust_setup_precedes_product_restore() {
    local setup restore
    setup="$(grep -n 'id: toolchain' "$(_swift_workflow)" | cut -d: -f1)"
    restore="$(grep -n 'id: cache-ffi' "$(_swift_workflow)" | cut -d: -f1)"
    assert_succeeds 'Rust identity is computed before FFI lookup' test "$setup" -lt "$restore"
}

test_ci_cache_keys_include_complete_rust_identity() {
    local workflow key lines
    for workflow in "$(_swift_workflow)" "$(_build_ffi_workflow)" "$(_codeql_workflow)"; do
        assert_file_contains "$workflow" 'id: toolchain' 'Rust validation exports its identity'
        assert_file_contains "$workflow" 'Scripts/ci/rust_toolchain.py' 'validate complete compiler identity'
        lines="$(awk '/^[[:space:]]*key:/ { print } /^[[:space:]]*restore-keys:/ { fallback=1; next } fallback && /[^[:space:]]/ { if ($0 ~ /^[[:space:]]+\$\{\{/) print; else fallback=0 }' "$workflow" | grep -E 'cargo-|ffi-xcframework-')"
        while IFS= read -r key; do
            printf '%s\n' "$key" > "$SCRATCH/rust-key.txt"
            assert_file_contains "$SCRATCH/rust-key.txt" '${{ steps.toolchain.outputs.cachekey }}' 'all compiled keys and fallbacks constrain Rust'
        done <<< "$lines"
    done
    assert_file_contains "$(_build_ffi_workflow)" 'cargo-release-all-slices-lto-v3-${{ steps.toolchain.outputs.cachekey }}-' 'release Cargo namespace isolates all slices and LTO'
}

test_ci_cache_rust_identity_changes_for_verbose_fields() {
    local workflow script dir first second expected
    dir="$(mktemp -d "$SCRATCH/rust-identity.XXXXXX")"
    cat > "$dir/rustup" <<'SH'
#!/bin/sh
case "$1" in
    show) printf 'stable-aarch64-apple-darwin (environment override)\n' ;;
    which) printf '%s/%s\n' "$RUST_FIXTURE_BIN" "$4" ;;
    *) exit 9 ;;
esac
SH
    printf '#!/bin/sh\ncat "$RUST_IDENTITY_FILE"\n' > "$dir/rustc"
    printf '#!/bin/sh\nprintf "cargo 1.100.0 (bbbbbbbbb 2026-10-28)\\n"\n' > "$dir/cargo"
    chmod +x "$dir/rustup" "$dir/rustc" "$dir/cargo"
    for workflow in "$(_swift_workflow)" "$(_build_ffi_workflow)" "$(_codeql_workflow)"; do
        script="$dir/validate.sh"
        awk '/id: toolchain/ { active=1; next } active && /run: \|/ { body=1; next } active && body { if ($0 ~ /^[[:space:]]*(- name:|#|$)/) exit; print }' "$workflow" > "$script"
        printf 'rustc 1.100.0 (aaaaaaaaa 2026-10-28)\nbinary: rustc\ncommit-hash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\ncommit-date: 2026-10-28\nhost: aarch64-apple-darwin\nrelease: 1.100.0\nLLVM version: 22\n' > "$dir/identity"
        : > "$dir/output"
        (unset RUSTC RUSTUP_TOOLCHAIN; PATH="$dir:$PATH" RUST_FIXTURE_BIN="$dir" RUST_IDENTITY_FILE="$dir/identity" GITHUB_ENV="$dir/env" GITHUB_OUTPUT="$dir/output" GITHUB_PATH="$dir/path" bash -e "$script") > /dev/null
        first="$(sed -n 's/^cachekey=//p' "$dir/output")"
        expected="$(shasum -a 256 "$dir/identity" | cut -d' ' -f1)"
        assert_eq "$expected" "$first" 'workflow validation hashes the full rustc output'
        sed 's/LLVM version: 22/LLVM version: 23/' "$dir/identity" > "$dir/changed"
        mv "$dir/changed" "$dir/identity"
        : > "$dir/output"
        (unset RUSTC RUSTUP_TOOLCHAIN; PATH="$dir:$PATH" RUST_FIXTURE_BIN="$dir" RUST_IDENTITY_FILE="$dir/identity" GITHUB_ENV="$dir/env" GITHUB_OUTPUT="$dir/output" GITHUB_PATH="$dir/path" bash -e "$script") > /dev/null
        second="$(sed -n 's/^cachekey=//p' "$dir/output")"
        assert_succeeds 'a verbose identity field changes the workflow cache key' test "$first" != "$second"
    done
}

# Restrict swift.yml to its native build job so rustfmt's independent setup
# cannot accidentally satisfy the build-job ordering contract.
_rust_build_job() {
    if [ "$1" = "$(_swift_workflow)" ]; then
        awk '/^  build:/ { active=1 } active' "$1"
    else
        cat "$1"
    fi
}

test_ci_validates_installed_stable_before_tests_and_cache_restore() {
    local workflow job python install validate consumer
    for workflow in "$(_swift_workflow)" "$(_build_ffi_workflow)" "$(_codeql_workflow)"; do
        job="$SCRATCH/rust-build-job.yml"
        _rust_build_job "$workflow" > "$job"
        python="$(grep -n 'uses: actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1' "$job" | cut -d: -f1)"
        install="$(grep -n 'rustup toolchain install stable --profile minimal --no-self-update' "$job" | cut -d: -f1)"
        validate="$(grep -n 'Scripts/ci/rust_toolchain.py' "$job" | cut -d: -f1)"
        consumer="$(grep -nE 'uses: actions/cache@|run: make test-scripts|run: make ffi-ci' "$job" | head -1 | cut -d: -f1)"
        assert_file_contains "$job" "python-version: '3.12'" 'validator and its tests use a TOML-capable Python'
        assert_succeeds 'Python setup precedes validation' test "${python:-0}" -gt 0
        assert_succeeds 'explicit stable install precedes validation' test "${install:-0}" -gt 0
        assert_succeeds 'validator is configured' test "${validate:-0}" -gt 0
        assert_succeeds 'known Python precedes validation' test "${python:-0}" -lt "${validate:-0}"
        assert_succeeds 'stable install precedes validation' test "${install:-0}" -lt "${validate:-0}"
        assert_succeeds 'validation precedes Cargo fixture tests and product restores' test "${validate:-0}" -lt "${consumer:-0}"
        assert_file_contains "$job" 'python3 Scripts/ci/rust_toolchain.py --github-env "$GITHUB_ENV" --github-output "$GITHUB_OUTPUT" --github-path "$GITHUB_PATH"' 'validated selection survives into later CI steps'
        assert_file_lacks "$job" 'rustup default stable' 'CI keeps the runner global default intact'
    done
}

test_codeql_validation_is_required_on_ffi_cache_hits() {
    local block="$SCRATCH/codeql-validator.yml"
    awk '/- name: Validate Rust/ { active=1 } active && /- name:/ && !/Validate Rust/ { exit } active { print }' "$(_codeql_workflow)" > "$block"
    assert_file_contains "$block" "if: matrix.language == 'swift'" 'validation covers every Swift matrix run'
    assert_file_lacks "$block" 'cache-hit' 'CodeQL cache hits cannot bypass validation'
}

test_ci_cache_release_keeps_publication_and_targets() {
    local workflow
    workflow="$(_build_ffi_workflow)"
    assert_file_contains "$workflow" 'target aarch64-apple-ios,x86_64-apple-ios,aarch64-apple-ios-sim,x86_64-apple-darwin,aarch64-apple-darwin' 'release retains all five architecture targets'
    assert_file_contains "$workflow" './Scripts/prepare-release.sh artifacts --force-overwrite-existing-release "$VERSION"' 'release force publication command is preserved'
    assert_file_contains "$workflow" './Scripts/prepare-release.sh artifacts "$VERSION"' 'release publication command is preserved'
}

# Evaluate only the explicitly supported workflow contract; an unknown
# expression fails rather than silently using this fixture's implementation.
_sdk_concurrency_group() {
    local group event="$1" pr="$2" run="$3" workflow="$4" identity
    group="$(sed -n 's/^  group: //p' "$(_swift_workflow)")"
    case "$event" in
        pull_request) identity="pr-$pr" ;;
        *) identity="run-$run" ;;
    esac
    group="${group//'${{ github.workflow }}'/$workflow}"
    group="${group//'${{ github.event_name == '\''pull_request'\'' && format('\''pr-{0}'\'', github.event.pull_request.number) || format('\''run-{0}'\'', github.run_id) }}'/$identity}"
    printf '%s\n' "$group"
}

test_sdk_concurrency_is_pr_scoped() {
    local f; f="$(_swift_workflow)"
    assert_file_contains "$f" 'concurrency:' 'workflow defines cancellation scope'
    assert_file_contains "$f" '  group: ${{ github.workflow }}-${{ github.event_name == '\''pull_request'\'' && format('\''pr-{0}'\'', github.event.pull_request.number) || format('\''run-{0}'\'', github.run_id) }}' 'group scopes PRs by number and other events by run identity'
    assert_file_contains "$f" '  cancel-in-progress: ${{ github.event_name == '\''pull_request'\'' }}' 'only PR events cancel earlier runs'
    assert_eq 'Build-pr-1' "$(_sdk_concurrency_group pull_request 1 101 Build)" 'PR 1 uses its own group'
    assert_eq 'Build-pr-1' "$(_sdk_concurrency_group pull_request 1 102 Build)" 'a newer PR 1 run shares its group'
    assert_eq 'Build-pr-2' "$(_sdk_concurrency_group pull_request 2 103 Build)" 'PR 2 does not cancel PR 1'
    assert_eq 'Build-run-1' "$(_sdk_concurrency_group push 0 1 Build)" 'a main push cannot collide with PR 1'
    assert_eq 'Build-run-2' "$(_sdk_concurrency_group push 0 2 Build)" 'two main pushes have independent groups'
    assert_eq 'Release-run-1' "$(_sdk_concurrency_group workflow_dispatch 0 1 Release)" 'a release workflow cannot share the build group'
}

_swift_dependency_paths() {
    _step_block "$1" | awk '
        /^        path: \|$/ { paths = 1; next }
        paths && /^          / { sub(/^          /, ""); print; next }
        paths { exit }
    '
}

test_swift_dependency_cache_paths_are_explicit() {
    local step paths expected
    expected="$(printf '.build/repositories\n.build/checkouts\n.build/artifacts')"
    for step in 'Restore SwiftPM dependencies' 'Save SwiftPM dependencies'; do
        paths="$(_swift_dependency_paths "$step")"
        assert_eq "$expected" "$paths" "$step caches only downloaded dependency directories"
        _step_block "$step" > "$SCRATCH/swift-cache-step.txt"
        assert_file_contains "$SCRATCH/swift-cache-step.txt" 'continue-on-error: true' "$step failures do not block normal builds"
    done
    _step_block 'Restore SwiftPM dependencies' > "$SCRATCH/swift-restore.txt"
    assert_file_contains "$SCRATCH/swift-restore.txt" 'actions/cache/restore@cdf6c1fa76f9f475f3d7449005a359c84ca0f306' 'restore uses the existing pinned action revision'
    assert_file_contains "$SCRATCH/swift-restore.txt" 'if: steps.swift-cache-key.outcome == '\''success'\''' 'a failed identity cannot restore a broad empty key'
    _step_block 'Save SwiftPM dependencies' > "$SCRATCH/swift-save.txt"
    assert_file_contains "$SCRATCH/swift-save.txt" 'actions/cache/save@cdf6c1fa76f9f475f3d7449005a359c84ca0f306' 'save uses the existing pinned action revision'
}

test_swift_dependency_keys_constrain_toolchain_and_manifests() {
    local step prefix
    _step_block 'Restore SwiftPM dependencies' > "$SCRATCH/swift-restore.txt"
    prefix='${{ runner.os }}-${{ runner.arch }}-swiftpm-dependencies-v1-${{ steps.xcode-cache-key.outputs.hash }}-${{ steps.swift-cache-key.outputs.hash }}-'
    assert_file_contains "$SCRATCH/swift-restore.txt" "key: $prefix" 'primary key scopes OS architecture Xcode and Swift'
    assert_file_contains "$SCRATCH/swift-restore.txt" 'hashFiles('\''Package.swift'\'', '\''Package.resolved'\'', '\''BuildSupport/LocalPackages-Package.swift'\'', '\''LocalPackages/Package.swift'\'')' 'primary key includes root and local FFI manifests and resolution lockfile'
    assert_eq "          $prefix" "$(awk '/restore-keys:/ { getline; print }' "$SCRATCH/swift-restore.txt")" 'fallback retains all toolchain fields'
    assert_eq '1' "$(awk '/restore-keys:/ { in_keys=1; next } in_keys && /^          / { n++; next } in_keys { in_keys=0 } END { print n+0 }' "$SCRATCH/swift-restore.txt")" 'no broader restore prefix is allowed'
    _step_block 'Save SwiftPM dependencies' > "$SCRATCH/swift-save.txt"
    assert_file_contains "$SCRATCH/swift-save.txt" 'key: ${{ steps.cache-swift.outputs.cache-primary-key }}' 'save reuses the exact lookup key even if resolution updates files'
}

test_swift_resolves_before_saving_dependencies() {
    local configure restore resolve save build f
    f="$(_swift_workflow)"
    configure="$(grep -n 'run: make configure-local-ffi$' "$f" | cut -d: -f1)"
    restore="$(grep -n 'name: Restore SwiftPM dependencies$' "$f" | cut -d: -f1)"
    resolve="$(grep -n 'run: make resolve$' "$f" | cut -d: -f1)"
    save="$(grep -n 'name: Save SwiftPM dependencies$' "$f" | cut -d: -f1)"
    build="$(grep -n 'run: make build SWIFT_BUILD_FLAGS=-v$' "$f" | cut -d: -f1)"
    assert_succeeds 'local FFI exists before dependency restore' test "${configure:-0}" -lt "${restore:-0}"
    assert_succeeds 'restore occurs before resolution' test "${restore:-0}" -lt "${resolve:-0}"
    assert_succeeds 'resolution occurs before save' test "${resolve:-0}" -lt "${save:-0}"
    assert_succeeds 'dependency save occurs before compilation' test "${save:-0}" -gt 0
    assert_succeeds 'dependency save occurs before compilation' test "${save:-0}" -lt "${build:-0}"
    _step_block 'Resolve SwiftPM dependencies' > "$SCRATCH/swift-resolve.txt"
    assert_file_contains "$SCRATCH/swift-resolve.txt" 'id: resolve-swift' 'resolution outcome is available for save gating'
    assert_file_lacks "$SCRATCH/swift-resolve.txt" 'continue-on-error' 'dependency resolution failures remain build failures'
    assert_eq '' "$(_step_condition 'Resolve SwiftPM dependencies')" 'resolution runs even on exact cache hits'
    assert_eq "      if: steps.resolve-swift.outcome == 'success' && steps.cache-swift.outputs.cache-hit != 'true' && steps.swift-cache-key.outcome == 'success'" "$(_step_condition 'Save SwiftPM dependencies')" 'only successful resolution after a non-hit saves dependencies'
}

test_swift_build_and_tests_remain_unconditional() {
    local step command
    for step in 'Build ZODLSwiftWalletSDK Swift Package' 'Run OfflineTests suite' 'Run Rust unit tests'; do
        assert_eq '' "$(_step_condition "$step")" "$step runs on cache hit and miss"
    done
    for command in 'make build SWIFT_BUILD_FLAGS=-v' 'make test-offline' 'make test-rust'; do
        assert_file_contains "$(_swift_workflow)" "run: $command" "$command remains enabled"
    done
}

test_swift_cache_identity_uses_actual_compiler_output() {
    local dir script first second
    dir="$(mktemp -d "$SCRATCH/swift-identity.XXXXXX")"
    script="$dir/identity.sh"
    _step_block 'Compute Swift cache identity' | awk '/run: \|/ { body=1; next } body { print }' > "$script"
    printf '#!/bin/sh\n[ "$1" = --version ] || exit 1\ncat "$SWIFT_IDENTITY_FILE"\n' > "$dir/swift"
    chmod +x "$dir/swift"
    printf 'Apple Swift version 6.4\nTarget: arm64-apple-macosx27.0\n' > "$dir/identity"
    : > "$dir/output"
    PATH="$dir:$PATH" SWIFT_IDENTITY_FILE="$dir/identity" GITHUB_OUTPUT="$dir/output" bash -e -o pipefail "$script" > /dev/null
    first="$(sed -n 's/^hash=//p' "$dir/output")"
    assert_eq "$(shasum -a 256 "$dir/identity" | cut -d' ' -f1)" "$first" 'Swift identity hashes the complete actual compiler output'
    printf 'Compiler build: 6.4.1\n' >> "$dir/identity"
    : > "$dir/output"
    PATH="$dir:$PATH" SWIFT_IDENTITY_FILE="$dir/identity" GITHUB_OUTPUT="$dir/output" bash -e -o pipefail "$script" > /dev/null
    second="$(sed -n 's/^hash=//p' "$dir/output")"
    assert_succeeds 'a compiler build change invalidates the Swift cache' test "$first" != "$second"
}

# The ohttp-trace feature turns OHTTP client trace ids on: QA/E2E builds only.
test_ohttp_e2e_builds_the_ffi_with_ohttp_trace() {
    assert_file_contains "$REPO_ROOT/.github/workflows/ohttp-e2e.yml" \
        "make ffi-macos MACOS_ARCHS=aarch64-apple-darwin FFI_CARGO_FEATURES=ohttp-trace" \
        "ohttp-e2e.yml passes FFI_CARGO_FEATURES=ohttp-trace to make"
    local out; out="$SCRATCH/dry-run-ffi-macos-trace.txt"
    OHTTP_ENV_RESOLVED=1 make -C "$REPO_ROOT" -n ffi-macos MACOS_ARCHS=aarch64-apple-darwin FFI_CARGO_FEATURES=ohttp-trace > "$out" 2>/dev/null
    assert_file_contains "$out" "cargo build --locked --manifest-path ../Cargo.toml --release --features ohttp-trace" \
        "FFI_CARGO_FEATURES turns into --features flag"
}

test_release_ffi_builds_never_enable_ohttp_trace() {
    local f
    for f in .github/workflows/build-ffi.yml Scripts/prepare-release.sh Scripts/release.sh; do
        assert_file_lacks "$REPO_ROOT/$f" "ohttp-trace" "$f does not enable ohttp-trace"
        assert_file_lacks "$REPO_ROOT/$f" "FFI_CARGO_FEATURES" "$f passes no extra Cargo features"
    done
    for f in ffi-all ffi-ci ffi-macos; do
        assert_file_lacks "$(_dry_run "$f")" " --features" "make $f enables no Cargo feature"
    done
    local out; out="$SCRATCH/dry-run-ffi-all-env-trace.txt"
    FFI_CARGO_FEATURES=ohttp-trace OHTTP_ENV_RESOLVED=1 make -C "$REPO_ROOT" -n ffi-all > "$out" 2>/dev/null
    assert_file_lacks "$out" " --features" "make ffi-all ignores FFI_CARGO_FEATURES from the environment"
    assert_file_contains "$REPO_ROOT/Cargo.toml" "default = []" "ohttp-trace is not a default feature"
}

# Parse job-scoped Actions secrets and ordering, rather than accepting stray text.
test_configured_native_workflows_use_required_actions_secrets_before_cache() {
    local workflow job
    for workflow in swift codeql ohttp-e2e build-ffi; do
        case "$workflow" in swift) job=build ;; codeql) job=analyze ;; ohttp-e2e) job=ffi ;; build-ffi) job=build-xcframework ;; esac
        assert_succeeds "$workflow supplies all eight Actions secrets before cache lookup" \
            ruby -ryaml -e '
              job = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1])
              names = %w[GATEWAY_HOST_MAINNET GATEWAY_HOST_TESTNET RELAY_URL_MAINNET RELAY_URL_TESTNET SIGNING_PUBKEY_MAINNET SIGNING_PUBKEY_TESTNET KEYS_DNS_NAME_MAINNET KEYS_DNS_NAME_TESTNET].map { |n| "ZODL_OHTTP_" + n }
              names.each { |n| abort "missing Actions secret #{n}" unless job.fetch("env", {})[n] == "${{ secrets.#{n} }}" }
              abort "native CI must require strict OHTTP" unless job.fetch("env", {})["ZODL_OHTTP_REQUIRE"] == "1"
              steps = job.fetch("steps")
              abort "AWS OHTTP fetch remains" if steps.any? { |s| s.fetch("uses", "").include?("aws-secrets") }
              index = steps.index { |s| s["id"] == "ohttp-config" && s.fetch("run", "").include?("ohttp_env.py --hash") }
              cache = steps.index { |s| s.fetch("uses", "").include?("actions/cache") }
              abort "configuration validation does not precede cache" unless index && cache && index < cache
              steps.select { |s| s.fetch("name", "").match?(/Cache (Cargo|FFI|XCFramework)/) }.each do |s|
                key = s.fetch("with").fetch("key")
                abort "cache misses configuration" unless key.include?("steps.ohttp-config.outputs.hash") || key.include?("steps.ffi-hash.outputs.hash")
                if s["name"] == "Cache Cargo"
                  s.fetch("with").fetch("restore-keys", "").lines.each { |line| abort "Cargo fallback omits configuration" unless line.include?("steps.ohttp-config.outputs.hash") }
                end
              end
            ' "$REPO_ROOT/.github/workflows/$workflow.yml" "$job"
    done
}

test_ohttp_source_capability_and_local_documentation() {
    assert_eq '1' "$(cat "$REPO_ROOT/BuildSupport/ohttp-config-version" 2>/dev/null)" 'source capability has version one'
    assert_succeeds 'marker has exact newline-terminated bytes' python3 -c 'import pathlib,sys; assert pathlib.Path(sys.argv[1]).read_bytes() == b"1\n"' "$REPO_ROOT/BuildSupport/ohttp-config-version"
    local name
    for name in GATEWAY_HOST_MAINNET GATEWAY_HOST_TESTNET RELAY_URL_MAINNET RELAY_URL_TESTNET SIGNING_PUBKEY_MAINNET SIGNING_PUBKEY_TESTNET KEYS_DNS_NAME_MAINNET KEYS_DNS_NAME_TESTNET; do
        assert_file_contains "$REPO_ROOT/docs/LOCAL_DEVELOPMENT.md" "ZODL_OHTTP_$name" 'docs list each required input'
    done
    assert_file_lacks "$REPO_ROOT/docs/LOCAL_DEVELOPMENT.md" 'gh variable get' 'local docs promise no automatic GitHub acquisition'
    assert_file_lacks "$REPO_ROOT/docs/LOCAL_DEVELOPMENT.md" 'login/interactive' 'local docs promise inherited inputs only'
    assert_file_lacks "$REPO_ROOT/Scripts/lib/ohttp_env.py" 'def load_shell_exports' 'automatic shell loader removed'
    assert_file_lacks "$REPO_ROOT/Scripts/lib/ohttp_env.py" 'def load_github_exports' 'automatic GitHub loader removed'
    assert_file_lacks "$REPO_ROOT/docs/LOCAL_DEVELOPMENT.md" 'SDK builds accept absent' 'optional build documentation is removed'
    assert_file_lacks "$REPO_ROOT/docs/LOCAL_DEVELOPMENT.md" 'no value-derived cache identity' 'stale cache guidance is removed'
}

test_e2e_cache_identities_keep_toolchain_and_configuration_boundaries() {
    assert_succeeds 'E2E build and test caches retain full configuration and compiler identities' \
        ruby -ryaml -e '
          jobs = YAML.load_file(ARGV[0]).fetch("jobs")
          ffi = jobs.fetch("ffi")
          steps = ffi.fetch("steps")
          cache = steps.index { |s| s.fetch("uses", "").include?("actions/cache") }
          rust = steps.index { |s| s["id"] == "toolchain" }
          abort "no toolchain validation before restore" unless rust && rust < cache
          steps.select { |s| s.fetch("uses", "").include?("actions/cache") }.each do |s|
            key = s.fetch("with").fetch("key")
            %w[steps.toolchain.outputs.cachekey steps.xcode-cache-key.outputs.hash runner.arch].each { |field| abort "missing cache identity" unless key.include?(field) }
            abort "private source cache" if s.fetch("with").fetch("path").include?("~/.cargo/git")
          end
          e2e = jobs.fetch("e2e")
          ffi.fetch("env").each { |name, value| abort "test env differs" unless e2e.fetch("env", {})[name] == value }
          abort "config digest not passed to consumer" unless ffi.fetch("outputs", {}).fetch("configuration-hash", "").include?("steps.ohttp-config.outputs.hash")
          swift = e2e.fetch("steps").find { |s| s["name"] == "Cache SwiftPM" }.fetch("with")
          abort "Swift product cache omits config" unless swift.fetch("key").include?("needs.ffi.outputs.configuration-hash")
          %w[needs.ffi.outputs.xcode-hash needs.ffi.outputs.source-hash].each { |field| abort "Swift product cache omits source/compiler identity" unless swift.fetch("key").include?(field) }
          abort "broad Swift cache fallback" unless swift.fetch("restore-keys", "").empty?
        ' "$REPO_ROOT/.github/workflows/ohttp-e2e.yml"
}

# Secret configuration must not be exposed by network-test diagnostics.
test_ohttp_e2e_diagnostics_do_not_print_configured_endpoints() {
    assert_succeeds 'E2E output keeps configured endpoint values private' python3 - "$REPO_ROOT/Tests/NetworkTests/OHTTPE2ETests.swift" <<'PYTHON'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
for line in source.splitlines():
    if re.search(r'\b(log|XCTAssertTrue)\(', line):
        assert not re.search(r'gateway=|relay=|tier0_ranked=\\\(tier0Hosts|\\\(host\\?\)', line), line
PYTHON
}
