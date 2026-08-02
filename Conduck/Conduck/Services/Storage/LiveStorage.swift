// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Live adapters
//
// THE ONLY FILE PERMITTED to touch `UserDefaults(suiteName:)`,
// `NSUbiquitousKeyValueStore.default`, `SecItem*`, or
// `FileManager.ubiquityIdentityToken`. Everything else goes through the
// protocols in `ConduckStorage.swift`. `scripts/check-storage-seam.sh` enforces
// this — the seam is worthless if a new call site opens a live store directly.

// MARK: - Defaults

/// App-Group `UserDefaults`, straight through.
final class LiveDefaultsStore: DefaultsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    /// - Note: NO `?? .standard` fallback, and the failure is fatal by design.
    ///   `UserDefaults(suiteName:)` returns nil only for a structurally invalid
    ///   suite name — the app's own bundle identifier, or the global domain. It
    ///   does NOT return nil for a missing App Groups entitlement (that yields a
    ///   working object that silently shares with nobody). So nil here can only
    ///   mean `Constants.appGroupID` was built wrong at compile time: a
    ///   deterministic, every-launch, every-target failure, not a runtime
    ///   condition a user can hit. Degrading to `.standard` would split state
    ///   across the app, the Share extension, the widget and the Watch, and
    ///   surface as data loss instead of the build misconfiguration it is.
    init(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure(
                "App Group \(suiteName) is unavailable — check the App Groups entitlement."
            )
        }
        self.defaults = defaults
    }

    private init(wrapping defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Device-local `UserDefaults.standard` — a DIFFERENT store from the App
    /// Group: not shared with the extensions or the Watch, and never synced. Its
    /// only users are per-machine cosmetics (the mascot shuffle bag). Keep it
    /// distinct; routing it into the App-Group abstraction would silently widen
    /// where those values live.
    static let standard = LiveDefaultsStore(wrapping: .standard)

    func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func double(forKey key: String) -> Double { defaults.double(forKey: key) }
    func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    func array(forKey key: String) -> [Any]? { defaults.array(forKey: key) }
    func stringArray(forKey key: String) -> [String]? { defaults.stringArray(forKey: key) }

    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: Double, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }

    func dictionaryRepresentation() -> [String: Any] { defaults.dictionaryRepresentation() }
}

// MARK: - Ubiquitous key-value store

/// `NSUbiquitousKeyValueStore.default`, straight through.
final class LiveUbiquitousStore: UbiquitousStore, @unchecked Sendable {
    private let store = NSUbiquitousKeyValueStore.default

    func object(forKey key: String) -> Any? { store.object(forKey: key) }
    func string(forKey key: String) -> String? { store.string(forKey: key) }
    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func bool(forKey key: String) -> Bool { store.bool(forKey: key) }
    func double(forKey key: String) -> Double { store.double(forKey: key) }
    func array(forKey key: String) -> [Any]? { store.array(forKey: key) }

    func set(_ value: Any?, forKey key: String) { store.set(value, forKey: key) }
    func set(_ value: Bool, forKey key: String) { store.set(value, forKey: key) }
    func set(_ value: Double, forKey key: String) { store.set(value, forKey: key) }
    func removeObject(forKey key: String) { store.removeObject(forKey: key) }

    @discardableResult
    func synchronize() -> Bool { store.synchronize() }

    func dictionaryRepresentation() -> [String: Any] { store.dictionaryRepresentation }
}

// MARK: - KVS change delivery

/// Translates `NSUbiquitousKeyValueStore.didChangeExternallyNotification` into
/// the `KVSChange` value the handlers consume.
final class LiveKVSChangeSource: KVSChangeSource, @unchecked Sendable {
    func observe(_ handler: @escaping @Sendable (KVSChange) -> Void) {
        // Registration is UNCONDITIONAL — no `ubiquityIdentityToken` gate. The
        // token is nil while signed out at process start, but a user who signs
        // in later must not need a relaunch before sync resumes; an observer on
        // a dormant store costs nothing (no notifications fire while signed
        // out, and `synchronize()` is a harmless no-op there).
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let rawReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
                  let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            else { return }
            handler(KVSChange(reason: .init(rawValue: rawReason), changedKeys: changedKeys))
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}

extension KVSChangeReason {
    /// Map a Foundation `NSUbiquitousKeyValueStore*Change` constant.
    init(rawValue: Int) {
        switch rawValue {
        case NSUbiquitousKeyValueStoreServerChange: self = .serverChange
        case NSUbiquitousKeyValueStoreInitialSyncChange: self = .initialSyncChange
        case NSUbiquitousKeyValueStoreQuotaViolationChange: self = .quotaViolationChange
        case NSUbiquitousKeyValueStoreAccountChange: self = .accountChange
        default: self = .unknown(rawValue)
        }
    }
}

// MARK: - Cloud availability

/// Real iCloud account presence.
struct LiveCloudAvailability: CloudAvailability {
    var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }
}

// MARK: - Secrets

/// The real Keychain. Pass-through to `SecItem*` — the caller owns the query
/// dictionary, so `kSecAttrSynchronizable` / `kSecAttrAccessible` semantics stay
/// exactly where they are documented at the call site.
struct LiveSecretStore: SecretStore {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Bundle

extension SettingsDependencies {
    /// The production bundle — real App Group, real iCloud KVS, real Keychain.
    nonisolated static func live() -> SettingsDependencies {
        SettingsDependencies(
            defaults: LiveDefaultsStore(suiteName: Constants.appGroupID),
            ubiquitous: LiveUbiquitousStore(),
            secrets: LiveSecretStore(),
            cloudAvailability: LiveCloudAvailability(),
            changes: LiveKVSChangeSource()
        )
    }
}
