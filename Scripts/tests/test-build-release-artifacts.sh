# Offline argument-validation tests for Scripts/ci/build-release-artifacts.sh.
#
# These must not reach the network or start a build: each asserts something
# argument parsing or the file itself settles. The producer is never sourced at
# the top level of this file, because the harness sources every test file into
# one shell.

_producer() { "$REPO_ROOT/Scripts/ci/build-release-artifacts.sh" "$@"; }

test_build_release_artifacts_is_executable() {
    assert_succeeds "build-release-artifacts.sh is executable" \
        test -x "$REPO_ROOT/Scripts/ci/build-release-artifacts.sh"
}

test_build_release_artifacts_help_succeeds() {
    assert_succeeds "--help" _producer --help
}

test_build_release_artifacts_help_documents_skip_verify() {
    assert_succeeds "--help documents --skip-verify" \
        bash -c '"$1" --help | grep -q -- --skip-verify' _ \
        "$REPO_ROOT/Scripts/ci/build-release-artifacts.sh"
}

test_build_release_artifacts_help_restricts_overwrite_to_drafts() {
    assert_succeeds "--help restricts overwrite to drafts" \
        bash -c '"$1" --help | grep -A1 -- --force-overwrite-existing-release | grep -q DRAFT' _ \
        "$REPO_ROOT/Scripts/ci/build-release-artifacts.sh"
}

test_build_release_artifacts_without_version_fails() {
    assert_fails "no version" _producer
}

test_build_release_artifacts_unknown_option_fails() {
    assert_fails "unknown option" _producer --frobnicate 2.7.1
}

test_build_release_artifacts_unknown_option_after_version_fails() {
    assert_fails "unknown option after the version" _producer 2.7.1 --frobnicate
}

test_build_release_artifacts_runs_from_a_subdirectory() {
    assert_succeeds "--help from Scripts/" \
        bash -c 'cd "$1/Scripts" && ./ci/build-release-artifacts.sh --help' _ "$REPO_ROOT"
}

test_build_release_artifacts_sourcing_has_no_side_effects() {
    assert_succeeds "sourcing defines functions and changes nothing" \
        bash -c 'cd "$1" && . "$2" && [ "$PWD" = "$1" ] && type produce_artifacts >/dev/null && case $- in *e*) exit 1;; esac' \
        _ "$SCRATCH" "$REPO_ROOT/Scripts/ci/build-release-artifacts.sh"
}

test_build_release_artifacts_carries_the_native_record_markers() {
    assert_file_contains "$REPO_ROOT/Scripts/ci/build-release-artifacts.sh" 'ZODL_SDK_BUILD_RECORD' 'names the build-record switch'
    assert_file_contains "$REPO_ROOT/Scripts/ci/build-release-artifacts.sh" 'sdk_build_record.py' 'names the build-record tool'
}
