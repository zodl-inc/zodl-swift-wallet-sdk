# Changelog
All notable changes to this library will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this library adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Fixed

- Refused stale migration submissions now persist recovery state: `zcashlc_migration_advance_step` returns Reevaluate
  until scanning reaches the higher observed wallet/server tip, then resumes the existing interruption
  or rebuild handling. No transaction is submitted or recorded in the wallet, and caller signatures
  are unchanged.

### Added

- `zcashlc_slipstream_stop_for_wallet_change(handle)`, the stop to call right before changing the
  wallet (adding or removing an account, a rewind, a wipe, or reopening a handle on the same
  wallet). It asks the running session to end its scan at the next block, then stops exactly as
  `zcashlc_slipstream_stop` does and returns the same `FfiSlipstreamStopReport`. Refuse the change
  unless `settled` and `drained` are both 1. `zcashlc_slipstream_stop` lets a scan call in progress
  run to the end of its chunk first, which can outlast its ten-second budget.
- `zcashlc_check_transaction_submittable(db_data, db_data_len, network_id, tx, tx_len,
  submission_server_height)` reports whether a raw transaction can be valid in the next block, so that nothing is
  submitted that no block can include. The next block is the one after the higher of the wallet's chain tip and
  `submission_server_height`, the latest block height of the server the transaction is about to be submitted to (a wallet
  that has no chain tip yet is judged by the server's height alone). It returns `0` when the transaction can be valid
  there, `1` when it is built for another consensus branch than that block's, `2` when it has expired by then (an expiry
  height of 0 never expires), and `-1` with the last error set when it cannot judge: `submission_server_height` is negative or
  no block height, which fails closed, no block can follow it, the network is unknown, the wallet database does not exist
  or cannot be read, or `tx` is no transaction. The branch is compared only for a v5 or later encoding, the only one that
  commits to a consensus branch; an earlier one has just its expiry judged. The wallet database is opened read-only, and
  nothing is written to it. These validity checks apply at every height.
- `zcashlc_payment_uri_parse` validates supported cross-chain payment request URIs and returns an
  internal JSON envelope for SDK bindings.
- `zcashlc_parse_gift_card_link(link, error_out)` reads a gift card link — any `https` URL whose
  fragment carries a `v=1` card (`#v=1&key=…&height=…`) or the legacy JSON payment-link encoding at
  `/payment-links/open#vN=` — without touching a database or the network, and returns an
  `FfiGiftCardLink`: its `origin` (`FfiGiftCardOrigin`: `V1`, `LegacyV1`, `LegacyV2`, `LegacyV3`),
  `network_id` (`0` testnet, `1` mainnet; regtest cards are refused), `birthday_height` (never
  below the network's NU5 activation height), the informational amount (`has_amount`/`amount`, in
  zatoshis), a nullable `description` (sanitized: control whitespace becomes a space, other
  control and invisible formatting characters such as bidi overrides are removed), the card
  wallet's Orchard-only `funding_address`, and the 64-byte BIP 39 `seed` of the card wallet (ZIP 32
  account 0). Free it with `zcashlc_free_gift_card`, which zeroes the seed. On failure it returns
  null, writes the reason to `error_out` when that is non-null, and sets the last error; neither
  contains any part of the link, which carries a spending secret. The reason is a stable
  `FfiGiftCardLinkError`: `NotAGiftLink`, `UnsupportedVersion`, `WrongNetwork` (regtest or an
  unknown network), `InvalidBirthday` (malformed, or below NU5 activation) or `InvalidLink`
  (anything else).
- `zcashlc_set_transaction_trust(db_data, db_data_len, txid_bytes, txid_bytes_len, trusted,
  network_id)` marks a stored transaction as trusted or untrusted in the sense of ZIP 315
  (`WalletWrite::set_tx_trust`): the outputs of a trusted transaction become spendable after the
  confirmations policy's `trusted` count even though this wallet did not produce them. The
  transaction must already be stored (for instance through `zcashlc_decrypt_and_store_transaction`,
  which stores nothing for a transaction that does not involve the wallet). Returns `true` on
  success, `false` with the last error set otherwise, including for a txid the wallet has not
  stored, so `true` always means the status was recorded.
- `zcashlc_proposal_requires_sapling_params(proposal_ptr, proposal_len)` reports, without a
  database, whether creating a proposal's transactions needs the Sapling proving parameters: `1`
  when any step has a Sapling input, payment, change or dummy output (or leaves a pool
  unspecified), `0` otherwise, and `-1` with the last error set when the proposal does not decode.

- `zcashlc_tor_http_get_with_timeout` adds an HTTP GET entry point whose trailing positive
  `timeout_ms` bounds the complete Tor operation, including connection setup, retries, and response
  body collection. It otherwise accepts the same arguments and returns the same response as
  `zcashlc_tor_http_get`; expiry or an invalid zero timeout returns null with the thread-local error
  set. Existing GET and POST call sites require no changes.
- Ledger hardware-wallet signing over Bluetooth LE, through `zcashlc_ledger_*` entry points over the
  `pczt_ledger` engine. The engine performs no I/O: every function here builds a command or parses a
  reply, and the caller moves the bytes. A reply passed in is always the raw transport payload, data
  followed by the two-byte status word.
  - Errors: every `zcashlc_ledger_*` failure (null / `false` / `-1`) is read with
    `zcashlc_ledger_take_last_error`, which returns `FfiLedgerError` (free with
    `zcashlc_ledger_free_error`) and clears the last error exactly as `zcashlc_clear_last_error`
    does. `kind` is a stable `u32`: `0` internal, `1` user rejected, `2` wrong app, `3` app too old,
    `4` device mismatch, `5` caps mismatch, `6` derivation budget exhausted, `7` device refused,
    `8` transaction not signable, `9` malformed reply, `10` invalid input, `11` command not
    accepted (`0x6901`, resend the identical command after a 50 ms backoff). `status_word` is valid
    when `has_status_word` is set; `is_transient` and `is_restartable` say whether the device
    condition can clear and whether a fresh ceremony could succeed. `reason` never carries APDU or
    reply bytes, a PCZT, a viewing key, an address, a device identity or a signature.
  - Transport policy, taken from the engine so a platform runner applies the same one:
    `zcashlc_ledger_max_cmd_not_accepted_retries` (resends allowed after consecutive `0x6901`
    refusals of one command), `zcashlc_ledger_cmd_not_accepted_backoff_ms` (the pause before each
    resend) and `zcashlc_ledger_default_timeout_ms` (the timeout for a reply that does not wait on
    the user).
  - App version: `zcashlc_ledger_firmware_version_apdu`, and `zcashlc_ledger_parse_app_version`
    returning `FfiLedgerAppVersion` (`major`, `minor`, `patch`, `supports_pczt`; free with
    `zcashlc_ledger_free_app_version`).
  - Device identity: `zcashlc_ledger_device_identity_apdu(network_id)`,
    `zcashlc_ledger_parse_device_identity` returning the `tpk0-…` string (free with
    `zcashlc_string_free`), and `zcashlc_ledger_validate_device_identity`.
    `zcashlc_ledger_check_account_zero_identity(network_id, ufvk, identity)` returns `true` when
    the transparent item of `ufvk`, the exported key of ZIP 32 account 0, derives the public key
    that `identity` hashes. It returns `false` with kind `4` (device mismatch) when it does not,
    kind `9` (malformed reply) when `ufvk` has no transparent item, and kind `10` (invalid input)
    when an input does not parse. The key of any other account never derives the identity, so the
    check applies to account 0 only.
  - Viewing key export: `zcashlc_ledger_ufvk_export_new(network_id, account_index)` returns an
    opaque `FfiLedgerUfvkExport` driven by `_next_apdu`, `_waits_for_user` and `_process_response`,
    which returns `FfiLedgerUfvkExportStep` (`status` is one of the
    `ZCASHLC_LEDGER_UFVK_EXPORT_*` constants; `ufvk` is set on completion; free with
    `zcashlc_ledger_free_ufvk_export_step`, which wipes the key). The export is terminal on any
    error but `0x6901`, so a declined export cannot be re-issued. Free the handle with
    `zcashlc_ledger_free_ufvk_export`.
  - Address display: `zcashlc_ledger_unified_address_apdu(network_id, account_index,
    transparent_address_index, display)` and `zcashlc_ledger_parse_unified_address`, which returns
    the encoded unified address holding only the account's Orchard receiver at diversifier index 0.
    `zcashlc_ledger_device_unified_address(network_id, ufvk)` returns the address the device
    displays for the account whose viewing key is `ufvk` (free with `zcashlc_string_free`): the
    external Orchard receiver at diversifier index 0, alone, encoded exactly as
    `zcashlc_ledger_parse_unified_address` encodes the device's reply, so the two strings are equal
    when the device shows the address of that key. It returns null with kind `10` (invalid input)
    when `ufvk` does not parse, is for another network, or has no Orchard item.
  - BLE framing: `zcashlc_ledger_ble_mtu_request`, `zcashlc_ledger_parse_ble_mtu_response`
    (the frame size, or `-1`), `zcashlc_ledger_ble_frames` returning `FfiLedgerFrames` of
    `FfiLedgerFrame` (free with `zcashlc_ledger_free_frames`, which wipes them), and an opaque
    `FfiLedgerBleDeframer` (`zcashlc_ledger_ble_deframer_new`, `_push`, `_reset`,
    `zcashlc_ledger_free_ble_deframer`). `_push` returns a boxed slice with a null pointer while
    more frames are expected and the complete reply on the last one.
  - Signing: `zcashlc_ledger_sign_session_new(db_data, db_data_len, network_id,
    account_uuid_bytes, pczt, pczt_len, device_identity, zip32_account_index, firmware_reply,
    firmware_reply_len)` returns an opaque `FfiLedgerSignSession`. It loads the account's viewing
    key from the wallet database, stamps BIP 44 derivations on transparent inputs that pay the
    account's derived addresses and carry none, redacts the PCZT to the full signer view, marks a
    single transparent output paying the account's internal (change) address as change, and runs
    every pre-flight check before any command exists. `_next_step` returns `FfiLedgerSignStep`
    (free with `zcashlc_ledger_free_sign_step`, which wipes the command): `kind` is a
    `ZCASHLC_LEDGER_SIGN_STEP_*` constant, `apdu` the command to send, `waits_for_user` whether its
    reply may wait on the user, `starts_review` whether it opens the on-device review (reported
    once), `stage` a `ZCASHLC_LEDGER_STAGE_*` constant, and `stream_acknowledged` / `stream_total`
    the streaming progress. `_process_response` returns a `ZCASHLC_LEDGER_SIGN_STATUS_*` constant
    or `-1`; `_finish` returns the signed PCZT once, for `zcashlc_extract_and_store_from_pczt`
    alongside the proven PCZT. Free the handle with `zcashlc_ledger_free_sign_session`.
- The coinholder-voting C surface for driving a round. Requests and reports cross as UTF-8 JSON in
  an `FfiBoxedSlice` (freed with `zcashlc_free_boxed_slice`), and every failure records a
  `VotingErrorView` JSON object as the thread's last error, so a caller branches on its `kind`
  rather than on message text.
  - Process setup: `zcashlc_voting_configure` fixes the proving policy for the process from a
    JSON policy — `0` when this call fixed it, `1` when one was already fixed, `-1` on error.
    Unset, it defaults to one CPU worker per available core and one heavy proof or keygen job at
    a time; a host that raises the heavy-job ceiling accepts the memory cost.
    `zcashlc_voting_validate_round_id` reports whether a round id is a canonical field encoding,
    without touching a database.
  - Store operations on an open `VotingDatabaseHandle`, for the reads and destructive edits a
    screen performs outside a round: `zcashlc_voting_round_plan` (the plan for one round against
    the caller's authenticated proposal roster), `zcashlc_voting_pending_share_rounds` (the
    rounds still owing helper-share delivery), `zcashlc_voting_reset_vote_tree`,
    `zcashlc_voting_reset_session_state` (drops the cached tree state and the locally prepared
    UNSIGNED delegation setup, so an abandoned Keystone request can be rebuilt; proved or
    submitted bundles, imported capabilities and stored signatures are untouched, and an empty
    round id drops only the cached tree state, wallet-wide, clearing no persisted column),
    `zcashlc_voting_delete_round`, `zcashlc_voting_retry_blocked_combined_cast` and
    `zcashlc_voting_clear_ballot_intents`.
  - Round sessions. `zcashlc_voting_session_open` takes the handle, the round inputs and binding
    as JSON, an optional `TorRuntime` and the host's operation epoch, and returns a
    `VotingSessionHandle` freed with `zcashlc_voting_session_free`. It performs no network I/O,
    so a bad round configuration is reported immediately rather than through a timeout. The
    session then drives the round: `zcashlc_voting_session_{plan, set_ballot_intents,
    setup_bundles, eligibility, sync_vote_tree, precompute_pir, precompute_delegation_proof,
    keystone_signing_requests, store_keystone_signatures, run, track_shares, cancel, set_epoch,
    update_host_configuration}`.
    `_run` and `_track_shares` block for the whole drive — minutes on a round with proofs to
    generate — and stream progress to an optional host callback that is invoked on runtime
    worker threads, possibly concurrently, and must not block; the event stream is lossy by
    design and the returned report is authoritative. One run at a time per session.
    `_sync_vote_tree` takes the session handle and a node URL — no database handle and no round
    id, because the session is already bound to a round — blocks for the sync, and returns the
    height synced to, or -1 on error.
  - A session holds one service configuration — the helper fleet, the vote-tree nodes and the
    round's timing — over the inputs it was opened with, and both drivers read it on every
    dispatch rather than capturing it when a run starts.
    `zcashlc_voting_session_update_host_configuration(session, host_json, host_json_len)` merges
    a `HostOverridesDto` into it and returns 0, or -1 with `VotingErrorView` JSON in the
    last-error slot for a null handle or a payload it cannot parse. It takes that configuration's
    own lock alone, so it returns at once even while `_run` or `_track_shares` is blocked, and a
    fleet pushed mid-run reaches that run's next dispatch. Every writer merges field by field: a
    field the JSON names replaces the current value, one it leaves absent keeps whatever is in
    place — `{}` changes nothing, and a zero-length payload is not a JSON document and is
    refused. The `host_json` of `_run` and `_track_shares` is merged in the same way once the
    call's own arguments have decoded and before its signer is built, so it holds for the session
    rather than for that one call — including when the call then fails, as `_run` does on a seed
    it cannot build a signer from. Nothing rolls that merge back; a caller that wants a later call
    driven against the values the session was opened with names those values on it.
  - The route a session is opened on governs every service it touches for the session's whole
    life — chain and helper traffic, PIR queries and vote-tree sync: a null `TorRuntime` is the
    direct HTTP route, and a Tor runtime is used through an isolated client, never falling back
    to a direct connection when Tor cannot connect. A PIR query hides which rows are fetched, not
    who fetches them, so a Tor session fails closed for all four rather than letting any of them
    show the PIR server or the tree node the device's address.
  - Delegation signing is stated per run. A software wallet passes its seed, which reaches the
    SDK's signer for that call only and never returns to the caller as a sighash, randomizer or
    PCZT; a Keystone wallet exchanges per-bundle signing requests through
    `zcashlc_voting_session_keystone_signing_requests` and
    `zcashlc_voting_session_store_keystone_signatures`, and later runs reuse the stored
    signatures. `_store_keystone_signatures` reads every response and verifies it against the
    request it answers before it stores any of them: bytes that are not a signed PCZT carrying a
    spend-authorization signature, and a signature that does not sign its bundle's current signing
    request, both fail the call as `invalid_input` and store nothing of the batch, leaving that
    bundle rescannable. The error JSON's `bundle_index` names the bundle whose response was
    refused. Nothing replaces a stored signature — the first one stored for a bundle is the one it
    keeps — so this is where a wrong response has to be stopped. A run with no signer reports the
    bundles that owe one instead of dispatching them.
  - `zcashlc_voting_hotkey_from_stored_secret` derives the `FfiVotingHotkey` a stored secret
    describes, for a network id, so a caller that persisted only the secret can hand the SDK the
    full hotkey again. Free with `zcashlc_voting_free_hotkey`.
  - The plan JSON of `zcashlc_voting_round_plan`, `zcashlc_voting_session_plan` and
    `zcashlc_voting_session_set_ballot_intents` carries one key beside the crate's own, at the
    same level: `has_legacy_in_flight_submission` (bool). It is true when the round holds a
    delegation or a vote this wallet built that an older SDK dispatched and never saw confirmed.
    Opening a sidecar written by that SDK migrates it in place and keeps every row, but the 5.x
    chain lifecycle owns only the submissions it reserved itself, so such a transaction gets no
    lifecycle row and resuming it is unsupported: the driver plans an advance step and re-dispatches
    the same transaction, rebuilt from its persisted inputs and re-signed over the stored sighash —
    so the bytes need not be identical — with nothing promised about the outcome. Read it before bundle
    setup, precompute or `_run`, and drive no such round. A delegation imported from a capability
    package is excluded and reports false: its transaction was broadcast elsewhere, the lifecycle
    adopts the hash rather than sending anything again, and the round is driven normally. The plans
    nested in a run report and in the event stream are the crate's view unchanged and carry no such
    key, so a caller that must gate on it reads one of the three calls above.

- `zcashlc_take_last_error_report`, `zcashlc_free_error_report`, and `FfiErrorReport` expose the
  most recent error as a classified, redacted report. `kind` is an `ErrorKind` discriminant
  (`u32`): `0` is unclassified, `1` scan required, `2` insufficient funds; the remaining values are
  listed in `rust/src/error_report.rs`. `message` never carries an amount, address, note identifier,
  or txid. `available` and `required` are zatoshis, fee included, and are `-1` unless `kind` is `2`.
  Taking the report clears the last error exactly as `zcashlc_clear_last_error` does, so a caller
  reads either the report or the string for one failure, never both. An error raised by a call site
  that does not classify is reported as kind `0` with a generic message. The pointer is null when
  there is no error and must be freed with `zcashlc_free_error_report`.
- `zcashlc_get_transaction`, `zcashlc_free_transaction_data`, and `FfiTransactionData` expose the
  serialized bytes and expiry height available for any wallet-store transaction without depending
  on the transaction-history projection.
- Pool-migration (Orchard→Ironwood) FFI: 33 `zcashlc_migration_*` entry points with their
  `#[repr(C)]` return types and `zcashlc_free_migration_*` destructors, plus
  `zcashlc_ironwood_activation_height`. Each call takes the wallet-db path, a 16-byte account uuid
  and a network id, opens the wallet database and the account-keyed migration store, and reports
  failure through the thread-local last-error channel with `NULL` / `false` / `-1` sentinels. Two
  stable message prefixes name the actionable conditions: `MIGRATION_PLAN_STALE` and
  `MIGRATION_PROVING_UNAVAILABLE`.
  - State: `zcashlc_migration_advance_step` (drives upstream `advance_migration` and marshals its
    decision into `FfiMigrationAdvanceStep`, freed by
    `zcashlc_free_migration_advance_step`; `NULL` with no last error means no run is stored; the
    step discriminants are exported as `ZCASHLC_ADVANCE_STEP_*` constants; upstream `Reevaluate`
    and `Replan` map to the compatibility `_ATTEND` case; a `Prove` step's `kind_*` fields moved
    off the step itself onto `FfiProveTarget` rows — `prove_targets`/`prove_targets_len`, freed by
    the step's own destructor — one per transaction of the WHOLE provable batch upstream now
    serves in one call; `id` is `0` for `Prove`, the batch entries carrying their own; the step now
    also carries the engine's advisory OUTLOOK (upstream #2936, `Advance::next`) as
    `next_height`/`next_kind` — the earliest target height and kind of the migration's next
    serviceable work, assuming the served step is executed and recorded, `next_height = -1` when
    nothing is height-schedulable — with the kind exported as the `ZCASHLC_STEP_KIND_*` constants,
    a verbatim mirror of upstream `state::StepKind`), `_progress`,
    `_is_note_split_needed`, `_has_overdue_transfers`, and `_has_invalid_transfers` (true iff the
    NON-terminal stored run holds an engine-`Invalid` or expired-unmined transaction; a cancelled
    run answers `false`).
    `_advance_step` and `_has_overdue_transfers` take an
    `estimated_tip: i64` parameter (`-1` = disabled) evaluated under the upstream engine's
    `DuenessTargets` rule: the estimate may only ACCELERATE scheduled-height due-ness, expiry and
    boundary settledness stay on the SCANNED tip, and a broadcast whose expiry only the ESTIMATED
    target has passed is withheld (protective, reversible) without ever being treated as expired.
  - Sync scheduling: `zcashlc_migration_sync_wakeups` returns `FfiMigrationSyncWakeups` (freed by
    `zcashlc_free_migration_sync_wakeups`) — the stored run's minimal sync/proving wake-up schedule
    as of the scanned tip, jitter re-drawn on every call; `_block_rate_samples` returns
    `FfiBlockRateSamples` (freed by `zcashlc_free_migration_block_rate_samples`) — up to `window`
    most-recently-scanned `(height, header time)` rows, ascending, the raw input a wall-clock
    chain-tip estimator projects from (a missing wallet-database file, like a missing `blocks`
    table, is the benign empty answer, and a coerced read failure is logged rather than silent);
    both read-only/local-database-only. There is no repair entry point: every repair is the
    engine's, performed inside `advance_migration` — a funding note spent outside the migration is
    discovered by the satisfiability oracle from scanned wallet data, a recorded broadcast is
    promoted to mined, and a transaction this process submitted whose broadcast was never recorded
    (a crash, or a failed persist, between submitting and recording) is recognized by the id the
    engine derived when it BUILT it and promoted just the same.
  - Batching: `zcashlc_migration_batch_pczts_by_actions` (pure, no wallet database) splits an
    ORDERED array of transaction action-weights (16 per preparation, 3 per transfer) into signer
    sessions bounded by a caller-supplied action budget, returning `FfiMigrationBatchSizes` (freed by
    `zcashlc_free_migration_batch_sizes`) — the per-session transaction COUNTS, summing to the input
    length, for the caller to re-slice its own ordered PCZT array by.
  - Note split: `zcashlc_migration_prepare_note_split`, `_sign_note_split`. The latter's
    handback — the first note-split transaction, proved now and returned for immediate broadcast —
    goes through the same atomic broadcast seam as the delivery executor, so its artifact is
    likewise the finalized consensus transaction rather than a PCZT.
  - Proposal and commit: `zcashlc_migration_residual_after_migration`, `_propose_transfers`,
    `_sign_and_store_schedule`. Committing a plan is linear in the wallet's note count: the
    upstream `wallet::WalletMigration` adapter these calls run over snapshots its spendable-note
    selection per adapter (librustzcash #2946), and the FFI builds one adapter per call.
  - Proving: `zcashlc_migration_prove_transactions(ids, ids_len, max_proofs)` proves the
    transactions the caller NAMES — the batch a prior `_advance_step` returned as its PROVE step —
    and returns `FfiMigrationProveOutcome` (freed by `zcashlc_free_migration_prove_outcome`,
    `NULL` = error): `total_proved` plus `preparation_txids`/`preparation_txids_len`, a heap array
    of raw 32-byte txids naming THE PREPARATIONS IT PROVED and nothing else. A transfer's txid is
    never returned, because appearing in that array means "retrievable through
    `_take_preparation_by_txid`", and a transfer is delivered by the drive's BROADCAST instruction
    alone. Like the delivery executor it never cranks the
    engine: `advance_migration` is the top-level call, and there is no proving to do without an
    instruction saying what to prove. Per row, a transaction that is no longer `Signed` is a SKIP
    rather than an error (a stale instruction is safe — the engine re-offers un-recorded work on
    the next crank), as is one whose anchor is not yet scanned or retained; every successful proof
    persists through the store seam. `max_proofs <= 0` means unlimited, and a platform that
    serializes database access behind one actor can pass `1` and loop, chunking a sweep without
    re-cranking between chunks. Call it from the sync path.
  - Preparation retrieval: `zcashlc_migration_take_preparation_by_txid(txid_ptr)` serves the
    proved PREPARATION with that 32-byte raw txid, returning the same `FfiPreparedTransfer` the
    delivery executor does (freed by `zcashlc_free_migration_prepared_transfer`) — finalized
    consensus transaction bytes, the row's stored txid, and the ENGINE TRANSFER ID, so the caller
    closes the loop through the existing `_record_transfer_result` — the same `Proved -> Broadcast`
    mark the delivery executor's success path makes — with no identity of its own. A proved
    preparation is a complete PCZT and its submission is the platform's ORDINARY path, not the engine's delivery ceremony: preparations are ZIP 318-exempt, and the engine's
    contract is that a preparation is broadcast as soon as it is proved. The accessor IS the take
    seam, not a byte read — `txid -> row -> PoolMigrations::take_transaction_for_broadcast` in one
    database transaction, so the wallet's record binds AT RETRIEVAL and a crashed consumer
    re-retrieves the same bytes over the same record. It is PREPARATION-GATED: a transfer's txid
    is refused ("transfers are served by the drive's broadcast instruction alone"), bare, before
    the seam is reached, as an unknown txid is — both are questions about WHICH row was named, not
    about whether an artifact can be made servable, so neither carries
    `MIGRATION_PROVING_UNAVAILABLE`. The seam's own refusal of a non-`Proved` row remains the
    readiness gate. Retrieved-but-never-submitted is a bounded, engine-modelled state: the record
    is idempotent, the preparation carries a ZIP 203 expiry, and an unsubmitted row surfaces
    through the ordinary attention path once it expires. Submitted-but-never-marked is bounded
    too, and is the ACCIDENT rather than the ordinary path now that the caller marks: the engine
    promotes any in-flight transaction its scan sees mine, by the id it stored when it BUILT the
    transaction.
  - Delivery: `zcashlc_migration_take_broadcast_transaction` serves the transaction the caller
    NAMES — the instruction a prior `_advance_step` returned as its BROADCAST step. It never
    proves and never cranks the engine: `advance_migration` is the top-level call and every
    executor is subservient to it, so there is no broadcast to make without having first been
    instructed to make it, and the re-spread, the satisfiability verification and the dueness
    judgement all belong to that advance. Serving goes through the store's atomic broadcast seam
    (`PoolMigrations::take_transaction_for_broadcast`), which finalizes and extracts the
    transaction and records it in the wallet's own tables — raw bytes, sent outputs, input-spend
    marks, status-queue entry — in the same database transaction that hands the bytes back, so the
    wallet record binds at the broadcast attempt rather than after it. `FfiPreparedTransfer`'s
    `pczt`/`pczt_len` therefore carry the FINALIZED CONSENSUS TRANSACTION bytes, submittable as-is.
    The seam's own refusal of a row that is not `Proved` is the STALENESS GUARD — an instruction
    that went stale between the advance and the serve fails here rather than being acted on, and
    the caller discharges it by advancing again. `FfiPreparedTransfer` accordingly loses its
    `status` field and `FfiPreparedTransferStatus` is gone: an executor either serves or errors, so
    there is no "nothing due"/"awaiting proof" shape left to carry. WHETHER a missing proof is what
    blocks delivery is now reported on the advance step itself — each `FfiProveTarget` row gains a
    trailing `schedule_due` bool, true when the effective dueness target has already reached that
    transaction's scheduled height. Then `_record_transfer_result` (whose terminal tags — 2
    invalid, 3 expired — record `report_broadcast_failure` testimony stamped at the observed
    wallet tip; the next drive call adjudicates it through sqlite's satisfiability oracle, while
    unknown and already-mined rows remain no-ops), and `_record_immediate_run`, which records a
    send-max sweep built outside the engine.
  - Read-only reporting: the query that CANNOT drive the engine (it opens read-only connections
    and must not mutate) — `_has_overdue_transfers` — derives its answer from upstream's public
    per-row status view (`MigrationState::transaction_statuses`) instead of the exported
    broadcast/prove queue
    selectors. Only the DERIVATION moves; every answer is unchanged. The view agrees with the
    kernel's queues by construction and renders the doomed-broadcast withhold as neither ready nor
    actionable, so the protective withhold and the `Signed`/awaiting-signature exclusions hold
    exactly as before; and the engine's broadcast-before-prove precedence is preserved explicitly —
    the two-tier derivation takes the broadcast-ready `(scheduled_height, id)`-min first and reaches
    the still-unproved rows only when that tier is empty, exactly as upstream
    `MigrationState::next_step` consults its own two queues. What IS gone is the scratch-clone
    VIRTUAL PROVE behind `_has_overdue_transfers` (a
    `MigrationState` was cloned and every prove-ready row flipped `Proved` in memory, just to ask
    what would then be broadcastable): dependency readiness is keyed on `Mined`, never `Proved`, so
    proving can unblock nothing, and one pass per tier over the statuses gives the same answer the
    clone did. The ordering key within each tier is re-derived rather than read off the engine —
    the SDK's one accepted drift risk here, recorded on librustzcash #2938. It remains an
    ADVISORY display read: no store-oracle verification happens on it, so it never promises
    what the next delivery call will serve.
  - Recovery: `zcashlc_migration_restart_step`, and `_refresh_stale_transfers`, which rebuilds every
    expired transfer of the stored run and returns the full stored schedule, persisting
    all-or-nothing (NULL on any error).
  - External signer: `zcashlc_migration_create_unsigned_note_split_pczts`,
    `_store_signed_note_split_pczts`, `_create_unsigned_transfer_pczts`,
    `_store_signed_schedule_pczts`.
  - Residual locking: `zcashlc_migration_lock_residual` returns the total locked zatoshi (`0` is a
    valid "nothing was spendable"); `_unlock_residual` returns the cleared-output count.
  - Estimation: `zcashlc_migration_estimate_runs` returns `FfiMigrationRunEstimate` (a per-run
    `FfiRunEstimate` plus the final residual), freed by `zcashlc_free_migration_run_estimate`. A
    zero balance is the zero-run estimate, not an error. `FfiRunEstimate` gains trailing `actions`
    (the signing workload in Orchard-family actions: 16 per preparation transaction, 3 per transfer)
    and `keystone_rounds` (the Keystone-class signing-round count the optimal `MinRounds` packing
    computes for the run) fields.
  - Status: `zcashlc_migration_transaction_statuses` returns one row per committed migration
    transaction — stable id, kind, lifecycle state, scheduled/expiry/mined heights, the broadcast
    txid while in mempool, readiness, next action, blocking reason, the `depends_on` heap array of
    ids that must mine first, `anchor_boundary` (the bucketed boundary a TRANSFER's anchor was
    drawn against; `-1` always for a preparation), and a trailing compatibility `invalid_reason`.
    Upstream unsatisfiability marks and open broadcast-failure reports project to state `5` /
    blocker `6` without changing the Swift ABI — freed by
    `zcashlc_free_migration_transaction_statuses`. No stored run yields an empty container.
  - `FfiMigrationSchedule` gains a trailing `preparations`/`preparations_len` heap array of
    `FfiMigrationPreparationStep` (id, layer, index, broadcast height, and the whole preceding
    layer's ids as its `depends_on`) — the note-preparation transactions of the same plan, which the
    transfer rows alone do not surface.
- The echo parameters on the commit calls (`ids`, `amounts`, heights and duration on the schedule
  commits; `output_values` and `fee` on the note-split commit) are verified consent echoes, checked
  against the previewed plan or, once committed, the stored state. A mismatch surfaces
  `MIGRATION_PLAN_STALE`, so a stale or tampered display cannot sign values the user did not
  approve. Next-executable heights are compared only against the previewed plan; anchor heights are
  display-only.
- Every transfer amount the FFI reports is the value that CROSSES into Ironwood — one of the round
  `{1,2,5}×10ⁿ` denominations the run was planned in, and the amount the destination balance grows
  by — not the larger spend-side note value.
- Keystone batch-signing UR bridge:
  `zcashlc_migration_keystone_build_sign_batch_qr_parts` redacts each PCZT for the batch-signer role
  and returns animated `"zcash-sign-batch"` UR frames in `FfiKeystoneQrParts` (freed by
  `zcashlc_free_migration_keystone_qr_parts`), taking one ordered PCZT array with preparations first;
  `_keystone_reset_sign_batch_decoder` (void, infallible) and `_keystone_decode_sign_batch_part`
  (`FfiKeystoneBatchDecodeResult`, freed by
  `zcashlc_free_migration_keystone_batch_decode_result`) drive the multi-frame scan session and
  report the device's firmware version on completion, erroring on a request-id mismatch; and
  `_keystone_apply_batch_signatures` applies the response's signatures positionally to the caller's
  unsigned PCZTs, erroring if the counts disagree.
- `zcashlc_migration_create_unsigned_note_split_pczts` and `_create_unsigned_transfer_pczts` return
  PCZTs carrying the account's ZIP 32 spend derivation on every spend still awaiting a signature,
  across the Orchard and Ironwood bundles alike. Without it Keystone rejects the batch with "None of
  inputs belongs to the provided account". The migration engine stamps it during the build
  (`Committer::start` resolves the account derivation and both builders pass it to
  `build::finalize_pczt`), so these entry points marshal the engine's bytes through unmodified; an
  account whose ZIP 32 derivation the wallet does not know (a UFVK import made without one) yields
  unstamped PCZTs rather than an error from these calls.
- `Balance` (inside `FfiAccountBalance` / `FfiWalletSummary`) gains a trailing `locked_value` field,
  keeping "the sum of the fields is the account's total" true.
- `zcashlc_migration_propose_immediate_transfers` — briefly part of this unreleased cycle, never
  exposed through the Swift welding and removed again before release — is gone. The immediate
  (single-transaction) lane is built entirely on the general-purpose
  `zcashlc_propose_send_max_transfer` (called with `orchard_only: true`) instead, which the engine
  itself never touches.
- `zcashlc_proving_interactive_begin`, `zcashlc_proving_interactive_end`, and
  `zcashlc_proving_interactive_active` apply a refcounted, scoped QoS boost to the global rayon
  proving pool, for callers waiting on an interactive proof (e.g. a voting signature) rather than
  background proving. On Apple platforms, `_begin` raises every pool worker to `USER_INITIATED` QoS
  on the 0→1 session edge; `_end` releases the boost on the 1→0 edge and is a saturating no-op when
  called without a matching `_begin`; `_active` reports the number of outstanding sessions.
  The boost is pool-wide while a session is open: background proving that overlaps a session
  runs boosted with it. Outside sessions workers keep their resting `UTILITY` QoS, so the
  migration prove sweep and the overnight BGTask path are unaffected except during an overlap.
  Failed override starts and releases are logged through `tracing`, and a failed release is
  counted — that worker stays boosted for the process lifetime. Non-Apple targets track the
  session refcount but apply no QoS override.
- `ErrorKind::AnchorNotFound` (`21`): `zcashlc_take_last_error_report` reports it when creating
  transactions from a proposal (`zcashlc_create_proposed_transactions`) fails because the wallet
  has not scanned to a height it can anchor them on. Such failures were reported as
  `ProposalInvalid` (`17`).
- `zcashlc_describe_unified_full_viewing_key` reports which items (P2PKH, P2SH, Sapling, Orchard,
  unknown) a unified full viewing key carries. It takes the key as a null-terminated string and a
  `network_id`, ignores whitespace around the key, and returns a bitmask of the items: `1` P2PKH,
  `2` P2SH, `4` Sapling, `8` Orchard, and `16` for an item of a typecode the library does not
  recognize. It returns `-1`, with no last error set, when the input is not a unified full viewing
  key for `network_id`, and `-2`, with the last error set, on an internal failure: a null pointer,
  input that is not UTF-8, an invalid `network_id`, or a panic. The last error never contains any
  part of the key.
- `zcashlc_find_account_key_overlap(db_data, db_data_len, ufvk, network_id)` finds the account in
  the wallet that shares an incoming viewing key component (Orchard, Sapling or transparent P2PKH)
  with a unified full viewing key, and reports what importing that key with
  `zcashlc_import_account_ufvk` would do to it. It opens the wallet database read-only and ignores
  whitespace around the key. It returns an `FfiAccountKeyOverlap`, freed with
  `zcashlc_free_account_key_overlap`, whose `kind` is an `FfiAccountKeyOverlapKind`:
  - `None` (`0`): no account shares a component, so the import adds an account.
  - `AlreadyImported` (`1`): the account's viewing key already covers every item of the key, so
    the import fails.
  - `WouldUpgrade` (`2`): the key carries every incoming viewing key item of the account and
    something its viewing key does not cover, so the import adds no account: it replaces the
    account's viewing key with the key instead.
  - `Conflicting` (`3`): the key shares a component with the account but lacks or changes
    another, so the import fails.
  - `MultipleAccounts` (`4`): the key's components match more than one account, so the import
    fails.

  Its `account` is that `FfiAccount`. For `None` and `MultipleAccounts` it is the value
  `zcashlc_get_account` returns for an unknown account, with all-zero `uuid_bytes` and null
  strings. The function returns null, with the last error set, on any other outcome: a null key, a
  key that is not UTF-8 or not a unified full viewing key for `network_id`, an invalid
  `network_id`, a wallet database that cannot be read, or a panic. The last error never contains
  any part of the key.
- `zcashlc_set_account_name(db_data, db_data_len, network_id, account_uuid_bytes, name)` sets the
  name of an account, replacing any name it had; the account's keys and all other state are
  unchanged. `name` is a null-terminated UTF-8 string. It returns `true` on success, and `false`
  with the last error set when no account has `account_uuid_bytes`, when `name` is null or not
  UTF-8, or when the wallet database cannot be written.
- `zcashlc_pow_target_spacing_era(network_id, height, start_ret, end_ret, spacing_ret)`,
  `zcashlc_target_seconds_between(network_id, from_height, to_height, seconds_ret)`,
  `zcashlc_height_after_target_seconds(network_id, from_height, seconds, height_ret)` and
  `zcashlc_default_tx_target_height_for_expiry(network_id, expiry_height, target_height_ret)` convert
  between heights and target time: 150 s a block before Blossom, 75 from Blossom, 25 from NU7, at the
  network's activation heights (NU7: mainnet 3,543,405, testnet 4,465,026), a registered custom network's
  included. They write, respectively, the run of equal spacing containing a height (`end_ret` `-1` when
  it never changes again); the summed
  spacing of the blocks after `from_height` through `to_height` (negative when lower); the height whole
  blocks reach in `seconds` (walking back when negative, stopping at 0); and the target height whose
  default expiry (40 blocks before NU7, 120 from NU7) is `expiry_height`, the earlier candidate for an
  expiry neither produces. Each returns `false` with the last error set, writing nothing, for an
  unknown or unregistered network or a null output pointer.
- `zcashlc_migration_cancel_run(db_data, db_data_len, account_uuid_bytes, network_id)` cancels the
  account's pending migration run and nothing more, and returns `true` (`false` with the last error
  set otherwise). The run is stored as cancelled and eligible advisory note reservations are released.
  Recorded spends retain the wallet's expiry and scan restrictions, even if network submission failed
  or was never attempted; transactions already broadcast are unaffected on-chain and may still mine.
  A proposal previewed earlier can no longer be committed
  (`MIGRATION_PLAN_STALE`). Unlike `zcashlc_migration_restart_step`, which cancels the same way, it
  plans nothing. It is never refused before the NU7 activation, so it takes no
  `upgrade_gate_bypass` and needs no chain tip. With no run pending it succeeds and changes no stored
  run. Afterwards `zcashlc_migration_advance_step` answers `ZCASHLC_ADVANCE_STEP_COMPLETE` for the run,
  whatever the chain tip: this is how a run that `ZCASHLC_ADVANCE_STEP_INTERRUPTED_BY_NETWORK_UPGRADE`
  reported is ended.
- `zcashlc_migration_availability(db_data, db_data_len, network_id, upgrade_gate_bypass)` reports what
  the migration may start at the height after the wallet's own chain tip, for choosing which options
  to offer before anything is planned. It takes no account, opens the wallet read-only and makes no
  network request. It returns an `FfiMigrationAvailability`, freed with
  `zcashlc_free_migration_availability`: `phase` is `ZCASHLC_MIGRATION_AVAILABLE` (`0`, both the
  scheduled and the immediate lane may start), `ZCASHLC_MIGRATION_PAUSED_UNTIL_UPGRADE` (`1`, the
  next block is before NU7: new scheduled work is paused); `activation_height` is the network's NU7
  activation height in both phases, `-1` when it has none; `immediate_available` is always `true`,
  retained for FFI compatibility. Valid committed transactions may still be proved and broadcast
  before activation. It judges the same gate as the calls refused with `MIGRATION_PAUSED_UNTIL_UPGRADE`.
  `upgrade_gate_bypass` is for internal builds: `true` makes the phase `0` at every height. A wallet
  with no chain tip, on a network that has an NU7 activation height and without the bypass, returns
  NULL with the last error set ("sync first"); with the bypass, or on a network with no NU7
  activation height, no tip is read.

### Changed

- `libzcashlc` is built for minimum iOS 16 and macOS 14 on every slice (the iOS simulator included);
  its C objects previously claimed the building Xcode SDK's version.
- `zcashlc_set_custom_network` takes a trailing `nu7` activation height. As for the other
  heights, a negative value means "not activated on this network".
- `zcashlc_create_proposed_transactions` takes a trailing `ovk_policy: u32`: `0` encrypts the
  outputs to the sending account's outgoing viewing key, as every call did before, and `1` discards
  it, so nobody holding the account's keys can recover the recipients, amounts or memos from the
  chain. Any other value fails. Existing callers must pass `0` to keep their behavior.
- `zcashlc_create_proposed_transactions` reads the Sapling parameter files only for a proposal that
  `zcashlc_proposal_requires_sapling_params` reports as needing them. For any other proposal
  `spend_params` and `output_params` may be null and the files need not exist; a proposal that
  needs them with null paths fails instead of panicking.
- `zcashlc_slipstream_snapshot` reports `tip_fresh = 1` only once the run that refreshed the
  chain tip has also completed a ChainTip-priority scan range (`spendable_hint = 1`) or reached
  Done, so a host that lifts a spendable-balance mask on `tip_fresh` never uncovers the transient
  zero the wallet database reports for every non-stabilized note until that range is scanned. A
  pass that stalls before scanning it, or that never queues a ChainTip-priority range, keeps
  `tip_fresh = 0` until it reaches Done. The field and its type are unchanged.
- `zcashlc_slipstream_stop` returns an `FfiSlipstreamStopReport` by value instead of `bool`. Its
  `settled` (`uint8_t`) is 0 while any aborted pass is still unwinding when the stop's ten-second
  budget runs out, and `drained` is 0 while an in-flight wallet commit has not drained within its
  own ten-second budget; each is 1 otherwise. `settle_ms` and `drain_ms` (`uint64_t`) say how long
  each wait took. A pass that outlived an earlier stop or start stays on record, so a later stop
  keeps reporting `settled = 0` until that pass has actually finished. A stop that cannot run, on a
  null handle for instance, returns all zeros. The `bool` was `true` only when both waits finished
  within their budgets, and `false` when either ran out or the stop could not run. A caller that
  read the `bool` must read the struct: the wallet file was proved quiescent only when `settled`
  and `drained` are both 1.
- `zcashlc_propose_transfer`, `zcashlc_propose_transfer_from_uri`,
  `zcashlc_propose_send_max_transfer`, and `zcashlc_create_proposed_transactions` classify their
  failures instead of flattening them into a string. Their last-error text now reads
  `<call site>: <redacted message>`, with the same redaction guarantee as `FfiErrorReport`, and the
  unredacted upstream text is logged on the device at `debug!` only. A caller that parsed the old
  text for a cause should take `zcashlc_take_last_error_report` and switch on `kind` instead.
  `zcashlc_propose_shielding` is unchanged and still reports a plain string.
- The `libzcashlc` crate is now licensed under the GNU Affero General Public License, version 3
  only (AGPL-3.0-only) instead of the MIT License. See `COMMERCIAL-LICENSE.md` in the repository
  root for commercial licensing, and `LICENSE-EXCEPTIONS.md` for App Store distribution and
  trademark clarifications.
- The pool-migration planning and estimating entry points — `zcashlc_migration_propose_transfers`,
  `zcashlc_migration_prepare_note_split`, `zcashlc_migration_is_note_split_needed`,
  `zcashlc_migration_residual_after_migration`, `zcashlc_migration_restart_step` and
  `zcashlc_migration_estimate_runs` — now size each run PER ACCOUNT, from the `key_source` the
  account row was created or imported with: an account tagged `keystone` (compared
  case-insensitively; nothing is trimmed or prefix-matched) has each run sized to what a Keystone
  signs in one 96-action signing round (16 actions per preparation transaction, 3 per transfer),
  so it plans more, smaller runs on a large or fragmented balance; every other account, an absent
  tag included, keeps the 50-note per-run sizing it had, so its runs are unchanged. Signatures and
  `#[repr(C)]` shapes are unchanged. `FfiRunEstimate::keystone_rounds` is 1 for every run of a
  `keystone` account (more only when even a one-note run overflows a round, which no smaller run
  can fix) and, for every other account, what a Keystone would need for a run of that shape. The
  estimate describes the runs the planning calls plan, under the same per-account sizing. A run
  committed before this change keeps its planned shape until it completes or
  `zcashlc_migration_restart_step` re-plans it. Estimating costs one planning pass per run, plus a
  sizing search per run for a `keystone` account.
- `zcashlc_migration_residual_after_migration` now returns the value the WHOLE migration leaves in
  the source pool — the `final_residual` that `zcashlc_migration_estimate_runs` reports for the
  same wallet (`-1` when it is zero) — instead of the next run's own leftover, and no longer reads
  the stored run: before, during and after a run alike it is computed from the live spendable
  balance. On a balance that takes more than one run the old value was mostly what the later runs
  migrate; on a single-run balance the value is unchanged before and during the run, while after
  the run completes the remaining dust is now reported where `-1` was returned before, and a
  balance whose canonical split the notes cannot fund now reports the whole spendable balance where
  the call used to fail. It costs one planning pass per remaining run, like the estimate.
- Coinholder voting hosts the `zcash_voting` 5.x native round driver with the `lrz` (librustzcash)
  backend, pinned to the published `=5.2.0-rc.2` release. Opening a voting
  database migrates schema 13 to 24 in place; older cores cannot reopen it.
  The step-by-step entry points a host used to drive are gone (see Removed) and the session surface
  that replaces them is new (see Added); what changed for the entry points that survive is:
  - `zcashlc_voting_db_open` takes a network id, fixing the voting network for the lifetime of
    the returned handle; an unknown one is rejected once at open rather than by each call.
  - Voting database handles opened on the same sidecar path share one connection instead of each
    opening its own, so writers serialize on it rather than contending for the file lock and only
    the first open migrates the file. A path whose file has been deleted or replaced since it was
    opened is excepted: `zcashlc_voting_db_open` then opens a fresh database there. Whatever still
    holds the old connection — another handle, or a session that outlived the handle it was opened
    from — keeps it, writing into a database no path names any more. Free the sessions, then the
    handles, before deleting a sidecar file.
  - `zcashlc_voting_generate_hotkey` drops its database and seed parameters and takes a network
    id, because voting hotkeys are app-owned random values rather than wallet-seed derivations;
    the caller must persist the returned stored secret. `FfiVotingHotkey` carries
    `stored_secret`, `raw_orchard_address` and `address_index` in place of its former key pair.
  - `zcashlc_voting_list_rounds` returns JSON in an `FfiBoxedSlice` instead of an
    `FfiRoundSummaries` struct; every voting result is JSON now, and the `#[repr(C)]` result
    structs and their destructors are gone with it (see Removed).
  - `zcashlc_voting_extract_nc_root` reads the TreeState's IRONWOOD tree, not its Orchard one —
    rounds anchor to the Ironwood pool, and the two roots never coincide, so a caller that kept
    the old value fails every round.
  - `zcashlc_voting_warm_proving_caches` starts the warm-up in the background and returns rather
    than performing it on the calling thread.
  - Hotkey generation and the software signer accept a regtest or custom network id, which
    resolves its voting identity through the registered base network: a modified-mainnet chain
    votes with mainnet hotkeys and HRPs, and an unconfigured custom network is rejected.
  - `zcashlc_voting_session_open` fails with `invalid_input` when the network registered through
    `zcashlc_set_custom_network` selects a different consensus branch at the round's snapshot
    height than the base network does. The message names both branches and the height. Note
    selection resolves its note version through the registered activation heights, but delegation
    derives its branch from the base network alone and refuses any other. Voting runs on NU6.3 on
    both sides, so where the two differ at least one has not reached NU6.3 at that height, and at
    least one half refuses the round on its own; the check reports that as one clear refusal at
    open rather than as an unsupported note version or an unsupported branch id from deeper in.
    A caller on a standard network id is unaffected: the two schedules are then the same one. On a
    regtest base they are not — the crate's regtest schedule activates NU6.3 at height 10, so a
    round whose snapshot height is below 10 is refused unless the registered heights say the same.
  - Every voting service a session touches rides the route the session was opened on: chain and
    helper traffic, PIR queries and vote-tree sync alike. A PIR query hides which rows are
    fetched, not who fetches them — the PIR server and the tree node see the device's address,
    the round and one fetch burst per bundle — so a Tor session fails closed for all four rather
    than letting any of them out some other way. Vote-tree sync is a session call
    (`zcashlc_voting_session_sync_vote_tree`) rather than a store call, because only a session
    carries a route to take it on.
    The vote-tree client follows the route rather than the round, which costs bandwidth and
    memory the caller should budget for. The crate keeps one tree client per wallet and
    transport, and each session has its own transport, so a session's first sync of a round's
    tree starts FROM SCRATCH instead of continuing the previous session's — paid whenever a round
    is reopened, and always on a route change, which requires a new session. That cost is not
    confined to `zcashlc_voting_session_sync_vote_tree`: `zcashlc_voting_session_run` syncs the
    same tree over the same transport whenever it casts a vote, so a caller that never syncs
    explicitly pays it too.
    The previous session's tree is also retained after the session is freed, for as long as its
    client holds any round's state — and that client owns the transport it was built over, so a
    Tor session's isolated Tor client stays alive with it, past the session and past the host
    disabling Tor. `zcashlc_voting_reset_vote_tree` for those rounds releases it, as does closing
    the last connection to the sidecar. Reset when the voter leaves the round, not on every
    session free — a round-scoped reset drops that round's state on every tree client of the
    wallet, including one a concurrent session is syncing on. The reset is keyed by the sidecar
    and the wallet id bound at the time of the call, so on a wallet switch it must run BEFORE
    `zcashlc_voting_set_wallet_id`; afterwards it addresses the new wallet's clients and leaves
    the old wallet's tree and transport in memory.
  - `zcashlc_voting_session_setup_bundles`'s JSON carries `privacy_trim_dropped_bundles`,
    `privacy_trim_dropped_notes`, `privacy_trim_dropped_value_zatoshi`, `skipped_suffix_bundles`,
    `skipped_suffix_notes` and `skipped_suffix_value_zatoshi`;
    `zcashlc_voting_session_eligibility`'s carries `privacy_trim_dropped_value_zatoshi`,
    `skipped_suffix_bundles`, `skipped_suffix_notes`
    and `skipped_suffix_value_zatoshi`. A new round is seeded with the crate's default bundle
    policy, privacy trim included: trailing low-value bundles are dropped until at most two remain,
    as long as what is dropped stays within 1% of the selected value and 1,000 ZEC. Any number of
    bundles can go that way, so a wallet with a long dust tail loses the whole tail rather than two
    of it. A round that already has a persisted policy keeps it.
- Migrated to `zcash_protocol 0.10.4`, `zcash_client_backend 0.24.0-rc.7`,
  `zcash_client_sqlite 0.22.0-rc.7`, `pczt 0.9.2`.
- The migration engine's wallet adapter is UPSTREAM's (`zcash_pool_migration::wallet::WalletMigration`
  plus `zcash_client_sqlite`'s account-scoped `PoolMigrations` store); the SDK's own fork of it is
  deleted. Three consequences reach behaviour rather than just code:
  - No migration type holds spend authority any more, and none can be given it. The adapter is
    built from the account's VIEWING key alone, and the engine's two signing entry points
    (`commit_preparation`, `rebuild_expired_transfer`) take an `orchard::keys::SpendingKey` per
    call — deriving its full viewing key and checking it against the account's stored one BEFORE
    building anything, refusing a foreign key with `CommitError::WrongSpendAuthority` /
    `RebuildError::WrongSpendAuthority` rather than silently signing nothing — so the FFI functions
    that sign pass the spending key they just decoded straight through and drop it with the call,
    instead of parking a `UnifiedSpendingKey` inside an adapter that mostly does not need one. The
    external-signer lanes are unchanged: they call the unsigned entry points, which take no
    authority at all.
  - The spendable-note snapshot that keeps a commit linear in the wallet's note count is
    upstream's own (librustzcash #2946) rather than an SDK mirror of it.
  - `PoolMigrationRead::mined_height` is answered by the adapter from the wallet's FULLY-SCANNED
    bound instead of being delegated to the store. The two agree on every value — the store
    applies the same rule at its own layer — so no answer changes; the store still answers
    directly on the paths that use it without an adapter.

  What remains SDK-side is the account's stored unified full viewing key: upstream's constructor
  takes the key from its CALLER (a wallet may hold several keys that view one account), and this
  SDK always supplies the one the account record holds, which is what lets an imported
  hardware-wallet account — whose spending key never exists on this device — plan, build and prove.
  A migration call against an account whose record holds no unified full viewing key now fails at
  the point the adapter is built rather than at the first key-dependent operation.
- `zcashlc_set_transaction_status` now returns `bool` (`true` on success) instead of `void`, so
  callers can detect a failed status write (previously any error — including an unknown chain
  height — was silently discarded). No `repr(C)` struct layout changes.
- `zcashlc_migration_state` is removed before any release exposed it, along with the state machine
  it served (`MigrationState`/`Complete`/`InProgress`/etc. never crossed the FFI as a stable shape).
  `zcashlc_migration_advance_step` replaces it: a verbatim, un-opinionated marshal of the upstream
  engine's own `next_step`, with no SDK-side derivation on top. `_progress` is otherwise unchanged
  in shape and keeps its own `is_immediate`-aware behavior: a mined immediate (send-max) run is
  consumed — it reports `is_present: false` and masks a stale engine `Complete`, so a host goes
  quiet once the sweep mines instead of reporting a per-run completion — while an unmined, unexpired
  immediate run still reports present with `is_immediate: true`. `FfiMigrationProgress` gains a
  trailing `is_immediate` boolean.
- The anchor bucket interval is selected per network: mainnet keeps the ZIP 318 grid of 144 reference
  blocks, while testnet and custom-parameter networks retain anchors every 12 reference blocks and
  compress the transfer and preparation delays by the same factor, so a migration crosses enough
  boundaries to be exercised in a test run. A reference block is one block until NU7 activates and spans
  three blocks from it, so from NU7 the boundaries lie three times as many blocks apart (432 on mainnet, 36
  on testnet). Nothing crosses the FFI for this — each wallet handle is opened with the interval its
  `network_id` selects — and a migration already in flight keeps the interval it was committed under.
- The migration engine counts ZIP 318's delays and expiry windows in reference blocks, the 75-second blocks
  of ZIP 318, and converts them to blocks with the network's NU7 activation height (mainnet 3,543,405,
  testnet 4,465,026): from NU7 a wait of the same length in time is three times as many blocks, and a wait
  that crosses the activation keeps its length in time. The broadcast and expiry heights of a schedule
  planned from NU7 lie accordingly (`FfiTransferProposal.next_executable_after_height` and `.expiry_height`,
  `FfiMigrationPreparationStep.broadcast_height`; from `zcashlc_migration_propose_transfers`,
  `zcashlc_migration_restart_step` and `zcashlc_migration_refresh_stale_transfers`), and
  `zcashlc_migration_advance_step` judges an overdue schedule and shifts a slept-through backlog by the same
  rule. Below the activation a reference block is one block, so heights there are unchanged. Convert a span
  of heights to time with `zcashlc_target_seconds_between`, not at 75 seconds a block. The reorg settle depth
  `zcashlc_migration_advance_step` judges a displaced step by is 10 reference blocks too: 10 blocks below the
  activation and 30 from it.
- A transaction whose expiry height the wallet does not know is assumed to expire after the default expiry
  delta for the height at which the wallet first observed it: 120 blocks from NU7 (mainnet 3,543,405,
  testnet 4,465,026), where the assumption was a fixed 40, and still 40 from Blossom until NU7. The delta
  sets how long the spends of such an unmined transaction keep counting, so the notes and transparent
  outputs it spends stay out of the spendable amounts that `zcashlc_get_wallet_summary`,
  `zcashlc_get_verified_transparent_balance`, `zcashlc_get_verified_transparent_balance_for_account`,
  `zcashlc_get_total_transparent_balance` and `zcashlc_get_total_transparent_balance_for_account` report,
  and out of new proposals, for as long as it stays unmined inside the window; how long
  `zcashlc_transaction_data_requests` keeps returning its `GetStatus` request; and how far a
  `TransactionsInvolvingAddress` request that searches for the spend of a transparent output reaches: its
  `block_range_end` lies up to 121 blocks past its `block_range_start`, where it lay up to 41. A transaction
  of that kind that never mines therefore frees its inputs 80 blocks later than before, the same 50 minutes
  it took at 75-second blocks. Nothing changes from Blossom until NU7, and no caller changes are required.
- Note locks are owner-keyed: the residual lock is keyed to a deterministic per-account owner, which
  makes re-locking idempotent, and `zcashlc_migration_unlock_residual` still clears the account's
  locks wholesale.
- `zcashlc_migration_record_transfer_result`'s success tag no longer records the reported txid: the
  engine marks the broadcast under the id it derived when it built the transaction. The reported
  value is now CHECKED against that id, and a mismatch is an error — the two can differ only if the
  platform submitted something other than the artifact the engine handed it, which is worth naming
  rather than silently recording a broadcast of a transaction that was never sent.
- The migration store connection uses the same 15 s `busy_timeout` as the wallet handle, so a
  `zcashlc_migration_*` call racing an engine write waits for the lock instead of surfacing
  `database is locked` early.
- Terminal rejection evidence is reported to the upstream engine, whose satisfiability oracle
  returns `Reevaluate` or `Replan`; the FFI projects those onto its existing `Attend` case. The
  `ext_zcashlc_orchard_ironwood_migration_invalid_marks` extension table is retired: its schema
  migration is no longer registered.
- The estimated-tip due-ness split is owned by the upstream engine (`DuenessTargets`) instead of
  hand-rolled SDK twins of the upstream predicates; behaviour additionally gains upstream's
  doomed-broadcast withhold (above).
- Which transaction each lane acts on is the engine's decision, not an SDK re-derivation, and it
  is made ONCE: `zcashlc_migration_advance_step` cranks `advance_migration`, and the two EXECUTORS
  — `_take_broadcast_transaction` and `_prove_transactions` — discharge the instruction it
  returned (see their entries above), so what they act on was verified against the store's
  satisfiability oracle before it was handed out. `_take_preparation_by_txid` is not a third
  executor but the retrieval half of the prove executor's own return: it acts only on a txid that
  return just named, and its gate refuses everything else. The READ-ONLY reporting query —
  `_has_overdue_transfers` — cannot drive,
  and reads the engine's public per-row status view instead; the SDK's hand-rolled twins of
  upstream's readiness predicates are gone, leaving only the `(scheduled_height, id)` ordering key
  that display read composes over the view. The note-split ceremony's immediate-broadcast pick
  reads the same view, so a resumed ceremony re-serves an already-proved, due preparation rather
  than proving another. The plan preview is likewise a READ of the engine's own
  `MigrationPlan::planned_transactions` enumeration — the same rows `commit_preparation` builds
  from — rather than a second derivation beside it: every preparation step's id, `layer`, `index`,
  `depends_on` and `broadcast_height`, and every transfer row's id and
  `next_executable_after_height`, come off that enumeration. A previewed row therefore describes
  exactly the transaction the commit will build, by construction rather than by two derivations
  agreeing; the values are unchanged (the enumeration's dependency and scheduling rules are the
  ones the preview used to reproduce by hand).
- Mined-transaction promotion is the upstream engine's: `advance_migration` sweeps every in-flight
  transaction and promotes the ones the wallet's scan has seen mine, so the drive path no longer
  reconciles first, and the read-only entry points reconcile through the engine's own
  `PoolMigrationRead::mined_height` rather than `WalletRead::get_tx_height`. That tightens the
  bound from the chain tip to the FULLY-SCANNED height — a promotion may not rest on a block
  outside the region a reorg truncation would roll back — and is the same bound the drive path
  promotes under, so a status read can no longer report `Mined` for a row `advance_migration`
  would refuse to promote.
- The five migration read entry points (`zcashlc_migration_transaction_statuses`,
  `zcashlc_migration_progress`, `zcashlc_migration_has_overdue_transfers`,
  `zcashlc_migration_has_invalid_transfers`,
  `zcashlc_migration_sync_wakeups`) now open the database read-only and report the persisted
  run without reconciling mined transactions first. Broadcast→Mined promotion is persisted by
  the write lanes (the advance-step engine sweep, the prove sweep, the delivery serves), which
  every live run drives at least once per open-lane pass, sync edge, and UI refresh; a read can
  therefore trail a just-mined broadcast by at most one such pass. Reads no longer contend with
  proving.
- The crate now builds against the NU7 release of the `librustzcash` crates and the `zodl-slipstream`
  0.4.1 engine. Its `rust-version` is 1.97, up from 1.91: building `libzcashlc` from source needs
  Rust 1.97 or newer.
- Every unified address, UFVK and UIVK string a `zcashlc_*` function returns is ZIP 316
  revision 0, with every receiver or item the value carries, as before the NU7 move. Revision 2
  is used only for a value revision 0 cannot represent (one with expiry metadata, a P2SH
  viewing-key item, or only transparent items). Decoding accepts both revisions, unchanged.
- `zcashlc_init_data_database` applies one more wallet-database migration. It changes stored data only, not
  the schema, and cannot be reverted. No address that `zcashlc_get_current_address` or
  `zcashlc_get_next_available_address` returns changes, and an older build can still open the database.
- `zodl-slipstream` is now required as `=0.4.1` from crates.io. No FFI caller change is required.
  This release includes the NU7 block cadence,
  the move to the librustzcash release, the engine facades' implementation of
  `WalletWrite::set_account_name`, and the restore anchor's resolution of a server tip or
  tree-state height above `i32::MAX` like an unreachable server (see the
  `zcashlc_slipstream_restore_anchor` entry under Fixed). It also fixes stale graft-buffer rows
  that could put commitment-tree leaves at the wrong position, or keep a shard out of the tree,
  after a stopped pass, a reorg or an account import.
- `zcashlc_slipstream_stop` and `zcashlc_slipstream_start` now call the engine for the bounded
  stop that proves the wallet file quiescent, which zodl-inc/slipstream#28 moved into the engine;
  that change also adds the stop for a wallet change.
- `zcashlc_init_data_database` now creates the
  `ext_zcashlc_orchard_ironwood_migration_immediate_runs` extension table, moving into it any
  records held by the `sdk_immediate_runs` table that read-write `zcashlc_migration_*` calls used
  to create on demand, and dropping that table. `zcashlc_migration_record_immediate_run` and
  `zcashlc_migration_progress` read and write only the new table, so `zcashlc_init_data_database`
  must have run with this version before either is called.
- `zcashlc_init_data_database` drops the retired
  `ext_zcashlc_orchard_ironwood_migration_invalid_marks` table, and read-write
  `zcashlc_migration_*` calls no longer replay its rows into the migration state first. Rejection
  marks a wallet never replayed are discarded; the engine re-adjudicates the affected transfers on
  their next broadcast attempt.
- `zcashlc_migration_advance_step` holds back the engine's step around the NU7 network upgrade,
  judged at the height after the wallet's own chain tip and never at `estimated_tip`, and takes a
  trailing `upgrade_gate_bypass: bool`. `FfiMigrationAdvanceStep` gains a final field,
  `network_upgrade_height: i64`, which a caller that builds the struct itself must now provide. Two
  steps are new, exported as `ZCASHLC_ADVANCE_STEP_PAUSED_FOR_NETWORK_UPGRADE` (`8`) and
  `ZCASHLC_ADVANCE_STEP_INTERRUPTED_BY_NETWORK_UPGRADE` (`9`). Both carry the NU7 activation height in
  `network_upgrade_height` (`-1` on every other step), name no transaction (`id` is `0`) and carry no
  outlook (`next_height` is `-1`), so a `switch` over `step` needs an arm for each. A network with no
  NU7 activation height is never gated.
  - `PAUSED_FOR_NETWORK_UPGRADE` answers in place of a Rebuild or a Replan before activation.
    Do nothing, and ask again as the chain advances. Valid committed work may still be proved
    and broadcast before activation.
  - `INTERRUPTED_BY_NETWORK_UPGRADE` answers from the activation on when a transaction of the stored
    run that is not mined was built for another consensus branch than the next block's, so the run
    cannot complete. While every such transaction is `Proved` or `Broadcast`, one of them may have
    been mined before the activation at a block the wallet has not scanned yet, and the call answers
    `ZCASHLC_ADVANCE_STEP_REEVALUATE` instead, to sync and ask again, until the wallet has scanned the
    block before the activation.
  - `upgrade_gate_bypass` is for internal builds: `true` lifts the pause on new scheduled work, so
    the call never answers `PAUSED_FOR_NETWORK_UPGRADE` and otherwise returns the engine's own step.
    It never lifts the interruption: the call still answers `INTERRUPTED_BY_NETWORK_UPGRADE`, or
    `ZCASHLC_ADVANCE_STEP_REEVALUATE` while the wallet's scan has not reached the block before the
    activation. Pass `false` to enforce the gate.
- Until the NU7 network upgrade has activated, the calls that plan, build, sign, store or rebuild a
  scheduled migration run are refused: `zcashlc_migration_propose_transfers`,
  `zcashlc_migration_prepare_note_split`, `zcashlc_migration_sign_note_split`,
  `zcashlc_migration_sign_and_store_schedule`, `zcashlc_migration_create_unsigned_note_split_pczts`,
  `zcashlc_migration_create_unsigned_transfer_pczts`,
  `zcashlc_migration_store_signed_note_split_pczts`,
  `zcashlc_migration_store_signed_schedule_pczts` and `zcashlc_migration_refresh_stale_transfers`
  return their failure value (NULL, or `false`) with the last error
  `MIGRATION_PAUSED_UNTIL_UPGRADE:<activation height>`, the height following the colon directly (for
  example `MIGRATION_PAUSED_UNTIL_UPGRADE:3543405`). Nothing is planned, cached, built, signed or
  stored by a refused call. The gate is judged at the height after the wallet's own chain tip, so a
  wallet with no chain tip fails with the usual "sync first" error instead, and
  `zcashlc_migration_refresh_stale_transfers` is no exception even where it has nothing to refresh (no
  stored run, or a terminal one), which it used to answer before reading any tip. A network with no NU7
  activation height is never gated. Each of the nine, and `zcashlc_migration_restart_step`, takes a
  trailing `upgrade_gate_bypass: bool`, which every existing call site must now pass. It is for
  internal builds: `true` lets the call through at every height. Pass `false` to enforce the gate. The
  read-only calls, `zcashlc_migration_prove_transactions`,
  `zcashlc_migration_take_broadcast_transaction`, `zcashlc_migration_take_preparation_by_txid`,
  `zcashlc_migration_record_transfer_result`, `zcashlc_migration_record_immediate_run`, the residual
  locks and the Keystone helpers are not gated.
- `zcashlc_migration_restart_step` returns a `*mut FfiMigrationRestartOutcome`,
  `{ schedule: *mut FfiMigrationSchedule, replan_after_height: i64 }`, in place of the
  `*mut FfiMigrationSchedule`. Free it with the new `zcashlc_free_migration_restart_outcome`, which
  also frees the schedule, and no longer with `zcashlc_free_migration_schedule`. The call still cancels
  the stored run first. From the NU7 activation on, or with `upgrade_gate_bypass`, it then plans as
  before: `schedule` is the fresh plan and `replan_after_height` is `-1`. Before the activation it
  plans nothing and succeeds with no last error: `schedule` is NULL, `replan_after_height` is the NU7
  activation height a new scheduled plan waits for, and a plan proposed earlier can no longer be
  committed (`MIGRATION_PLAN_STALE`).
- `zcashlc_migration_take_broadcast_transaction`, `zcashlc_migration_take_preparation_by_txid` and
  `zcashlc_migration_sign_note_split` check the transaction they hand back against the block it would
  be mined in, before the store's broadcast seam records it in the wallet, and refuse one that cannot
  be valid there. `zcashlc_migration_take_broadcast_transaction` and
  `zcashlc_migration_take_preparation_by_txid` take two trailing arguments,
  `submission_server_height: i64` and `upgrade_gate_bypass: bool`; `zcashlc_migration_sign_note_split`
  takes `submission_server_height: i64` right before its existing `upgrade_gate_bypass`. Every existing
  call site must pass them.
  - `submission_server_height` is the latest block height the server the transaction will be submitted
    to reports, read just before the call. The next block is the one after the higher of that height
    and the wallet's chain tip. A negative value means the height could not be read, and the call
    fails closed with the last error `the submission server's height is unknown` (for
    `zcashlc_migration_sign_note_split` before the run is committed), and so does a value above
    `u32::MAX`.
  - A transaction that is not built for the consensus branch of the next block or that has expired by it
    (an expiry height of 0 never expires, and a transaction can still be mined at its expiry height)
    makes the call return NULL with `MIGRATION_SUBMISSION_REFUSED:<code>`. `<code>` is `wrong_branch`
    or `expired`, checked in that order. A refused call records nothing in the wallet: for
    `zcashlc_migration_sign_note_split` the committed run and stored proof stay. A stored PCZT that
    does not parse fails with `MIGRATION_PROVING_UNAVAILABLE`.
  - `upgrade_gate_bypass` is retained on the broadcast accessors for ABI compatibility. It never
    bypasses submission validity; branch, expiry and server-height checks apply on every network.

### Removed
- The step-by-step coinholder-voting C surface is gone: `zcash_voting` absorbed the
  orchestration this crate used to drive one call at a time, and a host now opens a session and
  lets the round driver run (see Changed). What each group is replaced by:
  - Delegation setup, proving and submission — `zcashlc_voting_build_and_prove_delegation`,
    `zcashlc_voting_build_pczt`, `zcashlc_voting_extract_pczt_sighash`,
    `zcashlc_voting_extract_spend_auth_sig`, `zcashlc_voting_generate_delegation_inputs`,
    `zcashlc_voting_generate_delegation_inputs_with_fvk`, `zcashlc_voting_generate_note_witnesses`,
    `zcashlc_voting_generate_van_witness`, `zcashlc_voting_get_commitment_bundle`,
    `zcashlc_voting_get_wallet_notes`, `zcashlc_voting_verify_witness`,
    `zcashlc_voting_precompute_delegation_pir`, `zcashlc_voting_validate_pir_proof`,
    `zcashlc_voting_get_stored_pczt_sighash`, `zcashlc_voting_get_delegation_submission`,
    `zcashlc_voting_get_delegation_submission_with_keystone_sig` and
    `zcashlc_voting_get_delegation_submission_with_signature` — are replaced by
    `zcashlc_voting_session_setup_bundles`, `zcashlc_voting_session_precompute_pir`,
    `zcashlc_voting_session_precompute_delegation_proof` and `zcashlc_voting_session_run`. The
    intermediate material (witnesses, PCZTs, sighashes, delegation inputs) is no longer handed
    out at all for a software wallet; a Keystone wallet sees only the redacted per-bundle
    request, which carries the sighash its signature is verified against, so there is nothing
    left to read back separately.
  - Software delegation signing — `zcashlc_voting_sign_delegation_request` — is replaced by the
    per-run signer inside `zcashlc_voting_session_run`: a software wallet hands the run its
    seed, which reaches the SDK's signer for that call only, and no sighash, randomizer,
    signature or PCZT comes back to the caller.
  - Vote construction and casting — `zcashlc_voting_build_vote_commitment`,
    `zcashlc_voting_sign_cast_vote`, `zcashlc_voting_build_share_payloads`,
    `zcashlc_voting_encrypt_shares`, `zcashlc_voting_decompose_weight`,
    `zcashlc_voting_store_commitment_bundle`, `zcashlc_voting_commit_vote` and
    `zcashlc_voting_get_votes` — are replaced by
    `zcashlc_voting_session_set_ballot_intents`, which records the ballot, and
    `zcashlc_voting_session_run`, which builds, casts and delivers it.
  - Chain recording — `zcashlc_voting_store_delegation_tx_hash`,
    `zcashlc_voting_store_vote_tx_hash`, `zcashlc_voting_store_van_position`,
    `zcashlc_voting_mark_vote_submitted`, `zcashlc_voting_record_vc_position`,
    `zcashlc_voting_confirm_vote_submission`, `zcashlc_voting_get_delegation_tx_hash` and
    `zcashlc_voting_get_vote_tx_hash` — are the driver's own: `zcashlc_voting_session_run`
    submits and records, and its report plus `zcashlc_voting_round_plan` are the readbacks.
  - Share journaling — `zcashlc_voting_record_share_delegation`,
    `zcashlc_voting_mark_share_confirmed`, `zcashlc_voting_add_sent_servers`,
    `zcashlc_voting_get_share_delegations`, `zcashlc_voting_get_unconfirmed_delegations`,
    `zcashlc_voting_compute_share_nullifier`, `zcashlc_voting_recover_wire_json` and
    `zcashlc_voting_recoverable_share_indices` — are replaced by
    `zcashlc_voting_session_track_shares`, which rebuilds and delivers an owed share itself,
    and `zcashlc_voting_pending_share_rounds`, which says which rounds still owe one.
  - Round lifecycle and stored state — `zcashlc_voting_init_round`, `zcashlc_voting_clear_round`,
    `zcashlc_voting_setup_bundles`, `zcashlc_voting_get_round_state`,
    `zcashlc_voting_get_bundle_count` and `zcashlc_voting_clear_recovery_state` — are replaced by
    `zcashlc_voting_session_open` with `zcashlc_voting_session_setup_bundles`, and by
    `zcashlc_voting_round_plan`, `zcashlc_voting_reset_session_state` and
    `zcashlc_voting_delete_round`.
  - Vote-tree state — `zcashlc_voting_store_tree_state` and `zcashlc_voting_reset_tree_client` —
    are replaced by `zcashlc_voting_session_sync_vote_tree` and `zcashlc_voting_reset_vote_tree`;
    the round's anchor tree state is now an input to `zcashlc_voting_session_open`.
  - `zcashlc_voting_store_keystone_signature` is replaced by
    `zcashlc_voting_session_store_keystone_signatures`, which stores a whole round's signatures
    in one batch and reports how many were already present.
    `zcashlc_voting_clear_keystone_signature` has no replacement: there is no per-bundle delete,
    and the batch store reports a stored signature as already present rather than replacing it,
    so a bundle whose stored signature no longer matches its delegation setup is discarded with
    its round (`zcashlc_voting_delete_round`) and set up again.
  - Delegation recovery import — `zcashlc_voting_restore_recovered_delegation` and
    `zcashlc_voting_van_commitment`, which recomputed the VAN commitment a recovered row had to
    reproduce — has no replacement: importing a delegation capability rebuilt from a package is
    no longer part of the C surface.
  - The `#[repr(C)]` result structs `FfiRoundSummaries`, `FfiRoundState`, `FfiVoteRecords` and
    `FfiBundleSetupResult`, with their destructors `zcashlc_voting_free_round_summaries`,
    `zcashlc_voting_free_round_state`, `zcashlc_voting_free_vote_records` and
    `zcashlc_voting_free_bundle_setup_result`, are gone: every voting result is JSON in an
    `FfiBoxedSlice`, freed with `zcashlc_free_boxed_slice`.
- `zcashlc_voting_sync_vote_tree` is removed, and `zcashlc_voting_session_sync_vote_tree`
  replaces it. The store-level call had no route to take, so vote-tree traffic reached the node
  directly even for a round whose session had been opened on Tor. The replacement takes the
  `VotingSessionHandle` and the node URL in place of the database handle and the round id, and
  syncs over the session's route; a host that synced outside a round opens the round's session
  first.
- `zcashlc_migration_debug_reschedule_transfers` is removed. It was the only FFI entry point that
  wrote raw SQL directly against the engine-owned pool-migration tables, retro-compressing a
  committed schedule so its transfers become due in quick succession for manual broadcast testing.
  That testing purpose is now covered on the engine side by compressed test-network scheduling at
  commit time.
- `zcashlc_migration_pending_transfer_proposal` is removed, together with the standalone
  `zcashlc_free_migration_transfer_proposal` destructor that freed its answer. It was a
  KIND-FILTERED peek at the queue ("the next TRANSFER, specifically"), which the advance design
  makes a malformed question: any answer either masks imminent work of another kind or contradicts
  what the drive would serve. Its scheduling role belongs to `zcashlc_migration_advance_step`
  (whose outlook names the next serviceable work of ANY kind) and its display role to
  `zcashlc_migration_transaction_statuses` plus the schedule DTO. `FfiTransferProposal` itself
  stays — it is the row type of `FfiMigrationSchedule::transfers` — but is no longer handed out
  standalone.
- `zcashlc_migration_has_ready_broadcast` is removed. It had no consumer anywhere: the 2026-08-05
  D1 ruling deleted the sync gate's forward-looking clause, the only caller, and sync is now held
  only while a migration submission is in flight — never because a broadcast is expected in the
  future, and never for a fixed interval after one happened.
  `zcashlc_migration_has_overdue_transfers` — an honest "the delivery lane has actionable work"
  boolean, not a kind-filtered id peek — stays.
- `zcashlc_migration_extract_broadcast_tx` is removed. It had zero consumers, in the SDK or the
  app: every live flow receives already-finalized consensus transaction bytes from the store's
  atomic broadcast seam, never a PCZT that needs extracting. Its private helper,
  `migration_finalize::extract_tx`, goes with it — the FFI entry point was its only caller.

### Fixed
- `zcashlc_migration_take_broadcast_transaction` and `zcashlc_migration_take_preparation_by_txid`
  refuse a run that has ended (completed, failed, superseded or cancelled) with a bare error, before
  any other check. An instruction issued before `zcashlc_migration_cancel_run` could previously still
  be served after it, which recorded the transaction in the wallet and marked the notes the cancel had
  just released as spent again. No caller changes are required.
- `zcashlc_payment_uri_parse` rejects Ethereum native recipients, ERC-20 recipients, and token
  contracts whose hexadecimal address is not exactly 40 digits, instead of trusting the pinned
  EIP-681 parser's over-length address result.
- `zcashlc_payment_uri_parse` folds all-uppercase Bitcoin and Litecoin bech32 addresses before
  upstream validation without changing Litecoin's case-sensitive BIP-21 query-key semantics.
- `zcashlc_payment_uri_parse` rejects overflowing explicit ERC-20 chain IDs and conflicting native
  Ethereum payment parameters before the pinned parser can erase them from its typed result.
- `zcashlc_payment_uri_parse` rejects SPL-token amounts that cannot fit the `u64` used by any SPL
  transfer instruction.
- `zcashlc_extract_and_store_from_pczt` now records the transaction's Ironwood
  outputs in the stored sent transaction. Every Ironwood output was previously
  omitted, so for a post-NU6.3 PCZT delivering its payment through the Ironwood
  pool the external recipient's address and the decrypted memo were never
  persisted (and are not otherwise recoverable), and wallet-internal Ironwood
  outputs were invisible to the wallet until the transaction was mined and
  scanned. Shielded sent outputs stored by this call are also now tagged with
  their note commitment tree, as the transaction-builder spend path already did.
- The migration prover's transient-vs-hard error classification (`ProveErrorClass::is_transient`,
  behind `zcashlc_migration_prove_transactions` / `_advance_step`): `UnknownSpentNote` (a
  late-mining dependency's note the wallet has not seen yet) and `Tree(ShardTreeError::Query(_))`
  (shard-tree query races during sync — this exact case crash-looped a prove batch on Android on
  2026-07-28) now correctly resolve as the transient "retry on a later sweep" outcome instead of a
  hard `MIGRATION_PROVING_UNAVAILABLE:` error; the non-query `Tree` variants (`Storage`/`Insert`)
  stay hard, since no amount of syncing repairs a failing persistence layer or a corrupt tree
  write, and every transient deferral is now logged with the row id (a stalled sweep was
  previously silent). `IronwoodTreeUnavailable` moves the other way, out of the transient set: the
  backend tracks no Ironwood commitment tree at all, which no amount of syncing ever produces, so
  treating it as transient could retry forever instead of surfacing the real condition.
- `zcashlc_get_memo` accepts the Ironwood output pool code (4); an Ironwood note id was rejected as
  an unrecognized shielded protocol.
- Due-ness and expiry are evaluated on the engine's target-height contract (`chain tip + 1`) in every
  read path, with the "never expires" case honoured. Transfers now become due and expire one block
  earlier, consistently, and a doomed transfer is no longer served for broadcast. This now includes
  the proving sweep — the one remaining raw-tip caller — so a preparation scheduled exactly at the
  target is offered for proving on the advance that sees it rather than one block late.
- An `estimated_tip` at or beyond `u32::MAX` saturates below the height ceiling instead of
  overflowing the `+ 1` target conversion.
- `FfiMigrationProgress.next_transfer_ready_at_height` reports the next transfer still awaiting
  broadcast rather than one already in the mempool.
- Transfer amounts are read from the engine's `crossing_values()` instead of being re-derived at
  three marshal sites. The values are identical by construction, so no reported number changes.
- `zcashlc_slipstream_start` sets the engine's anchor-retention floor to the NU6.3 activation height,
  so a scheduled transfer's boundary anchor survives checkpoint pruning. Delivery previously stalled
  in a permanent `AnchorNotFound` retry until the transfer expired.
- Overlapping `zcashlc_slipstream_start` passes on one handle are serialized, fixing the panic
  (`SyncState::Error(2)`, surfaced as `rustSlipstreamSyncFailed`) when an `importAccount`-triggered
  restart ran two sessions against the same database.
- `zcashlc_slipstream_wallet_summary` no longer returns the empty sentinel during the ~30 s gap after
  a restore completes, and once NU6.3 is active reports the collapsed recovery balance in the
  Ironwood pool rather than Orchard.
- `zcashlc_slipstream_restore_anchor` resolves a server tip or tree-state height above `i32::MAX`
  as it does an unreachable server: a restore gets `max(fallback_checkpoint_height, birthday + 1)`
  and a new wallet gets `height` 0 with a null `treestate`. It used to return such a height as the
  server reported it.
- `zcashlc_migration_*` read-write entry points no longer create the wallet database, or any table
  in it, when asked about a wallet that does not exist or was never initialized; they return an
  error instead (a stray table used to make an empty file look like a wallet).
- Decode errors from `zcashlc_import_account_ufvk`, `zcashlc_derive_address_from_ufvk`,
  `zcashlc_derive_address_from_uivk` and `zcashlc_slipstream_start` no longer contain the key.
- `zcashlc_create_proposed_transactions` and `zcashlc_create_pczt_from_proposal` give a proposal whose
  target height has NU7 active an expiry 120 blocks after that height, not 40: the 50 minutes 40 blocks
  took at 75 seconds. A proposal with any ZIP 318 canonical crossing step keeps the ZIP 318 expiry;
  nothing changes from Blossom until NU7.
  From NU7 activation, a payment to a ZIP 316 revision 2 unified address whose expiry height falls
  before the new default expiry (target height + 120) but not before the old one (target height + 40),
  which used to succeed, is still proposed but fails here: `zcashlc_create_proposed_transactions`
  returns null with `zcashlc_take_last_error_report` reporting `ErrorKind::Unclassified` (`0`), and
  `zcashlc_create_pczt_from_proposal` returns null with the address expiry conflict in the last error
  message.
- `zcashlc_slipstream_snapshot`'s `tip_fresh` survives a `zcashlc_slipstream_stop` → `zcashlc_slipstream_start`
  gap shorter than 1.6 target block intervals of the block after the handle's last known chain tip: 120 s
  before NU7, as before, and 40 s once that block is a 25-second NU7 block. With no known tip, 120 s.
- `zcashlc_tor_lwd_conn_check_single_use_taddr` looks back over addresses exposed within one day of target
  time before the chain tip, and delays rechecks by the target spacing of the next block. Both assumed 75 s,
  so after NU7 the look-back covered eight hours and rechecks were three times too far out. In wall-clock
  terms, an address that has received nothing is now rechecked roughly 2–3× as often after NU7 as before it,
  each recheck being one address over its own Tor circuit. Unchanged before NU7 on mainnet and testnet.
- `FfiMigrationSchedule.estimated_duration_hours` (from `zcashlc_migration_propose_transfers`,
  `zcashlc_migration_restart_step` and `zcashlc_migration_refresh_stale_transfers`) counts blocks at their
  target spacing instead of 48 to the hour, so after NU7 it no longer reads up to three times too long.
- `zcashlc_migration_progress` keeps an unmined immediate migration with no known expiry pending for the
  default expiry delta past its record height: 40 blocks as before, 120 when NU7 is active at the next height.

## 2.8.0-rc.2 - 2026-07-28

### Changed
- Migrated to `zcash_protocol 0.10.2`, `zcash_client_backend 0.24.0-rc.5`,
  `zcash_client_sqlite 0.22.0-rc.5`.
- `zcashlc_propose_transfer` and `zcashlc_propose_transfer_from_uri`: once NU6.3 is active, a single
  payment of a canonical ZIP 318 denomination crossing the Orchard turnstile is proposed as a
  canonical crossing — one fewer ZIP 317 marginal-fee action, and up to two anchor-bucket intervals of
  additional confirmations on its inputs beyond `confirmations_policy`. A payment that cannot be
  funded that way is proposed as an ordinary transaction.
- `zcashlc_init_data_database` applies new migrations that repair the data described under Fixed
  below. No rescan is required.

### Fixed
- Ironwood notes received on an account's internal address are classified as change, so
  `v_transactions.has_change` and `v_tx_outputs.is_change` no longer present an account's own change
  as a recipient of its transaction. Balances were unaffected.
- An address that had received only Ironwood notes is treated as used, so
  `zcashlc_get_next_available_address` no longer hands it out again and the receiving account is
  reported as involved in the transaction that paid it.
- The funding account recorded for a transparent output counts value spent from the Ironwood pool, so
  an output funded entirely from Ironwood is attributed to the funding account and one funded from
  several pools to its largest contributor.
- `zcashlc_transaction_data_requests` derives status requests from durable observation intent: a sent
  transaction is queried by txid when the wallet cannot observe one of its shielded spends or outputs,
  intent sleeps while a transaction is mined and revives after a rewind, and redundant requests for
  wallet-observable transactions are no longer produced.
- The Tor HTTP and gRPC transports bound each network operation, so `zcashlc_get_exchange_rate_usd`,
  `zcashlc_tor_http_get` / `_post` and the `zcashlc_tor_lwd_conn_*` calls fail with an error instead
  of hanging against a server that accepts a connection and then never responds. They also reject a
  URL whose scheme is neither `http` nor `https`, which was previously treated as plaintext HTTP.

## 2.7.0-rc.3 - 2026-07-28

### Changed
- Migrated to `zcash_protocol 0.10.2`, `zcash_client_backend 0.24.0-rc.5`,
  `zcash_client_sqlite 0.22.0-rc.5`.
- `zcashlc_propose_transfer` and `zcashlc_propose_transfer_from_uri`: once NU6.3 is active, a single
  payment of a canonical ZIP 318 denomination crossing the Orchard turnstile is proposed as a
  canonical crossing — one fewer ZIP 317 marginal-fee action, and up to two anchor-bucket intervals of
  additional confirmations on its inputs beyond `confirmations_policy`. A payment that cannot be
  funded that way is proposed as an ordinary transaction.
- `zcashlc_init_data_database` applies new migrations that repair the data described under Fixed
  below. No rescan is required.

### Fixed
- Ironwood notes received on an account's internal address are classified as change, so
  `v_transactions.has_change` and `v_tx_outputs.is_change` no longer present an account's own change
  as a recipient of its transaction. Balances were unaffected.
- An address that had received only Ironwood notes is treated as used, so
  `zcashlc_get_next_available_address` no longer hands it out again and the receiving account is
  reported as involved in the transaction that paid it.
- The funding account recorded for a transparent output counts value spent from the Ironwood pool, so
  an output funded entirely from Ironwood is attributed to the funding account and one funded from
  several pools to its largest contributor.
- `zcashlc_transaction_data_requests` derives status requests from durable observation intent: a sent
  transaction is queried by txid when the wallet cannot observe one of its shielded spends or outputs,
  intent sleeps while a transaction is mined and revives after a rewind, and redundant requests for
  wallet-observable transactions are no longer produced.
- The Tor HTTP and gRPC transports bound each network operation, so `zcashlc_get_exchange_rate_usd`,
  `zcashlc_tor_http_get` / `_post` and the `zcashlc_tor_lwd_conn_*` calls fail with an error instead
  of hanging against a server that accepts a connection and then never responds. They also reject a
  URL whose scheme is neither `http` nor `https`, which was previously treated as plaintext HTTP.

## 2.7.0-rc.2 - 2026-07-26

### Changed
- Migrated to `zcash_client_backend 0.24.0-rc.4`,
  `zcash_client_sqlite 0.22.0-rc.4`, `pczt 0.9.1`.
- `zcashlc_redact_pczt_for_signer` requests `zcash_client_backend`'s full
  (non-compacted) signer view rather than the compact one, and the PCZT it
  returns is serialized at the minimal encoding version capable of
  representing its content (v1 for a v5 transaction) rather than always v2.
  Deployed hardware signers do not provide the receiver capabilities the
  compact view and v2 encoding require. The full view also clears Ironwood
  spend witnesses and output metadata alongside the other bundles.
- `zcashlc_add_proofs_to_pczt` reuses a cached Orchard-family proving key
  across the Orchard and Ironwood proofs (both use the same PostNu6_3 circuit
  after NU6.3) instead of rebuilding it for each, and derives the Ironwood
  circuit version from the PCZT's consensus branch id rather than hardcoding
  it. The resulting proofs are unchanged.

### Fixed
- `zcashlc_propose_send_max_transfer` now spends from the Ironwood pool in
  addition to Sapling and Orchard, so a post-NU6.3 wallet's Ironwood funds are
  no longer silently excluded from a send-max. This affects only the general
  send-max proposal; the spend set used by
  `zcashlc_propose_orchard_to_ironwood_migration` is unchanged. There is no
  Swift API for the general send-max proposal; `zcashlc_propose_send_max_transfer`
  is reachable only through the C FFI.
- PCZTs created by `zcashlc_create_pczt_from_proposal` for post-NU6.3 (v6)
  transactions carry ZIP 32 derivation metadata on the wallet-controlled
  zero-value Orchard spends that pad them (via
  `zcash_client_backend 0.24.0-rc.4`), so external Signers can identify and
  sign them. Previously those actions were unsignable and extraction failed
  with a missing spend-auth signature.

## 2.7.0-rc.1 - 2026-07-25

### Added
- `zcashlc_put_ironwood_subtree_roots`: Store Ironwood subtree roots in the
  wallet database, mirroring the Sapling and Orchard entry points.
- `zcashlc_propose_orchard_to_ironwood_migration`: Propose migrating an
  account's entire Orchard balance into the Ironwood pool.
- The wallet-summary FFI structs gained `ironwood_balance` on the per-account
  balance and `next_ironwood_subtree_index` on the summary.

### Changed
- Migrated to the Ironwood (NU6.3) releases: `orchard` 0.14→0.15,
  `zcash_client_backend` 0.23→0.24.0-rc.2, `zcash_client_sqlite`
  0.21→0.22.0-rc.2, `zcash_primitives`/`zcash_proofs` 0.28→0.30,
  `zcash_protocol` 0.9→0.10, `zcash_address` 0.12→0.13, `zcash_transparent`
  0.8→0.10, `pczt` 0.7→0.8, `zcash_keys` 0.14→0.16; the `[patch.crates-io]`
  git overrides were dropped.
- `zcashlc_add_proofs_to_pczt` also proves Ironwood bundles.
- Once NU6.3 activates, a payment to an Orchard receiver is delivered through
  the Ironwood bundle of a version 6 transaction: proposals returned by
  `zcashlc_propose_transfer` report such payments and the change from Ironwood
  spends as Ironwood-pool outputs, and `zcashlc_create_proposed_transactions`
  and `zcashlc_create_pczt_from_proposal` build the version 6 transaction.
  Fee and change calculation derive the Orchard bundle version from the
  proposal's target height, charging one ZIP 317 action per Orchard spend or
  output at or beyond activation rather than `max(spends, outputs)`, with
  Ironwood spends, outputs and change charged against the Ironwood bundle.

### Removed
- The `zcashlc_voting_*` FFI is no longer compiled. `zcash_voting` cannot
  resolve against the Ironwood (NU6.3) `orchard` release, so the `voting`
  module is gated behind `#[cfg(zcash_voting)]` and the
  `zcash_voting`/`zcash_keys` dependencies are commented out in `Cargo.toml`.
  The module sources are retained so the surface can be reinstated once the
  voting crates support the Ironwood dependency stack.

### Fixed
- `zcashlc_delete_account` no longer fails with a rusqlite
  `InvalidParameterName(":address")` error when the account being deleted is
  recorded as the recipient of one of its own sent outputs. Wallets on the 2.6
  line received this fix in 2.6.0-alpha.6.

## 2.6.0-alpha.6 - 2026-06-26

### Fixed
- Updated `zcash_client_sqlite` to 0.21.1, fixing an `InvalidParameterName` error in `delete_account` when the account being deleted is referenced by a `sent_notes` row via its `to_account_id` column (i.e. an account involved in a cross-account transfer) ([librustzcash#2426](https://github.com/zcash/librustzcash/pull/2426)).

## 2.6.0-alpha.4 - 2026-06-04

### Changed
- Migrated to the released crates.io versions listed under 2.5.2 below,
  including `zcash_protocol` 0.9, which sets the NU6.2 activation heights
  (mainnet 3364600, testnet 4052000). The FFI surface is unchanged.

## 2.5.2 - 2026-06-03

### Changed
- Migrated to released crates.io versions of the Zcash crates: `orchard`
  0.13.1→0.14, `zcash_client_backend` 0.22→0.23, `zcash_client_sqlite`
  0.20.2→0.21, `zcash_keys` 0.13→0.14, `zcash_primitives`/`zcash_proofs`
  0.27→0.28, `zcash_protocol` 0.8→0.9, `zcash_address` 0.11→0.12,
  `zcash_transparent` 0.7→0.8, `pczt` 0.6→0.7. `zcash_protocol` 0.9 carries
  the NU6.2 activation heights (mainnet 3364600, testnet 4052000), so
  transactions targeting those heights and above are built against the NU6.2
  consensus branch id. The FFI surface is unchanged.

## 2.6.0-alpha.3 - 2026-05-27

### Changed
- Updated `zcash_voting` to 0.10.1, taken from the released crate rather than a
  git revision. No `zcashlc_voting_*` entry points were added or removed.

## 2.6.0-alpha.2 - 2026-05-18

### Changed
- Updated `zcash_voting` to 0.8.1 (from 0.6.0). No `zcashlc_voting_*` entry
  points were added or removed.

## 2.5.1 - 2026-05-15

### Changed
- Replaced the `[patch.crates-io]` git pin on the librustzcash crates with
  their published releases: `zcash_client_backend 0.22.0`,
  `zcash_client_sqlite 0.20.2`, `zcash_keys 0.13.0`, `pczt 0.6.0`,
  `zcash_primitives`/`zcash_proofs 0.27.1`, `zcash_protocol 0.8.0`,
  `zcash_address 0.11.0`, `zcash_transparent 0.7.0`.

### Fixed
- Proposing a transaction that shields more than 150 transparent P2PKH inputs
  no longer fails from an incorrect fee computation.

## 2.6.0-alpha.1 - 2026-05-12

### Added
- The `zcashlc_voting_*` surface grew from the 11 entry points added in 2.5.0
  to 59, covering the voting-database handle, round setup and state, vote
  commitment and share-payload construction, share encryption, delegation PIR
  precomputation, vote-tree sync, VAN and note witness generation, and the
  vote/delegation transaction-hash store. All of them were removed again in
  2.7.0-rc.1.

## 2.5.0 - 2026-05-11

### Added
- `zcashlc_voting_compute_share_nullifier`: Compute the 32-byte share-reveal
  nullifier from a vote commitment, primary blind, and share index. Returns
  the nullifier as a 64-character hex C-string; the caller must free the
  returned pointer via `zcashlc_string_free`. Returns `NULL` on error or
  panic. Pure-function FFI: no wallet DB, voting DB, network, randomness,
  or secret material involved.
- `zcashlc_voting_validate_pir_proof`: Validate a PIR-fetched IMT
  non-membership proof against an expected root.
- `zcashlc_voting_db_open`, `zcashlc_voting_db_free`, and
  `zcashlc_voting_set_wallet_id`: Manage the voting database handle used by
  stateful voting FFI calls.
- `zcashlc_voting_precompute_delegation_pir`: Precompute and cache delegation
  PIR IMT proofs for a voting bundle using the configured voting database and
  caller-supplied PIR endpoint.
- `zcashlc_voting_sync_vote_tree`: Sync the vote commitment tree for a round
  from a chain node URL, returning the latest synced block height (>= 0) on
  success, or -1 on error.
- `zcashlc_voting_generate_van_witness`: Generate a vote authority note Merkle witness for
  the second voting ZKP and return it as a JSON-encoded `VanWitness`
  (`auth_path`, `position`, `anchor_height`) in a `*mut FfiBoxedSlice`.
- `zcashlc_voting_reset_tree_client`: Drop the in-memory tree client for a
  round so the next `zcashlc_voting_sync_vote_tree` call creates a fresh one.
- `zcashlc_voting_warm_proving_caches`, `zcashlc_voting_decompose_weight`,
  `zcashlc_voting_generate_delegation_inputs`,
  `zcashlc_voting_generate_delegation_inputs_with_fvk`,
  `zcashlc_voting_extract_pczt_sighash`,
  `zcashlc_voting_extract_spend_auth_sig`,
  `zcashlc_voting_extract_nc_root`, and `zcashlc_voting_verify_witness`:
  Utility FFI for voting proof setup, PCZT/signature extraction,
  note-commitment root extraction, and witness verification.
- `FfiRoundState`, `FfiVotingHotkey`, `FfiBundleSetupResult`,
  `FfiRoundSummaries`, and `FfiVoteRecords`, plus their
  `zcashlc_voting_free_*` helpers, for C-compatible voting return values.
- `zcashlc_voting_generate_note_witnesses`: Generate Orchard Merkle inclusion
  witnesses for the notes in a voting bundle, anchored at the round's snapshot
  height.
- `VotingDatabaseHandle` now also carries a
  `zcash_voting::tree_sync::VoteTreeSync`, constructed in
  `zcashlc_voting_db_open` and consumed by the tree-sync FFI above.
- `zcashlc_voting_init_round`, `zcashlc_voting_get_round_state`,
  `zcashlc_voting_list_rounds`, `zcashlc_voting_get_votes`,
  `zcashlc_voting_clear_round`, `zcashlc_voting_delete_skipped_bundles`,
  recovery-state transaction/hash/signature helpers, and share-delegation
  tracking helpers for persisted voting round state.
- `zcashlc_voting_generate_hotkey`, `zcashlc_voting_setup_bundles`,
  `zcashlc_voting_get_bundle_count`, `zcashlc_voting_build_pczt`,
  `zcashlc_voting_store_tree_state`,
  `zcashlc_voting_build_and_prove_delegation`,
  `zcashlc_voting_get_delegation_submission`,
  `zcashlc_voting_get_delegation_submission_with_keystone_sig`, and
  `zcashlc_voting_store_van_position` for the delegation workflow FFI.
- `zcashlc_voting_encrypt_shares`, `zcashlc_voting_build_vote_commitment`,
  `zcashlc_voting_build_share_payloads`, `zcashlc_voting_mark_vote_submitted`,
  and `zcashlc_voting_sign_cast_vote` for the vote-casting FFI.
- `zcashlc_voting_get_wallet_notes`: Load unspent Orchard notes for a wallet
  account at a snapshot height and return them as JSON-encoded
  `Vec<NoteInfo>` in a `*mut FfiBoxedSlice`. `account_uuid` must be a non-null
  pointer to exactly 16 bytes (binary account UUID). Returns `NULL` on error
  or panic. Output is suitable as the `notes_json` input to
  `zcashlc_voting_precompute_delegation_pir`.
- `zcashlc_voting_extract_orchard_fvk_from_ufvk`: Decode a UFVK string and
  return the raw 96-byte Orchard full viewing key in a
  `*mut FfiBoxedSlice`. Returns `NULL` on missing Orchard component,
  malformed UFVK, or invalid `network_id`.
- Added `zcash_voting 0.5.7` (`default-features = false`, `client-pir`,
  `client-tree-sync`) as a Rust dependency.
- Added `zcash_keys 0.13` (`orchard` feature) as a Rust dependency, used by
  the new wallet-notes and key-utility FFI for voting to decode UFVKs and derive
  Orchard FVKs.
- Added `incrementalmerkletree 0.8` (`default-features = false`) as a direct
  Rust dependency, used by `zcashlc_voting_generate_note_witnesses` for
  `Position` and the `MerklePath` returned by the wallet DB.

### Changed
- Pinned `orchard` to `=0.13.1` and enabled its `unstable-voting-circuits`
  feature (required transitively by `zcash_voting`).
- Enabled the `client-tree-sync` feature on `zcash_voting`, required by the
  new tree-sync FFI symbols and by the `VoteTreeSync` field on
  `VotingDatabaseHandle`.

## 2.4.6 - 2026-03-12

### Changed
- This is the first release using Github artifact-based deployment. Users should 
  obtain releases from <TBD>

## 0.19.2 - 2026-03-02

### Fixed
- Updated to `shardtree 0.6.2, zcash_client_sqlite 0.19.4` to fix a note
  commitment tree corruption bug.

## 0.19.1 - 2025-11-26

### Added
- `ffi::ZecUsdExchange`
- `zcashlc_get_exchange_rate_usd_from`

### Changed
- Reduced the number of exchanges queried for ZEC/USD back to the number we had
  in 0.18 and earlier, to reduce power consumption.

## 0.19.0 - 2025-11-04

### Added
- `ffi::AddressCheckResult`
- `ffi::SingleUseTaddr`
- `zcashlc_get_single_use_taddr`
- `zcashlc_free_single_use_taddr`
- `zcashlc_tor_lwd_conn_check_single_use_taddr`
- `zcashlc_free_address_check_result`
- `zcashlc_propose_send_max_transfer`
- `zcashlc_tor_lwd_conn_update_transparent_address_transactions`
- `zcashlc_tor_lwd_conn_fetch_utxos_by_address`
- `zcashlc_delete_account`

### Changed
- MSRV is now 1.90.
- Migrated to `zcash_client_backend 0.21`, `zcash_client_sqlite 0.19`, `pczt-0.5`.

## 0.18.5 - 2025-10-23

### Changed
- Updated to `zcash_client_sqlite-0.18.9` to fix problems in transparent UTXO
  selection for shielding, including incorrect handling of outputs received at
  ephemeral addresses and selection of dust transparent outputs for shielding.

## 0.18.4 - 2025-10-16

### Changed
- Updated to `zcash_client_sqlite-0.18.7` to improve consistency of spentness
  determination, reliability of transaction status request generation,
  and fix removal of already-fulfilled transaction enhancement requests.

## 0.18.3 - 2025-10-08

### Fixed
- Updated to `zcash_client_sqlite-0.18.4` to fix a problem with balance calculation
  related to detection of spends of outputs received by the wallet's ephemeral
  addresses.

## 0.18.2 - 2025-10-01

### Fixed
- Updated to `zcash_client_sqlite-0.18.3` to fix a problem with display of
  zero-conf-shielded fully transparent transactions.

## 0.18.1 - 2025-09-29

### Fixed
- Updated to `zcash_client_sqlite-0.18.2` to fix a problem with zero-conf shielding.

## 0.18.0 - 2025-09-26

### Added

- `ConfirmationsPolicy`

### Changed

- Updated to `zcash_client_backend 0.20`, `zcash_client_sqlite 0.18`.
- functions now take `confirmations_policy: ConfirmationsPolicy` instead of `min_confirmations: u32`:

  * `zcashlc_get_wallet_summary`
  * `zcashlc_get_verified_transparent_balance`
  * `zcashlc_get_verified_transparent_balance_for_account`
  * `zcashlc_propose_transfer`
  * `zcashlc_propose_send_max_transfer`
  * `zcashlc_propose_transfer_from_uri`
  * `zcashlc_propose_shielding`

## 0.17.1 - 2025-08-29

### Changed
- Updated to `zcash_client_sqlite 0.17.3` (hotfix release).

### Fixed
- This release fixes a potential false-positive in the `expired_unmined` column
  of the `v_transactions` view.

## 0.17.0 - 2025-06-04

### Added
- `FfiHttpRequestHeader`
- `FfiHttpResponseBytes`
- `FfiHttpResponseHeader`
- `TorDormantMode`
- `zcashlc_free_http_response_bytes`
- `zcashlc_tor_http_get`
- `zcashlc_tor_http_post`
- `zcashlc_tor_set_dormant`

### Changed
- MSRV is now 1.87.
- Updated to `zcash_client_backend 0.19`, `zcash_client_sqlite 0.17`.

## 0.16.0 - 2025-05-13

### Added
- `OutputStatusFilter`
- `TransactionStatusFilter`

### Changed
- `zcashlc_get_next_available_address` now takes an additional `receiver_flags`
  argument that permits the caller to specify which receivers should be
  included in the generated unified address.
- `FfiTransactionDataRequest` variant `SpendsFromAddress` has been renamed to
  `TransactionsInvolvingAddress` and has new fields.

## 0.15.0 - 2025-04-24

### Added
- `zcashlc_tor_lwd_conn_get_info`
- `zcashlc_tor_lwd_conn_get_tree_state`
- `zcashlc_tor_lwd_conn_latest_block`

### Changed
- `FfiWalletSummary` has a new field `recovery_progress`.
- `FfiWalletSummary.scan_progress` now only tracks the progress of making
  existing wallet balance spendable. In some cases (depending on how long a
  wallet was offline since its last sync) it may also happen to include progress
  of discovering new notes, but in general `FfiWalletSummary.recovery_progress`
  now covers the discovery of historic wallet information.

### Fixed
- `zcashlc_tor_lwd_conn_fetch_transaction` now correctly returns `null` as the
  error sentinel instead of a "none" `FfiBoxedSlice`.

## 0.14.2 - 2025-04-02

### Fixed
- This fixes an error in the `transparent_gap_limit_handling` migration,
  whereby wallets having received transparent outputs at child indices below
  the index of the default address could cause the migration to fail.

## 0.14.1 - 2025-03-27

### Fixed
- This fixes an error in the `transparent_gap_limit_handling` migration,
  whereby wallets that received Orchard outputs at diversifier indices for
  which no Sapling receivers could exist would incorrectly attempt to
  derive UAs containing sapling receivers at those indices.

## 0.14.0 - 2025-03-21

### Added
- `zcashlc_fix_witnesses`

### Changed
- MSRV is now 1.85.
- Updated to `zcash_client_backend 0.18`, `zcash_client_sqlite 0.16`.
- Added support for gap-limit-based discovery of transparent wallet addresses.

## 0.13.0 - 2025-03-04

### Added
- `FfiAccountMetadataKey`
- `FfiSymmetricKeys`
- `zcashlc_account_metadata_key_from_parts`
- `zcashlc_derive_account_metadata_key`
- `zcashlc_derive_private_use_metadata_key`
- `zcashlc_free_account_metadata_key`
- `zcashlc_free_symmetric_keys`
- `zcashlc_free_tor_lwd_conn`
- `zcashlc_pczt_requires_sapling_proofs`
- `zcashlc_redact_pczt_for_signer`
- `zcashlc_tor_connect_to_lightwalletd`
- `zcashlc_tor_isolated_client`
- `zcashlc_tor_lwd_conn_fetch_transaction`
- `zcashlc_tor_lwd_conn_submit_transaction`

### Changed
- MSRV is now 1.84.
- `FfiAccount` now has a `ufvk` string field.

## 0.12.0 - 2024-12-16

### Added
- `FfiUuid`
- `zcashlc_free_ffi_uuid`
- `zcashlc_get_account`
- `zcashlc_free_account`
- `FfiAddress`
- `zcashlc_free_ffi_address`
- `zcashlc_derive_address_from_ufvk`
- `zcashlc_derive_address_from_uivk`
- `zcashlc_create_pczt_from_proposal`
- `zcashlc_add_proofs_to_pczt`
- `zcashlc_extract_and_store_from_pczt`

### Changed
- Updated dependencies:
  - `sapling-crypto 0.4`
  - `orchard 0.10.1`
  - `zcash_primitives 0.21`
  - `zcash_proofs 0.21`
  - `zcash_keys 0.6`
  - `zcash_client_backend 0.16`
  - `zcash_client_sqlite 0.14`
- `FfiAccounts` now contains `FfiUuid`s instead of `FfiAccount`s.
- `FfiAccount` has changed:
  - It must now be freed with `zcashlc_free_account`.
  - Added fields `uuid_bytes`, `account_name`, `key_source`.
  - Renamed `account_index` field to `hd_account_index`.
- The following structs now have an `account_uuid` field instead of an
  `account_id` field:
  - `FFIBinaryKey`
  - `FFIEncodedKey`
  - `FfiAccountBalance`
- The following functions now have additional arguments `account_name` (which
  must be set) and `key_source` (which may be null):
  - `zcashlc_create_account`
  - `zcashlc_import_account_ufvk`
- `zcashlc_import_account_ufvk` now has additional arguments `seed_fingerprint`
  and `hd_account_index_raw`, which must either both be set or both be "null"
  values.
- `zcashlc_import_account_ufvk` now returns `*mut FfiUuid` instead of `i32`.
- The following functions now take an `account_uuid_bytes` pointer to a byte
  array, instead of an `i32`:
  - `zcashlc_get_current_address`
  - `zcashlc_get_next_available_address`
  - `zcashlc_list_transparent_receivers`
  - `zcashlc_get_verified_transparent_balance_for_account`
  - `zcashlc_get_total_transparent_balance_for_account`
  - `zcashlc_propose_transfer`
  - `zcashlc_propose_transfer_from_uri`
  - `zcashlc_propose_shielding`
- `zcashlc_derive_spending_key` now returns `*mut FfiBoxedSlice` instead of
  `*mut FFIBinaryKey`.

### Removed
- `zcashlc_get_memo_as_utf8`

## 0.11.0 - 2024-11-15

### Added
- `zcashlc_derive_arbitrary_wallet_key`
- `zcashlc_derive_arbitrary_account_key`

### Changed
- Updated `librustzcash` dependencies:
  - `zcash_primitives 0.20`
  - `zcash_proofs 0.20`
  - `zcash_keys 0.5`
  - `zcash_client_backend 0.15`
  - `zcash_client_sqlite 0.13`
- Updated to `rusqlite` version `0.32`
- Updated to `tor-rtcompat` version `0.23`
- `zcashlc_propose_transfer`, `zcashlc_propose_transfer_from_uri` and
  `zcashlc_propose_shielding` no longer accpt a `use_zip317_fees` parameter;
  ZIP 317 standard fees are now always used and are not configurable.

## 0.10.2 - 2024-10-22

### Changed
- Updated to `zcash_client_sqlite` version `0.12.2`

### Fixed
- This release fixes an error in wallet rewind that could cause a crash in the
  wallet backend in certain circumstances.

### Changed
- Updated to `zcash_client_sqlite` version `0.12.1`

## 0.10.1 - 2024-10-10

### Changed
- Updated to `zcash_client_sqlite` version `0.12.1`

### Fixed
- This release fixes an error in scan progress computation that could, under
  certain circumstances, result in scan progress values greater than 100% being
  reported.

## 0.10.0 - 2024-10-04

### Changed
- `zcashlc_rewind_to_height` now returns an `i64` value instead of a boolean. The
  value `-1` indicates failure; any other height indicates the height to which the
  data store was actually truncated. Also, this procedure now takes an additional
  `safe_rewind_ret` parameter that, on failure to rewind, will be set to the
  minimum height for which the rewind would succeed, or to -1 if
  no such height can be determined.

### Removed
- `zcashlc_get_nearest_rewind_height` has been removed. The return value of
  `zcashlc_rewind_to_height`, or in the case of rewind failure the value of its
  `safe_rewind_ret` return parameter should be used instead.

### Fixed
- This release fixes a potential source of corruption in wallet note commitment
  trees related to incorrect handling of chain reorgs. It includes a database
  migration that will repair the corrupted database state of any wallet
  affected by this corner case.

## 0.9.1 - 2024-08-21

### Fixed
- A database migration misconfiguration that could results in problems with wallet
  initialization was fixed.

## 0.9.0 - 2024-08-20

### Added
- `zcashlc_create_tor_runtime`
- `zcashlc_free_tor_runtime`
- `zcashlc_get_exchange_rate_usd`
- `zcashlc_set_transaction_status`
- `zcashlc_transaction_data_requests`
- `zcashlc_free_transaction_data_requests`
- `FfiTransactionStatus_Tag`
- `FfiTransactionStatus`
- `FfiTransactionDataRequest_Tag`
- `SpendsFromAddress_Body`
- `FfiTransactionDataRequest`
- `FfiTransactionDataRequests`
- `Decimal`

### Changed
- MSRV is now 1.80.
- Migrated to `zcash_client_sqlite 0.11`.
- `zcashlc_init_on_load` now takes a log level filter as a UTF-8 C string, instead of
  a boolean.
- The following methods now support ZIP 320 (TEX) addresses:
  - `zcashlc_get_address_metadata`
  - `zcashlc_propose_transfer`
- `zcashlc_decrypt_and_store_transaction` now takes its `mined_height` argument
  as `int64_t`. This allows callers to pass the value of `mined_height` as
  returned by the zcashd `getrawtransaction` RPC method.

### Removed
- `zcashlc_is_valid_sapling_address`, `zcashlc_is_valid_transparent_address`,
  `zcashlc_is_valid_unified_address` (use `zcashlc_get_address_metadata` instead).

## 0.8.1 - 2024-06-14

### Fixed
- Further changes for compatibility with XCode 15.3 and above.

## 0.8.0 - 2024-04-17

### Added
- `zcashlc_is_valid_sapling_address`

### Changed
- Updates to `zcash_client_sqlite` version `0.10.3` to add migrations that ensure the
  wallet's default Unified address contains an Orchard receiver.
- `zcashlc_get_memo` now takes an additional `output_pool` parameter. This fixes a problem
  with the retrieval of Orchard memos.

### Removed
- `zcashlc_is_valid_shielded_address` - use `zcashlc_is_valid_sapling_address` instead.

## 0.7.4 - 2024-03-28

### Added
- `zcashlc_put_orchard_subtree_roots`

## 0.7.3 - 2024-03-27

- Updates to `zcash_client_backend 0.12.1` to fix a bug in note selection
  when sending to a transparent recipient.

## 0.7.2 - 2024-03-27

- Updates to `zcash_client_sqlite 0.10.2` to fix a bug in an SQL query
  that prevented shielding of transparent funds.

## 0.7.1 - 2024-03-25

- Updates to `zcash_client_sqlite` version 0.10.1 to fix an incorrect
  constraint on the `sent_notes` table. Databases built or upgraded
  using version 0.7.0 will need to be deleted and restored from seed.

## 0.7.0 - 2024-03-25

This version has been yanked due to a bug in zcash_client_sqlite version 0.10.0

## Notable Changes
- Adds Orchard support.

### Added
- Structs and functions for listing accounts in the wallet:
  - `zcashlc_list_accounts`
  - `zcashlc_free_accounts`
  - `FfiAccounts`
  - `FfiAccount`
- `zcashlc_is_seed_relevant_to_any_derived_account`

### Changed
- Update to zcash_client_backend version 0.12.0 and zcash_client_sqlite version
  0.10.0.
- `zcashlc_scan_blocks` now takes a `TreeState` protobuf object that provides
  the frontiers of the note commitment trees as of the end of the block prior to
  the range being scanned.

## 0.6.0 - 2024-03-07

### Added
- `zcashlc_create_proposed_transactions`

### Changed
- Migrated to `zcash_client_sqlite 0.9`.

- `zcashlc_propose_shielding` now raises an error if more than one transparent
  receiver has funds that require shielding, to avoid creating transactions that
  link these receivers on chain. It also now takes a `transparent_receiver`
  argument that can be used to select a specific receiver for which to shield
  funds.
- `zcashlc_propose_shielding` now returns a "none" `FfiBoxedSlice` (with its
  `ptr` field set to `null`) if there are no funds to shield, or if the funds
  are below `shielding_threshold`.

### Removed
- `zcashlc_create_proposed_transaction`
  (use `zcashlc_create_proposed_transactions` instead).

## 0.5.1 - 2024-01-30

Update to `librustzcash` tag `ecc_sdk-20240130a`.

### Fixes
This release fixes a problem in the serialization of transaction proposals having
empty transaction requests (shielding transactions are change-only and contain
no payments.)

## 0.5.0 - 2024-01-29

## Notable Changes

This release updates the `librustzcash` dependencies to the stable interim tag
`ecc_sdk-20240129`. This provides improvements to wallet query performance that
have not yet been released in a published version of the `zcash_client_sqlite`
crate, as well as numerous unreleased changes to the `zcash_client_backend` and
`zcash_primitives` crates.

### Added
- FFI data structures:
  - `FfiBalance`
  - `FfiAccountBalance`
  - `FfiWalletSummary`
  - `FfiScanSummary`
  - `FfiBoxedSlice`
- FFI methods:
  - `zcashlc_propose_transfer`
  - `zcashlc_propose_transfer_from_uri`
  - `zcashlc_propose_shielding`
  - `zcashlc_create_proposed_transaction`
  - `zcashlc_get_wallet_summary`
  - `zcashlc_free_wallet_summary`
  - `zcashlc_free_boxed_slice`
  - `zcashlc_free_scan_summary`

### Changed
- `zcashlc_scan_blocks` now returns a `FfiScanSummary` value.

### Removed
- `zcashlc_get_balance` (use `zcashlc_get_wallet_summary` instead)
- `zcashlc_get_scan_progress` (use `zcashlc_get_wallet_summary` instead)
- `zcashlc_get_verified_balance` (use `zcashlc_get_wallet_summary` instead)
- `zcashlc_create_to_address` (use `zcashlc_propose_transfer`  and
  `zcashlc_create_proposed_transaction` instead)
- `zcashlc_shield_funds` (use `zcashlc_propose_shielding`  and
  `zcashlc_create_proposed_transaction` instead)

## 0.4.1 - 2023-10-20

### Issues Resolved
- [#103] Update to `zcash_client_sqlite` with a fix for
  [incorrect note deduplication in `v_transactions`](https://github.com/zcash/librustzcash/pull/1020).

Updated dependencies:
  - `zcash_client_sqlite 0.8.1`

## 0.4.0 - 2023-09-25

### Notable Changes

This release overhauls the FFI library to provide support for allowing wallets to
spend funds without fully syncing the blockchain. This results in significant
changes to much of the API; it is recommended that users review the changes
from the previous release carefully.

### Changed
- `anyhow` is now used for error management

### Issues Resolved
- [#95] Update to `zcash_client_backend` and `zcash_client_sqlite` with fast sync support

Updated dependencies:
  - `zcash_address 0.3`
  - `zcash_client_backend 0.10.0`
  - `zcash_client_sqlite 0.8.0`
  - `zcash_primitives 0.13.0`
  - `zcash_proofs 0.13.0`

  - `orchard 0.6`
  - `ffi_helpers 0.3`
  - `secp256k1 0.26`

Added dependencies:
  - `anyhow 0.1`
  - `prost 0.12`
  - `cfg-if 1.0`
  - `rayon 1.7`
  - `log-panics 2.0`
  - `once_cell 1.0`
  - `sharded-slab 0.1`
  - `tracing 0.1`
  - `tracing-subscriber 0.3`

## 0.3.1
- [#88] unmined transaction shows note value spent instead of tx value

Fixes an issue where a sent transaction would show the whole note spent value
instead of the value of that the user meant to transfer until it was mined.

## 0.3.0

- [#87] Outbound transactions show the wrong amount on v_transactions

removes `v_tx_received` and `v_tx_sent`.

`v_transactions` now shows the `account_balance_delta` column where the clients can
query the effect of a given transaction in the account balance. If fee was paid from
the account that's being queried, the delta will include it. Transactions where funds
are received into the queried account, will show the amount that the acount is receiving
and won't include the transaction fee since it does not change the balance of the account.

Creates `v_tx_outputs` that allows clients to know the outputs involved in a transaction.

## 0.2.0

- [#34] Fix SwiftPackageManager deprecation Warning
We had to change the name of the package to make it match the name
of the github repository due to Swift Package Manager conventions.

please see README.md for more information on how to import this package
going forward.

### FsBlock Db implementation and removal of BlockBb cache.

Implements `zcashlc_init_block_metadata_db`, `zcashlc_write_block_metadata`,
`zcashlc_free_block_meta`, `zcashlc_free_blocks_meta`

Declare `repr(C)` structs for FFI:
 - `FFIBlockMeta`: a block metadata row
 - `FFIBlocksMeta`: a structure that holds an array of `FFIBlockMeta`


expose shielding threshold for `shield_funds`

- [#81] Adopt latest crate versions
Bumped dependencies to `zcash_primitives 0.10`, `zcash_client_backend 0.7`,
`zcash_proofs 0.10`, `zcash_client_sqlite 0.5.0`

this adds support for `min_confirmations` on `shield_funds` and `shielding_threshold`.
- [#78] removing cocoapods support

## 0.1.1

Updating:
````
 - zcash_client_backend v0.6.0 -> v0.6.1
 - zcash_client_sqlite v0.4.0 -> v0.4.2
 - zcash_primitives v0.9.0 -> v0.9.1
````
This fixes the following issue
- [#72] fixes get_transparent_balance() fails when no UTXOs

## 0.1.0

Unified spending keys are now used in all places where spending authority
is required, both for performing spends of shielded funds and for shielding
transparent funds. Unified spending keys are represented as opaque arrays
of bytes, and FFI methods are provided to permit derivation of viewing keys
from the binary unified spending key representation.

IMPORTANT NOTE: the binary representation of a unified spending key may be
cached, but may become invalid and require re-derivation from seed to use as
input to any of the relevant APIs in the future, in the case that the
representation of the spending key changes or new types of spending authority
are recognized.  Spending keys give irrevocable spend authority over
a specific account.  Clients that choose to store the binary representation
of unified spending keys locally on device, should handle them with the
same level of care and secure storage policies as the wallet seed itself.

### Added
- `zcashlc_create_account` provides new account creation functionality.
  This is now the preferred API for the creation of new spend authorities
  within the wallet; `zcashlc_init_accounts_table_with_keys` remains available
  but should only be used if it is necessary to add multiple accounts at once,
  such as when restoring a wallet from seed where multiple accounts had been
  previously derived.

Key derivation API:
- `zcashlc_derive_spending_key`
- `zcashlc_spending_key_to_full_viewing_key`

Address retrieval, derivation, and verification API:
- `zcashlc_get_current_address`
- `zcashlc_get_next_available_address`
- `zcashlc_get_sapling_receiver_for_unified_address`
- `zcashlc_get_transparent_receiver_for_unified_address`
- `zcashlc_is_valid_unified_address`
- `zcashlc_is_valid_unified_full_viewing_key`
- `zcashlc_list_transparent_receivers`
- `zcashlc_get_typecodes_for_unified_address_receivers`
- `zcashlc_free_typecodes`
- `zcashlc_get_address_metadata`
Balance API:
- `zcashlc_get_verified_transparent_balance_for_account`
- `zcashlc_get_total_transparent_balance_for_account`

New memo access API:
- `zcashlc_get_received_memo`
- `zcashlc_get_sent_memo`

### Changed
- `zcashlc_create_to_address` now has been changed as follows:
  - it no longer takes the string encoding of a Sapling extended spending key
    as spend authority; instead, it takes the binary encoded form of a unified
    spending key as returned by `zcashlc_create_account` or
    `zcashlc_derive_spending_key`. See the note above.
  - it now takes the minimum number of confirmations used to filter notes to
    spend as an argument.
  - the memo argument is now passed as a potentially-null pointer to an
    `[u8; 512]` instead of a C string.
- `zcashlc_shield_funds` has been changed as follows:
  - it no longer takes the transparent spending key for a single P2PKH address
    as spend authority; instead, it takes the binary encoded form of a unified
    spending key as returned by `zcashlc_create_account`
    or `zcashlc_derive_spending_key`. See the note above.
  - the memo argument is now passed as a potentially-null pointer to an
    `[u8; 512]` instead of a C string.
  - it no longer takes a destination address; instead, the internal shielding
    address is automatically derived from the account ID.
- Various changes have been made to correctly implement ZIP 316:
  - `FFIUnifiedViewingKey` now stores an account ID and the encoding of a
    ZIP 316 Unified Full Viewing Key.
  - `zcashlc_init_accounts_table_with_keys` now takes a slice of ZIP 316 UFVKs.
- `zcashlc_put_utxo` no longer has an `address_str` argument (the address is
  instead inferred from the script).
- `zcashlc_get_verified_balance` now takes the minimum number of confirmations
  used to filter received notes as an argument.
- `zcashlc_get_verified_transparent_balance` now takes the minimum number of
  confirmations used to filter received notes as an argument.
- `zcashlc_get_total_transparent_balance` now returns a balance that includes
  all UTXOs including those only in the mempool (i.e. those with 0
  confirmations).

### Removed

The following spending key derivation APIs have been removed and replaced by
`zcashlc_derive_spending_key`:
- `zcashlc_derive_extended_spending_key`
- `zcashlc_derive_transparent_private_key_from_seed`
- `zcashlc_derive_transparent_account_private_key_from_seed`

The following viewing key APIs have been removed and replaced by
`zcashlc_spending_key_to_full_viewing_key`:
- `zcashlc_derive_extended_full_viewing_key`
- `zcashlc_derive_shielded_address_from_viewing_key`
- `zcashlc_derive_unified_viewing_keys_from_seed`

The following address derivation APIs have been removed in favor of
`zcashlc_get_current_address` and `zcashlc_get_next_available_address`:
- `zcashlc_get_address`
- `zcashlc_derive_shielded_address_from_seed`
- `zcashlc_derive_transparent_address_from_secret_key`
- `zcashlc_derive_transparent_address_from_seed`
- `zcashlc_derive_transparent_address_from_public_key`

- `zcashlc_init_accounts_table` has been removed in favor of
  `zcashlc_create_account`

## 0.0.3
- [#13] Migrate to `zcash/librustzcash` revision with NU5 awareness (#20)
  This enables mobile wallets to send transactions after NU5 activation.
