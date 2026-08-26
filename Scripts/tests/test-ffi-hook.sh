# Tests for the local-FFI pre-commit guard and its installer.

_hook_repo() {
    # A scratch git repo whose path is printed. $1: the flag value to stage
    # in Package.swift, or "none" to stage only an unrelated file.
    local dir flag="$1"
    dir="$SCRATCH/hookrepo-$RANDOM"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        git init -q
        if [ "$flag" = "none" ]; then
            printf 'let useLocalFFI = true\n' > Package.swift
            printf 'x\n' > other.txt
            git add other.txt
        else
            printf 'let useLocalFFI = %s\n' "$flag" > Package.swift
            git add Package.swift
        fi
    ) || return 1
    printf '%s\n' "$dir"
}

# Run the hook with cwd set to $1. A `( cd ... )` subshell rather than
# `env -C`: `-C` is a BSD-env extension (FreeBSD 14.2+, Nov 2024) that
# macos-15 -- the image swift.yml's CI runs on -- predates, so it is not
# portable enough for a test this suite must run there. Wrapped in a function
# because assert_succeeds/assert_fails invoke their argument list as "$@",
# and a bare subshell cannot be handed to them as data -- only a function or
# external command can.
_run_hook_in() {
    local dir="$1"
    ( cd "$dir" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null &&
        "$REPO_ROOT/Scripts/hooks/pre-commit" )
}

# Same, but with the escape hatch set for the hook process. The assignment is
# written literally here (not forwarded through "$@") because bash only
# recognizes a NAME=value word as an environment assignment when it is a
# literal token in the source at parse time -- one produced by expanding a
# positional parameter is just an ordinary argument, so forwarding it would
# leave the variable unset and the hook would see none of it.
_run_hook_in_with_override() {
    local dir="$1"
    ( cd "$dir" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null &&
        ZODL_ALLOW_LOCAL_FFI_COMMIT=1 "$REPO_ROOT/Scripts/hooks/pre-commit" )
}

test_hook_rejects_staged_local_mode() {
    local dir; dir="$(_hook_repo true)"
    assert_fails "hook with staged useLocalFFI = true" \
        _run_hook_in "$dir"
}

test_hook_allows_staged_release_mode() {
    local dir; dir="$(_hook_repo false)"
    assert_succeeds "hook with staged useLocalFFI = false" \
        _run_hook_in "$dir"
}

test_hook_ignores_unstaged_local_mode() {
    local dir; dir="$(_hook_repo none)"
    assert_succeeds "hook with local-mode worktree but unstaged Package.swift" \
        _run_hook_in "$dir"
}

test_hook_escape_hatch() {
    local dir; dir="$(_hook_repo true)"
    assert_succeeds "hook with ZODL_ALLOW_LOCAL_FFI_COMMIT=1" \
        _run_hook_in_with_override "$dir"
}

_installer_repo() {
    local dir
    dir="$SCRATCH/installrepo-$RANDOM"
    mkdir -p "$dir/Scripts/hooks"
    cp "$REPO_ROOT/Scripts/hooks/pre-commit" "$dir/Scripts/hooks/pre-commit"
    ( cd "$dir" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null && git init -q )
    printf '%s\n' "$dir"
}

test_installer_installs_hook() {
    local dir; dir="$(_installer_repo)"
    ( cd "$dir" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null &&
        install_local_ffi_hook ) || _fail "installer failed"
    _assertions=$((_assertions + 1))
    [ -x "$dir/.git/hooks/pre-commit" ] || _fail "hook not installed executable"
}

test_installer_preserves_foreign_hook() {
    local dir; dir="$(_installer_repo)"
    printf '#!/bin/sh\nexit 0\n' > "$dir/.git/hooks/pre-commit"
    ( cd "$dir" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null &&
        install_local_ffi_hook 2>/dev/null )
    assert_file_lacks "$dir/.git/hooks/pre-commit" "zodl-swift-wallet-sdk local-FFI guard" \
        "installer leaves a foreign pre-commit hook untouched"
}

test_installer_updates_own_hook() {
    local dir; dir="$(_installer_repo)"
    printf '#!/bin/sh\n# zodl-swift-wallet-sdk local-FFI guard (old)\nexit 0\n' \
        > "$dir/.git/hooks/pre-commit"
    ( cd "$dir" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null &&
        install_local_ffi_hook )
    assert_file_contains "$dir/.git/hooks/pre-commit" "git diff --cached" \
        "installer refreshes a hook it owns"
}
