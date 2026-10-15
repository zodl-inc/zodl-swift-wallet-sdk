import Foundation

/// Linearizes gift claim cancellation with synchronous native transaction creation.
final class GiftCardTransactionCreationAdmission: @unchecked Sendable {
    private enum State {
        case pending
        case cancelled
        case started
    }

    private let lock = NSLock()
    private var state = State.pending

    func cancelBeforeCreation() {
        lock.lock()
        defer { lock.unlock() }
        if case .pending = state { state = .cancelled }
    }

    func beginNativeCreation() throws {
        lock.lock()
        defer { lock.unlock() }
        if case .cancelled = state { throw CancellationError() }
        state = .started
    }
}

/// Absent for ordinary wallet creation, preserving its existing cancellation behavior.
enum GiftCardTransactionCreationContext {
    @TaskLocal static var admission: GiftCardTransactionCreationAdmission?
}
