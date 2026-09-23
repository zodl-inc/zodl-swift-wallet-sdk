//! Per-round voting session: executor, delegation pipeline, clients and
//! cancellation control, opened once per round and held for its lifetime.
//!
//! Everything a round needs that outlives one call lives here, because
//! `zcash_voting` binds it that way: the executor freezes the wallet scope and
//! the proposal roster at construction, the delegation pipeline freezes the
//! account and the lightwalletd anchor, and the chain client freezes the
//! endpoint fleet. Rebuilding them per call would re-validate all of that on
//! every screen tap and could not carry a cancellation signal across calls.
//!
//! [`VotingSession::open`] performs no network I/O. The PIR fleet only records
//! its endpoints, the chain client only validates its configuration, and the
//! helper client only holds a transport; nothing dials until a step runs. That
//! is what lets Swift open a session on the main thread and discover a bad
//! round configuration immediately rather than through a timeout.
//!
//! Every service a session touches rides the route chosen at open — Tor or
//! direct, never falling back: chain and helper traffic, PIR queries and
//! vote-tree sync alike. A PIR query hides which rows are fetched, not who
//! fetches them, so a fleet reached any other way would show the PIR server
//! the device address, the round and one fetch burst per bundle, and the tree
//! node as much again — an address tied to participation and to approximate
//! weight, which is exactly what the route exists to withhold.
//!
//! A run — [`VotingSession::run`] or [`VotingSession::track_shares`] — is
//! driven on the shared runtime instead of on the calling thread, and streams
//! what it observes to the host through an [`EventSink`] as it goes. Neither
//! driver fails: both return a report whose quiescence says why the round
//! stopped, so the errors these methods return are the ones around the run —
//! a signer this host cannot build, a report the wire projection refuses, or a
//! driver task that did not finish.
//!
//! Proving one bundle ahead of a run is the exception to that shape: it runs
//! on a thread this module creates and sizes rather than on the runtime,
//! because Orchard proving needs a stack neither a runtime worker nor the
//! host's calling thread is guaranteed to have.

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use zcash_voting::delegate::KeystoneSigningRequest;
use zcash_voting::storage::KeystoneSignatureInput;
use zeroize::Zeroizing;

use super::errors::{VotingResultExt, envelope_or_invalid_input, internal, invalid_input};
use super::route::SdkRoute;
use super::signer::SeedSpendAuthSigner;
use super::store::{VotingDatabaseHandle, legacy_in_flight};
use super::wallet_access::SdkWalletDbOpener;
use super::wire::{
    BallotIntentDto, BundleLayoutDto, DelegationProgressDto, DrivePolicyDto, EligibilityDto,
    HostOverridesDto, KeystoneSignatureBatchResultDto, KeystoneSignedBundleDto,
    KeystoneSigningRequestDto, PirPrecomputeDto, ProofStatusDto, RoundPlanDto, SessionBindingDto,
    SessionEventDto, SessionInputsDto, ShareTrackingPolicyDto, Signer, plan_view,
};

/// Stack the delegation proving thread is created with.
///
/// Orchard proof generation needs far more stack than a thread is given by
/// default, and the thread a host calls in on is the host's own, whose size
/// this SDK does not set — so the proof runs on a thread this module sizes.
const PROOF_THREAD_STACK_BYTES: usize = 64 << 20;

/// The C function a host installs to receive one run's events, or `None` to
/// run without an event stream.
///
/// Each call carries one `SessionEventDto` as UTF-8 JSON. The bytes are
/// borrowed for the duration of the call only, so a host that keeps them must
/// copy them.
pub(super) type EventCallback =
    Option<unsafe extern "C" fn(context: *mut std::ffi::c_void, json: *const u8, json_len: usize)>;

/// Where a run's events go: the host's callback and the context it named.
///
/// `Copy`, because the drivers want one of these in the spawned task and
/// another inside the reporter they report through, and there is nothing here
/// to share.
#[derive(Clone, Copy)]
pub(super) struct EventSink {
    callback: EventCallback,
    context: *mut std::ffi::c_void,
}

// SAFETY: a sink is a function pointer and an opaque host pointer, and Rust
// cannot know what the latter points at, so both obligations are the host's
// and [`EventSink::new`] states them: the context must stay valid for the
// whole run, and the callback must be safe to call from any thread at any
// time. The round driver reports from several bundle tasks at once, so
// concurrent calls are the normal case rather than an edge; the SDK's Swift
// wrapper serializes them.
unsafe impl Send for EventSink {}
unsafe impl Sync for EventSink {}

impl EventSink {
    /// A sink that discards every event.
    ///
    /// Test-only: the C surface builds every sink from the host's callback,
    /// which is itself optional, so nothing in production asks for an empty
    /// one by name.
    #[cfg(test)]
    pub(super) fn none() -> Self {
        EventSink {
            callback: None,
            context: std::ptr::null_mut(),
        }
    }

    /// A sink over the host's `callback`, called with `context`.
    ///
    /// The callback runs on whichever thread reached the event: one of the
    /// shared runtime's workers, or the proof thread this module creates. It
    /// must not block — the round driver reports from concurrent bundle tasks,
    /// and a callback that waits holds one of them up and can stall the run.
    /// Hand the JSON off and return.
    ///
    /// # Safety
    ///
    /// `callback`, when present, must be safe to call with `context` from any
    /// thread and from several threads at once, and `context` must stay valid
    /// until the run this sink is passed to has returned.
    pub(super) unsafe fn new(callback: EventCallback, context: *mut std::ffi::c_void) -> Self {
        EventSink { callback, context }
    }

    /// Serializes `event` and hands it to the host.
    ///
    /// A sink without a callback drops it, and so does an event that fails to
    /// serialize: the stream is an observation of a run, and the run's report
    /// — which carries the same plan, failures and outcomes — is what the host
    /// acts on.
    ///
    /// Does nothing but serialize and call, because the round driver reports
    /// from concurrent bundle tasks and a reporter that blocked would hold one
    /// of them up.
    pub(super) fn emit(&self, event: &SessionEventDto) {
        let Some(callback) = self.callback else {
            return;
        };
        let Ok(json) = serde_json::to_string(event) else {
            return;
        };
        // SAFETY: the callback and the context are the host's own, given to
        // `new` under its contract; the JSON is borrowed for this call only.
        unsafe { callback(self.context, json.as_ptr(), json.len()) };
    }

    /// A sink that appends every event's JSON to `collected`.
    ///
    /// Test-only. The context is `collected`'s target rather than a clone of
    /// the `Arc`, so a caller must keep its own clone alive for as long as the
    /// sink can be called — which is what lets the test read the events back
    /// after the run.
    #[cfg(test)]
    fn collecting(collected: &Arc<std::sync::Mutex<Vec<String>>>) -> Self {
        unsafe extern "C" fn collect(
            context: *mut std::ffi::c_void,
            json: *const u8,
            json_len: usize,
        ) {
            // SAFETY: `collecting` set the context to a live `Arc`'s target,
            // which its caller holds for the whole run, and `json` is the
            // emitted string's bytes.
            let collected = unsafe { &*context.cast::<std::sync::Mutex<Vec<String>>>() };
            let json = unsafe { std::slice::from_raw_parts(json, json_len) };
            // A panic must not unwind out of an `extern "C"` frame, so a
            // poisoned lock is taken anyway: the assertion belongs to the test
            // that reads the vector back, not to the driver's worker thread.
            collected
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .push(String::from_utf8_lossy(json).into_owned());
        }

        EventSink {
            callback: Some(collect),
            context: Arc::as_ptr(collected).cast::<std::ffi::c_void>().cast_mut(),
        }
    }
}

/// One open voting round: the crate objects that drive it, plus the inputs
/// they were built from.
///
/// Deliberately not `Debug`: the executor's round binding and the delegation
/// pipeline each hold the round's voting hotkey secret, and a derived
/// formatter would reach it through them. `SeedSpendAuthSigner` is not `Debug`
/// for the same reason.
pub struct VotingSession {
    /// A wallet-scoped handle on the sidecar, taken once at open.
    ///
    /// The executor and the pipeline each freeze their own handle over the
    /// same connection, so this one is never the thing they persist through;
    /// it is the session's own read handle, and the one share tracking drives
    /// the round's shares over.
    database: Arc<zcash_voting::storage::VotingDb>,
    /// The handle's own shared root, kept alive for as long as this session
    /// lives.
    ///
    /// [`Self::database`] above is [`VotingDatabaseHandle::scoped`] over the
    /// handle this session was opened from — a distinct `VotingDb` value
    /// (and so a distinct `Arc` allocation) that shares the same underlying
    /// connection but is not the registry's root itself. Closing that handle
    /// (`zcashlc_voting_db_free`) drops its root; nothing forbids doing so
    /// while a session opened from it is still alive. Without a strong
    /// reference to the root here, the registry's `Weak` entry for this path
    /// would then die with the handle, and a later
    /// `VotingDatabaseHandle::open` on the same path would open a genuine
    /// second connection instead of finding this session's — exactly the
    /// contention the registry exists to prevent. Never read again after
    /// construction: its only job is staying alive for as long as the
    /// session does.
    _root: Arc<zcash_voting::storage::VotingDb>,
    /// Runs the round's steps. Owns the round binding — id, network, roster
    /// and hotkey secret — which is why planning goes through it rather than
    /// through a roster this struct would otherwise have to keep in step.
    executor: zcash_voting::RoundExecutor<Arc<zcash_voting::HyperTransport<SdkRoute>>>,
    /// Round setup, note selection, bundle layout and delegation proving.
    ///
    /// `Arc` because the round driver hands it to the crate as a
    /// `DelegationDriver` while this session keeps using it.
    pipeline: Arc<zcash_voting::DelegationPipeline<SdkWalletDbOpener>>,
    /// The PIR fleet delegation precompute queries, over [`Self::transport`]
    /// like every other service: a PIR query hides which rows are fetched, not
    /// who fetches them.
    pir: Arc<zcash_voting::PirFleet>,
    /// The crate transport every one of this session's services was built on,
    /// kept because vote-tree sync takes it per call rather than at
    /// construction — the crate keeps one tree client per wallet and
    /// transport, so handing it the same one each time keeps the incremental
    /// state.
    transport: Arc<zcash_voting::HyperTransport<SdkRoute>>,
    /// The helper client, kept beside the executor's clone: the two share one
    /// health tracker, so share tracking observes what the round's deliveries
    /// learned about each helper.
    helper_client: zcash_voting::HelperClient,
    /// Cancellation and the host operation epoch, shared with every bounded
    /// pass this session starts.
    control: zcash_voting::ChainSubmissionControl,
    /// The inputs this session was opened with, kept because a step needs the
    /// ones the crate does not capture at construction: the helper fleet, the
    /// vote-tree nodes and the round's timing. A run reads them through
    /// [`HostInputs`], which applies [`Self::live_host`] on top.
    inputs: SessionInputsDto,
    /// The host's live service configuration over [`Self::inputs`]: the
    /// helper fleet, the vote-tree nodes and the round's timing, as the host
    /// last stated them.
    ///
    /// One slot per session, not one per run. Every writer merges into it —
    /// [`Self::run`] and [`Self::track_shares`] as they start,
    /// [`Self::merge_host_overrides`] at any time — and both drivers read it
    /// through [`HostInputs`] on every dispatch, so a round that takes minutes
    /// can be moved onto a fleet the host learned about after it started.
    ///
    /// The SDK's Swift wrapper admits one driver per session at a time, so a
    /// run and a tracking pass do not in fact overlap here. Nothing in this
    /// module relies on that: one shared slot is the right answer either way,
    /// because the two are views of one round, and a helper fleet one of them
    /// must stop using is one the other must stop using too.
    ///
    /// Its own small lock, taken only to clone the slot out or to merge into
    /// it, and never while a driver lock is held: see [`HostInputs`].
    live_host: std::sync::Mutex<HostOverridesDto>,
    /// How many times [`Self::live_host`] has been read, so a test can prove
    /// one host context is built from ONE snapshot of it.
    ///
    /// That is not observable from the values a context carries: a context
    /// assembled field by field and one assembled from a single snapshot agree
    /// on every value except when a merge lands between two of the reads, so
    /// only the read count separates them without racing a writer.
    #[cfg(test)]
    live_host_reads: std::sync::atomic::AtomicUsize,
    /// The voting identity of the store this session was opened from.
    network: zcash_voting::Network,
    /// The SDK's numeric network id, kept so wallet-database and key
    /// derivation calls resolve the same (possibly custom) chain.
    network_id: u32,
    /// The round this session is bound to, as canonical lowercase hex.
    round_id: String,
}

/// The bundle policy a new round is seeded with: the crate's default, privacy
/// trim included. The trim drops low-value trailing bundles, never below two,
/// within the smaller of 1% of the selected value and 1,000 ZEC; a wallet with
/// a long dust tail otherwise pays a delegation proof and a vote proof per
/// question for bundles that carry almost no weight. What was dropped is
/// reported in the layout so the host can show it. A round that already
/// persisted a policy keeps it: the crate treats the stored one as
/// authoritative.
fn new_round_bundle_policy() -> zcash_voting::BundlePolicy {
    zcash_voting::BundlePolicy::default()
}

impl VotingSession {
    /// Opens a session for one round over `store`'s sidecar.
    ///
    /// Validation runs front to back and fails on the first problem, so a host
    /// learns about a malformed round id before a malformed anchor and about a
    /// malformed anchor before an unusable PIR layout. Nothing here reaches the
    /// network: every failure is a decision about the arguments.
    ///
    /// `epoch` is the host's operation epoch at open. Swift bumps it whenever
    /// the user switches wallets or leaves the flow, and every bounded pass
    /// started under an older epoch stops at its next boundary.
    pub(super) fn open(
        store: &VotingDatabaseHandle,
        inputs: SessionInputsDto,
        binding: SessionBindingDto,
        route: SdkRoute,
        epoch: u64,
    ) -> anyhow::Result<Self> {
        let database = store.scoped()?;
        // See the `_root` field's own doc comment: this keeps the handle's
        // registry entry alive for as long as this session runs, even if the
        // handle itself closes first.
        let root = store.shared_root_handle();

        let round_params = inputs.round_params.clone().into_params();
        // Checked here as well as inside the pipeline constructor, so a bad
        // round id is reported as itself rather than as whatever the anchor
        // decode or the branch-id lookup makes of it.
        zcash_voting::validate_round_params(&round_params).ffi()?;

        // The bytes are lightwalletd output the host fetched and passed
        // through, so a decode failure is the host's input, not this SDK's
        // invariant.
        let tree_state =
            <zcash_client_backend::proto::service::TreeState as prost::Message>::decode(
                inputs.anchor_tree_state.as_slice(),
            )
            .map_err(|e| {
                invalid_input(format!(
                    "anchor tree state is not a TreeState protobuf: {e}"
                ))
            })?;

        // What follows resolves the branch id from `store.network` alone, which
        // carries no custom activation heights. A chain whose own heights
        // select a different branch at this snapshot is refused here, where
        // both the registered parameters and the flattened identity the crate
        // uses are in hand and the refusal can name them, rather than later as
        // an unsupported note version or an unsupported branch id.
        let params = crate::parse_network(store.network_id).map_err(envelope_or_invalid_input)?;
        super::helpers::require_branch_agreement(
            &params,
            store.network,
            round_params.snapshot_height,
        )?;

        // Resolves the consensus branch id active at the snapshot height, so
        // delegation PCZTs are built for the same upgrade the notes were
        // selected under.
        let lwd = zcash_voting::delegate::DelegationLwdInputs::from_anchor_tree_state(
            store.network,
            round_params.clone(),
            &inputs.round_name,
            &tree_state,
        )
        .ffi()?;

        let hotkey = binding
            .hotkey_secret
            .as_deref()
            .map(|secret| zcash_voting::VotingHotkey::from_stored_secret(secret, store.network))
            .transpose()
            .ffi()?;

        let bundle_policy = new_round_bundle_policy();

        let pipeline = Arc::new(
            zcash_voting::DelegationPipeline::new(
                Arc::clone(&database),
                SdkWalletDbOpener::new(&inputs.wallet_db_path, store.network_id),
                lwd,
                &inputs.account_uuid,
                hotkey,
                bundle_policy,
                None,
            )
            .ffi()?,
        );

        let transport = super::route::routed_transport(route);

        // Constructing the fleet validates the layout and normalizes the
        // endpoint list; it connects to nothing. It rides the session's route
        // like every other service: a PIR query hides which rows are fetched,
        // not who fetches them, so on a Tor session it must not leave the
        // device any other way.
        let pir = Arc::new(
            zcash_voting::PirFleet::new(
                &inputs.pir_endpoints,
                inputs.pir_layout.clone().into_layout(),
                transport.clone(),
            )
            .ffi()?,
        );

        let helper_transport: Arc<dyn zcash_voting::HelperTransport> = transport.clone();
        let helper_client = zcash_voting::HelperClient::new(
            helper_transport,
            zcash_voting::HelperHealth::default(),
        );

        let executor = zcash_voting::RoundExecutor::with_transport(
            Arc::clone(&database),
            Arc::clone(&transport),
            zcash_voting::ChainSubmissionClientConfig::for_network(
                store.network,
                inputs.chain_endpoints.clone(),
            ),
            // The executor's clone shares this client's health tracker, so a
            // helper the round found unreachable stays cooled down for share
            // tracking too.
            helper_client.clone(),
        )
        // A `ChainSubmissionFailure` is not a `VotingError`, so it cannot go
        // through `ffi()`; its kinds describe submission outcomes, and nothing
        // construction can fail on is one the host can act on differently.
        .map_err(|e| internal(format!("{e}")))?
        .with_binding(zcash_voting::RoundBinding {
            round_id: round_params.vote_round_id.clone(),
            network: store.network,
            proposals: binding
                .roster
                .iter()
                .map(|entry| zcash_voting::ProposalRosterEntry {
                    proposal_id: entry.proposal_id,
                    num_options: entry.num_options,
                })
                .collect(),
            hotkey_secret: binding.hotkey_secret.map(Zeroizing::new),
        })
        .ffi()?
        // Vote-tree sync takes the session's route as well: the tree node sees
        // the device address and the round, which is what the route exists to
        // keep from it.
        .with_tree_transport(transport.clone());

        let control = zcash_voting::ChainSubmissionControl::new(epoch);

        Ok(VotingSession {
            database,
            _root: root,
            executor,
            pipeline,
            pir,
            transport,
            helper_client,
            control,
            round_id: round_params.vote_round_id,
            network: store.network,
            network_id: store.network_id,
            inputs,
            live_host: std::sync::Mutex::new(HostOverridesDto::default()),
            #[cfg(test)]
            live_host_reads: std::sync::atomic::AtomicUsize::new(0),
        })
    }

    /// Merge `update` into the session's host configuration: a field it names
    /// replaces the current value, a field it leaves absent keeps it.
    ///
    /// Both drivers read the merged value on every dispatch, so a write made
    /// while a run is in flight takes effect at its next dispatch. The lock is
    /// this slot's alone: no driver lock is ever held while it is taken.
    ///
    /// A poisoned lock is recovered from rather than propagated. The slot is
    /// four independent fields assigned one at a time, so a panic between two
    /// of them leaves each field either its old value or its new one — never a
    /// half-written one — and refusing to serve a configuration would stop a
    /// round over a panic that happened somewhere else entirely.
    pub(super) fn merge_host_overrides(&self, update: HostOverridesDto) {
        let mut live = self
            .live_host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if update.helper_urls.is_some() {
            live.helper_urls = update.helper_urls;
        }
        if update.vote_tree_node_urls.is_some() {
            live.vote_tree_node_urls = update.vote_tree_node_urls;
        }
        if update.ceremony_start_seconds.is_some() {
            live.ceremony_start_seconds = update.ceremony_start_seconds;
        }
        if update.vote_end_time_seconds.is_some() {
            live.vote_end_time_seconds = update.vote_end_time_seconds;
        }
    }

    /// The round's resume plan, against the roster this session is bound to.
    ///
    /// Planned through the executor rather than by calling
    /// `zcash_voting::session::resume_plan` with a roster held here as well:
    /// the executor already owns the validated roster, and
    /// [`Self::set_ballot_intents`] returns the plan the executor computes, so
    /// routing both through it is what keeps the two answers the same one. The
    /// executor also refuses a round the sidecar stores under another network,
    /// which the bare `resume_plan` does not check.
    pub(super) fn plan(&self) -> anyhow::Result<RoundPlanDto> {
        let plan = self.executor.plan().ffi()?;
        self.plan_dto(plan)
    }

    /// Records ballot decisions and returns the refreshed plan.
    ///
    /// The whole batch is resolved against the bound roster before anything is
    /// written, so a decision for a proposal outside the authenticated roster
    /// leaves durable intent untouched.
    pub(super) fn set_ballot_intents(
        &self,
        intents: Vec<BallotIntentDto>,
    ) -> anyhow::Result<RoundPlanDto> {
        let intents = intents
            .into_iter()
            .map(BallotIntentDto::into_intent)
            .collect::<Vec<_>>();
        let plan = self.executor.set_ballot_intents(&intents).ffi()?;
        self.plan_dto(plan)
    }

    /// The wire form of `plan`, with the legacy in-flight flag this session's
    /// sidecar rows answer.
    ///
    /// Both entry points that return a plan go through here, so a host reads
    /// the same answer whether it planned the round or recorded a ballot.
    fn plan_dto(&self, plan: zcash_voting::session::RoundPlan) -> anyhow::Result<RoundPlanDto> {
        let has_legacy_in_flight_submission =
            legacy_in_flight(&self.database, &self.round_id, &plan)?;
        Ok(RoundPlanDto {
            plan: plan_view(plan)?,
            has_legacy_in_flight_submission,
        })
    }

    /// Creates the round row, then its delegation bundle rows.
    ///
    /// The round row is created before note selection runs, so a wallet with
    /// nothing eligible still leaves a round the host can plan and show. The
    /// explicit `ensure_round` is idempotent and duplicates what
    /// `setup_bundles` does first internally; it states that ordering at this
    /// boundary rather than depending on it silently.
    pub(super) fn setup_bundles(&self) -> anyhow::Result<BundleLayoutDto> {
        self.pipeline.ensure_round().ffi()?;
        let layout = self.pipeline.setup_bundles().ffi()?;
        Ok(BundleLayoutDto::from(layout))
    }

    /// Whether the account can vote in this round, without persisting anything.
    pub(super) fn eligibility(&self) -> anyhow::Result<EligibilityDto> {
        let report = self.pipeline.eligibility().ffi()?;
        Ok(EligibilityDto::from(report))
    }

    /// Persists one bundle's witnesses and padded secrets and warms its PIR
    /// rows.
    ///
    /// The one delegation step worth running ahead of a drive: a bundle whose
    /// rows are already warm proves without waiting on the PIR fleet, and the
    /// report says how much of the warmth was already there. The fleet is
    /// reached over the session's route like everything else it touches, so on
    /// a Tor session these queries fail closed rather than leaving the device
    /// directly.
    pub(super) fn precompute_pir(&self, bundle_index: u32) -> anyhow::Result<PirPrecomputeDto> {
        let report = self
            .pipeline
            .precompute_pir(bundle_index, &self.pir)
            .ffi()?;
        Ok(PirPrecomputeDto {
            bundle_index: report.bundle_index,
            cached: report.report.cached,
            fetched: report.report.fetched,
            // The round's layout as the precompute saw it, so one report is
            // enough for a host to say "bundle 2 of 5".
            bundle_count: report.layout.bundle_count,
        })
    }

    /// Sync this round's vote-commitment tree from `node_url` over the
    /// session's route, returning the height synced to.
    ///
    /// The crate keeps one tree client per wallet and transport, so passing
    /// the session's own transport on every call keeps the incremental state
    /// *within* one session.
    ///
    /// Across sessions it does not, and that is this routing's standing cost.
    /// Every session builds its own transport and the crate keys its clients
    /// on that transport's identity, so each session's first sync of a round
    /// syncs the tree from scratch rather than continuing the last session's.
    /// It is paid wherever a round is reopened, and worst where a route change
    /// forces a new session: toggling Tor mid-round buys a full resync over
    /// Tor. It is not paid only here: [`Self::run`] syncs the same tree over
    /// the same transport when it casts a vote, so a host that never calls
    /// this pays it too.
    ///
    /// The old client is not dropped with the session either. A routed client
    /// holds the transport it was built over — for a Tor session, this
    /// session's isolated Tor client — and outlives every other clone of that
    /// transport for as long as it holds any round's tree state, so both stay
    /// in memory, past the host disabling Tor, until
    /// [`super::store::reset_vote_tree`] forgets its rounds or the last
    /// connection to the sidecar closes. Nothing here resets on close, on
    /// purpose: the crate's round-scoped reset drops that round's state on
    /// *every* client the wallet has, so a session tidying up after itself
    /// would throw away a concurrent session's sync. That reset is also keyed
    /// by the wallet id the handle is bound to when it runs, so a wallet
    /// switch resets before `zcashlc_voting_set_wallet_id`, never after.
    pub(super) fn sync_vote_tree(&self, node_url: &str) -> anyhow::Result<u32> {
        zcash_voting::precompute::sync_vote_tree_with(
            &self.database,
            &self.round_id,
            node_url,
            self.transport.clone(),
        )
        .ffi()
    }

    /// Generates this bundle's proof, or reports the persisted one it reused,
    /// streaming the pipeline's stages to `sink` as it goes.
    ///
    /// Runs on a thread of its own with a
    /// [64 MiB stack](PROOF_THREAD_STACK_BYTES) and blocks the calling thread
    /// until that one joins — minutes for a proof this call has to generate.
    /// Not spawned on the shared runtime: proving is CPU work that would hold
    /// a worker for its whole duration, and a worker's stack is the runtime's
    /// to size rather than this call's.
    ///
    /// A spawned thread must own what it touches, so the pipeline and the
    /// fleet go in as `Arc` clones and the sink — which is `Copy` — goes in by
    /// value; nothing is borrowed from the session across the join.
    pub(super) fn precompute_delegation_proof(
        self: &Arc<Self>,
        bundle_index: u32,
        sink: EventSink,
    ) -> anyhow::Result<ProofStatusDto> {
        let pipeline = Arc::clone(&self.pipeline);
        let pir = Arc::clone(&self.pir);
        let status = std::thread::Builder::new()
            .name("zcash-voting-proof".to_string())
            .stack_size(PROOF_THREAD_STACK_BYTES)
            .spawn(move || {
                let reporter = DelegationProgressCallbackReporter { sink, bundle_index };
                pipeline.ensure_proof(bundle_index, &pir, &reporter)
            })
            // A thread the OS refused and a proof that panicked are both this
            // SDK's problem rather than a decision the host can make
            // differently, so both cross as `internal`; a panic payload is not
            // worth rendering into the message.
            .map_err(|e| internal(format!("voting proof thread did not start: {e}")))?
            .join()
            .map_err(|_| internal("voting proof thread panicked"))?
            .ffi()?;
        Ok(match status {
            zcash_voting::delegate::DelegationProofStatus::Generated => ProofStatusDto::Generated,
            zcash_voting::delegate::DelegationProofStatus::Reused => ProofStatusDto::Reused,
        })
    }

    /// The redacted PCZTs a Keystone device signs, one per named bundle and in
    /// the order named — one request per bundle, because the device signs one
    /// QR at a time and the host shows them in the order it asked for.
    ///
    /// A bundle the pipeline cannot build a request for fails the whole call
    /// rather than dropping out of the batch: the host asked for the set of
    /// QRs that covers a round, and a quietly shorter one would read as a
    /// complete set with a bundle that never needed signing.
    pub(super) fn keystone_signing_requests(
        &self,
        bundle_indices: &[u32],
    ) -> anyhow::Result<Vec<KeystoneSigningRequestDto>> {
        require_distinct_bundles(bundle_indices)?;
        bundle_indices
            .iter()
            .map(|bundle_index| {
                Ok(KeystoneSigningRequestDto::from(
                    self.pipeline.keystone_request(*bundle_index).ffi()?,
                ))
            })
            .collect()
    }

    /// Lifts the signatures off the PCZTs a Keystone device returned, checks
    /// each one against the request it answers, and stores them for this
    /// round.
    ///
    /// The signature bytes are the only thing taken from the host's PCZT. The
    /// sighash and `rk` stored beside each one come from the request this
    /// wallet rebuilds here, which is why the requests are rebuilt rather than
    /// handed back by the host: what a stored signature is later verified
    /// against is then the wallet's own, whatever the device returned.
    ///
    /// A response no signature can be lifted from, and a signature that does
    /// not sign the bundle's own request under that bundle's randomized key,
    /// each refuse the whole call, and nothing of the batch is stored — not
    /// even the entries that did verify. Both name their bundle on the error
    /// envelope, because a host collected one response per bundle and needs to
    /// know which to ask for again. That is the only moment either can be
    /// refused: what the store keeps for a bundle is the first signature it is
    /// given, it compares only the signing context afterwards, and it offers
    /// no way to clear one bundle. Scanning the right response afterwards
    /// stores it; scanning a response that already verified again reports it
    /// as already present.
    ///
    /// The write is one atomic idempotent batch: every named bundle is stored
    /// or none is, and a retry after a QR session that was interrupted halfway
    /// reports what was already there rather than failing on it.
    pub(super) fn store_keystone_signatures(
        &self,
        signed: Vec<KeystoneSignedBundleDto>,
    ) -> anyhow::Result<KeystoneSignatureBatchResultDto> {
        let bundle_indices = signed
            .iter()
            .map(|entry| entry.bundle_index)
            .collect::<Vec<_>>();
        require_distinct_bundles(&bundle_indices)?;
        let prepared = signed
            .iter()
            .map(|entry| {
                let request = self.pipeline.keystone_request(entry.bundle_index).ffi()?;
                let sig = super::signer::keystone_signature(&request, &entry.signed_pczt)
                    .ffi_for_bundle(entry.bundle_index)?;
                Ok((request, sig))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        let inputs = verified_signature_inputs(prepared)?;
        let stored = self
            .database
            .store_keystone_signatures_batch(&self.round_id, &inputs)
            .ffi()?;
        Ok(KeystoneSignatureBatchResultDto {
            inserted: stored.inserted,
            already_present: stored.already_present,
        })
    }

    /// Drives this round to quiescence, reporting every driver event to
    /// `sink` as it goes.
    ///
    /// Blocks the calling thread for the whole run — minutes on a round with
    /// proofs to generate — but runs the driver on the shared runtime rather
    /// than here: calls arrive from Swift threads, never from a runtime
    /// worker, and the driver hands its planning reads off the worker with
    /// `block_in_place`, which only a multi-thread runtime allows.
    ///
    /// `overrides` is merged into the session's live host configuration before
    /// the driver starts, by [`Self::merge_host_overrides`] and with its
    /// semantics: a field it names replaces the session's current value, a
    /// field it leaves absent keeps whatever is there. The driver reads that
    /// slot on every dispatch, so a configuration pushed while this run is in
    /// flight reaches its next dispatch — and what this call merged outlives
    /// the run, standing for later runs of the same session until something
    /// replaces it.
    ///
    /// That merge happens before the signer is built, so a call that then
    /// fails on an unusable seed has already moved the session's
    /// configuration. This is not a rollback boundary and is not meant to be
    /// one: the host stated a fleet, and the fleet it stated is the one the
    /// next call is driven against, whether or not this call got as far as
    /// signing anything.
    ///
    /// `signer` decides what the run may do with delegation. Without one, the
    /// driver reports the bundles that owe a signature instead of dispatching
    /// them; with a software seed, the seed goes into [`SeedSpendAuthSigner`]
    /// and nowhere else — never into Swift, and never into a sighash, alpha or
    /// PCZT the host could see. It is in a `Zeroizing` buffer from the moment
    /// the FFI decoded it, and that buffer is wiped when this run's delegation
    /// inputs drop with the spawned task.
    ///
    /// The driver itself never fails: a run that could do nothing says why
    /// through the report's quiescence. What can fail is either side of it —
    /// a signer this host cannot build, a driver task that did not finish, and
    /// a report the wire projection refuses.
    pub(super) fn run(
        self: &Arc<Self>,
        overrides: HostOverridesDto,
        signer: Signer,
        policy: DrivePolicyDto,
        sink: EventSink,
    ) -> anyhow::Result<zcash_voting::wire::RoundRunReportView> {
        self.merge_host_overrides(overrides);
        let session = Arc::clone(self);
        let (drive_policy, max_proof_concurrency) = policy.into_policy();
        // `.clone()` rather than `Arc::clone`: the unsizing coercion to the
        // trait object happens at this binding, and `Arc::clone`'s argument
        // would have to already be one.
        let driver: Arc<dyn zcash_voting::DelegationDriver> = self.pipeline.clone();
        let delegation = match signer {
            Signer::None => None,
            Signer::Software(seed) => Some(zcash_voting::DelegationSigner::Software(Arc::new(
                // `SeedSpendAuthSigner::new` rejects a seed it cannot derive
                // from with a bare message, which has to reach Swift as the
                // typed envelope the rest of the session uses — but the
                // network check it delegates already returns one, so wrapping
                // unconditionally would nest that envelope's JSON inside a
                // second one's message.
                SeedSpendAuthSigner::new(seed, self.network_id, self.network)
                    .map_err(envelope_or_invalid_input)?,
            ))),
            Signer::KeystoneStored => Some(zcash_voting::DelegationSigner::Keystone(
                zcash_voting::KeystoneSignatureSource::Stored,
            )),
        }
        .map(|signer| zcash_voting::DelegationStepInputs {
            driver,
            signer,
            pir: Arc::clone(&self.pir),
        });

        let report = super::runtime::runtime()
            .block_on(super::runtime::runtime().spawn(async move {
                let host = SessionHost {
                    inputs: HostInputs {
                        session: Arc::clone(&session),
                    },
                    delegation,
                    max_proof_concurrency,
                };
                let reporter = CallbackReporter { sink };
                zcash_voting::RoundDriver::new(&session.executor)
                    .with_policy(drive_policy)
                    .run(&host, &session.control, &reporter)
                    .await
            }))
            .map_err(|e| internal(format!("voting run task failed: {e}")))?;
        zcash_voting::wire::RoundRunReportView::try_from(report).ffi()
    }

    /// Drives this round's unconfirmed helper shares to confirmation,
    /// reporting every pass to `sink`.
    ///
    /// Spawned like [`Self::run`] and for the same reasons, and like it the
    /// driver never fails: a run that owed nothing, ran out of passes or found
    /// the vote already closed says so through the report's quiescence.
    ///
    /// `overrides` is merged into the session's live host configuration as in
    /// [`Self::run`] — the same slot, the same per-field merge — and this
    /// driver reads it on every pass.
    ///
    /// A round admits one tracking run at a time. A second started while a
    /// live one holds the round returns at once with `already_driving`; one
    /// started while a cancelled run is on its way out waits for it to release
    /// the round and takes it over.
    pub(super) fn track_shares(
        self: &Arc<Self>,
        overrides: HostOverridesDto,
        policy: ShareTrackingPolicyDto,
        sink: EventSink,
    ) -> anyhow::Result<zcash_voting::wire::ShareTrackingRunReportView> {
        self.merge_host_overrides(overrides);
        let session = Arc::clone(self);
        let policy = policy.into_policy();

        let report = super::runtime::runtime()
            .block_on(super::runtime::runtime().spawn(async move {
                let host = ShareTrackingHost {
                    inputs: HostInputs {
                        session: Arc::clone(&session),
                    },
                };
                let reporter = ShareTrackingCallbackReporter { sink };
                zcash_voting::ShareTrackingDriver::new(
                    &session.database,
                    &session.helper_client,
                    &session.round_id,
                )
                .with_policy(policy)
                .run(&host, &session.control, &reporter)
                .await
            }))
            .map_err(|e| internal(format!("share tracking task failed: {e}")))?;
        Ok(zcash_voting::wire::ShareTrackingRunReportView::from(report))
    }

    /// Cancels every bounded pass this session's control governs.
    ///
    /// Permanent: a cancelled session is finished, not paused. Work already
    /// made durable stays durable.
    pub(super) fn cancel(&self) {
        self.control.cancel();
    }

    /// Moves the host operation epoch, invalidating passes that captured an
    /// older one.
    pub(super) fn set_epoch(&self, epoch: u64) {
        self.control.set_operation_epoch(epoch);
    }

    /// The round this session is bound to.
    ///
    /// Test-only, like [`EventSink::none`]: every step here reaches the round
    /// through the field, and the C surface hands Swift the round id inside the
    /// plan and the reports rather than on its own.
    #[cfg(test)]
    pub(super) fn round_id(&self) -> &str {
        &self.round_id
    }

    /// The session's live host configuration as it stands.
    ///
    /// Test-only, and deliberately not part of the C surface: a host states
    /// this configuration, it does not read it back, and the drivers reach it
    /// through [`HostInputs`]. It exists so a test on the far side of the FFI
    /// can assert that a configuration pushed through
    /// `zcashlc_voting_session_update_host_configuration` landed in this slot.
    /// Nothing else can: that entry point answers `0` for any payload it can
    /// decode, whether or not it went on to merge it.
    #[cfg(test)]
    pub(super) fn live_host_snapshot(&self) -> HostOverridesDto {
        self.live_host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

/// Unix seconds now, or 0 on a host whose clock predates the epoch.
///
/// Read on every host context rather than captured once per run: a round can
/// take minutes, a proof can cross the last-moment or vote-end boundary, and
/// the step that follows must plan against the clock it actually runs under.
/// The fallback is deliberate — no round's timing window contains 0, so a
/// broken clock plans as if outside the window instead of stopping the run.
fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since_epoch| since_epoch.as_secs())
        .unwrap_or(0)
}

/// The host inputs a driver reads: the session's own, with whatever is in the
/// session's live host slot ([`VotingSession::merge_host_overrides`]) on top.
///
/// The slot is read afresh on every accessor call rather than captured when a
/// run starts, because the drivers ask for a host context between dispatches
/// precisely so the host can refresh what a long round depends on — the helper
/// fleet, the vote-tree nodes and the round's timing. A configuration the host
/// pushes mid-run therefore reaches the next dispatch.
///
/// A slot field that is set stands in for the session's value; one left absent
/// keeps the session's. JSON cannot say "clear this" — an explicit `null`
/// deserializes as absent — so a round whose timing must be gone is opened
/// without it rather than cleared here.
///
/// [`Self::resolved`] takes the slot once and answers all four values from
/// that one snapshot. Taking it per value would let a merge land between two
/// of them and produce a configuration no host ever stated — a helper fleet
/// from before it and a vote end from after, or worse, a `ceremony_start` and
/// a `vote_end` that never bounded one window. The crate reads that pair for
/// `RoundHostContext::is_last_moment()`, whose answer becomes the durable
/// `single_share` property of a cast, so the mixed pair would outlive the
/// dispatch that saw it.
///
/// The resolution touches neither the sidecar nor any lock the drivers hold,
/// because the drivers ask for a context between dispatches and one that
/// waited on a step's own lock would deadlock the run. The slot lock is held
/// for the clone alone, and by nothing that can block.
struct HostInputs {
    session: Arc<VotingSession>,
}

/// Everything one host context is built from, resolved together.
///
/// A value stands for one reading of the session's configuration: the live
/// slot where it names a field, the session's own inputs where it does not.
struct ResolvedHostConfiguration {
    configured_helper_urls: Vec<String>,
    vote_tree_node_urls: Vec<String>,
    ceremony_start_seconds: Option<u64>,
    vote_end_time_seconds: Option<u64>,
}

impl HostInputs {
    /// The session's live host slot as it stands right now.
    ///
    /// Cloned out under the lock and read outside it, so nothing this context
    /// answers with is computed while the slot is held. A poisoned lock is
    /// recovered from for the reason
    /// [`VotingSession::merge_host_overrides`] gives.
    fn live(&self) -> HostOverridesDto {
        #[cfg(test)]
        self.session
            .live_host_reads
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.session
            .live_host
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// One snapshot of the slot, resolved against the session's own inputs.
    ///
    /// Called exactly once per host context. The snapshot's fields are moved
    /// out rather than cloned, so the session's inputs are cloned only for the
    /// fields the host has not replaced.
    fn resolved(&self) -> ResolvedHostConfiguration {
        let live = self.live();
        ResolvedHostConfiguration {
            configured_helper_urls: live
                .helper_urls
                .unwrap_or_else(|| self.session.inputs.helper_urls.clone()),
            vote_tree_node_urls: live
                .vote_tree_node_urls
                .unwrap_or_else(|| self.session.inputs.vote_tree_node_urls.clone()),
            ceremony_start_seconds: live
                .ceremony_start_seconds
                .unwrap_or(self.session.inputs.ceremony_start_seconds),
            vote_end_time_seconds: live
                .vote_end_time_seconds
                .unwrap_or(self.session.inputs.vote_end_time_seconds),
        }
    }
}

/// The round driver's host: the session's inputs, plus what only a drive
/// needs.
struct SessionHost {
    inputs: HostInputs,
    /// The delegation inputs this run signs with, or `None` when the host
    /// named no signer.
    delegation: Option<zcash_voting::DelegationStepInputs>,
    max_proof_concurrency: usize,
}

impl zcash_voting::RoundHostSource for SessionHost {
    fn host_context(&self) -> zcash_voting::RoundHostContext {
        let resolved = self.inputs.resolved();
        zcash_voting::RoundHostContext {
            configured_helper_urls: resolved.configured_helper_urls,
            now_seconds: now_seconds(),
            ceremony_start_seconds: resolved.ceremony_start_seconds,
            vote_end_time_seconds: resolved.vote_end_time_seconds,
            vote_tree_node_urls: resolved.vote_tree_node_urls,
            delegation: self.delegation.clone(),
            // Fresh submissions only: the driver upgrades work the sidecar
            // already holds to exact-tree recovery itself, so naming a policy
            // for that case here would state a decision the crate makes.
            chain_policy: zcash_voting::ChainAdvancePolicy::default(),
            max_proof_concurrency: self.max_proof_concurrency,
        }
    }
}

/// The share-tracking driver's host: the helper fleet and the round's end,
/// which is all a pass reads.
struct ShareTrackingHost {
    inputs: HostInputs,
}

impl zcash_voting::ShareTrackingHostSource for ShareTrackingHost {
    fn host_context(&self) -> zcash_voting::ShareTrackingHostContext {
        // One snapshot here too, for the reason [`HostInputs`] gives: a pass
        // driven against a helper fleet from before a merge and a vote end
        // from after it is a pass no host asked for.
        let resolved = self.inputs.resolved();
        zcash_voting::ShareTrackingHostContext {
            configured_helper_urls: resolved.configured_helper_urls,
            now_seconds: now_seconds(),
            vote_end_time_seconds: resolved.vote_end_time_seconds,
        }
    }
}

/// Projects the round driver's events onto the host's sink.
struct CallbackReporter {
    sink: EventSink,
}

impl zcash_voting::RoundDriveReporter for CallbackReporter {
    fn report(&self, event: zcash_voting::RoundDriveEvent) {
        // An event the wire projection refuses is dropped rather than failing
        // the run: the stream is an observation, and the run report — which
        // carries the same plan, failures and chain outcomes — remains the
        // authoritative account of what happened.
        if let Ok(event) = zcash_voting::wire::RoundDriveEventView::try_from(event) {
            self.sink.emit(&SessionEventDto::RoundDrive {
                event: Box::new(event),
            });
        }
    }
}

/// Projects the share-tracking driver's events onto the host's sink.
struct ShareTrackingCallbackReporter {
    sink: EventSink,
}

impl zcash_voting::ShareTrackingReporter for ShareTrackingCallbackReporter {
    fn report(&self, event: zcash_voting::ShareTrackingEvent) {
        self.sink.emit(&SessionEventDto::ShareTracking {
            event: zcash_voting::wire::ShareTrackingEventView::from(event),
        });
    }
}

/// Projects one bundle's delegation-pipeline progress onto the host's sink.
///
/// The bundle index comes from the call rather than from the event: the
/// pipeline reports a stage, and which bundle it belongs to is what this
/// session asked it to prove.
struct DelegationProgressCallbackReporter {
    sink: EventSink,
    bundle_index: u32,
}

impl zcash_voting::DelegationProgressReporter for DelegationProgressCallbackReporter {
    fn on_progress(&self, progress: zcash_voting::delegate::DelegationProgress) {
        // An event that fails to serialize is dropped inside the sink, as in
        // the drivers' reporters above: the stream is an observation of the
        // proof, and the status this call returns is what the host acts on.
        self.sink.emit(&SessionEventDto::DelegationProgress {
            progress: DelegationProgressDto {
                bundle_index: self.bundle_index,
                stage: progress_stage(&progress).to_string(),
                fraction: progress_fraction(&progress),
            },
        });
    }
}

/// The wire name of a delegation progress stage: the crate's variant in
/// snake_case.
///
/// Spelled out rather than derived, because `DelegationProgress` is the
/// crate's own enum and carries no `Serialize`; writing the names here is also
/// what pins them as the strings Swift matches on. The enum is
/// `#[non_exhaustive]`, so a stage a newer crate reports and this SDK does not
/// name crosses as `unknown` rather than being dropped — a host shows an
/// unnamed step rather than a stalled one.
pub(super) fn progress_stage(
    progress: &zcash_voting::delegate::DelegationProgress,
) -> &'static str {
    use zcash_voting::delegate::DelegationProgress;

    match progress {
        DelegationProgress::SelectingNotes => "selecting_notes",
        DelegationProgress::PcztBuilding => "pczt_building",
        DelegationProgress::PcztBuilt => "pczt_built",
        DelegationProgress::ProofStarting => "proof_starting",
        DelegationProgress::WaitingForExistingProof => "waiting_for_existing_proof",
        DelegationProgress::ProofProgress(_) => "proof_progress",
        DelegationProgress::ProofComplete => "proof_complete",
        DelegationProgress::SigningPayload => "signing_payload",
        DelegationProgress::PayloadReady => "payload_ready",
        _ => "unknown",
    }
}

/// How far into itself a stage that measures its own progress is, and `None`
/// for one that does not: only proof generation reports a fraction.
pub(super) fn progress_fraction(
    progress: &zcash_voting::delegate::DelegationProgress,
) -> Option<f64> {
    match progress {
        zcash_voting::delegate::DelegationProgress::ProofProgress(fraction) => Some(*fraction),
        _ => None,
    }
}

/// Refuses a Keystone batch that names no bundle, or names one twice.
///
/// Both are the host's own mistake and neither has a sensible outcome: an
/// empty batch would build nothing and store nothing, and a repeated index
/// would either hand the host the same QR twice or offer the store two
/// signatures for one bundle. Checked before the pipeline prepares anything,
/// so the refusal costs no wallet read.
fn require_distinct_bundles(bundle_indices: &[u32]) -> anyhow::Result<()> {
    if bundle_indices.is_empty() {
        return Err(invalid_input("a Keystone batch names at least one bundle"));
    }
    let mut seen = std::collections::HashSet::with_capacity(bundle_indices.len());
    match bundle_indices
        .iter()
        .find(|bundle_index| !seen.insert(**bundle_index))
    {
        Some(duplicate) => Err(invalid_input(format!(
            "bundle {duplicate} is named twice in one Keystone batch"
        ))),
        None => Ok(()),
    }
}

/// Every prepared Keystone pair — the request this wallet rebuilt, and the
/// signature lifted from the PCZT the device returned for it — converted into
/// what the store takes, or the first refusal.
///
/// Whole-batch conversion before a single row is written is what makes a batch
/// containing one unusable signature store nothing at all. The store's own
/// batch is already atomic over what it is given; it can only be atomic over a
/// signature it never sees if the refusal happens on this side of the call.
fn verified_signature_inputs(
    prepared: Vec<(KeystoneSigningRequest, [u8; 64])>,
) -> anyhow::Result<Vec<KeystoneSignatureInput>> {
    prepared
        .into_iter()
        .map(|(request, sig)| {
            super::signer::verified_signature_input(&request, sig)
                .ffi_for_bundle(request.bundle_index)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voting::store;
    use crate::voting::test_support::*;
    use crate::voting::wire::DecisionDto;

    /// A session over a fresh in-memory store and a fresh wallet holding one
    /// note-less account.
    ///
    /// The temporary directory is returned alongside, not dropped here: it owns
    /// the wallet file the session's opener re-opens on every pipeline stage.
    fn open_session(
        tag: u8,
    ) -> (
        crate::voting::store::VotingDatabaseHandle,
        tempfile::TempDir,
        VotingSession,
    ) {
        let store = open_memory_store(crate::NETWORK_ID_TESTNET, "w");
        let (dir, wallet_path, account_uuid) =
            temp_wallet_db_with_account(crate::NETWORK_ID_TESTNET);
        let inputs = synthetic_session_inputs(tag, &wallet_path, &account_uuid);
        let hotkey =
            zcash_voting::hotkey::generate_random_voting_hotkey(zcash_voting::Network::Testnet)
                .expect("hotkey")
                .stored_secret()
                .to_vec();
        let session = VotingSession::open(
            &store,
            inputs,
            synthetic_binding(2, Some(hotkey)),
            SdkRoute::direct(),
            1,
        )
        .expect("open");
        (store, dir, session)
    }

    /// The refusal a wallet with nothing to vote with produces.
    ///
    /// Note selection reports it as `NoSpendableNotes` or, once weight is
    /// decomposed, as `InsufficientEligibility`; which of the two a fixture
    /// lands on is the crate's business, and every caller here only needs the
    /// round to have refused rather than failed some other way.
    fn assert_empty_wallet_refusal(err: &anyhow::Error) {
        let kind = error_kind(err);
        assert!(
            matches!(
                kind.as_str(),
                "no_spendable_notes" | "insufficient_eligibility"
            ),
            "unexpected kind for an empty wallet: {kind}"
        );
    }

    /// The error kind of a voting failure that crossed as `VotingErrorView` JSON.
    ///
    /// Every assertion below goes through this rather than matching message
    /// text: the point of the envelope is that Swift branches on the kind.
    fn error_kind(err: &anyhow::Error) -> String {
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("typed JSON error");
        serde_json::to_value(view.kind)
            .expect("kind")
            .as_str()
            .expect("kind is a string")
            .to_string()
    }

    /// The bundle a voting failure names on its envelope, if any.
    fn error_bundle_index(err: &anyhow::Error) -> Option<u32> {
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("typed JSON error");
        view.bundle_index
    }

    #[test]
    fn open_rejects_invalid_tree_state_bytes() {
        let store = open_memory_store(crate::NETWORK_ID_TESTNET, "w");
        let (_dir, wallet_path, account_uuid) =
            temp_wallet_db_with_account(crate::NETWORK_ID_TESTNET);
        let mut inputs = synthetic_session_inputs(0x21, &wallet_path, &account_uuid);
        inputs.anchor_tree_state = vec![0xff, 0xff, 0xff];
        // `VotingSession` is deliberately not `Debug` (it holds a hotkey
        // secret), so the success arm cannot go through `unwrap_err`.
        let err = match VotingSession::open(
            &store,
            inputs,
            synthetic_binding(1, None),
            SdkRoute::direct(),
            1,
        ) {
            Ok(_) => panic!("a malformed anchor tree state must not open a session"),
            Err(err) => err,
        };
        assert_eq!(error_kind(&err), "invalid_input");
    }

    #[test]
    fn open_binds_the_round_id_from_the_round_params() {
        let (_store, _dir, session) = open_session(0x20);
        assert_eq!(session.round_id(), hex_round_id(0x20));
    }

    /// A custom network whose activation heights select a different consensus
    /// branch than its base network does at the round's snapshot height cannot
    /// delegate: `zcash_voting` re-derives that branch from the base identity
    /// alone and refuses anything else. Opening must fail with the typed
    /// refusal rather than build a delegation for a branch this chain is not
    /// on.
    ///
    /// The custom network is registered for real here, through the FFI a host
    /// calls, because the registration is what the session resolves at open.
    /// That slot is process-global, so this runs under the shared guard that
    /// serializes it against the other test which registers one
    /// (`store_ffi::tests::db_open_custom_network_derives_voting_network_from_base`)
    /// and puts the previous registration back when the test ends.
    #[test]
    fn a_session_on_a_custom_network_with_a_diverging_branch_refuses_to_open() {
        let _custom_network = crate::lock_custom_network();

        // Modified mainnet: mainnet's own heights, except that this deployment
        // has not activated NU6.3 yet. Mainnet is on NU6.3 well below the
        // synthetic snapshot, so the two schedules disagree there.
        assert!(crate::zcashlc_set_custom_network(
            1, 347_500, 419_200, 653_600, 903_000, 1_046_400, 1_687_104, 2_726_400, 3_146_400,
            3_364_600, 10_000_000,
        ));

        let store = open_memory_store(crate::NETWORK_ID_REGTEST, "w");
        let (_dir, wallet_path, account_uuid) =
            temp_wallet_db_with_account(crate::NETWORK_ID_REGTEST);
        let mut inputs = synthetic_session_inputs(0x2b, &wallet_path, &account_uuid);
        // A mainnet-based chain is a production vote chain to the crate, which
        // refuses a plain-HTTP endpoint for one. Still the discard port, so
        // nothing is dialed; the scheme only keeps the chain configuration from
        // being what fails, so this case fails on the branch or not at all.
        inputs.chain_endpoints = vec!["https://127.0.0.1:9/".to_string()];
        let err = match VotingSession::open(
            &store,
            inputs,
            synthetic_binding(1, None),
            SdkRoute::direct(),
            1,
        ) {
            Ok(_) => panic!("a custom network whose branch differs must not open a session"),
            Err(err) => err,
        };
        assert_eq!(
            error_kind(&err),
            "invalid_input",
            "unexpected refusal: {err}"
        );
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("typed JSON error");
        assert!(
            view.message.contains("Nu6_2") && view.message.contains("Nu6_3"),
            "the refusal must name both branches: {}",
            view.message
        );

        // The refusal belongs to the custom slot alone: a standard network
        // still opens, in this same process, with that registration live.
        let (_store, _dir, session) = open_session(0x2c);
        assert_eq!(session.round_id(), hex_round_id(0x2c));
    }

    #[test]
    fn new_rounds_are_seeded_with_the_crates_default_privacy_trim() {
        let policy = new_round_bundle_policy();
        assert_eq!(policy.max_privacy_bundles(), Some(2));
        assert_eq!(policy.privacy_drop_bps(), 100);
    }

    /// A round whose bundle setup failed keeps its row and still plans.
    ///
    /// This is the sequence a voter with no eligible notes produces, so the
    /// round must survive it: `setup_bundles` persisted the round row before
    /// note selection refused, and the plan that follows reports a round that
    /// owes a draft — no proposal has been decided — rather than failing. The
    /// surviving row is asserted through the store, because a plan alone reads
    /// the same for a round the sidecar never recorded.
    #[test]
    fn plan_after_a_refused_bundle_setup_keeps_the_round_and_owes_a_draft() {
        let (store, _dir, session) = open_session(0x22);
        let err = session.setup_bundles().unwrap_err(); // empty wallet
        assert_empty_wallet_refusal(&err);

        let rounds = store::list_rounds(&store).expect("rounds");
        assert_eq!(
            rounds
                .iter()
                .map(|r| r.round_id.as_str())
                .collect::<Vec<_>>(),
            vec![hex_round_id(0x22).as_str()],
        );

        let plan = session
            .plan()
            .expect("a round with no bundles still plans")
            .plan;
        assert_eq!(plan.round_id, hex_round_id(0x22));
        assert!(plan.needs_draft_setup);
        assert!(!plan.needs_bundle_setup);
    }

    /// Planning a round the sidecar has never seen is not an error.
    ///
    /// The crate plans over a round's rows, and a round with none plans as an
    /// idle round that owes a draft. Asserting it here keeps the host from
    /// having to order "open" and "plan" against a round row it cannot see.
    #[test]
    fn plan_before_any_round_row_is_an_idle_plan() {
        let (_store, _dir, session) = open_session(0x29);
        let plan = session.plan().expect("plan").plan;
        assert_eq!(plan.round_id, hex_round_id(0x29));
        assert!(plan.next_steps.is_empty());
        assert!(plan.needs_draft_setup);
    }

    /// Both plan-returning session calls answer the legacy in-flight question,
    /// and a round this SDK created answers `false`.
    ///
    /// A session cannot reach a round an older SDK left mid-submission without
    /// that round's sidecar, which `store::tests` builds and drives through
    /// `round_plan`; what belongs here is that neither entry point drops the
    /// field on the way out, since a host that reads it from one and not the
    /// other would gate on nothing.
    #[test]
    fn both_plan_entry_points_report_the_legacy_in_flight_flag() {
        let (_store, _dir, session) = open_session(0x2a);
        assert!(
            !session
                .plan()
                .expect("plan")
                .has_legacy_in_flight_submission
        );

        session.setup_bundles().unwrap_err(); // empty wallet; the round row survives
        let plan = session
            .set_ballot_intents(vec![BallotIntentDto {
                proposal_id: 1,
                decision: DecisionDto::Choice { option: 0 },
            }])
            .expect("plan");
        assert!(!plan.has_legacy_in_flight_submission);
        assert_eq!(
            serde_json::to_value(&plan).expect("json")["has_legacy_in_flight_submission"],
            false,
            "the flag has to cross to Swift beside the crate's own keys"
        );
    }

    #[test]
    fn setup_bundles_on_empty_wallet_is_no_spendable_notes() {
        let (_store, _dir, session) = open_session(0x23);
        let err = session.setup_bundles().unwrap_err();
        assert_empty_wallet_refusal(&err);
    }

    #[test]
    fn eligibility_on_empty_wallet_is_no_spendable_notes() {
        let (_store, _dir, session) = open_session(0x26);
        let err = session.eligibility().unwrap_err();
        assert_empty_wallet_refusal(&err);
    }

    #[test]
    fn set_ballot_intents_requires_rostered_proposals() {
        let (_store, _dir, session) = open_session(0x24);
        let err = session
            .set_ballot_intents(vec![BallotIntentDto {
                proposal_id: 99,
                decision: DecisionDto::Skipped,
            }])
            .unwrap_err();
        assert_eq!(error_kind(&err), "invalid_input");
    }

    /// Recording an intent needs the round row, and `setup_bundles` is how a
    /// session creates it: its `ensure_round` runs before note selection, so
    /// the row survives the empty wallet's `NoSpendableNotes`. Without that
    /// first call the write fails on the sidecar's foreign key instead.
    #[test]
    fn set_ballot_intents_on_a_rostered_proposal_returns_a_plan() {
        let (_store, _dir, session) = open_session(0x27);
        session.setup_bundles().unwrap_err();
        let plan = session
            .set_ballot_intents(vec![BallotIntentDto {
                proposal_id: 1,
                decision: DecisionDto::Choice { option: 0 },
            }])
            .expect("plan")
            .plan;
        assert_eq!(plan.round_id, hex_round_id(0x27));
        // Proposal 2 is rostered and undecided, so the round still owes a draft;
        // proposal 1 now holds a choice with no bundle rows behind it.
        assert!(plan.needs_draft_setup);
        assert!(plan.needs_bundle_setup);
    }

    /// The same call before the round row exists: the sidecar refuses the
    /// write, and what must hold is that it reaches Swift as decodable typed
    /// JSON rather than as a panic or a bare message.
    #[test]
    fn set_ballot_intents_before_round_setup_is_a_typed_error() {
        let (_store, _dir, session) = open_session(0x28);
        let err = session
            .set_ballot_intents(vec![BallotIntentDto {
                proposal_id: 1,
                decision: DecisionDto::Choice { option: 0 },
            }])
            .unwrap_err();
        assert_eq!(error_kind(&err), "storage");
    }

    #[test]
    fn cancel_and_epoch_reach_the_control() {
        let (_store, _dir, session) = open_session(0x25);
        session.set_epoch(7);
        assert_eq!(session.control.operation_epoch(), 7);
        session.cancel();
        assert!(session.control.is_cancelled());
    }

    /// Every JSON string a run has handed the collecting sink so far.
    fn collected(seen: &Arc<std::sync::Mutex<Vec<String>>>) -> Vec<String> {
        seen.lock().expect("collected events").clone()
    }

    /// A sink with no callback drops events rather than calling through a
    /// null function pointer.
    ///
    /// Asserted against a collecting sink rather than on its own: that the
    /// call returns proves only that nothing crashed, so the same event is
    /// emitted through a sink that records it and then through the empty one,
    /// and what must hold is that the recorded vector does not grow.
    #[test]
    fn event_sink_without_a_callback_drops_events() {
        let event = SessionEventDto::DelegationProgress {
            progress: DelegationProgressDto {
                bundle_index: 0,
                stage: "proof_starting".to_string(),
                fraction: None,
            },
        };
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        EventSink::collecting(&seen).emit(&event);
        assert_eq!(collected(&seen).len(), 1, "the collecting sink recorded it");

        EventSink::none().emit(&event);
        assert_eq!(
            collected(&seen).len(),
            1,
            "a sink with no callback must record nothing"
        );
    }

    /// A cancelled session drives nothing: no plan is read and no endpoint is
    /// dialled, and the run says why it stopped rather than failing.
    #[test]
    fn run_on_cancelled_control_quiesces_cancelled_without_network() {
        let (_store, _dir, session) = open_session(0x31);
        let session = Arc::new(session);
        session.cancel();
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let report = session
            .run(
                HostOverridesDto::default(),
                Signer::None,
                DrivePolicyDto::default(),
                EventSink::collecting(&seen),
            )
            .expect("a cancelled run still reports");
        assert_eq!(
            serde_json::to_value(report.quiescence.kind).unwrap(),
            "cancelled"
        );
        assert!(
            collected(&seen).is_empty(),
            "a cancelled run reports no event"
        );
    }

    /// A seed the signer cannot derive from stops the call before anything is
    /// spawned, and reaches Swift as the typed envelope every other session
    /// failure uses rather than as a bare message.
    ///
    /// The message is asserted too, because the failure is wrapped on its way
    /// out: a wrap that did not check for an envelope first would put a
    /// serialized error where Swift shows text.
    #[test]
    fn run_with_a_software_seed_too_short_to_derive_is_a_typed_error() {
        let (_store, _dir, session) = open_session(0x35);
        let session = Arc::new(session);
        let err = session
            .run(
                HostOverridesDto::default(),
                Signer::Software(Zeroizing::new(vec![0u8; 8])),
                DrivePolicyDto::default(),
                EventSink::none(),
            )
            .unwrap_err();
        assert_eq!(error_kind(&err), "invalid_input");
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("typed JSON error");
        assert!(
            view.message.contains("seed must be at least"),
            "not the seed refusal in readable form: {}",
            view.message
        );
    }

    /// A fresh round with an undecided ballot: nothing is dispatchable, and the
    /// ballot is what the voter can still act on, so it outranks the bundle
    /// setup the round also owes. Nothing here reaches an endpoint.
    ///
    /// The events the run emitted are asserted as JSON rather than as views:
    /// what Swift decodes is the envelope, so this is where the
    /// `SessionEventDto::RoundDrive` shape is pinned down.
    #[test]
    fn run_on_an_undecided_ballot_quiesces_needs_ballot_and_streams_events() {
        let (_store, _dir, session) = open_session(0x32);
        let session = Arc::new(session);
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let report = session
            .run(
                HostOverridesDto::default(),
                Signer::None,
                DrivePolicyDto::default(),
                EventSink::collecting(&seen),
            )
            .expect("a round with no bundles still reports");
        assert_eq!(
            serde_json::to_value(report.quiescence.kind).unwrap(),
            "needs_ballot"
        );
        // The fixture roster, undecided: both proposals are the host's to
        // resolve before anything can be cast.
        assert_eq!(report.quiescence.open_proposals, vec![1, 2]);

        let events = collected(&seen);
        assert!(!events.is_empty(), "the run reported no event at all");
        for json in &events {
            let event: serde_json::Value = serde_json::from_str(json).expect("event JSON");
            assert_eq!(event["kind"], "round_drive");
            assert!(
                event["event"].is_object(),
                "a round_drive event carries the driver event: {json}"
            );
        }
        // The driver plans before it selects, so the first thing a host sees
        // is the plan the run will select from.
        let first: serde_json::Value = serde_json::from_str(&events[0]).expect("event JSON");
        assert_eq!(first["event"]["kind"], "plan_refreshed");
    }

    /// The same round once the ballot is terminal: the plan now owes bundle
    /// rows the run cannot create itself, which is the brief's expected
    /// handoff. Driven through a sink with no callback, which must be a no-op
    /// rather than a null call.
    #[test]
    fn run_with_a_decided_ballot_and_no_bundles_quiesces_needs_bundle_setup() {
        let (_store, _dir, session) = open_session(0x34);
        // Creates the round row (its `ensure_round` runs first) and then
        // refuses note selection on the empty wallet.
        session.setup_bundles().unwrap_err();
        session
            .set_ballot_intents(vec![
                BallotIntentDto {
                    proposal_id: 1,
                    decision: DecisionDto::Choice { option: 0 },
                },
                BallotIntentDto {
                    proposal_id: 2,
                    decision: DecisionDto::Skipped,
                },
            ])
            .expect("a terminal ballot over the bound roster");
        let session = Arc::new(session);
        let report = session
            .run(
                HostOverridesDto::default(),
                Signer::None,
                DrivePolicyDto::default(),
                EventSink::none(),
            )
            .expect("a round owing bundle setup still reports");
        assert_eq!(
            serde_json::to_value(report.quiescence.kind).unwrap(),
            "needs_bundle_setup"
        );
    }

    /// A round the sidecar holds no share for is quiescent on the first pass,
    /// and says so without reaching a helper.
    #[test]
    fn track_shares_with_nothing_pending_quiesces_immediately() {
        let (_store, _dir, session) = open_session(0x33);
        let session = Arc::new(session);
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let report = session
            .track_shares(
                HostOverridesDto::default(),
                ShareTrackingPolicyDto::default(),
                EventSink::collecting(&seen),
            )
            .expect("tracking a round with no shares still reports");
        assert_eq!(
            serde_json::to_value(report.quiescence.kind).unwrap(),
            "nothing_to_track"
        );
        // One pass, which found the round owing nothing and stopped: a second
        // would mean the driver waited on a helper it had no share for.
        assert_eq!(report.passes, 1);
        let events = collected(&seen);
        assert!(!events.is_empty(), "the pass reported no event at all");
        for json in &events {
            let event: serde_json::Value = serde_json::from_str(json).expect("event JSON");
            assert_eq!(event["kind"], "share_tracking");
            assert!(
                event["event"].is_object(),
                "a share_tracking event carries the driver event: {json}"
            );
        }
    }

    /// The round driver reads the session's host configuration on every
    /// dispatch, so a configuration pushed mid-run reaches the next one.
    ///
    /// Asserted against one host object throughout: a host that had captured
    /// its configuration at construction would keep answering with what the
    /// session was opened with, which is what the first `assert_ne!` rules
    /// out. The second write names no helpers, which must leave the pushed
    /// ones standing rather than restore the session's own.
    #[test]
    fn host_context_reads_the_latest_pushed_configuration_on_every_dispatch() {
        use zcash_voting::RoundHostSource;

        let (_store, _dir, session) = open_session(0x72);
        let session = Arc::new(session);
        let host = SessionHost {
            inputs: HostInputs {
                session: Arc::clone(&session),
            },
            delegation: None,
            max_proof_concurrency: 1,
        };
        let opened_with = host.host_context().configured_helper_urls;

        session.merge_host_overrides(HostOverridesDto {
            helper_urls: Some(vec!["https://helper.example/".to_string()]),
            ..Default::default()
        });
        assert_eq!(
            host.host_context().configured_helper_urls,
            vec!["https://helper.example/".to_string()]
        );
        assert_ne!(host.host_context().configured_helper_urls, opened_with);

        // A later write that names no helpers keeps the pushed ones.
        session.merge_host_overrides(HostOverridesDto {
            vote_tree_node_urls: Some(vec!["https://tree.example/".to_string()]),
            ..Default::default()
        });
        let context = host.host_context();
        assert_eq!(
            context.configured_helper_urls,
            vec!["https://helper.example/".to_string()]
        );
        assert_eq!(
            context.vote_tree_node_urls,
            vec!["https://tree.example/".to_string()]
        );
    }

    /// One host context is built from ONE read of the session's configuration
    /// slot, on both hosts.
    ///
    /// A context assembled from a read per field can mix two configurations
    /// that never co-existed: a merge landing between the ceremony-start read
    /// and the vote-end read produces a window whose start is the old one and
    /// whose end is the new one. The crate decides `is_last_moment()` from that
    /// pair, and that decision becomes the durable `single_share` property of a
    /// cast, so the mixed window is not a transient display value.
    ///
    /// Counting the reads is what makes the invariant testable at all: the four
    /// values of a correct context and of a mixed one are the same whenever no
    /// merge happens to land in between, so an assertion on values alone would
    /// pass on either. All four fields are merged first so that every one of
    /// them would show a stale read.
    #[test]
    fn a_host_context_is_built_from_one_snapshot_of_the_configuration_slot() {
        use std::sync::atomic::Ordering;
        use zcash_voting::{RoundHostSource, ShareTrackingHostSource};

        let (_store, _dir, session) = open_session(0x75);
        let session = Arc::new(session);
        session.merge_host_overrides(HostOverridesDto {
            helper_urls: Some(vec!["https://snapshot-helper.example/".to_string()]),
            vote_tree_node_urls: Some(vec!["https://snapshot-tree.example/".to_string()]),
            ceremony_start_seconds: Some(Some(3_000_000_000)),
            vote_end_time_seconds: Some(Some(4_000_000_000)),
        });

        let host = SessionHost {
            inputs: HostInputs {
                session: Arc::clone(&session),
            },
            delegation: None,
            max_proof_concurrency: 1,
        };
        session.live_host_reads.store(0, Ordering::SeqCst);
        let context = host.host_context();
        assert_eq!(
            session.live_host_reads.load(Ordering::SeqCst),
            1,
            "the round host read the configuration slot more than once for one context"
        );
        assert_eq!(
            context.configured_helper_urls,
            vec!["https://snapshot-helper.example/".to_string()]
        );
        assert_eq!(
            context.vote_tree_node_urls,
            vec!["https://snapshot-tree.example/".to_string()]
        );
        assert_eq!(context.ceremony_start_seconds, Some(3_000_000_000));
        assert_eq!(context.vote_end_time_seconds, Some(4_000_000_000));

        let tracking = ShareTrackingHost {
            inputs: HostInputs {
                session: Arc::clone(&session),
            },
        };
        session.live_host_reads.store(0, Ordering::SeqCst);
        let context = tracking.host_context();
        assert_eq!(
            session.live_host_reads.load(Ordering::SeqCst),
            1,
            "the share-tracking host read the configuration slot more than once for one context"
        );
        assert_eq!(
            context.configured_helper_urls,
            vec!["https://snapshot-helper.example/".to_string()]
        );
        assert_eq!(context.vote_end_time_seconds, Some(4_000_000_000));
    }

    /// The same slot, read by the other driver: share tracking sees a pushed
    /// helper fleet and a pushed vote end on its next pass.
    #[test]
    fn share_tracking_host_context_reads_the_latest_pushed_configuration() {
        use zcash_voting::ShareTrackingHostSource;

        let (_store, _dir, session) = open_session(0x73);
        let session = Arc::new(session);
        let host = ShareTrackingHost {
            inputs: HostInputs {
                session: Arc::clone(&session),
            },
        };
        let opened_with = host.host_context().configured_helper_urls;

        session.merge_host_overrides(HostOverridesDto {
            helper_urls: Some(vec!["https://tracking-helper.example/".to_string()]),
            ..Default::default()
        });
        assert_eq!(
            host.host_context().configured_helper_urls,
            vec!["https://tracking-helper.example/".to_string()]
        );
        assert_ne!(host.host_context().configured_helper_urls, opened_with);

        // A later write that names no helpers keeps the pushed ones.
        session.merge_host_overrides(HostOverridesDto {
            vote_end_time_seconds: Some(Some(4_000_000_000)),
            ..Default::default()
        });
        let context = host.host_context();
        assert_eq!(
            context.configured_helper_urls,
            vec!["https://tracking-helper.example/".to_string()]
        );
        assert_eq!(context.vote_end_time_seconds, Some(4_000_000_000));
    }

    /// A run merges its own overrides into the session's slot rather than
    /// carrying them alone, so what one run was driven with still holds for
    /// the next one — and a later run that names nothing keeps it.
    ///
    /// Driven on a cancelled session, which reaches no endpoint and reads no
    /// plan: what is under test is the merge the call performs before it
    /// spawns anything.
    #[test]
    fn a_runs_overrides_merge_into_the_session_slot_and_outlive_the_run() {
        use zcash_voting::RoundHostSource;

        let (_store, _dir, session) = open_session(0x74);
        let session = Arc::new(session);
        session.cancel();
        session
            .run(
                HostOverridesDto {
                    helper_urls: Some(vec!["https://run-helper.example/".to_string()]),
                    ..Default::default()
                },
                Signer::None,
                DrivePolicyDto::default(),
                EventSink::none(),
            )
            .expect("a cancelled run still reports");
        session
            .track_shares(
                HostOverridesDto::default(),
                ShareTrackingPolicyDto::default(),
                EventSink::none(),
            )
            .expect("a cancelled tracking run still reports");

        let host = SessionHost {
            inputs: HostInputs {
                session: Arc::clone(&session),
            },
            delegation: None,
            max_proof_concurrency: 1,
        };
        assert_eq!(
            host.host_context().configured_helper_urls,
            vec!["https://run-helper.example/".to_string()],
            "a later driver must still see what an earlier run was driven with"
        );
    }

    /// One Keystone-signed bundle, with PCZT bytes no signature can come out
    /// of: every assertion below refuses the batch before it reads them.
    fn signed_bundle(bundle_index: u32) -> KeystoneSignedBundleDto {
        KeystoneSignedBundleDto {
            bundle_index,
            signed_pczt: vec![0u8; 4],
        }
    }

    /// A batch names at least one bundle and never names one twice — in
    /// either direction of the Keystone flow. Both are the host's mistake and
    /// both are refused before the pipeline prepares anything.
    #[test]
    fn keystone_batches_reject_empty_and_duplicate_indices() {
        let (_store, _dir, session) = open_session(0x41);
        let refusals = [
            session.keystone_signing_requests(&[]).unwrap_err(),
            session.keystone_signing_requests(&[0, 1, 0]).unwrap_err(),
            session.store_keystone_signatures(vec![]).unwrap_err(),
            session
                .store_keystone_signatures(vec![signed_bundle(0), signed_bundle(0)])
                .unwrap_err(),
        ];
        for err in &refusals {
            assert_eq!(error_kind(err), "invalid_input");
        }
    }

    /// One scan against the wrong bundle must not cost the batch's good
    /// signatures. The conversion is the whole-batch gate: it returns the
    /// first refusal and no inputs at all, so `store_keystone_signatures_batch`
    /// is never reached and the bundle that did verify stays unsigned and
    /// rescannable.
    ///
    /// The refusal names its bundle on the envelope as well as in its text,
    /// which is what lets a host ask for that one QR again instead of the
    /// whole set.
    #[test]
    fn a_batch_with_one_signature_that_does_not_verify_yields_no_inputs_at_all() {
        let (good_request, good_sig) = keystone_request_signed([0x11u8; 32]);
        let (mut wrong_request, _) = keystone_request_signed([0x22u8; 32]);
        wrong_request.bundle_index = 1;
        let (_, someone_elses_sig) = keystone_request_signed([0x33u8; 32]);

        verified_signature_inputs(vec![(good_request.clone(), good_sig)])
            .expect("a batch whose every signature verifies converts");

        // A signature input carries the signature, the sighash and the
        // randomized key, so the failure says how many converted and no more.
        let err = match verified_signature_inputs(vec![
            (good_request, good_sig),
            (wrong_request, someone_elses_sig),
        ]) {
            Ok(inputs) => panic!(
                "one unusable signature must refuse the batch, not convert {}",
                inputs.len()
            ),
            Err(err) => err,
        };

        assert_eq!(error_kind(&err), "invalid_input");
        assert_eq!(error_bundle_index(&err), Some(1));
        assert!(err.to_string().contains("bundle 1"), "unexpected: {err}");
    }

    /// A round with no bundle rows has no request to build: the pipeline
    /// prepares the bundle first, and the fixture's wallet holds no note to
    /// prepare it from. What must hold is that the refusal is a condition the
    /// host can act on rather than an SDK invariant it can do nothing with.
    #[test]
    fn keystone_request_without_setup_is_a_typed_error() {
        let (_store, _dir, session) = open_session(0x42);
        let err = session.keystone_signing_requests(&[0]).unwrap_err();
        assert_empty_wallet_refusal(&err);
    }

    /// PIR precompute prepares the bundle before it warms a single row, so an
    /// empty wallet stops it at note selection — which is also how this test
    /// knows no endpoint was dialled: a fleet that had been contacted would
    /// report its own transport failure instead.
    #[test]
    fn precompute_pir_without_bundles_is_a_typed_error() {
        let (_store, _dir, session) = open_session(0x43);
        let err = session.precompute_pir(0).unwrap_err();
        assert_empty_wallet_refusal(&err);
    }

    #[test]
    fn delegation_progress_maps_variants_to_snake_case() {
        use zcash_voting::delegate::DelegationProgress;

        assert_eq!(
            progress_stage(&DelegationProgress::WaitingForExistingProof),
            "waiting_for_existing_proof"
        );
        assert_eq!(
            progress_stage(&DelegationProgress::ProofProgress(0.25)),
            "proof_progress"
        );
        assert_eq!(
            progress_fraction(&DelegationProgress::ProofProgress(0.25)),
            Some(0.25)
        );
        assert_eq!(progress_fraction(&DelegationProgress::ProofComplete), None);
    }

    /// The proving thread's failure path, which nothing else here covers: a
    /// bundle this round never set up. The pipeline refuses it while reading
    /// the wallet, so no endpoint is dialled, and what must hold is that the
    /// failure crosses the join as the typed envelope rather than as a panic
    /// or a hang.
    ///
    /// The stage the pipeline reports before it reads the wallet is what
    /// exercises the reporter, so the events are asserted as the JSON Swift
    /// decodes.
    #[test]
    fn precompute_delegation_proof_without_bundles_is_a_typed_error() {
        let (_store, _dir, session) = open_session(0x44);
        let session = Arc::new(session);
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let err = session
            .precompute_delegation_proof(0, EventSink::collecting(&seen))
            .unwrap_err();
        // The empty wallet's own refusal, which is also what says the fleet
        // was never reached: a dialled endpoint would have failed as its own
        // transport kind instead.
        assert_empty_wallet_refusal(&err);

        let events = collected(&seen);
        assert!(
            !events.is_empty(),
            "the proof step reported no progress at all"
        );
        for json in &events {
            let event: serde_json::Value = serde_json::from_str(json).expect("event JSON");
            assert_eq!(event["kind"], "delegation_progress");
            assert_eq!(event["progress"]["bundle_index"], 0);
            assert!(
                event["progress"]["stage"].is_string(),
                "a delegation_progress event names its stage: {json}"
            );
        }
    }

    /// A local listener that counts the connections it is offered. A session
    /// whose PIR or vote-tree traffic left the route would show up here.
    fn counting_listener() -> (String, Arc<std::sync::atomic::AtomicUsize>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.set_nonblocking(true).expect("nonblocking");
        let url = format!("http://{}/", listener.local_addr().expect("addr"));
        let accepted = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let seen = Arc::clone(&accepted);
        std::thread::spawn(move || {
            loop {
                match listener.accept() {
                    Ok(_) => {
                        seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    }
                    Err(_) => std::thread::sleep(std::time::Duration::from_millis(5)),
                }
            }
        });
        (url, accepted)
    }

    /// Every service a session touches rides the route it opened on.
    ///
    /// A route that refuses before dispatch stands in for a Tor route that
    /// cannot connect: PIR and vote-tree traffic must fail through it rather
    /// than reach the endpoint some other way, which the listener proves by
    /// counting the connections nothing was supposed to make.
    #[test]
    fn pir_and_vote_tree_traffic_take_the_session_route() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let (url, direct_connections) = counting_listener();
        let attempts = Arc::new(AtomicUsize::new(0));

        let store = open_memory_store(crate::NETWORK_ID_TESTNET, "routing-wallet");
        let (_dir, wallet_db_path, account_uuid) =
            temp_wallet_db_with_account(crate::NETWORK_ID_TESTNET);
        let mut inputs = synthetic_session_inputs(0x71, &wallet_db_path, &account_uuid);
        inputs.pir_endpoints = vec![url.clone()];
        inputs.vote_tree_node_urls = vec![url.clone()];
        let session = VotingSession::open(
            &store,
            inputs,
            synthetic_binding(2, None),
            SdkRoute::Refusing(Arc::clone(&attempts)),
            1,
        )
        .expect("open");

        assert!(
            session.pir.connect().is_err(),
            "the refusing route must fail PIR"
        );
        let after_pir = attempts.load(Ordering::SeqCst);
        assert!(after_pir >= 1, "PIR never reached the session's route");

        assert!(
            session.sync_vote_tree(&url).is_err(),
            "the refusing route must fail the tree sync"
        );
        assert!(
            attempts.load(Ordering::SeqCst) > after_pir,
            "vote-tree sync never reached the session's route"
        );

        std::thread::sleep(std::time::Duration::from_millis(100));
        assert_eq!(
            direct_connections.load(Ordering::SeqCst),
            0,
            "PIR or vote-tree traffic bypassed the session's route"
        );
    }

    /// A live session keeps its handle's root alive, so a handle that closes
    /// while the session still runs does not orphan the session's connection:
    /// a fresh handle opened afterward on the same path must still find it
    /// rather than opening a second one.
    ///
    /// The registry only tracks a `Weak` for each path (see `shared_root` in
    /// `store.rs`), so nothing but a live strong reference keeps an entry
    /// resolvable. `database` below is a *scoped* clone — a distinct
    /// `VotingDb` value, and so a distinct `Arc` allocation, over the same
    /// underlying connection — not a clone of the handle's root itself, so it
    /// cannot be what keeps the registry's entry alive; this test asserts the
    /// session provides that some other way.
    ///
    /// A `Weak` (rather than the store's own strong `root` field, which this
    /// module cannot reach — it is private to `store.rs`) is downgraded from
    /// [`VotingDatabaseHandle::shared_root_handle`] before the handle closes:
    /// this test must not itself hold a strong reference across the `drop`,
    /// or it would keep the entry alive regardless of what the session does,
    /// masking the very bug this test exists to catch.
    #[test]
    fn a_live_session_keeps_its_handles_root_alive_so_a_reopened_handle_shares_it() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("voting.sqlite3");
        let path = path.to_str().expect("utf-8 path");

        let store =
            VotingDatabaseHandle::open(path, crate::NETWORK_ID_TESTNET).expect("open store");
        store
            .set_wallet_id("session-keepalive-wallet")
            .expect("wallet id");
        let weak_root = Arc::downgrade(&store.shared_root_handle());

        let (_wallet_dir, wallet_path, account_uuid) =
            temp_wallet_db_with_account(crate::NETWORK_ID_TESTNET);
        let inputs = synthetic_session_inputs(0x91, &wallet_path, &account_uuid);
        let hotkey =
            zcash_voting::hotkey::generate_random_voting_hotkey(zcash_voting::Network::Testnet)
                .expect("hotkey")
                .stored_secret()
                .to_vec();
        let session = VotingSession::open(
            &store,
            inputs,
            synthetic_binding(2, Some(hotkey)),
            SdkRoute::direct(),
            1,
        )
        .expect("open session");

        drop(store);

        let kept_alive = weak_root
            .upgrade()
            .expect("a live session must keep its handle's root alive after the handle closes");

        let second = VotingDatabaseHandle::open(path, crate::NETWORK_ID_TESTNET)
            .expect("a fresh handle on the same path must still open while the session lives");
        assert!(
            Arc::ptr_eq(&second.shared_root_handle(), &kept_alive),
            "a handle reopened while a session lives must share the session's root"
        );
        // Keeps the session alive to the end of the test on purpose, so it is
        // still what is holding `kept_alive` up to the assertion above.
        drop(session);
    }
}
