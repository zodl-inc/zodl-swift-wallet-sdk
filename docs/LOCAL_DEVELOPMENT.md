# Local FFI Development

This guide explains how to work on the Rust FFI code alongside the Swift SDK.

## Overview

The SDK uses a pre-built XCFramework (`libzcashlc`) for the Rust FFI layer. For most SDK development, you don't need to rebuild the FFI — SPM automatically downloads the pre-built binary from GitHub Releases.

However, if you need to modify the Rust code in `rust/`, you'll need to set up local FFI development.

## How It Works

`Package.swift` automatically detects the presence of `LocalPackages/Package.swift` (created by the init script). When it exists, the SDK builds against your locally-built FFI instead of downloading the release binary. When it doesn't exist, the release binary is used as usual.

This means switching modes is as simple as:
- **Enable local FFI:** `./Scripts/init-local-ffi.sh`
- **Disable local FFI:** `rm -rf LocalPackages/` (or `./Scripts/reset-local-ffi.sh`)

No manual `Package.swift` edits are needed.

## Prerequisites

1. **Rust toolchain** — Rust 1.97 or newer is required, matching `rust-version` in `Cargo.toml`. Install via [rustup](https://rustup.rs/):
   ```bash
   curl --proto '=https' --tlsv1.3 -sSf https://sh.rustup.rs | sh
   ```

   If you already have Rust installed (for example, Rust 1.91), update the stable toolchain and verify the compiler version before building:
   ```bash
   rustup update stable
   rustc --version
   ```
   The reported version must be 1.97 or newer.

2. **Apple platform targets** — Install the required Rust targets:
   ```bash
   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
   rustup target add aarch64-apple-darwin
   ```

3. **Python 3.11 or newer** — `make test-scripts` and the CI Rust validator use Python's standard-library TOML parser. CI selects Python 3.12 explicitly.

CI installs the latest stable Rust, validates it against the root `Cargo.toml` minimum, and binds later steps to that compiler without changing the global rustup default. Conflicting explicit `RUSTC` or `RUSTUP_TOOLCHAIN` overrides fail validation. FFI and Cargo caches include the full verbose compiler identity, including its commit, host and LLVM version.

## OHTTP configuration

The OHTTP gateway hosts, relay URLs, key DNS names and signing keys are not build inputs.
Building the SDK, the FFI and the tests needs none of them, and a source build or a
precompiled SDK behaves the same. The binaries carry no configuration.

The app installs the configuration at runtime, once at launch and before any other SDK use:

```swift
try OHTTPEndpoints.configure(
    OHTTPConfiguration(
        mainnet: OHTTPNetworkConfiguration(
            gatewayHost: "ohttp-gateway.example",
            relayURL: "https://relay-mainnet.example/relay",
            keysDNSName: "mainnet.ohttp-keys.example",
            signingPublicKey: "<64 hex digits: an Ed25519 public key>"
        ),
        testnet: OHTTPNetworkConfiguration(/* same four values for testnet */)
    )
)
```

Each network has all four values or none, and mainnet and testnet share no value. An invalid
configuration throws `ZcashError.ohttpConfigurationInvalid`, naming the field and the rule but never the
value. Until `configure` is called with a configuration, or after `configure(nil)`, OHTTP is off.
The SDK never prints the values: descriptions and `dump` of the configuration types omit them.

### Tests

- **Offline tests** need no real values. `OHTTPTestSupport.installExampleConfiguration()` (in
  `Tests/OfflineTests`) installs the RFC 2606 example hosts with the RFC 8032 test public keys; a test that
  needs OHTTP calls it in `setUp`.
- **E2E tests** (`OHTTPE2ETests`, run by `ohttp-e2e.yml`) read the configuration from
  `OHTTP_E2E_{GATEWAY_HOST,RELAY_URL,KEYS_DNS_NAME,SIGNING_PUBKEY}_{MAINNET,TESTNET}` and install it through
  `OHTTPEndpoints.configure(_:)` before each test. When any of the eight is unset or empty the test is skipped,
  and the skip message names the missing variables. To run them locally, export the eight variables (and the
  `OHTTP_E2E_SEED_HEX` seed) in your shell; the workflow maps them from repository secrets on its test steps only.

## Quick Start

### One-Time Setup

You **must** run `init-local-ffi.sh` before opening the project in Xcode. Without it, SPM will attempt to download the release binary, which may not exist for development branches.

```bash
# Clone the repository
git clone https://github.com/zodl-inc/zodl-swift-wallet-sdk
cd zodl-swift-wallet-sdk

# Initialize local FFI (builds from source)
./Scripts/init-local-ffi.sh
```

The `--cached` flag downloads a pre-built release instead of building from source. This only works when `Package.swift` points to a published release:

```bash
./Scripts/init-local-ffi.sh --cached
```

**Warning:** Only use `--cached` if there have been no FFI changes on your branch since the last release. Using a stale pre-built binary with modified Swift bindings could cause silent data corruption and loss of funds. Additionally, `--cached` skips the Rust build entirely, so the first call to `rebuild-local-ffi.sh` will be a full (non-incremental) build.

The default source build contains all three ARM64 platform slices. For faster iteration you can select only the platforms you need:

```bash
./Scripts/init-local-ffi.sh --arm-macos     # macOS (swift build / swift test on the Mac)
./Scripts/init-local-ffi.sh --arm-ios       # iOS simulator + device
./Scripts/init-local-ffi.sh --arm-simulator # iOS simulator only
./Scripts/init-local-ffi.sh --arm-all       # iOS simulator + device + macOS
```

Building for a slice you didn't include will fail until you build it (via `rebuild-local-ffi.sh` or a full `init-local-ffi.sh`).

Cached installation verifies the pinned checksum, rejects unsafe archive members and validates all three canonical ARM64 slices before replacing the existing framework or wrapper. Older releases with Intel or legacy-named slices cannot be used with `--cached`; run a source initialization instead. Extraction and validation failures leave the previous installation intact.

### ARM64 CLI destinations

Compile and test on the CLI. Use an ARM64 iOS simulator/device or Apple Silicon Mac destination. Every `xcodebuild` build/test command must include `-skipMacroValidation` and an explicit `-derivedDataPath DerivedData` (or another path outside the Xcode app's DerivedData directory). If the testing scheme is unclear, ask before running it. Do not add Intel destinations to a build or archive.

For generic macOS or iOS Simulator destinations, pass `ARCHS=arm64` to the `xcodebuild` build or archive command. An Apple Silicon host alone does not restrict a generic destination to ARM64; Xcode may also request x86_64. Keep `-skipMacroValidation` and an explicit `-derivedDataPath` outside the Xcode app's DerivedData directory on these commands too.

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

If Xcode was already open before you ran `init-local-ffi.sh`, reset package caches: File > Packages > Reset Package Caches.

### Development Loop

```bash
# 1. Edit Rust code
vim rust/src/lib.rs

# 2. Fast incremental rebuild (seconds, not minutes!)
./Scripts/rebuild-local-ffi.sh              # iOS Simulator (default)
./Scripts/rebuild-local-ffi.sh ios-device   # iOS Device
./Scripts/rebuild-local-ffi.sh macos        # macOS

# 3. Build/test on the CLI (macOS on Apple Silicon)
swift build
swift test --filter OfflineTests
```

### Switching Back to Release Binary

```bash
./Scripts/reset-local-ffi.sh
```

If using Xcode, you may also need to reset package caches: File > Packages > Reset Package Caches.

## Scripts Reference

### `init-local-ffi.sh`

One-time setup that creates the local development environment.

```bash
./Scripts/init-local-ffi.sh                 # Build from source, all three ARM64 platform slices (recommended)
./Scripts/init-local-ffi.sh --arm-macos     # arm64 macOS slice only
./Scripts/init-local-ffi.sh --arm-ios       # arm64 iOS simulator + device slices
./Scripts/init-local-ffi.sh --arm-simulator # arm64 iOS simulator slice only
./Scripts/init-local-ffi.sh --arm-all       # arm64 iOS simulator + device + macOS slices
./Scripts/init-local-ffi.sh --cached        # Download pre-built release
```

This script:
- Builds the full XCFramework (all three ARM64 platform slices), a platform subset (`--arm-*`), or downloads a pre-built one
- Creates `LocalPackages/` with an SPM wrapper package
- `Package.swift` automatically detects `LocalPackages/` and switches to local mode

All source paths build `aarch64-*` targets regardless of host architecture. Intel destinations are unsupported. To add a missing ARM64 platform, run `rebuild-local-ffi.sh <target>` or a full `init-local-ffi.sh`. Unrecognized flags fail before toolchain or download calls.

### `rebuild-local-ffi.sh`

Fast incremental rebuild for the current development target. Requires `init-local-ffi.sh` to have been run first.

```bash
./Scripts/rebuild-local-ffi.sh [target]
```

Targets:
- `ios-sim` (default) — iOS Simulator (ARM64)
- `ios-device` — iOS Device (arm64)
- `macos` — macOS (ARM64)

**Why it's fast:** Only builds ONE architecture, and Cargo's incremental compilation means small changes rebuild in seconds.

The rebuilt slice is staged and validated before installation. Other canonical ARM64 slices are preserved with a staleness warning: check their `ENGINE_BUILD` tags after Rust changes. Unknown, legacy-named or Intel slices cause a failure before building; run `init-local-ffi.sh` to explicitly replace an incompatible installation. Failed builds and invalid staged products leave the installed framework and wrapper intact.

Use `--gpu` to forward the Rust `gpu` feature. Run `init-local-ffi.sh` before submitting FFI changes to verify all three ARM64 platform slices compile.

### `reset-local-ffi.sh`

Removes `LocalPackages/` and switches back to the release binary.

```bash
./Scripts/reset-local-ffi.sh
```

## Architecture Details

### XCFramework Structure

The XCFramework contains three platform slices:
- `ios-arm64` — iOS devices
- `ios-arm64-simulator` — iOS Simulator (ARM64)
- `macos-arm64` — macOS (ARM64)

### Build Targets

| Development Target | Rust Target | XCFramework Slice |
|-------------------|-------------|-------------------|
| iOS Simulator (Apple Silicon) | `aarch64-apple-ios-sim` | `ios-arm64-simulator` |
| iOS Device | `aarch64-apple-ios` | `ios-arm64` |
| macOS (Apple Silicon) | `aarch64-apple-darwin` | `macos-arm64` |

### Local Package Override

The `LocalPackages` directory contains a Swift package named `libzcashlc` with the same product name as the binary target in `Package.swift`. When `Package.swift` detects that `LocalPackages/Package.swift` exists, it adds `LocalPackages` as a path dependency and uses it instead of the `.binaryTarget` declaration. This switching is automatic — no manual edits to `Package.swift` are needed.

## Automatic FFI Rebuilds

The shared `ZODLSwiftWalletSDK` scheme in `ZcashSDK.xcworkspace` includes `FFIBuilder` as a build dependency. FFIBuilder runs `rebuild-local-ffi.sh` with the appropriate platform based on your selected destination, so Rust code is automatically recompiled when you build in Xcode.

**Note:** The FFIBuilder target requires `init-local-ffi.sh` to have been run first — it calls `rebuild-local-ffi.sh`, which expects `LocalPackages/` to exist.

| Approach | Best for |
|----------|----------|
| Manual script (`rebuild-local-ffi.sh`) | Occasional FFI changes, simple setup |
| FFIBuilder target in workspace | Frequent FFI changes, prefer staying in Xcode |

## Troubleshooting

### Xcode can't resolve packages / shows 404 error

This means `LocalPackages/` doesn't exist and SPM is trying to download the release binary. Run `./Scripts/init-local-ffi.sh` to set up local development, then reset package caches in Xcode: File > Packages > Reset Package Caches.

### Xcode doesn't pick up FFI changes

1. Clean the build folder: Cmd+Shift+K
2. If that doesn't work, reset package caches: File > Packages > Reset Package Caches
3. For CLI builds, remove only the repo-local `DerivedData/` you selected and build again. CLI builds must never depend on the Xcode app's DerivedData cache.

### Build fails with missing target

Ensure all Rust targets are installed:
```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
rustup target add aarch64-apple-darwin
```

### Header changes not reflected

The headers are regenerated during cargo build. If you see stale headers:
```bash
rm -rf target/Headers
./Scripts/rebuild-local-ffi.sh
```

### Xcode uses wrong FFI after switching modes

After running `init-local-ffi.sh` or `reset-local-ffi.sh`, Xcode may need to re-resolve packages:
1. File > Packages > Reset Package Caches
2. If that doesn't help, close and reopen the workspace

### FFIBuilder fails on first workspace open

When opening `ZcashSDK.xcworkspace` for the first time after running `init-local-ffi.sh`, FFIBuilder may fail with "Command PhaseScriptExecution failed with a nonzero exit code". This is a timing issue -- Xcode may attempt to build FFIBuilder before package resolution has completed. Run "Product > Build For > Testing" manually and the build should succeed. Subsequent builds will work normally.

### FFI rebuilds from scratch despite no changes

The Makefile (used by `init-local-ffi.sh`) and `rebuild-local-ffi.sh` invoke `cargo` with slightly different environment variables, which can cause Cargo to invalidate its build cache. This means the first `rebuild-local-ffi.sh` after `init-local-ffi.sh` (or vice versa) may do a full rebuild. Subsequent incremental rebuilds within the same tool will be fast.

### `rustup: command not found` in Xcode build

The scripts fall back to `~/.cargo/bin` on PATH to find the Rust toolchain. If you installed Rust via a non-standard method (e.g., Homebrew, Nix), you may need to ensure `cargo` and `rustup` are on the default PATH or add the appropriate source/export to `~/.zprofile`.

## Full Rebuild

Before submitting a PR that modifies Rust code:

```bash
# Full rebuild to verify all architectures compile
./Scripts/init-local-ffi.sh

# Run tests
swift test
```
