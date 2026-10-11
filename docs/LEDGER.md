# Ledger hardware wallets over Bluetooth

The SDK pairs accounts on, and signs transactions with, a Ledger device running the Zcash app,
over Bluetooth LE. The device holds the spending keys: the wallet imports the account's unified
full viewing key, builds transactions as PCZTs, and has the device sign them.

Supported devices are the Bluetooth models (Nano X, Stax, Flex and Nano Gen5) running Zcash app
3.6.0 or newer. A transaction with Ironwood outputs needs app 3.9.0 or newer; 3.9.3 is recommended.

The engine behind this is `pczt_ledger` (zodl-inc/pczt-ledger). It performs no I/O: the SDK moves the
bytes, and every protocol rule, pre-flight check and parser lives in the engine.

## App requirements

- iOS: add `NSBluetoothAlwaysUsageDescription` to the app's `Info.plist`. The first scan shows the
  system's Bluetooth permission prompt.
- macOS: a sandboxed app needs the `com.apple.security.device.bluetooth` entitlement.
- The first connection to a device brings up Bluetooth pairing: the system shows a pairing request and
  the device shows a code for the user to confirm. A device that was reset, or unpaired on the phone,
  fails with `ZcashError.ledgerBluetoothPairingRefused`; the user removes it from the system Bluetooth
  settings and pairs again. A device that is merely slow to answer, still bonded but not yet awake,
  instead times out with `ZcashError.ledgerTimeout`, worth a retry rather than a reason to unpair it:
  CoreBluetooth has no signal for a pairing request actually in progress, so connecting cannot tell the
  two apart by anything but a real pairing failure.

## Connecting

```swift
let scanner = LedgerBluetoothScanner(logger: logger)

for try await devices in scanner.devices() {
    // Show `devices` (model, name, signal strength) and let the user pick one; leaving the loop
    // stops the scan.
}

let transport = try await scanner.connect(to: pickedDevice)
```

`LedgerBluetoothTransport` conforms to `LedgerAPDUTransport`, the only thing the pairing and signing
code needs; a test double conforms to it too.

A `LedgerBluetoothTransport` closes itself when an exchange fails after its first frame went out --
a timeout, a disconnect, a reply that does not reassemble, or a cancelled task -- whoever the caller
is, since the device's reply to that command could otherwise be read as the reply to the next one.
`LedgerDevice`'s commands and signing also close the transport on any exchange that fails. Every
later call then throws the error that closed the transport, or `ZcashError.ledgerTransportClosed`
after a cancellation or `close()`, and the recovery is a new connection. A `LedgerDevice` call or a
signing ceremony that is cancelled once it holds the device closes the transport, whatever step it
was at -- during an exchange, between two commands or export chunks, or during the pause before
resending a command the device refused with `0x6901` -- since the device can be in the middle of a
command or an exchange. A call cancelled while it waits for its turn (behind another ceremony on the
same transport, or behind another exchange on it before its first command) closes nothing, because
it never reached the device. A refusal from the device (the user declining, a locked device, another
app open) leaves the transport open.

Every pairing, signing ceremony and app query or switch holds its transport for all of its commands.
Two of them over one transport run one after the other, whichever `LedgerDevice`,
`Synchronizer.signPCZTWithLedger` or `LedgerZcashApp` call started them, so neither can put a
command of its own between two of the other's: the Zcash app keeps per-ceremony state, and a stray
command in the middle of an export or a signing fails both. A call made while another ceremony runs
simply waits for it. A pairing that reconnects partway through holds the replacement transport the
same way, for the rest of the call, so a second device or ceremony on it waits too. Only the SDK's
own entry points hold the transport this way; a caller that exchanges with a transport directly while
one of them runs can still interleave its command.
`LedgerZcashApp.ensureZcashAppOpen` closes the caller's transport only when its link fails, and
closes a transport its `reconnect` opened whenever the call fails; `LedgerZcashApp.currentApp`
never closes the transport it is given.

After a first pairing the device is on its dashboard rather than the Zcash app, and any command then
fails with `ledgerWrongApp`. Before creating a `LedgerDevice` or signing, call
`LedgerZcashApp.ensureZcashAppOpen(transport:reconnect:)` on a fresh connection and use the transport
it returns instead of the one passed in: the Bluetooth link can drop while the device switches apps,
and `ensureZcashAppOpen` reconnects through `reconnect` when it does. The same holds for a
`LedgerDevice` that already exists: it keeps talking over its own `device.transport`, which
`ensureZcashAppOpen` cannot reach, so build a new `LedgerDevice` over the transport it returns rather
than keep using one built over the original. The device has 10 seconds to
reach the Zcash app after the user confirms, polled every 200 ms with up to 3 seconds for each
answer; a poll that loses the link or gets no answer is always followed by a reconnect before those
10 seconds can end the wait, and the time a reconnect that succeeds takes does not count towards
them. Each such reconnect gets 10 seconds of its own, enforced for a `reconnect` that honors
cancellation; one that ignores it is waited for, and any transport it then produces is closed
rather than used. A reconnect that fails starts the wait for
the app over, since the device may still be
rebooting into it, and is tried again after 500 milliseconds, then after twice the previous wait, at
most 2 seconds. It keeps trying for 10 seconds from the first of the reconnects that failed in a row,
and the first one that fails once they have passed propagates its own failure (typically
`ledgerBluetoothConnectionFailed`) instead of the generic `ledgerWrongApp` timeout; a reconnect that
succeeds ends the row, so a later failure starts again from 500 milliseconds.

## Pairing an account

```swift
let device = LedgerDevice(transport: transport, networkType: .mainnet)
let pairing = try await device.pairAccount(zip32AccountIndex: Zip32AccountIndex(0))

let accountUUID = try await synchronizer.importAccount(
    ufvk: pairing.ufvk.stringEncoded,
    seedFingerprint: nil,
    zip32AccountIndex: nil,
    purpose: .spending,
    name: "Ledger",
    keySource: Account.ledgerKeySource,
    birthday: birthday
)
// Persist `pairing.binding` (Codable) next to `accountUUID`.
```

`pairAccount` reads the app version (and refuses an app that cannot sign), reads the device's
identity, and asks the user to approve the viewing key export on the device. The identity is
read once, before the export: the Zcash app leaves a status screen up after the export and drops
the next command until the user dismisses it.

For ZIP 32 account 0, the identity is the hash of the account's first external transparent key.
`pairAccount` derives that key from the transparent item of the exported viewing key, and refuses
the pairing with `ZcashError.ledgerDeviceMismatch` when its hash is not the identity the device
gave (or with `ledgerMalformedReply` when the key has no transparent item; the Zcash app always
exports one). That ties the key's transparent item, and so the stored binding, to the device's seed.
It says nothing about the key's Orchard item, which the identity does not derive: check that one on
the device as "Verifying a receiving address on the device" describes, which refuses an address the
key's Orchard item does not derive. The key of any other account does not derive the identity at
all, so `pairAccount` does not check it against the identity; the on-device address check is the
check for those accounts too.

The app-version and identity reads before the export answer at once on a healthy link, so each gets
`readTimeout` (`LedgerDevice.defaultReadTimeout`, the engine's normal timeout, by default; pass
`LedgerDevice.defaultPairingReadTimeout`, 10 s, to detect a stalled device early) rather than waiting
on the user. Pass `reconnect`, a function
that opens a fresh connection to the same device, and a read that fails on the connection (a timeout,
a disconnect, a connection failure, or the device not being found) is asked once more over a new
transport before anything else is sent; a second such failure propagates, and so does a refusal.
Nothing is retried once the export command has been sent.

```swift
let pairing = try await device.pairAccount(
    zip32AccountIndex: Zip32AccountIndex(0),
    readTimeout: LedgerDevice.defaultPairingReadTimeout,
    reconnect: { try await scanner.connect(to: bluetoothDevice) }
)
// device.transport is the reconnected transport when pairAccount reconnected; close it once done.
```

The app owns every transport, the reconnected ones included: `device.transport` is the one the
device talks over now, and the app closes each transport it opened (closing is idempotent; the SDK
has already closed any whose exchange failed).

Pass `nil` for the seed fingerprint and the ZIP 32 account index: a Ledger never reveals its seed
fingerprint, and the binding carries the account index the signing session needs.
`Account.ledgerKeySource` (`"ledger"`) lets the wallet recognize its Ledger accounts, and the SDK
does read it once a proposal is built for the account: `change_split_policy` in `rust/src/lib.rs`
compares the account's stored `keySource` against it case-insensitively, and only a match builds
the proposal with at most one change output, the most the Ledger Zcash app can sign. An
account with no tag, a different tag, or one the lookup could not find keeps splitting change into
up to four outputs of at least 0.1 ZEC each (see "Change outputs" below).

### The device identity

`LedgerDeviceIdentity` (`tpk0-` and 64 hex digits) is a hash of the public key at
`m/44'/coin'/0'/0/0`. It names the seed rather than the hardware: two devices restored from the same
seed share it. It is per network. It is not a secret, but it is linkable to the device's first
transparent address once that address has spent on chain, so store it with the account and never
log it; its `description` prints a placeholder, and `stringEncoded` returns the value for storage.

## Verifying a receiving address on the device

```swift
let expected = try LedgerDevice.expectedUnifiedAddress(ufvk: ufvk, networkType: .mainnet)
// Show `expected.stringEncoded`, and ask the user to compare it with the device screen.
_ = try await device.displayUnifiedAddress(
    ufvk: ufvk,
    zip32AccountIndex: binding.zip32AccountIndex,
    transparentAddressIndex: 0
)
```

`expectedUnifiedAddress` derives the address from the account's viewing key, with no device. The
device shows the account's Orchard receiver at diversifier index 0, alone, whatever
`transparentAddressIndex` is: the index selects the transparent address the device shows next to it.
The account's default unified address carries a transparent receiver too, so it never matches the
device screen.

`displayUnifiedAddress` shows the address on the device and waits for the user. When the device
replies with an address that `ufvk` does not derive, it throws `ZcashError.ledgerDeviceMismatch`:
the device does not hold the keys of that viewing key, so do not use the key to receive funds for the
account. Show the user the address `expectedUnifiedAddress` returns, never an address the device
sends back; `displayUnifiedAddress` returns the derived address, not the device's reply.

## Sending

```
proposal ─ createPCZTFromProposal ─ pczt
  ├─ addProofsToPCZT(pczt)                                      → pcztWithProofs
  └─ signPCZTWithLedger(pczt, accountUUID, binding, transport)   → pcztWithSigs
createTransactionFromPCZT(pcztWithProofs, pcztWithSigs)          → submit
```

```swift
let pczt = try await synchronizer.createPCZTFromProposal(accountUUID: accountUUID, proposal: proposal)

async let pcztWithProofs = synchronizer.addProofsToPCZT(pczt: pczt)
let pcztWithSigs = try await synchronizer.signPCZTWithLedger(
    pczt: pczt,
    accountUUID: accountUUID,
    binding: binding,
    transport: transport,
    progress: { progress in /* update the UI */ }
)

let submission = try await synchronizer.createTransactionFromPCZT(
    pcztWithProofs: try await pcztWithProofs,
    pcztWithSigs: pcztWithSigs
)
```

Pass the PCZT `createPCZTFromProposal` returned to both calls, unredacted. The signing call prepares
its own copy for the device: it redacts it to the signer view, adds the key paths the device signs
at, and marks a transparent change output as change. The signed PCZT therefore differs from the
input by more than signatures, and the combine step in `createTransactionFromPCZT` merges it with the
proven PCZT: every field the Ledger path adds is one the prover's copy leaves empty.

The ceremony, reported through `LedgerSigningProgress`:

1. `identifyingDevice`: the app version is read, and the transaction is checked against every rule
   and limit of that version. A transaction the device cannot sign fails here with
   `ZcashError.ledgerTransactionNotSignable`, or `ledgerAppTooOld`, before anything is sent. The
   device's identity is then checked against the binding (`ledgerDeviceMismatch` otherwise).
2. `streaming(sent:total:)`: the transaction is sent to the device.
3. `awaitingReviewOnDevice`: the device shows the transaction. No timeout applies until the user
   approves or rejects it; a rejection fails with `ledgerUserRejected`.
4. `signing`, then `complete`.

The device's signatures are verified before the signed PCZT is returned.

### Change outputs

The Ledger Zcash app signs exactly one change output per transaction; a PCZT with two or more fails
the `identifyingDevice` check above with `ZcashError.ledgerTransactionNotSignable` before anything is
sent. The proposal itself already avoids this: `proposeTransfer`, `proposefulfillingPaymentURI` and
`proposeShielding` build at most one change output for an account whose `keySource` is
`Account.ledgerKeySource` (compared case-insensitively). Every other account keeps splitting change
into up to four outputs of at least 0.1 ZEC each, unchanged.

## Errors

Every Ledger failure is a `ZcashError` from the `ledger` family (`ZLEDG0001`–`ZLEDG0024`), or
`CancellationError`. `ZcashError.ledgerIsRestartable` says whether a fresh attempt could succeed:
after the user declined, after the device is not running the Zcash app or has exhausted its
derivation budget (opening or reopening it lets a fresh attempt succeed), after a device condition
that clears (a locked device), and after a transport failure on a new connection. It never means
"resend the last command".

| Error | Meaning and remedy |
|---|---|
| `ledgerWrongApp` | The dashboard, or another app, is open (also when the device reports either directly rather than as a plain refusal), or the device did not switch in time: call `LedgerZcashApp.ensureZcashAppOpen`. Restartable. |
| `ledgerAppNotInstalled` | The Zcash app is not installed: the user installs it on the device with Ledger Live. |
| `ledgerAppOpenRejected` | The user declined opening the Zcash app on the device; restartable. |
| `ledgerAppTooOld` | Update the Zcash app. |
| `ledgerDerivationBudgetExhausted` | The Zcash app ran out of key derivations for this run: close and reopen it on the device. Restartable. |
| `ledgerDeviceMismatch` | During signing: connect the paired device. During pairing of account 0: the exported key does not belong to the identified device; do not import it. During `displayUnifiedAddress`: the device's address is not the one the viewing key derives; do not use the key to receive funds. |
| `ledgerCapsMismatch` | The app version changed during the ceremony: try again. |
| `ledgerDeviceRefused(statusWord, isTransient)` | Any other refusal; `isTransient` for a condition that clears, such as a locked device. |
| `ledgerTransactionNotSignable` | A device rule or limit refuses the transaction; nothing was sent. |
| `ledgerMalformedReply` | The reply was not what the protocol promises, or a signature did not verify. |
| Bluetooth errors | `ledgerBluetoothUnsupported`, `ledgerBluetoothUnauthorized`, `ledgerBluetoothPoweredOff`, `ledgerDeviceNotFound`, `ledgerBluetoothConnectionFailed`, `ledgerBluetoothDisconnected`, `ledgerBluetoothPairingRefused`, `ledgerTimeout`, `ledgerTransportClosed`. |

Error reasons carry no command or reply bytes, PCZT, viewing key, address, device identity or
signature, and the SDK logs only lengths, stages and error codes. The `ledgerTransportFailed` case
wraps whatever a custom transport threw.
