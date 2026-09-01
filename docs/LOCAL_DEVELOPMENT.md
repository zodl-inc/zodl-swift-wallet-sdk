# Local FFI Development

This guide explains how to work on the Rust FFI code alongside the Swift SDK.

## Overview

The SDK uses a pre-built XCFramework (`libzcashlc`) for the Rust FFI layer. For most SDK development, you don't need to rebuild the FFI — SPM automatically downloads the pre-built binary from GitHub Releases.

However, if you need to modify the Rust code in `rust/`, you'll need to set up local FFI development.

## How It Works

`Package.swift` selects the FFI with an explicit switch: `let useLocalFFI = false` (the committed state) links the pre-built release binary; `true` links your locally built FFI in `LocalPackages/`. The scripts flip the switch for you:

- **Enable local FFI:** `./Scripts/init-local-ffi.sh` (builds the FFI, creates `LocalPackages/`, flips the switch)
- **Disable local FFI:** `./Scripts/reset-local-ffi.sh` (flips the switch back, removes `LocalPackages/`)

Never flip or commit the switch by hand — a commit with `useLocalFFI = true` cannot be resolved by package consumers, and CI rejects it. `init-local-ffi.sh` installs a pre-commit hook that blocks such commits locally (bypass deliberately with `ZODL_ALLOW_LOCAL_FFI_COMMIT=1`).

The switch is a literal in the manifest rather than a filesystem probe because SwiftPM (and Xcode) cache the evaluated manifest keyed by the file's bytes: a mode change has to change the bytes, or builds silently keep the previous mode from the cache. This also means switching modes needs no cache resetting — Xcode picks the new mode up on the next resolution.

## Prerequisites

1. **Rust toolchain** — Install via [rustup](https://rustup.rs/):
   ```bash
   curl --proto '=https' --tlsv1.3 -sSf https://sh.rustup.rs | sh
   ```

2. **Apple platform targets** — Install the required Rust targets:
   ```bash
   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
   rustup target add aarch64-apple-darwin x86_64-apple-darwin
   ```

## Quick Start

### One-Time Setup

You **must** run `init-local-ffi.sh` before opening the project in Xcode. Without it, SPM will attempt to download the release binary, which may not exist for development branches.

```bash
# Clone the repository
git clone https://github.com/zodl-inc/zcash-swift-wallet-sdk
cd zcash-swift-wallet-sdk

# Initialize local FFI (builds from source)
./Scripts/init-local-ffi.sh
```

The `--cached` flag downloads a pre-built release instead of building from source. This only works when `Package.swift` points to a published release:

```bash
./Scripts/init-local-ffi.sh --cached
```

**Warning:** Only use `--cached` if there have been no FFI changes on your branch since the last release. Using a stale pre-built binary with modified Swift bindings could cause silent data corruption and loss of funds. Additionally, `--cached` skips the Rust build entirely, so the first call to `rebuild-local-ffi.sh` will be a full (non-incremental) build.

For faster iteration on Apple Silicon you can build only the arm64 slices you need, skipping the x86_64 simulator/Mac slices you can't run there anyway:

```bash
./Scripts/init-local-ffi.sh --arm-macos # macOS (swift build / swift test on the Mac)
./Scripts/init-local-ffi.sh --arm-ios   # iOS simulator + device
./Scripts/init-local-ffi.sh --arm-all   # iOS simulator + device + macOS
```

Building for a slice you didn't include will fail until you build it (via `rebuild-local-ffi.sh` or a full `init-local-ffi.sh`).

### Opening in Xcode

You can open the project two ways:

- **Workspace** (recommended for FFI development) — includes the FFIBuilder target that automatically rebuilds the FFI when you build in Xcode:
  ```bash
  open ZcashSDK.xcworkspace
  ```
- **Package directly** — simpler, but you'll need to run `rebuild-local-ffi.sh` manually after Rust changes:
  ```bash
  open Package.swift
  ```

### Development Loop

```bash
# 1. Edit Rust code
vim rust/src/lib.rs

# 2. Fast incremental rebuild (seconds, not minutes!)
./Scripts/rebuild-local-ffi.sh              # iOS Simulator (default)
./Scripts/rebuild-local-ffi.sh ios-device   # iOS Device
./Scripts/rebuild-local-ffi.sh macos        # macOS

# 3. Build/test in Xcode
#    Clean build folder if Xcode doesn't pick up changes: Cmd+Shift+K
```

### Switching Back to Release Binary

```bash
./Scripts/reset-local-ffi.sh
```

## Scripts Reference

### `init-local-ffi.sh`

One-time setup that creates the local development environment.

```bash
./Scripts/init-local-ffi.sh             # Build from source, all 5 architectures (recommended)
./Scripts/init-local-ffi.sh --arm-macos # arm64 macOS slice only
./Scripts/init-local-ffi.sh --arm-ios   # arm64 iOS simulator + device slices
./Scripts/init-local-ffi.sh --arm-all   # arm64 iOS simulator + device + macOS slices
./Scripts/init-local-ffi.sh --cached    # Download pre-built release
```

This script:
- Builds the full XCFramework (all 5 architectures), an arm64-only subset (`--arm-*`, faster on Apple Silicon since it skips the x86_64 slices), or downloads a pre-built one
- Creates `LocalPackages/` with an SPM wrapper package
- Flips the `useLocalFFI` switch in `Package.swift` to link it

The `--arm-*` flags always build the `aarch64-*` targets regardless of host architecture. They produce an XCFramework containing only the requested arm64 slices, so building for an x86_64 simulator/Mac (or a slice you didn't include) will fail until you build it — run `rebuild-local-ffi.sh <target>` or a full `init-local-ffi.sh` to add the missing slices. Any unrecognized flag prints usage and exits without building.

### `rebuild-local-ffi.sh`

Fast incremental rebuild for the current development target. Requires `init-local-ffi.sh` to have been run first. Refuses to run while `Package.swift` is in release mode, since the rebuilt framework would not be linked.

```bash
./Scripts/rebuild-local-ffi.sh [target]
```

Targets:
- `ios-sim` (default) — iOS Simulator, auto-detects arm64 vs x86_64
- `ios-device` — iOS Device (arm64)
- `macos` — macOS, auto-detects arm64 vs x86_64

**Why it's fast:** Only builds ONE architecture, and Cargo's incremental compilation means small changes rebuild in seconds.

**Note:** This creates a single-architecture build. Run `init-local-ffi.sh` before submitting PRs to verify all architectures compile.

### `reset-local-ffi.sh`

Flips the `useLocalFFI` switch back to the release binary and removes `LocalPackages/`.

```bash
./Scripts/reset-local-ffi.sh
```

## Architecture Details

### XCFramework Structure

The XCFramework contains three platform slices:
- `ios-arm64` — iOS devices
- `ios-arm64_x86_64-simulator` — iOS Simulator (universal)
- `macos-arm64_x86_64` — macOS (universal)

### Build Targets

| Development Target | Rust Target | XCFramework Slice |
|-------------------|-------------|-------------------|
| iOS Simulator (Apple Silicon) | `aarch64-apple-ios-sim` | `ios-arm64_x86_64-simulator` |
| iOS Simulator (Intel) | `x86_64-apple-ios` | `ios-arm64_x86_64-simulator` |
| iOS Device | `aarch64-apple-ios` | `ios-arm64` |
| macOS (Apple Silicon) | `aarch64-apple-darwin` | `macos-arm64_x86_64` |
| macOS (Intel) | `x86_64-apple-darwin` | `macos-arm64_x86_64` |

### Local Package Override

The `LocalPackages` directory contains a Swift package named `libzcashlc` with the same product name as the binary target in `Package.swift`. When `useLocalFFI` is true, `Package.swift` adds `LocalPackages` as a path dependency and uses it instead of the `.binaryTarget` declaration. The scripts flip that switch; never edit or commit it by hand.

## Automatic FFI Rebuilds

The shared `ZcashLightClientKit` scheme in `ZcashSDK.xcworkspace` includes `FFIBuilder` as a build dependency. FFIBuilder runs `rebuild-local-ffi.sh` with the appropriate platform based on your selected destination, so Rust code is automatically recompiled when you build in Xcode.

**Note:** The FFIBuilder target requires `init-local-ffi.sh` to have been run first — it calls `rebuild-local-ffi.sh`, which expects `LocalPackages/` to exist.

| Approach | Best for |
|----------|----------|
| Manual script (`rebuild-local-ffi.sh`) | Occasional FFI changes, simple setup |
| FFIBuilder target in workspace | Frequent FFI changes, prefer staying in Xcode |

## Troubleshooting

### Xcode can't resolve packages / shows 404 error

This means `Package.swift` is in release mode (`useLocalFFI = false`) and SPM is trying to download a release binary that does not exist for this branch. Run `./Scripts/init-local-ffi.sh` to build and select the local FFI. The reverse failure — "LocalPackages does not contain a Package.swift" — means the flag is true but `LocalPackages/` is missing; run `./Scripts/init-local-ffi.sh` or `./Scripts/set-ffi-mode.sh release`.

### Xcode doesn't pick up FFI changes

1. Clean the build folder: Cmd+Shift+K
2. If that doesn't work, reset package caches: File > Packages > Reset Package Caches
3. If that doesn't work, close Xcode and delete DerivedData:
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData
   ```

### Build fails with missing target

Ensure all Rust targets are installed:
```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

### Header changes not reflected

The headers are regenerated during cargo build. If you see stale headers:
```bash
rm -rf target/Headers
./Scripts/rebuild-local-ffi.sh
```

### Xcode uses wrong FFI after switching modes

This should no longer happen: mode switches edit `Package.swift`, which invalidates SwiftPM's manifest cache by content. If Xcode still shows the old mode, it predates this mechanism — reset once via File > Packages > Reset Package Caches.

### FFIBuilder fails on first workspace open

When opening `ZcashSDK.xcworkspace` for the first time after running `init-local-ffi.sh`, FFIBuilder may fail with "Command PhaseScriptExecution failed with a nonzero exit code". This is a timing issue -- Xcode may attempt to build FFIBuilder before package resolution has completed. Run "Product > Build For > Testing" manually and the build should succeed. Subsequent builds will work normally.

### FFI rebuilds from scratch despite no changes

The Makefile (used by `init-local-ffi.sh`) and `rebuild-local-ffi.sh` invoke `cargo` with slightly different environment variables, which can cause Cargo to invalidate its build cache. This means the first `rebuild-local-ffi.sh` after `init-local-ffi.sh` (or vice versa) may do a full rebuild. Subsequent incremental rebuilds within the same tool will be fast.

### `rustup: command not found` in Xcode build

The scripts source `~/.cargo/env` to find the Rust toolchain. If you installed Rust via a non-standard method (e.g., Homebrew, Nix), you may need to ensure `cargo` and `rustup` are on the default PATH or add the appropriate source/export to `~/.zprofile`.

## Full Rebuild

Before submitting a PR that modifies Rust code:

```bash
# Full rebuild to verify all architectures compile
./Scripts/init-local-ffi.sh

# Run tests
swift test
```
