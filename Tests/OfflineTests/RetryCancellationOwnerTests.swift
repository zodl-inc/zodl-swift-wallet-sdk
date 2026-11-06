import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class RetryCancellationOwnerTests: XCTestCase {
    func testCancellationBeforeInstallSurvivesRegistrationCompletion() async {
        let owner = RetryCancellationOwner()
        let id = owner.begin()
        owner.cancel {}
        let gate = Gate()
        let task = Task { await gate.wait() }
        owner.install(task, id: id)
        XCTAssertTrue(task.isCancelled)
        gate.open()
        await task.value
    }

    func testStaleFinishAndInstallCannotRetireNewRetry() async {
        let owner = RetryCancellationOwner()
        let old = owner.begin()
        let current = owner.begin()
        let gate = Gate()
        let oldTask = Task { await gate.wait() }
        let currentTask = Task { await gate.wait() }
        owner.install(currentTask, id: current)
        owner.finish(id: old)
        owner.install(oldTask, id: old)
        XCTAssertTrue(oldTask.isCancelled)
        XCTAssertFalse(currentTask.isCancelled)
        owner.cancel {}
        XCTAssertTrue(currentTask.isCancelled)
        gate.open()
        await oldTask.value
        await currentTask.value
    }

    func testOverlappingRegistrationsAndRetryFinishCannotClearPendingRequest() async {
        let owner = RetryCancellationOwner()
        let gate = Gate()
        let first = owner.begin()
        let firstTask = Task { await gate.wait() }
        owner.install(firstTask, id: first)
        var rejectedTask: Task<Void, Never>?
        owner.cancel {
            owner.cancel {}
            owner.finish(id: first)
            let id = owner.begin()
            let task = Task { await gate.wait() }
            owner.install(task, id: id)
            rejectedTask = task
            XCTAssertTrue(task.isCancelled, "One completed request cannot clear another request's registration fence")
            owner.finish(id: id)
        }
        let admittedID = owner.begin()
        let admitted = Task { await gate.wait() }
        owner.install(admitted, id: admittedID)
        XCTAssertFalse(admitted.isCancelled, "New retries must be allowed once every request is registered")
        gate.open()
        await firstTask.value
        await rejectedTask?.value
        await admitted.value
    }
}
