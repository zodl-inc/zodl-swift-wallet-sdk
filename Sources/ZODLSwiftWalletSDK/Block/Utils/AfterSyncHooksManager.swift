//
//  AfterSyncHooksManager.swift
//
//
//  Created by Michal Fousek on 20.02.2023.
//

import Foundation

class AfterSyncHooksManager {
    struct WipeContext {
        let prewipe: () -> Void
        let completion: (Error?) async -> Void
    }

    struct RewindContext {
        let height: BlockHeight?
        let completion: (Result<BlockHeight, Error>) async -> Void
    }

    enum Hook {
        case anotherSync
        case rewind(RewindContext)
    }

    private var anotherSync = false
    private var rewinds: [RewindContext] = []

    var isEmpty: Bool { !anotherSync && rewinds.isEmpty }

    func insert(hook: Hook) {
        switch hook {
        case .anotherSync:
            anotherSync = true
        case let .rewind(context):
            rewinds.append(context)
        }
    }

    func rewindContexts() -> [RewindContext] { rewinds }

    func shouldExecuteAnotherSyncHook() -> Bool { anotherSync }
}
