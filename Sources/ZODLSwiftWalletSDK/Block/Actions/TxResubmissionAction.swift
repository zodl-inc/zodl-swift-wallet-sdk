//
//  TxResubmissionAction.swift
//
//
//  Created by Lukas Korba on 06-17-2024.
//

import Foundation

final class TxResubmissionAction {
    let resubmitter: TxResubmitter

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
    }
}

extension TxResubmissionAction: Action {
    var removeBlocksCacheWhenFailed: Bool { true }

    func run(with context: ActionContext, didUpdate: @escaping (CompactBlockProcessor.Event) async -> Void) async throws -> ActionContext {
        let latestBlockHeight = await context.syncControlData.latestBlockHeight

        await resubmitter.checkAndResubmit(latestBlockHeight: latestBlockHeight)

        if await context.prevState == .enhance {
            await context.update(state: .updateChainTip)
        } else {
            await context.update(state: .finished)
        }
        return context
    }

    func stop() async { }
}
