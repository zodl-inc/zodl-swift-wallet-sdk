# Zcash iOS Framework

[![Build Status](https://github.com/zodl-inc/zcash-swift-wallet-sdk/actions/workflows/swift.yml/badge.svg)](https://github.com/zodl-inc/zcash-swift-wallet-sdk/actions/workflows/swift.yml)


A Zcash Lightweight Client SDK for iOS, maintained by the Zcash Open Development
Lab (ZODL). It originated as the Electric Coin Company's ZcashLightClientKit; ECC
neither maintains nor reviews this fork. It is under active development. Please be
advised of the following:

- This code currently is not audited by an external security auditor, use it at your own risk
- We **are actively changing** the codebase and adding features where/when needed

🔒 Security Warnings

- The Zcash iOS Wallet SDK is experimental and a work in progress. Use it at your own risk.
- Developers using this SDK must familiarize themselves with the current [threat
  model](https://zcash.readthedocs.io/en/latest/rtd_pages/wallet_threat_model.html), especially the known weaknesses described there.
- To report a security vulnerability, follow [SECURITY.md](SECURITY.md). Do not open a public
  issue.

# Installation

## Swift Package Manager

Add a package with the source "https://github.com/zodl-inc/zcash-swift-wallet-sdk.git" in
either Xcode's GUI or in your `Package.swift` file. The library product is named
`ZcashLightClientKit`:

```swift
dependencies: [
    .package(url: "https://github.com/zodl-inc/zcash-swift-wallet-sdk.git", from: "3.0.0")
]
```

### Pre-release version support for Xcode projects

If you want to include a pre-release version e.g. `3.1.0-rc.1` in an Xcode project you will need to specify it with the commit sha instead, as it does not appear that Xcode supports 'meta data' from semantic version strings for swift packages (at the time of writing).

# FFI Development

This SDK includes Rust code that provides the core cryptographic and wallet functionality via FFI. For most SDK development, you don't need to build the Rust code - SPM automatically downloads pre-built binaries.

If you need to modify the Rust code in `rust/`:

```bash
# One-time setup (builds from source and configures the workspace)
./Scripts/init-local-ffi.sh

# Open the development workspace
open ZcashSDK.xcworkspace

# Fast incremental rebuild after changes
./Scripts/rebuild-local-ffi.sh
```

See [docs/LOCAL_DEVELOPMENT.md](docs/LOCAL_DEVELOPMENT.md) for detailed instructions.

# Testing

The best way to run tests is to open "Package.swift" in Xcode and use the Test panel and target an iOS device. Tests will build and run for a Mac target but are not currently working as expected.

There are three test targets grouped by external requirements:
1. `OfflineTests`
    - No external requirements.
2. `NetworkTests`
    - Require an active internet connection.
3. `DarksideTests`
    - Require an instance of `lightwalletd` to be running while the tests are being run, see below for some information on how to set up. (Darkside refers to a mode in lightwalletd that allows it to be updated to represent/mock different states of the underlying blockchain.)

## lightwalletd

The `DarksideTests` test target depend on a `lightwalletd` server instance running locally (or remotely). For convenience, we have added a universal (Mac) `lightwalletd` binary (in `Tests/lightwalletd/lightwalletd) and it can be run locally for use by the tests with the following command:

```
Tests/lightwalletd/lightwalletd --no-tls-very-insecure --data-dir /tmp --darkside-very-insecure --log-file /dev/stdout
```

You can find out more about running `lightwalletd`, from the main repo https://github.com/zcash/lightwalletd.

### Integrating with CD/CI

The `LIGHTWALLETD_ADDRESS` environment variable can also be added to your shell of choice and `xcodebuild` will pick it up accordingly.

We advise setting this value as a secret variable on your CD/CI environment when possible.

# Integrating with logging tools
There are a lots of good logging tools for iOS. So we'll leave that choice to you. ZcashLightClientKit relies on a simple protocol to bubble up logs to client applications, which is called `Logger` (kudos for the naming originality...)
```
public protocol Logger {
    
    func debug(_ message: String, file: String, function: String, line: Int)
    
    func info(_ message: String, file: String, function: String, line: Int)
    
    func event(_ message: String, file: String, function: String, line: Int)
    
    func warn(_ message: String, file: String, function: String, line: Int)
    
    func error(_ message: String, file: String, function: String, line: Int)
    
}
```

You have a few different options when it comes to logging:
1. Leave it to the SDK. It will use its own `Logger` with sensible defaults. For this option, simply omit the `loggingPolicy` parameter when creating the `Initializer`

2. Provide a custom logger. For this option, do the following:
    a). have one class conform to the `Logger` protocol
    b). inject that logger when creating the `Initializer` by passing a `loggingPolicy` of `.custom(yourLogger)`

3. No logging. The SDK will not log any events. For this option, pass a `loggingPolicy` of `.noLogging` when creating the `Initializer` 

For more details look the Sample App's `AppDelegate` code.

# Swiftlint

We don't like reinventing the wheel, so we gently borrowed swift lint rules from AirBnB which we find pretty cool and reasonable.
  
# Unstable features

## `Spend before Sync` synchronization algorithm

The CompactBlockProcessor is responsible for downloading and processing blocks from the lightwalletd. Since the inception of the SDK the blocks were processed in a linear order up to the chain tip. Latests SDK has introduced brand new algorithm for syncing of the blocks. It's called `Spend before Sync` and processes blocks in non-linear order so the spendable funds are discovered as soon as possible - allowing users to create a transaction while still syncing.
  
# Versioning

This project follows [semantic versioning](https://semver.org/) with pre-release versions. An example of a valid version number is `1.0.4-alpha11` denoting the `11th` iteration of the `alpha` pre-release of version `1.0.4`. Stable releases, such as `1.0.4` will not contain any pre-release identifiers. Pre-releases include the following, in order of stability: `alpha`, `beta`, `rc`. Version codes offer a numeric representation of the build name that always increases. The first six significant digits represent the major, minor and patch number (two digits each) and the last 3 significant digits represent the pre-release identifier. The first digit of the identifier signals the build type. Lastly, each new build has a higher version code than all previous builds. The following table breaks this down:

#### Build Types

| Type  | Purpose | Stability | Audience | Identifier | Example Version |
| :---- | :--------- | :---------- | :-------- | :------- | :--- |
| **alpha** | **Sandbox.** For developers to verify behavior and try features. Things seen here might never go to production. Most bugs here can be ignored.| Unstable: Expect bugs | Internal developers | 0XX | 1.2.3-alpha04 (10203004) |
| **beta** | **Hand-off.** For developers to present finished features. Bugs found here should be reported and immediately addressed, if they relate to recent changes. | Unstable: Report bugs | Internal stakeholders | 2XX | 1.2.3-beta04 (10203204) |
| **release candidate** | **Hardening.** Final testing for an app release that we believe is ready to go live. The focus here is regression testing to ensure that new changes have not introduced instability in areas that were previously working.  | Stable: Hunt for bugs | External testers | 4XX | 1.2.3-rc04 (10203404) |
| **production** | **Delivery.** Deliver new features to end users. Any bugs found here need to be prioritized. Some will require immediate attention but most can be worked into a future release. | Stable: Prioritize bugs | Public | 8XX | 1.2.3 (10203800) |

## Examples

This repo contains demos of isolated functionality that this SDK provides. They can be found in the examples folder.

Examples can be found in the [Demo App](/Example/ZcashLightClientSample).

# License

Copyright © 2026 Znewco, Inc. (d/b/a Zcash Open Development Lab)

ZODL ZcashLightClientKit is free software, licensed under the GNU Affero General
Public License, version 3 only (AGPL-3.0-only). See [LICENSE](LICENSE).

In short: you may use, study, modify, and redistribute ZODL ZcashLightClientKit,
but if you incorporate it into an application, the complete source of that
application must be made available under the AGPL to its users, including users
who interact with it over a network.

If those terms don't fit your project, **commercial licenses are available** —
see [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md). Official Zodl builds
distributed through the Apple App Store are released by Znewco under separate
terms; no App Store distribution permission is granted to AGPL licensees — see
[LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md).

ZODL ZcashLightClientKit is derived from ZcashLightClientKit, Copyright (c) 2020
Zcash, which was made available under the MIT License; that license is
reproduced in [LICENSE-MIT](LICENSE-MIT). It also depends on the Zcash Rust
crates (librustzcash and related) and other third-party libraries, which are
separately licensed by their respective copyright holders and are not covered by
this notice.
