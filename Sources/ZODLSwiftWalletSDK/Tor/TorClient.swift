//
//  TorRuntime.swift
//
//
//  Created by Jack Grigg on 04/06/2024.
//

import Foundation
import libzcashlc

public actor TorClient {
    private var underlyingRuntime: OpaquePointer?
    private var runtimeGeneration: UInt64 = 0
    private var pendingStartup: TorRuntimeAttempt?
    private var torDir: URL
    private let httpGetNative: TorHTTPGetNative
    private let httpExecutor: TorHTTPRequestExecutor

    public var cachedFiatCurrencyResult: FiatCurrencyResult?

    init(
        torDir: URL,
        httpGetNative: TorHTTPGetNative = TorHTTPGetNative(),
        httpExecutor: TorHTTPRequestExecutor = .shared
    ) {
        self.torDir = torDir
        self.httpGetNative = httpGetNative
        self.httpExecutor = httpExecutor
    }

    init(
        runtimePtr: OpaquePointer,
        torDir: URL,
        httpGetNative: TorHTTPGetNative = TorHTTPGetNative(),
        httpExecutor: TorHTTPRequestExecutor = .shared
    ) {
        underlyingRuntime = runtimePtr
        self.torDir = torDir
        self.httpGetNative = httpGetNative
        self.httpExecutor = httpExecutor
    }

    deinit {
        guard let runtime = underlyingRuntime else { return }

        let disposal = TorRuntimeDisposal(runtime: runtime, freeRuntime: httpGetNative.freeRuntime)
        TorRuntimeStartup.workerQueue.async { disposal.dispose() }
    }

    /// Open a voting round session that rides this client's Tor runtime.
    ///
    /// The runtime is lent for the duration of the call only: the crate takes
    /// an isolated client of its own while opening, so the round's circuits are
    /// not linkable to the rest of the wallet's Tor use and this actor keeps
    /// sole ownership of the runtime it can later close.
    ///
    /// Opening the session reaches no network. Getting to it may: on a client
    /// with no runtime yet, `prepareRuntime()` creates the Tor directory and
    /// bootstraps Arti first, under a bounded deadline while this actor remains available for cancellation.
    func makeVotingRoundSession(
        backend: VotingRustBackend,
        inputs: VotingSessionInputs,
        binding: VotingSessionBinding,
        isCustomServer: Bool,
        epoch: UInt64
    ) async throws -> VotingRoundSession {
        try await prepareRuntime()
        guard let runtime = underlyingRuntime else { throw ZcashError.torClientUnavailable }
        return try backend.makeSession(
            inputs: inputs,
            binding: binding,
            torRuntime: runtime,
            isCustomServer: isCustomServer,
            epoch: epoch
        )
    }

    public func isolatedClient() async throws -> TorClient {
        try await prepareRuntime()
        guard let runtime = underlyingRuntime else { throw ZcashError.torClientUnavailable }

        let isolatedPtr = httpGetNative.isolateRuntime(runtime)

        guard let isolatedPtr else {
            throw ZcashError.rustTorIsolatedClient(
                lastErrorMessage(fallback: "`TorClient.isolatedClient` failed with unknown error")
            )
        }

        return TorClient(runtimePtr: isolatedPtr, torDir: torDir, httpGetNative: httpGetNative, httpExecutor: httpExecutor)
    }

    /// Changes the client's current dormant mode, putting background tasks to sleep or waking
    /// them up as appropriate.
    ///
    /// This can be used to conserve CPU usage if you aren’t planning on using the client for
    /// a while, especially on mobile platforms.
    ///
    /// - Parameter mode: what level of sleep to put a Tor client into.
    func setDormant(mode: TorDormantMode) async throws {
        try await prepareRuntime()
        guard let runtime = underlyingRuntime else { throw ZcashError.torClientUnavailable }

        if !zcashlc_tor_set_dormant(runtime, mode) {
            throw ZcashError.rustTorIsolatedClient(
                lastErrorMessage(
                    fallback:
                        "`TorClient.setDormant` failed with unknown error"
                )
            )
        }
    }

    public func sleep() async {
        try? await setDormant(mode: Soft)
    }

    public func wake() async {
        try? await setDormant(mode: Normal)
    }

    /// Makes an HTTP request over Tor.
    ///
    /// - Parameter maxBytes: Maximum allowed response size in bytes (defaults to 257 MiB)
    /// - Parameter retryLimit: the maximum number of times that a failed request should be retried.
    ///             Set this to 0 to disable retries.
    public func httpRequest(for request: URLRequest, maxBytes: Int = (256 * 1024 * 1024) + (1024 * 1024), retryLimit: UInt8) async throws -> (data: Data, response: HTTPURLResponse) {
        try await httpRequest(for: request, maxBytes: maxBytes, retryLimit: retryLimit, postOnce: false)
    }

    /// Makes an HTTP request over Tor whose body must never be resent, such as an OHTTP relay post: a POST
    /// is tried again, on a new circuit, only when it failed to reach the server before any of it was sent
    /// (as ``httpPostStream(for:maxBytes:)`` is); a GET is not retried.
    func httpRequestSentOnce(for request: URLRequest, maxBytes: Int) async throws -> (data: Data, response: HTTPURLResponse) {
        try await httpRequest(for: request, maxBytes: maxBytes, retryLimit: 0, postOnce: true)
    }

    private func httpRequest(
        for request: URLRequest,
        maxBytes: Int,
        retryLimit: UInt8,
        postOnce: Bool
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try await prepareRuntime()
        guard let runtime = underlyingRuntime else { throw ZcashError.torClientUnavailable }

        let url = request.url
        guard let url else {
            throw ZcashError.rustTorHttpRequest("`TorClient.httpRequest` requires a URL")
        }

        let headers = request.allHTTPHeaderFields ?? [:]
        // Duplicate the header names and values into C strings.
        let cHeadersMut = headers.map { key, value in
            (strdup(key), strdup(value))
        }
        // Create the array of const pointers we will actually pass to Rust.
        let cHeaders = cHeadersMut.map { key, value in
            FfiHttpRequestHeader(name: key, value: value)
        }
        // Free the duplicate C strings once we are done.
        defer {
            for (namePtr, valuePtr) in cHeadersMut {
                free(namePtr)
                free(valuePtr)
            }
        }

        var responsePtr: UnsafeMutablePointer<FfiHttpResponseBytes>?
        try cHeaders.withUnsafeBufferPointer { headersPtr in
            switch request.httpMethod?.lowercased() {
            case "get":
                responsePtr = zcashlc_tor_http_get_bounded(
                    runtime,
                    [CChar](url.absoluteString.utf8CString),
                    headersPtr.baseAddress,
                    UInt(headersPtr.count),
                    retryLimit,
                    UInt(maxBytes)
                )
            case "post" where postOnce:
                let data = request.httpBody ?? Data()
                responsePtr = zcashlc_tor_http_post_once_bounded(
                    runtime,
                    [CChar](url.absoluteString.utf8CString),
                    headersPtr.baseAddress,
                    UInt(headersPtr.count),
                    data.bytes,
                    UInt(data.count),
                    UInt(maxBytes)
                )
            case "post":
                let data = request.httpBody ?? Data()
                responsePtr = zcashlc_tor_http_post_bounded(
                    runtime,
                    [CChar](url.absoluteString.utf8CString),
                    headersPtr.baseAddress,
                    UInt(headersPtr.count),
                    data.bytes,
                    UInt(data.count),
                    retryLimit,
                    UInt(maxBytes)
                )
            default:
                throw ZcashError.rustTorHttpRequest("Only GET and POST requests are supported")
            }
        }

        let outcome = zcashlc_tor_http_last_outcome()
        OHTTPHealthTraffic.current?.outerResponse(outcome)
        guard let responsePtr else {
            OHTTPHealthTraffic.current?.classify(OHTTPNativeHTTPFailure(outcome).outcome)
            throw ZcashError.rustTorHttpRequest(
                lastErrorMessage(fallback: "`TorClient.httpRequest` failed with unknown error")
            )
        }

        defer { zcashlc_free_http_response_bytes(responsePtr) }

        let response = responsePtr.pointee.unsafeToResponse(url: url)

        guard let response else {
            throw ZcashError.rustTorHttpRequest("`TorClient.httpRequest` returned invalid HTTP response")
        }

        return response
    }

    /// Posts `request` over Tor and returns as soon as the response head has arrived. The request is never
    /// resent; only a failure to reach the server, before any of it was sent, is tried again on a new circuit.
    /// The body follows as it arrives, at most `maxBytes` of it. Iterating the body no longer closes the
    /// stream. The body is read on a queue of its own, so a long stream holds no thread of the Swift
    /// concurrency pool. A body that gets no bytes for `request.timeoutInterval` fails with
    /// `URLError.timedOut`: a stream may last as long as the server keeps it open, but not stand still for that long.
    func httpPostStream(for request: URLRequest, maxBytes: Int) async throws -> OHTTPOuterStream {
        try await prepareRuntime()
        guard let runtime = underlyingRuntime else { throw ZcashError.torClientUnavailable }

        guard let url = request.url else {
            throw ZcashError.rustTorHttpRequest("`TorClient.httpPostStream` requires a URL")
        }

        let headers = request.allHTTPHeaderFields ?? [:]
        let cHeadersMut = headers.map { key, value in
            (strdup(key), strdup(value))
        }
        let cHeaders = cHeadersMut.map { key, value in
            FfiHttpRequestHeader(name: key, value: value)
        }
        defer {
            for (namePtr, valuePtr) in cHeadersMut {
                free(namePtr)
                free(valuePtr)
            }
        }

        let body = request.httpBody ?? Data()
        let streamPtr = cHeaders.withUnsafeBufferPointer { headersPtr in
            body.withUnsafeBytes { bodyPtr in
                zcashlc_tor_http_post_stream(
                    runtime,
                    [CChar](url.absoluteString.utf8CString),
                    headersPtr.baseAddress,
                    UInt(headersPtr.count),
                    bodyPtr.bindMemory(to: UInt8.self).baseAddress,
                    UInt(bodyPtr.count),
                    UInt(maxBytes)
                )
            }
        }

        let outcome = zcashlc_tor_http_last_outcome()
        OHTTPHealthTraffic.current?.outerResponse(outcome)
        guard let streamPtr else {
            OHTTPHealthTraffic.current?.classify(OHTTPNativeHTTPFailure(outcome).outcome)
            throw ZcashError.rustTorHttpRequest(
                lastErrorMessage(fallback: "`TorClient.httpPostStream` failed with unknown error")
            )
        }

        let reader = TorHTTPStreamReader(stream: streamPtr, owner: self, idleTimeout: request.timeoutInterval)
        return OHTTPOuterStream(
            status: Int(zcashlc_tor_http_stream_status(streamPtr)),
            contentType: reader.header("Content-Type"),
            retryAfter: reader.header("Retry-After"),
            body: reader.body()
        )
    }

    /// Makes an isolated GET under one timeout budget that starts before actor admission and includes
    /// executor waiting, native retries, and response-body collection. Cancellation or expiry before
    /// runtime ownership can complete while this actor remains busy; later admission starts no native work.
    /// Once the request owns runtime resources, cancellation waits for its bounded operation and cleanup.
    /// At most two bounded GETs own executor slots across the process, with each slot held through disposal.
    /// Cleanup, including final-owner runtime shutdown, can extend completion beyond the HTTP timer.
    /// Requires a prepared runtime from successful Tor enablement; otherwise throws torClientUnavailable.
    public nonisolated func httpGet(
        for request: URLRequest,
        retryLimit: UInt8,
        timeoutMilliseconds: UInt64
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let deadline = try TorHTTPRequestExecutor.deadline(
            timeoutMilliseconds: timeoutMilliseconds,
            now: DispatchTime.now().uptimeNanoseconds
        )
        let context = TorHTTPRequestContext(deadlineUptime: deadline)
        return try await context.run { context in
            try await self.httpGet(for: request, retryLimit: retryLimit, context: context)
        }
    }

    /// Parameter downloads preserve lazy Tor preparation within the same request deadline.
    /// While bootstrap runs on its native worker, cancellation/expiry can complete the waiting caller.
    /// A departing preparation releases its own interest; the last departure cancels native work.
    /// The context is checked again before isolation or GET. The root remains actor-owned throughout.
    nonisolated func httpGetPreparingRuntime(
        for request: URLRequest,
        retryLimit: UInt8,
        timeoutMilliseconds: UInt64
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let deadline = try TorHTTPRequestExecutor.deadline(
            timeoutMilliseconds: timeoutMilliseconds,
            now: DispatchTime.now().uptimeNanoseconds
        )
        let context = TorHTTPRequestContext(deadlineUptime: deadline)
        return try await context.run { context in
            try await self.prepareHTTPRuntime(for: request, context: context)
            return try await self.httpGet(for: request, retryLimit: retryLimit, context: context)
        }
    }

    private func prepareHTTPRuntime(for request: URLRequest, context: TorHTTPRequestContext) async throws {
        try context.checkCancellation()
        _ = try TorHTTPGetRequest.validate(request)
        try await prepareRuntime(deadline: context.deadlineUptime)
        try context.checkCancellation()
    }

    nonisolated func httpGet(
        for request: URLRequest,
        retryLimit: UInt8,
        context: TorHTTPRequestContext
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let ownedRequest = try await prepareHTTPGet(for: request, retryLimit: retryLimit, context: context)
        return try await httpExecutor.execute(
            deadlineUptime: context.deadlineUptime,
            operation: {
                try context.checkCancellation()
                return try ownedRequest.run(timeoutMilliseconds: $0)
            },
            dispose: { ownedRequest.dispose() }
        )
    }

    /// Ownership is acquired on the root actor; native execution and its completion
    /// must not need this actor again after it hands the owner to the caller.
    private func prepareHTTPGet(
        for request: URLRequest,
        retryLimit: UInt8,
        context: TorHTTPRequestContext
    ) throws -> TorHTTPGetRequest {
        try context.checkCancellation()
        let url = try TorHTTPGetRequest.validate(request)
        guard let runtime = underlyingRuntime else { throw ZcashError.torClientUnavailable }
        try context.claimOwnership()
        guard let isolated = httpGetNative.isolateRuntime(runtime) else {
            throw ZcashError.rustTorIsolatedClient(lastErrorMessage(fallback: "TorClient.httpGet could not isolate runtime"))
        }
        return TorHTTPGetRequest(
            runtime: isolated,
            request: request,
            url: url,
            retryLimit: retryLimit,
            deadline: context.deadlineUptime,
            native: httpGetNative
        )
    }

    public func getExchangeRateUSD() async throws -> FiatCurrencyResult {
        try await prepareRuntime()
        guard let runtime = underlyingRuntime else { throw ZcashError.torClientUnavailable }

        let rate = zcashlc_get_exchange_rate_usd(runtime)

        if rate.is_sign_negative {
            throw ZcashError.rustTorClientGet(lastErrorMessage(fallback: "`TorClient.get` failed with unknown error"))
        }

        let newValue = FiatCurrencyResult(
            date: Date(),
            rate: NSDecimalNumber(
                mantissa: rate.mantissa,
                exponent: rate.exponent,
                isNegative: rate.is_sign_negative
            ),
            state: .success
        )

        cachedFiatCurrencyResult = newValue

        return newValue
    }

    public func connectToLightwalletd(endpoint: String) async throws -> TorLwdConn {
        try await prepareRuntime()
        guard let runtime = underlyingRuntime else { throw ZcashError.torClientUnavailable }

        guard !endpoint.containsCStringNullBytesBeforeStringEnding() else {
            throw ZcashError.rustTorConnectToLightwalletd("endpoint string contains null bytes")
        }

        let lwdConnPtr = httpGetNative.connectLightwalletd(
            runtime, [CChar](endpoint.utf8CString)
        )

        guard let lwdConnPtr else {
            throw ZcashError.rustTorConnectToLightwalletd(
                lastErrorMessage(fallback: "`TorClient.connectToLightwalletd` failed with unknown error")
            )
        }

        return TorLwdConn(connPtr: lwdConnPtr, free: httpGetNative.freeLightwalletd)
    }
}

private struct TorRuntimeAttempt {
    let generation: UInt64
    let owner: TorRuntimeStartup
    let task: Task<Void, Error>
}

extension TorClient {
    /// The deadline is monotonic uptime in nanoseconds, shared with other startup owners.
    /// The first attempt keeps its native deadline; later callers cannot extend it. Each caller
    /// may leave independently, and the last abandoned interest cancels native work.
    nonisolated func prepare(deadline: UInt64? = nil) async throws {
        let deadline = try deadline ?? TorHTTPRequestExecutor.deadline(
            timeoutMilliseconds: 60_000,
            now: DispatchTime.now().uptimeNanoseconds
        )
        try await prepareRuntime(deadline: deadline)
    }

    /// Supersedes every preparation caller and dispatches native cancellation before suspending.
    /// A later preparation waits for the cancelled native attempt to quiesce before starting again.
    func close() async throws {
        runtimeGeneration &+= 1
        pendingStartup?.owner.cancel()
        guard let runtime = underlyingRuntime else { return }
        underlyingRuntime = nil
        let disposal = TorRuntimeDisposal(runtime: runtime, freeRuntime: httpGetNative.freeRuntime)
        await withCheckedContinuation { continuation in
            TorRuntimeStartup.workerQueue.async {
                disposal.dispose()
                continuation.resume()
            }
        }
    }

    public func updateCachedFiatCurrencyResult(_ result: FiatCurrencyResult?) async {
        cachedFiatCurrencyResult = result
    }

    private func prepareRuntime(deadline: UInt64? = nil) async throws {
        try Task.checkCancellation()
        if underlyingRuntime != nil { return }
        let deadline = try deadline ?? TorHTTPRequestExecutor.deadline(
            timeoutMilliseconds: 60_000,
            now: DispatchTime.now().uptimeNanoseconds
        )
        if let previous = pendingStartup,
           previous.owner.isCancelled {
            let generation = runtimeGeneration
            previous.owner.cancel()
            _ = await previous.task.result
            guard runtimeGeneration == generation else { throw CancellationError() }
            if pendingStartup?.generation == previous.generation { pendingStartup = nil }
            try Task.checkCancellation()
            return try await prepareRuntime(deadline: deadline)
        }
        if pendingStartup == nil {
            runtimeGeneration &+= 1
            let owner = TorRuntimeStartup(
                directory: torDir,
                deadline: deadline,
                native: httpGetNative.startup,
                freeRuntime: httpGetNative.freeRuntime
            )
            pendingStartup = TorRuntimeAttempt(generation: runtimeGeneration, owner: owner, task: Task { try await owner.run() })
        }
        guard let attempt = pendingStartup else { throw ZcashError.torClientUnavailable }
        guard let id = attempt.owner.registerWaiter() else {
            let generation = runtimeGeneration
            _ = await attempt.task.result
            guard runtimeGeneration == generation else { throw CancellationError() }
            if pendingStartup?.generation == attempt.generation { pendingStartup = nil }
            return try await prepareRuntime(deadline: deadline)
        }
        let waiter = TorRuntimeStartupWaiter { attempt.owner.releaseWaiter(id, cancelling: true) }
        do {
            try await waiter.wait(for: attempt.task, deadline: deadline)
            try Task.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw URLError(.timedOut) }
            guard runtimeGeneration == attempt.generation, !attempt.owner.isCancelled else { throw CancellationError() }
            if underlyingRuntime == nil {
                underlyingRuntime = try attempt.owner.claimRuntime()
                pendingStartup = nil
            }
            attempt.owner.releaseWaiter(id, cancelling: false)
        } catch {
            attempt.owner.releaseWaiter(id, cancelling: true)
            if attempt.owner.isCancelled {
                _ = await attempt.task.result
                if pendingStartup?.generation == attempt.generation { pendingStartup = nil }
            }
            throw error
        }
    }
}

public class TorLwdConn {
    private let conn: OpaquePointer
    private let free: @Sendable (OpaquePointer?) -> Void

    // swiftlint:disable:next strict_fileprivate
    fileprivate init(connPtr: OpaquePointer, free: @escaping @Sendable (OpaquePointer?) -> Void) {
        conn = connPtr
        self.free = free
    }

    deinit {
        free(conn)
    }

    /// Submits a raw transaction over lightwalletd.
    /// - Parameter spendTransaction: data representing the transaction to be sent
    /// - Throws: `serviceSubmitFailed` when GRPC call fails.
    func submit(spendTransaction: Data) throws -> LightWalletServiceResponse {
        let success = zcashlc_tor_lwd_conn_submit_transaction(
            conn,
            spendTransaction.bytes,
            UInt(spendTransaction.count)
        )

        var response = SendResponse()

        if !success {
            let err = lastErrorMessage(fallback: "`TorLwdConn.submit` failed with unknown error")

            if err.hasPrefix("Failed to submit transaction (") && err.contains(")") {
                guard let startOfCode = err.firstIndex(of: "(") else {
                    throw ZcashError.rustTorLwdSubmit(err)
                }
                guard let endOfCode = err.firstIndex(of: ")") else {
                    throw ZcashError.rustTorLwdSubmit(err)
                }
                guard let errorCode = Int32(err[err.index(startOfCode, offsetBy: 1)..<endOfCode]) else {
                    throw ZcashError.rustTorLwdSubmit(err)
                }
                let errorMessage = String(err[err.index(endOfCode, offsetBy: 3)...])

                response.errorCode = errorCode
                response.errorMessage = errorMessage
            } else {
                throw ZcashError.rustTorLwdSubmit(err)
            }
        }

        return response
    }

    /// Gets a transaction by id
    /// - Parameter txId: data representing the transaction ID
    /// - Throws: LightWalletServiceError
    /// - Returns: LightWalletServiceResponse
    /// - Throws: `serviceFetchTransactionFailed` when GRPC call fails.
    func fetchTransaction(txId: Data) throws -> (tx: ZcashTransaction.Fetched?, status: TransactionStatus) {
        guard txId.count == TxId.byteLength else {
            throw ZcashError.rustGetMemoInvalidTxIdLength
        }

        var height: UInt64 = 0

        let txPtr = zcashlc_tor_lwd_conn_fetch_transaction(conn, txId.bytes, &height)

        guard let txPtr else {
            let lastErrorMessage = lastErrorMessage(fallback: "`TorLwdConn.fetchTransaction` failed with unknown error")

            if lastErrorMessage.contains("No such mempool or main chain transaction") {
                return (tx: nil, status: .txidNotRecognized)
            } else if lastErrorMessage.contains("Transaction not found") {
                return (tx: nil, status: .txidNotRecognized)
            } else if lastErrorMessage.contains("No such mempool or blockchain transaction. Use gettransaction for wallet transactions.") {
                return (tx: nil, status: .txidNotRecognized)
            } else {
                throw ZcashError.rustTorLwdFetchTransaction(
                    lastErrorMessage
                )
            }
        }

        defer { zcashlc_free_boxed_slice(txPtr) }

        return ZcashTransaction.Fetched.returned(
            rawID: txId,
            raw: Data(
                bytes: txPtr.pointee.ptr,
                count: Int(txPtr.pointee.len)
            ),
            atServerHeight: height
        )
    }

    /// Gets a lightwalletd server info
    /// - Returns: LightWalletdInfo
    func getInfo() throws -> LightWalletdInfo {
        let infoPtr = zcashlc_tor_lwd_conn_get_info(conn)

        guard let infoPtr else {
            throw ZcashError.rustTorLwdGetInfo(
                lastErrorMessage(fallback: "`TorLwdConn.getInfo` failed with unknown error")
            )
        }

        defer { zcashlc_free_boxed_slice(infoPtr) }

        let slice = infoPtr.pointee
        guard let rawPtr = slice.ptr else {
            throw ZcashError.rustTorLwdGetInfo("`TorLwdConn.getInfo` Null pointer in FfiBoxedSlice")
        }

        let buffer = UnsafeBufferPointer<UInt8>(start: rawPtr, count: Int(slice.len))
        let data = Data(buffer: buffer)

        do {
            let info = try LightdInfo(serializedBytes: data)
            return info
        } catch {
            throw ZcashError.rustTorLwdGetInfo("`TorLwdConn.getInfo` Failed to decode protobuf LightdInfo: \(error)")
        }
    }

    /// Gets a block at the chain tip of the blockchain
    /// - Returns: Block
    func latestBlock() throws -> BlockID {
        var height: UInt32 = 0

        let blockIDPtr = zcashlc_tor_lwd_conn_latest_block(conn, &height)

        guard let blockIDPtr else {
            throw ZcashError.rustTorLwdLatestBlockHeight(
                lastErrorMessage(fallback: "`TorLwdConn.latestBlockHeight` failed with unknown error")
            )
        }

        defer { zcashlc_free_boxed_slice(blockIDPtr) }

        return BlockID(height: BlockHeight(height))
    }

    /// Gets a tree state for a given height
    /// - Parameter height: heght for what a tree state is requested
    /// - Returns: TreeState
    func getTreeState(height: BlockHeight) throws -> TreeState {
        let treeStatePtr = zcashlc_tor_lwd_conn_get_tree_state(conn, UInt32(height))

        guard let treeStatePtr else {
            throw ZcashError.rustTorLwdGetTreeState(
                lastErrorMessage(fallback: "`TorLwdConn.getTreeState` failed with unknown error")
            )
        }

        defer { zcashlc_free_boxed_slice(treeStatePtr) }

        let slice = treeStatePtr.pointee
        guard let rawPtr = slice.ptr else {
            throw ZcashError.rustTorLwdGetTreeState("`TorLwdConn.getTreeState` Null pointer in FfiBoxedSlice")
        }

        let buffer = UnsafeBufferPointer<UInt8>(start: rawPtr, count: Int(slice.len))
        let data = Data(buffer: buffer)

        do {
            let treeState = try TreeState(serializedBytes: data)
            return treeState
        } catch {
            throw ZcashError.rustTorLwdGetTreeState("`TorLwdConn.getTreeState` Failed to decode protobuf TreeState: \(error)")
        }
    }

    func checkSingleUseTransparentAddresses(
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID
    ) async throws -> TransparentAddressCheckResult {
        let addressCheckResultPtr = zcashlc_tor_lwd_conn_check_single_use_taddr(
            conn,
            dbData.0,
            dbData.1,
            networkType.networkId,
            accountUUID.id
        )

        guard let addressCheckResultPtr else {
            throw ZcashError.rustCheckSingleUseTransparentAddresses(
                lastErrorMessage(fallback: "`checkSingleUseTransparentAddresses` failed with unknown error")
            )
        }

        defer { zcashlc_free_address_check_result(addressCheckResultPtr) }

        if addressCheckResultPtr.pointee.tag == 0 {
            return TransparentAddressCheckResult.notFound
        } else {
            return TransparentAddressCheckResult.found(
                String(cString: addressCheckResultPtr.pointee.found.address)
            )
        }
    }

    func updateTransparentAddressTransactions(
        address: String,
        start: BlockHeight,
        end: BlockHeight,
        dbData: (String, UInt),
        networkType: NetworkType
    ) async throws -> TransparentAddressCheckResult {
        let addressCheckResultPtr = zcashlc_tor_lwd_conn_update_transparent_address_transactions(
            conn,
            dbData.0,
            dbData.1,
            networkType.networkId,
            address,
            UInt32(start),
            Int64(end)
        )

        guard let addressCheckResultPtr else {
            throw ZcashError.rustUpdateTransparentAddressTransactions(
                lastErrorMessage(fallback: "`updateTransparentAddressTransactions` failed with unknown error")
            )
        }

        defer { zcashlc_free_address_check_result(addressCheckResultPtr) }

        if addressCheckResultPtr.pointee.tag == 0 {
            return TransparentAddressCheckResult.notFound
        } else {
            return TransparentAddressCheckResult.found(
                String(cString: addressCheckResultPtr.pointee.found.address)
            )
        }
    }

    func fetchUTXOsByAddress(
        address: String,
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID
    ) async throws -> TransparentAddressCheckResult {
        let addressCheckResultPtr = zcashlc_tor_lwd_conn_fetch_utxos_by_address(
            conn,
            dbData.0,
            dbData.1,
            networkType.networkId,
            accountUUID.id,
            address
        )

        guard let addressCheckResultPtr else {
            throw ZcashError.rustFetchUTXOsByAddress(
                lastErrorMessage(fallback: "`fetchUTXOsByAddress` failed with unknown error")
            )
        }

        defer { zcashlc_free_address_check_result(addressCheckResultPtr) }

        if addressCheckResultPtr.pointee.tag == 0 {
            return TransparentAddressCheckResult.notFound
        } else {
            return TransparentAddressCheckResult.found(
                String(cString: addressCheckResultPtr.pointee.found.address)
            )
        }
    }
}

extension FfiHttpResponseBytes {
    func unsafeToResponse(url: URL) -> (data: Data, response: HTTPURLResponse)? {
        var headerFields: [String: String] = [:]

        for i in (0 ..< Int(headers_len)) {
            let headerPtr = headers_ptr.advanced(by: i).pointee

            let name = String(validatingCString: headerPtr.name)
            let value = String(validatingCString: headerPtr.value)

            guard let name, let value else {
                return nil
            }

            if headerFields.contains(where: { $0.key == name }) {
                // Duplicate header names correspond to a single header name
                // with multiple values separated by commas.
                headerFields[name]?.append(", \(value)")
            } else {
                headerFields[name] = value
            }
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: Int(status),
            httpVersion: String(validatingCString: version),
            headerFields: headerFields
        )

        guard let response else {
            return nil
        }

        return (
            data: Data(
                bytes: body_ptr,
                count: Int(body_len)
            ),
            response: response
        )
    }
}

extension TorClient {
    /// Internal OHTTP sender. Both key GET and single-send POST own the remaining probe
    /// budget before actor admission and execute with a real native send/read deadline.
    nonisolated func httpRequestSentOnce(
        for request: URLRequest,
        maxBytes: Int,
        timeoutMilliseconds: UInt64
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let deadline = try TorHTTPRequestExecutor.deadline(timeoutMilliseconds: timeoutMilliseconds, now: DispatchTime.now().uptimeNanoseconds)
        let context = TorHTTPRequestContext(deadlineUptime: deadline, preserveHTTPFailure: true)
        return try await context.run { context in
            let owned = try await self.prepareBoundedOHTTP(for: request, maxBytes: maxBytes, context: context)
            return try await self.httpExecutor.execute(
                deadlineUptime: context.deadlineUptime,
                operation: { remaining in
                    try context.checkCancellation()
                    return try owned.run(timeoutMilliseconds: remaining)
                },
                dispose: { owned.dispose() },
                preserveHTTPFailure: true
            )
        }
    }

    private func prepareBoundedOHTTP(for request: URLRequest, maxBytes: Int, context: TorHTTPRequestContext) throws -> TorHTTPGetRequest {
        try context.checkCancellation()
        let url = try TorHTTPGetRequest.validate(request, allowPost: true)
        guard maxBytes >= 0 else { throw URLError(.badURL) }
        guard let runtime = underlyingRuntime else { throw ZcashError.torClientUnavailable }
        try context.claimOwnership()
        guard let isolated = httpGetNative.isolateRuntime(runtime) else {
            throw ZcashError.rustTorIsolatedClient(lastErrorMessage(fallback: "OHTTP could not isolate runtime"))
        }
        return TorHTTPGetRequest(
            runtime: isolated,
            request: request,
            url: url,
            retryLimit: 0,
            deadline: context.deadlineUptime,
            native: httpGetNative,
            bounded: maxBytes
        )
    }
}
