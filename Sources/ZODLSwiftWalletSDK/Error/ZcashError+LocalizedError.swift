//
//  ZcashError+LocalizedError.swift
//
//  Presents ZcashError values via the Foundation error-reporting machinery.
//  This lives outside ZcashError.swift because that file is generated; see
//  ZcashErrorCodeDefinition.swift.

import Foundation

extension ZcashError: LocalizedError {
    public var errorDescription: String? {
        "\(code.rawValue): \(message)"
    }
}
