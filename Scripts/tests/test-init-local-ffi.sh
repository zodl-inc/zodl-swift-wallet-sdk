# Offline argument-parsing tests for init-local-ffi.sh.
#
# init-local-ffi.sh parses its single optional flag at the top level (not
# inside a function), so these invoke the script directly rather than sourcing
# it. Every case here is rejected by argument validation before the script
# reaches cargo, rustup, or the network -- usage() calls exit 1 on its own,
# well before build_arm_xcframework or any download path runs. Accepting
# --arm-simulator is deliberately NOT exercised here, since that would compile
# Rust; it is covered by a separate functional smoke test instead.

_init_local_ffi() { "$REPO_ROOT/Scripts/init-local-ffi.sh" "$@"; }

test_init_local_ffi_is_executable() {
    assert_succeeds "init-local-ffi.sh is executable" \
        test -x "$REPO_ROOT/Scripts/init-local-ffi.sh"
}

test_init_local_ffi_rejects_unknown_option() {
    assert_fails "unknown option --frobnicate" _init_local_ffi --frobnicate
}

test_init_local_ffi_rejects_too_many_arguments() {
    assert_fails "too many arguments" _init_local_ffi foo bar
}

# usage() prints the full options list to stderr whenever parsing fails, so
# triggering it via one unrecognized option is enough to pin that the new
# flag is listed there.
test_init_local_ffi_usage_mentions_arm_simulator() {
    assert_succeeds "usage output mentions --arm-simulator" \
        sh -c "'$REPO_ROOT/Scripts/init-local-ffi.sh' --frobnicate 2>&1 | grep -qF -- --arm-simulator"
}

# The script documents its options a second time, in the header comment block
# above `set -e` -- read directly, never printed at runtime. Scoped to that
# block specifically so this can't pass merely because the case arm or the
# usage() heredoc mention the flag elsewhere in the file.
test_init_local_ffi_header_comment_mentions_arm_simulator() {
    assert_succeeds "header comment block documents --arm-simulator" \
        sh -c "sed -n '2,/^set -e/p' '$REPO_ROOT/Scripts/init-local-ffi.sh' | grep -qF -- --arm-simulator"
}
