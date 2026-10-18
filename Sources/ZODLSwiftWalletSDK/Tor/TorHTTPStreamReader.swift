//
//  TorHTTPStreamReader.swift
//  ZODLSwiftWalletSDK
//
//  The body of a Tor HTTP response read as it arrives (`TorClient.httpPostStream`).
//

import Foundation
import libzcashlc

final class TorHTTPStreamReader: @unchecked Sendable {
    /// How long one native read waits for body bytes before the reader checks whether it was cancelled.
    static let waitMilliseconds: UInt64 = 250

    private enum ReadState: UInt8 {
        case data = 0
        case pending = 1
        case end = 2
    }

    private let lock = NSLock()
    private var cancelled = false
    private let stream: OpaquePointer
    /// Keeps the Tor client, and so its circuits, alive while the body is read.
    private let owner: TorClient

    init(stream: OpaquePointer, owner: TorClient) {
        self.stream = stream
        self.owner = owner
    }

    deinit {
        zcashlc_free_tor_http_stream(stream)
    }

    func header(_ name: String) -> String? {
        guard let value = zcashlc_tor_http_stream_header(stream, name) else {
            return nil
        }
        defer { zcashlc_string_free(value) }
        return String(cString: value)
    }

    func body() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [self] _ in
                lock.withLock { cancelled = true }
            }
            DispatchQueue.global(qos: .utility).async { [self] in
                read(into: continuation)
            }
        }
    }

    private func read(into continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        while !lock.withLock({ cancelled }) {
            var state: UInt8 = 0
            guard let slice = zcashlc_tor_http_stream_next(stream, Self.waitMilliseconds, &state) else {
                continuation.finish(
                    throwing: ZcashError.rustTorHttpRequest(
                        lastErrorMessage(fallback: "`TorClient.httpPostStream` body read failed")
                    )
                )
                return
            }
            defer { zcashlc_free_boxed_slice(slice) }

            switch ReadState(rawValue: state) {
            case .data:
                if let ptr = slice.pointee.ptr, slice.pointee.len > 0 {
                    continuation.yield(Data(bytes: ptr, count: Int(slice.pointee.len)))
                }
            case .end:
                continuation.finish()
                return
            case .pending, .none:
                continue
            }
        }
        continuation.finish(throwing: CancellationError())
    }
}
