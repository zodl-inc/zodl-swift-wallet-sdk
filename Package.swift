// swift-tools-version:5.6
import PackageDescription

// Local FFI development switch.
//
// `false` — the committed state: the SDK links the pre-built libzcashlc
// XCFramework from the GitHub release named below. `true`: the SDK links the
// locally built FFI in LocalPackages/ instead.
//
// The switch is a literal rather than a filesystem probe because SwiftPM
// caches the result of evaluating this manifest keyed by the manifest's
// bytes (plus package path and toolchain). A mode change therefore has to
// change this file's bytes, or every build keeps seeing the previously
// cached mode.
//
// Toggled by `make configure-local-ffi`, `Scripts/init-local-ffi.sh`, and
// `Scripts/reset-local-ffi.sh` (directly: `Scripts/set-ffi-mode.sh`). Do not
// flip it by hand, and never commit `true` — consumers cannot resolve the
// package in that state, and CI rejects it.
let useLocalFFI = false

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.24.2"),
    .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3")
]

var sdkDependencies: [Target.Dependency] = [
    .product(name: "SQLite", package: "SQLite.swift"),
    .product(name: "GRPC", package: "grpc-swift"),
]

var targets: [Target] = []

if useLocalFFI {
    dependencies.append(.package(name: "libzcashlc", path: "LocalPackages"))
    sdkDependencies.append(.product(name: "libzcashlc", package: "libzcashlc"))
} else {
    // Binary target for the Rust FFI library
    // Updated by Scripts/release.sh during the release process
    targets.append(
        .binaryTarget(
            name: "libzcashlc",
            url: "https://github.com/zcash/zcash-swift-wallet-sdk/releases/download/2.8.0-rc.2/libzcashlc.xcframework.zip",
            checksum: "7d0b196c53a70ae5eed453709cc231318cc1b90077f3157c33704fed32acf02f"
        )
    )
    sdkDependencies.append("libzcashlc")
}

targets.append(contentsOf: [
    .target(
        name: "ZcashLightClientKit",
        dependencies: sdkDependencies,
        exclude: [
            "Modules/Service/GRPC/ProtoBuf/proto/proposal.proto",
            "Error/Sourcery/"
        ],
        resources: [
            .copy("Resources/checkpoints")
        ]
    ),
    .target(
        name: "TestUtils",
        dependencies: ["ZcashLightClientKit"],
        path: "Tests/TestUtils",
        exclude: [
            "proto/darkside.proto",
            "Sourcery/AutoMockable.stencil",
            "Sourcery/generateMocks.sh"
        ],
        resources: [
            .copy("Resources/test_data.db"),
            .copy("Resources/cache.db"),
            .copy("Resources/darkside_caches.db"),
            .copy("Resources/darkside_data.db"),
            .copy("Resources/sandblasted_mainnet_block.json"),
            .copy("Resources/txBase64String.txt"),
            .copy("Resources/txFromAndroidSDK.txt"),
            .copy("Resources/integerOverflowJSON.json"),
            .copy("Resources/sapling-spend.params"),
            .copy("Resources/sapling-output.params")
        ]
    ),
    .testTarget(
        name: "OfflineTests",
        dependencies: ["ZcashLightClientKit", "TestUtils"]
    ),
    .testTarget(
        name: "NetworkTests",
        dependencies: ["ZcashLightClientKit", "TestUtils"]
    ),
    .testTarget(
        name: "DarksideTests",
        dependencies: ["ZcashLightClientKit", "TestUtils"]
    ),
    .testTarget(
        name: "AliasDarksideTests",
        dependencies: ["ZcashLightClientKit", "TestUtils"],
        exclude: [
            "scripts/"
        ]
    ),
    .testTarget(
        name: "PerformanceTests",
        dependencies: ["ZcashLightClientKit", "TestUtils"]
    )
])

let package = Package(
    name: "ZcashLightClientKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ZcashLightClientKit",
            targets: ["ZcashLightClientKit"]
        )
    ],
    dependencies: dependencies,
    targets: targets
)
