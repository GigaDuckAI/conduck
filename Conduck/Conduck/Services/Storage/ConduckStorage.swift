// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Storage seam
//
// Conduck's three persistent stores — App-Group `UserDefaults`, iCloud
// `NSUbiquitousKeyValueStore`, and the synchronizable Keychain — reach the app
// ONLY through the protocols below. Production wires the live adapters
// (`LiveStorage.swift`); a test host wires in-memory doubles
// (`InMemoryStorage.swift`).
//
// WHY a seam and not per-suite teardown: all three stores are shared and two of
// them SYNC. A test writing `remoteAgent.url.openclaw` lands in the developer's
// real App-Group container and, via iCloud, on their phone and watch. A
// synchronizable Keychain item is likewise a real iCloud-Keychain item — a
// `"<service>.tests"` namespace would still propagate. Cleanup discipline
// cannot substitute for never touching the store at all.
//
// The raw APIs (`UserDefaults(suiteName:)`, `NSUbiquitousKeyValueStore.default`,
// `SecItem*`, `FileManager.ubiquityIdentityToken`) are permitted ONLY inside
// `LiveStorage.swift`. `scripts/check-storage-seam.sh` fails the build-adjacent
// check if they appear elsewhere.

// MARK: - Defaults

/// The `UserDefaults` surface Conduck actually uses against its App Group.
/// Deliberately narrow — a double only has to reproduce these semantics.
protocol DefaultsStore: Sendable {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool
    func double(forKey key: String) -> Double
    func integer(forKey key: String) -> Int
    func array(forKey key: String) -> [Any]?
    func stringArray(forKey key: String) -> [String]?

    func set(_ value: Any?, forKey key: String)
    func set(_ value: Bool, forKey key: String)
    func set(_ value: Double, forKey key: String)
    func set(_ value: Int, forKey key: String)
    func removeObject(forKey key: String)

    /// Every key currently present. Used by the prefix sweeps (orphan
    /// reconciliation, per-ref key enumeration).
    func dictionaryRepresentation() -> [String: Any]
}

// MARK: - Ubiquitous key-value store

/// The `NSUbiquitousKeyValueStore` surface Conduck uses.
protocol UbiquitousStore: Sendable {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool
    func double(forKey key: String) -> Double
    func array(forKey key: String) -> [Any]?

    func set(_ value: Any?, forKey key: String)
    func set(_ value: Bool, forKey key: String)
    func set(_ value: Double, forKey key: String)
    func removeObject(forKey key: String)

    @discardableResult
    func synchronize() -> Bool

    func dictionaryRepresentation() -> [String: Any]
}

// MARK: - KVS change delivery

/// Why the ubiquitous store changed. Mirrors the
/// `NSUbiquitousKeyValueStore*Change` constants, but as a value the in-memory
/// double can emit directly — no `Notification` round-trip, no `userInfo`
/// unwrapping in the handler.
enum KVSChangeReason: Sendable {
    case serverChange
    case initialSyncChange
    case quotaViolationChange
    case accountChange
    /// A reason code Foundation added after this enum was written.
    case unknown(Int)

    /// The two reasons Conduck mirrors inbound. A quota violation or an account
    /// change carries no usable inbound delta.
    var deliversRemoteValues: Bool {
        switch self {
        case .serverChange, .initialSyncChange: return true
        case .quotaViolationChange, .accountChange, .unknown: return false
        }
    }
}

/// One external-change event from the ubiquitous store.
struct KVSChange: Sendable {
    let reason: KVSChangeReason
    let changedKeys: [String]
}

/// Delivers `KVSChange` events. The live adapter translates Apple's
/// notification; the in-memory double emits events on demand so the inbound
/// mirror is exercised deterministically, signed or not.
protocol KVSChangeSource: Sendable {
    /// Register a handler for external changes. The handler is invoked on the
    /// main queue. Registration is unconditional — a user who signs into iCloud
    /// mid-session must not need a relaunch before sync resumes.
    func observe(_ handler: @escaping @Sendable (KVSChange) -> Void)
}

// MARK: - Cloud availability

/// Whether this device evidences an iCloud account via the ubiquity identity
/// token — which tracks iCloud Drive, not KVS. `nil` means signed out, iCloud
/// Drive off, or a mis-provisioned entitlement; KVS and iCloud Keychain can
/// still be syncing. Consumers gate KVS push-UP writes on this, never cache
/// reads — reading the KVS local cache is always safe.
protocol CloudAvailability: Sendable {
    var isAvailable: Bool { get }
}

// MARK: - Secrets

/// A generic-password Keychain facade. The methods mirror `SecItem*` 1:1 so
/// call sites keep their existing query dictionaries (which carry
/// security-critical, heavily-reviewed attributes such as
/// `kSecAttrSynchronizable` and `kSecAttrAccessibleAfterFirstUnlock`) instead of
/// being re-expressed through a lossy convenience API.
protocol SecretStore: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

// MARK: - Dependency bundle

/// The stores a settings-owning service needs. Passed by constructor so a test
/// can build an isolated instance; `processDefault` is what production wires.
struct SettingsDependencies: Sendable {
    let defaults: any DefaultsStore
    let ubiquitous: any UbiquitousStore
    let secrets: any SecretStore
    let cloudAvailability: any CloudAvailability
    let changes: any KVSChangeSource

    init(
        defaults: any DefaultsStore,
        ubiquitous: any UbiquitousStore,
        secrets: any SecretStore,
        cloudAvailability: any CloudAvailability,
        changes: any KVSChangeSource
    ) {
        self.defaults = defaults
        self.ubiquitous = ubiquitous
        self.secrets = secrets
        self.cloudAvailability = cloudAvailability
        self.changes = changes
    }
}

extension SettingsDependencies {
    /// The bundle every production entry point uses.
    ///
    /// Under `CONDUCK_TESTING` — the `Debug-Testing` build configuration that
    /// every scheme's **Test** action builds the host with — this resolves to
    /// in-memory doubles, so a test host physically cannot open the real App
    /// Group, the real iCloud KVS, or the real Keychain. Run and Archive are
    /// unaffected (`official-build.sh` drives the scheme's Build/Archive
    /// actions, which stay Debug/Release).
    nonisolated static let processDefault: SettingsDependencies = {
        #if CONDUCK_TESTING
        return .inMemory()
        #else
        // Belt and braces: if XCTest is running and the host was NOT built with
        // `CONDUCK_TESTING`, the scheme has lost its `Debug-Testing` Test
        // configuration. Trap here — before a single live store opens — rather
        // than let the suite quietly write into the developer's real, syncing
        // stores. This is the check that catches a regenerated scheme.
        precondition(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            """
            XCTest is running against a host built WITHOUT CONDUCK_TESTING. \
            The scheme's Test action must build configuration "Debug-Testing". \
            Refusing to open live App-Group / iCloud-KVS / Keychain stores.
            """
        )
        return .live()
        #endif
    }()
}
