//! The `tracing` filter the FFI installs at load time.
//!
//! The host picks one level for the whole Rust backend. Only the SDK's own code and the Zcash
//! crates it drives honour it in full; every other dependency is capped at INFO. The HTTP/2 stack
//! alone (h2 under hyper and tonic) logs one DEBUG line per received frame — lightwalletd sends
//! one frame per compact block — and under a debugger that mirrors every log line synchronously
//! into its console, that slowed block download to the console's drain rate.

use tracing_subscriber::filter::{LevelFilter, Targets};

/// Target prefixes that log at the host's level. `tracing` targets are module paths and a
/// directive matches by prefix, so `zcash_` covers every `zcash_*` crate.
const HOST_LEVEL_TARGETS: [&str; 7] = [
    "zcashlc",
    "zodl_slipstream",
    "zcash_",
    "orchard",
    "sapling_crypto",
    "pczt",
    "shardtree",
];

/// Ceiling for every crate not in [`HOST_LEVEL_TARGETS`].
const THIRD_PARTY_CEILING: LevelFilter = LevelFilter::INFO;

/// Builds the filter for the level the host asked for.
pub(crate) fn rust_log_filter(host_level: LevelFilter) -> Targets {
    HOST_LEVEL_TARGETS
        .iter()
        .fold(
            Targets::new().with_default(host_level.min(THIRD_PARTY_CEILING)),
            |targets, target| targets.with_target(*target, host_level),
        )
        // Upstream `zcash_client_backend` #[instrument]s every block and batch (~600k spans per
        // fresh restore) at INFO, and through the os_log + signpost layers each span costs
        // syscalls on the scan producer thread. It stays at WARN whatever the host asks for.
        .with_target("zcash_client_backend", LevelFilter::WARN)
}

#[cfg(test)]
mod tests {
    use super::rust_log_filter;
    use tracing::Level;
    use tracing_subscriber::filter::LevelFilter;

    /// Third-party crates the Debug flood came from (h2 logged one line per
    /// received HTTP/2 frame) plus other infrastructure.
    const CAPPED: [&str; 9] = [
        "h2::codec::framed_read",
        "hyper::proto::h2::client",
        "hyper_util::client::legacy::connect::http",
        "tonic::transport::channel",
        "tower::buffer::worker",
        "rustls::client::hs",
        "tor_proto::channel",
        "arti_client::client",
        "schemerz",
    ];

    /// The SDK's own code and the Zcash crates it drives.
    const HOST_LEVEL: [&str; 10] = [
        "zcashlc",
        "zcashlc::voting",
        "zodl_slipstream::fetch",
        "zcash_client_sqlite::wallet::scanning",
        "zcash_voting",
        "zcash_pool_migration",
        "orchard::builder",
        "sapling_crypto::builder",
        "pczt::roles::signer",
        "shardtree",
    ];

    #[test]
    fn debug_host_caps_third_party_crates_at_info() {
        let filter = rust_log_filter(LevelFilter::DEBUG);
        for target in CAPPED {
            assert!(!filter.would_enable(target, &Level::DEBUG), "{target} must not log DEBUG");
            assert!(filter.would_enable(target, &Level::INFO), "{target} must still log INFO");
        }
    }

    #[test]
    fn debug_host_keeps_sdk_and_zcash_crates_at_debug() {
        let filter = rust_log_filter(LevelFilter::DEBUG);
        for target in HOST_LEVEL {
            assert!(filter.would_enable(target, &Level::DEBUG), "{target} must log DEBUG");
        }
    }

    #[test]
    fn zcash_client_backend_stays_capped_at_warn() {
        let filter = rust_log_filter(LevelFilter::DEBUG);
        assert!(!filter.would_enable("zcash_client_backend::scanning", &Level::INFO));
        assert!(filter.would_enable("zcash_client_backend::scanning", &Level::WARN));
    }

    #[test]
    fn info_host_is_a_ceiling_for_everyone() {
        let filter = rust_log_filter(LevelFilter::INFO);
        assert!(!filter.would_enable("zodl_slipstream::fetch", &Level::DEBUG));
        assert!(filter.would_enable("zodl_slipstream::fetch", &Level::INFO));
        assert!(filter.would_enable("h2::codec::framed_read", &Level::INFO));
        assert!(!filter.would_enable("h2::codec::framed_read", &Level::DEBUG));
    }

    #[test]
    fn trace_host_reaches_first_party_only() {
        let filter = rust_log_filter(LevelFilter::TRACE);
        assert!(filter.would_enable("zodl_slipstream::fetch", &Level::TRACE));
        assert!(!filter.would_enable("h2::codec::framed_read", &Level::TRACE));
    }

    #[test]
    fn off_host_silences_first_and_third_party_crates() {
        let filter = rust_log_filter(LevelFilter::OFF);
        for target in ["zcashlc", "zodl_slipstream::fetch", "h2::codec::framed_read", "tonic::transport"] {
            assert!(!filter.would_enable(target, &Level::ERROR), "{target} must be silent");
        }
    }
}
