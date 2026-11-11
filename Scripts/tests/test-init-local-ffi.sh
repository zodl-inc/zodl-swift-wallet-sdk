# Offline argument-parsing tests for init-local-ffi.sh.
#
# init-local-ffi.sh parses its single optional flag at the top level (not
# inside a function), so these invoke the script directly rather than sourcing
# it. Every case here is rejected by argument validation before the script
# reaches cargo, rustup, or the network -- usage() calls exit 1 on its own,
# well before native builds or any download path runs. The functional
# tests below cover accepted arm subsets with only the Cargo/toolchain boundary
# replaced, keeping compilation and network access out of this suite.

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

test_init_local_ffi_rejects_universal() {
    assert_fails "unsupported universal mode" _init_local_ffi --universal
}

test_init_local_ffi_rejects_trace_with_cached() {
    assert_fails "--trace with --cached" _init_local_ffi --cached --trace
}

test_init_local_ffi_rejects_too_many_arguments_with_trace() {
    assert_fails "too many arguments besides --trace" _init_local_ffi --trace foo bar
}
