//
//  TorHTTPStreamReader.swift
//  ZODLSwiftWalletSDK
//
//  The body of a Tor HTTP response read as it arrives (`TorClient.httpPostStream`).
//

import Foundation
import libzcashlc
import os

/// The native operations a ``TorHTTPStreamReader`` performs on its stream, so that a test can script them.
struct TorHTTPStreamNative: Sendable {
    /// One native read, which waits up to the given milliseconds for body bytes (`zcashlc_tor_http_stream_next`).
    /// It sets the state to 0 and returns the bytes when some came, to 1 when none came in time (also for a frame
    /// that carries no body bytes) and to 2 when the body has ended, with the last bytes of an error body that
    /// reached its 64 KiB guard. It returns null when the read failed, and the
    /// stream must then only be freed.
    var next: @Sendable (OpaquePointer, UInt64, UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<FfiBoxedSlice>? = {
        zcashlc_tor_http_stream_next($0, $1, $2)
    }
    var freeSlice: @Sendable (UnsafeMutablePointer<FfiBoxedSlice>) -> Void = { zcashlc_free_boxed_slice($0) }
    var lastOutcome: @Sendable () -> FfiTorHttpOutcome = { zcashlc_tor_http_last_outcome() }
    var freeStream: @Sendable (OpaquePointer) -> Void = { zcashlc_free_tor_http_stream($0) }
}

/// Reads the body of one Tor HTTP response, and frees its native stream when it is released. The body ends
/// when it is complete, when a read fails, when its consumer stops and, so that a stalled circuit cannot hold
/// the read open for good, when no bytes have come for the idle timeout.
final class TorHTTPStreamReader: @unchecked Sendable {
    /// How long one native read waits for body bytes before the reader checks whether it was cancelled and
    /// whether the body went idle, so an idle deadline is noticed up to this long after it has passed.
    static let waitMilliseconds: UInt64 = 250

    private enum ReadState: UInt8 {
        case data = 0
        case pending = 1
        case end = 2
    }

    /// Whether the consumer stopped reading the body.
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    /// Used by the one read loop, and by `header(_:)` before that loop starts, never by two at once.
    private let stream: OpaquePointer
    /// Keeps the Tor client, and so its circuits, alive while the body is read.
    private let owner: AnyObject?
    private let idleTimeoutNanoseconds: UInt64
    private let native: TorHTTPStreamNative
    private let now: @Sendable () -> UInt64
    private let health: OHTTPHealthTraffic?

    /// - Parameters:
    ///   - stream: The native stream, freed when the reader is released.
    ///   - owner: What must stay alive while the body is read: the Tor client, or nil when nothing has to.
    ///   - idleTimeout: How long, in seconds, the body may go without bytes before it fails with
    ///     `URLError.timedOut`. One second when it is not finite and positive.
    ///   - native: The native operations on `stream`.
    ///   - now: A monotonic clock, in nanoseconds.
    init(
        stream: OpaquePointer,
        owner: AnyObject?,
        idleTimeout: TimeInterval,
        native: TorHTTPStreamNative = TorHTTPStreamNative(),
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.stream = stream
        self.owner = owner
        self.idleTimeoutNanoseconds = Self.nanoseconds(idleTimeout)
        self.native = native
        self.now = now
        self.health = OHTTPHealthTraffic.current
    }

    deinit {
        native.freeStream(stream)
    }

    /// Converts a timeout in seconds to nanoseconds. A timeout that is not finite and positive counts as one
    /// second, and one too long to count in nanoseconds saturates at `UInt64.max` instead of overflowing, as
    /// `TorHTTPRequestExecutor.deadline(timeoutMilliseconds:now:)` does.
    private static func nanoseconds(_ timeout: TimeInterval) -> UInt64 {
        let seconds = timeout.isFinite && timeout > 0 ? timeout : 1
        let nanoseconds = seconds * 1_000_000_000
        return nanoseconds < Double(UInt64.max) ? UInt64(nanoseconds) : UInt64.max
    }

    func header(_ name: String) -> String? {
        guard let value = zcashlc_tor_http_stream_header(stream, name) else {
            return nil
        }
        defer { zcashlc_string_free(value) }
        return String(cString: value)
    }

    /// The body as it arrives. The stream is read by one loop at a time, so this is called once.
    func body() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [self] _ in
                cancelled.withLock { $0 = true }
            }
            DispatchQueue.global(qos: .utility).async { [self] in
                read(into: continuation)
            }
        }
    }

    private func read(into continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        // Only body bytes count as progress. A read that waited and found none and a frame that carries none
        // both report the pending state, and a peer that sends nothing more must not be able to keep the read going.
        var lastProgress = now()
        while !cancelled.withLock({ $0 }) {
            guard !isIdle(since: lastProgress) else {
                continuation.finish(throwing: URLError(.timedOut))
                return
            }
            var state: UInt8 = 0
            guard let slice = native.next(stream, Self.waitMilliseconds, &state) else {
                health?.classify(OHTTPNativeHTTPFailure(native.lastOutcome()).outcome)
                continuation.finish(
                    throwing: ZcashError.rustTorHttpRequest(
                        lastErrorMessage(fallback: "`TorClient.httpPostStream` body read failed")
                    )
                )
                return
            }
            defer { native.freeSlice(slice) }

            switch ReadState(rawValue: state) {
            case .data:
                if let ptr = slice.pointee.ptr, slice.pointee.len > 0 {
                    continuation.yield(Data(bytes: ptr, count: Int(slice.pointee.len)))
                    lastProgress = now()
                }
            case .end:
                // The native read that reaches the 64 KiB guard of an error body returns its last bytes
                // together with the end, so that the status classifier runs at once.
                if let ptr = slice.pointee.ptr, slice.pointee.len > 0 {
                    continuation.yield(Data(bytes: ptr, count: Int(slice.pointee.len)))
                }
                continuation.finish()
                return
            case .pending, .none:
                continue
            }
        }
        continuation.finish(throwing: CancellationError())
    }

    private func isIdle(since lastProgress: UInt64) -> Bool {
        let current = now()
        let elapsed = current > lastProgress ? current - lastProgress : 0
        return elapsed >= idleTimeoutNanoseconds
    }
}
