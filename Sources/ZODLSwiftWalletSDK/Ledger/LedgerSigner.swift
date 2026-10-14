//
//  LedgerSigner.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// Runs the PCZT signing ceremony against a paired Ledger device over a transport.
///
/// The async counterpart of `pczt_ledger`'s blocking ceremony runner, with the same rules: the session
/// decides every command, its deadline and its retry budget; a `0x6901` refusal is answered by
/// resending the same command after the engine's backoff; an exchange that fails on the transport
/// closes the transport, since the device's reply to the outstanding command can no longer be
/// attributed; every other failure ends the ceremony with the session's error.
///
/// The ceremony holds the transport from before its first command until it is over, so no other
/// ceremony the SDK runs over the same transport (a `LedgerDevice` call, an app switch, another
/// signing) can put a command of its own between two of this one's; one started meanwhile waits. See
/// `LedgerCeremony`.
///
/// Once the ceremony's first command has reached the device, a cancelled task closes the transport, at
/// any point: during an exchange, between two exchanges, or while the session is built. The device can
/// be in the middle of the ceremony, so the caller must open a new connection before it tries again. A
/// task cancelled before that, while it waits for its turn on the transport, closes nothing.
struct LedgerSigner {
    let rustBackend: ZcashRustBackendWelding
    let logger: Logger

    func sign(
        pczt: Pczt,
        accountUUID: AccountUUID,
        binding: LedgerAccountBinding,
        transport: LedgerAPDUTransport,
        progress: (@Sendable (LedgerSigningProgress) -> Void)?
    ) async throws -> Pczt {
        try await LedgerCeremony.run(on: transport) {
            try await signHoldingTransport(
                pczt: pczt,
                accountUUID: accountUUID,
                binding: binding,
                transport: transport,
                progress: progress
            )
        }
    }

    /// The ceremony itself, run while `sign` holds `transport` for it.
    private func signHoldingTransport(
        pczt: Pczt,
        accountUUID: AccountUUID,
        binding: LedgerAccountBinding,
        transport: LedgerAPDUTransport,
        progress: (@Sendable (LedgerSigningProgress) -> Void)?
    ) async throws -> Pczt {
        // Set once the ceremony's first command has reached the device. A cancellation before then
        // happens while the task waits for its turn on the transport, and closes nothing.
        var holdsDevice = false
        do {
            progress?(.identifyingDevice)
            logger.debug("Ledger signing: reading the app version")
            let versionAPDU = try ZcashLedgerBackend.firmwareVersionAPDU()
            let firmwareReply = try await LedgerCommands.query(
                versionAPDU,
                on: transport,
                timeout: ZcashLedgerBackend.defaultTimeout
            ) { reply -> Data in
                _ = try ZcashLedgerBackend.parseAppVersion(reply)
                return reply
            }
            holdsDevice = true

            let session = try await rustBackend.createLedgerSignSession(
                accountUUID: accountUUID,
                pczt: pczt,
                binding: binding,
                firmwareReply: firmwareReply
            )

            let signed = try await pump(session: session, transport: transport, progress: progress)
            logger.debug("Ledger signing: complete")
            progress?(.complete)
            return signed
        } catch {
            let publicError = ledgerZcashError(error)
            // An exchange the transport refused before sending anything never reached the device,
            // so there is nothing on it to abandon: the transport stays open, as for a cancellation
            // before the first command.
            let neverReachedDevice = error is LedgerExchangeNotStarted
            if holdsDevice && !neverReachedDevice && (publicError is CancellationError || Task.isCancelled) {
                // The device can be in the middle of the ceremony. Closing is idempotent, so a
                // transport that an exchange already closed is not affected.
                logger.debug("Ledger signing: cancelled; closing the transport")
                await transport.close()
            }
            if let zcashError = publicError as? ZcashError {
                logger.error("Ledger signing failed: \(zcashError.message) (\(zcashError.code.rawValue))")
            }
            throw publicError
        }
    }

    private func pump(
        session: LedgerSigningSession,
        transport: LedgerAPDUTransport,
        progress: (@Sendable (LedgerSigningProgress) -> Void)?
    ) async throws -> Pczt {
        var reportedStage: LedgerSignStage?
        var reviewStarted = false
        var signingReported = false

        while true {
            let command: LedgerSignCommand
            switch try session.nextStep() {
            case .send(let next):
                command = next
            case .done:
                return try session.finish()
            case .awaitingReply:
                // Only an exchange this runner never finished leaves a reply outstanding, and every
                // such exchange has already ended the ceremony.
                throw LedgerFFIError.local(.internal, "the signing session has a command outstanding and cannot be resumed")
            }

            if command.startsReview {
                reviewStarted = true
                logger.debug("Ledger signing: the transaction is on the device for review")
                progress?(.awaitingReviewOnDevice)
            } else if command.stage == .streaming, !reviewStarted {
                progress?(.streaming(sent: command.streamAcknowledged, total: command.streamTotal))
            } else if command.stage.isSigning, !signingReported {
                signingReported = true
                progress?(.signing)
            }
            if reportedStage != command.stage {
                logger.debug("Ledger signing: stage \(command.stage.rawValue)")
                reportedStage = command.stage
            }

            let timeout: TimeInterval? = command.waitsForUser ? nil : ZcashLedgerBackend.defaultTimeout
            let reply = try await LedgerCommands.exchange(command.apdu, on: transport, timeout: timeout)

            if try session.processResponse(reply) == .retrySameAPDU {
                logger.debug("Ledger signing: the device asked for the command again (0x6901)")
                try await LedgerCommands.backOff(transport: transport)
            }
        }
    }
}
