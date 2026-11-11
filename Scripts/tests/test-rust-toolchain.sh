# Run the standalone CI validator contracts through the standard script harness.
test_rust_toolchain_validation() {
    assert_succeeds 'stable Rust validator unit and Actions boundary tests' \
        python3 -B -m unittest discover -s "$REPO_ROOT/Scripts/tests" -p test_rust_toolchain.py
}
