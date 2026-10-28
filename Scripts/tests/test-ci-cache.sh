# shellcheck shell=bash disable=SC2016
# Literal shell/GitHub expressions are fixtures, evaluated by their consumers.
# Real Git/Cargo fixtures exercise the cache input and lockfile boundaries.
_ffi_fixture() {
    local repo
    repo="$(mktemp -d "$SCRATCH/ffi-repo.XXXXXX")"
    git -C "$repo" init -q
    git -C "$repo" config user.name 'Cache Tests'
    git -C "$repo" config user.email 'cache-tests@example.invalid'
    mkdir -p "$repo/rust" "$repo/BuildSupport" "$repo/Scripts"
    local input
    for input in Cargo.toml Cargo.lock Makefile rust/lib.rs BuildSupport/Makefile \
        BuildSupport/LocalPackages-Package.swift BuildSupport/module.modulemap \
        BuildSupport/platform-Info.plist Scripts/init-local-ffi.sh \
        Scripts/rebuild-local-ffi.sh Scripts/version-macos-framework.sh; do
        printf 'fixture\n' > "$repo/$input"
    done
    printf 'BuildSupport/products/\n' > "$repo/.gitignore"
    _ffi_commit "$repo"
    printf '%s\n' "$repo"
}

_ffi_commit() {
    git -C "$1" add -A
    git -C "$1" -c commit.gpgsign=false commit -qm fixture
}

_ffi_hash() { "$REPO_ROOT/Scripts/ci/ffi-input-hash.sh" "$1"; }

_assert_hash_changed() {
    local before="$1" repo="$2" label="$3" after
    _ffi_commit "$repo"
    after="$(_ffi_hash "$repo")"
    assert_succeeds "$label" test "$before" != "$after"
}

test_ffi_hash_is_stable() {
    local repo clone first second
    repo="$(_ffi_fixture)"
    clone="$(mktemp -d "$SCRATCH/ffi-clone.XXXXXX")"
    git clone -q "$repo" "$clone"
    first="$(_ffi_hash "$repo")"
    second="$(_ffi_hash "$clone")"
    assert_succeeds 'hash is exactly one lowercase SHA-256' \
        bash -c '[[ "$1" =~ ^[0-9a-f]{64}$ ]]' bash "$first"
    assert_eq "$first" "$second" 'equal committed trees have the same identity'
}

test_ffi_hash_covers_packaging() {
    local repo input before
    repo="$(_ffi_fixture)"
    for input in BuildSupport/LocalPackages-Package.swift BuildSupport/module.modulemap \
        BuildSupport/platform-Info.plist Scripts/version-macos-framework.sh; do
        before="$(_ffi_hash "$repo")"
        printf 'changed\n' >> "$repo/$input"
        _assert_hash_changed "$before" "$repo" "hash changes for $input"
    done
}

test_ffi_hash_covers_add_delete_and_space_paths() {
    local repo before
    repo="$(_ffi_fixture)"
    before="$(_ffi_hash "$repo")"
    printf 'package\n' > "$repo/BuildSupport/extra package.swift"
    _assert_hash_changed "$before" "$repo" 'tracked packaging addition changes hash'
    before="$(_ffi_hash "$repo")"
    mv "$repo/BuildSupport/extra package.swift" "$repo/BuildSupport/renamed package.swift"
    _assert_hash_changed "$before" "$repo" 'tracked packaging rename changes hash'
    before="$(_ffi_hash "$repo")"
    chmod +x "$repo/BuildSupport/renamed package.swift"
    _assert_hash_changed "$before" "$repo" 'tracked packaging mode changes hash'
    before="$(_ffi_hash "$repo")"
    rm "$repo/BuildSupport/renamed package.swift"
    _assert_hash_changed "$before" "$repo" 'tracked packaging deletion changes hash'
}

test_ffi_hash_covers_optional_toolchain_inputs() {
    local repo input before
    repo="$(_ffi_fixture)"
    mkdir "$repo/.cargo"
    for input in .cargo/config.toml rust-toolchain rust-toolchain.toml; do
        before="$(_ffi_hash "$repo")"
        printf 'toolchain\n' > "$repo/$input"
        _assert_hash_changed "$before" "$repo" "hash covers $input"
    done
}

test_ffi_hash_ignores_untracked_products() {
    local repo before
    repo="$(_ffi_fixture)"
    before="$(_ffi_hash "$repo")"
    mkdir -p "$repo/BuildSupport/products"
    printf 'binary\n' > "$repo/BuildSupport/products/libzcashlc.a"
    printf 'scratch\n' > "$repo/BuildSupport/untracked.swift"
    assert_eq "$before" "$(_ffi_hash "$repo")" 'ignored products and untracked files do not change hash'
}

test_ffi_hash_rejects_invalid_inputs() {
    local repo input copy
    assert_fails 'non-repository fails' _ffi_hash "$SCRATCH"
    repo="$(_ffi_fixture)"
    for input in Cargo.toml Cargo.lock Makefile rust BuildSupport/Makefile \
        BuildSupport/LocalPackages-Package.swift BuildSupport/module.modulemap \
        BuildSupport/platform-Info.plist Scripts/init-local-ffi.sh \
        Scripts/rebuild-local-ffi.sh Scripts/version-macos-framework.sh; do
        copy="$(mktemp -d "$SCRATCH/ffi-missing.XXXXXX")"
        git clone -q "$repo" "$copy"
        git -C "$copy" rm -qr "$input"
        _ffi_commit "$copy"
        assert_fails "missing committed $input fails" _ffi_hash "$copy"
    done
}

# Read the flags of the real entrypoints, then use those flags with a tiny
# offline crate. Removing --locked must allow drift and fail this regression.
_locked_entrypoint_flags() {
    local target="$1"
    if [ "$target" = initializer ]; then
        grep '^[[:space:]]*cargo build ' "$REPO_ROOT/Scripts/init-local-ffi.sh"
    else
        cat "$(_dry_run "$target")"
    fi | grep -E 'cargo (build|test)' | head -1 | grep -o -- '--locked' || true
}

test_ci_cargo_commands_are_locked() {
    local target output commands locked
    for target in ffi-ci ffi-all test-rust; do
        output="$(_dry_run "$target")"
        commands="$(grep -Ec 'cargo (build|test)' "$output")"
        locked="$(grep -E 'cargo (build|test)' "$output" | grep -c -- '--locked' || true)"
        assert_succeeds "$target invokes cargo" test "$commands" -gt 0
        assert_eq "$commands" "$locked" "$target locks every Cargo invocation"
    done
    assert_eq '--locked' "$(_locked_entrypoint_flags initializer)" 'arm initializer locks its direct Cargo build'
}

test_locked_manifest_drift() {
    local repo target flags before after
    repo="$(mktemp -d "$SCRATCH/locked-crate.XXXXXX")"
    mkdir -p "$repo/src" "$repo/dependency/src"
    printf '[package]\nname="lock-fixture"\nversion="0.1.0"\nedition="2021"\n[dependencies]\nlocal-dependency={path="dependency"}\n' > "$repo/Cargo.toml"
    printf '[package]\nname="local-dependency"\nversion="0.1.0"\nedition="2021"\n' > "$repo/dependency/Cargo.toml"
    printf 'pub fn fixture() {}\n' > "$repo/src/lib.rs"
    printf 'pub fn fixture() {}\n' > "$repo/dependency/src/lib.rs"
    assert_succeeds 'fixture lock generates offline' cargo generate-lockfile --offline --manifest-path "$repo/Cargo.toml"
    cp "$repo/Cargo.lock" "$repo/original.lock"
    for target in ffi-ci ffi-all test-rust initializer; do
        flags="$(_locked_entrypoint_flags "$target")"
        cp "$repo/original.lock" "$repo/Cargo.lock"
        sed 's/version="0.1.0"/version="0.2.0"/' "$repo/dependency/Cargo.toml" > "$repo/dependency/changed.toml"
        mv "$repo/dependency/changed.toml" "$repo/dependency/Cargo.toml"
        before="$(shasum -a 256 "$repo/Cargo.lock")"
        # An absent lock flag intentionally passes no argument in the RED run.
        assert_fails "$target flags reject manifest drift offline" \
            cargo metadata --offline ${flags:+"$flags"} --format-version 1 --manifest-path "$repo/Cargo.toml"
        after="$(shasum -a 256 "$repo/Cargo.lock")"
        assert_eq "$before" "$after" "$target leaves the lockfile unchanged on drift"
        sed 's/version="0.2.0"/version="0.1.0"/' "$repo/dependency/Cargo.toml" > "$repo/dependency/changed.toml"
        mv "$repo/dependency/changed.toml" "$repo/dependency/Cargo.toml"
        cp "$repo/original.lock" "$repo/Cargo.lock"
        assert_succeeds "$target flags accept matching manifests offline" \
            cargo metadata --offline ${flags:+"$flags"} --format-version 1 --manifest-path "$repo/Cargo.toml"
    done
}

# Archive the workflow's actual path list in a populated fixture. A widened
# path would include sibling build products, test output or credentials.
test_swift_dependency_archive_excludes_products_and_credentials() {
    local fixture step paths item
    fixture="$(mktemp -d "$SCRATCH/swift-dependencies.XXXXXX")"
    for item in .build/repositories/repo.git/HEAD .build/checkouts/package/Package.swift \
        .build/artifacts/library/library.zip .build/arm64-apple-macosx/debug/SDK.o \
        .build/debug/test-results .build/workspace-state.json .build/artifacts-old/compiled \
        LocalPackages/library.a .git-credentials .gitconfig; do
        mkdir -p "$fixture/$(dirname "$item")"
        printf 'fixture\n' > "$fixture/$item"
    done
    for step in 'Restore SwiftPM dependencies' 'Save SwiftPM dependencies'; do
        paths="$SCRATCH/swift-dependency-paths.txt"
        _swift_dependency_paths "$step" > "$paths"
        assert_succeeds "$step has dependency paths to archive" test -s "$paths"
        tar -cf "$SCRATCH/swift-dependencies.tar" -C "$fixture" -T "$paths"
        tar -tf "$SCRATCH/swift-dependencies.tar" | sed '/\/$/d' | sort > "$SCRATCH/swift-archive.txt"
        assert_eq "$(printf '.build/artifacts/library/library.zip\n.build/checkouts/package/Package.swift\n.build/repositories/repo.git/HEAD')" "$(cat "$SCRATCH/swift-archive.txt")" "$step archives only dependency content, excluding compiled output tests and credentials"
    done
}
