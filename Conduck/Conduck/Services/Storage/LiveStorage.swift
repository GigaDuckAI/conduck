// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import os

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

    @discardableResult
    func synchronize() -> Bool { defaults.synchronize() }

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
            // NEITHER userInfo VALUE MAY BE REQUIRED. Foundation supplies
            // `NSUbiquitousKeyValueStoreChangedKeysKey` ONLY for a server change
            // and an initial-sync change — it is absent for account change and
            // quota violation. Guarding on it drops those two notifications
            // entirely, one layer below the `deliversRemoteValues` policy, which
            // then reads as if account changes were considered and declined when
            // in fact they never arrived. Observers that deliberately reload on
            // ANY notification (the Watch settings reader) go stale on an iCloud
            // account switch and keep serving the previous account's values for
            // the rest of the process.
            let userInfo = notification.userInfo
            let changedKeys = userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            let reason = (userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int)
                .map(KVSChangeReason.init(rawValue:)) ?? .unknown(NSNotFound)
            handler(KVSChange(reason: reason, changedKeys: changedKeys))
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

/// Real App Group resolution stays behind the live adapter boundary. The file
/// implementation also accepts an explicit isolated directory for regression
/// tests, so locking, commits and reopen are tested without live settings.
nonisolated final class LiveContentSyncPolicyLock: ContentSyncPolicyPersistence, @unchecked Sendable {
    private let file = ContentSyncPolicyFile(directory: {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID)
    })

    func lock() -> Bool { file.lock() }
    func unlock() { file.unlock() }
    func readSnapshot() throws -> Data? { try file.readSnapshot() }
    func writeSnapshot(_ data: Data) throws { try file.writeSnapshot(data) }
}

/// The lock file is never replaced or removed. Only its separate JSON snapshot
/// is atomically replaced, so different processes always lock the same inode.
/// No UserDefaults or iCloud access: an explicit directory is fully isolated.
nonisolated final class ContentSyncPolicyFile: ContentSyncPolicyPersistence, @unchecked Sendable {
    enum Failure: Error { case unavailable }
    private static let log = Logger(subsystem: Constants.identityNamespace, category: "ContentSyncPolicy")
    private let localLock = NSLock()
    private let directory: @Sendable () -> URL?
    private var lockedDirectory: URL?
    private var descriptor: Int32 = -1

    init(directoryURL: URL) { directory = { directoryURL } }
    fileprivate init(directory: @escaping @Sendable () -> URL?) { self.directory = directory }

    func lock() -> Bool {
        guard localLock.try() else { return false }
        guard let directory = directory() else {
            Self.log.error("policy.lock stage=container-unavailable")
            localLock.unlock()
            return false
        }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch {
            Self.log.error("policy.lock stage=directory code=\((error as NSError).code)")
            localLock.unlock()
            return false
        }
        let path = directory.appendingPathComponent("ContentSyncPreference.lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            Self.log.error("policy.lock stage=open errno=\(errno)")
            localLock.unlock()
            return false
        }
        var result: Int32
        repeat { result = flock(descriptor, LOCK_EX | LOCK_NB) } while result != 0 && errno == EINTR
        guard result == 0 else {
            let code = errno
            if code != EWOULDBLOCK && code != EAGAIN {
                Self.log.error("policy.lock stage=flock errno=\(code)")
            }
            Darwin.close(descriptor)
            descriptor = -1
            localLock.unlock()
            return false
        }
        lockedDirectory = directory
        return true
    }

    func unlock() {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
        lockedDirectory = nil
        localLock.unlock()
    }

    func readSnapshot() throws -> Data? {
        guard let lockedDirectory else { throw Failure.unavailable }
        let url = lockedDirectory.appendingPathComponent("ContentSyncPreference.json")
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    func writeSnapshot(_ data: Data) throws {
        guard let lockedDirectory else { throw Failure.unavailable }
        try data.write(to: lockedDirectory.appendingPathComponent("ContentSyncPreference.json"), options: .atomic)
    }
}

extension SettingsDependencies {
    /// The production bundle — real App Group, real iCloud KVS, real Keychain.
    nonisolated static func live() -> SettingsDependencies {
        SettingsDependencies(
            defaults: LiveDefaultsStore(suiteName: Constants.appGroupID),
            ubiquitous: LiveUbiquitousStore(),
            secrets: LiveSecretStore(),
            cloudAvailability: LiveCloudAvailability(),
            changes: LiveKVSChangeSource(),
            contentSyncPolicyLock: LiveContentSyncPolicyLock()
        )
    }
}
