//! Tor support
//!
//! Lightwalletd endpoints whose host is an OHTTP gateway (`slipstream_core::ohttp::relay_for`)
//! are NOT dialled directly over Tor (the gateway refuses plain gRPC): this module routes them
//! through the engine's OHTTP-over-Tor connector, so every RPC is HPKE-encapsulated to the
//! gateway and the relay leg is an arti stream (the relay sees a Tor exit, the gateway sees the
//! relay).

pub(crate) mod http;

use std::convert::TryInto;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::anyhow;
use tonic::transport::{Channel, Uri};
use tor_rtcompat::{PreferredRuntime, ToplevelBlockOn};

use slipstream_core::{Endpoint as EngineEndpoint, connector::TorConn};

use transparent::{
    address::{Script, TransparentAddress},
    bundle::{OutPoint, TxOut},
};
use zcash_client_backend::{
    encoding::AddressCodec as _,
    proto::service::{self, compact_tx_streamer_client::CompactTxStreamerClient},
    tor::{Client, DormantMode},
    wallet::WalletTransparentOutput,
};
use zcash_primitives::block::BlockHash;
use zcash_protocol::{
    TxId,
    consensus::{self, BlockHeight},
    value::Zatoshis,
};
use zcash_script::script;

use crate::ffi;

/// Second arti client used ONLY for OHTTP-gateway endpoints, bootstrapped lazily on first use
/// from the same `tor_dir` (it runs read-only on arti's state lock, which the primary
/// `zcash_client_backend` client holds — acceptable: it still caches its own directory).
/// Shared (Arc) across `isolated_client()` handles so it is bootstrapped at most once.
type SharedOhttpTor = Arc<Mutex<Option<TorConn>>>;

pub struct TorRuntime {
    runtime: PreferredRuntime,
    client: Client,
    tor_dir: PathBuf,
    ohttp_tor: SharedOhttpTor,
}

impl TorRuntime {
    #[tracing::instrument]
    pub(crate) fn create(tor_dir: &Path, dangerously_trust_everyone: bool) -> anyhow::Result<Self> {
        let runtime = PreferredRuntime::create()?;
        let client = runtime.block_on(async {
            Client::create(tor_dir, |permissions: &mut fs_mistrust::MistrustBuilder| {
                if dangerously_trust_everyone {
                    permissions.dangerously_trust_everyone();
                }
            })
            .await
        })?;
        Ok(Self {
            runtime,
            client,
            tor_dir: tor_dir.to_path_buf(),
            ohttp_tor: Arc::new(Mutex::new(None)),
        })
    }

    /// True when `endpoint` is an OHTTP gateway that must never be dialled directly.
    fn is_ohttp_gateway(endpoint: &Uri) -> bool {
        endpoint
            .host()
            .is_some_and(|h| slipstream_core::ohttp::relay_for(h).is_some())
    }

    /// The engine `TorConn` for OHTTP-over-Tor, bootstrapping it on this runtime on first use.
    fn ohttp_tor_conn(&self) -> anyhow::Result<TorConn> {
        let mut slot = self
            .ohttp_tor
            .lock()
            .map_err(|_| anyhow!("OHTTP Tor client lock poisoned"))?;
        if let Some(t) = slot.as_ref() {
            return Ok(t.clone());
        }
        tracing::info!("bootstrapping arti client for OHTTP-over-Tor (FFI Tor runtime)");
        let tor_dir = self.tor_dir.clone();
        let conn = self
            .runtime
            .block_on(async { TorConn::bootstrap(&tor_dir, true).await })
            .map_err(|e| anyhow!("OHTTP-over-Tor bootstrap: {e}"))?;
        *slot = Some(conn.clone());
        Ok(conn)
    }

    /// OHTTP gateway endpoint: HPKE-encapsulated RPCs whose relay leg is an isolated Tor stream.
    fn connect_ohttp_over_tor(&self, endpoint: &Uri) -> anyhow::Result<LwdConn> {
        let host = endpoint
            .host()
            .ok_or_else(|| anyhow!("lightwalletd endpoint without host"))?
            .to_string();
        let tls = endpoint.scheme_str() != Some("http");
        let ep = EngineEndpoint {
            host,
            port: endpoint.port_u16().unwrap_or(if tls { 443 } else { 80 }),
            tls,
        };
        let tor = self.ohttp_tor_conn()?;
        tracing::info!(gateway = %ep.host, "FFI Tor client: connecting via OHTTP over Tor");
        let conn = self
            .runtime
            .block_on(async { tor.connect_isolated(&ep).await })
            .map_err(|e| anyhow!("OHTTP-over-Tor connect: {e}"))?;
        Ok(LwdConn {
            runtime: self.runtime.clone(),
            _client: TorHandle::Engine(tor),
            conn,
        })
    }

    pub(crate) fn runtime(&self) -> &PreferredRuntime {
        &self.runtime
    }

    pub(crate) fn client(&self) -> &Client {
        &self.client
    }

    /// Returns a new isolated `TorRuntime ` handle.
    ///
    /// The two `TorRuntime `s will share internal state and configuration, but their
    /// streams will never share circuits with one another.
    ///
    /// Use this method when you want separate parts of your program to each have a
    /// `TorRuntime ` handle, but where you don't want their activities to be linkable to
    /// one another over the Tor network.
    ///
    /// Calling this method is usually preferable to creating a completely separate
    /// `TorRuntime ` instance, since it can share its internals with the existing
    /// `TorRuntime `.
    pub(crate) fn isolated_client(&self) -> Self {
        Self {
            runtime: self.runtime.clone(),
            client: self.client.isolated_client(),
            tor_dir: self.tor_dir.clone(),
            ohttp_tor: Arc::clone(&self.ohttp_tor),
        }
    }

    /// Changes the client's current dormant mode, putting background tasks to sleep or
    /// waking them up as appropriate.
    ///
    /// This can be used to conserve CPU usage if you aren’t planning on using the client
    /// for a while, especially on mobile platforms.
    ///
    /// See the [`ffi::TorDormantMode`] documentation for more details.
    pub(crate) fn set_dormant(&self, mode: ffi::TorDormantMode) {
        self.client.set_dormant(match mode {
            ffi::TorDormantMode::Normal => DormantMode::Normal,
            ffi::TorDormantMode::Soft => DormantMode::Soft,
        });
    }

    /// Connects to the lightwalletd server at the given endpoint.
    ///
    /// Each connection returned by this method is isolated from any other Tor usage.
    pub(crate) fn connect_to_lightwalletd(&self, endpoint: Uri) -> anyhow::Result<LwdConn> {
        // OHTTP gateways refuse plain gRPC (426) and must not learn the client IP anyway: route
        // them through the engine's OHTTP-over-Tor connector instead of a direct Tor stream.
        if Self::is_ohttp_gateway(&endpoint) {
            return self.connect_ohttp_over_tor(&endpoint);
        }

        let Self {
            runtime, client, ..
        } = self.isolated_client();

        let allow_onion_services = false;
        let conn = runtime.block_on(async {
            client
                .connect_to_lightwalletd(endpoint, allow_onion_services)
                .await
        })?;

        Ok(LwdConn {
            runtime,
            _client: TorHandle::Zcash(client),
            conn,
        })
    }
}

/// Keeps the Tor client behind a connection alive for as long as the connection is.
#[allow(dead_code)]
enum TorHandle {
    Zcash(Client),
    Engine(TorConn),
}

pub struct LwdConn {
    conn: CompactTxStreamerClient<Channel>,
    _client: TorHandle,
    runtime: PreferredRuntime,
}

impl LwdConn {
    /// Returns information about this lightwalletd instance and the blockchain.
    pub(crate) fn get_lightd_info(&mut self) -> anyhow::Result<service::LightdInfo> {
        Ok(self
            .runtime
            .clone()
            .block_on(self.conn.get_lightd_info(service::Empty {}))?
            .into_inner())
    }

    /// Fetches the height and hash of the block at the tip of the best chain.
    pub(crate) fn get_latest_block(&mut self) -> anyhow::Result<(BlockHeight, BlockHash)> {
        let response = self
            .runtime
            .clone()
            .block_on(self.conn.get_latest_block(service::ChainSpec {}))?
            .into_inner();

        Ok((
            BlockHeight::from_u32(response.height.try_into()?),
            BlockHash::try_from_slice(&response.hash).ok_or_else(|| {
                anyhow!(
                    "Returned block hash has invalid length {}",
                    response.hash.len()
                )
            })?,
        ))
    }

    /// Fetches the transaction with the given ID.
    pub(crate) fn get_transaction(&mut self, txid: TxId) -> anyhow::Result<(Vec<u8>, u64)> {
        let request = service::TxFilter {
            hash: txid.as_ref().to_vec(),
            ..Default::default()
        };

        let response = self
            .runtime
            .clone()
            .block_on(self.conn.get_transaction(request))?
            .into_inner();

        Ok((response.data, response.height))
    }

    /// Submits a transaction to the Zcash network.
    pub(crate) fn send_transaction(&mut self, tx_bytes: Vec<u8>) -> anyhow::Result<()> {
        let request = service::RawTransaction {
            data: tx_bytes,
            ..Default::default()
        };

        let response = self
            .runtime
            .clone()
            .block_on(self.conn.send_transaction(request))?
            .into_inner();

        if response.error_code == 0 {
            Ok(())
        } else {
            Err(anyhow!(
                "Failed to submit transaction ({}): {}",
                response.error_code,
                response.error_message
            ))
        }
    }

    /// Fetches the note commitment tree state corresponding to the given block.
    pub(crate) fn get_tree_state(
        &mut self,
        height: BlockHeight,
    ) -> anyhow::Result<service::TreeState> {
        let request = service::BlockId {
            height: u32::from(height).into(),
            ..Default::default()
        };

        Ok(self
            .runtime
            .clone()
            .block_on(self.conn.get_tree_state(request))?
            .into_inner())
    }

    /// Discovers UTXOs received by the given transparent address in the provided block range, and
    /// invokes the provided callback with the [`WalletTransparentOutput`] corresponding to that
    /// UTXO.
    pub(crate) fn with_taddress_utxos<A>(
        &mut self,
        params: &impl consensus::Parameters,
        address: TransparentAddress,
        start: Option<BlockHeight>,
        limit: Option<u32>,
        mut f: impl FnMut(WalletTransparentOutput<A>) -> anyhow::Result<()>,
    ) -> anyhow::Result<()> {
        let request = service::GetAddressUtxosArg {
            addresses: vec![address.encode(params)],
            start_height: start.map_or(0, u64::from),
            max_entries: match limit {
                None => 0,
                Some(0) => return Err(anyhow!("Invalid limit")),
                Some(n) => n,
            },
        };

        self.runtime.clone().block_on(async {
            let mut utxos = self
                .conn
                .get_address_utxos_stream(request)
                .await?
                .into_inner();

            while let Some(result) = utxos.message().await? {
                let recipient_account = None;
                let key_scope = None;
                let funding_account = None;

                f(WalletTransparentOutput::from_parts(
                    OutPoint::new(result.txid[..].try_into()?, result.index.try_into()?),
                    TxOut::new(
                        Zatoshis::from_nonnegative_i64(result.value_zat)?,
                        Script(script::Code(result.script)),
                    ),
                    Some(BlockHeight::from(u32::try_from(result.height)?)),
                    recipient_account,
                    key_scope,
                    funding_account,
                )
                .ok_or(anyhow!(
                    "Received UTXO that doesn't correspond to a valid P2PKH or P2SH address"
                ))?)?;
            }

            Ok(())
        })
    }

    /// Calls the given closure with the transactions corresponding to the given t-address
    /// within the given block range, and the height of the main-chain block they are
    /// mined in (if any).
    pub(crate) fn with_taddress_transactions(
        &mut self,
        params: &impl consensus::Parameters,
        address: TransparentAddress,
        start: BlockHeight,
        end: Option<BlockHeight>,
        mut f: impl FnMut(Vec<u8>, Option<BlockHeight>) -> anyhow::Result<()>,
    ) -> anyhow::Result<()> {
        let request = service::TransparentAddressBlockFilter {
            address: address.encode(params),
            range: Some(service::BlockRange {
                start: Some(service::BlockId {
                    height: u32::from(start).into(),
                    ..Default::default()
                }),
                end: end.map(|height| service::BlockId {
                    height: u32::from(height).into(),
                    ..Default::default()
                }),
                pool_types: vec![],
            }),
        };

        self.runtime.clone().block_on(async {
            let mut txs = self.conn.get_taddress_txids(request).await?.into_inner();

            while let Some(tx) = txs.message().await? {
                let mined_height = match tx.height {
                    0 => None,
                    // TODO: Represent "not in main chain".
                    0xffff_ffff_ffff_ffff => None,
                    h => Some(BlockHeight::from_u32(h.try_into()?)),
                };

                f(tx.data, mined_height)?;
            }

            Ok(())
        })
    }
}
