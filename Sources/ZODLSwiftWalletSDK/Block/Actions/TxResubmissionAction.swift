//
//  TxResubmissionAction.swift
//
//
//  Created by Lukas Korba on 06-17-2024.
//

import Foundation

final class TxResubmissionAction {
    let resubmitter: TxResubmitter
    private var endpoint: LightWalletEndpoint

    var latestResolvedTime: TimeInterval {
        get { resubmitter.latestResolvedTime }
        set { resubmitter.latestResolvedTime = newValue }
    }

    // `CompactBlockProcessor.updateService(_:)` re-wires this with a freshly
    // resolved encoder after a server switch; forward to the resubmitter so
    // that update keeps reaching the instance actually used for resubmission.
    var transactionEncoder: TransactionEncoder {
        get { resubmitter.transactionEncoder }
        set { resubmitter.transactionEncoder = newValue }
    }

    init(container: DIContainer) {
        resubmitter = TxResubmitter(container: container)
        endpoint = container.resolve(LightWalletEndpoint.self)
    }

    func updateService(_ container: DIContainer) {
        transactionEncoder = container.resolve(TransactionEncoder.self)
        endpoint = container.resolve(LightWalletEndpoint.self)
    }
}

extension TxResubmissionAction: Action {
    var removeBlocksCacheWhenFailed: Bool { true }

    func run(with context: ActionContext, didUpdate: @escaping (CompactBlockProcessor.Event) async -> Void) async throws -> ActionContext {
        let latestBlockHeight = await context.syncControlData.latestBlockHeight

        // The endpoint is bound with the encoder only after successful service publication.
        let endpoint = self.endpoint
        let privateEndpoint = OHTTPEndpoints.isGateway(endpoint.host) ? endpoint : nil
        await SubmissionBudget.$legacyTimeoutMilliseconds.withValue(endpoint.singleCallTimeoutInMillis) {
            await resubmitter.checkAndResubmit(latestBlockHeight: latestBlockHeight, privateEndpoint: privateEndpoint)
        }

        if await context.prevState == .enhance {
            await context.update(state: .updateChainTip)
        } else {
            await context.update(state: .finished)
        }
        return context
    }

    func stop() async { }
}
