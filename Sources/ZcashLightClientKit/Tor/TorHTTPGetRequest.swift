import Foundation
import libzcashlc

/// Synchronous native operations. All request operations run together on one worker.
struct TorHTTPGetNative: Sendable {
    var get: @Sendable (
        OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<FfiHttpRequestHeader>?, UInt, UInt8, UInt64
    ) -> UnsafeMutablePointer<FfiHttpResponseBytes>? = { zcashlc_tor_http_get_with_timeout($0, $1, $2, $3, $4, $5) }
    var freeResponse: @Sendable (UnsafeMutablePointer<FfiHttpResponseBytes>?) -> Void = { zcashlc_free_http_response_bytes($0) }
    var isolateRuntime: @Sendable (OpaquePointer?) -> OpaquePointer? = { zcashlc_tor_isolated_client($0) }
    var freeRuntime: @Sendable (OpaquePointer?) -> Void = { zcashlc_free_tor_runtime($0) }
}

/// An isolated native runtime transferred from TorClient to exactly one executor job.
/// After construction, only that job's dispatch worker accesses or disposes the pointer.
final class TorHTTPGetRequest: @unchecked Sendable {
    private var runtime: OpaquePointer?
    private let url: URL
    private let headers: [String: String]
    private let retryLimit: UInt8
    private let deadline: UInt64
    private let native: TorHTTPGetNative

    init(runtime: OpaquePointer, request: URLRequest, url: URL, retryLimit: UInt8, deadline: UInt64, native: TorHTTPGetNative) {
        self.runtime = runtime
        self.url = url
        self.headers = request.allHTTPHeaderFields ?? [:]
        self.retryLimit = retryLimit
        self.deadline = deadline
        self.native = native
    }

    static func validate(_ request: URLRequest) throws -> URL {
        guard request.httpMethod?.uppercased() == "GET" else {
            throw ZcashError.rustTorHttpRequest("Only GET requests are supported by TorClient.httpGet")
        }
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              !url.absoluteString.containsCStringNullBytesBeforeStringEnding() else {
            throw ZcashError.rustTorHttpRequest("TorClient.httpGet requires an HTTP or HTTPS URL")
        }
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            guard !name.containsCStringNullBytesBeforeStringEnding(), !value.containsCStringNullBytesBeforeStringEnding() else {
                throw ZcashError.rustTorHttpRequest("TorClient.httpGet headers contain null bytes")
            }
        }
        return url
    }

    func run(timeoutMilliseconds: UInt64) throws -> TorHTTPRequestExecutor.Response {
        let allocated = headers.map { (strdup($0.key), strdup($0.value)) }
        defer {
            for (name, value) in allocated {
                free(name)
                free(value)
            }
        }
        guard allocated.allSatisfy({ $0.0 != nil && $0.1 != nil }) else {
            throw ZcashError.rustTorHttpRequest("TorClient.httpGet could not allocate headers")
        }
        var nativeHeaders = allocated.map { FfiHttpRequestHeader(name: $0.0, value: $0.1) }
        // Rust requires a non-null aligned slice pointer even when its length is zero.
        if nativeHeaders.isEmpty { nativeHeaders.append(FfiHttpRequestHeader(name: nil, value: nil)) }
        let responsePointer = try nativeHeaders.withUnsafeBufferPointer { buffer in
            try url.absoluteString.withCString { urlPointer in
                // Header/string allocation consumes the same deadline. Floor immediately
                // before native entry, so neither queue wait nor allocation extends it.
                let now = DispatchTime.now().uptimeNanoseconds
                let remaining = deadline > now ? deadline - now : 0
                let milliseconds = min(timeoutMilliseconds, remaining / 1_000_000)
                guard milliseconds > 0 else { throw URLError(.timedOut) }
                return native.get(runtime, urlPointer, buffer.baseAddress, UInt(headers.count), retryLimit, milliseconds)
            }
        }
        guard let responsePointer else {
            throw ZcashError.rustTorHttpRequest(
                lastErrorMessage(fallback: "TorClient.httpGet failed with unknown error")
            )
        }
        defer { native.freeResponse(responsePointer) }
        guard let response = responsePointer.pointee.unsafeToResponse(url: url) else {
            throw ZcashError.rustTorHttpRequest("TorClient.httpGet returned invalid HTTP response")
        }
        return response
    }

    func dispose() {
        guard let runtime else { return }
        self.runtime = nil
        native.freeRuntime(runtime)
    }
}
