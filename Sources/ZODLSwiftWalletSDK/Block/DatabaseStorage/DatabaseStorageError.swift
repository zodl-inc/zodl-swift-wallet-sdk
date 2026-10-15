//
//  Storage.swift
//  ZODLSwiftWalletSDK
//
//  Created by Francisco Gindre on 10/13/19.
//  Copyright © 2019 Electric Coin Company. All rights reserved.
//

import Foundation

enum DatabaseStorageError: Error {
    case couldNotCreate
    case openFailed
    case closeFailed
    case operationFailed
    case updateFailed
    case malformedEntity(fields: [String]?)
    case transactionFailed(underlyingError: Error)
    case latestBlockNotFound
}
