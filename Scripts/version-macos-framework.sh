#!/usr/bin/env bash
#
# version-macos-framework.sh — convert a SHALLOW libzcashlc.framework into the
# VERSIONED bundle layout that macOS requires for an embedded framework.
#
# Why: BuildSupport/Makefile assembles every platform's framework identically —
# a flat `libzcashlc.framework/{libzcashlc,Headers,Modules,Info.plist}` with the
# shared `platform-Info.plist` (which is the iOS-simulator one: CFBundlePackageType
# BNDL, CFBundleSupportedPlatforms [iphonesimulator]). That is fine for iOS (shallow
# bundles), but macOS embedding fails with:
#   "... contains Info.plist, expected Versions/Current/Resources/Info.plist
#    since the platform does not use shallow bundles".
# This rewrites the macOS slice into Versions/A/... with the proper symlinks and a
# correct macOS Info.plist (FMWK / MacOSX / LSMinimumSystemVersion). Idempotent.
# BuildSupport/Makefile runs it on every macOS framework it assembles, so release
# products (`ffi-all`, `ffi-macos`, `ffi-ci`) carry the versioned layout too, and
# `make configure-local-ffi` runs it only on products built before that change.
#
# Usage:
#   ./Scripts/version-macos-framework.sh <path/to/libzcashlc.framework>
# Default (no arg): the macOS slice inside the local-FFI xcframework.

set -euo pipefail

NAME="libzcashlc"
# The version source is located relative to this script, not the working directory:
# the Makefile runs it from BuildSupport/ while other callers run it from the root.
PLATFORM_PLIST="$(dirname "${BASH_SOURCE[0]}")/../BuildSupport/platform-Info.plist"
DEFAULT_FW="LocalPackages/libzcashlc.xcframework/macos-arm64/${NAME}.framework"
FW="${1:-$DEFAULT_FW}"

if [[ ! -d "$FW" ]]; then
    echo "error: framework not found: $FW" >&2
    exit 1
fi

# Already versioned? Nothing to do.
if [[ -d "$FW/Versions/A" ]]; then
    echo "version-macos-framework: $FW already versioned — skipping"
    exit 0
fi

# Read both versions before changing anything, so a missing or incomplete plist
# fails with the framework untouched. There is deliberately no fallback value: a
# made-up version in a shipped bundle is worse than a failed build.
if [[ ! -f "$PLATFORM_PLIST" ]]; then
    echo "error: version source not found: $PLATFORM_PLIST" >&2
    exit 1
fi
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLATFORM_PLIST") || {
    echo "error: CFBundleShortVersionString missing from $PLATFORM_PLIST" >&2
    exit 1
}
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLATFORM_PLIST") || {
    echo "error: CFBundleVersion missing from $PLATFORM_PLIST" >&2
    exit 1
}

echo "version-macos-framework: converting $FW to versioned layout"

mkdir -p "$FW/Versions/A/Resources"

# Move the real payload under Versions/A.
[[ -f "$FW/$NAME" ]]   && mv "$FW/$NAME"   "$FW/Versions/A/$NAME"
[[ -d "$FW/Headers" ]] && mv "$FW/Headers" "$FW/Versions/A/Headers"
[[ -d "$FW/Modules" ]] && mv "$FW/Modules" "$FW/Versions/A/Modules"

# Drop the shallow (iOS) Info.plist and write the correct macOS one into Resources.
# The versions were read from BuildSupport/platform-Info.plist above (the single
# source the Makefile stamps into every slice) so a future bump cannot drift.
rm -f "$FW/Info.plist"
cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>libzcashlc</string>
	<key>CFBundleIdentifier</key>
	<string>libzcashlc</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>libzcashlc</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleVersion</key>
	<string>${BUNDLE_VERSION}</string>
	<key>CFBundleShortVersionString</key>
	<string>${SHORT_VERSION}</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
</dict>
</plist>
PLIST

# Symlinks: Versions/Current -> A, then the top-level entries -> Versions/Current/*.
ln -sfn A "$FW/Versions/Current"
ln -sfn "Versions/Current/$NAME" "$FW/$NAME"
ln -sfn Versions/Current/Headers "$FW/Headers"
ln -sfn Versions/Current/Modules "$FW/Modules"
ln -sfn Versions/Current/Resources "$FW/Resources"

echo "version-macos-framework: done"
