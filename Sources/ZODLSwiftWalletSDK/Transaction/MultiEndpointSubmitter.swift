//
//  MultiEndpointSubmitter.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// Races one transaction against multiple endpoints in parallel.
///
/// Resumes the caller as soon as the outcome is decided (first acceptance, all
/// endpoints failed, timeout, or caller cancellation); in-flight submissions
/// continue through the grace window in the background before being cancelled.
final class MultiEndpointSubmitter {
    private let endpointSubmitter: EndpointSubmitter
    private let logger: Logger

    init(endpointSubmitter: EndpointSubmitter, logger: Logger) {
        self.endpointSubmitter = endpointSubmitter
        self.logger = logger
    }

    /// The outcome of one submission race, with what each endpoint answered.
    struct RaceResult {
        let outcome: TransactionSubmissionOutcome
        /// Each endpoint's answer, keyed by `endpointKey(_:)`, as far as the race had them when it
        /// resolved; an endpoint still in flight then (after a timeout, say) has no entry.
        let endpointOutcomes: [String: EndpointSubmission]
        /// The race itself, still winding down in the background after `outcome` resolved.
        let race: SubmissionRace?

        /// Each endpoint's final answer, once every endpoint's submission has ended: an endpoint in
        /// work that ignores cancellation (Tor) may still accept or refuse after the deadline.
        /// An endpoint whose submission ended by cancellation without answering has no entry.
        func settledEndpointOutcomes() async -> [String: EndpointSubmission] {
            guard let race else { return endpointOutcomes }
            return await race.settledAnswers()
        }
    }

    func submit(
        transaction: CreatedTransaction,
        to endpoints: [LightWalletEndpoint],
        timing: SubmissionTiming
    ) async -> TransactionSubmissionOutcome {
        await submitClassifyingRejection(transaction: transaction, to: endpoints, timing: timing).outcome
    }

    func submitClassifyingRejection(
        transaction: CreatedTransaction,
        to endpoints: [LightWalletEndpoint],
        timing: SubmissionTiming
    ) async -> RaceResult {
        let health = OHTTPHealthFailureOwner()
        guard !endpoints.isEmpty else {
            logger.warn("Multi-endpoint submission requested with an empty endpoint list.")
            return RaceResult(outcome: .unreachable, endpointOutcomes: [:], race: nil)
        }

        let race = SubmissionRace(
            transaction: transaction,
            endpoints: endpoints,
            timing: timing,
            endpointSubmitter: endpointSubmitter,
            logger: logger,
            health: health
        )

        // The worker is created before the cancellation handler is installed and
        // captured immutably by both closures — no lock needed.
        let worker = Task {
            await race.run()
        }

        let outcome = await withTaskCancellationHandler {
            await race.outcome()
        } onCancel: {
            worker.cancel()
            // Release the caller right away: children stuck in work that
            // ignores task cancellation (e.g. blocking FFI on the Tor path)
            // must not delay the `.cancelled` resolution — and a straggler's
            // late rejection must not replace it. The race keeps winding down
            // inside the worker task.
            Task {
                await race.callerCancelled()
            }
        }
        return RaceResult(outcome: outcome, endpointOutcomes: await race.endpointOutcomes(), race: race)
    }
}

/// Holds the race state and the two promises: the caller-facing outcome and the
/// internal "race finished" signal that releases the task group.
actor SubmissionRace {
    private let transaction: CreatedTransaction
    private let endpoints: [LightWalletEndpoint]
    private let timing: SubmissionTiming
    private let endpointSubmitter: EndpointSubmitter
    private let logger: Logger

    private var resolvedOutcome: TransactionSubmissionOutcome?
    private var outcomeContinuation: CheckedContinuation<TransactionSubmissionOutcome, Never>?
    private var raceFinished = false
    private var raceFinishedContinuation: CheckedContinuation<Void, Never>?
    private var winner: LightWalletEndpoint?
    private var firstRejection: (code: Int, message: String)?
    private let health: OHTTPHealthFailureOwner
    private var failedAttempts: [OHTTPHealthAttempt?]
    private var completedCount = 0
    private var answers: [String: EndpointSubmission] = [:]
    private var graceTask: Task<Void, Never>?
    private var settled = false
    private var settledContinuations: [CheckedContinuation<[String: EndpointSubmission], Never>] = []

    init(
        transaction: CreatedTransaction,
        endpoints: [LightWalletEndpoint],
        timing: SubmissionTiming,
        endpointSubmitter: EndpointSubmitter,
        logger: Logger,
        health: OHTTPHealthFailureOwner
    ) {
        self.transaction = transaction
        self.endpoints = endpoints
        self.timing = timing
        self.endpointSubmitter = endpointSubmitter
        self.logger = logger
        self.health = health
        failedAttempts = Array(repeating: nil, count: endpoints.count)
    }

    /// Runs the whole race. Returns only when every child task has ended.
    func run() async {
        logger.debug(
            """
            Starting submission race for \(transaction.txId.toHexStringTxId()): \(endpoints.count) endpoint(s), \
            timeout \(timing.responseTimeout)s, grace \(timing.postAcceptanceGraceDelay)s.
            """
        )
        await withTaskGroup(of: Void.self) { group in
            for (index, endpoint) in endpoints.enumerated() {
                group.addTask {
                    await self.submit(to: endpoint, index: index)
                }
            }
            group.addTask {
                await self.timeout()
            }

            await waitUntilRaceFinishes()
            group.cancelAll()
            await group.waitForAll()
        }

        graceTask?.cancel()
        // Safety net: if nothing resolved (every child ended via cancellation
        // before reporting), the caller must still be released.
        resolve(.cancelled)
        settle()
    }

    /// External cancellation: resolves `.cancelled` immediately (unless an
    /// outcome already won) so the caller is released even while children sit
    /// in non-cancellable work, and so a straggler's later rejection or
    /// failure cannot win over the cancellation.
    func callerCancelled() {
        resolve(.cancelled)
    }

    /// What each endpoint has answered so far. Complete once the race has resolved `.rejected`,
    /// which happens only after every endpoint answered.
    func endpointOutcomes() -> [String: EndpointSubmission] {
        answers
    }

    /// What each endpoint answered, once every child task has ended (see `run()`); the answers can
    /// still change after the caller-facing outcome resolved, until then.
    func settledAnswers() async -> [String: EndpointSubmission] {
        if settled { return answers }
        return await withCheckedContinuation { continuation in
            if settled {
                continuation.resume(returning: answers)
            } else {
                settledContinuations.append(continuation)
            }
        }
    }

    /// The caller-facing promise. Resumes exactly once.
    func outcome() async -> TransactionSubmissionOutcome {
        if let resolvedOutcome { return resolvedOutcome }
        return await withCheckedContinuation { continuation in
            if let resolvedOutcome {
                continuation.resume(returning: resolvedOutcome)
            } else {
                outcomeContinuation = continuation
            }
        }
    }

    // MARK: - Child tasks

    private func submit(to endpoint: LightWalletEndpoint, index: Int) async {
        let attempt = health.makeAttempt()
        do {
            try await health.withAttempt(attempt) {
                try await endpointSubmitter.submit(transaction: transaction, to: endpoint)
            }
            submissionSucceeded(at: endpoint)
        } catch let TransactionEncoderError.submitError(code, message) where SubmitRefusal.meansAccepted(code: code, message: message) {
            // The server already holds the transaction: that is its acceptance.
            logger.debug("Transaction \(transaction.txId.toHexStringTxId()) is already held by \(endpoint.host):\(endpoint.port): \(code) \(message)")
            submissionSucceeded(at: endpoint)
        } catch let TransactionEncoderError.submitError(code, message) {
            submissionRejected(at: endpoint, code: code, message: message)
        } catch let TransactionEncoderError.notSubmittable(refusal) {
            // The SDK refused to submit the transaction to this endpoint: it cannot be valid in the block after the endpoint's
            // height. That is a verdict on the transaction rather than a failure to reach the endpoint, so the race reports it as
            // a rejection, under the refusal's local code.
            submissionRejected(at: endpoint, code: refusal.code, message: refusal.description)
        } catch is CancellationError {
            submissionCancelled(at: endpoint)
        } catch {
            if Task.isCancelled {
                submissionCancelled(at: endpoint)
            } else {
                failedAttempts[index] = attempt
                submissionFailed(at: endpoint, error: error)
            }
        }
    }

    private func timeout() async {
        do {
            try await Task.sleep(nanoseconds: timing.responseTimeout.nanosecondsClamped)
        } catch {
            return
        }
        timeoutFired()
    }

    // MARK: - Race events (actor-serialized; arrival order decides ties)

    private func submissionSucceeded(at endpoint: LightWalletEndpoint) {
        completedCount += 1
        answers[endpointKey(endpoint)] = .accepted
        if winner == nil {
            winner = endpoint
            logger.info("Transaction \(transaction.txId.toHexStringTxId()) accepted by \(endpoint.host):\(endpoint.port).")
            resolve(.accepted(by: endpoint))
            startGraceCountdown()
        } else {
            logger.info("Transaction \(transaction.txId.toHexStringTxId()) also accepted by \(endpoint.host):\(endpoint.port) in the grace window.")
        }
        finishRaceIfAllCompleted()
    }

    private func submissionRejected(at endpoint: LightWalletEndpoint, code: Int, message: String) {
        completedCount += 1
        if firstRejection == nil {
            firstRejection = (code: code, message: message)
        }
        answers[endpointKey(endpoint)] = .refused(code: code, message: message)
        logger.warn("Transaction \(transaction.txId.toHexStringTxId()) rejected by \(endpoint.host):\(endpoint.port): \(code) \(message)")
        resolveIfAllFailed()
        finishRaceIfAllCompleted()
    }

    private func submissionFailed(at endpoint: LightWalletEndpoint, error: Error) {
        completedCount += 1
        answers[endpointKey(endpoint)] = .failed
        logger.warn("Transaction \(transaction.txId.toHexStringTxId()) submission to \(endpoint.host):\(endpoint.port) failed: \(error)")
        resolveIfAllFailed()
        finishRaceIfAllCompleted()
    }

    private func submissionCancelled(at endpoint: LightWalletEndpoint) {
        logger.debug("Transaction \(transaction.txId.toHexStringTxId()) submission to \(endpoint.host):\(endpoint.port) ended by cancellation.")
        completedCount += 1
        // Only external cancellation can end children unresolved: internal
        // cancellation (grace/timeout teardown) happens after a resolution.
        if resolvedOutcome == nil && completedCount >= endpoints.count {
            resolve(.cancelled)
        }
        finishRaceIfAllCompleted()
    }

    private func timeoutFired() {
        guard resolvedOutcome == nil else { return }
        let txId = transaction.txId.toHexStringTxId()
        logger.warn("Transaction \(txId) submission timed out after \(timing.responseTimeout)s; it may still have been broadcast.")
        resolve(.timedOut)
        finishRace()
    }

    // MARK: - Resolution

    private func resolveIfAllFailed() {
        guard winner == nil, resolvedOutcome == nil, completedCount >= endpoints.count else { return }
        let txId = transaction.txId.toHexStringTxId()
        if let firstRejection {
            logger.debug("Transaction \(txId) rejected by all endpoints; first rejection: \(firstRejection.code) \(firstRejection.message).")
            resolve(.rejected(code: firstRejection.code, message: firstRejection.message))
        } else {
            logger.debug("Transaction \(txId) unreachable; all \(endpoints.count) endpoint(s) failed at the transport level.")
            health.attempt?.adoptAllFailures(from: failedAttempts)
            resolve(.unreachable)
        }
        finishRace()
    }

    private func finishRaceIfAllCompleted() {
        guard completedCount >= endpoints.count else { return }
        finishRace()
    }

    private func startGraceCountdown() {
        let graceNanoseconds = timing.postAcceptanceGraceDelay.nanosecondsClamped
        graceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: graceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.finishRace()
        }
    }

    private func resolve(_ outcome: TransactionSubmissionOutcome) {
        guard resolvedOutcome == nil else { return }
        resolvedOutcome = outcome
        outcomeContinuation?.resume(returning: outcome)
        outcomeContinuation = nil
    }

    private func settle() {
        guard !settled else { return }
        settled = true
        let continuations = settledContinuations
        settledContinuations = []
        continuations.forEach { $0.resume(returning: answers) }
    }

    private func finishRace() {
        guard !raceFinished else { return }
        raceFinished = true
        raceFinishedContinuation?.resume()
        raceFinishedContinuation = nil
    }

    private func waitUntilRaceFinishes() async {
        if raceFinished { return }
        await withCheckedContinuation { continuation in
            if raceFinished {
                continuation.resume()
            } else {
                raceFinishedContinuation = continuation
            }
        }
    }
}

private extension TimeInterval {
    var nanosecondsClamped: UInt64 {
        guard self > 0 else { return 0 }
        let nanoseconds = self * 1_000_000_000
        guard nanoseconds < TimeInterval(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds)
    }
}
