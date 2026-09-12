// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardIsolatedStoreFixture.swift
//
// Every `ConversationStore(inMemory:)` mints a vault directory of its own under
// the simulator's temporary directory, and nothing owns its lifetime: the Core
// Data store is discarded at dealloc, but the payload leaves beside it are not.
// A Workboard suite publishes device-local payloads by design — several of them
// above the 30 MB sync ceiling, because that is what puts a card on the vault
// lane — so without a teardown each run leaves tens of megabytes per case
// behind until the device is wiped, and a long enough session fails on disk
// pressure rather than on a defect.
//
// This is the handle that closes them. A test class holds one, makes its stores
// through it, and empties it in `tearDown`; the store's own seam is what knows
// the generated path, and refuses anything but an isolated store.

import Foundation
@testable import Conduck

/// Stores made for one test class, and the vault directories they minted.
final class IsolatedWorkStores {
    private var stores: [ConversationStore] = []

    /// An in-memory store whose vault this fixture will remove.
    func make(proAccessProvider: @escaping @Sendable () -> ProAccessSnapshot = { .init() }) -> ConversationStore {
        let store = ConversationStore(inMemory: true, proAccessProvider: proAccessProvider)
        stores.append(store)
        return store
    }

    /// An on-disk store at `url` — the two-store topology cases need real
    /// sqlite files — whose vault this fixture will remove just the same.
    func make(storeURL: URL, proAccessProvider: @escaping @Sendable () -> ProAccessSnapshot = { .init() }) -> ConversationStore {
        let store = ConversationStore(storeURL: storeURL, proAccessProvider: proAccessProvider)
        stores.append(store)
        return store
    }

    /// Remove every vault directory these stores minted: payload leaves and
    /// staging markers together. Safe to call twice.
    func cleanUp() async {
        for store in stores {
            await store._removeIsolatedVaultDirectoryForTesting()
        }
        stores.removeAll()
    }
}
