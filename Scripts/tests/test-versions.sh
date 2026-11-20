# Tests for the version helpers in Scripts/ci/build-release-artifacts.sh.

test_is_prerelease_true_for_rc() {
    assert_succeeds "is_prerelease 2.8.0-rc.1" is_prerelease 2.8.0-rc.1
}

test_is_prerelease_true_for_alpha() {
    assert_succeeds "is_prerelease 2.6.0-alpha.6" is_prerelease 2.6.0-alpha.6
}

test_is_prerelease_false_for_release() {
    assert_fails "is_prerelease 2.8.0" is_prerelease 2.8.0
}

# The pre-release bit is stated in both directions. Only asserting the positive
# case would let `prerelease_flag` emit nothing for a release and still pass,
# which is exactly the state a re-uploaded draft must be able to leave behind.
test_prerelease_flag_marks_a_prerelease() {
    assert_eq "--prerelease=true" "$(prerelease_flag 2.8.0-rc.1)" \
        "prerelease_flag 2.8.0-rc.1"
}

test_prerelease_flag_unmarks_a_release() {
    assert_eq "--prerelease=false" "$(prerelease_flag 2.8.0)" \
        "prerelease_flag 2.8.0"
}
