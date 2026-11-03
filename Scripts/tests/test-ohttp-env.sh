# Keep runner privacy and native integration contracts in the standard suite.
test_ohttp_environment_runner() {
    assert_succeeds 'relay environment runner contracts' \
        python3 -B -m unittest discover -s "$REPO_ROOT/Scripts/tests" -p test_ohttp_env.py
}

# Pure native build-guard tests need neither private dependencies nor configuration.
test_ohttp_native_build_guard() {
    assert_succeeds 'native required-eight build guard compiles' \
        rustc --edition=2024 --test "$REPO_ROOT/rust/build_support/ohttp_config.rs" -o "$SCRATCH/ohttp-guard-tests"
    assert_succeeds 'native required-eight build guard contracts' "$SCRATCH/ohttp-guard-tests"
}
