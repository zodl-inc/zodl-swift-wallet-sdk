//
//  OHTTPThirdPartyHosts.swift
//  ZODLSwiftWalletSDK
//
//  The passthrough hosts the gateway carries, as the HTTP request paths use them. A host that is not a fixed
//  destination is admitted by the gateway's own list, and the gateway's `403 unknown authority` answers are
//  reported back to that list.
//
//  The list is refreshed over the exchange the caller hands in: the request's own transport, so a request that
//  rides Tor has its refresh ride Tor as well, and no refresh is ever sent from the device's own address on its
//  behalf. Everything here runs inside the caller's own task, waits included: nothing is detached, and nothing
//  outlives the call that started it. The list is never logged, since its hosts identify the deployment.
//

import Foundation

/// Admission of the passthrough hosts the gateway carries, and the refresh of its host list.
enum OHTTPThirdPartyHosts {
    /// One request to the gateway and its answer: the means a refresh is carried by.
    typealias Exchange = (OHTTPRequest) async throws -> OHTTPResponse

    /// The relay timeout of the refresh run before a voting session opens.
    static let sessionRefreshTimeoutMS = 15_000
    /// The relay timeout of a refresh run while a request is admitted.
    static let admissionRefreshTimeoutMS = 10_000
    /// The longest wait, in seconds, for another caller's running refresh before a host that is not carried is
    /// refused: the list that refresh brings may carry it.
    static let runningRefreshWait: TimeInterval = 10

    /// The longest body that can be the gateway's `unknown authority` answer. Longer bodies are not reported, so
    /// a large answer is never held for it.
    private static let unknownAuthorityMaxBytes = 64

    /// How long a wait for a running refresh sleeps before it looks again.
    private static let runningRefreshPollNanoseconds: UInt64 = 200_000_000

    /// The exchange that carries a refresh over `transport`: its `roundTrip`, never its `stream`. The round trip
    /// uses the transport's own sender, which in Tor mode is a Tor circuit; the streamed path does not.
    static func exchange(through transport: OHTTPTransport, timeoutMS: Int) -> Exchange {
        { request in
            try await transport.roundTrip(request: request, timeoutMS: timeoutMS)
        }
    }

    /// Runs one refresh of `network`'s list if one is due. Nil when none was due.
    ///
    /// The refresh ends in every case: with the gateway's answer, or as failed when `exchange` throws, a
    /// cancellation included, so the list held stays in use and the next refresh is not blocked.
    @discardableResult
    static func refresh(network: NetworkType, exchange: Exchange) async -> OHTTPHostListRefreshOutcome? {
        guard let refresh = OHTTPNative.thirdPartyBeginRefresh(network: network) else {
            return nil
        }
        let request = OHTTPRequest(
            method: "GET",
            scheme: "https",
            authority: refresh.authority,
            path: refresh.path,
            headers: refresh.ifNoneMatch.map { [("if-none-match", $0)] } ?? [],
            body: Data()
        )
        do {
            let response = try await exchange(request)
            return refresh.finish(status: response.status, body: response.body)
        } catch {
            return refresh.fail()
        }
    }

    /// A destination that does not depend on the list: a configured gateway, an alias host, or the
    /// path-restricted voting-config mirror URL.
    static func isFixedDestination(_ url: URL, host: String) -> Bool {
        OHTTPEndpoints.isGateway(host) || OHTTPEndpoints.isAliasHost(host) || OHTTPEndpoints.isPathRestrictedProxyURL(url)
    }

    /// Passes, or throws `ZcashError.ohttpUnsupportedHost` before anything is sent to `host`.
    ///
    /// A fixed destination passes without the list. Any other host needs OHTTP on for `network` and no port but
    /// 443, since the request is sent under the host alone. A refresh that is due runs first, over `exchange`;
    /// a host the list does not carry then gets one more refresh when the list is worth asking again, and waits
    /// up to `runningRefreshWait` for a refresh another caller is running, before it is refused. Every wait
    /// happens in the caller's task, and a cancelled caller stops waiting.
    static func admit(
        url: URL,
        host: String,
        network: NetworkType,
        runningRefreshWait: TimeInterval = runningRefreshWait,
        exchange: Exchange
    ) async throws {
        if isFixedDestination(url, host: host) {
            return
        }
        guard OHTTPEndpoints.gatewayHost(for: network) != nil else {
            throw ZcashError.ohttpUnsupportedHost
        }
        if let port = url.port, port != 443 {
            throw ZcashError.ohttpUnsupportedHost
        }

        await refresh(network: network, exchange: exchange)
        if OHTTPEndpoints.isProxyAllowlisted(host: host, network: network) {
            return
        }

        if OHTTPNative.thirdPartyRefreshBeforeRefusing(network: network) {
            await refresh(network: network, exchange: exchange)
        }
        let waitStarted = ContinuousClock.now
        while OHTTPNative.thirdPartyIsRefreshing(network: network), seconds(since: waitStarted) < runningRefreshWait {
            try await Task.sleep(nanoseconds: runningRefreshPollNanoseconds)
        }

        guard OHTTPEndpoints.isProxyAllowlisted(host: host, network: network) else {
            throw ZcashError.ohttpUnsupportedHost
        }
    }

    /// Reports the gateway's answer to a request for `host` to the list of `network`: a `403 unknown authority`
    /// for a host the list names asks for a refresh. Other statuses, and bodies longer than the answer can be,
    /// are not reported.
    static func noteAnswer(status: Int, body: Data, host: String, network: NetworkType) {
        guard status == 403, body.count <= unknownAuthorityMaxBytes else {
            return
        }
        OHTTPNative.thirdPartyNoteAnswer(host: host, network: network, status: status, body: body)
    }

    /// `body` passed on unchanged; when it ends within 64 bytes, `noteAnswer(status: 403, …)` is told.
    ///
    /// For the body of a streamed `403` answer. The body is read by its consumer, as it comes; only its first
    /// bytes are kept, and only until it is longer than the answer can be. A body that fails is not reported.
    static func watchingForUnknownAuthority(
        _ body: AsyncThrowingStream<Data, Error>,
        host: String,
        network: NetworkType
    ) -> AsyncThrowingStream<Data, Error> {
        let watched = WatchedBody(body: body, host: host, network: network)
        return AsyncThrowingStream(unfolding: { try await watched.next() })
    }

    /// Whether a voting session about to open should refresh first: a session on the direct route to the
    /// predefined servers, with OHTTP on for `network`, is reduced to the servers the list carries when it opens.
    static func refreshesBeforeSessionOpen(route: VotingTransportRoute, isCustomServer: Bool, network: NetworkType) -> Bool {
        route == .direct && !isCustomServer && OHTTPEndpoints.gatewayHost(for: network) != nil
    }

    /// Seconds since `start`, on the clock that keeps counting while the device sleeps.
    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let components = start.duration(to: ContinuousClock.now).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    /// The body of a streamed `403` answer, read through: the source iterator, and the first bytes it gave.
    private final class WatchedBody: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<Data, Error>.Iterator
        private let host: String
        private let network: NetworkType
        /// The bytes read so far; nil once they are more than the answer can be, or once the body ended.
        private var head: Data? = Data()

        init(body: AsyncThrowingStream<Data, Error>, host: String, network: NetworkType) {
            iterator = body.makeAsyncIterator()
            self.host = host
            self.network = network
        }

        func next() async throws -> Data? {
            let chunk: Data?
            do {
                chunk = try await iterator.next()
            } catch {
                head = nil
                throw error
            }
            guard let chunk else {
                if let head {
                    self.head = nil
                    OHTTPThirdPartyHosts.noteAnswer(status: 403, body: head, host: host, network: network)
                }
                return nil
            }
            if let held = head {
                let read = held + chunk
                head = read.count <= OHTTPThirdPartyHosts.unknownAuthorityMaxBytes ? read : nil
            }
            return chunk
        }
    }
}
