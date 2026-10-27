//
//  SubmitPlanExecutor.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// One background retry of a transaction through its plan's endpoints.
struct SubmitPlanAttempt {
    /// The endpoint that accepted the transaction, if any.
    let accepted: LightWalletEndpoint?
    /// What every endpoint tried answered, keyed by `endpointKey(_:)`.
    let answers: [String: EndpointSubmission]
    /// The last failure, when no endpoint accepted.
    let lastError: Error?
}

/// Background-retry executor: tries the recorded plan endpoints sequentially
/// until one accepts. Background retry stays gentle — no fan-out.
/// An empty endpoint list returns without submitting.
final class SubmitPlanExecutor {
    private let endpointSubmitter: EndpointSubmitter
    private let logger: Logger

    init(endpointSubmitter: EndpointSubmitter, logger: Logger) {
        self.endpointSubmitter = endpointSubmitter
        self.logger = logger
    }

    /// - Returns: the endpoint that accepted the transaction, or `nil` when
    ///   there was nothing to submit to. Callers that only care whether the
    ///   retry threw may ignore it.
    @discardableResult
    func submit(transaction: CreatedTransaction, endpoints: [LightWalletEndpoint]) async throws -> LightWalletEndpoint? {
        let attempt = try await submitRecordingAnswers(transaction: transaction, endpoints: endpoints)
        if attempt.accepted == nil, let lastError = attempt.lastError {
            throw lastError
        }
        return attempt.accepted
    }

    /// One background retry: the accepting endpoint, if any, what every endpoint tried answered
    /// (keyed by `endpointKey(_:)`), and the last error. Throws only for cancellation.
    func submitRecordingAnswers(
        transaction: CreatedTransaction,
        endpoints: [LightWalletEndpoint]
    ) async throws -> SubmitPlanAttempt {
        let txId = transaction.txId.toHexStringTxId()
        logger.debug("Transaction \(txId) background retry across \(endpoints.count) recorded endpoint(s).")
        var lastError: Error?
        var answers: [String: EndpointSubmission] = [:]

        for endpoint in endpoints {
            try Task.checkCancellation()
            do {
                try await endpointSubmitter.submit(transaction: transaction, to: endpoint)
                logger.debug("Transaction \(txId) background retry accepted by \(endpoint.host):\(endpoint.port).")
                answers[endpointKey(endpoint)] = .accepted
                return SubmitPlanAttempt(accepted: endpoint, answers: answers, lastError: nil)
            } catch let TransactionEncoderError.submitError(code, message) where SubmitRefusal.meansAccepted(code: code, message: message) {
                // The server already holds the transaction: that is its acceptance.
                logger.debug("Transaction \(txId) background retry: \(endpoint.host):\(endpoint.port) already holds it: \(code) \(message)")
                answers[endpointKey(endpoint)] = .accepted
                return SubmitPlanAttempt(accepted: endpoint, answers: answers, lastError: nil)
            } catch let TransactionEncoderError.submitError(code, message) {
                logger.warn("Transaction \(txId) background retry to \(endpoint.host):\(endpoint.port) refused: \(code) \(message)")
                answers[endpointKey(endpoint)] = .refused(code: code, message: message)
                lastError = TransactionEncoderError.submitError(code: code, message: message)
            } catch {
                logger.warn("Transaction \(txId) background retry to \(endpoint.host):\(endpoint.port) failed: \(error)")
                answers[endpointKey(endpoint)] = .failed
                lastError = error
            }
        }

        if lastError != nil {
            logger.warn("Transaction \(txId) background retry exhausted all \(endpoints.count) recorded endpoint(s).")
        }
        return SubmitPlanAttempt(accepted: nil, answers: answers, lastError: lastError)
    }
}
