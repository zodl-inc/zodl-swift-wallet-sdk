#!/bin/bash
# Switch Package.swift between the released FFI binary and the local build.
# Usage: ./Scripts/set-ffi-mode.sh {local|release}
#
# `local` requires LocalPackages/ to be set up (init-local-ffi.sh or
# `make configure-local-ffi`); `release` always works. The mode lives as a
# literal in Package.swift so that SwiftPM's manifest cache, which is keyed
# by the manifest's bytes, sees every mode change.

set -euo pipefail
cd "$(dirname "$0")/.."

. Scripts/lib/release-lib.sh

MODE="${1:-}"
case "$MODE" in
    local|release) ;;
    *)
        echo "Usage: ./Scripts/set-ffi-mode.sh {local|release}" >&2
        exit 1
        ;;
esac

if [[ "$MODE" == "local" && ! -f "LocalPackages/Package.swift" ]]; then
    echo "error: LocalPackages/ is not set up." >&2
    echo "       Run ./Scripts/init-local-ffi.sh or 'make configure-local-ffi' first." >&2
    exit 1
fi

if ! set_package_swift_ffi_mode Package.swift "$MODE"; then
    echo "error: Package.swift has no 'let useLocalFFI = ...' line to rewrite." >&2
    exit 1
fi
echo "Package.swift FFI mode: $MODE"

install_local_ffi_hook
