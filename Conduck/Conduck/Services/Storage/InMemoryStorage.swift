// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - In-memory doubles
//
// Lock-backed dictionaries reproducing only the semantics Conduck uses. These
// replace the real stores in a test host so a suite can never write into the
// developer's App Group, iCloud KVS, or iCloud Keychain.
//
// WHY not an ephemeral `UserDefaults` suite: a FIXED suite name lets two
// concurrently-running hosts (app tests + appex tests, or parallel
// destinations) erase each other via `removePersistentDomain`; a
// unique-per-process name leaves a crash-residue plist behind on every abort;
// and `setVolatileDomain` is not a transparent replacement — ordinary
// `set(_:forKey:)` still writes to the PERSISTENT suite domain, so nothing is
// actually contained.
//
// Each fake is `@unchecked Sendable` because a single `NSLock` genuinely
// protects all of its mutable state. Change events are dispatched AFTER the
// lock is released so a handler that reads back the store cannot deadlock.

// MARK: - Defaults

final class InMemoryDefaultsStore: DefaultsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    init(seed: [String: Any] = [:]) {
        storage = seed
    }

    private func value(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func object(forKey key: String) -> Any? { value(forKey: key) }
    func string(forKey key: String) -> String? { value(forKey: key) as? String }
    func data(forKey key: String) -> Data? { value(forKey: key) as? Data }
    func array(forKey key: String) -> [Any]? { value(forKey: key) as? [Any] }
    func stringArray(forKey key: String) -> [String]? { value(forKey: key) as? [String] }

    /// Matches `UserDefaults.bool(forKey:)`: a missing key is `false`, and a
    /// stored `NSNumber`/`String` coerces the same way.
    func bool(forKey key: String) -> Bool {
        switch value(forKey: key) {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return (text as NSString).boolValue
        case .none: return false
        default: return false
        }
    }

    func double(forKey key: String) -> Double {
        switch value(forKey: key) {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return (text as NSString).doubleValue
        default: return 0
        }
    }

    func integer(forKey key: String) -> Int {
        switch value(forKey: key) {
        case let number as NSNumber: return number.intValue
        case let text as String: return (text as NSString).integerValue
        default: return 0
        }
    }

    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        // `UserDefaults.set(nil, forKey:)` removes the key.
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }

    func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
    func set(_ value: Double, forKey key: String) { set(value as Any?, forKey: key) }
    func set(_ value: Int, forKey key: String) { set(value as Any?, forKey: key) }

    func removeObject(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Test affordance — drop everything.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - Ubiquitous key-value store

final class InMemoryUbiquitousStore: UbiquitousStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]
    private var handlers: [@Sendable (KVSChange) -> Void] = []

    init(seed: [String: Any] = [:]) {
        storage = seed
    }

    private func value(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func object(forKey key: String) -> Any? { value(forKey: key) }
    func string(forKey key: String) -> String? { value(forKey: key) as? String }
    func data(forKey key: String) -> Data? { value(forKey: key) as? Data }
    func array(forKey key: String) -> [Any]? { value(forKey: key) as? [Any] }

    func bool(forKey key: String) -> Bool {
        switch value(forKey: key) {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        default: return false
        }
    }

    func double(forKey key: String) -> Double {
        (value(forKey: key) as? NSNumber)?.doubleValue ?? 0
    }

    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }

    func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
    func set(_ value: Double, forKey key: String) { set(value as Any?, forKey: key) }

    func removeObject(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    @discardableResult
    func synchronize() -> Bool { true }

    func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    // MARK: Change simulation

    fileprivate func addHandler(_ handler: @escaping @Sendable (KVSChange) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    /// Stand in for a peer device's write: set the values, then deliver the
    /// external-change event the inbound mirror listens for. Exercises
    /// `handleICloudChange` deterministically — no signing, no Apple sync
    /// timing.
    func simulateRemoteChange(
        reason: KVSChangeReason = .serverChange,
        values: [String: Any?]
    ) {
        lock.lock()
        for (key, value) in values {
            if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
        }
        let snapshot = handlers
        lock.unlock()

        let change = KVSChange(reason: reason, changedKeys: Array(values.keys))
        for handler in snapshot { handler(change) }
    }

    /// Test affordance — drop everything (does not notify).
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

/// Change source backed by an `InMemoryUbiquitousStore`.
final class InMemoryKVSChangeSource: KVSChangeSource, @unchecked Sendable {
    private let store: InMemoryUbiquitousStore

    init(store: InMemoryUbiquitousStore) {
        self.store = store
    }

    func observe(_ handler: @escaping @Sendable (KVSChange) -> Void) {
        store.addHandler(handler)
    }
}

// MARK: - Cloud availability

/// Fixed availability. Flip to `true` to exercise the KVS read-fallback and
/// `performInitialSync`, both of which production gates on an iCloud account.
final class StubCloudAvailability: CloudAvailability, @unchecked Sendable {
    private let lock = NSLock()
    private var available: Bool

    init(available: Bool = false) {
        self.available = available
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    func setAvailable(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        available = value
    }
}

// MARK: - Secrets

/// Generic-password Keychain double.
///
/// Reproduces the attributes Conduck's queries actually key on: `kSecAttrService`,
/// `kSecAttrAccount`, and — critically — `kSecAttrSynchronizable`, which makes a
/// synchronizable item a DISTINCT item from a non-sync one with the same
/// account. The migration paths depend on exactly that distinction, so the
/// double must honour it or the migration tests would pass vacuously.
///
/// Absent `kSecAttrSynchronizable` means `false`, matching the Security
/// framework's default. `kSecAttrSynchronizableAny` matches both.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private struct ItemKey: Hashable {
        let service: String
        let account: String
        let synchronizable: Bool
    }

    private struct Item {
        var data: Data
        var accessible: String?
    }

    private let lock = NSLock()
    private var items: [ItemKey: Item] = [:]

    init() {}

    // MARK: Query decoding

    /// `nil` = the query named no service, which the real Keychain treats as a
    /// WILDCARD (it matches items of any service). Returning `""` and requiring
    /// equality instead would make such a query match nothing here, so a suite
    /// exercising that shape would pass vacuously against a fake that disagrees
    /// with `SecItemCopyMatching`.
    private func service(_ query: [String: Any]) -> String? {
        query[kSecAttrService as String] as? String
    }

    private func account(_ query: [String: Any]) -> String? {
        query[kSecAttrAccount as String] as? String
    }

    /// `nil` = match any synchronizable state (`kSecAttrSynchronizableAny`).
    private func synchronizable(_ query: [String: Any]) -> Bool? {
        guard let raw = query[kSecAttrSynchronizable as String] else { return false }
        if let string = raw as? String, string == (kSecAttrSynchronizableAny as String) {
            return nil
        }
        if let number = raw as? NSNumber { return number.boolValue }
        if let flag = raw as? Bool { return flag }
        return nil
    }

    private func matches(_ key: ItemKey, query: [String: Any]) -> Bool {
        if let wanted = service(query), key.service != wanted { return false }
        if let wanted = account(query), key.account != wanted { return false }
        if let wanted = synchronizable(query), key.synchronizable != wanted { return false }
        return true
    }

    // MARK: SecretStore

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        lock.lock()
        let matched = items
            .filter { matches($0.key, query: query) }
            // Stable order so `kSecMatchLimitOne` is deterministic.
            .sorted { $0.key.account < $1.key.account }
        lock.unlock()

        guard !matched.isEmpty else { return (errSecItemNotFound, nil) }

        let wantsAll = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
        let wantsAttributes = (query[kSecReturnAttributes as String] as? Bool) == true
        let wantsData = (query[kSecReturnData as String] as? Bool) == true

        func attributes(for entry: (key: ItemKey, value: Item)) -> [String: Any] {
            var dict: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: entry.key.service,
                kSecAttrAccount as String: entry.key.account,
                kSecAttrSynchronizable as String: entry.key.synchronizable
            ]
            if let accessible = entry.value.accessible {
                dict[kSecAttrAccessible as String] = accessible
            }
            if wantsData { dict[kSecValueData as String] = entry.value.data }
            return dict
        }

        if wantsAll {
            if wantsAttributes {
                return (errSecSuccess, matched.map(attributes) as AnyObject)
            }
            return (errSecSuccess, matched.map { $0.value.data } as AnyObject)
        }

        guard let first = matched.first else { return (errSecItemNotFound, nil) }
        if wantsAttributes {
            return (errSecSuccess, attributes(for: first) as AnyObject)
        }
        if wantsData {
            return (errSecSuccess, first.value.data as AnyObject)
        }
        return (errSecSuccess, nil)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        guard let account = account(attributes),
              let data = attributes[kSecValueData as String] as? Data
        else { return errSecParam }

        let key = ItemKey(
            service: service(attributes) ?? "",
            account: account,
            synchronizable: synchronizable(attributes) ?? false
        )

        lock.lock()
        defer { lock.unlock() }
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = Item(
            data: data,
            accessible: (attributes[kSecAttrAccessible as String] as? String)
                ?? (attributes[kSecAttrAccessible as String]).map { String(describing: $0) }
        )
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let matched = items.keys.filter { matches($0, query: query) }
        guard !matched.isEmpty else { return errSecItemNotFound }
        // `SecItemUpdate` can update attributes OTHER than the payload, and
        // succeeds when it does. Only the payload is modelled here, so an update
        // carrying none is a successful no-op rather than `errSecParam`.
        if let data = attributes[kSecValueData as String] as? Data {
            for key in matched { items[key]?.data = data }
        }
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let matched = items.keys.filter { matches($0, query: query) }
        guard !matched.isEmpty else { return errSecItemNotFound }
        for key in matched { items.removeValue(forKey: key) }
        return errSecSuccess
    }

    /// Test affordance — drop everything.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
    }
}

// MARK: - Bundle

extension SettingsDependencies {
    /// A fully isolated bundle. Every store is fresh, so two bundles cannot see
    /// each other's writes.
    /// - Parameter cloudAvailable: defaults to `false`, matching a device
    ///   signed OUT of iCloud — the posture the headless simulator has always
    ///   had (`ubiquityIdentityToken` is nil there). This keeps the KVS
    ///   read-fallback off by default, so one suite's dual-written KVS value
    ///   cannot leak into another suite's read. Pass `true` to exercise the
    ///   fallback or `performInitialSync`, both of which production gates on an
    ///   iCloud account.
    nonisolated static func inMemory(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        ubiquitous: InMemoryUbiquitousStore = InMemoryUbiquitousStore(),
        secrets: InMemorySecretStore = InMemorySecretStore(),
        cloudAvailable: Bool = false
    ) -> SettingsDependencies {
        SettingsDependencies(
            defaults: defaults,
            ubiquitous: ubiquitous,
            secrets: secrets,
            cloudAvailability: StubCloudAvailability(available: cloudAvailable),
            changes: InMemoryKVSChangeSource(store: ubiquitous)
        )
    }
}
