# prepare-release.sh is a deprecation stub: every invocation fails and points
# at the replacement. These must not touch git, the network or the checkout.

_prepare() { "$REPO_ROOT/Scripts/prepare-release.sh" "$@"; }

test_prepare_release_is_executable() {
    assert_succeeds "prepare-release.sh is executable" \
        test -x "$REPO_ROOT/Scripts/prepare-release.sh"
}

test_prepare_release_is_deprecated_for_every_invocation() {
    local args err needle
    for args in "" "--help" "start --issue 1 upstream 2.7.1" \
                "build upstream 2.7.1" "artifacts 2.7.1"; do
        # shellcheck disable=SC2086 # word splitting of the argument list is intended
        assert_fails "prepare-release.sh $args exits non-zero" _prepare $args
        # shellcheck disable=SC2086
        err="$(_prepare $args 2>&1 >/dev/null)"
        for needle in deprecated "shared ZODL skills library" \
                      Scripts/ci/build-release-artifacts.sh; do
            case "$err" in
                *"$needle"*) assert_eq "x" "x" "prepare-release.sh $args names $needle" ;;
                *) assert_eq "contains $needle" "does not" "prepare-release.sh $args names $needle" ;;
            esac
        done
        # The notice also reaches the public twin, so it names no repository
        # (no organization slug) and no skill identifier.
        for needle in zodl-inc/ zodl_; do
            case "$err" in
                *"$needle"*) assert_eq "omits $needle" "contains it" "prepare-release.sh $args omits $needle" ;;
                *) assert_eq "x" "x" "prepare-release.sh $args omits $needle" ;;
            esac
        done
    done
}

test_prepare_release_stub_needs_no_git_checkout() {
    local err rc=0
    err="$(cd "$SCRATCH" && "$REPO_ROOT/Scripts/prepare-release.sh" start upstream 2.7.1 2>&1 >/dev/null)" || rc=$?
    assert_eq "1" "$rc" "stub exits 1 outside a git checkout"
    case "$err" in
        *deprecated*) assert_eq "x" "x" "stub reports deprecation outside a checkout" ;;
        *) assert_eq "deprecated" "$err" "stub reports deprecation outside a checkout" ;;
    esac
}

test_release_tooling_is_gone() {
    assert_fails "the release script is removed" test -e "$REPO_ROOT/Scripts/release"".sh"
    assert_fails "the release library is removed" test -e "$REPO_ROOT/Scripts/lib/release""-lib.sh"
}

test_native_sdk_build_record_suite() {
    assert_succeeds "native artifacts source and build evidence" \
        python3 -m unittest discover -s "$REPO_ROOT/Scripts/tests" -p test_sdk_build_record.py
}

# Release requests must reject metadata even in dry runs with evidence disabled.
test_native_metadata_policy() {
    assert_succeeds "native release metadata requests stop before effects" \
        python3 -B -m unittest discover -s "$REPO_ROOT/Scripts/tests" -p test_sdk_build_record.py -k metadata
}

test_native_request_policy_preserves_prereleases() {
    local version
    for version in 5.0.0 5.0.0-rc.1 5.0.0-alpha.7; do
        assert_succeeds "supported request $version" require_supported_release_version "$version"
    done
}
