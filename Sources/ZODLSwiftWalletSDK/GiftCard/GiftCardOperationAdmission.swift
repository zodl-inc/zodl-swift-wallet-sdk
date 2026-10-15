import Foundation

/// Forwards cancellation across the handoff from preparation to native creation admission.
final class GiftCardOperationAdmission {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    private var requested = false

    func installCancellation(_ cancellation: @escaping () -> Void) {
        lock.lock()
        self.cancellation = cancellation
        let shouldCancel = requested
        lock.unlock()
        if shouldCancel { cancellation() }
    }

    func requestCancellation() {
        lock.lock()
        requested = true
        let cancellation = self.cancellation
        lock.unlock()
        cancellation?()
    }
}
