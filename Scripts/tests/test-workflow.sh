# Offline, text-only checks on .github/workflows/build-ffi.yml.
#
# These never invoke gh or dispatch anything; they just read the checked-in
# YAML. They exist to pin two properties from Finding 1's fix:
#
#   - the workflow accepts a `force` input and reads it into the build step
#     via `env:`, so `prepare-release.sh build --artifacts ci --rebuild` has
#     something to forward to;
#   - no `${{ }}` expression is interpolated directly into a `run:` script.
#     Template injection into `run:` is exactly what this repository's
#     zizmor lint flags; every workflow input must instead flow in through
#     `env:` and be read back as a shell variable.

_workflow_file() { printf '%s\n' "$REPO_ROOT/.github/workflows/build-ffi.yml"; }

test_build_ffi_workflow_declares_force_input() {
    assert_succeeds "build-ffi.yml declares a force input" \
        grep -q '^      force:' "$(_workflow_file)"
}

test_build_ffi_workflow_reads_force_via_env() {
    assert_succeeds "build-ffi.yml's build step reads FORCE from env, not inline" \
        grep -qF 'FORCE: ${{ github.event.inputs.force }}' "$(_workflow_file)"
}

test_build_ffi_workflow_branches_on_force_in_shell() {
    assert_succeeds "build-ffi.yml's run script branches on \$FORCE" \
        grep -qF '[ "$FORCE" = "true" ]' "$(_workflow_file)"
}

test_build_ffi_workflow_force_path_passes_force_overwrite_flag() {
    assert_succeeds "the \$FORCE=true branch passes --force-overwrite-existing-release" \
        grep -qF -- '--force-overwrite-existing-release "$VERSION"' "$(_workflow_file)"
}

# Report every `${{ }}` that reaches a `run:` script -- spliced into a one-line
# `run:`, or sitting in its block scalar. Those are the injection vectors: the
# runner expands them into shell text before bash sees the script. An
# expression anywhere else (an `env:` value, a `with:` input, a cache `key:`)
# is consumed by the runner or by an action, never by the shell, so it is not
# reported. A `run:` block ends at the first non-blank line indented no deeper
# than the `run:` key itself.
_run_script_interpolations() {
    awk '
        /^[[:space:]]*(- )?run:/ {
            in_run = 1
            run_indent = index($0, "run:") - 1
            if ($0 ~ /\$\{\{/) printf "%d: %s\n", NR, $0
            next
        }
        in_run {
            if ($0 ~ /^[[:space:]]*$/) next
            if (match($0, /[^[:space:]]/) - 1 <= run_indent) { in_run = 0; next }
            if ($0 ~ /\$\{\{/) printf "%d: %s\n", NR, $0
        }
    ' "$1"
}

test_build_ffi_workflow_interpolates_nothing_into_run_scripts() {
    assert_eq "" "$(_run_script_interpolations "$(_workflow_file)")" \
        "no \${{ }} in build-ffi.yml reaches a run: script"
}

# The guard above is a grep that is supposed to find nothing, so a scanner that
# silently matched nothing would pass it forever. Point it at a workflow that
# does splice an expression into `run:` and require it to notice.
test_run_script_interpolation_scanner_detects_an_injection() {
    local f; f="$SCRATCH/injected-workflow.yml"
    cat > "$f" <<'YAML'
jobs:
  build:
    steps:
      - name: Safe input, not shell text
        uses: ./.github/actions/authorize
        with:
          app-id: ${{ secrets.APP_ID }}
      - name: Safe cache key, not shell text
        uses: actions/cache@v4
        with:
          key: ${{ runner.os }}-cargo-v1-${{ hashFiles('Cargo.lock') }}
          restore-keys: |
            ${{ runner.os }}-cargo-v1-
      - name: Reads its input the safe way
        env:
          VERSION: ${{ github.event.inputs.version }}
        run: ./Scripts/build.sh "$VERSION"
      - name: Splices its input into the script
        run: |
          ./Scripts/build.sh ${{ github.event.inputs.version }}
YAML
    assert_eq "20:           ./Scripts/build.sh \${{ github.event.inputs.version }}" \
        "$(_run_script_interpolations "$f")" \
        "the scanner flags the run: splice and nothing else"
}
