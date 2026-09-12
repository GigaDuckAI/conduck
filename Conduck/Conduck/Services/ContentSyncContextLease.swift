// SPDX-License-Identifier: Apache-2.0

// Counts admitted Core Data contexts across actor suspension. A context lease
// lasts until its last use, including every await in a multi-batch operation;
// a container cannot be detached merely because one perform block returned.
// Explicit finish is idempotent and deinit is a backstop. Contexts remain
// confined to their own Core Data queues; only the count is lock-protected.

import CoreData
import Foundation

nonisolated final class ContentSyncContextRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var activeCount: Int { lock.withLock { count } }
    func admit() { lock.withLock { count += 1 } }
    func finish() { lock.withLock { count -= 1; precondition(count >= 0) } }
}

nonisolated final class ContentSyncContextLease: @unchecked Sendable {
    let context: NSManagedObjectContext
    private let registry: ContentSyncContextRegistry
    private let lock = NSLock()
    private var finished = false

    init(context: NSManagedObjectContext, registry: ContentSyncContextRegistry) {
        self.context = context
        self.registry = registry
        registry.admit()
    }

    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            registry.finish()
        }
    }

    deinit { finish() }
}
