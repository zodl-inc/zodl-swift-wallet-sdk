//! Transport route — Tor, OHTTP or direct — selected when a voting session is opened.
//!
//! `zcash_voting` keeps PIR, tree-sync, helper and vote-chain traffic behind one
//! host-supplied request executor, [`zcash_voting::RouteHttp`]. [`SdkRoute`] is
//! this SDK's executor: the wallet's Tor runtime, the OHTTP relay and gateway
//! the app configured, or the crate's own direct HTTP client
//! ([`resolve_session_route`] decides). A session picks one when it opens and
//! keeps it, together with the OHTTP configuration and the gateway host lists
//! it was picked under, so a round that chose Tor can never reach the network
//! any other way — a Tor route that cannot connect fails the request rather
//! than falling back, because a silent fall-back would put the voter's traffic
//! on the clear network after they asked for Tor, which is the one outcome
//! worse than the request failing.
//!
//! Which servers the OHTTP route reaches is the gateway's own host list of the
//! wallet's network ([`ThirdPartyHostLists`]). The SDK's compiled list
//! ([`crate::ohttp_hosts::BOOTSTRAP_THIRD_PARTY_HOSTS`]) is only where that
//! list starts, until the gateway's list was fetched. A session keeps the
//! predefined servers the list carries ([`retain_carried`]) and every request
//! is checked against it again before anything leaves the device.
//!
//! The crate owns protocol headers, deadlines, response ceilings and the
//! definite-versus-ambiguous classification; this module owns only how one
//! request leaves the device, and what the Tor client's failures mean in the
//! crate's [`RoutePhase`] terms.

use std::future::Future;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use slipstream_core::ohttp::{
    Dialer, HttpRoundTripError, NetworkType, ThirdPartyHostLists, ThirdPartyHosts,
    http_round_trip_with_dispatch, is_unknown_authority,
};
use zcash_client_backend::tor::{Error as TorError, http::HttpError};
use zcash_voting::{
    DirectRoute, HyperTransport, RouteError, RouteFuture, RouteHttp, RoutePhase, RouteRequest,
    RouteResponse,
};
use zodl_ohttp_client::OhttpNetworks;

use super::errors::invalid_input;

/// What a refusal adds while the host list it was decided by is being
/// refreshed: the server may be in the list that refresh brings.
const REFRESHING_SUFFIX: &str = "; its host list is being refreshed, try again shortly";

/// 64 MiB response cap for one voting call (the client's own bound; the gateway allows up to 256 MiB).
const MAX_OHTTP_RESPONSE_BYTES: usize = 64 * 1024 * 1024;

/// The request executor a voting session routes its traffic through.
///
/// Chosen once when the session opens. There is deliberately no path from
/// [`Self::Tor`] to a direct connection: an unavailable Tor route fails the
/// request.
pub(super) enum SdkRoute {
    /// The crate's own pooled HTTP/HTTPS client.
    Direct(DirectRoute),
    /// The wallet's Tor runtime. Boxed because an owned `TorRuntime` is an
    /// order of magnitude larger than a `DirectRoute`, and every session pays
    /// for the larger arm otherwise.
    Tor(Box<TorRoute>),
    /// The OHTTP relay and gateway, for predefined servers with Tor off and
    /// OHTTP configured for the wallet's network, to the servers the
    /// gateway's host list carries. Fails closed: there is no path from here
    /// to a direct connection.
    Ohttp(OhttpRoute),
    /// Refuses every request before dispatch and counts the attempts, so a
    /// test can prove which traffic reached the session's route.
    #[cfg(test)]
    Refusing(Arc<std::sync::atomic::AtomicUsize>),
}

impl SdkRoute {
    /// The direct HTTP/HTTPS route.
    pub(super) fn direct() -> Self {
        Self::Direct(DirectRoute::new())
    }

    /// The Tor route over `tor`.
    ///
    /// Takes the runtime by value so the session owns the handle it routes
    /// through; pass [`crate::tor::TorRuntime::isolated_client`] to keep a
    /// session's circuits unlinkable from the rest of the wallet's Tor use.
    pub(super) fn tor(tor: crate::tor::TorRuntime) -> Self {
        Self::Tor(Box::new(TorRoute { tor }))
    }
}

impl RouteHttp for SdkRoute {
    fn execute<'a>(
        &'a self,
        request: RouteRequest<'a>,
        on_dispatch: &'a (dyn Fn() + Send + Sync),
    ) -> RouteFuture<'a> {
        match self {
            Self::Direct(direct) => direct.execute(request, on_dispatch),
            Self::Tor(tor) => tor.execute(request, on_dispatch),
            Self::Ohttp(ohttp) => ohttp.execute(request, on_dispatch),
            #[cfg(test)]
            Self::Refusing(attempts) => {
                attempts.fetch_add(1, Ordering::SeqCst);
                Box::pin(async {
                    Err(RouteError::before_dispatch(
                        "refused by the test route".to_string(),
                    ))
                })
            }
        }
    }

    fn hook_precedes_connection_setup(&self) -> bool {
        match self {
            Self::Direct(direct) => direct.hook_precedes_connection_setup(),
            Self::Tor(tor) => tor.hook_precedes_connection_setup(),
            Self::Ohttp(ohttp) => ohttp.hook_precedes_connection_setup(),
            #[cfg(test)]
            Self::Refusing(_) => false,
        }
    }

    fn enforces_connect_timeout(&self) -> bool {
        match self {
            Self::Direct(direct) => direct.enforces_connect_timeout(),
            Self::Tor(tor) => tor.enforces_connect_timeout(),
            Self::Ohttp(ohttp) => ohttp.enforces_connect_timeout(),
            #[cfg(test)]
            Self::Refusing(_) => false,
        }
    }
}

/// Routes one voting request over the wallet's Tor client.
pub(super) struct TorRoute {
    tor: crate::tor::TorRuntime,
}

/// What the adapter had observed when the Tor client reported a failure.
///
/// The Tor client reports the same error type throughout a request, so what a
/// failure means depends on how far the request had got. The adapter learns
/// that from the one hook it is given: the response-parsing callback, which
/// runs only once response headers have arrived.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum TorPhase {
    /// No response headers had arrived.
    BeforeHeaders,
    /// Response headers had arrived; only the body was outstanding.
    AfterHeaders,
}

/// The [`RoutePhase`] a Tor client failure translates to.
///
/// Pre-dispatch is claimed only where the Tor client's error names a stage that
/// runs before the request is written — bootstrap, the circuit, TLS, building
/// the request, spawning the connection task — or a deadline that expired in
/// one. Everything else observed before headers may have reached the network
/// and is reported as such, because a helper or chain POST wrongly called
/// undispatched would be repeated.
// Consumed by `TorRoute::request`; also the module's unit-tested contract.
pub(super) fn classify_tor_error(error: &TorError, phase: TorPhase) -> RoutePhase {
    if phase == TorPhase::AfterHeaders {
        return RoutePhase::ResponseRead;
    }
    match error {
        TorError::MissingTorDirectory | TorError::Tor(_) | TorError::Io(_) => {
            RoutePhase::BeforeDispatch
        }
        TorError::Http(
            HttpError::NonHttpUrl
            | HttpError::Http(_)
            | HttpError::Tls(_)
            | HttpError::Spawn(_)
            | HttpError::Timeout(_),
        ) => RoutePhase::BeforeDispatch,
        // `HttpError::Hyper` covers the write and the wait for headers, so it
        // may have been delivered. `HttpError::Unsuccessful` is documented
        // upstream as unreachable for `http_get`/`http_post`; it is mapped here
        // rather than assumed away. Both enums are `#[non_exhaustive]`, so a
        // variant added upstream lands here too — conservatively.
        _ => RoutePhase::AfterDispatch,
    }
}

/// The URI a Tor request is dispatched to, or the pre-dispatch failure that
/// stands in for it.
///
/// Factored out of [`TorRoute::request`] so the rejection path is exercised
/// without a Tor runtime, which cannot be built without a Tor directory.
fn parse_url(url: &str) -> Result<http::Uri, RouteError> {
    url.parse::<http::Uri>()
        .map_err(|error| RouteError::before_dispatch(format!("invalid URL: {error}")))
}

/// The two request shapes the Tor client offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TorMethod {
    Get,
    Post,
}

/// The Tor client call `method` maps to, or the pre-dispatch failure for a
/// method it has no call for.
///
/// The crate only ever issues GET and POST. Anything else is refused rather
/// than quietly sent as one of them, because a method the endpoint did not
/// receive is a request it did not answer.
fn tor_method(method: &http::Method) -> Result<TorMethod, RouteError> {
    if *method == http::Method::GET {
        Ok(TorMethod::Get)
    } else if *method == http::Method::POST {
        Ok(TorMethod::Post)
    } else {
        Err(RouteError::before_dispatch(format!(
            "the Tor route cannot issue a {method} request"
        )))
    }
}

/// Reads a response body, stopping at `max` bytes.
///
/// Runs only after response headers have arrived, so every failure here is
/// [`RoutePhase::ResponseRead`] — a truncated read and an over-long body alike.
/// The body type is left generic because `hyper` is not a dependency of this
/// crate and its `Incoming` type therefore cannot be named.
async fn read_body<B: BodyExt<Data = Bytes>>(body: B, max: usize) -> Result<Vec<u8>, RouteError>
where
    B::Error: Into<Box<dyn std::error::Error + Send + Sync>>,
{
    Limited::new(body, max)
        .collect()
        .await
        .map(|body| body.to_bytes().to_vec())
        .map_err(|error| {
            RouteError::response_read(format!("read response body (limit {max} bytes): {error}"))
        })
}

impl TorRoute {
    async fn request(
        &self,
        request: RouteRequest<'_>,
        on_dispatch: &(dyn Fn() + Send + Sync),
    ) -> Result<RouteResponse, RouteError> {
        let RouteRequest {
            method,
            url,
            headers,
            body,
            timeout,
            // The Tor client's connection-setup deadline is fixed when the
            // client is created, so this route cannot bound setup per request
            // and says so through `enforces_connect_timeout`.
            connect_timeout: _,
            max_response_bytes,
        } = request;
        let uri = parse_url(url)?;
        let method = tor_method(&method)?;
        let headers = headers.to_vec();
        let apply = move |mut builder: http::request::Builder| {
            for (name, value) in &headers {
                builder = builder.header(name, value);
            }
            // The Tor client runs this callback with the circuit, the TLS
            // session and the HTTP/1 handshake already established, and writes
            // the request immediately after it returns. That makes this the
            // last moment at which no request byte can have left.
            on_dispatch();
            builder
        };
        let seen_headers = Arc::new(AtomicBool::new(false));
        let seen = Arc::clone(&seen_headers);
        // The body read's own failure travels as the response *value*, not as a
        // Tor error, so it can never be mistaken for a pre-dispatch failure.
        let read_response = move |body| async move {
            seen.store(true, Ordering::SeqCst);
            Ok(read_body(body, max_response_bytes).await)
        };
        let client = self.tor.client();
        // Retries are disabled: the crate decides what may be repeated, from a
        // phase this adapter reports. A retry here would repeat a POST the
        // crate had classified as ambiguous.
        let call = async {
            match method {
                TorMethod::Get => {
                    client
                        .http_get(uri, apply, read_response, 0, |_| None)
                        .await
                }
                TorMethod::Post => {
                    client
                        .http_post(
                            uri,
                            apply,
                            Full::new(Bytes::from(body)),
                            read_response,
                            0,
                            |_| None,
                        )
                        .await
                }
            }
        };
        let phase = || {
            if seen_headers.load(Ordering::SeqCst) {
                TorPhase::AfterHeaders
            } else {
                TorPhase::BeforeHeaders
            }
        };
        let response = tokio::time::timeout(timeout, call)
            .await
            .map_err(|_| match phase() {
                TorPhase::AfterHeaders => {
                    RouteError::response_read("timed out reading the response body")
                }
                TorPhase::BeforeHeaders => RouteError::before_dispatch("timed out before dispatch"),
            })?
            .map_err(|error| {
                let message = error.to_string();
                match classify_tor_error(&error, phase()) {
                    RoutePhase::BeforeDispatch => RouteError::before_dispatch(message),
                    RoutePhase::AfterDispatch => RouteError::after_dispatch(message),
                    RoutePhase::ResponseRead => RouteError::response_read(message),
                }
            })?;
        let (parts, body) = response.into_parts();
        let body = body?;
        let headers = parts
            .headers
            .iter()
            .filter_map(|(name, value)| {
                value
                    .to_str()
                    .ok()
                    .map(|value| (name.as_str().to_string(), value.to_string()))
            })
            .collect();
        Ok(RouteResponse {
            status: parts.status.as_u16(),
            headers,
            body,
        })
    }
}

impl RouteHttp for TorRoute {
    fn execute<'a>(
        &'a self,
        request: RouteRequest<'a>,
        on_dispatch: &'a (dyn Fn() + Send + Sync),
    ) -> RouteFuture<'a> {
        Box::pin(self.request(request, on_dispatch))
    }

    // `hook_precedes_connection_setup` and `enforces_connect_timeout` both keep
    // their `false` defaults, and both are load-bearing:
    //
    // The Tor client does not fuse connection setup with the first write — it
    // opens the circuit and completes the TLS and HTTP/1 handshakes before it
    // asks for the request headers, which is where the dispatch hook fires. So
    // every connect failure is already reported before the hook and stays
    // definite without any declaration. Claiming otherwise would buy nothing
    // and cost a great deal: the crate would then honor a pre-dispatch phase
    // reported *after* the hook, and the one deadline that can expire there
    // covers the write as well as the wait for headers. A POST cut off by it
    // would be reported as never sent and repeated.
    //
    // Connection setup is bounded by the deadline fixed when the Tor client was
    // created, not by the caller's `connect_timeout`, so this route claims no
    // connect budget either.
}

/// Whether `hosts` carries the server at `url` under a name without a port.
///
/// `Some` is the `:authority` the gateway knows the server by: the URL's host
/// in lower case. Only a plain `https` URL can be carried
/// ([`ThirdPartyHosts::filter_servers`]). A server on a port other than 443 is
/// `None` even when the list names it with that port, because the OHTTP round
/// trip sends the host alone: the request would reach the same name on 443.
fn carried_host(hosts: &ThirdPartyHosts, url: &str) -> Option<String> {
    hosts
        .filter_servers([url])
        .carried
        .into_iter()
        .next()
        .map(|server| server.authority)
        .filter(|authority| !authority.contains(':'))
}

/// The host list `lists` holds for the wallet's `network`; `None` when OHTTP
/// is off for the network, which it always is for regtest.
fn hosts_for(
    lists: &ThirdPartyHostLists,
    network: zcash_voting::Network,
) -> Option<&ThirdPartyHosts> {
    let (_, engine_network) = gateway_for(lists.networks(), network)?;
    lists.hosts(engine_network)
}

/// Whether a session rides the OHTTP route: Tor off, a predefined server and a
/// gateway for the wallet's `network` in `networks`. Only then does the
/// gateway's host list decide which of the session's servers it keeps
/// ([`retain_carried`]).
pub(super) fn rides_ohttp(
    networks: &OhttpNetworks,
    tor_on: bool,
    is_custom_server: bool,
    network: zcash_voting::Network,
) -> bool {
    !tor_on && !is_custom_server && gateway_for(networks, network).is_some()
}

/// Keeps the `endpoints` of one kind (`what`, as the message names it) that the
/// gateway's host list for the wallet's `network` carries ([`carried_host`]),
/// in their order, and leaves the others out: with Tor off a predefined server
/// is reached through the gateway or not at all.
///
/// Fails with `invalid_input` when the kind listed servers and none of them is
/// carried. While the list is being refreshed the message says to try again
/// shortly, because the refresh may bring them. An empty `endpoints` is left
/// alone. The message names no host.
pub(super) fn retain_carried(
    lists: &ThirdPartyHostLists,
    network: zcash_voting::Network,
    endpoints: &mut Vec<String>,
    what: &str,
) -> anyhow::Result<()> {
    let listed = endpoints.len();
    if listed == 0 {
        return Ok(());
    }
    let hosts = hosts_for(lists, network);
    endpoints.retain(|url| hosts.is_some_and(|hosts| carried_host(hosts, url).is_some()));
    if endpoints.is_empty() {
        let refreshing = if hosts.is_some_and(ThirdPartyHosts::is_refreshing) {
            REFRESHING_SUFFIX
        } else {
            ""
        };
        return Err(invalid_input(format!(
            "the OHTTP gateway carries none of the {listed} predefined {what} servers, and with Tor disabled they are not reached any other way{refreshing}"
        )));
    }
    Ok(())
}

/// Routes voting requests through the OHTTP gateway: the request is
/// BHTTP-encoded and HPKE-encrypted, sent via the relay, and the gateway
/// forwards it to the vote or PIR server. The relay sees the device address but
/// only ciphertext; the gateway sees the request but only the relay's address.
///
/// Used when Tor is off, the server is a predefined one and OHTTP is configured
/// for the wallet's network. Which servers it reaches is the gateway's host
/// list of that network, which starts from the SDK's compiled list until the
/// gateway's own list was fetched. Fails closed: a request the gateway does not
/// carry fails rather than going out directly, which would show the voter's
/// address to the vote server.
///
/// Rides the same OHTTP stack as the lightwalletd path (signed HPKE key
/// configs fetched through the relay, 64 MiB response cap).
pub(super) struct OhttpRoute {
    /// The OHTTP configuration and the gateway host lists the session opened
    /// under, which every request of the session uses.
    lists: Arc<ThirdPartyHostLists>,
    gateway_host: String,
    network: NetworkType,
}

impl OhttpRoute {
    /// The OHTTP route for the server at `url` through the gateway `lists`
    /// configures for the wallet's `network`, or a pre-dispatch failure when
    /// the gateway's host list does not carry that server ([`carried_host`]) or
    /// there is no gateway for the network (OHTTP off for it, or regtest).
    /// Decided by the list as it is: this never refreshes it.
    pub(super) fn new(
        lists: &Arc<ThirdPartyHostLists>,
        url: &str,
        network: zcash_voting::Network,
    ) -> Result<Self, RouteError> {
        let no_gateway = || RouteError::before_dispatch("no OHTTP gateway for this network");
        let (gateway_host, network) =
            gateway_for(lists.networks(), network).ok_or_else(no_gateway)?;
        let hosts = lists.hosts(network).ok_or_else(no_gateway)?;
        if carried_host(hosts, url).is_none() {
            return Err(RouteError::before_dispatch(
                "host not carried by the OHTTP gateway",
            ));
        }
        Ok(Self {
            lists: Arc::clone(lists),
            gateway_host: gateway_host.to_string(),
            network,
        })
    }

    /// Admits `url` or refuses it before dispatch; runs `refresh` at most once,
    /// only before refusing.
    ///
    /// `Ok` is the `:authority` the gateway carries the server as
    /// ([`carried_host`]). A server the list does not carry gets one refresh
    /// first when the list is worth refreshing
    /// ([`ThirdPartyHosts::refresh_before_refusing`]), since a server added to
    /// the gateway after the list was fetched is in the next one. The refusal
    /// says to try again shortly while a refresh is still running. No lock is
    /// held while `refresh` runs.
    async fn admit<R, Fut>(&self, url: &str, refresh: R) -> Result<String, RouteError>
    where
        R: FnOnce() -> Fut,
        Fut: Future<Output = ()>,
    {
        let hosts = self
            .lists
            .hosts(self.network)
            .ok_or_else(|| RouteError::before_dispatch("no OHTTP gateway for this network"))?;
        if let Some(authority) = carried_host(hosts, url) {
            return Ok(authority);
        }
        if hosts.refresh_before_refusing() {
            refresh().await;
            if let Some(authority) = carried_host(hosts, url) {
                return Ok(authority);
            }
        }
        let refreshing = if hosts.is_refreshing() {
            REFRESHING_SUFFIX
        } else {
            ""
        };
        Err(RouteError::before_dispatch(format!(
            "host not carried by the OHTTP gateway{refreshing}"
        )))
    }
}

/// The OHTTP gateway `networks` configures for `network`, and the network the
/// engine checks it against; `None` when OHTTP is off for the network, which it
/// always is for regtest. A testnet session never rides the mainnet gateway,
/// nor the other way round.
fn gateway_for(
    networks: &OhttpNetworks,
    network: zcash_voting::Network,
) -> Option<(&str, NetworkType)> {
    let (ohttp_network, engine_network) = match network {
        zcash_voting::Network::Mainnet => (zodl_ohttp_client::Network::Mainnet, NetworkType::Main),
        zcash_voting::Network::Testnet => (zodl_ohttp_client::Network::Testnet, NetworkType::Test),
        zcash_voting::Network::Regtest => return None,
    };
    networks
        .get(ohttp_network)
        .map(|config| (config.gateway_host(), engine_network))
}

/// Wraps `on_dispatch` so that `dispatched` records whether it fired.
fn dispatch_tracking<'a>(
    dispatched: &'a AtomicBool,
    on_dispatch: &'a (dyn Fn() + Send + Sync),
) -> impl Fn() + Send + Sync + 'a {
    move || {
        dispatched.store(true, Ordering::SeqCst);
        on_dispatch();
    }
}

/// A transport failure or timeout is ambiguous only once the sealed request may have left the
/// device. `on_dispatch` runs right before the sealed request is written to the relay
/// connection, so a key-config failure, a relay pause or a relay that cannot be reached stays
/// before dispatch: the request is provably unsent, and it keeps the before-dispatch phase and
/// its safe retry.
fn dispatch_phase_error(dispatched: &AtomicBool, message: String) -> RouteError {
    if dispatched.load(Ordering::SeqCst) {
        RouteError::after_dispatch(message)
    } else {
        RouteError::before_dispatch(format!("{message} (before dispatch)"))
    }
}

/// The route failure for an OHTTP round trip that ended in `error`.
///
/// An answer past the ceiling is a response-read failure whether or not the hook fired, because
/// the engine reads an answer only after it has sent the request. Any other failure follows the
/// hook, as [`dispatch_phase_error`] describes.
fn ohttp_route_error(dispatched: &AtomicBool, error: HttpRoundTripError) -> RouteError {
    match error {
        HttpRoundTripError::ResponseTooLarge(message) => {
            RouteError::response_read(format!("OHTTP response too large: {message}"))
        }
        HttpRoundTripError::Failed(message) => {
            dispatch_phase_error(dispatched, format!("OHTTP transport: {message}"))
        }
    }
}

impl RouteHttp for OhttpRoute {
    fn execute<'a>(
        &'a self,
        request: RouteRequest<'a>,
        on_dispatch: &'a (dyn Fn() + Send + Sync),
    ) -> RouteFuture<'a> {
        Box::pin(async move {
            // The session's endpoints were checked when it opened, but helper
            // and tree-node URLs arrive later from the host, and the gateway's
            // list can change meanwhile: refuse a server the list does not
            // carry, after at most one refresh, before anything leaves the
            // device. The refresh rides the session's own route to the relay;
            // a failed one keeps the list held, which then decides.
            let authority = self
                .admit(request.url, || async {
                    let _ = self.lists.refresh(self.network, Dialer::Direct).await;
                })
                .await?;

            let method = request.method.as_str().to_string();
            let max_response_bytes = request.max_response_bytes.min(MAX_OHTTP_RESPONSE_BYTES);

            // Track whether on_dispatch fired. Failures before the callback are definitely unsent
            // (before-dispatch phase, safe to retry); failures after it are ambiguous.
            let dispatched = AtomicBool::new(false);
            let wrapped_on_dispatch = dispatch_tracking(&dispatched, on_dispatch);

            // The relay leg uses the device's own connection (`Dialer::Direct`).
            // The callback fires right before the sealed request is written to the relay
            // connection, so a key-config failure, a relay pause or a relay that cannot be
            // reached stays before dispatch. The engine also stops reading an answer once it
            // is past `max_response_bytes`, instead of buffering it in full.
            let call = http_round_trip_with_dispatch(
                self.lists.networks(),
                &self.gateway_host,
                self.network,
                Dialer::Direct,
                &method,
                request.url,
                request.headers,
                &request.body,
                max_response_bytes,
                &wrapped_on_dispatch,
            );
            let (status, headers, body) = tokio::time::timeout(request.timeout, call)
                .await
                .map_err(|_| {
                    dispatch_phase_error(&dispatched, "OHTTP request timed out".to_string())
                })?
                .map_err(|error| ohttp_route_error(&dispatched, error))?;

            // The engine refuses a longer body itself; this check only keeps the ceiling true
            // should that ever change.
            if body.len() > max_response_bytes {
                return Err(RouteError::response_read(format!(
                    "response body too large: {} > {max_response_bytes} bytes",
                    body.len()
                )));
            }
            let response = zodl_ohttp_client::Response {
                status,
                headers,
                body,
            };
            // The gateway refused a server its list names: the replica that
            // answered has not learned it yet, so the list is fetched again at
            // the next refresh. The answer itself reaches the crate unchanged.
            if is_unknown_authority(&response)
                && let Some(hosts) = self.lists.hosts(self.network)
            {
                hosts.report_unknown_authority(&authority);
            }
            Ok(RouteResponse {
                status: response.status,
                headers: response.headers,
                body: response.body,
            })
        })
    }
}

/// Chooses the route a voting session rides, from Tor availability, whether
/// the servers are the user's own and the OHTTP configuration of `lists`
/// ([`ThirdPartyHostLists::networks`]).
///
/// - Tor on (`tor` is `Some`): [`SdkRoute::Tor`], over an isolated client, to
///   the vote and PIR servers directly.
/// - Tor off and a custom server: [`SdkRoute::Direct`]. Choosing one's own
///   server is the user's decision to be reached directly.
/// - Tor off, a predefined server and OHTTP configured for the wallet's
///   network: [`SdkRoute::Ohttp`] through the relay and gateway, and an error
///   when the gateway's host list does not carry every one of
///   `endpoint_urls`. No fallback to a direct connection. The session open
///   leaves out the servers the list does not carry before it gets here
///   ([`retain_carried`]).
/// - Tor off, a predefined server and OHTTP off for the wallet's network:
///   [`SdkRoute::Direct`]. There is no gateway to carry the request, and the
///   rest of the wallet's traffic on that network goes direct too.
///
/// `endpoint_urls` is every chain and PIR endpoint the session will use: they
/// share one route (a PIR query hides which rows are fetched, not who fetches
/// them), so one that the gateway cannot carry refuses the session rather than
/// failing partway through a round. It is read only in the Tor-off, predefined
/// case with OHTTP on. The route keeps `lists`, so every request of the session
/// is decided by the lists it opened with.
pub(super) fn resolve_session_route(
    lists: Arc<ThirdPartyHostLists>,
    tor: Option<&crate::tor::TorRuntime>,
    is_custom_server: bool,
    network: zcash_voting::Network,
    endpoint_urls: &[&str],
) -> anyhow::Result<SdkRoute> {
    if let Some(tor) = tor {
        return Ok(SdkRoute::tor(tor.isolated_client()));
    }
    if is_custom_server || gateway_for(lists.networks(), network).is_none() {
        return Ok(SdkRoute::direct());
    }
    // Every endpoint must pass; the route itself carries no per-endpoint state.
    let mut routes = endpoint_urls.iter().map(|url| {
        OhttpRoute::new(&lists, url, network).map_err(|error| {
            invalid_input(format!(
                "cannot reach predefined vote server at {url} with Tor disabled: {error}"
            ))
        })
    });
    let route = routes
        .next()
        .ok_or_else(|| invalid_input("at least one endpoint is required to choose a route"))??;
    for other in routes {
        other?;
    }
    Ok(SdkRoute::Ohttp(route))
}

/// The crate transport for every service of one session: chain, helper, PIR
/// and vote-tree traffic.
pub(super) fn routed_transport(route: SdkRoute) -> Arc<HyperTransport<SdkRoute>> {
    Arc::new(HyperTransport::with_route(route))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use http_body_util::Full;
    use std::sync::atomic::{AtomicBool, Ordering};
    use zcash_client_backend::tor::{
        Error as TorError,
        http::{HttpError, TimeoutPhase},
    };
    use zcash_voting::{RouteHttp, RoutePhase, RouteRequest};
    use zodl_ohttp_client::OhttpNetworks;

    use crate::ohttp_config::example;
    use slipstream_core::ohttp::{RefreshOutcome, ThirdPartyHostLists};
    use std::sync::atomic::AtomicUsize;

    /// Both networks configured, with the example values.
    fn configured() -> Arc<OhttpNetworks> {
        Arc::new(example::networks())
    }

    /// Lists for the example configuration, starting from the SDK's bootstrap list.
    fn lists() -> Arc<ThirdPartyHostLists> {
        Arc::new(ThirdPartyHostLists::new(
            configured(),
            crate::ohttp_hosts::BOOTSTRAP_THIRD_PARTY_HOSTS,
        ))
    }

    /// Makes `lists` hold a list just fetched from the gateway of `network` (scope `all`).
    fn install_list(lists: &ThirdPartyHostLists, network: NetworkType, hosts: &[&str]) {
        let holder = lists.hosts(network).expect("configured");
        let refresh = holder.begin_refresh().expect("due");
        let entries: Vec<String> = hosts
            .iter()
            .map(|host| format!(r#"{{"host":"{host}","routes":["* /*"]}}"#))
            .collect();
        let body = format!(
            r#"{{"version":1,"revision":"test","scope":"all","max_age_secs":300,"hosts":[{}]}}"#,
            entries.join(",")
        );
        let response = zodl_ohttp_client::Response {
            status: 200,
            headers: Vec::new(),
            body: body.into_bytes(),
        };
        assert_eq!(
            holder.finish_refresh(refresh, Some(&response)),
            RefreshOutcome::Updated
        );
    }

    fn http_build_error() -> http::Error {
        http::Request::builder()
            .header("invalid header name", "v")
            .body(())
            .expect_err("an invalid header name fails the builder")
    }

    fn json_error() -> serde_json::Error {
        serde_json::from_slice::<serde_json::Value>(b"truncated")
            .expect_err("`truncated` is not JSON")
    }

    #[test]
    fn tor_bootstrap_and_url_failures_are_before_dispatch() {
        for error in [
            TorError::MissingTorDirectory,
            TorError::Io(std::io::Error::other("fixture")),
            TorError::Http(HttpError::NonHttpUrl),
            TorError::Http(HttpError::Http(http_build_error())),
            TorError::Http(HttpError::Tls(std::io::Error::other("fixture"))),
            TorError::Http(HttpError::Timeout(TimeoutPhase::Connect)),
            TorError::Http(HttpError::Timeout(TimeoutPhase::Request)),
        ] {
            assert_eq!(
                classify_tor_error(&error, TorPhase::BeforeHeaders),
                RoutePhase::BeforeDispatch,
                "{error} must be reported as definitely undispatched"
            );
        }
    }

    #[test]
    fn other_failures_before_headers_are_after_dispatch() {
        for error in [
            TorError::Http(HttpError::Json(json_error())),
            // Documented upstream as unreachable for `http_get`/`http_post`; mapped
            // defensively rather than assumed away.
            TorError::Http(HttpError::Unsuccessful(
                http::StatusCode::INTERNAL_SERVER_ERROR,
            )),
        ] {
            assert_eq!(
                classify_tor_error(&error, TorPhase::BeforeHeaders),
                RoutePhase::AfterDispatch,
                "{error} may have reached the network"
            );
        }
    }

    #[test]
    fn failures_after_headers_are_response_read() {
        assert_eq!(
            classify_tor_error(
                &TorError::Http(HttpError::NonHttpUrl),
                TorPhase::AfterHeaders
            ),
            RoutePhase::ResponseRead
        );
        assert_eq!(
            classify_tor_error(
                &TorError::Http(HttpError::Timeout(TimeoutPhase::ResponseBody)),
                TorPhase::AfterHeaders
            ),
            RoutePhase::ResponseRead
        );
    }

    #[test]
    fn tor_route_with_invalid_url_fails_before_dispatch_without_network() {
        // A `TorRuntime` cannot be created without a Tor directory; the URL check runs
        // first, so it is factored out and exercised on its own.
        let error = parse_url("not a url").expect_err("a URL with spaces cannot be a URI");
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);
        assert!(parse_url("https://helper.example/x").is_ok());
    }

    #[test]
    fn only_get_and_post_reach_the_tor_client() {
        assert!(matches!(tor_method(&http::Method::GET), Ok(TorMethod::Get)));
        assert!(matches!(
            tor_method(&http::Method::POST),
            Ok(TorMethod::Post)
        ));
        let error = tor_method(&http::Method::PUT).expect_err("PUT is not a voting method");
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);
    }

    #[test]
    fn response_body_cap_is_enforced_after_headers() {
        let runtime = crate::voting::runtime::runtime();
        let body = |len: usize| Full::new(Bytes::from(vec![0u8; len]));
        assert_eq!(
            runtime.block_on(read_body(body(8), 8)).expect("under cap"),
            vec![0u8; 8]
        );
        let error = runtime
            .block_on(read_body(body(9), 8))
            .expect_err("over cap");
        assert_eq!(error.phase, RoutePhase::ResponseRead);
    }

    #[test]
    fn dispatch_phase_follows_the_callback() {
        let dispatched = AtomicBool::new(false);
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let on_dispatch = || {
            calls.fetch_add(1, Ordering::SeqCst);
        };
        let wrapped = dispatch_tracking(&dispatched, &on_dispatch);

        // Key-config fetch failed: the callback never ran.
        let error = dispatch_phase_error(&dispatched, "config HTTP 503".to_string());
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);

        wrapped();
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "the caller's callback still runs"
        );
        let error = dispatch_phase_error(&dispatched, "relay reset".to_string());
        assert_eq!(error.phase, RoutePhase::AfterDispatch);
    }

    #[test]
    fn ohttp_response_too_large_is_a_response_read_failure() {
        // An answer is only read once the request has been sent, so whether the hook fired
        // does not decide this failure.
        for dispatched in [false, true] {
            let error = ohttp_route_error(
                &AtomicBool::new(dispatched),
                HttpRoundTripError::ResponseTooLarge(
                    "response body too large: 300 > 200 bytes".into(),
                ),
            );
            assert_eq!(
                error.phase,
                RoutePhase::ResponseRead,
                "an answer past the ceiling is a response-read failure (dispatched: {dispatched})"
            );
            assert!(
                error.message.contains("300 > 200"),
                "the sizes reach the caller: {}",
                error.message
            );
        }
    }

    #[test]
    fn ohttp_failures_follow_the_dispatch_hook() {
        let error = ohttp_route_error(
            &AtomicBool::new(false),
            HttpRoundTripError::Failed("relay down".into()),
        );
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);
        assert!(
            error.message.ends_with("(before dispatch)"),
            "{}",
            error.message
        );

        let error = ohttp_route_error(
            &AtomicBool::new(true),
            HttpRoundTripError::Failed("relay down".into()),
        );
        assert_eq!(error.phase, RoutePhase::AfterDispatch);
    }

    #[test]
    fn ohttp_route_host_validation_is_before_dispatch() {
        // Host validation happens before any network call, so it's always before-dispatch.
        let error = OhttpRoute::new(
            &lists(),
            "https://unknown.example",
            zcash_voting::Network::Mainnet,
        )
        .err()
        .expect("host not carried by the gateway");
        assert_eq!(
            error.phase,
            RoutePhase::BeforeDispatch,
            "Host validation failure should be before-dispatch"
        );
    }

    #[test]
    fn ohttp_route_uses_the_gateway_of_the_wallet_network() {
        let url = "https://vote.zodl.com";
        let lists = lists();
        let mainnet =
            OhttpRoute::new(&lists, url, zcash_voting::Network::Mainnet).expect("mainnet");
        assert_eq!(mainnet.gateway_host, example::MAINNET.gateway_host);
        assert_eq!(mainnet.network, NetworkType::Main);
        let testnet =
            OhttpRoute::new(&lists, url, zcash_voting::Network::Testnet).expect("testnet");
        assert_eq!(testnet.gateway_host, example::TESTNET.gateway_host);
        assert_eq!(testnet.network, NetworkType::Test);
        let error = OhttpRoute::new(&lists, url, zcash_voting::Network::Regtest)
            .err()
            .expect("no regtest gateway");
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);
        // A network without a configuration has no gateway either.
        let error = OhttpRoute::new(
            &Arc::new(ThirdPartyHostLists::new(
                Arc::new(OhttpNetworks::default()),
                crate::ohttp_hosts::BOOTSTRAP_THIRD_PARTY_HOSTS,
            )),
            url,
            zcash_voting::Network::Mainnet,
        )
        .err()
        .expect("no gateway with OHTTP off");
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);
    }

    #[test]
    fn direct_route_executes_against_loopback_server() {
        // Minimal HTTP/1.1 server on 127.0.0.1 answering 200 with body "ok". Bound
        // before the thread is spawned so the address is live when the client dials,
        // and the thread returns rather than blocking if no client ever arrives.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let addr = listener.local_addr().expect("loopback address");
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            // Read the whole request head before answering, so the response is not
            // written into a half-sent request.
            let mut head = Vec::new();
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") {
                match stream.read(&mut byte) {
                    Ok(1) => head.push(byte[0]),
                    _ => return,
                }
            }
            let _ = stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
        });

        let route = SdkRoute::direct();
        let url = format!("http://{addr}/x");
        let headers: Vec<(String, String)> = Vec::new();
        let request = RouteRequest {
            method: http::Method::GET,
            url: &url,
            headers: &headers,
            body: Vec::new(),
            timeout: std::time::Duration::from_secs(5),
            connect_timeout: None,
            max_response_bytes: 1024,
        };
        let dispatched = AtomicBool::new(false);
        let response = crate::voting::runtime::runtime()
            .block_on(route.execute(request, &|| dispatched.store(true, Ordering::SeqCst)))
            .expect("the loopback server answers");
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"ok");
        assert!(dispatched.load(Ordering::SeqCst));
    }

    #[test]
    fn direct_route_delegates_its_dispatch_semantics() {
        let route = SdkRoute::direct();
        assert!(route.hook_precedes_connection_setup());
        assert!(route.enforces_connect_timeout());
    }

    #[test]
    fn routed_transport_carries_the_selected_route() {
        let transport = routed_transport(SdkRoute::direct());
        assert!(matches!(**transport.route(), SdkRoute::Direct(_)));
    }

    const EXPECTED_VOTE_HOSTS: [&str; 18] = [
        "vote.zodl.com",
        "prod.vote-chain-primary.valargroup.org",
        "voting.valargroup.dev",
        "ru.zcash.space",
        "147-182-192-212.sslip.io",
        "134-209-215-69.sslip.io",
        "mnval01.zcash.legends.sh",
        "zvote-1.stardust.rest",
        "zvote.zodl.com",
        "zvote.keplr.app",
        "zvote.zfnd.org",
        "v.ombie.cash",
        "svote.zcashlabs.com",
        "207-180-214-226.sslip.io",
        "vote.atlasstaking.com",
        "zvote.polkachu.com",
        "zvote.cros-nest.net",
        "vote.infra.cypherpunk.com",
    ];

    const EXPECTED_PIR_HOSTS: [&str; 3] = [
        "lb-pir-primary.valargroup.org",
        "lb-pir-backup.valargroup.org",
        "zpir-1.stardust.rest",
    ];

    fn variant(route: &SdkRoute) -> &'static str {
        match route {
            SdkRoute::Direct(_) => "Direct",
            SdkRoute::Tor(_) => "Tor",
            SdkRoute::Ohttp(_) => "Ohttp",
            SdkRoute::Refusing(_) => "Refusing",
        }
    }

    #[test]
    fn ohttp_route_rejects_unsupported_and_malformed_urls() {
        for url in [
            "https://custom.example.com/api/vote",
            "https://pir.valargroup.org/api",
            // Userinfo must not smuggle a listed host in front of the real one.
            "https://vote.zodl.com@evil.example/api",
            "not a url",
            "vote.zodl.com",
        ] {
            let error = OhttpRoute::new(&lists(), url, zcash_voting::Network::Mainnet)
                .err()
                .expect(url);
            assert_eq!(error.phase, RoutePhase::BeforeDispatch, "{url}");
        }
    }

    #[test]
    fn ohttp_route_accepts_every_gateway_host_with_or_without_slash_and_port() {
        let lists = lists();
        for host in EXPECTED_VOTE_HOSTS.iter().chain(EXPECTED_PIR_HOSTS.iter()) {
            for url in [
                format!("https://{host}"),
                format!("https://{host}/"),
                format!("https://{host}:443/api/v1/round"),
            ] {
                assert!(
                    OhttpRoute::new(&lists, &url, zcash_voting::Network::Mainnet).is_ok(),
                    "{url}"
                );
            }
        }
    }

    #[test]
    fn tor_off_custom_server_routes_direct() {
        for urls in [
            &["https://custom.example.com"][..],
            // Custom servers ride direct even at a host the gateway lists.
            &["https://vote.zodl.com"][..],
            &[][..],
        ] {
            let route =
                resolve_session_route(lists(), None, true, zcash_voting::Network::Mainnet, urls)
                    .expect("custom server");
            assert_eq!(variant(&route), "Direct");
        }
    }

    #[test]
    fn tor_off_predefined_servers_route_through_ohttp() {
        for host in EXPECTED_VOTE_HOSTS {
            let url = format!("https://{host}");
            let route = resolve_session_route(
                lists(),
                None,
                false,
                zcash_voting::Network::Mainnet,
                &[&url],
            )
            .expect(host);
            assert_eq!(variant(&route), "Ohttp", "{host}");
        }
        // The three PIR hosts take the same route as the vote servers.
        for host in EXPECTED_PIR_HOSTS {
            let url = format!("https://{host}/");
            let route = resolve_session_route(
                lists(),
                None,
                false,
                zcash_voting::Network::Mainnet,
                &[&url],
            )
            .expect(host);
            assert_eq!(variant(&route), "Ohttp", "{host}");
        }
        // A session's chain and PIR endpoints together.
        let route = resolve_session_route(
            lists(),
            None,
            false,
            zcash_voting::Network::Mainnet,
            &[
                "https://vote.zodl.com",
                "https://zvote.zodl.com/",
                "https://lb-pir-primary.valargroup.org/",
            ],
        )
        .expect("mixed vote and PIR endpoints");
        assert_eq!(variant(&route), "Ohttp");
    }

    #[test]
    fn tor_off_unknown_predefined_server_fails_closed() {
        for urls in [
            &["https://unknown.example.com/"][..],
            // One unsupported endpoint refuses the whole session.
            &["https://vote.zodl.com", "https://pir.example.com/"][..],
            &[][..],
        ] {
            let error =
                resolve_session_route(lists(), None, false, zcash_voting::Network::Mainnet, urls)
                    .err()
                    .unwrap_or_else(|| panic!("{urls:?} must not resolve a route"));
            // Crosses the FFI as the typed `invalid_input` envelope.
            let view: serde_json::Value =
                serde_json::from_str(&error.to_string()).expect("typed VotingErrorView JSON");
            assert_eq!(view["kind"], "invalid_input", "{urls:?}");
        }
    }

    #[test]
    fn voting_route_goes_direct_without_configuration() {
        let mainnet_only = Arc::new(
            OhttpNetworks::new(Some(example::config(example::MAINNET)), None).expect("mainnet"),
        );
        for (networks, network) in [
            (
                Arc::new(OhttpNetworks::default()),
                zcash_voting::Network::Mainnet,
            ),
            (
                Arc::new(OhttpNetworks::default()),
                zcash_voting::Network::Testnet,
            ),
            // Configuring the other network does not configure the wallet's.
            (mainnet_only, zcash_voting::Network::Testnet),
            // OHTTP never serves regtest.
            (configured(), zcash_voting::Network::Regtest),
        ] {
            // Predefined servers, the gateway's hosts and others alike: with OHTTP off for the
            // wallet's network there is no gateway to carry them, so they are reached directly.
            for urls in [
                &[
                    "https://vote.zodl.com",
                    "https://lb-pir-primary.valargroup.org/",
                ][..],
                &["https://unknown.example.com/"][..],
            ] {
                let lists = Arc::new(ThirdPartyHostLists::new(
                    Arc::clone(&networks),
                    crate::ohttp_hosts::BOOTSTRAP_THIRD_PARTY_HOSTS,
                ));
                let route = resolve_session_route(lists, None, false, network, urls)
                    .unwrap_or_else(|error| panic!("{network:?} {urls:?}: {error}"));
                assert_eq!(variant(&route), "Direct", "{network:?} {urls:?}");
            }
        }
    }

    #[test]
    fn voting_route_uses_ohttp_with_configuration() {
        let urls = &["https://vote.zodl.com", "https://zpir-1.stardust.rest/"][..];
        for (network, gateway_host, engine_network) in [
            (
                zcash_voting::Network::Mainnet,
                example::MAINNET.gateway_host,
                NetworkType::Main,
            ),
            (
                zcash_voting::Network::Testnet,
                example::TESTNET.gateway_host,
                NetworkType::Test,
            ),
        ] {
            let networks = configured();
            let route = resolve_session_route(
                Arc::new(ThirdPartyHostLists::new(
                    Arc::clone(&networks),
                    crate::ohttp_hosts::BOOTSTRAP_THIRD_PARTY_HOSTS,
                )),
                None,
                false,
                network,
                urls,
            )
            .unwrap_or_else(|error| panic!("{network:?}: {error}"));
            let route = match route {
                SdkRoute::Ohttp(route) => route,
                other => panic!("{network:?} took the {} route", variant(&other)),
            };
            // The session rides the gateway of its network, under the configuration it opened
            // with.
            assert_eq!(route.gateway_host, gateway_host);
            assert_eq!(route.network, engine_network);
            assert!(Arc::ptr_eq(route.lists.networks(), &networks));

            // Unchanged with a configuration: a server the gateway does not carry still refuses
            // the session rather than going direct.
            assert!(
                resolve_session_route(
                    lists(),
                    None,
                    false,
                    network,
                    &["https://vote.zodl.com", "https://unknown.example.com/"],
                )
                .is_err()
            );
        }
    }

    #[tokio::test]
    async fn ohttp_route_refuses_an_unlisted_host_before_dispatch() {
        let lists = lists();
        // A list just fetched: the refusal needs no refresh first.
        install_list(&lists, NetworkType::Main, &["vote.zodl.com"]);
        let route = OhttpRoute::new(
            &lists,
            "https://vote.zodl.com",
            zcash_voting::Network::Mainnet,
        )
        .expect("listed host");
        let dispatched = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&dispatched);
        let on_dispatch = move || flag.store(true, Ordering::SeqCst);
        let headers = Vec::new();
        let error = route
            .execute(
                RouteRequest {
                    method: http::Method::GET,
                    url: "https://helper.example.com/status",
                    headers: &headers,
                    body: Vec::new(),
                    timeout: std::time::Duration::from_secs(5),
                    connect_timeout: None,
                    max_response_bytes: 1024,
                },
                &on_dispatch,
            )
            .await
            .expect_err("an unlisted host never reaches the gateway");
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);
        assert!(!dispatched.load(Ordering::SeqCst));
    }

    #[test]
    fn rides_ohttp_only_with_tor_off_a_predefined_server_and_a_gateway() {
        let networks = configured();
        let mainnet = zcash_voting::Network::Mainnet;
        assert!(rides_ohttp(&networks, false, false, mainnet));
        assert!(!rides_ohttp(&networks, true, false, mainnet), "Tor on");
        assert!(
            !rides_ohttp(&networks, false, true, mainnet),
            "custom server"
        );
        assert!(
            !rides_ohttp(&networks, false, false, zcash_voting::Network::Regtest),
            "regtest"
        );
        assert!(
            !rides_ohttp(&OhttpNetworks::default(), false, false, mainnet),
            "OHTTP off"
        );
    }

    /// `urls` as a session's inputs hold them.
    fn endpoints(urls: &[&str]) -> Vec<String> {
        urls.iter().map(|url| url.to_string()).collect()
    }

    #[test]
    fn a_session_keeps_the_carried_servers() {
        let mut endpoints = endpoints(&[
            "https://vote.zodl.com",
            "https://unknown.example.com/",
            "https://zvote.zodl.com:443/api",
        ]);
        retain_carried(
            &lists(),
            zcash_voting::Network::Mainnet,
            &mut endpoints,
            "vote",
        )
        .expect("two servers are carried");
        assert_eq!(
            endpoints,
            ["https://vote.zodl.com", "https://zvote.zodl.com:443/api"]
        );
    }

    #[test]
    fn a_kind_with_no_carried_server_refuses_the_session() {
        let mut endpoints = endpoints(&["https://unknown.example.com/"]);
        let error = retain_carried(
            &lists(),
            zcash_voting::Network::Mainnet,
            &mut endpoints,
            "vote",
        )
        .expect_err("no server is carried");
        let message = error.to_string();
        // Crosses the FFI as the typed `invalid_input` envelope.
        let view: serde_json::Value =
            serde_json::from_str(&message).expect("typed VotingErrorView JSON");
        assert_eq!(view["kind"], "invalid_input");
        assert!(
            message.contains("carries none of the 1 predefined vote servers"),
            "{message}"
        );
        assert!(!message.contains("try again"), "{message}");
    }

    #[test]
    fn the_refusal_says_try_again_while_a_refresh_runs() {
        let lists = lists();
        let holder = lists.hosts(NetworkType::Main).expect("configured");
        let handle = holder.begin_refresh().expect("due");
        let mut endpoints = endpoints(&["https://unknown.example.com/"]);
        let error = retain_carried(
            &lists,
            zcash_voting::Network::Mainnet,
            &mut endpoints,
            "vote",
        )
        .expect_err("no server is carried");
        assert!(error.to_string().contains("try again shortly"), "{error}");
        holder.fail_refresh(handle, None);
    }

    #[test]
    fn a_kind_that_listed_nothing_is_left_alone() {
        let mut endpoints = Vec::new();
        retain_carried(
            &lists(),
            zcash_voting::Network::Mainnet,
            &mut endpoints,
            "PIR",
        )
        .expect("nothing to refuse");
        assert!(endpoints.is_empty());
    }

    #[test]
    fn a_server_on_another_port_is_dropped() {
        let lists = lists();
        install_list(
            &lists,
            NetworkType::Main,
            &["vote.example.org:8443", "vote.example.org"],
        );
        let mut endpoints = endpoints(&[
            "https://vote.example.org:8443/",
            "https://vote.example.org/",
        ]);
        retain_carried(
            &lists,
            zcash_voting::Network::Mainnet,
            &mut endpoints,
            "vote",
        )
        .expect("one server is carried");
        assert_eq!(endpoints, ["https://vote.example.org/"]);
    }

    /// The OHTTP route of a mainnet session at a predefined server, over `lists`.
    fn admitting_route(lists: &Arc<ThirdPartyHostLists>) -> OhttpRoute {
        OhttpRoute::new(
            lists,
            "https://vote.zodl.com",
            zcash_voting::Network::Mainnet,
        )
        .expect("a carried server")
    }

    /// A refresh that only counts that it ran.
    fn counting(refreshes: &AtomicUsize) -> impl FnOnce() -> std::future::Ready<()> + '_ {
        move || {
            refreshes.fetch_add(1, Ordering::SeqCst);
            std::future::ready(())
        }
    }

    #[tokio::test]
    async fn a_carried_host_is_admitted_without_a_refresh() {
        let lists = lists();
        let route = admitting_route(&lists);
        let refreshes = AtomicUsize::new(0);
        let authority = route
            .admit("https://vote.zodl.com/x", counting(&refreshes))
            .await
            .expect("carried");
        assert_eq!(authority, "vote.zodl.com");
        assert_eq!(refreshes.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn a_host_on_no_list_gets_one_refresh_then_is_refused() {
        let lists = lists();
        let route = admitting_route(&lists);
        let refreshes = AtomicUsize::new(0);
        let error = route
            .admit("https://helper.example.com/status", counting(&refreshes))
            .await
            .expect_err("not carried");
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);
        assert_eq!(refreshes.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn a_refresh_that_brings_the_host_admits_it() {
        let lists = lists();
        let route = admitting_route(&lists);
        let authority = route
            .admit("https://helper.example.com/status", || {
                install_list(&lists, NetworkType::Main, &["helper.example.com"]);
                std::future::ready(())
            })
            .await
            .expect("carried after the refresh");
        assert_eq!(authority, "helper.example.com");
    }

    #[tokio::test]
    async fn a_fresh_list_is_not_refreshed_again() {
        let lists = lists();
        install_list(&lists, NetworkType::Main, &["vote.zodl.com"]);
        let route = admitting_route(&lists);
        let refreshes = AtomicUsize::new(0);
        let error = route
            .admit("https://helper.example.com/", counting(&refreshes))
            .await
            .expect_err("not carried");
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);
        assert_eq!(refreshes.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn an_http_or_ported_url_is_refused_before_dispatch() {
        let lists = lists();
        install_list(
            &lists,
            NetworkType::Main,
            &["vote.zodl.com", "vote.zodl.com:8443"],
        );
        let route = admitting_route(&lists);
        let refreshes = AtomicUsize::new(0);
        for url in ["http://vote.zodl.com/x", "https://vote.zodl.com:8443/x"] {
            let error = route.admit(url, counting(&refreshes)).await.expect_err(url);
            assert_eq!(error.phase, RoutePhase::BeforeDispatch, "{url}");
        }
        assert_eq!(refreshes.load(Ordering::SeqCst), 0);
    }
}
