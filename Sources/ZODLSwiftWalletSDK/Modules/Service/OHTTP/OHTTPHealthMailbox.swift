import Foundation
import os

/// Only operation publishers wait for capacity. Transport observations replace a single snapshot slot.
final class OHTTPHealthMailbox: Sendable {
    private struct Publisher {
        let update: OHTTPHealthUpdate
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var closed = false
        var snapshot: OHTTPHealthSnapshot?
        var latestSnapshotVersion: UInt64?
        var completions: [OHTTPHealthUpdate] = []
        var publishers: [Publisher] = []
        var reader: CheckedContinuation<OHTTPHealthUpdate?, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func snapshot(_ snapshot: OHTTPHealthSnapshot) {
        let reader = state.withLock { state -> CheckedContinuation<OHTTPHealthUpdate?, Never>? in
            guard !state.closed, state.latestSnapshotVersion.map({ snapshot.version > $0 }) ?? true else { return nil }
            state.latestSnapshotVersion = snapshot.version
            if let reader = state.reader {
                state.reader = nil
                return reader
            }
            state.snapshot = snapshot
            return nil
        }
        reader?.resume(returning: .snapshot(snapshot))
    }

    func complete(_ update: OHTTPHealthUpdate) async {
        await withCheckedContinuation { continuation in
            let result = state.withLock { state -> (accepted: Bool, reader: CheckedContinuation<OHTTPHealthUpdate?, Never>?) in
                if state.closed { return (true, nil) }
                if let waiting = state.reader {
                    state.reader = nil
                    return (true, waiting)
                }
                if state.completions.count < 64 {
                    state.completions.append(update)
                    return (true, nil)
                }
                // This evidence belongs to the still-active async publisher until admitted.
                state.publishers.append(Publisher(update: update, continuation: continuation))
                return (false, nil)
            }
            result.reader?.resume(returning: update)
            if result.accepted { continuation.resume() }
        }
    }

    private struct ReadResult {
        let ready: Bool
        let update: OHTTPHealthUpdate?
        var publisher: CheckedContinuation<Void, Never>?
    }

    func next() async -> OHTTPHealthUpdate? {
        await withCheckedContinuation { continuation in
            let result = state.withLock { state -> ReadResult in
                if state.closed { return ReadResult(ready: true, update: nil) }
                if !state.completions.isEmpty {
                    let update = state.completions.removeFirst()
                    var publisher: CheckedContinuation<Void, Never>?
                    if !state.publishers.isEmpty {
                        let waiting = state.publishers.removeFirst()
                        state.completions.append(waiting.update)
                        publisher = waiting.continuation
                    }
                    return ReadResult(ready: true, update: update, publisher: publisher)
                }
                if let snapshot = state.snapshot {
                    state.snapshot = nil
                    return ReadResult(ready: true, update: .snapshot(snapshot))
                }
                precondition(state.reader == nil, "Each health update stream supports one consumer")
                state.reader = continuation
                return ReadResult(ready: false, update: nil)
            }
            result.publisher?.resume()
            if result.ready { continuation.resume(returning: result.update) }
        }
    }

    func close() {
        let retired = state.withLock { state in
            state.closed = true
            let retired = (state.reader, state.publishers)
            state.reader = nil
            state.publishers = []
            state.completions = []
            state.snapshot = nil
            return retired
        }
        retired.0?.resume(returning: nil)
        for publisher in retired.1 { publisher.continuation.resume() }
    }
}
