import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class ConsensusBranchIDTests: XCTestCase {
    /// The constants are what the Rust core reports on either side of the real testnet NU7 activation height.
    func testNU7ConsensusBranchIDIsTheBranchTheCoreReportsFromActivation() throws {
        let backend = ZcashRustBackend.makeForTests(fsBlockDbRoot: Environment.uniqueTestTempDirectory, networkType: .testnet)

        XCTAssertEqual(try backend.consensusBranchIdFor(height: 4_465_026), ZcashSDK.nu7ConsensusBranchID)
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 4_465_025), ZcashSDK.nu63ConsensusBranchID)
        XCTAssertEqual(ZcashSDK.nu7ConsensusBranchID.toString(), "77190ad9")
    }
}
