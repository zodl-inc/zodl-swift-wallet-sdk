#!/bin/bash
# Switch back to the released FFI binary and remove the local development
# environment. Safe to run repeatedly and in any half-switched state.
# Usage: ./Scripts/reset-local-ffi.sh

set -e
cd "$(dirname "$0")/.."

./Scripts/set-ffi-mode.sh release

if [[ -d "LocalPackages" ]]; then
    rm -rf LocalPackages/
    echo "Removed LocalPackages/."
fi

echo "Package.swift now uses the released FFI binary."
