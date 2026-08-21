//
//  TransparentReceiverOwner.swift
//  ZcashLightClientKit
//

import Foundation

extension ZcashRustBackendWelding {
    /// The account that exposed `address` as one of its transparent receivers, or `nil` when no
    /// account did. The Tor UTXO lookup is account-scoped on the FFI side, so a caller holding only
    /// an address has to recover its owner first.
    func accountUUID(owning address: TransparentAddress) async throws -> AccountUUID? {
        for account in try await listAccounts() {
            let receivers = try await listTransparentReceivers(accountUUID: account.id)
            if receivers.contains(where: { $0.stringEncoded == address.stringEncoded }) {
                return account.id
            }
        }

        return nil
    }
}
