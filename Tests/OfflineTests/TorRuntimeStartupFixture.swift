import Foundation
import libzcashlc
@testable import ZODLSwiftWalletSDK

/// Runs a synthetic bootstrap on the real owner's worker without involving the Tor network.
extension TorRuntimeStartupNative {
    static func fixture(_ create: @escaping @Sendable (String, UInt) -> OpaquePointer?) -> TorRuntimeStartupNative {
        TorRuntimeStartupNative(
            begin: { bytes, _ in
                let job = StartupFixtureJob(path: String(bytes: bytes, encoding: .utf8) ?? "", create: create)
                return OpaquePointer(Unmanaged.passRetained(job).toOpaque())
            },
            cancel: { _ in },
            wait: { pointer in
                let job = Unmanaged<StartupFixtureJob>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue()
                job.runtime = job.create(job.path, UInt(job.path.utf8.count))
                return job.runtime == nil ? 2 : 1
            },
            take: { pointer in
                let job = Unmanaged<StartupFixtureJob>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue()
                return FfiTorStartupResultV1(status: job.runtime == nil ? 2 : 1, runtime: job.runtime)
            },
            free: { pointer in Unmanaged<StartupFixtureJob>.fromOpaque(UnsafeRawPointer(pointer)).release() }
        )
    }
}

private final class StartupFixtureJob {
    let path: String
    let create: @Sendable (String, UInt) -> OpaquePointer?
    var runtime: OpaquePointer?

    init(path: String, create: @escaping @Sendable (String, UInt) -> OpaquePointer?) {
        self.path = path
        self.create = create
    }
}
