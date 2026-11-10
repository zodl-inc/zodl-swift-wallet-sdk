import Foundation
import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPCompactBlockHeightTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OHTTPTestSupport.installExampleConfiguration()
    }

    private func makeService() -> LightWalletOHTTPService {
        let service = LightWalletOHTTPService(
            endpoint: LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true),
            singleCallTimeout: 1000,
            streamingCallTimeout: 1000,
            tor: TorClient(torDir: FileManager.default.temporaryDirectory),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )
        service.blockRangeRPC = { _, range in
            XCTAssertEqual(range.start.height, 1)
            XCTAssertEqual(range.end.height, 2)
            var block = CompactBlock()
            block.height = UInt64.max
            return [block]
        }
        return service
    }

    func testBlockRangeRejectsAnOverflowingReturnedHeight() async throws {
        let service = makeService()
        do {
            for try await _ in try service.blockRange(1...2, mode: ServiceMode.direct) {
                XCTFail("An invalid-height block must not be yielded")
            }
            XCTFail("The invalid height must terminate the range with an error")
        } catch ZcashError.serviceBlockRangeFailed {
        }
        await service.closeConnections()
    }

    func testBlockStreamRejectsAnOverflowingReturnedHeight() async throws {
        let service = makeService()
        do {
            for try await _ in try service.blockStream(startHeight: 1, endHeight: 2, mode: ServiceMode.direct) {
                XCTFail("An invalid-height block must not be yielded")
            }
            XCTFail("The invalid height must terminate the stream with an error")
        } catch ZcashError.serviceBlockStreamFailed {
        }
        await service.closeConnections()
    }
}
