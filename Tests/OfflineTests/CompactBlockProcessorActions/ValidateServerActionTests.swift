//
//  ValidateServerActionTests.swift
//
//
//  Created by Lukáš Korba on 16.05.2023.
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class ValidateServerActionTests: ZcashTestCase {
    var underlyingChainName = ""
    var underlyingNetworkType = NetworkType.testnet
    var underlyingNetwork: ZcashNetwork?
    var underlyingSaplingActivationHeight: BlockHeight?
    /// The Sapling activation height the server reports, when it has to be a value no `BlockHeight` can hold.
    var underlyingReportedSaplingActivationHeight: UInt64?
    var underlyingConsensusBranchID = ""
    /// The tip height the server reports, which the action also hands to the local consensus rules.
    var underlyingBlockHeight: UInt64 = 2
    /// The branch id the local consensus rules answer for the server's tip. The default is NU5's, which `c2d6d0b4` encodes.
    var underlyingLocalConsensusBranchID: ConsensusBranchID = -1026109260
    var underlyingIronwoodTree = ""
    var serviceMock = LightWalletServiceMock()

    override func setUp() {
        super.setUp()

        underlyingChainName = "test"
        underlyingNetworkType = .testnet
        underlyingNetwork = nil
        underlyingSaplingActivationHeight = nil
        underlyingReportedSaplingActivationHeight = nil
        underlyingConsensusBranchID = "c2d6d0b4"
        underlyingBlockHeight = 2
        underlyingLocalConsensusBranchID = -1026109260
        underlyingIronwoodTree = ""
        serviceMock = LightWalletServiceMock()
    }

    func testValidateServerAction_NextAction() async throws {
        let validateServerAction = setupAction()

        do {
            let context = ActionContextMock.default()
            let nextContext = try await validateServerAction.run(with: context) { _ in }

            let acResult = nextContext.checkStateIs(.fetchUTXO)
            XCTAssertTrue(acResult == .true, "Check of state failed with '\(acResult)'")
        } catch {
            XCTFail("testValidateServerAction_NextAction is not expected to fail. \(error)")
        }
    }

    func testValidateServerAction_ChainNameError() async throws {
        underlyingChainName = "invalid"

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("testValidateServerAction_ChainNameError is expected to fail.")
        } catch ZcashError.compactBlockProcessorChainName(let chainName) {
            XCTAssertEqual(chainName, "invalid")
        } catch {
            XCTFail("""
            testValidateServerAction_ChainNameError is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorChainName
            """)
        }
    }

    func testValidateServerAction_NetworkMatchError() async throws {
        underlyingNetworkType = .mainnet

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("testValidateServerAction_NetworkMatchError is expected to fail.")
        } catch let ZcashError.compactBlockProcessorNetworkMismatch(expected, found) {
            XCTAssertEqual(expected, .mainnet)
            XCTAssertEqual(found, .testnet)
        } catch {
            XCTFail("""
            testValidateServerAction_NetworkMatchError is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorNetworkMismatch
            """)
        }
    }

    func testValidateServerAction_SaplingActivationError() async throws {
        underlyingSaplingActivationHeight = 1

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("testValidateServerAction_SaplingActivationError is expected to fail.")
        } catch let ZcashError.compactBlockProcessorSaplingActivationMismatch(expected, found) {
            XCTAssertEqual(expected, 280_000)
            XCTAssertEqual(found, 1)
        } catch {
            XCTFail("""
            testValidateServerAction_SaplingActivationError is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorSaplingActivationMismatch
            """)
        }
    }

    func testValidateServerAction_ConsensusBranchIDError_InvalidRemoteBranch() async throws {
        underlyingConsensusBranchID = "1 1"

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("testValidateServerAction_ConsensusBranchIDError_InvalidRemoteBranch is expected to fail.")
        } catch ZcashError.compactBlockProcessorConsensusBranchID {
        } catch {
            XCTFail("""
            testValidateServerAction_ConsensusBranchIDError_InvalidRemoteBranch is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorConsensusBranchID
            """)
        }
    }

    func testValidateServerAction_ConsensusBranchIDError_ValidRemoteBranch() async throws {
        underlyingConsensusBranchID = "1"

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("testValidateServerAction_ConsensusBranchIDError_ValidRemoteBranch is expected to fail.")
        } catch let ZcashError.compactBlockProcessorWrongConsensusBranchId(expected, found) {
            XCTAssertEqual(expected, -1026109260)
            XCTAssertEqual(found, 1)
        } catch {
            XCTFail("""
            testValidateServerAction_ConsensusBranchIDError_ValidRemoteBranch is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorWrongConsensusBranchId
            """)
        }
    }

    func testValidateServerAction_CustomNetworkAcceptsMismatchedChainAndBranch() async throws {
        // A regtest custom network syncing against a modified-mainnet Ironwood backend: the backend
        // reports chainName "main" and a nonstandard branch id, but the Sapling activation matches.
        underlyingNetwork = ZcashNetworkBuilder.regtest(
            activationHeights: NetworkActivationHeights(sapling: 1, nu5: 1, nu6: 1, nu6_3: 5000)
        )
        underlyingChainName = "main"
        underlyingConsensusBranchID = "ffffffff"
        underlyingSaplingActivationHeight = nil

        let validateServerAction = setupAction()

        do {
            let context = ActionContextMock.default()
            let nextContext = try await validateServerAction.run(with: context) { _ in }

            let acResult = nextContext.checkStateIs(.fetchUTXO)
            XCTAssertTrue(acResult == .true, "Custom network should pass server validation, got '\(acResult)'")
        } catch {
            XCTFail("Custom network is not expected to fail server validation. \(error)")
        }
    }

    func testValidateServerAction_CustomNetworkStillChecksSaplingActivation() async throws {
        // Even for a custom network, a wrong Sapling-activation height (e.g. a real mainnet server)
        // must still be rejected.
        underlyingNetwork = ZcashNetworkBuilder.regtest(
            activationHeights: NetworkActivationHeights(sapling: 1, nu6_3: 5000)
        )
        underlyingChainName = "main"
        underlyingConsensusBranchID = "ffffffff"
        underlyingSaplingActivationHeight = 419_200

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("Custom network with mismatched Sapling activation is expected to fail.")
        } catch let ZcashError.compactBlockProcessorSaplingActivationMismatch(expected, found) {
            XCTAssertEqual(expected, 1)
            XCTAssertEqual(found, 419_200)
        } catch {
            XCTFail("""
            testValidateServerAction_CustomNetworkStillChecksSaplingActivation is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorSaplingActivationMismatch
            """)
        }
    }

    /// Sync validation reads the server's tip only to look up the consensus branch id, which a custom network
    /// skips. Every regtest network is a custom network, so on those a tip the SDK can't use does not fail
    /// validation, unlike on mainnet and testnet. Server evaluation rules such a server out on every network.
    func testValidateServerAction_CustomNetworkDoesNotLookAtTheServersTip() async throws {
        let customNetworks = [
            ZcashNetworkBuilder.network(for: .regtest),
            ZcashNetworkBuilder.regtest(activationHeights: NetworkActivationHeights(sapling: 1, nu5: 1, nu6: 1, nu6_3: 5000))
        ]

        for network in customNetworks {
            underlyingNetwork = network
            underlyingChainName = "main"
            underlyingConsensusBranchID = "ffffffff"
            underlyingBlockHeight = UInt64.max

            let validateServerAction = setupAction()

            let nextContext = try await validateServerAction.run(with: ActionContextMock.default()) { _ in }

            let acResult = nextContext.checkStateIs(.fetchUTXO)
            XCTAssertTrue(acResult == .true, "A custom network is expected to pass server validation, got '\(acResult)'")
        }
    }

    // A server can report any `UInt64`, and the branch id lookup takes an `Int32`: a tip it cannot
    // take has to fail the action with an error instead of trapping.

    func testValidateServerAction_BlockHeightAboveInt32Max_ThrowsServerBlockHeightOutOfRange() async throws {
        underlyingBlockHeight = UInt64(Int32.max) + 1

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("A tip above Int32.max is expected to fail server validation.")
        } catch ZcashError.compactBlockProcessorServerBlockHeightOutOfRange {
        } catch {
            XCTFail("""
            testValidateServerAction_BlockHeightAboveInt32Max is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorServerBlockHeightOutOfRange
            """)
        }
    }

    func testValidateServerAction_BlockHeightUInt64Max_ThrowsServerBlockHeightOutOfRange() async throws {
        underlyingBlockHeight = UInt64.max

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("A tip of UInt64.max is expected to fail server validation.")
        } catch ZcashError.compactBlockProcessorServerBlockHeightOutOfRange {
        } catch {
            XCTFail("""
            testValidateServerAction_BlockHeightUInt64Max is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorServerBlockHeightOutOfRange
            """)
        }
    }

    func testValidateServerAction_SaplingActivationUInt64Max_ReportsClampedHeightInMismatch() async throws {
        underlyingReportedSaplingActivationHeight = UInt64.max

        let validateServerAction = setupAction()

        do {
            _ = try await validateServerAction.run(with: ActionContextMock()) { _ in }
            XCTFail("A Sapling activation that does not match is expected to fail server validation.")
        } catch let ZcashError.compactBlockProcessorSaplingActivationMismatch(expected, found) {
            XCTAssertEqual(expected, 280_000)
            XCTAssertEqual(found, BlockHeight.max)
        } catch {
            XCTFail("""
            testValidateServerAction_SaplingActivationUInt64Max is expected to fail but error \(error) doesn't match \
            ZcashError.compactBlockProcessorSaplingActivationMismatch
            """)
        }
    }

    // MARK: - Ironwood server probe

    // Scanning cannot notice a server that omits Ironwood tree data, and the Ironwood pool is where the Orchard migration
    // moves funds, so the probe is the only guard. It has to keep running for as long as NU6.3 is active at the server's
    // tip: a later network upgrade changes the branch id the server reports but not the need for Ironwood data.

    /// The testnet tip at which NU7 activates (also pinned by `ConsensusBranchIDTests`).
    private let testnetNU7ActivationHeight: UInt64 = 4_465_026

    func testValidateServerAction_IronwoodProbe_NU63ServerWithoutIronwoodTree_Throws() async throws {
        let tipHeight = try testnetIronwoodActivationHeight()
        serveTip(at: tipHeight, branchID: ZcashSDK.nu63ConsensusBranchID, ironwoodTree: "")

        await assertProbeRejectsServer()
        assertProbeRequestedTreeState(at: tipHeight)
    }

    func testValidateServerAction_IronwoodProbe_NU63ServerWithIronwoodTree_Passes() async throws {
        let tipHeight = try testnetIronwoodActivationHeight()
        serveTip(at: tipHeight, branchID: ZcashSDK.nu63ConsensusBranchID, ironwoodTree: "01")

        await assertProbeAcceptsServer()
        assertProbeRequestedTreeState(at: tipHeight)
    }

    func testValidateServerAction_IronwoodProbe_NU7ServerWithoutIronwoodTree_Throws() async throws {
        serveTip(at: testnetNU7ActivationHeight, branchID: ZcashSDK.nu7ConsensusBranchID, ironwoodTree: "")

        await assertProbeRejectsServer()
        assertProbeRequestedTreeState(at: testnetNU7ActivationHeight)
    }

    func testValidateServerAction_IronwoodProbe_NU7ServerWithIronwoodTree_Passes() async throws {
        serveTip(at: testnetNU7ActivationHeight, branchID: ZcashSDK.nu7ConsensusBranchID, ironwoodTree: "01")

        await assertProbeAcceptsServer()
        assertProbeRequestedTreeState(at: testnetNU7ActivationHeight)
    }

    func testValidateServerAction_IronwoodProbe_UnrecognizedLaterBranchWithoutIronwoodTree_Throws() async throws {
        // The probe keys on NU6.3 being active at the tip, not on a branch id the SDK knows, so it also runs after
        // a network upgrade that this SDK version has no constant for.
        let tipHeight = testnetNU7ActivationHeight + 1_000_000
        serveTip(at: tipHeight, branchID: 0x1234_5678, ironwoodTree: "")

        await assertProbeRejectsServer()
        assertProbeRequestedTreeState(at: tipHeight)
    }

    func testValidateServerAction_IronwoodProbe_NotRunBeforeNU63Activation() async throws {
        // A server whose tip precedes NU6.3 has no Ironwood pool yet, so it is not asked for a tree state and an
        // empty `ironwoodTree` is expected there.
        let tipHeight = try testnetIronwoodActivationHeight() - 1
        serveTip(at: tipHeight, branchID: -1026109260, ironwoodTree: "")

        await assertProbeAcceptsServer()
        XCTAssertFalse(serviceMock.getTreeStateModeCalled, "A tip before NU6.3 activation is not expected to be probed.")
    }

    /// The height at which NU6.3 activates on testnet, read from the SDK instead of copied here.
    private func testnetIronwoodActivationHeight() throws -> UInt64 {
        UInt64(try XCTUnwrap(ZcashNetworkBuilder.network(for: .testnet).ironwoodActivationHeight))
    }

    /// Has the server report a tip of `height` on `branchID`, which the local consensus rules agree with, so the branch checks pass.
    private func serveTip(at height: UInt64, branchID: ConsensusBranchID, ironwoodTree: String) {
        underlyingBlockHeight = height
        underlyingConsensusBranchID = branchID.toString()
        underlyingLocalConsensusBranchID = branchID
        underlyingIronwoodTree = ironwoodTree
    }

    private func assertProbeRejectsServer(file: StaticString = #filePath, line: UInt = #line) async {
        let validateServerAction = setupAction()

        do {
            // A context that tolerates the state update, so an action that wrongly accepts the server fails this test instead of
            // trapping on an unset mock closure and ending the whole test run.
            _ = try await validateServerAction.run(with: ActionContextMock.default()) { _ in }
            XCTFail("A server that serves no Ironwood tree state past NU6.3 activation is expected to fail.", file: file, line: line)
        } catch ZcashError.compactBlockProcessorServerMissingIronwoodSupport {
        } catch {
            XCTFail(
                "Expected ZcashError.compactBlockProcessorServerMissingIronwoodSupport but got \(error).",
                file: file,
                line: line
            )
        }
    }

    private func assertProbeAcceptsServer(file: StaticString = #filePath, line: UInt = #line) async {
        let validateServerAction = setupAction()

        do {
            let nextContext = try await validateServerAction.run(with: ActionContextMock.default()) { _ in }

            let acResult = nextContext.checkStateIs(.fetchUTXO)
            XCTAssertTrue(acResult == .true, "Check of state failed with '\(acResult)'", file: file, line: line)
        } catch {
            XCTFail("The server is not expected to fail validation. \(error)", file: file, line: line)
        }
    }

    private func assertProbeRequestedTreeState(at tipHeight: UInt64, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(serviceMock.getTreeStateModeCallsCount, 1, "The tree state is expected to be requested once.", file: file, line: line)
        XCTAssertEqual(
            serviceMock.getTreeStateModeReceivedArguments?.id.height,
            tipHeight,
            "The tree state is expected to be requested at the server's tip.",
            file: file,
            line: line
        )
    }

    private func setupAction() -> ValidateServerAction {
        let network = underlyingNetwork ?? ZcashNetworkBuilder.network(for: underlyingNetworkType)
        let config: CompactBlockProcessor.Configuration = .standard(
            for: network, walletBirthday: 0
        )

        let tipHeight = underlyingBlockHeight
        let localBranchID = underlyingLocalConsensusBranchID

        let rustBackendMock = ZcashRustBackendWeldingMock()
        rustBackendMock.consensusBranchIdForHeightClosure = { height in
            XCTAssertEqual(UInt64(height), tipHeight, "")
            return localBranchID
        }

        let lightWalletdInfoMock = LightWalletdInfoMock()
        lightWalletdInfoMock.underlyingConsensusBranchID = underlyingConsensusBranchID
        lightWalletdInfoMock.underlyingSaplingActivationHeight = underlyingReportedSaplingActivationHeight
            ?? UInt64(underlyingSaplingActivationHeight ?? config.saplingActivation)
        lightWalletdInfoMock.underlyingBlockHeight = tipHeight
        lightWalletdInfoMock.underlyingChainName = underlyingChainName

        var treeState = TreeState()
        treeState.ironwoodTree = underlyingIronwoodTree

        // The container's closure captures this local, so the test keeps asserting on the same mock through the property.
        let serviceMock = self.serviceMock
        serviceMock.getInfoModeReturnValue = lightWalletdInfoMock
        serviceMock.getTreeStateModeReturnValue = treeState

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackendMock }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in serviceMock }
        mockContainer.mock(type: SDKFlags.self, isSingleton: true) { _ in SDKFlags(torEnabled: false, exchangeRateEnabled: false) }

        return ValidateServerAction(
            container: mockContainer,
            configProvider: CompactBlockProcessor.ConfigProvider(config: config)
        )
    }
}
