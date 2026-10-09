//
//  BlockRepository.swift
//  ZODLSwiftWalletSDK
//
//  Created by Francisco Gindre on 10/16/19.
//  Copyright © 2019 Electric Coin Company. All rights reserved.
//

import Foundation

protocol BlockRepository {
    func lastScannedBlockHeight() -> BlockHeight
}
