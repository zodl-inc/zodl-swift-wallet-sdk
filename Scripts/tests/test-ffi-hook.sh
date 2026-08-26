# Tests for the local-FFI pre-commit guard and its installer.

_hook_repo() {
    # A scratch git repo whose path is printed. $1: the flag value to stage
    # in Package.swift, or "none" to stage only an unrelated file.
    local dir flag="$1"
    dir="$SCRATCH/hookrepo-$RANDOM"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
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

test_hook_rejects_staged_local_mode() {
    local dir; dir="$(_hook_repo true)"
    assert_fails "hook with staged useLocalFFI = true" \
        env -C "$dir" "$REPO_ROOT/Scripts/hooks/pre-commit"
}

test_hook_allows_staged_release_mode() {
    local dir; dir="$(_hook_repo false)"
    assert_succeeds "hook with staged useLocalFFI = false" \
        env -C "$dir" "$REPO_ROOT/Scripts/hooks/pre-commit"
}

test_hook_ignores_unstaged_local_mode() {
    local dir; dir="$(_hook_repo none)"
    assert_succeeds "hook with local-mode worktree but unstaged Package.swift" \
        env -C "$dir" "$REPO_ROOT/Scripts/hooks/pre-commit"
}

test_hook_escape_hatch() {
    local dir; dir="$(_hook_repo true)"
    assert_succeeds "hook with ZODL_ALLOW_LOCAL_FFI_COMMIT=1" \
        env -C "$dir" ZODL_ALLOW_LOCAL_FFI_COMMIT=1 "$REPO_ROOT/Scripts/hooks/pre-commit"
}

_installer_repo() {
    local dir
    dir="$SCRATCH/installrepo-$RANDOM"
    mkdir -p "$dir/Scripts/hooks"
    cp "$REPO_ROOT/Scripts/hooks/pre-commit" "$dir/Scripts/hooks/pre-commit"
    ( cd "$dir" && git init -q )
    printf '%s\n' "$dir"
}

test_installer_installs_hook() {
    local dir; dir="$(_installer_repo)"
    ( cd "$dir" && install_local_ffi_hook ) || _fail "installer failed"
    _assertions=$((_assertions + 1))
    [ -x "$dir/.git/hooks/pre-commit" ] || _fail "hook not installed executable"
}

test_installer_preserves_foreign_hook() {
    local dir; dir="$(_installer_repo)"
    printf '#!/bin/sh\nexit 0\n' > "$dir/.git/hooks/pre-commit"
    ( cd "$dir" && install_local_ffi_hook 2>/dev/null )
    assert_file_lacks "$dir/.git/hooks/pre-commit" "zodl-swift-wallet-sdk local-FFI guard" \
        "installer leaves a foreign pre-commit hook untouched"
}

test_installer_updates_own_hook() {
    local dir; dir="$(_installer_repo)"
    printf '#!/bin/sh\n# zodl-swift-wallet-sdk local-FFI guard (old)\nexit 0\n' \
        > "$dir/.git/hooks/pre-commit"
    ( cd "$dir" && install_local_ffi_hook )
    assert_file_contains "$dir/.git/hooks/pre-commit" "git diff --cached" \
        "installer refreshes a hook it owns"
}
