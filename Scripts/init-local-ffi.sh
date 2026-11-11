#!/bin/bash
# Initialize ARM64 local FFI development.
# --arm-macos, --arm-ios, --arm-simulator select subsets; --arm-all (or no flag)
# builds all three slices. --cached downloads the pinned ARM64 release.
# --trace enables OHTTP client trace ids for QA builds only; never ship it.
set -eo pipefail
cd "$(dirname "$0")/.."

export MACOSX_DEPLOYMENT_TARGET=14.0
export IPHONEOS_DEPLOYMENT_TARGET=16.0

usage() {
    echo "Error: $1" >&2
    cat >&2 <<'USAGE'
Usage: ./Scripts/init-local-ffi.sh [option] [--trace]
  (no option)      Build all three ARM64 slices from source.
  --arm-all        Build all three ARM64 slices from source.
  --arm-macos      Build only ARM64 macOS.
  --arm-ios        Build ARM64 iOS simulator and device.
  --arm-simulator  Build only ARM64 iOS simulator.
  --cached         Download the pinned canonical ARM64 release.
  --trace          QA build with the ohttp-trace feature; never ship it.
USAGE
    exit 1
}
FFI_CARGO_FEATURES=""
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--trace" ]]; then
        FFI_CARGO_FEATURES="ohttp-trace"
    else
        ARGS+=("$arg")
    fi
done
[[ ${#ARGS[@]} -le 1 ]] || usage 'Too many arguments; pass at most one option.'
CARGO_FEATURES=()
[[ -z "$FFI_CARGO_FEATURES" ]] || CARGO_FEATURES=(--features "$FFI_CARGO_FEATURES")
MODE=source
TARGETS=()
case "${ARGS[0]:-}" in
    '') MODE=full ;;
    --arm-all) TARGETS=(ios-sim ios-device macos) ;;
    --arm-macos) TARGETS=(macos) ;;
    --arm-ios) TARGETS=(ios-sim ios-device) ;;
    --arm-simulator) TARGETS=(ios-sim) ;;
    --cached) MODE=cached ;;
    *) usage "Unknown option: ${ARGS[0]}" ;;
esac

if [[ "$MODE" == cached && -n "$FFI_CARGO_FEATURES" ]]; then
    usage "--trace needs a source build; it cannot be combined with --cached."
fi

# Keep an explicitly selected compiler or fixture toolchain on PATH.
if ! command -v cargo >/dev/null 2>&1; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi

XCFRAMEWORK_DIR=LocalPackages/libzcashlc.xcframework
mkdir -p LocalPackages
STAGE=$(mktemp -d LocalPackages/.ffi-stage.XXXXXX)
STAGED_XCFW="$STAGE/libzcashlc.xcframework"
OLD_FRAMEWORK=false
OLD_WRAPPER=false
NEW_FRAMEWORK=false
NEW_WRAPPER=false
COMMITTED=false
cleanup() {
    local status=$?
    if [[ "$COMMITTED" != true ]]; then
        [[ "$NEW_WRAPPER" != true ]] || rm -f LocalPackages/Package.swift
        [[ "$NEW_FRAMEWORK" != true ]] || rm -rf "$XCFRAMEWORK_DIR"
        [[ "$OLD_FRAMEWORK" != true ]] || mv "$STAGE/previous.xcframework" "$XCFRAMEWORK_DIR"
        [[ "$OLD_WRAPPER" != true ]] || mv "$STAGE/previous-Package.swift" LocalPackages/Package.swift
    fi
    rm -rf "$STAGE"
    exit "$status"
}
trap cleanup EXIT

if [[ "$MODE" == full ]]; then
    (cd BuildSupport && make xcframework FFI_CARGO_FEATURES="$FFI_CARGO_FEATURES")
    cp -RP BuildSupport/products/libzcashlc.xcframework "$STAGED_XCFW"
elif [[ "$MODE" == cached ]]; then
    # The pinned URL and checksum always travel together; download into owned storage.
    read -r REPO SDK_VERSION EXPECTED_CHECKSUM < <(python3 - <<'PY'
import re
from pathlib import Path
text = Path('Package.swift').read_text()
match = re.search(r'https://github.com/([^/]+/[^/]+)/releases/download/([^/]+)/libzcashlc\.xcframework\.zip"\s*,\s*checksum:\s*"([a-f0-9]{64})"', text)
if match:
    print(*match.groups())
PY
    ) || { echo 'Error: Could not parse pinned libzcashlc URL and checksum.' >&2; exit 1; }
    gh release download "$SDK_VERSION" --repo "$REPO" --pattern libzcashlc.xcframework.zip --dir "$STAGE"
    ACTUAL_CHECKSUM=$(shasum -a 256 "$STAGE/libzcashlc.xcframework.zip" | awk '{print $1}')
    [[ "$ACTUAL_CHECKSUM" == "$EXPECTED_CHECKSUM" ]] || { echo 'Error: Checksum mismatch!' >&2; exit 1; }
    # Check every member before extracting anything. Release products are shallow:
    # links and special files are rejected, including entries outside the bundle.
    python3 - "$STAGE/libzcashlc.xcframework.zip" "$STAGE" <<'PY'
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile
archive, stage = sys.argv[1:]
with zipfile.ZipFile(archive) as source:
    seen = set()
    for item in source.infolist():
        path = PurePosixPath(item.filename)
        kind = stat.S_IFMT(item.external_attr >> 16)
        if (path.is_absolute() or '\\' in item.filename or '..' in path.parts
                or not path.parts or path.parts[0] != 'libzcashlc.xcframework'
                or kind not in (0, stat.S_IFREG, stat.S_IFDIR) or path in seen):
            raise ValueError('unsafe or duplicate archive member: ' + item.filename)
        seen.add(path)
    source.extractall(Path(stage))
PY
else
    mkdir -p "$STAGED_XCFW"
    SLICES=()
    for target in "${TARGETS[@]}"; do
        case "$target" in
            ios-sim) triple=aarch64-apple-ios-sim; slice=ios-arm64-simulator ;;
            ios-device) triple=aarch64-apple-ios; slice=ios-arm64 ;;
            macos) triple=aarch64-apple-darwin; slice=macos-arm64 ;;
        esac
        rustup target add "$triple"
        cargo build --locked --target "$triple" --release "${CARGO_FEATURES[@]}"
        framework="$STAGED_XCFW/$slice/libzcashlc.framework"
        mkdir -p "$framework/Headers" "$framework/Modules"
        cp "target/$triple/release/libzcashlc.a" "$framework/libzcashlc"
        cp BuildSupport/module.modulemap "$framework/Modules/"
        cp BuildSupport/platform-Info.plist "$framework/Info.plist"
        cp -R target/Headers/. "$framework/Headers/"
        SLICES+=("$slice")
    done
    python3 Scripts/lib/ffi_layout.py manifest "$STAGED_XCFW/Info.plist" "${SLICES[@]}"
fi

VALIDATION=()
[[ "$MODE" != full && "$MODE" != cached ]] || VALIDATION=(--require-full)
python3 Scripts/lib/ffi_layout.py validate "$STAGED_XCFW" "${VALIDATION[@]}"
if [[ -d "$STAGED_XCFW/macos-arm64" ]]; then
    ./Scripts/version-macos-framework.sh "$STAGED_XCFW/macos-arm64/libzcashlc.framework"
fi
python3 Scripts/lib/ffi_layout.py validate "$STAGED_XCFW" --allow-versioned-macos "${VALIDATION[@]}"
cp BuildSupport/LocalPackages-Package.swift "$STAGE/Package.swift"

# Same-filesystem renames with rollback keep the installed bundle and wrapper
# intact if either replacement fails. Old contents survive until both succeed.
if [[ -e "$XCFRAMEWORK_DIR" || -L "$XCFRAMEWORK_DIR" ]]; then
    mv "$XCFRAMEWORK_DIR" "$STAGE/previous.xcframework"
    OLD_FRAMEWORK=true
fi
if [[ -e LocalPackages/Package.swift || -L LocalPackages/Package.swift ]]; then
    mv LocalPackages/Package.swift "$STAGE/previous-Package.swift"
    OLD_WRAPPER=true
fi
mv "$STAGED_XCFW" "$XCFRAMEWORK_DIR"
NEW_FRAMEWORK=true
mv "$STAGE/Package.swift" LocalPackages/Package.swift
NEW_WRAPPER=true
COMMITTED=true

echo 'Local ARM64 FFI initialized at LocalPackages/.'
echo 'Use ARM64 Xcode destinations. Rebuild missing slices with rebuild-local-ffi.sh.'
if [[ "$MODE" == cached ]]; then
    echo 'Downloaded FFI may not match local source. Rebuild after Rust changes.'
fi
echo 'Open ZcashSDK.xcworkspace for automatic FFI rebuilds, or run swift build.'
echo 'To switch back to the release binary: ./Scripts/reset-local-ffi.sh'
