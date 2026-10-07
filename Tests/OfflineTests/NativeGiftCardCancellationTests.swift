import XCTest
@testable import ZcashLightClientKit

final class NativeGiftCardCancellationTests: XCTestCase {
    func testPendingCancellationWhenCompletionHandlerRegistersClosesNativeAdmission() {
        let operation = GiftCardOperationAdmission()
        operation.requestCancellation()
        let creation = GiftCardTransactionCreationAdmission()
        operation.installCancellation { creation.cancelBeforeCreation() }
        XCTAssertThrowsError(try creation.beginNativeCreation()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testCancellationCannotRevokeNativeAdmission() throws {
        let creation = GiftCardTransactionCreationAdmission()
        try creation.beginNativeCreation()
        creation.cancelBeforeCreation()
        XCTAssertNoThrow(try creation.beginNativeCreation())
    }
}
