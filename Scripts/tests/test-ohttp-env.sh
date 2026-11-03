# Keep runner privacy and native integration contracts in the standard suite.
test_ohttp_environment_runner() {
    assert_succeeds 'relay environment runner contracts' \
        python3 -B -m unittest discover -s "$REPO_ROOT/Scripts/tests" -p test_ohttp_env.py
}
