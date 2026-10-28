#!/usr/bin/env bash
# Identify committed FFI inputs, including packaging paths and executable modes.
set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [REPOSITORY]" >&2
    exit 1
fi

repo="$(git -C "${1:-.}" rev-parse --show-toplevel)"
required=(
    Cargo.toml Cargo.lock Makefile rust BuildSupport/Makefile
    BuildSupport/LocalPackages-Package.swift BuildSupport/module.modulemap
    BuildSupport/platform-Info.plist Scripts/init-local-ffi.sh
    Scripts/rebuild-local-ffi.sh Scripts/version-macos-framework.sh
)
for input in "${required[@]}"; do
    if ! git -C "$repo" cat-file -e "HEAD:$input"; then
        echo "Missing committed FFI input: $input" >&2
        exit 1
    fi
done

# ls-tree emits the mode, object identity and full path with NUL delimiters.
# Hash that stream directly so spaces/newlines and additions/deletions are safe.
# Generated products never enter the committed tree.
git -C "$repo" ls-tree -r -z HEAD -- \
    rust Cargo.toml Cargo.lock BuildSupport Makefile .cargo \
    rust-toolchain rust-toolchain.toml \
    Scripts/init-local-ffi.sh Scripts/rebuild-local-ffi.sh \
    Scripts/version-macos-framework.sh Scripts/prepare-release.sh \
    Scripts/release.sh Scripts/lib/release-lib.sh Scripts/ci/ffi-input-hash.sh \
    | shasum -a 256 | cut -d' ' -f1
