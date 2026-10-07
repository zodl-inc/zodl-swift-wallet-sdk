# Gift cards

A gift card is a liberated payment (ZIP 324): a bearer link that carries the key of a small,
single-purpose wallet. The link is any `https` URL whose fragment carries the card, in the `v=1`
format or in the legacy JSON payment-link encoding at `/payment-links/open#vN=`:

```
https://gift.zodl.com/#v=1&key=zgift1…&height=<birthday>[&amount=<ZEC>][&desc=<text>]
https://<host>/payment-links/open#v3=…   (legacy; also v1= and v2=)
```

The key is BIP 39 entropy (empty passphrase); the card wallet is ZIP 32 account 0 of its seed, and
the funds sit at that account's Orchard-only default address (in the Ironwood pool since NU6.3).
The host is not part of the card and the link fragment never reaches a server. Anyone holding the
link can spend the card, including its issuer, who can rederive the key. `GiftCard.origin` reports
the encoding a link was read from (`.zodl` for `v=1`, `.legacyV1`/`.legacyV2`/`.legacyV3`).

Parsing is done by the SDK's rust layer, from the module the card tooling shares, so every client
reads a link the same way:

- The birthday must be at or above the network's NU5 activation height. Cards hold Orchard funds
  only, which cannot exist before NU5, and a lower height would only make the card wallet scan
  millions of blocks for nothing. Such a link throws `giftCardLinkInvalidBirthday`.
- `message` is sanitized: line breaks and other control whitespace become a space, and control and
  invisible formatting characters (bidi overrides and isolates, zero-width spaces and the like)
  are removed. A message that is blank afterwards is `nil`. It is still text anyone could have
  written; show it as untrusted content.
- A malformed `amount` or `desc` is read as absent rather than refusing a funded card; `v`, `key`
  and `height` are strict.

## Redeeming

```swift
// At launch: delete card wallets a crash or a killed app left behind.
try? GiftCardRedeemer.removeLeftoverWallets()

let card = try GiftCard(link: scannedText)          // offline; see "Errors" below

let redeemer = try GiftCardRedeemer(
    card: card,
    network: ZcashNetworkBuilder.network(for: .mainnet),
    endpoint: endpoint,                              // the app's lightwalletd endpoint
    isTorEnabled: mainWalletUsesTor                  // the main wallet's Tor setting
)

let status = try await redeemer.check()             // syncs the card wallet from its birthday
switch status.state {
case .ready:   break                                // show status.redeemable: current Orchard preview, after status.fee
case .pending: break                                // waiting for 10 confirmations; check() again later
case .dust:    break                                // the fee would take everything; nothing to redeem
case .empty:   break                                // already redeemed, or never funded
}

await mainSynchronizer.stopAndWait()                // optional: await the main wallet's stop operation
let redemption = try await redeemer.redeem(
    to: myUnifiedAddress,                           // same network, with an Orchard receiver
    memo: try Memo(string: "Gift card"),
    recordIn: mainSynchronizer                       // the wallet myUnifiedAddress belongs to
)
// redemption.results: one TransactionSubmitResult per created transaction (usually one)
// redemption.amount and redemption.fee come from the actual proposal.
// Later note or chain changes can make them differ from the earlier status preview.
// redemption.recordedInDestination: the trusted claim is visible in main-wallet history
// Recording alone does not confirm the claim or make its funds spendable (ZIP 315).
try await mainSynchronizer.start()

try await redeemer.cleanup()                        // stops and deletes the temporary wallet
```

- `statedAmount` and `message` come from the link and are unverified. Show `GiftCardStatus`
  amounts as the card's value, and the message as untrusted user content.
- `redeem(to:memo:recordIn:)` sends the whole spendable balance, with the optional `memo`, minus
  the ZIP 317 fee (normally 10,000 zatoshis, which a card is funded with on top of its face value).
  It discards the outgoing viewing key, so the card's key cannot reveal the recipient; the
  redeeming wallet still records the incoming payment as usual. `redeem(to:memo:)` does the same
  without a destination and returns the results alone.
- Both redemption overloads require a same-network unified address with an Orchard receiver.
  Orchard-only and multi-receiver addresses that include Orchard are accepted unchanged. An address
  without Orchard throws `giftCardRecipientRequiresOrchard` before proposal or claim creation.
- `check()` derives `fee` and `redeemable` from a send-max proposal to the card's Orchard-only
  address, previewing the Orchard-capable recipient class redemption accepts. It is a snapshot of
  current notes and chain height. Later note or chain changes can change the actual proposal's fee
  and amount; use `Redemption.fee` and `Redemption.amount` for the actual result.
- Sapling parameters are unnecessary only if the actual proposal has no Sapling inputs or outputs.
  Input selection is unchanged, so an Orchard recipient alone does not guarantee this.

## Confirmations (ZIP 315)

[ZIP 315](https://zips.z.cash/zip-0315) distinguishes trusted notes (the wallet's own change, or
outputs of transactions the wallet chose to trust) from untrusted ones (anything received from
another wallet). Both wallets in a redemption use the SDK's transfer policy: **3 confirmations
for trusted notes, 10 for untrusted ones.** The SDK's tests pin both numbers.

**The card side: 10.** Every note on a card was sent by another wallet — the issuer's — so it is
untrusted, and `check()` reports `.pending` until it has 10 confirmations. This is the guard that
matters: the issuer can rederive the card's key, and could in principle try to undo the funding
with a reorg. Ten confirmations is ZIP 315's bar for funds that someone else controlled.

**The claim side: 3 when recorded as trusted.** After an accepted submission, the destination
stores the claim and explicitly marks it trusted. Its outputs use the default three-confirmation
wait. This is a policy choice for faster spendability, with an accepted residual risk: even after
card funding has ten confirmations, the issuer and anyone holding the link share its spending
key and can sign a competing spend of the same inputs. Constructing the claim on this device
does not establish exclusive control over them. A competing spend could replace the claim in a
reorg after three to nine confirmations, and the destination could lose a gift it had already
spent from. This is not a claim that an attack has been reproduced, nor does a ten-confirmation
wait eliminate every possible reorg. When trust was never recorded, normal receiving-wallet sync
discovers the claim as an ordinary untrusted receive with the ten-confirmation wait.

## Immediate claim recording

- Pass the main wallet's synchronizer as `recordIn:`. Once a server has accepted the claim,
  `GiftCardRedeemer` reads the raw transaction back from the card wallet and stores it in the
  destination (the receive shows at once, unmined, with its memo), explicitly marked as trusted.
  The main wallet uses the trusted transfer policy: three confirmations by default before
  the gift becomes spendable. The next sync mines the stored transaction as usual.
- Only the SDK's own synchronizers (`SDKSynchronizer`, `SlipstreamSynchronizer`) can record the
  claim. Recording is internal to the SDK. With any other conformer, `recordedInDestination` is
  `false`. Normal sync can discover the claim when it pays that wallet; an unrelated wallet
  does not receive it.
- The call goes straight to the wallet database, so it works while the main synchronizer is
  stopped — which is how an app typically runs a claim, so the two wallets do not compete for the
  shared database executor. The example uses a main synchronizer typed as
  `AwaitableStopSynchronizer`, the optional capability both SDK implementations support. Await
  `stopAndWait()` before starting work that needs the stop operation to finish; synchronous
  `stop()` only requests it. The classic synchronizer joins processor-owned sync, mempool,
  rewind, polling and action work before returning; queued automatic restarts are superseded by this stop.
  Slipstream completes its queued teardown and earlier lifecycle work, but its engine can return a
  non-quiescent stop. Both complete even when no new stopped state is emitted, including idle or
  unprepared paths. Keep ownership of the pause so other app lifecycle paths do not start the main wallet
  while the claim is running, then restart it afterwards.
- Recording can never fail the redemption: the funds are already on their way. A failure is logged
  and reported as `Redemption.recordedInDestination == false`. When the claim pays the specified
  wallet, normal sync can discover it from the chain as an ordinary untrusted receive if trust was
  never recorded. An unrelated `recordIn:` wallet does not receive the claim.
- `recordedInDestination` is `true` only when the claim is stored in the destination and
  explicitly marked as trusted. A claim that does not involve the destination wallet
  (`recordIn:` is not the wallet `recipient` belongs to) is not stored there, so the flag is `false`.
- Only accepted submissions (`.success`) are recorded. A transaction rejected by every server is
  not stored in the destination.
- Recording a claim explicitly sets its trusted status, including when repeated after an untrusted
  status. It does not migrate historical claims or other stored trust records, or change the SDK's
  general support for marking transactions as trusted or untrusted.
- Immediate history visibility does not make an unmined output spendable.

## Lifecycle and concurrency

- The temporary wallet is always a `SlipstreamSynchronizer` with a custom alias derived from a hash of the card's
  funding address (`GiftCardRedeemer.alias`), never `.default`. All of its files live in one
  directory under `storageDirectory` (the temporary directory by default), which `cleanup()`
  deletes, including the files `wipe()` leaves behind.
- It runs alongside the app's main synchronizer. Both share the SDK's global database executor, so
  Swift wallet-database calls can contend with each other; both engines also consume CPU and I/O
  while a card is being checked.
- Only one redeemer per card can be alive in the process; a second throws
  `giftCardRedeemerAlreadyActive` until owned cleanup successfully wipes the wallet and removes its root directory.
- Calls on a redeemer run one at a time, in order. Cancelling the task awaiting `check()` stops
  the wait (throws `CancellationError`); the card wallet keeps syncing until `cleanup()`.
- A cancelled queued `check()` or `redeem(to:memo:recordIn:)` throws `CancellationError`
  before preparation or creation. Cancellation during redemption preparation, or while creation
  waits for the wallet database executor, prevents native creation. The point of no return is the
  final native admission immediately before synchronous transaction construction.
- After native admission, redemption owns creation, submission, and accepted receipt recording.
  It returns the resulting outcome even if its caller cancels. Await that outcome before retrying
  a claim. An error on a later submission-stream iteration is rethrown only after attempting to
  record earlier accepted receipts. Every accepted receipt is attempted even if recording another
  fails; a recording failure preserves submission results and sets `recordedInDestination` to
  `false`. Completion with no submission results throws `giftCardRedemptionIncomplete` (`ZGIFT0012`).
- `cleanup()` closes admission to new checks and redemptions immediately, cancels preparation
  that has not reached native claim admission, and joins earlier work before wiping. A successful
  return means the engine was safely wiped, its card service connections and existing host Tor
  runtime were closed, all remaining wallet files were deleted, and another redeemer can claim the
  card.
- Each cleanup caller has a 30-second monotonic budget starting at admission, including time queued
  behind earlier work. Cancellation returns `CancellationError`; expiration throws
  `giftCardCleanupTimedOut` (`ZGIFT0011`). Both detach only that caller's wait: owned teardown keeps
  running and the card remains in use. The app must not treat a timeout as permission to create a
  replacement or delete the wallet itself.
- A wipe refusal or storage failure is returned unchanged and keeps the card quarantined. Owned
  teardown retries after 1, 2, 4, 8, 16, then 30 seconds, capped at 30 seconds, with no overlapping
  attempts. Only successful wipe and root deletion release the alias. Once wipe succeeds, a failed
  root deletion retries removal alone. These are teardown retries, never claim/submission retries.
- Dropping a used redeemer transfers teardown to retained process ownership. Cleanup continues
  without any external redeemer reference, and `removeLeftoverWallets(in:)` skips it until teardown
  succeeds. An unused redeemer releases its claim immediately when dropped only if cleanup has
  never been requested; once requested, teardown keeps ownership until it succeeds.
- `cleanup()` never loses funds: the key is in the link. If a submission failed, clean up and use
  a new redeemer to retry, because the old one treats the notes as spent until its transaction
  expires.
- A card wallet holds the card's keys, its notes and the claim with its recipient. A redeemer
  interrupted by a crash or a killed app leaves it on disk (excluded from backups).
  Call `GiftCardRedeemer.removeLeftoverWallets(in:)` at launch, with the same `storageDirectory`;
  it skips every wallet with active or retained teardown ownership in the process.
- Tor follows `isTorEnabled`: birthday/restore metadata, identifying sync requests, and claim
  submission use configured Tor when enabled. Slipstream bulk block fetching remains direct.
  There is no direct fallback after a protected request fails. Pass the main wallet's setting;
  when disabled, the endpoint sees the device's IP address for identifying requests as well.
- The birthday lookup asks the server for the tree state of the block before the card's birthday
  and uses it only if the state is for exactly that height; otherwise the card wallet starts from
  the nearest bundled checkpoint strictly below the birthday. The independent latest bundled
  checkpoint supplies the native resolver's recovery fallback, including for older cards.
- Exchange-rate fetching is off for the card wallet, and logging is off by default so the
  transaction that links the card to the user's address does not end up in shared logs.

## Errors

The parse errors come from a stable code the rust layer reports, not from its message text, and
none of them carries any part of the link.

| Error | Meaning |
|---|---|
| `giftCardLinkNotAGiftCard` (`ZGIFT0006`) | Not an `https` URL carrying a gift card. |
| `giftCardLinkUnsupportedVersion` (`ZGIFT0007`) | A gift card link of a version this SDK does not read. |
| `giftCardLinkUnsupportedNetwork` (`ZGIFT0008`) | A card for regtest or an unknown network. |
| `giftCardLinkInvalidBirthday` (`ZGIFT0009`) | Malformed birthday, or below NU5 activation. |
| `giftCardLinkInvalid` (`ZGIFT0010`) | Any other malformed link. |
| `giftCardNetworkMismatch` (`ZGIFT0001`) | The card, or the redeem address, is for another network. |
| `giftCardRedeemerAlreadyActive` (`ZGIFT0002`) | The card has an active redeemer or retained teardown ownership. |
| `giftCardRedemptionIncomplete` (`ZGIFT0012`) | The claim completed without a submission result. |
| `giftCardCleanupTimedOut` (`ZGIFT0011`) | This caller waited 30 seconds; cleanup continues and the card remains in use. |
| `giftCardRedeemerNotReady` (`ZGIFT0003`) | `redeem(to:)` before `check()`. |
| `giftCardNothingToRedeem` (`ZGIFT0004`) | Nothing spendable: empty, still pending, or dust (the fee would take everything). |
| `giftCardRedeemerCleanedUp` (`ZGIFT0005`) | The redeemer was cleaned up. |
| `giftCardRecipientRequiresOrchard` (`ZGIFT0013`) | Use a same-network unified address with an Orchard receiver; other receivers may also be present. |

The cleaned-up, not-ready and network-mismatch guards take precedence over the recipient receiver
check. The new recipient error carries no address or key data; exhaustive switches over `ZcashError`
or `ZcashErrorCode` need the new case. Both redemption method signatures are unchanged.

`check()` also rethrows the card wallet's sync error, and `redeem(to:)` the errors of
`proposeSendMax` and `createProposedTransactions`. The destination's errors are never thrown; see
`Redemption.recordedInDestination`.
