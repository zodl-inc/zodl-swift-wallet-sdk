# Tests for the file-reading helpers in Scripts/ci/build-release-artifacts.sh.

test_cargo_package_version_reads_package_table() {
    assert_eq "2.7.0-rc.3" "$(cargo_package_version "$(fixture Cargo.toml)")" \
        "cargo_package_version reads [package].version"
}
