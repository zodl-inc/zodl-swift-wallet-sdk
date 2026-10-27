//
//  ValidateServerAction.swift
//
//
//  Created by Michal Fousek on 05.05.2023.
//

import Foundation

final class ValidateServerAction {
    let configProvider: CompactBlockProcessor.ConfigProvider
    let rustBackend: ZcashRustBackendWelding
    var service: LightWalletService
    let sdkFlags: SDKFlags

    init(container: DIContainer, configProvider: CompactBlockProcessor.ConfigProvider) {
        self.configProvider = configProvider
        rustBackend = container.resolve(ZcashRustBackendWelding.self)
        service = container.resolve(LightWalletService.self)
        sdkFlags = container.resolve(SDKFlags.self)
    }
}

extension ValidateServerAction: Action {
    var removeBlocksCacheWhenFailed: Bool { false }

    func run(with context: ActionContext, didUpdate: @escaping (CompactBlockProcessor.Event) async -> Void) async throws -> ActionContext {
        let config = await configProvider.config
        // called each sync, an action in a state machine diagram
        let info = try await service.getInfo(mode: await sdkFlags.ifTor(.defaultTor))
        let localNetwork = config.network
        let saplingActivation = config.saplingActivation

        // A custom-parameter network (customActivationHeights != nil, e.g. a regtest wallet pointed at a
        // modified-mainnet Ironwood backend) may reach a server that identifies with a different base
        // chain (chainName "main", or a nonstandard name entirely) and reports a nonstandard consensus
        // branch id. For such networks the chain-name and branch-id checks are skipped wholesale — the
        // recognition guard included, since an unrecognized chainName must not kill custom-network sync;
        // the Sapling-activation check below still guards against pointing a custom-heights wallet at a
        // real main/test server.
        let isCustomNetwork = localNetwork.customActivationHeights != nil

        // check network types
        if !isCustomNetwork {
            guard let remoteNetworkType = NetworkType.forChainName(info.chainName) else {
                throw ZcashError.compactBlockProcessorChainName(info.chainName)
            }

            guard remoteNetworkType == localNetwork.networkType else {
                throw ZcashError.compactBlockProcessorNetworkMismatch(localNetwork.networkType, remoteNetworkType)
            }
        }

        guard saplingActivation == info.saplingActivationHeight else {
            // The server can report any `UInt64` here, so it is clamped for the error instead of converted.
            throw ZcashError.compactBlockProcessorSaplingActivationMismatch(
                saplingActivation,
                BlockHeight(clamping: info.saplingActivationHeight)
            )
        }

        // check branch id
        if !isCustomNetwork {
            // The branch id is looked up at the server's tip, and the rust backend takes the height as an `Int32`.
            guard let tipHeight = BlockHeight(serverHeight: info.blockHeight) else {
                throw ZcashError.compactBlockProcessorServerBlockHeightOutOfRange
            }

            let localBranch = try rustBackend.consensusBranchIdFor(height: Int32(tipHeight))

            guard let remoteBranchID = ConsensusBranchID.fromString(info.consensusBranchID) else {
                throw ZcashError.compactBlockProcessorConsensusBranchID
            }

            guard remoteBranchID == localBranch else {
                throw ZcashError.compactBlockProcessorWrongConsensusBranchId(localBranch, remoteBranchID)
            }

            // Past the Ironwood (NU6.3) activation, compact-block scanning is what detects the
            // wallet's shielded transactions; status requests by transaction id are scoped to
            // fully-transparent transactions, which scanning cannot detect, so they are no help
            // here. A server that omits Ironwood data would let scanning pass silently (absent
            // Ironwood chain metadata reads as zero, satisfying the tree-size consistency check) while
            // never detecting anything in that pool, so its absence must fail loudly. The tree state at
            // the server's tip is the discriminating block-level signal: an Ironwood-capable server
            // always serves a non-empty `ironwoodTree` frontier once the pool exists.
            //
            // The probe runs for as long as NU6.3 is active at the server's tip, not only while the
            // server reports NU6.3's own branch id: a later network upgrade, such as NU7, changes the
            // branch id the server reports, while the Ironwood pool and the need for its data stay.
            //
            // A custom network carries its own activation heights and reports a nonstandard branch id,
            // so it has no standard NU6.3 height to compare the tip with; the probe stays with the other
            // checks that the custom-network skip covers.
            if let ironwoodActivation = localNetwork.ironwoodActivationHeight, tipHeight >= ironwoodActivation {
                var tipBlock = BlockID()
                tipBlock.height = info.blockHeight
                let treeState = try await service.getTreeState(tipBlock, mode: await sdkFlags.ifTor(.defaultTor))
                guard !treeState.ironwoodTree.isEmpty else {
                    throw ZcashError.compactBlockProcessorServerMissingIronwoodSupport
                }
            }
        }

        await context.update(state: .fetchUTXO)
        return context
    }

    func stop() async { }
}
