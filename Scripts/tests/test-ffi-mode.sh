# Tests for the Package.swift FFI-mode helpers.

test_package_swift_ffi_mode_reads_release() {
    assert_eq "release" "$(package_swift_ffi_mode "$(fixture Package.swift)")" \
        "package_swift_ffi_mode reads the committed (false) state as release"
}

test_package_swift_ffi_mode_reads_local() {
    local f; f="$(fixture Package.swift)"
    set_package_swift_ffi_mode "$f" local
    assert_eq "local" "$(package_swift_ffi_mode "$f")" \
        "package_swift_ffi_mode reads a flipped flag as local"
}

test_package_swift_ffi_mode_fails_without_flag() {
    local f; f="$SCRATCH/no-flag.swift"
    printf 'import PackageDescription\n' > "$f"
    assert_fails "package_swift_ffi_mode with no flag line" \
        package_swift_ffi_mode "$f"
}

test_set_ffi_mode_local_flips_the_literal() {
    local f; f="$(fixture Package.swift)"
    set_package_swift_ffi_mode "$f" local
    assert_file_contains "$f" "let useLocalFFI = true" \
        "set_package_swift_ffi_mode local writes true"
    assert_file_lacks "$f" "let useLocalFFI = false" \
        "set_package_swift_ffi_mode local leaves no false line"
}

test_set_ffi_mode_release_flips_back() {
    local f; f="$(fixture Package.swift)"
    set_package_swift_ffi_mode "$f" local
    set_package_swift_ffi_mode "$f" release
    assert_file_contains "$f" "let useLocalFFI = false" \
        "set_package_swift_ffi_mode release writes false"
}

test_set_ffi_mode_is_idempotent() {
    local f count; f="$(fixture Package.swift)"
    set_package_swift_ffi_mode "$f" local
    assert_succeeds "second set to the same mode" \
        set_package_swift_ffi_mode "$f" local
    count="$(grep -c '^let useLocalFFI = ' "$f")"
    assert_eq "1" "$count" "exactly one flag line survives repeated sets"
}

test_set_ffi_mode_rejects_unknown_mode() {
    assert_fails "set_package_swift_ffi_mode with a bogus mode" \
        set_package_swift_ffi_mode "$(fixture Package.swift)" bogus
}

test_set_ffi_mode_fails_without_flag_line() {
    local f; f="$SCRATCH/no-flag-set.swift"
    printf 'import PackageDescription\n' > "$f"
    assert_fails "set_package_swift_ffi_mode with no flag line" \
        set_package_swift_ffi_mode "$f" local
}

test_set_ffi_mode_leaves_the_rest_alone() {
    local f; f="$(fixture Package.swift)"
    set_package_swift_ffi_mode "$f" local
    assert_file_contains "$f" \
        "https://github.com/zcash/zcash-swift-wallet-sdk/releases/download/2.7.0-rc.3/libzcashlc.xcframework.zip" \
        "set_package_swift_ffi_mode does not disturb the binary target URL"
}
