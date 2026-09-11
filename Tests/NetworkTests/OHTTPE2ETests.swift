//
//  OHTTPE2ETests.swift
//  ZcashLightClientKit
//
//  Live end-to-end test of the OHTTP (RFC 9458) transport against the testnet gateway:
//  restore a wallet from seed, sync to the chain tip through `ohttp-gateway-testnet.example`
//  and check the balance. Two variants: OHTTP only (`.direct` service mode), and Tor + OHTTP
//  (every leg to the relay rides an arti circuit, so the relay sees a Tor exit).
//
//  Driven by environment variables (see .github/workflows/ohttp-e2e.yml); skipped when the seed
//  is not provided so `swift test` on a developer machine stays offline:
//    OHTTP_E2E_SEED_HEX          64-byte BIP39 seed, hex (TESTNET wallet)
//    OHTTP_E2E_BIRTHDAY          wallet birthday height
//    OHTTP_E2E_MIN_BALANCE_ZAT   minimum expected total balance in zatoshi (default 90 TAZ)
//    OHTTP_E2E_TIMEOUT_SECONDS   sync deadline (default 3600)
//    OHTTP_E2E_GATEWAY_HOST      default ohttp-gateway-testnet.example
//
//  Every log line is prefixed `OHTTP-E2E` so the CI job can grep the evidence.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class OHTTPE2ETests: ZcashTestCase {
    private enum Env {
        static let environment = ProcessInfo.processInfo.environment
        static var seedHex: String? { environment["OHTTP_E2E_SEED_HEX"].flatMap { $0.isEmpty ? nil : $0 } }
        static var birthday: BlockHeight { environment["OHTTP_E2E_BIRTHDAY"].flatMap { Int($0) } ?? 4_123_503 }
        static var minBalanceZatoshi: Int64 { environment["OHTTP_E2E_MIN_BALANCE_ZAT"].flatMap { Int64($0) } ?? 9_000_000_000 }
        static var timeoutSeconds: TimeInterval { environment["OHTTP_E2E_TIMEOUT_SECONDS"].flatMap { TimeInterval($0) } ?? 3600 }
        static var gatewayHost: String { environment["OHTTP_E2E_GATEWAY_HOST"] ?? "ohttp-gateway-testnet.example" }
    }

    // MARK: - Tests

    /// OHTTP only: Swift RPCs and the Rust sync engine go HPKE-encapsulated through the relay;
    /// nothing touches Tor (the pre-consent path in the apps).
    func testRestoreAndSyncOverOHTTP() async throws {
        try await restoreAndSync(tor: false)
    }

    /// Tor + OHTTP: same, with Tor enabled the way the apps do it after the user opts in.
    /// The relay must see a Tor exit instead of this host's IP.
    func testRestoreAndSyncOverTorAndOHTTP() async throws {
        try await restoreAndSync(tor: true)
    }

    // MARK: - Scenario

    private func restoreAndSync(tor: Bool) async throws {
        guard let seedHex = Env.seedHex, let seed = Data(hexString: seedHex), seed.count == 64 else {
            throw XCTSkip("OHTTP_E2E_SEED_HEX not set (or not a 64-byte hex seed); live OHTTP E2E skipped")
        }

        let mode = tor ? "tor+ohttp" : "ohttp"
        let host = Env.gatewayHost
        XCTAssertTrue(OHTTPEndpoints.isGateway(host), "\(host) must be a configured OHTTP gateway")
        log("mode=\(mode) gateway=\(host) relay=\(try OHTTPEndpoints.relayURL(for: host)) birthday=\(Env.birthday)")
        log("host egress ip=\(await publicIP(via: nil) ?? "unknown")")

        let endpoint = LightWalletEndpoint(
            address: host,
            port: 443,
            secure: true,
            singleCallTimeoutInMillis: 30_000,
            streamingCallTimeoutInMillis: 10 * 60 * 60 * 1000
        )
        let databases = TemporaryDbBuilder.build()
        let initializer = Initializer(
            cacheDbURL: nil,
            fsBlockDbRoot: databases.fsCacheDbRoot,
            generalStorageURL: databases.generalStorageURL,
            dataDbURL: databases.dataDB,
            torDirURL: databases.torDir,
            endpoint: endpoint,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            alias: .custom("ohttp-e2e-\(mode)"),
            loggingPolicy: .default(.debug),
            isTorEnabled: tor,
            isExchangeRateEnabled: false
        )
        let synchronizer = SDKSynchronizer(initializer: initializer)
        defer { synchronizer.stop() }

        let result = try await synchronizer.prepare(with: [UInt8](seed), walletBirthday: Env.birthday, name: "ohttp-e2e", keySource: nil)
        guard case .success = result else {
            return XCTFail("prepare() returned \(result), expected .success")
        }
        log("prepared wallet (\(mode))")

        if tor {
            // Same call the apps make when the user turns on Tor protection: bootstraps arti and
            // flips the SDK flag so every RPC uses a Tor service mode.
            try await synchronizer.tor(enabled: true)
            let initialized = await synchronizer.isTorSuccessfullyInitialized()
            log("tor enabled, initialized=\(String(describing: initialized))")
            log("tor exit ip=\(await publicIP(via: synchronizer) ?? "unknown")")
        }

        try await synchronizer.start(retry: false)
        log("sync started")

        let deadline = Date().addingTimeInterval(Env.timeoutSeconds)
        var lastReport = Date.distantPast
        var state = synchronizer.latestState
        while Date() < deadline {
            state = synchronizer.latestState
            if case .error(let error) = state.syncStatus {
                XCTFail("sync failed (\(mode)): \(error)")
                return
            }
            if case .upToDate = state.syncStatus, !state.isRecovering {
                break
            }
            if Date().timeIntervalSince(lastReport) >= 30 {
                log("progress status=\(describe(state.syncStatus)) tip=\(state.latestBlockHeight) fullyScanned=\(state.fullyScannedHeight) recovering=\(state.isRecovering)")
                lastReport = Date()
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        guard case .upToDate = state.syncStatus, !state.isRecovering else {
            XCTFail("sync did not reach upToDate within \(Int(Env.timeoutSeconds))s (\(mode)); last status=\(describe(state.syncStatus)) tip=\(state.latestBlockHeight) fullyScanned=\(state.fullyScannedHeight)")
            return
        }
        log("synced tip=\(state.latestBlockHeight) fullyScanned=\(state.fullyScannedHeight)")

        let balances = try await synchronizer.getAccountsBalances()
        var total: Int64 = 0
        for (account, balance) in balances {
            let shielded = balance.shieldedTotal().amount
            let transparent = balance.unshielded.amount
            total += shielded + transparent
            log("account=\(account) shielded=\(shielded) transparent=\(transparent) orchard=\(balance.orchardBalance.total().amount) sapling=\(balance.saplingBalance.total().amount)")
        }
        log("RESULT mode=\(mode) total_zatoshi=\(total) min_expected=\(Env.minBalanceZatoshi) tip=\(state.latestBlockHeight)")
        XCTAssertGreaterThanOrEqual(total, Env.minBalanceZatoshi, "restored balance too low for \(mode)")
    }

    // MARK: - Helpers

    /// Public IP as seen by an external service: through Tor when a synchronizer with Tor enabled
    /// is given, otherwise directly. Evidence only — never fails the test.
    private func publicIP(via synchronizer: SDKSynchronizer?) async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        do {
            let data: Data
            if let synchronizer {
                (data, _) = try await synchronizer.httpRequestOverTor(for: URLRequest(url: url), retryLimit: 3)
            } else {
                (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            log("public ip lookup failed: \(error)")
            return nil
        }
    }

    private func describe(_ status: SyncStatus) -> String {
        switch status {
        case .unprepared: return "unprepared"
        case .syncing(let progress, let spendable): return "syncing(\(Int(progress * 100))%, spendable=\(spendable))"
        case .upToDate: return "upToDate"
        case .stopped: return "stopped"
        case .error(let error): return "error(\(error))"
        }
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("OHTTP-E2E \(stamp) \(message)")
    }
}

private extension Data {
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
