#!/bin/bash
# Incrementally rebuild one ARM64 slice, preserving validated canonical slices.
# --trace enables OHTTP client trace ids for QA builds only; never ship it.
# Usage: ./Scripts/rebuild-local-ffi.sh [ios-sim|ios-device|macos] [--gpu] [--trace]
set -eo pipefail
cd "$(dirname "$0")/.."

export MACOSX_DEPLOYMENT_TARGET=14.0
export IPHONEOS_DEPLOYMENT_TARGET=16.0
TARGET=ios-sim
CARGO_FEATURES=""
for arg in "$@"; do
    case "$arg" in
        ios-sim|ios-device|macos) TARGET="$arg" ;;
        --gpu) CARGO_FEATURES="${CARGO_FEATURES:+$CARGO_FEATURES,}gpu" ;;
        --trace) CARGO_FEATURES="${CARGO_FEATURES:+$CARGO_FEATURES,}ohttp-trace" ;;
        *) echo "Unknown arg: $arg" >&2; echo 'Usage: rebuild-local-ffi.sh [ios-sim|ios-device|macos] [--gpu] [--trace]' >&2; exit 1 ;;
    esac
done
FEATURE_ARGS=()
[[ -z "$CARGO_FEATURES" ]] || FEATURE_ARGS=(--features "$CARGO_FEATURES")

XCFRAMEWORK_DIR=LocalPackages/libzcashlc.xcframework
if ! python3 Scripts/lib/ffi_layout.py validate "$XCFRAMEWORK_DIR" --allow-versioned-macos; then
    echo 'Error: Local FFI is missing or incompatible. Reinitialize with ./Scripts/init-local-ffi.sh (or an --arm-* subset).' >&2
    exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi
case "$TARGET" in
    ios-sim) RUST_TARGET=aarch64-apple-ios-sim; SLICE=ios-arm64-simulator ;;
    ios-device) RUST_TARGET=aarch64-apple-ios; SLICE=ios-arm64 ;;
    macos) RUST_TARGET=aarch64-apple-darwin; SLICE=macos-arm64 ;;
esac
rustup target add "$RUST_TARGET"
cargo build --locked --target "$RUST_TARGET" --release "${FEATURE_ARGS[@]}"

STAGE=$(mktemp -d LocalPackages/.ffi-stage.XXXXXX)
STAGED_XCFW="$STAGE/libzcashlc.xcframework"
OLD_FRAMEWORK=false
NEW_FRAMEWORK=false
COMMITTED=false
cleanup() {
    local status=$?
    if [[ "$COMMITTED" != true ]]; then
        [[ "$NEW_FRAMEWORK" != true ]] || rm -rf "$XCFRAMEWORK_DIR"
        [[ "$OLD_FRAMEWORK" != true ]] || mv "$STAGE/previous.xcframework" "$XCFRAMEWORK_DIR"
    fi
    rm -rf "$STAGE"
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$STAGED_XCFW"
SLICES=()
for path in "$XCFRAMEWORK_DIR"/*/; do
    slice=$(basename "$path")
    if [[ "$slice" != "$SLICE" ]]; then
        cp -RP "$path" "$STAGED_XCFW/$slice"
        SLICES+=("$slice")
        echo "Warning: preserved existing slice '$slice' — NOT rebuilt; check its ENGINE_BUILD tag before trusting it."
    fi
done
framework="$STAGED_XCFW/$SLICE/libzcashlc.framework"
mkdir -p "$framework/Headers" "$framework/Modules"
cp "target/$RUST_TARGET/release/libzcashlc.a" "$framework/libzcashlc"
cp BuildSupport/module.modulemap "$framework/Modules/"
cp BuildSupport/platform-Info.plist "$framework/Info.plist"
cp -R target/Headers/. "$framework/Headers/"
if [[ "$TARGET" == macos ]]; then
    ./Scripts/version-macos-framework.sh "$framework"
fi
SLICES+=("$SLICE")
# Canonical manifest ordering also keeps unchanged platform metadata stable.
IFS=$'\n' SLICES=($(printf '%s\n' "${SLICES[@]}" | sort))
unset IFS
python3 Scripts/lib/ffi_layout.py manifest "$STAGED_XCFW/Info.plist" "${SLICES[@]}"
python3 Scripts/lib/ffi_layout.py validate "$STAGED_XCFW" --allow-versioned-macos
mv "$XCFRAMEWORK_DIR" "$STAGE/previous.xcframework"
OLD_FRAMEWORK=true
mv "$STAGED_XCFW" "$XCFRAMEWORK_DIR"
NEW_FRAMEWORK=true
COMMITTED=true

echo "Rebuilt $TARGET (arm64) in $XCFRAMEWORK_DIR."
echo 'Other platforms were preserved as-is. Check ENGINE_BUILD after Rust changes.'
echo 'Run ./Scripts/init-local-ffi.sh --arm-all to rebuild every slice fresh.'
