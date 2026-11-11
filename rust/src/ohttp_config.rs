//! The OHTTP configuration the app installs at launch.
//!
//! The library carries no OHTTP endpoint or key. [`zcashlc_ohttp_configure`] installs the
//! configuration of mainnet and testnet, one value for the whole process, and every OHTTP path of
//! the FFI reads it through [`installed_networks`]: the key-configuration check and the relay,
//! gateway and DNS lookups of the Swift transport (`ohttp.rs`), the refusal to dial a gateway over
//! Tor (`tor.rs`), each start of the Slipstream engine and the provisioning anchor (`lib.rs`), and
//! each voting session as it opens (`voting/route.rs`).
//!
//! Until a configuration is installed, and for a network passed as null, OHTTP is off: no host is
//! that network's gateway, so its servers are plain servers.

use std::slice;
use std::sync::{Arc, LazyLock, PoisonError, RwLock};

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zodl_ohttp_client::{ConfigField, Network, OhttpConfig, OhttpConfigParams, OhttpNetworks};

use crate::unwrap_exc_or;

/// The installed configuration. A new one replaces it whole and none is edited in place, so a
/// reader that keeps the `Arc` keeps one complete configuration.
static INSTALLED: LazyLock<RwLock<Arc<OhttpNetworks>>> =
    LazyLock::new(|| RwLock::new(Arc::new(OhttpNetworks::default())));

/// The configuration installed now; both networks are off until [`zcashlc_ohttp_configure`]
/// succeeds. A caller that looks up more than one thing reads it once and keeps the `Arc`, so
/// that its lookups agree with each other even if the app installs another configuration
/// meanwhile.
pub(crate) fn installed_networks() -> Arc<OhttpNetworks> {
    Arc::clone(&INSTALLED.read().unwrap_or_else(PoisonError::into_inner))
}

/// Replaces the installed configuration with `networks`.
fn install(networks: OhttpNetworks) {
    *INSTALLED.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(networks);
}

/// The OHTTP configuration of one network, as [`zcashlc_ohttp_configure`] takes it: four UTF-8
/// strings, each a pointer and a length in bytes, without a terminating NUL.
///
/// Version 1 of the layout: a later layout gets a new name, so a caller built against this one
/// keeps working.
#[repr(C)]
pub struct FfiOhttpNetworkConfigV1 {
    /// The gateway's host name, which is also the inner `:authority` of light client server
    /// requests: a lower-case bare DNS host name (no scheme, port, path or trailing dot).
    pub(crate) gateway_host: *const u8,
    pub(crate) gateway_host_len: usize,
    /// The URL sealed requests are posted to: `https://`, a host, an optional port and an
    /// optional path, without userinfo, query or fragment.
    pub(crate) relay_url: *const u8,
    pub(crate) relay_url_len: usize,
    /// The DNS TXT name of the gateway's signed key configuration: a lower-case bare DNS host
    /// name.
    pub(crate) keys_dns_name: *const u8,
    pub(crate) keys_dns_name_len: usize,
    /// The key-configuration signing key: a raw Ed25519 public key as 64 hex digits.
    pub(crate) signing_pubkey: *const u8,
    pub(crate) signing_pubkey_len: usize,
}

/// Installs the OHTTP configuration of mainnet and testnet, replacing the one installed before.
///
/// A null `mainnet` or `testnet` turns OHTTP off for that network: its gateway host is then a
/// plain server. A non-null one must carry all four values, each checked by its rule (see
/// [`FfiOhttpNetworkConfigV1`]), and the two networks must not share a value (ignoring ASCII
/// case).
///
/// Returns `true` once the configuration is installed. On `false` the configuration installed
/// before is kept, and the thread's last error names the network, the field and the rule it
/// breaks, never the value.
///
/// Call it at launch, before anything uses OHTTP. A Slipstream sync pass and a voting session
/// keep the configuration they started with; the next start or session reads the new one. The
/// values are copied: the caller's buffers are not kept after the call.
///
/// # Safety
///
/// - `mainnet` and `testnet` must each be null or point to an [`FfiOhttpNetworkConfigV1`] that
///   is valid for reads for the duration of the call.
/// - In each of them, every `(pointer, length)` pair must be valid for reads for `length` bytes,
///   with an alignment of `1`, or have a length of zero, and the memory must not be mutated for
///   the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_configure(
    mainnet: *const FfiOhttpNetworkConfigV1,
    testnet: *const FfiOhttpNetworkConfigV1,
) -> bool {
    let res = catch_panic(|| {
        let mainnet = unsafe { network_config(Network::Mainnet, mainnet) }?;
        let testnet = unsafe { network_config(Network::Testnet, testnet) }?;
        install(OhttpNetworks::new(mainnet, testnet)?);
        Ok(true)
    });
    unwrap_exc_or(res, false)
}

/// The configuration of `network` that `config` points to, or `None` (OHTTP off) for null.
///
/// # Safety
///
/// As for [`zcashlc_ohttp_configure`].
unsafe fn network_config(
    network: Network,
    config: *const FfiOhttpNetworkConfigV1,
) -> anyhow::Result<Option<OhttpConfig>> {
    let Some(config) = (unsafe { config.as_ref() }) else {
        return Ok(None);
    };
    let params = unsafe {
        OhttpConfigParams {
            gateway_host: value(
                network,
                ConfigField::GatewayHost,
                config.gateway_host,
                config.gateway_host_len,
            )?,
            relay_url: value(
                network,
                ConfigField::RelayUrl,
                config.relay_url,
                config.relay_url_len,
            )?,
            keys_dns_name: value(
                network,
                ConfigField::KeysDnsName,
                config.keys_dns_name,
                config.keys_dns_name_len,
            )?,
            signing_pubkey: value(
                network,
                ConfigField::SigningPubkey,
                config.signing_pubkey,
                config.signing_pubkey_len,
            )?,
        }
    };
    OhttpConfig::new(params)
        .map(Some)
        .map_err(|error| anyhow!("{}: {error}", network.as_str()))
}

/// The value of `field` in `network`'s configuration: `len` bytes at `ptr`, which must be UTF-8.
/// An error names the network and the field, never the bytes.
///
/// # Safety
///
/// When `len` is non-zero, `ptr` must be null or valid for reads for `len` bytes, with an
/// alignment of `1`, and the memory must not be mutated while the value is in use.
unsafe fn value<'a>(
    network: Network,
    field: ConfigField,
    ptr: *const u8,
    len: usize,
) -> anyhow::Result<&'a str> {
    let bytes = if len == 0 {
        &[][..]
    } else if ptr.is_null() {
        return Err(anyhow!(
            "{}: OHTTP configuration: {field} is a null pointer with a non-zero length",
            network.as_str()
        ));
    } else {
        unsafe { slice::from_raw_parts(ptr, len) }
    };
    std::str::from_utf8(bytes).map_err(|_| {
        anyhow!(
            "{}: OHTTP configuration: {field} is not UTF-8",
            network.as_str()
        )
    })
}

/// Serializes the tests that install a configuration or read the installed one: it is
/// process-wide, and the test harness runs tests on parallel threads of one process. Every test
/// that touches it holds [`InstalledNetworksGuard`] for its whole body and installs what it needs
/// first.
#[cfg(test)]
static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Exclusive use of the installed configuration for one test, with the configuration installed
/// before put back when the test ends.
#[cfg(test)]
pub(crate) struct InstalledNetworksGuard {
    /// Held for the guard's lifetime; dropped after [`Drop::drop`] restores.
    _lock: std::sync::MutexGuard<'static, ()>,
    previous: Arc<OhttpNetworks>,
}

#[cfg(test)]
impl Drop for InstalledNetworksGuard {
    fn drop(&mut self) {
        // Restored after a failed test too, so that the tests that run afterwards do not inherit
        // its configuration.
        *INSTALLED.write().unwrap_or_else(PoisonError::into_inner) = Arc::clone(&self.previous);
    }
}

/// Takes the installed configuration for the duration of the calling test.
#[cfg(test)]
pub(crate) fn lock_installed_networks() -> InstalledNetworksGuard {
    // A test that failed while holding the lock does not fail the others.
    let lock = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    InstalledNetworksGuard {
        _lock: lock,
        previous: installed_networks(),
    }
}

/// Installs `networks` as [`zcashlc_ohttp_configure`] does, for a test that holds
/// [`lock_installed_networks`].
#[cfg(test)]
pub(crate) fn install_for_test(networks: OhttpNetworks) {
    install(networks);
}

/// The example configuration of the tests: RFC 2606 names, and the public keys of RFC 8032 §7.1
/// TEST 1 (mainnet) and TEST 2 (testnet) as signing keys.
#[cfg(test)]
pub(crate) mod example {
    use zodl_ohttp_client::{OhttpConfig, OhttpConfigParams, OhttpNetworks};

    /// Mainnet's example values.
    pub(crate) const MAINNET: OhttpConfigParams<'static> = OhttpConfigParams {
        gateway_host: "ohttp-gateway.example",
        relay_url: "https://relay-mainnet.example/relay",
        keys_dns_name: "mainnet.ohttp-keys.example",
        signing_pubkey: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    };

    /// Testnet's example values.
    pub(crate) const TESTNET: OhttpConfigParams<'static> = OhttpConfigParams {
        gateway_host: "ohttp-gateway-testnet.example",
        relay_url: "https://relay-testnet.example/relay",
        keys_dns_name: "testnet.ohttp-keys.example",
        signing_pubkey: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
    };

    /// The configuration of `params`, which must be valid.
    pub(crate) fn config(params: OhttpConfigParams<'_>) -> OhttpConfig {
        OhttpConfig::new(params).expect("valid example values")
    }

    /// Both networks on, with the example values.
    pub(crate) fn networks() -> OhttpNetworks {
        OhttpNetworks::new(Some(config(MAINNET)), Some(config(TESTNET))).expect("example networks")
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::CStr;
    use std::os::raw::c_char;
    use std::ptr;

    use super::*;
    use crate::{zcashlc_clear_last_error, zcashlc_error_message_utf8, zcashlc_last_error_length};

    /// `params` as the C caller passes them: each value a pointer to its bytes and their length.
    fn ffi(params: &OhttpConfigParams<'_>) -> FfiOhttpNetworkConfigV1 {
        FfiOhttpNetworkConfigV1 {
            gateway_host: params.gateway_host.as_ptr(),
            gateway_host_len: params.gateway_host.len(),
            relay_url: params.relay_url.as_ptr(),
            relay_url_len: params.relay_url.len(),
            keys_dns_name: params.keys_dns_name.as_ptr(),
            keys_dns_name_len: params.keys_dns_name.len(),
            signing_pubkey: params.signing_pubkey.as_ptr(),
            signing_pubkey_len: params.signing_pubkey.len(),
        }
    }

    /// [`zcashlc_ohttp_configure`] on the C structures of `mainnet` and `testnet`, `None` passed
    /// as null.
    fn configure(
        mainnet: Option<&FfiOhttpNetworkConfigV1>,
        testnet: Option<&FfiOhttpNetworkConfigV1>,
    ) -> bool {
        unsafe {
            zcashlc_ohttp_configure(
                mainnet.map_or(ptr::null(), ptr::from_ref),
                testnet.map_or(ptr::null(), ptr::from_ref),
            )
        }
    }

    /// [`configure`] with the values of `mainnet` and `testnet`.
    fn configure_values(
        mainnet: Option<OhttpConfigParams<'_>>,
        testnet: Option<OhttpConfigParams<'_>>,
    ) -> bool {
        configure(
            mainnet.as_ref().map(ffi).as_ref(),
            testnet.as_ref().map(ffi).as_ref(),
        )
    }

    /// The thread's last error.
    fn last_error_message() -> String {
        let len = zcashlc_last_error_length();
        assert!(len > 0, "no last error");
        let mut error = vec![0u8; len as usize];
        let copied =
            unsafe { zcashlc_error_message_utf8(error.as_mut_ptr().cast::<c_char>(), len) };
        assert_eq!(copied, len);
        unsafe { CStr::from_ptr(error.as_ptr().cast::<c_char>()) }
            .to_str()
            .unwrap()
            .to_owned()
    }

    /// The configuration of `params` as `network`'s, the other network off.
    fn only(network: Network, params: OhttpConfigParams<'_>) -> OhttpNetworks {
        let config = Some(example::config(params));
        match network {
            Network::Mainnet => OhttpNetworks::new(config, None),
            Network::Testnet => OhttpNetworks::new(None, config),
        }
        .expect("one network")
    }

    #[test]
    fn configure_installs_both_networks() {
        let _guard = lock_installed_networks();
        install_for_test(OhttpNetworks::default());

        assert!(configure_values(
            Some(example::MAINNET),
            Some(example::TESTNET)
        ));
        let installed = installed_networks();
        assert_eq!(*installed, example::networks());
        assert_eq!(
            installed.relay_for(example::MAINNET.gateway_host),
            Some(example::MAINNET.relay_url)
        );
        assert_eq!(
            installed.relay_for(example::TESTNET.gateway_host),
            Some(example::TESTNET.relay_url)
        );
    }

    #[test]
    fn configure_with_null_turns_network_off() {
        let _guard = lock_installed_networks();
        install_for_test(example::networks());

        assert!(configure_values(Some(example::MAINNET), None));
        let installed = installed_networks();
        assert_eq!(*installed, only(Network::Mainnet, example::MAINNET));
        assert!(installed.get(Network::Testnet).is_none());
        assert_eq!(installed.relay_for(example::TESTNET.gateway_host), None);

        assert!(configure_values(None, Some(example::TESTNET)));
        assert_eq!(
            *installed_networks(),
            only(Network::Testnet, example::TESTNET)
        );

        assert!(configure_values(None, None));
        assert_eq!(*installed_networks(), OhttpNetworks::default());
    }

    #[test]
    fn configure_rejects_invalid_value_naming_field() {
        let _guard = lock_installed_networks();
        install_for_test(OhttpNetworks::default());

        // One broken value at a time, in either network: the error names the network and the
        // field, and quotes no value, neither the refused one nor any other.
        let cases: [(Network, &str, OhttpConfigParams<'_>); 6] = [
            (
                Network::Mainnet,
                "gateway_host",
                OhttpConfigParams {
                    gateway_host: "OHTTP-Gateway.example",
                    ..example::MAINNET
                },
            ),
            (
                Network::Mainnet,
                "relay_url",
                OhttpConfigParams {
                    relay_url: "http://relay-mainnet.example/relay",
                    ..example::MAINNET
                },
            ),
            (
                Network::Mainnet,
                "gateway_host",
                OhttpConfigParams {
                    gateway_host: "",
                    ..example::MAINNET
                },
            ),
            (
                Network::Testnet,
                "keys_dns_name",
                OhttpConfigParams {
                    keys_dns_name: "testnet.ohttp-keys.example.",
                    ..example::TESTNET
                },
            ),
            (
                Network::Testnet,
                "signing_pubkey",
                OhttpConfigParams {
                    signing_pubkey: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af466",
                    ..example::TESTNET
                },
            ),
            (
                Network::Testnet,
                "relay_url",
                OhttpConfigParams {
                    relay_url: "https://relay-testnet.example/relay?network=testnet",
                    ..example::TESTNET
                },
            ),
        ];
        for (network, field, params) in cases {
            let (mainnet, testnet) = match network {
                Network::Mainnet => (params, example::TESTNET),
                Network::Testnet => (example::MAINNET, params),
            };
            zcashlc_clear_last_error();
            assert!(!configure_values(Some(mainnet), Some(testnet)), "{field}");
            let message = last_error_message();
            assert!(message.contains(field), "{message}");
            assert!(message.contains(network.as_str()), "{message}");
            for value in [mainnet, testnet].iter().flat_map(|params| {
                [
                    params.gateway_host,
                    params.relay_url,
                    params.keys_dns_name,
                    params.signing_pubkey,
                ]
            }) {
                assert!(
                    value.is_empty() || !message.contains(value),
                    "the error quotes a value: {message}"
                );
            }
        }

        // Bytes that are not UTF-8, and a length without its bytes, are refused naming the
        // field too.
        let not_utf8 = [0xff, 0xfe];
        let mut config = ffi(&example::TESTNET);
        config.keys_dns_name = not_utf8.as_ptr();
        config.keys_dns_name_len = not_utf8.len();
        zcashlc_clear_last_error();
        assert!(!configure(Some(&ffi(&example::MAINNET)), Some(&config)));
        let message = last_error_message();
        assert!(message.contains("testnet"), "{message}");
        assert!(message.contains("keys_dns_name"), "{message}");

        let mut config = ffi(&example::MAINNET);
        config.signing_pubkey = ptr::null();
        zcashlc_clear_last_error();
        assert!(!configure(Some(&config), None));
        let message = last_error_message();
        assert!(message.contains("mainnet"), "{message}");
        assert!(message.contains("signing_pubkey"), "{message}");

        zcashlc_clear_last_error();
    }

    #[test]
    fn configure_replaces_previous_configuration() {
        let _guard = lock_installed_networks();
        install_for_test(OhttpNetworks::default());
        assert!(configure_values(
            Some(example::MAINNET),
            Some(example::TESTNET)
        ));
        let before = installed_networks();

        // The mainnet values, now as testnet's configuration, and mainnet off: nothing of the
        // first configuration survives, neither a network nor a host's network.
        assert!(configure_values(None, Some(example::MAINNET)));
        let installed = installed_networks();
        assert_eq!(*installed, only(Network::Testnet, example::MAINNET));
        assert!(installed.get(Network::Mainnet).is_none());
        assert_eq!(
            installed.network_of_host(example::MAINNET.gateway_host),
            Some(Network::Testnet)
        );
        assert_eq!(installed.relay_for(example::TESTNET.gateway_host), None);

        // A reader that took the configuration before keeps that one, whole.
        assert_eq!(*before, example::networks());
    }

    #[test]
    fn failed_configure_keeps_previous_configuration() {
        let _guard = lock_installed_networks();
        install_for_test(example::networks());

        // An invalid value in one network installs neither network.
        let broken_testnet = OhttpConfigParams {
            relay_url: "https://relay-testnet.example/relay#keys",
            ..example::TESTNET
        };
        zcashlc_clear_last_error();
        assert!(!configure_values(
            Some(example::MAINNET),
            Some(broken_testnet)
        ));
        assert_eq!(*installed_networks(), example::networks());

        // Networks that share a value are refused as a pair.
        let shared = OhttpConfigParams {
            relay_url: example::MAINNET.relay_url,
            ..example::TESTNET
        };
        zcashlc_clear_last_error();
        assert!(!configure_values(Some(example::MAINNET), Some(shared)));
        let message = last_error_message();
        assert!(message.contains("relay_url"), "{message}");
        assert!(!message.contains(example::MAINNET.relay_url), "{message}");
        assert_eq!(*installed_networks(), example::networks());

        // With OHTTP off before, a refused configuration leaves it off rather than half on.
        install_for_test(OhttpNetworks::default());
        assert!(!configure_values(
            Some(example::MAINNET),
            Some(broken_testnet)
        ));
        assert_eq!(*installed_networks(), OhttpNetworks::default());

        zcashlc_clear_last_error();
    }
}
