// SPDX-License-Identifier: Apache-2.0

// Conduck
// StorageTestSupport.swift
//
// Reaches the in-memory stores the app is running on inside this test host.
//
// The host is built with `CONDUCK_TESTING` (the `Debug-Testing` configuration
// every scheme's Test action selects), so `SettingsDependencies.processDefault`
// resolves to in-memory doubles. A test that wants to stage a value or assert a
// write must talk to THOSE stores — reaching for `UserDefaults(suiteName:)` or
// `NSUbiquitousKeyValueStore.default` would touch the developer's real,
// iCloud-syncing containers and assert against a store the app never reads.

import Foundation
@testable import ConduckWatch_Watch_App

enum TestStores {
    /// The App-Group defaults the app is using in this process.
    static var defaults: InMemoryDefaultsStore { unwrap(SettingsDependencies.processDefault.defaults) }

    /// The ubiquitous store the app is using. `simulateRemoteChange(values:)`
    /// stands in for a peer device's push.
    static var kvs: InMemoryUbiquitousStore { unwrap(SettingsDependencies.processDefault.ubiquitous) }

    /// The Keychain the app is using.
    static var secrets: InMemorySecretStore { unwrap(SettingsDependencies.processDefault.secrets) }

    /// Wipe all three. Cheaper and more complete than per-key teardown, and it
    /// cannot leak anywhere because nothing here is persistent.
    static func removeAll() {
        defaults.removeAll()
        kvs.removeAll()
        secrets.removeAll()
    }

    private static func unwrap<T>(_ store: Any) -> T {
        guard let typed = store as? T else {
            fatalError(
                """
                Test host is not running on in-memory stores (got \(type(of: store))). \
                The scheme's Test action must build configuration "Debug-Testing" so \
                CONDUCK_TESTING is defined.
                """
            )
        }
        return typed
    }
}
